defmodule HalC2.ClaudeBudgetTest do
  use ExUnit.Case, async: true

  alias HalC2.Claude.Budget

  # Each key's latest count, as `HalC2.OpenShell.Review` adds them up.
  defp told(steps, resumed \\ false) do
    Enum.reduce(steps, {Budget.new(resumed), %{}}, fn step, {budget, told} ->
      {budget, counts} = step.(budget)
      {budget, Enum.reduce(counts, told, fn {key, n}, told -> Map.put(told, key, n) end)}
    end)
    |> elem(1)
    |> Map.values()
    |> Enum.sum()
  end

  # A background subagent's progress can come after its turn's result, which already
  # counted all of what the message spent.
  test "a subagent's progress after a result does not count its message twice" do
    sub = %{
      "type" => "assistant",
      "parent_tool_use_id" => "toolu-a",
      "message" => %{"id" => "msg-1", "usage" => %{"input_tokens" => 10}}
    }

    result = %{"type" => "result", "modelUsage" => %{"claude" => %{"inputTokens" => 100}}}

    progress = %{
      "type" => "system",
      "subtype" => "task_progress",
      "tool_use_id" => "toolu-a",
      "usage" => %{"total_tokens" => 100}
    }

    assert told([&Budget.observe(&1, sub), &Budget.observe(&1, result)]) == 100

    assert told([
             &Budget.observe(&1, sub),
             &Budget.observe(&1, result),
             &Budget.observe(&1, progress)
           ]) == 100
  end

  # A resumed session's first result counts what it restored and what this process's
  # counts already reported; a message counted before it and again after is in it.
  test "a resumed session's message counted again after its first result is not taken back" do
    sub = %{
      "type" => "assistant",
      "parent_tool_use_id" => "toolu-a",
      "message" => %{"id" => "msg-1", "usage" => %{"output_tokens" => 1}}
    }

    result = &%{"type" => "result", "modelUsage" => %{"claude" => %{"inputTokens" => &1}}}

    progress = %{
      "type" => "system",
      "subtype" => "task_progress",
      "tool_use_id" => "toolu-a",
      "usage" => %{"total_tokens" => 1}
    }

    steps = [
      &Budget.observe(&1, sub),
      &Budget.observe(&1, result.(1)),
      &Budget.observe(&1, result.(2))
    ]

    assert told(steps, true) == 2

    assert told(steps ++ [&Budget.observe(&1, progress), &Budget.observe(&1, result.(2))], true) ==
             2
  end
end
