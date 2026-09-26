defmodule HalC2.Steps.Orchestration.RecoveryAndIdleSessions do
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Orchestration.IdleSessions
  alias HalC2.Test.Node
  alias HalC2.Test.Node.World

  # Turns run on the fake Codex (`World.providers/1`). A turn "cut off" by a stop has
  # its provider process killed first, as provider processes die with the node.
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

  step ~r/^thread "(?<thread>[^"]+)" (?:had a running turn|was mid-turn when the node stopped|was mid-turn on a provider conversation that can resume)$/,
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

  step "thread {string} was idle and thread {string} was running when the node stopped",
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

  step "the node restarts and a client connects", context do
    context = %{context | node: Node.restart(context.node), clients: %{}}
    client = Node.sub(World.client(context), 900, %{"type" => "shell"})
    {frame, client} = Node.await(client, &(&1["t"] == "shell"))

    context
    |> World.put_client(client)
    |> Map.put(:shell, frame)
  end

  step "the client never sees {string} as running", %{args: [thread]} = context do
    id = World.thread_id(context, thread)
    # The first rows the client gets already show the turn settled.
    assert [row] = for([_node, ^id, "thread", row] <- context.shell["rows"], do: row)
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

  step "the node checks for idle sessions", context do
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
    assert [{pid, _}] = Registry.lookup(HalC2.Codex.Registry, World.thread_id(context, thread))
    assert pid == context.runtime
    context
  end

  step "it is released once 4 hours pass without activity", context do
    context = context |> backdate(context.thread, 4 * 60) |> check()
    assert_released(context, context.thread)
  end

  step "the provider starts again and resumes its conversation", context do
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    assert %{"ordinal" => 2} = World.await_latest_run(context, context.thread, "completed")
    assert [%{"threadId" => "native-thread-1"}] = World.codex_requests(context, "thread/resume")
    assert [%{"status" => "ready"}] = World.entities(context, context.thread, "provider-session")
    context
  end

  # --- helpers -----------------------------------------------------------------------

  defp item(type, id, fields), do: %{"item" => Map.merge(%{"type" => type, "id" => id}, fields)}

  # Kills the thread's Codex process, as a node stop does, so nothing settles the turn.
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
    Node.ensure(IdleSessions)
    Map.put(context, :released, IdleSessions.check())
  end

  defp assert_released(context, thread) do
    id = World.thread_id(context, thread)
    if released = context[:released], do: assert(id in released)
    pid = context.runtime
    assert_receive {:DOWN, _, :process, ^pid, _}
    assert Registry.lookup(HalC2.Codex.Registry, id) == []
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
