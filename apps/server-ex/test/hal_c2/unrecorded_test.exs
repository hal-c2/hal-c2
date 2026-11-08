defmodule HalC2.UnrecordedTest do
  # hal-c2#1285 (review of #1398): a turn the store failed that ended inside a call
  # (a stop Muse refuses, ACP's prompt answered at once) left its failure in the
  # runtime's state, and the thread's next run failed with it, or lost its first event.
  use ExUnit.Case, async: true

  alias HalC2.Orchestration.Unrecorded

  @failure %{
    run: "run-1",
    at: "then",
    failure: "The turn could not be saved",
    provider_turn: :pending
  }

  defp state(run, marker \\ @failure),
    do: %{thread_id: "t", turn: run && %{ids: %{run: run}}, unrecorded: marker}

  # What the handler saw: whether it ran dry and whether the state held the failure.
  defp seen(state), do: {Process.get(:hal_c2_unrecorded_stream), Map.has_key?(state, :unrecorded)}

  test "a call that ends the failed turn writes nothing and drops the failure" do
    handle = fn :interrupt, _from, state ->
      {:reply, seen(state), %{state | turn: nil}}
    end

    assert {:reply, {"t", true}, next} =
             Unrecorded.handle_call(:interrupt, nil, state("run-1"), handle)

    refute Map.has_key?(next, :unrecorded)
    assert Process.get(:hal_c2_unrecorded_stream) == nil
  end

  test "a call the failed turn runs on through keeps the failure" do
    handle = fn :steer, _from, state -> {:reply, seen(state), state} end

    assert {:reply, {"t", true}, %{unrecorded: @failure}} =
             Unrecorded.handle_call(:steer, nil, state("run-1"), handle)
  end

  test "the next run's calls and messages neither run dry nor see an earlier turn's failure" do
    call = fn :start, _from, state -> {:reply, seen(state), state} end

    info = fn :event, state ->
      send(self(), {:seen, seen(state)})
      {:noreply, state}
    end

    assert {:reply, {nil, false}, next} =
             Unrecorded.handle_call(:start, nil, state("run-2"), call)

    refute Map.has_key?(next, :unrecorded)

    assert {:noreply, next} = Unrecorded.handle_info(__MODULE__, :event, state("run-2"), info)
    assert_received {:seen, {nil, false}}
    refute Map.has_key?(next, :unrecorded)
  end

  test "an idle runtime does not keep an ended turn's failure" do
    info = fn :event, state ->
      send(self(), {:seen, seen(state)})
      {:noreply, state}
    end

    assert {:noreply, next} = Unrecorded.handle_info(__MODULE__, :event, state(nil), info)
    assert_received {:seen, {nil, false}}
    refute Map.has_key?(next, :unrecorded)
  end

  test "a call whose write to another stream the store refuses replies an error and keeps the turn" do
    handle = fn :interrupt, _from, _state ->
      raise HalC2.Streams.Unrecorded.of(%RuntimeError{message: "disk full"})
    end

    state = state("run-1")

    assert {:reply, {:error, "The turn could not be saved: disk full"}, ^state} =
             Unrecorded.handle_call(:interrupt, nil, state, handle)

    assert Process.get(:hal_c2_unrecorded_stream) == nil
  end
end
