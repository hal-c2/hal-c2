defmodule HalC2.TurnWatchPropTest do
  @moduledoc """
  A state machine over `HalC2.Orchestration.TurnWatch` and the ends it records
  (`HalC2.Orchestration.TurnWriter.abandon/5`), on one thread whose runs share a
  provider instance and are driven, one at a time, by a runtime process the test
  plays. The runtime claims each run it starts, starts work in it (a provider
  subagent, a background command, a task delegated through HAL-C2), completes it or
  hands over an end the store did not record, with some of that work it ended. The
  store can refuse the thread's writes and take them again, and the runtime can exit,
  crashing or stopping, at any point: while its run runs, while its end waits on the
  store, while a try at recording it runs, and after that try recorded the run but
  before TurnWatch heard its answer, with the next run started on a new runtime in
  between.

  The promise: a run is driven while its runtime lives and claims it, and while its
  end waits on the store; TurnWatch monitors exactly the runtimes of the runs it
  holds a claim for. A held end keeps its runtime's claim until it records, whatever
  releases the run meanwhile. An end the store recorded fails the run and the work
  its runtime ended, and leaves the rest running. A runtime that crashed while it
  drove a run, or went, by any exit, before the run's end recorded, takes the work it
  kept running with it: that of its run and of the instance's earlier runs, but never
  a later run's, and never a delegated task. A runtime that stops with no run of its
  own left alone changes nothing.

  A provider subagent's work runs in a thread of its own. A Stop of a run whose
  runtime crashed can race TurnWatch's end of it (`stop_crashed/0`): the end that
  settles the work in the subagents' threads is the one that ends the run, so they
  read alike, and so is one the store refused after those threads took it, ahead of a
  Stop that comes once the store recovers (`late_stop/0`) (review of #1398). The next
  run's runtime can resume a subagent an earlier run started (Claude's SendMessage),
  the lost run itself among them, before the lost runtime's last try: that try leaves
  it, its records and the work in its thread running (`recover/3`).

  TurnWatch's mailbox is traced, so each step waits on the messages it receives (a
  runtime's `:DOWN`, a try's answer, a state read) rather than on time.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Orchestration, StreamState}
  alias HalC2.Orchestration.{Entities, TurnWatch, TurnWriter}

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @tid "watch-thread"
  @instance "codex"
  @wait_ms 10_000
  @kinds [:native, :command, :delegated]

  property "TurnWatch keeps each run driven and its end takes only what its runtime held",
    numtests: HalC2.Prop.numtests(200),
    max_size: 25 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        start()
        {history, state, result} = run_commands(__MODULE__, cmds)
        stop()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # Two recoveries in a row each resume the subagent, the second one already running.
  test "a subagent resumed by a second recovery while it runs" do
    m = __MODULE__

    cmds = [
      {:set, {:var, 1}, {:call, m, :start_run, []}},
      {:set, {:var, 2}, {:call, m, :add_work, [:native]}},
      {:set, {:var, 3}, {:call, m, :complete, []}},
      {:set, {:var, 4}, {:call, m, :start_run, []}},
      {:set, {:var, 5}, {:call, m, :stop_crashed, []}},
      {:set, {:var, 6}, {:call, m, :start_run, []}},
      {:set, {:var, 7}, {:call, m, :complete, []}},
      {:set, {:var, 8}, {:call, m, :start_run, []}},
      {:set, {:var, 9}, {:call, m, :refuse, []}},
      {:set, {:var, 10}, {:call, m, :fail_unrecorded, [[]]}},
      {:set, {:var, 11}, {:call, m, :recover, [:after_answer, :mid, [1]]}},
      {:set, {:var, 12}, {:call, m, :refuse, []}},
      {:set, {:var, 13}, {:call, m, :fail_unrecorded, [[]]}},
      {:set, {:var, 14}, {:call, m, :recover, [:during_try, :mid, [1]]}},
      {:set, {:var, 15}, {:call, m, :exit_runtime, [:crash]}}
    ]

    Process.flag(:trap_exit, true)
    start()
    {_history, _state, result} = run_commands(__MODULE__, cmds)
    stop()
    assert result == :ok
  end

  defp start do
    flush_traces()
    for key <- [:runs, :work, :runtime, :spawned], do: Process.delete({__MODULE__, key})
    home = HalC2.Prop.scratch_home("turn-watch")
    Application.put_env(:hal_c2, :unrecorded_retry_ms, 1)

    HalC2.Prop.start_services([
      {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
      HalC2.Streams,
      HalC2.Shell,
      TurnWatch
    ])

    :erlang.trace(Process.whereis(TurnWatch), true, [:receive])
    seed([Orchestration.create("thread", @tid, %{"id" => @tid, "title" => "Watched"})])
  end

  defp stop do
    for pid <- Process.get({__MODULE__, :spawned}, []), do: Process.exit(pid, :kill)
    HalC2.Prop.stop_services()

    for key <- ~w(store_hook unrecorded_retry_ms streams_hook abandon_hook)a,
        do: Application.delete_env(:hal_c2, key)

    flush_traces()
  end

  # --- model ---------------------------------------------------------------------

  # runs: each run by ordinal, the latest last, with its status (:running, :held while
  # its end waits on the store, :completed, :failed), its runtime, whether its runtime
  # went before the end recorded (`lost`) and the work the runtime ended (`ended`).
  # work: each piece by id, with its run, kind and status. claimed: the runs TurnWatch
  # holds a claim for. runtime: the live runtime, if any, numbered from 1 by `runtimes`.
  def initial_state,
    do: %{
      refusing: false,
      runtime: nil,
      runtimes: 0,
      runs: %{},
      work: %{},
      claimed: MapSet.new()
    }

  def command(state) do
    open =
      for {id, %{status: :running, kind: kind}} <- state.work, kind != :delegated, do: id

    driving = driving(state)

    frequency(
      [
        {if(active(state) == nil, do: 1, else: 3),
         {:call, __MODULE__, if(state.refusing, do: :accept, else: :refuse), []}}
      ] ++
        if(active(state) == nil and not state.refusing,
          do: [{3, {:call, __MODULE__, :start_run, []}}],
          else: []
        ) ++
        case driving do
          :running ->
            if(state.refusing,
              do: [],
              else: [
                {4, {:call, __MODULE__, :add_work, [oneof(@kinds)]}},
                {2, {:call, __MODULE__, :complete, []}},
                {1, {:call, __MODULE__, :stop_crashed, []}}
              ]
            ) ++
              [
                {if(state.refusing, do: 4, else: 1),
                 {:call, __MODULE__, :fail_unrecorded, [ended(open)]}}
              ]

          :held ->
            [
              {10,
               {:call, __MODULE__, :recover,
                [
                  oneof([:during_try, :after_answer]),
                  oneof([false, true, :mid]),
                  resumable(state)
                ]}}
            ]

          nil ->
            if(late_stop?(state), do: [{4, {:call, __MODULE__, :late_stop, []}}], else: [])
        end ++
        if(state.runtime != nil,
          do: [
            {1,
             {:call, __MODULE__, :exit_runtime,
              [if(driving == :running, do: :crash, else: oneof([:crash, :normal]))]}}
          ],
          else: []
        )
    )
  end

  defp ended([]), do: []
  defp ended(open), do: let(ids <- resize(3, list(oneof(open))), do: Enum.uniq(ids))

  # Provider subagents the next run can resume once the held end records: those an
  # earlier end failed, and those that end fails, its own run's among them.
  defp resumable(state) do
    state.work
    |> Enum.filter(&match?({_, %{kind: :native}}, &1))
    |> Enum.map(&elem(&1, 0))
    |> ended()
  end

  # The run in progress lost its runtime while the store refused its end.
  defp late_stop?(state),
    do: state.refusing and match?(%{status: :held, lost: true}, active(state))

  # The thread's run in progress, the latest: running, or its end held.
  defp active(state) do
    case state.runs[map_size(state.runs)] do
      %{status: status} = run when status in [:running, :held] -> run
      _ -> nil
    end
  end

  # How the live runtime drives the run in progress, if it does.
  defp driving(state) do
    case active(state) do
      %{runtime: runtime, status: status} when runtime == state.runtime -> status
      _ -> nil
    end
  end

  def precondition(state, {:call, _, :start_run, []}),
    do: active(state) == nil and not state.refusing

  def precondition(state, {:call, _, cmd, _}) when cmd in [:add_work, :complete, :stop_crashed],
    do: not state.refusing and driving(state) == :running

  def precondition(state, {:call, _, :fail_unrecorded, [ended]}),
    do:
      driving(state) == :running and
        Enum.all?(
          ended,
          &match?(%{status: :running, kind: kind} when kind != :delegated, state.work[&1])
        )

  def precondition(state, {:call, _, :recover, [_at, _next, resumed]}),
    do:
      state.refusing and state.runtime != nil and driving(state) == :held and
        Enum.all?(resumed, &match?(%{kind: :native}, state.work[&1]))

  def precondition(state, {:call, _, :late_stop, []}),
    do: late_stop?(state) and driving(state) == nil

  def precondition(state, {:call, _, :exit_runtime, [reason]}),
    do: state.runtime != nil and (reason == :crash or driving(state) != :running)

  def precondition(state, {:call, _, :refuse, []}), do: not state.refusing
  def precondition(state, {:call, _, :accept, []}), do: state.refusing

  def next_state(state, _result, {:call, _, :refuse, []}), do: %{state | refusing: true}

  def next_state(state, _result, {:call, _, :accept, []}) do
    held = for {ordinal, %{status: :held}} <- state.runs, do: ordinal
    Enum.reduce(held, %{state | refusing: false}, &recorded(&2, &1))
  end

  def next_state(state, _result, {:call, _, :start_run, []}) do
    {runtime, runtimes} =
      if state.runtime,
        do: {state.runtime, state.runtimes},
        else: {state.runtimes + 1, state.runtimes + 1}

    ordinal = map_size(state.runs) + 1
    run = %{status: :running, runtime: runtime, lost: false, ended: MapSet.new()}

    %{
      state
      | runs: Map.put(state.runs, ordinal, run),
        runtime: runtime,
        runtimes: runtimes,
        claimed: MapSet.put(state.claimed, ordinal)
    }
  end

  def next_state(state, _result, {:call, _, :add_work, [kind]}) do
    piece = %{run: map_size(state.runs), kind: kind, status: :running}
    put_in(state.work[map_size(state.work) + 1], piece)
  end

  def next_state(state, _result, {:call, _, :complete, []}) do
    ordinal = map_size(state.runs)
    state = put_in(state.runs[ordinal].status, :completed)
    %{state | claimed: MapSet.delete(state.claimed, ordinal)}
  end

  def next_state(state, _result, {:call, _, :fail_unrecorded, [ended]}) do
    ordinal = map_size(state.runs)

    state =
      update_in(state.runs[ordinal], &%{&1 | status: :held, ended: MapSet.new(ended)})

    if state.refusing, do: state, else: recorded(state, ordinal)
  end

  # TurnWatch's end of the crashed runtime settles the subagents' threads first, so it
  # ends the run, as on a crash alone.
  def next_state(state, result, {:call, mod, :stop_crashed, []}),
    do: next_state(state, result, {:call, mod, :exit_runtime, [:crash]})

  def next_state(state, _result, {:call, _, :exit_runtime, [reason]}) do
    ordinal = map_size(state.runs)
    driving = driving(state)
    state = %{state | runtime: nil}

    if driving == :held or (driving == :running and reason == :crash) do
      state = %{
        state
        | runs: Map.update!(state.runs, ordinal, &%{&1 | status: :held, lost: true}),
          claimed: MapSet.delete(state.claimed, ordinal)
      }

      if state.refusing, do: state, else: recorded(state, ordinal)
    else
      state
    end
  end

  # The Stop ends the run as the try the store refused chose: failed.
  def next_state(state, result, {:call, mod, :late_stop, []}),
    do: next_state(state, result, {:call, mod, :accept, []})

  # A subagent the next run resumed is that run's runtime's, whether it resumed it
  # during the try or after it.
  def next_state(state, _result, {:call, _, :recover, [_at, next?, resumed]}) do
    ordinal = map_size(state.runs)
    state = put_in(state.runs[ordinal].lost, true)
    state = recorded(%{state | refusing: false, runtime: nil}, ordinal)

    if next? != false do
      state = next_state(state, nil, {:call, __MODULE__, :start_run, []})

      state =
        Enum.reduce(@kinds, state, fn kind, state ->
          next_state(state, nil, {:call, __MODULE__, :add_work, [kind]})
        end)

      Enum.reduce(resumed, state, fn id, state ->
        update_in(state.work[id], &%{&1 | status: :running, run: ordinal + 1})
      end)
    else
      state
    end
  end

  # Run `ordinal`'s end records: the run fails, and so does the work its runtime ended;
  # a runtime that went first takes with it the work it kept running, its run's and its
  # instance's earlier runs', but not a delegated task.
  defp recorded(state, ordinal) do
    run = state.runs[ordinal]

    work =
      Map.new(state.work, fn {id, piece} ->
        fails? =
          piece.status == :running and piece.kind != :delegated and
            (id in run.ended or (run.lost and piece.run <= ordinal))

        {id, if(fails?, do: %{piece | status: :failed}, else: piece)}
      end)

    %{
      state
      | runs: Map.put(state.runs, ordinal, %{run | status: :failed}),
        work: work,
        claimed: MapSet.delete(state.claimed, ordinal)
    }
  end

  # And the work in the run's subagents' threads ended as the run did.
  def postcondition(state, {:call, _, :stop_crashed, []}, {observed, children}),
    do:
      postcondition(state, {:call, __MODULE__, :exit_runtime, [:crash]}, observed) and
        (Enum.all?(children, &(&1 == "failed")) or
           (IO.puts("the subagents' threads read #{inspect(children)}") && false))

  # And the work in each subagent's thread reads as the subagent does.
  def postcondition(state, {:call, _, :late_stop, []} = call, {observed, children}),
    do:
      postcondition(state, {:call, __MODULE__, :accept, []}, observed) and
        children?(next_state(state, nil, call), children)

  def postcondition(state, {:call, _, :recover, _} = call, {observed, children}),
    do: postcondition(state, call, observed) and children?(next_state(state, nil, call), children)

  def postcondition(state, call, observed) do
    expected = expected(next_state(state, nil, call))

    observed == expected or
      (IO.puts(
         "expected #{inspect(expected, pretty: true)}\nobserved #{inspect(observed, pretty: true)}"
       ) &&
         false)
  end

  defp children?(state, children) do
    expected =
      for {id, %{kind: :native, status: status}} <- state.work,
          into: %{},
          do: {id, Atom.to_string(status)}

    children == expected or
      (IO.puts("the subagents' threads read #{inspect(children)}, not #{inspect(expected)}") &&
         false)
  end

  # What the thread and TurnWatch show for `state`.
  defp expected(state) do
    runs =
      Map.new(state.runs, fn {ordinal, run} ->
        status = if run.status == :held, do: "running", else: Atom.to_string(run.status)
        {run_id(ordinal), status}
      end)

    entities =
      for {id, piece} <- state.work,
          key <- entities(id, piece.kind),
          into: %{},
          do: {key, Atom.to_string(piece.status)}

    driven =
      Map.new(state.runs, fn {ordinal, run} ->
        {run_id(ordinal), run.status == :held or ordinal in state.claimed}
      end)

    claimed = MapSet.new(state.claimed, &run_id/1)

    %{
      runs: runs,
      entities: entities,
      driven: driven,
      claimed: claimed,
      monitors: MapSet.size(claimed)
    }
  end

  # --- commands ------------------------------------------------------------------

  # The commands number runs and work in the order they come, as the model does, so a
  # shrunk case drops steps without renumbering the rest.

  def refuse do
    Application.put_env(:hal_c2, :store_hook, {__MODULE__, :refuse_thread, []})
    observe()
  end

  def accept do
    Application.delete_env(:hal_c2, :store_hook)
    drain()
    observe()
  end

  # The store takes writes again, and a Stop that took the run for undriven before
  # (`TurnWriter.abandon/5` as `Orchestration.interrupt_undriven/2` calls it) ends it
  # ahead of TurnWatch's next try, which waits on the run's lock the test holds. The
  # try the store refused had ended the work in the subagents' threads.
  def late_stop do
    run = run_id(latest())
    lock = {{TurnWriter, :abandon, run}, self()}
    true = :global.set_lock(lock, [node()])
    Application.delete_env(:hal_c2, :store_hook)
    # The Stop takes the lock the test holds, and releases it.
    :ok = TurnWriter.abandon(@tid, run, "interrupted", nil)
    :global.del_lock(lock, [node()])
    drain()
    {observe(), children()}
  end

  # The live runtime starts the next run and claims it, a new runtime if none lives.
  def start_run do
    ordinal = new_run()
    :ok = runtime() |> ask(fn -> TurnWatch.claim(@tid, run_id(ordinal)) end) |> answer()
    observe()
  end

  def add_work(kind) do
    id = new_work(kind)
    seed(work(id, latest(), kind))
    child_thread(id, kind)
    observe()
  end

  # The live runtime crashes and the run is stopped (`TurnWriter.abandon/5` as
  # `Orchestration.interrupt_undriven/2` calls it, the runtime gone) while TurnWatch's
  # try at ending it holds after the subagents' threads, if it settles any. The Stop
  # waits for that end, or ends the run itself.
  def stop_crashed do
    watch = Process.whereis(TurnWatch)
    pid = Process.get({__MODULE__, :runtime})
    run = run_id(latest())
    test = self()
    Application.put_env(:hal_c2, :streams_hook, {__MODULE__, :hold_try, [test, watch]})
    Application.put_env(:hal_c2, :abandon_hook, {__MODULE__, :waiting, [test]})
    stop_runtime(pid, :crash)
    await_down(watch, pid)

    held =
      receive do
        {:held_try, try} -> try
        {:trace, ^watch, :receive, {:attempted, ^run, _}} -> nil
      after
        @wait_ms -> raise "no try at ending #{run}"
      end

    spawn_link(fn ->
      send(test, {:stopped, TurnWriter.abandon(@tid, run, "interrupted", nil)})
    end)

    receive do
      {:waiting, ^run} -> :ok
      {:stopped, :ok} -> send(test, {:stopped, :ok})
    after
      @wait_ms -> raise "the Stop neither waited nor ended #{run}"
    end

    if held, do: send(held, :go)

    receive do
      {:stopped, :ok} -> :ok
    after
      @wait_ms -> raise "the Stop of #{run} never ended"
    end

    for key <- ~w(streams_hook abandon_hook)a, do: Application.delete_env(:hal_c2, key)
    if held, do: await_trace(watch, &match?({:attempted, ^run, _}, &1))
    drain()

    children =
      for {id, :native} <- Process.get({__MODULE__, :work}, %{}),
          HalC2.Streams.state(@tid)
          |> StreamState.get("subagent")
          |> get_in(["sub-#{id}", "runId"]) ==
            run,
          do:
            HalC2.Streams.state(child_id(id))
            |> StreamState.get("turn-item")
            |> get_in([child_item(id), "status"])

    {observe(), children}
  end

  # TurnWatch's try waits for the test's go at its first use of the thread after a
  # subagent's thread.
  def hold_try(test, watch, :ensured, stream_id) do
    # The try itself, not the tasks its end starts.
    if Process.get(:"$callers") == [watch] do
      cond do
        stream_id != @tid ->
          Process.put({__MODULE__, :child_seen}, true)

        Process.get({__MODULE__, :child_seen}, false) and
            Process.put({__MODULE__, :held}, true) == nil ->
          send(test, {:held_try, self()})
          receive do: (:go -> :ok)

        true ->
          :ok
      end
    end

    :ok
  end

  def hold_try(_test, _watch, _stage, _stream_id), do: :ok

  # TurnWatch's try waits for the test's go at its first use of a subagent's thread.
  def hold_child(test, watch, :ensured, stream_id) do
    if Process.get(:"$callers") == [watch] and stream_id != @tid and
         Process.put({__MODULE__, :held}, true) == nil do
      send(test, {:held_child, self()})
      receive do: (:go -> :ok)
    end

    :ok
  end

  def hold_child(_test, _watch, _stage, _stream_id), do: :ok

  def waiting(test, run_id), do: send(test, {:waiting, run_id})

  # The runtime records its run completed and releases it, its work left running.
  def complete do
    run = run_id(latest())

    HalC2.Streams.transact(@tid, :thread, fn stream ->
      {[Orchestration.upsert(stream, "run", run, &Map.put(&1, "status", "completed"))], :ok}
    end)

    TurnWatch.release(run)
    drain()
    observe()
  end

  # The runtime hands over the end of its run, which the store did not record, with
  # the work it ended (`TurnWriter.finish/3`).
  def fail_unrecorded(ended) do
    work = Process.get({__MODULE__, :work})

    TurnWatch.unrecorded(@tid, run_id(latest()), %{
      at: Entities.now(),
      failure: "The turn could not be saved",
      provider_turn: nil,
      ended: ended |> Enum.flat_map(&entities(&1, work[&1])) |> MapSet.new()
    })

    drain()
    observe()
  end

  def exit_runtime(reason) do
    pid = Process.get({__MODULE__, :runtime})
    watch = Process.whereis(TurnWatch)

    watched? =
      Enum.any?(watch_state(watch).claims, fn {_, {_, claimant, _}} -> claimant == pid end)

    stop_runtime(pid, reason)
    if watched?, do: await_down(watch, pid)
    drain()
    observe()
  end

  # The store takes the thread's writes again while the runtime of the held run goes:
  # during the try that records the run, or after that try recorded it and before
  # TurnWatch heard its answer. `next?` starts the thread's next run on a new runtime,
  # with one piece of each kind of work, between that answer and TurnWatch hearing it,
  # and resumes the `resumed` provider subagents earlier runs started
  # (`NativeSubagent.resume/3`), each running a command again in its own thread. With
  # `:mid` the next run starts and resumes them during the try instead, as the try
  # first comes to a subagent's thread, after it read the thread's subagents (review
  # of #1398).
  def recover(at, next?, resumed) do
    watch = Process.whereis(TurnWatch)
    pid = Process.get({__MODULE__, :runtime})
    run = run_id(latest())
    gate = make_ref()
    hold = {__MODULE__, :hold_once, [self(), gate]}
    Application.put_env(:hal_c2, :store_hook, hold)

    if next? == :mid,
      do: Application.put_env(:hal_c2, :streams_hook, {__MODULE__, :hold_child, [self(), watch]})

    send(watch, {:retry, run})

    {store, resumer} =
      receive do
        {:held, ^gate, store} ->
          {store, nil}

        {:held_child, try} ->
          # The test's own writes go by the store's hold.
          Application.delete_env(:hal_c2, :streams_hook)
          Application.delete_env(:hal_c2, :store_hook)
          ordinal = new_run()
          for id <- resumed, do: resume(id, ordinal)
          Application.put_env(:hal_c2, :store_hook, hold)
          send(try, :go)

          receive do
            {:held, ^gate, store} -> {store, ordinal}
          after
            @wait_ms -> raise "no try at recording #{run}"
          end
      after
        @wait_ms -> raise "no try at recording #{run}"
      end

    Application.delete_env(:hal_c2, :streams_hook)

    if at == :during_try do
      stop_runtime(pid, :crash)
      await_down(watch, pid)
    end

    :sys.suspend(watch)
    Application.delete_env(:hal_c2, :store_hook)
    send(store, {:go, gate})
    await_trace(watch, &match?({:attempted, ^run, :ok}, &1))
    if at == :after_answer, do: stop_runtime(pid, :crash)

    claim =
      if next? != false do
        ordinal = resumer || new_run()
        ids = Enum.map(@kinds, &{new_work(&1), &1})
        seed(Enum.flat_map(ids, fn {id, kind} -> work(id, ordinal, kind) end))
        for {id, kind} <- ids, do: child_thread(id, kind)
        unless resumer, do: for(id <- resumed, do: resume(id, ordinal))
        runtime() |> ask(fn -> TurnWatch.claim(@tid, run_id(ordinal)) end)
      end

    :sys.resume(watch)
    drain()
    if claim, do: :ok = answer(claim)
    {observe(), children()}
  end

  # --- the store -----------------------------------------------------------------

  # The store refuses the thread's writes, as a full disk does.
  def refuse_thread(:append_change, @tid) do
    if self() == Process.whereis(HalC2.Store), do: raise("the disk is full"), else: :ok
  end

  def refuse_thread(_stage, _stream_id), do: :ok

  # The store's first write to the thread waits for the test's go.
  def hold_once(test, gate, :append_change, @tid) do
    if self() == Process.whereis(HalC2.Store) and Process.put({:held, gate}, true) == nil do
      send(test, {:held, gate, self()})

      receive do
        {:go, ^gate} -> :ok
      end
    end

    :ok
  end

  def hold_once(_test, _gate, _stage, _stream_id), do: :ok

  # --- helpers -------------------------------------------------------------------

  defp run_id(ordinal), do: "run-#{ordinal}"

  defp run(ordinal),
    do: %{
      "id" => run_id(ordinal),
      "threadId" => @tid,
      "status" => "running",
      "ordinal" => ordinal,
      "providerInstanceId" => @instance,
      "rootNodeId" => "node-root-#{ordinal}"
    }

  # The entities of a piece of work, as `{kind, id}`.
  defp entities(id, :native),
    do: [
      {"subagent", "sub-#{id}"},
      {"node", "sub-#{id}"},
      {"turn-item", "turn-item:subagent:sub-#{id}"}
    ]

  defp entities(id, :command), do: [{"turn-item", "item-#{id}"}, {"node", "node-item-#{id}"}]

  defp entities(id, :delegated),
    do: [{"subagent", "del-#{id}"}, {"node", "del-#{id}"}, {"turn-item", "turn-item:del-#{id}"}]

  defp work(id, ordinal, kind) do
    run = run_id(ordinal)
    open = %{"runId" => run, "status" => "running"}

    case kind do
      :native ->
        [
          {"subagent", "sub-#{id}",
           Map.merge(open, %{"origin" => "provider_native", "childThreadId" => child_id(id)})},
          {"node", "sub-#{id}", open},
          {"turn-item", "turn-item:subagent:sub-#{id}",
           Map.merge(open, %{"type" => "subagent", "nodeId" => "sub-#{id}"})}
        ]

      :command ->
        [
          {"turn-item", "item-#{id}",
           Map.merge(open, %{"type" => "command_execution", "nodeId" => "node-item-#{id}"})},
          {"node", "node-item-#{id}", open}
        ]

      :delegated ->
        [
          {"subagent", "del-#{id}", Map.put(open, "origin", "app_owned")},
          {"node", "del-#{id}", open},
          {"turn-item", "turn-item:del-#{id}",
           Map.merge(open, %{"type" => "subagent", "nodeId" => "del-#{id}"})}
        ]
    end
    |> Enum.map(fn {kind, id, entity} ->
      Orchestration.create(kind, id, Map.put(entity, "id", id))
    end)
  end

  # A provider subagent's own thread, a command of its running.
  defp child_thread(id, :native) do
    item = %{
      "id" => child_item(id),
      "status" => "running",
      "type" => "command_execution",
      "ordinal" => 1
    }

    :ok =
      HalC2.Streams.transact(child_id(id), :thread, fn _stream ->
        {[
           Orchestration.create("thread", child_id(id), %{"id" => child_id(id), "title" => "Sub"}),
           Orchestration.create("turn-item", child_item(id), item)
         ], :ok}
      end)
  end

  defp child_thread(_id, _kind), do: :ok

  defp resume(id, ordinal) do
    entity = StreamState.get(HalC2.Streams.state(@tid), "subagent")["sub-#{id}"]
    entity = Map.put(entity, "threadId", @tid)
    HalC2.Orchestration.NativeSubagent.resume(%{run: run_id(ordinal)}, entity, "go on")
    item = &Map.merge(&1, %{"status" => "running", "completedAt" => nil})

    # A second recovery can resume a subagent whose item is already running: upsert
    # then has nothing to write.
    :ok =
      HalC2.Streams.transact(child_id(id), :thread, fn stream ->
        {List.wrap(Orchestration.upsert(stream, "turn-item", child_item(id), item)), :ok}
      end)
  end

  defp child_id(id), do: "child-#{id}"
  defp child_item(id), do: "child-item-#{id}"

  # The next run, created running.
  defp new_run do
    ordinal = latest() + 1
    Process.put({__MODULE__, :runs}, ordinal)
    seed([Orchestration.create("run", run_id(ordinal), run(ordinal))])
    ordinal
  end

  defp latest, do: Process.get({__MODULE__, :runs}, 0)

  # The next piece of work's id.
  defp new_work(kind) do
    work = Process.get({__MODULE__, :work}, %{})
    id = map_size(work) + 1
    Process.put({__MODULE__, :work}, Map.put(work, id, kind))
    id
  end

  defp seed(changes),
    do: :ok = HalC2.Streams.transact(@tid, :thread, fn _stream -> {changes, :ok} end)

  defp observe do
    stream = HalC2.Streams.state(@tid)
    watch = Process.whereis(TurnWatch)
    claims = watch_state(watch).claims
    {:monitors, monitors} = Process.info(watch, :monitors)

    runs = for {id, run} <- StreamState.get(stream, "run"), into: %{}, do: {id, run["status"]}

    entities =
      for kind <- ~w(subagent node turn-item),
          {id, entity} <- StreamState.get(stream, kind),
          into: %{},
          do: {{kind, id}, entity["status"]}

    %{
      runs: runs,
      entities: entities,
      driven: Map.new(runs, fn {id, _} -> {id, TurnWatch.driven?(id)} end),
      claimed: MapSet.new(Map.keys(claims)),
      monitors: length(monitors)
    }
  end

  # How the work in each provider subagent's thread reads, by its piece's id.
  defp children do
    for {id, :native} <- Process.get({__MODULE__, :work}, %{}),
        into: %{},
        do:
          {id,
           HalC2.Streams.state(child_id(id))
           |> StreamState.get("turn-item")
           |> get_in([child_item(id), "status"])}
  end

  # Waits until no try at recording a held end is running; with the store taking writes,
  # until every held end is recorded, its retries asked for at once.
  defp drain do
    watch = Process.whereis(TurnWatch)
    state = watch_state(watch)
    accepting? = Application.get_env(:hal_c2, :store_hook) == nil

    case Enum.find(state.pending, fn {_, ending} -> ending.trying end) do
      {run, _} ->
        await_trace(watch, &match?({:attempted, ^run, _}, &1))
        if accepting?, do: drain(), else: :ok

      nil ->
        case accepting? and Map.keys(state.pending) do
          [run | _] ->
            send(watch, {:retry, run})
            drain()

          _ ->
            :ok
        end
    end
  end

  # TurnWatch's state once it has handled everything it received before: the trace of
  # the read marks where it stood.
  defp watch_state(watch) do
    state = :sys.get_state(watch)
    me = self()
    await_trace(watch, &match?({:system, {^me, _}, :get_state}, &1))
    state
  end

  defp await_down(watch, pid),
    do: await_trace(watch, &match?({:DOWN, _, :process, ^pid, _}, &1))

  defp await_trace(watch, wanted?) do
    receive do
      {:trace, ^watch, :receive, message} ->
        if wanted?.(message), do: message, else: await_trace(watch, wanted?)
    after
      @wait_ms -> raise "TurnWatch never received what the step waits on"
    end
  end

  defp flush_traces do
    receive do
      {:trace, _, _, _} -> flush_traces()
    after
      0 -> :ok
    end
  end

  # --- runtimes ------------------------------------------------------------------

  # The live runtime, started if none lives.
  defp runtime do
    case Process.get({__MODULE__, :runtime}) do
      nil ->
        pid = spawn(&runtime_loop/0)
        Process.put({__MODULE__, :runtime}, pid)
        Process.put({__MODULE__, :spawned}, [pid | Process.get({__MODULE__, :spawned}, [])])
        pid

      pid ->
        pid
    end
  end

  defp ask(pid, fun) do
    ref = make_ref()
    send(pid, {:run, self(), ref, fun})
    ref
  end

  defp answer(ref) do
    receive do
      {^ref, result} -> result
    after
      @wait_ms -> raise "the runtime did not answer"
    end
  end

  defp runtime_loop do
    receive do
      {:run, from, ref, fun} ->
        send(from, {ref, fun.()})
        runtime_loop()

      :stop ->
        :ok
    end
  end

  defp stop_runtime(pid, reason) do
    ref = Process.monitor(pid)
    if reason == :crash, do: Process.exit(pid, :crash), else: send(pid, :stop)
    receive do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok)
    Process.delete({__MODULE__, :runtime})
  end
end
