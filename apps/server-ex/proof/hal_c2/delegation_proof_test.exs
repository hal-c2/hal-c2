defmodule HalC2.DelegationProofTest do
  # One delegated task, its parent and a child thread with a few runs and a command it
  # may leave running in the background, on a provider that wakes itself when the command
  # ends or one that does not, with the caller waiting or not and cancelling, a report
  # that fails, and the MC stopping at any step and booting again. prop/hal_c2/delegation_prop_test.exs runs the code in sequence;
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
      "HalC2.Orchestration.Delegation.finished/3" => "finished",
      "HalC2.Orchestration.Delegation.settle_if_quiet/1" => ~w(finished check sweep),
      "HalC2.Orchestration.Delegation.report/5" => "report-fail",
      "HalC2.Orchestration.Delegation.cancel/2" => ~w(cancel cancel-refused),
      "HalC2.Orchestration.Delegation.reconcile/2" => ~w(reconcile-boot reconcile-after),
      "HalC2.Orchestration.Recovery.run/0" => ~w(reconcile-boot recover-settle),
      "HalC2.Orchestration.Recovery.settle/1" => "recover-settle",
      "HalC2.Orchestration.Recovery.continue/0" => ~w(continue skip-continue reconcile-after),
      "HalC2.Orchestration.Delegation hook(:reporting)" => "report-fail",
      "HalC2.Orchestration.Delegation hook(:settling)" => "report-fail",
      "HalC2.Orchestration.Delegation hook(:expiring)" => "time-out",
      "HalC2.Orchestration.Delegation hook(:cancelling)" => "cancel",
      "HalC2.Orchestration.Delegation hook(:starting)" => "record"
    },
    abstracts: %{
      "HalC2.Orchestration.Delegation.request/1" => @tool,
      "HalC2.Orchestration.Delegation.task_status/2" => "reads a task; changes nothing",
      "HalC2.Orchestration.Delegation.wait_budget/1" =>
        "how long a wait lasts; the model's wait may give up at any time",
      "HalC2.Orchestration.Delegation.wake_policy/1" => @policy,
      "HalC2.Orchestration.Delegation.preamble/1" =>
        "the text the child's first message opens with; the model has the launch",
      "HalC2.Orchestration.Delegation.resolve_delivery/1" => @policy,
      "HalC2.Orchestration.Delegation.acknowledge_child_read/3" =>
        "reading the child's answer in full resolves its delivery, as resolve_delivery/1 does; no part of how the task ends",
      "HalC2.Orchestration.Delegation.flush_pending/1" =>
        "wakes the caller for results that landed while a wake was already with it; with one task no delivery is left pending that way, and its caller finished/3 is covered",
      "HalC2.Orchestration.Delegation.stop_wakes/2" =>
        "stopping the caller's turn disposes its tasks' deliveries and cancels a queued wake; disposal is in the model through cancel, and a suppressed wake can only wake less",
      "HalC2.Orchestration.Delegation.accept_delivery/1" =>
        "the provider reads the message that woke the parent; the model ends at the message",
      "HalC2.Orchestration.Recovery.start_link/0" => "starts the process that runs boot",
      "HalC2.Orchestration.Recovery.stopping?/0" =>
        "tells the MC is shutting down; the model has crash"
    },
    environment: %{
      "child-end" => "a run of the child thread ends, and its report starts",
      "child-start" => "the user rolls back and asks again, so the child works again",
      "bg-start" => "a run of the child leaves a command running in the background",
      "bg-end" =>
        "the command ends; Codex is woken with a run about it, Grok's runtime checks the child",
      "wake-run" => "the Codex runtime queues its run about the command (a Claude CLI its own)",
      "crash" => "the MC stops: its calls, reports and waits die; its store stays",
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
        "A task still working when the MC stopped ends with the turn that continues it",
        "A task whose subagent is not continued after a restart is interrupted",
        "Cancelling a running task interrupts the subagent",
        "Cancelling a finished task is refused",
        "A subagent's own later turn that finishes its background work delivers the task's result",
        "A task is not settled between its subagent's background work ending and the turn that work wakes",
        "A Grok subagent's background work ending settles its task with its last answer",
        "A task whose end report was lost settles without a restart",
        "Cancelling a task that waits on background work stops that work"
      ]
    }

  # The faults the environment may or may not take, and what the user does, which the
  # code does not wait for.
  @besides ~w(crash parent-idle child-start report-fail launch-failed time-out cancel)

  # The code's own rules, which a rule that stays enabled takes in the end.
  @fair ~w(record launch wait-done child-end finished bg-end wake-run check sweep reconcile-boot
           recover-settle continue skip-continue reconcile-after restart)

  for init <- [
        "waiting-start(2, wakes-itself)",
        "async-start(2, wakes-itself)",
        "waiting-start(2, grok)",
        "async-start(2, grok)"
      ] do
    test "a task settles once, from #{init}", %{proof: proof} do
      refute_reachable(proof, unquote(init), "settled-twice", [])
    end

    test "the parent is woken at most once per task, from #{init}", %{proof: proof} do
      refute_reachable(proof, unquote(init), "woken-twice", [])
    end

    test "a cancelled task never wakes the parent, from #{init}", %{proof: proof} do
      refute_reachable(proof, unquote(init), "cancelled-woken", [])
    end

    test "a result marked delivered is never lost to a crash, from #{init}", %{proof: proof} do
      refute_reachable(proof, unquote(init), "lost-wake", [])
    end

    test "a result acknowledged to a wait was there to read, from #{init}", %{proof: proof} do
      refute_reachable(proof, unquote(init), "unread", [])
    end

    test "a task never ends while a command of its child runs, from #{init}", %{proof: proof} do
      refute_reachable(proof, unquote(init), "bg-settled", [])
    end

    # A provider that wakes itself (Codex, Claude) ends the command before it queues the
    # run about it, and nothing the MC stores tells that gap from a quiet child: a report
    # or a check landing in it settles the task early. A known limit, not claimed here.
    if init =~ "grok" do
      test "a task never ends while its child works or owes work, from #{init}", %{
        proof: proof
      } do
        refute_reachable(proof, unquote(init), "owing-settled", [])
      end
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
