defmodule HalC2.AcpRuntimeTerminateTest do
  use ExUnit.Case, async: true

  alias HalC2.Acp.ThreadRuntime

  # A store that timed out took a Kimi turn's runtime down, and ending the turn on the
  # way out timed out again: the crash report named that second failure, not the
  # first, and the turn was left for `HalC2.Orchestration.TurnWatch` all the same.
  test "a runtime that crashes mid-turn stops even when ending the turn fails" do
    task =
      Task.async(fn ->
        {:ok, state} = ThreadRuntime.init("thread-1")

        # Text buffered for an item the runtime no longer knows: writing it raises.
        state = %{
          state
          | turn: %{ids: %{driver: "acpRegistry"}},
            buffer: %{{"gone", "text"} => "hi"}
        }

        ThreadRuntime.terminate({:timeout, {GenServer, :call, []}}, state)
      end)

    assert :ok = Task.await(task)
  end
end
