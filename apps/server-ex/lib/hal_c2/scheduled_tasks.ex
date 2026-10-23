defmodule HalC2.ScheduledTasks do
  @moduledoc """
  Scheduled tasks (`scheduledTasks.*`): prompts that run on an interval or at a
  local time of day, in a thread or in a new thread each time.

  Tasks live in `<home>/scheduled-tasks.json`. One timer wakes for the next due
  run, at least every minute, so a changed clock or a sleeping host is noticed.
  A fixed-time run missed by more than ten minutes (the host was off) moves to
  its next slot instead of firing late, and so does every due run on an MC without
  automatic actions (`HAL_C2_MC_NO_AUTO_ACTIONS`), where a task only runs when asked
  (`scheduledTasks.runNow`). Watchers (client sockets) get
  `{:hal_c2_scheduled_tasks, mc, tasks}` whenever a task changes.

  A run gets an hour to send its prompt. One that has not finished by then is
  stopped, the run its own prompt started (or queued) in its thread is
  interrupted (or cancelled while queued) — never another turn in that thread —
  and the run is recorded as failed ("The run timed out."), so a prompt that
  never comes back cannot keep its task `running` for good. A task that starts
  a new thread per run is given that thread's id up front, so the same cleanup
  finds its thread too.
  """

  use GenServer

  require Logger

  alias HalC2.Orchestration

  @min_interval 60_000
  @missed_grace 10 * 60_000
  @max_sleep 60_000
  @run_timeout_ms 60 * 60_000
  @cleanup_timeout_ms 5 * 60_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def list(_input \\ %{}), do: {:ok, %{"tasks" => GenServer.call(__MODULE__, :list)}}
  def upsert(input), do: GenServer.call(__MODULE__, {:upsert, input})
  def delete(%{"id" => id}), do: GenServer.call(__MODULE__, {:delete, id})

  def set_enabled(%{"id" => id, "enabled" => enabled}),
    do: GenServer.call(__MODULE__, {:set_enabled, id, enabled})

  @doc "Runs a task now and replies once its message is sent."
  # The call waits as long as a run may take (the cap below, plus slack for the
  # scheduler to record the timeout and answer), so a caller whose run wedges
  # is answered with the timed-out task instead of a call timeout long before.
  # The websocket RPC serving it gives this method the same budget
  # (`HalC2.Web.Socket.rpc_timeout/1`), so the answer reaches clients too.
  def run_now(%{"id" => id}),
    do: GenServer.call(__MODULE__, {:run_now, id}, run_timeout_ms() + 5_000)

  def subscribe(pid, ref \\ nil), do: GenServer.call(__MODULE__, {:subscribe, pid, ref})
  def unsubscribe(pid, ref \\ nil), do: GenServer.cast(__MODULE__, {:unsubscribe, pid, ref})

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

  def handle_call({:subscribe, pid, ref}, _from, state) do
    watchers = HalC2.Watchers.add(state.watchers, pid, ref)
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
  def handle_cast({:unsubscribe, pid, ref}, state) do
    watchers = HalC2.Watchers.remove(state.watchers, pid, ref)
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

          missed?(task, at) or not Application.get_env(:hal_c2, :auto_actions, true) ->
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

  # A run outlived its hour: stop it, interrupt the turn it was starting, and
  # record it like any other failed run (which also answers a waiting "run now").
  # A timeout for a run the table no longer holds falls through to the ignore
  # below, as a timer can fire as its run finishes.
  def handle_info({:run_timeout, pid}, %{runs: runs} = state) when is_map_key(runs, pid) do
    run = runs[pid]
    Process.demonitor(run.ref, [:flush])
    Process.exit(pid, :kill)
    interrupt_turn(pid, run)
    {state, _task} = complete(state, pid, {:error, "The run timed out."})
    {:noreply, changed(state)}
  end

  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, %{state | watchers: Map.delete(state.watchers, pid)}}

  def handle_info(_other, state), do: {:noreply, state}

  # A scheduler updated in place (`HalC2.Hot`) does not run `init/1` again, and one
  # from before runs were linked does not trap exits yet, nor is linked to the runs it
  # started then. A run that ended meanwhile is answered by its DOWN.
  @impl true
  def code_change(_old, state, _extra) do
    Process.flag(:trap_exit, true)

    # Runs from before runs were linked are linked now, and ones from before the
    # run cap get a timer of their own for the time they have left, so none is
    # left running for good nor given a fresh hour on top of the time it has
    # already had. They also gain the thread and message their cleanup needs:
    # the thread their task names, and the deterministic message id `fire/3`
    # built from their start. One limit: a pre-upgrade run of a task that
    # starts a new thread each run launched under an id nothing recorded, so
    # its thread cannot be recovered here — the run still times out, fails
    # its task and frees it to run again; only the orphan-thread interrupt
    # is skipped.
    runs =
      Map.new(state.runs, fn {pid, run} ->
        Process.link(pid)

        run =
          if run[:timer],
            do: run,
            else: Map.put(run, :timer, arm_timeout(pid, remaining_ms(run)))

        run = Map.put_new_lazy(run, :thread_id, fn -> state.tasks[run.id]["threadId"] end)
        run = Map.put_new_lazy(run, :message_id, fn -> message_id(run) end)
        {pid, run}
      end)

    {:ok, %{state | runs: runs}}
  end

  # --- runs --------------------------------------------------------------------

  defp start_run(state, task, trigger, from) do
    at = now()
    fire_key = "#{task["id"]}:#{DateTime.to_unix(at, :millisecond)}:#{trigger}"
    running = Map.merge(task, %{"lastRunStatus" => "running", "updatedAt" => iso(at)})
    # The thread this run's prompt lands in: the task's own, or — for a task
    # that starts a new thread each run — one minted now and handed to the
    # launch, so a run that times out mid-launch still has a thread to clean up.
    thread_id = task["threadId"] || HalC2.Environment.uuid4()
    # Linked, so a scheduler that dies takes its runs with it, and monitored, so a run
    # that exits fails its task.
    parent = self()

    {pid, ref} =
      :erlang.spawn_opt(
        fn -> send(parent, {:run_done, self(), fire(running, fire_key, thread_id)}) end,
        [:link, :monitor]
      )

    run = %{
      ref: ref,
      id: task["id"],
      started: at,
      from: from,
      trigger: trigger,
      thread_id: thread_id,
      message_id: message_id(fire_key),
      timer: arm_timeout(pid)
    }

    state
    |> put(running)
    |> Map.update!(:runs, &Map.put(&1, pid, run))
    |> changed()
  end

  defp arm_timeout(pid, delay \\ nil),
    do: Process.send_after(self(), {:run_timeout, pid}, delay || run_timeout_ms())

  # The deterministic id of the message a run sends, from its fire key. A run
  # from before runs carried it rebuilds its key from its start.
  defp message_id(fire_key) when is_binary(fire_key), do: "scheduled-task-message:#{fire_key}"

  defp message_id(%{id: id, started: started} = run),
    do:
      message_id(
        "#{id}:#{DateTime.to_unix(started, :millisecond)}:#{run[:trigger] || "scheduled"}"
      )

  defp message_id(_run), do: nil

  # How much of its hour a run started at `run.started` has left. The cap
  # above means a host clock that moved backwards never extends a run past
  # its hour, matching the monotonic timer the normal path arms.
  defp remaining_ms(%{started: %DateTime{} = started}),
    do:
      (run_timeout_ms() - DateTime.diff(now(), started, :millisecond))
      |> max(0)
      |> min(run_timeout_ms())

  defp remaining_ms(_run), do: run_timeout_ms()

  @doc """
  How long a run gets to send its prompt; `:scheduled_tasks_run_timeout_ms`
  lets tests shorten the hour. The transports that wait on a manual run size
  their own deadlines from this.
  """
  def run_timeout_ms do
    case Application.get_env(:hal_c2, :scheduled_tasks_run_timeout_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @run_timeout_ms
    end
  end

  @active_statuses ~w(preparing starting running waiting)

  # Cleans up exactly the run a timed-out run's own prompt started, in its
  # thread: interrupted while active, cancelled while queued, left alone when
  # the prompt never landed — never another turn in that thread. The cleanup
  # runs in a process of its own (one per timed-out run): the wedged thread
  # that stalled the run must not wedge the scheduler too, and waiting on that
  # thread's stream is what lets the lookup run after a dispatch that was
  # still in the stream's mailbox when its sender was killed commits, so the
  # late prompt is cleaned up instead of running unattended. It is bounded:
  # a stream that never answers gives the cleanup up after
  # `@cleanup_timeout_ms`, so one wedged stream leaks at most one cleanup for
  # that long, and a cleanup that fails or gives up is logged — a prompt
  # left running unattended leaves a trace.
  defp interrupt_turn(pid, run) do
    with thread_id when is_binary(thread_id) <- run[:thread_id],
         message_id when is_binary(message_id) <- run[:message_id] || message_id(run) do
      spawn(fn ->
        # The run process is dead before anyone decides its prompt's run is
        # undriven: while it lived, it alone would have begun that turn.
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        end

        cleanup =
          Task.async(fn ->
            try do
              clean_up_prompt(thread_id, message_id)
              :ok
            catch
              kind, reason when kind in [:exit, :throw, :error] ->
                {:error, Exception.format(kind, reason, __STACKTRACE__)}
            end
          end)

        outcome =
          Task.yield(cleanup, @cleanup_timeout_ms) || Task.shutdown(cleanup, :brutal_kill)

        case outcome do
          {:ok, :ok} ->
            :ok

          {:ok, {:error, reason}} ->
            Logger.warning(
              "scheduled run cleanup failed for thread #{thread_id} message #{message_id}: #{reason}"
            )

          {:exit, reason} ->
            Logger.warning(
              "scheduled run cleanup exited for thread #{thread_id} message #{message_id}: #{inspect(reason)}"
            )

          nil ->
            Logger.warning(
              "scheduled run cleanup gave up after #{@cleanup_timeout_ms} ms for thread #{thread_id} message #{message_id}"
            )
        end
      end)
    else
      _ -> :ok
    end
  end

  defp clean_up_prompt(thread_id, message_id) do
    case prompt_run(thread_id, message_id) do
      %{"id" => run_id, "status" => "queued"} ->
        _ =
          Orchestration.dispatch(%{
            "type" => "queued-run.cancel",
            "threadId" => thread_id,
            "runId" => run_id
          })

        # The cancel only takes a run that is still queued; one promoted
        # between the read above and the cancel is handled as active now.
        case prompt_run(thread_id, message_id) do
          %{"status" => status} when status in @active_statuses ->
            clean_up_prompt(thread_id, message_id)

          _ ->
            :ok
        end

      %{"id" => run_id, "status" => status} when status in @active_statuses ->
        _ =
          Orchestration.dispatch(%{
            "type" => "run.interrupt",
            "threadId" => thread_id,
            "runId" => run_id
          })

        # A run still only starting (or preparing) after that, with nothing
        # driving it, is one whose dispatch committed after its sender was
        # killed: `begin_turn` will never run for it, so end it here.
        case prompt_run(thread_id, message_id) do
          %{"id" => ^run_id, "status" => left} when left in ~w(starting preparing) ->
            unless HalC2.Orchestration.TurnWatch.driven?(run_id),
              do: HalC2.Orchestration.TurnWriter.abandon(thread_id, run_id, "interrupted", nil)

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  # The run whose user message is `message_id`, read inside the thread's
  # stream so the read is ordered after the (possibly wedged) dispatch that
  # created it, however long that stream takes to answer.
  defp prompt_run(thread_id, message_id) do
    HalC2.Streams.transact(thread_id, :thread, fn state ->
      run =
        state
        |> HalC2.StreamState.list("run")
        |> Enum.find(&(&1["userMessageId"] == message_id))

      {[], run}
    end)
  end

  # A deleted task's runs end with it, so a task created later under the same id does
  # not take the result of a run that was not its own. Killing a run mid-dispatch
  # has the timeout's late-commit hazard, so a deleted run's own prompt is
  # cleaned up the same way (`interrupt_turn/2`): a prompt that lands after
  # its sender was killed does not run, or sit undriven, for a deleted task.
  # That cleanup cannot tell landed-before from landed-after the kill, and
  # does not try: deleting a task during its run ends that run's turn too,
  # even one already running in its thread (pinned in
  # `features/settings/scheduled-tasks.feature`).
  defp stop_runs(state, id) do
    {gone, runs} = Enum.split_with(state.runs, fn {_, run} -> run.id == id end)

    for {pid, %{ref: ref, from: from} = run} <- gone do
      if run[:timer], do: Process.cancel_timer(run.timer)
      Process.demonitor(ref, [:flush])
      Process.exit(pid, :kill)
      interrupt_turn(pid, run)
      if from, do: GenServer.reply(from, error("Schedule task not found.", id))
    end

    %{state | runs: Map.new(runs)}
  end

  defp complete(state, pid, result) do
    {%{id: id, started: started, from: from} = run, runs} = Map.pop(state.runs, pid)
    if run[:timer], do: Process.cancel_timer(run.timer)
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

  # Sends the prompt: into the task's thread, or as the first message of a new
  # one (`thread_id`, minted in `start_run/4` for such a task).
  defp fire(task, fire_key, thread_id) do
    command_id = "scheduled-task:#{fire_key}"
    message_id = message_id(fire_key)

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
            "threadId" => thread_id,
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
    HalC2.Watchers.notify(state.watchers, {:hal_c2_scheduled_tasks, node(), tasks})
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

  # Millisecond precision like `Date#toISOString`, whatever the source.
  defp iso(%DateTime{microsecond: {us, _}} = at),
    do: DateTime.to_iso8601(%{at | microsecond: {div(us, 1000) * 1000, 3}})
end
