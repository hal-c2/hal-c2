defmodule HalC2.Orchestration.HandoffTest do
  use ExUnit.Case, async: true

  alias HalC2.Orchestration.Handoff

  @header "Imported conversation history from the previous HAL-C2 orchestrator. Use it as context; do not repeat it unless the user asks."

  defp user(text), do: %{"type" => "user_message", "text" => text}
  defp assistant(text), do: %{"type" => "assistant_message", "text" => text}

  test "a short imported conversation is kept whole, oldest first" do
    items = [user("hi"), %{"type" => "command_execution", "input" => "ls"}, assistant("hello")]
    assert Handoff.legacy_summary(items) == "#{@header}\n\nUser:\nhi\n\nAssistant:\nhello"
  end

  test "the newest messages win, and the first that does not fit keeps its end cut at a word" do
    words = fn prefix -> Enum.map_join(1..4_000, " ", &"#{prefix}#{&1}") end
    oldest = user("oldest message")
    older = user(words.("w"))
    newest = assistant(String.duplicate("n", 20_000))

    summary = Handoff.legacy_summary([oldest, older, newest])
    assert String.length(summary) <= 32_000
    refute summary =~ "oldest message"

    [@header, "User:\n... " <> kept, "Assistant:\n" <> reply] = String.split(summary, "\n\n")
    assert reply == String.duplicate("n", 20_000)
    # The kept end of the older message starts at a whole word and runs to its end.
    assert [first | _] = String.split(kept, " ")
    assert first =~ ~r/^w\d+$/
    assert String.ends_with?(older["text"], " " <> kept)
  end

  test "a message with no word break inside the budget is cut where the budget ends" do
    body = String.duplicate("x", 40_000)
    summary = Handoff.legacy_summary([user(body)])
    assert String.length(summary) == 32_000
    assert [@header, "User:\n... " <> kept] = String.split(summary, "\n\n")
    assert kept == String.duplicate("x", String.length(kept))
  end
end
