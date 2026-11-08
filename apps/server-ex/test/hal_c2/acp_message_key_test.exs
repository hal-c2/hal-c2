defmodule HalC2.Acp.MessageKeyTest do
  # Review of hal-c2/hal-c2#1321: v19 put a segment in a turn's message keys, so a turn
  # running across the upgrade wrote its later text under a new key and split its
  # message mid-sentence.
  use ExUnit.Case, async: true

  alias HalC2.Acp.ThreadRuntime

  test "a turn in progress across the upgrade to v19 keeps its message's key" do
    turn = %{ids: %{run: "run-1"}}
    before = %{v: 18, turn: turn}

    {:ok, upgraded} = ThreadRuntime.code_change(nil, before, nil)

    assert upgraded.v == 19
    assert ThreadRuntime.message_key(upgraded.turn, :assistant, "m1") == "assistant:run-1:m1"
    assert ThreadRuntime.message_key(upgraded.turn, :assistant, nil) == "assistant:run-1:current"
  end

  test "a turn begun on v19 keys its messages by segment" do
    turn = %{ids: %{run: "run-1"}, segment: 0}

    assert ThreadRuntime.message_key(turn, :assistant, "m1") == "assistant:run-1:0:m1"

    assert ThreadRuntime.message_key(%{turn | segment: 2}, :reasoning, nil) ==
             "reasoning:run-1:2:current"
  end
end
