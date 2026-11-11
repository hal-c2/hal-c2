defmodule HalC2.Orchestration.SelectionTest do
  use ExUnit.Case, async: true

  alias HalC2.{Patch, StreamState}
  alias HalC2.Orchestration.Selection

  @codex %{"instanceId" => "codex", "model" => "gpt-5.4"}
  @other %{"instanceId" => "codex", "model" => "gpt-5.5"}

  defp state(entities) do
    entities
    |> Enum.with_index(1)
    |> Enum.reduce(StreamState.new(), fn {{kind, id, entity}, seq}, state ->
      StreamState.apply_event(state, %{
        seq: seq,
        kind: kind,
        entity: id,
        patch: Patch.diff(nil, entity)
      })
    end)
  end

  defp thread(fields \\ %{}) do
    Map.merge(
      %{
        "id" => "t1",
        "modelSelection" => @codex,
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "selectionRevision" => 3
      },
      fields
    )
  end

  defp set(fields), do: {"thread", "t1", %{"s" => fields}}

  defp revision_after(changes) do
    Enum.find_value(Enum.reverse(changes), fn
      {"thread", "t1", %{"s" => %{"selectionRevision" => rev}}} -> rev
      _ -> nil
    end)
  end

  describe "stamp/2" do
    test "a change to what the thread runs on moves the revision on by one" do
      state = state([{"thread", "t1", thread()}])

      for change <- [
            %{"modelSelection" => @other},
            %{"runtimeMode" => "approval-required"},
            %{"interactionMode" => "plan"},
            %{"providerInstanceId" => "claudeAgent"}
          ] do
        assert state |> Selection.stamp([set(change)]) |> revision_after() == 4
        assert Selection.moved(state, "t1", [set(change)]) == 4
      end
    end

    test "a change to anything else leaves the revision and names no move" do
      state = state([{"thread", "t1", thread()}])
      changes = [set(%{"title" => "Renamed"})]
      assert Selection.stamp(state, changes) == changes
      assert Selection.moved(state, "t1", changes) == nil
    end

    test "a thread brought from elsewhere keeps its counter, which never goes backwards" do
      created = [{"thread", "t1", Patch.diff(nil, thread())}]
      assert Selection.stamp(StreamState.new(), created) == created

      state = state([{"thread", "t1", thread()}])
      lower = [set(%{"selectionRevision" => 1})]
      assert state |> Selection.stamp(lower) |> revision_after() == 3

      higher = [set(%{"modelSelection" => @other, "selectionRevision" => 9})]
      assert state |> Selection.stamp(higher) |> revision_after() == 9
    end

    test "queued runs follow a change, picked or not, unless it is a queued run's own pick" do
      run = fn id, picked ->
        {"run", id,
         %{
           "id" => id,
           "threadId" => "t1",
           "status" => "queued",
           "modelSelection" => @codex,
           "providerInstanceId" => "codex",
           "selectionPicked" => picked
         }}
      end

      unflagged =
        {"run", "r3",
         %{"id" => "r3", "threadId" => "t1", "status" => "queued", "modelSelection" => @codex}}

      state = state([{"thread", "t1", thread()}, run.("r1", true), run.("r2", false), unflagged])

      followed =
        for {"run", id, %{"s" => %{"modelSelection" => @other} = s}} <-
              Selection.stamp(state, [set(%{"modelSelection" => @other})]),
            do: {id, s["selectionPicked"]}

      # The MC's own runs (no flag) are left alone.
      # (r2 was unpicked already, so its patch leaves the flag out.)
      assert Enum.sort(followed) == [{"r1", false}, {"r2", nil}]

      # r1 starting on its own pick: r2, queued behind it, follows; nothing else changes.
      taken = [
        set(%{"modelSelection" => @other}),
        {"run", "r1", %{"s" => %{"status" => "running"}}}
      ]

      assert for(
               {"run", id, %{"s" => %{"modelSelection" => _}}} <- Selection.stamp(state, taken),
               do: id
             ) == ["r2"]
    end
  end

  describe "stale/2" do
    test "a pick made against the thread's revision is taken" do
      assert Selection.stale(%{"selectionBase" => 3, "modelSelection" => @other}, thread()) == nil
    end

    test "a command without a base is taken as before" do
      assert Selection.stale(%{"modelSelection" => @other}, thread()) == nil
    end

    test "a pick against an older revision that the thread already has is taken" do
      picked = %{"selectionBase" => 1, "modelSelection" => Map.put(@codex, "options", [])}
      assert Selection.stale(picked, thread()) == nil
    end

    test "a pick against an older revision is refused, naming what the thread has" do
      assert {:error, refusal} =
               Selection.stale(%{"selectionBase" => 1, "modelSelection" => @other}, thread())

      assert refusal == %{
               "code" => "selection-stale",
               "message" =>
                 "This thread moved to gpt-5.4 on Codex elsewhere. Check it and send again.",
               "selectionRevision" => 3,
               "modelSelection" => @codex
             }

      assert {:error, _} =
               Selection.stale(%{"selectionBase" => 1, "runtimeMode" => "auto"}, thread())
    end
  end

  test "same_selection?/2 compares instance, model and options in any order" do
    a = Map.put(@codex, "options", [%{"id" => "effort", "value" => "high"}, %{"id" => "fast"}])
    b = Map.put(@codex, "options", [%{"id" => "fast"}, %{"id" => "effort", "value" => "high"}])
    assert Selection.same_selection?(a, b)
    assert Selection.same_selection?(@codex, Map.put(@codex, "options", []))
    refute Selection.same_selection?(@codex, @other)
    refute Selection.same_selection?(@codex, %{"instanceId" => "codex_2", "model" => "gpt-5.4"})
  end
end
