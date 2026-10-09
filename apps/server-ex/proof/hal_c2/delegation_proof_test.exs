defmodule HalC2.DelegationProofTest do
  # One delegated task, its parent and a child thread with two runs, with the caller
  # waiting or not and cancelling, a report that fails, and the MC stopping at any step
  # and booting again. prop/hal_c2/delegation_prop_test.exs runs the code in sequence;
  # this explores every interleaving up to the bounds.
  @tool "the agent's tool call, a thin front to start/3 and wait/3; the model has the call and the wait"
  @policy "changes the wake or delivery of a task already in the parent; no part of how it ends"

  use HalC2.Proof,
    model: "delegation.maude",
    module: "DELEGATION",
    check: "DELEGATION-PROPS",
    code: [
      {:exports, HalC2.Orchestration.Delegation},
      {:calls, HalC2.Orchestration.Delegation, :hook},
      {:exports, HalC2.Orchestration.Recovery}
    ],
    covers: %{
      "HalC2.Orchestration.Delegation.delegate/3" =>
        ~w(record launch launch-failed wait-done time-out),
      "HalC2.Orchestration.Delegation.wait/3" => ~w(wait-done time-out),
      "HalC2.Orchestration.Delegation.finished/3" => ~w(finished finished-late wake),
      "HalC2.Orchestration.Delegation.report/5" => "report-fail",
      "HalC2.Orchestration.Delegation.cancel/2" => ~w(cancel cancel-refused),
      "HalC2.Orchestration.Delegation.reconcile/2" => ~w(reconcile-boot reconcile-after),
      "HalC2.Orchestration.Recovery.run/0" => ~w(reconcile-boot recover-settle),
      "HalC2.Orchestration.Recovery.settle/1" => "recover-settle",
      "HalC2.Orchestration.Recovery.continue/0" => ~w(continue skip-continue reconcile-after),
      "HalC2.Orchestration.Delegation hook(:reporting)" => "report-fail",
      "HalC2.Orchestration.Delegation hook(:expiring)" => "time-out",
      "HalC2.Orchestration.Delegation hook(:cancelling)" => "cancel"
    },
    abstracts: %{
      "HalC2.Orchestration.Delegation.request/1" => @tool,
      "HalC2.Orchestration.Delegation.task_status/2" => "reads a task; changes nothing",
      "HalC2.Orchestration.Delegation.wait_budget/1" =>
        "how long a wait lasts; the model's wait may give up at any time",
      "HalC2.Orchestration.Delegation.wake_policy/1" => @policy,
      "HalC2.Orchestration.Delegation.resolve_delivery/1" => @policy,
      "HalC2.Orchestration.Delegation.accept_delivery/1" =>
        "the provider reads the message that woke the parent; the model ends at the message",
      "HalC2.Orchestration.Recovery.start_link/0" => "starts the process that runs boot",
      "HalC2.Orchestration.Recovery.stopping?/0" =>
        "tells the MC is shutting down; the model has crash"
    },
    environment: %{
      "child-end" => "a run of the child thread ends, and its report starts",
      "child-start" => "the user rolls back and asks again, so the child works again",
      "crash" => "the MC stops: its calls, reports, waits and wakes die; its store stays",
      "restart" => "the MC starts again and boots",
      "parent-idle" => "the parent's own turn ends"
    },
    scenarios: %{
      "mc/orchestration/delegation.feature" => [
        "Waiting for a task returns its result when it finishes",
        "A wait that times out leaves the task running",
        "A background task delivers its result to the caller as a message",
        "A completion delivered twice wakes the caller once",
        "A waited-for task that finishes while the caller is busy is only acknowledged",
        "A waited-for task that finishes after the caller went idle is delivered",
        "A task whose end never reached its caller settles when the MC starts",
        "A task whose end report timed out settles on the retry",
        "A task still working when the MC stopped is not settled when it starts",
        "A task whose subagent is not continued after a restart is interrupted",
        "Cancelling a running task interrupts the subagent",
        "Cancelling a finished task is refused"
      ]
    }

  # The faults the environment may or may not take, and what the user does, which the
  # code does not wait for.
  @besides ~w(crash parent-idle child-start report-fail launch-failed time-out cancel)

  # The code's own rules, which a rule that stays enabled takes in the end.
  @fair ~w(record launch wait-done child-end finished finished-late wake reconcile-boot
           recover-settle continue skip-continue reconcile-after restart)

  for init <- ["waiting-start(2)", "async-start(2)"] do
    test "a task settles once, from #{init}", %{proof: proof} do
      refute_reachable(proof, unquote(init), "settled-twice", [])
    end

    test "the parent is woken at most once per task, from #{init}", %{proof: proof} do
      refute_reachable(proof, unquote(init), "woken-twice", [])
    end

    test "a cancelled task never wakes the parent, from #{init}", %{proof: proof} do
      refute_reachable(proof, unquote(init), "cancelled-woken", [])
    end

    test "a result acknowledged to a wait was there to read, from #{init}", %{proof: proof} do
      refute_reachable(proof, unquote(init), "unread", [])
    end

    # Fewer faults than a report has attempts: a report that gave up leaves the task
    # running until the next boot.
    test "a task cannot get stuck while fewer reports fail than are tried, from #{init}", %{
      proof: proof
    } do
      refute_deadlock(proof, unquote(init), "resting", besides: @besides)
    end

    test "a task whose child stopped ends, across restarts, while reports are retried, from #{init}",
         %{proof: proof} do
      assert_ltl(proof, unquote(init), "[] (stopped -> <> over)", fair: @fair)
    end
  end
end
