defmodule HalC2.ModelSelectionProofTest do
  # What a thread runs on, changed by two clients with stale views and by a writer that
  # sends no base (an agent's hal_c2_thread_configure, or an old client), while a turn
  # runs and messages queue behind it; every update and reply may be lost, reordered or
  # cut off by a reconnect. A pick is a model; modes are sent at once with no base.
  @creating "decides what a new thread runs on before any client shows it; the model starts from a thread that names its selection"

  use HalC2.Proof,
    model: "model_selection.maude",
    module: "MODEL-SELECTION",
    check: "MODEL-SELECTION-PROPS",
    code: [
      {:exports, HalC2.Orchestration.Selection},
      {:exports, HalC2.Orchestration.NewThread}
    ],
    covers: %{
      "HalC2.Orchestration.Selection.revision/1" => ~w(dispatchStale dispatch setThreadMode),
      # Every commit to a thread's stream: a set, a mode change, a queued pick taken at
      # its start, each moving the revision on and the queue with it.
      "HalC2.Orchestration.Selection.stamp/2" =>
        ~w(configure setThreadMode dispatch startNext),
      "HalC2.Orchestration.Selection.moved/3" => "setThreadMode",
      "HalC2.Orchestration.Selection.stale/2" => ~w(dispatchStale dispatch),
      "HalC2.Orchestration.Selection.picked/1" => ~w(dispatch dispatchStale),
      # new_run/5's take of a pick at its start, and stale/2's "what the thread has".
      "HalC2.Orchestration.Selection.same_selection?/2" => ~w(dispatchStale dispatch startNext)
    },
    abstracts: %{
      "HalC2.Orchestration.NewThread.defaults/1" => @creating,
      "HalC2.Orchestration.NewThread.defaults/2" => @creating,
      "HalC2.Orchestration.NewThread.complete/1" => @creating
    },
    environment: %{
      "pick" => "a user picks another model in the composer",
      "sendPicked" => "a user sends with a pick",
      "sendNoPick" => "a user sends without one",
      "setMode" => "a user changes the mode, which the client sends at once",
      "deliver" => "a stream update reaches a client",
      "reply" => "a client hears the reply to its mode set",
      "replyPick" => "a client with a pick hears the revision its mode set made",
      "replyNone" => "a client with a pick hears that its mode set changed nothing",
      "replyLate" => "a reply for an RPC its client gave up with its socket",
      "refused" => "a client hears a refusal naming the thread's selection",
      "dropPick" => "a client drops a pick once the thread has moved past its base",
      "loseUpdate" => "a stream update is lost with its connection",
      "loseReply" => "a reply is lost with its connection",
      "reconnect" => "a client resubscribes and has the thread as it is",
      "sessionStarts" => "the provider session starts the turn on what the MC asked",
      "turnEnd" => "the provider ends the turn"
    },
    scenarios: %{
      "composer/model-and-mode.feature" => [
        "A send picked against a selection that has since changed is refused",
        "A send that picks nothing keeps a model chosen elsewhere",
        "A queued message's pick gives way to a later change",
        "A message that names another model on the same account changes the thread's model",
        "A change to what a thread runs on answers with the revision it made"
      ]
    }

  @fair ~w(dispatch dispatchStale setThreadMode configure deliver reply replyPick replyNone
           replyLate refused dropPick reconnect sessionStarts turnEnd startNext)

  # start(c1 picks, sends, mode changes, c2 picks, sends, mode changes, writer's sets, cfg)
  @inits [
    "start(1, 1, 0, 1, 1, 0, 1, fix)",
    "start(1, 1, 1, 0, 1, 0, 1, fix)",
    "start(1, 1, 1, 1, 1, 1, 0, fix)"
  ]

  for init <- @inits do
    test "no choice is replaced by one made without seeing it, from #{init}", %{proof: proof} do
      refute_reachable(proof, unquote(init), "lostUpdate", [])
    end

    test "every turn runs on what its client showed, its entity shows and its thread names, from #{init}",
         %{proof: proof} do
      refute_reachable(proof, unquote(init), "wrongRun", [])
    end

    test "a running turn runs on its session's model, from #{init}", %{proof: proof} do
      refute_reachable(proof, unquote(init), "sessionDiffers", [])
    end

    test "nothing is left showing a selection the thread does not have, from #{init}",
         %{proof: proof} do
      refute_reachable(proof, unquote(init), "unsettled", [])
      refute_deadlock(proof, unquote(init), "done", besides: ~w(loseUpdate loseReply))
    end
  end

  for init <- ["start(1, 1, 0, 1, 1, 0, 1, fix)", "start(1, 1, 1, 0, 0, 0, 1, fix)"] do
    test "every client comes to show what the thread runs on, from #{init}", %{proof: proof} do
      assert_ltl(proof, unquote(init), "<> [] agreed", fair: @fair)
    end
  end

  # Each part of the fix is what keeps its bad state out.

  test "without the base check, a stale pick replaces a newer choice", %{proof: proof} do
    assert_reachable(proof, "start(1, 1, 0, 0, 0, 0, 1, noBaseCheck)", "lostUpdate")
  end

  test "a send that carries what it shows replaces a newer choice", %{proof: proof} do
    assert_reachable(proof, "start(0, 1, 0, 0, 0, 0, 1, pickless)", "lostUpdate")
  end

  test "a client that drops its pick only once the thread equals it keeps a stale one",
       %{proof: proof} do
    assert_reachable(proof, "start(1, 0, 0, 0, 0, 0, 1, equalityDrop)", "unsettled")
  end

  test "a queued pick that does not give way replaces a later choice", %{proof: proof} do
    assert_reachable(proof, "start(1, 1, 0, 0, 0, 0, 1, picksStay)", "lostUpdate")
  end

  # A client's own mode set, interleaved with the writer: a reply that names the
  # revision whether or not the set moved it lets the writer's change through unseen.
  test "a reply naming a revision its set did not make lets another writer's change through",
       %{proof: proof} do
    assert_reachable(proof, "start(1, 1, 1, 0, 0, 0, 1, replyAlways)", "lostUpdate")
  end

  test "a message's same-account model that never becomes the thread's runs unseen",
       %{proof: proof} do
    assert_reachable(proof, "start(1, 1, 0, 0, 0, 0, 0, noSameAccount)", "wrongRun")
    assert_reachable(proof, "start(1, 1, 0, 0, 0, 0, 0, noSameAccount)", "unsettled")

    assert_raise ExUnit.AssertionError, fn ->
      assert_ltl(proof, "start(1, 1, 0, 0, 0, 0, 0, noSameAccount)", "<> [] agreed", fair: @fair)
    end
  end

  test "a client that sends a selection it did not show runs on it", %{proof: proof} do
    assert_reachable(proof, "start(0, 0, 0, 0, 1, 0, 0, inventing)", "wrongRun")
  end
end
