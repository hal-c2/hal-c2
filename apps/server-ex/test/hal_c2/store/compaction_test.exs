defmodule HalC2.Store.CompactionTest do
  use ExUnit.Case, async: false

  alias HalC2.{Store, StreamState}
  alias HalC2.Store.Compaction

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "hal-c2.sqlite")
    start_supervised!({Store, path: path})
    %{path: path}
  end

  defp append(changes), do: {:ok, _} = Store.append([{:thread, "t1", changes}])
  defp at(change, at), do: Tuple.insert_at(change, 3, at)

  defp events(path), do: Store.reduce_stream(path, "t1", 0, [], &[&1 | &2]) |> Enum.reverse()

  defp fold(events), do: Enum.reduce(events, StreamState.new(), &StreamState.apply_event(&2, &1))

  defp view(state),
    do: Map.take(state, [:seq, :updated_at, :entities, :created, :changed, :deleted])

  # A client that had the log up to every offset, then read the compacted log after it.
  defp same_from_every_offset(before, path) do
    whole = view(fold(before))
    after_compaction = events(path)

    for offset <- [0 | Enum.map(before, & &1.seq)] do
      known = before |> Enum.take_while(&(&1.seq <= offset)) |> fold()

      resumed =
        after_compaction
        |> Enum.drop_while(&(&1.seq <= offset))
        |> Enum.reduce(known, &StreamState.apply_event(&2, &1))

      assert view(resumed) == whole, "resuming from #{offset}"
    end
  end

  test "a streamed message keeps its first and last event", %{path: path} do
    append([{"thread", "t1", %{"s" => %{"title" => "New"}}}])
    append([{"message", "m1", %{"s" => %{"text" => "", "streaming" => true}}}])
    for chunk <- ~w(a b c d), do: append([{"message", "m1", %{"a" => %{"text" => chunk}}}])
    append([{"message", "m1", %{"s" => %{"streaming" => false}}}])
    before = events(path)

    assert %{events: 4, rewritten: 1} = Compaction.run(Store, all: true)

    assert [_thread, %{seq: 2}, %{seq: 7, patch: patch}] = events(path)
    assert patch == %{"s" => %{"text" => "abcd", "streaming" => false}}
    same_from_every_offset(before, path)
  end

  test "a visit keeps the rename before it, and the time of that rename", %{path: path} do
    append([at({"thread", "t1", %{"s" => %{"title" => "New"}}}, 1_000)])
    append([at({"thread", "t1", %{"s" => %{"title" => "Draft"}}}, 2_000)])
    append([at({"thread", "t1", %{"s" => %{"title" => "Renamed"}}}, 3_000)])
    append([at({"thread", "t1", %{"s" => %{"lastVisitedAt" => 1}, "q" => true}}, 4_000)])
    append([at({"thread", "t1", %{"s" => %{"lastVisitedAt" => 2}, "q" => true}}, 5_000)])
    before = events(path)

    assert %{events: 2} = Compaction.run(Store, all: true)

    assert [%{seq: 1}, %{seq: 3, at: 3_000}, %{seq: 5, patch: %{"q" => true}}] = events(path)
    assert fold(events(path)).updated_at == 3_000
    same_from_every_offset(before, path)
  end

  test "creation, deletion and every other kind stay", %{path: path} do
    append([{"message", "m1", %{"s" => %{"text" => "a"}}}])
    append([{"message", "m1", %{"s" => %{"text" => "b"}}}])
    append([{"message", "m1", %{"d" => true}}])
    append([{"message", "m1", %{"s" => %{"text" => "again"}}}])
    append([{"turn-item", "i1", %{"s" => %{"text" => "a"}}}])
    append([{"turn-item", "i1", %{"s" => %{"text" => "b"}}}])
    append([{"run", "r1", %{"s" => %{"status" => "running"}}}])
    append([{"run", "r1", %{"s" => %{"status" => "completed"}}}])
    before = events(path)

    assert %{events: 0} = Compaction.run(Store, all: true)
    assert events(path) == before
  end

  test "a second run finds nothing, and a later one only the threads that changed",
       %{path: path} do
    for title <- ~w(a b c), do: append([{"thread", "t1", %{"s" => %{"title" => title}}}])

    assert %{streams: 1, events: 1} = Compaction.run(Store)
    assert %{streams: 0, events: 0} = Compaction.run(Store)
    assert Compaction.plan(path, "t1") == []
  end

  test "a thread still being imported is left alone", %{path: path} do
    for title <- ~w(a b c), do: append([{"thread", "t1", %{"s" => %{"title" => title}}}])
    :ok = Store.put_meta("import.thread.t1", "{}")

    assert %{events: 0} = Compaction.run(Store, all: true)
    assert length(events(path)) == 3
  end

  test "a thread skipped while it was imported is compacted once its import finishes",
       %{path: path} do
    for title <- ~w(a b c), do: append([{"thread", "t1", %{"s" => %{"title" => title}}}])
    :ok = Store.put_meta("import.thread.t1", "{}")
    assert %{events: 0} = Compaction.run(Store)

    # Other threads go on changing while the import waits, and later runs move past it.
    {:ok, last} = Store.append([{:thread, "t2", [{"thread", "t2", %{"s" => %{"title" => "x"}}}]}])
    assert %{events: 0} = Compaction.run(Store)
    assert Store.meta(path, "compaction.through") == Integer.to_string(last)

    :ok = Store.delete_meta("import.thread.t1")
    before = events(path)
    assert %{streams: 1, events: 1} = Compaction.run(Store)
    same_from_every_offset(before, path)
    assert Store.meta(path, "compaction.skipped") == "{}"
  end

  test "a later run reads only the entities changed since the last", %{path: path} do
    message = fn id -> %{"id" => id, "role" => "assistant", "text" => ""} end
    append([{"thread", "t1", %{"s" => %{"title" => "t"}}}])
    append([{"message", "m1", %{"s" => message.("m1")}}])
    for chunk <- ~w(a b c), do: append([{"message", "m1", %{"a" => %{"text" => chunk}}}])
    assert %{events: 2} = Compaction.run(Store)

    append([{"message", "m2", %{"s" => message.("m2")}}])
    for chunk <- ~w(d e f), do: append([{"message", "m2", %{"a" => %{"text" => chunk}}}])
    through = String.to_integer(Store.meta(path, "compaction.through"))
    planned = Compaction.plan(path, "t1", :infinity, since: through)
    assert length(planned) == 3

    entities =
      for op <- planned, do: Enum.find(events(path), &(&1.seq == elem(op, 1))).entity

    assert Enum.uniq(entities) == ["m2"]

    before = events(path)
    assert %{events: 2} = Compaction.run(Store)
    same_from_every_offset(before, path)
  end
end
