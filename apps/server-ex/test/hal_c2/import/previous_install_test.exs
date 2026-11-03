defmodule HalC2.Import.PreviousInstallTest do
  use ExUnit.Case, async: false

  alias HalC2.Import.PreviousInstall
  alias HalC2.{StreamState, Streams}
  alias HalC2.Test.Mc

  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  @id "t3-alpha"
  # More than one of `HalC2.Import.V2`'s batches, so a stopped import leaves some behind.
  @messages 2_100

  setup %{tmp_dir: dir} do
    mc = Mc.start(Path.join(dir, "mc"))
    home = Path.join(dir, "t3")
    install = Path.join(home, "dev")
    root = Path.join(dir, "shop")
    File.mkdir_p!(install)
    File.mkdir_p!(root)
    Mc.World.put_env("T3CODE_HOME", home)
    log = Path.join(install, "state.sqlite")
    write_install(log, root)
    %{mc: mc, install: install, log: log}
  end

  # A stream started between a stopped import and its retry (search's backfill reads
  # every thread at boot) used to keep what it loaded: the retry's events went to the
  # store behind it, and the retry's own commit then applied over the gap, so the
  # thread showed, and would snapshot, only the messages of the stopped attempt.
  test "a stream started before a stopped import is continued holds the whole thread",
       %{install: install, log: log} do
    input = %{"source" => install, "threadIds" => [@id]}
    assert {:ok, %{"failed" => [%{"id" => @id}]}} = PreviousInstall.import_threads(input)

    partial = Streams.read(@id, &Enum.count(StreamState.all(&1, "message")))
    assert partial in 1..(@messages - 1)

    readable(log)
    assert {:ok, %{"imported" => [@id]}} = PreviousInstall.import_threads(input)

    assert messages() == @messages
    # And so does what it writes to disk on the way out.
    :ok = Streams.stop(@id)
    assert messages() == @messages
  end

  defp messages, do: Streams.read(@id, &Enum.count(StreamState.all(&1, "message")))

  defp write_install(log, root) do
    {:ok, db} = Exqlite.Sqlite3.open(log)

    :ok =
      Exqlite.Sqlite3.execute(db, """
      CREATE TABLE orchestration_events (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT, aggregate_kind TEXT, stream_id TEXT,
        event_type TEXT, payload_json TEXT, occurred_at TEXT, application_event_version INTEGER);
      CREATE TABLE projection_projects (
        project_id TEXT, title TEXT, workspace_root TEXT, scripts_json TEXT, deleted_at TEXT);
      CREATE TABLE orchestration_v2_projection_threads (
        thread_id TEXT, project_id TEXT, title TEXT, updated_at TEXT, payload_json TEXT);
      INSERT INTO projection_projects VALUES ('v2-project', 'shop', '#{root}', '[]', NULL);
      INSERT INTO orchestration_v2_projection_threads VALUES
        ('#{@id}', 'v2-project', 'Alpha', '2026-09-01T11:00:00.000Z', '{}');
      """)

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(db, """
      INSERT INTO orchestration_events (aggregate_kind, stream_id, event_type, payload_json,
        occurred_at, application_event_version)
      VALUES ('thread', ?1, ?2, ?3, '2026-09-01T10:00:00.000Z', 2)
      """)

    thread = %{
      "id" => @id,
      "projectId" => "v2-project",
      "title" => "Alpha",
      "worktreePath" => root,
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-01T10:00:00.000Z"
    }

    # The last message cannot be read, so the first import stops there.
    events =
      [{"thread.created", JSON.encode!(thread)}] ++
        for(k <- 1..(@messages - 1), do: {"message.sent", JSON.encode!(message(k))}) ++
        [{"message.sent", "{"}]

    :ok = Exqlite.Sqlite3.execute(db, "BEGIN")

    for {type, payload} <- events do
      :ok = Exqlite.Sqlite3.bind(stmt, [@id, type, payload])
      :done = Exqlite.Sqlite3.step(db, stmt)
    end

    :ok = Exqlite.Sqlite3.execute(db, "COMMIT")
    :ok = Exqlite.Sqlite3.release(db, stmt)
    :ok = Exqlite.Sqlite3.close(db)
  end

  defp readable(log) do
    {:ok, db} = Exqlite.Sqlite3.open(log)

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(
        db,
        "UPDATE orchestration_events SET payload_json = ?1 WHERE sequence = (SELECT MAX(sequence) FROM orchestration_events)"
      )

    :ok = Exqlite.Sqlite3.bind(stmt, [JSON.encode!(message(@messages))])
    :done = Exqlite.Sqlite3.step(db, stmt)
    :ok = Exqlite.Sqlite3.release(db, stmt)
    :ok = Exqlite.Sqlite3.close(db)
  end

  defp message(k),
    do: %{
      "id" => "#{@id}-m#{k}",
      "threadId" => @id,
      "role" => "user",
      "text" => "message #{k}",
      "attachments" => [],
      "createdAt" => "2026-09-01T11:00:00.000Z"
    }
end
