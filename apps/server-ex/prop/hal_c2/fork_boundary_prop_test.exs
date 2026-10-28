defmodule HalC2.ForkBoundaryPropTest do
  @moduledoc """
  The law `HalC2.Orchestration.Handoff.fork_boundary/3` promises, for any
  recorded source turns: a fork point with a native reference cuts there, one
  without is trimmed by the finished turns after it on Codex and refused on
  Claude once later turns exist, and a fork point with no recorded turn is
  refused. A plain `forall`: the boundary is pure over the source's state.
  """

  use ExUnit.Case, async: true
  use PropCheck

  alias HalC2.Orchestration.Handoff
  alias HalC2.StreamState

  @point %{
    "runId" => "run-1",
    "providerThreadRef" => %{"driver" => "x", "nativeId" => "native-thread-1"}
  }

  property "the boundary follows the recorded turns", numtests: HalC2.Prop.numtests(100) do
    forall {driver, first, after_count} <-
             {oneof(["codex", "claudeAgent"]), oneof([:recorded, :missing, :gone]), integer(0, 4)} do
      Handoff.fork_boundary(source(first, after_count), @point, driver) ==
        expected(driver, first, after_count)
    end
  end

  defp expected(_driver, :recorded, _after), do: {:native, "native-1"}
  defp expected("codex", :missing, after_count), do: {:trim, after_count}
  defp expected("claudeAgent", :missing, 0), do: {:trim, 0}

  defp expected("claudeAgent", :missing, _after) do
    {:error,
     "Cannot fork Claude thread from that turn: no message position was recorded for that turn."}
  end

  # No recorded turns at all: the boundary is unknown, not an error.
  defp expected(_driver, :gone, 0), do: :unknown

  defp expected(driver, :gone, _after) do
    label = if driver == "codex", do: "Codex", else: "Claude"

    {:error,
     "Cannot fork #{label} thread from that turn: the source turn was not found in the provider's conversation."}
  end

  # Run 1's provider turn (absent for :gone, referenceless for :missing) and
  # `after_count` finished turns after it, all on one provider thread.
  defp source(first, after_count) do
    turn = fn ordinal, native ->
      {"provider-turn",
       %{
         "id" => "pturn-#{ordinal}",
         "providerThreadId" => "pthread-1",
         "runAttemptId" => "attempt-#{ordinal}",
         "nativeTurnRef" => %{"driver" => "x", "nativeId" => native},
         "ordinal" => ordinal,
         "status" => "completed"
       }}
    end

    first =
      case first do
        :recorded -> turn.(1, "native-1")
        :missing -> turn.(1, nil)
        :gone -> nil
      end

    later =
      for ordinal <- 2..(after_count + 1)//1,
          after_count > 0,
          do: turn.(ordinal, "native-#{ordinal}")

    ([{"run-attempt", %{"id" => "attempt-1", "runId" => "run-1"}}, first] ++ later)
    |> Enum.filter(& &1)
    |> Enum.with_index(1)
    |> Enum.reduce(StreamState.new(), fn {{kind, entity}, seq}, state ->
      StreamState.apply_event(state, %{
        seq: seq,
        kind: kind,
        entity: entity["id"],
        patch: %{"s" => entity}
      })
    end)
  end
end
