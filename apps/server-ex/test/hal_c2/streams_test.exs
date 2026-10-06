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

  # --- clients -----------------------------------------------------------------------

  defp run(n, status \\ "completed"),
    do: {"run", "run-#{n}", %{"s" => %{"id" => "run-#{n}", "ordinal" => n, "status" => status}}}

  defp item(n, run, fields \\ %{}) do
    fields = Map.merge(%{"id" => "item-#{n}", "ordinal" => n, "runId" => "run-#{run}"}, fields)
    {"turn-item", "item-#{n}", %{"s" => Map.put_new(fields, "type", "assistant_message")}}
  end

  # Three runs of two items each, with a node beside every item.
  defp long_thread(id) do
    changes =
      thread(id) ++
        for run <- 1..3, change <- [run(run) | run_items(run)], do: change

    {:ok, seq} = Streams.commit(id, :thread, changes)
    seq
  end

  defp run_items(run) do
    for n <- [run * 2 - 1, run * 2],
        change <- [
          item(n, run),
          {"node", "node-#{n}", %{"s" => %{"id" => "node-#{n}", "runId" => "run-#{run}"}}}
        ],
        do: change
  end

  defp client_snapshot(id, acc \\ []) do
    receive do
      {:hal_c2_stream, ^id, {:snapshot, _seq, _at, rows, :more, _meta}} ->
        client_snapshot(id, [rows | acc])

      {:hal_c2_stream, ^id, {:snapshot, seq, _at, rows, :done, meta}} ->
        {seq, meta, List.flatten(Enum.reverse([rows | acc]))}
    after
      1_000 -> flunk("snapshot incomplete")
    end
  end

  defp ids(rows, kind), do: for({^kind, id, _} <- rows, do: id)

  test "a client is sent entities as clients see them, with the handle to resume by" do
    {:ok, _} = Streams.commit("th-7", :thread, thread("th-7"))

    command = %{"id" => "c1", "type" => "command_execution", "output" => "lots"}
    {:ok, _} = Streams.commit("th-7", :thread, [{"turn-item", "c1", %{"s" => command}}])

    :ok = Streams.subscribe("th-7", self(), nil, %{})
    {seq, meta, rows} = client_snapshot("th-7")
    assert meta == %{handle: Streams.Server.handle()}
    assert [{"turn-item", "c1", item}] = Enum.filter(rows, &(elem(&1, 0) == "turn-item"))
    refute Map.has_key?(item, "output")
    assert_receive {:hal_c2_stream, "th-7", {:live, ^seq, handle}}
    assert handle == meta.handle

    # Output the client never shows is not sent; what is left of the commit is.
    {:ok, _} =
      Streams.commit("th-7", :thread, [{"turn-item", "c1", %{"a" => %{"output" => "x"}}}])

    {:ok, last} =
      Streams.commit("th-7", :thread, [{"turn-item", "c1", %{"s" => %{"exitCode" => 1}}}])

    assert_receive {:hal_c2_stream, "th-7", {:events, [%{seq: ^last, patch: patch}], ^last}}
    assert patch == %{"s" => %{"exitCode" => 1, "outputIndicatesFailure" => true}}
    refute_received {:hal_c2_stream, "th-7", {:events, _, _}}
  end

  test "a client resumes with its handle and is sent the log since, merged per entity" do
    {:ok, _} = Streams.commit("th-8", :thread, thread("th-8"))
    {:ok, offset} = Streams.commit("th-8", :thread, [item(1, 1, %{"text" => "Hel"})])

    {:ok, _} =
      Streams.commit("th-8", :thread, [{"turn-item", "item-1", %{"a" => %{"text" => "lo"}}}])

    {:ok, last} =
      Streams.commit("th-8", :thread, [{"turn-item", "item-1", %{"a" => %{"text" => "!"}}}])

    :ok = Streams.subscribe("th-8", self(), offset, %{handle: Streams.Server.handle()})

    assert_receive {:hal_c2_stream, "th-8",
                    {:events, [%{seq: ^last, patch: %{"a" => %{"text" => "lo!"}}}], ^last}}

    assert_receive {:hal_c2_stream, "th-8", {:live, ^last, _}}
  end

  test "an offset that came with another handle starts over" do
    {:ok, seq} = Streams.commit("th-9", :thread, thread("th-9"))
    :ok = Streams.subscribe("th-9", self(), seq, %{handle: "another-store.1"})
    assert {^seq, _meta, [{"thread", "th-9", _}]} = client_snapshot("th-9")
  end

  test "a client further behind than a replay is sent each changed entity once" do
    {:ok, offset} = Streams.commit("th-10", :thread, thread("th-10") ++ [item(1, 1), item(2, 1)])

    appends = for _ <- 1..2_001, do: {"turn-item", "item-2", %{"a" => %{"text" => "x"}}}

    {:ok, _} =
      Streams.commit("th-10", :thread, appends ++ [{"turn-item", "item-1", HalC2.Patch.delete()}])

    {:ok, last} = Streams.commit("th-10", :thread, [item(3, 1)])

    :ok = Streams.subscribe("th-10", self(), offset, %{handle: Streams.Server.handle()})
    assert_receive {:hal_c2_stream, "th-10", {:events, events, ^last}}

    assert [
             %{entity: "item-2", patch: %{"d" => true, "s" => %{"text" => text}}},
             %{entity: "item-1", patch: %{"d" => true} = gone},
             %{entity: "item-3", seq: ^last, patch: %{"d" => true, "s" => %{}}}
           ] = events

    assert byte_size(text) == 2_001
    assert map_size(gone) == 1
    assert_receive {:hal_c2_stream, "th-10", {:live, ^last, _}}
    refute_received {:hal_c2_stream, "th-10", {:snapshot, _, _, _, _, _}}
  end

  test "a client names the kinds it folds and is sent no others" do
    {:ok, _} = Streams.commit("th-11", :thread, thread("th-11") ++ [run(1), item(1, 1)])

    for {id, role} <- [{"m-user", "user"}, {"m-agent", "assistant"}] do
      message = %{"id" => id, "role" => role, "runId" => "run-1", "text" => ""}
      {:ok, _} = Streams.commit("th-11", :thread, [{"message", id, %{"s" => message}}])
    end

    kinds = %{"turn-item" => %{}, "run" => %{}, "message" => %{"role" => "user"}}
    :ok = Streams.subscribe("th-11", self(), nil, %{kinds: kinds})
    {_seq, _meta, rows} = client_snapshot("th-11")
    assert Enum.map(rows, &elem(&1, 1)) == ~w(run-1 item-1 m-user)

    # The reply's text is the turn item's; its message says the same again.
    {:ok, last} =
      Streams.commit("th-11", :thread, [
        {"turn-item", "item-1", %{"a" => %{"text" => "Hi"}}},
        {"message", "m-agent", %{"a" => %{"text" => "Hi"}}}
      ])

    assert_receive {:hal_c2_stream, "th-11", {:events, [%{entity: "item-1"}], ^last}}
  end

  test "a window holds the newest runs, and pages reach back to the start" do
    seq = long_thread("th-12")
    :ok = Streams.subscribe("th-12", self(), nil, %{window: {:items, 2}})

    {^seq, meta, rows} = client_snapshot("th-12")
    assert meta.floor == 3
    assert ids(rows, "turn-item") == ~w(item-5 item-6)
    assert ids(rows, "node") == ~w(node-5 node-6)
    # What is not a run's own is held whole.
    assert ids(rows, "run") == ~w(run-1 run-2 run-3)
    assert_receive {:hal_c2_stream, "th-12", {:live, ^seq, _}}

    # Nothing is said about entities the client does not hold.
    {:ok, _} =
      Streams.commit("th-12", :thread, [{"turn-item", "item-1", %{"a" => %{"text" => "x"}}}])

    {:ok, last} =
      Streams.commit("th-12", :thread, [{"turn-item", "item-6", %{"a" => %{"text" => "y"}}}])

    assert_receive {:hal_c2_stream, "th-12", {:events, [%{entity: "item-6"}], ^last}}
    refute_received {:hal_c2_stream, "th-12", {:events, [%{entity: "item-1"}], _}}

    :ok = Streams.more("th-12", self(), 3)
    assert_receive {:hal_c2_stream, "th-12", {:page, ^last, page, nil, :done}}
    assert ids(page, "turn-item") == ~w(item-1 item-2 item-3 item-4)
    assert %{"text" => "x"} = Enum.find_value(page, fn {_, id, e} -> if id == "item-1", do: e end)

    # They are the client's now.
    {:ok, next} =
      Streams.commit("th-12", :thread, [{"turn-item", "item-1", %{"a" => %{"text" => "z"}}}])

    assert_receive {:hal_c2_stream, "th-12", {:events, [%{entity: "item-1"}], ^next}}

    :ok = Streams.more("th-12", self(), 3)
    assert_receive {:hal_c2_stream, "th-12", {:page, ^next, [], nil, :done}}
  end

  test "a window never holds a rolled-back run" do
    _ = long_thread("th-13")

    {:ok, _} =
      Streams.commit("th-13", :thread, [{"run", "run-2", %{"s" => %{"status" => "rolled_back"}}}])

    :ok = Streams.subscribe("th-13", self(), nil, %{window: {:items, 3}})
    {_seq, meta, rows} = client_snapshot("th-13")
    assert meta.floor == nil
    assert ids(rows, "turn-item") == ~w(item-1 item-2 item-5 item-6)
  end

  test "a client that kept a window resumes it" do
    seq = long_thread("th-14")

    {:ok, _} =
      Streams.commit("th-14", :thread, [{"turn-item", "item-2", %{"a" => %{"text" => "x"}}}])

    {:ok, last} =
      Streams.commit("th-14", :thread, [{"turn-item", "item-4", %{"a" => %{"text" => "y"}}}])

    client = %{handle: Streams.Server.handle(), window: {:floor, 2}}
    :ok = Streams.subscribe("th-14", self(), seq, client)
    assert_receive {:hal_c2_stream, "th-14", {:events, [%{entity: "item-4"}], ^last}}
    assert_receive {:hal_c2_stream, "th-14", {:live, ^last, _}}
  end

  test "a watcher is told of changes without being sent the stream" do
    {:ok, seq} = Streams.commit("th-15", :thread, thread("th-15"))
    :ok = Streams.watch("th-15", self())
    assert_receive {:hal_c2_stream, "th-15", {:live, ^seq}}
    {:ok, next} = Streams.commit("th-15", :thread, append("x"))
    assert_receive {:hal_c2_stream, "th-15", {:changed, ^next}}
    refute_received {:hal_c2_stream, "th-15", {:snapshot, _, _, _, _}}
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
