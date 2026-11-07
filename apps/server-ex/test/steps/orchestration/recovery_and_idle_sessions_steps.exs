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

  step ~r/^thread "(?<thread>[^"]+)" (?<when>had|has) a running turn with a running command$/,
       %{args: [thread, tense]} = context do
    context =
      context
      |> World.running_turn(thread)
      |> World.codex_notify(
        thread,
        "item/started",
        item("commandExecution", "cmd-a", %{"command" => "sleep"})
      )

    World.await_state(
      context,
      thread,
      &(&1.entities["turn-item"]["turn-item:codex:cmd-a"]["status"] == "running")
    )

    if tense == "had", do: kill_provider(context, thread), else: Map.put(context, :thread, thread)
  end

  # Stopped as the application stops: the runtimes first, then the service that settles
  # what they left (`Recovery.Shutdown`), while the streams are still up.
  step "the MC shuts down cleanly", context do
    ExUnit.Callbacks.start_supervised!(HalC2.Orchestration.Recovery.Shutdown)
    Map.put(context, :mc, Mc.stop(context.mc))
  end

  # The boot that follows finds nothing to settle, so what it reads the stop wrote.
  step "the run and the command are ended before the MC stops", context do
    context = %{context | mc: Mc.restart(context.mc), clients: %{}}
    state = World.state(context, context.thread)
    assert %{"status" => "interrupted"} = state.entities["run"][context.running]

    assert %{"status" => "interrupted"} =
             state.entities["turn-item"]["turn-item:codex:cmd-a"]

    context
  end

  step ~r/^the command says it was cancelled because the server (?<how>restarted|shut down) before the provider work completed$/,
       %{args: [how]} = context do
    assert World.state(context, context.thread).entities["turn-item"]["turn-item:codex:cmd-a"][
             "statusDetail"
           ] == "Cancelled because the server #{how} before the provider work completed."

    context
  end

  step ~r/^thread "(?<thread>[^"]+)" (?:had a running turn|was mid-turn(?: on "codex")? when the MC stopped|was mid-turn on a provider conversation that can resume)$/,
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

  # The provider's turn ended, and the MC stopped while it captured the run's checkpoint:
  # the capture's effect is still recorded as running.
  step "the provider turn of {string} had ended and its checkpoint was still to be captured when the MC stopped",
       %{args: [thread]} = context do
    context = World.running_turn(context, thread) |> kill_provider(thread)
    thread_id = World.thread_id(context, thread)
    run = World.state(context, thread).entities["run"][context.running]
    [session] = World.entities(context, thread, "provider-session")
    at = HalC2.Orchestration.Entities.now()
    id = "effect:checkpoint-#{System.unique_integer([:positive])}"

    HalC2.Store.put_meta(
      "effect:#{thread_id}:#{id}",
      JSON.encode!(%{
        "id" => id,
        "threadId" => thread_id,
        "type" => "checkpoint.capture",
        "lane" => "checkpoint",
        "status" => "running",
        "attempts" => 1,
        "delays" => [],
        "error" => nil,
        "args" => %{
          "cwd" => session["cwd"],
          "scopeId" => thread_id,
          "runOrdinal" => run["ordinal"],
          "runId" => run["id"],
          "rootNodeId" => run["rootNodeId"],
          "at" => at
        },
        "createdAt" => at,
        "updatedAt" => at
      })
    )

    context
  end

  step "the run is not ended as cut off", context do
    run = World.state(context, context.thread).entities["run"][context.running]
    refute run["status"] in ~w(interrupted failed), inspect(run)
    context
  end

  step "it completes once its checkpoint is captured", context do
    run =
      World.await_run(
        context,
        context.thread,
        &(&1["id"] == context.running and &1["status"] == "completed")
      )

    assert %{"checkpointId" => checkpoint} = run
    assert World.state(context, context.thread).entities["checkpoint"][checkpoint]
    World.await_row(World.thread_id(context, context.thread), &(&1["activeRunId"] == nil))
    context
  end

  step "{string} is now set to run on {string}", %{args: [thread, instance]} = context do
    model = if instance == "claudeAgent", do: "sonnet", else: "gpt-5.4"

    context =
      World.command(context, %{
        "type" => "thread.model-selection.set",
        "threadId" => World.thread_id(context, thread),
        "modelSelection" => %{"instanceId" => instance, "model" => model}
      })

    assert {:ok, _} = context.reply
    HalC2.Streams.flush_shell(World.thread_id(context, thread))
    context
  end

  # A first restart continues the cut-off turn; the MC stops again with the continuation
  # accepted but not yet sent to the provider, as it records a run in that moment.
  step "the continuation turn of {string} had not reached its provider when the MC stopped again",
       %{args: [thread]} = context do
    context = World.running_turn(context, thread) |> kill_provider(thread)
    context = %{context | mc: Mc.restart(context.mc), clients: %{}}

    message =
      Enum.find(World.entities(context, thread, "message"), &(&1["text"] == @continuation)) ||
        flunk("the first restart did not continue #{thread}")

    run =
      World.await_run(
        context,
        thread,
        &(&1["id"] == message["runId"] and &1["status"] in ~w(running waiting completed))
      )

    if Registry.lookup(HalC2.Codex.Registry, World.thread_id(context, thread)) != [],
      do: kill_provider(context, thread)

    World.put_entity(context, thread, "run", run["id"], %{
      "s" => %{"status" => "starting", "startedAt" => nil, "completedAt" => nil}
    })

    World.put_entity(context, thread, "run-attempt", run["activeAttemptId"], %{
      "s" => %{"status" => "pending", "providerTurnId" => nil, "completedAt" => nil}
    })

    context
    |> Map.put(:continuation, run["id"])
    |> Map.put(:sent, length(continuations_sent(context)))
  end

  step "{string} is continued from that turn", %{args: [thread]} = context do
    run_id = context.continuation

    World.await_run(
      context,
      thread,
      &(&1["id"] == run_id and &1["status"] in ~w(running waiting completed))
    )

    assert length(continuations_sent(context)) == context.sent + 1

    assert [_] =
             Enum.filter(
               World.entities(context, thread, "message"),
               &(&1["text"] == @continuation)
             )

    context
  end

  # A boot cut short after it asked runs its recovery again.
  step "the MC restarts and its recovery runs twice for {string}", %{args: [thread]} = context do
    context = %{context | mc: Mc.restart(context.mc), clients: %{}}
    run = World.state(context, thread).entities["run"][context.cut_off]
    thread_id = World.thread_id(context, thread)
    :persistent_term.put({HalC2.Orchestration.Recovery, :continuable}, [{thread_id, run}])
    :ok = HalC2.Orchestration.Recovery.continue()
    context
  end

  step "{string} receives one {string} message", %{args: [thread, text]} = context do
    assert [_] = Enum.filter(World.entities(context, thread, "message"), &(&1["text"] == text))
    context
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

    # "starting" is decided before the provider is asked; running is its answer.
    World.await_state(
      context,
      context.thread,
      &(&1.entities["run"][run_id]["status"] in ~w(running waiting completed))
    )

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

  # The stop reached Codex, which acknowledged it and went on; the MC died before the turn
  # ended, so only the stop's request item records that the user wanted it stopped.
  step ~r/^the user had asked to stop the running turn of "(?<thread>[^"]+)"(?<queue>, with a message queued behind it)?$/,
       %{args: [thread | queue]} = context do
    File.write!(Path.join(context.mc.home, "ignore-interrupt"), "")
    context = World.running_turn(context, thread)

    World.await_state(context, thread, fn state ->
      Enum.any?(
        Map.values(state.entities["provider-thread"] || %{}),
        &is_map(&1["nativeThreadRef"])
      )
    end)

    context =
      if List.first(queue) in [nil, ""],
        do: context,
        else: World.queue_message(context, thread, "Next")

    {reply, context} =
      World.dispatch(context, %{
        "type" => "run.interrupt",
        "commandId" => "command:stop-#{thread}",
        "threadId" => World.thread_id(context, thread)
      })

    assert {:ok, _} = reply
    stop = "turn-item:run:#{context.running}:signal:interrupt-request"
    World.await_state(context, thread, &(&1.entities["turn-item"][stop] != nil))
    assert World.state(context, thread).entities["run"][context.running]["status"] == "running"
    File.rm!(Path.join(context.mc.home, "ignore-interrupt"))
    context |> kill_provider(thread) |> Map.put(:cut_off, context.running)
  end

  # `continue/0` has run by the time the MC is back; whatever it enqueued has run after a drain.
  step "no continuation is asked of {string}", %{args: [thread]} = context do
    :ok = HalC2.Orchestration.Effects.drain(World.thread_id(context, thread))
    message = "message:restart-continuation:#{context.cut_off}"
    assert World.state(context, thread).entities["message"][message] == nil

    assert World.state(context, thread).entities["run"][context.cut_off]["status"] ==
             "interrupted"

    context
  end

  step "the message queued on {string} is held for the user", %{args: [thread]} = context do
    [queued] = context.queued
    run = World.state(context, thread).entities["run"][queued]
    assert %{"status" => "queued", "queueHeld" => true} = run
    assert World.runs(context, thread) |> Enum.filter(&(&1["status"] == "running")) == []
    context
  end

  # The effect a restart enqueues to continue a thread waits in its lane until released.
  step "the continuation a restart asks of the subagent waits to be sent", context do
    child = World.thread_id(context, "subagent")
    World.put_app_env(:effects_hook, {__MODULE__, :hold_continuation, [self(), child]})
    context
  end

  # The checks that settle a quiet child's task: the boot's, after `continue/0`, and the
  # periodic one.
  step "the task is {string} however often it is checked while the continuation waits",
       %{args: [status]} = context do
    child = World.thread_id(context, "subagent")
    assert_receive {:continuation_held, ^child, lane}, 5_000

    assert HalC2.Orchestration.Delegation.reconcile(
             World.thread_id(context, context.task_parent),
             false
           ) == 0

    :ok = HalC2.Orchestration.Delegation.settle_if_quiet(child)

    task =
      HalC2.StreamState.get(World.state(context, context.task_parent), "subagent")[
        context.task_id
      ]

    assert task["status"] == status
    Map.put(context, :held_lane, lane)
  end

  step "the continuation is sent", context do
    Application.delete_env(:hal_c2, :effects_hook)
    send(context.held_lane, :release_continuation)
    context
  end

  # --- provider processes an MC that died left running ------------------------------------

  # A stand-in provider whose `sleep` is a command it left in the background; it holds
  # stdout too, so end of file means both are gone. The MC "dies" by its record naming
  # an MC that is gone, as one from a VM that was killed does; the program itself keeps
  # running, owned by this test.
  step "a provider process with a command in the background was running when the MC died",
       context do
    {:ok, sub} =
      HalC2.Subprocess.start(["sh", "-c", ~s(sleep 60 & while read l; do echo "$l"; done)])

    mc_died(sub)
    Map.put(context, :orphan, sub)
  end

  # The command leaves the provider's process group (hal-c2/hal-c2#387); the provider
  # answers with its pid.
  step "a provider process with a command in a session of its own was running when the MC died",
       context do
    {:ok, sub} =
      HalC2.Subprocess.start([
        "sh",
        "-c",
        ~s(setsid sleep 60 & echo $!; while read l; do echo "$l"; done)
      ])

    assert_receive {:subprocess_lines, reader, [line]} when reader == sub.reader, 5_000
    mc_died(sub)
    context |> Map.put(:orphan, sub) |> Map.put(:left_command, String.to_integer(line))
  end

  # The provider stops on the MC's death, as on a closed stdin, and answers with the
  # pid of the command it leaves running in its group.
  step "a provider process had exited leaving a command in its group when the MC died",
       context do
    {:ok, sub} =
      HalC2.Subprocess.start(["sh", "-c", ~s(sleep 60 & while read l; do echo $!; exit 0; done)])

    pid = HalC2.Subprocess.os_pid(sub)
    mc_died(sub)
    :ok = HalC2.Subprocess.write_line(sub, "stop")
    assert_receive {:subprocess_lines, reader, [line]} when reader == sub.reader, 5_000
    await_exit(pid)
    Map.put(context, :left_command, String.to_integer(line))
  end

  # Only this service restarts, into a file where the state dir goes (the dir set aside
  # beside it), so the rest of the MC keeps a state dir it read at its own start.
  step "the MC restarted unable to make the directory of its program records", context do
    :ok = ExUnit.Callbacks.stop_supervised(HalC2.Subprocess.Orphans)
    state = Path.dirname(HalC2.Subprocess.Orphans.dir())
    File.rename!(state, state <> ".aside")
    File.write!(state, "")
    ExUnit.Callbacks.start_supervised!(HalC2.Subprocess.Orphans)
    context
  end

  step "a program start is refused", context do
    assert {:error, {:untracked, :no_records_dir}} =
             HalC2.Subprocess.start(["sh", "-c", "exit 0"])

    context
  end

  step "the directory of program records can be made again", context do
    state = Path.dirname(HalC2.Subprocess.Orphans.dir())
    File.rm!(state)
    File.rename!(state <> ".aside", state)
    context
  end

  step "a program starts", context do
    assert {:ok, sub} = HalC2.Subprocess.start(["sh", "-c", "exit 0"])
    HalC2.Subprocess.stop(sub)
    context
  end

  defp mc_died(sub) do
    pid = HalC2.Subprocess.os_pid(sub)
    dir = HalC2.Subprocess.Orphans.dir()

    [path] =
      for name <- File.ls!(dir),
          path = Path.join(dir, name),
          match?(%{"pid" => ^pid}, JSON.decode!(File.read!(path))),
          do: path

    record = JSON.decode!(File.read!(path))
    gone = Map.put(record["mc"], "started", "an earlier boot")
    File.write!(path, JSON.encode!(%{record | "mc" => gone}))
  end

  # Nothing tells this test an outside process exited; the bound is how long a failure waits.
  defp await_exit(pid, tries \\ 500) do
    cond do
      HalC2.Subprocess.Orphans.gone?(pid) ->
        :ok

      tries == 0 ->
        flunk("#{pid} did not exit")

      true ->
        Process.sleep(10)
        await_exit(pid, tries - 1)
    end
  end

  step "the provider process and its background command have been killed", context do
    with %{orphan: sub} <- context do
      exit_ref = sub.proc.exit_ref
      # Killed by SIGKILL.
      assert_receive {^exit_ref, {:ok, 137}}, 5_000
    end

    with %{left_command: command} <- context,
         do: assert(HalC2.Subprocess.Orphans.gone?(command))

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

  # The stop a client sends naming the run it saw, as a restart does.
  step "a client stops run {int} of {string}", %{args: [ordinal, thread]} = context do
    %{"id" => run_id} = Enum.find(World.runs(context, thread), &(&1["ordinal"] == ordinal))

    {reply, context} =
      World.dispatch(context, %{
        "type" => "run.interrupt",
        "threadId" => World.thread_id(context, thread),
        "runId" => run_id
      })

    Map.put(context, :reply, reply)
  end

  step "{string} ran its latest turn on Claude", %{args: [thread]} = context do
    claude = %{"modelSelection" => %{"instanceId" => "claudeAgent", "model" => "sonnet"}}
    context = World.dispatch_message(context, thread, "Hi", claude)
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    World.await_run(context, thread, &(&1["ordinal"] == 3 and &1["status"] == "completed"))
    context
  end

  step "{string} is running its latest turn on Claude", %{args: [thread]} = context do
    claude = %{"modelSelection" => %{"instanceId" => "claudeAgent", "model" => "sonnet"}}
    context = World.dispatch_message(context, thread, "wait for me", claude)
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    World.await_run(context, thread, &(&1["ordinal"] == 3 and &1["status"] == "running"))
    context
  end

  step "run {int} of {string} is interrupted", %{args: [ordinal, thread]} = context do
    World.await_run(
      context,
      thread,
      &(&1["ordinal"] == ordinal and &1["status"] == "interrupted")
    )

    context
  end

  step "the stop is refused", context do
    assert {:error, _, _} = context.reply
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
    text = "Background command completed (exit 0): npm run dev\n\nOutput tail:\nbye"
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

  step ~r/^thread "(?<thread>[^"]+)" left the Codex command "(?<command>[^"]+)" running in the background$/,
       %{args: [thread, command]} = context do
    context = idle_turn(context, thread)
    context = World.dispatch_message(context, thread, "Start the dev server in the background")
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    World.await_run(context, thread, &(&1["ordinal"] == 2 and &1["status"] == "completed"))
    context = await_background(context)

    assert [%{"description" => ^command}] = World.row(context, thread)["pendingBackgroundTasks"]
    context
  end

  step ~r/^Codex reports the command ended (?<ending>with exit code \d+|without an exit code)$/,
       %{args: [ending]} = context do
    item =
      case Regex.run(~r/\d+/, ending) do
        [code] -> %{"exitCode" => String.to_integer(code), "status" => "completed"}
        nil -> %{"status" => "failed"}
      end

    background_ends(context, Map.merge(%{"command" => "npm run dev"}, item))
  end

  step "the command ends after writing 5,000 characters of output", context do
    output = Enum.map_join(0..4_999, &Integer.to_string(rem(&1, 10)))
    command = "npm run dev -- " <> String.duplicate("--watch src ", 20)

    context
    |> background_ends(%{
      "command" => command,
      "status" => "completed",
      "exitCode" => 0,
      "aggregatedOutput" => output <> "\n"
    })
    |> Map.merge(%{output: output, long_command: command})
  end

  step "Codex reports the command ended twice", context do
    item = %{"command" => "npm run dev", "status" => "completed", "exitCode" => 0}
    context = background_ends(context, item)
    codex_item_completed(context, "cmd-bg", item)
    wakes_sent(context)
  end

  step ~r/^the wake of "(?<thread>[^"]+)" is marked (?<outcome>\w+) and reads "(?<summary>[^"]+)"$/,
       %{args: [thread, outcome, summary]} = context do
    assert %{
             "createdBy" => "agent",
             "notification" => %{
               "source" => %{"kind" => "background_command"},
               "outcome" => ^outcome,
               "summary" => ^summary,
               "detail" => "npm run dev"
             }
           } = wake_message(context, thread)

    context
  end

  step "its turn tells Codex {string}", %{args: [text]} = context do
    assert wake_message(context, context.thread)["text"] == text
    assert codex_told(context) == text
    context
  end

  step ~r/^Codex is told the command ended, followed by "Output tail:" and the last 1,000 characters$/,
       context do
    assert [_header, tail] = String.split(codex_told(context), "\n\nOutput tail:\n")
    assert tail == "..." <> String.slice(context.output, -1_000, 1_000)
    context
  end

  step ~r/^a command line longer than 200 characters is cut there and ends with "\.\.\."$/,
       context do
    assert [header, _tail] = String.split(codex_told(context), "\n\nOutput tail:\n")

    assert header ==
             "Background command completed (exit 0): " <>
               String.slice(context.long_command, 0, 200) <> "..."

    context
  end

  step "{string} runs one turn for it", %{args: [thread]} = context do
    assert [1, 2, 3] = World.runs(context, thread) |> Enum.map(& &1["ordinal"]) |> Enum.sort()
    context
  end

  # The fake Codex keeps a turn saying "wait" open, its command still running, until
  # the step ends it as the situation has it.
  step ~r/^thread "(?<thread>[^"]+)" has a Codex command (?<situation>still running inside its own turn|left running by .+)$/,
       %{args: [thread, situation]} = context do
    context =
      context |> World.providers() |> World.named_thread(thread) |> Map.put(:thread, thread)

    context =
      World.dispatch_message(context, thread, "Start the dev server in the background and wait")

    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    run = World.await_latest_run(context, thread, "running")

    World.await_state(
      context,
      thread,
      &match?(
        %{"status" => "running"},
        (&1.entities["turn-item"] || %{})["turn-item:codex:cmd-bg"]
      )
    )

    main = %{"threadId" => "native-thread-1", "turnId" => "native-turn-1"}
    ending = Map.put(main, "id", "cmd-bg")

    {context, ending} =
      case situation do
        "still running inside its own turn" ->
          {context, ending}

        "left running by a turn the user stopped" ->
          {reply, context} =
            World.dispatch(context, %{
              "type" => "run.interrupt",
              "threadId" => World.thread_id(context, thread)
            })

          assert {:ok, _} = reply

          World.await_run(
            context,
            thread,
            &(&1["id"] == run["id"] and &1["status"] == "interrupted")
          )

          {context, ending}

        "left running by a turn that failed" ->
          World.codex_notify(context, thread, "turn/completed", %{
            "threadId" => "native-thread-1",
            "turn" => %{
              "id" => "native-turn-1",
              "status" => "failed",
              "error" => %{"message" => "boom"}
            }
          })

          World.await_run(context, thread, &(&1["id"] == run["id"] and &1["status"] == "failed"))
          {context, ending}

        "left running by a subagent" ->
          child = %{"threadId" => "native-child-1", "turnId" => "native-child-turn-1"}

          World.codex_notify(context, thread, "item/started", %{
            "threadId" => "native-thread-1",
            "turnId" => "native-turn-1",
            "item" => %{
              "type" => "collabAgentToolCall",
              "id" => "collab-1",
              "tool" => "spawnAgent",
              "prompt" => "Start the tests",
              "senderThreadId" => "native-thread-1",
              "receiverThreadIds" => ["native-child-1"],
              "status" => "inProgress",
              "agentsStates" => %{}
            }
          })

          World.codex_notify(
            context,
            thread,
            "item/started",
            Map.put(child, "item", %{
              "type" => "commandExecution",
              "id" => "cmd-sub",
              "command" => "mix test --listen",
              "processId" => "4276",
              "status" => "inProgress"
            })
          )

          # The parent's own command ends inside its turn, which then completes.
          codex_item_completed(
            context,
            "cmd-bg",
            %{"command" => "npm run dev", "status" => "completed", "exitCode" => 0},
            "native-turn-1"
          )

          World.codex_notify(context, thread, "turn/completed", %{
            "threadId" => "native-thread-1",
            "turn" => %{"id" => "native-turn-1", "status" => "completed"}
          })

          World.await_run(
            context,
            thread,
            &(&1["id"] == run["id"] and &1["status"] == "completed")
          )

          {context, Map.put(child, "id", "cmd-sub")}
      end

    context
    |> Map.put(:ending, ending)
    |> Map.put(:runs_before, length(World.runs(context, thread)))
  end

  step "the command ends", context do
    {id, ending} = Map.pop(context.ending, "id")

    World.codex_notify(
      context,
      context.thread,
      "item/completed",
      Map.put(ending, "item", %{
        "type" => "commandExecution",
        "id" => id,
        "status" => "completed",
        "exitCode" => 0,
        "aggregatedOutput" => "done\n"
      })
    )

    wakes_sent(context)
  end

  step ~r/^no turn starts in "(?<thread>[^"]+)"(?: for it)?$/, %{args: [thread]} = context do
    runs = World.runs(context, thread)

    assert length(runs) == context.runs_before,
           "runs: #{inspect(Enum.map(runs, & &1["ordinal"]))}"

    assert agent_wakes(context, thread) == []

    context
  end

  step "the provider process of {string} does not exit when it is asked to",
       %{args: [thread]} = context do
    context = World.providers(context)
    File.write!(Path.join(World.project(context, "demo").root, "will-not-exit"), "")
    context = idle_turn(context, thread)
    {_, runtime} = World.codex_runtime(context, thread)
    Map.put(context, :os_pid, HalC2.JsonRpc.Connection.os_pid(runtime.conn))
  end

  step "the session of {string} is released", %{args: [thread]} = context do
    started = System.monotonic_time(:millisecond)
    assert :ok = HalC2.Orchestration.release_session(World.thread_id(context, thread))
    Map.put(context, :released_in, System.monotonic_time(:millisecond) - started)
  end

  step "the session is recorded as stopped after at most 30 seconds", context do
    assert context.released_in <= 30_000

    assert [%{"status" => "stopped"}] =
             World.entities(context, context.thread, "provider-session")

    # Stopped, and so is its process, which only a kill could end.
    await_exit(context.os_pid)
    File.rm!(Path.join(World.project(context, "demo").root, "will-not-exit"))
    context
  end

  step "the user stops {string} and Codex still lists the command's terminal after being asked to end it",
       %{args: [thread]} = context do
    cwd = World.thread(context, thread)["worktreePath"] || World.project(context, "demo").root
    File.write!(Path.join(cwd, "terminal-stays"), "")

    {reply, context} =
      World.dispatch(context, %{
        "type" => "run.interrupt",
        "threadId" => World.thread_id(context, thread)
      })

    Map.put(context, :reply, reply)
  end

  step "the stop fails saying the background terminal remained active after termination",
       context do
    assert {:error, message, _} = context.reply
    assert message == "Codex background terminal 4275 remained active after termination."

    # The command goes on, listed as it was.
    assert [%{"description" => "npm run dev"}] =
             World.row(context, context.thread)["pendingBackgroundTasks"]

    assert %{"status" => "running"} =
             World.state(context, context.thread).entities["turn-item"]["turn-item:codex:cmd-bg"]

    context
  end

  # --- waking a thread for finished background work --------------------------------------

  # Claude's subagent and command (`background_turn/2`) go on while the thread's latest
  # turn runs on Codex, which keeps a turn saying "wait" open until it is ended.
  step "thread {string} has a running turn and work left running in the background",
       %{args: [thread]} = context do
    context = context |> background_turn(thread) |> Map.put(:thread, thread)
    codex = %{"modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"}}
    context = World.dispatch_message(context, thread, "wait for it", codex)
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    run = World.await_run(context, thread, &(&1["ordinal"] == 3 and &1["status"] == "running"))
    Map.put(context, :running, run["id"])
  end

  step "thread {string} left work running in the background", %{args: [thread]} = context do
    context |> background_turn(thread) |> Map.put(:thread, thread)
  end

  step ~r/^thread "(?<thread>[^"]+)" left work running in the background and was then (?<state>archived|deleted)$/,
       %{args: [thread, state]} = context do
    context = context |> background_turn(thread) |> Map.put(:thread, thread)
    type = if state == "archived", do: "thread.archive", else: "thread.delete"

    {reply, context} =
      World.dispatch(context, %{"type" => type, "threadId" => World.thread_id(context, thread)})

    assert {:ok, _} = reply
    Map.put(context, :runs_before, length(World.runs(context, thread)))
  end

  step "the provider reports the background work finished", context do
    background_finishes(context)
  end

  step "the work finishes", context do
    # A thread whose deletion stopped its provider has nothing left to report.
    if Registry.lookup(HalC2.Claude.Registry, World.thread_id(context, context.thread)) != [],
      do: background_finishes(context)

    :ok = HalC2.Orchestration.Wake.drain()
    context
  end

  step "the work finishes and the wake cannot be delivered at first", context do
    tries = :ets.new(:wake_tries, [:public, :ordered_set])
    Application.put_env(:hal_c2, :wake_hook, {__MODULE__, :refuse_first_wake, [tries]})
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :wake_hook) end)
    context = background_finishes(context)
    :ok = HalC2.Orchestration.Wake.drain()
    Map.put(context, :wake_tries, tries)
  end

  @doc false
  # The wake hook: refuses the first try, and records when each came.
  def refuse_first_wake(tries, _command) do
    :ets.insert(tries, {System.unique_integer([:monotonic]), System.monotonic_time(:millisecond)})
    if :ets.info(tries, :size) == 1, do: {:error, "not yet"}, else: :ok
  end

  step "{string} gets one message from the agent reading {string}",
       %{args: [thread, text]} = context do
    wakes = agent_wakes(context, thread)
    assert [%{"text" => ^text, "runId" => run_id}] = wakes
    Map.put(context, :wake_run, run_id)
  end

  step "it runs after the running turn", context do
    thread = context.thread

    # Queued while the Codex turn runs; Codex ends it, and the wake's run follows.
    assert %{"status" => "queued"} =
             Enum.find(World.runs(context, thread), &(&1["id"] == context.wake_run))

    World.codex_notify(context, thread, "turn/completed", %{
      "threadId" => "native-thread-1",
      "turn" => %{"id" => "native-turn-1", "status" => "completed"}
    })

    wake =
      World.await_run(
        context,
        thread,
        &(&1["id"] == context.wake_run and &1["status"] == "completed")
      )

    running = Enum.find(World.runs(context, thread), &(&1["id"] == context.running))
    assert %{"status" => "completed", "completedAt" => ended} = running
    assert wake["startedAt"] >= ended
    assert wake["modelSelection"]["instanceId"] == "claudeAgent"
    context
  end

  step ~r/^the MC tries again, waiting 100 milliseconds at first and never more than 5 seconds between tries$/,
       context do
    assert [{_, first}, {_, second}] = :ets.tab2list(context.wake_tries)
    assert second - first >= 100

    assert Enum.map(0..8, &HalC2.Orchestration.Wake.retry_delay/1) ==
             [100, 200, 400, 800, 1_600, 3_200, 5_000, 5_000, 5_000]

    context
  end

  step "{string} is woken once", %{args: [thread]} = context do
    assert [%{"runId" => run_id}] = agent_wakes(context, thread)
    World.await_run(context, thread, &(&1["id"] == run_id and &1["status"] == "completed"))
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
    assert text =~ "The server stopped, which ended the background command"
    assert text =~ "`npm run dev`"

    # The command itself was ended as interrupted, and Codex was sent the message.
    World.await_state(
      context,
      context.thread,
      &(&1.entities["run"][context.continuation_message["runId"]]["status"] in ~w(running waiting completed))
    )

    assert %{"status" => "interrupted"} =
             World.state(context, context.thread).entities["turn-item"]["turn-item:codex:cmd-bg"]

    assert Enum.any?(
             World.codex_requests(context, "turn/start"),
             &match?(%{"input" => [%{"text" => ^text} | _]}, &1)
           )

    context
  end

  # The fake Claude ends its turn with only that work running in the background; the
  # provider process then dies with the MC.
  step ~r/^thread "(?<thread>[^"]+)" ended its turn to wait on (?<work>a monitor|a subagent|a background task)$/,
       %{args: [thread, work]} = context do
    context = context |> World.providers() |> World.named_thread(thread)
    claude = %{"modelSelection" => %{"instanceId" => "claudeAgent", "model" => "sonnet"}}

    context =
      for {text, n} <- [{"Hi", 1}, {waiting_on(work), 2}], reduce: context do
        context ->
          context = World.dispatch_message(context, thread, text, claude)
          assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
          World.await_run(context, thread, &(&1["ordinal"] == n and &1["status"] == "completed"))
          context
      end

    run = World.await_run(context, thread, &(&1["ordinal"] == 2))

    context
    |> Map.put(:thread, thread)
    |> leave_waiting()
    |> Map.merge(%{settled_run: run, work: work})
  end

  # A Claude child of "parent"'s task, whose only turn ends that way.
  step ~r/^a task delegated to "(?<thread>[^"]+)" ended its turn to wait on (?<work>a monitor|a subagent|a background task)$/,
       %{args: [thread, work]} = context do
    input = %{
      "task" => waiting_on(work),
      "mode" => "async",
      "target" => %{"providerInstanceId" => "claudeAgent"}
    }

    assert {:ok, %{"taskId" => task_id}} =
             World.mcp_tool(context, "parent", "delegate_task", input, "codex")

    state = World.await_state(context, "parent", &HalC2.StreamState.get(&1, "subagent")[task_id])
    child = HalC2.StreamState.get(state, "subagent")[task_id]["childThreadId"]
    context = put_in(context, [:threads, thread], child)
    World.await_run(context, thread, &(&1["status"] == "completed"))

    context
    |> Map.merge(%{thread: thread, task_id: task_id, task_parent: "parent"})
    |> leave_waiting()
  end

  step ~r/^the continuation names (?<work>a monitor|a subagent|a background task) the restart ended$/,
       %{args: [work]} = context do
    text = context.continuation_message["text"]

    named = %{
      "a monitor" => ~s(waiting on: the monitor "Watch the dev log".),
      "a subagent" => ~s(waiting on: the subagent "Survey the repo".),
      "a background task" => "ended the background command `npm run build`."
    }

    assert text =~ "The server stopped, which "
    assert text =~ named[work]
    context
  end

  step "the task delegated to {string} ends {string}, not {string}",
       %{args: [_thread, status, _]} = context do
    state =
      World.await_state(
        context,
        context.task_parent,
        &(HalC2.StreamState.get(&1, "subagent")[context.task_id]["status"] not in ~w(pending running))
      )

    assert %{"status" => ^status} = HalC2.StreamState.get(state, "subagent")[context.task_id]
    context
  end

  # A Claude thread "t1" whose last turn completed with a subagent left running, whose
  # provider process died without ending it, and whose session the idle release stopped.
  step "a completed thread has leftover background tool or subagent records", context do
    context =
      context |> World.providers() |> World.log_claude_prompts() |> World.named_thread("t1")

    claude = %{"modelSelection" => %{"instanceId" => "claudeAgent", "model" => "sonnet"}}

    context =
      for {text, n} <- [{"Hi", 1}, {waiting_on("a subagent"), 2}], reduce: context do
        context ->
          context = World.dispatch_message(context, "t1", text, claude)
          assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
          World.await_run(context, "t1", &(&1["ordinal"] == n and &1["status"] == "completed"))
          context
      end

    context = context |> Map.put(:thread, "t1") |> leave_waiting()
    :ok = HalC2.Orchestration.release_session(World.thread_id(context, "t1"))
    Map.put(context, :claude, claude)
  end

  step "the thread is not woken", context do
    id = World.thread_id(context, "t1")
    :ok = HalC2.Orchestration.Effects.drain(id)
    state = World.state(context, "t1")

    assert Enum.map(HalC2.StreamState.list(state, "run"), & &1["ordinal"]) |> Enum.sort() == [
             1,
             2
           ]

    refute Enum.any?(
             Map.keys(state.entities["message"] || %{}),
             &String.starts_with?(&1, "message:restart-continuation:")
           )

    last = Enum.find(HalC2.StreamState.list(state, "run"), &(&1["ordinal"] == 2))

    background =
      for item <- HalC2.StreamState.list(state, "turn-item"),
          item["runId"] == last["id"],
          item["type"] in ~w(command_execution dynamic_tool subagent),
          do: item

    assert background != []
    assert Enum.all?(background, &(&1["status"] == "interrupted"))
    context
  end

  step "its background cleanup note reaches the provider once, on the next manual turn",
       context do
    before = length(World.claude_prompts(context))

    for {text, n} <- [{"Next", 3}, {"Again", 4}] do
      context = World.dispatch_message(context, "t1", text, context.claude)
      assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
      World.await_run(context, "t1", &(&1["ordinal"] == n and &1["status"] == "completed"))
    end

    [first, second] = context |> World.claude_prompts() |> Enum.drop(before)
    assert first =~ "<server_restart>"

    assert first =~
             ~s(ended the background work it had left running: the subagent "Survey the repo".)

    refute second =~ "<server_restart>"

    thread = World.state(context, "t1").entities["thread"][World.thread_id(context, "t1")]
    refute Map.has_key?(thread, "restartNote")
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

  step "the MC runs without automatic actions", context do
    Application.put_env(:hal_c2, :auto_actions, false)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :auto_actions) end)
    context
  end

  step "nothing is sent to {string}", %{args: [thread]} = context do
    assert context.resumed == []

    runs =
      context |> World.thread_id(thread) |> HalC2.Streams.state() |> HalC2.StreamState.list("run")

    assert length(runs) == 1
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

  defp codex_item_completed(context, id, item, turn \\ "native-turn-2") do
    World.codex_notify(context, context.thread, "item/completed", %{
      "threadId" => "native-thread-1",
      "turnId" => turn,
      "item" => Map.merge(%{"type" => "commandExecution", "id" => id}, item)
    })
  end

  # The background command cmd-bg ends as `item` has it; the wake it starts has run.
  defp background_ends(context, item) do
    codex_item_completed(context, "cmd-bg", item)

    World.await_row(
      World.thread_id(context, context.thread),
      &(&1["pendingBackgroundTasks"] == [])
    )

    World.await_run(
      context,
      context.thread,
      &(&1["ordinal"] == 3 and &1["status"] == "completed")
    )

    World.await_row(World.thread_id(context, context.thread), &(&1["activeRunId"] == nil))
    context
  end

  # Once the runtime has handled what it was sent, every wake it started is sent or
  # dropped, and a run one started has ended.
  defp wakes_sent(context) do
    :sys.get_state(runtime(context, context.thread))
    :ok = HalC2.Orchestration.Wake.drain()
    World.await_row(World.thread_id(context, context.thread), &(&1["activeRunId"] == nil))
    context
  end

  defp wake_message(context, thread) do
    state = World.state(context, thread)
    run = Enum.find(HalC2.StreamState.list(state, "run"), &(&1["ordinal"] == 3))
    state.entities["message"][run["userMessageId"]]
  end

  defp codex_told(context) do
    %{"input" => [%{"text" => text} | _]} = List.last(World.codex_requests(context, "turn/start"))
    text
  end

  defp continuations_sent(context),
    do:
      Enum.filter(
        World.codex_requests(context, "turn/start"),
        &match?(%{"input" => [%{"text" => @continuation} | _]}, &1)
      )

  # Claude's subagent and command end, and Claude answers by itself between turns.
  defp background_finishes(context) do
    for {task, tool, status} <- [
          {"task-agent-2", "agent-2", "completed"},
          {"task-bash-2", "bash-2", "stopped"}
        ],
        do: claude_says(context, context.thread, notification(task, tool, status, "Done"))

    claude_says(context, context.thread, %{
      "type" => "assistant",
      "message" => %{
        "id" => "m-wake",
        "content" => [%{"type" => "text", "text" => "Both are done."}]
      }
    })

    claude_says(context, context.thread, %{"type" => "result", "subtype" => "success"})
    [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, World.thread_id(context, context.thread))
    :sys.get_state(pid)
    context
  end

  defp agent_wakes(context, thread) do
    # A wake is the agent's turn of the user's role; the provider's answers are the assistant's.
    for %{"role" => "user", "createdBy" => "agent", "creationSource" => "provider"} = message <-
          World.entities(context, thread, "message"),
        do: message
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

  defp waiting_on("a monitor"), do: "start a monitor"
  defp waiting_on("a subagent"), do: "only the subagent in the background"
  defp waiting_on("a background task"), do: "only the command in the background"

  # Kills the provider process of `context.thread` once its one background task shows.
  defp leave_waiting(context) do
    context = await_background(context)
    pid = runtime(context, context.thread)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}
    context
  end

  defp await_background(context) do
    World.await_row(
      World.thread_id(context, context.thread),
      &(length(&1["pendingBackgroundTasks"] || []) == 1)
    )

    context
  end

  defp claude_says(context, thread, message) do
    [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, World.thread_id(context, thread))
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

  @doc false
  def hold_continuation(
        test,
        thread_id,
        :execute,
        %{"type" => "provider-runtime.continue", "threadId" => thread_id}
      ) do
    send(test, {:continuation_held, thread_id, self()})

    receive do
      :release_continuation -> :ok
    end
  end

  def hold_continuation(_test, _thread_id, _stage, _record), do: :ok

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
