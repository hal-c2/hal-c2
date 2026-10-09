defmodule HalC2.ScheduledTasksProofTest do
  # Commands, ticks and watchers arriving while runs are in flight, and the scheduler
  # crashing with runs out. prop/hal_c2/scheduled_tasks_prop_test.exs settles every run
  # before its next command; this explores every order up to the bounds.
  @plain "changes no task or run: the model leaves it out"

  use HalC2.Proof,
    model: "scheduled_tasks.maude",
    module: "SCHEDULED-TASKS",
    check: "SCHEDULED-TASKS-PROPS",
    code: [
      {:exports, HalC2.ScheduledTasks},
      {:messages, HalC2.ScheduledTasks},
      {:state, HalC2.ScheduledTasks}
    ],
    covers: %{
      "HalC2.ScheduledTasks.upsert/1" => "upsert",
      "HalC2.ScheduledTasks.delete/1" => "delete",
      "HalC2.ScheduledTasks.set_enabled/1" => "set-enabled",
      "HalC2.ScheduledTasks.run_now/1" => ~w(run-now run-now-gone run-now-running),
      "HalC2.ScheduledTasks.subscribe/1" => "subscribe",
      "HalC2.ScheduledTasks.unsubscribe/1" => "unsubscribe",
      "HalC2.ScheduledTasks handle_call {:upsert, _}" => "upsert",
      "HalC2.ScheduledTasks handle_call {:delete, _}" => "delete",
      "HalC2.ScheduledTasks handle_call {:set_enabled, _, _}" => "set-enabled",
      "HalC2.ScheduledTasks handle_call {:run_now, _}" =>
        ~w(run-now run-now-gone run-now-running),
      "HalC2.ScheduledTasks handle_call {:subscribe, _}" => "subscribe",
      "HalC2.ScheduledTasks handle_cast {:unsubscribe, _}" => "unsubscribe",
      "HalC2.ScheduledTasks handle_info :tick" => "tick",
      "HalC2.ScheduledTasks handle_info {:run_done, _, _}" => ~w(run-done stale),
      "HalC2.ScheduledTasks handle_info {:DOWN, _, :process, _, _}" =>
        ~w(run-down watcher-down stale),
      "HalC2.ScheduledTasks state :tasks" => "tsk",
      "HalC2.ScheduledTasks state :runs" => "run",
      "HalC2.ScheduledTasks state :watchers" => "watching",
      "HalC2.ScheduledTasks state :timer" => "armed"
    },
    abstracts: %{
      "HalC2.ScheduledTasks.start_link/1" => "starts the process crash and restart stand for",
      "HalC2.ScheduledTasks.list/1" => @plain,
      "HalC2.ScheduledTasks handle_call :list" => @plain,
      "HalC2.ScheduledTasks.next_run/2" => "aims a run; the model counts ticks",
      "HalC2.ScheduledTasks handle_info _" => "ignores what it does not know, as stale does",
      "HalC2.ScheduledTasks state :path" =>
        "where the tasks are saved; the model keeps them across a crash without a file"
    },
    environment: %{
      "fire" => "fire/2 returns: the prompt is sent",
      "fire-dies" => "the run's process exits, perhaps once the prompt was sent",
      "advance" => "the clock moves on",
      "crash" => "the scheduler stops: its runs table and timer go, and its runs with it",
      "restart" =>
        "the supervisor starts it again; init/1 fails the runs it was in the middle of",
      "watcher-dies" => "a client socket that watches exits"
    },
    scenarios: %{
      "settings/scheduled-tasks.feature" => [
        "A task that is already running cannot be started again",
        "Deleting a task during its run ends the run",
        "A run cut off by shutdown is marked failed",
        "The user runs a task now",
        "Pausing a task stops its runs and resuming schedules it again",
        "Editing a task that no longer exists fails",
        "The user deletes a task"
      ]
    }

  # Two tasks, each due soon; the second is a task alone, with more of everything else.
  @starts ["one(3, 1, 4)", "seeded(1, 1, 2)"]

  # Rules the code's own steps do not need; the fair ones are the code's, and `fire`
  # (the prompt is sent) is what B3 makes an assumption: a run that never returns
  # keeps its task running for good, as no run has a timeout.
  @fair ~w(tick run-done run-down stale fire restart watcher-down unsubscribe)

  for init <- @starts do
    test "a run's result is applied only to the task record that started it, from #{init}",
         %{proof: proof} do
      refute_reachable(proof, unquote(init), "mixed", [])
    end

    test "a task never has two runs at once, in the table or as processes, from #{init}",
         %{proof: proof} do
      refute_reachable(proof, unquote(init), "twoEntries", [])
      refute_reachable(proof, unquote(init), "twoRunners", [])
    end

    test "a task marked running always has a run in the table, from #{init}", %{proof: proof} do
      refute_reachable(proof, unquote(init), "stuckRunning", [])
    end

    test "a fire_key fires at most once, given a prompt takes longer than the clock's unit, from #{init}",
         %{proof: proof} do
      refute_reachable(proof, unquote(init), "refired", [])
    end

    test "a run_now caller never gets two replies, from #{init}", %{proof: proof} do
      refute_reachable(proof, unquote(init), "twiceAnswered", [])
    end
  end

  test "a run_now caller waiting on a run gets its reply, if prompts are sent", %{proof: proof} do
    assert_ltl(proof, "one(1, 1, 2)", "[] (waiting(1) -> <> answered(1))", fair: @fair)
  end

  test "a started run is recorded in the end, if prompts are sent", %{proof: proof} do
    formula = "[] (entered(1) -> <> ~ entered(1)) /\\ [] (entered(2) -> <> ~ entered(2))"
    assert_ltl(proof, "one(1, 1, 2)", formula, fair: @fair)
  end

  test "a due task starts in the end: the timer is armed again after every change",
       %{proof: proof} do
    assert_ltl(proof, "one(1, 1, 2)", "[] (due(1) -> <> ~ due(1))", fair: @fair)
  end

  test "a watcher that exits is dropped in the end", %{proof: proof} do
    for watcher <- 1..2 do
      assert_ltl(proof, "watched(0, 1, 0)", "[] (lost(#{watcher}) -> <> ~ lost(#{watcher}))",
        fair: @fair
      )
    end
  end
end
