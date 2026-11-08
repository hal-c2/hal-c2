defmodule HalC2.Orchestration.Unrecorded do
  @moduledoc """
  A turn whose events the store could not record (a full disk, say): its run fails
  with what the store said, at the time it failed, and its provider turn stops with
  it, as a Stop stops it. The provider runtime goes on driving the turn to its end
  without writing any more of it (`HalC2.Streams.unrecorded/2`), and hands that end to
  `HalC2.Orchestration.TurnWatch` (`TurnWriter.finish/3`), which keeps it in memory
  and records it, once, when the store takes it. The provider session stays, so the
  thread's next message goes on in the same provider conversation.

  A runtime routes its messages through `handle_info/4`, after its own clauses:

      defoverridable handle_info: 2

      @impl true
      def handle_info(message, state),
        do: Unrecorded.handle_info(__MODULE__, message, state, fn m, s -> super(m, s) end)

  A failed write outside a turn, or inside one of the runtime's calls, raises as
  before; a call's crash is TurnWatch's to end.
  """

  alias HalC2.Orchestration.{Entities, TurnWatch}
  alias HalC2.Streams

  @doc """
  Handles `message` with `handle` (the runtime's own `handle_info/2`). A turn the store
  fails starts its runtime's stop (`module.handle_call(:interrupt, ...)`).
  """
  def handle_info(module, message, state, handle) do
    if Map.get(state, :unrecorded) do
      dry(state, fn -> handle.(message, state) end)
    else
      try do
        handle.(message, state)
      rescue
        error in Streams.Unrecorded ->
          case run(state) do
            nil -> reraise error, __STACKTRACE__
            run -> failed(module, message, state, handle, run, error)
          end
      end
    end
  end

  # The message is handled again from where it found the runtime, now writing nothing,
  # and a turn still running is stopped. TurnWatch holds the failure from here on, so
  # a runtime that crashes before the turn ends still fails the run with it.
  defp failed(module, message, state, handle, run, error) do
    unrecorded = %{
      run: run,
      at: Entities.now(),
      failure: "The turn could not be saved: #{error.message}",
      provider_turn: :pending
    }

    TurnWatch.unrecorded(state.thread_id, run, unrecorded)
    state = Map.put(state, :unrecorded, unrecorded)

    dry(state, fn ->
      message
      |> handle.(state)
      |> map_state(fn state ->
        if run(state) == run,
          do: elem(module.handle_call(:interrupt, {self(), make_ref()}, state), 2),
          else: state
      end)
    end)
  end

  # Another stream's write failing here (a subagent's thread) loses that message
  # alone. The turn's end, once handed over, takes the runtime out of dry mode.
  defp dry(state, fun) do
    state.thread_id
    |> Streams.unrecorded(fun)
    |> map_state(fn next ->
      if run(next) == state.unrecorded.run, do: next, else: Map.delete(next, :unrecorded)
    end)
  rescue
    Streams.Unrecorded -> {:noreply, state}
  end

  defp run(%{turn: %{ids: %{run: run}}}), do: run
  defp run(_state), do: nil

  defp map_state({:noreply, state}, fun), do: {:noreply, fun.(state)}
  defp map_state({:noreply, state, next}, fun), do: {:noreply, fun.(state), next}
  defp map_state({:stop, reason, state}, fun), do: {:stop, reason, fun.(state)}
end
