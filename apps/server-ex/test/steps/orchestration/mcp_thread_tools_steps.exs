defmodule HalC2.Steps.Orchestration.McpThreadTools do
  @moduledoc """
  Steps for `features/node/orchestration/mcp-thread-tools.feature`, and the MCP
  caller setup and failure steps the other MCP features share.

  MCP tool calls keep their outcome in `context.mcp_result`: `{:ok, result}` or
  `{:error, code, message}` (see `HalC2.Test.Node.World.mcp_tool/5`). Turns run on the
  fake Codex CLI: "wait" keeps one running, steering it with "say X" ends it.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.StreamState
  alias HalC2.Test.Node.World

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
    do: Map.put(context, :mcp_result, World.mcp_tool(context, caller, "halc2_thread_list"))
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

    result = World.mcp_tool(context, caller, "halc2_thread_list", arguments)
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
      World.mcp_tool(context, caller, "halc2_thread_read", %{
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
      World.mcp_tool(context, caller, "halc2_thread_read", %{
        "threadId" => World.thread_id(context, thread)
      })

    result =
      World.mcp_tool(context, caller, "halc2_thread_read", %{
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
      World.mcp_tool(context, caller, "halc2_thread_read", %{
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
             World.mcp_tool(context, context.reader, "halc2_thread_read", %{
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
    do: Map.put(context, :mcp_result, World.mcp_tool(context, caller, "halc2_thread_read"))
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
        World.mcp_tool(context, caller, "halc2_thread_wait", %{"threadId" => id})
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
      World.mcp_tool(context, caller, "halc2_thread_wait", %{
        "threadId" => World.thread_id(context, thread),
        "timeoutMs" => 1_000
      })

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
    result = World.mcp_tool(context, caller, "halc2_thread_wait", arguments)

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
      World.mcp_tool(context, caller, "halc2_thread_wait", %{
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
    result =
      World.mcp_tool(context, caller, "halc2_thread_interrupt", %{
        "threadId" => World.thread_id(context, thread)
      })

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
    result = World.mcp_tool(context, caller, "halc2_thread_search", %{"query" => word})
    Map.put(context, :mcp_result, result)
  end

  step "only matches in {string} are returned", %{args: [project]} = context do
    assert {:ok, %{"matches" => matches}} = context.mcp_result
    assert Enum.map(matches, & &1["threadId"]) == [World.thread_id(context, "local mention")]
    assert Enum.all?(matches, &(&1["projectId"] == World.project(context, project).id))
    context
  end

  step("the agent of {string} reads the environment", %{args: [caller]} = context,
    do: Map.put(context, :mcp_result, World.mcp_tool(context, caller, "halc2_environment_read"))
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
      World.mcp_tool(context, caller, "halc2_environment_preferences_update", %{
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
      World.mcp_tool(context, caller, "halc2_thread_launch", %{
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
      World.mcp_tool(context, caller, "halc2_thread_launch", %{
        "title" => "With attachment",
        "message" => "look",
        "attachments" => [attachment]
      })

    Map.put(context, :mcp_result, result)
  end

  step "the agent of {string} launches a thread in project {string}",
       %{args: [caller, project]} = context do
    result =
      World.mcp_tool(context, caller, "halc2_thread_launch", %{
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
    create_threads(
      context,
      context.batch_caller,
      [%{"prompt" => "say one"}, %{"prompt" => "say two"}],
      key
    )
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
      for {{_node, id}, {"thread", _row}} <- HalC2.Shell.rows(),
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

    refute Enum.any?(HalC2.Shell.rows(), fn {{_node, id}, {kind, _row}} ->
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
    result = World.mcp_tool(context, caller, "halc2_thread_fork", %{"title" => "Agent fork"})
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
      World.mcp_tool(context, caller, "halc2_thread_merge_back", %{
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
        "halc2_thread_update",
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
      World.mcp_tool(context, caller, "halc2_thread_configure", %{
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
      World.mcp_tool(context, caller, "halc2_thread_configuration", %{
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
      World.mcp_tool(context, caller, "halc2_thread_organize", %{
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
      World.mcp_tool(context, caller, "halc2_thread_transfers", %{
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
      World.mcp_tool(context, context.uploader, "halc2_thread_send_attachments", %{
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
      World.mcp_tool(context, caller, "halc2_thread_send_attachments", %{
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
             World.mcp_tool(context, context.uploader, "halc2_attachment_discard", %{
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
        "halc2_thread_send",
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
      "halc2_thread_organize",
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
             World.mcp_tool(context, caller, "halc2_thread_update", %{
               "threadId" => World.thread_id(context, thread),
               "action" => "link_pull_request",
               "pullRequest" => pull_request()
             })

    context
  end

  defp use_fake_text(context) do
    log = Path.join(context.node.home, "text-calls.jsonl")
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
    case File.read(Path.join(context.node.home, "text-calls.jsonl")) do
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
          %{"name" => "FAKE_AUTH_FILE", "value" => Path.join(context.node.home, "signed-in")}
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
      assert_receive {:halc2_providers_changed, _}, 5_000
      await_signed_out(instance)
    end
  end

  defp prepare_upload(context, caller) do
    result =
      World.mcp_tool(context, caller, "halc2_attachment_prepare_upload", %{
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
