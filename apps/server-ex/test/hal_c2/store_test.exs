defmodule HalC2.StoreTest do
  use ExUnit.Case, async: false

  alias HalC2.Store
  alias Exqlite.Sqlite3

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "hal-c2.sqlite")
    start_supervised!({Store, path: path})
    %{path: path}
  end

  defp change(id), do: {"thread", id, %{"s" => %{"id" => id}}}

  defp slow_after(ms) do
    Application.put_env(:hal_c2, :store_slow_write_ms, ms)
    on_exit(fn -> Application.delete_env(:hal_c2, :store_slow_write_ms) end)
  end

  test "an append that writes nothing reports the end of the log" do
    assert {:ok, 0} = Store.append([])
    {:ok, last} = Store.append([{:thread, "t1", [change("t1"), change("t1")]}])

    assert {:ok, ^last} = Store.append([])
    assert {:ok, ^last} = Store.append([{:thread, "t2", []}])
  end

  test "a write waits for a store that is restarting", %{path: path} do
    :ok = stop_supervised(Store)
    write = Task.async(fn -> Store.append([{:thread, "t1", [change("t1")]}]) end)
    start_supervised!({Store, path: path})

    assert {:ok, 1} = Task.await(write)
  end

  # A stream's sidebar write was queued at the store when the thread-move property
  # restarted it, and took the stream down with it (hal-c2/hal-c2#399).
  test "a write the store is stopped before taking waits for it to restart", %{path: path} do
    store = Process.whereis(Store)
    :ok = :sys.suspend(store)
    :erlang.trace(store, true, [:receive])
    write = Task.async(fn -> Store.append([{:thread, "t1", [change("t1")]}]) end)
    assert_receive {:trace, ^store, :receive, {:"$gen_call", _, {:append, _, _}}}

    :ok = stop_supervised(Store)
    start_supervised!({Store, path: path})

    assert {:ok, 1} = Task.await(write)
    assert [%{id: "t1"}] = Store.list_streams(path)
  end

  test "a write queued at a store stopped with a {:shutdown, _} reason waits for it too",
       %{path: path} do
    store = Process.whereis(Store)
    ref = Process.monitor(store)
    :ok = :sys.suspend(store)
    :erlang.trace(store, true, [:receive])
    write = Task.async(fn -> Store.append([{:thread, "t1", [change("t1")]}]) end)
    assert_receive {:trace, ^store, :receive, {:"$gen_call", _, {:append, _, _}}}

    # The test's supervisor starts it again.
    :ok = GenServer.stop(store, {:shutdown, :moved})
    assert_receive {:DOWN, ^ref, :process, ^store, {:shutdown, :moved}}

    assert {:ok, 1} = Task.await(write)
    assert [%{id: "t1"}] = Store.list_streams(path)
  end

  # Without the trap the stop would kill the store inside the call: before its COMMIT
  # the write is lost to this caller, and after it a retry would append it twice.
  test "a write the store has taken when it is stopped is answered before it stops",
       %{path: path} do
    # Under a supervisor of the test's own, which another process can stop it with.
    :ok = stop_supervised(Store)

    sup =
      start_supervised!(%{
        id: :store_sup,
        start: {Supervisor, :start_link, [[{Store, path: path}], [strategy: :one_for_one]]},
        type: :supervisor
      })

    store = Process.whereis(Store)
    # Another connection holds the write lock, so the store's append waits inside its
    # BEGIN IMMEDIATE until this test lets it go. That wait is bounded by the
    # store's `busy_timeout = 5000`: the gap between the `:call` trace below
    # and the ROLLBACK is the whole budget, so on a loaded box this test can
    # fail with the store crashing on the timed-out BEGIN instead — if it
    # flakes, that is the first place to look.
    {:ok, db} = Sqlite3.open(path)
    :ok = Sqlite3.execute(db, "BEGIN IMMEDIATE")
    :erlang.trace(store, true, [:call, :receive])
    :erlang.trace_pattern({Sqlite3, :execute, 2}, [{[:_, "BEGIN IMMEDIATE"], [], []}], [])

    # Even when an assertion below fails: the trace pattern is global, and the second
    # connection would hold the file of a test that is already over.
    on_exit(fn ->
      :erlang.trace_pattern({Sqlite3, :execute, 2}, false, [])
      Sqlite3.close(db)
    end)

    write = Task.async(fn -> Store.append([{:thread, "t1", [change("t1")]}]) end)
    assert_receive {:trace, ^store, :call, {Sqlite3, :execute, [_, "BEGIN IMMEDIATE"]}}

    stop = Task.async(fn -> Supervisor.terminate_child(sup, Store) end)
    assert_receive {:trace, ^store, :receive, {:EXIT, _, :shutdown}}
    :ok = Sqlite3.execute(db, "ROLLBACK")

    assert {:ok, 1} = Task.await(write)
    assert :ok = Task.await(stop)
    refute Process.whereis(Store)
    :erlang.trace_pattern({Sqlite3, :execute, 2}, false, [])
    Sqlite3.close(db)

    assert [%{id: "t1"}] = Store.list_streams(path)
    assert [_] = Store.reduce_stream(path, "t1", 0, [], &[&1 | &2], [])
  end

  test "a store updated in place from before it trapped exits traps them after the update" do
    store = Process.whereis(Store)

    # What the version before was: a store that did not trap exits.
    :sys.replace_state(store, fn state ->
      Process.flag(:trap_exit, false)
      state
    end)

    assert {:trap_exit, false} = Process.info(store, :trap_exit)

    # What `HalC2.Hot` does for a process whose module changed.
    :ok = :sys.suspend(store)
    :ok = :sys.change_code(store, Store, nil, :hot)
    :ok = :sys.resume(store)

    assert {:trap_exit, true} = Process.info(store, :trap_exit)
    assert {:ok, 1} = Store.append([{:thread, "t1", [change("t1")]}])
  end

  test "the store's shutdown gives the calls in hand a minute" do
    assert Store.child_spec(path: "hal-c2.sqlite").shutdown == 60_000
  end

  # A write that took more than a minute exited its caller, and a running turn
  # with it, on a disk that was only slow (hal-c2/hal-c2#644).
  @tag capture_log: true
  test "a write to a slow store waits for it, and says so once", %{path: path} do
    slow_after(0)
    HalC2.Test.LogTap.attach()
    store = Process.whereis(Store)
    :ok = :sys.suspend(store)
    write = Task.async(fn -> Store.append([{:thread, "t1", [change("t1")]}]) end)

    assert_receive {:logged, :warning, "a store append has waited 0 ms" <> _}
    :ok = :sys.resume(store)

    assert {:ok, 1} = Task.await(write)
    refute_received {:logged, _, _}
    assert [%{id: "t1"}] = Store.list_streams(path)
  end

  @tag capture_log: true
  test "a store that dies under a waiting write still ends it" do
    store = Process.whereis(Store)
    :ok = :sys.suspend(store)
    :erlang.trace(store, true, [:receive])
    {writer, ref} = spawn_monitor(fn -> Store.append([{:thread, "t1", [change("t1")]}]) end)
    assert_receive {:trace, ^store, :receive, {:"$gen_call", _, {:append, _, _}}}

    Process.exit(store, :kill)

    assert_receive {:DOWN, ^ref, :process, ^writer,
                    {:killed, {GenServer, :call, [Store, {:append, _, _}, :infinity]}}}
  end

  test "an EXIT-shaped message naming another process leaves the store running",
       %{path: path} do
    store = Process.whereis(Store)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(store, {:EXIT, self(), :boom})
        assert {:ok, 1} = Store.append([{:thread, "t1", [change("t1")]}])
      end)

    assert log =~ "the store ignored an unexpected message: {:EXIT,"
    assert Process.whereis(Store) == store
    assert [%{id: "t1"}] = Store.list_streams(path)
  end

  test "a stray message leaves the store running", %{path: path} do
    store = Process.whereis(Store)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(store, :unexpected)
        assert {:ok, 1} = Store.append([{:thread, "t1", [change("t1")]}])
      end)

    assert log =~ "the store ignored an unexpected message: :unexpected"
    assert Process.whereis(Store) == store
    assert [%{id: "t1"}] = Store.list_streams(path)
  end

  @tag capture_log: true
  test "a checkpointer that dies takes the store down, and its writes survive the restart",
       %{path: path} do
    store = Process.whereis(Store)
    ref = Process.monitor(store)
    {:ok, 1} = Store.append([{:thread, "t1", [change("t1")]}])

    Process.exit(:sys.get_state(store).checkpointer, :boom)
    assert_receive {:DOWN, ^ref, :process, ^store, :boom}

    # The test's supervisor starts it again, and the write waits for it.
    assert {:ok, 2} = Store.append([{:thread, "t2", [change("t2")]}])
    assert Enum.map(Store.list_streams(path), & &1.id) |> Enum.sort() == ["t1", "t2"]
  end

  test "the time of an append is only given with its store" do
    assert {:ok, 1} = Store.append(Store, [{:thread, "t1", [change("t1")]}], 1_700_000_000_000)

    # Taking the batches for the store would exit in GenServer.whereis.
    assert_raise FunctionClauseError, fn ->
      apply(Store, :append, [[{:thread, "t1", [change("t1")]}], 1_700_000_000_000])
    end
  end

  test "derived rows do not create a stream, whose kind only an append knows", %{path: path} do
    assert {:error, :unknown_stream} = Store.put_snapshot("p1", 0, %{})
    assert {:error, :unknown_stream} = Store.put_shell("p1", 0, {"project", %{}})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Store.index_messages("p1", [{"m1", "user", "hello", "2026-01-01T00:00:00Z", true}])
        _ = :sys.get_state(Store)
      end)

    assert log =~ "the store ignored messages of p1"

    assert Store.list_streams(path) == []
    assert Store.search_messages(path, "%hello%", 10) == []

    {:ok, _} = Store.append([{:project, "p1", [{"project", "p1", %{"s" => %{"id" => "p1"}}}]}])
    assert [%{id: "p1", kind: "project"}] = Store.list_streams(path)
  end

  test "an append that fails leaves no events and no stream", %{path: path} do
    {:ok, 1} = Store.append([{:thread, "t1", [change("t1")]}])

    assert {:error, _} =
             Store.append([
               {:thread, "t2", [change("t2")]},
               {:thread, "t3", [{"thread", "t3", {:not_json}}]}
             ])

    assert [%{id: "t1"}] = Store.list_streams(path)
    assert {:ok, 2} = Store.append([{:thread, "t2", [change("t2")]}])
  end

  test "a batch of messages is indexed whole or not at all", %{path: path} do
    {:ok, _} = Store.append([{:thread, "t1", [change("t1")]}])
    messages = [{"m1", "user", "one", "a", true}, {"m2", "user", "two", "b", true}]

    Store.index_messages("t1", messages)
    _ = :sys.get_state(Store)
    assert [{"t1", "user", "one", "a"}] = Store.search_messages(path, "%one%", 10)

    # The second row cannot be stored, so the first must not stay either.
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Store.index_messages("t1", [
          {"m3", "user", "three", "c", true},
          {"m4", "user", nil, "d", true}
        ])

        _ = :sys.get_state(Store)
      end)

    assert log =~ "the store ignored messages of t1"

    assert Store.search_messages(path, "%three%", 10) == []
    assert Store.search_messages(path, "%two%", 10) == [{"t1", "user", "two", "b"}]
  end

  test "typed messages are counted per day, and one deleted is forgotten", %{path: path} do
    {:ok, _} = Store.append([{:thread, "t1", [change("t1")]}])

    Store.index_messages("t1", [
      {"m1", "user", "one", "2026-01-01T09:00:00Z", true},
      {"m2", "user", "two", "2026-01-01T10:00:00Z", true},
      {"m3", "user", "sent by an agent", "2026-01-01T11:00:00Z", false},
      {"m4", "user", "three", "2026-01-02T09:00:00Z", true},
      {"m5", "user", "too old", "2025-12-31T09:00:00Z", true}
    ])

    Store.index_messages("t1", [{"m2", :deleted}])
    _ = :sys.get_state(Store)

    assert Enum.sort(Store.typed_messages_since(path, "2026-01-01")) ==
             [{"t1", "2026-01-01", 1}, {"t1", "2026-01-02", 1}]

    assert Store.search_messages(path, "%two%", 10) == []
  end

  test "a store an older MC wrote gains the column, and its rows wait to be read", %{path: path} do
    {:ok, _} = Store.append([{:thread, "t1", [change("t1")]}])
    :ok = stop_supervised(Store)

    {:ok, db} = Sqlite3.open(path)

    :ok =
      Sqlite3.execute(db, """
      DROP INDEX messages_typed;
      DROP INDEX messages_untyped;
      ALTER TABLE messages DROP COLUMN typed;
      INSERT INTO messages (stream, id, role, text, created_at)
        SELECT key, 'm1', 'user', 'old', '2026-01-01T09:00:00Z' FROM streams;
      """)

    :ok = Sqlite3.close(db)
    start_supervised!({Store, path: path})

    assert Store.typed_messages_since(path, "2026-01-01") == []
    assert [{"t1", "user", "old", _}] = Store.search_messages(path, "%old%", 10)
    assert Store.untyped_messages?(path)

    Store.index_messages("t1", [{"m1", "user", "old", "2026-01-01T09:00:00Z", true}])
    _ = :sys.get_state(Store)
    assert Store.typed_messages_since(path, "2026-01-01") == [{"t1", "2026-01-01", 1}]
    refute Store.untyped_messages?(path)
  end

  test "the meta entries under a prefix are read in one go, and only those", %{path: path} do
    :ok = Store.put_meta("import.thread.a", "unfinished")
    :ok = Store.put_meta("import.thread.b", "finished")
    :ok = Store.put_meta("import_thread.c%", "other")

    assert Store.metas(path, "import.thread.") == %{
             "import.thread.a" => "unfinished",
             "import.thread.b" => "finished"
           }

    assert Store.metas(path, "import.none.") == %{}
  end

  # Each read's connection stayed open, with its file handles and page cache, until the
  # reader next collected garbage: a dev MC held 300+ handles on its store.
  @tag skip: not File.dir?("/proc/self/fd")
  test "a read closes its connection before it returns", %{path: path} do
    {:ok, _} = Store.append([{:thread, "t1", [change("t1")]}])
    Store.put_meta("k", "v")

    open = fn ->
      "/proc/self/fd"
      |> File.ls!()
      |> Enum.count(&(File.read_link(Path.join("/proc/self/fd", &1)) == {:ok, path}))
    end

    reads = fn ->
      for _ <- 1..20 do
        Store.meta(path, "k")
        Store.metas(path, "k")
        Store.list_shell(path)
        Store.list_streams(path)
        Store.get_snapshot(path, "t1")
        Store.stream_tail(path, "t1")
        Store.streams_present(path, ["t1"])
        Store.reduce_stream(path, "t1", 0, 0, fn _, n -> n + 1 end)
      end
    end

    # The first read can open one connection for good (the checkpointer's).
    reads.()
    before = open.()
    # A heap that never fills, so nothing these reads leave behind is collected.
    {pid, ref} =
      :erlang.spawn_opt(
        fn ->
          reads.()
          exit({:opened, open.() - before})
        end,
        [
          :monitor,
          min_heap_size: 2_000_000
        ]
      )

    assert_receive {:DOWN, ^ref, :process, ^pid, {:opened, 0}}, 5_000
  end

  describe "storing a thread with no stream to index it" do
    defp message(id),
      do:
        {"message", id,
         %{"s" => %{"id" => id, "role" => "user", "text" => id, "createdAt" => "2026-11-01"}}}

    defp indexed_thread(ids) do
      HalC2.Search.storing_thread("t1", fn ->
        {:ok, _} = Store.append([{:thread, "t1", Enum.map(ids, &message/1)}])
      end)
    end

    test "a write that fails leaves a count of what the thread holds, and the mark", %{path: path} do
      indexed_thread(~w(m1 m2))
      Store.put_meta("messages_typed", "1")

      assert_raise RuntimeError, fn ->
        HalC2.Search.storing_thread("t1", fn ->
          {:ok, _} = Store.append([{:thread, "t1", [{"message", "m2", HalC2.Patch.delete()}]}])
          raise "the disk is full"
        end)
      end

      assert HalC2.Search.read?()
      assert [{"t1", "2026-11-01", 1}] = Store.typed_messages_since(path, "2000-01-01")
    end

    test "a store not yet read stays unread, even when the write removes what said so",
         %{path: path} do
      indexed_thread(~w(m1))
      {:ok, db} = Sqlite3.open(path)
      :ok = Sqlite3.execute(db, "PRAGMA busy_timeout = 5000")
      :ok = Sqlite3.execute(db, "UPDATE messages SET typed = NULL")
      :ok = Sqlite3.close(db)
      Store.put_meta("messages_typed", "1")
      refute HalC2.Search.read?()

      assert_raise RuntimeError, fn ->
        HalC2.Search.storing_thread("t1", fn -> raise "the disk is full" end)
      end

      refute HalC2.Search.read?()
    end
  end
end
