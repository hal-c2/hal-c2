defmodule HalC2.OpenShell.Broker do
  @moduledoc """
  The one place a review sandbox can talk to the MC (#1412): an MCP endpoint of its
  own that lists and calls one tool, the plugin tool the review reports with. It is
  not the MC's MCP server (`HalC2.Mcp`): a sandboxed agent gets no other HAL-C2 tool.

  Each review gets a token (`issue/1`) that names its thread, its review, the commit
  it is of and the tool, and lapses with the review's lease. A request needs it, is
  at most `HalC2.OpenShell.Policy.broker_body/0` bytes, and is answered for that
  thread only; the plugin validates the report on this side. The first report taken
  revokes the token and closes the sandbox (`HalC2.OpenShell.Review.close/2`), after
  the answer has gone out.

  It listens on its own port, started with the first review (`listen/0`). Where the
  sandbox reaches it is `config :hal_c2, :openshell_broker` (`host`, `ips`, `bind`,
  `port`), defaulting to the container runtime's name for this machine.
  """

  @behaviour Plug

  import Plug.Conn

  alias HalC2.OpenShell.Policy

  @table __MODULE__
  @path "/report"

  @doc """
  Starts the listener, linked to the caller (`HalC2.OpenShell.Review`), and answers
  where a sandbox reaches it: `{:ok, %{host, port, path, ips, url}, pid}`.
  """
  def listen do
    config = Application.get_env(:hal_c2, :openshell_broker, [])
    {:ok, ip} = :inet.parse_address(String.to_charlist(Keyword.get(config, :bind, "0.0.0.0")))

    with {:ok, pid} <-
           Bandit.start_link(
             plug: __MODULE__,
             ip: ip,
             port: Keyword.get(config, :port, 0),
             startup_log: false
           ),
         {:ok, {_ip, port}} <- ThousandIsland.listener_info(pid) do
      host = Keyword.get_lazy(config, :host, &default_host/0)

      {:ok,
       %{
         host: host,
         port: port,
         path: @path,
         ips: Keyword.get_lazy(config, :ips, &default_ips/0),
         url: "http://#{host}:#{port}#{@path}"
       }, pid}
    end
  end

  # The name the container runtime gives the machine a sandbox runs on. On Docker it
  # is the alias OpenShell's driver pins for the supervisor to the gateway's host
  # (loopback on Linux's host network, Docker's host-gateway on a Mac's bridge), and
  # the proxy connects an alias to that pinned address only, ahead of `ips`; so it
  # holds on either network while the broker binds every interface.
  defp default_host do
    case HalC2.OpenShell.state() do
      %{"driver" => "docker"} -> "host.docker.internal"
      _ -> "host.containers.internal"
    end
  end

  # The addresses that name resolves to from a sandbox: this machine's own, and the
  # address rootless Podman maps to it.
  defp default_ips do
    own =
      case :inet.getifaddrs() do
        {:ok, interfaces} ->
          for {_name, opts} <- interfaces,
              {:addr, {_, _, _, _} = addr} <- opts,
              addr != {127, 0, 0, 1},
              do: addr |> :inet.ntoa() |> to_string()

        _ ->
          []
      end

    Enum.uniq(own ++ ["169.254.1.2"])
  end

  @doc """
  A token for one report of `grant`: `%{thread_id, tool, review, commit, deadline}`
  (unix seconds). A thread has one token; a new one replaces the old.
  """
  def issue(%{thread_id: thread_id} = grant) do
    revoke(thread_id)
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    :ets.insert(@table, {hash(token), thread_id, grant, false})
    :ets.insert(@table, {{:thread, thread_id}, hash(token)})
    token
  end

  @doc "Revokes the token of `thread_id`, if it has one."
  def revoke(thread_id) do
    if :ets.whereis(@table) != :undefined do
      case :ets.take(@table, {:thread, thread_id}) do
        [{_, hashed}] -> :ets.delete(@table, hashed)
        [] -> :ok
      end
    end

    :ok
  end

  @doc "The grant of a live `token`, or nil."
  def grant(token) when is_binary(token) do
    with true <- :ets.whereis(@table) != :undefined,
         [{_, _thread_id, grant, _taking}] <- :ets.lookup(@table, hash(token)),
         true <- grant.deadline > System.os_time(:second) do
      grant
    else
      _ -> nil
    end
  end

  defp hash(token), do: :crypto.hash(:sha256, token)

  # A token takes one report at a time: `taking/2` flips its flag in one step, so of
  # two reports sent at once only one reaches the tool. A token revoked meanwhile is
  # gone, and nothing puts it back.
  defp taking(token, from) do
    key = hash(token)
    spec = [{{key, :"$1", :"$2", from}, [], [{{{:const, key}, :"$1", :"$2", not from}}]}]
    :ets.select_replace(@table, spec) == 1
  end

  @doc false
  # Made by `HalC2.OpenShell.Review`, which outlives every token. Public so the
  # plug's processes revoke one; it holds only the hashes of tokens.
  def table do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
  end

  # --- the endpoint ----------------------------------------------------------------------

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "POST", request_path: @path} = conn, _opts) do
    with {:ok, grant} <- authorize(conn),
         {:ok, body, conn} <- body(conn),
         {:ok, request} <- decode(body) do
      respond(conn, grant, request)
    else
      {:status, status, message} -> send_text(conn, status, message)
      {:status, status, message, conn} -> send_text(conn, status, message)
    end
  end

  def call(%Plug.Conn{request_path: @path} = conn, _opts), do: send_text(conn, 405, "POST only")
  def call(conn, _opts), do: send_text(conn, 404, "not found")

  defp authorize(conn) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         %{} = grant <- grant(token) do
      {:ok, Map.put(grant, :token, token)}
    else
      _ -> {:status, 401, "unauthorized"}
    end
  end

  defp body(conn) do
    limit = Policy.broker_body()

    case read_body(conn, length: limit, read_length: limit) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _, conn} -> {:status, 413, "too large", conn}
      {:error, _} -> {:status, 400, "unreadable"}
    end
  end

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, %{"jsonrpc" => "2.0", "method" => method} = request} when is_binary(method) ->
        {:ok, request}

      _ ->
        {:status, 400, "not a JSON-RPC request"}
    end
  end

  # Notifications get no answer.
  defp respond(conn, _grant, request) when not is_map_key(request, "id"),
    do: send_resp(conn, 202, "")

  defp respond(conn, grant, %{"id" => id, "method" => method} = request) do
    case method do
      "initialize" ->
        send_json(conn, result(id, initialized()))

      "ping" ->
        send_json(conn, result(id, %{}))

      "tools/list" ->
        send_json(conn, result(id, %{"tools" => tools(grant)}))

      "tools/call" ->
        call_tool(conn, grant, id, request["params"] || %{})

      _ ->
        send_json(conn, rpc_error(id, -32601, "Method not found: #{method}"))
    end
  end

  defp initialized do
    %{
      "protocolVersion" => Policy.mcp_version(),
      "capabilities" => %{"tools" => %{"listChanged" => false}},
      "serverInfo" => %{"name" => "hal-c2", "version" => "0.1.0"}
    }
  end

  defp tools(grant),
    do: Enum.filter(HalC2.Plugins.tools(grant.thread_id), &(&1["name"] == grant.tool))

  defp call_tool(conn, %{tool: tool} = grant, id, %{"name" => tool} = params) do
    arguments = if is_map(params["arguments"]), do: params["arguments"], else: %{}

    # The report is of the commit the sandbox was made for, and only while it stands.
    reported =
      case HalC2.OpenShell.Review.binding(grant.thread_id) do
        %{commit: commit} when commit == grant.commit ->
          if taking(grant.token, false) do
            case HalC2.Plugins.call_tool(tool, arguments, grant.thread_id) do
              {:ok, _} = ok ->
                ok

              # Not taken: the agent may correct its report and send it again.
              other ->
                taking(grant.token, true)
                other
            end
          else
            {:error, "report_in_progress", "A report of this review is being taken."}
          end

        _ ->
          {:error, "sandbox_closed", "The review's sandbox is closed."}
      end

    case reported do
      {:ok, value} ->
        # The first report taken is the only one: the token goes before the answer,
        # and the sandbox after it, sent or not (Bandit raises when its peer is gone).
        revoke(grant.thread_id)

        try do
          send_json(
            conn,
            result(id, %{
              "content" => [%{"type" => "text", "text" => JSON.encode!(value)}],
              "structuredContent" => value
            })
          )
        after
          HalC2.OpenShell.Review.close(grant.thread_id, "reported")
        end

      {:error, code, message} ->
        failure = %{"_tag" => "OrchestratorMcpFailure", "code" => code, "message" => message}

        send_json(
          conn,
          result(id, %{
            "content" => [%{"type" => "text", "text" => JSON.encode!(failure)}],
            "isError" => true
          })
        )

      nil ->
        send_json(conn, rpc_error(id, -32602, "Unknown tool: #{tool}"))
    end
  end

  defp call_tool(conn, _grant, id, params),
    do: send_json(conn, rpc_error(id, -32602, "Unknown tool: #{inspect(params["name"])}"))

  defp result(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp rpc_error(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  defp send_json(conn, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(body))
  end

  defp send_text(conn, status, text) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, text)
  end
end
