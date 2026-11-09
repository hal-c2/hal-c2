defmodule HalC2.HandoffHistoryProofTest do
  # What of a thread's history a provider is handed, over every thread of up to four
  # runs, at every budget from none to past the whole history. It is no protocol, so
  # this is not what proofs are usually for; it is here because a law of select/2 can
  # break in a window a few characters wide, which random budgets rarely land in, and
  # the model tries them all. prop/hal_c2/handoff_history_prop_test.exs runs the code
  # itself on large threads.
  #
  # The model counts in units, not characters: a run's request takes 2 whole, what
  # cutting other agents' words or the user's to their floors saves is a unit or two,
  # condensing or showing a run in full a few more, and the note ahead of a history
  # that is not whole is 2. The newest run's steps are rungs, each what showing that
  # many of its newest steps adds; tail/3 searching them in order is the model picking
  # the biggest that fits, which the property's sweep checks the code does. A cut of
  # what was said fills what is left of the budget, as largest/3 does to within a
  # character. A message said again in a later run is not modelled; the property
  # checks it names a run that is shown.
  #
  # Each part of the design is a switch in the model, and each test below turns one off
  # to find the flaw it closes:
  #
  #   - Without room held back for the newest run's last step, squeezing what was said
  #     takes all of it, and the step the next agent picks up from is not shown.
  #   - Holding that room even as the budget nears what the first and newest runs take
  #     at their floors cuts everything below the floors where they would have fit.
  #   - Leaving runs out oldest first, whatever they hold, drops a run with the user's
  #     words while one with none of them stays.
  #   - Sending what was said whole as soon as it fits, with no room for the newest's
  #     last step, hides that step at a budget where a smaller one, squeezing what was
  #     said, showed it.
  @provider_handoff "when a handoff is sent and what it may take; provider_handoff.maude's"

  use HalC2.Proof,
    model: "handoff_history.maude",
    module: "HANDOFF-HISTORY",
    check: "HANDOFF-HISTORY-PROPS",
    timeout: 600_000,
    code: [{:exports, HalC2.Orchestration.Handoff}],
    covers: %{
      "HalC2.Orchestration.Handoff.history/2" => ~w(history length),
      "HalC2.Orchestration.Handoff.select/2" =>
        ~w(select upgrade share raise steps squeezed held floor squeeze order fewest stage)
    },
    abstracts: %{
      "HalC2.Orchestration.Handoff.plan/6" => @provider_handoff,
      "HalC2.Orchestration.Handoff.room/3" => @provider_handoff,
      "HalC2.Orchestration.Handoff.fresh_start/2" => @provider_handoff,
      "HalC2.Orchestration.Handoff.transcript/5" =>
        "gathers a thread's runs for history/2 and wraps what it gives",
      "HalC2.Orchestration.Handoff.prompt/2" =>
        "puts what history/2 gives ahead of the user's text",
      "HalC2.Orchestration.Handoff.legacy_summary/1" =>
        "a version 1 thread's history, kept from its newest message back; no runs",
      "HalC2.Orchestration.Handoff.ahead/2" =>
        "puts what history/2 gives ahead of a turn's text, kept apart for a runtime that sends it on its own",
      "HalC2.Orchestration.Handoff.fork_boundary/3" =>
        "where a native fork cuts its conversation; no history is chosen"
    },
    environment: %{
      "run" => "the thread: each run a shape of what it holds",
      "newest" => "the thread's newest run, and the steps it took"
    },
    scenarios: %{
      "mc/orchestration/provider-handoff.feature" => [
        "A long transcript condenses an older run that does not fit"
      ]
    }

  # Hold, Shrink, Order, Step.
  @design "true, true, true, true"

  # Threads of up to four runs whose requests vary in what cutting saves, the newest
  # with up to three steps; and of up to three runs, each sized every way.
  test "every history fits, gives way in order and keeps more in a bigger budget",
       %{proof: proof} do
    refute_reachable(proof, "gen(cfg(#{@design}), narrow, 4, nil)", "lawless", [])
    refute_reachable(proof, "gen(cfg(#{@design}), wide, 3, nil)", "lawless", [])
  end

  test "without room held for the newest's last step, squeezing hides it", %{proof: proof} do
    assert_reachable(proof, "gen(cfg(false, true, true, true), narrow, 3, nil)", "disordered")
  end

  test "room held to the end cuts everything where the first and newest fit at their floors",
       %{proof: proof} do
    assert_reachable(proof, "gen(cfg(true, false, true, true), narrow, 3, nil)", "disordered")
  end

  test "runs left out oldest first drop the user's words before another agent's",
       %{proof: proof} do
    assert_reachable(proof, "gen(cfg(true, true, false, true), narrow, 4, nil)", "disordered")
  end

  test "what was said sent whole without room for the newest's last step hides it at a bigger budget",
       %{proof: proof} do
    assert_reachable(proof, "gen(cfg(true, true, true, false), wide, 2, nil)", "shrinks")
  end
end
