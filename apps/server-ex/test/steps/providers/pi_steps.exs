defmodule HalC2.Steps.Providers.Pi do
  @moduledoc """
  Steps for `features/providers/pi.feature`. The MC runs Pi in its own RPC mode
  (`HalC2.Pi`, `HalC2.Pi.ThreadRuntime`); the scripted fake Pi (`fake_pi_rpc.py`, through
  `HalC2.Test.FakeAcp.install_pi/3`) is the user's `pi`, sessions and all.
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias HalC2.StreamState
  alias HalC2.Test.FakeAcp
  alias HalC2.Test.Mc.World

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

  # A turn starts a Pi process, which a loaded machine can take seconds over; only a
  # failing turn waits this long.
  @turn_ms 20_000

  # Sends `text` and waits for its (new) run to finish as `status`.
  defp turn(context, text, status \\ "completed", title \\ nil) do
    before = for run <- StreamState.list(state(context, title), "run"), do: run["id"]
    context = FakeAcp.send_message(context, text, title)

    run =
      World.await_stream(
        World.thread_id(context, title || context.thread),
        fn state ->
          Enum.find(
            StreamState.list(state, "run"),
            &(&1["id"] not in before and &1["status"] in ~w(completed failed interrupted))
          )
        end,
        @turn_ms
      )

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

  step "the pi command is not installed on the MC", context do
    FakeAcp.services()
    HalC2.Acp.forget("pi")
    missing = Path.join(HalC2.Test.Mc.tmp_dir(context.mc, "no-pi"), "pi")
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

  # The path lives in the scenario's machine (`HalC2.Test.Mc.Host`).
  step "Pi's binary path is set to {string}", %{args: [path]} = context do
    install(context, %{}, path: HalC2.Test.Mc.Host.path(context, path))
  end

  step "the user sends a message to Pi", context do
    context |> FakeAcp.thread() |> turn("hello Pi")
  end

  step "the turn runs on the user's own Pi installation", context do
    assert_runs_on(context, FakeAcp.fake(context).bin)
  end

  step "that Pi binary runs the turn", context do
    assert_runs_on(context, HalC2.Test.Mc.Host.path(context, "/opt/pi/bin/pi"))
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

  # The thread runs on Pi's own default model; the MC never picks one for it.
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

    assert [%{"env" => %{"HAL_C2_PI_RUNTIME_MODE" => "approval-required"}}] =
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
    assert first["env"]["HAL_C2_PI_RUNTIME_MODE"] == "approval-required"
    assert second["env"]["HAL_C2_PI_RUNTIME_MODE"] == "full-access"
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

  # Pi asked twice; the MC answered the second itself.
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

    assert [
             %{
               "id" => question,
               "header" => "Question",
               "question" => "Pick a color",
               "options" => options
             }
           ] =
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

  # Turn two is stopped while Pi works; the user's message is already in Pi's session.
  step "a Pi thread with a stopped turn followed by a finished turn", context do
    context = context |> install() |> FakeAcp.thread() |> turn("first")
    context = FakeAcp.send_message(context, "a long task")
    await_answers(context, 2)

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, context.thread)
      })

    FakeAcp.await_run(context, "interrupted")
    context = turn(context, "third")
    Map.merge(context, %{current_thread: context.thread, pi_session: session_file(context)})
  end

  # Turn two is stopped, and the session's entries cannot be read as it ends: the
  # thread never learns where Pi put its message, though Pi kept it.
  step "a Pi thread whose second turn was stopped before Pi reported its place in the session",
       context do
    context = context |> install() |> FakeAcp.thread() |> turn("first")
    context = FakeAcp.send_message(context, "a long task")
    await_answers(context, 2)
    context = FakeAcp.configure(context, &Map.put(&1, "failCommands", ["get_entries"]))

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, context.thread)
      })

    FakeAcp.await_run(context, "interrupted")
    context = FakeAcp.configure(context, &Map.delete(&1, "failCommands"))

    refs =
      state(context)
      |> StreamState.list("provider-turn")
      |> Enum.sort_by(& &1["ordinal"])
      |> Enum.map(&get_in(&1, ["nativeTurnRef", "nativeId"]))

    assert [first, nil] = refs
    assert is_binary(first)
    context
  end

  step "a third turn finished after it", context do
    context = turn(context, "third")
    Map.merge(context, %{current_thread: context.thread, pi_session: session_file(context)})
  end

  step "the user reverts to the end of the third turn", context do
    World.rollback(context, context.thread, 3, %{"restoreFiles" => false})
  end

  step "the user forks from the end of the third turn", context do
    context = World.fork(context, context.thread, 3, "past the stop")
    Map.put(context, :pi_went_past, "past the stop")
  end

  step "Pi continues from the third turn", context do
    assert {:ok, _} = context.reply
    title = context[:pi_went_past]
    context = turn(context, "where are we", "completed", title)

    assert List.last(replies(context, title)) ==
             "Reply to where are we after [first | a long task | third]"

    context
  end

  step "the user reverts to before the stopped turn", context do
    World.rollback(context, context.thread, 1, %{"restoreFiles" => false})
  end

  # Pi forked its session before the stopped turn's user message.
  step "Pi continues from the turn before it", context do
    assert {:ok, _} = context.reply
    assert [%{"entryId" => entry}] = FakeAcp.received_type(context, "fork")
    assert entry == user_entry(context.pi_session, "a long task")
    assert session_file(context) != context.pi_session
    context
  end

  step "the stopped turn is not used as Pi's history", context do
    context = turn(context, "where are we")
    assert List.last(replies(context)) == "Reply to where are we after [first]"

    history =
      for %{"message" => %{"role" => "user", "content" => text}} <-
            JSON.decode!(File.read!(session_file(context)))["entries"],
          do: text

    assert history == ["first", "where are we"]
    context
  end

  # Pi has started its answer number `count` in the scenario's thread (its text may
  # still be held back for streaming).
  defp await_answers(context, count) do
    World.await_stream(World.thread_id(context, context.thread), fn state ->
      length(
        Enum.filter(StreamState.list(state, "turn-item"), &(&1["type"] == "assistant_message"))
      ) == count
    end)
  end

  step "a Pi thread whose second turn is running", context do
    context = context |> install() |> FakeAcp.thread() |> turn("first")
    context = FakeAcp.send_message(context, "a long task")
    await_answers(context, 2)
    Map.put(context, :pi_session, session_file(context))
  end

  step "the user forks from the first turn", context do
    source = World.thread_id(context, context.thread)
    run = state(context) |> StreamState.list("run") |> Enum.find(&(&1["ordinal"] == 1))
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

    put_in(context, [:threads, "fork"], id)
  end

  step "the new thread continues Pi's conversation through the first turn only", context do
    context = turn(context, "where are we", "completed", "fork")
    assert List.last(replies(context, "fork")) == "Reply to where are we after [first]"
    # The source's running turn goes on in its own session.
    assert session_file(context, "fork") != context.pi_session
    context
  end

  # The first turn takes a steer and finishes, so Pi's session holds two user messages
  # for it: the prompt and the steer.
  step "a Pi thread whose first turn took the steer {string}", %{args: [text]} = context do
    turns = [
      %{
        "match" => "a steered task",
        "steps" => [%{"text" => "Working on it."}, %{"waitAbort" => true}]
      }
    ]

    context =
      context
      |> with_turns(turns)
      |> FakeAcp.thread()
      |> FakeAcp.send_message("please do a steered task")

    await_answers(context, 1)
    {:ok, _} = steer(context, text)
    FakeAcp.await_run(context, "completed")
    Map.merge(context, %{pi_session: session_file(context), steered: text})
  end

  step ~r/^the Pi thread's next turn (?<next>has not started|is running)$/,
       %{args: [next]} = context do
    if next == "is running" do
      answered = length(items(context, "assistant_message"))
      context = FakeAcp.send_message(context, "a long task")
      await_answers(context, answered + 1)
      context
    else
      context
    end
  end

  step "the new thread continues Pi's conversation through the steer", context do
    context = turn(context, "where are we", "completed", "fork")

    assert List.last(replies(context, "fork")) ==
             "Reply to where are we after [please do a steered task | #{context.steered}]"

    context
  end

  step "the user forks from the second turn into a new worktree", context do
    root = World.project(context).root
    worktree = Path.join(HalC2.Test.Mc.tmp_dir(context.mc, "worktrees"), "pi-fork")
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
    HalC2.Test.Mc.ensure(HalC2.Mcp)

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

    # The fake echoes its prompt: the MC's worker preamble, then the task.
    assert "Reply to You are a HAL-C2 worker " <> _ = answer
    assert String.ends_with?(answer, "\nTask:\nWrite the release notes after []")

    assert [%{"childThreadId" => ^child_id, "nodeId" => node_id}] =
             StreamState.list(state, "turn-item") |> Enum.filter(&(&1["type"] == "subagent"))

    assert node_id == task["id"]
    child = HalC2.Streams.Server.state(HalC2.Streams.ensure(child_id))

    assert %{"lineage" => %{"parentThreadId" => ^thread_id, "relationshipToParent" => "subagent"}} =
             StreamState.get(child, "thread")[child_id]

    assert [{"user", task_text}, {"assistant", ^answer}] =
             child
             |> StreamState.list("message")
             |> Enum.sort_by(& &1["createdAt"])
             |> Enum.map(&{&1["role"], &1["text"]})

    assert String.ends_with?(task_text, "\nTask:\nWrite the release notes")

    context
  end

  # --- steering ---

  # Pi's turn says something, then waits: for a steer to join its work ("is still
  # working"), or until one or two steers reach it only after it settled, as ones sent
  # just as its run ended do ("went idle ...").
  step ~r/^a Pi turn that (?<state>is still working|went idle just before (?:the steer|two steers) landed)$/,
       %{args: [state]} = context do
    wait =
      case state do
        "is still working" -> %{"waitAbort" => true}
        "went idle just before the steer landed" -> %{"settleOnSteer" => 1}
        _two -> %{"settleOnSteer" => 2}
      end

    turns = [
      %{"match" => "a steered task", "steps" => [%{"text" => "Working on it."}, wait]}
    ]

    context =
      context
      |> with_turns(turns)
      |> FakeAcp.thread()
      |> FakeAcp.send_message("please do a steered task")

    World.await_stream(World.thread_id(context, context.thread), fn state ->
      Enum.any?(StreamState.list(state, "turn-item"), &(&1["type"] == "assistant_message"))
    end)

    context
  end

  step "the user steers the thread with {string}", %{args: [text]} = context do
    {:ok, _} = steer(context, text)
    Map.put(context, :steered, text)
  end

  # A working turn on a Pi whose compaction takes far longer than the test:
  # a steered `/compact` is still running when the turn is stopped.
  step "a Pi turn that is still working while Pi compacts slowly", context do
    turns = [
      %{
        "match" => "a steered task",
        "steps" => [%{"text" => "Working on it."}, %{"waitAbort" => true}]
      }
    ]

    context =
      context
      |> install(%{"turns" => turns ++ FakeAcp.pi_turns(), "compactDelaySec" => 30})
      |> FakeAcp.thread()
      |> FakeAcp.send_message("please do a steered task")

    World.await_stream(World.thread_id(context, context.thread), fn state ->
      Enum.any?(StreamState.list(state, "turn-item"), &(&1["type"] == "assistant_message"))
    end)

    context
  end

  step "the user steers the thread with {string} and stops the turn before Pi finishes compacting",
       %{args: [text]} = context do
    steered = Task.async(fn -> steer(context, text) end)
    await_compact_sent(context)

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "threadId" => World.thread_id(context, context.thread)
      })

    Map.put(context, :compact_steer, steered)
  end

  # The fake received Pi's `compact`, so the runtime's compaction task is out.
  defp await_compact_sent(context, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 10_000

    cond do
      FakeAcp.received_type(context, "compact") != [] ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("Pi was never sent the steered compact")

      true ->
        receive do
        after
          20 -> await_compact_sent(context, deadline)
        end
    end
  end

  step "the steer is answered and the turn is stopped", context do
    FakeAcp.await_run(context, "interrupted")

    assert {:ok, {:ok, _}} =
             Task.yield(context.compact_steer, 5_000) ||
               Task.shutdown(context.compact_steer, :brutal_kill)

    context
  end

  step "the next Pi turn finishes", context do
    turn(context, "hello after the stop")
  end

  # As the slow compaction above, but Pi finishes it a couple of seconds
  # after it starts: within whatever turn runs next.
  step "a Pi turn that is still working while Pi compacts for a few seconds", context do
    turns = [
      %{
        "match" => "a steered task",
        "steps" => [%{"text" => "Working on it."}, %{"waitAbort" => true}]
      }
    ]

    context =
      context
      |> install(%{"turns" => turns ++ FakeAcp.pi_turns(), "compactDelaySec" => 2})
      |> FakeAcp.thread()
      |> FakeAcp.send_message("please do a steered task")

    World.await_stream(World.thread_id(context, context.thread), fn state ->
      Enum.any?(StreamState.list(state, "turn-item"), &(&1["type"] == "assistant_message"))
    end)

    context
  end

  # Pi's `abort` does not stop a compaction: the stopped steer compaction
  # finishes while the next turn runs. The fake scripts its late events into
  # that turn; once Pi's answer has landed (and with it the abandonment),
  # steering `/compact` again compacts for real.
  step "the next Pi turn runs while Pi finishes the stopped compaction and then compacts again",
       context do
    ended = %{
      "event" => %{
        "type" => "compaction_end",
        "aborted" => false,
        "result" => %{
          "summary" => "The stopped compaction.",
          "tokensBefore" => 1000,
          "estimatedTokensAfter" => 200
        }
      }
    }

    start = %{"event" => %{"type" => "compaction_start", "reason" => "manual"}}
    steps = [%{"text" => "Working again."}, start, ended, %{"waitAbort" => true}]

    context =
      FakeAcp.configure(context, fn cfg ->
        Map.update(cfg, "turns", [], &[%{"match" => "after the stop", "steps" => steps} | &1])
      end)

    context = FakeAcp.send_message(context, "hello after the stop")

    World.await_stream(World.thread_id(context, context.thread), fn state ->
      Enum.any?(StreamState.list(state, "turn-item"), &(&1["type"] == "assistant_message"))
    end)

    await_compact_answered(context)
    context = FakeAcp.configure(context, &Map.delete(&1, "compactDelaySec"))
    {:ok, _} = steer(context, "/compact")

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "threadId" => World.thread_id(context, context.thread)
      })

    FakeAcp.await_run(context, "interrupted")
    context
  end

  # Pi starts a prompt sent while it still finishes the stopped compaction
  # only once that compaction is over, and shows nothing for it until then
  # (`isStreaming` stays false): the watchdog, checking every 200 ms through
  # the couple of seconds left, must not read that as an idle Pi.
  step "the user sends a message Pi starts only once the stopped compaction ends", context do
    context = quick_watchdog(context)

    behind = %{
      "match" => "after the stop",
      "afterCompaction" => true,
      "steps" => [%{"text" => "Done after the compaction."}]
    }

    context
    |> FakeAcp.configure(fn cfg -> Map.update(cfg, "turns", [behind], &[behind | &1]) end)
    |> turn("hello after the stop")
  end

  # Settled as idle, the turn would have completed with nothing in it, and
  # Pi's answer would have found no turn to land in.
  step "that turn waits for the compaction and runs to its end", context do
    assert Enum.any?(FakeAcp.log(context), &Map.has_key?(&1, "compact_answered"))

    assert "Done after the compaction." in for(
             item <- items(context, "assistant_message"),
             do: item["text"]
           )

    assert items(context, "compaction") == []
    context
  end

  step "the next turn shows only its own compaction", context do
    assert [%{"title" => "Context compacted", "summary" => "Compacted."}] =
             items(context, "compaction")

    context
  end

  # As the slow compaction above, but Pi's delayed answer is a failure and
  # sends no compaction events at all, `compaction_end` included.
  step "a Pi turn that is still working while Pi's compaction fails slowly without an end event",
       context do
    turns = [
      %{
        "match" => "a steered task",
        "steps" => [%{"text" => "Working on it."}, %{"waitAbort" => true}]
      }
    ]

    config = %{
      "turns" => turns ++ FakeAcp.pi_turns(),
      "compactDelaySec" => 1,
      "compactError" => "nothing to compact"
    }

    context =
      context
      |> install(config)
      |> FakeAcp.thread()
      |> FakeAcp.send_message("please do a steered task")

    World.await_stream(World.thread_id(context, context.thread), fn state ->
      Enum.any?(StreamState.list(state, "turn-item"), &(&1["type"] == "assistant_message"))
    end)

    context
  end

  # Pi answered the abandoned compaction (the fake logs it once the answer
  # is on the wire); with the failure behind it, a fresh `/compact` succeeds.
  step "Pi's failed answer has landed and the user sends {string}",
       %{args: [text]} = context do
    await_compact_answered(context)

    context =
      FakeAcp.configure(context, fn cfg ->
        cfg |> Map.delete("compactError") |> Map.delete("compactDelaySec")
      end)

    turn(context, text)
  end

  defp await_compact_answered(context, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 10_000

    cond do
      Enum.any?(FakeAcp.log(context), &Map.has_key?(&1, "compact_answered")) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("Pi never answered the abandoned compact")

      true ->
        receive do
        after
          20 -> await_compact_answered(context, deadline)
        end
    end
  end

  defp steer(context, text) do
    HalC2.Orchestration.dispatch(%{
      "type" => "message.dispatch",
      "commandId" => "cmd-#{System.unique_integer([:positive])}",
      "threadId" => World.thread_id(context, context.thread),
      "messageId" => "msg-#{System.unique_integer([:positive])}",
      "text" => text,
      "attachments" => [],
      "deliveryIntent" => "steer"
    })
  end

  # The fake declines a steer that says "decline" once it reaches Pi after the run
  # settled; the turn settles only once both have reached it, so both are out at once.
  step "the user steers the thread with two messages at once that Pi declines", context do
    texts = ["decline the first", "decline the second"]

    for reply <- texts |> Enum.map(&Task.async(fn -> steer(context, &1) end)) |> Task.await_many(),
        do: assert({:ok, _} = reply)

    Map.put(context, :steered, texts)
  end

  # Each message runs as a message of its own once the steered turn ended: completed
  # when Pi declined it, failed when Pi exited.
  step ~r/^(?:each|the) message is sent on its own after the turn$/, context do
    state = FakeAcp.await_runs(context, 1 + length(List.wrap(context.steered)))
    [turn | own] = state |> StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])
    assert turn["status"] == Map.get(context, :ended, "completed")
    messages = Map.new(StreamState.list(state, "message"), &{&1["id"], &1})

    assert Enum.sort(for run <- own, do: messages[run["userMessageId"]]["text"]) ==
             Enum.sort(List.wrap(context.steered))

    assert Enum.all?(own, &(&1["status"] == "completed"))
    context
  end

  # The fake never answers a steer that says "ignore" once its run settled; the runtime
  # gives it a short answer budget here.
  step "the user steers the thread with a message Pi never answers", context do
    Application.put_env(:hal_c2, :pi_steer_answer_ms, 200)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :pi_steer_answer_ms) end)
    {:ok, _} = steer(context, "ignore this one")
    Map.put(context, :steered, "ignore this one")
  end

  step "the turn ends with the message in it", context do
    state = FakeAcp.await_runs(context, 1)
    assert [%{"status" => "completed", "id" => run}] = StreamState.list(state, "run")

    assert Enum.any?(
             StreamState.list(state, "message"),
             &(&1["role"] == "user" and &1["text"] == context.steered and &1["runId"] == run)
           )

    context
  end

  # The fake exits on a steer that says "vanish", before answering it.
  step "the user steers the thread with a message Pi exits on", context do
    {:ok, _} = steer(context, "vanish now")
    Map.merge(context, %{steered: "vanish now", ended: "failed"})
  end

  # The fake takes a steer that says "hold" in without answering it while the turn
  # waits, so it is still out when the abort reaches it and Pi settles the turn.
  step "the user steers the thread with a message Pi holds and stops the turn", context do
    steered = Task.async(fn -> steer(context, "hold this thought") end)
    await_steer_sent(context, "hold this thought")

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, context.thread)
      })

    assert {:ok, _} = Task.await(steered)
    Map.put(context, :steered, "hold this thought")
  end

  # The fake declines a steer that says "decline after stop" only once the abort
  # reaches it: the run already settled (the runtime holds the settle for the
  # steer's answer), the user stops the turn, and only then does Pi refuse.
  step "the user steers the thread with a message Pi declines after the turn is stopped",
       context do
    steered = Task.async(fn -> steer(context, "decline after stop this one") end)
    await_steer_sent(context, "decline after stop this one")

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, context.thread)
      })

    assert {:ok, _} = Task.await(steered, 15_000)
    Map.put(context, :steered, "decline after stop this one")
  end

  step "the stopped turn ends with the message in it and no new turn starts", context do
    state = FakeAcp.await_runs(context, 1)
    assert [%{"status" => "interrupted", "id" => run}] = StreamState.list(state, "run")

    assert Enum.any?(
             StreamState.list(state, "message"),
             &(&1["role"] == "user" and &1["text"] == context.steered and &1["runId"] == run)
           )

    context
  end

  # The fake received the steer prompt with `text`, so the runtime has it out. The
  # fake writes its log from another OS process; there is no message to wait on.
  defp await_steer_sent(context, text, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    sent? =
      Enum.any?(
        FakeAcp.received_type(context, "prompt"),
        &(&1["streamingBehavior"] == "steer" and &1["message"] == text)
      )

    cond do
      sent? ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("Pi was never sent the steer #{inspect(text)}")

      true ->
        receive do
        after
          20 -> await_steer_sent(context, text, deadline)
        end
    end
  end

  # The fake refuses a steer that says "refuse", as Pi rejects one before accepting it.
  step "the user steers the thread with a message Pi refuses", context do
    reply =
      HalC2.Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, context.thread),
        "messageId" => "msg-#{System.unique_integer([:positive])}",
        "text" => "refuse this one",
        "attachments" => [],
        "deliveryIntent" => "steer"
      })

    Map.put(context, :steer_reply, reply)
  end

  step "the sender hears Pi did not take the message", context do
    assert {:error, message} = context.steer_reply
    assert message =~ "Pi did not take the message into its running turn"
    assert message =~ "Pi cannot take this message now"
    context
  end

  step "the Pi turn runs on without it", context do
    state = World.stream(context, context.thread)
    assert [%{"status" => "running"}] = StreamState.list(state, "run")
    refute Enum.any?(StreamState.list(state, "message"), &(&1["text"] == "refuse this one"))
    context
  end

  # One run, which Pi's answer to the steer ends.
  defp steered_turn(context) do
    state = FakeAcp.await_runs(context, 1)
    assert [%{"status" => "completed"}] = StreamState.list(state, "run")

    assert Enum.any?(
             FakeAcp.received_type(context, "prompt"),
             &(&1["streamingBehavior"] == "steer")
           )

    replies(context)
  end

  step "the message is queued into the running work", context do
    assert "steered: #{context.steered}" in steered_turn(context)
    context
  end

  step "the message starts new work in the same turn", context do
    assert Enum.any?(
             steered_turn(context),
             &String.starts_with?(&1, "Reply to #{context.steered}")
           )

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
             &(&1["lastError"] == "Pi process exited unexpectedly.")
           )

    context
  end

  # --- health and models ---

  step "Pi is turned off in the provider settings", context do
    install(context, %{}, enabled: false)
  end

  # The refresh is under way on a slow Pi; the entry read meanwhile says so.
  step "the MC is still looking for the pi command", context do
    context = install(context, %{"versionDelaySec" => 8})
    pid = spawn(fn -> FakeAcp.probe("pi") end)
    ExUnit.Callbacks.on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    deadline = System.monotonic_time(:millisecond) + 5_000

    await = fn await ->
      cond do
        :persistent_term.get({HalC2.Acp, "pi", :loading}, false) ->
          :ok

        System.monotonic_time(:millisecond) > deadline ->
          flunk("the Pi read never started")

        true ->
          receive do
          after
            10 -> :ok
          end && await.(await)
      end
    end

    await.(await)
    Map.put(context, :providers, [FakeAcp.entry("pi")])
  end

  step "the pi command is not installed", context do
    context = install(context)
    missing = Path.join(HalC2.Test.Mc.tmp_dir(context.mc, "no-pi-here"), "pi")
    FakeAcp.settings(&put_in(&1, ["providers", "pi", "binaryPath"], missing))
    context
  end

  # A path that is there but is no program: a directory where the binary goes.
  step "the pi command is found but cannot be run", context do
    context = install(context)
    dir = HalC2.Test.Mc.tmp_dir(context.mc, "pi-is-a-dir")
    FakeAcp.settings(&put_in(&1, ["providers", "pi", "binaryPath"], dir))
    context
  end

  step "the pi version check does not finish in time", context do
    install(context, %{"versionDelaySec" => 30})
  end

  step "the pi version check exits with an error", context do
    install(context, %{"versionExit" => 2})
  end

  step "pi prints no version", context do
    install(context, %{"version" => ""})
  end

  step "Pi is shown with the message {string}", %{args: [message]} = context do
    assert %{"message" => ^message} = pi(context)
    context
  end

  step "Pi takes 8 seconds to print its version", context do
    install(context, %{"versionDelaySec" => 8})
  end

  step "Pi is not reported as timed out", context do
    assert %{"status" => status} = pi(context)
    assert status in ["ready", "warning"]
    assert [%{"slug" => "default"} | _] = pi(context)["models"]
    context
  end

  step "Pi's launch arguments pin {string} and Pi holds only an Anthropic key",
       %{args: [pinned]} = context do
    context =
      install(context, %{
        "models" => [
          %{"provider" => "anthropic", "id" => "sonnet", "name" => "Sonnet", "reasoning" => false}
        ]
      })

    FakeAcp.settings(&put_in(&1, ["providers", "pi", "launchArgs"], "--model #{pinned}"))
    context
  end

  step "Pi stays ready, with its other models still offered", context do
    assert %{"status" => "ready", "models" => models} = pi(context)
    assert Enum.any?(models, &(&1["slug"] == "anthropic/sonnet"))
    context
  end

  step "Pi's provider details name {string} and say its provider has no credentials",
       %{args: [pinned]} = context do
    assert %{"message" => message} = pi(context)
    assert message =~ pinned
    assert message =~ "has no credentials"
    context
  end

  # Discovery's 30 seconds scaled down 20 times: Pi's extensions take a second.
  step "Pi takes 20 seconds to load its extensions", context do
    Application.put_env(:hal_c2, :pi_discover_ms, 1_500)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :pi_discover_ms) end)

    install(context, %{
      "models" => [
        %{"provider" => "fake", "id" => "base", "name" => "Base", "reasoning" => false},
        %{"provider" => "extension", "id" => "added", "name" => "Added", "reasoning" => false}
      ],
      "commandDelays" => %{"get_available_models" => 1.0}
    })
  end

  step "the models Pi's extensions add are offered", context do
    assert Enum.any?(pi(context)["models"], &(&1["slug"] == "extension/added"))
    context
  end

  step "discovery that takes longer than 30 seconds falls back to {string}",
       %{args: [fallback]} = context do
    # A first discovery, with no earlier list for this Pi to keep.
    :persistent_term.erase({HalC2.Acp, "pi", :pi_last_models})

    FakeAcp.configure(context, &put_in(&1, ["commandDelays"], %{"get_available_models" => 2.0}))
    assert Enum.map(FakeAcp.probe("pi")["models"], & &1["name"]) == [fallback]
    context
  end

  step "Pi discovery of its models and commands fails", context do
    install(context, %{"discoveryError" => true})
  end

  step "Pi is shown with a message that the live session will retry startup", context do
    assert %{"message" => message} = pi(context)
    assert message =~ "could not refresh its models and commands"
    assert message =~ "The live session will retry startup."
    context
  end

  step "Pi listed the models {string} and {string}", %{args: [a, b]} = context do
    models =
      Enum.map([a, b], &%{"provider" => "fake", "id" => &1, "name" => &1, "reasoning" => false})

    context = install(context, %{"models" => models})

    {_providers, context} =
      context
      |> Map.put(:reply, {:ok, %{}})
      |> then(fn ctx -> {FakeAcp.probe("pi"), ctx} end)
      |> then(fn {_entry, ctx} -> FakeAcp.open_config(ctx) end)

    context
  end

  step "Pi's models are discovered again and only {string} is listed",
       %{args: [kept]} = context do
    context =
      FakeAcp.configure(context, fn cfg ->
        put_in(cfg, ["models"], [
          %{"provider" => "fake", "id" => kept, "name" => kept, "reasoning" => false}
        ])
      end)

    FakeAcp.probe("pi")
    {providers, context} = FakeAcp.open_config(context)
    Map.put(context, :providers, providers)
  end

  step "only {string} is offered", %{args: [kept]} = context do
    assert Enum.map(pi(context)["models"], & &1["slug"]) == ["default", "fake/#{kept}"]
    context
  end

  step "a discovery that fails or does not finish keeps both", context do
    both = ["default", "fake/alpha", "fake/beta"]

    # Both offered again, successfully, so the failed discovery has both to keep.
    context =
      FakeAcp.configure(context, fn cfg ->
        put_in(cfg, ["models"], [
          %{"provider" => "fake", "id" => "alpha", "name" => "alpha", "reasoning" => false},
          %{"provider" => "fake", "id" => "beta", "name" => "beta", "reasoning" => false}
        ])
      end)

    assert Enum.map(FakeAcp.probe("pi")["models"], & &1["slug"]) == both
    context = FakeAcp.configure(context, &Map.put(&1, "discoveryError", true))
    assert Enum.map(FakeAcp.probe("pi")["models"], & &1["slug"]) == both
    context
  end

  # --- launch arguments ---

  step "the user sets Pi's launch arguments to {string}", %{args: [args]} = context do
    context = install(context)
    FakeAcp.settings(&put_in(&1, ["providers", "pi", "launchArgs"], args))
    FakeAcp.probe("pi")
    {_, context} = FakeAcp.open_config(context)
    context
  end

  step "the setting is refused with the message {string}", %{args: [message]} = context do
    assert %{"status" => "error", "message" => ^message} = pi(context)
    context
  end

  step "a Pi extension takes the argument {string}", %{args: [_args]} = context do
    install(context)
  end

  step "the setting is accepted", context do
    FakeAcp.settings(&put_in(&1, ["providers", "pi", "launchArgs"], "--plan-depth 3"))
    assert %{"status" => status} = FakeAcp.probe("pi")
    assert status in ["ready", "warning"]
    {providers, context} = FakeAcp.open_config(context)
    refute match?(%{"status" => "error"}, FakeAcp.find(providers, "pi"))
    context
  end

  step "Pi starts with {string}", %{args: [args]} = context do
    context = context |> FakeAcp.thread() |> turn("hello Pi")
    assert [%{"argv" => argv}] = thread_starts(context)
    assert Enum.join(argv, " ") =~ args
    context
  end

  # --- skills and slash commands ---

  defp with_skills(context, names, extra \\ %{}) do
    commands =
      for name <- names,
          do: %{
            "name" => "skill:#{name}",
            "source" => "skill",
            "description" => "The #{name} skill"
          }

    install(context, Map.merge(%{"commands" => commands}, extra))
  end

  step "Pi has the skills {string} and {string}", %{args: [a, b]} = context do
    with_skills(context, [a, b])
  end

  step "Pi has the skill {string}", %{args: [name]} = context do
    with_skills(context, [name])
  end

  # A thread with a conversation to compact: a bare `/compact` as the first message is refused.
  step "a Pi thread that has answered a message", context do
    context |> install() |> FakeAcp.thread() |> turn("first")
  end

  step "the user sends {string} to a Pi thread", %{args: [text]} = context do
    context =
      cond do
        context[:thread] -> context
        context[:provider] -> FakeAcp.thread(context)
        true -> context |> install() |> FakeAcp.thread()
      end

    context = turn(context, text)
    Map.put(context, :sent_text, text)
  end

  defp last_prompt(context) do
    context |> FakeAcp.received_type("prompt") |> List.last() |> Map.get("message")
  end

  # An uploaded file attached to the next message; with `stored?: false` its
  # saved copy never landed, so the turn's attachment has no path.
  defp upload_pdf(name, stored?) do
    body = "%PDF-1.4 notes"

    {:ok, %{"attachmentId" => id, "relativeUrl" => "/api/attachments/upload/" <> token}} =
      HalC2.Attachments.create_upload_url(%{
        "type" => "file",
        "name" => name,
        "mimeType" => "application/pdf",
        "sizeBytes" => byte_size(body)
      })

    if stored?, do: :ok = HalC2.Attachments.store(token, body)

    {%{
       "type" => "file",
       "id" => id,
       "name" => name,
       "mimeType" => "application/pdf",
       "sizeBytes" => byte_size(body)
     }, id}
  end

  defp send_with(context, text, attachment) do
    context = FakeAcp.send_message(context, text, nil, %{"attachments" => [attachment]})
    FakeAcp.await_runs(context, 1)
    context
  end

  step "the user attaches a PDF to a Pi message", context do
    context = context |> install() |> FakeAcp.thread()
    {attachment, _id} = upload_pdf("notes.pdf", true)
    context = send_with(context, "please read this", attachment)
    Map.put(context, :sent_text, "please read this")
  end

  step "Pi receives the line {string} followed by the file's path",
       %{args: [line]} = context do
    assert last_prompt(context) =~ line
    assert [_, path] = Regex.run(~r/\[Attachment saved at ([^\]]+)\]/, last_prompt(context))
    assert File.exists?(path)
    context
  end

  step "the saved copy of {string} attached to a Pi message cannot be found",
       %{args: [name]} = context do
    context = context |> install() |> FakeAcp.thread()
    {attachment, _id} = upload_pdf(name, false)
    # A claimed attachment (not a pending upload, which dispatch refuses
    # outright) whose saved file is gone: its path resolves to nothing.
    Map.put(context, :attachment, Map.put(attachment, "id", "claimed-gone-#{name}"))
  end

  step "the message reaches Pi", context do
    send_with(context, "please read this", context.attachment)
  end

  step "Pi is told {string} is unavailable", %{args: [name]} = context do
    assert last_prompt(context) =~ ~s([Attachment "#{name}" is unavailable])
    context
  end

  step "Pi loads both {string} and {string}", %{args: [a, b]} = context do
    assert last_prompt(context) =~ "/skill:#{a}"
    assert last_prompt(context) =~ "/skill:#{b}"
    context
  end

  step "Pi receives the user's text as written, with any images it carries", context do
    words =
      context.sent_text
      |> String.replace(~r/\$\S+/, "")
      |> String.split()

    prompt = last_prompt(context)
    assert Enum.all?(words, &(prompt =~ &1))
    context
  end

  step "Pi loads {string} and nothing for {string}", %{args: [skill, other]} = context do
    prompt = last_prompt(context)
    assert prompt =~ "/skill:#{skill}"
    assert prompt =~ other
    refute prompt =~ "/skill:#{String.trim_leading(other, "$")}"
    context
  end

  step "Pi loads {string} once", %{args: [skill]} = context do
    assert last_prompt(context) |> String.split("/skill:#{skill}") |> length() == 2
    context
  end

  step "the user types a slash in a Pi thread", context do
    context = install(context)
    FakeAcp.probe("pi")
    {providers, context} = context |> FakeAcp.thread() |> FakeAcp.open_config()
    commands = FakeAcp.find(providers, "pi")["slashCommands"] || []
    Map.merge(context, %{providers: providers, commands: commands})
  end

  # "\"/x\" is offered" is the shared step in grok_steps.exs, over :commands.

  step "Pi compacts its conversation", context do
    assert [_ | _] = FakeAcp.received_type(context, "compact")
    context
  end

  step "Pi compacts its conversation following {string}", %{args: [text]} = context do
    assert [%{"customInstructions" => ^text}] = FakeAcp.received_type(context, "compact")
    context
  end

  step "the work log shows the compaction", context do
    assert [%{"title" => "Context compacted", "status" => "completed"}] =
             items(context, "compaction")

    context
  end

  step "Pi receives it as an ordinary message", context do
    assert String.starts_with?(last_prompt(context), "/compacted")
    assert FakeAcp.received_type(context, "compact") == []
    context
  end

  # --- approvals ---

  # A question item currently waiting in the thread (the composer card).
  defp await_question(context) do
    [item] =
      World.await_stream(World.thread_id(context, context.thread), fn state ->
        case Enum.filter(
               StreamState.list(state, "turn-item"),
               &(&1["type"] == "user_input_request" and
                   &1["status"] in ["waiting", "pending", "running"])
             ) do
          [] -> nil
          items -> [List.last(items)]
        end
      end)

    item
  end

  defp await_approval(context) do
    request = FakeAcp.await_request(context)

    item =
      World.await_stream(World.thread_id(context, context.thread), fn state ->
        Enum.find(
          StreamState.list(state, "turn-item"),
          &(&1["type"] == "approval_request" and &1["requestId"] == request["id"])
        )
      end)

    {request, item}
  end

  step "Pi asks to run a command and the user declines", context do
    context = FakeAcp.send_message(context, "please run a command")
    request = FakeAcp.await_request(context)
    FakeAcp.respond(context, request["id"], %{"decision" => "decline"})
  end

  step "the command does not run", context do
    FakeAcp.await_run(context, "completed")
    assert for(%{"tool" => _} <- FakeAcp.log(context), do: :ran) == []
    context
  end

  step "Pi is told {string}", %{args: [reason]} = context do
    tools = items(context, "command_execution")
    assert Enum.any?(tools, &String.contains?(&1["output"] || "", reason))
    context
  end

  step "Pi asks to run {string}", %{args: [command]} = context do
    context = FakeAcp.send_message(context, "please run a command")
    Map.merge(context, %{approval_command: command, approval: await_approval(context)})
  end

  step "Pi's approval is titled {string}", %{args: [title]} = context do
    {_request, item} = context.approval
    assert item["title"] == title
    context
  end

  step "it shows the command Pi wants to run", context do
    {_request, item} = context.approval
    assert (item["prompt"] || "") =~ context.approval_command
    context
  end

  step ~r/^Pi asks to use its (?<tool>\w+) tool$/, %{args: [tool]} = context do
    turn = %{
      "match" => "use your tool",
      "steps" => [
        %{"tool" => tool, "args" => tool_args(tool), "output" => "done"},
        %{"text" => "Done."}
      ]
    }

    context =
      FakeAcp.configure(context, fn cfg ->
        put_in(cfg, ["turns"], [turn | FakeAcp.pi_turns()])
      end)

    context
    |> FakeAcp.send_message("please use your tool")
    |> Map.put(:requested_tool, tool)
  end

  defp tool_args("bash"), do: %{"command" => "ls"}
  defp tool_args(t) when t in ["edit", "write"], do: %{"path" => "src/app.ts", "content" => "x"}
  defp tool_args(_t), do: %{"q" => "x"}

  # "the user is asked to approve ..." is shared with opencode_steps.exs.

  # --- extension dialogs ---

  defp dialog_thread(context, step, prompt) do
    turns = [%{"match" => prompt, "steps" => [step, %{"text" => "Done answering."}]}]

    context
    |> with_turns(turns)
    |> FakeAcp.thread()
    |> FakeAcp.send_message(prompt)
  end

  step ~r/^a Pi extension asks the user for (?<kind>a line of text|a longer text edit)$/,
       %{args: [kind]} = context do
    method = if kind == "a line of text", do: "input", else: "editor"

    context =
      dialog_thread(
        context,
        %{"ui" => %{"method" => method, "title" => "Your words"}, "say" => "Got: "},
        "ask me something"
      )

    Map.put(context, :pending_request, FakeAcp.await_request(context))
  end

  step "the user can type an answer or choose {string}", %{args: [empty]} = context do
    [question] = await_question(context)["questions"]
    assert Enum.any?(question["options"], &(&1["label"] == empty and &1["value"] == ""))
    Map.put(context, :question, question)
  end

  step "choosing it sends an empty answer to the extension", context do
    context =
      FakeAcp.respond(context, context.pending_request["id"], %{
        "answers" => %{context.question["id"] => ""}
      })

    FakeAcp.await_run(context, "completed")
    assert [%{"value" => ""}] = for(%{"ui_answer" => a} <- FakeAcp.log(context), do: a)
    context
  end

  step "a Pi extension asks for a line of text titled {string} with a blank placeholder",
       %{args: [title]} = context do
    context =
      dialog_thread(
        context,
        %{
          "ui" => %{"method" => "input", "title" => title, "placeholder" => ""},
          "say" => "Got: "
        },
        "ask me something"
      )

    Map.put(context, :pending_request, FakeAcp.await_request(context))
  end

  step "the user is asked {string}", %{args: [question]} = context do
    [q] = await_question(context)["questions"]
    assert q["question"] == question
    Map.put(context, :question, q)
  end

  step "the turn keeps running until the answer goes back to the extension", context do
    state = World.stream(context, context.thread)
    assert Enum.any?(StreamState.list(state, "run"), &(&1["status"] == "running"))

    context =
      FakeAcp.respond(context, context.pending_request["id"], %{
        "answers" => %{context.question["id"] => "nap"}
      })

    FakeAcp.await_run(context, "completed")
    assert [%{"value" => "nap"}] = for(%{"ui_answer" => a} <- FakeAcp.log(context), do: a)
    context
  end

  # Pi stopped reading before it asked (the fake's `deaf` dialog), so no answer reaches it.
  step "a Pi extension asked the user a question", context do
    ui = %{"method" => "input", "title" => "Your words"}
    context = dialog_thread(context, %{"ui" => ui, "deaf" => true}, "ask me something")
    request = FakeAcp.await_request(context)
    [question] = await_question(context)["questions"]
    Map.merge(context, %{pending_request: request, question: question})
  end

  defp answer_pending(context, value) do
    HalC2.Orchestration.dispatch(%{
      "type" => "runtime-request.respond",
      "commandId" => "cmd-#{System.unique_integer([:positive])}",
      "threadId" => World.thread_id(context, context.thread),
      "requestId" => context.pending_request["id"],
      "answers" => %{context.question["id"] => value}
    })
  end

  step "the user's answer cannot be delivered to Pi", context do
    assert {:error, message} = answer_pending(context, "nap")
    assert message =~ "Pi did not get the answer"
    context
  end

  # Still waiting in the thread, and a second answer is tried rather than refused.
  step "the question stays open for another answer", context do
    item = await_question(context)
    assert item["requestId"] == context.pending_request["id"]
    assert {:error, message} = answer_pending(context, "nap again")
    refute message =~ "No pending"
    context
  end

  @editor_prefill "  def run do\n    :ok\n  end\n\n" <> String.duplicate("# note\n", 400)

  step "a Pi extension asks the user to edit a text that already has content", context do
    ui = %{"method" => "editor", "title" => "Edit it", "prefill" => @editor_prefill}
    context = dialog_thread(context, %{"ui" => ui, "say" => "Got: "}, "ask me something")
    Map.put(context, :pending_request, FakeAcp.await_request(context))
  end

  # Longer than the 2,000 characters quoted in the question: the composer gets it all.
  step "the whole text fills the answer composer, ready to edit", context do
    [question] = await_question(context)["questions"]
    assert String.length(@editor_prefill) > 2_000
    assert question["initialAnswer"] == @editor_prefill
    Map.put(context, :question, question)
  end

  step "the answer goes back to the extension with its spaces and line breaks as typed",
       context do
    typed = "  def run do\n    :edited\n  end\n\n"

    context =
      FakeAcp.respond(context, context.pending_request["id"], %{
        "answers" => %{context.question["id"] => typed}
      })

    FakeAcp.await_run(context, "completed")
    assert [%{"value" => ^typed}] = for(%{"ui_answer" => a} <- FakeAcp.log(context), do: a)
    context
  end

  step ~r/^a Pi extension (?<asks>asks the user to pick from a list|asks the user to edit a text|asks for a line of text with no placeholder) titled "(?<title>[^"]+)" with nothing else to say$/,
       %{args: [asks, title]} = context do
    ui =
      case asks do
        "asks the user to pick from a list" ->
          %{"method" => "select", "title" => title, "options" => ["main", "dev"]}

        "asks the user to edit a text" ->
          %{"method" => "editor", "title" => title}

        _ ->
          %{"method" => "input", "title" => title}
      end

    context = dialog_thread(context, %{"ui" => ui, "say" => "Got: "}, "ask me something")
    Map.put(context, :pending_request, FakeAcp.await_request(context))
  end

  step "the question reads {string} once, under the header {string}",
       %{args: [text, header]} = context do
    [q] = await_question(context)["questions"]
    assert q["question"] == text
    assert q["header"] == header
    context
  end

  step "a Pi extension asks for a line of text titled {string} with the placeholder {string}",
       %{args: [title, placeholder]} = context do
    context =
      dialog_thread(
        context,
        %{
          "ui" => %{"method" => "input", "title" => title, "placeholder" => placeholder},
          "say" => "Got: "
        },
        "ask me something"
      )

    Map.put(context, :pending_request, FakeAcp.await_request(context))
  end

  step "the question's header is {string}", %{args: [header]} = context do
    [q] = await_question(context)["questions"]
    assert q["header"] == header
    context
  end

  step "a Pi extension offers a list whose choices include an empty one", context do
    context =
      dialog_thread(
        context,
        %{
          "ui" => %{"method" => "select", "title" => "Pick one", "options" => ["", "two"]},
          "say" => "Got: "
        },
        "ask me something"
      )

    Map.put(context, :pending_request, FakeAcp.await_request(context))
  end

  step "that choice is offered as {string}", %{args: [label]} = context do
    [q] = await_question(context)["questions"]
    assert Enum.any?(q["options"], &(&1["label"] == label and &1["value"] == ""))
    context
  end

  step "a Pi extension asked the user to pick from a list", context do
    context =
      dialog_thread(
        context,
        %{
          "ui" => %{"method" => "select", "title" => "Pick one", "options" => ["a", "b"]},
          "say" => "Got: "
        },
        "ask me something"
      )

    Map.put(context, :pending_request, FakeAcp.await_request(context))
  end

  step "the user dismisses the request", context do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.user-input.dismiss",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, context.thread),
        "requestId" => context.pending_request["id"]
      })

    context
  end

  step "the extension is told the dialog was cancelled", context do
    FakeAcp.await_run(context, "completed")

    assert [%{"cancelled" => true}] =
             FakeAcp.received_type(context, "extension_ui_response")

    context
  end

  step "a client answers the Pi request {string} that is not open",
       %{args: [request_id]} = context do
    context = context |> install() |> FakeAcp.thread() |> turn("hello Pi")

    reply =
      HalC2.Orchestration.dispatch(%{
        "type" => "runtime-request.respond",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, context.thread),
        "requestId" => request_id,
        "decision" => "accept"
      })

    Map.put(context, :reply, reply)
  end

  step "the answer is refused with {string}", %{args: [message]} = context do
    assert {:error, text} = context.reply
    assert text =~ message
    context
  end

  step "the user allowed a Pi extension's confirmation for the session", context do
    confirm = fn message ->
      %{"ui" => %{"method" => "confirm", "title" => "Continue?", "message" => message}}
    end

    turns = [
      %{
        "match" => "confirm thrice",
        "steps" => [
          confirm.("First thing"),
          confirm.("Second thing"),
          confirm.("First thing"),
          %{"text" => "All confirmed."}
        ]
      }
    ]

    context =
      context
      |> with_turns(turns)
      |> FakeAcp.thread()
      |> FakeAcp.send_message("please confirm thrice")

    request = FakeAcp.await_request(context)

    context
    |> FakeAcp.respond(request["id"], %{"decision" => "acceptForSession"})
    |> Map.put(:request, request)
  end

  step "the extension asks to confirm something with a different title or message", context do
    context
  end

  # "the user is asked again" is the shared step in permission_modes_steps.exs.

  step "the same confirmation asked again is allowed without asking", context do
    second = FakeAcp.await_request(context)
    context = FakeAcp.respond(context, second["id"], %{"decision" => "accept"})
    state = FakeAcp.await_run(context, "completed")
    # The extension asked three times; only two requests were opened for the user.
    assert length(StreamState.list(state, "runtime-request")) == 2

    assert [_, _, _] =
             for(%{"ui_answer" => a} <- FakeAcp.log(context), a["confirmed"] == true, do: a)

    context
  end

  # --- tools in the work log ---

  step ~r/^Pi runs its (?<tool>.+) tool$/, %{args: [tool]} = context do
    {name, args} =
      case tool do
        "bash" -> {"bash", %{"command" => "npm test"}}
        "edit" -> {"edit", %{"path" => "src/app.ts", "content" => "x"}}
        "write" -> {"write", %{"path" => "src/app.ts", "content" => "x"}}
        "edit, without naming a file" -> {"edit", %{"content" => "x"}}
        other -> {other, %{"pattern" => "foo"}}
      end

    turns = [
      %{
        "match" => "run your tool",
        "steps" => [
          %{"tool" => name, "args" => args, "output" => "tool output", "exitCode" => 3},
          %{"text" => "Done."}
        ]
      }
    ]

    context |> with_turns(turns) |> FakeAcp.thread() |> turn("please run your tool")
  end

  step "the thread shows a command with what was run, its output and its exit code", context do
    assert [%{"input" => "npm test", "output" => "tool output", "exitCode" => 3}] =
             items(context, "command_execution")

    context
  end

  step "the thread shows a file change naming the file", context do
    assert [%{"fileName" => "src/app.ts"}] = items(context, "file_change")
    context
  end

  step "the thread shows a plain tool call named after the tool, with what it was given",
       context do
    assert [item] = items(context, "dynamic_tool")
    assert item["toolName"] in ["edit", "grep"]
    assert is_map(item["input"])
    context
  end

  step ~r/^Pi runs (?<shell>a bash command|a PowerShell command) on a Pi version that reports the exit code (?<where>.+)$/,
       %{args: [shell, where]} = context do
    tool = if String.contains?(shell, "PowerShell"), do: "powershell", else: "bash"
    exit_where = if String.contains?(where, "structured"), do: "structured", else: "details"

    turns = [
      %{
        "match" => "shell out",
        "steps" => [
          %{
            "tool" => tool,
            "args" => %{"command" => "false"},
            "output" => "nope",
            "exitCode" => 2,
            "exitWhere" => exit_where,
            "isError" => true
          },
          %{"text" => "Done."}
        ]
      }
    ]

    context |> with_turns(turns) |> FakeAcp.thread() |> turn("please shell out")
  end

  step "the step shows as a command with exit code 2", context do
    assert [%{"exitCode" => 2}] = items(context, "command_execution")
    context
  end

  # --- retries, compactions, failures ---

  defp event_thread(context, steps, prompt \\ "do the thing", await \\ "completed") do
    turns = [%{"match" => prompt, "steps" => steps}]
    context = context |> with_turns(turns) |> FakeAcp.thread()

    # A running turn is one Pi has: a steer sent before it is not steering it.
    if await == :running do
      context = FakeAcp.send_message(context, prompt)
      FakeAcp.await_run(context, "running")
      context
    else
      turn(context, prompt, await)
    end
  end

  defp last_error(context, title \\ nil) do
    context
    |> state(title)
    |> StreamState.list("provider-session")
    |> Enum.find_value(& &1["lastError"])
  end

  step ~r/^Pi's compaction of the conversation (?<ends>is still running|finishes|fails|is stopped by the user)$/,
       %{args: [ends]} = context do
    case ends do
      "is still running" ->
        event_thread(
          context,
          [
            %{"event" => %{"type" => "compaction_start", "reason" => "threshold"}},
            %{"waitAbort" => true}
          ],
          "compact please",
          :running
        )

      "finishes" ->
        event_thread(
          context,
          [
            %{"event" => %{"type" => "compaction_start", "reason" => "threshold"}},
            %{
              "event" => %{
                "type" => "compaction_end",
                "aborted" => false,
                "result" => %{
                  "summary" => "Earlier work, in brief.",
                  "tokensBefore" => 9000,
                  "estimatedTokensAfter" => 900
                }
              }
            },
            %{"text" => "After."}
          ],
          "compact please"
        )

      "fails" ->
        event_thread(
          context,
          [
            %{"event" => %{"type" => "compaction_start", "reason" => "threshold"}},
            %{
              "event" => %{
                "type" => "compaction_end",
                "aborted" => false,
                "result" => nil,
                "errorMessage" => "summary model unavailable"
              }
            },
            %{"text" => "After."}
          ],
          "compact please"
        )

      "is stopped by the user" ->
        event_thread(
          context,
          [
            %{"event" => %{"type" => "compaction_start", "reason" => "threshold"}},
            %{"event" => %{"type" => "compaction_end", "aborted" => true, "result" => nil}},
            %{"text" => "After."}
          ],
          "compact please"
        )
    end
  end

  step "the work log entry reads {string}", %{args: [title]} = context do
    context =
      if title == "Compacting context..." do
        [item] =
          World.await_stream(World.thread_id(context, context.thread), fn state ->
            case Enum.filter(StreamState.list(state, "turn-item"), &(&1["type"] == "compaction")) do
              [] -> nil
              items -> items
            end
          end)

        assert item["title"] == title
        Map.put(context, :compaction_item, item)
      else
        assert [%{"title" => ^title} = item] = items(context, "compaction")
        Map.put(context, :compaction_item, item)
      end

    context
  end

  step "it is shown as running", context do
    [item] = items(context, "compaction")
    assert item["status"] == "running"

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, context.thread)
      })

    FakeAcp.await_run(context, "interrupted")
    context
  end

  step "it carries Pi's summary and the token count before compaction", context do
    assert [%{"summary" => "Earlier work, in brief.", "beforeTokenCount" => 9000}] =
             items(context, "compaction")

    context
  end

  step "it carries Pi's reason, or {string}", %{args: [_default]} = context do
    assert [%{"summary" => "summary model unavailable", "status" => "failed"}] =
             items(context, "compaction")

    context
  end

  step "it is shown as stopped, not failed", context do
    assert [%{"status" => status}] = items(context, "compaction")
    assert status in ["cancelled", "interrupted"]
    context
  end

  step ~r/^Pi's request to the model fails and (?<outcome>Pi waits to try again|Pi gives no reason for it|every attempt fails)$/,
       %{args: [outcome]} = context do
    case outcome do
      "Pi waits to try again" ->
        event_thread(
          context,
          [
            %{
              "event" => %{
                "type" => "auto_retry_start",
                "attempt" => 2,
                "maxAttempts" => 4,
                "delayMs" => 250,
                "errorMessage" => "busy"
              }
            },
            %{"waitAbort" => true}
          ],
          "retry please",
          :running
        )

      "Pi gives no reason for it" ->
        event_thread(
          context,
          [
            %{
              "event" => %{
                "type" => "auto_retry_start",
                "attempt" => 1,
                "maxAttempts" => 2,
                "delayMs" => 10
              }
            },
            %{"event" => %{"type" => "auto_retry_end", "success" => true, "attempt" => 1}},
            %{"text" => "Recovered."}
          ],
          "retry please"
        )

      "every attempt fails" ->
        event_thread(
          context,
          [
            %{
              "event" => %{
                "type" => "auto_retry_start",
                "attempt" => 1,
                "maxAttempts" => 1,
                "delayMs" => 10,
                "errorMessage" => "busy"
              }
            },
            %{"event" => %{"type" => "auto_retry_end", "success" => false, "attempt" => 1}}
          ],
          "retry please",
          "failed"
        )
    end
  end

  step "the work log shows the attempt number, the most attempts allowed and the wait", context do
    [item] =
      World.await_stream(World.thread_id(context, context.thread), fn state ->
        case Enum.filter(StreamState.list(state, "turn-item"), &(&1["type"] == "error")) do
          [] -> nil
          items -> items
        end
      end)

    assert %{"retry" => %{"attempt" => 2, "maxAttempts" => 4, "retryDelayMs" => 250}} = item

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, context.thread)
      })

    FakeAcp.await_run(context, "interrupted")
    context
  end

  step "the work log shows \"Pi provider request failed.\"", context do
    assert [%{"failure" => %{"message" => "Pi provider request failed."}}] =
             items(context, "error")

    context
  end

  step "the work log shows the turn failing with Pi's last error, or \"Pi auto-retry failed.\"",
       context do
    assert last_error(context) == "Pi auto-retry failed."
    context
  end

  # A hanging turn on the scenario's thread, with Pi's own pid in context.
  defp hanging_turn(context) do
    turns = [%{"match" => "hang on", "steps" => [%{"text" => "Working."}, %{"hang" => true}]}]

    context =
      context |> with_turns(turns) |> FakeAcp.thread() |> FakeAcp.send_message("please hang on")

    await_answers(context, 1)
    assert [%{"pid" => pid}] = thread_starts(context)
    Map.put(context, :pi_pid, pid)
  end

  defp tell(context, failed_title \\ nil) do
    if failed_title, do: FakeAcp.await_run(context, "failed", failed_title)
    Map.merge(context, %{told: last_error(context), reply: {:error, last_error(context)}})
  end

  step "Pi reports a model error without giving a reason", context do
    context =
      event_thread(
        context,
        [
          %{
            "event" => %{
              "type" => "message_end",
              "message" => %{"role" => "assistant", "stopReason" => "error"}
            }
          }
        ],
        "fail quietly",
        "failed"
      )

    tell(context)
  end

  step "Pi rejects the user's message without giving a reason", context do
    context =
      context
      |> install(%{"promptError" => ""})
      |> FakeAcp.thread()
      |> turn("hello Pi", "failed")

    tell(context)
  end

  step("a Pi thread is starting", context, do: context)

  step "Pi exits with code 2 before answering", context do
    context
    |> install(%{"exitCommands" => %{"get_state" => 2}})
    |> FakeAcp.thread()
    |> turn("hello Pi", "failed")
    |> tell()
  end

  step "Pi refuses a request with an explanation of 5,000 characters", context do
    explanation = String.duplicate("é", 4_999) <> "!"

    context
    |> install(%{"promptError" => explanation})
    |> FakeAcp.thread()
    |> turn("hello Pi", "failed")
    |> tell()
    |> Map.put(:explanation, explanation)
  end

  step "the failure the user sees carries its first 200 characters followed by an ellipsis",
       context do
    assert context.told == String.slice(context.explanation, 0, 200) <> "…"
    context
  end

  step "Pi cannot compact when asked by a steer without giving a reason", context do
    context =
      event_thread(
        context,
        [%{"text" => "Working."}, %{"waitAbort" => true}],
        "a long thing",
        :running
      )

    context = FakeAcp.configure(context, &Map.put(&1, "compactError", ""))
    reply = steer(context, "/compact")

    text =
      case reply do
        {:error, t} -> t
        other -> inspect(other)
      end

    Map.merge(context, %{reply: reply, told: text})
  end

  step "Pi is stopped while a turn runs without giving a reason", context do
    context = hanging_turn(context)

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, context.thread)
      })

    {_, 0} = System.cmd("kill", ["-9", Integer.to_string(context.pi_pid)])
    tell(context, context.thread)
  end

  step "Pi exits while a turn runs without giving a reason", context do
    context = hanging_turn(context)
    {_, 0} = System.cmd("kill", ["-9", Integer.to_string(context.pi_pid)])
    tell(context, context.thread)
  end

  step "the model Pi uses answers that it is at capacity due to high demand", context do
    event_thread(
      context,
      [
        %{
          "event" => %{
            "type" => "message_end",
            "message" => %{
              "role" => "assistant",
              "stopReason" => "error",
              "errorMessage" => "The model is currently at capacity due to high demand."
            }
          }
        }
      ],
      "busy model",
      "failed"
    )
  end

  step "the thread's error says {string}", %{args: [message]} = context do
    assert last_error(context) == message
    context
  end

  step "the model refused a Pi request because the conversation was too long", context do
    Map.put(context, :overflow, true)
  end

  step "Pi compacts the conversation and says it will try again", context do
    overflow = fn will_retry, prompt ->
      %{
        "match" => prompt,
        "steps" => [
          %{
            "event" => %{
              "type" => "message_end",
              "message" => %{
                "role" => "assistant",
                "stopReason" => "error",
                "errorMessage" => "context too long"
              }
            }
          },
          %{"event" => %{"type" => "compaction_start", "reason" => "overflow"}},
          %{
            "event" => %{
              "type" => "compaction_end",
              "aborted" => false,
              "willRetry" => will_retry,
              "result" => %{"summary" => "Shorter now.", "tokensBefore" => 100}
            }
          },
          %{"text" => "Recovered."}
        ]
      }
    end

    context =
      with_turns(context, [overflow.(true, "too long a chat"), overflow.(false, "overflow again")])

    context = context |> FakeAcp.thread() |> FakeAcp.send_message("a too long a chat")
    FakeAcp.await_run(context, "completed")
    context
  end

  step "the turn is not reported as failed", context do
    state = state(context)
    runs = StreamState.list(state, "run")
    refute Enum.any?(runs, &(&1["status"] == "failed"))
    context
  end

  step "a compaction that will not try again leaves an earlier failure in place", context do
    context = turn(context, "overflow again please", "failed")
    assert last_error(context) == "context too long"
    context
  end

  # --- extension errors and notices ---

  step "the Pi extension at {string} throws during a turn", %{args: [path]} = context do
    event = %{
      "type" => "extension_error",
      "extensionPath" => path,
      "event" => "tool_result",
      "error" => "it broke"
    }

    event_thread(context, [%{"event" => event}, %{"text" => "Still done."}], "extension work")
  end

  step "the turn shows an error titled {string}", %{args: [title]} = context do
    assert [%{"title" => ^title, "status" => "failed"}] = items(context, "error")
    context
  end

  step "the Pi extension {string} fails while a tool runs", %{args: [name]} = context do
    turns = [
      %{
        "match" => "linted work",
        "steps" => [
          %{"tool" => "bash", "args" => %{"command" => "make lint"}, "output" => "ok"},
          %{
            "event" => %{
              "type" => "extension_error",
              "extensionPath" => "/home/user/.pi/agent/extensions/#{name}.ts",
              "event" => "tool_result",
              "error" => "lint exploded"
            }
          },
          %{"text" => "Done."}
        ]
      }
    ]

    context
    |> with_turns(turns)
    |> FakeAcp.thread()
    |> FakeAcp.send_message("please do linted work")
  end

  step "the turn continues", context do
    FakeAcp.await_run(context, "completed")
    context
  end

  step "the work log shows a failed entry titled {string}", %{args: [title]} = context do
    assert [%{"title" => ^title, "status" => "failed"}] = items(context, "error")
    context
  end

  step "it says during which step the extension failed and why", context do
    assert [%{"failure" => %{"message" => message}}] = items(context, "error")
    assert message =~ "during tool_result"
    assert message =~ "lint exploded"
    context
  end

  step "a Pi extension failed while no turn was running", context do
    event = %{
      "type" => "extension_error",
      "extensionPath" => "/home/user/.pi/agent/extensions/nightly/index.ts",
      "event" => "session_start",
      "error" => "woke up wrong"
    }

    context
    |> install(%{"settledEvents" => [event]})
    |> FakeAcp.thread()
    |> turn("first")
  end

  # "the user sends the next message" is the shared step in claude_steps.exs.

  step "that turn's work log shows the extension's failure", context do
    state = state(context)
    [_, second] = state |> StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])
    errors = Enum.filter(items(context, "error"), &(&1["title"] == "nightly"))
    assert [%{"runId" => run_id}] = errors
    assert run_id == second["id"]
    context
  end

  step "a Pi extension shows the warning {string}", %{args: [warning]} = context do
    event_thread(
      context,
      [
        %{"uiEmit" => %{"method" => "notify", "message" => warning, "notifyType" => "warning"}},
        %{"text" => "Done."}
      ],
      "warn me"
    )
  end

  step "the work log shows {string} as a warning", %{args: [warning]} = context do
    assert [%{"message" => ^warning}] = items(context, "system_notice")
    context
  end

  step "a Pi extension sends the notification {string}", %{args: [text]} = context do
    event_thread(
      context,
      [%{"uiEmit" => %{"method" => "notify", "message" => text}}, %{"text" => "Done."}],
      "notify me"
    )
  end

  step "the thread shows a notice with both lines", context do
    assert [%{"message" => message}] = items(context, "system_notice")
    assert message =~ "Lint finished"
    assert message =~ "3 warnings"
    context
  end

  step "it is not folded into the tool calls", context do
    tool_items =
      context
      |> state()
      |> StreamState.list("turn-item")
      |> Enum.filter(&(&1["type"] in ["dynamic_tool", "command_execution", "file_change"]))

    refute Enum.any?(tool_items, &String.contains?(inspect(&1), "Lint finished"))
    context
  end

  step "a Pi extension sets a widget, the window title or the editor's text", context do
    event_thread(
      context,
      [
        %{"uiEmit" => %{"method" => "setWidget", "widgetId" => "w1", "content" => ["hi"]}},
        %{"uiEmit" => %{"method" => "setTitle", "title" => "Fancy title"}},
        %{"uiEmit" => %{"method" => "setEditorText", "text" => "draft text"}},
        %{"text" => "All done."}
      ],
      "dress the terminal"
    )
  end

  step "nothing is shown in the thread", context do
    shown =
      context
      |> state()
      |> StreamState.list("turn-item")
      |> Enum.map(&inspect/1)
      |> Enum.join(" ")

    refute shown =~ "Fancy title"
    refute shown =~ "draft text"
    context
  end

  # --- notices in two threads ---

  step "Pi threads {string} and {string} each send a notification as the first item of a turn",
       %{args: [one, two]} = context do
    turns =
      for title <- [one, two] do
        %{
          "match" => "notify #{title}",
          "steps" => [
            %{"uiEmit" => %{"method" => "notify", "message" => "Notice for #{title}"}},
            %{"text" => "Done."}
          ]
        }
      end

    context = with_turns(context, turns)

    context =
      Enum.reduce([one, two], context, fn title, context ->
        context = FakeAcp.thread(context, title)
        turn(context, "notify #{title}", "completed", title)
      end)

    Map.put(context, :notice_threads, [one, two])
  end

  step "the user opens each thread", context do
    opened = Map.new(context.notice_threads, &{&1, state(context, &1)})
    Map.put(context, :opened, opened)
  end

  step "{string} shows its own notice", %{args: [title]} = context do
    notices =
      context.opened[title]
      |> StreamState.list("turn-item")
      |> Enum.filter(&(&1["type"] == "system_notice"))

    assert [%{"message" => message}] = notices
    assert message == "Notice for #{title}"
    context
  end

  # --- titles and short-lived Pi processes ---

  # The fake answers a title prompt with the JSON a title writer returns.
  defp title_turns(extra \\ []) do
    [
      %{
        "match" => "User message:",
        "steps" => [%{"text" => ~s({"title":"Login form fix","needsRefinement":false})}]
      }
      | extra
    ]
  end

  # Asks Pi for a thread title the way the MC does, with Pi as the text model.
  defp ask_title(context, model \\ "default") do
    FakeAcp.settings(
      &Map.put(&1, "textGenerationModelSelection", %{"instanceId" => "pi", "model" => model})
    )

    result = HalC2.TextGeneration.thread_title(World.project(context).root, "Fix the login form")
    Map.put(context, :title_result, result)
  end

  step "Pi's launch arguments name an extension and a tool list", context do
    context = install(context, %{"turns" => title_turns() ++ FakeAcp.pi_turns()})

    FakeAcp.settings(
      &put_in(&1, ["providers", "pi", "launchArgs"], "--extension /user/ext.ts --tools read,bash")
    )

    context
  end

  step "Pi writes a thread title", context do
    context = ask_title(context)
    assert {:ok, %{"title" => "Login form fix"}} = context.title_result
    context
  end

  step "Pi runs with every tool and extension turned off", context do
    assert [%{"argv" => argv} | _] =
             context
             |> FakeAcp.starts("pi")
             |> Enum.filter(&("--no-session" in &1["argv"] and "--no-tools" in &1["argv"]))

    assert "--no-extensions" in argv
    refute "/user/ext.ts" in argv
    refute "read,bash" in argv
    context
  end

  step "no Pi session file is left behind", context do
    sessions = Path.join(FakeAcp.fake(context, "pi").dir, "sessions")
    assert File.ls(sessions) in [{:error, :enoent}, {:ok, []}]
    context
  end

  step "the text-generation model is one only a Pi extension provides", context do
    context
    |> install(%{"turns" => title_turns() ++ FakeAcp.pi_turns()})
    |> Map.put(:title_model, "ext/only-model")
  end

  step "Pi is asked for a thread title", context do
    ask_title(context, context[:title_model] || "default")
  end

  step "the failure names that model", context do
    assert {:error, message} = context.title_result
    assert message =~ context.title_model
    Map.put(context, :title_error, message)
  end

  step "says extensions are not loaded when Pi writes titles and commit messages", context do
    assert context.title_error =~
             "Extensions are not loaded when Pi writes titles and commit messages"

    context
  end

  step "Pi ends a title request with no text and the error {string}",
       %{args: [error]} = context do
    ended = %{
      "event" => %{
        "type" => "message_end",
        "message" => %{"role" => "assistant", "stopReason" => "error", "errorMessage" => error}
      }
    }

    install(context, %{
      "turns" => [%{"match" => "User message:", "steps" => [ended]}] ++ FakeAcp.pi_turns()
    })
  end

  step "the failure reads {string}", %{args: [expected]} = context do
    assert {:error, ^expected} = context.title_result
    context
  end

  # The fake has no login to expire; what the MC controls is that its
  # short-lived Pi processes start offline, so they cannot spend a renewal.
  step "the user's Pi login has expired and is renewed with a single-use token", context do
    context
    |> install(%{"turns" => title_turns() ++ FakeAcp.pi_turns()})
    |> FakeAcp.thread()
    |> turn("first")
    |> turn("second")
  end

  step "the MC starts Pi only to check its status, write a title or fork a session", context do
    HalC2.Acp.load()
    context = ask_title(context)
    assert {:ok, _} = context.title_result

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

    context = put_in(context, [:threads, "fork"], id)
    turn(context, "after the fork", "completed", "fork")
  end

  step "that Pi process starts without refreshing its catalog or logins", context do
    short_lived =
      Enum.filter(
        FakeAcp.starts(context, "pi"),
        &("--no-session" in &1["argv"] or "--fork" in &1["argv"])
      )

    # Status, the title and the fork copy each started one.
    assert length(short_lived) >= 3
    assert Enum.all?(short_lived, &("--offline" in &1["argv"]))
    context
  end

  step "the user's next Pi turn still signs in", context do
    context = turn(context, "still here")
    assert [%{"argv" => argv} | _] = thread_starts(context)
    refute "--offline" in argv
    context
  end

  # --- Pi aborting a turn itself ---

  step "Pi aborts a turn itself, for an extension, a compaction or a session replacement",
       context do
    aborted = %{
      "event" => %{
        "type" => "message_end",
        "message" => %{"role" => "assistant", "stopReason" => "aborted"}
      }
    }

    context =
      context
      |> with_turns([
        %{"match" => "abort yourself", "steps" => [%{"text" => "Working."}, aborted]}
      ])
      |> FakeAcp.thread()
      |> FakeAcp.send_message("abort yourself")

    run =
      World.await_stream(World.thread_id(context, context.thread), fn state ->
        Enum.find(
          StreamState.list(state, "run"),
          &(&1["status"] in ~w(completed failed interrupted))
        )
      end)

    Map.put(context, :aborted_run, run)
  end

  step "the turn reads as interrupted, not completed", context do
    assert context.aborted_run["status"] == "interrupted"
    context
  end

  step "the next turn Pi starts reads as its own outcome", context do
    turn(context, "next please")
  end

  # "the turn carries on" is the shared step in claude_steps.exs.

  # --- the Pi process and its channel ---

  step "a Pi extension prints text that is not part of Pi's protocol", context do
    with_turns(context, [
      %{
        "match" => "hello Pi",
        "steps" => [%{"raw" => "extension debug noise"}, %{"text" => "Clean reply."}]
      }
    ])
  end

  step "the stray text is ignored", context do
    refute Enum.join(replies(context), " ") =~ "extension debug noise"
    context
  end

  step "the turn finishes normally", context do
    assert List.last(replies(context)) == "Clean reply."
    context
  end

  step "Pi answers with text that contains the characters U+2028 and U+2029", context do
    text = "alpha\u2028beta\u2029gamma"

    context
    |> with_turns([%{"match" => "separators", "steps" => [%{"text" => text}]}])
    |> FakeAcp.thread()
    |> turn("show separators")
  end

  step "the reply shows the whole text", context do
    assert List.last(replies(context)) == "alpha\u2028beta\u2029gamma"
    context
  end

  step "Pi starts but the session cannot finish setting up", context do
    context = context |> install(%{"failCommands" => ["get_entries"]}) |> FakeAcp.thread()
    turn(context, "hello Pi", "failed")
  end

  step "the Pi process is stopped", context do
    pids = for %{"pid" => pid} <- thread_starts(context), do: pid
    assert [_ | _] = pids

    # The pids the fake itself logged at spawn: each is gone now (no such process).
    deadline = System.monotonic_time(:millisecond) + 5_000

    await = fn await ->
      alive =
        Enum.find(pids, fn pid ->
          match?(
            {_, 0},
            System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
          )
        end)

      cond do
        alive == nil ->
          :ok

        System.monotonic_time(:millisecond) > deadline ->
          flunk("Pi (pid #{alive}) is still running")

        true ->
          receive do
          after
            50 -> :ok
          end && await.(await)
      end
    end

    await.(await)
    context
  end

  # --- oversized messages, idle and silent Pi, dying with requests out ---

  # The watchdog's check interval, shortened so scenarios do not wait on it.
  defp quick_watchdog(context) do
    Application.put_env(:hal_c2, :pi_turn_watchdog_ms, 200)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :pi_turn_watchdog_ms) end)
    context
  end

  # One event whose line alone is over 8 MiB, then a normal reply in the
  # same turn: only the oversized message may be lost.
  step "Pi sends one message larger than 8 MiB", context do
    huge = %{
      "event" => %{
        "type" => "message_update",
        "message" => %{"role" => "assistant"},
        "assistantMessageEvent" => %{
          "type" => "text_delta",
          "delta" => String.duplicate("x", 9_000_000)
        }
      }
    }

    context
    |> with_turns([
      %{"match" => "big please", "steps" => [huge, %{"text" => "After."}]}
    ])
    |> FakeAcp.thread()
    |> turn("big please")
  end

  step "that message is dropped", context do
    assert replies(context) == ["After."]
    context
  end

  step "the session keeps running", context do
    context = turn(context, "hello again")
    assert List.last(replies(context)) =~ "Reply to hello again"
    context
  end

  step "a Pi extension handles {string} without starting agent work",
       %{args: [command]} = context do
    listed = %{"name" => String.trim_leading(command, "/"), "source" => "extension"}

    context
    |> quick_watchdog()
    |> install(%{"handledCommands" => [command], "commands" => [listed]})
  end

  # The session's first command lookup outlasts its deadline; the next one answers.
  step "Pi lists its commands only after the session's first lookup gave up", context do
    Application.put_env(:hal_c2, :pi_skills_ms, 300)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :pi_skills_ms) end)

    FakeAcp.configure(
      context,
      &Map.merge(&1, %{
        "commandDelays" => %{"get_commands" => 1.0},
        "delayOnce" => ["get_commands"]
      })
    )
  end

  # An extension command settles after two idle checks, a message after fifteen.
  step "the turn finishes as a command does, once Pi is briefly idle", context do
    assert Enum.any?(StreamState.list(state(context), "run"), &(&1["status"] == "completed"))

    checks =
      context
      |> FakeAcp.log()
      |> Enum.drop_while(&(get_in(&1, ["recv", "type"]) != "prompt"))
      |> Enum.count(&(get_in(&1, ["recv", "type"]) == "get_state"))

    assert checks < 15
    context
  end

  step "the turn finishes once Pi is idle", context do
    runs = StreamState.list(state(context), "run")
    assert Enum.any?(runs, &(&1["status"] == "completed"))
    context
  end

  step "the Pi turn is not left running", context do
    active = ~w(preparing queued starting running waiting pending)
    runs = StreamState.list(state(context), "run")
    refute Enum.any?(runs, &(&1["status"] in active))
    context
  end

  # Pi reads idle while its extensions' hooks run before its agent starts:
  # with checks every 200 ms, the two idle checks that settle a `/` command
  # come well inside the 1.5 s, the ordinary message's fifteen do not.
  step "Pi's extensions work for a few seconds before Pi's agent starts on {string}",
       %{args: [text]} = context do
    turn = %{"match" => text, "startDelaySec" => 1.5, "steps" => [%{"text" => "Started late."}]}

    context
    |> quick_watchdog()
    |> with_turns([turn])
  end

  # A prompt template expands into an agent prompt, so its hooks run as an
  # ordinary message's do; Pi also lists an extension command, which would
  # settle quickly.
  step "Pi's extensions work for a few seconds before Pi's agent starts on the prompt template {string}",
       %{args: [template]} = context do
    turn = %{
      "match" => template,
      "startDelaySec" => 1.5,
      "steps" => [%{"text" => "Started late."}]
    }

    commands = [
      %{"name" => String.trim_leading(template, "/"), "source" => "prompt"},
      %{"name" => "stats", "source" => "extension"}
    ]

    context
    |> quick_watchdog()
    |> install(%{"turns" => [turn | FakeAcp.pi_turns()], "commands" => commands})
  end

  step "that turn waits for Pi's agent and runs to its end", context do
    assert List.last(replies(context)) == "Started late."
    assert [%{"status" => "completed"}] = StreamState.list(state(context), "run")
    context
  end

  step "Pi accepted a message but never reports whether it is working", context do
    context =
      context
      |> quick_watchdog()
      |> install(%{"silentCommands" => ["go silent"]})
      |> FakeAcp.thread()
      |> turn("hello Pi")

    before = length(FakeAcp.received_type(context, "get_state"))
    context = FakeAcp.configure(context, &Map.put(&1, "failCommands", ["get_state"]))
    context = FakeAcp.send_message(context, "go silent please")
    await_received(context, "prompt", 2)
    Map.put(context, :get_state_before, before)
  end

  step "three checks of Pi's state fail", context do
    await_received(context, "get_state", context.get_state_before + 3)
    context
  end

  step "the silent turn fails", context do
    FakeAcp.await_run(context, "failed")
    context
  end

  # The fake has received `count` commands of `type` (it logs every one).
  defp await_received(context, type, count, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 10_000

    cond do
      length(FakeAcp.received_type(context, type)) >= count ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("Pi never received #{count} #{type} commands")

      true ->
        receive do
        after
          20 -> await_received(context, type, count, deadline)
        end
    end
  end

  # Several calls out on the MC's own Pi channel at once, on a Pi that takes
  # half a minute to answer any of them.
  step "HAL-C2 is waiting for Pi to answer several requests", context do
    context = install(context, %{"commandDelays" => %{"get_state" => 30}})
    {:ok, argv, env} = HalC2.Pi.launch("pi", ephemeral: true)

    {:ok, conn} =
      HalC2.JsonRpc.Connection.start_link(
        cmd: argv,
        handler: self(),
        cd: World.project(context).root,
        env: env,
        dialect: :pi
      )

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(conn) do
        try do
          HalC2.JsonRpc.Connection.stop(conn)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    tasks =
      for _ <- 1..3 do
        Task.async(fn -> HalC2.JsonRpc.Connection.call(conn, "get_state", %{}, 60_000) end)
      end

    await_received(context, "get_state", 1)
    Map.merge(context, %{waiting_conn: conn, waiting_tasks: tasks})
  end

  step "the Pi process exits", context do
    pid = HalC2.JsonRpc.Connection.os_pid(context.waiting_conn)
    {_, 0} = System.cmd("kill", ["-9", Integer.to_string(pid)])
    Map.put(context, :waiting_since, System.monotonic_time(:millisecond))
  end

  step "every waiting request fails immediately instead of waiting out its deadline", context do
    results = Task.yield_many(context.waiting_tasks, 10_000)
    elapsed = System.monotonic_time(:millisecond) - context.waiting_since

    assert Enum.all?(results, fn {_task, outcome} -> match?({:ok, {:error, _}}, outcome) end)
    assert elapsed < 10_000
    context
  end

  # --- messages sent while Pi compacts ---

  # Pi 1.4 rejects every prompt while it compacts: the fake does too, and logs the
  # prompts it takes up (`accepted`) and its compaction's start and end.
  @compaction_turns [
    %{"match" => "compact after", "compactAfter" => 2, "steps" => [%{"text" => "Done."}]},
    %{
      "match" => "compact within",
      "steps" => [%{"text" => "Working on it."}, %{"compactFor" => 2}, %{"waitAbort" => true}]
    }
  ]

  step ~r/^Pi is compacting the conversation (?<when>after a finished turn|inside the running turn)$/,
       %{args: [compacting]} = context do
    config = %{
      "turns" => @compaction_turns ++ FakeAcp.pi_turns(),
      "rejectWhileCompacting" => true
    }

    context = context |> install(config) |> FakeAcp.thread()
    compacting(Map.put(context, :compacting, compacting), "")
  end

  # A turn that leaves Pi compacting once it settled, or one compacting as it runs.
  # Pi sends `compaction_start` before it settles the turn's last checks, so by the
  # turn's end the MC has heard it.
  defp compacting(%{compacting: "after a finished turn"} = context, again),
    do: turn(context, "compact after this#{again}")

  defp compacting(context, again) do
    before = length(items(context, "compaction"))
    context = FakeAcp.send_message(context, "compact within this#{again}")

    World.await_stream(World.thread_id(context, context.thread), fn state ->
      running =
        state
        |> StreamState.list("turn-item")
        |> Enum.filter(&(&1["type"] == "compaction"))

      length(running) > before and List.last(running)["title"] == "Compacting context..."
    end)

    context
  end

  step ~r/^the user (?<how>sends|steers the turn with) "(?<text>[^"]+)" while it does$/,
       %{args: [how, text]} = context do
    if how == "sends" do
      turn(context, text)
    else
      assert {:ok, _} = steer(context, text)
      FakeAcp.await_run(context, "completed")
      context
    end
  end

  step "Pi receives {string} once, after the compaction ends", %{args: [text]} = context do
    log = Enum.with_index(FakeAcp.log(context))
    assert [at] = for({%{"accepted" => ^text}, i} <- log, do: i)
    assert [_ | _] = for({%{"compaction" => "end"}, i} <- log, i < at, do: i)
    assert for({%{"rejected" => ^text}, _} <- log, do: :rejected) == []
    context
  end

  # A second compaction like the first: a message sent meanwhile is stopped, and
  # one sent after it still runs, so Pi was free to take the stopped one by then.
  step "Pi never gets a message whose turn the user stops before then", context do
    stopped = "the stopped message"
    context = compacting(context, " again")
    thread_id = World.thread_id(context, context.thread)

    context =
      if context.compacting == "after a finished turn" do
        context = FakeAcp.send_message(context, stopped)
        FakeAcp.await_run(context, "running")
        context
      else
        steering = Task.async(fn -> steer(context, stopped) end)
        await_held_steer(thread_id)
        Map.put(context, :steering, steering)
      end

    {:ok, _} = HalC2.Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})
    if context[:steering], do: assert({:ok, _} = Task.await(context.steering))
    FakeAcp.await_run(context, "interrupted")
    context = turn(context, "after the stop")

    assert for(
             %{"recv" => %{"type" => "prompt", "message" => ^stopped}} <- FakeAcp.log(context),
             do: :sent
           ) == []

    context
  end

  # The runtime holds the steer while Pi compacts; nothing outside it says so yet.
  defp await_held_steer(thread_id, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 10_000
    [{pid, _}] = Registry.lookup(HalC2.Pi.Registry, thread_id)

    cond do
      :sys.get_state(pid).held_steers != [] ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("the steer was never held")

      true ->
        receive do
        after
          20 -> await_held_steer(thread_id, deadline)
        end
    end
  end

  # --- stopping while Pi compacts, and long texts ---

  # A `/compact` turn whose compaction is still running (the fake answers
  # it in half a minute). The restart grace is shortened the same way the
  # watchdog's is.
  step "Pi is compacting the conversation", context do
    Application.put_env(:hal_c2, :pi_compact_restart_ms, 200)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :pi_compact_restart_ms) end)

    context =
      context
      |> install(%{"compactDelaySec" => 30})
      |> FakeAcp.thread()
      |> turn("first")
      |> FakeAcp.send_message("/compact")

    await_compact_sent(context)
    context
  end

  step "Pi is given 2 seconds to stop the compaction and is then restarted", context do
    # Pi was asked to stop first (the abort), then restarted: the process
    # that was compacting is gone. Its next turn (below) runs a new one.
    assert FakeAcp.received_type(context, "abort") != []
    assert [%{"pid" => pid} | _] = thread_starts(context)
    deadline = System.monotonic_time(:millisecond) + 10_000

    await = fn await ->
      alive? =
        match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true))

      cond do
        not alive? ->
          :ok

        System.monotonic_time(:millisecond) > deadline ->
          flunk("the compacting Pi (pid #{pid}) was not restarted")

        true ->
          receive do
          after
            50 -> await.(await)
          end
      end
    end

    await.(await)
    FakeAcp.await_run(context, "interrupted")
    context
  end

  step "the thread can take the next message", context do
    context = turn(context, "hello again")
    assert length(thread_starts(context)) >= 2
    context
  end

  # Each long text arrives its own way; `kept` is what the thread shows of
  # it and `cut_original` what Pi sent, taken from the fake's own log or the
  # script, so the limit is checked against Pi's text, not the MC's copy.
  step ~r/^Pi sends (?<text>the input of a tool awaiting approval|the reason a compaction failed|the detail of an extension's failure|the current value of a text edit) longer than its limit$/,
       %{args: [text]} = context do
    {original, kept} =
      case text do
        "the input of a tool awaiting approval" ->
          command = String.duplicate("a", 5_000)

          turns = [
            %{
              "match" => "use your tool",
              "steps" => [
                %{"tool" => "bash", "args" => %{"command" => command}, "output" => "done"},
                %{"text" => "Done."}
              ]
            }
          ]

          context =
            context
            |> with_turns(turns)
            |> FakeAcp.thread("Work", "approval-required")
            |> FakeAcp.send_message("please use your tool")

          {_request, item} = await_approval(context)
          %{"message" => sent} = Enum.find(FakeAcp.log(context), & &1["ui"])["ui"]
          {sent, item["prompt"]}

        "the reason a compaction failed" ->
          reason = String.duplicate("r", 5_000)

          steps = [
            %{"event" => %{"type" => "compaction_start", "reason" => "threshold"}},
            %{
              "event" => %{
                "type" => "compaction_end",
                "aborted" => false,
                "result" => nil,
                "errorMessage" => reason
              }
            },
            %{"text" => "Done."}
          ]

          context = event_thread(context, steps, "compact please")
          [%{"summary" => kept}] = items(context, "compaction")
          {reason, kept}

        "the detail of an extension's failure" ->
          detail = String.duplicate("e", 5_000)

          steps = [
            %{
              "event" => %{
                "type" => "extension_error",
                "extensionPath" => "/extensions/auto-lint.ts",
                "event" => "tool_result",
                "error" => detail
              }
            },
            %{"text" => "Done."}
          ]

          context = event_thread(context, steps, "fail please")
          [%{"failure" => %{"message" => message}}] = items(context, "error")
          prefix = "auto-lint failed during tool_result.\n\n"
          {detail, String.replace_prefix(message, prefix, "")}

        "the current value of a text edit" ->
          prefill = String.duplicate("p", 5_000)

          context =
            dialog_thread(
              context,
              %{
                "ui" => %{"method" => "editor", "title" => "Edit it", "prefill" => prefill},
                "say" => "Got: "
              },
              "ask me something"
            )

          [question] = await_question(context)["questions"]
          [_, kept] = String.split(question["question"], "Current value:\n", parts: 2)
          {prefill, kept}
      end

    Map.merge(context, %{cut_original: original, cut_kept: kept})
  end

  step ~r/^the thread keeps its first (?<limit>[\d,]+) characters$/,
       %{args: [limit]} = context do
    limit = limit |> String.replace(",", "") |> String.to_integer()
    assert context.cut_kept == String.slice(context.cut_original, 0, limit)
    assert String.length(context.cut_kept) == limit
    context
  end

  # Reopening restarts Pi in a new mode, which switches back to the session
  # file; here that Pi takes far longer than the (shortened) minute to say
  # how its state is.
  step "Pi does not finish reopening that session within 60 seconds", context do
    Application.put_env(:hal_c2, :pi_open_ms, 300)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :pi_open_ms) end)

    context =
      FakeAcp.configure(context, &Map.put(&1, "commandDelays", %{"get_state" => 5}))

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.runtime-mode.set",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, context.thread),
        "runtimeMode" => "full-access"
      })

    turn(context, "hello again", "failed")
  end

  step "the user is told the session could not be opened", context do
    assert (last_error(context) || "") =~ "session could not be opened"
    context
  end

  step "Pi reports no file for the session", context do
    context = context |> install(%{"noSessionFile" => true}) |> FakeAcp.thread()
    turn(context, "hello Pi", "failed")
  end

  step "the thread fails to start with {string}", %{args: [message]} = context do
    assert (last_error(context) || "") =~ message
    context
  end

  step "a Pi extension cancels switching sessions", context do
    context = context |> install() |> FakeAcp.thread() |> turn("hello Pi")
    FakeAcp.configure(context, &Map.put(&1, "cancelSwitch", true))
  end

  step "the user opens a Pi thread with history", context do
    # A different access mode restarts Pi, which switches back to the session.
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.runtime-mode.set",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, context.thread),
        "runtimeMode" => "approval-required"
      })

    turn(context, "hello again", "failed")
  end

  step "the thread fails to start saying {string}", %{args: [message]} = context do
    assert (last_error(context) || "") =~ message
    context
  end

  step "the MC itself was started by an agent that holds a HAL-C2 tools credential", context do
    System.put_env("HAL_C2_MCP_BEARER_TOKEN", "another-sessions-token")
    System.put_env("HAL_C2_MCP_URL", "http://127.0.0.1:9/mcp")
    ExUnit.Callbacks.on_exit(fn -> System.delete_env("HAL_C2_MCP_BEARER_TOKEN") end)
    ExUnit.Callbacks.on_exit(fn -> System.delete_env("HAL_C2_MCP_URL") end)
    install(context)
  end

  step "a Pi thread starts", context do
    context |> FakeAcp.thread() |> turn("hello Pi")
  end

  step "Pi receives only the credential of its own thread", context do
    assert [%{"env" => env}] = thread_starts(context)
    refute env["HAL_C2_MCP_BEARER_TOKEN"] == "another-sessions-token"
    refute env["HAL_C2_MCP_URL"] == "http://127.0.0.1:9/mcp"
    context
  end

  step "the user's Pi installation has extensions, skills, project instructions and saved logins",
       context do
    install(context)
  end

  step "Pi loads all of them as it does in its own terminal app", context do
    assert [%{"argv" => argv}] = thread_starts(context)

    for off <- ["--no-extensions", "--no-skills", "--no-context-files", "--no-session"],
        do: refute(off in argv)

    context
  end

  step "a Pi thread titled {string}", %{args: [title]} = context do
    context |> install() |> FakeAcp.thread(title)
  end

  step "the thread next talks to Pi", context do
    turn(context, "hello Pi")
  end

  step "Pi's session is named {string}", %{args: [title]} = context do
    assert [%{"name" => ^title}] = FakeAcp.received_type(context, "set_session_name")
    context
  end

  step "Pi's own session list shows it under that name", context do
    assert JSON.decode!(File.read!(session_file(context)))["name"] ==
             FakeAcp.received_type(context, "set_session_name") |> hd() |> Map.get("name")

    context
  end

  step "a turn asks Pi for the model {string}", %{args: [model]} = context do
    context =
      context
      |> install()
      |> FakeAcp.thread("Work", "full-access", %{
        "modelSelection" => %{"instanceId" => "pi", "model" => model}
      })
      |> turn("hello Pi", "failed")

    context
  end

  step "the turn is refused with {string}", %{args: [message]} = context do
    assert (last_error(context) || "") =~ message
    context
  end

  # --- steering /compact and refusals ---

  step "{string} is not sent to the model as a message", %{args: [text]} = context do
    refute Enum.any?(FakeAcp.received_type(context, "prompt"), &(&1["message"] == text))
    context
  end

  step "Pi refuses a message the user steered the thread with", context do
    reply = steer(context, "refuse this one")
    assert {:error, _} = reply
    # Pi is still working: a steer it can take is answered in the same turn.
    {:ok, _} = steer(context, "also check the docs")
    context
  end

  step "the turn keeps running and its output keeps arriving", context do
    state = FakeAcp.await_run(context, "completed")
    assert [%{"status" => "completed"}] = StreamState.list(state, "run")
    assert Enum.any?(replies(context), &String.contains?(&1, "steered: also check the docs"))
    context
  end

  step "Pi is running a command", context do
    turns = [
      %{
        "match" => "run the slow command",
        "steps" => [
          %{
            "tool" => "bash",
            "args" => %{"command" => "sleep 60"},
            "output" => "",
            "hangInTool" => true
          }
        ]
      }
    ]

    context =
      context
      |> with_turns(turns)
      |> FakeAcp.thread()
      |> FakeAcp.send_message("please run the slow command")

    World.await_stream(World.thread_id(context, context.thread), fn state ->
      Enum.any?(StreamState.list(state, "turn-item"), &(&1["type"] == "command_execution"))
    end)

    context
  end

  # "the user stops the turn" is the common step (common_steps.exs).

  step "the command shows as interrupted, not failed", context do
    FakeAcp.await_run(context, "interrupted")
    assert [%{"status" => "interrupted"}] = items(context, "command_execution")
    context
  end

  # --- models and thinking across switches ---

  defp send_on_model(context, text, model, thinking \\ nil) do
    selection = %{"instanceId" => "pi", "model" => model}

    selection =
      if thinking,
        do: Map.put(selection, "options", [%{"id" => "thinking", "value" => thinking}]),
        else: selection

    before = for run <- StreamState.list(state(context), "run"), do: run["id"]
    context = FakeAcp.send_message(context, text, nil, %{"modelSelection" => selection})

    run =
      World.await_stream(World.thread_id(context, context.thread), fn state ->
        Enum.find(
          StreamState.list(state, "run"),
          &(&1["id"] not in before and &1["status"] in ~w(completed failed interrupted))
        )
      end)

    assert run["status"] == "completed"
    context
  end

  # The last thinking level Pi was set to after it was last set to the model
  # `provider/model_id`, in the order the fake received the commands.
  defp thinking_after_model(context, model_id) do
    received = for %{"recv" => msg} <- FakeAcp.log(context), do: msg

    {_seen, level} =
      Enum.reduce(received, {false, nil}, fn msg, {seen, level} ->
        cond do
          msg["type"] == "set_model" and msg["modelId"] == model_id -> {true, level}
          msg["type"] == "set_model" -> {seen, level}
          msg["type"] == "set_thinking_level" and seen -> {seen, msg["level"]}
          true -> {seen, level}
        end
      end)

    level
  end

  step "a Pi thread runs model {string} with thinking set to high by the user",
       %{args: [a]} = context do
    models = [
      %{"provider" => "fake", "id" => a, "name" => a, "reasoning" => true},
      %{"provider" => "fake", "id" => "B", "name" => "B", "reasoning" => true}
    ]

    context =
      install(context, %{
        "models" => models,
        "thinkingLevel" => "medium",
        "modelThinking" => %{"fake/#{a}" => "minimal", "fake/B" => "low"}
      })

    context =
      FakeAcp.thread(context, "Work", "full-access", %{
        "modelSelection" => %{"instanceId" => "pi", "model" => "fake/#{a}"}
      })

    send_on_model(context, "first on A", "fake/#{a}", "high")
  end

  step "the user switches the thread to model {string} and sends the next message",
       %{args: [b]} = context do
    send_on_model(context, "now on B", "fake/#{b}")
  end

  step "Pi runs the turn on {string} with thinking high", %{args: [b]} = context do
    assert thinking_after_model(context, b) == "high"
    context
  end

  step "switching back to Pi's default model with Pi's default thinking uses that model's own level",
       context do
    context = send_on_model(context, "back to default", "default")
    # Pi reported "minimal" for its own model on the way back; the session's
    # starting level (medium) is the default the user is back to.
    assert thinking_after_model(context, "A") == "medium"
    context
  end

  step "a Pi thread whose model the user changed from {string} to another model",
       %{args: [_default]} = context do
    models = [
      %{"provider" => "fake", "id" => "home", "name" => "Home", "reasoning" => true},
      %{"provider" => "fake", "id" => "other", "name" => "Other", "reasoning" => true}
    ]

    context =
      install(context, %{
        "models" => models,
        "thinkingLevel" => "low",
        "modelThinking" => %{"fake/home" => "minimal", "fake/other" => "minimal"}
      })

    context =
      FakeAcp.thread(context, "Work", "full-access", %{
        "modelSelection" => %{"instanceId" => "pi", "model" => "default"}
      })

    context = turn(context, "at home")
    send_on_model(context, "away", "fake/other", "high")
  end

  step "the user chooses {string} again", %{args: [_default]} = context do
    send_on_model(context, "home again", "default")
  end

  step "Pi goes back to the model and thinking level it started with", context do
    assert thinking_after_model(context, "home") == "low"
    context
  end

  step "Pi is set to model {string} at thinking level high", %{args: [a]} = context do
    models =
      for id <- [a, "b"],
          do: %{"provider" => "fake", "id" => id, "name" => id, "reasoning" => true}

    install(context, %{"models" => models, "thinkingLevel" => "high"})
  end

  step "the user opens the thinking options for Pi model {string}", %{args: [b]} = context do
    entry = FakeAcp.probe("pi")

    thinking_of = fn slug ->
      model = Enum.find(entry["models"], &(&1["slug"] == slug))
      model["capabilities"]["optionDescriptors"] |> hd()
    end

    Map.merge(context, %{thinking_b: thinking_of.("fake/#{b}"), thinking_entry: entry})
  end

  step "no level is marked as Pi's default for {string}", %{args: [_b]} = context do
    refute Enum.any?(context.thinking_b["options"], & &1["isDefault"])
    context
  end

  step "for {string} high is marked as the default", %{args: [a]} = context do
    model = Enum.find(context.thinking_entry["models"], &(&1["slug"] == "fake/#{a}"))
    [thinking] = model["capabilities"]["optionDescriptors"]
    assert [%{"id" => "high"}] = Enum.filter(thinking["options"], & &1["isDefault"])
    context
  end

  step "Pi discovered models from the providers {string} and {string}",
       %{args: [p1, p2]} = context do
    models = [
      %{"provider" => p1, "id" => "gpt-x", "name" => "GPT X", "reasoning" => false},
      %{"provider" => p2, "id" => "claude-x", "name" => "Claude X", "reasoning" => false}
    ]

    install(context, %{"models" => models})
  end

  step "the user opens the model picker and searches for {string}", %{args: [term]} = context do
    FakeAcp.probe("pi")
    {_, context} = FakeAcp.open_config(context)
    Map.put(context, :search_term, term)
  end

  step "the models from that provider are listed with its name", context do
    found =
      Enum.filter(pi(context)["models"], fn m ->
        String.contains?(String.downcase(m["subProvider"] || ""), context.search_term) or
          String.contains?(String.downcase(m["slug"] || ""), context.search_term)
      end)

    assert [%{"slug" => "anthropic/claude-x", "subProvider" => "anthropic"}] = found
    context
  end

  # --- fork without the user's extensions ---

  step "a Pi thread whose installation has extensions", context do
    context = install(context)

    FakeAcp.settings(
      &put_in(
        &1,
        ["providers", "pi", "launchArgs"],
        "--extension /tmp/user-ext.ts --tools bash,read"
      )
    )

    context |> FakeAcp.thread() |> turn("first") |> turn("second")
  end

  step "the user forks the Pi thread", context do
    source = World.thread_id(context, context.thread)
    run = state(context) |> StreamState.list("run") |> Enum.find(&(&1["ordinal"] == 1))
    id = "th-pi-plain-fork-#{System.unique_integer([:positive])}"

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.fork",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "sourceThreadId" => source,
        "targetThreadId" => id,
        "title" => "fork",
        "sourcePoint" => %{"type" => "run", "runId" => run["id"]}
      })

    context = put_in(context[:threads]["fork"], id)
    turn(context, "from the fork", "completed", "fork")
  end

  step "the copy of Pi's conversation is made with extensions and tools turned off", context do
    assert [%{"argv" => argv}] = Enum.filter(FakeAcp.starts(context), &("--fork" in &1["argv"]))
    assert "--no-extensions" in argv
    assert "--no-tools" in argv
    refute "/tmp/user-ext.ts" in argv
    refute "bash,read" in argv
    context
  end

  # --- slow skills ---

  step "Pi does not list its skills within 4 seconds", context do
    context =
      with_skills(context, ["deploy"], %{
        "commandDelays" => %{"get_commands" => 10},
        "delayOnce" => ["get_commands"]
      })

    FakeAcp.thread(context)
  end

  step "the thread is ready without them", context do
    started = System.monotonic_time(:millisecond)
    context = turn(context, "hello there")
    assert System.monotonic_time(:millisecond) - started < 9_000
    context
  end

  step "the skills are looked up again the first time the user mentions one", context do
    context = turn(context, "$deploy it now")
    assert last_prompt(context) =~ "/skill:deploy"
    context
  end

  # --- updates ---

  # The latest Pi release, as if already read from the registry.
  @pi_latest "0.81.0"

  defp pi_latest(context) do
    :persistent_term.put(
      {HalC2.ProviderUpdates, "pi"},
      {@pi_latest, System.monotonic_time(:millisecond)}
    )

    ExUnit.Callbacks.on_exit(fn ->
      for key <- [
            {HalC2.ProviderUpdates, "pi"},
            {HalC2.ProviderUpdates, "pi", :state},
            {HalC2.ProviderUpdates, "pi", :offered}
          ],
          do: :persistent_term.erase(key)
    end)

    context
  end

  # A global npm prefix: `bin/pi` links into `lib/node_modules`, and its npm logs
  # what it was asked and makes the fake report the latest version.
  step "the pi command on the MC was installed with npm", context do
    prefix = HalC2.Test.Mc.Host.path(context, "/usr/local")
    real = Path.join(prefix, "lib/node_modules/@earendil-works/pi-coding-agent/dist/pi")
    link = Path.join(prefix, "bin/pi")
    context = context |> pi_latest() |> install(%{}, path: real)
    %{dir: dir} = FakeAcp.fake(context)
    File.mkdir_p!(Path.dirname(link))
    File.ln_s!(real, link)
    FakeAcp.settings(&put_in(&1, ["providers", "pi", "binaryPath"], link))
    npm = Path.join(prefix, "bin/npm")
    config = Path.join(dir, "config.json")

    File.write!(npm, """
    #!/bin/sh
    echo "$@" >> '#{Path.join(prefix, "npm.log")}'
    python3 -c 'import json,sys; p=sys.argv[1]; c=json.load(open(p)); c["version"]="#{@pi_latest}"; json.dump(c,open(p,"w"))' '#{config}'
    """)

    File.chmod!(npm, 0o755)
    Map.put(context, :npm_prefix, prefix)
  end

  step "the user updates Pi from HAL-C2", context do
    {reply, context} =
      World.call_keeping(context, "server.updateProvider", %{"provider" => "pi"})

    Map.put(context, :reply, reply)
  end

  step "the Pi package is updated by npm", context do
    prefix = context.npm_prefix

    assert File.read!(Path.join(prefix, "npm.log")) ==
             "install -g --prefix #{prefix} @earendil-works/pi-coding-agent@latest\n"

    assert {:ok, %{"providers" => providers}} = context.reply
    pi = FakeAcp.find(providers, "pi")
    assert %{"version" => @pi_latest, "updateState" => %{"status" => "succeeded"}} = pi
    assert pi["versionAdvisory"]["status"] == "current"
    context
  end

  # A pi of its own (here the fake's plain script) is shown behind with no update
  # to run, and asking for one is refused.
  step "a Pi that npm does not own can only be updated by hand", context do
    context = install(context)

    {reply, context} =
      World.call_keeping(context, "server.updateProvider", %{"provider" => "pi"})

    assert {:error, "This installation cannot be updated from here.", _} = reply
    input = %{"instanceId" => "pi", "refreshModels" => true}

    {{:ok, %{"providers" => providers}}, context} =
      World.call_keeping(context, "server.refreshProviders", input, "default", 60_000)

    advisory = FakeAcp.find(providers, "pi")["versionAdvisory"]
    assert %{"status" => "behind_latest", "canUpdate" => false, "updateCommand" => nil} = advisory
    context
  end

  # --- OpenRouter output cap ---

  # The extension HAL-C2 writes for Pi, run under bun with a stand-in Pi API; the
  # cap is the extension's `before_provider_request` handler.
  @extension_harness Path.expand("../../support/pi_extension_harness.ts", __DIR__)

  step ~r/^a Pi thread uses an? (?<model>OpenRouter model|model from another provider)$/,
       %{args: [model]} = context do
    provider = if model == "OpenRouter model", do: "openrouter", else: "anthropic"
    Map.put(context, :pi_model, %{"provider" => provider, "id" => "some/model"})
  end

  step ~r/^Pi asks the model for up to (?<asked>[\d,]+) output tokens$/,
       %{args: [asked]} = context do
    payload = %{"model" => "some/model", "max_tokens" => tokens(asked)}
    event = JSON.encode!(%{"type" => "before_provider_request", "payload" => payload})
    ctx = JSON.encode!(%{"model" => context.pi_model})
    args = [@extension_harness, HalC2.Pi.extension_path(), "before_provider_request", event, ctx]
    env = [{"HAL_C2_MCP_URL", nil}, {"HAL_C2_MCP_BEARER_TOKEN", nil}]

    {out, 0} = System.cmd("bun", args, env: env, stderr_to_stdout: true)
    sent = out |> String.split("\n", trim: true) |> List.last() |> JSON.decode!()
    Map.put(context, :sent, sent || payload)
  end

  step ~r/^the request goes out asking for (?<sent>[\d,]+)$/, %{args: [sent]} = context do
    assert context.sent["max_tokens"] == tokens(sent)
    assert context.sent["model"] == "some/model"
    context
  end

  defp tokens(text), do: text |> String.replace(",", "") |> String.to_integer()
end
