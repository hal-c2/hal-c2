defmodule HalC2.Steps.Orchestration.RecoveryAndIdleSessions do
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Orchestration.IdleSessions
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  # Turns run on the fake Codex (`World.providers/1`). A turn "cut off" by a stop has
  # its provider process killed first, as provider processes die with the MC.
  # "No activity for N minutes" moves the thread's timestamps N minutes back.

  @continuation "Continue where you left off."
  @started ~w(starting running waiting completed)

  # --- turns cut off by a restart ------------------------------------------------------

  step "thread {string} had a running turn with a streaming answer and a running command",
       %{args: [thread]} = context do
    context = World.running_turn(context, thread)

    context
    |> World.codex_notify(thread, "item/started", item("agentMessage", "msg-a", %{"text" => ""}))
    |> World.codex_notify(thread, "item/agentMessage/delta", %{
      "itemId" => "msg-a",
      "delta" => "Half.\n\n"
    })
    |> World.codex_notify(
      thread,
      "item/started",
      item("commandExecution", "cmd-a", %{"command" => "sleep"})
    )

    World.await_state(context, thread, fn state ->
      match?(
        %{"streaming" => true, "text" => "Half.\n\n"},
        state.entities["message"]["message:codex:msg-a"]
      ) and
        state.entities["turn-item"]["turn-item:codex:cmd-a"]["status"] == "running"
    end)

    kill_provider(context, thread)
  end

  step ~r/^thread "(?<thread>[^"]+)" (?:had a running turn|was mid-turn when the MC stopped|was mid-turn on a provider conversation that can resume)$/,
       %{args: [thread]} = context do
    context = World.running_turn(context, thread)
    # The provider's conversation can resume: Codex named its native thread.
    World.await_state(context, thread, fn state ->
      Enum.any?(
        Map.values(state.entities["provider-thread"] || %{}),
        &is_map(&1["nativeThreadRef"])
      )
    end)

    context |> kill_provider(thread) |> Map.put(:cut_off, context.running)
  end

  step "thread {string} was idle and thread {string} was running when the MC stopped",
       %{args: [idle, running]} = context do
    context = idle_turn(context, idle)
    context = World.running_turn(context, running)
    kill_provider(context, running)
  end

  step "the run, its attempt, its provider turn and its nodes are interrupted", context do
    state = World.state(context, context.thread)
    run = state.entities["run"][context.running]
    assert %{"status" => "interrupted", "completedAt" => completed} = run
    assert is_binary(completed)

    for kind <- ~w(run-attempt provider-turn node) do
      entities = HalC2.StreamState.list(state, kind)
      assert entities != [], "no #{kind}"
      assert Enum.all?(entities, &(&1["status"] == "interrupted")), inspect({kind, entities})
    end

    assert state.entities["run-attempt"][run["activeAttemptId"]]["status"] == "interrupted"
    context
  end

  step "the running command item is interrupted", context do
    assert %{"status" => "interrupted"} =
             World.state(context, context.thread).entities["turn-item"]["turn-item:codex:cmd-a"]

    context
  end

  step "the answer stops streaming", context do
    state = World.state(context, context.thread)

    assert %{"streaming" => false, "text" => "Half.\n\n"} =
             state.entities["message"]["message:codex:msg-a"]

    context
  end

  step "the provider thread of {string} is idle", %{args: [thread]} = context do
    assert [%{"status" => "idle"}] = World.entities(context, thread, "provider-thread")
    context
  end

  step "the MC restarts and a client connects", context do
    context = %{context | mc: Mc.restart(context.mc), clients: %{}}
    client = Mc.sub(World.client(context), 900, %{"type" => "shell"})
    {frame, client} = Mc.await(client, &(&1["t"] == "shell"))

    context
    |> World.put_client(client)
    |> Map.put(:shell, frame)
  end

  step "the client never sees {string} as running", %{args: [thread]} = context do
    id = World.thread_id(context, thread)
    # The first rows the client gets already show the turn settled.
    assert [row] = for([_mc, ^id, "thread", row] <- context.shell["rows"], do: row)
    assert row["status"] == "interrupted"
    assert row["activeRunId"] == nil
    context
  end

  step "only {string} is settled", %{args: [thread]} = context do
    # The idle thread's stream was never opened at boot.
    for {title, _} <- context.threads, title != thread do
      assert Registry.lookup(HalC2.Streams.Registry, World.thread_id(context, title)) == []
    end

    assert %{"status" => "interrupted"} = World.latest_run(context, thread)
    context
  end

  # --- continuing after a restart ------------------------------------------------------

  step "project {string} continues threads after a server update", %{args: [project]} = context do
    continue_setting(context, project, true)
  end

  step "the project does not continue threads after an update", context do
    continue_setting(context, "demo", false)
  end

  step "a newer message was sent to {string} after that run", %{args: [thread]} = context do
    World.queue_message(context, thread, "Newer")
  end

  step "the run was waiting on the user rather than running", context do
    World.put_entity(context, context.thread, "run", context.running, %{
      "s" => %{"status" => "waiting"}
    })
  end

  step "the provider conversation has no native thread to resume", context do
    [provider_thread] = World.entities(context, context.thread, "provider-thread")

    World.put_entity(context, context.thread, "provider-thread", provider_thread["id"], %{
      "s" => %{"nativeThreadRef" => nil}
    })
  end

  step "{string} receives {string} from the server on the same model",
       %{args: [thread, text]} = context do
    message =
      Enum.find(World.entities(context, thread, "message"), &(&1["text"] == text)) ||
        flunk("no #{inspect(text)} in #{thread}")

    assert %{"role" => "user", "createdBy" => "agent", "creationSource" => "server"} = message
    runs = World.state(context, thread).entities["run"]
    assert runs[message["runId"]]["modelSelection"] == runs[context.cut_off]["modelSelection"]
    Map.put(context, :continuation, message["runId"])
  end

  step "it starts immediately", context do
    run_id = context.continuation

    state =
      World.await_state(context, context.thread, fn state ->
        state.entities["run"][run_id]["status"] in @started
      end)

    assert state.entities["run"][run_id]["queuePosition"] == nil

    assert Enum.any?(
             World.codex_requests(context, "turn/start"),
             &match?(%{"input" => [%{"text" => @continuation} | _]}, &1)
           )

    context
  end

  step "no continuation message is sent to {string}", %{args: [thread]} = context do
    refute Enum.any?(World.entities(context, thread, "message"), &(&1["text"] == @continuation))

    assert World.state(context, thread).entities["run"][context.cut_off]["status"] ==
             "interrupted"

    context
  end

  # --- a runtime crashing mid-turn ---------------------------------------------------------

  # A call no runtime handles crashes it, as a bug in any of its callbacks would.
  step "the runtime running the turn of {string} crashes", %{args: [thread]} = context do
    pid = runtime(context, thread)
    ref = Process.monitor(pid)
    catch_exit(GenServer.call(pid, :crash))
    assert_receive {:DOWN, ^ref, :process, _, {:function_clause, _}}
    context
  end

  # As a thread's deletion stops it, but with its turn still running.
  step "the runtime running the turn of {string} stops without ending it",
       %{args: [thread]} = context do
    :ok = GenServer.stop(runtime(context, thread), :shutdown)
    assert World.state(context, thread).entities["run"][context.running]["status"] == "running"
    context
  end

  step "the user stops {string}", %{args: [thread]} = context do
    {reply, context} =
      World.dispatch(context, %{
        "type" => "run.interrupt",
        "commandId" => "command:stop-#{thread}",
        "threadId" => World.thread_id(context, thread)
      })

    assert {:ok, _} = reply
    context
  end

  step "the run of {string} is interrupted", %{args: [thread]} = context do
    World.await_run(
      context,
      thread,
      &(&1["id"] == context.running and &1["status"] == "interrupted")
    )

    context
  end

  step "the run of {string} fails saying the session ended unexpectedly",
       %{args: [thread]} = context do
    World.await_run(context, thread, &(&1["id"] == context.running and &1["status"] == "failed"))

    assert Enum.any?(
             World.entities(context, thread, "provider-session"),
             &(&1["lastError"] =~ "session ended unexpectedly")
           )

    context
  end

  # --- idle sessions ---------------------------------------------------------------------

  step ~r/^thread "(?<thread>[^"]+)" has a live provider process and no activity for (?<n>\d+) (?<unit>minutes|hours)$/,
       %{args: [thread, n, unit]} = context do
    minutes = String.to_integer(n) * if(unit == "hours", do: 60, else: 1)
    context |> idle_turn(thread) |> backdate(thread, minutes)
  end

  step "thread {string} has background tasks running and no activity for 1 hour",
       %{args: [thread]} = context do
    context = idle_turn(context, thread)
    [provider_thread] = World.entities(context, thread, "provider-thread")

    context
    |> World.put_entity(thread, "provider-thread", provider_thread["id"], %{
      "s" => %{
        "pendingBackgroundTasks" => [
          %{"taskId" => "task-1", "taskType" => "local_bash", "description" => "Watch the build"}
        ]
      }
    })
    |> backdate(thread, 60)
    |> tap(
      &World.await_row(World.thread_id(&1, thread), fn row ->
        row["pendingBackgroundTasks"] != []
      end)
    )
  end

  # The fake Claude starts both on "in the background" (`test/support/fake_claude.py`);
  # what it reports after the turn is sent to the thread's runtime as if it came from
  # the CLI.
  step "thread {string} left a Claude subagent and a command running in the background",
       %{args: [thread]} = context do
    background_turn(context, thread)
  end

  step "thread {string} had a Claude subagent and a command running in the background when the MC stopped",
       %{args: [thread]} = context do
    context = background_turn(context, thread)
    # Killed outright, as the MC's stop leaves no time to end the work.
    Process.exit(context.runtime, :kill)
    assert_receive {:DOWN, _, :process, _, :killed}
    assert length(World.row(context, thread)["pendingBackgroundTasks"]) == 2
    context
  end

  step "thread {string} finished a Claude turn", %{args: [thread]} = context do
    context = context |> World.providers() |> World.named_thread(thread)
    claude = %{"modelSelection" => %{"instanceId" => "claudeAgent", "model" => "sonnet"}}
    context = World.dispatch_message(context, thread, "Hi", claude)
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    World.await_run(context, thread, &(&1["status"] == "completed"))
    pid = runtime(context, thread)
    Process.monitor(pid)
    Map.put(context, :runtime, pid)
  end

  # The turn a task notification wakes Claude for, which the MC did not run.
  step "Claude launches a subagent in the background between turns", context do
    claude_says(context, context.thread, %{
      "type" => "assistant",
      "message" => %{
        "id" => "m-wake",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "agent-wake",
            "name" => "Agent",
            "input" => %{"description" => "Check the tests", "run_in_background" => true}
          }
        ]
      }
    })

    claude_says(context, context.thread, %{
      "type" => "system",
      "subtype" => "task_started",
      "task_id" => "task-wake",
      "tool_use_id" => "agent-wake",
      "description" => "Check the tests",
      "task_type" => "local_agent",
      "is_backgrounded" => true
    })

    # The launch was a turn of Claude's own; it ends with its result.
    claude_says(context, context.thread, %{"type" => "result", "subtype" => "success"})
    await_background(context)
  end

  # A subagent resumed through SendMessage, or one started before the MC recorded them.
  step "Claude reports progress on a subagent it resumed between turns", context do
    claude_says(context, context.thread, %{
      "type" => "system",
      "subtype" => "task_progress",
      "task_id" => "task-wake",
      "tool_use_id" => "agent-wake",
      "description" => "Check the tests",
      "summary" => "Running mix test"
    })

    await_background(context)
  end

  step "{string} lists the subagent {string} as background work",
       %{args: [thread, title]} = context do
    assert [%{"taskType" => "subagent", "description" => ^title}] =
             World.row(context, thread)["pendingBackgroundTasks"]

    context
  end

  step "Claude reports that subagent completed", context do
    claude_says(
      context,
      context.thread,
      notification("task-wake", "agent-wake", "completed", "All green")
    )

    context
  end

  step "{string} has had no activity for {int} minutes", %{args: [thread, minutes]} = context do
    backdate(context, thread, minutes)
  end

  step "{string} lists the subagent and the command as background work",
       %{args: [thread]} = context do
    assert [
             %{
               "taskId" => "agent-2",
               "taskType" => "subagent",
               "description" => "Survey the repo"
             },
             %{
               "taskId" => "bash-2",
               "taskType" => "command_execution",
               "description" => "npm run build"
             }
           ] = Enum.sort_by(World.row(context, thread)["pendingBackgroundTasks"], & &1["taskId"])

    context
  end

  step "{string} lists no background work", %{args: [thread]} = context do
    World.await_row(World.thread_id(context, thread), &(&1["pendingBackgroundTasks"] == []))
    context
  end

  step ~r/^Claude reports the subagent completed with "(?<summary>[^"]+)" and the command stopped$/,
       %{args: [summary]} = context do
    claude_says(
      context,
      context.thread,
      notification("task-agent-2", "agent-2", "completed", summary)
    )

    claude_says(
      context,
      context.thread,
      notification("task-bash-2", "bash-2", "stopped", "Stopped")
    )

    World.await_row(
      World.thread_id(context, context.thread),
      &(&1["pendingBackgroundTasks"] == [])
    )

    context
  end

  step "the subagent of {string} is completed with {string}",
       %{args: [thread, summary]} = context do
    assert [%{"status" => "completed", "result" => ^summary, "origin" => "provider_native"}] =
             World.entities(context, thread, "subagent")

    context
  end

  step "the user rewinds {string} to its first run", %{args: [thread]} = context do
    id = World.thread_id(context, thread)
    scope = HalC2.Checkpoint.scope_id(id)

    {reply, context} =
      World.dispatch(context, %{
        "type" => "checkpoint.rollback",
        "threadId" => id,
        "scopeId" => scope,
        "checkpointId" => HalC2.Checkpoint.checkpoint_id(scope, 1),
        "restoreFiles" => false
      })

    assert {:ok, _} = reply
    context
  end

  step "the subagent and the command of {string} are interrupted", %{args: [thread]} = context do
    World.await_state(context, thread, fn state ->
      items = Map.values(state.entities["turn-item"] || %{})

      Enum.map(Map.values(state.entities["subagent"] || %{}), & &1["status"]) == ["interrupted"] and
        Enum.sort(
          for(
            item <- items,
            item["type"] in ["subagent", "command_execution"],
            item["nativeItemRef"]["nativeId"] in ["agent-2", "bash-2"],
            do: item["status"]
          )
        ) == ["interrupted", "interrupted"]
    end)

    context
  end

  # The fake Codex leaves "npm run dev" (cmd-bg, process 4275) running on "in the
  # background" (`test/support/fake_codex.py`); its exit is sent to the thread's runtime
  # as if the app-server reported it.
  step "thread {string} left a Codex command running in the background",
       %{args: [thread]} = context do
    context = idle_turn(context, thread)
    context = World.dispatch_message(context, thread, "Start the dev server in the background")
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    World.await_run(context, thread, &(&1["ordinal"] == 2 and &1["status"] == "completed"))
    await_background(context)
  end

  step "thread {string} has a Codex turn running a command in a terminal",
       %{args: [thread]} = context do
    context =
      context |> World.providers() |> World.named_thread(thread) |> Map.put(:thread, thread)

    context =
      World.dispatch_message(context, thread, "Start the dev server in the background and wait")

    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"

    World.await_state(context, thread, fn state ->
      Enum.any?(
        Map.values(state.entities["turn-item"] || %{}),
        &(&1["type"] == "command_execution")
      )
    end)

    context
  end

  step "{string} lists the command {string} as background work",
       %{args: [thread, command]} = context do
    assert [%{"taskType" => "command_execution", "description" => ^command}] =
             World.row(context, thread)["pendingBackgroundTasks"]

    context
  end

  step "Codex reports the command exited with {string}", %{args: [output]} = context do
    World.codex_notify(context, context.thread, "item/completed", %{
      "threadId" => "native-thread-1",
      "turnId" => "native-turn-2",
      "item" => %{
        "type" => "commandExecution",
        "id" => "cmd-bg",
        "command" => "npm run dev",
        "status" => "completed",
        "aggregatedOutput" => output,
        "exitCode" => 0
      }
    })

    World.await_row(
      World.thread_id(context, context.thread),
      &(&1["pendingBackgroundTasks"] == [])
    )

    # The exit wakes the thread with a turn of its own; steps go on once it has run.
    World.await_run(
      context,
      context.thread,
      &(&1["ordinal"] == 3 and &1["status"] == "completed")
    )

    World.await_row(World.thread_id(context, context.thread), &(&1["activeRunId"] == nil))
    context
  end

  step "{string} runs a turn telling Codex the background command finished",
       %{args: [thread]} = context do
    text = "The background command `npm run dev` exited with code 0."
    state = World.state(context, thread)

    # One new run, started by the MC for the agent, whose message Codex was sent.
    assert [%{"ordinal" => 1}, %{"ordinal" => 2}, %{"ordinal" => 3} = run] =
             Enum.sort_by(HalC2.StreamState.list(state, "run"), & &1["ordinal"])

    assert %{"status" => "completed", "providerInstanceId" => "codex"} = run

    assert %{
             "role" => "user",
             "text" => ^text,
             "createdBy" => "agent",
             "creationSource" => "provider"
           } = state.entities["message"][run["userMessageId"]]

    assert %{"threadId" => "native-thread-1", "input" => [%{"text" => ^text} | _]} =
             List.last(World.codex_requests(context, "turn/start"))

    # The command it reports is the one run 2 left behind, ended with its output.
    assert %{"status" => "completed", "output" => "bye", "runId" => left_by} =
             state.entities["turn-item"]["turn-item:codex:cmd-bg"]

    assert left_by != run["id"]
    context
  end

  # --- continuing after a restart ended background work ---------------------------------

  # The turn completed with its dev server still running; the provider process then
  # dies with the MC, with no time to end the command itself.
  step "thread {string} finished its turn and left a command running in the background",
       %{args: [thread]} = context do
    context = idle_turn(context, thread)
    context = World.dispatch_message(context, thread, "Start the dev server in the background")
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    run = World.await_run(context, thread, &(&1["ordinal"] == 2 and &1["status"] == "completed"))
    context = await_background(context)
    Process.exit(context.runtime, :kill)
    assert_receive {:DOWN, _, :process, _, :killed}
    assert length(World.row(context, thread)["pendingBackgroundTasks"]) == 1
    Map.put(context, :settled_run, run)
  end

  step "{string} receives one continuation turn", %{args: [thread]} = context do
    continuations =
      for %{"creationSource" => "server", "role" => "user"} = message <-
            World.entities(context, thread, "message"),
          do: message

    assert [%{"createdBy" => "agent", "runId" => run_id} = message] = continuations

    # A run of its own after the settled one, on the same model, sent to the provider.
    state =
      World.await_state(context, thread, &(&1.entities["run"][run_id]["status"] in @started))

    run = state.entities["run"][run_id]
    assert run["ordinal"] == context.settled_run["ordinal"] + 1
    assert run["modelSelection"] == context.settled_run["modelSelection"]

    assert World.state(context, thread).entities["run"][context.settled_run["id"]]["status"] ==
             "completed"

    Map.put(context, :continuation_message, message)
  end

  step "the continuation names the background command the restart ended", context do
    text = context.continuation_message["text"]
    assert text =~ "restarted"
    assert text =~ "`npm run dev`"

    # The command itself was ended as interrupted, and Codex was sent the message.
    assert %{"status" => "interrupted"} =
             World.state(context, context.thread).entities["turn-item"]["turn-item:codex:cmd-bg"]

    assert Enum.any?(
             World.codex_requests(context, "turn/start"),
             &match?(%{"input" => [%{"text" => ^text} | _]}, &1)
           )

    context
  end

  # --- native subagents ------------------------------------------------------------------

  # Claude's own subagent (its Agent tool), running in the background when the provider
  # process dies with the MC. Its work shows in a child thread of its own.
  step "a native provider subagent thread of {string} was running when the MC stopped",
       %{args: [thread]} = context do
    context = background_turn(context, thread)

    assert %{"status" => "running", "childThreadId" => child, "id" => id} =
             Enum.find(
               World.entities(context, thread, "subagent"),
               &(&1["origin"] == "provider_native")
             )

    World.await_row(child, &(&1["lineage"]["relationshipToParent"] == "subagent"))
    Process.exit(context.runtime, :kill)
    assert_receive {:DOWN, _, :process, _, :killed}

    context
    |> put_in([:threads, "subagent"], child)
    |> Map.merge(%{thread: thread, native_subagent: id})
  end

  step "the subagent thread is settled or interrupted", context do
    state = World.state(context, context.thread)
    id = context.native_subagent
    child = World.thread_id(context, "subagent")

    assert %{"status" => "interrupted", "completedAt" => at, "childThreadId" => ^child} =
             state.entities["subagent"][id]

    assert is_binary(at)
    assert %{"status" => "interrupted"} = state.entities["node"][id]
    assert %{"status" => "interrupted"} = state.entities["turn-item"]["turn-item:subagent:#{id}"]
    context
  end

  step "it is not left running", context do
    child = World.thread_id(context, "subagent")
    active = ~w(preparing queued starting running waiting pending)

    # Neither the child thread nor its parent shows work in progress to a client.
    for id <- [child, World.thread_id(context, context.thread)] do
      row = World.await_row(id, &(&1["pendingBackgroundTasks"] == []))
      assert row["activeRunId"] == nil
      refute row["status"] in active
      refute row["activityRunStatus"] in active
    end

    state = World.state(context, "subagent")

    for kind <- ~w(run node turn-item subagent), entity <- HalC2.StreamState.list(state, kind) do
      refute entity["status"] in active, "#{kind} #{entity["id"]} is #{entity["status"]}"
    end

    refute Enum.any?(HalC2.StreamState.list(state, "message"), &(&1["streaming"] == true))
    context
  end

  step "the Codex process of {string} exits", %{args: [thread]} = context do
    {_pid, state} = World.codex_runtime(context, thread)
    Process.exit(state.conn, :kill)
    context
  end

  step ~r/^the command of "(?<thread>[^"]+)" is (?<status>completed with "[^"]+"|interrupted|failed)$/,
       %{args: [thread, status]} = context do
    {status, output} =
      case Regex.run(~r/^completed with "(.+)"$/, status) do
        [_, output] -> {"completed", output}
        nil -> {status, nil}
      end

    World.await_state(context, thread, fn state ->
      Enum.any?(
        Map.values(state.entities["turn-item"] || %{}),
        &(&1["nativeItemRef"]["nativeId"] == "cmd-bg" and &1["status"] == status and
            (output == nil or &1["output"] == output))
      )
    end)

    context
  end

  step "Codex is asked to terminate the command's terminal", context do
    assert [%{"processId" => "4275"}] =
             World.codex_requests(context, "thread/backgroundTerminals/terminate")

    context
  end

  step "{string} has an active run", %{args: [thread]} = context do
    at = World.iso_from_now(-120 * 60_000)

    World.put_entity(context, thread, "run", "run-active", %{
      "s" => %{
        "id" => "run-active",
        "threadId" => World.thread_id(context, thread),
        "ordinal" => 2,
        "status" => "running",
        "requestedAt" => at,
        "startedAt" => at
      }
    })
    |> tap(
      &World.await_row(World.thread_id(&1, thread), fn row ->
        row["activeRunId"] == "run-active"
      end)
    )
  end

  step "{string} waits on an approval or question", %{args: [thread]} = context do
    World.put_entity(context, thread, "runtime-request", "request-1", %{
      "s" => %{
        "id" => "request-1",
        "threadId" => World.thread_id(context, thread),
        "kind" => "approval",
        "status" => "pending",
        "createdAt" => World.iso_from_now(-120 * 60_000)
      }
    })
    |> tap(
      &World.await_row(World.thread_id(&1, thread), fn row ->
        row["pendingRuntimeRequest"] != nil
      end)
    )
  end

  step "a provider process is live for a thread that was deleted", context do
    context
    |> idle_turn("t1")
    |> World.patch_thread("t1", %{"deletedAt" => World.iso_from_now(0)})
  end

  step "thread {string} became idle {int} minutes ago", %{args: [thread, minutes]} = context do
    context |> idle_turn(thread) |> backdate(thread, minutes)
  end

  step "the idle session of {string} was released", %{args: [thread]} = context do
    context = context |> idle_turn(thread) |> backdate(thread, 30)
    context = check(context)
    assert_released(context, thread)
  end

  step "the MC checks for idle sessions", context do
    check(context)
  end

  step "the provider process of {string} stops", %{args: [thread]} = context do
    assert_released(context, thread)
  end

  step "the provider process of {string} has been released", %{args: [thread]} = context do
    assert_released(context, thread)
    assert [%{"status" => "stopped"}] = World.entities(context, thread, "provider-session")
    context
  end

  step "that provider process stops", context do
    assert_released(context, context.thread)
  end

  step "its provider session is stopped", context do
    assert [%{"status" => "stopped"}] =
             World.entities(context, context.thread, "provider-session")

    context
  end

  step "the provider process of {string} keeps running", %{args: [thread]} = context do
    refute World.thread_id(context, thread) in context.released
    assert Process.alive?(context.runtime)
    assert runtime(context, thread) == context.runtime
    context
  end

  step "it is released once 4 hours pass without activity", context do
    context = context |> backdate(context.thread, 4 * 60) |> check()
    assert_released(context, context.thread)
  end

  # The idle check's release reaches the provider process just ahead of the message's
  # start: the process is held until both wait on it.
  step "the MC releases the session of {string} as the user sends {string} to {string}",
       %{args: [thread, text, thread]} = context do
    Mc.ensure(IdleSessions)
    pid = context.runtime
    test = self()
    :ok = :sys.suspend(pid)
    :erlang.trace(pid, true, [:receive])
    spawn(fn -> send(test, {:released, IdleSessions.check()}) end)
    assert_receive {:trace, ^pid, :receive, {:"$gen_call", _, :release}}
    message = World.message_command(context, thread, text)
    spawn(fn -> send(test, {:sent, World.command(%{}, message).reply}) end)
    assert_receive {:trace, ^pid, :receive, {:"$gen_call", _, {:start_turn, _}}}
    :erlang.trace(pid, false, [:receive])
    :ok = :sys.resume(pid)
    assert_receive {:released, released}
    assert World.thread_id(context, thread) in released
    assert_receive {:DOWN, _, :process, ^pid, {:shutdown, :released}}
    assert_receive {:sent, reply}
    Map.merge(context, %{released: released, reply: reply})
  end

  step "the provider starts again and resumes its conversation", context do
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    assert %{"ordinal" => 2} = World.await_latest_run(context, context.thread, "completed")
    assert [%{"threadId" => "native-thread-1"}] = World.codex_requests(context, "thread/resume")
    assert [%{"status" => "ready"}] = World.entities(context, context.thread, "provider-session")
    context
  end

  # --- limit recovery ------------------------------------------------------------------
  # The fake Claude stops on a usage limit resetting at the epoch its message names; the
  # recovery sweep (`HalC2.Orchestration.LimitRecovery`) runs with the clock a step names.

  step ~r/^the latest run of "(?<thread>[^"]+)" failed on a usage limit that resets at (?<time>\d{1,2}:\d{2})$/,
       %{args: [thread, time]} = context do
    reset = next_clock(time)

    context =
      context
      |> World.agents()
      |> World.create_thread(thread, nil, %{
        "modelSelection" => %{"instanceId" => "claudeAgent", "model" => "claude-haiku-4-5"}
      })

    {{:ok, _}, context} =
      World.send_message(context, thread, "usage limit until #{div(reset, 1000)}")

    World.await_runs(context, thread, ["failed"])
    World.await_row(World.thread_id(context, thread), &(&1["lastErrorClass"] == "usage_limit"))
    Map.merge(context, %{thread: thread, limit_reset: reset})
  end

  step "{string} records a limit recovery with auto-resume for that run and reset",
       %{args: [thread]} = context do
    row = World.row(context, thread)

    {{:ok, _}, context} =
      World.dispatch(context, %{
        "type" => "thread.metadata.update",
        "threadId" => row["id"],
        "limitRecovery" => %{
          "runId" => row["latestRunId"],
          "resetAt" => row["usageLimitResetAt"],
          "autoResume" => true
        }
      })

    World.await_row(row["id"], &(&1["limitRecovery"]["autoResume"] == true))
    Map.put(context, :failed_run, row["latestRunId"])
  end

  step ~r/^(?<time>\d{1,2}:\d{2}) passes$/, %{args: [time]} = context do
    at = next_clock(time)
    assert at == context.limit_reset
    # Nothing is sent a moment before the reset.
    assert resumes(context, context.thread, at - 1) == []
    Map.put(context, :resumed, resumes(context, context.thread, at))
  end

  step "the engine continues {string} once, without a new message from the user",
       %{args: [thread]} = context do
    run_id = context.failed_run
    assert [%{"usageLimitContinuationOfRunId" => ^run_id}] = context.resumed

    state =
      World.await_thread(context, thread, fn state ->
        state |> HalC2.StreamState.list("run") |> length() == 2
      end)

    # The continuation is the server's, not a message the user typed.
    assert [_first, %{"text" => @continuation}] =
             state
             |> HalC2.StreamState.list("message")
             |> Enum.filter(&(&1["role"] == "user"))
             |> Enum.sort_by(& &1["createdAt"])

    # A later sweep sends nothing more.
    assert resumes(context, thread, context.limit_reset + 60_000) == []
    context
  end

  # --- helpers -----------------------------------------------------------------------

  # The continuation messages a recovery sweep at `at` sends to the thread.
  defp resumes(context, thread, at) do
    id = World.thread_id(context, thread)

    for %{"type" => "message.dispatch", "threadId" => ^id} = command <-
          HalC2.Orchestration.LimitRecovery.sweep(at),
        do: command
  end

  # The next time the wall clock (UTC) shows `time`, at least a minute ahead.
  defp next_clock(time) do
    [hour, minute] = time |> String.split(":") |> Enum.map(&String.to_integer/1)

    today =
      Date.utc_today()
      |> DateTime.new!(Time.new!(hour, minute, 0))
      |> DateTime.to_unix(:millisecond)

    if today > System.system_time(:millisecond) + 60_000,
      do: today,
      else: today + 24 * 60 * 60 * 1_000
  end

  defp item(type, id, fields), do: %{"item" => Map.merge(%{"type" => type, "id" => id}, fields)}

  # Kills the thread's Codex process, as an MC stop does, so nothing settles the turn.
  defp runtime(context, thread) do
    id = World.thread_id(context, thread)

    [pid] =
      for registry <- [HalC2.Codex.Registry, HalC2.Claude.Registry, HalC2.Acp.Registry],
          {pid, _} <- Registry.lookup(registry, id),
          do: pid

    pid
  end

  defp kill_provider(context, thread) do
    {pid, _} = World.codex_runtime(context, thread)
    ref = Process.monitor(pid)
    :ok = DynamicSupervisor.terminate_child(HalC2.Codex.Supervisor, pid)
    assert_receive {:DOWN, ^ref, :process, _, _}
    Map.put(context, :thread, thread)
  end

  # A turn that completed, leaving its provider process live (`context.runtime`).
  defp idle_turn(context, thread) do
    context = World.providers(context)

    context =
      if (context[:threads] || %{})[thread],
        do: context,
        else: World.named_thread(context, thread)

    context = context |> Map.put(:thread, thread) |> World.dispatch_message(thread, "Hi")
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    World.await_latest_run(context, thread, "completed")
    World.await_row(World.thread_id(context, thread), &(&1["activeRunId"] == nil))
    {pid, _} = World.codex_runtime(context, thread)
    Process.monitor(pid)
    Map.put(context, :runtime, pid)
  end

  # Two turns on the fake Claude: "Hi", then one that leaves a subagent (agent-2) and a
  # command (bash-2) running in the background.
  defp background_turn(context, thread) do
    context = context |> World.providers() |> World.named_thread(thread)
    claude = %{"modelSelection" => %{"instanceId" => "claudeAgent", "model" => "sonnet"}}

    context =
      for {text, n} <- [{"Hi", 1}, {"Work in the background", 2}], reduce: context do
        context ->
          context = World.dispatch_message(context, thread, text, claude)
          assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
          World.await_run(context, thread, &(&1["ordinal"] == n and &1["status"] == "completed"))
          context
      end

    World.await_row(
      World.thread_id(context, thread),
      &(length(&1["pendingBackgroundTasks"] || []) == 2)
    )

    pid = runtime(context, thread)
    Process.monitor(pid)
    Map.put(context, :runtime, pid)
  end

  defp await_background(context) do
    World.await_row(
      World.thread_id(context, context.thread),
      &(length(&1["pendingBackgroundTasks"] || []) == 1)
    )

    context
  end

  defp claude_says(context, thread, message) do
    pid = runtime(context, thread)
    send(pid, {:claude, :sys.get_state(pid).session, {:message, message}})
  end

  defp notification(task_id, tool_id, status, summary),
    do: %{
      "type" => "system",
      "subtype" => "task_notification",
      "task_id" => task_id,
      "tool_use_id" => tool_id,
      "status" => status,
      "output_file" => "/tmp/#{task_id}.output",
      "summary" => summary
    }

  # Moves every activity timestamp of the thread `minutes` into the past.
  defp backdate(context, thread, minutes) do
    at = World.iso_from_now(-minutes * 60_000)
    id = World.thread_id(context, thread)
    state = World.state(context, thread)

    runs =
      for run <- HalC2.StreamState.list(state, "run"),
          fields =
            for(key <- ~w(requestedAt startedAt completedAt), run[key], into: %{}, do: {key, at}),
          do: {"run", run["id"], %{"s" => fields}}

    messages =
      for message <- HalC2.StreamState.list(state, "message"),
          do: {"message", message["id"], %{"s" => %{"createdAt" => at, "updatedAt" => at}}}

    {:ok, _} =
      HalC2.Streams.commit(
        id,
        :thread,
        [{"thread", id, %{"s" => %{"createdAt" => at}}}] ++ runs ++ messages
      )

    World.await_row(id, &(&1["createdAt"] == at))
    context
  end

  defp check(context) do
    Mc.ensure(IdleSessions)
    Map.put(context, :released, IdleSessions.check())
  end

  defp assert_released(context, thread) do
    id = World.thread_id(context, thread)
    if released = context[:released], do: assert(id in released)
    pid = context.runtime
    assert_receive {:DOWN, _, :process, ^pid, _}
    assert Registry.lookup(HalC2.Codex.Registry, id) == []
    assert Registry.lookup(HalC2.Claude.Registry, id) == []
    context
  end

  defp continue_setting(context, project, on?) do
    id = World.project(context, project).id

    context =
      World.update_settings(context, %{
        "projectSettingsOverrides" => %{id => %{"continueThreadsAfterServerUpdate" => on?}}
      })

    assert HalC2.Settings.for_project(id)["continueThreadsAfterServerUpdate"] == on?
    context
  end
end
