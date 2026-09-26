defmodule HalC2.ThreadArchive do
  @moduledoc """
  A thread as one file (`.hal-c2-thread`, JSON): what `mix hal_c2.thread.export`
  writes, `mix hal_c2.thread.import` reads, and a move between cluster members
  (`HalC2.ThreadMove`) sends.

  Version 2 carries the thread's stream as entities (`HalC2.StreamState.rows/1`), the
  project it lived in (its root and repository), attachments and terminal scrollback
  (base64 with sha256), a `git bundle` of its checkpoint refs and, when its provider
  can carry one, the agent's native session (`HalC2.PortableSessions`). Version 1 is
  the Node server's archive (`apps/server/scripts/thread-transfer.ts`); it imports
  through `HalC2.Import.V2` without a session.

  An import checks the whole file before it writes anything. The thread lands in a
  named project or the one project here that is a checkout of the same repository;
  every recorded path under the old project root is rewritten to the new one.
  Checkpoints only land in a checkout of the same repository.
  """

  alias HalC2.{Attachments, Patch, PortableSessions, Store, StreamState, Streams, Terminal}
  alias HalC2.Checkpoint

  @format "hal-c2-thread-export"
  @version 2
  @extension ".hal-c2-thread"

  @type archive :: map

  def extension, do: @extension

  # --- export --------------------------------------------------------------------

  @doc """
  The archive of a thread on this node, by id or title. `opts[:session]` false
  leaves the agent's session out.
  """
  @spec build(String.t(), keyword) :: {:ok, archive} | {:error, String.t()}
  def build(ref, opts \\ []) do
    with {:ok, id} <- find_thread(ref),
         state = state(id),
         %{} = thread <- StreamState.get(state, "thread")[id] || {:error, "No thread #{ref}."},
         :ok <- if(thread["movedTo"], do: {:error, moved_message(thread)}, else: :ok) do
      project = project(thread["projectId"]) || %{}
      root = project["workspaceRoot"]
      cwd = thread["worktreePath"] || root

      {:ok,
       %{
         "format" => @format,
         "version" => @version,
         "exportedAt" => now(),
         "thread" => %{
           "id" => id,
           "title" => thread["title"],
           "projectId" => thread["projectId"],
           "projectTitle" => project["title"],
           "projectRoot" => root,
           "repository" => repository(root),
           "worktreePath" => thread["worktreePath"],
           "branch" => thread["branch"],
           "machine" => label()
         },
         "updatedAt" => state.updated_at,
         "entities" =>
           for({kind, eid, entity} <- StreamState.rows(state), do: [kind, eid, entity]),
         "attachments" => attachments(state),
         "terminalLogs" =>
           for({terminal, data} <- Terminal.saved_scrollback(id), do: file(terminal, data)),
         "checkpoints" => checkpoints(state, root),
         "session" => if(Keyword.get(opts, :session, true), do: session(state, thread, cwd))
       }}
    end
  end

  @doc "Writes a thread's archive to `path`, readable only by the user."
  @spec export_file(String.t(), Path.t(), keyword) :: {:ok, map} | {:error, String.t()}
  def export_file(ref, path, opts \\ []) do
    with {:ok, archive} <- build(ref, opts) do
      path = Path.expand(path)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, JSON.encode_to_iodata!(archive))
      File.chmod!(path, 0o600)
      {:ok, summary(archive)}
    end
  end

  # --- import --------------------------------------------------------------------

  @doc "Imports the archive at `path`; see `import_archive/2`."
  @spec import_file(Path.t(), keyword) :: {:ok, map} | {:error, String.t()}
  def import_file(path, opts \\ []) do
    case File.read(Path.expand(path)) do
      {:ok, data} -> import_archive(data, opts)
      {:error, reason} -> {:error, "Could not read #{path}: #{:file.format_error(reason)}."}
    end
  end

  @doc """
  Imports an archive (its JSON or decoded map) onto this node. `opts[:project]` names
  the project (title or id); without it the thread goes into the one project that is a
  checkout of the same repository. Returns `%{thread, title, project, notes}`, where
  `notes` are what the user should be told (checkpoints left behind, say).

  `opts[:replace]` true lets the archive replace this node's copy of the thread,
  which a move back uses; otherwise a thread that is already here is refused.
  """
  @spec import_archive(binary | map, keyword) :: {:ok, map} | {:error, String.t()}
  def import_archive(data, opts \\ []) do
    with {:ok, archive} <- decode(data),
         :ok <- not_here(archive, opts),
         {:ok, project} <- resolve_project(archive, opts[:project]) do
      write(archive, project, opts)
    end
  end

  @doc """
  Checks an archive: its format, version and every checksum. Returns it decoded,
  each carried file's bytes under `"data"`.
  """
  @spec decode(binary | map) :: {:ok, archive} | {:error, String.t()}
  def decode(data) when is_binary(data) do
    case JSON.decode(data) do
      {:ok, %{} = map} -> decode(map)
      _ -> {:error, "The file is damaged: it is not a HAL-C2 thread file. Nothing was imported."}
    end
  end

  def decode(%{"format" => @format, "version" => version})
      when is_integer(version) and version > @version,
      do:
        {:error,
         "This file needs a newer HAL-C2: it was written in version #{version} of the thread file format and this machine reads up to version #{@version}. Nothing was imported."}

  def decode(%{"format" => @format, "version" => version} = archive) when version in [1, 2] do
    with {:ok, attachments} <- verify(archive["attachments"], "the attachment"),
         {:ok, logs} <- verify(archive["terminalLogs"] || [], "the terminal log"),
         {:ok, checkpoints} <- verify_checkpoints(archive["checkpoints"]),
         {:ok, session} <- verify_session(archive["session"]) do
      {:ok,
       %{
         archive
         | "attachments" => attachments
       }
       |> Map.put("terminalLogs", logs)
       |> Map.put("checkpoints", checkpoints)
       |> Map.put("session", session)}
    end
  end

  def decode(_),
    do: {:error, "The file is damaged: it is not a HAL-C2 thread file. Nothing was imported."}

  defp verify(nil, _what), do: {:ok, []}

  defp verify(files, what) when is_list(files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      case verified(file) do
        {:ok, data} -> {:cont, {:ok, [Map.put(file, "data", data) | acc]}}
        :error -> {:halt, damaged("#{what} #{file["fileName"]}")}
      end
    end)
    |> then(fn
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end)
  end

  defp verify(_files, what), do: damaged(what)

  defp verify_checkpoints(nil), do: {:ok, nil}

  defp verify_checkpoints(%{"bundle" => bundle} = checkpoints) do
    case verified(bundle) do
      {:ok, data} -> {:ok, Map.put(checkpoints, "bundle", Map.put(bundle, "data", data))}
      :error -> damaged("the checkpoints")
    end
  end

  defp verify_session(nil), do: {:ok, nil}

  defp verify_session(%{"files" => files} = session) do
    with {:ok, files} <- verify(files, "the agent's session file"),
         do: {:ok, %{session | "files" => files}}
  end

  defp verified(%{"sha256" => sha, "dataBase64" => b64}) when is_binary(b64) do
    with {:ok, data} <- Base.decode64(b64),
         true <- sha256(data) == String.downcase(to_string(sha)) do
      {:ok, data}
    else
      _ -> :error
    end
  end

  defp verified(_), do: :error

  defp damaged(what),
    do:
      {:error, "The file is damaged: #{what} does not match its checksum. Nothing was imported."}

  # A thread that is already here is refused, unless this node only keeps a forwarding
  # record for it (it moved away and is coming back) or the caller replaces it.
  defp not_here(%{"thread" => %{"id" => id} = meta}, opts) do
    replace? = opts[:replace] == true

    case local_thread(id) do
      nil -> :ok
      %{"movedTo" => %{}} -> :ok
      _ when replace? -> :ok
      _ -> {:error, "#{meta["title"]} is already on #{label()}."}
    end
  end

  @doc """
  The project an archive lands in: `name` (a title or id), or the one project here
  that is a checkout of the archive's repository.
  """
  @spec resolve_project(archive, String.t() | nil) :: {:ok, map} | {:error, String.t()}
  def resolve_project(archive, name) do
    projects = local_projects()
    title = archive["thread"]["title"]

    if name do
      case Enum.find(projects, &(&1["id"] == name)) ||
             Enum.find(projects, &(&1["title"] == name)) do
        nil -> {:error, "There is no project #{name} on #{label()}. #{title} was not imported."}
        project -> {:ok, project}
      end
    else
      case candidates(projects, archive) do
        [project] ->
          {:ok, project}

        [] ->
          {:error,
           "No project on #{label()} is a checkout of the repository of #{title}. Name a project to import it into."}

        several ->
          {:error,
           "Several projects on #{label()} are checkouts of the repository of #{title} (#{Enum.map_join(several, ", ", & &1["title"])}). Name the one to import it into."}
      end
    end
  end

  # The Node server's file names only the project's root: the project at that root,
  # else a checkout of the same repository, else the only project, as its script did.
  defp candidates(projects, %{"version" => 1, "thread" => meta} = archive) do
    root = meta["sourceWorkspaceRoot"]

    with [] <- Enum.filter(projects, &(root != nil and &1["workspaceRoot"] == root)),
         [] <- same_repository(projects, put_in(archive, ["thread", "projectRoot"], root)) do
      if length(projects) == 1, do: projects, else: []
    end
  end

  defp candidates(projects, archive), do: same_repository(projects, archive)

  @doc "This node's projects that are checkouts of the archive's repository."
  def same_repository(projects \\ local_projects(), archive) do
    case archive["thread"]["repository"] || repository(archive["thread"]["projectRoot"]) do
      nil -> []
      key -> Enum.filter(projects, &(repository(&1["workspaceRoot"]) == key))
    end
  end

  @doc "This node's projects that are not deleted, as their project rows."
  def local_projects do
    for {"project", row} <- local_rows(), row["deletedAt"] == nil, do: row
  end

  defp write(%{"version" => 1} = archive, project, _opts), do: write_v1(archive, project)

  defp write(archive, project, opts) do
    meta = archive["thread"]
    id = meta["id"]
    dest_root = project["workspaceRoot"]
    rewrite = rewriter(meta["projectRoot"], dest_root, meta["projectId"], project["id"])
    same_repo? = repository(dest_root) != nil and repository(dest_root) == meta["repository"]

    {checkpoint_notes, checkpoints_ok?} = place_checkpoints(archive, dest_root, same_repo?)
    {carried_session, session_notes} = place_session(archive, dest_root, opts)

    entities =
      for [kind, eid, entity] <- archive["entities"] do
        entity = rewrite.(entity)

        entity =
          if kind == "checkpoint" and not checkpoints_ok? and entity["status"] == "ready",
            do: Map.merge(entity, %{"status" => "missing", "files" => []}),
            else: entity

        {kind, eid, entity}
      end

    entities =
      entities
      |> Enum.map(&carried(&1, id, archive, meta, dest_root))
      |> Enum.map(&with_session(&1, carried_session))

    for %{"fileName" => name, "data" => data} <- archive["attachments"] do
      path = Path.join(Attachments.dir(), Path.basename(name))
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, data)
    end

    for %{"fileName" => terminal, "data" => data} <- archive["terminalLogs"],
        do: Terminal.put_scrollback(id, terminal, data)

    at = archive["updatedAt"] || System.os_time(:millisecond)
    changes = changes(id, entities, at)
    commit(id, changes)

    {:ok,
     %{
       thread: id,
       title: meta["title"],
       project: project["id"],
       session: carried_session != nil,
       notes: checkpoint_notes ++ session_notes
     }}
  end

  # The thread's entity knows where it came from, so the agent can be told the project
  # moved; a worktree it had stays behind on the machine it left.
  defp carried({"thread", eid, entity}, id, _archive, meta, dest_root) when eid == id do
    arrived =
      if meta["projectRoot"] && meta["projectRoot"] != dest_root,
        do: %{"from" => meta["projectRoot"], "to" => dest_root, "machine" => meta["machine"]}

    entity =
      entity
      |> Map.drop(["movedTo", "moving"])
      |> Map.put("worktreePath", nil)
      |> then(&if(arrived, do: Map.put(&1, "arrived", arrived), else: &1))

    {"thread", eid, entity}
  end

  # A provider thread's own session stays on the machine it left unless it is carried
  # (`place_session/3`); without it the next message is a handoff.
  defp carried({"provider-thread", eid, entity}, _id, _archive, _meta, _root) do
    ref = entity["nativeThreadRef"]
    entity = if is_map(ref), do: Map.put(entity, "nativeThreadRef", nil), else: entity
    {"provider-thread", eid, Map.delete(entity, "carriedSession")}
  end

  defp carried(row, _id, _archive, _meta, _root), do: row

  # The provider thread whose session came along continues from the copy.
  defp with_session(
         {"provider-thread", eid, entity},
         %{"providerThreadId" => eid, "carriedSession" => session}
       ),
       do: {"provider-thread", eid, Map.put(entity, "carriedSession", session)}

  defp with_session(row, _carried), do: row

  # Every entity as a patch from what this node has (nothing, or a forwarding record
  # and the copy it left behind), so a thread coming back does not repeat anything.
  defp changes(id, entities, at) do
    current = state(id)
    have = for {kind, eid, _} <- StreamState.rows(current), into: MapSet.new(), do: {kind, eid}
    incoming = for {kind, eid, _} <- entities, into: MapSet.new(), do: {kind, eid}

    deletes =
      for {kind, eid} <- have,
          not MapSet.member?(incoming, {kind, eid}),
          do: {kind, eid, Patch.delete(), at}

    upserts =
      for {kind, eid, entity} <- entities,
          patch = Patch.diff(StreamState.get(current, kind)[eid], entity),
          patch != :unchanged,
          do: {kind, eid, patch, at}

    deletes ++ upserts
  end

  defp commit(_id, []), do: :ok

  defp commit(id, changes) do
    if Process.whereis(HalC2.Streams) do
      {:ok, _} = Streams.commit(id, :thread, changes)
      Streams.flush_shell(id)
    else
      {:ok, _} = Store.append([{:thread, id, changes}])
      HalC2.Projection.rebuild(id)
    end

    :ok
  end

  # --- version 1 (the Node server's archive) -------------------------------------------

  defp write_v1(archive, project) do
    meta = archive["thread"]
    id = meta["id"]

    source =
      Path.join(System.tmp_dir!(), "hal-c2-thread-#{System.unique_integer([:positive])}.sqlite")

    rewrite =
      rewriter(
        meta["sourceWorkspaceRoot"],
        project["workspaceRoot"],
        meta["sourceProjectId"],
        project["id"]
      )

    try do
      events =
        for event <- archive["events"] || [], event["streamId"] == id do
          payload = event["payloadJson"] |> JSON.decode!() |> rewrite.()

          {event["aggregateKind"], event["streamId"], event["eventType"], payload,
           event["occurredAt"], event["applicationEventVersion"]}
        end

      node_log(source, events)
      {:ok, _} = HalC2.Import.V2.run(source, Store, only: [id])
    after
      File.rm(source)
    end

    for %{"fileName" => name, "data" => data} <- archive["attachments"] do
      path = Path.join(Attachments.dir(), Path.basename(name))
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, data)
    end

    for %{"fileName" => name, "data" => data} <- archive["terminalLogs"],
        terminal = v1_terminal(name, id),
        do: Terminal.put_scrollback(id, terminal, data)

    # The Node server's provider sessions do not come along: the next message hands
    # the conversation over.
    loaded = StreamState.load(Store.path(), id)

    native =
      for pt <- StreamState.list(loaded, "provider-thread"),
          is_map(pt["nativeThreadRef"]),
          do: {"provider-thread", pt["id"], %{"s" => %{"nativeThreadRef" => nil}}}

    if native != [], do: {:ok, _} = Store.append([{:thread, id, native}])

    if Process.whereis(HalC2.Shell) do
      case HalC2.Projection.rebuild(id) do
        {_, _} = kind_row -> HalC2.Shell.put_row(id, kind_row)
        nil -> :ok
      end
    else
      HalC2.Projection.rebuild(id)
    end

    {:ok, %{thread: id, title: meta["title"], project: project["id"], session: false, notes: []}}
  end

  defp v1_terminal(name, thread_id) do
    prefix = "terminal_#{Base.url_encode64(thread_id, padding: false)}"

    cond do
      name == prefix <> ".log" ->
        "term-1"

      String.starts_with?(name, prefix <> "_") and String.ends_with?(name, ".log") ->
        case name
             |> String.replace_prefix(prefix <> "_", "")
             |> String.replace_suffix(".log", "")
             |> Base.url_decode64(padding: false) do
          {:ok, terminal} -> terminal
          :error -> nil
        end

      true ->
        nil
    end
  end

  defp node_log(path, events) do
    alias Exqlite.Sqlite3
    {:ok, db} = Sqlite3.open(path)

    try do
      :ok =
        Sqlite3.execute(db, """
        CREATE TABLE orchestration_events (
          sequence INTEGER PRIMARY KEY AUTOINCREMENT, aggregate_kind TEXT, stream_id TEXT,
          event_type TEXT, payload_json TEXT, occurred_at TEXT, application_event_version INTEGER)
        """)

      {:ok, stmt} =
        Sqlite3.prepare(db, """
        INSERT INTO orchestration_events (aggregate_kind, stream_id, event_type, payload_json,
          occurred_at, application_event_version) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        """)

      :ok = Sqlite3.execute(db, "BEGIN")

      for {aggregate, stream, type, payload, at, version} <- events do
        :ok = Sqlite3.bind(stmt, [aggregate, stream, type, JSON.encode!(payload), at, version])
        :done = Sqlite3.step(db, stmt)
      end

      :ok = Sqlite3.execute(db, "COMMIT")
      :ok = Sqlite3.release(db, stmt)
    after
      Sqlite3.close(db)
    end
  end

  # --- pieces ---------------------------------------------------------------------

  @doc "A short account of an archive: `%{thread, title, attachments, terminalLogs, checkpoints, session}`."
  def summary(archive) do
    %{
      thread: archive["thread"]["id"],
      title: archive["thread"]["title"],
      attachments: length(archive["attachments"] || []),
      terminal_logs: length(archive["terminalLogs"] || []),
      checkpoints: length((archive["checkpoints"] || %{})["refs"] || []),
      session: archive["session"] != nil
    }
  end

  defp attachments(state) do
    for message <- StreamState.list(state, "message"),
        %{"id" => _} = attachment <- List.wrap(message["attachments"]),
        path = Attachments.path(attachment),
        path != nil,
        uniq: true,
        do: file(Path.basename(path), File.read!(path))
  end

  # The thread's checkpoint refs (and the workspace before its first run) as one
  # bundle, so diffs and rewinds work in another checkout of the repository.
  defp checkpoints(_state, nil), do: nil

  defp checkpoints(state, root) do
    scopes = StreamState.list(state, "checkpoint-scope")

    refs =
      (for(c <- StreamState.list(state, "checkpoint"), is_binary(c["ref"]), do: c["ref"]) ++
         for(s <- scopes, do: Checkpoint.ref(s["id"], 0)))
      |> Enum.uniq()
      |> Enum.filter(&(is_binary(&1) and Checkpoint.exists?(scope_cwd(scopes, root), &1)))

    cwd = scope_cwd(scopes, root)

    with [_ | _] <- refs,
         bundle =
           Path.join(System.tmp_dir!(), "hal-c2-bundle-#{System.unique_integer([:positive])}"),
         {:ok, _} <- HalC2.Git.ok(cwd, ["bundle", "create", bundle | refs]) do
      data = File.read!(bundle)
      File.rm(bundle)
      %{"refs" => refs, "bundle" => file("checkpoints.bundle", data)}
    else
      _ -> nil
    end
  end

  defp scope_cwd(scopes, root) do
    Enum.find_value(scopes, root, fn scope ->
      if is_binary(scope["cwd"]) and File.dir?(scope["cwd"]), do: scope["cwd"]
    end)
  end

  # Fetches the carried checkpoint refs into the destination checkout. A different
  # repository keeps none, and says so.
  defp place_checkpoints(%{"checkpoints" => nil}, _root, _same), do: {[], true}

  defp place_checkpoints(%{"checkpoints" => checkpoints, "thread" => meta}, root, true) do
    bundle = Path.join(System.tmp_dir!(), "hal-c2-bundle-#{System.unique_integer([:positive])}")
    File.write!(bundle, checkpoints["bundle"]["data"])

    specs = for ref <- checkpoints["refs"], do: "+#{ref}:#{ref}"

    try do
      case HalC2.Git.ok(root, ["fetch", "--no-tags", "-q", bundle | specs]) do
        {:ok, _} -> {[], true}
        {:error, _} -> {[checkpoints_note(meta, "could not be copied")], false}
      end
    after
      File.rm(bundle)
    end
  end

  defp place_checkpoints(%{"thread" => meta}, _root, false),
    do: {[checkpoints_note(meta, "stay behind")], false}

  defp checkpoints_note(meta, what),
    do:
      "Checkpoints of #{meta["title"]} #{what}: the project on #{label()} is a different repository, so runs from before the move have no diff and cannot be rewound to."

  defp session(state, thread, cwd) do
    PortableSessions.export(state, thread, cwd)
  end

  defp place_session(%{"session" => nil}, _root, _opts), do: {nil, []}

  defp place_session(%{"session" => session} = archive, root, opts) do
    if Keyword.get(opts, :session, true),
      do: PortableSessions.place(session, root, archive),
      else: {nil, []}
  end

  @doc """
  A function rewriting every string under `from` (a project root) to `to`, and the
  project id `from_id` to `to_id`, anywhere in a JSON-shaped value.
  """
  def rewriter(from, to, from_id, to_id) do
    fn value -> rewrite(value, from, to, from_id, to_id) end
  end

  defp rewrite(%{} = map, from, to, from_id, to_id) do
    Map.new(map, fn
      {"projectId", ^from_id} when from_id != nil -> {"projectId", to_id}
      {key, value} -> {key, rewrite(value, from, to, from_id, to_id)}
    end)
  end

  defp rewrite(list, from, to, from_id, to_id) when is_list(list),
    do: Enum.map(list, &rewrite(&1, from, to, from_id, to_id))

  defp rewrite(string, from, to, _from_id, _to_id)
       when is_binary(string) and is_binary(from) and is_binary(to) and from != "" and
              from != to,
       do: replace_root(string, from, to)

  defp rewrite(value, _from, _to, _from_id, _to_id), do: value

  # Only whole path segments: "/code/shop" does not match "/code/shop-app".
  defp replace_root(string, from, to) do
    if String.contains?(string, from),
      do: Regex.replace(~r/#{Regex.escape(from)}(?=$|[\/\\"'\s:;,)\]}])/, string, to),
      else: string
  end

  @doc "The repository a checkout belongs to, as `host/owner/repo`, from its origin."
  def repository(nil), do: nil

  def repository(root) do
    with true <- File.dir?(root),
         {:ok, url} <- HalC2.Git.ok(root, ~w(config --get remote.origin.url)),
         url when url != "" <- String.trim(url) do
      HalC2.AgentSessions.remote_key(url)
    else
      _ -> nil
    end
  end

  defp file(name, data),
    do: %{"fileName" => name, "sha256" => sha256(data), "dataBase64" => Base.encode64(data)}

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp find_thread(ref) do
    threads = for {"thread", row} <- local_rows(), do: row

    case Enum.find(threads, &(&1["id"] == ref)) ||
           Enum.filter(threads, &(&1["title"] == ref and &1["movedTo"] == nil)) do
      %{"id" => id} -> {:ok, id}
      [%{"id" => id}] -> {:ok, id}
      [] -> {:error, "There is no thread #{ref} on #{label()}."}
      _ -> {:error, "Several threads on #{label()} are called #{ref}. Name it by its id."}
    end
  end

  # This node's sidebar rows as stored, which a stream writes before it tells the shell.
  defp local_rows, do: for({_id, kind, row} <- Store.list_shell(Store.path()), do: {kind, row})

  defp local_thread(id) do
    if id in Enum.map(Store.list_streams(Store.path()), & &1.id),
      do: StreamState.get(state(id), "thread")[id]
  end

  defp state(id) do
    if Process.whereis(HalC2.Streams),
      do: Streams.Server.state(Streams.ensure(id)),
      else: StreamState.load(Store.path(), id)
  end

  defp project(nil), do: nil

  defp project(id) do
    Enum.find_value(local_rows(), fn
      {"project", %{"id" => ^id} = row} -> row
      _ -> nil
    end)
  end

  defp moved_message(thread),
    do: "#{thread["title"]} has moved to #{thread["movedTo"]["label"] || "another machine"}."

  @doc "This machine's name, as clients show it."
  def label, do: HalC2.Environment.descriptor()["label"]

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
