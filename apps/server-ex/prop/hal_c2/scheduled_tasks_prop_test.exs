defmodule HalC2.ScheduledTasksPropTest do
  @moduledoc """
  `HalC2.ScheduledTasks` against a model of its tasks and the clock. Time is the
  model's: the service's clock reads a value the commands move, and a tick is sent by
  hand, so a run is due when the model says and never when a timer happens to fire.
  Runs go to a fake that reports each firing to the test, so "fires exactly once"
  is counted, not slept on.

  The promises modelled: the next run of an interval is its period after now and of a
  fixed time is the next wall-clock slot on a permitted weekday; a due task fires once
  per tick however late the tick; a fixed-time run missed by ten minutes or more moves
  to its next slot instead of firing; a run asked for by hand neither shifts nor doubles
  the schedule; paused and deleted tasks never fire; a task that fails or whose run
  crashes is recorded and the scheduler lives on; everything survives a restart, and a
  restart that slept through due times fires them once.

  The clock stays inside June 2026 so the wall clock has no daylight-saving change, in
  whatever zone the machine is in.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.ScheduledTasks

  @moduletag timeout: :infinity

  @day 86_400_000
  @grace 600_000
  @min_interval 60_000
  @start ~U[2026-06-01 00:00:00.000Z]
  @clock {__MODULE__, :clock}

  property "tasks fire when due, once, and the schedule survives everything",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        setup()
        {history, state, result} = run_commands(__MODULE__, cmds)
        teardown()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  defp setup do
    HalC2.Prop.scratch_home("scheduled-tasks")
    :persistent_term.put(@clock, DateTime.to_unix(@start, :millisecond))

    Application.put_env(:hal_c2, :scheduled_tasks_clock, fn ->
      DateTime.from_unix!(:persistent_term.get(@clock), :millisecond)
    end)

    test = self()

    Application.put_env(:hal_c2, :scheduled_tasks_fire, fn task, key ->
      send(test, {:fired, task["id"], key})

      case task["prompt"] do
        "ok" -> {:ok, %{}}
        "fail" -> {:error, "no"}
        "crash" -> exit(:crashed)
      end
    end)

    HalC2.Prop.start_services([ScheduledTasks])
    {:ok, _} = ScheduledTasks.subscribe(self())
  end

  defp teardown do
    HalC2.Prop.stop_services()
    :persistent_term.erase(@clock)
    Application.delete_env(:hal_c2, :scheduled_tasks_clock)
    Application.delete_env(:hal_c2, :scheduled_tasks_fire)
  end

  # --- model ------------------------------------------------------------------

  # tasks: id => %{schedule, enabled, next (ms or nil), prompt, status, count}.
  # offset: the machine's wall clock minus UTC, which does not change in June.
  def initial_state do
    start = DateTime.to_unix(@start, :millisecond)

    {{y, mo, d}, {h, mi, s}} =
      :calendar.universal_time_to_local_time({{@start.year, @start.month, @start.day}, {0, 0, 0}})

    local = :calendar.datetime_to_gregorian_seconds({{y, mo, d}, {h, mi, s}})
    utc = :calendar.datetime_to_gregorian_seconds({{2026, 6, 1}, {0, 0, 0}})
    %{now: start, offset: (local - utc) * 1000, tasks: %{}}
  end

  def command(state) do
    ids = oneof(["t1", "t2", "t3"])
    known = Map.keys(state.tasks)

    frequency(
      [
        {6,
         {:call, __MODULE__, :upsert, [ids, schedule(), boolean_enabled(), prompt(), existing()]}},
        {3, {:call, __MODULE__, :set_enabled, [ids, boolean_enabled()]}},
        {2, {:call, __MODULE__, :delete, [ids]}},
        {3, {:call, __MODULE__, :run_now, [ids]}},
        {8, {:call, __MODULE__, :advance, [delta(state)]}},
        {2, {:call, __MODULE__, :restart_after, [oneof([0, 5_000, 1_800_000, 7_200_000])]}},
        {1, {:call, __MODULE__, :list, []}}
      ] ++
        if(known == [],
          do: [],
          else: [{4, {:call, __MODULE__, :run_now, [oneof(known)]}}]
        )
    )
  end

  defp boolean_enabled, do: frequency([{4, true}, {1, false}])
  defp existing, do: frequency([{4, false}, {1, true}])

  defp prompt, do: frequency([{8, "ok"}, {2, "fail"}, {1, "crash"}])

  # Valid schedules, and now and then one the service must refuse. A time of day may
  # be written "9:05" or "09:05"; no weekdays and all seven both mean every day.
  defp schedule do
    time = oneof(["0:00", "00:00", "7:30", "09:05", "9:05", "12:00", "23:59"])

    weekdays =
      oneof([[], [0, 1, 2, 3, 4, 5, 6], [1, 2, 3, 4, 5], [5, 1, 3], [0], [6, 6, 0], [2]])

    frequency([
      {3, {:interval, oneof([60_000, 90_000, 3_600_000])}},
      {4, {:fixed, time, weekdays}},
      {1, oneof([{:interval, 59_999}, {:fixed, "24:00", []}, {:fixed, "9:5", []}])}
    ])
  end

  # Time passing: seconds, minutes, hours, and the instants a rule turns on: exactly
  # when the first task is due, and either side of the ten-minute grace.
  defp delta(state) do
    due =
      for {_, %{enabled: true, next: next}} <- state.tasks, next != nil, do: next - state.now

    free =
      oneof([1_000, 30_000, 61_000, 90_000, 660_000, 3_600_000, 7_200_000, 43_200_000])

    if due == [] do
      free
    else
      first = Enum.min(due)

      frequency([
        {4, free},
        {3, oneof([max(first, 1), first + 1, first + 599_999, first + 600_000, first + 600_001])}
      ])
    end
  end

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :upsert, args}), do: upsert_model(state, args)

  def next_state(state, _result, {:call, _, :set_enabled, [id, enabled]}) do
    case state.tasks[id] do
      nil ->
        state

      task ->
        next =
          cond do
            not enabled -> nil
            task.enabled and task.next -> task.next
            true -> next_run(state, task.schedule, state.now)
          end

        put_in(state.tasks[id], %{task | enabled: enabled, next: next})
    end
  end

  def next_state(state, _result, {:call, _, :delete, [id]}),
    do: %{state | tasks: Map.delete(state.tasks, id)}

  def next_state(state, _result, {:call, _, :run_now, [id]}) do
    case state.tasks[id] do
      nil ->
        state

      task ->
        # A run by hand leaves the pending run where it was; a paused task has none.
        task = ran(task)
        put_in(state.tasks[id], %{task | next: if(task.enabled, do: task.next)})
    end
  end

  def next_state(state, _result, {:call, _, :advance, [delta]}) do
    {state, _fired} = tick(%{state | now: state.now + delta})
    state
  end

  def next_state(state, _result, {:call, _, :restart_after, [delta]}) do
    {state, _fired} = tick(%{state | now: state.now + delta})
    state
  end

  def next_state(state, _result, _call), do: state

  # Every enabled task that is due at `now` runs once, and is aimed afresh, however
  # long overdue; a fixed time that is ten minutes or more overdue is only re-aimed.
  defp tick(state) do
    Enum.reduce(Enum.sort(state.tasks), {state, []}, fn {id, task}, {state, fired} ->
      cond do
        not task.enabled or task.next == nil or task.next > state.now ->
          {state, fired}

        match?({:fixed, _, _}, task.schedule) and state.now - task.next >= @grace ->
          {put_in(state.tasks[id].next, next_run(state, task.schedule, state.now)), fired}

        true ->
          task = ran(task)
          task = %{task | next: next_run(state, task.schedule, state.now)}
          {put_in(state.tasks[id], task), [id | fired]}
      end
    end)
  end

  defp ran(task) do
    status = if task.prompt == "ok", do: "succeeded", else: "failed"
    %{task | status: status, count: task.count + 1}
  end

  defp upsert_model(state, [id, schedule, enabled, prompt, require_existing]) do
    existing = state.tasks[id]

    cond do
      require_existing and existing == nil ->
        state

      not valid?(schedule) ->
        state

      true ->
        keep = existing != nil and existing.enabled and same?(existing.schedule, schedule)

        next =
          cond do
            not enabled -> nil
            keep and existing.next -> existing.next
            true -> next_run(state, schedule, state.now)
          end

        task = %{
          schedule: schedule,
          enabled: enabled,
          next: next,
          prompt: prompt,
          status: if(existing, do: existing.status, else: "never"),
          count: if(existing, do: existing.count, else: 0)
        }

        put_in(state.tasks[id], task)
    end
  end

  defp valid?({:interval, ms}), do: ms >= @min_interval
  defp valid?({:fixed, time, _}), do: time_of_day(time) != nil

  defp same?({:interval, a}, {:interval, b}), do: a == b

  defp same?({:fixed, t1, d1}, {:fixed, t2, d2}),
    do: time_of_day(t1) == time_of_day(t2) and day_set(d1) == day_set(d2)

  defp same?(_, _), do: false

  defp time_of_day(time) do
    with [h, m] <- String.split(time, ":"),
         true <- byte_size(m) == 2,
         {h, ""} <- Integer.parse(h),
         {m, ""} <- Integer.parse(m),
         true <- h in 0..23 and m in 0..59 do
      {h, m}
    else
      _ -> nil
    end
  end

  # No weekdays means every day.
  defp day_set(days) do
    case MapSet.new(days) do
      set when set == %MapSet{} -> MapSet.new(0..6)
      set -> set
    end
  end

  # The next run after `from` (ms): an interval's period on, or the first wall-clock
  # slot after it on a permitted weekday. Local days are counted from the epoch, a
  # Thursday, with Sunday as 0.
  defp next_run(_state, {:interval, ms}, from), do: from + ms

  defp next_run(state, {:fixed, time, days}, from) do
    {h, m} = time_of_day(time)
    days = day_set(days)
    first_day = div(from + state.offset, @day)

    Enum.find_value(0..8, fn n ->
      day = first_day + n
      at = day * @day + (h * 60 + m) * 60_000 - state.offset

      if rem(day + 4, 7) in days and at > from, do: at
    end)
  end

  # What a client sees of a task, from the model and from the service.
  defp view(state) do
    for {id, task} <- Enum.sort(state.tasks),
        do: {id, task.enabled, task.next && iso(task.next), task.status, task.count}
  end

  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  def postcondition(state, call, {result, tasks, fired}) do
    after_state = next_state(state, nil, call)

    tasks == view(after_state) and fired == expected_fires(state, call) and
      ok?(state, call, result)
  end

  def postcondition(_state, _call, _other), do: false

  defp expected_fires(state, {:call, _, op, [delta]}) when op in [:advance, :restart_after] do
    {_, fired} = tick(%{state | now: state.now + delta})
    Enum.sort(fired)
  end

  defp expected_fires(state, {:call, _, :run_now, [id]}),
    do: if(state.tasks[id], do: [id], else: [])

  defp expected_fires(_state, _call), do: []

  defp ok?(state, {:call, _, :upsert, [id, schedule, _, _, require_existing]}, result) do
    if (require_existing and state.tasks[id] == nil) or not valid?(schedule),
      do: match?({:error, %{"_tag" => "ScheduledTaskError"}}, result),
      else: match?({:ok, %{"task" => %{"id" => ^id}}}, result)
  end

  defp ok?(state, {:call, _, op, [id | _]}, result)
       when op in [:set_enabled, :delete, :run_now] do
    if state.tasks[id] == nil,
      do: match?({:error, %{"_tag" => "ScheduledTaskError"}}, result),
      else: match?({:ok, _}, result)
  end

  defp ok?(_state, _call, result), do: result == :ok

  # --- system under test --------------------------------------------------------

  defp wrap(result) do
    {result, ScheduledTasks.list() |> then(fn {:ok, %{"tasks" => tasks}} -> view_of(tasks) end)}
  end

  defp view_of(tasks) do
    for task <- Enum.sort_by(tasks, & &1["id"]),
        do:
          {task["id"], task["enabled"], task["nextRunAt"], task["lastRunStatus"],
           task["runCount"]}
  end

  defp finish({result, tasks}), do: {result, tasks, fired()}

  # Messages the fake sent for runs started so far, as the ids fired.
  defp fired(acc \\ []) do
    receive do
      {:fired, id, _key} -> fired([id | acc])
    after
      0 -> Enum.sort(acc)
    end
  end

  def upsert(id, schedule, enabled, prompt, require_existing) do
    flush()

    input = %{
      "id" => id,
      "title" => "Task #{id}",
      "prompt" => prompt,
      "enabled" => enabled,
      "schedule" => schedule_input(schedule),
      "projectId" => "p1",
      "threadId" => nil,
      "requireExisting" => require_existing
    }

    input |> ScheduledTasks.upsert() |> wrap() |> finish()
  end

  def set_enabled(id, enabled) do
    flush()
    %{"id" => id, "enabled" => enabled} |> ScheduledTasks.set_enabled() |> wrap() |> finish()
  end

  def delete(id) do
    flush()
    %{"id" => id} |> ScheduledTasks.delete() |> wrap() |> finish()
  end

  # Replies once the run is recorded, so the fake has reported by the time it returns.
  def run_now(id) do
    flush()
    %{"id" => id} |> ScheduledTasks.run_now() |> wrap() |> finish()
  end

  def list do
    flush()
    {:ok, %{"tasks" => tasks}} = ScheduledTasks.list()
    {:ok, view_of(tasks), []}
  end

  # The clock moves and the service ticks; every run it starts has been reported and
  # recorded when this returns.
  def advance(delta) do
    flush()
    :persistent_term.put(@clock, :persistent_term.get(@clock) + delta)
    tick_and_settle()
  end

  # The service stops, the clock moves while it is down, and it starts again.
  def restart_after(delta) do
    flush()
    sup = Process.get({HalC2.Prop, :services})
    :ok = Supervisor.terminate_child(sup, ScheduledTasks)
    :persistent_term.put(@clock, :persistent_term.get(@clock) + delta)
    {:ok, _} = Supervisor.restart_child(sup, ScheduledTasks)
    {:ok, _} = ScheduledTasks.subscribe(self())
    tick_and_settle()
  end

  defp tick_and_settle do
    send(ScheduledTasks, :tick)
    :sys.get_state(ScheduledTasks)
    settle()

    {:ok, tasks} =
      ScheduledTasks.list() |> then(fn {:ok, %{"tasks" => t}} -> {:ok, view_of(t)} end)

    {:ok, tasks, fired()}
  end

  # Waits, on the service's own notifications, until no run is in flight.
  defp settle do
    {:ok, %{"tasks" => tasks}} = ScheduledTasks.list()

    if Enum.any?(tasks, &(&1["lastRunStatus"] == "running")) do
      receive do
        {:hal_c2_scheduled_tasks, _node, _tasks} -> settle()
      after
        5_000 -> :timeout
      end
    else
      :ok
    end
  end

  defp flush do
    receive do
      {:hal_c2_scheduled_tasks, _, _} -> flush()
    after
      0 -> :ok
    end
  end

  defp schedule_input({:interval, ms}), do: %{"type" => "interval", "everyMs" => ms}

  defp schedule_input({:fixed, time, weekdays}),
    do: %{"type" => "fixed_time", "timeOfDay" => time, "weekdays" => weekdays}
end
