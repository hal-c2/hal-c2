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
  a rolled-back run, which no timeline shows. Every other kind (the thread, its runs,
  checkpoints, requests) is small and held whole. A `floor` of `nil` is a window
  that reaches the start of the thread.

  Whatever is left out here is never sent as an event either, so a client is never
  handed a patch to an entity it does not have.
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
  Events as they go to the view's client: those to entities it holds, trimmed.
  `before` is the stream as it was before them, for the entities they deleted.
  """
  @spec events(t, StreamState.t(), StreamState.t(), [HalC2.Store.event()]) ::
          [HalC2.Store.event()]
  def events(view, stream, before \\ StreamState.new(), events) do
    Enum.flat_map(events, fn %{kind: kind, entity: id, patch: patch} = event ->
      entity = StreamState.get(stream, kind)[id] || StreamState.get(before, kind)[id]

      with false <- StreamState.void?(event),
           true <- holds?(view, stream, kind, entity),
           %{} = patch <- Wire.patch(kind, patch, entity && entity["type"]) do
        [%{event | patch: patch}]
      else
        _ -> []
      end
    end)
  end

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
        for {seq, kind, id, entity} <- upserts, holds?(view, stream, kind, entity) do
          patch = %{"d" => true, "s" => Wire.entity(kind, entity)}
          %{seq: seq, kind: kind, entity: id, patch: patch, at: at}
        end

      deletes =
        for {seq, kind, id} <- deletes, holds?(view, stream, kind, nil) do
          %{seq: seq, kind: kind, entity: id, patch: HalC2.Patch.delete(), at: at}
        end

      Enum.sort_by(upserts ++ deletes, & &1.seq)
    end
  end
end
