defmodule HalC2.Orchestration.Unrecorded do
  @moduledoc """
  A turn whose events the store could not record (a full disk, say): its run fails
  with what the store said, at the time it failed, and its provider turn stops with
  it, as a Stop stops it. The provider runtime goes on driving the turn to its end
  without writing any more of it (`HalC2.Streams.unrecorded/2`), and hands that end to
  `HalC2.Orchestration.TurnWatch` (`TurnWriter.finish/3`), which keeps it in memory
  and records it, once, when the store takes it. The provider session stays, so the
  thread's next message goes on in the same provider conversation.

  A runtime routes its messages and calls through `handle_info/4` and `handle_call/4`,
  after its own clauses:

      defoverridable handle_info: 2, handle_call: 3

      @impl true
      def handle_info(message, state),
        do: Unrecorded.handle_info(__MODULE__, message, state, fn m, s -> super(m, s) end)

      @impl true
      def handle_call(request, from, state),
        do: Unrecorded.handle_call(request, from, state, fn r, f, s -> super(r, f, s) end)

  The runtime's state keeps the failure (`:unrecorded`) while its turn runs, and only
  for that turn: a call can end it too (a stop the provider refuses), and the marker
  goes with it, so the thread's next run records as usual. While the turn goes
  unrecorded, another stream's write the store refuses (a subagent's thread) is lost
  alone (`HalC2.Streams.unrecorded/2`): the runtime still stops the turn and hands
  over its end. A failed write outside a turn, or inside a call while the turn still
  records, raises as before; a call's crash is TurnWatch's to end.
  """

  alias HalC2.Orchestration.{Entities, TurnWatch}
  alias HalC2.Streams

  @doc """
  Handles `message` with `handle` (the runtime's own `handle_info/2`). A turn the store
  fails starts its runtime's stop (`module.handle_call(:interrupt, ...)`).
  """
  def handle_info(module, message, state, handle) do
    case marked(state) do
      {:dry, state} ->
        dry(state, fn -> handle.(message, state) end)

      {:wet, state} ->
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

  @doc """
  Handles `request` with `handle` (the runtime's own `handle_call/3`), writing nothing
  while its turn goes unrecorded: a stop the provider refuses ends the turn in the
  call, and hands its end over as a message's would.
  """
  def handle_call(request, from, state, handle) do
    case marked(state) do
      {:dry, state} ->
        dry(state, fn -> handle.(request, from, state) end)

      {:wet, state} ->
        handle.(request, from, state)
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

  # The turn's end, once handed over, takes the runtime out of dry mode.
  defp dry(state, fun) do
    state.thread_id
    |> Streams.unrecorded(fun)
    |> map_state(&unmark(&1, state.unrecorded.run))
  end

  # A marker whose turn is no longer the runtime's is gone, however that turn ended.
  defp marked(%{unrecorded: %{run: run}} = state) do
    if run(state) == run, do: {:dry, state}, else: {:wet, Map.delete(state, :unrecorded)}
  end

  defp marked(state), do: {:wet, state}

  defp unmark(state, run),
    do: if(run(state) == run, do: state, else: Map.delete(state, :unrecorded))

  defp run(%{turn: %{ids: %{run: run}}}), do: run
  defp run(_state), do: nil

  defp map_state({:reply, reply, state}, fun), do: {:reply, reply, fun.(state)}
  defp map_state({:reply, reply, state, next}, fun), do: {:reply, reply, fun.(state), next}
  defp map_state({:stop, reason, reply, state}, fun), do: {:stop, reason, reply, fun.(state)}
  defp map_state({:noreply, state}, fun), do: {:noreply, fun.(state)}
  defp map_state({:noreply, state, next}, fun), do: {:noreply, fun.(state), next}
  defp map_state({:stop, reason, state}, fun), do: {:stop, reason, fun.(state)}
end
