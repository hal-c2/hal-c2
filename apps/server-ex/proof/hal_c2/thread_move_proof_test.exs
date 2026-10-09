defmodule HalC2.ThreadMoveProofTest do
  # Moving a thread between two or three MCs, with messages in any order, crashes,
  # partitions, timeouts and movers that die. prop/hal_c2/thread_move_prop_test.exs runs
  # the code on one machine pair; this explores every interleaving up to the bounds.
  @before "a check before any move begins, which changes nothing"
  @handoff "how the agent continues once the thread is imported; no part of who holds it"
  @after_turn "waits for the thread's turn to end, then calls move/3, which begin models"

  use HalC2.Proof,
    model: "thread_move.maude",
    module: "THREAD-MOVE",
    check: "THREAD-MOVE-PROPS",
    code: [
      {:exports, HalC2.ThreadMove},
      {:messages, HalC2.ThreadMove},
      {:state, HalC2.ThreadMove},
      {:calls, HalC2.ThreadMove, :hook},
      {:exports, HalC2.Orchestration.Handoff}
    ],
    covers: %{
      "HalC2.ThreadMove.move/3" =>
        ~w(begin moved forward stop called-off broke-off mover freeing freeing?),
      "HalC2.ThreadMove.taking/2" => ~w(taking taking-gone),
      "HalC2.ThreadMove.accept/3" =>
        ~w(stage take import import-failed refused gave-up accept put sent),
      "HalC2.ThreadMove.arrived?/2" => ~w(answer locked got has moves),
      "HalC2.ThreadMove.settle/1" =>
        ~w(settle let-go forward stop letting freeing? again release),
      "HalC2.ThreadMove handle_cast {:watch, _, _, _}" => "mover-died",
      "HalC2.ThreadMove handle_cast {:done, _, _}" => "settle",
      "HalC2.ThreadMove handle_info {:settle, _}" => "settle",
      "HalC2.ThreadMove handle_info {:nodeup, _}" => ~w(settle restart heal),
      "HalC2.ThreadMove handle_info {_, _}" => "again",
      "HalC2.ThreadMove handle_info {:DOWN, _, :process, _, _}" => ~w(settle mover-died),
      "HalC2.ThreadMove state :movers" => "mover",
      "HalC2.ThreadMove state :again" => "again",
      "HalC2.ThreadMove state :task" => "asked",
      "HalC2.ThreadMove state :asked" => "asked",
      "HalC2.ThreadMove state :queue" => "settle",
      "HalC2.ThreadMove hook(:sending)" => "begin",
      "HalC2.ThreadMove hook(:accepted)" => "moved",
      "HalC2.ThreadMove hook(:staged)" => "stage",
      "HalC2.ThreadMove hook(:taking)" => "import",
      "HalC2.ThreadMove hook(:letting_go)" => "forward",
      "HalC2.ThreadMove hook(:arrived)" => "answer"
    },
    abstracts: %{
      "HalC2.ThreadMove.start_link/1" => "starts the process settle/1 runs in",
      "HalC2.ThreadMove.after_turn/3" => @after_turn,
      "HalC2.ThreadMove handle_call {:after_turn, _, _, _}" => @after_turn,
      "HalC2.ThreadMove handle_info {:hal_c2_stream, _, _}" => @after_turn,
      "HalC2.ThreadMove handle_info {:turn_check, _}" => @after_turn,
      "HalC2.ThreadMove state :after_turn" => @after_turn,
      "HalC2.ThreadMove handle_info _" => "ignores what it does not know",
      "HalC2.ThreadMove.destinations/1" => @before,
      "HalC2.ThreadMove.fit/1" => @before,
      "HalC2.ThreadMove.have/1" => @before,
      "HalC2.ThreadMove.projects/1" => @before,
      "HalC2.ThreadMove.agent/1" => @before,
      "HalC2.ThreadMove.provider_name/1" => "a name for messages",
      "HalC2.ThreadMove.locate/1" => "reads where the thread lives; changes nothing",
      "HalC2.ThreadMove.read/3" =>
        "serves the files the destination stages; a call that breaks off ends the staging, as stage and sever model",
      "HalC2.Orchestration.Handoff.plan/6" => @handoff,
      "HalC2.Orchestration.Handoff.prompt/2" => @handoff,
      "HalC2.Orchestration.Handoff.transcript/3" => @handoff,
      "HalC2.Orchestration.Handoff.legacy_summary/1" => @handoff
    },
    environment: %{
      "crash" => "an MC stops: its processes die, its store stays, its links break",
      "restart" => "the MC starts again",
      "partition" => "two MCs stop reaching each other",
      "heal" => "they reach each other again",
      "time-out" => "an :erpc call gives up",
      "drop" => "an answer to a call that gave up is thrown away"
    },
    scenarios: %{
      "threads/moving-between-machines.feature" => [
        "The user moves a thread to another machine",
        "A moved thread can be moved back",
        "A move that breaks off part way leaves the thread on the source",
        "A destination that was cut off while copying does not take the thread afterwards",
        "A move cut off while the destination takes the thread waits for the destination",
        "The source restarting while the destination takes the thread does not undo the move",
        "The source going offline after the destination confirmed does not undo the move",
        "A thread cannot be moved twice at once"
      ]
    }

  # Rules the environment may or may not take; the code's own may not stop.
  @faults ~w(crash partition time-out mover-died)
  @fair ~w(begin moved forward called-off broke-off taking taking-gone stage
           take import import-failed refused gave-up answer settle let-go again release
           restart heal drop)

  # Each searches every state for all of twice, lost, hurts and wrong at once.
  for init <- ["two(2, 2)", "three(2, 2)"] do
    test "a thread is never writable on two MCs or lost, a stale let-go never stops its session, and its source hears truly whether its move arrived, from #{init}",
         %{proof: proof} do
      refute_reachable(proof, unquote(init), "broken", [])
    end
  end

  for init <- ["two(2, 2)", "three(2, 1)"] do
    test "a move never gets stuck, from #{init}", %{proof: proof} do
      refute_deadlock(proof, unquote(init), "settled", besides: @faults)
    end
  end

  # The thread keeps only the last move from each MC. Keeping only the last of all fails
  # here: a moves it to b, b on to c and c back to b while a still asks after its move.
  test "the last move from each MC is enough to say whether a move arrived", %{proof: proof} do
    refute_reachable(proof, "three(3, 0)", "broken", [])
  end

  test "a move that begins ends, with up to one fault", %{proof: proof} do
    formula = "[] (moving(1) -> <> ~ moving(1)) /\\ [] (moving(2) -> <> ~ moving(2))"
    assert_ltl(proof, "two(2, 1)", formula, fair: @fair)
  end
end
