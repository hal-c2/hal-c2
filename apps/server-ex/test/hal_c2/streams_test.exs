defmodule HalC2.StreamsTest do
  # Uses the MC-wide named Store, Streams, and Shell processes.
  use ExUnit.Case, async: false

  alias HalC2.Streams

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)
    :ok
  end

  defp thread(id, fields \\ %{}),
    do: [{"thread", id, HalC2.Patch.diff(nil, Map.merge(%{"id" => id, "title" => "t"}, fields))}]

  defp append(text), do: [{"turn-item", "item-1", %{"a" => %{"text" => text}}}]

  test "a stream whose log holds a patch that sets nothing still loads" do
    {:ok, _} =
      HalC2.Store.append([
        {:thread, "th-1", thread("th-1") ++ [{"turn-item", "item-1", %{"s" => nil}}]}
      ])

    state = Streams.Server.state(Streams.ensure("th-1"))
    assert state.seq == 2
    assert HalC2.StreamState.get(state, "turn-item") == %{}
    assert {:ok, 3} = Streams.commit("th-1", :thread, append("more"))

    # A client catching up from before it is sent only the events that change something.
    :ok = Streams.subscribe("th-1", self(), 1)
    assert_receive {:hal_c2_stream, "th-1", {:events, [%{seq: 3, entity: "item-1"}]}}
    assert_receive {:hal_c2_stream, "th-1", {:live, 3}}
  end

  test "a patch that sets nothing still counts toward a replay being too long" do
    changes =
      thread("th-1") ++
        [{"turn-item", "item-0", %{"s" => nil}}] ++ for(_ <- 1..2_000, do: hd(append("x")))

    {:ok, last} = HalC2.Store.append([{:thread, "th-1", changes}])

    # 2,001 events are behind the client, one more than a replay carries.
    :ok = Streams.subscribe("th-1", self(), 1)
    assert_receive {:hal_c2_stream, "th-1", {:snapshot, ^last, _at, _rows, :done}}
    assert_receive {:hal_c2_stream, "th-1", {:live, ^last}}
    refute_received {:hal_c2_stream, "th-1", {:events, _}}
  end

  test "subscribers get the current state, then live events" do
    {:ok, _} = Streams.commit("th-1", :thread, thread("th-1"))
    :ok = Streams.subscribe("th-1", self(), nil)

    assert_receive {:hal_c2_stream, "th-1",
                    {:snapshot, seq, _at, [{"thread", "th-1", %{"title" => "t"}}], :done}}

    {:ok, next} =
      Streams.commit("th-1", :thread, [{"turn-item", "item-1", %{"s" => %{"text" => "Hel"}}}])

    assert next == seq + 1

    assert_receive {:hal_c2_stream, "th-1",
                    {:events,
                     [%{seq: ^next, kind: "turn-item", patch: %{"s" => %{"text" => "Hel"}}}]}}
  end

  test "a reconnecting subscriber replays only what it missed" do
    {:ok, _} = Streams.commit("th-2", :thread, thread("th-2"))

    {:ok, offset} =
      Streams.commit("th-2", :thread, [{"turn-item", "item-1", %{"s" => %{"text" => "Hel"}}}])

    {:ok, _} = Streams.commit("th-2", :thread, append("lo"))
    {:ok, last} = Streams.commit("th-2", :thread, append(", world"))

    :ok = Streams.subscribe("th-2", self(), offset)
    assert_receive {:hal_c2_stream, "th-2", {:events, events}}

    assert [
             %{patch: %{"a" => %{"text" => "lo"}}},
             %{seq: ^last, patch: %{"a" => %{"text" => ", world"}}}
           ] = events
  end

  test "state survives the stream process stopping and reloads from the log" do
    {:ok, _} = Streams.commit("th-3", :thread, thread("th-3"))

    {:ok, _} =
      Streams.commit("th-3", :thread, [{"turn-item", "item-1", %{"s" => %{"text" => "a"}}}])

    {:ok, _} = Streams.commit("th-3", :thread, append("b"))
    pid = Streams.ensure("th-3")
    ref = Process.monitor(pid)
    GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, _, _, _}

    state = HalC2.Streams.Server.state(Streams.ensure("th-3"))
    assert state.entities["turn-item"]["item-1"]["text"] == "ab"
  end

  test "snapshot rows arrive in creation order" do
    {:ok, _} = Streams.commit("th-6", :thread, thread("th-6"))
    ids = for n <- 1..20, do: "item-#{n}"

    for id <- ids,
        do:
          {:ok, _} =
            Streams.commit("th-6", :thread, [{"turn-item", id, %{"s" => %{"text" => id}}}])

    # Updating an early item must not move it.
    {:ok, _} =
      Streams.commit("th-6", :thread, [{"turn-item", "item-1", %{"a" => %{"text" => "!"}}}])

    :ok = Streams.subscribe("th-6", self(), nil)
    rows = collect_snapshot("th-6", []) |> List.flatten()
    assert for({"turn-item", id, _} <- rows, do: id) == ids
  end

  test "large snapshots arrive in bounded chunks" do
    big = String.duplicate("x", 100_000)
    changes = for i <- 1..10, do: {"turn-item", "item-#{i}", %{"s" => %{"output" => big}}}
    {:ok, _} = Streams.commit("th-5", :thread, changes)
    :ok = Streams.subscribe("th-5", self(), nil)

    chunks = collect_snapshot("th-5", [])
    assert length(chunks) > 1
    assert chunks |> List.flatten() |> length() == 10
    assert Enum.all?(chunks, &(:erlang.external_size(&1) < 400_000))
  end

  defp collect_snapshot(id, acc) do
    receive do
      {:hal_c2_stream, ^id, {:snapshot, _seq, _at, rows, :more}} ->
        collect_snapshot(id, [rows | acc])

      {:hal_c2_stream, ^id, {:snapshot, _seq, _at, rows, :done}} ->
        Enum.reverse([rows | acc])
    after
      1_000 -> flunk("snapshot incomplete")
    end
  end

  test "thread changes update the shell row and notify its subscribers" do
    :ok = HalC2.Shell.subscribe(self())
    {:ok, _} = Streams.commit("th-4", :thread, thread("th-4", %{"projectId" => "p"}))

    # Rows are recomputed shortly after a commit, not on every one.
    assert_receive {:hal_c2_shell, {:rows, mc, [{"th-4", {"thread", row}}]}}, 1_000
    assert mc == node()
    assert %{"id" => "th-4", "title" => "t", "projectId" => "p", "status" => "idle"} = row

    {:ok, _} =
      Streams.commit("th-4", :thread, [{"thread", "th-4", %{"s" => %{"title" => "Renamed"}}}])

    assert_receive {:hal_c2_shell, {:rows, _, [{"th-4", {"thread", %{"title" => "Renamed"}}}]}},
                   1_000

    assert [{"thread", %{"title" => "Renamed"}}] =
             for({{_, "th-4"}, kind_row} <- HalC2.Shell.rows(), do: kind_row)
  end
end
