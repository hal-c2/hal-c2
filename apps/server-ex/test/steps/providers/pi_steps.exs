defmodule HalC2.Steps.Providers.Pi do
  @moduledoc """
  Steps for `features/providers/pi.feature`. The node runs Pi in its own RPC mode
  (`HalC2.Pi`, `HalC2.Pi.ThreadRuntime`); the scripted fake Pi (`fake_pi_rpc.py`, through
  `HalC2.Test.FakeAcp.install_pi/3`) is the user's `pi`, sessions and all.
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias HalC2.StreamState
  alias HalC2.Test.FakeAcp
  alias HalC2.Test.Node.World

  defp install(context, config \\ %{}, opts \\ []),
    do: FakeAcp.install_pi(context, config, Keyword.put_new(opts, :enabled, true))

  # A fake Pi with extra turn scripts ahead of the default ones.
  defp with_turns(context, turns), do: install(context, %{"turns" => turns ++ FakeAcp.pi_turns()})

  defp pi(context), do: FakeAcp.find(context.providers, "pi")

  # The Pi processes that served the thread: RPC sessions in `cwd` (the project by
  # default), not the throwaway ones that read models.
  defp thread_starts(context, cwd \\ nil) do
    cwd = cwd || World.project(context).root

    Enum.filter(
      FakeAcp.starts(context),
      &(&1["cwd"] == cwd and "rpc" in &1["argv"] and "--no-session" not in &1["argv"] and
          "--fork" not in &1["argv"])
    )
  end

  defp state(context, title \\ nil) do
    id = World.thread_id(context, title || context.thread)
    HalC2.Streams.Server.state(HalC2.Streams.ensure(id))
  end

  defp replies(context, title \\ nil) do
    for m <-
          context
          |> state(title)
          |> StreamState.list("message")
          |> Enum.sort_by(& &1["createdAt"]),
        m["role"] == "assistant",
        do: m["text"]
  end

  # Sends `text` and waits for its (new) run to finish as `status`.
  defp turn(context, text, status \\ "completed", title \\ nil) do
    before = for run <- StreamState.list(state(context, title), "run"), do: run["id"]
    context = FakeAcp.send_message(context, text, title)

    run =
      World.await_stream(World.thread_id(context, title || context.thread), fn state ->
        Enum.find(
          StreamState.list(state, "run"),
          &(&1["id"] not in before and &1["status"] in ~w(completed failed interrupted))
        )
      end)

    assert run["status"] == status
    context
  end

  # The thread's native conversation: Pi's session file.
  defp session_file(context, title \\ nil) do
    state = state(context, title)
    thread = StreamState.get(state, "thread")[World.thread_id(context, title || context.thread)]
    provider_thread = StreamState.get(state, "provider-thread")[thread["activeProviderThreadId"]]
    get_in(provider_thread, ["nativeThreadRef", "nativeId"])
  end

  defp items(context, type),
    do: context |> state() |> StreamState.list("turn-item") |> Enum.filter(&(&1["type"] == type))

  step "Pi is installed but not enabled", context do
    install(context, %{}, enabled: false)
  end

  step "no Pi process is started", context do
    HalC2.Acp.load()
    assert %{"enabled" => false} = FakeAcp.entry("pi")
    assert FakeAcp.starts(context, "pi") == []
    context
  end

  step "the pi command is not installed on the node", context do
    FakeAcp.services()
    HalC2.Acp.forget("pi")
    missing = Path.join(HalC2.Test.Node.tmp_dir(context.node, "no-pi"), "pi")
    FakeAcp.settings(&put_in(&1, ["providers"], %{"pi" => %{"binaryPath" => missing}}))
    Map.put(context, :provider, "pi")
  end

  step "Pi is not offered", context do
    assert context.providers != nil
    assert FakeAcp.find(context.providers, "pi") == nil
    context
  end

  step "Pi is installed and enabled", context do
    context = install(context)
    assert %{"enabled" => true} = FakeAcp.entry("pi")
    context
  end

  # The path lives in the scenario's machine (`HalC2.Test.Node.Host`).
  step "Pi's binary path is set to {string}", %{args: [path]} = context do
    install(context, %{}, path: HalC2.Test.Node.Host.path(context, path))
  end

  step "the user sends a message to Pi", context do
    context |> FakeAcp.thread() |> turn("hello Pi")
  end

  step "the turn runs on the user's own Pi installation", context do
    assert_runs_on(context, FakeAcp.fake(context).bin)
  end

  step "that Pi binary runs the turn", context do
    assert_runs_on(context, HalC2.Test.Node.Host.path(context, "/opt/pi/bin/pi"))
  end

  # That binary ran Pi's RPC mode in the project, with HAL-C2's extension, and got the
  # message as a prompt.
  defp assert_runs_on(context, bin) do
    assert [%{"argv" => argv, "env" => env}] = thread_starts(context)
    assert env["FAKE_BIN"] == bin
    assert ["--mode", "rpc" | _] = tl(argv)
    assert "--extension" in argv
    assert [%{"message" => "hello Pi"}] = FakeAcp.received_type(context, "prompt")
    context
  end

  # --- status ---

  step "the installed Pi is 0.79.0", context do
    install(context, %{"version" => "0.79.0"})
  end

  step "Pi is shown as unsupported with a hint to update to 0.80.5 or newer", context do
    assert %{"status" => "error", "message" => message} = pi(context)
    assert message == "Pi 0.79.0 is unsupported. Update to Pi 0.80.5 or newer."
    context
  end

  step "Pi reports no models", context do
    install(context, %{"models" => []})
  end

  step "Pi says to sign in with Pi in a terminal or configure an API key", context do
    assert %{"status" => "warning", "message" => message} = pi(context)
    assert message =~ "Run `pi` in a terminal and use /login, or configure an API key"
    assert pi(context)["auth"]["status"] == "unauthenticated"
    context
  end

  # Pi stops at a startup prompt, so the throwaway session that reads models and
  # commands never answers.
  step "Pi discovery needs interactive input", context do
    install(context, %{"discoveryError" => true})
  end

  step "Pi stays available with the {string} model", %{args: [name]} = context do
    entry = pi(context)
    assert entry["status"] != "error"
    assert [%{"slug" => "default", "name" => ^name}] = entry["models"]
    assert entry["message"] =~ "The live session will retry startup."
    context
  end

  # The thread runs on Pi's own default model; the node never picks one for it.
  step "the first thread lets Pi handle its startup prompt", context do
    context =
      context
      |> FakeAcp.configure(&Map.delete(&1, "discoveryError"))
      |> FakeAcp.thread("Work", "full-access", %{
        "modelSelection" => %{"instanceId" => "pi", "model" => "default"}
      })
      |> turn("hello Pi")

    assert [_] = thread_starts(context)
    assert FakeAcp.received_type(context, "set_model") == []
    context
  end

  # --- launch arguments ---

  step "the user adds the launch argument {string} to Pi", %{args: [args]} = context do
    context = install(context)
    FakeAcp.settings(&put_in(&1, ["providers", "pi", "launchArgs"], args))
    FakeAcp.probe("pi")
    {_, context} = FakeAcp.open_config(context)
    context
  end

  step "the setting is refused with a message that HAL-C2 owns that part of Pi", context do
    assert %{"status" => "error", "message" => message} = pi(context)

    assert message ==
             "Pi launch argument '--mode' is controlled by HAL-C2 and cannot be overridden."

    # Pi never ran with them.
    refute Enum.any?(FakeAcp.starts(context), &("json" in &1["argv"]))
    context
  end

  # --- thinking levels ---

  step "the Pi model supports thinking levels up to extra high", context do
    install(context, %{
      "thinkingLevel" => "high",
      "models" => [
        %{
          "provider" => "fake",
          "id" => "deep",
          "name" => "Deep",
          "reasoning" => true,
          "thinkingLevelMap" => %{"xhigh" => "xhigh"},
          "contextWindow" => 200_000
        }
      ]
    })
  end

  step "the user opens the options for that model", context do
    FakeAcp.probe("pi")
    {providers, context} = FakeAcp.open_config(context)
    model = Enum.find(FakeAcp.find(providers, "pi")["models"], &(&1["slug"] == "fake/deep"))

    assert [%{"id" => "thinking", "type" => "select"} = thinking] =
             model["capabilities"]["optionDescriptors"]

    Map.put(context, :thinking, thinking)
  end

  step "off, minimal, low, medium, high and extra high are offered", context do
    assert Enum.map(context.thinking["options"], & &1["label"]) ==
             ["Off", "Minimal", "Low", "Medium", "High", "Extra High"]

    context
  end

  step "Pi's configured level is marked as the default", context do
    assert [%{"id" => "high"}] = Enum.filter(context.thinking["options"], & &1["isDefault"])
    context
  end

  # --- access modes ---

  step ~r/^the thread runs Pi in (?<mode>approval required|auto-accept edits|full access)$/,
       %{args: [mode]} = context do
    context |> install() |> FakeAcp.thread("Work", String.replace(mode, " ", "-"))
  end

  step ~r/^Pi wants to (?<action>read a file|edit a file|run a command)$/,
       %{args: [action]} = context do
    FakeAcp.send_message(context, "please #{action}")
  end

  step "the user opens the access picker in a Pi thread", context do
    context = context |> install() |> FakeAcp.thread("Work", "approval-required")
    {_, context} = FakeAcp.open_config(context)
    context
  end

  step "a Pi thread saved with auto mode", context do
    context |> install() |> FakeAcp.thread("Work", "auto")
  end

  step "it shows and behaves as approval required", context do
    # Pi offers approval required first and no auto, so the thread shows that...
    assert ["approval-required" | modes] = pi(context)["supportedRuntimeModes"]
    refute "auto" in modes

    # ...and HAL-C2's extension in Pi holds an edit for the user.
    context = FakeAcp.send_message(context, "please edit a file")
    assert %{"status" => "pending", "kind" => "file-change"} = FakeAcp.await_request(context)

    assert [%{"env" => %{"HALC2_PI_RUNTIME_MODE" => "approval-required"}}] =
             thread_starts(context)

    context
  end

  step "a Pi thread with history", context do
    context =
      context
      |> install()
      |> FakeAcp.thread("Work", "approval-required")
      |> turn("hello Pi")

    Map.put(context, :pi_session, session_file(context))
  end

  # The next turn starts a new Pi in the new mode, which switches to the session file.
  step "Pi restarts and continues the same native conversation", context do
    context = turn(context, "hello again")

    assert [first, second] = thread_starts(context)
    assert first["env"]["HALC2_PI_RUNTIME_MODE"] == "approval-required"
    assert second["env"]["HALC2_PI_RUNTIME_MODE"] == "full-access"
    assert [%{"sessionPath" => session}] = FakeAcp.received_type(context, "switch_session")
    assert session == context.pi_session
    assert List.last(replies(context)) == "Reply to hello again after [hello Pi]"
    context
  end

  step "Pi asked to run the same command twice", context do
    context =
      context
      |> install()
      |> FakeAcp.thread("Work", "approval-required")
      |> FakeAcp.send_message("please run it twice")

    Map.put(context, :request, FakeAcp.await_request(context))
  end

  step "the user allows it for the session the first time", context do
    FakeAcp.respond(context, context.request["id"], %{"decision" => "acceptForSession"})
  end

  # Pi asked twice; the node answered the second itself.
  step "the second request is allowed without asking", context do
    state = FakeAcp.await_run(context, "completed")
    assert [%{"status" => "resolved"}] = StreamState.list(state, "runtime-request")
    log = FakeAcp.log(context)
    assert [_, _] = for(%{"ui" => %{"method" => "confirm"}} <- log, do: :asked)
    assert [_, _] = for(%{"tool" => %{"name" => "bash"}} <- log, do: :ran)

    assert [%{"confirmed" => true}, %{"confirmed" => true}] =
             FakeAcp.received_type(context, "extension_ui_response")

    context
  end

  # --- extension dialogs ---

  step "a Pi extension asks the user to pick from a list", context do
    turns = [
      %{
        "match" => "pick a color",
        "steps" => [%{"select" => %{"title" => "Pick a color", "options" => ~w(red green blue)}}]
      }
    ]

    context
    |> with_turns(turns)
    |> FakeAcp.thread()
    |> FakeAcp.send_message("pick a color")
  end

  step "the choices appear in the composer and the answer goes back to the extension", context do
    request = FakeAcp.await_request(context)
    assert request["kind"] == "user_input"

    [item] =
      World.await_stream(World.thread_id(context, context.thread), fn state ->
        case Enum.filter(
               StreamState.list(state, "turn-item"),
               &(&1["type"] == "user_input_request")
             ) do
          [] -> nil
          items -> items
        end
      end)

    assert [%{"id" => question, "header" => "Pick a color", "options" => options}] =
             item["questions"]

    assert Enum.map(options, & &1["label"]) == ~w(red green blue)

    context = FakeAcp.respond(context, request["id"], %{"answers" => %{question => "green"}})
    FakeAcp.await_run(context, "completed")
    assert [%{"value" => "green"}] = for(%{"ui_answer" => a} <- FakeAcp.log(context), do: a)
    assert List.last(replies(context)) == "Picked green."
    context
  end

  # --- Pi's terminal app ---

  step "a Pi thread in HAL-C2", context do
    context |> install() |> FakeAcp.thread() |> turn("hello Pi")
  end

  # Pi's own app continues a session file: `pi --session <file>`, here in print mode.
  step "the user opens the same session in Pi's own terminal app", context do
    file = session_file(context)
    assert is_binary(file) and File.exists?(file)

    {out, 0} =
      System.cmd(FakeAcp.fake(context).bin, ["--session", file, "-p", "what did I say"],
        cd: World.project(context).root
      )

    Map.merge(context, %{pi_session: file, terminal_reply: String.trim(out)})
  end

  step "the conversation continues there from the same session file", context do
    assert context.terminal_reply == "Reply to what did I say after [hello Pi]"

    assert [_, _, %{"message" => %{"role" => "user", "content" => "what did I say"}}, _] =
             JSON.decode!(File.read!(context.pi_session))["entries"]

    context
  end

  # --- rewind and fork ---

  step "a Pi thread with three turns", context do
    context = context |> install() |> FakeAcp.thread()
    context = Enum.reduce(~w(first second third), context, &turn(&2, &1))
    Map.merge(context, %{current_thread: context.thread, pi_session: session_file(context)})
  end

  # Pi forked its session before the second turn's user message; the thread goes on
  # in the new session file.
  step "Pi continues from the first turn", context do
    assert {:ok, _} = context.reply
    assert [%{"entryId" => entry}] = FakeAcp.received_type(context, "fork")
    assert entry == user_entry(context.pi_session, "second")

    context = turn(context, "where are we")
    assert List.last(replies(context)) == "Reply to where are we after [first]"
    assert session_file(context) != context.pi_session
    context
  end

  step "the user forks from the second turn into a new worktree", context do
    root = World.project(context).root
    worktree = Path.join(HalC2.Test.Node.tmp_dir(context.node, "worktrees"), "pi-fork")
    World.git!(root, ["worktree", "add", "-q", "-b", "pi-fork", worktree])
    source = World.thread_id(context, context.thread)
    run = state(context) |> StreamState.list("run") |> Enum.find(&(&1["ordinal"] == 2))
    id = "th-pi-fork-#{System.unique_integer([:positive])}"

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.fork",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "sourceThreadId" => source,
        "targetThreadId" => id,
        "title" => "fork",
        "sourcePoint" => %{"type" => "run", "runId" => run["id"]}
      })

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.metadata.update",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => id,
        "branch" => "pi-fork",
        "worktreePath" => worktree
      })

    context |> put_in([:threads, "fork"], id) |> Map.put(:worktree, worktree)
  end

  step "the new thread continues Pi's conversation through the second turn in that worktree",
       context do
    source = session_file(context)
    context = turn(context, "where are we", "completed", "fork")
    assert List.last(replies(context, "fork")) == "Reply to where are we after [first | second]"

    # A short-lived Pi copied the source's session in the worktree and cut it before
    # the third turn; the thread's Pi runs there on the copy.
    assert [%{"argv" => argv}] =
             Enum.filter(FakeAcp.starts(context), &("--fork" in &1["argv"]))

    assert [^source] = argv |> Enum.drop_while(&(&1 != "--fork")) |> Enum.slice(1, 1)
    assert [%{"cwd" => cwd}] = Enum.filter(FakeAcp.starts(context), &("--fork" in &1["argv"]))
    assert cwd == context.worktree
    assert [_] = thread_starts(context, context.worktree)
    copy = session_file(context, "fork")
    assert is_binary(copy) and copy != source
    context
  end

  # The id of the user message `text` in a Pi session file.
  defp user_entry(file, text) do
    Enum.find_value(JSON.decode!(File.read!(file))["entries"], fn entry ->
      if entry["message"] == %{"role" => "user", "content" => text}, do: entry["id"]
    end)
  end

  # --- skills ---

  step "Pi loads the project skill {string}", %{args: [name]} = context do
    root = World.project(context).root

    install(context, %{
      "commands" => [
        %{
          "name" => "skill:#{name}",
          "source" => "skill",
          "description" => "Deploy the app",
          "sourceInfo" => %{
            "path" => Path.join([root, ".pi", "skills", name, "SKILL.md"]),
            "scope" => "project"
          }
        }
      ]
    })
  end

  step "the user opens the skill menu in a Pi thread", context do
    FakeAcp.probe("pi")
    {providers, context} = context |> FakeAcp.thread() |> FakeAcp.open_config()
    Map.put(context, :skills, FakeAcp.find(providers, "pi")["skills"])
  end

  # HAL-C2 writes a skill as `$name`; Pi gets its own `/skill:name` command.
  step "{string} is offered and uses Pi's own skill expansion", %{args: [name]} = context do
    assert [%{"name" => ^name, "scope" => "project", "enabled" => true}] = context.skills
    context = turn(context, "$#{name} to staging")

    assert [%{"message" => message}] = FakeAcp.received_type(context, "prompt")
    assert message == "/skill:#{name} to staging"
    context
  end

  # --- retries and compactions ---

  step "Pi retries a failed request and later compacts the conversation", context do
    turns = [
      %{
        "match" => "a flaky request",
        "steps" => [
          %{
            "event" => %{
              "type" => "auto_retry_start",
              "attempt" => 1,
              "maxAttempts" => 3,
              "delayMs" => 10,
              "errorMessage" => "overloaded"
            }
          },
          %{"event" => %{"type" => "auto_retry_end", "success" => true, "attempt" => 1}},
          %{"text" => "Done."},
          %{"event" => %{"type" => "compaction_start", "reason" => "threshold"}},
          %{
            "event" => %{
              "type" => "compaction_end",
              "aborted" => false,
              "result" => %{
                "summary" => "The user asked for a flaky request.",
                "tokensBefore" => 150_000,
                "estimatedTokensAfter" => 20_000
              }
            }
          }
        ]
      }
    ]

    context |> with_turns(turns) |> FakeAcp.thread() |> turn("a flaky request")
  end

  step "the work log shows the retry and the compaction", context do
    assert [retry] = items(context, "error")

    assert %{
             "status" => "completed",
             "title" => "Provider recovered",
             "retry" => %{"attempt" => 1, "maxAttempts" => 3},
             "failure" => %{"message" => "overloaded", "retryable" => true}
           } = retry

    assert [
             %{
               "status" => "completed",
               "title" => "Context compacted",
               "summary" => "The user asked for a flaky request.",
               "beforeTokenCount" => 150_000,
               "afterTokenCount" => 20_000
             }
           ] = items(context, "compaction")

    context
  end

  # --- context meter ---

  step "Pi reports its context usage while answering", context do
    usage = %{"input" => 1000, "output" => 200, "cacheRead" => 300, "totalTokens" => 1500}

    turns = [
      %{
        "match" => "how much context",
        "steps" => [%{"text" => "Thinking it over.", "usage" => usage}, %{"waitAbort" => true}]
      }
    ]

    context |> with_turns(turns) |> FakeAcp.thread() |> FakeAcp.send_message("how much context")
  end

  # The provider turn's usage (what the meter reads) moves while the turn still runs.
  step "the context meter shows Pi's reported usage", context do
    thread_id = World.thread_id(context, context.thread)

    usage =
      World.await_stream(thread_id, fn state ->
        running = Enum.any?(StreamState.list(state, "run"), &(&1["status"] == "running"))

        Enum.find_value(StreamState.list(state, "provider-turn"), fn turn ->
          if running and turn["tokenUsage"], do: turn["tokenUsage"]
        end)
      end)

    assert %{
             "usedTokens" => 1500,
             "maxTokens" => 200_000,
             "inputTokens" => 1000,
             "cachedInputTokens" => 300,
             "outputTokens" => 200
           } = usage

    {:ok, _} = HalC2.Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})
    FakeAcp.await_run(context, "interrupted")
    context
  end

  # --- delegation ---

  step "Pi delegates a task", context do
    HalC2.Test.Node.ensure(HalC2.Mcp)

    turns = [
      %{
        "match" => "delegate the release notes",
        "steps" => [
          %{
            "mcp" => %{
              "name" => "delegate_task",
              "arguments" => %{
                "task" => "Write the release notes",
                "mode" => "wait",
                "timeoutMs" => 20_000
              }
            }
          },
          %{"text" => "Delegated."}
        ]
      }
    ]

    context
    |> with_turns(turns)
    |> FakeAcp.thread()
    |> turn("delegate the release notes")
  end

  step "the task appears as a child thread in the subagent view", context do
    thread_id = World.thread_id(context, context.thread)
    state = state(context)

    assert [%{"mcp" => %{"result" => result}}] =
             for(%{"mcp" => _} = l <- FakeAcp.log(context), do: l)

    refute result["isError"]

    assert [%{"status" => "completed", "childThreadId" => child_id, "result" => answer} = task] =
             StreamState.list(state, "subagent")

    assert answer == "Reply to Write the release notes after []"

    assert [%{"childThreadId" => ^child_id, "nodeId" => node_id}] =
             StreamState.list(state, "turn-item") |> Enum.filter(&(&1["type"] == "subagent"))

    assert node_id == task["id"]
    child = HalC2.Streams.Server.state(HalC2.Streams.ensure(child_id))

    assert %{"lineage" => %{"parentThreadId" => ^thread_id, "relationshipToParent" => "subagent"}} =
             StreamState.get(child, "thread")[child_id]

    assert [{"user", "Write the release notes"}, {"assistant", ^answer}] =
             child
             |> StreamState.list("message")
             |> Enum.sort_by(& &1["createdAt"])
             |> Enum.map(&{&1["role"], &1["text"]})

    context
  end

  # --- process exit ---

  step "a Pi turn is running", context do
    context =
      context
      |> install()
      |> FakeAcp.thread()
      |> FakeAcp.send_message("please do a long task")

    FakeAcp.await_run(context, "running")

    World.await_stream(World.thread_id(context, context.thread), fn state ->
      Enum.any?(StreamState.list(state, "turn-item"), &(&1["type"] == "assistant_message"))
    end)

    context
  end

  # Pi's own pid, from the fake's start log (never found by name).
  step "the Pi process exits unexpectedly", context do
    assert [%{"pid" => pid}] = thread_starts(context)
    {_, 0} = System.cmd("kill", ["-9", Integer.to_string(pid)])
    context
  end

  step "the turn fails saying Pi exited unexpectedly", context do
    state = FakeAcp.await_run(context, "failed")

    assert Enum.any?(
             StreamState.list(state, "provider-session"),
             &(&1["lastError"] == "Pi exited unexpectedly")
           )

    context
  end
end
