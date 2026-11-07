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

  test "overBudget measures what is sent, not the history the wire drops" do
    big = Map.put(handoff("ready"), "history", [%{"text" => String.duplicate("x", 1_200_000)}])
    snapshot = History.snapshot(state([{"context-handoff", "h-ready", big}]))
    assert snapshot["overBudget"] == false
    refute Map.has_key?(row(snapshot, "h-ready"), "history")
  end
end
