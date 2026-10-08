defmodule HalC2.Prop.StreamsCollector do
  @moduledoc """
  A stream subscriber for the property tests in `prop/`: a process that keeps every
  `{:hal_c2_stream, id, message}` it is sent and folds them the way a client does, so
  a test can ask it what it holds of each stream and what it was sent to get there.

  Per stream it keeps `msgs` (every message since its subscription was last
  `reset/4`, oldest first), `entities` (`{kind, id} => entity`, what it holds),
  `offset`, `handle` and `floor` (what it would resume from), and `from` (the offset
  the current subscription resumed from).
  """

  alias HalC2.Patch

  def start, do: spawn(fn -> loop(%{}) end)

  @doc """
  Readies the collector for a new subscription to `stream`. `keep?` keeps what it
  holds, as a client that resumes does; otherwise it starts with nothing.
  """
  def reset(pid, stream, from, keep?), do: call(pid, {:reset, stream, from, keep?})

  @doc "What the collector holds of `stream`, or `nil`."
  def get(pid, stream), do: call(pid, {:get, stream})

  defp call(pid, request) do
    ref = Process.monitor(pid)
    send(pid, {request, self(), ref})

    receive do
      {^ref, reply} ->
        Process.demonitor(ref, [:flush])
        reply

      {:DOWN, ^ref, _, _, reason} ->
        exit({:collector_down, reason})
    end
  end

  defp empty,
    do: %{msgs: [], entities: %{}, offset: nil, handle: nil, floor: nil, from: nil, snap: false}

  defp loop(streams) do
    receive do
      {{:reset, stream, from, keep?}, caller, ref} ->
        sub = Map.get(streams, stream, empty())
        sub = if keep?, do: sub, else: empty()
        send(caller, {ref, :ok})
        loop(Map.put(streams, stream, %{sub | msgs: [], from: from, snap: false}))

      {{:get, stream}, caller, ref} ->
        reply =
          case streams do
            %{^stream => sub} -> %{sub | msgs: Enum.reverse(sub.msgs)}
            _ -> nil
          end

        send(caller, {ref, reply})
        loop(streams)

      {:hal_c2_stream, stream, message} ->
        sub = Map.get(streams, stream, empty())
        sub = fold(%{sub | msgs: [message | sub.msgs]}, message)
        loop(Map.put(streams, stream, sub))
    end
  end

  # The first part of a snapshot replaces everything held.
  defp fold(sub, {:snapshot, seq, _at, rows, _more}), do: snapshot(sub, seq, rows)

  defp fold(sub, {:snapshot, seq, _at, rows, _more, meta}),
    do: %{snapshot(sub, seq, rows) | handle: meta.handle, floor: meta[:floor]}

  defp fold(sub, {:events, events}) do
    sub = apply_events(sub, events)
    if events == [], do: sub, else: %{sub | offset: List.last(events).seq}
  end

  defp fold(sub, {:events, events, seq}), do: %{apply_events(sub, events) | offset: seq}
  defp fold(sub, {:live, seq}), do: %{sub | offset: seq}
  defp fold(sub, {:live, seq, handle}), do: %{sub | offset: seq, handle: handle}
  defp fold(sub, {:changed, seq}), do: %{sub | offset: seq}

  defp fold(sub, {:page, _seq, rows, floor, _more}),
    do: %{sub | entities: put_rows(sub.entities, rows), floor: floor}

  defp snapshot(sub, seq, rows) do
    held = if sub.snap, do: sub.entities, else: %{}
    %{sub | entities: put_rows(held, rows), offset: seq, snap: true}
  end

  defp put_rows(entities, rows),
    do: Enum.reduce(rows, entities, fn {kind, id, e}, acc -> Map.put(acc, {kind, id}, e) end)

  defp apply_events(sub, events) do
    entities =
      for event <- events, not HalC2.StreamState.void?(event), reduce: sub.entities do
        acc ->
          %{kind: kind, entity: id, patch: patch} = event

          case Patch.apply(acc[{kind, id}], patch) do
            nil -> Map.delete(acc, {kind, id})
            entity -> Map.put(acc, {kind, id}, entity)
          end
      end

    %{sub | entities: entities}
  end
end
