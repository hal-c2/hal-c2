defmodule HalC2.Import.V2 do
  @moduledoc """
  Imports an earlier install's `orchestration_events` log into a `HalC2.Store`.

  The earlier install's log stores every update as the whole entity, so streaming text is
  re-stored in full on every chunk. Each event is diffed against the previous version
  of its entity and only the `HalC2.Patch` is kept; identical re-emits are dropped.

  The source is opened read-only. Streams are imported one at a time, in order of
  their first event, so only one stream's latest entities are held in memory.

  Provider sessions follow the earlier install's projection rules: a session belongs to
  a thread from `provider-session.attached` until `provider-session.detached`, and
  an update to a session the thread is not bound to changes nothing in that thread.

  Two more projection rules of the earlier install are made explicit in the log: a provider thread
  update for this thread (other than a queued placeholder) makes it the thread's
  `activeProviderThreadId`, and visits and mark-unread are quiet patches.

  A thread logged only as version 1 events (before an earlier install moved to v2) is
  folded by `HalC2.Import.V1Thread` into the v2 entities that install migrated it to.

  Options: `:only`, the stream ids to import, and `:rewrite`, a function every event's
  payload goes through first (`HalC2.ThreadArchive.rewriter/4`, to land in another project).
  `:resume` names streams an import that stopped partway left in the store, as
  `%{id => {count, last}}`: their changes there and the last of them (`{kind, entity,
  patch, at}`). The import is deterministic, so those streams continue after their first
  `count` changes; one whose last change is not the import's own raises instead, since
  something else wrote to it and its history can no longer be continued. Only that
  last skipped change is compared, so determinism also rests on the source's
  prefix being unchanged and on the retry diffing as the stopped attempt did
  (an older MC's import resumed after an upgrade whose diffing changed would
  mix its prefix patches with new suffix diffs). The tail is
  read again just before each batch of changes after the skipped ones is stored, and at
  the end of the stream, so a write during the replay itself
  (which re-reads the whole history first) — before the first batch or between
  later ones — raises too instead of being appended over
  or silently kept — checked immediately before the append, not atomically with
  it: a write landing between that re-read and the store call is still possible,
  though in practice the thread is hidden and its family's imports are locked,
  so a writer would need its id by another route. And so does
  one holding more changes than the source now gives, including one the source no
  longer has at all. Determinism needs the same
  `:rewrite` as the stopped import: the caller resumes a stream only into the project
  it was going to (`HalC2.Import.PreviousInstall`).
  """

  @quiet_events ["thread.visited", "thread.marked-unread"]

  alias Exqlite.Sqlite3

  @batch 2_000

  @type report :: %{
          streams: non_neg_integer,
          source_events: non_neg_integer,
          events: non_neg_integer,
          source_bytes: non_neg_integer,
          bytes: non_neg_integer
        }

  @spec run(String.t(), GenServer.server(), keyword) :: {:ok, report}
  def run(source_path, store \\ HalC2.Store, opts \\ []) do
    {:ok, db} = Sqlite3.open(source_path, mode: :readonly)

    try do
      streams = source_streams(db, Keyword.get(opts, :only))
      resume = Keyword.get(opts, :resume, %{})

      # A stream to resume that the source no longer has at all is not skipped over:
      # what is stored here is more than its install now has, as below.
      for {id, {skip, _last}} <- resume,
          skip > 0,
          not Enum.any?(streams, fn {_aggregate, stream_id, _legacy?} -> stream_id == id end) do
        raise "#{id} holds more here than its install now has, so it cannot be continued"
      end

      totals = %{streams: 0, source_events: 0, events: 0, source_bytes: 0, bytes: 0}
      progress = progress(db, streams, opts[:progress])

      report =
        Enum.reduce(streams, totals, fn {aggregate, stream_id, legacy?}, totals ->
          stream_report =
            import_stream(
              db,
              store,
              aggregate,
              stream_id,
              legacy?,
              Map.get(resume, stream_id, {0, nil}),
              opts[:rewrite] || (& &1),
              &progress.(totals.source_events + &1)
            )

          Map.merge(totals, stream_report, fn _k, a, b -> a + b end)
          |> Map.update!(:streams, &(&1 + 1))
        end)

      {:ok, report}
    after
      Sqlite3.close(db)
    end
  end

  # `opts[:progress]` is told `(events read, events to read)` as the import goes.
  defp progress(_db, _streams, nil), do: fn _read -> :ok end

  defp progress(db, streams, report) do
    {:ok, stmt} =
      Sqlite3.prepare(db, """
      SELECT COUNT(*) FROM orchestration_events
      WHERE aggregate_kind = ?1 AND stream_id = ?2
        AND (?3 OR aggregate_kind = 'project' OR application_event_version = 2)
      """)

    total =
      Enum.sum_by(streams, fn {aggregate, stream_id, legacy?} ->
        :ok = Sqlite3.bind(stmt, [aggregate, stream_id, if(legacy?, do: 1, else: 0)])
        {:ok, [[count]]} = Sqlite3.fetch_all(db, stmt)
        count
      end)

    :ok = Sqlite3.release(db, stmt)
    fn read -> report.(read, total) end
  end

  @doc "Maps an earlier install's event to `{kind, entity_id, entity}`, or `nil` when it carries no entity."
  @spec entity(String.t(), map) :: {String.t(), String.t(), map} | nil
  def entity(event_type, payload) do
    kind = event_type |> String.split(".", parts: 2) |> hd()

    case payload do
      %{"id" => id} when is_binary(id) -> {kind, id, payload}
      _ -> with id when is_binary(id) <- payload[camel(kind) <> "Id"], do: {kind, id, payload}
    end
  end

  defp camel(kind) do
    [first | rest] = String.split(kind, "-")
    Enum.join([first | Enum.map(rest, &String.capitalize/1)])
  end

  # Named streams are looked up one by one, so picking a few threads out of a large
  # log does not read all of it.
  defp source_streams(db, only) do
    filter = if only, do: "AND stream_id = ?1", else: ""

    {:ok, stmt} =
      Sqlite3.prepare(db, """
      SELECT aggregate_kind, stream_id, MAX(application_event_version IS 2), MIN(sequence)
      FROM orchestration_events
      WHERE (aggregate_kind IN ('project', 'thread') OR application_event_version = 2) #{filter}
      GROUP BY aggregate_kind, stream_id ORDER BY MIN(sequence)
      """)

    rows =
      if only do
        only
        |> Enum.flat_map(fn id ->
          :ok = Sqlite3.bind(stmt, [id])
          {:ok, rows} = Sqlite3.fetch_all(db, stmt)
          rows
        end)
        |> Enum.sort_by(fn [_, _, _, first] -> first end)
      else
        {:ok, rows} = Sqlite3.fetch_all(db, stmt)
        rows
      end

    :ok = Sqlite3.release(db, stmt)
    for [aggregate, id, v2, _] <- rows, do: {aggregate, id, aggregate == "thread" and v2 == 0}
  end

  # A thread with any v2 event was migrated by an earlier install; its v1 events are
  # history the v2 ones already carry.
  defp import_stream(db, store, aggregate, stream_id, legacy?, {skip, last}, rewrite, progress) do
    {:ok, stmt} =
      Sqlite3.prepare(db, """
      SELECT event_type, payload_json, occurred_at FROM orchestration_events
      WHERE aggregate_kind = ?1 AND stream_id = ?2
        AND (?3 OR aggregate_kind = 'project' OR application_event_version = 2)
      ORDER BY sequence
      """)

    :ok = Sqlite3.bind(stmt, [aggregate, stream_id, if(legacy?, do: 1, else: 0)])
    stream_kind = if aggregate == "project", do: :project, else: :thread

    acc = %{
      stream_id: stream_id,
      latest: %{},
      bound_sessions: MapSet.new(),
      v1: if(legacy?, do: HalC2.Import.V1Thread.new(stream_id)),
      rewrite: rewrite,
      progress: progress,
      pending: [],
      pending_count: 0,
      skip: skip,
      last: last,
      # The stored tail this stream must still end at before each batch is
      # stored: the tail the resume was snapshotted from, then this import's
      # own last stored change after each flush. Nil when not resuming.
      check_tail: if(skip > 0, do: {skip, last}),
      source_events: 0,
      events: 0,
      source_bytes: 0,
      bytes: 0
    }

    acc = step(db, stmt, acc, store, stream_kind, stream_id)

    if acc.skip > 0,
      do:
        raise("#{stream_id} holds more here than its install now has, so it cannot be continued")

    # Checked once more after the last flush, which also covers nothing after
    # the skipped changes being left to store (the tail check in `flush/4`
    # would not run, and a write during the replay would be kept as part of
    # the imported history).
    acc = flush(acc, store, stream_kind, stream_id)
    acc = verify_tail(acc, store, stream_id)
    HalC2.Projection.rebuild(store, stream_id)
    Map.take(acc, [:source_events, :events, :source_bytes, :bytes])
  end

  defp step(db, stmt, acc, store, stream_kind, stream_id) do
    {status, rows} =
      case Sqlite3.multi_step(db, stmt, 500) do
        {:rows, rows} -> {:more, rows}
        {:done, rows} -> {:done, rows}
      end

    acc =
      Enum.reduce(rows, acc, fn [type, json, occurred_at], acc ->
        acc = %{
          acc
          | source_events: acc.source_events + 1,
            source_bytes: acc.source_bytes + byte_size(json)
        }

        acc = diff_event(acc, type, acc.rewrite.(JSON.decode!(json)), occurred_at)
        if acc.pending_count >= @batch, do: flush(acc, store, stream_kind, stream_id), else: acc
      end)

    acc.progress.(acc.source_events)
    if status == :more, do: step(db, stmt, acc, store, stream_kind, stream_id), else: acc
  end

  defp unix_ms(iso) do
    {:ok, dt, _} = DateTime.from_iso8601(iso)
    DateTime.to_unix(dt, :millisecond)
  end

  defp diff_event(%{v1: %{} = v1} = acc, type, payload, occurred_at) do
    {v1, changes} = HalC2.Import.V1Thread.apply(v1, type, payload, occurred_at)
    at = unix_ms(occurred_at)

    Enum.reduce(changes, %{acc | v1: v1}, fn
      {kind, id, nil}, acc -> remove(acc, kind, id, at)
      {kind, id, entity}, acc -> upsert(acc, kind, id, entity, at)
    end)
  end

  defp diff_event(acc, type, payload, occurred_at),
    do: diff_v2(acc, type, payload, unix_ms(occurred_at))

  defp diff_v2(acc, "provider-session.detached", payload, at) do
    case entity("provider-session.detached", payload) do
      {kind, id, _} ->
        if MapSet.member?(acc.bound_sessions, id) do
          acc
          |> Map.update!(:bound_sessions, &MapSet.delete(&1, id))
          |> Map.update!(:latest, &Map.delete(&1, {kind, id}))
          |> push({kind, id, HalC2.Patch.delete(), at})
        else
          acc
        end

      nil ->
        acc
    end
  end

  defp diff_v2(acc, "provider-session.updated", %{"id" => id} = payload, at) do
    if MapSet.member?(acc.bound_sessions, id),
      do: upsert(acc, "provider-session", id, payload, at),
      else: acc
  end

  defp diff_v2(acc, "provider-session.attached", %{"id" => id} = payload, at) do
    acc
    |> Map.update!(:bound_sessions, &MapSet.put(&1, id))
    |> upsert("provider-session", id, payload, at)
  end

  defp diff_v2(acc, "provider-thread.updated", %{"id" => id} = payload, at) do
    acc = upsert(acc, "provider-thread", id, payload, at)
    thread = Map.get(acc.latest, {"thread", acc.stream_id})

    if payload["appThreadId"] == acc.stream_id and thread != nil and not placeholder?(payload),
      do: upsert(acc, "thread", acc.stream_id, Map.put(thread, "activeProviderThreadId", id), at),
      else: acc
  end

  # Version 1 project events after the first carry only the fields they change.
  defp diff_v2(acc, type, %{"projectId" => id} = payload, at)
       when type in ["project.meta-updated", "project.deleted"] do
    project = Map.get(acc.latest, {"project", id}, %{})
    upsert(acc, "project", id, Map.merge(project, payload), at)
  end

  defp diff_v2(acc, type, payload, at) do
    case entity(type, payload) do
      nil -> acc
      {kind, id, entity} -> upsert(acc, kind, id, entity, at, type in @quiet_events)
    end
  end

  defp upsert(acc, kind, id, entity, at, quiet? \\ false) do
    key = {kind, id}

    case HalC2.Patch.diff(Map.get(acc.latest, key), entity) do
      :unchanged ->
        acc

      patch ->
        patch = if quiet?, do: Map.put(patch, "q", true), else: patch
        acc |> Map.update!(:latest, &Map.put(&1, key, entity)) |> push({kind, id, patch, at})
    end
  end

  defp remove(acc, kind, id, at) do
    if Map.has_key?(acc.latest, {kind, id}),
      do:
        acc
        |> Map.update!(:latest, &Map.delete(&1, {kind, id}))
        |> push({kind, id, HalC2.Patch.delete(), at}),
      else: acc
  end

  # A provider thread queued for a future run; it does not become the active one.
  defp placeholder?(provider_thread) do
    provider_thread["status"] == "not_loaded" and
      Enum.all?(
        ~w(firstRunOrdinal nativeThreadRef providerSessionId),
        &(provider_thread[&1] in [nil, :null])
      )
  end

  defp push(%{skip: 0} = acc, change),
    do: %{acc | pending: [change | acc.pending], pending_count: acc.pending_count + 1}

  # A change a stopped import already stored; the last of them must be the stored one.
  # The replay is deterministic, so a write here after the stop moves that last change.
  # That checks the snapshot the resume was given; a write during the replay is
  # checked for by the tail re-read before each post-skip flush (`verify_tail/3`
  # — immediately before the append, not atomically with it). Only the last
  # skipped change is compared, so the prefix before it is taken as the stopped
  # import left it: determinism rests on the source's prefix being unchanged
  # and on the retry diffing as the stopped attempt did (see the moduledoc).
  defp push(%{skip: 1} = acc, change) do
    if stored(change) != acc.last, do: raise(diverged(acc.stream_id))

    %{acc | skip: 0}
  end

  defp push(acc, _change), do: %{acc | skip: acc.skip - 1}

  # A change in the form the store keeps it (string keys, lists for tuples),
  # as `HalC2.Store.stream_tail/2` reads it back.
  defp stored({kind, entity, patch, at}),
    do: {kind, entity, JSON.decode!(JSON.encode!(patch)), at}

  defp diverged(stream_id),
    do: "#{stream_id} changed here after its import stopped, so it cannot be continued"

  # Before each batch after the skipped changes is stored, and again at the end
  # of the stream, the stream must still end where this import last left it
  # (the resume's snapshot, then its own last stored change): a write during
  # the replay — before the first batch or between later ones — would
  # otherwise have this import's diffs, computed without it, appended over it,
  # or be kept as imported history. The re-read is on a reader connection and
  # the append goes through the store writer after it, so the check narrows
  # the window to between the two calls rather than closing it (the thread is
  # hidden and family imports are locked meanwhile; a conditional append
  # inside the writer would close it).
  defp verify_tail(%{check_tail: nil} = acc, _store, _stream_id), do: acc

  defp verify_tail(acc, store, stream_id) do
    if HalC2.Store.stream_tail(HalC2.Store.path(store), stream_id) != acc.check_tail,
      do: raise(diverged(stream_id))

    acc
  end

  defp flush(%{pending: []} = acc, _store, _kind, _id), do: acc

  defp flush(acc, store, stream_kind, stream_id) do
    acc = verify_tail(acc, store, stream_id)
    changes = Enum.reverse(acc.pending)
    {:ok, _seq} = HalC2.Store.append(store, [{stream_kind, stream_id, changes}])

    bytes =
      Enum.reduce(changes, 0, fn {_, _, patch, _}, n ->
        n + IO.iodata_length(JSON.encode_to_iodata!(patch))
      end)

    # The next batch's tail check expects this import's own last stored change.
    check_tail =
      case acc.check_tail do
        nil -> nil
        {count, _last} -> {count + length(changes), stored(List.last(changes))}
      end

    %{
      acc
      | pending: [],
        pending_count: 0,
        check_tail: check_tail,
        events: acc.events + length(changes),
        bytes: acc.bytes + bytes
    }
  end
end
