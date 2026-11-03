defmodule HalC2.StreamsColdTest do
  # A stream keeps the turn items, messages and nodes of its older runs on disk
  # (`HalC2.StreamState`, "Hot and cold"). What anyone reads of it, and what clients
  # are sent, is what a whole fold of the log holds.
  use ExUnit.Case, async: false

  alias HalC2.{Store, StreamState, Streams}
  alias HalC2.Projection.Timeline
  alias HalC2.Streams.Server

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:hal_c2, :stream_hot_items)
    Application.put_env(:hal_c2, :stream_hot_items, 2)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:hal_c2, :stream_hot_items, previous),
        else: Application.delete_env(:hal_c2, :stream_hot_items)
    end)

    path = Path.join(dir, "hal-c2.sqlite")
    start_supervised!({Store, path: path})
    start_supervised!(Streams)
    %{path: path}
  end

  test "older runs go cold and every read still sees the whole thread", %{path: path} do
    for i <- 1..8, do: run("th", i, 3)
    state = Streams.state("th")

    assert state.floor != nil
    assert map_size(StreamState.get(state, "turn-item")) < 24
    assert rows(state) == whole(path, "th")
    assert StreamState.fetch(state, "turn-item", "r1-i1")["text"] == "1.1"

    assert Server.get(Streams.ensure("th"), "message", "r1-m") == %{
             "runId" => "r1",
             "text" => "q1"
           }

    counts = StreamState.item_counts(state)
    assert Enum.all?(1..8, &(counts["r#{&1}"] == 3))
  end

  test "a whole client and a windowed one that pages back hold what a fold holds", %{path: path} do
    for i <- 1..8, do: run("th", i, 3)

    :ok = Streams.subscribe("th", self(), nil, %{kinds: nil})
    assert snapshot() == wire(whole(path, "th"))

    :ok = Streams.subscribe("th", self(), nil, %{kinds: nil, window: {:items, 2}, tag: :w})
    first = snapshot(:w)
    paged = page_all("th", :w)

    expected = for {k, _, _} = row <- wire(whole(path, "th")), k in ~w(turn-item message), do: row
    held = for {k, _, _} = row <- first ++ paged, k in ~w(turn-item message), do: row
    assert Enum.sort(held) == Enum.sort(expected)
  end

  test "a change to a cold entity reaches clients and outlives a restart", %{path: path} do
    for i <- 1..8, do: run("th", i, 3)
    :ok = Streams.subscribe("th", self(), nil, %{kinds: nil})
    _ = snapshot()

    {:ok, seq} =
      Streams.commit("th", :thread, [
        {"turn-item", "r1-i1", %{"a" => %{"text" => "!"}}},
        {"turn-item", "r1-i2", HalC2.Patch.delete()}
      ])

    assert_receive {:hal_c2_stream, "th", {:events, events, ^seq}}
    assert [%{entity: "r1-i1", patch: %{"a" => %{"text" => "!"}}}, %{entity: "r1-i2"}] = events

    state = Streams.state("th")
    assert StreamState.fetch(state, "turn-item", "r1-i1")["text"] == "1.1!"
    assert StreamState.fetch(state, "turn-item", "r1-i2") == nil
    assert rows(state) == whole(path, "th")

    stop("th")
    restarted = Streams.state("th")
    assert restarted.seq == seq
    assert rows(restarted) == whole(path, "th")
    assert StreamState.fetch(restarted, "turn-item", "r1-i2") == nil
  end

  test "changed_since replays a client from any offset to the whole thread", %{path: path} do
    for i <- 1..6, do: run("th", i, 3)
    {:ok, _} = Streams.commit("th", :thread, [{"turn-item", "r1-i3", HalC2.Patch.delete()}])
    state = Streams.state("th")
    log = Store.reduce_stream(path, "th", 0, [], &[&1 | &2]) |> Enum.reverse()

    for offset <- [0, 5, div(state.seq, 2), state.seq - 1, state.seq] do
      client = log |> Enum.take_while(&(&1.seq <= offset)) |> fold()
      {upserts, deletes} = StreamState.changed_since(state, offset)

      copy =
        Enum.reduce(upserts, entities(client), fn {_, kind, id, entity}, acc ->
          Map.put(acc, {kind, id}, entity)
        end)

      copy = Enum.reduce(deletes, copy, fn {_, kind, id}, acc -> Map.delete(acc, {kind, id}) end)
      assert copy == entities(fold(log))
    end
  end

  test "an older MC's snapshot that fits migrates as it loads", %{path: path} do
    for i <- 1..8, do: run("th", i, 3)
    stop("th")
    whole = whole(path, "th")
    legacy = legacy(path, "th", nil)

    sql!(path, "DELETE FROM hot_snapshots")
    sql!(path, "DELETE FROM cold")
    put_legacy(path, "th", legacy.seq, legacy)

    state = StreamState.load(path, "th", store: Store, max_legacy: 100_000_000)
    assert state.floor != nil
    assert rows(state) == whole
    # Migrated once: the older snapshot is gone and a hot one stands in its place.
    assert {_, %StreamState{v: 4}} = Store.get_snapshot(path, "th")
    assert Store.legacy_snapshot(path, "th", 100_000_000) == nil
    assert rows(StreamState.load(path, "th")) == whole
  end

  test "a long one's hot part is read one entity at a time, as demote leaves it", %{path: path} do
    for i <- 1..8, do: run("th", i, 3)
    legacy = legacy(path, "th", nil)
    blob = :erlang.term_to_binary(legacy, [:compressed])

    {hot, plan} = StreamState.Legacy.hot(blob, StreamState.hot_items(), MapSet.new())
    {demoted, rows} = StreamState.demote(StreamState.migrate(legacy), StreamState.hot_items())

    assert hot.entities == demoted.entities

    assert {hot.floor, hot.tally, hot.created, hot.changed} ==
             {demoted.floor, demoted.tally, demoted.created, demoted.changed}

    cold = fn blob ->
      self = self()
      :ok = StreamState.Legacy.cold(blob, plan, 5, &send(self, {:rows, &1}))

      Stream.repeatedly(fn -> receive(do: ({:rows, r} -> r), after: (0 -> nil)) end)
      |> Enum.take_while(& &1)
      |> Enum.concat()
    end

    assert Enum.sort(cold.(blob)) == Enum.sort(rows)
    # An uncompressed one too.
    assert Enum.sort(cold.(:erlang.term_to_binary(legacy))) == Enum.sort(rows)
  end

  test "a long one serves at once and writes its cold part in the background", %{path: path} do
    previous = Application.get_env(:hal_c2, :stream_max_legacy_bytes)
    Application.put_env(:hal_c2, :stream_max_legacy_bytes, 1)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:hal_c2, :stream_max_legacy_bytes, previous),
        else: Application.delete_env(:hal_c2, :stream_max_legacy_bytes)
    end)

    for i <- 1..8, do: run("th", i, 3)
    # Changed after the older MC's snapshot: it stays in memory for the log to apply to.
    {:ok, last} =
      Streams.commit("th", :thread, [{"turn-item", "r1-i1", %{"a" => %{"text" => "!"}}}])

    stop("th")
    legacy = legacy(path, "th", last - 1)

    sql!(path, "DELETE FROM hot_snapshots")
    sql!(path, "DELETE FROM cold")
    put_legacy(path, "th", legacy.seq, legacy)

    pid = Streams.ensure("th")
    state = Streams.state("th")
    assert StreamState.fetch(state, "turn-item", "r1-i1")["text"] == "1.1!"
    # Read by another process, the cold part is there once it is written.
    assert rows(state) == whole(path, "th")

    # A change to an entity the migration is writing waits for it.
    {:ok, _} = Streams.commit("th", :thread, [{"turn-item", "r2-i1", %{"a" => %{"text" => "?"}}}])
    :ok = Server.await_cold(pid)

    state = Streams.state("th")
    assert StreamState.fetch(state, "turn-item", "r2-i1")["text"] == "2.1?"
    assert rows(state) == whole(path, "th")
    assert StreamState.migration(state) == nil
    assert Store.legacy_snapshot(path, "th", 100_000_000) == nil
    assert {_, %StreamState{v: 4}} = Store.get_snapshot(path, "th")

    stop("th")
    assert rows(Streams.state("th")) == whole(path, "th")
  end

  # A read that walked the cold rows after a commit brought one back to memory and a
  # snapshot wrote the table again saw it changed, or not at all (#964).
  test "a read walks the cold rows as they were when it took the state", %{path: path} do
    for i <- 1..8, do: run("th", i, 3)
    reader = reader(fn -> Server.read(Streams.ensure("th")) end)
    assert_receive {:took, ^reader, seq}

    {:ok, _} =
      Streams.commit("th", :thread, [
        {"turn-item", "r1-i1", %{"a" => %{"text" => "!"}}},
        {"turn-item", "r1-i2", HalC2.Patch.delete()}
      ])

    # Snapshots write both again: one as the next runs go cold, one on the way out.
    for i <- 9..10, do: run("th", i, 3)
    stop("th")

    send(reader, :walk)
    assert_receive {:walked, ^reader, walked}
    assert walked == whole(path, "th", seq)
    assert {"turn-item", "r1-i2", %{"text" => "1.2"}} = List.keyfind(walked, "r1-i2", 1)
  end

  test "a read taken while the stream migrates walks it as it took it", %{path: path} do
    previous = Application.get_env(:hal_c2, :stream_max_legacy_bytes)
    Application.put_env(:hal_c2, :stream_max_legacy_bytes, 1)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:hal_c2, :stream_max_legacy_bytes, previous),
        else: Application.delete_env(:hal_c2, :stream_max_legacy_bytes)
    end)

    start_supervised!(Streams.Migrations)
    for i <- 1..8, do: run("th", i, 3)
    stop("th")
    legacy = legacy(path, "th", nil)
    sql!(path, "DELETE FROM hot_snapshots")
    sql!(path, "DELETE FROM cold")
    put_legacy(path, "th", legacy.seq, legacy)

    # The migration waits for its turn while the read is taken and a commit waits for it.
    test = self()

    holder =
      spawn_link(fn ->
        :ok = Streams.Migrations.turn()
        send(test, :holding)
        receive do: (:release -> :ok)
      end)

    assert_receive :holding
    reader = reader(fn -> Server.read(Streams.ensure("th")) end)
    assert_receive {:took, ^reader, seq}

    committer =
      Task.async(fn ->
        Streams.commit("th", :thread, [{"turn-item", "r1-i2", HalC2.Patch.delete()}])
      end)

    send(holder, :release)
    assert {:ok, _} = Task.await(committer)

    send(reader, :walk)
    assert_receive {:walked, ^reader, walked}
    assert walked == whole(path, "th", seq)
    assert List.keyfind(walked, "r1-i2", 1)
  end

  test "the transcript counts what a whole fold shows, cold items included", %{path: path} do
    for i <- 1..3, do: run("src", i, 3)
    {:ok, _} = Streams.commit("src", :thread, [{"thread", "src", %{"s" => %{"id" => "src"}}}])

    for i <- 1..8, do: run("th", i, 3)

    # Run 2 was steered: its first attempt's interrupt result is noise, unless the user
    # asked for the stop, as in run 3. Run 4 was a queued message, cancelled.
    {:ok, _} =
      Streams.commit("th", :thread, [
        {"thread", "th",
         %{
           "s" => %{
             "id" => "th",
             "forkedFrom" => %{"type" => "run", "threadId" => "src", "runId" => "r2"}
           }
         }},
        {"run-attempt", "a2",
         %{"s" => %{"runId" => "r2", "rootNodeId" => "n2", "status" => "superseded"}}},
        {"run-attempt", "a3",
         %{"s" => %{"runId" => "r3", "rootNodeId" => "n3", "status" => "superseded"}}},
        item("r2", "x2", %{"type" => "run_interrupt_result", "nodeId" => "n2"}),
        item("r3", "x3", %{"type" => "run_interrupt_result", "nodeId" => "n3"}),
        item("r3", "q3", %{"type" => "run_interrupt_request"}),
        item("r4", "u4", %{"type" => "user_message", "inputIntent" => "queued_turn"})
      ])

    for i <- 9..12, do: run("th", i, 3)

    # Statuses change after the items went cold: run 5 is rolled back, run 4 cancelled.
    {:ok, _} =
      Streams.commit("th", :thread, [
        {"run", "r5", %{"s" => %{"status" => "rolled_back"}}},
        {"run", "r4", %{"s" => %{"status" => "cancelled"}}}
      ])

    state = Streams.state("th")
    assert Map.has_key?(StreamState.tally(state), "r2")
    whole = fold(Store.reduce_stream(path, "th", 0, [], &[&1 | &2]) |> Enum.reverse())
    source = Streams.state("src")
    whole_source = fold(Store.reduce_stream(path, "src", 0, [], &[&1 | &2]) |> Enum.reverse())

    assert Timeline.local_count(state) == length(Timeline.local_items(whole))
    assert Timeline.local_items(state) == Timeline.local_items(whole)

    assert Timeline.visible_count(state, fn "src" -> source end) ==
             length(Timeline.visible_items(whole, fn "src" -> whole_source end))

    shell = HalC2.Projection.Shell.thread_shell(state)
    assert shell["itemCount"] == length(Timeline.local_items(whole))
  end

  # --- helpers ----------------------------------------------------------------

  # One settled run of `n` turn items with its user message, `ordinal` `i`.
  test "cold rows that share a seq are each read once across pages", %{path: path} do
    # An older snapshot's entities carry no creation seq of their own (0), and its
    # migration marks every one changed at the snapshot's seq: more than a page of
    # cold rows can share one seq.
    for i <- 1..8, do: run("th", i, 3)
    stop("th")
    keys = for i <- 1..1_200, do: {"turn-item", "old-#{String.pad_leading("#{i}", 4, "0")}"}

    :ok =
      Store.put_cold(
        "th",
        for({kind, id} <- keys, do: {kind, id, "r1", 0, 7, %{"runId" => "r1"}}),
        false
      )

    state = StreamState.load(path, "th")
    old = MapSet.new(keys)
    read = for {kind, id, _} <- StreamState.rows(state), {kind, id} in old, do: {kind, id}
    assert read == keys

    {changed, _} = StreamState.changed_since(state, state.since)
    assert Enum.count(changed, fn {_, kind, id, _} -> {kind, id} in old end) == 1_200
  end

  defp run(stream, i, n) do
    run = "r#{i}"

    {:ok, _} =
      Streams.commit(stream, :thread, [
        {"run", run, %{"s" => %{"id" => run, "ordinal" => i, "status" => "running"}}},
        {"message", "#{run}-m", %{"s" => %{"runId" => run, "text" => "q#{i}"}}}
        | for(
            j <- 1..n,
            do:
              {"turn-item", "#{run}-i#{j}",
               %{"s" => %{"runId" => run, "threadId" => stream, "text" => "#{i}.#{j}"}}}
          )
      ])

    {:ok, _} =
      Streams.commit(stream, :thread, [{"run", run, %{"s" => %{"status" => "completed"}}}])
  end

  defp item(run, id, fields),
    do:
      {"turn-item", "#{run}-#{id}",
       %{"s" => Map.merge(%{"runId" => run, "threadId" => "th", "id" => "#{run}-#{id}"}, fields)}}

  defp fold(events), do: Enum.reduce(events, StreamState.new(), &StreamState.apply_event(&2, &1))

  defp whole(path, id, seq \\ nil),
    do:
      path
      |> Store.reduce_stream(id, 0, StreamState.new(), fn event, state ->
        if seq == nil or event.seq <= seq, do: StreamState.apply_event(state, event), else: state
      end)
      |> rows()

  # A process that takes a state with `take` (`Server.read/1`), says so, and walks it
  # in `StreamState.read/2` when told to.
  defp reader(take) do
    test = self()

    spawn_link(fn ->
      state = take.()
      send(test, {:took, self(), state.seq})

      StreamState.read(state, fn state ->
        receive do: (:walk -> send(test, {:walked, self(), rows(state)}))
      end)
    end)
  end

  defp rows(state), do: state |> StreamState.rows() |> Enum.to_list()

  defp entities(state),
    do: for({kind, id, entity} <- StreamState.rows(state), into: %{}, do: {{kind, id}, entity})

  defp wire(rows), do: for({k, id, e} <- rows, do: {k, id, HalC2.Web.Wire.entity(k, e)})

  defp snapshot(tag \\ nil, acc \\ []) do
    name = if tag, do: {"th", tag}, else: "th"

    receive do
      {:hal_c2_stream, ^name, {:snapshot, _, _, rows, :more, _}} -> snapshot(tag, acc ++ rows)
      {:hal_c2_stream, ^name, {:snapshot, _, _, rows, :done, _}} -> acc ++ rows
    after
      1_000 -> flunk("no snapshot")
    end
  end

  defp page_all(id, tag, acc \\ []) do
    :ok = Server.more(id, self(), 2, tag)
    {rows, floor} = page(tag, [])
    if floor == nil, do: acc ++ rows, else: page_all(id, tag, acc ++ rows)
  end

  defp page(tag, acc) do
    receive do
      {:hal_c2_stream, {"th", ^tag}, {:page, _, rows, _floor, :more}} -> page(tag, acc ++ rows)
      {:hal_c2_stream, {"th", ^tag}, {:page, _, rows, floor, :done}} -> {acc ++ rows, floor}
    after
      1_000 -> flunk("no page")
    end
  end

  defp stop(id) do
    pid = Streams.ensure(id)
    ref = Process.monitor(pid)
    GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
  end

  # What an older MC kept of a stream as of `seq` (all of it with `nil`): every entity.
  defp legacy(path, id, seq) do
    legacy =
      path
      |> Store.reduce_stream(id, 0, StreamState.new(), fn event, state ->
        if seq == nil or event.seq <= seq, do: StreamState.apply_event(state, event), else: state
      end)

    legacy = %{Map.from_struct(legacy) | v: 3} |> Map.drop([:floor, :dirty, :src])
    Map.put(legacy, :__struct__, StreamState)
  end

  defp put_legacy(path, id, seq, state) do
    {:ok, db} = Exqlite.Sqlite3.open(path)
    blob = :erlang.term_to_binary(state, [:compressed])

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(
        db,
        "INSERT INTO snapshots (stream, seq, state) SELECT key, ?2, ?3 FROM streams WHERE id = ?1 ON CONFLICT(stream) DO UPDATE SET seq = excluded.seq, state = excluded.state"
      )

    :ok = Exqlite.Sqlite3.bind(stmt, [id, seq, {:blob, blob}])
    :done = Exqlite.Sqlite3.step(db, stmt)
    :ok = Exqlite.Sqlite3.release(db, stmt)
    Exqlite.Sqlite3.close(db)
  end

  defp sql!(path, sql) do
    {:ok, db} = Exqlite.Sqlite3.open(path)
    :ok = Exqlite.Sqlite3.execute(db, sql)
    Exqlite.Sqlite3.close(db)
  end
end
