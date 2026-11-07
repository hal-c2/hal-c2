defmodule HalC2.RollbackForksPropTest do
  @moduledoc """
  The law `HalC2.Orchestration.Rollback.reopened_forks/3` promises: a rewind that
  leaves the provider no conversation gives back exactly the forks whose history a
  rolled-back run took over natively, and a rewind that keeps a conversation gives
  back none. A plain `forall`: the selection is pure over the thread's state.

  The model does not restate the rule's field checks. It generates what happened to
  each context transfer (a story: still pending, failed while a run tried it, taken
  over natively or as portable context by a run, a merge-back) and what the rewind
  left the provider, renders those into the entities and the provider-thread patch
  the MC would hold, and expects the reopened forks from the stories alone.
  """

  use ExUnit.Case, async: true
  use PropCheck

  alias HalC2.Orchestration.Rollback
  alias HalC2.StreamState

  @runs ~w(run-1 run-2 run-3)

  property "only forks a rolled-back run took over natively reopen, and only with no conversation left",
    numtests: HalC2.Prop.numtests(300) do
    forall {stories, rolled, rewind} <-
             {list(story()), list(oneof(@runs)), rewind()} do
      transfers =
        stories
        |> Enum.with_index(1)
        |> Enum.map(fn {story, i} -> {"ct-#{i}", story} end)

      rolled = MapSet.new(rolled)

      expected =
        for {id, {:fork, {:native, run}}} <- transfers,
            rewind == :no_conversation,
            run in rolled,
            do: id

      actual = Rollback.reopened_forks(state(transfers), rolled, patch(rewind))

      (Enum.sort(actual) == Enum.sort(expected))
      |> when_fail(IO.puts("stories #{inspect(transfers)}; expected #{inspect(expected)}"))
    end
  end

  # What happened to one transfer.
  defp story do
    run = oneof(@runs)

    oneof([
      {:fork, :pending},
      {:fork, {:failed, oneof([nil | @runs])}},
      {:fork, {:native, run}},
      {:fork, {:portable, run}},
      {:merge_back, {:native, run}},
      {:merge_back, {:portable, run}},
      {:merge_back, :pending}
    ])
  end

  # What the provider's rewind left of its conversation.
  defp rewind, do: oneof([:no_conversation, :kept_head, :kept_thread])

  # The provider-thread patch each outcome is written as.
  defp patch(:no_conversation),
    do: %{"nativeThreadRef" => nil, "nativeConversationHeadRef" => nil}

  defp patch(:kept_head), do: %{"nativeConversationHeadRef" => %{"nativeId" => "uuid-1"}}
  defp patch(:kept_thread), do: %{"nativeThreadRef" => %{"nativeId" => "session-1"}}

  # A transfer as the MC records it after its story.
  defp render({type, outcome}) do
    base = %{"type" => to_string(type), "createdAt" => "2026-11-01T00:00:00Z"}

    case outcome do
      :pending ->
        Map.put(base, "status", "pending")

      {:failed, run} ->
        Map.merge(base, %{
          "status" => "failed",
          "targetRunId" => run,
          "resolution" => %{"strategy" => "native_fork"}
        })

      {how, run} ->
        strategy = if how == :native, do: "native_fork", else: "portable_context"

        Map.merge(base, %{
          "status" => "consumed",
          "targetRunId" => run,
          "consumedAt" => "2026-11-01T00:01:00Z",
          "resolution" => %{"strategy" => strategy}
        })
    end
  end

  defp state(transfers) do
    transfers
    |> Enum.with_index(1)
    |> Enum.reduce(StreamState.new(), fn {{id, story}, seq}, state ->
      StreamState.apply_event(state, %{
        seq: seq,
        kind: "context-transfer",
        entity: id,
        patch: %{"s" => Map.put(render(story), "id", id)}
      })
    end)
  end
end
