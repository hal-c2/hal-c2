defmodule HalC2.HistoryPropTest do
  @moduledoc """
  The laws `HalC2.Projection.History` promises over any mix of user runs, automatic
  runs, rolled-back runs and queued runs: following cursors from the snapshot visits
  every shown run exactly once, newest first, a page never splits a run, no page
  counts more than its user turns or runs, and a cursor still gives the same older
  runs after the thread gains runs. Pure folds, so plain `forall`s.
  """

  use ExUnit.Case, async: false
  use PropCheck

  alias HalC2.Projection.History
  alias HalC2.StreamState

  property "following cursors visits each shown run once, newest first, whole",
    numtests: HalC2.Prop.numtests(100),
    max_size: 60 do
    forall kinds <- list(oneof([:user, :user, :auto, :rolled_back, :queued])) do
      state = build(kinds)
      pages = walk(state, History.snapshot(state), [])
      visited = Enum.flat_map(pages, &run_numbers/1)

      Enum.sort(visited) == shown(kinds) and visited == Enum.uniq(visited) and
        newest_first?(pages) and Enum.all?(pages, &whole?/1)
    end
  end

  property "a cursor keeps giving the same older runs while the thread grows",
    numtests: HalC2.Prop.numtests(100),
    max_size: 60 do
    forall {kinds, more} <- {list(oneof([:user, :auto])), list(oneof([:user, :auto]))} do
      state = build(kinds)
      grown = build(kinds ++ more)

      case History.snapshot(state)["cursor"] do
        nil ->
          true

        cursor ->
          {:ok, before} = History.page(state, cursor)
          {:ok, later} = History.page(grown, cursor)
          before == Map.put(later, "offset", before["offset"])
      end
    end
  end

  property "a page holds at most its user turns and its cap of runs",
    numtests: HalC2.Prop.numtests(100),
    max_size: 400 do
    forall kinds <- list(oneof([:user, :auto, :auto])) do
      state = build(kinds)
      [first | rest] = walk(state, History.snapshot(state), [])

      Enum.all?([{10, first} | Enum.map(rest, &{20, &1})], fn {limit, rows} ->
        user_count(rows) <= limit and runs(rows) <= 150
      end)
    end
  end

  defp build(kinds) do
    kinds
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {kind, n} -> entities(kind, n) end)
    |> Enum.reduce(StreamState.new(), fn {kind, id, entity}, state ->
      StreamState.apply_event(state, %{
        seq: state.seq + 1,
        kind: kind,
        entity: id,
        patch: %{"s" => entity},
        at: 0
      })
    end)
  end

  defp entities(kind, n) do
    status = %{user: "completed", auto: "completed", rolled_back: "rolled_back", queued: "queued"}
    run = %{"id" => "run-#{n}", "ordinal" => n, "status" => status[kind]}
    run = if kind in [:user, :queued], do: Map.put(run, "userMessageId", "msg-#{n}"), else: run
    item = %{"id" => "item-#{n}", "runId" => run["id"], "type" => "reasoning"}
    steer = %{"id" => "steer-#{n}", "runId" => run["id"], "role" => "user"}
    message = %{"id" => "msg-#{n}", "runId" => run["id"], "role" => "user"}

    # A queued run holds its message alone (the snapshot carries that, whatever its age).
    case kind do
      :queued ->
        [{"run", run["id"], run}, {"message", message["id"], message}]

      _ ->
        [
          {"run", run["id"], run},
          {"turn-item", item["id"], item},
          {"message", steer["id"], steer}
        ] ++ if(kind == :user, do: [{"message", message["id"], message}], else: [])
    end
  end

  defp shown(kinds),
    do: for({kind, n} <- Enum.with_index(kinds, 1), kind in [:user, :auto], do: n)

  # Each page after the snapshot is a whole page of runs older than the last.
  defp walk(state, page, acc) do
    acc = acc ++ [page["rows"]]

    case page["cursor"] do
      nil ->
        acc

      cursor ->
        {:ok, next} = History.page(state, cursor)
        walk(state, next, acc)
    end
  end

  defp run_numbers(rows),
    do: for([kind, "item-" <> n, _] <- rows, kind == "turn-item", do: String.to_integer(n))

  defp newest_first?(pages) do
    pages
    |> Enum.map(&run_numbers/1)
    |> Enum.reject(&(&1 == []))
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [newer, older] -> Enum.max(older) < Enum.min(newer) end)
  end

  # A run's steering message comes with its items, or neither does.
  defp whole?(rows) do
    items = run_numbers(rows)
    steers = for ["message", "steer-" <> n, _] <- rows, do: String.to_integer(n)
    Enum.sort(items) == Enum.sort(steers)
  end

  defp user_count(rows),
    do:
      Enum.count(rows, fn [kind, id, _] ->
        kind == "message" and String.starts_with?(id, "msg-")
      end)

  defp runs(rows), do: rows |> Enum.filter(&(hd(&1) == "turn-item")) |> length()
end
