defmodule HalC2.Steps.Platform.EventStore do
  @moduledoc "Steps for features/mc/platform/event-store.feature."
  use Cucumber.StepDefinition
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [start_supervised!: 1, stop_supervised!: 1]

  alias Exqlite.Sqlite3
  alias HalC2.{Doctor, Store, StreamState, Streams}
  alias HalC2.Projection.Check
  alias HalC2.Store.{Compaction, Compactor}
  alias HalC2.Test.{Mc, WsClient}
  alias HalC2.Test.Mc.World

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
    assert StreamState.get(StreamState.load(context.mc.store, id), "provider-session") == %{}
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
          Store.reduce_stream(context.mc.store, id, 0, 0, fn _event, count ->
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

  step "the store's writer is busy", context do
    :ok = :sys.suspend(Store)
    ExUnit.Callbacks.on_exit(fn -> if Process.whereis(Store), do: :sys.resume(Store) end)
    context
  end

  step "a thread is used for the first time", context do
    Map.put(context, :started, Streams.ensure("thread-#{System.unique_integer([:positive])}"))
  end

  step "it starts without waiting for the writer", context do
    assert Process.alive?(context.started)
    :ok = :sys.resume(Store)
    context
  end

  # --- a slow store ---------------------------------------------------------------------

  step("a turn is running in the thread", context, do: World.running_turn(context, "main"))

  # The fake Codex answers this turn once the scenario writes the gate file "answer".
  step "a turn is running in the thread, about to answer", context do
    gate = Mc.tmp_dir(context.mc, "gate")
    fake = Path.expand("../../support/fake_codex.py", __DIR__)
    World.put_app_env(:codex_command, ["env", "FAKE_CODEX_GATE=#{gate}", "python3", "-u", fake])

    context
    |> World.running_turn("main", "answer from gate")
    |> Map.put(:gate, gate)
  end

  # Every write the store holds up logs at once, as one held up past the threshold does.
  step "the store's writer is stalled", context do
    World.put_app_env(:store_slow_write_ms, 0)
    HalC2.Test.LogTap.attach()
    :ok = :sys.suspend(Store)
    ExUnit.Callbacks.on_exit(fn -> if Process.whereis(Store), do: :sys.resume(Store) end)
    context
  end

  step "the agent answers and ends its turn", context do
    File.write!(Path.join(context.gate, "answer"), "done")
    context
  end

  step "the user asks to stop the turn", context do
    test = self()

    command = %{
      "type" => "run.interrupt",
      "commandId" => "cmd-#{System.unique_integer([:positive])}",
      "threadId" => World.thread_id(context, "main"),
      "runId" => context.running
    }

    spawn(fn -> send(test, {:stopped, HalC2.Orchestration.dispatch(command)}) end)
    context
  end

  step "the MC logs that the store is slow", context do
    assert_receive {:logged, :warning, "a store append has waited" <> _}, 5_000

    assert [{runtime, _}] =
             Registry.lookup(HalC2.Codex.Registry, World.thread_id(context, "main"))

    assert Process.alive?(runtime)
    context
  end

  step "the turn completes once the store catches up", context do
    resume_store()
    World.await_runs(context, "main", ["completed"])
    context
  end

  step "the turn is interrupted once the store catches up", context do
    resume_store()
    assert_receive {:stopped, {:ok, _}}, 5_000
    World.await_runs(context, "main", ["interrupted"])
    context
  end

  defp resume_store do
    Application.delete_env(:hal_c2, :store_slow_write_ms)
    :ok = :sys.resume(Store)
  end

  # --- snapshots ------------------------------------------------------------------------

  step "a thread receives 500 more events", context do
    commit(context, for(n <- 1..500, do: {"note", "n-#{n}", %{"s" => %{"text" => "note #{n}"}}}))
    context
  end

  step "the MC writes a snapshot of its folded state", context do
    id = World.thread_id(context, "main")
    state = thread_state(context)
    idle_stop(id)
    assert {seq, %StreamState{} = snapshot} = Store.get_snapshot(context.mc.store, id)
    assert seq == state.seq
    # Where the stream's cold rows are is not part of it.
    assert snapshot == %{state | src: nil}
    context
  end

  step "a thread's snapshot is missing", context do
    id = World.thread_id(context, "main")
    commit(context, for(n <- 1..500, do: {"note", "n-#{n}", %{"s" => %{"text" => "note #{n}"}}}))
    expected = thread_state(context)
    idle_stop(id)
    assert Store.get_snapshot(context.mc.store, id)
    sql!(context, "DELETE FROM hot_snapshots")
    sql!(context, "DELETE FROM cold")
    assert Store.get_snapshot(context.mc.store, id) == nil
    Map.put(context, :expected, expected)
  end

  step "a client subscribes to the thread", context do
    id = World.thread_id(context, "main")
    client = sub(World.client(context), 1, id)
    {live, frames, client} = WsClient.recv_until(client, &(&1["t"] == "live" and &1["id"] == 1))
    rows = for %{"t" => "snapshot", "rows" => rows} <- frames, row <- rows, do: row
    context |> World.put_client(client) |> Map.merge(%{live: live, rows: rows})
  end

  step "the MC folds the log again", context do
    id = World.thread_id(context, "main")
    state = thread_state(context)
    assert state == StreamState.load(context.mc.store, id)
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

  step "a thread's snapshot was written by an older MC", context do
    id = World.thread_id(context, "main")
    state = thread_state(context)
    idle_stop(id)

    # v1 state had no creation order, nor a record of what changed when.
    old =
      state
      |> Map.from_struct()
      |> Map.drop([:created, :changed, :deleted, :since])
      |> Map.merge(%{__struct__: StreamState, v: 1})

    put_legacy(context, id, state.seq, old)
    Map.put(context, :expected, state)
  end

  step "the MC loads the thread", context do
    Map.put(context, :loaded, thread_state(context))
  end

  step "the snapshot is migrated to the current format", context do
    loaded = context.loaded
    assert %StreamState{v: 4, created: created} = loaded
    # Loaded from the snapshot (a fold of the log records creation order).
    assert created == %{}
    # Nothing is known of what changed before the snapshot: a client behind it starts over.
    assert loaded.since == loaded.seq
    assert StreamState.changed_since(loaded, loaded.seq - 1) == :unknown
    assert loaded.entities == context.expected.entities
    assert loaded.seq == context.expected.seq
    # Migrated once: the older MC's snapshot gives way to the current one.
    id = World.thread_id(context, "main")
    assert {_, %StreamState{v: 4}} = Store.get_snapshot(context.mc.store, id)
    assert Store.legacy_snapshot(context.mc.store, id, 1_000_000_000) == nil
    context
  end

  # --- hot and cold ---------------------------------------------------------------------

  step "a thread has finished {int} runs of {int} items while memory holds {int}",
       %{args: [runs, items, hot]} = context do
    previous = Application.get_env(:hal_c2, :stream_hot_items)
    Application.put_env(:hal_c2, :stream_hot_items, hot)

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:hal_c2, :stream_hot_items, previous),
        else: Application.delete_env(:hal_c2, :stream_hot_items)
    end)

    id = World.thread_id(context, "main")
    # The thread's stream started before memory was made this small.
    idle_stop(id)

    for i <- 1..runs do
      run = "run-cold-#{i}"

      commit(context, [
        {"run", run, %{"s" => %{"id" => run, "ordinal" => 1_000 + i, "status" => "running"}}},
        {"message", "#{run}-m",
         %{"s" => %{"id" => "#{run}-m", "runId" => run, "text" => "q#{i}"}}}
        | for(
            j <- 1..items,
            do:
              {"turn-item", "#{run}-#{j}",
               %{
                 "s" => %{
                   "id" => "#{run}-#{j}",
                   "runId" => run,
                   "threadId" => id,
                   "text" => "#{i}.#{j}"
                 }
               }}
          )
      ])

      commit(context, [{"run", run, %{"s" => %{"status" => "completed"}}}])
    end

    Map.put(context, :hot, hot)
  end

  step "the MC holds only the latest runs' items in memory", context do
    state = thread_state(context)
    assert state.floor != nil
    assert map_size(StreamState.get(state, "turn-item")) <= 2 * context.hot
    context
  end

  step "the client receives every entity of a fold of the log", context do
    whole =
      context.mc.store
      |> Store.reduce_stream(
        World.thread_id(context, "main"),
        0,
        StreamState.new(),
        &StreamState.apply_event(&2, &1)
      )

    expected =
      for {kind, id, entity} <- StreamState.rows(whole),
          do: [kind, id, HalC2.Web.Wire.entity(kind, entity)]

    assert Enum.sort(context.rows) == Enum.sort(expected)
    context
  end

  step "a client reads the thread's entities {int} at a time", %{args: [limit]} = context do
    id = World.thread_id(context, "main")

    {rows, pages, context} = read_rows(context, id, limit, nil, [], 0)
    Map.merge(context, %{rows: rows, pages: pages, limit: limit})
  end

  step "pages of {int} rows", %{args: [page]} = context do
    Application.put_env(:hal_c2, :thread_rows_page, page)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :thread_rows_page) end)
    Map.put(context, :page, page)
  end

  step "a client from before paging reads the thread's entities", context do
    {reply, context} =
      World.call!(context, "hal-c2.threadRows", %{"threadId" => World.thread_id(context, "main")})

    assert reply["next"] == nil
    Map.merge(context, %{rows: reply["rows"], pages: 1})
  end

  step "it got each entity once in the order they were created, in one reply", context do
    assert context.pages == 1 and length(context.rows) > context.page
    each_entity_once(context)
  end

  step "it took more than one page, each entity once in the order they were created",
       context do
    assert context.pages > 1
    each_entity_once(context)
  end

  defp each_entity_once(context) do
    whole =
      Store.reduce_stream(
        context.mc.store,
        World.thread_id(context, "main"),
        0,
        StreamState.new(),
        &StreamState.apply_event(&2, &1)
      )

    assert context.rows ==
             for(
               {kind, id, entity} <- StreamState.rows(whole),
               do: [kind, id, HalC2.Web.Wire.entity(kind, entity)]
             )

    context
  end

  step "the thread's older runs are read from disk after a restart", context do
    id = World.thread_id(context, "main")
    idle_stop(id)
    state = thread_state(context)
    assert state.floor != nil
    assert StreamState.fetch(state, "turn-item", "run-cold-1-1")["text"] == "1.1"

    assert Enum.count(StreamState.all(state, "turn-item")) >=
             map_size(StreamState.get(state, "turn-item"))

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
      assert state == StreamState.load(context.mc.store, id)
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
             List.keyfind(Store.list_shell(context.mc.store), id, 0)

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

    {_, client} = Mc.await(client, &(&1["t"] == "shell" and &1["id"] == 2))

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
    HalC2.Shell.online_mcs()
    flush_rows()

    sql!(
      context,
      "DELETE FROM shell WHERE stream IN (SELECT key FROM streams WHERE id LIKE 'th-old-%')"
    )

    sql!(
      context,
      "DELETE FROM hot_snapshots WHERE stream IN (SELECT key FROM streams WHERE id LIKE 'th-old-%')"
    )

    stored = Store.list_shell(context.mc.store)
    for id <- ids, do: refute(List.keyfind(stored, id, 0))
    Map.put(context, :old_threads, ids)
  end

  step "it rebuilds their rows without delaying startup", context do
    [_, slow] = context.old_threads
    # Startup returned before the slow row existed: it arrives as a later update.
    row = await_update(slow)
    assert row["title"] == "old 2"

    stored = Store.list_shell(context.mc.store)
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
    sql!(context, "DELETE FROM meta WHERE key = 'messages_typed'")
    assert Store.search_messages(context.mc.store, "%flux%", 10) == []
    context
  end

  step "their finished messages are indexed once", context do
    backfill()
    found = Store.search_messages(context.mc.store, "%flux%", 10)

    assert found |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
             Enum.sort([World.thread_id(context, "main"), World.thread_id(context, "other")])

    assert Store.meta(context.mc.store, "messages_typed") == "1"

    # A later start does not index them again.
    sql!(context, "DELETE FROM messages")
    backfill()
    assert Store.search_messages(context.mc.store, "%flux%", 10) == []
    sql!(context, "DELETE FROM meta WHERE key = 'messages_typed'")
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

  # --- WAL checkpoints ------------------------------------------------------------------

  step "the store's writer never checkpoints the WAL itself", context do
    %{db: db} = :sys.get_state(Store)
    {:ok, stmt} = Sqlite3.prepare(db, "PRAGMA wal_autocheckpoint")
    assert {:ok, [[0]]} = Sqlite3.fetch_all(db, stmt)
    Sqlite3.release(db, stmt)
    context
  end

  step "a checkpoint from its own connection copies the changes into the database", context do
    assert {:ok, %{log: log, checkpointed: checkpointed}} = Store.checkpoint()
    assert log > 0 and checkpointed > 0
    context
  end

  step "that connection closes when the store stops", context do
    ref = Process.monitor(:sys.get_state(Store).checkpointer)
    context = %{context | mc: Mc.restart(context.mc), clients: %{}}
    assert_receive {:DOWN, ^ref, :process, _, _}
    context
  end

  # --- schema version -------------------------------------------------------------------

  step "an MC opens its store", context do
    %{context | mc: Mc.restart(context.mc), clients: %{}}
  end

  step "the store carries the schema version it was written with", context do
    assert Store.meta(context.mc.store, "schema_version") ==
             Integer.to_string(Store.schema_version())

    context
  end

  step "a store written by a newer MC schema", context do
    newer = Store.schema_version() + 1
    :ok = Store.put_meta("schema_version", Integer.to_string(newer))
    Map.put(context, :newer, newer)
  end

  step "an older MC opens it", context do
    for child <- [
          HalC2.Orchestration.Wake,
          HalC2.RuntimeRecord,
          HalC2.Web,
          HalC2.Shell,
          HalC2.Streams,
          HalC2.Auth,
          HalC2.Store
        ],
        do: ExUnit.Callbacks.stop_supervised(child)

    Map.put(
      context,
      :opened,
      ExUnit.Callbacks.start_supervised({Store, path: context.mc.store})
    )
  end

  step "it refuses to start and names the version it found", context do
    assert {:error, {{:newer_schema, message}, _child}} = context.opened
    assert message =~ "schema version #{context.newer}"
    refute Process.whereis(Store)
    # The file is left as it was.
    assert Store.meta(context.mc.store, "schema_version") == Integer.to_string(context.newer)
    context
  end

  # --- table statistics -----------------------------------------------------------------

  step "a store with no table statistics", context do
    context = stopped(context)
    sql!(context, "DROP TABLE IF EXISTS sqlite_stat1")
    assert stat_tables(context) == []
    Map.put(context, :stopped_at, System.monotonic_time(:millisecond))
  end

  step "it opens the store without reading through its tables", context do
    # ANALYZE, or PRAGMA optimize on a store without statistics, reads every table and
    # leaves what it found in sqlite_stat1.
    assert stat_tables(context) == []
    context
  end

  step "it accepts clients within a second of opening the store", context do
    client = Mc.config(Mc.connect(context.mc))
    assert System.monotonic_time(:millisecond) - context.stopped_at < 1_000
    World.put_client(context, client)
  end

  # --- checking projections -------------------------------------------------------------

  step "a thread in the log has no projection", context do
    context = stopped(context)
    id = World.thread_id(context, "main")
    sql!(context, "DELETE FROM shell WHERE stream = #{key(id)}")
    Map.put(context, :faults, [{:missing, id}])
  end

  step "a projection exists for a thread the log never created", context do
    context = stopped(context)
    sql!(context, "INSERT INTO streams (id, kind) VALUES ('th-ghost', 'thread')")

    sql!(context, """
    INSERT INTO shell (stream, seq, kind, row)
    SELECT #{key("th-ghost")}, seq, kind, row FROM shell WHERE stream = #{key(World.thread_id(context, "main"))}
    """)

    Map.put(context, :faults, [{:unexpected, "th-ghost"}])
  end

  step "a thread's stored projection can no longer be read", context do
    context = stopped(context)
    id = World.thread_id(context, "main")
    put_snapshot_bytes(context, id, <<0>>)
    Map.put(context, :faults, [{:unreadable, id}])
  end

  step "a fork's source thread can no longer be read", context do
    source = World.thread_id(context, "main")
    fork = "th-fork"

    thread = %{
      "id" => fork,
      "projectId" => World.project(context).id,
      "title" => "fork",
      "forkedFrom" => %{"type" => "run", "threadId" => source, "runId" => "run-1"}
    }

    {:ok, _} = Streams.commit(fork, :thread, [{"thread", fork, HalC2.Patch.diff(nil, thread)}])
    World.await_row(fork, & &1)
    context = stopped(context)
    put_snapshot_bytes(context, source, <<0>>)
    Map.put(context, :faults, [{:unreadable, source}, {:unreadable_source, source, fork}])
  end

  step "the projections stopped at an earlier sequence than the log", context do
    context = stopped(context)
    id = World.thread_id(context, "main")
    sql!(context, "UPDATE shell SET seq = 1 WHERE stream = #{key(id)}")
    [%{seq: last} | _] = context |> log(id) |> Enum.reverse()
    Map.put(context, :faults, [{:behind, id, 1, last}])
  end

  step "the projections were written by another projection format", context do
    context = stopped(context)
    id = World.thread_id(context, "main")
    put_snapshot_bytes(context, id, :erlang.term_to_binary(%{v: 99}))
    Map.put(context, :faults, [{:format, id, 99}])
  end

  step "the projections are checked against the log", context do
    Map.put(context, :problems, Check.run(context.mc.store))
  end

  for report <- [
        "the missing thread",
        "the unexpected thread",
        "the unreadable thread",
        "the source and the fork as unreadable",
        "the sequence they are at and the log's",
        "the format version it found"
      ] do
    step "the check fails and names #{report}", context do
      assert context.problems == Enum.sort(context.faults)
      for problem <- context.problems, do: assert(Check.describe(problem) =~ elem(problem, 1))
      context
    end
  end

  # --- rebuilding projections -----------------------------------------------------------

  step "the projections of the MC are damaged", context do
    Application.put_env(:hal_c2, :stream_hot_items, 2)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :stream_hot_items) end)
    id = World.thread_id(context, "main")
    # The stream started before memory was made this small.
    idle_stop(id)

    for i <- 1..3 do
      run = "run-#{i}"

      commit(context, [
        {"run", run, %{"s" => %{"id" => run, "ordinal" => i, "status" => "running"}}},
        {"message", "#{run}-m",
         %{
           "s" => %{
             "id" => "#{run}-m",
             "runId" => run,
             "role" => "user",
             "text" => "question #{i} about flux"
           }
         }}
        | for(
            j <- 1..3,
            do:
              {"turn-item", "#{run}-#{j}",
               %{
                 "s" => %{
                   "id" => "#{run}-#{j}",
                   "runId" => run,
                   "threadId" => id,
                   "text" => "#{i}.#{j}"
                 }
               }}
          )
      ])

      commit(context, [{"run", run, %{"s" => %{"status" => "completed"}}}])
    end

    state = thread_state(context)
    expected = entities(state)
    order = for {"turn-item", item, _} <- StreamState.rows(state), do: item
    assert length(order) == 9
    context = stopped(context)

    for sql <- [
          "DELETE FROM shell",
          "UPDATE hot_snapshots SET state = x'00'",
          "DELETE FROM cold",
          "DELETE FROM messages"
        ],
        do: sql!(context, sql)

    assert Check.run(context.mc.store) != []
    Map.merge(context, %{expected: expected, order: order})
  end

  step "the projections are rebuilt", context do
    start_supervised!({Store, path: context.mc.store})
    Map.put(context, :rebuilt, Check.rebuild())
  end

  step "every thread, run, message and timeline item is derived again from the log", context do
    id = World.thread_id(context, "main")
    assert id in context.rebuilt
    state = StreamState.load(context.mc.store, id)
    assert entities(state) == context.expected
    assert [_ | _] = Store.search_messages(context.mc.store, "%flux%", 10)
    Map.put(context, :loaded, state)
  end

  step "timeline items keep the order they first had", context do
    assert for({"turn-item", item, _} <- StreamState.rows(context.loaded), do: item) ==
             context.order

    context
  end

  step "the check against the log passes", context do
    assert Check.run(context.mc.store) == []
    context
  end

  # --- compaction -----------------------------------------------------------------------

  step "a thread was renamed, pinned, linked to pull requests and visited many times and its messages streamed in many updates",
       context do
    id = World.thread_id(context, "main")

    for i <- 1..3 do
      for command <- [
            %{"type" => "thread.metadata.update", "title" => "title #{i}"},
            %{"type" => "thread.pin"},
            %{"type" => "thread.unpin"},
            %{"type" => "thread.visit", "visitedAt" => World.iso_from_now(i * 1_000)}
          ],
          do: {:ok, _} = dispatch(Map.put(command, "threadId", id))

      link = %{"host" => "github.com", "repository" => "o/r", "number" => i, "url" => "u#{i}"}
      commit(context, [{"thread", id, %{"s" => %{"pullRequests" => [link]}}}])
    end

    for m <- ["m-1", "m-2"], do: stream_message(context, m, 10, 10)

    commit(context, [
      {"run", "run-1", %{"s" => %{"id" => "run-1", "status" => "running"}}},
      {"turn-item", "i-1", %{"s" => %{"id" => "i-1", "runId" => "run-1", "text" => "a"}}}
    ])

    commit(context, [{"turn-item", "i-1", %{"a" => %{"text" => "b"}}}])
    commit(context, [{"run", "run-1", %{"s" => %{"status" => "completed"}}}])
    context
  end

  step "the thread was deleted", context do
    id = World.thread_id(context, "main")
    # As `thread.delete` marks its thread.
    commit(context, [{"thread", id, %{"s" => %{"deletedAt" => World.iso_from_now(0)}}}])
    state = thread_state(context)

    Map.merge(context, %{
      before: log(context, id),
      entities_before: entities(state),
      row_before: HalC2.Projection.row(context.mc.store, id, state)
    })
  end

  # Said of a compaction a step runs, and of the one the MC runs in the background.
  step "the log is compacted", context do
    if context[:background] do
      assert_receive {:compacted, %{events: events}} when events > 0, 5_000
      context
    else
      id = World.thread_id(context, "main")
      context = Map.put_new_lazy(context, :before, fn -> log(context, id) end)
      Map.put(context, :compaction, Compaction.run(Store, all: true))
    end
  end

  step "of the thread's updates only its creation and its deletion are kept", context do
    id = World.thread_id(context, "main")
    written = for %{kind: "thread"} = e <- context.before, do: e
    kept = for %{kind: "thread"} = e <- log(context, id), do: e
    assert [hd(written).seq, List.last(written).seq] == Enum.map(kept, & &1.seq)
    assert %{"s" => %{"deletedAt" => _, "title" => "title 3"}} = List.last(kept).patch
    context
  end

  step "the oldest and the newest update of each message are kept", context do
    after_compaction = log(context, World.thread_id(context, "main"))

    for m <- ["m-1", "m-2"] do
      written = for %{kind: "message", entity: ^m} = e <- context.before, do: e.seq
      kept = for %{kind: "message", entity: ^m} = e <- after_compaction, do: e.seq
      assert length(written) == 12
      assert kept == [hd(written), List.last(written)]
    end

    context
  end

  step "its runs and every timeline item update stay in the log", context do
    stays = &(&1.kind in ["run", "turn-item"])
    after_compaction = log(context, World.thread_id(context, "main"))
    assert Enum.filter(after_compaction, stays) == Enum.filter(context.before, stays)
    assert length(Enum.filter(after_compaction, stays)) == 4
    context
  end

  step "rebuilding the projections gives the same threads as before", context do
    id = World.thread_id(context, "main")
    context = stopped(context)
    start_supervised!({Store, path: context.mc.store})
    Check.rebuild()

    assert entities(StreamState.load(context.mc.store, id)) == context.entities_before
    {kind, row} = context.row_before
    assert {id, kind, row} == List.keyfind(Store.list_shell(context.mc.store), id, 0)
    assert Check.run(context.mc.store) == []
    context
  end

  step "a thread was renamed and then visited", context do
    id = World.thread_id(context, "main")

    {:ok, %{"sequence" => renamed}} =
      dispatch(%{"type" => "thread.metadata.update", "threadId" => id, "title" => "Renamed"})

    visits =
      for {type, n} <- [visit: 1, visit: 2, unread: 3, visit: 4] do
        command =
          if type == :visit,
            do: %{"type" => "thread.visit", "visitedAt" => World.iso_from_now(n * 1_000)},
            else: %{"type" => "thread.mark-unread"}

        {:ok, %{"sequence" => seq}} = dispatch(Map.put(command, "threadId", id))
        seq
      end

    before = log(context, id)
    assert Enum.all?(visits, fn seq -> Enum.find(before, &(&1.seq == seq)).patch["q"] end)
    Map.merge(context, %{renamed: renamed, visits: visits, before: before})
  end

  step "the rename stays in the log", context do
    after_compaction = log(context, World.thread_id(context, "main"))
    rename = Enum.find(context.before, &(&1.seq == context.renamed))
    assert Enum.find(after_compaction, &(&1.seq == context.renamed)) == rename
    assert fold(after_compaction).updated_at == fold(context.before).updated_at
    assert fold(after_compaction).updated_at == rename.at
    context
  end

  step "of the visits and marks as unread only the newest is kept", context do
    after_compaction = log(context, World.thread_id(context, "main"))
    quiet = for %{kind: "thread", patch: %{"q" => true}} = e <- after_compaction, do: e.seq
    assert quiet == [List.last(context.visits)]
    assert fold(after_compaction).entities == fold(context.before).entities
    context
  end

  step "a client last read the log at an offset before many messages were streamed", context do
    id = World.thread_id(context, "main")
    client = sub(World.client(context), 1, id)
    {live, _, client} = WsClient.recv_until(client, &(&1["t"] == "live" and &1["id"] == 1))
    Mc.unsub(client, 1)
    offset = live["offset"]
    for m <- ["m-1", "m-2", "m-3"], do: stream_message(context, m, 20, 10)
    known = context |> log(id) |> Enum.take_while(&(&1.seq <= offset)) |> fold()
    context |> World.put_client(client) |> Map.merge(%{offset: offset, known: known})
  end

  step "the log was compacted since", context do
    whole = fold(log(context, World.thread_id(context, "main")))
    assert %{events: removed} = Compaction.run(Store, all: true)
    assert removed > 0
    Map.put(context, :whole, whole)
  end

  step "the client resumes from its offset", context do
    id = World.thread_id(context, "main")
    client = sub(World.client(context, "resuming"), 2, id, context.offset)
    {_live, frames, client} = WsClient.recv_until(client, &(&1["t"] == "live" and &1["id"] == 2))
    refute Enum.any?(frames, &(&1["t"] == "snapshot" and &1["id"] == 2))

    resumed =
      for %{"t" => "events", "id" => 2, "events" => events} <- frames,
          [seq, kind, entity, patch, at] <- events,
          reduce: context.known,
          do: (state ->
                 StreamState.apply_event(state, %{
                   seq: seq,
                   kind: kind,
                   entity: entity,
                   patch: patch,
                   at: at
                 }))

    context |> World.put_client("resuming", client) |> Map.put(:resumed, resumed)
  end

  step "it ends with the same threads and messages, in the same order, as a client that read every event",
       context do
    assert Enum.to_list(StreamState.rows(context.resumed)) ==
             Enum.to_list(StreamState.rows(context.whole))

    assert context.resumed.updated_at == context.whole.updated_at

    # And a client reading the thread now gets the same rows.
    client = sub(World.client(context, "fresh"), 3, World.thread_id(context, "main"))
    {_, frames, client} = WsClient.recv_until(client, &(&1["t"] == "live" and &1["id"] == 3))
    rows = for %{"t" => "snapshot", "id" => 3, "rows" => rows} <- frames, row <- rows, do: row

    assert rows ==
             for(
               {kind, id, entity} <- StreamState.rows(context.whole),
               do: [kind, id, HalC2.Web.Wire.entity(kind, entity)]
             )

    World.put_client(context, "fresh", client)
  end

  step "the MC has been running for one minute", context do
    stream_message(context, "m-big", 200, 2_000)
    assert Store.space(context.mc.store).vacuum == :incremental
    start_supervised!({Compactor, after: 0, every: 50, gap: 0, pages: 8, notify: self()})
    Map.put(context, :background, true)
  end

  step "it is compacted again every six hours after that", context do
    assert Compactor.schedule() == {:timer.minutes(1), :timer.hours(6)}
    assert_receive {:compacted, %{events: 0}}, 5_000
    context
  end

  step "the space it frees is given back to the disk a little at a time while the MC runs",
       context do
    page = pragma(context, "page_size")
    steps = reclaimed([])
    assert length(steps) > 1
    assert steps == Enum.sort(steps, :desc) and List.last(steps) == 0
    for [a, b] <- Enum.chunk_every(steps, 2, 1, :discard), do: assert(a - b <= 8 * page)
    stop_supervised!(Compactor)
    context
  end

  step "a message was streamed in many updates", context do
    stream_message(context, "m-big", 100, 2_000)
    Map.put(context, :events_before, pragma(context, "events"))
  end

  step "it reports how many events it removed", context do
    removed = context.events_before - pragma(context, "events")
    assert removed >= 100 and context.compaction.events == removed
    assert Compaction.describe(context.compaction) =~ "removed #{removed} events"
    context
  end

  step "how many bytes the store can now give back", context do
    free = Store.space(context.mc.store).free
    assert free > 0 and context.compaction.reclaimable == free
    assert Compaction.describe(context.compaction) =~ "#{free} bytes reclaimable"
    context
  end

  step "a log with many thousands of events", context do
    for m <- 1..4, do: stream_message(context, "m-#{m}", 750, 10)
    ops = Compaction.plan(context.mc.store, World.thread_id(context, "main"))
    assert length(ops) > 3_000
    Map.put(context, :ops, ops)
  end

  step "the log is compacted while clients send commands", context do
    id = World.thread_id(context, "main")
    counter = :counters.new(1, [])

    on_batch = fn ->
      :counters.add(counter, 1, 1)
      title = "batch #{:counters.get(counter, 1)}"

      assert {:ok, _} =
               dispatch(%{"type" => "thread.metadata.update", "threadId" => id, "title" => title})
    end

    report = Compaction.run(Store, all: true, on_batch: on_batch)
    Map.merge(context, %{compaction: report, batches: :counters.get(counter, 1)})
  end

  step "the commands are accepted between the batches of 50 events it works through", context do
    assert context.batches == ceil(length(context.ops) / 50)
    id = World.thread_id(context, "main")
    state = thread_state(context)
    assert StreamState.get(state, "thread")[id]["title"] == "batch #{context.batches}"
    assert view(StreamState.load(context.mc.store, id)) == view(state)
    assert view(fold(log(context, id))) == view(state)
    context
  end

  # --- doctor ---------------------------------------------------------------------------

  step "a store created before it could give space back to the disk while running", context do
    stream_message(context, "m-big", 100, 2_000)
    context = stopped(context)
    # The mode takes effect with a VACUUM on the connection that set it.
    sql!(context, "PRAGMA auto_vacuum = NONE; VACUUM")
    assert Store.space(context.mc.store).vacuum == :none

    Map.merge(context, %{
      size_before: store_size(context),
      events_before: pragma(context, "events")
    })
  end

  step "a log with events no replay needs", context do
    stream_message(context, "m-big", 20, 100)
    context = stopped(context)
    assert Compaction.removable(context.mc.store) > 0
    Map.put(context, :unchanged, unchanged(context))
  end

  step "an MC or a client has the store open", context do
    id = World.thread_id(context, "main")

    for title <- ~w(a b c),
        do:
          {:ok, _} =
            dispatch(%{"type" => "thread.metadata.update", "threadId" => id, "title" => title})

    # A client reading the store directly, as sqlite3 or a backup tool does.
    {:ok, db} = Sqlite3.open(context.mc.store, mode: :readonly)
    {:ok, stmt} = Sqlite3.prepare(db, "SELECT count(*) FROM events")
    {:row, [_]} = Sqlite3.step(db, stmt)
    :ok = Sqlite3.release(db, stmt)
    ExUnit.Callbacks.on_exit(fn -> Sqlite3.close(db) end)
    assert Compaction.removable(context.mc.store) > 0
    Map.merge(context, %{reader: db, unchanged: unchanged(context)})
  end

  step "the user runs the MC's doctor command with {string}", %{args: [flag]} = context do
    run_doctor(context, [flag])
  end

  step "the user runs the MC's doctor command with {string} and {string}",
       %{args: flags} = context do
    run_doctor(context, flags)
  end

  step "the user runs the MC's doctor command in a terminal", context do
    me = self()

    output =
      ExUnit.CaptureIO.capture_io("\n\n\n\n", fn ->
        send(me, {:doctor, Doctor.command([], path: context.mc.store, tty?: true)})
      end)

    assert_received {:doctor, result}
    Map.merge(context, %{doctor: result, output: output})
  end

  step "the user chooses the repairs, with the recommended ones chosen", context do
    asked = Regex.scan(~r/Make this repair\? \[(.)\/(.)\]/, context.output)
    assert asked != [] and Enum.all?(asked, &(&1 == ["Make this repair? [Y/n]", "Y", "n"]))
    assert {:ok, text} = context.doctor
    assert text =~ "Compacted the log: removed"
    assert Compaction.removable(context.mc.store) == 0
    context
  end

  step "the repairs are listed and nothing changes", context do
    assert {:ok, text} = context.doctor
    assert text =~ "Compact the log:" and text =~ "Nothing was changed"
    assert unchanged(context) == context.unchanged
    context
  end

  step "the projections are checked, the log is compacted and the projections are checked again",
       context do
    assert {:ok, text} = context.doctor

    lines =
      for line <- [
            "Checked the projections: they match the log",
            "Compacted the log: removed",
            "Checked the projections again: they match the log"
          ],
          do: :binary.match(text, line)

    assert Enum.all?(lines, &(&1 != :nomatch)) and lines == Enum.sort(lines)
    context
  end

  step "the store is switched to give space back while running and is shrunk", context do
    assert %{vacuum: :incremental, free: 0} = Store.space(context.mc.store)
    assert store_size(context) < context.size_before
    context
  end

  step "it reports the store's size before and after and how many events it removed", context do
    {:ok, text} = context.doctor
    assert [_, removed] = Regex.run(~r/removed (\d+) events/, text)
    assert String.to_integer(removed) == context.events_before - pragma(context, "events")
    assert String.to_integer(removed) >= 100
    assert text =~ ~r/Store size: [\d.]+ [kMG]?B(ytes)? before, [\d.]+ [kMG]?B(ytes)? after/
    context
  end

  step "a second run reports {string}", %{args: [text]} = context do
    assert Doctor.command(["--fix"], path: context.mc.store) == {:ok, text}
    context
  end

  step "it refuses and changes nothing", context do
    assert [_, _] = context.refusals

    for result <- context.refusals do
      assert {:error, message} = result
      assert message =~ "is open" and message =~ "Nothing was changed"
    end

    assert unchanged(context) == context.unchanged
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

  # Reads a thread's rows a page at a time, as a client walks `next`.
  defp read_rows(context, id, limit, cursor, rows, pages) do
    {reply, context} =
      World.call!(context, "hal-c2.threadRows", %{
        "threadId" => id,
        "after" => cursor,
        "limit" => limit
      })

    assert length(reply["rows"]) <= limit
    rows = rows ++ reply["rows"]

    if reply["next"],
      do: read_rows(context, id, limit, reply["next"], rows, pages + 1),
      else: {rows, pages + 1, context}
  end

  defp log(context, id, after_seq \\ 0),
    do: Store.reduce_stream(context.mc.store, id, after_seq, [], &[&1 | &2]) |> Enum.reverse()

  defp sub(client, id, stream, offset \\ nil) do
    shape = %{"type" => "stream", "mc" => Atom.to_string(node()), "stream" => stream}
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
    {:ok, db} = Sqlite3.open(context.mc.store, opts)

    try do
      fun.(db)
    after
      Sqlite3.close(db)
    end
  end

  # Lets a stream process go idle, as it does after `idle_stop` with no subscribers.
  # A snapshot as an older MC wrote it, in the table it wrote to.
  defp put_legacy(context, id, seq, state) do
    blob = :erlang.term_to_binary(state, [:compressed])

    with_db(context, [], fn db ->
      :ok = Sqlite3.execute(db, "PRAGMA busy_timeout = 5000")
      :ok = Sqlite3.execute(db, "DELETE FROM hot_snapshots")

      {:ok, stmt} =
        Sqlite3.prepare(db, """
        INSERT INTO snapshots (stream, seq, state) SELECT key, ?2, ?3 FROM streams WHERE id = ?1
        ON CONFLICT(stream) DO UPDATE SET seq = excluded.seq, state = excluded.state
        """)

      :ok = Sqlite3.bind(stmt, [id, seq, {:blob, blob}])
      :done = Sqlite3.step(db, stmt)
      :ok = Sqlite3.release(db, stmt)
    end)
  end

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
      Mc.await(
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

  defp stopped(context) do
    context = %{context | mc: Mc.stop(context.mc), clients: %{}}
    # A clean stop leaves every projection matching the log.
    assert Check.run(context.mc.store) == []
    context
  end

  defp key(id), do: "(SELECT key FROM streams WHERE id = '#{id}')"

  defp put_snapshot_bytes(context, id, bytes) do
    sql!(context, """
    INSERT INTO hot_snapshots (stream, seq, state) VALUES (#{key(id)}, 1, x'#{Base.encode16(bytes)}')
    ON CONFLICT(stream) DO UPDATE SET state = excluded.state
    """)
  end

  defp stat_tables(context) do
    with_db(context, [mode: :readonly], fn db ->
      {:ok, stmt} =
        Sqlite3.prepare(db, "SELECT name FROM sqlite_master WHERE name LIKE 'sqlite_stat%'")

      {:ok, rows} = Sqlite3.fetch_all(db, stmt)
      rows
    end)
  end

  # `"events"` counts the log; anything else is a PRAGMA.
  defp pragma(context, name) do
    sql = if name == "events", do: "SELECT count(*) FROM events", else: "PRAGMA #{name}"

    with_db(context, [mode: :readonly], fn db ->
      {:ok, stmt} = Sqlite3.prepare(db, sql)
      {:ok, [[value]]} = Sqlite3.fetch_all(db, stmt)
      value
    end)
  end

  defp entities(state),
    do:
      Map.new(
        ~w(thread run message turn-item),
        &{&1, Enum.sort_by(StreamState.all(state, &1), fn entity -> entity["id"] end)}
      )

  # A message streamed as an agent writes one: created, `appends` chunks of `size`
  # characters, then finished, each its own event.
  defp stream_message(context, id, appends, size) do
    message = %{"id" => id, "role" => "assistant", "text" => "", "streaming" => true}
    commit(context, [{"message", id, %{"s" => message}}])

    for _ <- 1..appends do
      chunk = binary_part(Base.encode64(:crypto.strong_rand_bytes(size)), 0, size)
      commit(context, [{"message", id, %{"a" => %{"text" => chunk}}}])
    end

    commit(context, [{"message", id, %{"s" => %{"streaming" => false}}}])
  end

  defp fold(events), do: Enum.reduce(events, StreamState.new(), &StreamState.apply_event(&2, &1))

  defp view(state),
    do: Map.take(state, [:seq, :updated_at, :entities, :created, :changed, :deleted])

  defp reclaimed(steps) do
    receive do
      {:reclaimed, 0} -> Enum.reverse([0 | steps])
      {:reclaimed, free} -> reclaimed([free | steps])
    after
      5_000 -> flunk("the store stopped giving space back at #{inspect(steps)}")
    end
  end

  defp store_size(context) do
    for file <- [context.mc.store, context.mc.store <> "-wal"],
        {:ok, %{size: size}} <- [File.stat(file)],
        reduce: 0,
        do: (total -> total + size)
  end

  # What a repair would change: the log, what compaction would remove, and how the store
  # gives space back.
  defp unchanged(context) do
    %{
      events: pragma(context, "events"),
      log: log(context, World.thread_id(context, "main")),
      removable: Compaction.removable(context.mc.store),
      vacuum: Store.space(context.mc.store).vacuum
    }
  end

  # With a client reading the store, the doctor runs once with the MC up and once with
  # only the client left.
  defp run_doctor(%{reader: _} = context, args) do
    with_mc = Doctor.command(args, path: context.mc.store)
    context = stopped(context)
    Map.put(context, :refusals, [with_mc, Doctor.command(args, path: context.mc.store)])
  end

  defp run_doctor(context, args),
    do: Map.put(context, :doctor, Doctor.command(args, path: context.mc.store))
end
