defmodule HalC2.HistoryPropTest do
  @moduledoc """
  The laws of `HalC2.Projection.History`: paging back from a bounded snapshot
  covers the visible timeline exactly once and in order, a page holds whole
  turns within its turn limits, a cursor survives the thread growing, and
  history with no turn starts stays within its item and size budgets. The
  module is pure, so these are plain `forall`s over generated timelines.
  """

  use ExUnit.Case, async: true
  use PropCheck

  alias HalC2.Projection.{History, Timeline}
  alias HalC2.StreamState

  # A timeline of turns: each is how many ordinary items follow its opening
  # message, how many steering messages it carries, and who started it.
  defp turn_spec,
    do: {resize(5, non_neg_integer()), resize(2, non_neg_integer()), oneof(["user", "agent"])}

  defp timeline, do: resize(30, list(turn_spec()))

  defp state(turns) do
    entities =
      [{"thread", %{"id" => "thread-1", "title" => "Thread"}}] ++
        Enum.flat_map(Enum.with_index(turns, 1), fn {{items, steers, by}, n} ->
          run_id = "run-#{n}"

          [
            {"run",
             %{"id" => run_id, "threadId" => "thread-1", "ordinal" => n, "status" => "completed"}}
          ] ++
            [
              item("u-#{n}", run_id, "user_message", %{
                "inputIntent" => "turn_start",
                "createdBy" => by
              })
            ] ++
            for(i <- 1..items//1, do: item("a-#{n}-#{i}", run_id, "assistant_message")) ++
            for(
              i <- 1..steers//1,
              do:
                item("s-#{n}-#{i}", run_id, "user_message", %{
                  "inputIntent" => "steer",
                  "createdBy" => "user"
                })
            )
        end)

    fold(entities)
  end

  defp fold(entities) do
    entities
    |> Enum.with_index(1)
    |> Enum.reduce(StreamState.new(), fn {{kind, entity}, seq}, state ->
      StreamState.apply_event(state, %{
        seq: seq,
        kind: kind,
        entity: entity["id"],
        patch: %{"s" => entity},
        at: 1_788_256_800_000 + seq * 1000
      })
    end)
  end

  defp item(id, run_id, type, extra \\ %{}) do
    {"turn-item",
     Map.merge(
       %{
         "id" => id,
         "threadId" => "thread-1",
         "runId" => run_id,
         "type" => type,
         "status" => "completed"
       },
       extra
     )}
  end

  defp ids(%{rows: rows}), do: for(["turn-item", id, _] <- rows, do: id)
  defp items_of(%{rows: rows}), do: for(["turn-item", _, entity] <- rows, do: entity)

  # Every page from the bounded snapshot back to the start, newest first.
  defp pages(state) do
    first = History.bounded(state)
    collect_pages(state, first, [first])
  end

  defp collect_pages(_state, %{has_more: false}, acc), do: acc

  defp collect_pages(state, %{cursor: cursor}, acc) do
    {:ok, page} = History.page_before(state, cursor)
    collect_pages(state, page, acc ++ [page])
  end

  property "paging back covers the visible timeline exactly once, in order",
    numtests: HalC2.Prop.numtests(100) do
    forall turns <- timeline() do
      state = state(turns)
      covered = state |> pages() |> Enum.reverse() |> Enum.flat_map(&ids/1)
      visible = Enum.map(Timeline.local_items(state), & &1["id"])
      covered == visible
    end
  end

  property "a page holds whole turns within its limits",
    numtests: HalC2.Prop.numtests(100) do
    forall turns <- timeline() do
      state = state(turns)
      [first | rest] = pages(state)
      visible = Timeline.local_items(state)
      first_id = visible |> List.first(%{}) |> Map.get("id")

      whole? = fn page, user_limit ->
        page_items = items_of(page)

        (page_items == [] or hd(page_items)["id"] == first_id or
           History.turn_start?(hd(page_items))) and
          Enum.count(page_items, &History.user_turn?/1) <= user_limit and
          Enum.count(page_items, &History.turn_start?/1) <= 150
      end

      whole?.(first, 10) and Enum.all?(rest, &whole?.(&1, 20))
    end
  end

  property "a cursor gives the same page after the thread grows",
    numtests: HalC2.Prop.numtests(100) do
    forall {turns, more} <- {timeline(), timeline()} do
      state = state(turns)

      case History.bounded(state) do
        %{cursor: nil} ->
          true

        %{cursor: cursor} ->
          {:ok, before_page} = History.page_before(state, cursor)

          grown =
            fold(
              Enum.flat_map(Enum.with_index(more, length(turns) + 1), fn {{items, _s, by}, n} ->
                run_id = "run-x#{n}"

                [
                  {"run",
                   %{
                     "id" => run_id,
                     "threadId" => "thread-1",
                     "ordinal" => 1_000 + n,
                     "status" => "completed"
                   }},
                  item("x-#{n}", run_id, "user_message", %{
                    "inputIntent" => "turn_start",
                    "createdBy" => by
                  })
                ] ++
                  for(i <- 1..items//1, do: item("xa-#{n}-#{i}", run_id, "assistant_message"))
              end)
            )

          grown =
            Enum.reduce(
              StreamState.rows(grown),
              state,
              fn {kind, id, entity}, acc ->
                StreamState.apply_event(acc, %{
                  seq: acc.seq + 1,
                  kind: kind,
                  entity: id,
                  patch: %{"s" => entity},
                  at: 1_788_256_900_000 + acc.seq
                })
              end
            )

          {:ok, after_page} = History.page_before(grown, cursor)
          ids(before_page) == ids(after_page)
      end
    end
  end

  property "history with no turn starts stays within its item and size budgets",
    numtests: HalC2.Prop.numtests(100) do
    forall sizes <- resize(40, list(resize(50, non_neg_integer()))) do
      items =
        Enum.map(Enum.with_index(sizes, 1), fn {size, n} ->
          item("i-#{n}", "run-1", "assistant_message", %{
            "text" => String.duplicate("x", size * 1_000)
          })
        end)

      entities =
        [
          {"thread", %{"id" => "thread-1", "title" => "Thread"}},
          {"run",
           %{"id" => "run-1", "threadId" => "thread-1", "ordinal" => 1, "status" => "completed"}}
        ] ++ items

      state = fold(entities)

      Enum.all?(pages(state), fn page ->
        page_items = items_of(page)
        encoded = Enum.sum_by(page_items, &(JSON.encode!(&1) |> byte_size()))
        length(page_items) <= 75 and (length(page_items) <= 1 or encoded <= 1_048_576)
      end)
    end
  end

  property "cursors round-trip", numtests: HalC2.Prop.numtests(100) do
    forall {seq, position} <- {non_neg_integer(), non_neg_integer()} do
      cursor = History.encode_cursor(seq, "thread-1", "item-1", position)

      History.decode_cursor(cursor) ==
        {:ok, %{"v" => 1, "seq" => seq, "st" => "thread-1", "si" => "item-1", "p" => position}}
    end
  end
end
