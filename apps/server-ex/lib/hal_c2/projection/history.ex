defmodule HalC2.Projection.History do
  @moduledoc """
  A thread's history in bounded pages, for a client that renders the end of a long
  thread and pages back on request (`hal-c2.threadHistory`).

  A page is whole runs, so a turn is never split: a run holds all of its items,
  messages and nodes, including the messages that steered it. A turn is a run a user
  message started; a run a notification or background work started is a turn of its
  own but is not counted against a page's budget of user turns, only against its cap
  of `#{150}` runs. A page ends at a run boundary, so what a thread gains later never
  moves it.

  One exception: a run holding more than `#{500}` windowed rows is paged within
  itself, newest rows first in slices of at most `#{75}` rows within the size
  budget, so opening a thread whose latest turn ran thousands of tool calls starts
  at that turn's newest rows instead of loading it whole. Its cursor names the run
  and how many of its rows lie before the slice, so rows the run gains later (which
  land after the slice) never move it.

  The snapshot is the newest `#{10}` user turns, and a page the `#{20}` before a
  cursor. The run cursor names the oldest run a page holds (its ordinal and id), so
  it stays valid while the thread grows and when that run later leaves the timeline:
  the next page is the runs with a lower ordinal. A cursor that does not decode to
  one of these is refused.

  The snapshot also carries everything the thread keeps small (the thread, runs,
  requests, plans, handoffs, checkpoints), so what the user can still act on is held
  whatever its age, plus the messages of queued runs. A pending runtime request —
  an approval, a question the agent asked — also pulls in the turn item and node
  that carry it, however old or large, so its answer panel can open; once it is
  resolved only the newest turns carry it. A plan or handoff that is no
  longer actionable keeps its shape but blanks its bulky text and sets
  `detailInTurnItem`: the text is in its turn item. A pending or ready handoff and a
  pending transfer count as actionable.

  Imported threads can hold rows with no run. They cannot be paged by run, so they
  are paged by rows and size instead (at most `#{75}` rows within the budget, and
  always at least one row however large), after every run page; the result says
  `runlessHistory` while a thread holds such rows.
  """

  alias HalC2.StreamState
  alias HalC2.Web.Wire

  @snapshot_turns 10
  @page_turns 20
  @max_runs 150
  @max_cursor 4_096
  @budget 1_000_000
  @split_rows 500
  @slice_rows 75
  @windowed ~w(turn-item message node)
  @waiting ~w(pending ready)

  @doc "The newest user turns of a thread, with what the user can act on."
  @spec snapshot(StreamState.t()) :: map
  def snapshot(state) do
    {windowed, cursor} = take(state, nil, @snapshot_turns)
    queued = for run <- StreamState.list(state, "run"), run["status"] == "queued", do: run["id"]

    small =
      for {kind, _} <- state.entities,
          kind not in @windowed,
          {_kind, id, entity} <- Enum.to_list(StreamState.rows(state, kinds: [kind])),
          do: {kind, id, compact(kind, entity)}

    windowed = windowed ++ queued_rows(state, queued, windowed)
    pending = pending_rows(state, windowed)

    held =
      Enum.map(small, &{actionable?(&1), &1}) ++
        Enum.map(windowed, &{queued_message?(&1, queued), &1}) ++
        Enum.map(pending, &{true, &1})

    # Encoded once: the rows sent, and the size of what the user can act on as sent, so
    # what the wire leaves out (a handoff's history) does not count.
    encoded = for {keep?, row} <- held, do: {keep?, hd(encode([row]))}

    size =
      for({true, [_, _, entity]} <- encoded, do: byte_size(JSON.encode!(entity))) |> Enum.sum()

    %{
      "rows" => Enum.map(encoded, &elem(&1, 1)),
      "cursor" => cursor,
      "offset" => state.seq,
      "overBudget" => size > @budget,
      "runlessHistory" => runless?(state)
    }
  end

  @doc "The user turns before `cursor`, or the error of a cursor this MC did not give."
  @spec page(StreamState.t(), term) :: {:ok, map} | {:error, map}
  def page(state, cursor) do
    with {:ok, before} <- decode(cursor) do
      {rows, next} =
        case before do
          {:run, ordinal} -> take(state, ordinal, @page_turns)
          {:intra, ordinal, run_id, index} -> intra(state, ordinal, run_id, index)
          {:runless, index} -> runless_page(state, index)
        end

      {:ok,
       %{
         "rows" => encode(rows),
         "cursor" => next,
         "offset" => state.seq,
         "overBudget" => false,
         "runlessHistory" => runless?(state)
       }}
    end
  end

  # Windowed rows newest-run first up to `turns` user turns or the cap, in creation
  # order, and the cursor of what lies before them (nil at the start of the history).
  # A run over the split limit contributes only its newest slice and ends the page.
  defp take(state, before, turns) do
    shown = shown_runs(state, before)

    {taken, _rest, _count, intra} =
      Enum.reduce_while(shown, {[], shown, 0, nil}, fn run, {taken, [_ | rest], count, _} ->
        rows = Enum.to_list(StreamState.run_rows(state, [run["id"]]))

        if length(rows) > @split_rows do
          slice = newest_slice(rows)
          {:halt, {[{run, slice} | taken], rest, count, length(rows) - length(slice)}}
        else
          count = if user_turn?(run), do: count + 1, else: count
          acc = {[{run, rows} | taken], rest, count, nil}

          if count >= turns or length(taken) + 1 >= @max_runs,
            do: {:halt, acc},
            else: {:cont, acc}
        end
      end)

    case taken do
      [] ->
        # No run page here: what remains, if anything, is history with no runs.
        case runless_rows(state) do
          [] -> {[], nil}
          rows -> runless_slice(rows, length(rows))
        end

      [{oldest, _} | _] ->
        rows = taken |> Enum.reverse() |> Enum.flat_map(&elem(&1, 1))

        cursor =
          cond do
            intra != nil -> encode_intra(oldest, intra)
            # Runless rows follow the last run page, reached with this same cursor.
            older?(state, oldest) -> encode_cursor(oldest)
            true -> nil
          end

        {rows, cursor}
    end
  end

  # Whether any history lies before `run`: an older shown run, or runless rows.
  defp older?(state, run) do
    shown_runs(state, run["ordinal"] || 0) != [] or runless?(state)
  end

  defp shown_runs(state, before) do
    runs =
      for run <- StreamState.list(state, "run"),
          shown?(run),
          before == nil or (run["ordinal"] || 0) < before,
          do: run

    Enum.sort_by(runs, &(&1["ordinal"] || 0), :desc)
  end

  # The slice of a split run before `index` of its rows. A run that has since left
  # the timeline resumes from where it was: the runs older than it.
  defp intra(state, ordinal, run_id, index) do
    case StreamState.get(state, "run")[run_id] do
      %{} = run ->
        if shown?(run) do
          rows = Enum.to_list(StreamState.run_rows(state, [run_id]))
          {slice, start} = slice_before(rows, index)

          next =
            cond do
              start > 0 -> encode_intra(run, start)
              older?(state, run) -> encode_cursor(run)
              true -> nil
            end

          {slice, next}
        else
          take(state, ordinal, @page_turns)
        end

      _ ->
        take(state, ordinal, @page_turns)
    end
  end

  defp runless_page(state, index), do: runless_slice(runless_rows(state), index)

  defp runless_slice(rows, index) do
    {slice, start} = slice_before(rows, index)
    {slice, if(start > 0, do: encode_runless(start))}
  end

  # The rows of no run, in creation order.
  defp runless_rows(state) do
    for {kind, id, entity} <- StreamState.rows(state, kinds: @windowed),
        entity["runId"] == nil,
        do: {kind, id, entity}
  end

  # The newest rows of `rows`: at most @slice_rows and within the budget as sent,
  # but always the newest one, however large it is alone.
  defp newest_slice(rows), do: elem(slice_before(rows, length(rows)), 0)

  defp slice_before(rows, index) do
    index = rows |> length() |> min(max(index, 0))

    {kept, _size} =
      rows
      |> Enum.slice(0, index)
      |> Enum.take(-@slice_rows)
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn row, {kept, size} ->
        size = size + row_size(row)

        if kept == [] or size <= @budget,
          do: {:cont, {[row | kept], size}},
          else: {:halt, {kept, size}}
      end)

    {kept, index - length(kept)}
  end

  defp row_size({kind, _id, entity}),
    do: entity |> then(&Wire.entity(kind, &1)) |> JSON.encode!() |> byte_size()

  # A rolled-back run no timeline shows, and a run cancelled before it started never was.
  defp shown?(%{"status" => status}) when status in ~w(rolled_back queued), do: false
  defp shown?(%{"status" => "cancelled", "startedAt" => nil}), do: false
  defp shown?(_run), do: true

  defp user_turn?(run), do: is_binary(run["userMessageId"])

  # The queued runs' windowed rows the taken runs do not already hold.
  defp queued_rows(state, queued, held) do
    have = MapSet.new(held, fn {kind, id, _} -> {kind, id} end)

    for row <- StreamState.run_rows(state, queued),
        not MapSet.member?(have, {elem(row, 0), elem(row, 1)}),
        do: row
  end

  defp queued_message?({"message", _, %{"runId" => run}}, queued), do: run in queued
  defp queued_message?(_row, _queued), do: false

  # The turn items and nodes carrying a pending runtime request (its questions, its
  # prompt), which the request row alone does not hold: found through the request's
  # node and that node's run, so a long thread is not scanned whole. A request whose
  # node is gone or runless falls back to naming its item directly.
  defp pending_rows(state, held) do
    pending =
      for request <- StreamState.list(state, "runtime-request"),
          request["status"] == "pending",
          do: request

    ids = MapSet.new(pending, & &1["id"])
    node_ids = MapSet.new(for r <- pending, is_binary(r["nodeId"]), do: r["nodeId"])
    nodes = StreamState.lookup(state, for(id <- node_ids, do: {"node", id}))
    runs = for {_, node} <- nodes, is_binary(node["runId"]), do: node["runId"]

    candidates =
      if runs == [] and pending != [] do
        StreamState.rows(state, kinds: @windowed)
      else
        StreamState.run_rows(state, runs)
      end

    have = MapSet.new(held, fn {kind, id, _} -> {kind, id} end)

    for {kind, id, entity} = row <- candidates,
        MapSet.member?(ids, entity["requestId"]) or
          MapSet.member?(ids, entity["runtimeRequestId"]) or
          (kind == "node" and MapSet.member?(node_ids, id)),
        not MapSet.member?(have, {kind, id}),
        do: row
  end

  # A handoff waits to be delivered while `pending` or `ready` (the MC writes `ready`,
  # then `consumed` or `failed`); a context transfer waits while `pending`.
  defp actionable?({"plan", _id, %{"status" => status}}), do: status == "active"
  defp actionable?({"context-handoff", _id, %{"status" => status}}), do: status in @waiting
  defp actionable?({"context-transfer", _id, %{"status" => status}}), do: status == "pending"
  defp actionable?({"runtime-request", _id, %{"status" => status}}), do: status == "pending"
  defp actionable?(_row), do: false

  # What is no longer actionable keeps its shape, as the contract decodes it, with its
  # bulky text blanked and `detailInTurnItem` saying the detail is in its timeline item.
  defp compact("plan", %{"status" => status} = plan) when status != "active" do
    plan
    |> Map.drop(["explanation"])
    |> then(&if(&1["kind"] == "proposed_plan", do: Map.put(&1, "markdown", ""), else: &1))
    |> Map.put("detailInTurnItem", true)
  end

  defp compact("context-handoff", %{"status" => status} = handoff) when status not in @waiting,
    do: handoff |> Map.put("summaryText", "") |> Map.put("detailInTurnItem", true)

  defp compact(_kind, entity), do: entity

  # Imported history keeps its messages and items outside any run; those rows are
  # paged by rows and size after the run pages, never silently complete.
  defp runless?(state) do
    Enum.any?(@windowed, fn kind ->
      state |> StreamState.get(kind) |> Enum.any?(fn {_id, entity} -> entity["runId"] == nil end)
    end)
  end

  defp encode(rows),
    do: for({kind, id, entity} <- rows, do: [kind, id, Wire.entity(kind, entity)])

  defp encode_cursor(run),
    do: Base.url_encode64("h1:#{run["ordinal"] || 0}:#{run["id"]}", padding: false)

  defp encode_intra(run, index),
    do: Base.url_encode64("h2:#{run["ordinal"] || 0}:#{index}:#{run["id"]}", padding: false)

  defp encode_runless(index), do: Base.url_encode64("h3:#{index}", padding: false)

  defp decode(cursor)
       when is_binary(cursor) and cursor != "" and byte_size(cursor) <= @max_cursor do
    with {:ok, text} <- Base.url_decode64(cursor, padding: false),
         {:ok, before} <- parse(text) do
      {:ok, before}
    else
      _ -> invalid()
    end
  end

  defp decode(_cursor), do: invalid()

  defp parse(text) do
    case String.split(text, ":", parts: 4) do
      ["h1", ordinal, _id] ->
        with {ordinal, ""} <- Integer.parse(ordinal), do: {:ok, {:run, ordinal}}

      ["h2", ordinal, index, id] ->
        with {ordinal, ""} <- Integer.parse(ordinal),
             {index, ""} <- Integer.parse(index),
             true <- index >= 0,
             do: {:ok, {:intra, ordinal, id, index}}

      ["h3", index] ->
        with {index, ""} <- Integer.parse(index), true <- index >= 0, do: {:ok, {:runless, index}}

      _ ->
        :error
    end
  end

  defp invalid,
    do: {:error, %{"_tag" => "InvalidHistoryCursor", "message" => "invalid history cursor"}}
end
