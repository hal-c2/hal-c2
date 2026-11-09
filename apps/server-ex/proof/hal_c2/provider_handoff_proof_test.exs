defmodule HalC2.ProviderHandoffProofTest do
  # One thread whose runs alternate between two providers, each with its own native
  # conversation, through every interleaving of prompts, confirmations, usage reports,
  # failed runs and crashed runtimes, with one prompt or confirmation lost on the way.
  # prop/hal_c2/provider_handoff_prop_test.exs runs the code itself.
  #
  # Each part of the design is a switch in the model, and turning one off finds the
  # flaw it closes (the searches take about a second each):
  #
  #   - Without the unconfirmed mark, a prompt that is lost after the MC moved its
  #     provider's place forward leaves that provider's conversation missing a run the
  #     next resume will not send again (#1233).
  #   - With a confirmation that clears whatever mark is set, a late confirmation of an
  #     older run clears the mark of a newer run whose prompt was lost, with the same
  #     result. Confirmations are keyed to their run.
  #   - Without the room check, a handoff resumed into a nearly full conversation
  #     overfills it (#1232).
  #   - With a runtime that keeps its conversation when the MC asks for a new one, the
  #     new conversation's whole thread lands on top of the old one and overfills it.
  #   - Counting only the newest usage report, not what each later turn sent with its
  #     reserve, under-counts a conversation whose report has not come yet, and a resume
  #     overfills it.
  #   - A wake planned like a run moves its provider's place past what it was handed,
  #     but sends nothing, so the next run resumes without what the provider missed.
  #     A wake, like `/compact`, is quiet: it leaves the place and the mark alone.
  #   - Replacing a conversation whose handoff went unconfirmed, or that has no room,
  #     cuts off the background work running in it. With it running, the handoff goes
  #     into the conversation again, or the run is refused (#1232 :182).
  #   - Sending again only what came after the run that set the mark, not after the run
  #     through which the conversation was known to hold the thread, leaves out what
  #     that run carried.
  #   - A run that ended before its turn began sent nothing, so its mark is taken back
  #     with the provider's place, and what it would have sent takes no room: the next
  #     run goes on in the same conversation. Dropping the mark without moving the place
  #     back would lose what the run was to carry.
  @provider "the provider's side; the MC sees it only through prompts, confirmations and reports"
  @handoff "what a prompt carries; the model counts it by size, not by text"
  @history "what of the thread fits a size; pure, its laws in handoff_history.maude and prop/hal_c2/handoff_history_prop_test.exs"
  @observe "what plugins hear of a turn (HalC2.Plugins.observe/1): reads a turn and its items; changes nothing"
  @items "writes a turn's items, streamed text and requests; for a provider that never says it started the turn, the first one confirms it as confirm models"

  use HalC2.Proof,
    model: "provider_handoff.maude",
    module: "PROVIDER-HANDOFF",
    check: "PROVIDER-HANDOFF-PROPS",
    timeout: 600_000,
    code: [
      {:exports, HalC2.Orchestration.Handoff},
      {:exports, HalC2.Orchestration.TurnWriter}
    ],
    covers: %{
      "HalC2.Orchestration.Handoff.plan/6" =>
        ~w(resume restart resend busy refuse fresh? mark overfull unsent),
      "HalC2.Orchestration.Handoff.room/3" => ~w(occ reserve unsent),
      "HalC2.Orchestration.Handoff.transcript/5" => ~w(fit done),
      "HalC2.Orchestration.Handoff.fresh_start/2" => "restart",
      "HalC2.Orchestration.TurnWriter.ensure_item/5" => ~w(confirm late-ack clear background),
      "HalC2.Orchestration.TurnWriter.confirmed/2" => ~w(confirm late-ack clear),
      "HalC2.Orchestration.TurnWriter.finish/3" => ~w(complete fail),
      "HalC2.Orchestration.TurnWriter.checkpointed/4" => "complete",
      "HalC2.Orchestration.TurnWriter.abandon/4" => ~w(refuse fail)
    },
    abstracts: %{
      "HalC2.Orchestration.Handoff.prompt/2" => @handoff,
      "HalC2.Orchestration.Handoff.legacy_summary/1" => @handoff,
      "HalC2.Orchestration.Handoff.history/2" => @history,
      "HalC2.Orchestration.Handoff.select/2" => @history,
      "HalC2.Orchestration.Handoff.ahead/2" => @handoff,
      "HalC2.Orchestration.Handoff.fork_boundary/3" =>
        "a fork starts its conversation from its source's, which no run here does",
      "HalC2.Orchestration.TurnWriter.started/1" =>
        "the provider turn a run starts; resume and restart write it with the run",
      "HalC2.Orchestration.TurnWriter.commit/2" => @items,
      "HalC2.Orchestration.TurnWriter.commit_active/3" => @items,
      "HalC2.Orchestration.TurnWriter.buffer/4" => @items,
      "HalC2.Orchestration.TurnWriter.flush/2" => @items,
      "HalC2.Orchestration.TurnWriter.split_ready/1" => @items,
      "HalC2.Orchestration.TurnWriter.item_id/2" => @items,
      "HalC2.Orchestration.TurnWriter.finish_item/5" => @items,
      "HalC2.Orchestration.TurnWriter.end_item/5" => @items,
      "HalC2.Orchestration.TurnWriter.observe_item/3" => @observe,
      "HalC2.Orchestration.TurnWriter.observed_item/1" => @observe,
      "HalC2.Orchestration.TurnWriter.new_conversation?/1" => @observe,
      "HalC2.Orchestration.TurnWriter.observe_started/1" => @observe,
      "HalC2.Orchestration.TurnWriter.finish_plan/3" => @items,
      "HalC2.Orchestration.TurnWriter.write_todo/4" => @items,
      "HalC2.Orchestration.TurnWriter.open_request/6" => @items,
      "HalC2.Orchestration.TurnWriter.open_question/3" => @items,
      "HalC2.Orchestration.TurnWriter.open_async_question/3" => @items,
      "HalC2.Orchestration.TurnWriter.resolve_request/4" => @items,
      "HalC2.Orchestration.TurnWriter.close_open_items/2" => @items,
      "HalC2.Orchestration.TurnWriter.message_request?/1" => @items,
      "HalC2.Orchestration.TurnWriter.start_failure/2" => "the message a failed start ends with"
    },
    environment: %{
      "deliver" => @provider <> ": it takes a prompt into the conversation it names",
      "open" =>
        @provider <>
          ": it opens a new conversation, once Orchestration has released the runtime that held the old one",
      "reuse" => @provider <> ": a runtime that keeps its conversation; only with Fresh off",
      "answer" => @provider <> ": it answers the turn and reports how full the conversation is",
      "late-reply" => "a usage report that lands on its turn after the run ended",
      "wake" =>
        "Orchestration's quiet runs: a wake, or `/compact` or `/logout` on a conversation, plans no handoff and leaves the provider thread's place and mark",
      "wake-none" =>
        "a wake with no conversation to wake; the model sends nothing, where Orchestration hands a command the thread",
      "wake-in" =>
        @provider <> ": it takes a wake into its conversation, which adds nothing to it",
      "settle" => @provider <> ": background work it started ends",
      "drop" => "a prompt lost on the way to the provider",
      "lose-ack" => "a confirmation lost on the way back",
      "crash" => "the provider's runtime dies with its run"
    },
    scenarios: %{
      "mc/orchestration/provider-handoff.feature" => [
        "History that may not have reached the provider is sent again on a new conversation",
        "A handoff that does not fit the resumed conversation starts a fresh one",
        "A handoff that does not fit waits for background work instead of cutting it off",
        "A handoff waits when the first message after a switch asks to compact",
        "A message that cannot fit even a fresh conversation fails the run",
        "Switching back to the first provider resumes its own conversation",
        "The delta strategy hands over only what the target provider has not seen"
      ],
      "providers/claude.feature" => [
        "A turn that failed before its prompt was sent keeps the Claude session",
        "A Claude turn that ended while Claude started still owes what it did not send"
      ]
    }

  @faults ~w(drop lose-ack crash unsent)
  @script "todo(1, 1) todo(2, 2) todo(3, 1) todo(4, 2)"
  # Mark, Room, Fresh, Keyed, Quiet, Busy, Since.
  @design "true, true, true, true, true, true, true"

  test "no prompt leaves its conversation without an earlier run or overfills it with a handoff",
       %{proof: proof} do
    refute_reachable(proof, "start(#{@design}, 8, 1, 0, #{@script})", "unsafe", [])
  end

  test "a message too big for any conversation fails its run and the next one is safe",
       %{proof: proof} do
    init = "start(#{@design}, 8, 1, 0, todo(1, 1) todo(2, 9) todo(3, 1))"
    refute_reachable(proof, init, "unsafe", [])
  end

  test "a wake loses no run the provider missed", %{proof: proof} do
    init = "start(#{@design}, 8, 1, 0, todo(1, 1) todo(2, 2) poke(3, a) todo(4, 1))"
    refute_reachable(proof, init, "unsafe", [])
  end

  # With background work every step can interleave with its start and end, so these
  # searches send runs 1 to 3 to providers a, b and a, the shape in which a handoff goes
  # back into a conversation that may hold background work; run 4 goes to either.
  @background "todo(1, 1) on(1, a) todo(2, 1) on(2, b) todo(3, 1) on(3, a) todo(4, 1)"

  test "background work is never cut off, and what an unconfirmed handoff carried goes again",
       %{proof: proof} do
    init = "start(#{@design}, 8, 1, 1, #{@background})"
    refute_reachable(proof, init, "unsafe", [])
  end

  test "runs never get stuck, with one fault", %{proof: proof} do
    init =
      "start(#{@design}, 8, 1, 1, todo(1, 1) on(1, a) todo(2, 2) on(2, b) poke(3, a) todo(4, 1))"

    refute_deadlock(proof, init, "settled", besides: @faults ++ ~w(background settle))
  end

  test "every run ends when nothing is lost", %{proof: proof} do
    assert_ltl(proof, "start(#{@design}, 8, 0, 0, #{@script})", "<> finished", [])
  end
end
