defmodule HalC2.ScheduledTasksRunsTest do
  use ExUnit.Case, async: false

  alias HalC2.ScheduledTasks

  @moduletag :tmp_dir
  @clock {__MODULE__, :clock}

  # Every wait here is for a message the scheduler or a run sends, so this only bounds
  # how long a failing test takes to say so. ExUnit's 100 ms default is shorter than a
  # loaded runner may take to schedule the process that sends it.
  @wait 5_000

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    :persistent_term.put(@clock, ~U[2026-06-01 08:00:00.000Z])
    Application.put_env(:hal_c2, :scheduled_tasks_clock, fn -> :persistent_term.get(@clock) end)

    on_exit(fn ->
      :persistent_term.erase(@clock)
      Application.delete_env(:hal_c2, :scheduled_tasks_clock)
      Application.delete_env(:hal_c2, :scheduled_tasks_fire)
      Application.delete_env(:hal_c2, :scheduled_tasks_run_timeout_ms)
    end)

    start_supervised!(ScheduledTasks)
    {:ok, _} = ScheduledTasks.subscribe(self())
    :ok
  end

  defp interval_task(id \\ "t1") do
    {:ok, _} =
      ScheduledTasks.upsert(%{
        "id" => id,
        "title" => id,
        "prompt" => "go",
        "enabled" => true,
        "schedule" => %{"type" => "interval", "everyMs" => 60_000},
        "projectId" => "p1"
      })
  end

  defp advance(ms) do
    :persistent_term.put(@clock, DateTime.add(:persistent_term.get(@clock), ms, :millisecond))
    send(ScheduledTasks, :tick)
    :sys.get_state(ScheduledTasks)
  end

  defp task(id \\ "t1") do
    {:ok, %{"tasks" => tasks}} = ScheduledTasks.list()
    Enum.find(tasks, &(&1["id"] == id))
  end

  defp await_idle do
    if task()["lastRunStatus"] == "running" do
      assert_receive {:hal_c2_scheduled_tasks, _, _}, @wait
      await_idle()
    end
  end

  test "a run that exits fails its task and the scheduler lives on" do
    Application.put_env(:hal_c2, :scheduled_tasks_fire, fn _, _ -> exit(:crashed) end)
    server = Process.whereis(ScheduledTasks)
    interval_task()

    advance(60_000)
    await_idle()

    assert Process.whereis(ScheduledTasks) == server
    assert %{"lastRunStatus" => "failed", "runCount" => 1} = task()
  end

  test "a run in flight does not block the scheduler or keep its timer spinning" do
    blocking_fire()
    interval_task()
    advance(60_000)
    assert_receive {:started, run}, @wait
    send(run, :armed)

    # Answers while the run is out, and is not waiting on the due time it already met.
    assert %{"lastRunStatus" => "running"} = task()
    assert Process.read_timer(:sys.get_state(ScheduledTasks).timer) > 1_000

    send(run, :release)
    await_idle()
    assert %{"lastRunStatus" => "succeeded", "runCount" => 1} = task()
  end

  test "enabling a task that is already on keeps its pending run" do
    {:ok, %{"task" => %{"nextRunAt" => next}}} = interval_task()
    :persistent_term.put(@clock, DateTime.add(:persistent_term.get(@clock), 30_000, :millisecond))

    assert {:ok, %{"task" => %{"nextRunAt" => ^next}}} =
             ScheduledTasks.set_enabled(%{"id" => "t1", "enabled" => true})
  end

  # A fire that blocks until released. It cannot finish before the test says
  # `:armed`, so a test that monitors the run on `{:started, run}` always has its
  # monitor in place first: there is no window in which the run has already gone
  # and the monitor answers `:noproc` (#207).
  defp blocking_fire do
    test = self()

    Application.put_env(:hal_c2, :scheduled_tasks_fire, fn _, _ ->
      send(test, {:started, self()})

      receive do
        :armed -> :ok
      end

      receive do
        :release -> {:ok, %{}}
      end
    end)
  end

  # Monitors a started run, then lets it proceed (see `blocking_fire/0`).
  defp monitor_started(run) do
    ref = Process.monitor(run)
    send(run, :armed)
    ref
  end

  test "a task deleted and made again during a run does not take the old run's result" do
    blocking_fire()
    interval_task()
    caller = Task.async(fn -> ScheduledTasks.run_now(%{"id" => "t1"}) end)
    assert_receive {:started, run}, @wait
    ref = monitor_started(run)

    assert {:ok, %{"id" => "t1"}} = ScheduledTasks.delete(%{"id" => "t1"})
    assert {:error, %{"message" => "Schedule task not found."}} = Task.await(caller)
    assert_receive {:DOWN, ^ref, :process, ^run, :killed}, @wait

    interval_task()
    assert %{"lastRunStatus" => "never", "runCount" => 0} = task()

    # Nothing of the old run is left to block the new task.
    Task.async(fn -> ScheduledTasks.run_now(%{"id" => "t1"}) end)
    assert_receive {:started, _}, @wait
  end

  test "a run does not outlive the scheduler that started it" do
    blocking_fire()
    interval_task()
    advance(60_000)
    assert_receive {:started, run}, @wait
    ref = monitor_started(run)

    # The run is linked to the scheduler from the moment it exists, so the kill below
    # reaches it however late the exit signal is delivered.
    scheduler = Process.whereis(ScheduledTasks)
    assert {:links, links} = Process.info(run, :links)
    assert scheduler in links

    Process.exit(scheduler, :kill)

    assert_receive {:DOWN, ^ref, :process, ^run, :killed}, @wait
  end

  test "a scheduler updated in place from before runs were linked outlives a run it ends" do
    scheduler = Process.whereis(ScheduledTasks)
    down = Process.monitor(scheduler)

    # What the version before was: a scheduler that did not trap exits.
    :sys.replace_state(scheduler, fn state ->
      Process.flag(:trap_exit, false)
      state
    end)

    # What `HalC2.Hot` does for a process whose module changed.
    :ok = :sys.suspend(scheduler)
    :ok = :sys.change_code(scheduler, ScheduledTasks, nil, :hot)
    :ok = :sys.resume(scheduler)

    blocking_fire()
    interval_task()
    caller = Task.async(fn -> ScheduledTasks.run_now(%{"id" => "t1"}) end)
    assert_receive {:started, run}, @wait
    ref = monitor_started(run)
    assert {:ok, _} = ScheduledTasks.delete(%{"id" => "t1"})
    Task.await(caller)
    assert_receive {:DOWN, ^ref, :process, ^run, :killed}, @wait

    _ = :sys.get_state(scheduler)
    refute_received {:DOWN, ^down, _, _, _}
  end

  test "a run started before the scheduler was updated in place does not outlive it" do
    scheduler = Process.whereis(ScheduledTasks)
    blocking_fire()
    interval_task()
    advance(60_000)
    assert_receive {:started, run}, @wait
    ref = monitor_started(run)

    # What the version before was: a scheduler that did not trap exits, nor link its runs.
    :sys.replace_state(scheduler, fn state ->
      Process.flag(:trap_exit, false)
      Process.unlink(run)
      state
    end)

    :ok = :sys.suspend(scheduler)
    :ok = :sys.change_code(scheduler, ScheduledTasks, nil, :hot)
    :ok = :sys.resume(scheduler)

    Process.exit(scheduler, :kill)

    assert_receive {:DOWN, ^ref, :process, ^run, :killed}, @wait
  end

  test "a run that never finishes times out, fails its task and answers its caller" do
    Application.put_env(:hal_c2, :scheduled_tasks_run_timeout_ms, 50)
    blocking_fire()
    interval_task()
    caller = Task.async(fn -> ScheduledTasks.run_now(%{"id" => "t1"}) end)
    assert_receive {:started, run}, @wait
    ref = monitor_started(run)

    # The waiting "run now" caller is answered with the failed task, as for a
    # run that fails or crashes.
    assert {:ok,
            %{
              "task" => %{
                "lastRunStatus" => "failed",
                "lastRunError" => "The run timed out.",
                "runCount" => 1
              }
            }} = Task.await(caller, @wait)

    assert_receive {:DOWN, ^ref, :process, ^run, :killed}, @wait
    assert %{"lastRunStatus" => "failed", "lastRunError" => "The run timed out."} = task()

    # The timed-out run no longer blocks the task: it can run again.
    Application.delete_env(:hal_c2, :scheduled_tasks_run_timeout_ms)
    caller = Task.async(fn -> ScheduledTasks.run_now(%{"id" => "t1"}) end)
    assert_receive {:started, run}, @wait
    send(run, :armed)
    send(run, :release)

    assert {:ok, %{"task" => %{"lastRunStatus" => "succeeded", "runCount" => 2}}} =
             Task.await(caller, @wait)
  end

  # A run started before the cap existed has no timer of its own and none of
  # what its cleanup needs; an upgrade in place arms it for the time left
  # (never more than the cap, even if the clock moved backwards meanwhile)
  # and fills those in, and the armed timer then ends it like any other.
  test "an upgrade in place arms a pre-cap run, which then times out" do
    scheduler = Process.whereis(ScheduledTasks)
    blocking_fire()

    {:ok, _} =
      ScheduledTasks.upsert(%{
        "id" => "t1",
        "title" => "t1",
        "prompt" => "go",
        "enabled" => true,
        "schedule" => %{"type" => "interval", "everyMs" => 60_000},
        "projectId" => "p1",
        "threadId" => "th-old"
      })

    caller = Task.async(fn -> ScheduledTasks.run_now(%{"id" => "t1"}) end)
    assert_receive {:started, run}, @wait
    ref = monitor_started(run)

    old_shape = fn state ->
      Map.update!(state, :runs, fn runs ->
        Map.new(runs, fn {pid, run} ->
          if run[:timer], do: Process.cancel_timer(run.timer)
          Process.unlink(pid)
          {pid, Map.drop(run, [:timer, :thread_id, :message_id])}
        end)
      end)
    end

    upgrade = fn ->
      :ok = :sys.suspend(scheduler)
      :ok = :sys.change_code(scheduler, ScheduledTasks, nil, :hot)
      :ok = :sys.resume(scheduler)
    end

    :sys.replace_state(scheduler, old_shape)
    upgrade.()

    assert %{^run => backfilled} = :sys.get_state(scheduler).runs
    assert backfilled.thread_id == "th-old"
    assert backfilled.message_id =~ "scheduled-task-message:t1:"
    assert backfilled.message_id =~ ":manual"
    assert is_reference(backfilled.timer)

    # Again, now with a short cap and a clock that moved backwards in
    # flight: the re-armed timer is at most the cap, and firing it fails
    # the task and answers the waiting caller.
    :sys.replace_state(scheduler, old_shape)
    :persistent_term.put(@clock, ~U[2026-06-01 07:00:00.000Z])
    Application.put_env(:hal_c2, :scheduled_tasks_run_timeout_ms, 50)
    upgrade.()

    assert %{^run => rearmed} = :sys.get_state(scheduler).runs
    assert (left = Process.read_timer(rearmed.timer)) == false or left <= 50

    assert {:ok,
            %{
              "task" => %{
                "lastRunStatus" => "failed",
                "lastRunError" => "The run timed out."
              }
            }} = Task.await(caller, @wait)

    assert_receive {:DOWN, ^ref, :process, ^run, :killed}, @wait
  end

  test "a timeout for a run that already finished is ignored" do
    Application.put_env(:hal_c2, :scheduled_tasks_fire, fn _, _ -> {:ok, %{}} end)
    interval_task()

    assert {:ok, %{"task" => %{"lastRunStatus" => "succeeded"}}} =
             ScheduledTasks.run_now(%{"id" => "t1"})

    send(ScheduledTasks, {:run_timeout, self()})
    _ = :sys.get_state(ScheduledTasks)

    assert %{"lastRunStatus" => "succeeded", "runCount" => 1} = task()
  end
end
