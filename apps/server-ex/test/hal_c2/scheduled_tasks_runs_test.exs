defmodule HalC2.ScheduledTasksRunsTest do
  use ExUnit.Case, async: false

  alias HalC2.ScheduledTasks

  @moduletag :tmp_dir
  @clock {__MODULE__, :clock}

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    :persistent_term.put(@clock, ~U[2026-06-01 08:00:00.000Z])
    Application.put_env(:hal_c2, :scheduled_tasks_clock, fn -> :persistent_term.get(@clock) end)

    on_exit(fn ->
      :persistent_term.erase(@clock)
      Application.delete_env(:hal_c2, :scheduled_tasks_clock)
      Application.delete_env(:hal_c2, :scheduled_tasks_fire)
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
      assert_receive {:hal_c2_scheduled_tasks, _, _}
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
    test = self()

    Application.put_env(:hal_c2, :scheduled_tasks_fire, fn _, _ ->
      send(test, {:started, self()})

      receive do
        :release -> {:ok, %{}}
      end
    end)

    interval_task()
    advance(60_000)
    assert_receive {:started, run}

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

  defp blocking_fire do
    test = self()

    Application.put_env(:hal_c2, :scheduled_tasks_fire, fn _, _ ->
      send(test, {:started, self()})

      receive do
        :release -> {:ok, %{}}
      end
    end)
  end

  test "a task deleted and made again during a run does not take the old run's result" do
    blocking_fire()
    interval_task()
    caller = Task.async(fn -> ScheduledTasks.run_now(%{"id" => "t1"}) end)
    assert_receive {:started, run}
    ref = Process.monitor(run)

    assert {:ok, %{"id" => "t1"}} = ScheduledTasks.delete(%{"id" => "t1"})
    assert {:error, %{"message" => "Schedule task not found."}} = Task.await(caller)
    assert_receive {:DOWN, ^ref, :process, ^run, :killed}

    interval_task()
    assert %{"lastRunStatus" => "never", "runCount" => 0} = task()

    # Nothing of the old run is left to block the new task.
    Task.async(fn -> ScheduledTasks.run_now(%{"id" => "t1"}) end)
    assert_receive {:started, _}
  end

  test "a run does not outlive the scheduler that started it" do
    blocking_fire()
    interval_task()
    advance(60_000)
    assert_receive {:started, run}
    ref = Process.monitor(run)

    Process.exit(Process.whereis(ScheduledTasks), :kill)

    assert_receive {:DOWN, ^ref, :process, ^run, :killed}
  end
end
