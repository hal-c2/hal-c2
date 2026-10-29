defmodule HalC2.Steps.Orchestration.McpThreadTools do
  @moduledoc """
  Steps for `features/mc/orchestration/mcp-thread-tools.feature`, and the MCP
  caller setup and failure steps the other MCP features share.

  MCP tool calls keep their outcome in `context.mcp_result`: `{:ok, result}` or
  `{:error, code, message}` (see `HalC2.Test.Mc.World.mcp_tool/5`). Turns run on the
  fake Codex CLI: "wait" keeps one running, steering it with "say X" ends it.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.StreamState
  alias HalC2.Test.Mc.World

  @fake_text Path.expand("../../support/fake_text_cli.py", __DIR__)
  @active ~w(preparing starting running waiting)

  # --- shared by the MCP features --------------------------------------------------

  step "thread {string} in {string} runs in full-access mode with a turn running on {string}",
       %{args: [thread, project, "codex"]} = context do
    context = World.launch_titled(context, thread, project, "wait for it")
    World.await_runs(context, thread, ["running"])
    context
  end

  step "it fails with code {string}", %{args: [code]} = context do
    assert {:error, ^code, _} = context.mcp_result
    context
  end

  step "it fails with code {string} and {string}", %{args: [code, message]} = context do
    assert {:error, ^code, ^message} = context.mcp_result
    context
  end

  # --- threads of the scenario -----------------------------------------------------

  step("thread {string} in {string} is idle", %{args: [thread, project]} = context,
    do: World.create_thread(context, thread, project)
  )

  step "{string} is idle", %{args: [thread]} = context do
    refute Enum.any?(World.runs(context, thread), &(&1["status"] in @active))
    context
  end

  step("{string} has a turn running", %{args: [thread]} = context,
    do: start_waiting(context, thread)
  )

  step("{string} has a turn running that does not finish", %{args: [thread]} = context,
    do: start_waiting(context, thread)
  )

  step "thread {string} belongs to another project", %{args: [thread]} = context do
    context
    |> World.create_project("another")
    |> World.create_thread(thread, "another")
  end

  # --- listing and reading ---------------------------------------------------------

  step("the agent of {string} lists threads", %{args: [caller]} = context,
    do: Map.put(context, :mcp_result, World.mcp_tool(context, caller, "hal_c2_thread_list"))
  )

  step "it receives {string} and {string} with the project id and the caller's own id",
       %{args: [first, second]} = context do
    assert {:ok, result} = context.mcp_result
    ids = Enum.map(result["threads"], & &1["threadId"])
    assert World.thread_id(context, first) in ids
    assert World.thread_id(context, second) in ids
    assert result["projectId"] == World.project(context, "demo").id
    assert result["currentThreadId"] == World.thread_id(context, "caller")
    context
  end

  step "it does not receive {string}", %{args: [thread]} = context do
    assert {:ok, result} = context.mcp_result
    refute World.thread_id(context, thread) in Enum.map(result["threads"], & &1["threadId"])
    context
  end

  step ~r/^the agent of "(?<caller>[^"]+)" lists threads (?<filter>with status "running"|whose title contains "Fix" in any case|leaving out subagent threads|with a limit of 1)$/,
       %{args: [caller, filter]} = context do
    caller_id = World.thread_id(context, caller)

    {context, arguments, expected} =
      case filter do
        "with status " <> _ ->
          {context, %{"statuses" => ["running"]}, [caller_id]}

        "whose title contains " <> _ ->
          context =
            context
            |> World.create_thread("Fix login", "demo")
            |> World.create_thread("hotfix build", "demo")

          {context, %{"titleContains" => "Fix"},
           [World.thread_id(context, "Fix login"), World.thread_id(context, "hotfix build")]}

        "leaving out subagent threads" ->
          context =
            World.launch_titled(context, "helper", "demo", "say done", %{
              "lineage" => %{"parentThreadId" => caller_id, "relationshipToParent" => "subagent"}
            })

          World.await_row(
            World.thread_id(context, "helper"),
            &(get_in(&1, ["lineage", "relationshipToParent"]) == "subagent")
          )

          {context, %{"includeSubagents" => false}, [caller_id, World.thread_id(context, "t2")]}

        "with a limit of 1" ->
          {context, %{"limit" => 1}, :first}
      end

    result = World.mcp_tool(context, caller, "hal_c2_thread_list", arguments)
    context |> Map.put(:mcp_result, result) |> Map.put(:expected_threads, expected)
  end

  step "only matching threads are returned with a total and a next cursor when more remain",
       context do
    assert {:ok, result} = context.mcp_result
    ids = Enum.map(result["threads"], & &1["threadId"])

    case context.expected_threads do
      :first ->
        # Two threads in the project: one on this page, the other behind the cursor.
        assert length(ids) == 1
        assert result["total"] == 2
        assert result["nextCursor"] == 1

      expected ->
        assert Enum.sort(ids) == Enum.sort(expected)
        assert result["total"] == length(expected)
        assert result["nextCursor"] == nil
    end

    context
  end

  step "{string} has {int} messages", %{args: [thread, 5]} = context do
    # A user message and two answers, then a user message and one answer.
    assert %{"status" => "completed"} = World.finish_turn(context, thread, "say one | two")
    assert %{"status" => "completed"} = World.finish_turn(context, thread, "say three")
    context
  end

  step "the agent of {string} reads {string} after position {int}",
       %{args: [caller, thread, position]} = context do
    result =
      World.mcp_tool(context, caller, "hal_c2_thread_read", %{
        "threadId" => World.thread_id(context, thread),
        "afterPosition" => position
      })

    Map.put(context, :mcp_result, result)
  end

  step "it receives the messages at positions 3 and 4, the next position and whether more remain",
       context do
    assert {:ok, result} = context.mcp_result
    assert Enum.map(result["items"], & &1["position"]) == [3, 4]
    assert Enum.map(result["items"], & &1["text"]) == ["say three", "three"]
    assert result["nextPosition"] == 4
    assert result["hasMore"] == false
    context
  end

  step "the thread's recent runs, newest first", context do
    assert {:ok, %{"recentRuns" => runs}} = context.mcp_result
    assert Enum.map(runs, & &1["ordinal"]) == [2, 1]
    assert Enum.all?(runs, &(&1["status"] == "completed"))
    context
  end

  step "the agent of {string} reads {string} in the activity view",
       %{args: [caller, thread]} = context do
    assert %{"status" => "completed"} = World.finish_turn(context, thread, "edit notes.md")

    messages =
      World.mcp_tool(context, caller, "hal_c2_thread_read", %{
        "threadId" => World.thread_id(context, thread)
      })

    result =
      World.mcp_tool(context, caller, "hal_c2_thread_read", %{
        "threadId" => World.thread_id(context, thread),
        "view" => "activity"
      })

    context |> Map.put(:mcp_result, result) |> Map.put(:messages_view, messages)
  end

  step "commands, file changes and other items are included", context do
    assert {:ok, %{"items" => items}} = context.mcp_result
    types = Enum.map(items, & &1["type"])
    assert "command_execution" in types
    assert "file_change" in types
    assert "user_message" in types and "assistant_message" in types
    # The messages view leaves the tool work out.
    assert {:ok, %{"items" => messages}} = context.messages_view
    assert Enum.all?(messages, &(&1["type"] in ["user_message", "assistant_message"]))
    context
  end

  step "a message of {string} is 30,000 characters long", %{args: [thread]} = context do
    text = String.duplicate("x", 30_000)
    assert %{"status" => "completed"} = World.finish_turn(context, thread, text)
    Map.merge(context, %{long_thread: thread, long_text: text})
  end

  step "the agent of {string} reads it with a limit of 20,000 characters",
       %{args: [caller]} = context do
    result =
      World.mcp_tool(context, caller, "hal_c2_thread_read", %{
        "threadId" => World.thread_id(context, context.long_thread),
        "maxCharsPerItem" => 20_000
      })

    context |> Map.put(:mcp_result, result) |> Map.put(:reader, caller)
  end

  step "the text is cut to 20,000 characters and can be read on from an offset", context do
    assert {:ok, %{"items" => items}} = context.mcp_result
    assert %{"itemId" => item, "text" => text} = Enum.find(items, & &1["truncated"])
    assert text == String.slice(context.long_text, 0, 20_000)

    assert {:ok, %{"items" => [rest]}} =
             World.mcp_tool(context, context.reader, "hal_c2_thread_read", %{
               "threadId" => World.thread_id(context, context.long_thread),
               "itemId" => item,
               "maxCharsPerItem" => 20_000,
               "textOffset" => 20_000
             })

    assert rest["text"] == String.slice(context.long_text, 20_000, 10_000)
    assert rest["truncated"] == false
    context
  end

  step("the agent of {string} reads without naming a thread", %{args: [caller]} = context,
    do: Map.put(context, :mcp_result, World.mcp_tool(context, caller, "hal_c2_thread_read"))
  )

  step "it receives {string}", %{args: [thread]} = context do
    assert {:ok, %{"thread" => %{"threadId" => id}}} = context.mcp_result
    assert id == World.thread_id(context, thread)
    context
  end

  # --- sending ---------------------------------------------------------------------

  step "the agent of {string} sends {string} to {string} in mode {string}",
       %{args: [caller, text, thread, mode]} = context do
    send_message(context, caller, thread, %{"message" => text, "mode" => mode})
    |> Map.put(:sent_text, text)
  end

  step(
    "the agent of {string} sends a message to {string} in mode {string}",
    %{args: [caller, thread, mode]} = context,
    do: send_message(context, caller, thread, %{"message" => "say hi", "mode" => mode})
  )

  step("the agent of {string} sends a message to {string}", %{args: [caller, thread]} = context,
    do: send_message(context, caller, thread, %{"message" => "say hi"})
  )

  step ~r/^the message is delivered as (?<delivery>a new turn started immediately|a steer of the running turn|a turn queued after the active one|a restart of the running turn)$/,
       %{args: [delivery]} = context do
    assert {:ok, result} = context.mcp_result
    thread = context.sent_to
    first = List.first(context.runs_before)

    case delivery do
      "a new turn started immediately" ->
        assert result["delivery"] == "start_immediately"
        assert result["runId"] != nil

        World.await_state(context, thread, fn state ->
          Enum.any?(StreamState.list(state, "run"), &(&1["id"] == result["runId"]))
        end)

      "a steer of the running turn" ->
        assert result["delivery"] == "steer_active"
        state = World.state(context, thread)
        assert StreamState.get(state, "message")[result["messageId"]]["runId"] == first["id"]

      "a turn queued after the active one" ->
        assert result["delivery"] == "queue_after_active"
        runs = World.runs(context, thread)
        queued = Enum.find(runs, &(&1["userMessageId"] == result["messageId"]))
        assert queued["status"] == "queued"
        assert Enum.find(runs, &(&1["id"] == first["id"]))["status"] == "running"

      "a restart of the running turn" ->
        assert result["delivery"] == "restart_active"

        World.await_state(context, thread, fn state ->
          runs = StreamState.list(state, "run")

          Enum.find(runs, &(&1["id"] == first["id"]))["status"] == "interrupted" and
            Enum.any?(runs, &(&1["userMessageId"] == result["messageId"]))
        end)
    end

    context
  end

  step "it is recorded as sent by {string}, created by an agent through MCP",
       %{args: [caller]} = context do
    assert {:ok, %{"messageId" => id}} = context.mcp_result
    message = StreamState.get(World.state(context, context.sent_to), "message")[id]
    assert message["text"] == context.sent_text
    assert message["senderThreadId"] == World.thread_id(context, caller)
    assert message["createdBy"] == "agent"
    assert message["creationSource"] == "mcp"
    context
  end

  # --- waiting and interrupting ----------------------------------------------------

  step "the agent of {string} waits on {string}", %{args: [caller, thread]} = context do
    id = World.thread_id(context, thread)

    task =
      Task.async(fn ->
        World.mcp_tool(context, caller, "hal_c2_thread_wait", %{"threadId" => id})
      end)

    Map.put(context, :wait, task)
  end

  step "that turn completes", context do
    thread = Enum.find_value(context.threads, fn {t, _} -> if t == "t2", do: t end)
    World.send_turn(context, thread, "say done")
    context
  end

  step "the wait returns status {string} without timing out", %{args: [status]} = context do
    assert {:ok, result} = Task.await(context.wait, 10_000)
    assert result["status"] == status
    assert result["timedOut"] == false
    context
  end

  step "the agent of {string} waits on {string} for 1 second",
       %{args: [caller, thread]} = context do
    started = System.monotonic_time(:millisecond)

    result =
      World.mcp_tool(context, caller, "hal_c2_thread_wait", %{
        "threadId" => World.thread_id(context, thread),
        "timeoutMs" => 1_000
      })

    context
    |> Map.put(:mcp_result, result)
    |> Map.put(:waited, System.monotonic_time(:millisecond) - started)
  end

  # Waits by agents on ACP providers are capped under their client's limit; this
  # shortens the cap (restored afterwards).
  step "the MCP client of an ACP provider gives up on a tool call after 1 second", context do
    previous = Application.get_env(:hal_c2, :acp_max_wait_ms)
    Application.put_env(:hal_c2, :acp_max_wait_ms, 1_000)

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:hal_c2, :acp_max_wait_ms, previous),
        else: Application.delete_env(:hal_c2, :acp_max_wait_ms)
    end)

    context
  end

  step "the agent of {string} on {string} waits on {string} for 2 hours",
       %{args: [caller, instance, thread]} = context do
    started = System.monotonic_time(:millisecond)

    result =
      World.mcp_tool(
        context,
        caller,
        "hal_c2_thread_wait",
        %{"threadId" => World.thread_id(context, thread), "timeoutMs" => 2 * 60 * 60 * 1_000},
        instance
      )

    context
    |> Map.put(:mcp_result, result)
    |> Map.put(:waited, System.monotonic_time(:millisecond) - started)
  end

  step "the wait returns the run's current status and that it timed out", context do
    assert {:ok, result} = context.mcp_result
    assert result["status"] == "running"
    assert result["timedOut"] == true
    assert context.waited >= 1_000
    context
  end

  step ~r/^the agent of "(?<caller>[^"]+)" waits on "(?<thread>[^"]+)" for (?<asked>nothing given|0 milliseconds|2 hours)$/,
       %{args: [caller, thread, asked]} = context do
    requested =
      case asked do
        "nothing given" -> nil
        "0 milliseconds" -> 0
        "2 hours" -> 2 * 60 * 60 * 1_000
      end

    arguments =
      if requested,
        do: %{"threadId" => World.thread_id(context, thread), "timeoutMs" => requested},
        else: %{"threadId" => World.thread_id(context, thread)}

    # The thread is idle, so the wait answers at once whatever it would allow.
    result = World.mcp_tool(context, caller, "hal_c2_thread_wait", arguments)

    context
    |> Map.put(:mcp_result, result)
    |> Map.put(:requested_timeout, requested)
  end

  step ~r/^the wait lasts at most (?<used>10 minutes|1 millisecond|1 hour)$/,
       %{args: [used]} = context do
    assert {:ok, %{"timedOut" => false}} = context.mcp_result

    limit =
      case used do
        "10 minutes" -> 10 * 60 * 1_000
        "1 millisecond" -> 1
        "1 hour" -> 60 * 60 * 1_000
      end

    assert HalC2.Mcp.Tools.wait_timeout(context.requested_timeout) == limit
    context
  end

  step "the agent of {string} waits on idle thread {string}",
       %{args: [caller, thread]} = context do
    assert %{"status" => "completed"} = World.finish_turn(context, thread, "say ready")
    started = System.monotonic_time(:millisecond)

    result =
      World.mcp_tool(context, caller, "hal_c2_thread_wait", %{
        "threadId" => World.thread_id(context, thread),
        "timeoutMs" => 60_000
      })

    context
    |> Map.put(:mcp_result, result)
    |> Map.put(:waited, System.monotonic_time(:millisecond) - started)
    |> Map.put(:wait_thread, thread)
  end

  step "the wait returns immediately with the latest run's status", context do
    assert {:ok, result} = context.mcp_result
    [latest] = World.runs(context, context.wait_thread)
    assert result["runId"] == latest["id"]
    assert result["status"] == "completed"
    assert result["timedOut"] == false
    assert context.waited < 5_000
    context
  end

  step "the agent of {string} interrupts {string}", %{args: [caller, thread]} = context do
    arguments = %{"threadId" => World.thread_id(context, thread)}

    arguments =
      if context[:named_run], do: Map.put(arguments, "runId", context.named_run), else: arguments

    result = World.mcp_tool(context, caller, "hal_c2_thread_interrupt", arguments)
    Map.put(context, :mcp_result, result)
  end

  step "the running turn of {string} is interrupted", %{args: [thread]} = context do
    assert {:ok, %{"interrupted" => true, "runId" => run}} = context.mcp_result

    World.await_state(context, thread, fn state ->
      StreamState.get(state, "run")[run]["status"] == "interrupted"
    end)

    context
  end

  # --- search and environment ------------------------------------------------------

  step "threads in {string} and in another project mention {string}",
       %{args: [project, word]} = context do
    context =
      context
      |> World.create_thread("local mention", project)
      |> World.create_project("another")
      |> World.create_thread("foreign mention", "another")

    for thread <- ["local mention", "foreign mention"] do
      assert %{"status" => "completed"} =
               World.finish_turn(context, thread, "the #{word} test again")
    end

    context
  end

  step "the agent of {string} searches for {string}", %{args: [caller, word]} = context do
    result = World.mcp_tool(context, caller, "hal_c2_thread_search", %{"query" => word})
    Map.put(context, :mcp_result, result)
  end

  step "only matches in {string} are returned", %{args: [project]} = context do
    assert {:ok, %{"matches" => matches}} = context.mcp_result
    assert Enum.map(matches, & &1["threadId"]) == [World.thread_id(context, "local mention")]
    assert Enum.all?(matches, &(&1["projectId"] == World.project(context, project).id))
    context
  end

  step("the agent of {string} reads the environment", %{args: [caller]} = context,
    do: Map.put(context, :mcp_result, World.mcp_tool(context, caller, "hal_c2_environment_read"))
  )

  step "it receives the environment id, label, platform, the caller's thread and project",
       context do
    assert {:ok, result} = context.mcp_result
    descriptor = HalC2.Environment.descriptor()
    assert result["environmentId"] == descriptor["environmentId"]
    assert is_binary(result["environmentId"])
    assert result["label"] == descriptor["label"]
    assert result["platform"] == descriptor["platform"]
    assert result["currentThreadId"] == World.thread_id(context, "caller")
    assert result["currentProjectId"] == World.project(context, "demo").id
    context
  end

  step "each enabled provider instance with its driver, status and model slugs", context do
    assert {:ok, %{"providers" => providers}} = context.mcp_result
    enabled = for p <- HalC2.Environment.providers(), p["enabled"] != false, do: p

    assert Enum.map(providers, & &1["providerInstanceId"]) ==
             Enum.map(enabled, & &1["instanceId"])

    codex = Enum.find(providers, &(&1["providerInstanceId"] == "codex"))
    assert codex["driver"] == "codex"
    assert is_binary(codex["status"])
    assert codex["models"] != [] and Enum.all?(codex["models"], &is_binary/1)
    context
  end

  step "the agent of {string} updates the default thread workspace mode and the writing style",
       %{args: [caller]} = context do
    {settings, version} = HalC2.Settings.get()
    {:ok, _} = HalC2.Settings.put(Map.put(settings, "enableAgentBrowserAccess", true), version)

    result =
      World.mcp_tool(context, caller, "hal_c2_environment_preferences_update", %{
        "defaultThreadEnvMode" => "worktree",
        "sourceControlWritingStyle" => %{"mode" => "custom", "customInstructions" => "Be brief."},
        "enableAgentBrowserAccess" => false
      })

    Map.put(context, :mcp_result, result)
  end

  step "those settings change", context do
    assert {:ok, result} = context.mcp_result
    assert result["defaultThreadEnvMode"] == "worktree"
    assert result["sourceControlWritingStyle"]["customInstructions"] == "Be brief."
    {settings, _} = HalC2.Settings.get()
    assert settings["defaultThreadEnvMode"] == "worktree"
    assert settings["sourceControlWritingStyle"]["mode"] == "custom"
    context
  end

  step "settings outside the allowed list are left alone", context do
    {settings, _} = HalC2.Settings.get()
    assert settings["enableAgentBrowserAccess"] == true
    context
  end

  # --- launching and creating ------------------------------------------------------

  step "the agent of {string} launches a thread in {string} with message {string}",
       %{args: [caller, project, text]} = context do
    result =
      World.mcp_tool(context, caller, "hal_c2_thread_launch", %{
        "projectId" => World.project(context, project).id,
        "title" => "Release notes",
        "message" => text
      })

    context |> Map.put(:mcp_result, result) |> Map.put(:launch_text, text)
  end

  step "a new thread is created by an agent through MCP with the caller's model and modes",
       context do
    assert {:ok, %{"threadId" => id}} = context.mcp_result
    context = put_in(context, [:threads, "launched"], id)
    thread = World.thread(context, "launched")
    caller = World.thread(context, "caller")
    assert thread["createdBy"] == "agent"
    assert thread["creationSource"] == "mcp"
    assert thread["modelSelection"] == caller["modelSelection"]
    assert thread["runtimeMode"] == caller["runtimeMode"]
    assert thread["interactionMode"] == caller["interactionMode"]
    context
  end

  step "its first turn starts with that message", context do
    state =
      World.await_state(context, "launched", fn state ->
        StreamState.list(state, "run") != []
      end)

    [run] = StreamState.list(state, "run")
    assert StreamState.get(state, "message")[run["userMessageId"]]["text"] == context.launch_text
    context
  end

  # The base branch is ahead of `main`, so a worktree based on it can be told from one
  # based on the checkout's own branch.
  step "the agent of {string} launches a thread in {string} in a new worktree based on {string} on branch {string}",
       %{args: [caller, project, base, branch]} = context do
    %{id: project_id, root: root} = World.project(context, project)
    World.git!(root, ["checkout", "-q", "-b", base])
    World.commit!(root, %{"base.txt" => "from the base\n"}, "base work")
    World.git!(root, ~w(checkout -q main))
    HalC2.Test.Mc.ensure(HalC2.Workspace)
    context = World.worktree_setup(context)

    result =
      World.mcp_tool(context, caller, "hal_c2_thread_launch", %{
        "projectId" => project_id,
        "title" => "Demo",
        "message" => "list the files",
        "workspaceStrategy" => %{
          "type" => "worktree",
          "baseRef" => base,
          "branch" => branch,
          "startFromOrigin" => false
        }
      })

    # The launching steps know the thread as "new" (`a new thread exists in ...`).
    assert {:ok, %{"threadId" => id, "projectId" => ^project_id}} = result

    context
    |> Map.merge(%{mcp_result: result, launch_base: base, launch_branch: branch})
    |> put_in([:threads, "new"], id)
    |> put_in([:threads, "launched"], id)
  end

  step "its worktree is based on {string}", %{args: [base]} = context do
    root = World.project(context, "demo").root
    branch = context.launch_branch

    state =
      World.await_state(context, "launched", fn state ->
        thread = StreamState.get(state, "thread")[World.thread_id(context, "launched")]
        is_binary(thread["worktreePath"]) and thread["branch"] == branch
      end)

    path = StreamState.get(state, "thread")[World.thread_id(context, "launched")]["worktreePath"]
    assert World.git!(path, ~w(rev-parse --is-inside-work-tree)) == "true"
    assert World.git!(path, ~w(rev-parse --abbrev-ref HEAD)) == branch
    # The new branch starts at the base branch's commit, not at the checkout's.
    assert World.git!(path, ~w(rev-parse HEAD)) == World.git!(root, ["rev-parse", base])
    refute World.git!(path, ~w(rev-parse HEAD)) == World.git!(root, ~w(rev-parse main))
    assert File.read!(Path.join(path, "base.txt")) == "from the base\n"
    Map.put(context, :launch_path, path)
  end

  step "its first run waits until the worktree is ready", context do
    # The launch answered while the workspace was still being prepared...
    assert {:ok, %{"runId" => run_id, "status" => "preparing"}} = context.mcp_result
    id = World.thread_id(context, "launched")

    state =
      World.await_state(
        context,
        "launched",
        &(StreamState.get(&1, "run")[run_id]["status"] == "completed"),
        15_000
      )

    # ...and the turn started only once it was: in the worktree, after the preparation
    # item completed.
    ready = StreamState.get(state, "turn-item")["turn-item:workspace-preparation:#{run_id}"]
    assert %{"status" => "completed", "title" => "Workspace ready"} = ready
    assert StreamState.get(state, "run")[run_id]["startedAt"] >= ready["completedAt"]

    assert [%{"cwd" => cwd}] =
             Enum.filter(World.codex_requests(context, "turn/start"), fn request ->
               Enum.any?(request["input"], &(&1["text"] == "list the files"))
             end)

    assert cwd == context.launch_path

    preparing =
      Enum.find(World.events(context, "launched"), &(&1.kind == "run" and &1.entity == run_id))

    assert %{"s" => %{"status" => "preparing"}} = preparing.patch
    assert id == StreamState.get(state, "run")[run_id]["threadId"]
    context
  end

  step "the agent of {string} launches a thread with an attachment that already belongs to {string}",
       %{args: [caller, thread]} = context do
    attachment = %{
      "type" => "image",
      "id" => "#{World.thread_id(context, thread)}-shot",
      "name" => "shot.png",
      "mimeType" => "image/png",
      "sizeBytes" => 4
    }

    result =
      World.mcp_tool(context, caller, "hal_c2_thread_launch", %{
        "title" => "With attachment",
        "message" => "look",
        "attachments" => [attachment]
      })

    Map.put(context, :mcp_result, result)
  end

  step "the agent of {string} launches a thread in project {string}",
       %{args: [caller, project]} = context do
    result =
      World.mcp_tool(context, caller, "hal_c2_thread_launch", %{
        "projectId" => project,
        "title" => "Lost",
        "message" => "say hi"
      })

    Map.put(context, :mcp_result, result)
  end

  step "the agent of {string} creates {int} threads with prompts",
       %{args: [caller, n]} = context do
    threads = for i <- 1..n, do: %{"prompt" => "say batch #{i}"}
    create_threads(context, caller, threads, "batch-1")
  end

  step "{int} top-level threads exist in the caller's project and workspace",
       %{args: [n]} = context do
    assert {:ok, %{"threads" => threads}} = context.mcp_result
    assert length(threads) == n
    caller = World.row(context, "caller")

    for %{"threadId" => id} <- threads do
      row = World.await_row(id, & &1)
      assert row["projectId"] == caller["projectId"]
      assert row["worktreePath"] == caller["worktreePath"]
      assert row["branch"] == caller["branch"]
      assert get_in(row, ["lineage", "parentThreadId"]) == nil
    end

    context
  end

  step "each starts its prompt immediately", context do
    assert {:ok, %{"threads" => threads}} = context.mcp_result

    for {%{"threadId" => id, "runId" => run_id}, i} <- Enum.with_index(threads, 1) do
      assert run_id != nil
      state = HalC2.Streams.Server.state(HalC2.Streams.ensure(id))
      run = StreamState.get(state, "run")[run_id]
      assert run["queuePosition"] == nil
      assert StreamState.get(state, "message")[run["userMessageId"]]["text"] == "say batch #{i}"
    end

    context
  end

  step "their ids are derived from the caller, the request key and their position", context do
    assert {:ok, %{"threads" => threads}} = context.mcp_result
    caller = World.thread_id(context, "caller")

    assert Enum.map(threads, & &1["threadId"]) ==
             for(i <- 0..(length(threads) - 1), do: "thread:mcp:#{caller}:batch-1:#{i}")

    context
  end

  step "the agent of {string} created threads with request key {string}",
       %{args: [caller, key]} = context do
    context =
      create_threads(context, caller, [%{"prompt" => "say one"}, %{"prompt" => "say two"}], key)

    assert {:ok, %{"threads" => [_, _] = threads}} = context.mcp_result
    for %{"threadId" => id} <- threads, do: World.await_row(id, & &1)
    Map.put(context, :batch_caller, caller)
  end

  step "it repeats the request with request key {string}", %{args: [key]} = context do
    # A thread batch here, a delegated task in the delegation scenarios.
    if context[:batch_caller] do
      create_threads(
        context,
        context.batch_caller,
        [%{"prompt" => "say one"}, %{"prompt" => "say two"}],
        key
      )
    else
      result =
        World.mcp_tool(context, context.task_parent, "delegate_task", %{
          "task" => "wait for it",
          "mode" => "async",
          "clientRequestId" => key
        })

      Map.put(context, :mcp_result, result)
    end
  end

  step "it fails because the threads already exist", context do
    assert {:error, "orchestration_error", message} = context.mcp_result
    assert message =~ "Unable to create thread 1"
    assert message =~ "already exists"
    context
  end

  step "no extra threads are created", context do
    caller = World.thread_id(context, "caller")

    batch =
      for {{_mc, id}, {"thread", _row}} <- HalC2.Shell.rows(),
          String.starts_with?(id, "thread:mcp:#{caller}:"),
          do: id

    assert length(batch) == 2
    context
  end

  step ~r/^the agent of "(?<caller>[^"]+)" creates a thread with (?<input>title "Audit deps"|no title and a 100-character prompt|no title and no prompt, 2nd in batch)$/,
       %{args: [caller, input]} = context do
    {threads, pick} =
      case input do
        "title " <> _ -> {[%{"title" => "Audit deps", "prompt" => "say audit"}], 0}
        "no title and a 100-character prompt" -> {[%{"prompt" => prompt(100)}], 0}
        "no title and no prompt, 2nd in batch" -> {[%{}, %{}], 1}
      end

    context = create_threads(context, caller, threads, "titles")
    assert {:ok, %{"threads" => created}} = context.mcp_result
    Map.put(context, :titled, Enum.at(created, pick)["threadId"])
  end

  step ~r/^its title is (?<title>the .+)$/, %{args: [title]} = context do
    expected =
      case title do
        ~s(the first 77 characters followed by "...") ->
          String.slice(prompt(100), 0, 77) <> "..."

        ~s(the caller's title followed by " thread 2") ->
          World.row(context, "caller")["title"] <> " thread 2"
      end

    row = World.await_row(context.titled, & &1)
    assert row["title"] == expected
    context
  end

  step "the agent of {string} asks for {int} threads in one batch",
       %{args: [caller, n]} = context do
    threads = for i <- 1..n, do: %{"title" => "Batch #{i}"}
    create_threads(context, caller, threads, "too-many")
  end

  step "the request is rejected", context do
    assert {:error, "invalid_request", message} = context.mcp_result
    assert message =~ "20"
    caller = World.thread_id(context, "caller")

    refute Enum.any?(HalC2.Shell.rows(), fn {{_mc, id}, {kind, _row}} ->
             kind == "thread" and String.starts_with?(id, "thread:mcp:#{caller}:")
           end)

    context
  end

  step ~r/^the agent of "(?<caller>[^"]+)" creates a thread on (?<target>a driver with no usable instance|an instance that is not registered|an instance that is not signed in|an instance whose driver differs from the one named|a model the instance does not offer)$/,
       %{args: [caller, target]} = context do
    target =
      case target do
        "a driver with no usable instance" ->
          %{"driverKind" => "cursor"}

        "an instance that is not registered" ->
          %{"providerInstanceId" => "codex-elsewhere"}

        "an instance that is not signed in" ->
          signed_out_agent(context)
          %{"providerInstanceId" => "opencode"}

        "an instance whose driver differs from the one named" ->
          %{"providerInstanceId" => "codex", "driverKind" => "claudeAgent"}

        "a model the instance does not offer" ->
          %{"providerInstanceId" => "codex", "model" => "no-such-model"}
      end

    create_threads(context, caller, [%{"prompt" => "say hi", "target" => target}], "target")
  end

  step "the agent of {string} creates {int} threads and the second cannot be created",
       %{args: [caller, 3]} = context do
    # The second thread's id is already taken.
    taken = "thread:mcp:#{World.thread_id(context, caller)}:broken:1"
    context = World.create_thread(context, "taken", "demo", %{"threadId" => taken})
    threads = for i <- 1..3, do: %{"prompt" => "say batch #{i}"}
    create_threads(context, caller, threads, "broken")
  end

  step "the first exists, the third was not attempted", context do
    caller = World.thread_id(context, "caller")
    World.await_row("thread:mcp:#{caller}:broken:0", & &1)
    assert HalC2.Shell.row(node(), "thread:mcp:#{caller}:broken:2") == nil
    context
  end

  step "the error names thread 2", context do
    assert {:error, "orchestration_error", "Unable to create thread 2: " <> _} =
             context.mcp_result

    context
  end

  # --- forks and merge-backs -------------------------------------------------------

  step "{string} has a completed turn", %{args: [thread]} = context do
    # Its running turn completes and another starts, so its agent is still live.
    context = World.send_turn(context, thread, "say done")
    World.await_runs(context, thread, ["completed"])
    start_waiting(context, thread)
  end

  step "the agent of {string} forks itself", %{args: [caller]} = context do
    result = World.mcp_tool(context, caller, "hal_c2_thread_fork", %{"title" => "Agent fork"})
    Map.put(context, :mcp_result, result)
  end

  step "a fork of {string} is created by an agent through MCP and its id is returned",
       %{args: [source]} = context do
    assert {:ok, %{"targetThreadId" => id}} = context.mcp_result
    World.await_row(id, & &1)

    fork =
      HalC2.Streams.Server.state(HalC2.Streams.ensure(id))
      |> StreamState.get("thread")
      |> Map.get(id)

    assert fork["createdBy"] == "agent"
    assert fork["creationSource"] == "mcp"
    assert get_in(fork, ["lineage", "parentThreadId"]) == World.thread_id(context, source)
    context
  end

  step "{string} is a fork of {string} with a completed turn",
       %{args: [fork, parent]} = context do
    # The scenario's caller becomes a fork of `parent`, with a turn of its own done and
    # another running.
    assert %{"status" => "completed"} = World.finish_turn(context, parent, "write base.txt")
    id = "th-fork-#{System.unique_integer([:positive])}"

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.fork",
        "commandId" => "cmd-fork-#{id}",
        "sourceThreadId" => World.thread_id(context, parent),
        "targetThreadId" => id,
        "sourcePoint" => %{"type" => "latest_stable"},
        "createdBy" => "user",
        "creationSource" => "web"
      })

    World.await_row(id, & &1)
    context = put_in(context, [:threads, fork], id)
    assert %{"status" => "completed"} = World.finish_turn(context, fork, "write fork.txt")
    start_waiting(context, fork)
  end

  step "the agent of {string} merges back into {string}", %{args: [caller, parent]} = context do
    result =
      World.mcp_tool(context, caller, "hal_c2_thread_merge_back", %{
        "targetThreadId" => World.thread_id(context, parent)
      })

    Map.put(context, :mcp_result, result)
  end

  step "a merge-back from {string} to {string} is pending", %{args: [fork, parent]} = context do
    assert {:ok, _} = context.mcp_result

    transfer =
      World.state(context, parent)
      |> StreamState.list("context-transfer")
      |> Enum.find(&(&1["type"] == "merge_back"))

    assert transfer["sourceThreadId"] == World.thread_id(context, fork)
    assert transfer["targetThreadId"] == World.thread_id(context, parent)
    assert transfer["status"] == "pending"
    context
  end

  # --- metadata, configuration and organization ------------------------------------

  step ~r/^the agent of "(?<caller>[^"]+)" updates "(?<thread>[^"]+)" with action "(?<action>[^"]+)"(?<rest> and no title| and no message| and no PR)?$/,
       %{args: args} = context do
    [caller, thread, action | rest] = args
    missing = List.first(rest) not in [nil, ""]

    context =
      case action do
        "regenerate_title" when not missing ->
          use_fake_text(context)
          assert %{"status" => "completed"} = World.finish_turn(context, thread, "say hello")
          context

        "unlink_pull_request" ->
          link(context, caller, thread)

        _ ->
          context
      end

    arguments =
      case {action, missing} do
        {"rename", false} -> %{"title" => "Renamed by agent"}
        {"link_pull_request", false} -> %{"pullRequest" => pull_request()}
        _ -> %{}
      end

    result =
      World.mcp_tool(
        context,
        caller,
        "hal_c2_thread_update",
        Map.merge(arguments, %{"threadId" => World.thread_id(context, thread), "action" => action})
      )

    Map.put(context, :mcp_result, result)
  end

  step ~r/^"(?<thread>[^"]+)" has the new title$/, %{args: [thread]} = context do
    assert {:ok, %{"title" => "Renamed by agent"}} = context.mcp_result
    World.await_row(World.thread_id(context, thread), &(&1["title"] == "Renamed by agent"))
    context
  end

  step ~r/^a title for "(?<thread>[^"]+)" is generated from its first message$/,
       %{args: [thread]} = context do
    assert {:ok, _} = context.mcp_result
    World.await_row(World.thread_id(context, thread), &(&1["title"] == "codex title"), 10_000)
    [call | _] = text_calls(context)
    assert call["prompt"] =~ "say hello"
    context
  end

  step ~r/^"(?<thread>[^"]+)" links the pull request in its project$/,
       %{args: [thread]} = context do
    assert {:ok, %{"linkedPullRequest" => linked}} = context.mcp_result
    assert linked["number"] == 12
    assert linked["projectId"] == World.project(context, "demo").id
    assert World.thread(context, thread)["linkedPullRequest"] == linked
    context
  end

  step ~r/^"(?<thread>[^"]+)" has no linked pull request$/, %{args: [thread]} = context do
    assert {:ok, %{"linkedPullRequest" => nil}} = context.mcp_result
    assert World.thread(context, thread)["linkedPullRequest"] == nil
    context
  end

  step ~r/^the agent of "(?<caller>[^"]+)" configures model "(?<model>[^"]+)" on (?<instance>its own instance|"claudeAgent")$/,
       %{args: [caller, model, instance]} = context do
    instance = if instance == "its own instance", do: "codex", else: "claudeAgent"

    result =
      World.mcp_tool(context, caller, "hal_c2_thread_configure", %{
        "modelSelection" => %{"instanceId" => instance, "model" => model}
      })

    context |> Map.put(:mcp_result, result) |> Map.put(:configured, {instance, model})
  end

  step "the caller's model selection changes", context do
    assert {:ok, _} = context.mcp_result
    {"codex", model} = context.configured

    World.await_state(context, "caller", fn state ->
      thread = StreamState.get(state, "thread")[World.thread_id(context, "caller")]
      thread["modelSelection"] == %{"instanceId" => "codex", "model" => model}
    end)

    context
  end

  step "the caller switches provider", context do
    assert {:ok, _} = context.mcp_result
    {"claudeAgent", model} = context.configured

    World.await_state(context, "caller", fn state ->
      thread = StreamState.get(state, "thread")[World.thread_id(context, "caller")]

      get_in(thread, ["modelSelection", "instanceId"]) == "claudeAgent" and
        get_in(thread, ["modelSelection", "model"]) == model
    end)

    context
  end

  step "the agent of {string} reads the configuration of {string}",
       %{args: [caller, thread]} = context do
    result =
      World.mcp_tool(context, caller, "hal_c2_thread_configuration", %{
        "threadId" => World.thread_id(context, thread)
      })

    Map.put(context, :mcp_result, result)
  end

  step "it receives the model selection, runtime mode and interaction mode of {string}",
       %{args: [thread]} = context do
    assert {:ok, result} = context.mcp_result
    entity = World.thread(context, thread)
    assert result["threadId"] == World.thread_id(context, thread)
    assert result["modelSelection"] == entity["modelSelection"]
    assert result["runtimeMode"] == entity["runtimeMode"]
    assert result["interactionMode"] == entity["interactionMode"]
    assert is_binary(result["runtimeMode"]) and is_binary(result["interactionMode"])
    context
  end

  step "the agent of {string} organizes {string} with action {string}",
       %{args: [caller, thread, action]} = context do
    id = World.thread_id(context, thread)

    # Undoing needs something to undo; marking unread needs a visit.
    before =
      case action do
        "unpin" -> "pin"
        "unsettle" -> "settle"
        "unsnooze" -> "snooze"
        "unarchive" -> "archive"
        _ -> nil
      end

    if before do
      assert {:ok, _} = organize(context, caller, thread, before)
      World.await_row(id, organized(before))
    end

    if action == "mark_unread" do
      {:ok, _} =
        HalC2.Orchestration.dispatch(%{
          "type" => "thread.visit",
          "commandId" => "cmd-visit-#{System.unique_integer([:positive])}",
          "threadId" => id,
          "visitedAt" => DateTime.utc_now() |> DateTime.to_iso8601()
        })

      World.await_row(id, &(&1["lastVisitedAt"] != nil))
    end

    result = organize(context, caller, thread, action)
    assert {:ok, _} = result
    # `"t2" is pinned` and `"t2" is archived` are also setup steps elsewhere, which
    # leave a pinned or archived thread as it is: the change is awaited here.
    World.await_row(id, organized(action))
    Map.put(context, :mcp_result, result)
  end

  step ~r/^"(?<thread>[^"]+)" is (?<result>unpinned|settled|unsettled|snoozed|not snoozed|unarchived|marked unread)$/,
       %{args: [thread, result]} = context do
    # In pull-request-links these arrange the state discovery and the sync
    # cadence then observe, rather than awaiting a tool's doing.
    if String.contains?(context[:file] || "", "pull-request-links") and
         result in ["settled", "unarchived"] do
      HalC2.Steps.Orchestration.PullRequestLinks.arrange_state(context, thread, result)
    else
      await_organized(context, thread, result)
    end
  end

  defp await_organized(context, thread, result) do
    action =
      case result do
        "unpinned" -> "unpin"
        "settled" -> "settle"
        "unsettled" -> "unsettle"
        "snoozed" -> "snooze"
        "not snoozed" -> "unsnooze"
        "unarchived" -> "unarchive"
        "marked unread" -> "mark_unread"
      end

    World.await_row(World.thread_id(context, thread), organized(action))
    context
  end

  step "the agent of {string} snoozes {string} without a time",
       %{args: [caller, thread]} = context do
    result =
      World.mcp_tool(context, caller, "hal_c2_thread_organize", %{
        "threadId" => World.thread_id(context, thread),
        "action" => "snooze"
      })

    Map.put(context, :mcp_result, result)
  end

  step "{string} has a pending merge-back from a fork", %{args: [thread]} = context do
    assert %{"status" => "completed"} = World.finish_turn(context, thread, "write base.txt")
    id = "th-fork-#{System.unique_integer([:positive])}"

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.fork",
        "commandId" => "cmd-fork-#{id}",
        "sourceThreadId" => World.thread_id(context, thread),
        "targetThreadId" => id,
        "sourcePoint" => %{"type" => "latest_stable"},
        "createdBy" => "user",
        "creationSource" => "web"
      })

    World.await_row(id, & &1)
    context = put_in(context, [:threads, "fork"], id)
    assert %{"status" => "completed"} = World.finish_turn(context, "fork", "write fork.txt")

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.merge_back",
        "commandId" => "cmd-merge-#{id}",
        "sourceThreadId" => id,
        "targetThreadId" => World.thread_id(context, thread),
        "sourcePoint" => %{"type" => "latest_stable"},
        "createdBy" => "user"
      })

    context
  end

  step "the agent of {string} lists the transfers of {string}",
       %{args: [caller, thread]} = context do
    result =
      World.mcp_tool(context, caller, "hal_c2_thread_transfers", %{
        "threadId" => World.thread_id(context, thread)
      })

    Map.put(context, :mcp_result, result)
  end

  step "it receives each transfer's id, source, target and status", context do
    assert {:ok, %{"transfers" => transfers}} = context.mcp_result
    fork = World.thread_id(context, "fork")
    t2 = World.thread_id(context, "t2")
    assert [_ | _] = transfers

    assert Enum.all?(
             transfers,
             &(Map.keys(&1) |> Enum.sort() == ~w(id sourceThreadId status targetThreadId))
           )

    assert Enum.any?(
             transfers,
             &(&1["sourceThreadId"] == fork and &1["targetThreadId"] == t2 and
                 &1["status"] == "pending")
           )

    context
  end

  # --- attachments -----------------------------------------------------------------

  step "the agent of {string} prepared an upload", %{args: [caller]} = context do
    prepare_upload(context, caller) |> upload()
  end

  step "it sends the uploaded attachment to {string} with a message",
       %{args: [thread]} = context do
    result =
      World.mcp_tool(context, context.uploader, "hal_c2_thread_send_attachments", %{
        "threadId" => World.thread_id(context, thread),
        "message" => "say see attached",
        "attachments" => [context.attachment]
      })

    Map.put(context, :mcp_result, result)
  end

  step "{string} receives the message with the attachment", %{args: [thread]} = context do
    assert {:ok, %{"messageId" => id}} = context.mcp_result
    message = StreamState.get(World.state(context, thread), "message")[id]
    assert message["text"] == "say see attached"
    assert message["senderThreadId"] == World.thread_id(context, context.uploader)
    assert [attachment] = message["attachments"]
    assert attachment["name"] == "notes.txt"
    assert File.exists?(HalC2.Attachments.path(attachment))
    context
  end

  step "the attachment belongs to a different thread", context do
    Map.put(context, :attachment, %{
      "type" => "file",
      "id" => "#{World.thread_id(context, "caller")}-notes",
      "name" => "notes.txt",
      "mimeType" => "text/plain",
      "sizeBytes" => 5
    })
  end

  step "the agent of {string} sends attachments to {string}",
       %{args: [caller, thread]} = context do
    context =
      if context[:attachment], do: context, else: prepare_upload(context, caller) |> upload()

    result =
      World.mcp_tool(context, caller, "hal_c2_thread_send_attachments", %{
        "threadId" => World.thread_id(context, thread),
        "message" => "say see attached",
        "attachments" => [context.attachment]
      })

    Map.put(context, :mcp_result, result)
  end

  step("the agent of {string} prepares an upload", %{args: [caller]} = context,
    do: prepare_upload(context, caller)
  )

  step "it receives where to upload it", context do
    assert {:ok, %{"attachmentId" => "pending-" <> _, "relativeUrl" => url, "expiresAt" => at}} =
             context.mcp_result

    assert "/api/attachments/upload/" <> _ = url
    assert is_integer(at)
    context
  end

  step "discarding the attachment removes it", context do
    context = upload(context)
    %{"id" => id} = context.attachment
    assert [_] = Path.wildcard(Path.join(attachments_dir(), id <> ".*"))

    assert {:ok, %{}} =
             World.mcp_tool(context, context.uploader, "hal_c2_attachment_discard", %{
               "attachmentId" => id
             })

    assert Path.wildcard(Path.join(attachments_dir(), id <> ".*")) == []
    context
  end

  # --- capabilities ----------------------------------------------------------------

  step(
    "the agent of {string} asks for the orchestrator's capabilities",
    %{args: [caller]} = context,
    do:
      Map.put(context, :mcp_result, World.mcp_tool(context, caller, "orchestrator_capabilities"))
  )

  step "it receives the caller's inherited provider, model and modes", context do
    assert {:ok, result} = context.mcp_result
    caller = World.thread(context, "caller")
    assert result["parentThreadId"] == World.thread_id(context, "caller")
    assert result["inheritedProviderInstanceId"] == "codex"
    assert result["inheritedModel"] == caller["modelSelection"]["model"]
    assert result["runtimeMode"] == "full-access"
    assert result["interactionMode"] == "default"
    context
  end

  step "each provider instance with its models, options and whether it can run a child task and why not",
       context do
    assert {:ok, %{"providers" => providers}} = context.mcp_result

    assert Enum.map(providers, & &1["providerInstanceId"]) ==
             Enum.map(HalC2.Environment.providers(), & &1["instanceId"])

    for provider <- providers do
      assert is_boolean(provider["canRunChildTask"])
      assert is_list(provider["constraints"])
      assert provider["canRunChildTask"] == (provider["constraints"] == [])
      assert Enum.all?(provider["models"], &is_binary(&1["id"]))
    end

    assert Enum.find(providers, &(&1["providerInstanceId"] == "codex"))["models"] != []
    context
  end

  step "that batches hold at most 20 threads", context do
    assert {:ok, %{"features" => %{"maxBatchThreads" => 20, "batchThreadCreation" => true}}} =
             context.mcp_result

    context
  end

  # --- backlog: environment, limits, settlement, attached and deleted threads -----

  step ~r/^the writing style has custom instructions of 5,000 characters$/, context do
    instructions = String.duplicate("Be brief. ", 500)
    assert String.length(instructions) == 5_000
    {settings, version} = HalC2.Settings.get()

    {:ok, _} =
      HalC2.Settings.put(
        Map.put(settings, "sourceControlWritingStyle", %{
          "mode" => "custom",
          "customInstructions" => instructions,
          "followChangeRequestTemplates" => true
        }),
        version
      )

    Map.put(context, :instructions, instructions)
  end

  step ~r/^the custom instructions arrive cut to 4,000 characters$/, context do
    assert {:ok, result} = context.mcp_result
    style = get_in(result, ["preferences", "sourceControlWritingStyle"])
    assert style["customInstructions"] == String.slice(context.instructions, 0, 4_000)
    Map.put(context, :style, style)
  end

  step "they are flagged as truncated", context do
    assert context.style["truncated"] == true
    context
  end

  # The credential a different environment issued: the caller's live credential,
  # restamped with another environment's id, as a token minted there would carry.
  step "a credential that was issued by another environment", context do
    %{authorization: "Bearer " <> token} =
      HalC2.Mcp.server(World.thread_id(context, "caller"), "codex")

    [{^token, caller, alive}] = :ets.lookup(HalC2.Mcp.Credentials, token)

    :ets.insert(
      HalC2.Mcp.Credentials,
      {token, %{caller | environment_id: "another-environment"}, alive}
    )

    Map.put(context, :foreign_caller, "caller")
  end

  step ~r/^its agent (?<action>reads the environment|updates the preferences)$/,
       %{args: [action]} = context do
    {tool, arguments} =
      case action do
        "reads the environment" ->
          {"hal_c2_environment_read", %{}}

        "updates the preferences" ->
          {"hal_c2_environment_preferences_update", %{"defaultThreadEnvMode" => "worktree"}}
      end

    Map.put(
      context,
      :mcp_result,
      World.mcp_tool(context, context.foreign_caller, tool, arguments)
    )
  end

  step "thread {string} works in worktree {string} on branch {string}",
       %{args: [thread, path, branch]} = context do
    context = World.patch_thread(context, thread, %{"worktreePath" => path, "branch" => branch})

    World.await_row(
      World.thread_id(context, thread),
      &(&1["worktreePath"] == path and &1["branch"] == branch)
    )

    context
  end

  step "the agent of {string} launches a thread in {string} without saying where it works",
       %{args: [caller, project]} = context do
    result =
      World.mcp_tool(context, caller, "hal_c2_thread_launch", %{
        "projectId" => World.project(context, project).id,
        "title" => "Rooted",
        "message" => "say rooted"
      })

    assert {:ok, %{"threadId" => id}} = result
    context |> Map.put(:mcp_result, result) |> put_in([:threads, "new"], id)
  end

  step "the new thread works in the project root with no worktree", context do
    thread = World.thread(context, "new")
    assert thread["worktreePath"] == nil
    context
  end

  step "it does not share the caller's worktree or branch", context do
    thread = World.thread(context, "new")
    caller = World.thread(context, "caller")
    assert caller["worktreePath"] == "/work/x"
    refute thread["worktreePath"] == caller["worktreePath"]
    refute thread["branch"] == caller["branch"]
    context
  end

  step ~r/^the agent of "(?<caller>[^"]+)" (?<request>launches a thread with a message of 120,001 characters|launches a thread with 9 attachments|sends 9 attachments to "t2"|sends no attachments to "t2"|sends attachments to "t2" with a message of 120,001 characters)$/,
       %{args: [caller, request]} = context do
    oversized = String.duplicate("x", 120_001)

    attachment = fn i ->
      %{
        "type" => "file",
        "id" => "pending-limit-#{i}",
        "name" => "n#{i}.txt",
        "mimeType" => "text/plain",
        "sizeBytes" => 1
      }
    end

    nine = Enum.map(1..9, attachment)
    t2 = World.thread_id(context, "t2")

    context =
      context
      |> Map.put(:threads_before, project_thread_ids(context))
      |> Map.put(
        :messages_before,
        length(StreamState.list(World.state(context, "t2"), "message"))
      )

    result =
      case request do
        "launches a thread with a message of 120,001 characters" ->
          World.mcp_tool(context, caller, "hal_c2_thread_launch", %{
            "title" => "Too long",
            "message" => oversized
          })

        "launches a thread with 9 attachments" ->
          World.mcp_tool(context, caller, "hal_c2_thread_launch", %{
            "title" => "Too many",
            "message" => "look",
            "attachments" => nine
          })

        ~s(sends 9 attachments to "t2") ->
          World.mcp_tool(context, caller, "hal_c2_thread_send_attachments", %{
            "threadId" => t2,
            "message" => "look",
            "attachments" => nine
          })

        ~s(sends no attachments to "t2") ->
          World.mcp_tool(context, caller, "hal_c2_thread_send_attachments", %{
            "threadId" => t2,
            "message" => "look",
            "attachments" => []
          })

        ~s(sends attachments to "t2" with a message of 120,001 characters) ->
          World.mcp_tool(context, caller, "hal_c2_thread_send_attachments", %{
            "threadId" => t2,
            "message" => oversized,
            "attachments" => [attachment.(1)]
          })
      end

    Map.put(context, :mcp_result, result)
  end

  step "the tool refuses the input as invalid", context do
    assert {:error, "invalid_request", _message} = context.mcp_result
    context
  end

  step "no thread is created and nothing is sent", context do
    assert project_thread_ids(context) == context.threads_before

    assert length(StreamState.list(World.state(context, "t2"), "message")) ==
             context.messages_before

    context
  end

  step "thread {string} has a settlement decision", %{args: [thread]} = context do
    id = World.thread_id(context, thread)

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.settle",
        "commandId" => "cmd-settle-#{System.unique_integer([:positive])}",
        "threadId" => id,
        "settledAt" => World.iso_from_now(0)
      })

    World.await_row(id, &(&1["settledOverride"] == "settled" and &1["settledAt"] != nil))
    context
  end

  step "the agent of {string} lists or reads {string}", %{args: [caller, thread]} = context do
    listed = World.mcp_tool(context, caller, "hal_c2_thread_list", %{})

    read =
      World.mcp_tool(context, caller, "hal_c2_thread_read", %{
        "threadId" => World.thread_id(context, thread)
      })

    context
    |> Map.put(:listed, listed)
    |> Map.put(:mcp_result, read)
    |> Map.put(:settled_thread, thread)
  end

  step "the response includes the settlement state of {string}", %{args: [thread]} = context do
    id = World.thread_id(context, thread)
    assert {:ok, %{"threads" => threads}} = context.listed
    listed = Enum.find(threads, &(&1["threadId"] == id))
    assert listed["settled"] == true
    assert is_binary(listed["settledAt"])
    assert {:ok, %{"thread" => read}} = context.mcp_result
    assert read["settled"] == true
    assert read["settledAt"] == listed["settledAt"]
    Map.merge(context, %{listed_item: listed, read_thread: read})
  end

  step "it says why {string} can or cannot settle", %{args: [_thread]} = context do
    for item <- [context.listed_item, context.read_thread] do
      assert item["canSettle"] == false
      assert item["settlementReason"] == "already settled"
    end

    context
  end

  step "the user attached thread {string} of another project to a message of {string}",
       %{args: [elsewhere, caller]} = context do
    context
    |> attachable_elsewhere(elsewhere)
    |> attach_as_context(caller, elsewhere, %{})
  end

  step "a message written by an agent of {string} carries a context record naming thread {string} of another project",
       %{args: [caller, elsewhere]} = context do
    context
    |> attachable_elsewhere(elsewhere)
    |> attach_as_context(caller, elsewhere, %{"createdBy" => "agent", "creationSource" => "mcp"})
  end

  step "it receives the thread's messages", context do
    assert {:ok, result} = context.mcp_result
    assert result["thread"]["threadId"] == World.thread_id(context, "elsewhere")
    assert Enum.any?(result["items"], &(&1["text"] == "say from elsewhere"))
    context
  end

  step "listing, sending to or interrupting {string} is still refused",
       %{args: [elsewhere]} = context do
    id = World.thread_id(context, elsewhere)

    assert {:ok, %{"threads" => threads}} =
             World.mcp_tool(context, "caller", "hal_c2_thread_list")

    refute id in Enum.map(threads, & &1["threadId"])

    assert {:error, "thread_not_found", _} =
             World.mcp_tool(context, "caller", "hal_c2_thread_send", %{
               "threadId" => id,
               "message" => "say hi"
             })

    assert {:error, "thread_not_found", _} =
             World.mcp_tool(context, "caller", "hal_c2_thread_interrupt", %{"threadId" => id})

    context
  end

  step "thread {string} was deleted", %{args: [thread]} = context do
    id = World.thread_id(context, thread)

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.delete",
        "commandId" => "cmd-delete-#{System.unique_integer([:positive])}",
        "threadId" => id
      })

    World.await_row(id, &(&1["deletedAt"] != nil))
    Map.put(context, :deleted_thread, thread)
  end

  step "the tool fails with code {string} saying {string}", %{args: [code, saying]} = context do
    # The saying names the scenario's thread; the tool names it by its id.
    [_, name] = Regex.run(~r/^Thread (\S+) is no longer available\.$/, saying)
    expected = "Thread #{World.thread_id(context, name)} is no longer available."
    assert {:error, ^code, ^expected} = context.mcp_result
    context
  end

  step "{string} has no turn running", %{args: [thread]} = context do
    refute Enum.any?(World.runs(context, thread), &(&1["status"] in @active))
    context
  end

  step "the agent names a run of {string} that already finished", %{args: [thread]} = context do
    assert %{"status" => "completed", "id" => run_id} =
             World.finish_turn(context, thread, "say finished")

    Map.merge(context, %{named_run: run_id, finished_thread: thread})
  end

  step ~r/^the answer's status is (?<status>interrupt_requested|no_active_run|that run's final status)$/,
       %{args: [status]} = context do
    assert {:ok, result} = context.mcp_result

    expected =
      case status do
        "that run's final status" ->
          World.runs(context, context.finished_thread)
          |> Enum.find(&(&1["id"] == context.named_run))
          |> Map.fetch!("status")

        other ->
          other
      end

    assert result["status"] == expected
    context
  end

  step "the agent of {string} sent {string} to {string} with request key {string}",
       %{args: [caller, text, thread, key]} = context do
    result =
      World.mcp_tool(context, caller, "hal_c2_thread_send", %{
        "threadId" => World.thread_id(context, thread),
        "message" => text,
        "clientRequestId" => key
      })

    assert {:ok, %{"messageId" => _}} = result
    Map.merge(context, %{sent_once: result, sent_text: text, sent_to: thread, sent_from: caller})
  end

  step "it repeats the send with request key {string}", %{args: [key]} = context do
    result =
      World.mcp_tool(context, context.sent_from, "hal_c2_thread_send", %{
        "threadId" => World.thread_id(context, context.sent_to),
        "message" => context.sent_text,
        "clientRequestId" => key
      })

    Map.put(context, :mcp_result, result)
  end

  step "{string} received the message once", %{args: [thread]} = context do
    assert {:ok, repeat} = context.mcp_result
    assert {:ok, first} = context.sent_once
    assert repeat["messageId"] == first["messageId"]

    delivered =
      World.state(context, thread)
      |> StreamState.list("message")
      |> Enum.filter(&(&1["text"] == context.sent_text))

    assert length(delivered) == 1
    context
  end

  step "the agent of {string} interrupted {string} with request key {string}",
       %{args: [caller, thread, key]} = context do
    context = start_waiting(context, thread)

    result =
      World.mcp_tool(context, caller, "hal_c2_thread_interrupt", %{
        "threadId" => World.thread_id(context, thread),
        "clientRequestId" => key
      })

    assert {:ok, %{"status" => "interrupt_requested", "runId" => run_id}} = result
    Map.merge(context, %{interrupted_run: run_id, interrupt_caller: caller})
  end

  step "it repeats the interrupt with request key {string}", %{args: [key]} = context do
    # The retry comes after the run has ended, as one after a lost response
    # would: only the first call's receipt can still answer it.
    run_id = context.interrupted_run

    World.await_state(context, "t2", fn state ->
      StreamState.get(state, "run")[run_id]["status"] == "interrupted"
    end)

    result =
      World.mcp_tool(context, context.interrupt_caller, "hal_c2_thread_interrupt", %{
        "threadId" => World.thread_id(context, "t2"),
        "clientRequestId" => key
      })

    Map.put(context, :mcp_result, result)
  end

  step "the agent of {string} sends {string} to {string} with request key {string}",
       %{args: [caller, text, thread, key]} = context do
    result =
      World.mcp_tool(context, caller, "hal_c2_thread_send", %{
        "threadId" => World.thread_id(context, thread),
        "message" => text,
        "clientRequestId" => key
      })

    Map.update(context, :keyed_sends, [{text, result}], &(&1 ++ [{text, result}]))
  end

  step "{string} received both messages", %{args: [thread]} = context do
    ids =
      for {_text, result} <- context.keyed_sends do
        assert {:ok, %{"messageId" => id}} = result
        id
      end

    assert length(Enum.uniq(ids)) == 2
    texts = Enum.map(StreamState.list(World.state(context, thread), "message"), & &1["text"])
    assert Enum.count(texts, &(&1 == "from caller")) == 1
    assert Enum.count(texts, &(&1 == "from other")) == 1
    context
  end

  step "the turn of {string} was interrupted once", %{args: [thread]} = context do
    # The retry was answered from the first call's receipt, naming its run.
    assert {:ok, %{"status" => "interrupt_requested", "runId" => run_id}} = context.mcp_result
    assert run_id == context.interrupted_run
    run_id = context.interrupted_run

    World.await_state(context, thread, fn state ->
      StreamState.get(state, "run")[run_id]["status"] == "interrupted"
    end)

    requests =
      World.state(context, thread)
      |> StreamState.list("turn-item")
      |> Enum.filter(&(&1["type"] == "run_interrupt_request" and &1["runId"] == run_id))

    assert length(requests) == 1

    transitions =
      Enum.filter(World.events(context, thread), fn event ->
        event.kind == "run" and event.entity == run_id and
          get_in(event.patch, ["s", "status"]) == "interrupted"
      end)

    assert length(transitions) == 1
    context
  end

  # A thread in another project with a message of its own, named for attachment.
  defp attachable_elsewhere(context, elsewhere) do
    context =
      context
      |> World.create_project("another")
      |> World.create_thread(elsewhere, "another")

    assert %{"status" => "completed"} =
             World.finish_turn(context, elsewhere, "say from elsewhere")

    context
  end

  # Sends a message to `caller` carrying a `thread` context record for
  # `elsewhere`; `fields` says who wrote it (the user by default).
  defp attach_as_context(context, caller, elsewhere, fields) do
    record = %{
      "contextId" => "ctx-elsewhere",
      "kind" => "thread",
      "threadId" => World.thread_id(context, elsewhere),
      "title" => elsewhere
    }

    fields = Map.put(fields, "context", %{"records" => [record]})

    context =
      World.send_turn(
        context,
        caller,
        "See [#{elsewhere}](hal-c2-context://v1/thread/ctx-elsewhere)",
        fields
      )

    World.await_state(context, caller, fn state ->
      Enum.any?(StreamState.list(state, "message"), fn message ->
        Enum.any?(
          get_in(message, ["context", "records"]) || [],
          &(&1["threadId"] == record["threadId"])
        )
      end)
    end)

    context
  end

  defp project_thread_ids(context) do
    project = World.project(context, "demo").id

    for {{_mc, id}, {"thread", row}} <- HalC2.Shell.rows(),
        row["projectId"] == project and row["deletedAt"] == nil,
        do: id
  end

  # --- helpers ---------------------------------------------------------------------

  # The MCP tools read the thread's sidebar row, so the turn counts once the row shows it.
  defp start_waiting(context, thread) do
    context = World.send_turn(context, thread, "wait for it")
    World.await_row(World.thread_id(context, thread), &(&1["activeRunId"] != nil))
    context
  end

  defp send_message(context, caller, thread, arguments) do
    context = Map.merge(context, %{sent_to: thread, runs_before: World.runs(context, thread)})

    result =
      World.mcp_tool(
        context,
        caller,
        "hal_c2_thread_send",
        Map.put(arguments, "threadId", World.thread_id(context, thread))
      )

    Map.put(context, :mcp_result, result)
  end

  defp create_threads(context, caller, threads, key) do
    result =
      World.mcp_tool(context, caller, "create_threads", %{
        "threads" => threads,
        "clientRequestId" => key
      })

    Map.put(context, :mcp_result, result)
  end

  defp prompt(n), do: "say " <> String.duplicate("a", n - 4)

  defp organize(context, caller, thread, action) do
    arguments =
      if action == "snooze",
        do: %{"snoozedUntil" => World.iso_from_now(3_600)},
        else: %{}

    World.mcp_tool(
      context,
      caller,
      "hal_c2_thread_organize",
      Map.merge(arguments, %{"threadId" => World.thread_id(context, thread), "action" => action})
    )
  end

  # How a thread's row shows an organize action.
  defp organized(action) do
    case action do
      "pin" -> &(&1["pinnedAt"] != nil)
      "unpin" -> &(&1["pinnedAt"] == nil)
      "settle" -> &(&1["settledAt"] != nil and &1["settledOverride"] == "settled")
      "unsettle" -> &(&1["settledAt"] == nil and &1["settledOverride"] == "active")
      "snooze" -> &(&1["snoozedUntil"] != nil)
      "unsnooze" -> &(&1["snoozedUntil"] == nil)
      "archive" -> &(&1["archivedAt"] != nil)
      "unarchive" -> &(&1["archivedAt"] == nil)
      "mark_unread" -> &(&1["lastVisitedAt"] == nil)
    end
  end

  defp pull_request,
    do: %{
      "repository" => "acme/demo",
      "number" => 12,
      "url" => "https://github.com/acme/demo/pull/12"
    }

  defp link(context, caller, thread) do
    assert {:ok, _} =
             World.mcp_tool(context, caller, "hal_c2_thread_update", %{
               "threadId" => World.thread_id(context, thread),
               "action" => "link_pull_request",
               "pullRequest" => pull_request()
             })

    context
  end

  defp use_fake_text(context) do
    log = Path.join(context.mc.home, "text-calls.jsonl")
    System.put_env("FAKE_TEXT_LOG", log)
    previous = Application.get_env(:hal_c2, :text_codex_command)
    Application.put_env(:hal_c2, :text_codex_command, @fake_text)

    ExUnit.Callbacks.on_exit(fn ->
      System.delete_env("FAKE_TEXT_LOG")
      restore_app_env(:text_codex_command, previous)
    end)

    context
  end

  defp text_calls(context) do
    case File.read(Path.join(context.mc.home, "text-calls.jsonl")) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      {:error, :enoent} -> []
    end
  end

  # OpenCode (the fake ACP agent) asks for a sign-in that never happened, so the
  # provider list reports it signed out.
  defp signed_out_agent(context) do
    {settings, version} = HalC2.Settings.get()

    instances = %{
      "opencode" => %{
        "driver" => "opencode",
        "enabled" => true,
        "environment" => [
          %{"name" => "FAKE_AUTH_FILE", "value" => Path.join(context.mc.home, "signed-in")}
        ]
      }
    }

    {:ok, _} = HalC2.Settings.put(Map.put(settings, "providerInstances", instances), version)
    :ok = HalC2.Settings.watch(self())
    HalC2.Acp.forget("opencode")
    HalC2.Acp.entry("opencode")
    await_signed_out("opencode")
  end

  defp await_signed_out(instance) do
    if get_in(HalC2.Acp.entry(instance), ["auth", "status"]) == "unauthenticated" do
      :ok
    else
      assert_receive {:hal_c2_providers_changed, _}, 5_000
      await_signed_out(instance)
    end
  end

  defp prepare_upload(context, caller) do
    result =
      World.mcp_tool(context, caller, "hal_c2_attachment_prepare_upload", %{
        "upload" => %{
          "type" => "file",
          "name" => "notes.txt",
          "mimeType" => "text/plain",
          "sizeBytes" => 5
        }
      })

    context |> Map.put(:mcp_result, result) |> Map.put(:uploader, caller)
  end

  # Uploads the prepared attachment's bytes, as a client would to its URL.
  defp upload(context) do
    {:ok, %{"attachmentId" => id, "relativeUrl" => "/api/attachments/upload/" <> token}} =
      context.mcp_result

    :ok = HalC2.Attachments.store(token, "hello")

    Map.put(context, :attachment, %{
      "type" => "file",
      "id" => id,
      "name" => "notes.txt",
      "mimeType" => "text/plain",
      "sizeBytes" => 5
    })
  end

  defp attachments_dir, do: Path.join(Application.fetch_env!(:hal_c2, :home), "attachments")

  # Puts an app env key back as it was; one that was unset stays unset (a nil value
  # would override `Application.get_env/3` defaults in later scenarios).
  defp restore_app_env(key, nil), do: Application.delete_env(:hal_c2, key)
  defp restore_app_env(key, value), do: Application.put_env(:hal_c2, key, value)
end
