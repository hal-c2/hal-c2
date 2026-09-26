defmodule HalC2.Steps.Timeline.ToolCalls do
  @moduledoc """
  Steps for `features/timeline/tool-calls.feature`. The three turns each write one file
  with the fake Codex: "turn-1.txt", "turn-2.txt", "turn-3.txt".
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Node.World

  step "a thread with three finished turns", context do
    World.finished_turns(
      context,
      World.current(context),
      for(n <- 1..3, do: "write turn-#{n}.txt")
    )
  end

  step "a client asks for the diff of the second turn", context do
    {result, context} =
      World.call!(context, "orchestration.getTurnDiff", %{
        "threadId" => World.thread_id(context, World.current(context)),
        "fromTurnCount" => 1,
        "toTurnCount" => 2
      })

    Map.put(context, :diff, result)
  end

  step "it receives the changes made during the second turn", context do
    assert %{"fromTurnCount" => 1, "toTurnCount" => 2, "diff" => diff} = context.diff
    assert changed_files(diff) == ["turn-2.txt"]
    assert diff =~ "+write turn-2.txt"
    context
  end

  step "a client asks for the whole thread's diff", context do
    {result, context} =
      World.call!(context, "orchestration.getFullThreadDiff", %{
        "threadId" => World.thread_id(context, World.current(context)),
        "toTurnCount" => 3
      })

    Map.put(context, :diff, result)
  end

  step "it receives the changes from before the first turn to after the last", context do
    assert %{"fromTurnCount" => 0, "toTurnCount" => 3, "diff" => diff} = context.diff
    assert changed_files(diff) == ["turn-1.txt", "turn-2.txt", "turn-3.txt"]
    context
  end

  defp changed_files(diff),
    do: for([_, path] <- Regex.scan(~r/^diff --git a\/(\S+) /m, diff), do: path) |> Enum.sort()
end
