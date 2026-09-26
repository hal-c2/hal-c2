defmodule HalC2.Mcp do
  @moduledoc """
  The `hal-c2` MCP server that agents get in their provider sessions, so an agent
  can work with HAL-C2 itself: read and message threads, launch new ones, and manage
  the queue, projects, and schedule (`HalC2.Mcp.Tools`).

  It is served at `POST /mcp` on the node, as JSON-RPC over HTTP (MCP's
  streamable HTTP transport, answered with plain JSON). Each thread has its own
  bearer credential (`server/2`), given to that thread's agent, so every tool call
  acts as the thread that made it. A credential lapses after a day without MCP
  traffic while its thread has no run in progress (`:mcp_liveness_ms`), and is
  revoked when the thread's provider session stops (`revoke/1`).

  A project can turn the server off for its threads (`enableAgentBrowserAccess`
  in its settings overrides).

  Tool definitions and the instructions agents get come from the Node server
  (`scripts/export-mcp-tools.ts`), so both servers advertise the same tools.
  """

  use GenServer

  @table __MODULE__.Credentials
  @protocol "2025-06-18"
  @liveness_ms 24 * 60 * 60 * 1_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  The MCP server for the agent of `thread_id` running on `instance`:
  `%{url: url, authorization: "Bearer ..."}`.
  """
  def server(thread_id, instance) do
    token =
      case :ets.match(@table, {:"$1", %{thread_id: thread_id, instance: instance}, :_}) do
        [[token] | _] -> token
        [] -> GenServer.call(__MODULE__, {:credential, thread_id, instance})
      end

    port = Application.get_env(:hal_c2, :port, 3780)
    %{url: "http://127.0.0.1:#{port}/mcp", authorization: "Bearer " <> token}
  end

  @doc "Revokes every credential of `thread_id`, as its provider session stops."
  def revoke(thread_id) do
    if :ets.whereis(@table) != :undefined,
      do: :ets.match_delete(@table, {:_, %{thread_id: thread_id, instance: :_}, :_})

    :ok
  end

  @doc """
  The MCP server to give the agent of `thread_id`, or nil when the user keeps HAL-C2's
  tools from agents (`enableAgentBrowserAccess`, which gates the whole server).
  """
  def for_agent(thread_id, instance) do
    project =
      case HalC2.Shell.row(node(), thread_id) do
        {"thread", row} -> row["projectId"]
        _ -> nil
      end

    allowed =
      Process.whereis(HalC2.Settings) == nil or
        HalC2.Settings.for_project(project)["enableAgentBrowserAccess"] != false

    if Process.whereis(__MODULE__) && allowed, do: server(thread_id, instance)
  end

  @doc "What agents are told about the tools, for their system or developer prompt."
  def instructions do
    case :persistent_term.get({__MODULE__, :instructions}, nil) do
      nil ->
        text = File.read!(Application.app_dir(:hal_c2, "priv/mcp_instructions.md"))
        :persistent_term.put({__MODULE__, :instructions}, text)
        text

      text ->
        text
    end
  end

  @doc """
  Answers one MCP request: `{status, body}` where `body` is JSON or nil. `authorization`
  is the request's Authorization header.
  """
  def handle(authorization, body) do
    with "Bearer " <> token <- authorization || :missing,
         [{_, caller, last_alive}] <- :ets.lookup(@table, token),
         :ok <- alive(token, caller, last_alive) do
      case JSON.decode(body) do
        {:ok, %{"method" => method} = request} -> answer(request, method, caller)
        _ -> {400, rpc_error(nil, -32700, "Parse error")}
      end
    else
      _ ->
        {401,
         %{
           "error" => "invalid_mcp_credential",
           "message" => "A valid provider-scoped MCP bearer credential is required."
         }}
    end
  end

  # A credential stays alive while its agent calls in or its thread has a run in
  # progress (the Node server touches it on every provider turn); an idle one lapses.
  defp alive(token, caller, last_alive) do
    now = System.monotonic_time(:millisecond)

    if now - last_alive <= Application.get_env(:hal_c2, :mcp_liveness_ms, @liveness_ms) or
         running?(caller.thread_id) do
      :ets.update_element(@table, token, {3, now})
      :ok
    else
      :ets.delete(@table, token)
      :expired
    end
  end

  defp running?(thread_id) do
    HalC2.Streams.ensure(thread_id)
    |> HalC2.Streams.Server.state()
    |> HalC2.StreamState.list("run")
    |> Enum.any?(&(&1["status"] in ~w(preparing starting running waiting)))
  end

  # Notifications have no id and get no answer.
  defp answer(request, _method, _caller) when not is_map_key(request, "id"), do: {202, nil}

  defp answer(%{"id" => id} = request, method, caller) do
    case method do
      "initialize" ->
        {200,
         result(id, %{
           "protocolVersion" => get_in(request, ["params", "protocolVersion"]) || @protocol,
           "capabilities" => %{"tools" => %{"listChanged" => false}},
           "serverInfo" => %{"name" => "hal-c2", "version" => "0.1.0"},
           "instructions" => instructions()
         })}

      "ping" ->
        {200, result(id, %{})}

      "tools/list" ->
        {200, result(id, %{"tools" => HalC2.Mcp.Tools.list() ++ plugin_tools()})}

      "tools/call" ->
        %{"name" => name} = params = request["params"] || %{}
        {200, result(id, call(name, params["arguments"] || %{}, caller))}

      _ ->
        {200, rpc_error(id, -32601, "Method not found: #{method}")}
    end
  end

  # Tools of the enabled tool packs (`HalC2.Plugins`); HAL-C2's own keep their names.
  defp plugin_tools do
    own = MapSet.new(HalC2.Mcp.Tools.list(), & &1["name"])
    Enum.reject(HalC2.Plugins.tools(), &MapSet.member?(own, &1["name"]))
  end

  # A tool's answer as MCP content; a failure is an error result the agent can read.
  defp call(name, arguments, caller) do
    answer =
      if Enum.any?(HalC2.Mcp.Tools.list(), &(&1["name"] == name)),
        do: HalC2.Mcp.Tools.call(name, arguments, caller),
        else: HalC2.Plugins.call_tool(name, arguments) || HalC2.Mcp.Tools.call(name, arguments, caller)

    case answer do
      {:ok, value} ->
        %{
          "content" => [%{"type" => "text", "text" => JSON.encode!(value)}],
          "structuredContent" => value
        }

      # A tool whose answer is more than JSON, such as a screenshot.
      {:ok, value, content} ->
        %{"content" => content, "structuredContent" => value}

      {:error, code, message} ->
        failure = %{"_tag" => "OrchestratorMcpFailure", "code" => code, "message" => message}
        %{"content" => [%{"type" => "text", "text" => JSON.encode!(failure)}], "isError" => true}
    end
  end

  defp result(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp rpc_error(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  # --- server ------------------------------------------------------------------

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, nil}
  end

  @impl true
  def handle_call({:credential, thread_id, instance}, _from, state) do
    caller = %{thread_id: thread_id, instance: instance}

    token =
      case :ets.match(@table, {:"$1", caller, :_}) do
        [[token] | _] ->
          token

        [] ->
          token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
          :ets.insert(@table, {token, caller, System.monotonic_time(:millisecond)})
          token
      end

    {:reply, token, state}
  end
end
