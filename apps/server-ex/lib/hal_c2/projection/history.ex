defmodule HalC2.Projection.History do
  @moduledoc """
  A thread's history in bounded pages, for a client that asks for a snapshot
  without the whole transcript (`hal-c2.threadRows` with `"bounded"`, then
  `"cursor"` for the pages before it).

  A bounded snapshot holds the newest #{10} user turns; a page before a cursor
  holds the #{20} before them. A page never splits a turn: it walks the visible
  timeline back through complete turns, however many items they hold, and
  steering messages belong to the turn they steered. Automatic turns (started
  by background work, not the user) count against a raw cap, so hundreds of
  them between two user messages still bound a page. History that records no
  turn starts (an import) is paged by items and encoded size instead, and
  always holds at least one item, however large it is.

  Everything the user can still act on rides along whatever the window: active
  plans, pending handoffs, pending requests, queued messages. A finished plan
  or handoff named by an item in the window carries only its status, with
  `detailInTurnItem` saying its detail is in that item, never the text twice.
  When what must be kept is itself over the size budget, nothing actionable is
  dropped; the snapshot says so (`payloadBudgetExceeded`).

  A cursor names where a page starts: the item it begins at and the position
  that item held, so it stays valid while the thread grows, and resumes from
  the recorded position when its item has since left the timeline. One the MC
  never gave is refused.
  """

  import HalC2.Projection.JS, only: [get: 2]

  alias HalC2.StreamState
  alias HalC2.Projection.Timeline
  alias HalC2.Web.Wire

  @snapshot_user_turns 10
  @page_user_turns 20
  @max_raw_turns 150
  @max_items 75
  @max_encoded_bytes 1_048_576
  @max_cursor_length 4_096

  @type page :: %{
          rows: [[term]],
          cursor: String.t() | nil,
          has_more: boolean,
          over_budget: boolean
        }

  @doc "Whether an item starts a turn: a user message sent as one, or queued as one."
  @spec turn_start?(map) :: boolean
  def turn_start?(item),
    do:
      get(item, "type") == "user_message" and
        get(item, "inputIntent") in ["turn_start", "queued_turn"]

  @doc "Whether an item starts a turn of the user's (steering starts none, and automatic turns are not the user's)."
  @spec user_turn?(map) :: boolean
  def user_turn?(item), do: turn_start?(item) and get(item, "createdBy") == "user"

  @doc """
  The bounded snapshot of a thread stream: its rows as clients receive them
  (`[kind, id, entity]`, creation order, wire-trimmed), the cursor for the
  page before it when older history exists, and whether keeping everything
  actionable took it over its size budget.
  """
  @spec bounded(StreamState.t()) :: page
  def bounded(state) do
    visible = Timeline.local_items(state)
    {items, oldest, has_more} = select(visible, length(visible), @snapshot_user_turns)
    rows = snapshot_rows(state, items)

    %{
      rows: rows,
      cursor: if(has_more, do: cursor_for(state, oldest)),
      has_more: has_more,
      over_budget: byte_size(JSON.encode!(rows)) > @max_encoded_bytes
    }
  end

  @doc """
  The page of history before `cursor`, as `bounded/1`'s rows of the windowed
  kinds only, with the cursor for the page before that. `:invalid_cursor` for
  a cursor this MC cannot use.
  """
  @spec page_before(StreamState.t(), String.t()) :: {:ok, page} | :invalid_cursor
  def page_before(state, cursor) do
    with {:ok, payload} <- decode_cursor(cursor) do
      visible = Timeline.local_items(state)
      anchor = anchor_index(visible, payload)
      {items, oldest, has_more} = select(visible, anchor, @page_user_turns)

      {:ok,
       %{
         rows: page_rows(state, items),
         cursor: if(has_more, do: cursor_for(state, oldest)),
         has_more: has_more,
         over_budget: false
       }}
    end
  end

  # --- selection -----------------------------------------------------------------

  # The items of `visible` (oldest first, positions kept) ending just before
  # index `end_index`, through complete user turns: `{items, oldest, has_more}`
  # where `oldest` is `{item, position}` of the first item kept, if any.
  defp select(visible, end_index, max_user_turns) do
    indexed = Enum.with_index(visible)
    before = Enum.take(indexed, end_index)
    by_turns? = Enum.any?(before, fn {item, _} -> turn_start?(item) end)

    {_count, _bytes, _user, _raw, selected} =
      before
      |> Enum.reverse()
      |> Enum.reduce_while({0, 0, 0, 0, []}, fn {item, _} = entry,
                                                {count, bytes, user, raw, acc} ->
        row_bytes = if by_turns?, do: 0, else: encoded_bytes(item)

        over? =
          count > 0 and
            if by_turns?,
              do: user >= max_user_turns or raw >= @max_raw_turns,
              else: count >= @max_items or bytes + row_bytes > @max_encoded_bytes

        if over? do
          {:halt, {count, bytes, user, raw, acc}}
        else
          {:cont,
           {count + 1, bytes + row_bytes, user + count_if(user_turn?(item)),
            raw + count_if(turn_start?(item)), [entry | acc]}}
        end
      end)

    items = Enum.map(selected, &elem(&1, 0))

    case selected do
      [] -> {[], nil, false}
      [{_, position} | _] = kept -> {items, hd(kept), position > 0}
    end
  end

  defp count_if(true), do: 1
  defp count_if(false), do: 0

  defp encoded_bytes(item),
    do: item |> then(&Wire.entity("turn-item", &1)) |> JSON.encode!() |> byte_size()

  # Where a cursor's page ends: at the item it names, or at the position it
  # recorded (clamped) when that item has since left the timeline.
  defp anchor_index(visible, %{"st" => thread_id, "si" => item_id, "p" => position}) do
    case Enum.find_index(visible, fn item ->
           get(item, "id") == item_id and get(item, "threadId") in [nil, thread_id]
         end) do
      nil -> min(position, length(visible))
      index -> index
    end
  end

  # --- rows ----------------------------------------------------------------------

  # A bounded snapshot's rows: every kind, bounded to the window's items and
  # what they need, plus everything actionable wherever it sits.
  defp snapshot_rows(state, items) do
    kept = kept_item_ids(state, items)
    runs = MapSet.new(items, &get(&1, "runId"))
    messages = kept_message_ids(state, items)
    plans = named_ids(items, ~w(proposed_plan todo_list), "planId")
    handoffs = named_ids(items, ~w(handoff), "contextHandoffId")

    for {kind, id, entity} <- StreamState.rows(state),
        row = snapshot_row(kind, id, entity, kept, runs, messages, plans, handoffs),
        row != nil,
        do: row
  end

  defp snapshot_row("turn-item", id, entity, kept, _runs, _messages, _plans, _handoffs) do
    if MapSet.member?(kept, id), do: ["turn-item", id, Wire.entity("turn-item", entity)]
  end

  defp snapshot_row("message", id, entity, _kept, _runs, messages, _plans, _handoffs) do
    if MapSet.member?(messages, id), do: ["message", id, entity]
  end

  defp snapshot_row("node", id, entity, _kept, runs, _messages, _plans, _handoffs) do
    if get(entity, "runId") == nil or MapSet.member?(runs, get(entity, "runId")),
      do: ["node", id, entity]
  end

  defp snapshot_row("plan", id, entity, _kept, _runs, _messages, plans, _handoffs) do
    cond do
      get(entity, "status") == "active" -> ["plan", id, entity]
      MapSet.member?(plans, id) -> ["plan", id, status_only_plan(entity)]
      true -> nil
    end
  end

  defp snapshot_row("context-handoff", id, entity, _kept, _runs, _messages, _plans, handoffs) do
    cond do
      get(entity, "status") in ["pending", "ready"] ->
        ["context-handoff", id, Wire.entity("context-handoff", entity)]

      MapSet.member?(handoffs, id) ->
        handoff = Wire.entity("context-handoff", entity)
        ["context-handoff", id, Map.put(handoff, "detailInTurnItem", true)]

      true ->
        nil
    end
  end

  defp snapshot_row(kind, id, entity, _kept, _runs, _messages, _plans, _handoffs),
    do: [kind, id, Wire.entity(kind, entity)]

  # A history page's rows: the page's items, and their runs' messages and nodes.
  defp page_rows(state, items) do
    kept = MapSet.new(items, &get(&1, "id"))
    runs = MapSet.new(items, &get(&1, "runId"))

    messages =
      for item <- items, id = get(item, "messageId"), id != nil, into: MapSet.new(), do: id

    for {kind, id, entity} <- StreamState.rows(state),
        kind in ["turn-item", "message", "node"],
        (kind == "turn-item" and MapSet.member?(kept, id)) or
          (kind == "message" and
             (MapSet.member?(messages, id) or MapSet.member?(runs, get(entity, "runId")))) or
          (kind == "node" and MapSet.member?(runs, get(entity, "runId"))),
        do: [kind, id, Wire.entity(kind, entity)]
  end

  # The window's items, plus every interrupt request: whether a superseded
  # interrupt result shows depends on its request, which may sit outside the
  # window the result lands in.
  defp kept_item_ids(state, items) do
    requests =
      for item <- StreamState.list(state, "turn-item"),
          get(item, "type") == "run_interrupt_request",
          do: get(item, "id")

    MapSet.new(Enum.map(items, &get(&1, "id")) ++ requests)
  end

  # The messages a bounded snapshot carries: the ones its items name, the ones
  # of the latest and of every live or queued run (a queued message is
  # actionable wherever it sits), and delegated completions.
  defp kept_message_ids(state, items) do
    runs = StreamState.list(state, "run")
    latest = Enum.max_by(runs, &(get(&1, "ordinal") || 0), fn -> nil end)

    live =
      for run <- runs,
          get(run, "id") == get(latest, "id") or
            get(run, "status") in ~w(preparing starting running waiting queued),
          do: run

    by_item = for item <- items, id = get(item, "messageId"), id != nil, do: id
    by_run = for run <- live, id = get(run, "userMessageId"), id != nil, do: id
    live_ids = MapSet.new(live, &get(&1, "id"))

    of_runs =
      for message <- StreamState.list(state, "message"),
          MapSet.member?(live_ids, get(message, "runId")) or
            get(message, "delegatedCompletion") != nil,
          do: get(message, "id")

    MapSet.new(by_item ++ by_run ++ of_runs)
  end

  defp named_ids(items, types, field) do
    for item <- items,
        get(item, "type") in types,
        id = get(item, field),
        id != nil,
        into: MapSet.new(),
        do: id
  end

  # A finished plan beside its timeline item: its status, and the mark that
  # its detail is in the item — never the plan text a second time.
  defp status_only_plan(plan) do
    plan
    |> then(
      &if(get(&1, "kind") == "proposed_plan",
        do: Map.put(&1, "markdown", ""),
        else: Map.delete(&1, "explanation")
      )
    )
    |> Map.put("detailInTurnItem", true)
  end

  # --- cursors -------------------------------------------------------------------

  defp cursor_for(_state, nil), do: nil

  defp cursor_for(state, {item, position}) do
    thread_id = get(Timeline.thread(state), "id") || get(item, "threadId")
    encode_cursor(state.seq, thread_id, get(item, "id"), position)
  end

  @doc "A history cursor naming `item_id` of `thread_id` at `position`, as of `seq`."
  @spec encode_cursor(non_neg_integer, String.t(), String.t(), non_neg_integer) :: String.t()
  def encode_cursor(seq, thread_id, item_id, position) do
    %{"v" => 1, "seq" => seq, "st" => thread_id, "si" => item_id, "p" => position}
    |> JSON.encode!()
    |> Base.url_encode64(padding: false)
  end

  @doc "A cursor's payload, or `:invalid_cursor` for one this MC cannot use."
  @spec decode_cursor(term) :: {:ok, map} | :invalid_cursor
  def decode_cursor(cursor) when is_binary(cursor) do
    with true <- cursor != "" and String.length(cursor) <= @max_cursor_length,
         {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{} = payload} <- JSON.decode(json),
         true <- valid_payload?(payload) do
      {:ok, payload}
    else
      _ -> :invalid_cursor
    end
  end

  def decode_cursor(_cursor), do: :invalid_cursor

  defp valid_payload?(%{"v" => 1, "seq" => seq, "st" => st, "si" => si, "p" => p}),
    do:
      is_integer(seq) and seq >= 0 and is_binary(st) and st != "" and is_binary(si) and
        si != "" and is_integer(p) and p >= 0

  defp valid_payload?(_payload), do: false
end
