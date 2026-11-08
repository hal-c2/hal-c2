defmodule HalC2.Test.FakeSandbox do
  @moduledoc """
  A review sandbox for `HalC2.Test.FakeOpenShell`'s `:exec` (#1412): `exec/3` answers
  the commands `HalC2.OpenShell.Review` and the thread runtimes run in one, with the
  sandbox's `/sandbox` standing for directory `root` here.

  - `tar -x ... -C dest -f -` unpacks its stdin into `dest`;
  - `sh -c script` runs `script` here, `/sandbox` in it rewritten to `root`;
  - `codex app-server` and `claude` are agents in Elixir that answer their handshakes
    and play one turn per message: they report through the MCP server they were given,
    the review broker, with `opts[:report]` (an approval unless it is `nil`), report
    `opts[:tokens]` tokens used (0), and finish the turn. With `hang: true` Codex's
    turn runs on, after `{:sandbox_turn, pid}` to `test`, until it is interrupted.

  `opts` may be a function giving them, asked again for each command. `test` hears
  `{:sandbox_exec, argv, %{workdir, environment}}` for every command, and
  `{:sandbox_reported, status, body}` for each answer the broker gave the agent. With
  `hold: program`, a command of `program` waits to start for `:release`, sent to the
  pid of `{:sandbox_held, pid}`.
  """

  @report %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []}

  @doc """
  A directory for a sandbox's `/sandbox`, removed when the test ends. Its path is
  plain, since the fake rewrites scripts with it: a test's own `tmp_dir` is named
  for the test, quotes included.
  """
  def root do
    root = Path.join(System.tmp_dir!(), "fake-sandbox-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(root) end)
    root
  end

  def exec(root, test, opts \\ []) do
    fn command, io, start ->
      opts = if is_function(opts, 0), do: opts.(), else: opts

      send(
        test,
        {:sandbox_exec, command, %{workdir: start.workdir, environment: start.environment}}
      )

      # `hold: program` keeps that program from starting until the test releases it.
      if List.first(command) == opts[:hold] do
        send(test, {:sandbox_held, self()})

        receive do
          :release -> :ok
        end
      end

      run(command, io, %{root: root, test: test, opts: Map.new(opts)})
    end
  end

  defp run(["tar", "-x" | args], io, s) do
    dest = args |> Enum.drop_while(&(&1 != "-C")) |> Enum.at(1) |> local(s)
    archive = stdin(io, [])
    File.mkdir_p!(dest)
    :ok = :erl_tar.extract({:binary, archive}, cwd: to_charlist(dest))
    io.exit.(0)
  end

  defp run(["sh", "-c", script], io, s) do
    {out, code} = System.cmd("sh", ["-c", String.replace(script, "/sandbox", s.root)])
    if out != "", do: io.stdout.(String.replace(out, s.root, "/sandbox"))
    io.exit.(code)
  end

  defp run(["codex", "app-server"], io, s), do: agent(io, s, "", &codex/3)
  defp run(["claude" | _], io, s), do: agent(io, s, "", &claude/3)
  defp run(_command, io, _s), do: io.exit.(127)

  defp stdin(io, acc) do
    case io.read.() do
      {:stdin, data} -> stdin(io, [acc, data])
      :eof -> IO.iodata_to_binary(acc)
      _ -> stdin(io, acc)
    end
  end

  # Reads JSON lines until stdin closes, handing each to `answer`.
  defp agent(io, s, buffer, answer) do
    case io.read.() do
      {:stdin, data} ->
        [rest | lines] = Enum.reverse(String.split(buffer <> data, "\n"))

        s =
          lines
          |> Enum.reverse()
          |> Enum.reject(&(&1 == ""))
          |> Enum.reduce(s, &answer.(JSON.decode!(&1), io, &2))

        agent(io, s, rest, answer)

      :eof ->
        io.exit.(0)

      _ ->
        agent(io, s, buffer, answer)
    end
  end

  defp out(io, message), do: io.stdout.(JSON.encode!(message) <> "\n")

  # --- codex app-server -----------------------------------------------------------------

  defp codex(%{"method" => "initialize", "id" => id}, io, s) do
    out(io, %{"id" => id, "result" => %{"userAgent" => "fake-sandbox-codex"}})
    s
  end

  defp codex(%{"method" => "thread/start", "id" => id, "params" => params}, io, s) do
    server = get_in(params, ["config", "mcp_servers", "hal-c2"]) || %{}
    out(io, %{"id" => id, "result" => %{"thread" => %{"id" => "sandboxed-thread"}}})

    Map.put(s, :mcp, %{
      url: server["url"],
      authorization: get_in(server, ["http_headers", "Authorization"])
    })
  end

  defp codex(%{"method" => "turn/start", "id" => id}, io, s) do
    turn = "sandboxed-turn-#{System.unique_integer([:positive])}"
    ctx = %{"threadId" => "sandboxed-thread", "turnId" => turn}
    out(io, %{"id" => id, "result" => %{"turn" => %{"id" => turn, "status" => "inProgress"}}})

    out(io, %{
      "method" => "turn/started",
      "params" => Map.put(ctx, "turn", %{"id" => turn, "status" => "inProgress"})
    })

    tokens = Map.get(s.opts, :tokens, 0)

    out(io, %{
      "method" => "thread/tokenUsage/updated",
      "params" =>
        Map.put(ctx, "tokenUsage", %{
          "last" => %{"totalTokens" => tokens, "inputTokens" => tokens, "outputTokens" => 0},
          "total" => %{"totalTokens" => tokens, "inputTokens" => tokens, "outputTokens" => 0}
        })
    })

    if s.opts[:hang] do
      # The turn runs until it is interrupted.
      send(s.test, {:sandbox_turn, self()})
      Map.put(s, :turn, ctx)
    else
      report(s)
      completed(io, ctx, "completed")
      s
    end
  end

  defp codex(%{"method" => "turn/interrupt", "id" => id}, io, s) do
    out(io, %{"id" => id, "result" => %{}})
    if s[:turn], do: completed(io, s.turn, "interrupted")
    Map.delete(s, :turn)
  end

  defp codex(%{"id" => id, "method" => _}, io, s) do
    out(io, %{"id" => id, "result" => %{}})
    s
  end

  defp codex(_message, _io, s), do: s

  defp completed(io, ctx, status),
    do:
      out(io, %{
        "method" => "turn/completed",
        "params" => Map.put(ctx, "turn", %{"id" => ctx["turnId"], "status" => status})
      })

  # --- claude stream-json -----------------------------------------------------------------

  defp claude(%{"type" => "control_request", "request_id" => id, "request" => request}, io, s) do
    {response, s} =
      case request do
        %{"subtype" => "mcp_set_servers", "servers" => servers} ->
          server = servers["hal-c2"] || %{}

          {%{"added" => Map.keys(servers), "removed" => [], "errors" => %{}},
           Map.put(s, :mcp, %{
             url: server["url"],
             authorization: get_in(server, ["headers", "Authorization"])
           })}

        _ ->
          {%{}, s}
      end

    out(io, %{
      "type" => "control_response",
      "response" => %{"subtype" => "success", "request_id" => id, "response" => response}
    })

    s
  end

  defp claude(%{"type" => "user"}, io, s) do
    session = "sandboxed-session"
    tokens = Map.get(s.opts, :tokens, 0)

    out(io, %{
      "type" => "system",
      "subtype" => "init",
      "session_id" => session,
      "model" => "claude-haiku",
      "permissionMode" => "default"
    })

    out(io, %{
      "type" => "assistant",
      "session_id" => session,
      "message" => %{
        "id" => "m-#{System.unique_integer([:positive])}",
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => "Reviewing"}],
        "usage" => %{"input_tokens" => tokens, "output_tokens" => 0}
      }
    })

    report(s)

    out(io, %{
      "type" => "result",
      "subtype" => "success",
      "is_error" => false,
      "result" => "done",
      "session_id" => session
    })

    s
  end

  defp claude(_message, _io, s), do: s

  # --- the broker ----------------------------------------------------------------------

  defp report(%{opts: opts} = s) do
    arguments = Map.get(opts, :report, @report)

    if arguments && s[:mcp] do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "code_review_report", "arguments" => arguments}
      }

      # `reports: n` sends the report n times at once.
      1..Map.get(opts, :reports, 1)
      |> Task.async_stream(fn _ -> post(s.mcp, request) end, timeout: 30_000)
      |> Enum.each(fn {:ok, {status, body}} ->
        send(s.test, {:sandbox_reported, status, body})
      end)
    end
  end

  @doc "POSTs JSON-RPC `body` to the broker `mcp` names: `{status, body}`."
  def post(%{url: url, authorization: authorization}, body) do
    {:ok, _} = Application.ensure_all_started(:inets)
    headers = if authorization, do: [{~c"authorization", to_charlist(authorization)}], else: []

    request =
      {to_charlist(url), headers, ~c"application/json", IO.iodata_to_binary(body_of(body))}

    {:ok, {{_, status, _}, _headers, answer}} =
      :httpc.request(:post, request, [timeout: 15_000], body_format: :binary)

    {status, answer}
  end

  defp body_of(body) when is_binary(body), do: body
  defp body_of(body), do: JSON.encode!(body)

  defp local(path, s), do: String.replace_prefix(path, "/sandbox", s.root)
end
