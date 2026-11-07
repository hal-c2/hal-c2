defmodule HalC2.SnoozeWakePropTest do
  @moduledoc """
  A state machine over one thread's snooze and the runs that come and go around it
  (`features/threads/snooze.feature`): snooze, unsnooze, a queued message of the user's
  or one the MC sent for the agent (a notification, a delegated result), a run starting
  (the oldest queued one, or a run of its own), and a run ending completed or failed.

  The model keeps, for the latest run made, the snooze it began in and the one
  it ended in. After every command the test compares the real thread with it:

  - snoozing is refused exactly while a queued run carries the user's own message; a
    queued wake of the agent's does not stop it;
  - a snoozed thread is awake to automatic settlement (`Settlement.blocker/2`) exactly
    when its latest run both began and ended after the snooze; a run that began before
    it and fails or finishes later (a late failure) leaves the snooze alone, and so does a
    wake the MC sent for the agent when it finishes (its failure wakes the thread).

  The runs are written as the turn writer would leave them, with times placed against
  the snooze's own time stamp; no provider is behind them.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Orchestration
  alias HalC2.Orchestration.Settlement
  alias HalC2.Projection.JS
  alias HalC2.StreamState

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @thread "snooze-thread"
  @hour 3_600_000
  @half_hour 1_800_000

  property "a snoozed thread wakes exactly when its latest run began and ended after the snooze",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("snooze-wake")

        HalC2.Prop.start_services([
          {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
          HalC2.Streams,
          HalC2.Shell,
          HalC2.Orchestration.TurnWatch
        ])

        setup()
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ----------------------------------------------------------------------

  # snoozed, epoch: the number of the snooze in force (counts every snooze);
  # runs: %{id, ord, kind :user | :notification | :delegated | :direct, status :queued |
  #   :running | :completed | :failed, began, ended} where began and ended are the epoch
  #   whose snooze the run was in when it began and ended, nil when it was not snoozed.
  def initial_state, do: %{snoozed: false, epoch: 0, runs: [], next: 1}

  def command(state) do
    queued = Enum.filter(state.runs, &(&1.status == :queued))
    running = Enum.filter(state.runs, &(&1.status == :running))

    start_id =
      case Enum.sort_by(queued, & &1.ord) do
        [oldest | _] -> oldest.id
        [] -> "r#{state.next}"
      end

    frequency(
      [
        {4, {:call, __MODULE__, :snooze, []}},
        {3, {:call, __MODULE__, :unsnooze, []}},
        {3,
         {:call, __MODULE__, :queue, ["r#{state.next}", oneof(~w(user notification delegated)a)]}}
      ] ++
        if(running == [], do: [{4, {:call, __MODULE__, :start, [start_id]}}], else: []) ++
        if(running == [],
          do: [],
          else: [
            {5, {:call, __MODULE__, :finish, [hd(running).id, oneof(~w(completed failed)a)]}}
          ]
        )
    )
  end

  def precondition(state, {:call, _, :snooze, []}), do: not state.snoozed
  def precondition(state, {:call, _, :unsnooze, []}), do: state.snoozed

  def precondition(state, {:call, _, :queue, [id, _]}),
    do: id == "r#{state.next}"

  def precondition(state, {:call, _, :start, [id]}) do
    not Enum.any?(state.runs, &(&1.status == :running)) and
      (id == "r#{state.next}" or Enum.any?(state.runs, &(&1.id == id and &1.status == :queued)))
  end

  def precondition(state, {:call, _, :finish, [id, _]}),
    do: Enum.any?(state.runs, &(&1.id == id and &1.status == :running))

  def next_state(state, _result, {:call, _, :snooze, []}) do
    case expected_snooze(state) do
      :ok -> %{state | snoozed: true, epoch: state.epoch + 1}
      :error -> state
    end
  end

  def next_state(state, _result, {:call, _, :unsnooze, []}), do: %{state | snoozed: false}

  def next_state(state, _result, {:call, _, :queue, [id, kind]}) do
    run = %{id: id, ord: state.next, kind: kind, status: :queued, began: nil, ended: nil}
    %{state | runs: state.runs ++ [run], next: state.next + 1}
  end

  def next_state(state, _result, {:call, _, :start, [id]}) do
    stamp = if state.snoozed, do: state.epoch

    case Enum.find(state.runs, &(&1.id == id)) do
      nil ->
        run = %{
          id: id,
          ord: state.next,
          kind: :direct,
          status: :running,
          began: stamp,
          ended: nil
        }

        %{state | runs: state.runs ++ [run], next: state.next + 1}

      _ ->
        update_run(state, id, &%{&1 | status: :running, began: stamp})
    end
  end

  def next_state(state, _result, {:call, _, :finish, [id, outcome]}) do
    stamp = if state.snoozed, do: state.epoch
    update_run(state, id, &%{&1 | status: outcome, ended: stamp})
  end

  defp update_run(state, id, fun),
    do: %{state | runs: Enum.map(state.runs, &if(&1.id == id, do: fun.(&1), else: &1))}

  # Snoozing is refused while a queued run carries the user's own message.
  defp expected_snooze(state) do
    if Enum.any?(state.runs, &(&1.status == :queued and &1.kind == :user)),
      do: :error,
      else: :ok
  end

  # The latest run made, a queued one included: it has not ended, so it hides the end
  # of the run before it.
  defp latest(state), do: Enum.max_by(state.runs, & &1.ord, fn -> nil end)

  # The model's answer to whether the snoozed thread is awake: its latest run ended and
  # both its start and its end fall after this snooze.
  defp awake?(state) do
    case latest(state) do
      # A wake the MC sent for the agent that finishes is not news; its failure is.
      %{status: :completed, kind: kind} when kind in [:notification, :delegated] ->
        false

      %{status: status, began: began, ended: ended} when status in [:completed, :failed] ->
        began == state.epoch and ended == state.epoch

      _ ->
        false
    end
  end

  def postcondition(state, {:call, _, fun, _} = call, result) do
    after_state = next_state(state, nil, call)
    {parked, row} = parked?()

    reply_ok? = fun != :snooze or result == {:snooze, expected_snooze(state)}
    snoozed_ok? = row["snoozedUntil"] != nil == after_state.snoozed
    parked_ok? = parked == (after_state.snoozed and not awake?(after_state))

    unless reply_ok? and snoozed_ok? and parked_ok? do
      IO.puts(
        "#{fun}: result #{inspect(result)}, parked #{parked}, row snoozedUntil " <>
          "#{inspect(row["snoozedUntil"])} snoozedAt #{inspect(row["snoozedAt"])} " <>
          "started #{inspect(row["latestRunStartedAt"])} completed " <>
          "#{inspect(row["latestRunCompletedAt"])}\n  model #{inspect(after_state)}"
      )
    end

    reply_ok? and snoozed_ok? and parked_ok?
  end

  # --- commands ---------------------------------------------------------------------

  def snooze do
    # The MC stamps a snooze with the wall clock; the times the runs carry are placed
    # against the stamp of their own snooze, so keep the clock past the last of them.
    wait_past(Process.get(:latest_ts, 0))

    reply =
      case Orchestration.dispatch(%{
             "type" => "thread.snooze",
             "threadId" => @thread,
             "snoozedUntil" => "#{Date.add(Date.utc_today(), 1)}T09:00:00.000Z"
           }) do
        {:ok, _} -> :ok
        {:error, _} -> :error
      end

    {:snooze, reply}
  end

  def unsnooze do
    {:ok, _} = Orchestration.dispatch(%{"type" => "thread.unsnooze", "threadId" => @thread})
    {:unsnooze, :ok}
  end

  def queue(id, kind) do
    message = "m-#{id}"

    extra =
      case kind do
        :user -> %{}
        :notification -> %{"notification" => %{"kind" => "background"}}
        :delegated -> %{"delegatedCompletion" => %{"taskIds" => ["t"], "acceptedAt" => nil}}
      end

    ordinal = ordinal(id)

    commit([
      {"message", message,
       Map.merge(%{"id" => message, "role" => "user", "text" => "queued #{id}"}, extra)},
      {"run", id,
       %{
         "id" => id,
         "ordinal" => ordinal,
         "status" => "queued",
         "userMessageId" => message,
         "requestedAt" => iso(past(@hour))
       }}
    ])

    {:queue, :ok}
  end

  # The run starts, from the queue or on its own, with its start placed after the
  # snooze in force, or before any snooze to come.
  def start(id) do
    at = stamp(1, @hour)
    track(at)

    run =
      case run(id) do
        nil -> %{"id" => id, "ordinal" => ordinal(id), "requestedAt" => iso(at)}
        existing -> existing
      end

    commit([
      {"run", id, Map.merge(run, %{"status" => "running", "startedAt" => iso(at)})}
    ])

    {:start, :ok}
  end

  def finish(id, outcome) do
    at = stamp(2, @half_hour)
    track(at)

    commit([
      {"run", id, %{"status" => Atom.to_string(outcome), "completedAt" => iso(at)}}
    ])

    {:finish, :ok}
  end

  # --- the real side ----------------------------------------------------------------

  defp setup do
    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => @thread,
        "projectId" => "project-1",
        "title" => "Snoozed",
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default"
      })
  end

  defp ordinal("r" <> n), do: String.to_integer(n)

  # While snoozed, `after_ms` past the snooze's stamp; otherwise `ago` before now, ahead
  # of every snooze still to come.
  defp stamp(after_ms, ago) do
    case JS.epoch_ms(thread()["snoozedAt"]) do
      nil -> past(ago)
      snoozed_at -> snoozed_at + after_ms
    end
  end

  defp past(ms), do: System.system_time(:millisecond) - ms
  defp iso(ms), do: JS.iso(ms)

  defp track(at), do: Process.put(:latest_ts, max(Process.get(:latest_ts, 0), at))

  defp wait_past(ts) do
    if System.system_time(:millisecond) <= ts, do: wait_past(ts)
  end

  defp stream, do: HalC2.Streams.Server.state(HalC2.Streams.ensure(@thread))
  defp thread, do: StreamState.get(stream(), "thread")[@thread]
  defp run(id), do: StreamState.get(stream(), "run")[id]

  defp commit(entities) do
    {:ok, _} =
      HalC2.Streams.commit(
        @thread,
        :thread,
        for({kind, id, s} <- entities, do: {kind, id, %{"s" => s}})
      )
  end

  # Whether automatic settlement finds the snoozed thread parked: the run in progress
  # and the other blockers are set aside, so the snooze is the only thing it can see.
  defp parked? do
    {"thread", row} = HalC2.Projection.row(HalC2.Store.path(), @thread, stream())
    row = Map.put(row, "activityRunStatus", nil)
    {Settlement.blocker(row, System.system_time(:millisecond)) == "snoozed", row}
  end
end
