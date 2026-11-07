defmodule HalC2.Projects do
  @moduledoc """
  Projects on this MC (`projects.mutate`) and the folder browser used to pick a
  project's workspace root (`filesystem.browse`).

  A project is its own stream holding one `project` entity in the shape of the
  contracts' `Project`; its sidebar row follows from it (`HalC2.Projection`).
  Deleting sets `deletedAt`, which removes it from clients' sidebars.

  A project in a git checkout carries the contracts' `RepositoryIdentity`, keyed by
  its origin. Clients group projects on different machines by its `canonicalKey`,
  which is how a new thread's composer offers every machine with a checkout.
  """

  alias HalC2.{Patch, StreamState}
  alias HalC2.Orchestration.Entities

  @spec mutate(map) :: {:ok, map} | {:error, String.t()}
  def mutate(m) do
    case apply_mutation(m) do
      {:error, {:owned, message, _owner}} -> {:error, message}
      reply -> reply
    end
  end

  @doc """
  `mutate/1` for a client: a folder another project owns is refused with that
  project's id in `projectId`, so the client can open the project it was after.
  """
  @spec mutate_for_client(map) :: {:ok, map} | {:error, String.t() | map}
  def mutate_for_client(m) do
    case apply_mutation(m) do
      {:error, {:owned, message, owner}} ->
        {:error, %{"_tag" => "WorkspaceInUse", "message" => message, "projectId" => owner}}

      reply ->
        reply
    end
  end

  defp apply_mutation(%{"type" => "project.create", "projectId" => id} = m) do
    root = workspace_root(m["workspaceRoot"] || "")

    cond do
      root == "" ->
        {:error, "a workspace folder is required"}

      relative?(root) ->
        {:error, relative_error(root)}

      not File.dir?(root) and m["createWorkspaceRootIfMissing"] != true ->
        {:error, "#{root} does not exist on this machine"}

      owner = owner(root, id) ->
        {:error, {:owned, "Workspace #{root} already belongs to project #{owner}.", owner}}

      true ->
        File.mkdir_p!(root)
        at = Entities.now()

        project = %{
          "id" => id,
          "title" => m["title"] || Path.basename(root),
          "workspaceRoot" => root,
          "defaultModelSelection" => m["defaultModelSelection"],
          "scripts" => m["scripts"] || [],
          "createdAt" => at,
          "updatedAt" => at,
          "deletedAt" => nil
        }

        project =
          case repository_identity(root) do
            nil -> project
            identity -> Map.put(project, "repositoryIdentity", identity)
          end

        {:ok, _} = HalC2.Streams.commit(id, :project, [{"project", id, Patch.diff(nil, project)}])
        {:ok, contract(project)}
    end
  end

  defp apply_mutation(%{"type" => "project.update", "projectId" => id} = m) do
    fields =
      m
      |> Map.take(
        ~w(title defaultModelSelection scripts autoPull projectIcon faviconPath defaultThreadEnvMode)
      )
      |> then(
        &if(m["workspaceRoot"],
          do: Map.put(&1, "workspaceRoot", workspace_root(m["workspaceRoot"])),
          else: &1
        )
      )

    case relative_root(fields) || (fields["workspaceRoot"] && owner(fields["workspaceRoot"], id)) do
      {:refused, error} ->
        {:error, error}

      nil ->
        # A moved project belongs to the repository of its new folder, if any.
        identify =
          case fields["workspaceRoot"] do
            nil -> & &1
            root -> identify(repository_identity(root))
          end

        # An update that changes nothing keeps the update time, so nothing is recorded.
        update(id, fn current ->
          next = current |> Map.merge(fields) |> identify.()
          if next == current, do: current, else: Map.put(next, "updatedAt", Entities.now())
        end)

      owner ->
        {:error,
         {:owned, "Workspace #{fields["workspaceRoot"]} already belongs to project #{owner}.",
          owner}}
    end
  end

  # A project with threads is deleted only with `force`, which deletes its threads first.
  defp apply_mutation(%{"type" => "project.delete", "projectId" => id} = m) do
    case {threads(id), m["force"] == true} do
      {[_ | _], false} ->
        {:error, "Project #{id} is not empty."}

      {threads, _} ->
        with :ok <- delete_threads(threads, m["commandId"] || "project.delete:#{id}"),
             :ok <- HalC2.ProjectClones.discard(id),
             do:
               update(
                 id,
                 &Map.merge(&1, %{"deletedAt" => Entities.now(), "updatedAt" => Entities.now()})
               )
    end
  end

  defp apply_mutation(%{"type" => type}), do: {:error, "#{type} is not supported"}

  defp update(id, fun) do
    HalC2.Streams.transact(id, :project, fn state ->
      case StreamState.get(state, "project")[id] do
        nil ->
          {[], {:error, "unknown project #{id}"}}

        current ->
          next = fun.(current)

          case Patch.diff(current, next) do
            :unchanged -> {[], {:ok, contract(next)}}
            patch -> {[{"project", id, patch}], {:ok, contract(next)}}
          end
      end
    end)
  end

  defp identify(nil), do: &Map.delete(&1, "repositoryIdentity")
  defp identify(identity), do: &Map.put(&1, "repositoryIdentity", identity)

  @doc """
  The repository a checkout belongs to, as the contracts' `RepositoryIdentity`: its
  origin, normalized as `HalC2.AgentSessions.remote_key/1` does. Nil
  outside a repository or without an origin.
  """
  def repository_identity(root) do
    with true <- is_binary(root) and File.dir?(root),
         {:ok, url} <- HalC2.Git.ok(root, ~w(config --get remote.origin.url)),
         url when url != "" <- String.trim(url),
         {:ok, top} <- HalC2.Git.ok(root, ~w(rev-parse --show-toplevel)) do
      key = HalC2.AgentSessions.remote_key(url)
      # Drops the host from `host/owner/.../name`.
      path = key |> String.split("/") |> Enum.drop(1) |> Enum.join("/")
      segments = String.split(path, "/", trim: true)

      %{
        "canonicalKey" => key,
        "locator" => %{
          "source" => "git-remote",
          "remoteName" => "origin",
          "remoteUrl" => without_credentials(url)
        },
        "rootPath" => String.trim(top),
        "displayName" => path,
        "owner" => List.first(segments),
        "name" => List.last(segments)
      }
      |> Map.reject(fn {_field, value} -> value in [nil, ""] end)
    else
      _ -> nil
    end
  end

  # Clients see the remote, so a token embedded in an HTTPS origin stays behind.
  defp without_credentials(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, userinfo: info} = uri
      when scheme in ["http", "https"] and is_binary(info) ->
        URI.to_string(%{uri | userinfo: nil})

      _ ->
        url
    end
  end

  @doc """
  Gives this MC's projects the repository identity of their checkout when the
  shell starts or loads new code (`HalC2.Shell`): projects added before the MC
  recorded one, ones imported from an earlier install, and checkouts whose origin changed. A folder that is gone or has no origin keeps
  what it had. Not a user edit, so the update time stays.
  """
  def identify_repositories do
    for {{mc, id}, {"project", project}} <- HalC2.Shell.rows(),
        mc == node() and project["deletedAt"] == nil,
        (identity = repository_identity(project["workspaceRoot"])) != nil,
        identity["canonicalKey"] != get_in(project, ["repositoryIdentity", "canonicalKey"]),
        do: update(id, identify(identity))

    :ok
  end

  # The other live project whose workspace is `root`, if any.
  defp owner(root, id) do
    Enum.find_value(stored(), fn project ->
      if project["id"] != id and project["workspaceRoot"] == root, do: project["id"]
    end)
  end

  @doc """
  The workspace roots of this MC's projects as stored, a project created a moment
  ago included (`roots/0` follows the sidebar, which catches up after).
  """
  def stored_roots, do: Enum.map(stored(), & &1["workspaceRoot"])

  # The projects not deleted, as stored.
  defp stored do
    path = HalC2.Store.path()

    for %{id: id, kind: "project"} <- HalC2.Store.list_streams(path),
        project = StreamState.get(StreamState.load(path, id), "project")[id],
        project && project["deletedAt"] == nil,
        do: project
  end

  # The project's threads not yet deleted, archived ones included.
  defp threads(id) do
    for {{mc, thread_id}, {"thread", row}} <- HalC2.Shell.rows(),
        mc == node() and row["projectId"] == id and row["deletedAt"] == nil,
        do: thread_id
  end

  defp delete_threads(threads, command_id) do
    Enum.reduce_while(threads, :ok, fn thread_id, :ok ->
      command = %{
        "type" => "thread.delete",
        "threadId" => thread_id,
        "commandId" => "#{command_id}:delete-thread:#{thread_id}"
      }

      case HalC2.Orchestration.dispatch(command) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # The contracts' `Project`: stored entities drop null fields, and projects
  # imported from an earlier install's log name their id `projectId`.
  defp contract(project) do
    optional =
      Map.take(
        project,
        ~w(repositoryIdentity faviconPath projectIcon defaultThreadEnvMode autoPull)
      )

    Map.merge(optional, %{
      "id" => project["id"] || project["projectId"],
      "title" => project["title"],
      "workspaceRoot" => project["workspaceRoot"],
      "defaultModelSelection" => project["defaultModelSelection"],
      "scripts" => project["scripts"] || [],
      "createdAt" => project["createdAt"],
      "updatedAt" => project["updatedAt"],
      "deletedAt" => project["deletedAt"]
    })
  end

  @doc """
  Brings projects whose settings say `defaultAutoPull` up to date at boot. Only a
  clean checkout on its default branch with an upstream,
  nothing of its own to push, and something new to pull. Each checkout is pulled
  once however many projects share it; a failure is logged and skipped. An MC without
  automatic actions (`HAL_C2_MC_NO_AUTO_ACTIONS`) pulls nothing.
  """
  def auto_pull do
    roots =
      for {{mc, _id}, {"project", project}} <- HalC2.Shell.rows(),
          Application.get_env(:hal_c2, :auto_actions, true),
          mc == node(),
          project["deletedAt"] == nil,
          HalC2.Settings.for_project(project["id"])["defaultAutoPull"] == true,
          uniq: true,
          do: project["workspaceRoot"]

    for root <- roots do
      local = HalC2.Vcs.local_status(root)

      with %{"isRepo" => true, "isDefaultRef" => true, "hasWorkingTreeChanges" => false} <-
             local,
           %{"hasUpstream" => true, "aheadCount" => 0, "behindCount" => behind} when behind > 0 <-
             HalC2.Vcs.remote_status(root, fetch: true),
           {:error, error} <- HalC2.Vcs.pull(%{"cwd" => root}) do
        require Logger
        Logger.warning("automatic pull of #{root} failed: #{inspect(error)}")
      end
    end

    :ok
  end

  @doc """
  The id of this MC's project a directory belongs to: a thread's worktree, or
  the project whose workspace holds it (the deepest one). Nil when none does.
  """
  def at(path) when is_binary(path) do
    path = Path.expand(path)
    rows = for {{mc, _id}, row} <- HalC2.Shell.rows(), mc == node(), do: row

    worktree =
      Enum.find_value(rows, fn
        {"thread", %{"worktreePath" => root, "projectId" => id}} when is_binary(root) ->
          if within?(path, root), do: id

        _ ->
          nil
      end)

    worktree ||
      rows
      |> Enum.flat_map(fn
        {"project", %{"workspaceRoot" => root, "id" => id} = row} when is_binary(root) ->
          if row["deletedAt"] == nil and within?(path, root), do: [{root, id}], else: []

        _ ->
          []
      end)
      |> Enum.max_by(fn {root, _} -> byte_size(root) end, fn -> {nil, nil} end)
      |> elem(1)
  end

  def at(_path), do: nil

  @doc "Every folder of this MC's projects: thread worktrees and live project workspaces."
  def roots do
    for {{mc, _id}, {kind, row}} <- HalC2.Shell.rows(),
        mc == node(),
        root = owned_root(kind, row),
        is_binary(root),
        do: root
  end

  defp owned_root("thread", row), do: row["worktreePath"]
  defp owned_root("project", row), do: if(row["deletedAt"] == nil, do: row["workspaceRoot"])
  defp owned_root(_kind, _row), do: nil

  defp within?(path, root) do
    root = Path.expand(root)
    path == root or String.starts_with?(path, root <> "/")
  end

  @doc """
  Folders matching a partly typed path: the folders in its parent whose names start
  with its last segment, or every folder inside it when it ends with a separator.
  Hidden folders show only when asked for.
  """
  @spec browse(map) :: {:ok, map} | {:error, String.t()}
  def browse(%{"partialPath" => partial} = input) do
    resolved = partial |> expand() |> Path.expand(input["cwd"] || home())
    whole_dir? = String.ends_with?(partial, "/") or partial == "~"
    parent = if whole_dir?, do: resolved, else: Path.dirname(resolved)
    prefix = if whole_dir?, do: "", else: Path.basename(resolved)
    show_hidden = whole_dir? or String.starts_with?(prefix, ".")

    case File.ls(parent) do
      {:ok, names} ->
        entries =
          for name <- Enum.sort(names),
              String.starts_with?(String.downcase(name), String.downcase(prefix)),
              show_hidden or not String.starts_with?(name, "."),
              File.dir?(Path.join(parent, name)),
              do: %{"name" => name, "fullPath" => Path.join(parent, name)}

        {:ok, %{"parentPath" => parent, "entries" => entries}}

      {:error, reason} when reason in [:eacces, :eperm] ->
        {:ok, %{"parentPath" => parent, "entries" => []}}

      {:error, reason} ->
        {:error, "cannot read #{parent}: #{:file.format_error(reason)}"}
    end
  end

  @doc "A folder as a user typed it, with a leading `~` as `$HOME`."
  def expand_home(path), do: expand(path)

  # A project's folder as stored: `~` is this MC's home and `.`/`..` are resolved. A
  # relative path stays as typed, for `relative?/1` to refuse: it has no meaning here.
  defp workspace_root(""), do: ""

  defp workspace_root(path) do
    path = expand(path)
    if relative?(path), do: path, else: Path.expand(path)
  end

  defp relative_root(%{"workspaceRoot" => root}) when is_binary(root) do
    cond do
      root == "" -> {:refused, "a workspace folder is required"}
      relative?(root) -> {:refused, relative_error(root)}
      true -> nil
    end
  end

  defp relative_root(_), do: nil

  defp relative?(path), do: path != "" and Path.type(path) != :absolute

  defp relative_error(path),
    do: "Workspace #{path} is not an absolute path. Use a full path or one starting with ~/."

  defp expand("~"), do: home()
  defp expand("~/" <> rest), do: Path.join(home(), rest)
  defp expand(path), do: path

  # `$HOME` as the process sees it now.
  defp home, do: System.get_env("HOME") || System.user_home!()
end
