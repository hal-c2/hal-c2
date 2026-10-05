defmodule HalC2.Import.PreviousInstall do
  @moduledoc """
  Picks threads out of a T3 Code or Node HAL-C2 install on this machine and brings
  them onto the running MC, for `HalC2.Import.Picker`.

  A source is a data directory holding the Node server's database: `userdata` and
  `dev` under an old home (`HalC2.Paths.legacy_candidates/3`, `state.sqlite` or
  `statev2.sqlite`), and the Node server's own XDG data directories. Only those are
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
      here = here()

      threads =
        for thread <- Map.values(index.threads), thread.parent == nil do
          project = index.projects[thread.project]

          %{
            "id" => thread.id,
            "title" => thread.title,
            "project" => (project && project.title) || thread.project,
            "updatedAt" => thread.updated_at,
            "subagents" => length(family(index, thread.id)) - 1,
            "settled" => thread.settled,
            "imported" => MapSet.member?(here, thread.id)
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
  def import_threads(%{"source" => path, "threadIds" => ids}) when is_list(ids) do
    with {:ok, index} <- index(path) do
      files = %{
        attachments: ls(Path.join(path, "attachments")),
        terminals: ls(Path.join([path, "logs", "terminals"]))
      }

      results = Enum.map(ids, &{&1, import_thread(path, index, files, &1)})

      {:ok,
       %{
         "imported" => for({id, :ok} <- results, do: id),
         "failed" => for({id, {:error, m}} <- results, do: %{"id" => id, "message" => m})
       }}
    end
  end

  def import_threads(_), do: {:error, "Name the install and the threads to import."}

  defp import_thread(path, index, files, id) do
    with %{} = thread <- index.threads[id] || {:error, "It is not in #{path}."},
         [_ | _] = missing <- family(index, id) -- MapSet.to_list(here()),
         {:ok, project, target} <- target(index.projects[thread.project]) do
      rewrite =
        ThreadArchive.rewriter(project.root, target["workspaceRoot"], project.id, target["id"])

      {:ok, _} = HalC2.Import.V2.run(database(path), Store, only: missing, rewrite: rewrite)
      Enum.each(missing, &finish(path, files, &1))
    else
      [] -> {:error, "It is already here."}
      {:error, message} -> {:error, message}
    end
  rescue
    error -> {:error, "It could not be read: #{Exception.message(error)}"}
  end

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

  # The project here at the source project's folder, made when there is none.
  defp target(nil), do: {:error, "Its project is gone from the install."}

  defp target(project) do
    root = Path.expand(project.root)

    case Enum.find(ThreadArchive.local_projects(), &(Path.expand(&1["workspaceRoot"]) == root)) do
      %{} = local ->
        {:ok, project, local}

      nil ->
        id =
          if MapSet.member?(here(), project.id), do: HalC2.Environment.uuid4(), else: project.id

        input = %{
          "type" => "project.create",
          "projectId" => id,
          "workspaceRoot" => root,
          "title" => project.title,
          "scripts" => project.scripts
        }

        case Projects.mutate(input) do
          {:ok, local} -> {:ok, project, local}
          {:error, _} -> {:error, "Its project folder #{root} is no longer on this machine."}
        end
    end
  end

  # A thread and every thread its subagents ran in.
  defp family(index, id),
    do: [id | Enum.flat_map(Map.get(index.children, id, []), &family(index, &1))]

  defp here, do: MapSet.new(Store.list_streams(Store.path()), & &1.id)

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      {:error, _} -> []
    end
  end

  # The source's threads and projects, from the Node server's read model. Threads it
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
