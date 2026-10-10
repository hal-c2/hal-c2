defmodule HalC2.Steps.Orchestration.Projects do
  @moduledoc """
  Steps for `features/mc/orchestration/projects.feature`. Clients change projects
  over the socket (`projects.mutate`) and the reply is `context.reply`. Folders under
  `~` live in a scenario home: `$HOME` points at a temporary folder for the scenario,
  as the MC expands `~` from it, and is restored afterwards.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @old "2020-01-01T00:00:00.000Z"

  # --- creating -------------------------------------------------------------------

  step "the folder {string} does not exist", %{args: [folder]} = context do
    context = home(context)
    refute File.exists?(path(context, folder))
    context
  end

  step "a client creates project {string} for {string}", %{args: [id, folder]} = context do
    mutate(context, %{"type" => "project.create", "projectId" => id, "workspaceRoot" => folder})
  end

  step "a client creates project {string} for {string} asking to create the folder",
       %{args: [id, folder]} = context do
    context
    |> Map.put(:folder, folder)
    |> mutate(%{
      "type" => "project.create",
      "projectId" => id,
      "workspaceRoot" => folder,
      "createWorkspaceRootIfMissing" => true
    })
  end

  step "a client creates project {string} titled {string} with a default model and a test script",
       %{args: [id, title]} = context do
    context
    |> Map.put(:expected, %{
      "title" => title,
      "defaultModelSelection" => model(),
      "scripts" => [script()]
    })
    |> mutate(%{
      "type" => "project.create",
      "projectId" => id,
      "title" => title,
      "workspaceRoot" => World.git_repo(context, id),
      "defaultModelSelection" => model(),
      "scripts" => [script()]
    })
  end

  step "a client creates a project with no folder", context do
    mutate(context, %{"type" => "project.create", "projectId" => "p1", "title" => "App"})
  end

  step "a client creates a project for missing folder /missing without asking to create it",
       context do
    mutate(context, %{
      "type" => "project.create",
      "projectId" => "p1",
      "workspaceRoot" => "/missing"
    })
  end

  step "project {string} exists with title {string} and the folder expanded to a full path",
       %{args: [id, title]} = context do
    assert {:ok, %{"id" => ^id, "title" => ^title, "workspaceRoot" => root}} = context.reply
    assert root == Path.join(Mc.Host.home(context), "code/app")
    assert stored(id)["workspaceRoot"] == root
    context
  end

  step "it has no scripts and is not deleted", context do
    assert {:ok, %{"scripts" => [], "deletedAt" => nil}} = context.reply
    context
  end

  step "project {string} has that title, default model and script", %{args: [id]} = context do
    assert {:ok, project} = context.reply
    assert Map.take(project, Map.keys(context.expected)) == context.expected
    assert Map.take(stored(id), Map.keys(context.expected)) == context.expected
    context
  end

  step "the folder exists and project {string} points at it", %{args: [id]} = context do
    root = path(context, context.folder)
    assert File.dir?(root)
    assert {:ok, %{"id" => ^id, "workspaceRoot" => ^root}} = context.reply
    context
  end

  # --- updating ---------------------------------------------------------------------

  step "project {string} exists", %{args: [id]} = context do
    context = World.create_project(context, id)
    # Backdated, so an update's time is later even within the same millisecond.
    {:ok, _} =
      HalC2.Streams.commit(id, :project, [{"project", id, %{"s" => %{"updatedAt" => @old}}}])

    context
  end

  step "a client updates the {word} of {string}", %{args: [field, id]} = context do
    update(context, id, field)
  end

  step "a client updates the {word} {word} of {string}", %{args: [a, b, id]} = context do
    update(context, id, "#{a} #{b}")
  end

  step "a client updates the {word} {word} {word} of {string}",
       %{args: [a, b, c, id]} = context do
    update(context, id, "#{a} #{b} #{c}")
  end

  step "a client updates the {word} {word} {word} {word} of {string}",
       %{args: [a, b, c, d, id]} = context do
    update(context, id, "#{a} #{b} #{c} #{d}")
  end

  step "{string} has the new {word} and a later update time", %{args: [id, _]} = context do
    changed(context, id)
  end

  step "{string} has the new {word} {word} and a later update time",
       %{args: [id, _, _]} = context do
    changed(context, id)
  end

  step "{string} has the new {word} {word} {word} and a later update time",
       %{args: [id, _, _, _]} = context do
    changed(context, id)
  end

  step "{string} has the new {word} {word} {word} {word} and a later update time",
       %{args: [id, _, _, _, _]} = context do
    changed(context, id)
  end

  step "project {string} is titled {string}", %{args: [id, title]} = context do
    context = World.create_project(context, title, %{"projectId" => id})
    Map.merge(context, %{project_id: id, seq: seq(id)})
  end

  step "a client sets its title to {string}", %{args: [title]} = context do
    mutate(context, %{
      "type" => "project.update",
      "projectId" => context.project_id,
      "title" => title
    })
  end

  step "no change is recorded for {string}", %{args: [id]} = context do
    assert {:ok, %{"title" => _}} = context.reply
    assert seq(id) == context.seq
    context
  end

  # --- deleting ---------------------------------------------------------------------

  # "a client deletes {string}" is in threads_steps.exs, shared with threads.feature.

  step "{string} is marked deleted and no longer listed for clients", %{args: [id]} = context do
    assert {:ok, %{"deletedAt" => deleted}} = context.reply
    assert is_binary(deleted)
    assert stored(id)["deletedAt"] == deleted
    # Clients hide rows that carry `deletedAt`.
    assert %{"deletedAt" => ^deleted} = shell_row(context, id)
    context
  end

  step "a client updates project {string}", %{args: [id]} = context do
    mutate(context, %{"type" => "project.update", "projectId" => id, "title" => "Renamed"})
  end

  step "a client deletes project {string}", %{args: [id]} = context do
    mutate(context, %{"type" => "project.delete", "projectId" => id})
  end

  step "a client sends a project change of type {string}", %{args: [type]} = context do
    mutate(context, %{"type" => type, "projectId" => "p1"})
  end

  step "project {string} has threads", %{args: [id]} = context do
    context =
      context
      |> World.create_project(id)
      |> World.create_thread("first", id)
      |> World.create_thread("second", id)

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.archive",
        "threadId" => World.thread_id(context, "second"),
        "commandId" => "archive-second"
      })

    World.await_row(World.thread_id(context, "second"), &is_binary(&1["archivedAt"]))
    context
  end

  step "a client deletes {string} without force", %{args: [id]} = context do
    mutate(context, %{"type" => "project.delete", "projectId" => id})
  end

  step "it fails because the project is not empty", context do
    assert {:error, "Project p1 is not empty.", _} = context.reply
    assert stored("p1")["deletedAt"] == nil
    for title <- ["first", "second"], do: assert(thread_deleted(context, title) == nil)
    context
  end

  step "a client deletes {string} with force", %{args: [id]} = context do
    mutate(context, %{"type" => "project.delete", "projectId" => id, "force" => true})
  end

  step "its threads are deleted and then the project", context do
    assert {:ok, %{"deletedAt" => project_deleted}} = context.reply

    for title <- ["first", "second"] do
      deleted = thread_deleted(context, title)
      assert is_binary(deleted), "#{title} was not deleted"
      assert deleted <= project_deleted
    end

    context
  end

  # --- which project owns a folder --------------------------------------------------

  step "thread {string} of project {string} works in a worktree outside the project folder",
       %{args: [thread, project]} = context do
    worktree = Mc.tmp_dir(context.mc, "worktree")
    context = World.create_project(context, project)
    refute String.starts_with?(worktree, World.project(context, project).root)

    context
    |> World.create_thread(thread, project, %{
      "worktreePath" => worktree,
      "branch" => "hal-c2/#{thread}"
    })
    |> Map.put(:worktree, worktree)
  end

  step "a path inside that worktree belongs to project {string}", %{args: [project]} = context do
    assert HalC2.Projects.at(Path.join(context.worktree, "src/app.ts")) == project
    context
  end

  step "project {string} has {string} and project {string} has {string}",
       %{args: [outer, outer_folder, inner, inner_folder]} = context do
    context = home(context)

    context
    |> World.create_project(outer, %{
      "workspaceRoot" => outer_folder,
      "createWorkspaceRootIfMissing" => true
    })
    |> World.create_project(inner, %{
      "workspaceRoot" => inner_folder,
      "createWorkspaceRootIfMissing" => true
    })
  end

  step "{string} belongs to project {string}", %{args: [folder, project]} = context do
    assert HalC2.Projects.at(path(context, folder)) == project
    context
  end

  # --- imported projects ------------------------------------------------------------

  step "a project was imported from a Node server's history", context do
    root = World.git_repo(context, "imported")

    # The `project.created` payload an earlier install wrote: the id is `projectId`.
    payload = %{
      "projectId" => "imported",
      "title" => "Imported",
      "workspaceRoot" => root,
      "defaultModelSelection" => model(),
      "scripts" => [script()],
      "createdAt" => @old,
      "updatedAt" => @old
    }

    source = Path.join(Mc.tmp_dir(context.mc, "mc-log"), "state.sqlite")

    World.node_log(source, [
      {"project", "imported", "project.created", payload, 1_577_836_800_000}
    ])

    {:ok, _} = HalC2.Import.V2.run(source)

    # Imports run before an MC serves anyone.
    %{context | mc: Mc.restart(context.mc), clients: %{}}
  end

  step "a client reads it", context do
    Map.put(context, :read, shell_row(context, "imported"))
  end

  step "it has the same shape as a project created on the MC", context do
    context =
      World.create_project(context, "Native", %{
        "projectId" => "native",
        "defaultModelSelection" => model(),
        "scripts" => [script()]
      })

    native = shell_row(context, "native")
    assert context.read["id"] == "imported"
    assert Map.keys(context.read) == Map.keys(native)

    assert Map.drop(context.read, ~w(id title workspaceRoot createdAt updatedAt)) ==
             Map.drop(native, ~w(id title workspaceRoot createdAt updatedAt))

    {:ok, updated} =
      HalC2.Projects.mutate(%{
        "type" => "project.update",
        "projectId" => "imported",
        "title" => "Renamed"
      })

    assert updated["id"] == "imported"

    assert Map.keys(updated) ==
             Map.keys(
               HalC2.Projects.mutate(%{
                 "type" => "project.update",
                 "projectId" => "native",
                 "title" => "Renamed"
               })
               |> elem(1)
             )

    context
  end

  # --- shared folders ---------------------------------------------------------------

  step "a client creates or moves another project to {string}", %{args: [folder]} = context do
    context = World.create_project(context, "p2")

    {created, context} =
      World.call(context, "projects.mutate", %{
        "type" => "project.create",
        "projectId" => "p3",
        "workspaceRoot" => folder,
        "commandId" => "create-p3"
      })

    {moved, context} =
      World.call(context, "projects.mutate", %{
        "type" => "project.update",
        "projectId" => "p2",
        "workspaceRoot" => folder,
        "commandId" => "move-p2"
      })

    Map.merge(context, %{replies: [created, moved], folder: folder})
  end

  step "it fails because the folder already belongs to a project", context do
    root = path(context, context.folder)

    for reply <- context.replies do
      assert {:error, message, _} = reply
      assert message == "Workspace #{root} already belongs to project p1."
    end

    assert stored("p2")["workspaceRoot"] == World.project(context, "p2").root
    assert stored("p3") == nil
    context
  end

  # --- repository identity ----------------------------------------------------------

  step "the folder {string} is a checkout whose origin is {string}",
       %{args: [folder, url]} = context do
    context = home(context)
    File.mkdir_p!(path(context, folder))
    checkout(path(context, folder), url)
    context
  end

  step "project {string} is a checkout of {string}", %{args: [id, url]} = context do
    root = context |> World.git_repo(id) |> checkout(url)
    World.create_project(context, id, %{"projectId" => id, "workspaceRoot" => root})
  end

  step "a client moves {string} to a checkout of {string}", %{args: [id, url]} = context do
    root = context |> World.git_repo("#{id}-moved") |> checkout(url)
    mutate(context, %{"type" => "project.update", "projectId" => id, "workspaceRoot" => root})
  end

  step "project {string} was added before its checkout had the origin {string}",
       %{args: [id, url]} = context do
    context = World.create_project(context, id, %{"projectId" => id})
    assert stored(id)["repositoryIdentity"] == nil
    checkout(World.project(context, id).root, url)
    context
  end

  # What `HalC2.Hot.reload/2` does to a process whose module changed.
  step "the MC loads new code in place", context do
    :ok = :sys.suspend(HalC2.Shell)
    :ok = :sys.change_code(HalC2.Shell, HalC2.Shell, nil, :hot)
    :ok = :sys.resume(HalC2.Shell)
    context
  end

  step "project {string} is a checkout of {string} named {string} owned by {string}",
       %{args: [id, key, name, owner]} = context do
    # Filled in by a task when the shell starts or loads new code.
    World.await_row(id, &(&1["repositoryIdentity"]["canonicalKey"] == key))
    identity = shell_row(context, id)["repositoryIdentity"]

    assert %{"canonicalKey" => ^key, "name" => ^name, "owner" => ^owner} = identity
    assert identity["locator"]["remoteName"] == "origin"
    Map.put(context, :identity, identity)
  end

  step "its remote is {string}", %{args: [url]} = context do
    assert context.identity["locator"]["remoteUrl"] == url
    context
  end

  step "project {string} is not a checkout of any repository", %{args: [id]} = context do
    assert {:ok, project} = context.reply
    refute Map.has_key?(project, "repositoryIdentity")
    refute Map.has_key?(shell_row(context, id), "repositoryIdentity")
    context
  end

  defp checkout(root, url) do
    System.cmd("git", ~w(init -q), cd: root)
    {_, 0} = System.cmd("git", ["remote", "add", "origin", url], cd: root)
    root
  end

  # --- helpers ----------------------------------------------------------------------

  @updates %{
    "title" => {"title", "Renamed"},
    "default model" =>
      {"defaultModelSelection", %{"instanceId" => "claude", "model" => "claude-opus-4-6"}},
    "scripts" =>
      {"scripts",
       [
         %{
           "id" => "lint",
           "name" => "Lint",
           "command" => "npm run lint",
           "icon" => "lint",
           "runOnWorktreeCreate" => false
         }
       ]},
    "automatic pull choice" => {"autoPull", true},
    "icon" => {"projectIcon", %{"kind" => "emoji", "emoji" => "🚀"}},
    "favicon path" => {"faviconPath", "public/favicon.svg"},
    "default thread workspace mode" => {"defaultThreadEnvMode", "worktree"}
  }

  defp update(context, id, "folder") do
    root = Mc.tmp_dir(context.mc, "moved")
    do_update(context, id, "workspaceRoot", root)
  end

  defp update(context, id, field) do
    {key, value} = Map.fetch!(@updates, field)
    do_update(context, id, key, value)
  end

  defp do_update(context, id, key, value) do
    context
    |> Map.put(:change, {key, value})
    |> mutate(%{"type" => "project.update", "projectId" => id, key => value})
  end

  defp changed(context, id) do
    {key, value} = context.change
    assert {:ok, %{^key => ^value, "updatedAt" => at}} = context.reply
    assert at > @old
    assert %{^key => ^value, "updatedAt" => ^at} = stored(id)
    context
  end

  defp mutate(context, mutation) do
    mutation = Map.put_new(mutation, "commandId", "cmd-#{System.unique_integer([:positive])}")
    {reply, context} = World.call(context, "projects.mutate", mutation)
    Map.put(context, :reply, reply)
  end

  defp model, do: %{"instanceId" => "codex", "model" => "gpt-5.4"}

  defp script,
    do: %{
      "id" => "test",
      "name" => "Test",
      "command" => "npm test",
      "icon" => "test",
      "runOnWorktreeCreate" => false
    }

  # The project as stored on the MC, or nil.
  defp stored(id) do
    HalC2.StreamState.get(HalC2.StreamState.load(HalC2.Store.path(), id), "project")[id]
  end

  defp seq(id) do
    Enum.find_value(HalC2.Store.list_streams(HalC2.Store.path()), &(&1.id == id && &1.seq))
  end

  defp thread_deleted(context, title) do
    id = World.thread_id(context, title)

    HalC2.StreamState.get(HalC2.StreamState.load(HalC2.Store.path(), id), "thread")[id][
      "deletedAt"
    ]
  end

  # The project's row as a client subscribed to the shell first sees it.
  defp shell_row(context, id) do
    HalC2.Streams.flush_shell(id)
    :sys.get_state(HalC2.Shell)
    client = Mc.sub(World.client(context), 900, %{"type" => "shell"})
    {frame, client} = Mc.await(client, &(&1["t"] == "shell"))
    Mc.unsub(client, 900)
    assert [row] = for([_mc, ^id, "project", row] <- frame["rows"], do: row)
    row
  end

  # `~` is the scenario's `$HOME` (`HalC2.Test.Mc.Host`), set once for the scenario, as
  # the MC expands it.
  defp home(context), do: tap(context, &Mc.Host.home/1)

  defp path(context, "~/" <> _ = path), do: Mc.Host.path(context, path)
  defp path(_context, path), do: path
end
