defmodule HalC2.Streams.View do
  @moduledoc """
  What one client holds of a stream, and so what it is sent.

  A client names the entities it folds with `kinds`: a map from entity kind to the
  field values an entity of that kind must have, such as
  `%{"turn-item" => %{}, "message" => %{"role" => "user"}}`. Without one it holds
  every entity.

  A client may also hold only the end of a thread, a `window`. Turn items, messages
  and nodes belong to a run; the client holds those of runs whose ordinal is at
  least the window's `floor`, plus the few that belong to no run, and never those of
  a rolled-back run, which no timeline shows. A run waiting in the queue has not run
  yet, so it is held whatever its ordinal: a queue held for long keeps runs older
  than the window, and the composer lists them by their message. Every other kind
  (the thread, its runs, checkpoints, requests) is small and held whole. A `floor`
  of `nil` is a window that reaches the start of the thread.

  Whatever is left out here is never sent as an event either, so a client is never
  handed a patch to an entity it does not have. An entity that comes to be held
  (a field its kind is chosen by changed) is sent whole in place of the patch, and
  one that stops being held is deleted for the client. A run that moves in or out
  of the window (rolled back, or leaving or rejoining the queue below the floor)
  takes every item of the run with it.
  """

  alias HalC2.StreamState
  alias HalC2.Web.Wire

  @windowed ~w(turn-item message node)

  @type kinds :: %{String.t() => %{String.t() => term}} | nil
  @type window :: %{floor: integer | nil} | nil
  @type t :: %{kinds: kinds, window: window}

  @doc "Whether the view holds this entity. A deleted entity (`nil`) passes by its kind."
  @spec holds?(t, StreamState.t(), String.t(), map | nil) :: boolean
  def holds?(view, stream, kind, entity),
    do: kind?(view.kinds, kind, entity) and in_window?(view.window, stream, kind, entity)

  defp kind?(nil, _kind, _entity), do: true

  defp kind?(kinds, kind, entity) do
    case kinds do
      %{^kind => where} -> entity == nil or Enum.all?(where, fn {k, v} -> entity[k] == v end)
      _ -> false
    end
  end

  defp in_window?(nil, _stream, _kind, _entity), do: true
  defp in_window?(_window, _stream, _kind, nil), do: true

  defp in_window?(%{floor: floor}, stream, kind, entity) when kind in @windowed do
    case StreamState.get(stream, "run")[entity["runId"]] do
      nil -> true
      %{"status" => "rolled_back"} -> false
      %{"status" => "queued"} -> true
      run -> floor == nil or ordinal(run) >= floor
    end
  end

  defp in_window?(_window, _stream, _kind, _entity), do: true

  @doc """
  The floor of a window over the newest runs that together hold at least `items`
  turn items: `nil` when that is every run.
  """
  @spec tail(StreamState.t(), pos_integer) :: integer | nil
  def tail(stream, items) do
    {_taken, floor} = take_runs(stream, nil, items)
    floor
  end

  @doc """
  The runs before `floor` that together hold at least `items` turn items, newest
  first, as `{run_ids, floor}` with the floor a window has once it holds them too.
  """
  @spec take_runs(StreamState.t(), integer | nil, pos_integer) :: {MapSet.t(), integer | nil}
  def take_runs(stream, before, items) do
    counts =
      stream
      |> StreamState.get("turn-item")
      |> Enum.frequencies_by(fn {_id, item} -> item["runId"] end)

    runs =
      for {id, run} <- StreamState.get(stream, "run"),
          run["status"] != "rolled_back",
          before == nil or ordinal(run) < before,
          do: {ordinal(run), id}

    runs = Enum.sort(runs, :desc)

    {taken, rest, _count} =
      Enum.reduce_while(runs, {[], runs, 0}, fn {_, id} = run, {taken, [_ | rest], count} ->
        count = count + Map.get(counts, id, 0)
        acc = {[run | taken], rest, count}
        if count >= items, do: {:halt, acc}, else: {:cont, acc}
      end)

    floor =
      case {taken, rest} do
        {[], _} -> nil
        {_, []} -> nil
        {[{ordinal, _} | _], _} -> ordinal
      end

    {MapSet.new(taken, &elem(&1, 1)), floor}
  end

  defp ordinal(run), do: run["ordinal"] || 0

  @doc "The view's rows as they go to the client, in creation order."
  @spec rows(t, StreamState.t()) :: [{String.t(), String.t(), map}]
  def rows(view, stream) do
    for {kind, id, entity} <- StreamState.rows(stream),
        holds?(view, stream, kind, entity),
        do: {kind, id, Wire.entity(kind, entity)}
  end

  @doc "The windowed rows of `runs` as they go to the client, in creation order."
  @spec page(t, StreamState.t(), MapSet.t()) :: [{String.t(), String.t(), map}]
  def page(view, stream, runs) do
    for {kind, id, entity} <- StreamState.rows(stream),
        kind in @windowed,
        MapSet.member?(runs, entity["runId"]),
        kind?(view.kinds, kind, entity),
        do: {kind, id, Wire.entity(kind, entity)}
  end

  @doc """
  A commit's events as they go to the view's client, trimmed. `before` is the
  stream as it was before them, which says what the client held until now.
  """
  @spec events(t, StreamState.t(), StreamState.t(), [HalC2.Store.event()]) ::
          [HalC2.Store.event()]
  def events(view, stream, before, events) do
    {sent, settled} =
      Enum.flat_map_reduce(events, MapSet.new(), fn event, settled ->
        %{kind: kind, entity: id, patch: patch} = event
        was = StreamState.get(before, kind)[id]
        now = StreamState.get(stream, kind)[id]
        held? = was != nil and holds?(view, before, kind, was)
        holds? = now != nil and holds?(view, stream, kind, now)

        cond do
          StreamState.void?(event) or MapSet.member?(settled, {kind, id}) ->
            {[], settled}

          # Held all along, or made by this commit: its patches are all there is to say.
          holds? and (held? or was == nil) ->
            case Wire.patch(kind, patch, now["type"]) do
              nil -> {[], settled}
              patch -> {[%{event | patch: patch}], settled}
            end

          holds? ->
            {[%{event | patch: replacement(kind, now)}], MapSet.put(settled, {kind, id})}

          held? ->
            {[%{event | patch: HalC2.Patch.delete()}], MapSet.put(settled, {kind, id})}

          true ->
            {[], settled}
        end
      end)

    sent ++ rolled(view, stream, before, events, settled)
  end

  # A run that moves in or out of the window takes its items with it, without an
  # event to any of them: the ones the client held go, the ones it comes to hold
  # are sent whole.
  defp rolled(%{window: nil}, _stream, _before, _events, _settled), do: []

  defp rolled(view, stream, before, events, settled) do
    for %{kind: "run", entity: run} = event <- Enum.uniq_by(Enum.reverse(events), & &1.entity),
        {kind, id, entity} <- of_run(stream, run),
        not MapSet.member?(settled, {kind, id}),
        kind?(view.kinds, kind, entity),
        move =
          moving(view.window, before, stream, kind, StreamState.get(before, kind)[id], entity),
        move != :stays,
        do: %{event | kind: kind, entity: id, patch: moved(kind, entity, move == :joins)}
  end

  # Whether a commit's change to its run moves an entity into the window or out.
  # One made by the commit itself was not held before, whatever its run said.
  defp moving(window, before, stream, kind, was, entity) do
    held? = was != nil and in_window?(window, before, kind, was)

    case {held?, in_window?(window, stream, kind, entity)} do
      {false, true} when was != nil -> :joins
      {true, false} -> :leaves
      _ -> :stays
    end
  end

  defp moved(kind, entity, true), do: replacement(kind, entity)
  defp moved(_kind, _entity, false), do: HalC2.Patch.delete()

  defp of_run(stream, run) do
    for kind <- @windowed,
        {id, %{"runId" => ^run} = entity} <- StreamState.get(stream, kind),
        do: {kind, id, entity}
  end

  defp replacement(kind, entity), do: %{"d" => true, "s" => Wire.entity(kind, entity)}

  @doc """
  The log's events since a client's offset as they go to it, merged per entity and
  trimmed. What the client held at its offset is not known here, only what it holds
  now, so an entity held now is taken to have been held then. A run out of the
  window deletes its items, and one waiting in the queue, which may have rejoined
  it, sends its message again: all it holds before it runs.
  """
  @spec replayed(t, StreamState.t(), [HalC2.Store.event()]) :: [HalC2.Store.event()]
  def replayed(view, stream, events) do
    Enum.flat_map(events, fn %{kind: kind, entity: id, patch: patch} = event ->
      entity = StreamState.get(stream, kind)[id]

      sent =
        with false <- StreamState.void?(event),
             true <- holds?(view, stream, kind, entity),
             %{} = patch <- Wire.patch(kind, patch, entity && entity["type"]) do
          [%{event | patch: patch}]
        else
          _ -> []
        end

      # Whether or not the client holds runs: its items are what it is owed.
      sent ++ rolled_since(view, stream, event)
    end)
  end

  defp rolled_since(%{window: window} = view, stream, %{kind: "run", entity: run} = event)
       when window != nil do
    queued? = StreamState.get(stream, "run")[run]["status"] == "queued"

    for {kind, id, entity} <- of_run(stream, run),
        kind?(view.kinds, kind, entity),
        queued? or not in_window?(window, stream, kind, entity),
        do: %{event | kind: kind, entity: id, patch: moved(kind, entity, queued?)}
  end

  defp rolled_since(_view, _stream, _event), do: []

  @doc """
  What a copy of the view as of `offset` lacks, as events that replace each entity
  changed since and delete each one gone, or `:unknown` when the stream no longer
  knows (`HalC2.StreamState.changed_since/2`).
  """
  @spec changed_since(t, StreamState.t(), non_neg_integer) :: [HalC2.Store.event()] | :unknown
  def changed_since(view, stream, offset) do
    with {upserts, deletes} <- StreamState.changed_since(stream, offset) do
      # When each one changed is not kept; clients only need a time to show.
      at = stream.updated_at || 0

      upserts =
        Enum.flat_map(upserts, fn {seq, kind, id, entity} ->
          event = %{seq: seq, kind: kind, entity: id, patch: replacement(kind, entity), at: at}
          sent = if holds?(view, stream, kind, entity), do: [event], else: []
          # Whether or not the client holds runs: its items are what it is owed.
          sent ++ rolled_since(view, stream, event)
        end)

      deletes =
        for {seq, kind, id} <- deletes, holds?(view, stream, kind, nil) do
          %{seq: seq, kind: kind, entity: id, patch: HalC2.Patch.delete(), at: at}
        end

      Enum.sort_by(upserts ++ deletes, & &1.seq)
    end
  end
end
