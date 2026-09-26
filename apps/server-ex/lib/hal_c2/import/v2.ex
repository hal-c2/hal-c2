defmodule HalC2.Import.V2 do
  @moduledoc """
  Imports the Node server's `orchestration_events` log into a `HalC2.Store`.

  The Node log stores every update as the whole entity, so streaming text is
  re-stored in full on every chunk. Each event is diffed against the previous version
  of its entity and only the `HalC2.Patch` is kept; identical re-emits are dropped.

  The source is opened read-only. Streams are imported one at a time, in order of
  their first event, so only one stream's latest entities are held in memory.

  Provider sessions follow the Node projection's binding rules: a session belongs to
  a thread from `provider-session.attached` until `provider-session.detached`, and
  an update to a session the thread is not bound to changes nothing in that thread.

  Two more Node projection rules are made explicit in the log: a provider thread
  update for this thread (other than a queued placeholder) makes it the thread's
  `activeProviderThreadId`, and visits and mark-unread are quiet patches.

  A thread logged only as version 1 events (before the Node server moved to v2) is
  folded by `HalC2.Import.V1Thread` into the v2 entities the Node server migrates it to.
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
      totals = %{streams: 0, source_events: 0, events: 0, source_bytes: 0, bytes: 0}

      report =
        Enum.reduce(streams, totals, fn {aggregate, stream_id, legacy?}, totals ->
          stream_report = import_stream(db, store, aggregate, stream_id, legacy?)

          Map.merge(totals, stream_report, fn _k, a, b -> a + b end)
          |> Map.update!(:streams, &(&1 + 1))
        end)

      {:ok, report}
    after
      Sqlite3.close(db)
    end
  end

  @doc "Maps a Node event to `{kind, entity_id, entity}`, or `nil` when it carries no entity."
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

  defp source_streams(db, only) do
    {:ok, stmt} =
      Sqlite3.prepare(db, """
      SELECT aggregate_kind, stream_id, MAX(application_event_version IS 2)
      FROM orchestration_events
      WHERE aggregate_kind IN ('project', 'thread') OR application_event_version = 2
      GROUP BY aggregate_kind, stream_id ORDER BY MIN(sequence)
      """)

    {:ok, rows} = Sqlite3.fetch_all(db, stmt)

    for [aggregate, id, v2] <- rows,
        only == nil or id in only,
        do: {aggregate, id, aggregate == "thread" and v2 == 0}
  end

  # A thread with any v2 event was migrated by the Node server; its v1 events are
  # history the v2 ones already carry.
  defp import_stream(db, store, aggregate, stream_id, legacy?) do
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
      pending: [],
      pending_count: 0,
      source_events: 0,
      events: 0,
      source_bytes: 0,
      bytes: 0
    }

    acc = step(db, stmt, acc, store, stream_kind, stream_id)
    acc = flush(acc, store, stream_kind, stream_id)
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

        acc = diff_event(acc, type, JSON.decode!(json), occurred_at)
        if acc.pending_count >= @batch, do: flush(acc, store, stream_kind, stream_id), else: acc
      end)

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

  defp push(acc, change),
    do: %{acc | pending: [change | acc.pending], pending_count: acc.pending_count + 1}

  defp flush(%{pending: []} = acc, _store, _kind, _id), do: acc

  defp flush(acc, store, stream_kind, stream_id) do
    changes = Enum.reverse(acc.pending)
    {:ok, _seq} = HalC2.Store.append(store, [{stream_kind, stream_id, changes}])

    bytes =
      Enum.reduce(changes, 0, fn {_, _, patch, _}, n ->
        n + IO.iodata_length(JSON.encode_to_iodata!(patch))
      end)

    %{
      acc
      | pending: [],
        pending_count: 0,
        events: acc.events + length(changes),
        bytes: acc.bytes + bytes
    }
  end
end
