defmodule HalC2.Steps.Platform.EventStore do
  @moduledoc "Steps for features/node/platform/event-store.feature."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias Exqlite.Sqlite3
  alias HalC2.{Store, StreamState, Streams}
  alias HalC2.Test.{Node, WsClient}
  alias HalC2.Test.Node.World

  # --- offsets --------------------------------------------------------------------------

  step "a thread changes twice", context do
    id = World.thread_id(context, "main")

    seqs =
      for title <- ["first", "second"] do
        {:ok, %{"sequence" => seq}} =
          dispatch(%{"type" => "thread.metadata.update", "threadId" => id, "title" => title})

        seq
      end

    Map.put(context, :seqs, seqs)
  end

  step "both changes are in the log with increasing offsets", context do
    [first, second] = context.seqs
    assert first < second

    titles =
      for %{seq: seq, kind: "thread", patch: %{"s" => %{"title" => title}}} <-
            log(context, World.thread_id(context, "main")),
          seq in context.seqs,
          do: {seq, title}

    assert titles == [{first, "first"}, {second, "second"}]
    context
  end

  step "clients resume from those offsets", context do
    [first, second] = context.seqs
    client = sub(World.client(context), 1, World.thread_id(context, "main"), first)
    {live, skipped, _} = WsClient.recv_until(client, &(&1["t"] == "live" and &1["id"] == 1))

    assert live["offset"] == second
    refute Enum.any?(skipped, &(&1["t"] == "snapshot"))

    assert [[^second, "thread", _, %{"s" => %{"title" => "second"}}, _at]] =
             for(%{"t" => "events", "events" => events} <- skipped, event <- events, do: event)

    context
  end

  # --- patches --------------------------------------------------------------------------

  step "an assistant message is streaming", context do
    message = %{"id" => "msg-stream", "role" => "assistant", "text" => "Hel", "streaming" => true}
    commit(context, [{"message", "msg-stream", HalC2.Patch.diff(nil, message)}])
    Map.put(context, :message, message)
  end

  step "more text arrives for it", context do
    next = %{context.message | "text" => "Hello, world"}
    seq = commit(context, [{"message", "msg-stream", HalC2.Patch.diff(context.message, next)}])
    Map.put(context, :seq, seq)
  end

  step "the log records only the new text", context do
    [event] = log(context, World.thread_id(context, "main"), context.seq - 1)
    assert event.patch == %{"a" => %{"text" => "lo, world"}}
    refute raw_patch(context, context.seq) =~ "Hel"
    assert thread_state(context).entities["message"]["msg-stream"]["text"] == "Hello, world"
    context
  end

  step "a thread entity is written with the same value it already has", context do
    id = World.thread_id(context, "main")
    command = %{"type" => "thread.active.reorder", "threadId" => id, "orderKey" => "a0"}
    {:ok, %{"sequence" => before}} = dispatch(command)
    {:ok, %{"sequence" => after_seq}} = dispatch(command)
    Map.merge(context, %{before: before, after: after_seq, count: length(log(context, id))})
  end

  step "no event is added to the log", context do
    assert context.after == context.before
    id = World.thread_id(context, "main")
    assert [%{seq: last} | _] = Enum.reverse(log(context, id))
    assert last == context.before
    assert length(log(context, id)) == context.count
    context
  end

  # --- quiet patches --------------------------------------------------------------------

  step "a thread last active an hour ago", context do
    id = World.thread_id(context, "main")
    at = System.os_time(:millisecond) - 60 * 60 * 1_000
    iso = HalC2.Projection.JS.iso(at)
    commit(context, [{"thread", id, %{"s" => %{"updatedAt" => iso}}, at}])
    row = World.await_row(id, &(HalC2.Projection.JS.epoch_ms(&1["updatedAt"]) == at))
    Map.put(context, :active_at, row["updatedAt"])
  end

  step "the user visits the thread", context do
    visited = World.iso_from_now(0)

    {{:ok, _}, context} =
      World.dispatch(context, %{
        "type" => "thread.visit",
        "threadId" => World.thread_id(context, "main"),
        "visitedAt" => visited
      })

    Map.put(context, :visited, visited)
  end

  step "the visit is recorded", context do
    id = World.thread_id(context, "main")
    row = World.await_row(id, &(&1["lastVisitedAt"] == context.visited))
    assert World.thread(context, "main")["lastVisitedAt"] == context.visited
    Map.put(context, :row, row)
  end

  step "the thread's last activity time does not move", context do
    assert context.row["updatedAt"] == context.active_at

    assert [%{patch: %{"q" => true, "s" => %{"lastVisitedAt" => _}}} | _] =
             Enum.reverse(log(context, World.thread_id(context, "main")))

    context
  end

  # --- deletes --------------------------------------------------------------------------

  step "a thread with an attached provider session", context do
    id = World.thread_id(context, "main")

    session = %{
      "id" => "ps-1",
      "threadId" => id,
      "status" => "ready",
      "providerInstanceId" => "codex"
    }

    commit(context, [{"provider-session", "ps-1", HalC2.Patch.diff(nil, session)}])
    assert StreamState.get(thread_state(context), "provider-session")["ps-1"]
    context
  end

  step "the provider session is stopped", context do
    {:ok, _} =
      dispatch(%{
        "type" => "provider-session.detach",
        "threadId" => World.thread_id(context, "main"),
        "providerSessionId" => "ps-1"
      })

    context
  end

  step "the thread's state no longer contains it", context do
    id = World.thread_id(context, "main")
    assert %{patch: %{"d" => true}, kind: "provider-session"} = List.last(log(context, id))
    assert StreamState.get(thread_state(context), "provider-session") == %{}
    # A fold of the log from scratch agrees with the live state.
    assert StreamState.get(StreamState.load(context.node.store, id), "provider-session") == %{}
    context
  end

  # --- compression ----------------------------------------------------------------------

  step "a command writes more than a kilobyte of output", context do
    output = Enum.map_join(1..200, "\n", &"line #{&1} of the build output")
    item = %{"id" => "cmd-1", "type" => "command_execution", "output" => output}
    seq = commit(context, [{"turn-item", "cmd-1", HalC2.Patch.diff(nil, item)}])
    Map.merge(context, %{seq: seq, output: output})
  end

  step "the patch is compressed in the store", context do
    stored = raw_patch(context, context.seq)
    assert <<0, _::binary>> = stored
    assert byte_size(stored) < byte_size(context.output)
    context
  end

  step "reading it back gives the original output", context do
    [event] = log(context, World.thread_id(context, "main"), context.seq - 1)
    assert event.patch["s"]["output"] == context.output
    context
  end

  # --- readers --------------------------------------------------------------------------

  step "a client is reading a large thread history", context do
    id = World.thread_id(context, "main")

    commit(
      context,
      for(n <- 1..1_200, do: {"note", "n-#{n}", %{"s" => %{"text" => "note #{n}"}}})
    )

    expected = length(log(context, id))
    test = self()

    reader =
      spawn_link(fn ->
        count =
          Store.reduce_stream(context.node.store, id, 0, 0, fn _event, count ->
            if count == 0 do
              send(test, {:reading, self()})
              receive do: (:go -> :ok)
            end

            count + 1
          end)

        send(test, {:read, count})
      end)

    assert_receive {:reading, ^reader}, 2_000
    Map.merge(context, %{reader: reader, expected: expected})
  end

  step "the thread keeps changing", context do
    seqs =
      for n <- 1..20,
          do: commit(context, [{"note", "late-#{n}", %{"s" => %{"text" => "late #{n}"}}}])

    Map.put(context, :seqs, seqs)
  end

  step "the changes are appended without waiting for the reader", context do
    # Every append returned while the reader was still inside its read.
    refute_received {:read, _}
    assert length(context.seqs) == 20
    assert context.seqs == Enum.sort(context.seqs)
    send(context.reader, :go)
    # The reader sees the log as it was when it started.
    assert_receive {:read, count}, 5_000
    assert count == context.expected
    context
  end

  # --- snapshots ------------------------------------------------------------------------

  step "a thread receives 500 more events", context do
    commit(context, for(n <- 1..500, do: {"note", "n-#{n}", %{"s" => %{"text" => "note #{n}"}}}))
    context
  end

  step "the node writes a snapshot of its folded state", context do
    id = World.thread_id(context, "main")
    state = thread_state(context)
    idle_stop(id)
    assert {seq, %StreamState{} = snapshot} = Store.get_snapshot(context.node.store, id)
    assert seq == state.seq
    assert snapshot == state
    context
  end

  step "a thread's snapshot is missing", context do
    id = World.thread_id(context, "main")
    commit(context, for(n <- 1..500, do: {"note", "n-#{n}", %{"s" => %{"text" => "note #{n}"}}}))
    expected = thread_state(context)
    idle_stop(id)
    assert Store.get_snapshot(context.node.store, id)
    sql!(context, "DELETE FROM snapshots")
    assert Store.get_snapshot(context.node.store, id) == nil
    Map.put(context, :expected, expected)
  end

  step "a client subscribes to the thread", context do
    id = World.thread_id(context, "main")
    client = sub(World.client(context), 1, id)
    {live, frames, client} = WsClient.recv_until(client, &(&1["t"] == "live" and &1["id"] == 1))
    rows = for %{"t" => "snapshot", "rows" => rows} <- frames, row <- rows, do: row
    context |> World.put_client(client) |> Map.merge(%{live: live, rows: rows})
  end

  step "the node folds the log again", context do
    id = World.thread_id(context, "main")
    state = thread_state(context)
    assert state == StreamState.load(context.node.store, id)
    assert state.seq == context.expected.seq
    assert context.live["offset"] == state.seq
    context
  end

  step "the client receives the same state", context do
    expected =
      for {kind, id, entity} <- StreamState.rows(context.expected), do: [kind, id, entity]

    assert context.rows == expected
    context
  end

  step "a thread's snapshot was written by an older node", context do
    id = World.thread_id(context, "main")
    state = thread_state(context)
    idle_stop(id)

    # v1 state had no creation order.
    old =
      state
      |> Map.from_struct()
      |> Map.drop([:created])
      |> Map.merge(%{__struct__: StreamState, v: 1})

    :ok = Store.put_snapshot(id, state.seq, old)
    Map.put(context, :expected, state)
  end

  step "the node loads the thread", context do
    Map.put(context, :loaded, thread_state(context))
  end

  step "the snapshot is migrated to the current format", context do
    loaded = context.loaded
    assert %StreamState{v: 2, created: created} = loaded
    # Loaded from the snapshot (a fold of the log records creation order).
    assert created == %{}
    assert loaded.entities == context.expected.entities
    assert loaded.seq == context.expected.seq
    context
  end

  # --- restarts -------------------------------------------------------------------------

  step "every project and thread is back with its full history", context do
    project = World.project(context, "widgets").id
    thread = World.thread_id(context, "main")
    assert World.await_row(project, & &1)["title"] == "widgets"
    assert World.await_row(thread, & &1)["title"] == "main"

    for id <- [project, thread] do
      [%{seq: first} | _] = log(context, id)
      state = Streams.Server.state(Streams.ensure(id))
      assert state == StreamState.load(context.node.store, id)
      assert state.created |> Map.values() |> Enum.min() == first
    end

    assert StreamState.get(thread_state(context), "thread")[thread]["projectId"] == project
    context
  end

  # --- sidebar rows ---------------------------------------------------------------------

  step "a thread's title changes", context do
    id = World.thread_id(context, "main")

    {:ok, _} =
      dispatch(%{"type" => "thread.metadata.update", "threadId" => id, "title" => "Renamed"})

    context
  end

  step "its sidebar row is updated in the store", context do
    id = World.thread_id(context, "main")
    World.await_row(id, &(&1["title"] == "Renamed"))

    assert {^id, "thread", %{"title" => "Renamed"}} =
             List.keyfind(Store.list_shell(context.node.store), id, 0)

    context
  end

  step "rows changing quickly are sent to clients at most every 250 milliseconds", context do
    id = World.thread_id(context, "main")

    client =
      WsClient.send_json(World.client(context), %{
        "t" => "sub",
        "id" => 2,
        "shape" => %{"type" => "shell"}
      })

    {_, client} = Node.await(client, &(&1["t"] == "shell" and &1["id"] == 2))

    started = System.monotonic_time(:millisecond)

    for n <- 1..20,
        do:
          {:ok, _} =
            dispatch(%{
              "type" => "thread.metadata.update",
              "threadId" => id,
              "title" => "burst #{n}"
            })

    {frames, _client} = row_frames(client, id, "burst 20", [])
    [{first_at, _} | _] = frames
    assert first_at - started >= 250
    # Twenty changes arrive as a handful of rows, never one per change.
    assert length(frames) <= 3
    context
  end

  step "threads written before the sidebar table existed", context do
    ids =
      for n <- 1..2 do
        id = "th-old-#{n}"
        thread = %{"id" => id, "projectId" => World.project(context).id, "title" => "old #{n}"}
        # The second has a long log, so rebuilding it takes a while.
        notes =
          if n == 2,
            do: for(i <- 1..2_000, do: {"note", "n-#{i}", %{"s" => %{"text" => "note #{i}"}}}),
            else: []

        {:ok, _} =
          Streams.commit(id, :thread, [{"thread", id, HalC2.Patch.diff(nil, thread)} | notes])

        World.await_row(id, & &1)
        id
      end

    for id <- ids, do: idle_stop(id)
    # Rows from before the restart must not stand in for rebuilt ones.
    HalC2.Shell.online_nodes()
    flush_rows()

    sql!(
      context,
      "DELETE FROM shell WHERE stream IN (SELECT key FROM streams WHERE id LIKE 'th-old-%')"
    )

    sql!(
      context,
      "DELETE FROM snapshots WHERE stream IN (SELECT key FROM streams WHERE id LIKE 'th-old-%')"
    )

    stored = Store.list_shell(context.node.store)
    for id <- ids, do: refute(List.keyfind(stored, id, 0))
    Map.put(context, :old_threads, ids)
  end

  step "it rebuilds their rows without delaying startup", context do
    [_, slow] = context.old_threads
    # Startup returned before the slow row existed: it arrives as a later update.
    row = await_update(slow)
    assert row["title"] == "old 2"

    stored = Store.list_shell(context.node.store)
    for id <- context.old_threads, do: assert({^id, "thread", _} = List.keyfind(stored, id, 0))
    context
  end

  # --- message index --------------------------------------------------------------------

  step "threads written before the message index existed", context do
    context =
      context
      |> World.add_message("main", "user", "where is the flux capacitor")
      |> World.create_thread("other")
      |> World.add_message("other", "assistant", "the flux capacitor is in the garage")

    # Index casts land before this call returns.
    Store.path()
    sql!(context, "DELETE FROM messages")
    sql!(context, "DELETE FROM meta WHERE key = 'messages_indexed'")
    assert Store.search_messages(context.node.store, "%flux%", 10) == []
    context
  end

  step "their finished messages are indexed once", context do
    backfill()
    found = Store.search_messages(context.node.store, "%flux%", 10)

    assert found |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
             Enum.sort([World.thread_id(context, "main"), World.thread_id(context, "other")])

    assert Store.meta(context.node.store, "messages_indexed") == "1"

    # A later start does not index them again.
    sql!(context, "DELETE FROM messages")
    backfill()
    assert Store.search_messages(context.node.store, "%flux%", 10) == []
    sql!(context, "DELETE FROM meta WHERE key = 'messages_indexed'")
    backfill()
    context
  end

  step "search finds them", context do
    {result, context} = World.call!(context, "orchestration.searchThreads", %{"query" => "flux"})
    threads = for match <- result["matches"], do: {match["threadId"], match["source"]}

    assert Enum.sort(threads) ==
             Enum.sort([
               {World.thread_id(context, "main"), "user"},
               {World.thread_id(context, "other"), "assistant"}
             ])

    context
  end

  # --- schema version -------------------------------------------------------------------

  step "a node opens its store", context do
    %{context | node: Node.restart(context.node), clients: %{}}
  end

  step "the store carries the schema version it was written with", context do
    assert Store.meta(context.node.store, "schema_version") ==
             Integer.to_string(Store.schema_version())

    context
  end

  step "a store written by a newer node schema", context do
    newer = Store.schema_version() + 1
    :ok = Store.put_meta("schema_version", Integer.to_string(newer))
    Map.put(context, :newer, newer)
  end

  step "an older node opens it", context do
    for child <- [HalC2.Web, HalC2.Shell, HalC2.Streams, HalC2.Auth, HalC2.Store],
        do: ExUnit.Callbacks.stop_supervised(child)

    Map.put(
      context,
      :opened,
      ExUnit.Callbacks.start_supervised({Store, path: context.node.store})
    )
  end

  step "it refuses to start and names the version it found", context do
    assert {:error, {{:newer_schema, message}, _child}} = context.opened
    assert message =~ "schema version #{context.newer}"
    refute Process.whereis(Store)
    # The file is left as it was.
    assert Store.meta(context.node.store, "schema_version") == Integer.to_string(context.newer)
    context
  end

  # --- helpers --------------------------------------------------------------------------

  defp dispatch(command),
    do:
      HalC2.Orchestration.dispatch(
        Map.put_new(command, "commandId", "cmd-#{System.unique_integer([:positive])}")
      )

  defp commit(context, changes) do
    {:ok, seq} = Streams.commit(World.thread_id(context, "main"), :thread, changes)
    seq
  end

  defp thread_state(context),
    do: Streams.Server.state(Streams.ensure(World.thread_id(context, "main")))

  defp log(context, id, after_seq \\ 0),
    do: Store.reduce_stream(context.node.store, id, after_seq, [], &[&1 | &2]) |> Enum.reverse()

  defp sub(client, id, stream, offset \\ nil) do
    shape = %{"type" => "stream", "node" => Atom.to_string(node()), "stream" => stream}
    frame = %{"t" => "sub", "id" => id, "shape" => shape}
    WsClient.send_json(client, if(offset, do: Map.put(frame, "offset", offset), else: frame))
  end

  # The stored bytes of one event's patch.
  defp raw_patch(context, seq) do
    with_db(context, [mode: :readonly], fn db ->
      {:ok, stmt} = Sqlite3.prepare(db, "SELECT patch FROM events WHERE seq = ?1")
      :ok = Sqlite3.bind(stmt, [seq])
      {:row, [patch]} = Sqlite3.step(db, stmt)
      patch
    end)
  end

  # Test setup that edits the scenario's own store file directly.
  defp sql!(context, statement) do
    with_db(context, [], fn db ->
      :ok = Sqlite3.execute(db, "PRAGMA busy_timeout = 5000")
      :ok = Sqlite3.execute(db, statement)
    end)
  end

  defp with_db(context, opts, fun) do
    {:ok, db} = Sqlite3.open(context.node.store, opts)

    try do
      fun.(db)
    after
      Sqlite3.close(db)
    end
  end

  # Lets a stream process go idle, as it does after `idle_stop` with no subscribers.
  defp idle_stop(id) do
    pid = Streams.ensure(id)
    ref = Process.monitor(pid)
    send(pid, :timeout)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
  end

  defp flush_rows do
    receive do
      {:hal_c2_shell, _} -> flush_rows()
    after
      0 -> :ok
    end
  end

  defp row_frames(client, id, title, acc) do
    {frame, client} =
      Node.await(
        client,
        &(&1["t"] == "shell.rows" and Enum.any?(&1["rows"], fn [row_id | _] -> row_id == id end)),
        3_000
      )

    at = System.monotonic_time(:millisecond)
    [_, _, row] = Enum.find(frame["rows"], fn [row_id | _] -> row_id == id end)
    acc = [{at, row} | acc]

    if row["title"] == title,
      do: {Enum.reverse(acc), client},
      else: row_frames(client, id, title, acc)
  end

  defp await_update(id) do
    receive do
      {:hal_c2_shell, {:rows, _, rows}} ->
        case List.keyfind(rows, id, 0) do
          {^id, {"thread", row}} -> row
          nil -> await_update(id)
        end
    after
      5_000 -> flunk("#{id}'s row was never rebuilt after startup")
    end
  end

  # Indexes old messages as the application does once at startup.
  defp backfill do
    :ok = HalC2.Search.backfill()
    Store.path()
  end
end
