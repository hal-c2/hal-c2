defmodule HalC2.RollbackForksPropTest do
  @moduledoc """
  The law `HalC2.Orchestration.Rollback.reopened_forks/3` promises, for any
  context transfers and any set of rolled-back runs: a rewind that leaves the
  provider no conversation gives back exactly the fork transfers a rolled-back
  run consumed as a native fork, and a rewind that keeps a conversation gives
  back none. A plain `forall`: the selection is pure over the thread's state.
  """

  use ExUnit.Case, async: true
  use PropCheck

  alias HalC2.Orchestration.Rollback
  alias HalC2.StreamState

  @runs ~w(run-1 run-2 run-3)

  property "only natively consumed forks of rolled-back runs reopen, and only with no conversation left",
    numtests: HalC2.Prop.numtests(200) do
    forall {transfers, rolled, cleared} <-
             {list(transfer()), list(oneof(@runs)), boolean()} do
      transfers =
        transfers |> Enum.with_index(1) |> Enum.map(fn {t, i} -> Map.put(t, "id", "ct-#{i}") end)

      rolled = MapSet.new(rolled)

      patch =
        if cleared, do: %{"nativeThreadRef" => nil}, else: %{"nativeConversationHeadRef" => %{}}

      expected =
        for t <- transfers,
            cleared,
            t["type"] == "fork" and t["status"] == "consumed",
            get_in(t, ["resolution", "strategy"]) == "native_fork",
            MapSet.member?(rolled, t["targetRunId"]),
            do: t["id"]

      Enum.sort(Rollback.reopened_forks(state(transfers), rolled, patch)) == Enum.sort(expected)
    end
  end

  defp transfer do
    let {type, status, strategy, run} <-
          {oneof(["fork", "merge_back"]), oneof(["pending", "consumed", "failed"]),
           oneof(["native_fork", "portable_context", nil]), oneof([nil | @runs])} do
      %{
        "type" => type,
        "status" => status,
        "resolution" => strategy && %{"strategy" => strategy},
        "targetRunId" => run
      }
    end
  end

  defp state(transfers) do
    transfers
    |> Enum.with_index(1)
    |> Enum.reduce(StreamState.new(), fn {t, seq}, state ->
      StreamState.apply_event(state, %{
        seq: seq,
        kind: "context-transfer",
        entity: t["id"],
        patch: %{"s" => t}
      })
    end)
  end
end
