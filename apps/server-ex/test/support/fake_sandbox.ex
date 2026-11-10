defmodule HalC2.Test.FakeSandbox do
  @moduledoc """
  A review sandbox for `HalC2.Test.FakeOpenShell`'s `:exec` (#1412): `exec/3` answers
  the commands `HalC2.OpenShell.Review` and the thread runtimes run in one, with the
  sandbox's `/review` standing for directory `root` here.

  - `tar -x ... -C dest -f -` unpacks its stdin into `dest`;
  - `sh -c script` runs `script` here, `/review` in it rewritten to `root`;
  - `printenv NAME` answers the placeholder OpenShell puts in a sandbox's
    environment for a provider's credential, `openshell:resolve:env:fake_NAME`, or
    with `printenv: :missing` exits 1, as for a provider OpenShell did not attach;
  - `codex login --with-api-key` keeps its stdin as the sandbox's Codex login, and
    tells `test` `{:sandbox_login, key}`: as 0.117's, the fake's Codex turn fails
    without one;
  - `codex app-server` and `claude` are agents in Elixir that answer their handshakes
    and play one turn per message: they report through the MCP server they were given,
    the review broker, with `opts[:report]` (an approval unless it is `nil`), report
    `opts[:tokens]` tokens used (0), and finish the turn. Claude also reports
    `opts[:cached]` cache reads (0), with `rate_limit: info` a rate limit event, with
    `task_update: input` a TaskUpdate call that succeeds, and with `subagent_tokens: n` a subagent's message that used `n`,
    which its task's progress then says used `subagent_progress` (none), and its result
    says the turn used `cli_tokens` over every model (none). Codex, with `subagent_tokens`, spawns a subagent whose thread reports `n`. With `hang: true` Codex's turn runs on, after `{:sandbox_turn, pid}`
    to `test`, until it is interrupted. With `late_tokens: n` Codex tells, once its turn
    ended, that the thread used `n`.

  What the agents send the broker passes the sandbox's proxy first, which refuses an
  MCP revision the sandbox's policy does not allow; Codex, as 0.117's, sends no
  MCP-Protocol-Version header, and Claude sends `HalC2.OpenShell.Policy.mcp_version/0`.

  `stat -f` of the review's writable paths answers the tmpfs mounts it asked for,
  or an overlay with `disk: :unbounded`.

  `opts` may be a function giving them, asked again for each command. `test` hears
  `{:sandbox_exec, argv, %{workdir, environment}}` for every command, and
  `{:sandbox_reported, status, body}` for each answer the broker gave the agent, and
  Claude's `{:sandbox_prompt, content}` for each message it is sent, and Codex's
  `{:sandbox_thread_start, params}` for each thread it starts. With
  `hold: program`, a command of `program` waits to start for `:release`, sent to the
  pid of `{:sandbox_held, pid}`.
  """

  @report %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []}

  @doc """
  A directory for a sandbox's `/review`, removed when the test ends. Its path is
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

      run(command, io, %{
        root: root,
        test: test,
        opts: Map.new(opts),
        policy: Process.get(:fake_policy)
      })
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
    # A path's `/review`, not a ref's (`refs/review/base`).
    script = Regex.replace(~r{(?<![\w./-])/review(?![\w.-])}, script, s.root)
    {out, code} = System.cmd("sh", ["-c", script])
    if out != "", do: io.stdout.(String.replace(out, s.root, "/review"))
    io.exit.(code)
  end

  # The tmpfs mounts the review asked for, of their size, unless `disk: :unbounded`.
  defp run(["stat", "-f", "-c", "%T %b %S", "--" | paths], io, s) do
    sizes = Map.new(HalC2.OpenShell.Policy.writable())

    for path <- paths do
      line =
        if s.opts[:disk] == :unbounded,
          do: "overlayfs 26214400 4096",
          else: "tmpfs #{div(sizes[path], 4096)} 4096"

      io.stdout.(line <> "\n")
    end

    io.exit.(0)
  end

  defp run(["printenv", _name], io, %{opts: %{printenv: :missing}}), do: io.exit.(1)

  defp run(["printenv", name], io, _s) do
    io.stdout.("openshell:resolve:env:fake_#{name}\n")
    io.exit.(0)
  end

  defp run(["codex", "login", "--with-api-key"], io, s) do
    key = io |> stdin([]) |> String.trim()
    File.mkdir_p!(Path.dirname(login(s)))
    File.write!(login(s), key)
    send(s.test, {:sandbox_login, key})
    io.exit.(0)
  end

  defp run(["codex", "app-server"], io, s), do: agent(io, s, "", &codex/3)
  defp run(["claude" | _], io, s), do: agent(io, s, "", &claude/3)
  defp run(_command, io, _s), do: io.exit.(127)

  defp login(s), do: Path.join([s.root, "home", ".codex", "auth.json"])

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
    send(s.test, {:sandbox_thread_start, params})
    server = get_in(params, ["config", "mcp_servers", "hal-c2"]) || %{}
    out(io, %{"id" => id, "result" => %{"thread" => %{"id" => "sandboxed-thread"}}})

    # As 0.117's, the fake's Codex sends no MCP-Protocol-Version header.
    Map.put(s, :mcp, %{
      url: server["url"],
      authorization: get_in(server, ["http_headers", "Authorization"]),
      version: nil
    })
  end

  defp codex(%{"method" => "turn/start", "id" => id}, io, s) do
    turn = "sandboxed-turn-#{System.unique_integer([:positive])}"
    ctx = %{"threadId" => "sandboxed-thread", "turnId" => turn}
    out(io, %{"id" => id, "result" => %{"turn" => %{"id" => turn, "status" => "inProgress"}}})

    if File.exists?(login(s)), do: turn(io, ctx, s), else: unauthorized(io, ctx, s)
  end

  defp codex(%{"method" => "turn/interrupt", "id" => id}, io, s) do
    out(io, %{"id" => id, "result" => %{}})

    if s[:turn] do
      completed(io, s.turn, "interrupted")
      late_tokens(io, s.turn, s)
    end

    Map.delete(s, :turn)
  end

  defp codex(%{"id" => id, "method" => _}, io, s) do
    out(io, %{"id" => id, "result" => %{}})
    s
  end

  defp codex(_message, _io, s), do: s

  # As Codex 0.117 does with no login: its environment's key is not its login.
  defp unauthorized(io, ctx, s) do
    error = %{
      "message" => "unexpected status 401 Unauthorized: Missing bearer authentication in header"
    }

    out(io, %{
      "method" => "error",
      "params" => Map.merge(ctx, %{"error" => error, "willRetry" => false})
    })

    out(io, %{
      "method" => "turn/completed",
      "params" =>
        Map.put(ctx, "turn", %{"id" => ctx["turnId"], "status" => "failed", "error" => error})
    })

    s
  end

  defp turn(io, ctx, s) do
    out(io, %{
      "method" => "turn/started",
      "params" => Map.put(ctx, "turn", %{"id" => ctx["turnId"], "status" => "inProgress"})
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

    if sub = s.opts[:subagent_tokens] do
      child = "sandboxed-subagent"

      out(io, %{
        "method" => "item/started",
        "params" =>
          Map.put(ctx, "item", %{
            "type" => "collabAgentToolCall",
            "id" => "collab-1",
            "tool" => "spawnAgent",
            "prompt" => "Look closer",
            "senderThreadId" => "sandboxed-thread",
            "receiverThreadIds" => [child],
            "status" => "inProgress",
            "agentsStates" => %{child => %{"status" => "running"}}
          })
      })

      out(io, %{
        "method" => "thread/tokenUsage/updated",
        "params" => %{
          "threadId" => child,
          "turnId" => "sandboxed-subagent-turn",
          "tokenUsage" => %{
            "last" => %{"totalTokens" => sub, "inputTokens" => sub, "outputTokens" => 0},
            "total" => %{"totalTokens" => sub, "inputTokens" => sub, "outputTokens" => 0}
          }
        }
      })
    end

    if s.opts[:hang] do
      # The turn runs until it is interrupted.
      send(s.test, {:sandbox_turn, self()})
      Map.put(s, :turn, ctx)
    else
      report(s)
      completed(io, ctx, "completed")
      late_tokens(io, ctx, s)
      s
    end
  end

  # What the thread spent, told only after its turn ended.
  defp late_tokens(io, ctx, s) do
    if late = s.opts[:late_tokens] do
      out(io, %{
        "method" => "thread/tokenUsage/updated",
        "params" =>
          Map.put(ctx, "tokenUsage", %{
            "last" => %{"totalTokens" => late, "inputTokens" => late, "outputTokens" => 0},
            "total" => %{"totalTokens" => late, "inputTokens" => late, "outputTokens" => 0}
          })
      })
    end
  end

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
             authorization: get_in(server, ["headers", "Authorization"]),
             version: HalC2.OpenShell.Policy.mcp_version()
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

  defp claude(%{"type" => "user", "message" => message}, io, s) do
    send(s.test, {:sandbox_prompt, message["content"]})
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
        "usage" => %{
          "input_tokens" => tokens,
          "cache_read_input_tokens" => Map.get(s.opts, :cached, 0),
          "output_tokens" => 0
        }
      }
    })

    if sub = s.opts[:subagent_tokens] do
      out(io, %{
        "type" => "assistant",
        "session_id" => session,
        "parent_tool_use_id" => "toolu-subagent",
        "message" => %{
          "id" => "m-#{System.unique_integer([:positive])}",
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "Looking"}],
          "usage" => %{"input_tokens" => sub, "output_tokens" => 0}
        }
      })

      if total = s.opts[:subagent_progress] do
        out(io, %{
          "type" => "system",
          "subtype" => "task_progress",
          "session_id" => session,
          "task_id" => "task-subagent",
          "tool_use_id" => "toolu-subagent",
          "description" => "Looking",
          "usage" => %{"total_tokens" => total, "tool_uses" => 1, "duration_ms" => 10}
        })
      end
    end

    if info = s.opts[:rate_limit] do
      out(io, %{"type" => "rate_limit_event", "session_id" => session, "rate_limit_info" => info})
    end

    if task = s.opts[:task_update] do
      out(io, %{
        "type" => "assistant",
        "session_id" => session,
        "message" => %{
          "id" => "m-#{System.unique_integer([:positive])}",
          "role" => "assistant",
          "content" => [
            %{"type" => "tool_use", "id" => "toolu-task", "name" => "TaskUpdate", "input" => task}
          ]
        }
      })

      out(io, %{
        "type" => "user",
        "session_id" => session,
        "message" => %{
          "role" => "user",
          "content" => [
            %{
              "type" => "tool_result",
              "tool_use_id" => "toolu-task",
              "content" => "Updated task ##{task["taskId"]} status"
            }
          ]
        },
        "tool_use_result" => %{"success" => true, "taskId" => task["taskId"]}
      })
    end

    report(s)

    out(io, %{
      "type" => "result",
      "subtype" => "success",
      "is_error" => false,
      "result" => "done",
      "session_id" => session,
      "modelUsage" =>
        if(cli = s.opts[:cli_tokens],
          do: %{"claude-haiku" => %{"inputTokens" => cli, "outputTokens" => 0}},
          else: %{}
        )
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
      |> Task.async_stream(fn _ -> proxied(s, request) end, timeout: 30_000)
      |> Enum.each(fn {:ok, {status, body}} ->
        send(s.test, {:sandbox_reported, status, body})
      end)
    end
  end

  # OpenShell's proxy: it takes a request with no MCP-Protocol-Version header as of
  # 2025-03-26, as the MCP spec says, and refuses a revision the report endpoint's
  # policy does not list, before the broker sees it.
  defp proxied(%{mcp: mcp, policy: policy}, request) do
    version = mcp.version || "2025-03-26"

    allowed =
      case policy do
        %{network_policies: %{"report" => %{endpoints: [%{mcp: %{versions: versions}} | _]}}} ->
          versions

        _ ->
          [version]
      end

    if version in allowed,
      do: post(mcp, request),
      else: {403, ~s({"error":"mcp_protocol_version_not_allowed"})}
  end

  @doc "POSTs JSON-RPC `body` to the broker `mcp` names: `{status, body}`."
  def post(%{url: url, authorization: authorization} = mcp, body) do
    {:ok, _} = Application.ensure_all_started(:inets)
    headers = if authorization, do: [{~c"authorization", to_charlist(authorization)}], else: []

    headers =
      case mcp[:version] do
        nil -> headers
        version -> [{~c"mcp-protocol-version", to_charlist(version)} | headers]
      end

    request =
      {to_charlist(url), headers, ~c"application/json", IO.iodata_to_binary(body_of(body))}

    {:ok, {{_, status, _}, _headers, answer}} =
      :httpc.request(:post, request, [timeout: 15_000], body_format: :binary)

    {status, answer}
  end

  defp body_of(body) when is_binary(body), do: body
  defp body_of(body), do: JSON.encode!(body)

  defp local(path, s), do: String.replace_prefix(path, "/review", s.root)
end
