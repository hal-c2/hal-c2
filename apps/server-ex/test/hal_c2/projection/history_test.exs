defmodule HalC2.Projection.HistoryTest do
  use ExUnit.Case, async: true

  alias HalC2.Projection.History
  alias HalC2.StreamState

  # Required fields of `OrchestrationV2ContextHandoff` and the plan schemas in
  # packages/contracts/src/orchestrationV2.ts: a compacted row must still decode.
  @handoff ~w(id status targetRunId fromProviderThreadIds toProviderThreadId
              coveredRunOrdinals strategy summaryMessageId summaryText
              createdByProviderInstanceId)

  defp state(rows) do
    rows
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

  defp row(snapshot, id), do: hd(for [_, ^id, entity] <- snapshot["rows"], do: entity)

  defp handoff(status) do
    base = for key <- @handoff, into: %{}, do: {key, "x"}
    Map.merge(base, %{"id" => "h-#{status}", "status" => status, "history" => [%{}]})
  end

  test "a finished plan and handoff keep their contract fields, blank their text" do
    plan = %{
      "id" => "plan-1",
      "nodeId" => "n",
      "kind" => "proposed_plan",
      "status" => "completed",
      "markdown" => "# text"
    }

    snapshot =
      History.snapshot(
        state([{"plan", "plan-1", plan}, {"context-handoff", "h-failed", handoff("failed")}])
      )

    compact = row(snapshot, "plan-1")
    assert compact["nodeId"] == "n"
    assert compact["markdown"] == ""
    assert compact["detailInTurnItem"] == true
    refute Map.has_key?(compact, "detailInTimeline")

    done = row(snapshot, "h-failed")
    for key <- @handoff -- ["summaryText"], do: assert(Map.has_key?(done, key), key)
    assert done["summaryText"] == ""
    assert done["detailInTurnItem"] == true
    refute Map.has_key?(done, "runId")
  end

  test "a ready handoff is not compacted" do
    snapshot = History.snapshot(state([{"context-handoff", "h-ready", handoff("ready")}]))
    refute Map.has_key?(row(snapshot, "h-ready"), "detailInTurnItem")
  end

  test "rows with no run mark the history as runless" do
    item = %{"id" => "i-1", "runId" => nil, "type" => "reasoning"}
    assert History.snapshot(state([{"turn-item", "i-1", item}]))["runlessHistory"] == true
    assert History.snapshot(state([]))["runlessHistory"] == false
  end

  defp run(n, items) do
    run = %{
      "id" => "run-#{n}",
      "ordinal" => n,
      "status" => "completed",
      "userMessageId" => "m-#{n}"
    }

    [{"run", run["id"], run}] ++
      for i <- 1..items do
        item = %{
          "id" => "i-#{n}-#{i}",
          "runId" => run["id"],
          "type" => "reasoning",
          "ordinal" => i
        }

        {"turn-item", item["id"], item}
      end
  end

  defp item_ids(page), do: for(["turn-item", id, _] <- page["rows"], do: id)

  test "a turn longer than 500 rows is paged within itself, newest first" do
    state = state(run(1, 900))
    snapshot = History.snapshot(state)
    ids = item_ids(snapshot)
    assert length(ids) <= 75
    assert List.last(ids) == "i-1-900"
    assert is_binary(snapshot["cursor"])

    {:ok, page} = History.page(state, snapshot["cursor"])
    page_ids = item_ids(page)
    assert length(page_ids) <= 75
    assert List.last(page_ids) == List.first(ids) |> then(&"i-1-#{item_n(&1) - 1}")
    assert MapSet.disjoint?(MapSet.new(ids), MapSet.new(page_ids))
  end

  test "an ordinary turn of 400 rows stays whole" do
    snapshot = History.snapshot(state(run(1, 400)))
    assert length(item_ids(snapshot)) == 400
    assert snapshot["cursor"] == nil
  end

  test "history with no runs is paged by rows, at least one however large" do
    big = %{
      "id" => "big",
      "runId" => nil,
      "type" => "reasoning",
      "text" => String.duplicate("x", 1_200_000)
    }

    rows =
      for i <- 1..200 do
        item = %{"id" => "r-#{i}", "runId" => nil, "type" => "reasoning", "ordinal" => i}
        {"turn-item", item["id"], item}
      end ++ [{"turn-item", "big", big}]

    state = state(rows)
    snapshot = History.snapshot(state)
    ids = item_ids(snapshot)
    assert ids == ["big"]
    assert is_binary(snapshot["cursor"])

    {:ok, page} = History.page(state, snapshot["cursor"])
    assert length(item_ids(page)) == 75
    assert List.last(item_ids(page)) == "r-200"
  end

  test "a pending question older than the newest turns is carried with its item" do
    request = %{
      "id" => "req-1",
      "nodeId" => "node-q",
      "kind" => "user_input",
      "status" => "pending"
    }

    node = %{"id" => "node-q", "runId" => "run-1", "runtimeRequestId" => "req-1"}

    item = %{
      "id" => "q-1",
      "runId" => "run-1",
      "type" => "user_input_request",
      "requestId" => "req-1",
      "questions" => [%{"id" => "a"}]
    }

    rows =
      run(1, 1) ++
        [
          {"runtime-request", "req-1", request},
          {"node", "node-q", node},
          {"turn-item", "q-1", item}
        ] ++
        Enum.flat_map(2..30, &run(&1, 1))

    snapshot = History.snapshot(state(rows))
    assert row(snapshot, "q-1")["questions"] == [%{"id" => "a"}]
    assert row(snapshot, "node-q")

    resolved = Map.put(request, "status", "resolved")

    snapshot =
      History.snapshot(
        state([{"runtime-request", "req-1", resolved} | rows] |> Enum.uniq_by(&elem(&1, 1)))
      )

    refute Enum.any?(snapshot["rows"], &match?(["turn-item", "q-1", _], &1))
  end

  defp item_n("i-1-" <> n), do: String.to_integer(n)

  test "overBudget measures what is sent, not the history the wire drops" do
    big = Map.put(handoff("ready"), "history", [%{"text" => String.duplicate("x", 1_200_000)}])
    snapshot = History.snapshot(state([{"context-handoff", "h-ready", big}]))
    assert snapshot["overBudget"] == false
    refute Map.has_key?(row(snapshot, "h-ready"), "history")
  end
end
