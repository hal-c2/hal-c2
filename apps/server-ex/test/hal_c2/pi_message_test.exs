defmodule HalC2.PiMessageTest do
  use ExUnit.Case, async: true

  @history "<conversation_history>\nUser: please $review it\n\nAssistant: done\n</conversation_history>"

  test "without history the user's skills lead, as Pi expands them" do
    assert HalC2.Pi.message("please $review this", nil, ["review"]) == "/skill:review please this"
  end

  # #1342: read in the whole text, the history's `$review` ran again and the history
  # lost its lines.
  test "history goes whole ahead of words that name no skill" do
    assert HalC2.Pi.message(@history <> "\n\nWhere were we?", @history, ["review"]) ==
             @history <> "\n\nWhere were we?"
  end

  test "a skill the user names leads, with the history as its words ahead of theirs" do
    assert HalC2.Pi.message(@history <> "\n\nnow $deploy it", @history, ["deploy", "review"]) ==
             "/skill:deploy " <> @history <> "\n\nnow it"

    assert HalC2.Pi.message(@history <> "\n\n/skill:deploy", @history, []) ==
             "/skill:deploy " <> @history
  end
end
