defmodule HalC2.TurnsProofTest do
  # One thread's turns: a run starting, a message queued behind it and one more on the
  # way, a Codex runtime that drives them, TurnWatch, the idle session check, an
  # interrupt and a delete, through every interleaving of their processes, with a
  # runtime that crashes, a start that raises or times out, and the MC restarting.
  # A run's "waiting" is "running" here, and Codex stands for every runtime.
  @items "writes a turn's items, streamed text and requests; no run's status changes"
  @changes "builds a transaction's changes; each transaction is one step"
  @preparing "a run that waits on its worktree, then starts through begin_turn/2 as a message does"
  @steer "adds a message to the turn the runtime drives; here a message queues behind an active run"

  use HalC2.Proof,
    model: "turns.maude",
    module: "TURNS",
    check: "TURNS-PROPS",
    code: [
      {:exports, HalC2.Orchestration.TurnWatch},
      {:messages, HalC2.Orchestration.TurnWatch},
      {:exports, HalC2.Orchestration.IdleSessions},
      {:messages, HalC2.Orchestration.IdleSessions},
      {:exports, HalC2.Orchestration.Recovery},
      {:exports, HalC2.Orchestration.TurnWriter},
      {:messages, HalC2.Codex.ThreadRuntime},
      {:exports, HalC2.Orchestration}
    ],
    covers: %{
      "HalC2.Orchestration.dispatch/1" =>
        ~w(dispatch begin-turn retry start-failed delete stop-runtimes interrupt-any
           interrupt-undriven),
      # dispatch/1's message path, split around a caller's own transaction (delegation).
      "HalC2.Orchestration.decide_dispatch/3" => "dispatch",
      "HalC2.Orchestration.dispatched/3" => ~w(begin-turn retry start-failed interrupt-any),
      "HalC2.Orchestration.start_next/1" =>
        ~w(start-next decideNext begin-turn retry start-failed),
      "HalC2.Orchestration.release_session/1" => ~w(release-session release-idle keep-turn),
      "HalC2.Orchestration.runtime/1" => "begin-turn",
      "HalC2.Orchestration.TurnWriter.started/1" => "started",
      "HalC2.Orchestration.TurnWriter.commit_active/3" => "started",
      "HalC2.Orchestration.TurnWriter.finish/3" => "finish",
      "HalC2.Orchestration.TurnWriter.abandon/4" => "abandon",
      "HalC2.Codex.ThreadRuntime handle_call {:start_turn, _}" => ~w(take started refused),
      "HalC2.Codex.ThreadRuntime handle_call :interrupt" => ~w(interrupted no-turn),
      "HalC2.Codex.ThreadRuntime handle_call :release" => ~w(release-idle keep-turn),
      "HalC2.Codex.ThreadRuntime handle_info {:json_rpc, _, {:notification, _, _}}" => "finish",
      "HalC2.Codex.ThreadRuntime handle_info {:EXIT, _, _}" => "exit",
      "HalC2.Orchestration.TurnWatch.claim/2" => "started",
      "HalC2.Orchestration.TurnWatch.release/1" => "release",
      "HalC2.Orchestration.TurnWatch.driven?/1" => ~w(end-abandoned interrupt-undriven),
      "HalC2.Orchestration.TurnWatch handle_call {:claim, _, _, _}" => "started",
      "HalC2.Orchestration.TurnWatch handle_cast {:release, _}" => "release",
      "HalC2.Orchestration.TurnWatch handle_call {:driven?, _}" => "claimed?",
      "HalC2.Orchestration.TurnWatch handle_info {:DOWN, _, :process, _, _}" => ~w(gone abandon),
      "HalC2.Orchestration.IdleSessions.check/0" => ~w(end-abandoned release-session),
      "HalC2.Orchestration.IdleSessions handle_call :check" => ~w(end-abandoned release-session),
      "HalC2.Orchestration.IdleSessions handle_info :check" => ~w(end-abandoned release-session),
      "HalC2.Orchestration.Recovery.run/0" => ~w(restart settle hold),
      "HalC2.Orchestration.Recovery.settle/1" => ~w(settle hold),
      "HalC2.Orchestration.Recovery.continue/0" => "settle"
    },
    abstracts: %{
      "HalC2.Orchestration.handle/2" =>
        "serves reads and other RPCs; messages arrive by dispatch/1",
      "HalC2.Orchestration.launch_thread/2" =>
        "creates a thread, then sends its message as dispatch/1 does",
      "HalC2.Orchestration.release_prepared/2" => @preparing,
      "HalC2.Orchestration.progress_prepared/3" => @preparing,
      "HalC2.Orchestration.fail_prepared/4" => @preparing,
      "HalC2.Orchestration.upsert/4" => @changes,
      "HalC2.Orchestration.create/3" => @changes,
      "HalC2.Orchestration.next_ordinal/1" => @changes,
      "HalC2.Orchestration.driver_for/1" => "names an instance's driver",
      "HalC2.Orchestration.TurnWriter.commit/2" => @items,
      "HalC2.Orchestration.TurnWriter.buffer/4" => @items,
      "HalC2.Orchestration.TurnWriter.flush/2" => @items,
      "HalC2.Orchestration.TurnWriter.split_ready/1" => @items,
      "HalC2.Orchestration.TurnWriter.item_id/2" => @items,
      "HalC2.Orchestration.TurnWriter.ensure_item/4" => @items,
      "HalC2.Orchestration.TurnWriter.finish_item/4" => @items,
      "HalC2.Orchestration.TurnWriter.finish_plan/3" => @items,
      "HalC2.Orchestration.TurnWriter.write_todo/4" => @items,
      "HalC2.Orchestration.TurnWriter.open_request/4" => @items,
      "HalC2.Orchestration.TurnWriter.open_question/3" => @items,
      "HalC2.Orchestration.TurnWriter.open_async_question/3" => @items,
      "HalC2.Orchestration.TurnWriter.resolve_request/4" => @items,
      "HalC2.Orchestration.TurnWriter.close_open_items/2" => @items,
      "HalC2.Orchestration.TurnWriter.message_request?/1" => @items,
      "HalC2.Orchestration.TurnWriter.start_failure/2" => "the message a failed start ends with",
      "HalC2.Codex.ThreadRuntime handle_call {:steer, _, _}" => @steer,
      "HalC2.Codex.ThreadRuntime handle_call {:respond, _, _}" => @items,
      "HalC2.Codex.ThreadRuntime handle_call {:rollback, _}" =>
        "rolls back the checkout between turns; no run changes",
      "HalC2.Codex.ThreadRuntime handle_call {:upload_feedback, _}" =>
        "sends feedback; no run changes",
      "HalC2.Codex.ThreadRuntime handle_call :settle" => "a barrier for tests; changes nothing",
      "HalC2.Codex.ThreadRuntime handle_info {:json_rpc, _, {:request, _, _, _}}" => @items,
      "HalC2.Codex.ThreadRuntime handle_info {:json_rpc, _, {:request, _, \"item/tool/requestUserInput\", _}}" =>
        @items,
      "HalC2.Codex.ThreadRuntime handle_info {:json_rpc, _, {:request, _, \"mcpServer/elicitation/request\", _}}" =>
        @items,
      "HalC2.Codex.ThreadRuntime handle_info :flush" => @items,
      "HalC2.Codex.ThreadRuntime handle_info _" => "ignores what it does not know",
      "HalC2.Orchestration.TurnWatch.start_link/1" =>
        "starts the process TurnWatch's rules run in",
      "HalC2.Orchestration.IdleSessions.start_link/1" => "starts the timer the idle rules run on",
      "HalC2.Orchestration.Recovery.start_link/0" => "runs run/0 at boot, as restart does",
      "HalC2.Orchestration.Recovery.auto_turns?/0" =>
        "on in the MC modelled here; a scratch MC with it off leaves next's requeued run queued",
      "HalC2.Orchestration.Recovery.stopping?/0" =>
        "a runtime stopping with the MC leaves its turn to Recovery, as restart's wipe does"
    },
    environment: %{
      "crash" => "the runtime's process crashes",
      "raise" => "begin_turn/2 raises before it calls the runtime",
      "time-out" => "start_turn/2's call to the runtime times out",
      "refused" => "the provider refuses to start the turn",
      "exit" => "the app-server exits under a turn",
      "restart" => "the MC stops and starts again"
    },
    scenarios: %{
      "mc/orchestration/runs.feature" => [
        "A provider that dies while starting the turn fails the run",
        "A provider session that cannot be opened fails the run",
        "A turn that ends after its thread was deleted stays cancelled",
        "A turn that starts after its thread was deleted stays cancelled",
        "A turn that starts after its start gave up stays failed",
        "The next queued message starts when a run ends",
        "Interrupting the running turn",
        "Interrupting when nothing is running is refused",
        "Stopping the provider session of an idle thread",
        "Stopping the provider session while a turn runs is refused"
      ],
      "mc/orchestration/recovery-and-idle-sessions.feature" => [
        "A turn whose runtime crashes ends as failed",
        "Stopping a turn whose runtime is gone ends it",
        "A session that is still in use is never released",
        "A message sent as its idle session is released still runs",
        "A turn cut off by a restart is interrupted at boot"
      ],
      "mc/orchestration/queue-and-steering.feature" => [
        "A held queue does not start when a run ends"
      ]
    }

  # Rules the environment may or may not take; the code's own may not stop.
  @faults ~w(crash raise time-out refused exit restart)
  @fair ~w(dispatch begin-turn start-failed start-next take started finish interrupted
           no-turn interrupt-any interrupt-undriven delete stop-runtimes abandon
           end-abandoned release-session release-idle keep-turn retry)

  # turns(faults, interrupt, delete, idle timer)
  @inits [
    "turns(2, false, false, ready)",
    "turns(2, true, false, ready)",
    "turns(2, false, true, ready)",
    "turns(3, true, true, ready)"
  ]

  for init <- @inits do
    test "a thread never runs two turns at once, from #{init}", %{proof: proof} do
      refute_reachable(proof, unquote(init), "twice", [])
    end

    test "a run that ended stays as it ended, from #{init}", %{proof: proof} do
      refute_reachable(proof, unquote(init), "flipped", [])
    end

    test "a thread's turns never get stuck, from #{init}", %{proof: proof} do
      refute_deadlock(proof, unquote(init), "settled", besides: @faults)
    end
  end

  # IdleSessions releases a runtime between its check for an active run and a message
  # that starts one there: the runtime keeps a turn it took, and a start it stopped
  # under is tried again.
  test "no run fails unless something faults", %{proof: proof} do
    refute_reachable(proof, "turns(0, true, true, ready)", "failed?", [])
    refute_reachable(proof, "turns(0, true, false, ready)", "failed?", [])
  end

  for init <- [
        "turns(2, false, false, ready)",
        "turns(2, true, false, ready)",
        "turns(2, false, true, ready)",
        "turns(1, true, true, ready)"
      ] do
    test "every run ends, and a queued message starts once none is active, from #{init}",
         %{proof: proof} do
      formula =
        "[] (active(r1) -> <> ~ active(r1)) /\\ [] (active(r2) -> <> ~ active(r2)) /\\ " <>
          "[] (active(q) -> <> ~ active(q)) /\\ [] (waiting(q) -> <> ~ waiting(q)) /\\ " <>
          "[] (waiting(r2) -> <> ~ waiting(r2))"

      assert_ltl(proof, unquote(init), formula, fair: @fair)
    end
  end
end
