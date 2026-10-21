defmodule HalC2.Import.PreviousInstall do
  @moduledoc """
  Picks threads out of a T3 Code or earlier HAL-C2 install on this machine and brings
  them onto the running MC, for `HalC2.Import.Picker`.

  A source is a data directory holding an earlier install's database: `userdata` and
  `dev` under an old home (`HalC2.Paths.legacy_candidates/3`, `state.sqlite` or
  `statev2.sqlite`), and the XDG data directories an earlier install used. Only those are
  read, and only read: the database is opened read-only, so a server still running
  on it is undisturbed.

  A thread comes with the threads its subagents ran in, its attachments and its
  terminal scrollback. It lands in the project at the same folder, which is created
  when this MC has none there. The agent's session is on this machine already, so the
  thread keeps its tie to it; a turn the source was running is ended as interrupted.
  Checkpoints are refs in the project's repository and need no copying
  (`HalC2.Checkpoint`).
  """

  alias Exqlite.Sqlite3
  alias HalC2.{Attachments, Paths, Projects, Store, StreamState, Terminal, ThreadArchive}

  @databases ~w(statev2.sqlite state.sqlite)

  # The store's mark on a thread being imported: "events:" and the project it goes to
  # from before its stream is made until all its events are in (`Import.V2` writes them
  # in batches), then "files:" and that project until its files are brought, when the
  # mark goes. The project stays in both stages: whichever stage an import stopped
  # at, its stored events were already rewritten into that project.
  @mark_prefix "import.thread."
  @events "events:"
  @files "files:"
  @project_gone {:error,
                 "It was partly imported into a project that is no longer here, so it cannot be continued."}

  @doc "The installs found on this machine: `[%{\"path\", \"label\"}]`."
  def sources(env \\ System.get_env(), user_home \\ Paths.user_home()) do
    old =
      for home <- Paths.legacy_candidates(env, user_home),
          {sub, suffix} <- [{"userdata", ""}, {"dev", " (development)"}],
          do: {Path.join(home, sub), old_label(home) <> suffix}

    node =
      for {app, suffix} <- [{"hal-c2", ""}, {"hal-c2-dev", " (development)"}],
          do:
            {Paths.app_dirs(nil, env, user_home, Paths.platform(), app).data,
             "HAL-C2 before the MC" <> suffix}

    for {dir, label} <- old ++ node, database(dir) != nil, do: %{"path" => dir, "label" => label}
  end

  defp old_label(home), do: if(Path.basename(home) == ".hal-c2", do: "HAL-C2", else: "T3 Code")

  defp database(dir),
    do: Enum.find(Enum.map(@databases, &Path.join(dir, &1)), &File.regular?/1)

  @doc """
  The threads of the source at `input["source"]`, the ones still in play before the
  settled ones and newest first within each, without the ones subagents ran in:
  `%{"threads" => [%{"id", "title", "project", "updatedAt", "subagents", "settled",
  "imported"}]}`.
  """
  def scan(%{"source" => path}) do
    with {:ok, index} <- index(path) do
      done = done(MapSet.new(Store.list_streams(Store.path()), & &1.id), marks())

      threads =
        for thread <- Map.values(index.threads), thread.parent == nil do
          project = index.projects[thread.project]
          members = family(index, thread.id)

          %{
            "id" => thread.id,
            "title" => thread.title,
            "project" => (project && project.title) || thread.project,
            "updatedAt" => thread.updated_at,
            "subagents" => length(members) - 1,
            "settled" => thread.settled,
            "imported" => todo(members, done) == []
          }
        end

      threads = Enum.sort_by(threads, &{!&1["settled"], &1["updatedAt"] || "", &1["id"]}, :desc)
      {:ok, %{"threads" => threads}}
    end
  end

  def scan(_), do: {:error, "Name the install to read."}

  @doc """
  Imports the threads `input["threadIds"]` of the source at `input["source"]`:
  `%{"imported" => [id], "failed" => [%{"id", "message"}]}`. One thread failing
  leaves the others alone.
  """
  def import_threads(input, report \\ fn _progress -> :ok end)

  def import_threads(%{"source" => path, "threadIds" => ids}, report) when is_list(ids) do
    with {:ok, index} <- index(path) do
      files = %{
        attachments: ls(Path.join(path, "attachments")),
        terminals: ls(Path.join([path, "logs", "terminals"]))
      }

      results = Enum.map(ids, &{&1, import_thread(path, index, files, &1, report)})

      {:ok,
       %{
         "imported" => for({id, :ok} <- results, do: id),
         "failed" => for({id, {:error, m}} <- results, do: %{"id" => id, "message" => m})
       }}
    end
  end

  def import_threads(_, _), do: {:error, "Name the install and the threads to import."}

  # `report` hears how far the thread is: its events read, then its threads finished.
  # A thread whose stream is here but whose events or files were not all brought (the
  # import failed or the MC stopped) is marked so in the store, and a retry continues it
  # rather than answering "already here": its events after those already in, then its
  # files. The marks are state, not a lock: two imports of one thread at once are kept
  # apart by a lock on it, which goes with the process holding it.
  # The lock is on the family's root, not the thread asked for: an import writes the
  # whole family, and the picker accepts a subagent's thread by id too, so imports of
  # a parent and of its child would otherwise both run over the child's stream.
  defp import_thread(path, index, files, id, report) do
    case :global.trans(
           {{__MODULE__, root_of(index, id)}, self()},
           fn -> import_free(path, index, files, id, report) end,
           [node()],
           0
         ) do
      :aborted -> {:error, "It is being imported already."}
      result -> result
    end
  end

  defp import_free(path, index, files, id, report) do
    with %{} = thread <- index.threads[id] || {:error, "It is not in #{path}."},
         family = family(index, id),
         here = Store.streams_present(Store.path(), family),
         marks = marks(),
         [_ | _] = missing <- todo(family, done(here, marks)),
         :ok <- known_marks(missing, marks),
         # Absent here, or here with only some of their events. `here` and `marks` are
         # read before the marks below are put, so only streams an earlier import left
         # resume, and only into the project they were going to.
         reading = Enum.filter(missing, &(not MapSet.member?(here, &1) or events?(marks[&1]))),
         resumed = Enum.filter(reading, &MapSet.member?(here, &1)),
         # Here, marked, at either stage: their stored events were rewritten into the
         # marked project, so the retry must land there and must not make another.
         staged =
           Enum.filter(missing, &(MapSet.member?(here, &1) and Map.has_key?(marks, &1))),
         {:ok, project, target} <- target(index.projects[thread.project], staged == []),
         :ok <- same_project(staged, marks, target["id"]) do
      rewrite =
        ThreadArchive.rewriter(project.root, target["workspaceRoot"], project.id, target["id"])

      events = &report.(%{"stage" => "events", "done" => &1, "total" => &2})
      threads = &report.(%{"stage" => "files", "done" => &1, "total" => length(missing)})

      Enum.each(reading, &(:ok = Store.put_meta(mark_key(&1), @events <> target["id"])))

      if reading != [] do
        {:ok, _} =
          HalC2.Import.V2.run(database(path), Store,
            only: reading,
            resume: Map.new(resumed, &{&1, Store.stream_tail(Store.path(), &1)}),
            rewrite: rewrite,
            progress: events
          )

        Enum.each(reading, &(:ok = Store.put_meta(mark_key(&1), @files <> target["id"])))
      end

      threads.(0)

      missing
      |> Enum.with_index(1)
      |> Enum.each(fn {id, n} ->
        finish(path, files, id)
        :ok = Store.delete_meta(mark_key(id))
        threads.(n)
      end)
    else
      [] -> {:error, "It is already here."}
      {:error, message} -> {:error, message}
    end
  rescue
    error -> {:error, "It could not be read: #{Exception.message(error)}"}
  end

  # The events already stored were rewritten into the project they were imported into;
  # the rest must land there too, or the thread would hold two projects' ids.
  defp same_project(staged, marks, project_id) do
    if Enum.all?(staged, &(marks[&1] in [@events <> project_id, @files <> project_id])),
      do: :ok,
      else: @project_gone
  end

  # A mark this MC does not know (a newer MC's extra stage, say) is not the files
  # stage, whatever else it could be taken for: finishing such a thread from its
  # partial state and clearing the mark would make truncated history permanent.
  # As `done/2`, it fails closed and the mark stays.
  defp known_marks(missing, marks) do
    if Enum.all?(missing, &(stage(marks[&1]) != :unknown)) do
      :ok
    else
      {:error,
       "It was partly imported in a way this MC does not know, so it cannot be continued."}
    end
  end

  defp stage(nil), do: nil

  defp stage(mark) do
    cond do
      events?(mark) -> :events
      String.starts_with?(mark, @files) -> :files
      true -> :unknown
    end
  end

  defp events?(mark), do: is_binary(mark) and String.starts_with?(mark, @events)

  # The files of an imported thread, and its row in the sidebar.
  defp finish(path, files, id) do
    state = StreamState.load(Store.path(), id)

    for kind <- ["message", "turn-item"],
        entity <- StreamState.list(state, kind),
        %{"id" => attachment} when is_binary(attachment) <- entity["attachments"] || [],
        name <- files.attachments,
        String.starts_with?(name, attachment <> ".") do
      File.mkdir_p!(Attachments.dir())
      File.cp!(Path.join([path, "attachments", name]), Path.join(Attachments.dir(), name))
    end

    for name <- files.terminals, terminal = ThreadArchive.v1_terminal(name, id) do
      log = File.read!(Path.join([path, "logs", "terminals", name]))
      Terminal.put_scrollback(id, terminal, log)
    end

    HalC2.Orchestration.Recovery.settle(id)

    with {_, _} = kind_row <- HalC2.Projection.rebuild(id), do: HalC2.Shell.put_row(id, kind_row)
  end

  # The project here at the source project's folder, made when there is none and
  # `create?` (a thread partly imported is continued only in the project it went to).
  defp target(nil, _create?), do: {:error, "Its project is gone from the install."}

  defp target(project, create?) do
    root = Path.expand(project.root)

    case Enum.find(ThreadArchive.local_projects(), &(Path.expand(&1["workspaceRoot"]) == root)) do
      %{} = local ->
        {:ok, project, local}

      nil when not create? ->
        @project_gone

      nil ->
        taken? = MapSet.member?(Store.streams_present(Store.path(), [project.id]), project.id)
        id = if taken?, do: HalC2.Environment.uuid4(), else: project.id

        input = %{
          "type" => "project.create",
          "projectId" => id,
          "workspaceRoot" => root,
          "title" => project.title,
          "scripts" => project.scripts
        }

        case Projects.mutate(input) do
          {:ok, local} ->
            # The project's row is written a moment after the commit; a retry of a failed
            # import must find the project it made, not try to make it again.
            HalC2.Streams.flush_shell(id)
            {:ok, project, local}

          {:error, _} ->
            {:error, "Its project folder #{root} is no longer on this machine."}
        end
    end
  end

  # The oldest ancestor of a thread in the index (itself, for a thread no subagent
  # ran from, or one not in the index).
  defp root_of(index, id), do: root_of(index, id, MapSet.new())

  defp root_of(index, id, seen) do
    case index.threads[id] do
      %{parent: parent} when is_binary(parent) ->
        if MapSet.member?(seen, id), do: id, else: root_of(index, parent, MapSet.put(seen, id))

      _ ->
        id
    end
  end

  # A thread and every thread its subagents ran in.
  defp family(index, id),
    do: [id | Enum.flat_map(Map.get(index.children, id, []), &family(index, &1))]

  # The threads here whole: their streams are here and no mark says their events or
  # files are not. Any mark counts, whatever it says, so one this MC does not know
  # leaves the thread to be imported again rather than taken as whole.
  defp done(here, marks), do: MapSet.reject(here, &Map.has_key?(marks, &1))

  defp marks do
    for {key, mark} <- Store.metas(Store.path(), @mark_prefix),
        into: %{},
        do: {String.replace_prefix(key, @mark_prefix, ""), mark}
  end

  @doc """
  The streams an import has not finished bringing here: they are left out of the
  sidebar until a retry makes them whole (`HalC2.Shell`).
  """
  def unfinished(path) do
    for {key, _} <- Store.metas(path, @mark_prefix),
        into: MapSet.new(),
        do: String.replace_prefix(key, @mark_prefix, "")
  end

  # The threads of a family still to bring: absent here, or here without their files.
  defp todo(family, done), do: Enum.reject(family, &MapSet.member?(done, &1))

  defp mark_key(id), do: @mark_prefix <> id

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      {:error, _} -> []
    end
  end

  # The source's threads and projects, from the earlier install's read model. Threads it
  # never moved to orchestration v2 are only in the older table.
  defp index(path) do
    if Enum.any?(sources(), &(&1["path"] == path)) do
      {:ok, db} = Sqlite3.open(database(path), mode: :readonly)

      try do
        v2 =
          rows(db, "orchestration_v2_projection_threads", """
          thread_id, project_id, title, updated_at,
          json_extract(payload_json, '$.lineage.parentThreadId'),
          json_extract(payload_json, '$.settledOverride'),
          json_extract(payload_json, '$.settledAt')
          """)

        v1 =
          rows(
            db,
            "projection_threads",
            "thread_id, project_id, title, updated_at, NULL, NULL, NULL"
          )

        threads =
          for [id, project, title, updated_at, parent, override, settled_at] <- v1 ++ v2,
              into: %{} do
            {id,
             %{
               id: id,
               project: project,
               title: title,
               updated_at: updated_at,
               parent: parent,
               # As the source's sidebar had it: the user's choice wins over the rule's.
               settled: override == "settled" or (settled_at != nil and override != "active")
             }}
          end

        projects =
          for [id, title, root, scripts] <-
                rows(db, "projection_projects", "project_id, title, workspace_root, scripts_json"),
              into: %{} do
            {id, %{id: id, title: title, root: root, scripts: JSON.decode!(scripts || "[]")}}
          end

        children =
          threads
          |> Map.values()
          |> Enum.filter(&(&1.parent != nil))
          |> Enum.group_by(& &1.parent, & &1.id)

        {:ok, %{threads: threads, projects: projects, children: children}}
      after
        Sqlite3.close(db)
      end
    else
      {:error, "#{path} is not a T3 Code or HAL-C2 install on this machine."}
    end
  end

  # A table's live rows, or none when the source's schema has no such table.
  defp rows(db, table, columns) do
    with {:ok, info} <- Sqlite3.prepare(db, "SELECT name FROM pragma_table_info('#{table}')"),
         {:ok, [_ | _] = names} <- Sqlite3.fetch_all(db, info),
         where = if(["deleted_at"] in names, do: "WHERE deleted_at IS NULL", else: ""),
         {:ok, stmt} <- Sqlite3.prepare(db, "SELECT #{columns} FROM #{table} #{where}"),
         {:ok, rows} <- Sqlite3.fetch_all(db, stmt) do
      rows
    else
      _ -> []
    end
  end
end
