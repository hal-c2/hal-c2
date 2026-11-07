defmodule HalC2.HistoryPropTest do
  @moduledoc """
  The laws `HalC2.Projection.History` promises over any mix of user runs, automatic
  runs, rolled-back runs and queued runs: following cursors from the snapshot visits
  every shown run exactly once, newest first, a page never splits a run, no page
  counts more than its user turns or runs, and a cursor still gives the same older
  runs after the thread gains runs. A run past the split limit is the exception that
  is paged within itself: its slices still visit every item exactly once, newest
  slice first, at most 75 rows at a time. Rows with no run are visited last, also
  exactly once. A pending question's item is in the snapshot however old it is.
  Pure folds, so plain `forall`s.
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

  property "split turns and runless rows are visited exactly once, slices bounded",
    numtests: HalC2.Prop.numtests(30),
    max_size: 12 do
    forall {specs, runless} <-
             {list({oneof([:user, :auto]), oneof([1, 3, 600])}), integer(0, 160)} do
      state = build_sized(specs, runless)
      pages = walk(state, History.snapshot(state), [])
      visited = for rows <- pages, ["turn-item", id, _] <- rows, do: id

      expected =
        for {{_kind, count}, n} <- Enum.with_index(specs, 1),
            i <- 1..count//1,
            do: "item-#{n}-#{i}"

      runless_ids = for i <- 1..runless//1, do: "old-#{i}"

      counts = Map.new(Enum.with_index(specs, 1), fn {{_, count}, n} -> {"run-#{n}", count} end)

      # Runless rows come after every run row, and a page that holds a split
      # slice holds at most 75 items of that run.
      Enum.sort(visited) == Enum.sort(expected ++ runless_ids) and
        visited == Enum.uniq(visited) and
        runless_last?(visited, runless_ids) and
        Enum.all?(pages, &slice_bounded?(&1, counts))
    end
  end

  property "a pending question's item is in the snapshot however many turns follow",
    numtests: HalC2.Prop.numtests(30),
    max_size: 40 do
    forall later <- integer(0, 40) do
      request = %{
        "id" => "req-q",
        "nodeId" => "node-q",
        "kind" => "user_input",
        "status" => "pending"
      }

      node = %{"id" => "node-q", "runId" => "run-1", "runtimeRequestId" => "req-q"}

      item = %{
        "id" => "q-1",
        "runId" => "run-1",
        "type" => "user_input_request",
        "requestId" => "req-q"
      }

      rows =
        entities(:user, 1) ++
          [
            {"runtime-request", "req-q", request},
            {"node", "node-q", node},
            {"turn-item", "q-1", item}
          ] ++
          Enum.flat_map(List.duplicate(:user, later) |> Enum.with_index(2), fn {kind, n} ->
            entities(kind, n)
          end)

      state =
        Enum.reduce(rows, StreamState.new(), fn {kind, id, entity}, state ->
          StreamState.apply_event(state, %{
            seq: state.seq + 1,
            kind: kind,
            entity: id,
            patch: %{"s" => entity},
            at: 0
          })
        end)

      Enum.any?(History.snapshot(state)["rows"], &match?(["turn-item", "q-1", _], &1))
    end
  end

  defp runless_last?(_visited, []), do: true

  defp runless_last?(visited, runless_ids) do
    set = MapSet.new(runless_ids)
    {_runs, rest} = Enum.split_while(visited, &(not MapSet.member?(set, &1)))
    Enum.all?(rest, &MapSet.member?(set, &1))
  end

  # A split run (over 500 items) and the runless rows may appear in a page with at
  # most 75 items at a time; only a run at or under the limit may appear with more.
  defp slice_bounded?(rows, counts) do
    rows
    |> Enum.filter(&match?(["turn-item", _, _], &1))
    |> Enum.group_by(fn [_, _, entity] -> entity["runId"] end)
    |> Enum.all?(fn {run, items} ->
      length(items) <= 75 or (run != nil and Map.get(counts, run, 0) <= 500)
    end)
  end

  defp build_sized(specs, runless) do
    rows =
      Enum.flat_map(Enum.with_index(specs, 1), fn {{kind, count}, n} ->
        run = %{"id" => "run-#{n}", "ordinal" => n, "status" => "completed"}
        run = if kind == :user, do: Map.put(run, "userMessageId", "msg-#{n}"), else: run

        [{"run", run["id"], run}] ++
          for i <- 1..count//1 do
            item = %{"id" => "item-#{n}-#{i}", "runId" => run["id"], "type" => "reasoning"}
            {"turn-item", item["id"], Map.put(item, "ordinal", n * 1000 + i)}
          end ++
          if kind == :user do
            [
              {"message", "msg-#{n}",
               %{"id" => "msg-#{n}", "runId" => run["id"], "role" => "user"}}
            ]
          else
            []
          end
      end) ++
        for i <- 1..runless//1 do
          item = %{"id" => "old-#{i}", "runId" => nil, "type" => "reasoning"}
          {"turn-item", item["id"], Map.put(item, "ordinal", i)}
        end

    Enum.reduce(rows, StreamState.new(), fn {kind, id, entity}, state ->
      StreamState.apply_event(state, %{
        seq: state.seq + 1,
        kind: kind,
        entity: id,
        patch: %{"s" => entity},
        at: 0
      })
    end)
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
