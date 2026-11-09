defmodule HalC2.HandoffAheadPropTest do
  @moduledoc """
  The laws `HalC2.Orchestration.Handoff.ahead/2`, `HalC2.Pi.message/3` and
  `HalC2.Codex.Goals.first_turn/2` promise (#1342). A turn can be put behind history
  more than once (a fork's fallback, then a fresh start): its text is always what it carries ahead, then the user's words,
  and `history` is exactly what it carries ahead. Pi gets that history whole, and
  only the user's words are read for `$skill` mentions, so a skill the history names
  never runs again and the history keeps its lines. A Codex `/goal` that opens with
  its own prompt keeps that history ahead of it.

  A plain `forall`: both are pure.
  """

  use ExUnit.Case, async: true
  use PropCheck

  alias HalC2.Orchestration.Handoff

  @skills ["review", "deploy"]

  property "a turn's text is its history, then the user's words, however often it is put behind",
    numtests: HalC2.Prop.numtests(300) do
    forall {said, contexts} <- {words(), list(oneof([nil, history()]))} do
      turn = Enum.reduce(contexts, %{text: said}, &Handoff.ahead(&2, &1))
      # Each context goes ahead of all that came before it, joined as `prompt/2` joins.
      carried =
        contexts
        |> Enum.reject(&is_nil/1)
        |> Enum.reduce(nil, &if(&2, do: Handoff.prompt(&1, &2), else: &1))

      if carried,
        do: turn == %{text: Handoff.prompt(carried, said), history: carried},
        else: turn == %{text: said}
    end
  end

  property "a Codex goal's first turn keeps the history ahead of the goal's prompt",
    numtests: HalC2.Prop.numtests(300) do
    forall {said, objective, contexts, sent?} <-
             {words(), words(), list(oneof([nil, history()])), boolean()} do
      # The runtime's turn names the message the user sent; a turn may also come without.
      start = if sent?, do: %{text: said, message: said}, else: %{text: said}
      turn = Enum.reduce(contexts, start, &Handoff.ahead(&2, &1))
      opened = HalC2.Codex.Goals.first_turn(turn, objective)
      goal = HalC2.Codex.Goals.first_prompt(objective)

      # Only the user's words give way; what the turn carries stays, and stays ahead.
      Map.delete(opened, :text) == Map.delete(turn, :text) and
        if(turn[:history],
          do: opened.text == turn.history <> "\n\n" <> goal,
          else: opened.text == goal
        )
    end
  end

  property "Pi gets the history whole and expands only the skills the user names",
    numtests: HalC2.Prop.numtests(300) do
    forall {said, history} <- {words(), history()} do
      turn = Handoff.ahead(%{text: said}, history)
      sent = HalC2.Pi.message(turn.text, turn.history, @skills)
      own = HalC2.Pi.expand_skills(said, @skills)

      String.contains?(sent, history) and
        squeeze(String.replace(sent, history, " ", global: false)) == squeeze(own) and
        Enum.all?(
          @skills,
          &(String.contains?(sent, "/skill:" <> &1) == String.contains?(own, "/skill:" <> &1))
        )
    end
  end

  defp squeeze(text), do: text |> String.split(~r/\s+/, trim: true) |> Enum.join(" ")

  defp word, do: oneof(["fix", "it", "now", "$review", "$deploy", "$other", "/goal"])

  defp words do
    let ws <- non_empty(list(word())), do: Enum.join(ws, " ")
  end

  defp history do
    let lines <- non_empty(list(words())) do
      "<conversation_history>\nUser: " <> Enum.join(lines, "\n\n") <> "\n</conversation_history>"
    end
  end
end
