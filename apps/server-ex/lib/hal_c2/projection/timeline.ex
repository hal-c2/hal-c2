defmodule HalC2.Projection.Timeline do
  @moduledoc """
  Which turn items a thread's transcript shows.

  Build an `index/3` once per thread, then ask `visible?/2` of each item. Items of a
  rolled-back run are hidden, as are queued messages whose run was cancelled and the
  unpaired interrupt result of a superseded attempt.

  `visible_items/2` is the transcript as the thread view numbers it: for a thread
  forked from a run, the source's items through that run and a fork marker come
  before the thread's own visible items. `local_count/1` and `visible_count/2` count
  the same items without reading older runs' from disk, from the stream's
  `HalC2.StreamState.tally/1`.
  """

  import HalC2.Projection.JS, only: [get: 2]

  alias HalC2.StreamState

  @type index :: %{statuses: map, superseded: MapSet.t(), interrupted_runs: MapSet.t()}
  @typedoc "Returns the state of another thread, or `nil` when it is unknown."
  @type resolve :: (String.t() -> StreamState.t() | nil)

  @spec index([map], [map], [map]) :: index
  def index(runs, attempts, items) do
    %{
      statuses: Map.new(runs, &{get(&1, "id"), get(&1, "status")}),
      superseded:
        for(
          a <- attempts,
          get(a, "status") == "superseded",
          into: MapSet.new(),
          do: {get(a, "runId"), get(a, "rootNodeId")}
        ),
      interrupted_runs:
        for(
          i <- items,
          get(i, "type") == "run_interrupt_request",
          into: MapSet.new(),
          do: get(i, "runId")
        )
    }
  end

  @spec visible?(index, map) :: boolean
  def visible?(index, item) do
    status = if run_id = get(item, "runId"), do: index.statuses[run_id]

    cond do
      status == "rolled_back" ->
        false

      status == "cancelled" and get(item, "type") == "user_message" and
          get(item, "inputIntent") == "queued_turn" ->
        false

      true ->
        not superseded_interrupt?(index, item)
    end
  end

  @doc """
  A plain steer restarts the attempt and leaves an interrupt result behind; it is
  noise unless the user asked for the stop (a matching interrupt request).
  """
  @spec superseded_interrupt?(index, map) :: boolean
  def superseded_interrupt?(index, item) do
    run_id = get(item, "runId")
    node_id = get(item, "nodeId")

    get(item, "type") == "run_interrupt_result" and run_id != nil and node_id != nil and
      superseded?(index, run_id, node_id)
  end

  defp superseded?(index, run_id, node_id),
    do:
      MapSet.member?(index.superseded, {run_id, node_id}) and
        not MapSet.member?(index.interrupted_runs, run_id)

  @doc "The thread's own visible turn items, in creation order, older runs' read from disk."
  @spec local_items(StreamState.t()) :: [map]
  def local_items(state) do
    items = state |> StreamState.all("turn-item") |> Enum.to_list()
    index = index(StreamState.list(state, "run"), StreamState.list(state, "run-attempt"), items)
    Enum.filter(items, &visible?(index, &1))
  end

  @doc "How many items `local_items/1` holds, counted without reading older runs'."
  @spec local_count(StreamState.t()) :: non_neg_integer
  def local_count(state) do
    {items, index} = counting(state)

    cold =
      for {run_id, tags} <- StreamState.tally(state),
          {tag, n} <- tags,
          shown?(index, run_id, index.statuses[run_id], tag),
          reduce: 0,
          do: (acc -> acc + n)

    Enum.count(items, &visible?(index, &1)) + cold
  end

  # What is in memory, and an index that knows of the cold interrupt requests too.
  defp counting(state) do
    items = StreamState.list(state, "turn-item")
    index = index(StreamState.list(state, "run"), StreamState.list(state, "run-attempt"), items)

    requested =
      for {run_id, %{interrupt_request: _}} <- StreamState.tally(state),
          into: index.interrupted_runs,
          do: run_id

    {items, %{index | interrupted_runs: requested}}
  end

  # `visible?/2` of a cold item by its `HalC2.StreamState` tag.
  defp shown?(_index, _run_id, "rolled_back", _tag), do: false
  defp shown?(_index, _run_id, "cancelled", :queued_user), do: false

  defp shown?(index, run_id, _status, {:interrupt_result, node_id}),
    do: not superseded?(index, run_id, node_id)

  defp shown?(_index, _run_id, _status, _tag), do: true

  @doc "The thread's transcript, including history inherited from a run fork's source."
  @spec visible_items(StreamState.t(), resolve) :: [map]
  def visible_items(state, resolve), do: visible_items(state, resolve, MapSet.new())

  defp visible_items(state, resolve, seen) do
    thread = thread(state)

    with %{"type" => "run", "threadId" => source_id, "runId" => run_id} <-
           get(thread, "forkedFrom"),
         false <- MapSet.member?(seen, source_id),
         %StreamState{} = source <- resolve.(source_id) do
      inherited = through_run(source, run_id, resolve, MapSet.put(seen, get(thread, "id")))
      inherited ++ [fork_marker(thread, source_id, run_id) | local_items(state)]
    else
      _ -> local_items(state)
    end
  end

  @doc "How many items `visible_items/2` holds, counted without reading older runs'."
  @spec visible_count(StreamState.t(), resolve) :: non_neg_integer
  def visible_count(state, resolve),
    do: inherited_count(state, resolve, MapSet.new()) + local_count(state)

  # How many items a thread inherits from a run fork's source, its fork marker included.
  defp inherited_count(state, resolve, seen) do
    thread = thread(state)

    with %{"type" => "run", "threadId" => source_id, "runId" => run_id} <-
           get(thread, "forkedFrom"),
         false <- MapSet.member?(seen, source_id),
         %StreamState{} = source <- resolve.(source_id) do
      count_through_run(source, run_id, resolve, MapSet.put(seen, get(thread, "id"))) + 1
    else
      _ -> 0
    end
  end

  # `length(through_run(...))`: what the source inherits (its own items are its
  # thread's, which `through_run/4` leaves out of its transcript) and its items up to
  # the run.
  defp count_through_run(source, run_id, resolve, seen) do
    runs = StreamState.list(source, "run")

    case Enum.find(runs, &(get(&1, "id") == run_id)) do
      nil ->
        0

      run ->
        history_origin = get(thread(source), "historyOrigin")
        ordinals = Map.new(runs, &{get(&1, "id"), get(&1, "ordinal")})
        {items, index} = counting(source)

        hot =
          Enum.count(items, fn item ->
            not superseded_interrupt?(index, item) and
              at_or_before_run?(history_origin, item, ordinals, run)
          end)

        cold =
          for {run_id, tags} <- StreamState.tally(source),
              is_integer(ordinals[run_id]) and ordinals[run_id] <= get(run, "ordinal"),
              {tag, n} <- tags,
              shown?(index, run_id, nil, tag),
              reduce: 0,
              do: (acc -> acc + n)

        inherited_count(source, resolve, seen) + hot + cold
    end
  end

  # The source's transcript up to and including `run_id`; empty if the run is gone.
  defp through_run(source, run_id, resolve, seen) do
    runs = StreamState.list(source, "run")

    case Enum.find(runs, &(get(&1, "id") == run_id)) do
      nil ->
        []

      run ->
        source_thread = thread(source)
        source_id = get(source_thread, "id")
        ordinals = Map.new(runs, &{get(&1, "id"), get(&1, "ordinal")})
        items = source |> StreamState.all("turn-item") |> Enum.to_list()
        index = index(runs, StreamState.list(source, "run-attempt"), items)

        inherited =
          source
          |> visible_items(resolve, seen)
          |> Enum.filter(&(get(&1, "threadId") != source_id or get(&1, "type") == "fork"))

        local =
          Enum.filter(items, fn item ->
            not superseded_interrupt?(index, item) and
              at_or_before_run?(get(source_thread, "historyOrigin"), item, ordinals, run)
          end)

        inherited ++ local
    end
  end

  defp at_or_before_run?(history_origin, item, ordinals, run) do
    case get(item, "runId") do
      nil -> history_origin == "v1_import"
      run_id -> is_integer(ordinals[run_id]) and ordinals[run_id] <= get(run, "ordinal")
    end
  end

  defp fork_marker(thread, source_id, run_id) do
    thread_id = get(thread, "id")
    created_at = get(thread, "createdAt")

    %{
      "id" => "turn-item:fork:#{thread_id}",
      "threadId" => thread_id,
      "runId" => nil,
      "nodeId" => nil,
      "providerTurnId" => nil,
      "nativeItemRef" => nil,
      "parentItemId" => nil,
      "ordinal" => 0,
      "status" => "completed",
      "title" => "Forked from conversation",
      "startedAt" => nil,
      "completedAt" => created_at,
      "updatedAt" => created_at,
      "type" => "fork",
      "source" => %{"type" => "run", "threadId" => source_id, "runId" => run_id},
      "targetThreadId" => thread_id
    }
  end

  @doc "The thread entity of a thread stream."
  @spec thread(StreamState.t()) :: map | nil
  def thread(state), do: state |> StreamState.list("thread") |> List.first()
end
