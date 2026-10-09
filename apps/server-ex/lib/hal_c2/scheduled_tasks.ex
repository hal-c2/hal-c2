defmodule HalC2.ScheduledTasks do
  @moduledoc """
  Scheduled tasks (`scheduledTasks.*`): prompts that run on an interval or at a
  local time of day, in a thread or in a new thread each time.

  Tasks live in `<home>/scheduled-tasks.json`. One timer wakes for the next due
  run, at least every minute, so a changed clock or a sleeping host is noticed.
  A fixed-time run missed by more than ten minutes (the host was off) moves to
  its next slot instead of firing late. Watchers (client sockets) get
  `{:hal_c2_scheduled_tasks, mc, tasks}` whenever a task changes.
  """

  use GenServer

  alias HalC2.Orchestration

  @min_interval 60_000
  @missed_grace 10 * 60_000
  @max_sleep 60_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def list(_input \\ %{}), do: {:ok, %{"tasks" => GenServer.call(__MODULE__, :list)}}
  def upsert(input), do: GenServer.call(__MODULE__, {:upsert, input})
  def delete(%{"id" => id}), do: GenServer.call(__MODULE__, {:delete, id})

  def set_enabled(%{"id" => id, "enabled" => enabled}),
    do: GenServer.call(__MODULE__, {:set_enabled, id, enabled})

  @doc "Runs a task now and replies once its message is sent."
  def run_now(%{"id" => id}), do: GenServer.call(__MODULE__, {:run_now, id}, 120_000)

  def subscribe(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})
  def unsubscribe(pid), do: GenServer.cast(__MODULE__, {:unsubscribe, pid})

  # --- server ------------------------------------------------------------------

  @impl true
  def init(nil) do
    # Runs are linked to this process; trapping exits keeps one that exits from taking
    # the scheduler down.
    Process.flag(:trap_exit, true)
    path = Path.join(HalC2.Paths.data_dir(), "scheduled-tasks.json")

    tasks =
      for task <- load(path), into: %{} do
        # A run this MC was in the middle of when it stopped did not finish.
        task =
          if task["lastRunStatus"] == "running",
            do: finished(task, {:error, "The server stopped during this run."}, now()),
            else: task

        {task["id"], task}
      end

    state = %{path: path, tasks: tasks, runs: %{}, watchers: %{}, timer: nil}
    {:ok, schedule(state)}
  end

  @impl true
  def handle_call(:list, _from, state), do: {:reply, sorted(state), state}

  def handle_call({:subscribe, pid}, _from, state) do
    watchers = Map.put_new_lazy(state.watchers, pid, fn -> Process.monitor(pid) end)
    {:reply, {:ok, sorted(state)}, %{state | watchers: watchers}}
  end

  def handle_call({:upsert, input}, _from, state) do
    existing = input["id"] && state.tasks[input["id"]]

    cond do
      input["requireExisting"] == true and existing == nil ->
        {:reply, error("Schedule task not found.", input["id"]), state}

      invalid_schedule?(input["schedule"]) ->
        {:reply, error("The schedule is not valid.", input["id"]), state}

      true ->
        task = build(input, existing, now())
        {:reply, {:ok, %{"task" => task}}, state |> put(task) |> changed()}
    end
  end

  def handle_call({:delete, id}, _from, state) do
    case Map.pop(state.tasks, id) do
      {nil, _} ->
        {:reply, error("Schedule task not found.", id), state}

      {_, tasks} ->
        {:reply, {:ok, %{"id" => id}}, changed(stop_runs(%{state | tasks: tasks}, id))}
    end
  end

  def handle_call({:set_enabled, id, enabled}, _from, state) do
    case state.tasks[id] do
      nil ->
        {:reply, error("Schedule task not found.", id), state}

      task ->
        at = now()

        task =
          Map.merge(task, %{
            "enabled" => enabled,
            "updatedAt" => iso(at),
            "nextRunAt" =>
              cond do
                not enabled -> nil
                # Enabling a task that is already on keeps its pending run.
                task["enabled"] and task["nextRunAt"] -> task["nextRunAt"]
                true -> next_run(task["schedule"], at)
              end
          })

        {:reply, {:ok, %{"task" => task}}, state |> put(task) |> changed()}
    end
  end

  def handle_call({:run_now, id}, from, state) do
    cond do
      state.tasks[id] == nil -> {:reply, error("Schedule task not found.", id), state}
      running?(state, id) -> {:reply, error("Schedule task is already running.", id), state}
      true -> {:noreply, start_run(state, state.tasks[id], "manual", from)}
    end
  end

  @impl true
  def handle_cast({:unsubscribe, pid}, state) do
    {ref, watchers} = Map.pop(state.watchers, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:noreply, %{state | watchers: watchers}}
  end

  @impl true
  def handle_info(:tick, state) do
    at = now()
    before = state.tasks
    state = %{state | timer: nil}

    state =
      state.tasks
      |> Map.values()
      |> Enum.filter(&due?(&1, at))
      |> Enum.reduce(state, fn task, state ->
        cond do
          running?(state, task["id"]) ->
            state

          missed?(task, at) ->
            put(state, Map.put(task, "nextRunAt", next_run(task["schedule"], at)))

          true ->
            start_run(state, task, "scheduled", nil)
        end
      end)

    # A tick that starts nothing (a due task still running) only re-arms the timer.
    {:noreply, if(state.tasks == before, do: schedule(state), else: changed(state))}
  end

  # A run finished: record it, and answer a waiting "run now".
  def handle_info({:run_done, pid, result}, %{runs: runs} = state) when is_map_key(runs, pid) do
    Process.demonitor(runs[pid].ref, [:flush])
    {state, _task} = complete(state, pid, result)
    {:noreply, changed(state)}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{runs: runs} = state)
      when is_map_key(runs, pid) do
    {state, _task} = complete(state, pid, {:error, "The run stopped: #{inspect(reason)}"})
    {:noreply, changed(state)}
  end

  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, %{state | watchers: Map.delete(state.watchers, pid)}}

  def handle_info(_other, state), do: {:noreply, state}

  # A scheduler updated in place (`HalC2.Hot`) does not run `init/1` again, and one
  # from before runs were linked does not trap exits yet.
  @impl true
  def code_change(_old, state, _extra) do
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  # --- runs --------------------------------------------------------------------

  defp start_run(state, task, trigger, from) do
    at = now()
    fire_key = "#{task["id"]}:#{DateTime.to_unix(at, :millisecond)}:#{trigger}"
    running = Map.merge(task, %{"lastRunStatus" => "running", "updatedAt" => iso(at)})
    # Linked, so a scheduler that dies takes its runs with it, and monitored, so a run
    # that exits fails its task.
    parent = self()

    {pid, ref} =
      :erlang.spawn_opt(
        fn -> send(parent, {:run_done, self(), fire(running, fire_key)}) end,
        [:link, :monitor]
      )

    state
    |> put(running)
    |> Map.update!(
      :runs,
      &Map.put(&1, pid, %{ref: ref, id: task["id"], started: at, from: from, trigger: trigger})
    )
    |> changed()
  end

  # A deleted task's runs end with it, so a task created later under the same id does
  # not take the result of a run that was not its own.
  defp stop_runs(state, id) do
    {gone, runs} = Enum.split_with(state.runs, fn {_, run} -> run.id == id end)

    for {pid, %{ref: ref, from: from}} <- gone do
      Process.demonitor(ref, [:flush])
      Process.exit(pid, :kill)
      if from, do: GenServer.reply(from, error("Schedule task not found.", id))
    end

    %{state | runs: Map.new(runs)}
  end

  defp complete(state, pid, result) do
    {%{id: id, started: started, from: from} = run, runs} = Map.pop(state.runs, pid)
    state = %{state | runs: runs}

    case state.tasks[id] do
      # Deleted while it ran.
      nil ->
        if from, do: GenServer.reply(from, error("Schedule task not found.", id))
        {state, nil}

      task ->
        task = finished(task, result, started, run[:trigger])
        if from, do: GenServer.reply(from, {:ok, %{"task" => task}})
        {put(state, task), task}
    end
  end

  # A scheduled run aims the next one afresh; a run asked for by hand ("manual")
  # leaves the schedule where it was, so the pending run still fires when due.
  defp finished(task, result, started, trigger \\ "scheduled") do
    at = now()

    next =
      cond do
        not task["enabled"] -> nil
        trigger == "manual" and task["nextRunAt"] != nil -> task["nextRunAt"]
        true -> next_run(task["schedule"], at)
      end

    Map.merge(task, %{
      "updatedAt" => iso(at),
      "lastRunAt" => iso(started),
      "lastRunStatus" => if(result == :ok, do: "succeeded", else: "failed"),
      "lastRunError" =>
        case result do
          :ok -> nil
          {:error, message} -> message
        end,
      "runCount" => (task["runCount"] || 0) + 1,
      "nextRunAt" => next
    })
  end

  # Sends the prompt: into the task's thread, or as the first message of a new one.
  defp fire(task, fire_key) do
    command_id = "scheduled-task:#{fire_key}"
    message_id = "scheduled-task-message:#{fire_key}"

    result =
      cond do
        # Tests fire into a fake of their own.
        fake = Application.get_env(:hal_c2, :scheduled_tasks_fire) ->
          fake.(task, fire_key)

        task["threadId"] ->
          Orchestration.dispatch(%{
            "type" => "message.dispatch",
            "commandId" => command_id,
            "threadId" => task["threadId"],
            "messageId" => message_id,
            "scheduledTaskId" => task["id"],
            "text" => task["prompt"],
            "attachments" => [],
            "modelSelection" => task["modelSelection"],
            "createdBy" => task["createdBy"],
            "creationSource" => task["creationSource"],
            "dispatchMode" => %{"type" => "queue_after_active"}
          })

        true ->
          Orchestration.launch_thread(%{
            "commandId" => command_id,
            "projectId" => task["projectId"],
            "title" => task["title"],
            "modelSelection" => task["modelSelection"],
            "runtimeMode" => task["runtimeMode"],
            "interactionMode" => task["interactionMode"],
            "workspaceStrategy" => task["workspaceStrategy"],
            "createdBy" => task["createdBy"],
            "creationSource" => task["creationSource"],
            "initialMessage" => %{
              "messageId" => message_id,
              "scheduledTaskId" => task["id"],
              "text" => task["prompt"],
              "attachments" => []
            }
          })
      end

    case result do
      {:ok, _} -> :ok
      {:error, %{"message" => message}} -> {:error, message}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      other -> {:error, inspect(other)}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  # --- tasks -------------------------------------------------------------------

  defp build(input, existing, at) do
    base =
      existing ||
        %{
          "id" => input["id"] || HalC2.Environment.uuid4(),
          "createdAt" => iso(at),
          "lastRunAt" => nil,
          "lastRunStatus" => "never",
          "lastRunError" => nil,
          "runCount" => 0
        }

    task =
      base
      |> Map.merge(
        Map.take(
          input,
          ~w(title prompt enabled schedule projectId workspaceStrategy modelSelection runtimeMode interactionMode)
        )
      )
      |> Map.merge(%{
        "threadId" => input["threadId"],
        "createdBy" => input["createdBy"] || base["createdBy"] || "user",
        "creationSource" => input["creationSource"] || base["creationSource"] || "web",
        "updatedAt" => iso(at)
      })

    # An unchanged schedule keeps its pending run; a new one is aimed afresh.
    keep =
      existing && existing["enabled"] && same_schedule?(existing["schedule"], task["schedule"])

    next =
      cond do
        not task["enabled"] -> nil
        keep && existing["nextRunAt"] -> existing["nextRunAt"]
        true -> next_run(task["schedule"], at)
      end

    Map.put(task, "nextRunAt", next)
  end

  # Whether two schedules fire at the same times: "9:00" is "09:00", and no weekdays
  # is every weekday.
  defp same_schedule?(%{"type" => "fixed_time"} = a, %{"type" => "fixed_time"} = b) do
    time_of_day(a["timeOfDay"]) != nil and
      time_of_day(a["timeOfDay"]) == time_of_day(b["timeOfDay"]) and
      weekday_key(a["weekdays"]) == weekday_key(b["weekdays"])
  end

  defp same_schedule?(a, b), do: a == b

  defp weekday_key(weekdays) do
    case weekdays |> List.wrap() |> Enum.uniq() |> Enum.sort() do
      days when length(days) in [0, 7] -> :daily
      days -> days
    end
  end

  defp invalid_schedule?(%{"type" => "interval", "everyMs" => ms}),
    do: not (is_integer(ms) and ms >= @min_interval)

  defp invalid_schedule?(%{"type" => "fixed_time", "timeOfDay" => time}),
    do: time_of_day(time) == nil

  defp invalid_schedule?(_), do: true

  @doc false
  # The first run after `from` (a UTC `DateTime`), as an ISO string, or nil.
  def next_run(%{"type" => "interval", "everyMs" => ms}, from),
    do: from |> DateTime.add(max(ms, @min_interval), :millisecond) |> iso()

  def next_run(%{"type" => "fixed_time", "timeOfDay" => time} = schedule, from) do
    weekdays = MapSet.new(schedule["weekdays"] || [])

    local =
      from
      |> DateTime.to_naive()
      |> NaiveDateTime.to_erl()
      |> :calendar.universal_time_to_local_time()

    today = local |> NaiveDateTime.from_erl!() |> NaiveDateTime.to_date()

    with {hour, minute} <- time_of_day(time) do
      Enum.find_value(0..7, fn offset ->
        date = Date.add(today, offset)
        weekday = rem(Date.day_of_week(date), 7)

        with true <- MapSet.size(weekdays) == 0 or MapSet.member?(weekdays, weekday),
             [utc | _] <-
               :calendar.local_time_to_universal_time_dst({Date.to_erl(date), {hour, minute, 0}}),
             at = DateTime.from_naive!(NaiveDateTime.from_erl!(utc), "Etc/UTC"),
             :gt <- DateTime.compare(at, from) do
          iso(at)
        else
          _ -> nil
        end
      end)
    end
  end

  def next_run(_schedule, _from), do: nil

  defp time_of_day(time) when is_binary(time) do
    case Regex.run(~r/^([01]?\d|2[0-3]):([0-5]\d)$/, String.trim(time)) do
      [_, hour, minute] -> {String.to_integer(hour), String.to_integer(minute)}
      _ -> nil
    end
  end

  defp time_of_day(_), do: nil

  defp due?(task, at), do: task["enabled"] and before?(task["nextRunAt"], at, 0)

  defp missed?(%{"schedule" => %{"type" => "fixed_time"}} = task, at),
    do: before?(task["nextRunAt"], at, @missed_grace)

  defp missed?(_task, _at), do: false

  # Whether `iso` is at least `margin` ms before `at`.
  defp before?(nil, _at, _margin), do: false

  defp before?(iso, at, margin) do
    case DateTime.from_iso8601(iso) do
      {:ok, time, _} -> DateTime.diff(at, time, :millisecond) > margin - 1
      _ -> false
    end
  end

  defp running?(state, id), do: Enum.any?(state.runs, fn {_, run} -> run.id == id end)

  defp put(state, task), do: %{state | tasks: Map.put(state.tasks, task["id"], task)}

  defp sorted(state), do: state.tasks |> Map.values() |> Enum.sort_by(& &1["createdAt"])

  # Saves, tells watchers, and re-arms the timer.
  defp changed(state) do
    save(state.path, sorted(state))
    tasks = sorted(state)
    for {pid, _} <- state.watchers, do: send(pid, {:hal_c2_scheduled_tasks, node(), tasks})
    schedule(state)
  end

  defp schedule(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    at = now()

    delay =
      state.tasks
      |> Map.values()
      |> Enum.filter(&(&1["enabled"] and not running?(state, &1["id"])))
      |> Enum.flat_map(fn task ->
        case task["nextRunAt"] && DateTime.from_iso8601(task["nextRunAt"]) do
          {:ok, time, _} -> [max(DateTime.diff(time, at, :millisecond), 0)]
          _ -> []
        end
      end)
      |> Enum.min(fn -> @max_sleep end)
      |> min(@max_sleep)

    %{state | timer: Process.send_after(self(), :tick, delay)}
  end

  defp load(path) do
    with {:ok, text} <- File.read(path),
         {:ok, tasks} when is_list(tasks) <- JSON.decode(text) do
      Enum.filter(tasks, &is_map/1)
    else
      _ -> []
    end
  end

  defp save(path, tasks) do
    tmp = path <> ".tmp"
    File.mkdir_p!(Path.dirname(path))
    File.write!(tmp, JSON.encode!(tasks))
    File.rename!(tmp, path)
  end

  defp error(message, id),
    do:
      {:error,
       %{"_tag" => "ScheduledTaskError", "message" => message}
       |> then(&if(id, do: Map.put(&1, "taskId", id), else: &1))}

  # The time runs are aimed and fired by; `:scheduled_tasks_clock` (a zero-arity
  # function returning a UTC `DateTime`) lets tests move it.
  defp now do
    clock = Application.get_env(:hal_c2, :scheduled_tasks_clock) || (&DateTime.utc_now/0)
    clock.() |> DateTime.truncate(:millisecond)
  end

  # Millisecond precision like the TS server's `toISOString`, whatever the source.
  defp iso(%DateTime{microsecond: {us, _}} = at),
    do: DateTime.to_iso8601(%{at | microsecond: {div(us, 1000) * 1000, 3}})
end
