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

  The snapshot is the newest `#{10}` user turns, and a page the `#{20}` before a
  cursor. The cursor names the oldest run a page holds (its ordinal and id), so it
  stays valid while the thread grows and when that run later leaves the timeline:
  the next page is the runs with a lower ordinal. A cursor that does not decode to
  that is refused.

  The snapshot also carries everything the thread keeps small (the thread, runs,
  requests, plans, handoffs, checkpoints), so what the user can still act on is held
  whatever its age, plus the messages of queued runs. A plan or handoff that is no
  longer actionable keeps its shape but blanks its bulky text and sets
  `detailInTurnItem`: the text is in its turn item. A pending or ready handoff and a
  pending transfer count as actionable.

  Imported threads can hold rows with no run. They cannot be paged by run, so the
  result says `runlessHistory` instead of letting a nil cursor read as "complete".
  """

  alias HalC2.StreamState
  alias HalC2.Web.Wire

  @snapshot_turns 10
  @page_turns 20
  @max_runs 150
  @max_cursor 4_096
  @budget 1_000_000
  @windowed ~w(turn-item message node)
  @waiting ~w(pending ready)

  @doc "The newest user turns of a thread, with what the user can act on."
  @spec snapshot(StreamState.t()) :: map
  def snapshot(state) do
    {runs, cursor} = take(state, nil, @snapshot_turns)
    queued = for run <- StreamState.list(state, "run"), run["status"] == "queued", do: run["id"]

    small =
      for {kind, _} <- state.entities,
          kind not in @windowed,
          {_kind, id, entity} <- Enum.to_list(StreamState.rows(state, kinds: [kind])),
          do: {kind, id, compact(kind, entity)}

    windowed = windowed_rows(state, runs ++ queued)

    held =
      Enum.map(small, &{actionable?(&1), &1}) ++
        Enum.map(windowed, &{queued_message?(&1, queued), &1})

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
      {runs, next} = take(state, before, @page_turns)

      {:ok,
       %{
         "rows" => encode(windowed_rows(state, runs)),
         "cursor" => next,
         "offset" => state.seq,
         "overBudget" => false,
         "runlessHistory" => runless?(state)
       }}
    end
  end

  # Run ids newest first up to `turns` user turns or the cap, and the cursor of what
  # lies before them (nil at the start of the history).
  defp take(state, before, turns) do
    shown =
      for run <- StreamState.list(state, "run"),
          shown?(run),
          before == nil or (run["ordinal"] || 0) < before,
          do: run

    shown = Enum.sort_by(shown, &(&1["ordinal"] || 0), :desc)
    {taken, rest, _} = Enum.reduce_while(shown, {[], shown, 0}, &step(&1, &2, turns))

    cursor =
      case {taken, rest} do
        {[], _} -> nil
        {_, []} -> nil
        {[oldest | _], _} -> encode_cursor(oldest)
      end

    {Enum.reverse(Enum.map(taken, & &1["id"])), cursor}
  end

  defp step(run, {taken, [_ | rest], count}, turns) do
    count = if user_turn?(run), do: count + 1, else: count
    acc = {[run | taken], rest, count}
    if count >= turns or length(taken) + 1 >= @max_runs, do: {:halt, acc}, else: {:cont, acc}
  end

  # A rolled-back run no timeline shows, and a run cancelled before it started never was.
  defp shown?(%{"status" => status}) when status in ~w(rolled_back queued), do: false
  defp shown?(%{"status" => "cancelled", "startedAt" => nil}), do: false
  defp shown?(_run), do: true

  defp user_turn?(run), do: is_binary(run["userMessageId"])

  defp windowed_rows(state, runs) do
    for {kind, id, entity} <- StreamState.run_rows(state, runs), do: {kind, id, entity}
  end

  defp queued_message?({"message", _, %{"runId" => run}}, queued), do: run in queued
  defp queued_message?(_row, _queued), do: false

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

  # Imported history keeps its messages and items outside any run, which these pages
  # do not reach yet: a client is told, so a missing cursor is not read as the start.
  defp runless?(state) do
    Enum.any?(@windowed, fn kind ->
      state |> StreamState.get(kind) |> Enum.any?(fn {_id, entity} -> entity["runId"] == nil end)
    end)
  end

  defp encode(rows),
    do: for({kind, id, entity} <- rows, do: [kind, id, Wire.entity(kind, entity)])

  defp encode_cursor(run),
    do: Base.url_encode64("h1:#{run["ordinal"] || 0}:#{run["id"]}", padding: false)

  defp decode(cursor)
       when is_binary(cursor) and cursor != "" and byte_size(cursor) <= @max_cursor do
    with {:ok, text} <- Base.url_decode64(cursor, padding: false),
         ["h1", ordinal, _id] <- String.split(text, ":", parts: 3),
         {ordinal, ""} <- Integer.parse(ordinal) do
      {:ok, ordinal}
    else
      _ -> invalid()
    end
  end

  defp decode(_cursor), do: invalid()

  defp invalid,
    do: {:error, %{"_tag" => "InvalidHistoryCursor", "message" => "invalid history cursor"}}
end
