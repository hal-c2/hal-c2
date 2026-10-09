defmodule HalC2.Steps.Settings.ScheduledTasks do
  @moduledoc """
  Steps for `features/settings/scheduled-tasks.feature`, against
  `HalC2.ScheduledTasks` over the `scheduledTasks.*` RPCs.

  Time is the scenario's: the service's clock (`:scheduled_tasks_clock`) reads a
  value the steps set, starting on Monday 2026-09-21 at 07:00 local time. Time
  passes a minute at a time with a `:tick` each minute, as the service's own
  timer wakes at least every minute, and each run is waited for before the
  next minute.
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @monday ~D[2026-09-21]
  @clock {__MODULE__, :clock}

  # --- tasks and their schedules -----------------------------------------------------

  step ~r/^a task "(?<title>[^"]+)" that runs at (?<time>\d\d:\d\d) on every day$/,
       %{args: [title, time]} = context do
    save_task(context, %{"title" => title, "schedule" => at(time)})
  end

  step ~r/^a task that runs at (?<time>\d\d:\d\d)$/, %{args: [time]} = context do
    save_task(context, %{"schedule" => at(time)})
  end

  step ~r/^a task that runs at (?<time>\d\d:\d\d) on weekdays$/, %{args: [time]} = context do
    save_task(context, %{"schedule" => Map.put(at(time), "weekdays", [1, 2, 3, 4, 5])})
  end

  step "a task that runs daily", context do
    save_task(context, %{"schedule" => at("09:00")})
  end

  step ~r/^a task that runs every (?<minutes>\d+) minutes$/, %{args: [minutes]} = context do
    save_task(context, %{"schedule" => every(String.to_integer(minutes))})
  end

  # An hourly task that has run once, so it has a history.
  # The run's prompt blocks on the thread's suspended stream, so the "run now" call
  # stays unanswered on its own socket while the scenario goes on.
  step "a task is running and the user waits for it with \"run now\"", context do
    context = World.create_thread(context, "Triage", "api")
    thread = World.thread_id(context, "Triage")
    context = save_task(context, %{"threadId" => thread, "schedule" => every(60)})
    id = context.task["id"]
    :ok = :sys.suspend(HalC2.Streams.ensure(thread))

    shape = %{"type" => "scheduledTasks", "mc" => Atom.to_string(node())}
    waiter = context |> World.client("waiter") |> Mc.sub(7, shape)
    call = System.unique_integer([:positive])
    waiter = Mc.rpc(waiter, context.mc.environment, call, "scheduledTasks.runNow", %{"id" => id})

    {_frame, waiter} =
      Mc.await(waiter, fn frame ->
        frame["t"] == "scheduledTasks" and
          Enum.any?(frame["tasks"], &(&1["id"] == id and &1["lastRunStatus"] == "running"))
      end)

    [run] = for {pid, %{id: ^id}} <- :sys.get_state(HalC2.ScheduledTasks).runs, do: pid

    context
    |> World.put_client("waiter", waiter)
    |> Map.merge(%{waiting: call, run: Process.monitor(run)})
  end

  step "a task that runs every hour", context do
    context = context |> save_task(%{"schedule" => every(60)}) |> pass(60)
    assert %{"runCount" => 1, "lastRunStatus" => "succeeded"} = task(context)
    context
  end

  step "a task that names an existing thread", context do
    context = World.create_thread(context, "Triage", "api")
    save_task(context, %{"threadId" => World.thread_id(context, "Triage")})
  end

  step "a task with no thread", context do
    save_task(context, %{"threadId" => nil})
  end

  step "a task whose next run is in 20 minutes", context do
    context = save_task(context, %{"schedule" => every(20)})
    assert context.task["nextRunAt"] == iso(DateTime.add(now(), 20, :minute))
    context
  end

  # A run that cannot finish: its thread's stream is held, so sending the prompt waits.
  step "a task is running", context do
    context = World.create_thread(context, "Triage", "api")
    thread = World.thread_id(context, "Triage")
    context = save_task(context, %{"threadId" => thread, "schedule" => every(60)})
    :ok = :sys.suspend(HalC2.Streams.ensure(thread))
    set_clock(DateTime.add(now(), 60, :minute))
    send(HalC2.ScheduledTasks, :tick)

    assert %{runs: runs, tasks: tasks} = :sys.get_state(HalC2.ScheduledTasks)
    assert map_size(runs) == 1
    assert tasks[context.task["id"]]["lastRunStatus"] == "running"
    context
  end

  step "a task saved by an older version that runs every 10 seconds", context do
    context = start(context)
    :ok = ExUnit.Callbacks.stop_supervised(HalC2.ScheduledTasks)
    at = iso(now())

    legacy =
      input(context, %{
        "id" => "legacy-task",
        "schedule" => %{"type" => "interval", "everyMs" => 10_000},
        "createdAt" => at,
        "updatedAt" => at,
        "nextRunAt" => iso(DateTime.add(now(), 1, :minute)),
        "lastRunAt" => nil,
        "lastRunStatus" => "never",
        "lastRunError" => nil,
        "runCount" => 0,
        "createdBy" => "user",
        "creationSource" => "web"
      })

    File.write!(Path.join(context.mc.home, "scheduled-tasks.json"), JSON.encode!([legacy]))
    context = start(context)
    Map.put(context, :task, legacy)
  end

  # --- time ----------------------------------------------------------------------------

  step ~r/^the clock reaches (?<time>\d\d:\d\d)$/, %{args: [time]} = context do
    pass_until(context, local(Date.from_iso8601!(local_date()), time))
  end

  step ~r/^(?<minutes>\d+) minutes pass$/, %{args: [minutes]} = context do
    pass(context, String.to_integer(minutes))
  end

  step ~r/^Saturday (?<time>\d\d:\d\d) passes$/, %{args: [time]} = context do
    pass_until(context, local(Date.add(@monday, 5), time), 1)
  end

  # The MC is down meanwhile: no timer fires until it starts again.
  step ~r/^the machine was off from (?<from>\d\d:\d\d) until (?<until>\d\d:\d\d)$/,
       %{args: [from, until]} = context do
    context = pass_until(context, local(@monday, from))
    context = %{context | mc: Mc.stop(context.mc), clients: %{}}
    set_clock(local(@monday, until))
    context
  end

  step "the task runs", context do
    {:ok, next, _} = DateTime.from_iso8601(context.task["nextRunAt"])
    pass_until(context, next)
  end

  # --- outcomes of runs ------------------------------------------------------------------

  step "the MC sends the task's prompt to the project", context do
    assert_prompt_in(new_thread(context))
    context
  end

  step "the task records a successful run", context do
    task = task(context)
    assert task["lastRunStatus"] == "succeeded"
    assert task["lastRunError"] == nil
    assert task["runCount"] == 1
    assert task["lastRunAt"] == iso(local(@monday, "09:00"))
    assert task["nextRunAt"] == iso(local(Date.add(@monday, 1), "09:00"))
    context
  end

  step "the task has run twice", context do
    assert %{"runCount" => 2, "lastRunStatus" => "succeeded"} = task(context)
    context
  end

  step "the task does not run", context do
    assert %{"runCount" => 0, "lastRunStatus" => "never", "lastRunAt" => nil} = task(context)
    context
  end

  step ~r/^its next run is Monday at (?<time>\d\d:\d\d)$/, %{args: [time]} = context do
    assert task(context)["nextRunAt"] == iso(local(Date.add(@monday, 7), time))
    context
  end

  step "the task does not run immediately", context do
    context = start(context)
    send(HalC2.ScheduledTasks, :tick)
    settle()
    assert %{"runCount" => 0, "lastRunStatus" => "never"} = task(context)
    context
  end

  step "its next run moves to the next 09:00", context do
    assert task(context)["nextRunAt"] == iso(local(Date.add(@monday, 1), "09:00"))
    context
  end

  step "the prompt is sent into that thread", context do
    assert_prompt_in(World.thread_id(context, "Triage"))
    context
  end

  step "the prompt starts a new thread for the run", context do
    thread = new_thread(context)
    assert_prompt_in(thread)
    assert thread != context.threads["Triage"]
    context
  end

  step "the task is still listed with its schedule and run history", context do
    before = context.task
    context = start(context)

    assert %{"schedule" => schedule, "runCount" => 1, "lastRunStatus" => "succeeded"} =
             task = task(context)

    assert schedule == before["schedule"]
    assert task["lastRunAt"] != nil
    assert task["nextRunAt"] == iso(DateTime.add(now(), 60, :minute))
    context
  end

  step ~r/^after restart the task's last run failed with "(?<message>[^"]+)"$/,
       %{args: [message]} = context do
    context = %{context | mc: Mc.restart(context.mc), clients: %{}}

    assert %{"lastRunStatus" => "failed", "lastRunError" => ^message, "runCount" => 1} =
             task(context)

    context
  end

  # --- the user manages tasks ------------------------------------------------------------

  step "the user runs the task now", context do
    before = task(context)["runCount"]

    {reply, context} =
      World.call(context, "scheduledTasks.runNow", %{"id" => context.task["id"]})

    Map.merge(context, %{reply: reply, run_count: before})
  end

  step "the prompt is sent immediately", context do
    assert {:ok, %{"task" => %{"lastRunStatus" => "succeeded"}}} = context.reply
    assert DateTime.compare(now(), local(@monday, "09:00")) == :lt
    assert_prompt_in(new_thread(context))
    context
  end

  step "the run count goes up by one", context do
    assert task(context)["runCount"] == context.run_count + 1
    context
  end

  step "the user pauses the task", context do
    set_enabled(context, false)
  end

  step "the user resumes the task", context do
    set_enabled(context, true)
  end

  step "the task has no next run", context do
    assert %{"enabled" => false, "nextRunAt" => nil} = task(context)
    context
  end

  step "the task has a next run again", context do
    assert %{"enabled" => true} = task = task(context)
    assert task["nextRunAt"] == iso(DateTime.add(now(), 60, :minute))
    context
  end

  step "the user changes the task's prompt", context do
    context = pass(context, 5)
    edit(context, %{"prompt" => "Look at new Sentry errors and group them."})
  end

  # The pending run keeps its time: 20 minutes after the task was saved.
  step "the next run is still in 20 minutes", context do
    assert {:ok, %{"task" => edited}} = context.reply
    assert edited["prompt"] == "Look at new Sentry errors and group them."
    assert task(context)["nextRunAt"] == context.task["nextRunAt"]
    context
  end

  step ~r/^the user saves a task that runs every (?<seconds>\d+) seconds$/,
       %{args: [seconds]} = context do
    schedule = %{"type" => "interval", "everyMs" => String.to_integer(seconds) * 1_000}

    {reply, context} =
      World.call(
        start(context),
        "scheduledTasks.upsert",
        input(context, %{"schedule" => schedule})
      )

    Map.put(context, :reply, reply)
  end

  step "the user deletes the task", context do
    {reply, context} = World.call(context, "scheduledTasks.delete", %{"id" => context.task["id"]})
    assert {:ok, _} = reply
    context
  end

  step "the run is stopped and the waiting user is told {string}", %{args: [message]} = context do
    assert_receive {:DOWN, ref, :process, _, :killed} when ref == context.run, 5_000
    {frame, waiter} = Mc.await(World.client(context, "waiter"), Mc.reply?(context.waiting))
    assert %{"t" => "rpc.error", "error" => error} = frame
    assert "#{error} #{inspect(frame["detail"])}" =~ message
    World.put_client(context, "waiter", waiter)
  end

  step "a task made later with the same id starts with no run history", context do
    context = save_task(context, %{"id" => context.task["id"], "threadId" => nil})
    assert %{"lastRunStatus" => "never", "runCount" => 0} = task(context)
    context
  end

  step "another client deleted the task {string}", %{args: [title]} = context do
    context = save_task(context, %{"title" => title})

    {reply, context} =
      World.call(context, "scheduledTasks.delete", %{"id" => context.task["id"]}, "other")

    assert {:ok, _} = reply
    context
  end

  step "the user saves changes to {string}", %{args: [title]} = context do
    assert context.task["title"] == title
    context = edit(context, %{"prompt" => "Only new errors."})
    assert {{:ok, %{"tasks" => []}}, _} = World.call(context, "scheduledTasks.list")
    context
  end

  # Saving an edit needs a schedule the MC accepts now, so the edit also raises
  # the interval to the one-minute floor, as the settings form does.
  step "the user can list, pause, edit and delete it", context do
    id = context.task["id"]

    assert %{"schedule" => %{"everyMs" => 10_000}} = task(context)

    assert {{:ok, %{"task" => %{"enabled" => false}}}, context} =
             World.call(context, "scheduledTasks.setEnabled", %{"id" => id, "enabled" => false})

    context = edit(context, %{"prompt" => "Tidy up.", "schedule" => every(1), "enabled" => false})
    assert {:ok, %{"task" => %{"prompt" => "Tidy up."}}} = context.reply

    assert {{:ok, _}, context} = World.call(context, "scheduledTasks.delete", %{"id" => id})
    assert {{:ok, %{"tasks" => []}}, context} = World.call(context, "scheduledTasks.list")
    context
  end

  # --- watching and agents ------------------------------------------------------------------

  step "two clients watch the scheduled tasks", context do
    context = start(context)
    shape = %{"type" => "scheduledTasks", "mc" => Atom.to_string(node())}

    Enum.reduce(["first", "second"], context, fn name, context ->
      client = context |> World.client(name) |> Mc.sub(7, shape)
      {%{"tasks" => []}, client} = Mc.await(client, &(&1["t"] == "scheduledTasks"))
      World.put_client(context, name, client)
    end)
  end

  step "one client creates a task", context do
    {reply, context} =
      World.call(
        context,
        "scheduledTasks.upsert",
        input(context, %{"title" => "Nightly review"}),
        "first"
      )

    assert {:ok, %{"task" => task}} = reply
    Map.put(context, :task, task)
  end

  step "the other client sees the task without refreshing", context do
    id = context.task["id"]

    {_frame, client} =
      Mc.await(
        World.client(context, "second"),
        &(&1["t"] == "scheduledTasks" and Enum.any?(&1["tasks"], fn task -> task["id"] == id end))
      )

    World.put_client(context, "second", client)
  end

  step "an agent in a thread with the MC's tools", context do
    context
    |> start()
    |> World.create_thread("Agent work", "api")
    |> World.add_run("Agent work", "running")
  end

  step "the agent schedules a task to run every morning", context do
    args = %{
      "title" => "Morning check",
      "prompt" => "Summarise what changed overnight.",
      "schedule" => %{"type" => "fixed_time", "timeOfDay" => "08:00"}
    }

    caller = %{thread_id: World.thread_id(context, "Agent work"), instance: "codex"}
    assert {:ok, %{"task" => task}} = HalC2.Mcp.Tools.call("schedule_task", args, caller)
    Map.put(context, :task, task)
  end

  step "the task appears in the user's scheduled tasks", context do
    assert %{"title" => "Morning check", "enabled" => true} = task = task(context)

    assert task["nextRunAt"] == iso(local(@monday, "08:00")) or
             task["nextRunAt"] == iso(local(Date.add(@monday, 1), "08:00"))

    context
  end

  step "the task records that an agent created it", context do
    assert %{"createdBy" => "agent", "creationSource" => "mcp", "threadId" => thread} =
             task(context)

    assert thread == World.thread_id(context, "Agent work")
    context
  end

  # --- helpers ---------------------------------------------------------------------------

  # Starts the service on the scenario's clock.
  defp start(context) do
    unless context[:clock?] do
      if :persistent_term.get(@clock, nil) == nil, do: set_clock(local(@monday, "07:00"))
      World.put_app_env(:scheduled_tasks_clock, fn -> :persistent_term.get(@clock) end)
      ExUnit.Callbacks.on_exit(fn -> :persistent_term.erase(@clock) end)
    end

    Mc.ensure(HalC2.ScheduledTasks)
    Map.put(context, :clock?, true)
  end

  defp input(context, fields) do
    Map.merge(
      %{
        "title" => "Check Sentry",
        "prompt" => "Look at new Sentry errors.",
        "enabled" => true,
        "schedule" => at("09:00"),
        "projectId" => World.project(context, "api").id,
        "threadId" => nil,
        "workspaceStrategy" => %{"type" => "root"},
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default"
      },
      fields
    )
  end

  defp save_task(context, fields) do
    context = start(context)
    {reply, context} = World.call(context, "scheduledTasks.upsert", input(context, fields))
    assert {:ok, %{"task" => task}} = reply
    Map.put(context, :task, task)
  end

  # Saves an edit of the scenario's task as the settings form does.
  defp edit(context, fields) do
    payload =
      context.task
      |> Map.take(~w(id title prompt enabled schedule projectId threadId workspaceStrategy
                     modelSelection runtimeMode interactionMode))
      |> Map.merge(fields)
      |> Map.put("requireExisting", true)

    {reply, context} = World.call(context, "scheduledTasks.upsert", payload)
    Map.put(context, :reply, reply)
  end

  defp set_enabled(context, enabled) do
    {reply, context} =
      World.call(context, "scheduledTasks.setEnabled", %{
        "id" => context.task["id"],
        "enabled" => enabled
      })

    assert {:ok, %{"task" => %{"enabled" => ^enabled}}} = reply
    Map.put(context, :reply, reply)
  end

  # The scenario's task as the MC lists it now.
  defp task(context) do
    context = start(context)
    {{:ok, %{"tasks" => tasks}}, _client} = World.call(context, "scheduledTasks.list")
    Enum.find(tasks, &(&1["id"] == context.task["id"])) || flunk("the task is not listed")
  end

  # `minutes` pass, a minute at a time.
  defp pass(context, minutes) do
    context = start(context)

    for _ <- 1..minutes do
      set_clock(DateTime.add(now(), 1, :minute))
      send(HalC2.ScheduledTasks, :tick)
      settle()
    end

    context
  end

  # Time jumps to a minute before `at` and passes a minute at a time until
  # `after_minutes` past it.
  defp pass_until(context, at, after_minutes \\ 0) do
    context = start(context)
    start = DateTime.add(at, -1, :minute)
    if DateTime.compare(start, now()) == :gt, do: set_clock(start)
    pass(context, max(DateTime.diff(at, now(), :minute), 0) + after_minutes)
  end

  # Waits until no run is in flight. A helper process follows the service's
  # changes, so the scenario's mailbox (which sockets read) stays clean.
  defp settle do
    me = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        {:ok, _} = HalC2.ScheduledTasks.subscribe(self())
        idle(me, ref)
      end)

    receive do
      {^ref, :settled} ->
        Process.demonitor(monitor, [:flush])
        :ok

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        flunk("waiting for scheduled runs failed: #{inspect(reason)}")
    after
      10_000 ->
        Process.exit(pid, :kill)
        flunk("a scheduled run did not finish")
    end
  end

  defp idle(me, ref) do
    if :sys.get_state(HalC2.ScheduledTasks).runs == %{} do
      send(me, {ref, :settled})
    else
      receive do
        {:hal_c2_scheduled_tasks, _mc, _tasks} -> idle(me, ref)
      end
    end
  end

  # The thread a run of the task launched in "api", once the sidebar has it.
  defp new_thread(context) do
    title = context.task["title"]
    project = World.project(context, "api").id

    ids =
      for {{mc, id}, {"thread", row}} <- HalC2.Shell.rows(),
          mc == node(),
          row["projectId"] == project,
          row["title"] == title,
          do: id

    case ids do
      [id] ->
        id

      [] ->
        receive do
          {:hal_c2_shell, _} -> new_thread(context)
        after
          2_000 -> flunk("no thread titled #{inspect(title)} in the project")
        end
    end
  end

  defp assert_prompt_in(thread_id) do
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))

    assert Enum.any?(HalC2.StreamState.list(state, "message"), fn message ->
             message["role"] == "user" and message["text"] == "Look at new Sentry errors."
           end),
           "the task's prompt is not in #{thread_id}"
  end

  defp at(time), do: %{"type" => "fixed_time", "timeOfDay" => time}
  defp every(minutes), do: %{"type" => "interval", "everyMs" => minutes * 60_000}

  defp now, do: :persistent_term.get(@clock)
  defp set_clock(at), do: :persistent_term.put(@clock, ms(at))
  defp iso(at), do: at |> ms() |> DateTime.to_iso8601()

  # Millisecond precision, as the MC keeps its times.
  defp ms(%DateTime{microsecond: {us, _}} = at),
    do: %{at | microsecond: {div(us, 1000) * 1000, 3}}

  # The UTC time of `time` ("HH:MM") local time on `date`.
  defp local(date, time) do
    [hour, minute] = time |> String.split(":") |> Enum.map(&String.to_integer/1)
    [utc | _] = :calendar.local_time_to_universal_time_dst({Date.to_erl(date), {hour, minute, 0}})

    DateTime.from_naive!(NaiveDateTime.from_erl!(utc), "Etc/UTC")
    |> DateTime.truncate(:millisecond)
  end

  defp local_date do
    now()
    |> DateTime.to_naive()
    |> NaiveDateTime.to_erl()
    |> :calendar.universal_time_to_local_time()
    |> elem(0)
    |> Date.from_erl!()
    |> Date.to_iso8601()
  end
end
