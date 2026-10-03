defmodule HalC2.Steps.Orchestration.ScheduledTasks do
  @moduledoc """
  Steps for `features/mc/orchestration/scheduled-tasks.feature`.

  Clients act over the socket (`scheduledTasks.*`), agents through the MCP tools.
  The scheduler's clock is pinned (`:scheduled_tasks_clock`) so times of day are
  exact; "becomes due" moves it past the task's next run and wakes the scheduler.
  Times of day are local times on `context.day` (a Monday unless a step says).
  A task is saved the first time a step names it; "missing" names one that is not.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.ScheduledTasks
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @hour 3_600_000
  @monday ~D[2026-07-06]
  @model %{"instanceId" => "codex", "model" => "gpt-5.4"}
  @days ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)

  # --- background ----------------------------------------------------------------------

  step "the local time zone of the MC is used for times of day", context do
    Mc.ensure(HalC2.ScheduledTasks)
    Mc.ensure(HalC2.WorktreeSetup)
    at = DateTime.utc_now()
    noon = ScheduledTasks.next_run(%{"type" => "fixed_time", "timeOfDay" => "12:00"}, at)
    assert %NaiveDateTime{hour: 12, minute: 0} = local(noon)
    context |> World.providers() |> Map.merge(%{tasks: %{}, day: @monday})
  end

  # --- saving ----------------------------------------------------------------------------

  step "a client saves a new task {string} every {int} hour(s) in {string}",
       %{args: [title, hours, project]} = context do
    context = pin(context, now(context))

    input =
      input(context, title, %{"schedule" => every(hours), "projectId" => id(context, project)})

    save(context, title, input)
  end

  step "the task is enabled, has never run, has run 0 times and is due in 1 hour", context do
    assert {:ok, %{"task" => task}} = context.reply
    assert %{"enabled" => true, "lastRunStatus" => "never", "lastRunAt" => nil} = task
    assert task["runCount"] == 0
    assert task["nextRunAt"] == iso(DateTime.add(context.now, @hour, :millisecond))
    context
  end

  step "it was created by the user from the web", context do
    assert {:ok, %{"task" => %{"createdBy" => "user", "creationSource" => "web"}}} =
             context.reply

    context
  end

  step ~r/^a client saves a task with schedule (?<schedule>.+)$/,
       %{args: [schedule]} = context do
    schedule =
      case schedule do
        "every 30 seconds" -> %{"type" => "interval", "everyMs" => 30_000}
        ~s(every "ten" milliseconds) -> %{"type" => "interval", "everyMs" => "ten"}
        "at time of day " <> time -> %{"type" => "fixed_time", "timeOfDay" => unquoted(time)}
        "of an unknown type" -> %{"type" => "cron", "expression" => "0 9 * * *"}
      end

    save(context, "invalid", input(context, "invalid", %{"schedule" => schedule}))
  end

  step "it is {word} local time on a {word}", %{args: [time, weekday]} = context do
    day = Date.add(@monday, Enum.find_index(@days, &(&1 == weekday)))
    context = Map.put(context, :day, day)
    pin(context, at(context, time))
  end

  step ~r/^a client saves a task at "(?<time>[^"]+)" on (?<days>every day|Mondays only)$/,
       %{args: [time, days]} = context do
    schedule = %{"type" => "fixed_time", "timeOfDay" => time}
    schedule = if days == "Mondays only", do: Map.put(schedule, "weekdays", [1]), else: schedule
    save(context, "fixed", input(context, "fixed", %{"schedule" => schedule}))
  end

  step ~r/^the task is next due (?<when>(?:next )?[A-Za-z]+) at (?<time>\d\d:\d\d)$/,
       %{args: [on, time]} = context do
    assert {:ok, %{"task" => task}} = context.reply
    weekday = Enum.find_index(@days, &(&1 == String.replace_prefix(on, "next ", ""))) + 1

    offset =
      Enum.find(0..7, fn offset ->
        date = Date.add(context.day, offset)
        Date.day_of_week(date) == weekday and (offset > 0 or not String.starts_with?(on, "next"))
      end)

    day = Date.add(context.day, offset)
    assert local(task["nextRunAt"]) == NaiveDateTime.new!(day, time(time))
    context
  end

  # --- listing and editing ------------------------------------------------------------------

  step "tasks {string} then {string} were created", %{args: [first, second]} = context do
    context |> task(first) |> task(second)
  end

  step "a client lists the tasks", context do
    {reply, context} = World.call(context, "scheduledTasks.list")
    Map.put(context, :reply, reply)
  end

  step "it receives {string} then {string}", %{args: [first, second]} = context do
    assert {:ok, %{"tasks" => tasks}} = context.reply
    assert Enum.map(tasks, & &1["title"]) == [first, second]
    context
  end

  step "a client opened task {string} for editing and it was then deleted",
       %{args: [name]} = context do
    context = task(context, name)
    form = current(context, name)
    {{:ok, _}, context} = World.call(context, "scheduledTasks.delete", %{"id" => form["id"]})
    Map.put(context, :form, form)
  end

  step "the client saves its edit as an edit of an existing task", context do
    edit =
      context.form
      |> Map.take(~w(id title prompt enabled schedule projectId threadId workspaceStrategy
        modelSelection runtimeMode interactionMode))
      |> Map.merge(%{"title" => "Edited", "requireExisting" => true})

    {reply, context} = World.call(context, "scheduledTasks.upsert", edit)
    Map.put(context, :reply, reply)
  end

  step "no task is recreated", context do
    assert tasks() == []
    context
  end

  step "task {string} is due at {word}", %{args: [name, time]} = context do
    if World.given?(context) do
      # Saved an hour before, running every hour.
      due = at(context, time)
      context |> pin(DateTime.add(due, -@hour, :millisecond)) |> task(name)
    else
      assert local(current(context, name)["nextRunAt"]) == local_at(context, time)
      context
    end
  end

  step "task {string} runs every hour and is due at {word}", %{args: [name, time]} = context do
    due = at(context, time)
    context |> pin(DateTime.add(due, -@hour, :millisecond)) |> task(name)
  end

  step "a client renames task {string} without changing its schedule",
       %{args: [name]} = context do
    context
    |> advance(30 * 60_000)
    |> edit(name, %{"title" => "Renamed"})
  end

  # The save's own answer: a pending run it kept may fire right after.
  step "task {string} is still due at {word}", %{args: [name, time]} = context do
    assert {:ok, %{"task" => %{"id" => id} = task}} = context.reply
    assert id == context.tasks[name]
    assert local(task["nextRunAt"]) == local_at(context, time)
    context
  end

  step "a client changes it to every {int} hours at {word}", %{args: [hours, time]} = context do
    [name] = Map.keys(context.tasks)

    context
    |> pin(at(context, time))
    |> edit(name, %{"schedule" => every(hours)})
  end

  step "task {string} at {string} is due at {word}", %{args: [name, time, due]} = context do
    schedule = %{"type" => "fixed_time", "timeOfDay" => time}

    context =
      context
      |> pin(DateTime.add(at(context, due), -60_000, :millisecond))
      |> task(name, %{"schedule" => schedule})

    assert local(current(context, name)["nextRunAt"]) == local_at(context, due)
    context
  end

  # A minute after the pending run was due, so aiming afresh would pick tomorrow.
  step "a client saves it with time {string}", %{args: [time]} = context do
    [name] = Map.keys(context.tasks)
    task = current(context, name)

    context
    |> advance(2 * 60_000)
    |> edit(name, %{"schedule" => Map.put(task["schedule"], "timeOfDay", time)})
  end

  # --- enabling and deleting -------------------------------------------------------------------

  step("a client disables task {string}", %{args: [name]} = context,
    do: set_enabled(context, name, false)
  )

  step("a client enables task {string}", %{args: [name]} = context,
    do: set_enabled(context, name, true)
  )

  step "task {string} has no next run", %{args: [name]} = context do
    assert {:ok, %{"task" => %{"enabled" => false}}} = context.reply
    assert current(context, name)["nextRunAt"] == nil
    context
  end

  step "task {string} has a next run", %{args: [name]} = context do
    assert {:ok, %{"task" => %{"enabled" => true}}} = context.reply
    assert is_binary(current(context, name)["nextRunAt"])
    context
  end

  step "a client deletes task {string}", %{args: [name]} = context do
    context = task(context, name)

    {reply, context} =
      World.call(context, "scheduledTasks.delete", %{"id" => task_id(context, name)})

    Map.put(context, :reply, reply)
  end

  step "task {string} is no longer listed", %{args: [name]} = context do
    assert {:ok, %{"id" => id}} = context.reply
    assert id == context.tasks[name]
    refute Enum.any?(tasks(), &(&1["id"] == id))
    context
  end

  step("a client runs now task {string}", %{args: [name]} = context, do: run_now(context, name))

  # --- runs --------------------------------------------------------------------------------------

  # The thread has a turn running, so the queueing behind it shows.
  step "task {string} is bound to thread {string}", %{args: [name, thread]} = context do
    context = World.running_turn(context, thread)
    task(context, name, %{"threadId" => World.thread_id(context, thread)})
  end

  step("task {string} becomes due", %{args: [name]} = context, do: run_due(context, name))

  step "its prompt is sent to {string} to start after any active turn",
       %{args: [thread]} = context do
    [name] = Map.keys(context.tasks)
    prompt = current(context, name)["prompt"]
    runs = World.entities(context, thread, "run")
    message = Enum.find(World.entities(context, thread, "message"), &(&1["text"] == prompt))
    assert message, "no message #{inspect(prompt)} in #{thread}"
    assert %{"status" => "queued"} = Enum.find(runs, &(&1["id"] == message["runId"]))
    assert Enum.any?(runs, &(&1["status"] == "running"))
    Map.put(context, :message, message)
  end

  step "the message records that it came from task {string}", %{args: [name]} = context do
    assert context.message["scheduledTaskId"] == context.tasks[name]
    context
  end

  step "task {string} is not bound to a thread and uses a new worktree",
       %{args: [name]} = context do
    task(context, name, %{
      "threadId" => nil,
      "workspaceStrategy" => %{"type" => "worktree", "baseRef" => "main"},
      "runtimeMode" => "approval-required",
      "interactionMode" => "plan"
    })
  end

  step "a new thread titled like the task is launched in {string} with the task's model and modes",
       %{args: [project]} = context do
    [name] = Map.keys(context.tasks)
    task = current(context, name)
    {context, thread} = launched(context, task)
    assert thread["projectId"] == id(context, project)
    assert thread["modelSelection"] == task["modelSelection"]
    assert thread["runtimeMode"] == task["runtimeMode"]
    assert thread["interactionMode"] == task["interactionMode"]
    Map.put(context, :launched, thread["id"])
  end

  step "its first message is the task's prompt, recorded as coming from task {string}",
       %{args: [name]} = context do
    [first | _] =
      context
      |> World.entities(context.launched, "message")
      |> Enum.sort_by(& &1["createdAt"])

    assert %{"role" => "user", "text" => text, "scheduledTaskId" => id} = first
    assert text == current(context, name)["prompt"]
    assert id == context.tasks[name]
    context
  end

  step "task {string} runs and the prompt is delivered", %{args: [name]} = context do
    context = run_due(context, name)
    {context, thread} = launched(context, current(context, name))

    assert Enum.any?(
             World.entities(context, thread["id"], "message"),
             &(&1["scheduledTaskId"] == context.tasks[name])
           )

    context
  end

  step "task {string} last ran successfully, its run count grows by 1 and its next run is aimed",
       %{args: [name]} = context do
    task = current(context, name)
    assert %{"lastRunStatus" => "succeeded", "lastRunError" => nil} = task
    assert task["runCount"] == context.run_count + 1
    assert task["lastRunAt"] == iso(context.now)
    assert task["nextRunAt"] == iso(DateTime.add(context.now, @hour, :millisecond))
    context
  end

  step "task {string} is bound to a thread that no longer exists", %{args: [name]} = context do
    task(context, name, %{"threadId" => "thread-gone"})
  end

  # A task the MC already found due is awaited; otherwise it is made due first.
  step("task {string} runs", %{args: [name]} = context, do: run_due(context, name))

  step "task {string} last failed with the reason and its run count grows by 1",
       %{args: [name]} = context do
    task = current(context, name)
    assert task["lastRunStatus"] == "failed"
    assert is_binary(task["lastRunError"]) and task["lastRunError"] != ""
    assert task["runCount"] == context.run_count + 1
    context
  end

  step("a client runs task {string} now", %{args: [name]} = context, do: run_now(context, name))

  step "the answer is task {string} after the run, with its outcome",
       %{args: [name]} = context do
    assert {:ok, %{"task" => task}} = context.reply
    assert task["id"] == context.tasks[name]
    assert %{"lastRunStatus" => "succeeded", "runCount" => 1} = task
    assert task["lastRunAt"] == iso(context.now)
    assert task == current(context, name)
    context
  end

  # A daily task saved an hour after its time of day, so its pending run is tomorrow's.
  step "task {string} is due at {word} tomorrow", %{args: [name, time]} = context do
    context =
      context
      |> pin(DateTime.add(at(context, time), @hour, :millisecond))
      |> task(name, %{"schedule" => %{"type" => "fixed_time", "timeOfDay" => time}})

    assert local(current(context, name)["nextRunAt"]) == tomorrow_at(context, time)
    context
  end

  step "one run starts immediately", context do
    [name] = Map.keys(context.tasks)
    assert {:ok, %{"task" => task}} = context.reply
    assert %{"lastRunStatus" => "succeeded", "runCount" => 1} = task
    assert task["lastRunAt"] == iso(context.now)
    # Its prompt went out now, as the first message of a new thread.
    {context, thread} = launched(context, task)

    World.await_state(context, thread["id"], fn state ->
      Enum.any?(
        HalC2.StreamState.list(state, "message"),
        &(&1["scheduledTaskId"] == context.tasks[name] and &1["text"] == task["prompt"])
      )
    end)

    context
  end

  step "task {string} is still due at {word} tomorrow", %{args: [name, time]} = context do
    assert {:ok, %{"task" => answered}} = context.reply
    task = current(context, name)
    assert local(task["nextRunAt"]) == tomorrow_at(context, time)
    assert answered["nextRunAt"] == task["nextRunAt"]
    # The scheduler did not take the manual run for the scheduled one.
    assert task["runCount"] == 1
    context
  end

  step("task {string} is running", %{args: [name]} = context, do: running(context, name))

  step "task {string} is running and becomes due again", %{args: [name]} = context do
    context = running(context, name)
    due = current(context, name)["nextRunAt"]
    {:ok, due, _} = DateTime.from_iso8601(due)
    context = pin(context, DateTime.add(due, @hour, :millisecond))
    tick()
    context
  end

  step "no second run starts", context do
    [name] = Map.keys(context.tasks)
    assert map_size(:sys.get_state(ScheduledTasks).runs) == 1
    :sys.resume(context.suspended)
    task = await_task(context, name, &(&1["lastRunStatus"] != "running"))
    assert task["runCount"] == 1
    assert :sys.get_state(ScheduledTasks).runs == %{}
    context
  end

  step "a client ran task {string} now and deleted it during the run",
       %{args: [name]} = context do
    context = bound(context, name)
    stream = suspend(context, name)
    request = System.unique_integer([:positive])

    client =
      Mc.rpc(
        World.client(context),
        context.mc.environment,
        request,
        "scheduledTasks.runNow",
        %{"id" => task_id(context, name)}
      )

    context = World.put_client(context, client)
    await_task(context, name, &(&1["lastRunStatus"] == "running"))

    {result, context} =
      World.call(context, "scheduledTasks.delete", %{"id" => task_id(context, name)}, "other")

    assert {:ok, _} = result
    Map.merge(context, %{suspended: stream, request: request})
  end

  step "the run ends", context do
    :sys.resume(context.suspended)
    [name] = Map.keys(context.tasks)
    id = task_id(context, name)
    # Its message goes out, and the run is over once the scheduler has no run left.
    World.await_state(context, "t-#{name}", fn state ->
      Enum.any?(HalC2.StreamState.list(state, "message"), &(&1["scheduledTaskId"] == id))
    end)

    context
  end

  step "the client is told {string}", %{args: [message]} = context do
    {frame, client} = Mc.await(World.client(context), Mc.reply?(context.request), 5_000)
    assert %{"t" => "rpc.error", "error" => ^message} = frame
    assert :sys.get_state(ScheduledTasks).runs == %{}
    assert tasks() == []
    World.put_client(context, client)
  end

  # --- the scheduler ---------------------------------------------------------------------------

  step "task {string} was due at {word} and the MC was asleep until {word}",
       %{args: [name, due, woke]} = context do
    schedule = %{"type" => "fixed_time", "timeOfDay" => due}

    context
    |> pin(DateTime.add(at(context, due), -@hour, :millisecond))
    |> task(name, %{"schedule" => schedule})
    |> pin(at(context, woke))
  end

  step "task {string} runs every hour and was due while the MC was asleep",
       %{args: [name]} = context do
    context = context |> pin(at(context, "08:00")) |> task(name)
    context |> pin(at(context, "12:00")) |> Map.put(:run_count, 0)
  end

  step "the MC checks its schedule", context do
    {:ok, _} = ScheduledTasks.subscribe(self())
    tick()
    # The check is done once the scheduler has handled the wake-up.
    :sys.get_state(ScheduledTasks)
    context
  end

  step "task {string} does not run and is next due at its following slot",
       %{args: [name]} = context do
    task = current(context, name)
    assert %{"lastRunStatus" => "never", "runCount" => 0} = task

    assert local(task["nextRunAt"]) ==
             NaiveDateTime.add(local_at(context, task["schedule"]["timeOfDay"]), 1, :day)

    context
  end

  step "the next task is due in 3 hours", context do
    context = context |> pin(now(context)) |> task("later", %{"schedule" => every(3)})
    due = current(context, "later")["nextRunAt"]
    assert due == iso(DateTime.add(context.now, 3 * @hour, :millisecond))
    context
  end

  step "the MC checks its schedule again within a minute", context do
    %{timer: timer} = :sys.get_state(ScheduledTasks)
    left = Process.read_timer(timer)
    assert is_integer(left) and left > 0 and left <= 60_000
    context
  end

  step "task {string} was running when the MC stopped", %{args: [name]} = context do
    context = running(context, name)

    stored =
      Path.join(context.mc.home, "scheduled-tasks.json") |> File.read!() |> JSON.decode!()

    assert [%{"lastRunStatus" => "running"}] = stored
    context
  end

  step "task {string} last failed with {string}", %{args: [name, message]} = context do
    assert %{"lastRunStatus" => "failed", "lastRunError" => ^message} = current(context, name)
    context
  end

  step "task {string} exists", %{args: [name]} = context do
    context = context |> task(name) |> run_due(name)
    Map.put(context, :before_restart, current(context, name))
  end

  step "task {string} is listed with its schedule and history", %{args: [name]} = context do
    task = current(context, name)
    assert task == context.before_restart
    assert task["runCount"] == 1 and task["lastRunStatus"] == "succeeded"
    context
  end

  step "a client watches the scheduled tasks", context do
    shape = %{"type" => "scheduledTasks", "mc" => Atom.to_string(node())}
    client = context.mc |> Mc.connect() |> Mc.sub(1, shape)
    {_, client} = Mc.await(client, &(&1["t"] == "scheduledTasks" and &1["tasks"] == []))
    World.put_client(context, "watcher", client)
  end

  step "task {string} is saved, runs or is deleted", %{args: [name]} = context do
    context = context |> task(name) |> run_due(name)

    {{:ok, _}, context} =
      World.call(context, "scheduledTasks.delete", %{"id" => task_id(context, name)})

    context
  end

  step "the client receives the updated task list each time", context do
    [name] = Map.keys(context.tasks)
    id = task_id(context, name)
    frames = &(&1["t"] == "scheduledTasks" and pred(&1["tasks"], id, &2))
    client = World.client(context, "watcher")
    {_, client} = Mc.await(client, &frames.(&1, fn task -> task["runCount"] == 0 end))

    {_, client} =
      Mc.await(client, &frames.(&1, fn task -> task["lastRunStatus"] == "running" end))

    {_, client} = Mc.await(client, &frames.(&1, fn task -> task["runCount"] == 1 end))
    {_, client} = Mc.await(client, &(&1["t"] == "scheduledTasks" and &1["tasks"] == []))
    World.put_client(context, "watcher", client)
  end

  # --- agents through MCP ------------------------------------------------------------------------

  step "thread {string} in {string} has a turn running", %{args: [thread, project]} = context do
    caller(context, thread, project)
  end

  step "the agent of {string} schedules {string} every hour",
       %{args: [thread, title]} = context do
    context = caller(context, thread, "demo")

    reply =
      tool(context, thread, "schedule_task", %{
        "title" => title,
        "prompt" => "Check CI on the open pull requests.",
        "schedule" => every(1)
      })

    assert {:ok, %{"task" => task}} = reply
    context |> Map.put(:reply, reply) |> put_in([:tasks, title], task["id"])
  end

  step "the task is bound to {string}, uses its model and modes, and was created by an agent through MCP",
       %{args: [thread]} = context do
    assert {:ok, %{"task" => task}} = context.reply
    caller = World.thread(context, thread)
    assert task["threadId"] == caller["id"]
    assert task["modelSelection"] == caller["modelSelection"]
    assert task["runtimeMode"] == caller["runtimeMode"]
    assert task["interactionMode"] == caller["interactionMode"]
    assert %{"createdBy" => "agent", "creationSource" => "mcp"} = task
    context
  end

  step "an agent schedules a task without a title", context do
    context = caller(context, "caller", "demo")
    prompt = String.duplicate("Summarise yesterday's commits and flag risky ones. ", 3)

    reply =
      tool(context, "caller", "schedule_task", %{"prompt" => prompt, "schedule" => every(1)})

    context |> Map.put(:reply, reply) |> Map.put(:prompt, prompt)
  end

  step "the title is the first 60 characters of the prompt", context do
    assert {:ok, %{"task" => %{"title" => title}}} = context.reply
    assert title == String.slice(context.prompt, 0, 60)
    context
  end

  step "thread {string} has a task bound to it", %{args: [thread]} = context do
    context = caller(context, thread, "demo")

    reply =
      tool(context, thread, "schedule_task", %{"prompt" => "Check CI.", "schedule" => every(1)})

    assert {:ok, %{"task" => %{"id" => id, "threadId" => bound}}} = reply
    assert bound == World.thread_id(context, thread)
    put_in(context, [:tasks, "bound"], id)
  end

  step "the agent of {string} updates the task to not be bound to its thread",
       %{args: [thread]} = context do
    args = %{"scheduledTaskId" => context.tasks["bound"], "bindToCurrentThread" => false}
    assert {:ok, %{"boundThreadId" => nil}} = tool(context, thread, "update_scheduled_task", args)
    context
  end

  step "each run launches a new worktree from origin's main", context do
    task = current(context, "bound")
    assert task["threadId"] == nil

    assert task["workspaceStrategy"] ==
             %{"type" => "worktree", "baseRef" => "main", "startFromOrigin" => true}

    context
  end

  step "a task belongs to another project", context do
    context = context |> caller("caller", "demo") |> World.create_project("other")
    task(context, "elsewhere", %{"projectId" => id(context, "other")})
  end

  step "the agent of {string} lists, updates, deletes or runs it", %{args: [thread]} = context do
    id = task_id(context, "elsewhere")

    replies = %{
      list: tool(context, thread, "list_scheduled_tasks", %{}),
      update:
        tool(context, thread, "update_scheduled_task", %{
          "scheduledTaskId" => id,
          "title" => "Mine"
        }),
      delete: tool(context, thread, "delete_scheduled_task", %{"scheduledTaskId" => id}),
      run: tool(context, thread, "run_scheduled_task_now", %{"taskId" => id})
    }

    Map.put(context, :replies, replies)
  end

  step "it is not listed and every change is refused", context do
    id = task_id(context, "elsewhere")
    assert {:ok, %{"tasks" => listed}} = context.replies.list
    refute Enum.any?(listed, &(&1["id"] == id))

    for action <- [:update, :delete, :run],
        do: assert({:error, _} = context.replies[action], "#{action} was not refused")

    assert %{"title" => "elsewhere", "runCount" => 0} = current(context, "elsewhere")
    context
  end

  # --- legacy tasks ------------------------------------------------------------------------------

  step "a stored task from an older version runs every 30 seconds", context do
    context = pin(context, at(context, "08:00"))
    :ok = ExUnit.Callbacks.stop_supervised(HalC2.ScheduledTasks)
    created = iso(context.now)

    legacy =
      input(context, "legacy", %{"schedule" => %{"type" => "interval", "everyMs" => 30_000}})
      |> Map.merge(%{
        "id" => "legacy-task",
        "threadId" => nil,
        "createdBy" => "user",
        "creationSource" => "web",
        "createdAt" => created,
        "updatedAt" => created,
        "nextRunAt" => iso(DateTime.add(context.now, 30_000, :millisecond)),
        "lastRunAt" => nil,
        "lastRunStatus" => "never",
        "lastRunError" => nil,
        "runCount" => 0
      })

    File.write!(Path.join(context.mc.home, "scheduled-tasks.json"), JSON.encode!([legacy]))
    put_in(context, [:tasks, "legacy"], "legacy-task")
  end

  step "the MC loads it", context do
    Mc.ensure(HalC2.ScheduledTasks)
    assert %{"schedule" => %{"everyMs" => 30_000}} = current(context, "legacy")
    run_due(context, "legacy")
  end

  step "it runs every minute rather than being refused", context do
    task = current(context, "legacy")
    assert %{"lastRunStatus" => "succeeded", "runCount" => 1} = task
    assert task["nextRunAt"] == iso(DateTime.add(context.now, 60_000, :millisecond))
    context
  end

  # --- helpers -------------------------------------------------------------------------------

  # Pins the scheduler's clock at `at` (a UTC DateTime) for the rest of the scenario.
  defp pin(context, at) do
    at = DateTime.truncate(at, :millisecond)
    Application.put_env(:hal_c2, :scheduled_tasks_clock, fn -> at end)

    ExUnit.Callbacks.on_exit({__MODULE__, :clock}, fn ->
      Application.delete_env(:hal_c2, :scheduled_tasks_clock)
    end)

    Map.put(context, :now, at)
  end

  defp now(context), do: context[:now] || DateTime.truncate(DateTime.utc_now(), :millisecond)

  defp advance(context, ms), do: pin(context, DateTime.add(now(context), ms, :millisecond))

  # `time` ("09:00") local on the scenario's day, as a UTC DateTime.
  defp at(context, time) do
    naive = local_at(context, time)
    [utc | _] = :calendar.local_time_to_universal_time_dst(NaiveDateTime.to_erl(naive))
    DateTime.from_naive!(NaiveDateTime.from_erl!(utc), "Etc/UTC")
  end

  defp local_at(context, time), do: NaiveDateTime.new!(context.day, time(time))

  defp tomorrow_at(context, time), do: NaiveDateTime.new!(Date.add(context.day, 1), time(time))

  defp time(time) do
    [hour, minute] = time |> String.split(":") |> Enum.map(&String.to_integer/1)
    Time.new!(hour, minute, 0)
  end

  defp local(iso) do
    {:ok, at, _} = DateTime.from_iso8601(iso)

    at
    |> DateTime.to_naive()
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_erl()
    |> :calendar.universal_time_to_local_time()
    |> NaiveDateTime.from_erl!()
  end

  defp iso(at), do: DateTime.to_iso8601(at)

  defp every(hours), do: %{"type" => "interval", "everyMs" => hours * @hour}

  defp unquoted(text), do: String.trim(text, "\"")

  defp id(context, project), do: World.project(context, project).id

  defp input(context, title, fields) do
    Map.merge(
      %{
        "title" => title,
        "prompt" => "Prompt of #{title}",
        "enabled" => true,
        "schedule" => every(1),
        "projectId" => id(context, "demo"),
        "workspaceStrategy" => %{"type" => "root"},
        "modelSelection" => @model,
        "runtimeMode" => "full-access",
        "interactionMode" => "default"
      },
      fields
    )
  end

  # Saves over the socket; a created task is remembered by name.
  defp save(context, name, input) do
    {reply, context} = World.call(context, "scheduledTasks.upsert", input)

    context = Map.put(context, :reply, reply)

    case reply do
      {:ok, %{"task" => %{"id" => id}}} -> put_in(context, [:tasks, name], id)
      _ -> context
    end
  end

  # The named task, saved on first mention.
  defp task(context, name, fields \\ %{}) do
    cond do
      name == "missing" or context.tasks[name] ->
        context

      true ->
        reply = context[:reply]
        # A second after the last one, so the order they were created in is clear.
        context =
          if context.tasks == %{}, do: pin(context, now(context)), else: advance(context, 1_000)

        context = save(context, name, input(context, name, fields))
        assert {:ok, _} = context.reply, "saving #{name} failed: #{inspect(context.reply)}"
        Map.put(context, :reply, reply)
    end
  end

  defp task_id(context, name), do: context.tasks[name] || name

  defp tasks do
    {:ok, %{"tasks" => tasks}} = ScheduledTasks.list()
    tasks
  end

  defp current(context, name) do
    id = task_id(context, name)
    Enum.find(tasks(), &(&1["id"] == id)) || flunk("task #{name} is not listed")
  end

  defp edit(context, name, fields) do
    input = Map.merge(current(context, name), fields)
    {reply, context} = World.call(context, "scheduledTasks.upsert", input)
    Map.put(context, :reply, reply)
  end

  defp set_enabled(context, name, enabled) do
    context = task(context, name)
    payload = %{"id" => task_id(context, name), "enabled" => enabled}
    {reply, context} = World.call(context, "scheduledTasks.setEnabled", payload)
    Map.put(context, :reply, reply)
  end

  defp run_now(context, name) do
    context = task(context, name)

    {reply, context} =
      World.call(context, "scheduledTasks.runNow", %{"id" => task_id(context, name)})

    Map.put(context, :reply, reply)
  end

  defp tick, do: send(ScheduledTasks, :tick)

  # Moves the clock past the task's next run, wakes the scheduler and waits for the run.
  # A task already due by the clock (the MC checked its schedule) is only awaited.
  defp run_due(context, name) do
    context = task(context, name)
    task = current(context, name)
    {:ok, due, _} = DateTime.from_iso8601(task["nextRunAt"])

    context =
      if DateTime.compare(due, now(context)) == :gt do
        context = pin(context, DateTime.add(due, 1_000, :millisecond))
        {:ok, _} = ScheduledTasks.subscribe(self())
        tick()
        context
      else
        context
      end

    await_task(context, name, &(&1["runCount"] > task["runCount"]))
    Map.put(context, :run_count, task["runCount"])
  end

  defp await_task(context, name, fun) do
    {:ok, _} = ScheduledTasks.subscribe(self())
    await_changed(context, name, fun)
  end

  defp await_changed(context, name, fun) do
    id = task_id(context, name)
    task = Enum.find(tasks(), &(&1["id"] == id))

    if task && fun.(task) do
      task
    else
      receive do
        {:hal_c2_scheduled_tasks, _, _} -> await_changed(context, name, fun)
      after
        5_000 -> flunk("task #{name} never got there: #{inspect(task)}")
      end
    end
  end

  defp pred(tasks, id, fun), do: Enum.any?(tasks, &(&1["id"] == id and fun.(&1)))

  # A task bound to its own idle thread "t-<name>".
  defp bound(context, name) do
    thread = "t-#{name}"
    context = World.named_thread(context, thread)
    task(context, name, %{"threadId" => thread})
  end

  # Holds the task's thread so a run sending into it stays running.
  defp suspend(context, name) do
    stream = HalC2.Streams.ensure(World.thread_id(context, "t-#{name}"))
    :sys.suspend(stream)
    stream
  end

  # A bound task that became due and is running, its message held up.
  defp running(context, name) do
    context = bound(context, name)
    stream = suspend(context, name)
    {:ok, due, _} = DateTime.from_iso8601(current(context, name)["nextRunAt"])
    context = pin(context, DateTime.add(due, 1_000, :millisecond))
    {:ok, _} = ScheduledTasks.subscribe(self())
    tick()
    await_task(context, name, &(&1["lastRunStatus"] == "running"))
    Map.put(context, :suspended, stream)
  end

  # The thread a run of `task` launched, with its entity.
  defp launched(context, task) do
    %{"title" => title, "projectId" => project} = task

    thread =
      await_launched(fn ->
        Enum.find_value(HalC2.Shell.rows(), fn
          {{_, id}, {"thread", %{"title" => ^title, "projectId" => ^project}}} -> id
          _ -> nil
        end)
      end)

    context = put_in(context, [:threads, thread], thread)
    {context, World.thread(context, thread)}
  end

  defp await_launched(find) do
    case find.() do
      nil ->
        receive do
          {:hal_c2_shell, _} -> await_launched(find)
        after
          5_000 -> flunk("no thread was launched")
        end

      id ->
        id
    end
  end

  # A thread of `project` with a turn running, whose agent calls the MCP tools.
  defp caller(context, thread, project) do
    Mc.ensure(HalC2.Mcp)

    context =
      if (context[:threads] || %{})[thread],
        do: context,
        else: World.named_thread(context, thread, project)

    if context[:callers][thread],
      do: context,
      else:
        context |> World.running_turn(thread) |> put_in([Access.key(:callers, %{}), thread], true)
  end

  defp tool(context, thread, name, arguments) do
    %{authorization: auth} = HalC2.Mcp.server(World.thread_id(context, thread), "codex")

    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => arguments}
    }

    case HalC2.Mcp.handle(auth, JSON.encode!(request)) do
      {200, %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}}} ->
        {:error, text}

      {200, %{"result" => %{"structuredContent" => result}}} ->
        {:ok, result}
    end
  end
end
