defmodule HalC2.CodexTurnEndPropTest do
  @moduledoc """
  A state machine over one Codex turn (`HalC2.Codex.ThreadRuntime`) that spawns
  subagents of its own: Codex starts subagents and reports where each stands,
  then the turn ends one of six ways — Codex reports it completed, failed or
  interrupted, its app-server (and with it the event stream) dies without
  reporting anything, it closes its output and runs on, or it stops taking input
  so the MC's next write to it fails — and a subagent's own report may still
  arrive after a reported end.

  The promise: the run ends as the turn did (a dead or closed stream or a failed
  write fails it), and a subagent still running ends with the turn exactly when
  nothing can report it again — an interrupted turn, or a dead or closed stream or
  a failed write, which fails it. After a completed or failed turn Codex itself
  reported, its subagents carry on in their own threads and their later reports
  land; a report for one that had already ended changes nothing. A stream that
  dies after such a reported end, with no turn active, fails the subagents that
  turn left running and leaves the run as the turn ended it.

  The store can also refuse the thread's writes mid-turn, as a full disk does (#1285):
  on Codex's next event, which the runtime then stops the turn for, on that stop being
  ignored past its deadline, or on the turn's own end. Until the store takes writes
  again the thread shows the run running as it was. Then the run is failed, at the
  time it failed, and its provider turn reads as it ended: stopped, as Codex ended it,
  or still running when Codex ignored the stop, until Codex ends it late or its
  app-server goes. Subagents still running fail with it, the work in their own threads
  too, but for a turn Codex reported completed or failed: those carry on as after a
  recorded end. An app-server that dies before the store recovers takes them all with
  it, and a provider turn left running reads as interrupted. The store may refuse the
  subagents' threads as well, which changes none of that (#1398). A message sent while
  the provider turn is left over first stops it, and runs only once Codex reports it
  ended: when Codex acknowledges that stop and goes on, the message's run fails and the
  provider turn stays left over (#1398).

  The turn runs on the fake app-server in `test/support/fake_codex.py`, which
  leaves a turn saying "wait" open; the test then plays Codex's side itself.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Orchestration, StreamState}

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @tid "codex-thread"
  @fake_codex Path.expand("../../test/support/fake_codex.py", __DIR__)
  @wait_ms 10_000

  # What the thread shows for the state Codex reports of a subagent.
  @shown %{
    "completed" => "completed",
    "errored" => "failed",
    "shutdown" => "cancelled",
    "interrupted" => "interrupted"
  }

  property "a Codex turn's end settles its subagents as the way it ended says",
    numtests: HalC2.Prop.numtests(25),
    max_size: 12 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        start()
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()

        for key <- ~w(codex_command store_hook unrecorded_retry_ms codex_interrupt_deadline_ms)a,
            do: Application.delete_env(:hal_c2, key)

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  defp start do
    Process.delete(:lost)
    home = HalC2.Prop.scratch_home("codex-turn-end")
    work = Path.join(home, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)
    # While this file exists the app-server acknowledges a stop and keeps the turn.
    ignore = Path.join(home, "ignore-interrupt")
    Process.put(:ignore_interrupt, ignore)

    Application.put_env(:hal_c2, :codex_command, [
      "env",
      "FAKE_CODEX_IGNORE_INTERRUPT_FILE=" <> ignore,
      "python3",
      "-u",
      @fake_codex
    ])

    Application.put_env(:hal_c2, :unrecorded_retry_ms, 20)
    Application.put_env(:hal_c2, :codex_interrupt_deadline_ms, 100)

    HalC2.Prop.start_services([
      {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
      HalC2.Streams,
      HalC2.Shell,
      HalC2.Orchestration.TurnWatch,
      HalC2.Mcp,
      {Registry, keys: :unique, name: HalC2.Codex.Registry},
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Claude.Registry},
        id: :claude_registry
      ),
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Acp.Registry},
        id: :acp_registry
      ),
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Pi.Registry},
        id: :pi_registry
      ),
      {DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one},
      HalC2.Settings
    ])

    :ok = HalC2.Streams.subscribe(@tid, self(), nil)
    selection = %{"instanceId" => "codex", "model" => "gpt-5.4"}

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => @tid,
        "projectId" => "project-1",
        "title" => "Codex",
        "modelSelection" => selection,
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "worktreePath" => work
      })

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "threadId" => @tid,
        "messageId" => "m1",
        "text" => "wait for it",
        "attachments" => [],
        "modelSelection" => selection,
        "dispatchMode" => %{"type" => "start_immediately"}
      })

    await_until(
      fn ->
        case runtime() do
          {_,
           %{
             turn: %{native_turn_id: turn, ids: %{run: run} = ids},
             native_thread_id: thread
           }}
          when is_binary(turn) and is_binary(thread) ->
            Process.put(:native_thread, thread)
            Process.put(:native_turn, turn)
            Process.put(:run, run)
            Process.put(:provider_turn, ids[:provider_turn])
            observed().run == "running"

          _ ->
            false
        end
      end,
      "no Codex turn"
    )
  end

  # --- model ---------------------------------------------------------------------

  # phase: :running, :reported (Codex reported the turn's end; its subagents'
  # reports can still arrive), :ended (the stream died, or the run's unrecorded end
  # was recorded; nothing more can arrive), :unrecorded (the store refuses the
  # thread's writes and the turn has ended, unrecorded) or :leftover (the run is
  # recorded, its provider turn still running). subs: each spawned subagent's shown
  # status, in spawn order. held: how the provider turn of an unrecorded run ended;
  # pt: its provider turn's status, once the run is recorded (nil: not compared).
  # follows: how each later message's run ended, in order. lost: the app-server died
  # while the store refused the run's end.
  def initial_state,
    do: %{
      phase: :running,
      run: "running",
      subs: [],
      held: nil,
      pt: nil,
      follows: [],
      lost: false
    }

  def command(state) do
    reports =
      if state.subs != [] and state.phase != :ended,
        do: [
          {3,
           {:call, __MODULE__, :report,
            [oneof(Enum.to_list(1..length(state.subs))), oneof(Map.keys(@shown))]}}
        ],
        else: []

    case state.phase do
      :running ->
        frequency(
          [
            {3, {:call, __MODULE__, :spawn, [length(state.subs) + 1]}},
            {2, {:call, __MODULE__, :end_turn, [:completed]}},
            {2, {:call, __MODULE__, :end_turn, [:failed]}},
            {2, {:call, __MODULE__, :end_turn, [:interrupted]}},
            {2, {:call, __MODULE__, :end_turn, [:stream]}},
            {2, {:call, __MODULE__, :fail_write, [oneof([:stopped, :ignored]), scope()]}},
            {2,
             {:call, __MODULE__, :fail_end, [oneof([:completed, :failed, :interrupted]), scope()]}},
            {2, {:call, __MODULE__, :end_turn, [:deaf]}},
            {2, {:call, __MODULE__, :end_turn, [:mute]}}
          ] ++ reports
        )

      :unrecorded ->
        frequency(
          [
            {1, {:call, __MODULE__, :observe, []}},
            {3, {:call, __MODULE__, :recover, []}}
          ] ++ if(state.lost, do: [], else: [{2, {:call, __MODULE__, :end_held_stream, []}}])
        )

      :leftover ->
        oneof([
          {:call, __MODULE__, :observe, []},
          {:call, __MODULE__, :follow_up, [oneof([:honoured, :ignored])]},
          {:call, __MODULE__, :end_turn,
           [oneof([:completed, :failed, :interrupted, :stream, :deaf, :mute])]}
        ])

      :reported ->
        frequency(
          [{1, {:call, __MODULE__, :observe, []}}, {2, {:call, __MODULE__, :end_stream, []}}] ++
            reports
        )

      :ended ->
        {:call, __MODULE__, :observe, []}
    end
  end

  # What the store refuses: the thread's writes, or every stream's, its subagents'
  # threads too.
  defp scope, do: oneof([:thread, :all])

  def precondition(state, {:call, _, :spawn, [n]}),
    do: state.phase == :running and n == length(state.subs) + 1

  def precondition(state, {:call, _, :report, [n, reported]}),
    do: state.phase != :ended and n in 1..length(state.subs) and Map.has_key?(@shown, reported)

  def precondition(state, {:call, _, :end_turn, [_kind]}),
    do: state.phase in [:running, :leftover]

  def precondition(state, {:call, _, :fail_write, [_how, _scope]}), do: state.phase == :running
  def precondition(state, {:call, _, :fail_end, [_kind, _scope]}), do: state.phase == :running
  def precondition(state, {:call, _, :follow_up, [_how]}), do: state.phase == :leftover
  def precondition(state, {:call, _, :recover, []}), do: state.phase == :unrecorded
  def precondition(state, {:call, _, :end_stream, []}), do: state.phase == :reported

  def precondition(state, {:call, _, :end_held_stream, []}),
    do: state.phase == :unrecorded and not state.lost

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :spawn, _}),
    do: %{state | subs: state.subs ++ ["running"]}

  def next_state(state, _result, {:call, _, :report, [n, reported]}) do
    subs =
      List.update_at(state.subs, n - 1, fn
        "running" -> @shown[reported]
        ended -> ended
      end)

    %{state | subs: subs}
  end

  # A left-over provider turn ends late: as Codex says, or interrupted with its
  # app-server, however that dies. The run stays as it was recorded.
  def next_state(%{phase: :leftover} = state, _result, {:call, _, :end_turn, [kind]}) do
    pt = if kind in [:stream, :deaf, :mute], do: "interrupted", else: Atom.to_string(kind)
    %{state | phase: :ended, pt: pt}
  end

  def next_state(state, _result, {:call, _, :end_turn, [kind]}) do
    case kind do
      :completed ->
        %{state | phase: :reported, run: "completed"}

      :failed ->
        %{state | phase: :reported, run: "failed"}

      :interrupted ->
        %{state | phase: :reported, run: "interrupted", subs: settle(state, "interrupted")}

      # A write the app-server no longer takes, or output it closed while it runs
      # on, retires it, as its death does.
      dead when dead in [:stream, :deaf, :mute] ->
        %{state | phase: :ended, run: "failed", subs: settle(state, "failed")}
    end
  end

  # The stream dies after Codex reported the turn's end: the run keeps how
  # the turn ended, and subagents it left running fail with the stream.
  def next_state(state, _result, {:call, _, :end_stream, []}),
    do: %{state | phase: :ended, subs: settle(state, "failed")}

  # The store refuses the turn's writes: nothing changes on the thread yet. The
  # runtime stops the turn, which Codex ends as interrupted or keeps running.
  def next_state(state, _result, {:call, _, :fail_write, [how, _scope]}),
    do: %{
      state
      | phase: :unrecorded,
        held: if(how == :stopped, do: "interrupted", else: "running")
    }

  def next_state(state, _result, {:call, _, :fail_end, [kind, _scope]}),
    do: %{state | phase: :unrecorded, held: Atom.to_string(kind)}

  # The next message stops the left-over provider turn first. Codex ends it, and the
  # message's turn runs; or acknowledges the stop and goes on, and the message's run
  # fails, the provider turn still left over.
  def next_state(state, _result, {:call, _, :follow_up, [:honoured]}),
    do: %{state | phase: :ended, pt: "interrupted", follows: state.follows ++ ["completed"]}

  def next_state(state, _result, {:call, _, :follow_up, [:ignored]}),
    do: %{state | follows: state.follows ++ ["failed"]}

  def next_state(state, _result, {:call, _, :end_held_stream, []}), do: %{state | lost: true}

  # The run fails. A turn Codex reported completed or failed leaves its subagents
  # carrying on, reports of them still to come; an app-server gone took them with it.
  def next_state(state, _result, {:call, _, :recover, []}) do
    failed = %{state | run: "failed", subs: settle(state, "failed"), pt: state.held}

    cond do
      state.lost ->
        pt = if state.held == "running", do: "interrupted", else: state.held
        %{failed | phase: :ended, pt: pt}

      state.held in ~w(completed failed) ->
        %{state | phase: :reported, run: "failed", pt: state.held}

      state.held == "running" ->
        %{failed | phase: :leftover}

      true ->
        %{failed | phase: :ended}
    end
  end

  def next_state(state, _result, _call), do: state

  defp settle(state, status),
    do:
      Enum.map(state.subs, fn
        "running" -> status
        ended -> ended
      end)

  def postcondition(state, {:call, _, name, _} = call, seen) do
    expected = next_state(state, nil, call)

    seen.run == expected.run and seen.subs == expected.subs and
      seen.follows == expected.follows and seen.strays == 0 and seen.open_children == 0 and
      (expected.pt == nil or seen.pt == expected.pt) and
      (name != :recover or seen.on_time)
  end

  # --- commands ------------------------------------------------------------------

  # Codex starts subagent `n`, still working on its task: a command running in its
  # own thread.
  def spawn(n) do
    notify("item/started", collab(n, "inProgress", %{"status" => "running"}))
    await_until(fn -> length(observed().subs) >= n end, "subagent #{n} never showed")

    notify("item/started", %{
      "threadId" => "native-child-#{n}",
      "turnId" => "native-child-turn-#{n}",
      "item" => %{"type" => "commandExecution", "id" => "child-cmd-#{n}", "command" => "ls lib"}
    })

    settle_runtime()
    observed()
  end

  # Codex reports subagent `n` as `reported` (a state that ends it).
  def report(n, reported) do
    notify(
      "item/completed",
      collab(n, "completed", %{"status" => reported, "message" => "result #{n}"})
    )

    settle_runtime()
    observed()
  end

  # The turn ends: as Codex reports it, or with its app-server dying mid-turn.
  def end_turn(:stream) do
    kill_app_server()

    await_until(
      fn -> observed().run != "running" and observed().pt != "running" end,
      "the run never ended"
    )

    settle_runtime()
    observed()
  end

  # The app-server stops reading its input but keeps its output open; the next
  # thing written to it fails.
  def end_turn(:deaf) do
    {_, runtime} = runtime()
    {:ok, _} = HalC2.JsonRpc.Connection.call(runtime.conn, "test/deaf", %{})
    HalC2.JsonRpc.Connection.notify(runtime.conn, "test/ping", nil)

    await_until(
      fn -> observed().run != "running" and observed().pt != "running" end,
      "the run never ended"
    )

    settle_runtime()
    observed()
  end

  # The app-server closes its output and runs on: nothing more can be reported.
  def end_turn(:mute) do
    {_, runtime} = runtime()
    HalC2.JsonRpc.Connection.notify(runtime.conn, "test/mute", nil)

    await_until(
      fn -> observed().run != "running" and observed().pt != "running" end,
      "the run never ended"
    )

    settle_runtime()
    observed()
  end

  def end_turn(kind) do
    status = Atom.to_string(kind)

    turn =
      %{"id" => Process.get(:native_turn), "status" => status}
      |> then(fn turn ->
        if kind == :failed,
          do: Map.put(turn, "error", %{"message" => "the turn failed"}),
          else: turn
      end)

    notify("turn/completed", %{"turn" => turn})

    await_until(
      fn -> observed().run != "running" and observed().pt != "running" end,
      "the run never ended"
    )

    settle_runtime()
    observed()
  end

  # The store refuses the thread's writes from Codex's next event on, which the
  # runtime stops the turn for: Codex ends it, or (`:ignored`) keeps it past the stop's
  # deadline. Returns once TurnWatch holds the run's end and the store refused it.
  def fail_write(how, scope) do
    if how == :ignored, do: File.write!(Process.get(:ignore_interrupt), "")
    refuse(scope)
    notify("item/started", message_item("inProgress"))
    unrecorded()
  end

  # The store refuses the thread's writes from the turn's own end on.
  def fail_end(kind, scope) do
    refuse(scope)
    turn = %{"id" => Process.get(:native_turn), "status" => Atom.to_string(kind)}

    turn =
      if kind == :failed,
        do: Map.put(turn, "error", %{"message" => "the turn failed"}),
        else: turn

    notify("turn/completed", %{"turn" => turn})
    unrecorded()
  end

  # The store takes writes again; TurnWatch's next try records the run, and with its
  # app-server gone, the runtime's (if it lives) the provider turn it left running.
  def recover do
    HalC2.Test.Machines.refuse_changes(nil)
    File.rm(Process.get(:ignore_interrupt))

    await_until(
      fn ->
        observed().run != "running" and
          not (Process.get(:lost, false) and observed().pt == "running")
      end,
      "the run was never recorded"
    )

    settle_runtime()
    run = current(@tid) |> StreamState.list("run") |> List.first()
    Map.put(observed(), :on_time, run["completedAt"] == Process.get(:failed_at))
  end

  # The next message to the thread, while its provider turn is left over: Codex ends
  # the left-over turn when the message's stop reaches it, or (`:ignored`) goes on.
  # Either way the left-over turn first reports an answer, an approval and a subagent,
  # which the message's run, waiting for it, does not take (`strays`).
  def follow_up(how) do
    ignore = Process.get(:ignore_interrupt)
    if how == :honoured, do: File.rm(ignore), else: File.write!(ignore, "")
    File.write!(ignore <> "-reports", "")

    n = length(observed().follows) + 1
    selection = %{"instanceId" => "codex", "model" => "gpt-5.4"}

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "threadId" => @tid,
        "messageId" => "m#{n + 1}",
        "text" => "Next",
        "attachments" => [],
        "modelSelection" => selection,
        "dispatchMode" => %{"type" => "start_immediately"}
      })

    await_until(
      fn ->
        follows = observed().follows
        length(follows) == n and List.last(follows) in ~w(completed failed interrupted)
      end,
      "the next message's run never ended"
    )

    settle_runtime()
    observed()
  end

  defp refuse(:thread), do: HalC2.Test.Machines.refuse_changes(@tid)

  defp refuse(:all),
    do: Application.put_env(:hal_c2, :store_hook, {__MODULE__, :refuse_every, []})

  # The store refuses every stream's changes, as a full disk does.
  def refuse_every(:append_change, _stream_id) do
    if self() == Process.whereis(HalC2.Store), do: raise("the disk is full"), else: :ok
  end

  def refuse_every(_stage, _stream_id), do: :ok

  defp unrecorded do
    {:unrecorded, at} = HalC2.Orchestration.TurnWatch.attempted(Process.get(:run))
    Process.put(:failed_at, at)
    settle_runtime()
    observed()
  end

  # The app-server dies after Codex reported the turn's end, while subagents
  # that turn left running carry on in their own threads.
  def end_stream do
    kill_app_server()

    await_until(
      fn -> Enum.all?(observed().subs, &(&1 != "running")) end,
      "the subagents never settled"
    )

    settle_runtime()
    observed()
  end

  # The app-server dies while the store still refuses the run's end: the runtime,
  # failing to record what went with it, may go too.
  def end_held_stream do
    {_, runtime} = runtime()
    ref = Process.monitor(runtime.conn)
    kill_app_server()

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    after
      @wait_ms -> :ok
    end

    Process.put(:lost, true)
    settle_runtime()
    observed()
  end

  def observe, do: observed()

  # --- the real side ---------------------------------------------------------------

  defp message_item(status) do
    %{
      "threadId" => Process.get(:native_thread),
      "turnId" => Process.get(:native_turn),
      "item" => %{
        "type" => "agentMessage",
        "id" => "msg-unrecorded",
        "text" => "",
        "status" => status
      }
    }
  end

  defp collab(n, status, agent_state) do
    %{
      "threadId" => Process.get(:native_thread),
      "turnId" => Process.get(:native_turn),
      "item" => %{
        "type" => "collabAgentToolCall",
        "id" => "collab-#{n}",
        "tool" => "spawnAgent",
        "prompt" => "List the modules in lib",
        "senderThreadId" => Process.get(:native_thread),
        "receiverThreadIds" => ["native-child-#{n}"],
        "status" => status,
        "agentsStates" => %{"native-child-#{n}" => agent_state}
      }
    }
  end

  # As the app-server would send it; the `:settle` call after rides behind it,
  # so what is read back is what its handling committed.
  defp notify(method, params) do
    {pid, runtime} = runtime()
    send(pid, {:json_rpc, runtime.conn, {:notification, method, params}})
  end

  # The fake app-server dies without ending anything, as a crashed Codex does.
  defp kill_app_server do
    {_, runtime} = runtime()
    os_pid = HalC2.Subprocess.os_pid(:sys.get_state(runtime.conn).sub)
    {_, 0} = System.cmd("kill", ["-9", Integer.to_string(os_pid)])
  end

  # A runtime going as it is asked has nothing left to settle.
  defp settle_runtime do
    case Registry.lookup(HalC2.Codex.Registry, @tid) do
      [{pid, _}] -> GenServer.call(pid, :settle)
      [] -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp runtime do
    case Registry.lookup(HalC2.Codex.Registry, @tid) do
      [{pid, _}] -> {pid, :sys.get_state(pid)}
      [] -> nil
    end
  end

  defp observed do
    state = current(@tid)
    first = Process.get(:run)
    {[run], later} = state |> StreamState.list("run") |> Enum.split_with(&(&1["id"] == first))
    # A subagent finishing after a completed turn wakes the thread in a task of its own
    # (`HalC2.Orchestration.Wake`); only the messages sent here are follow-ups.
    follows = Enum.filter(later, &(&1["userMessageId"] =~ ~r/^m\d+$/))
    turn = StreamState.get(state, "provider-turn")[Process.get(:provider_turn)]

    subagents = StreamState.list(state, "subagent")

    %{
      run: run["status"],
      subs: Enum.map(subagents, & &1["status"]),
      # Subagents shown as ended whose own thread still has work running.
      open_children:
        Enum.count(subagents, fn sub ->
          sub["status"] != "running" and
            sub["childThreadId"]
            |> current()
            |> StreamState.list("turn-item")
            |> Enum.any?(&(&1["status"] == "running"))
        end),
      pt: turn && turn["status"],
      follows: follows |> Enum.sort_by(& &1["ordinal"]) |> Enum.map(& &1["status"]),
      strays:
        Enum.count(
          ~w(message runtime-request subagent turn-item),
          &Enum.any?(Map.keys(StreamState.get(state, &1)), fn id -> id =~ "leftover" end)
        )
    }
  end

  # Wakes on the stream's own commits; what it waited for never happening is
  # the failure the postcondition then shows, so it returns rather than raises.
  defp await_until(fun, _what, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @wait_ms

    if fun.() do
      :ok
    else
      receive do
        {:hal_c2_stream, @tid, _} -> await_until(fun, nil, deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) -> :timeout
      end
    end
  end

  defp current(tid), do: HalC2.Streams.Server.state(HalC2.Streams.ensure(tid))
end
