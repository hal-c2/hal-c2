defmodule HalC2.Steps.Threads.MovingBetweenMachines do
  @moduledoc """
  Steps for `features/threads/moving-between-machines.feature`.

  The first machine of the Background ("laptop") is the scenario's MC in this VM;
  the others are peers running the whole MC (`HalC2.Test.Machines`). Each machine's
  "shop" is its own clone of one repository whose origin names GitHub. The thread
  file is `HalC2.ThreadArchive`'s: exports run `mix hal_c2.thread.export` here, and
  imports call `HalC2.ThreadArchive.import_file/2` (the task's body) on the machine.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.{Machines, Mc}
  alias HalC2.Test.Mc.World

  @repository "acme/shop"
  @history_start "<conversation_history>"

  # --- background ----------------------------------------------------------------------

  step "a cluster of the machines {string} and {string}", %{args: [local, other]} = context do
    Machines.cluster(context, local, [other])
  end

  step "the project {string} on each machine is a checkout of the same repository",
       %{args: [title]} = context do
    [local] = for {label, :local} <- context.machines, do: label
    context = World.create_project(context, title)
    root = World.project(context, title).root
    bare = World.github_remote(context, root, @repository)

    context =
      put_in(context, [Access.key(:checkouts, %{}), local], %{
        title => World.project(context, title)
      })

    context.machines
    |> Enum.reject(&(elem(&1, 1) == :local))
    |> Enum.reduce(Map.put(context, :bare, bare), fn {label, _}, context ->
      clone(context, label, title, "#{World.slug(title)}-#{label}")
    end)
  end

  step "the thread {string} lives on {string} in {string}",
       %{args: [title, machine, project]} = context do
    assert Machines.machine(context, machine) == :local
    World.create_thread(context, title, project)
  end

  # --- the destination's projects ------------------------------------------------------

  step "{string} instead has one project that is a checkout of the same repository",
       %{args: [machine]} = context do
    assert [_] = checkouts(context, machine)
    context
  end

  step "{string} instead has two projects that are checkouts of the same repository",
       %{args: [machine]} = context do
    clone(context, machine, "shop copy", "shop-copy-#{machine}")
  end

  step "{string} instead has no checkout of the repository", %{args: [machine]} = context do
    no_checkout(context, machine)
  end

  defp no_checkout(context, machine) do
    for %{id: id} <- checkouts(context, machine),
        do: Machines.on(context, machine, Machines, :delete_project, [id])

    root = World.git_repo(context, "scratch-#{machine}")

    Machines.on(context, machine, Machines, :create_project, [
      "scratch-#{machine}",
      "scratch",
      root
    ])

    put_in(context, [:checkouts, machine], %{"scratch" => %{id: "scratch-#{machine}", root: root}})
  end

  # --- export and import ---------------------------------------------------------------

  step "the user exports {string} on {string} to the file {string}",
       %{args: [title, machine, file]} = context do
    assert Machines.machine(context, machine) == :local
    context = furnish(context, title)
    before = World.state(context, title)
    context = export(context, title, file)
    Map.put(context, :before, before)
  end

  step "the file holds the thread with its history, attachments, terminal scrollback, checkpoints and the agent's session",
       context do
    archive = context.thread_file |> File.read!() |> JSON.decode!()
    assert archive["format"] == "hal-c2-thread-export" and archive["version"] == 2
    kinds = Enum.frequencies(for [kind, _, _] <- archive["entities"], do: kind)
    assert kinds["thread"] == 1
    assert kinds["message"] >= 3
    assert kinds["run"] >= 1
    assert [%{"fileName" => _}] = archive["attachments"]
    assert [%{"fileName" => "term-1"}] = archive["terminalLogs"]
    assert [_ | _] = archive["checkpoints"]["refs"]
    assert %{"driver" => _, "files" => [_ | _]} = archive["session"]
    context
  end

  step "{string} stays on {string} unchanged", %{args: [title, machine]} = context do
    assert Machines.machine(context, machine) == :local
    after_export = World.state(context, title)
    assert after_export.seq == context.before.seq
    assert after_export.entities == context.before.entities
    context
  end

  step "{string} has left the cluster", %{args: [machine]} = context do
    Machines.leave(context, machine)
  end

  step "the file {string} was exported from {string}", %{args: [file, machine]} = context do
    assert Machines.machine(context, machine) == :local
    context |> furnish("Alpha") |> export("Alpha", file)
  end

  step "the user imports the file on {string} into the project {string}",
       %{args: [machine, project]} = context do
    import_file(context, machine, project: project)
  end

  step "{string} is listed under {string} in {string} with everything a move carries",
       %{args: [title, machine, project]} = context do
    assert {:ok, _} = context.imported
    id = World.thread_id(context, title)
    %{id: project_id, root: root} = checkout(context, machine, project)

    assert %{"projectId" => ^project_id, "title" => ^title} = remote_row(context, machine, id)
    carried!(context, machine, id, root)
  end

  step "the user imports {string} on {string} without naming a project",
       %{args: [file, machine]} = context do
    context
    |> ensure_file(file)
    |> import_file(machine, [])
  end

  step "{string} is imported into that project", %{args: [title]} = context do
    assert {:ok, %{project: project}} = context.imported
    [%{id: ^project}] = checkouts(context, context.import_machine)
    assert remote_row(context, context.import_machine, World.thread_id(context, title))
    context
  end

  step "the import is refused and asks the user to name one", context do
    assert {:error, message} = context.imported
    assert message =~ "Several projects on #{context.import_machine}"
    assert message =~ "Name the one to import it into."
    refute_imported(context)
  end

  step "the import is refused and asks the user to name a project", context do
    assert {:error, message} = context.imported
    assert message =~ "No project on #{context.import_machine}"
    assert message =~ "Name a project to import it into."
    refute_imported(context)
  end

  step "{string} was imported on {string}", %{args: [file, machine]} = context do
    context = context |> ensure_file(file) |> import_file(machine, [])
    assert {:ok, _} = context.imported
    context
  end

  step "the user imports it on {string} again", %{args: [machine]} = context do
    import_file(context, machine, [])
  end

  step "the user is told {string} is already on {string}",
       %{args: [title, machine]} = context do
    assert context.imported == {:error, "#{title} is already on #{machine}."}
    context
  end

  step "there is still one {string}", %{args: [title]} = context do
    rows = Machines.on(context, context.import_machine, Machines, :rows, [])
    assert length(for({"thread", %{"title" => ^title}} <- rows, do: 1)) == 1
    context
  end

  step "{string} was exported by a newer HAL-C2 in a format {string} does not know",
       %{args: [file, _machine]} = context do
    context = export(context, "Alpha", file)
    archive = context.thread_file |> File.read!() |> JSON.decode!()
    File.write!(context.thread_file, JSON.encode!(%{archive | "version" => 3}))
    context
  end

  step "the user imports it on {string}", %{args: [machine]} = context do
    import_file(context, machine, [])
  end

  step "the user is told the file needs a newer HAL-C2", context do
    assert {:error, message} = context.imported
    assert message =~ "needs a newer HAL-C2"
    context
  end

  step "nothing is imported", context do
    refute_imported(context)
  end

  step "one of the attachments in {string} does not match its checksum",
       %{args: [file]} = context do
    context = context |> furnish("Alpha") |> export("Alpha", file)
    archive = context.thread_file |> File.read!() |> JSON.decode!()
    [attachment | rest] = archive["attachments"]
    damaged = %{attachment | "dataBase64" => Base.encode64("not the image")}
    File.write!(context.thread_file, JSON.encode!(%{archive | "attachments" => [damaged | rest]}))
    context
  end

  step "the user is told the file is damaged", context do
    assert {:error, message} = context.imported
    assert message =~ "The file is damaged"
    assert message =~ "Nothing was imported."
    context
  end

  step "a thread file exported by the previous server", context do
    root = World.project(context, "shop").root
    id = "th-legacy-#{System.unique_integer([:positive])}"
    at = "2026-09-01T00:00:00.000Z"
    image = "#{id}-img"

    thread =
      Map.merge(thread_fields(id, "Legacy", "shop"), %{"createdAt" => at, "updatedAt" => at})

    events = [
      v1_event(id, "thread.created", thread, at),
      v1_event(id, "run.updated", run(id, "run-legacy", at), at),
      v1_event(
        id,
        "message.updated",
        message(id, "m1", "user", "Can you fix the cart?", at, [image]),
        at
      ),
      v1_event(
        id,
        "message.updated",
        message(id, "m2", "assistant", "The cart is fixed.", at, []),
        at
      ),
      v1_event(
        id,
        "provider-thread.updated",
        %{
          "id" => "pt-legacy",
          "appThreadId" => id,
          "providerInstanceId" => "codex",
          "driver" => "codex",
          "status" => "idle",
          "nativeThreadRef" => %{
            "driver" => "codex",
            "nativeId" => "thr-mc",
            "strength" => "strong"
          },
          "firstRunOrdinal" => 1
        },
        at
      )
    ]

    archive = %{
      "format" => "hal-c2-thread-export",
      "version" => 1,
      "exportedAt" => at,
      "thread" => %{
        "id" => id,
        "title" => "Legacy",
        "sourceProjectId" => "shop",
        "sourceWorkspaceRoot" => root,
        "orchestrationVersion" => 2
      },
      "events" => events,
      "projections" => %{},
      "attachments" => [v1_file(image <> ".png", <<0x89, "PNG legacy">>)],
      "terminalLogs" => [
        v1_file("terminal_#{Base.url_encode64(id, padding: false)}.log", "$ make\nbuilt\n")
      ]
    }

    file = Path.join(Mc.tmp_dir(context.mc, "legacy"), "legacy.hal-c2-thread")
    File.write!(file, JSON.encode!(archive))

    context
    |> Map.put(:thread_file, file)
    |> put_in([:threads, "Legacy"], id)
    |> Map.put(:legacy, %{id: id, image: image})
  end

  step "the thread is listed with its history, attachments and terminal scrollback", context do
    assert {:ok, _} = context.imported
    %{id: id, image: image} = context.legacy
    machine = context.import_machine
    assert %{"title" => "Legacy"} = remote_row(context, machine, id)

    texts =
      for m <- Machines.on(context, machine, Machines, :entities, [id, "message"]), do: m["text"]

    assert Enum.sort(texts) == ["Can you fix the cart?", "The cart is fixed."]

    path = Machines.on(context, machine, HalC2.Attachments, :path, [%{"id" => image}])
    assert Machines.on(context, machine, File, :read!, [path]) == <<0x89, "PNG legacy">>

    assert Machines.on(context, machine, HalC2.Terminal, :saved_scrollback, [id]) == [
             {"term-1", "$ make\nbuilt\n"}
           ]

    context
  end

  step "its next message hands the conversation over to the agent", context do
    %{id: id} = context.legacy
    machine = context.import_machine

    for pt <- Machines.on(context, machine, Machines, :entities, [id, "provider-thread"]),
        do: assert(pt["nativeThreadRef"] == nil)

    prompt = remote_turn(context, machine, id, "Where were we?")
    assert String.starts_with?(prompt, @history_start)
    assert prompt =~ "User: Can you fix the cart?"
    assert prompt =~ "Assistant: The cart is fixed."
    context
  end

  # --- moving within the cluster ---------------------------------------------------------

  step "the user moves {string} to {string}", %{args: [title, to]} = context do
    move(context, title, to, context[:move_opts] || [])
  end

  # After an agent moved it (`hal_c2_thread_move`), only checks where it lives.
  step "{string} moves to {string}", %{args: [title, to]} = context do
    if context[:mcp_result] do
      assert {:ok, %{"status" => "moved", "machine" => ^to}} = context.mcp_result
      arrived!(context, title, to)
    else
      context = move(context, title, to, [])
      moved!(context)
      context
    end
  end

  step "the user moves {string} to {string} into the project {string}",
       %{args: [title, to, project]} = context do
    context = furnish(context, title)
    move(context, title, to, project: checkout(context, to, project).id)
  end

  step "{string} moves into that project", %{args: [title]} = context do
    %{"projectId" => project} = moved!(context)
    assert [%{id: ^project}] = checkouts(context, context.move_to)

    assert %{"projectId" => ^project} =
             remote_row(context, context.move_to, World.thread_id(context, title))

    context
  end

  step "{string} moves into {string}", %{args: [title, project]} = context do
    %{"projectId" => project_id} = moved!(context)
    assert checkout(context, context.move_to, project).id == project_id

    assert %{"projectId" => ^project_id} =
             remote_row(context, context.move_to, World.thread_id(context, title))

    context
  end

  step "{string} moves into the project at {string}", %{args: [title, path]} = context do
    %{"projectId" => project} = moved!(context)
    root = home_path(context, context.move_to, path)
    assert %{id: ^project} = Enum.find(checkouts(context, context.move_to), &(&1.root == root))

    assert %{"projectId" => ^project} =
             remote_row(context, context.move_to, World.thread_id(context, title))

    context
  end

  step "the user is asked which of the two to move {string} into", %{args: [title]} = context do
    assert {:ok, %{"status" => "choose_project", "message" => message, "projects" => projects}} =
             context.move

    assert message =~ "Choose which one to move #{title} into."

    assert Enum.sort(for p <- projects, do: p["id"]) ==
             Enum.sort(for p <- checkouts(context, context.move_to), do: p.id)

    not_moved!(context, title)
  end

  step "the user is asked to pick a project or add one on {string}",
       %{args: [machine]} = context do
    assert {:ok, %{"status" => "choose_project", "message" => message}} = context.move
    assert message =~ "Pick a project on #{machine} or add one there"
    not_moved!(context, "Alpha")
  end

  step "{string} on {string} is at {string} with the remote {string}",
       %{args: [title, machine, path, remote]} = context do
    assert Machines.machine(context, machine) == :local
    %{id: id, root: old} = World.project(context, title)
    root = home_path(context, machine, path)
    File.mkdir_p!(Path.dirname(root))
    File.rename!(old, root)
    World.git!(root, ["remote", "set-url", "origin", remote])

    {:ok, _} =
      HalC2.Projects.mutate(%{
        "type" => "project.update",
        "projectId" => id,
        "workspaceRoot" => root
      })

    World.await_row(id, &(&1["workspaceRoot"] == root))
    project = %{id: id, root: root}

    context
    |> put_in([:projects, title], project)
    |> put_in([:checkouts, machine, title], project)
  end

  step "{string} has {string} with the remote {string}",
       %{args: [machine, path, remote]} = context do
    for %{id: id} <- checkouts(context, machine),
        do: Machines.on(context, machine, Machines, :delete_project, [id])

    root = home_path(context, machine, path)
    File.mkdir_p!(Path.dirname(root))
    World.git!(Path.dirname(root), ["clone", "-q", context.bare, root])
    World.git!(root, ["remote", "set-url", "origin", remote])
    title = Path.basename(root)
    id = "#{title}-#{machine}"
    Machines.on(context, machine, Machines, :create_project, [id, title, root])
    put_in(context, [:checkouts, machine], %{title => %{id: id, root: root}})
  end

  step "{string} instead has no checkout of the repository of {string}",
       %{args: [machine, _title]} = context do
    no_checkout(context, machine)
  end

  step "the user is told checkpoints stay behind because {string} is a different repository",
       %{args: [project]} = context do
    assert Enum.any?(
             context.told,
             &(&1 =~
                 "Checkpoints of Alpha stay behind: #{project} on #{context.move_to} is a different repository")
           ),
           "not told in #{inspect(context.told)}"

    context
  end

  # --- refusals --------------------------------------------------------------------------

  step "{string} is offline", %{args: [machine]} = context do
    Machines.stop(Machines.machine(context, machine))
    Map.update(context, :offline, [machine], &[machine | &1])
  end

  # As the machine itself would report it, had it been started with that label.
  step "{string} is also called {string}", %{args: [machine, label]} = context do
    peer = Machines.mc_of(context, machine)
    {^peer, descriptor} = List.keyfind(HalC2.Shell.environments(), peer, 0)
    GenServer.cast(HalC2.Shell, {:peer_environment, peer, %{descriptor | "label" => label}})
    :sys.get_state(HalC2.Shell)
    context
  end

  step "the user is told several machines are called {string} and to name one by its environment id",
       %{args: [label]} = context do
    assert [message] = context.told
    assert message =~ "Several machines are called #{label}."

    for {_mc, %{"environmentId" => id}} <- HalC2.Shell.environments(),
        do: assert(message =~ id)

    context
  end

  step "{string} does not have the agent {string} runs on",
       %{args: [machine, title]} = context do
    context = on_claude(context, title)

    Machines.on(context, machine, Application, :put_env, [
      :hal_c2,
      :claude_command,
      ["hal-c2-no-claude"]
    ])

    context
  end

  step "the directory of the chosen project on {string} is gone", %{args: [machine]} = context do
    [%{id: id, root: root}] = checkouts(context, machine)
    File.rm_rf!(root)
    Map.put(context, :move_opts, project: id)
  end

  step "{string} has too little free disk space for {string}", %{args: [machine, _]} = context do
    # More than any disk has free: the move needs room for the thread and this reserve.
    Machines.on(context, machine, Application, :put_env, [:hal_c2, :thread_move_reserve, 10 ** 18])

    context
  end

  step "{string} stays on {string} as it was", %{args: [title, machine]} = context do
    assert Machines.machine(context, machine) == :local
    not_moved!(context, title)
    assert World.state(context, title).entities == context.before_move.entities
    context
  end

  step "nothing of {string} is left on {string}", %{args: [title, machine]} = context do
    if machine in (context[:offline] || []) do
      context
    else
      id = World.thread_id(context, title)
      refute remote_row(context, machine, id)
      streams = Machines.on(context, machine, Machines, :streams, [])
      refute id in streams
      assert Machines.on(context, machine, Machines, :incoming_moves, []) == []
      context
    end
  end

  step "{string} stays on {string} and keeps running", %{args: [title, machine]} = context do
    assert Machines.machine(context, machine) == :local
    not_moved!(context, title)
    assert Enum.any?(World.runs(context, title), &(&1["status"] == "running"))
    context
  end

  step "the agent in {string} is waiting for the user to approve a command",
       %{args: [title]} = context do
    context
    |> Map.put(:current, title)
    |> World.request_from_agent("approve run: rm -rf build")
  end

  step "the user is told to answer or stop {string} before moving it",
       %{args: [title]} = context do
    assert {:error, %{"code" => "thread_not_movable", "message" => message}} = context.move
    assert message =~ "Answer or stop #{title} before moving it."
    context
  end

  step "{string} stays on {string}", %{args: [title, machine]} = context do
    assert Machines.machine(context, machine) == :local
    not_moved!(context, title)
  end

  step "the agent {string} runs on is not signed in on {string}",
       %{args: [title, machine]} = context do
    context = on_claude(context, title)

    Machines.on(context, machine, HalC2.ProviderUsageLimits, :remember_account, [
      "claudeAgent",
      %{"status" => "unauthenticated", "message" => "Run claude login."}
    ])

    Machines.on(context, machine, :sys, :get_state, [HalC2.ProviderUsageLimits])
    context
  end

  # --- worktrees and the checkout ------------------------------------------------------

  step "{string} works in its own worktree on the branch {string}",
       %{args: [title, branch]} = context do
    context = own_worktree(context, title, branch)
    assert %{"status" => "completed"} = World.finish_turn(context, title, "write run-1.txt")
    context
  end

  step "{string} works in its own worktree on {string}", %{args: [title, machine]} = context do
    assert Machines.machine(context, machine) == :local
    context = own_worktree(context, title, "feature/#{World.slug(title)}")
    assert %{"status" => "completed"} = World.finish_turn(context, title, "write run-1.txt")
    context
  end

  step "{string} works in a new worktree of {string} on {string} on the branch {string}",
       %{args: [title, project, machine, branch]} = context do
    moved!(context)
    thread = remote_thread(context, machine, title)
    path = thread["worktreePath"]
    assert thread["branch"] == branch
    assert is_binary(path) and path != context.worktree.path
    assert World.git!(path, ~w(rev-parse --abbrev-ref HEAD)) == branch

    # A worktree of that machine's checkout: they share one repository.
    root = checkout(context, machine, project).root

    assert World.git!(path, ~w(rev-parse --path-format=absolute --git-common-dir)) ==
             World.git!(root, ~w(rev-parse --path-format=absolute --git-common-dir))

    Map.put(context, :moved_worktree, path)
  end

  step "the branch has the commits it had on {string}, including ones never pushed",
       %{args: [_machine]} = context do
    %{branch: branch, head: head} = context.worktree
    assert World.git!(context.moved_worktree, ["rev-parse", branch]) == head
    assert World.git!(context.worktree.root, ["branch", "-r", "--contains", head]) == ""
    context
  end

  step "the worktree holds the files as they were at the end of the last run of {string}",
       %{args: [_title]} = context do
    for file <- ~w(cart.txt run-1.txt),
        do:
          assert(
            File.read!(Path.join(context.moved_worktree, file)) ==
              File.read!(Path.join(context.worktree.path, file))
          )

    context
  end

  step "{string} works directly in the checkout of {string} with uncommitted changes",
       %{args: [title, project]} = context do
    assert %{"status" => "completed"} = World.finish_turn(context, title, "write run-1.txt")
    File.write!(Path.join(World.project(context, project).root, "wip.txt"), "half done\n")
    context
  end

  step "the checkout of {string} on {string} is left as it was",
       %{args: [project, machine]} = context do
    moved!(context)
    root = checkout(context, machine, project).root
    assert World.git!(root, ~w(status --porcelain)) == ""
    refute File.exists?(Path.join(root, "wip.txt"))
    context
  end

  step "the user is told the uncommitted changes stayed on {string}",
       %{args: [machine]} = context do
    told!(context, "The uncommitted changes in shop stay on #{machine}")
  end

  step "the worktree on {string} is still there with its files", %{args: [machine]} = context do
    assert Machines.machine(context, machine) == :local
    %{path: path} = context.worktree
    assert File.read!(Path.join(path, "cart.txt")) == "cart\n"
    assert File.exists?(Path.join(path, "run-1.txt"))
    assert path in World.worktrees(context.worktree.root)
    context
  end

  step "it no longer belongs to any thread", context do
    path = context.worktree.path

    for {"thread", row} <- Machines.rows(), do: refute(row["worktreePath"] == path)

    context
  end

  # --- what travels ----------------------------------------------------------------------

  step("{string} has its id and title", %{args: [_title]} = context,
    do: Map.put(context, :kept, ~w(id title))
  )

  step "{string} has its agent, model, permission and interaction modes",
       %{args: [title]} = context do
    keep(context, title, %{
      "providerInstanceId" => "codex",
      "modelSelection" => %{
        "instanceId" => "codex",
        "model" => "gpt-5.5",
        "options" => [%{"id" => "reasoningEffort", "value" => "high"}]
      },
      "runtimeMode" => "approval-required",
      "interactionMode" => "plan"
    })
  end

  step "{string} has its parent, root thread and the run it forked from",
       %{args: [title]} = context do
    keep(context, title, %{
      "lineage" => %{
        "parentThreadId" => "th-parent",
        "relationshipToParent" => "fork",
        "rootThreadId" => "th-root"
      },
      "forkedFrom" => %{"type" => "run", "threadId" => "th-parent", "runId" => "run-parent-2"}
    })
  end

  step "{string} has its pin, snooze, archive and settle state", %{args: [title]} = context do
    keep(context, title, %{
      "pinnedAt" => World.iso_from_now(-60_000),
      "snoozedAt" => World.iso_from_now(-30_000),
      "snoozedUntil" => World.iso_from_now(World.days(1)),
      "archivedAt" => World.iso_from_now(-10_000),
      "settledOverride" => "settled",
      "settledAt" => World.iso_from_now(-10_000)
    })
  end

  step "{string} has its linked pull request", %{args: [title]} = context do
    pull = %{
      "host" => "github.com",
      "repository" => @repository,
      "number" => 42,
      "url" => "https://github.com/#{@repository}/pull/42",
      "title" => "Cart",
      "state" => "open"
    }

    keep(context, title, %{"linkedPullRequest" => pull, "pullRequests" => [pull]})
  end

  step "{string} has its unread state", %{args: [title]} = context do
    keep(context, title, %{"lastVisitedAt" => World.iso_from_now(-60_000)})
  end

  step "{string} has a pending merge-back from one of its forks", %{args: [title]} = context do
    id = World.thread_id(context, title)

    transfer = %{
      "id" => "ctx-merge-back-1",
      "type" => "merge_back",
      "status" => "pending",
      "sourceThreadId" => "th-fork",
      "targetThreadId" => id,
      "createdAt" => World.iso_from_now(0),
      "updatedAt" => World.iso_from_now(0)
    }

    context
    |> World.put_entity(title, "context-transfer", transfer["id"], %{"s" => transfer})
    |> Map.put(:kept_kinds, ["context-transfer"])
  end

  step("{string} on {string} still has its id and title", %{args: [title, machine]} = context,
    do: still_has(context, title, machine)
  )

  step(
    "{string} on {string} still has its agent, model, permission and interaction modes",
    %{args: [title, machine]} = context,
    do: still_has(context, title, machine)
  )

  step(
    "{string} on {string} still has its parent, root thread and the run it forked from",
    %{args: [title, machine]} = context,
    do: still_has(context, title, machine)
  )

  step(
    "{string} on {string} still has its pin, snooze, archive and settle state",
    %{args: [title, machine]} = context,
    do: still_has(context, title, machine)
  )

  step(
    "{string} on {string} still has its linked pull request",
    %{args: [title, machine]} = context,
    do: still_has(context, title, machine)
  )

  step("{string} on {string} still has its unread state", %{args: [title, machine]} = context,
    do: still_has(context, title, machine)
  )

  step(
    "{string} on {string} still has a pending merge-back from one of its forks",
    %{args: [title, machine]} = context,
    do: still_has(context, title, machine)
  )

  step "{string} has its messages with their times and authors", %{args: [title]} = context do
    context
    |> World.add_message(title, "user", "Can you fix the cart?", World.iso_from_now(-120_000))
    |> World.add_message(title, "assistant", "The cart is fixed.", World.iso_from_now(-60_000))
    |> Map.put(:kept_kinds, ["message"])
  end

  step "{string} has its tool activity, plans and answered approvals",
       %{args: [title]} = context do
    assert %{"status" => "completed", "id" => run} =
             World.finish_turn(context, title, "write run-1.txt")

    at = World.iso_from_now(0)

    context
    |> World.add_item(title, "item-tool-1", "command_execution", run, %{
      "title" => "npm test",
      "status" => "completed"
    })
    |> World.add_item(title, "item-plan-1", "plan", run, %{
      "title" => "Plan",
      "status" => "completed"
    })
    |> World.put_entity(title, "runtime-request", "req-approve-1", %{
      "s" => %{
        "id" => "req-approve-1",
        "threadId" => World.thread_id(context, title),
        "runId" => run,
        "type" => "command_approval",
        "status" => "resolved",
        "decision" => "accept",
        "createdAt" => at,
        "resolvedAt" => at
      }
    })
    |> Map.put(:kept_kinds, ["turn-item", "runtime-request"])
  end

  step "{string} has its runs and their outcomes", %{args: [title]} = context do
    assert %{"status" => "completed"} = World.finish_turn(context, title, "write run-1.txt")

    context
    |> World.add_run(title, "failed", nil, %{"ordinal" => 2})
    |> Map.put(:kept_kinds, ["run"])
  end

  step "{string} has its attachments", %{args: [title]} = context do
    context |> furnish(title) |> Map.put(:kept_kinds, ["message"])
  end

  step "{string} has the scrollback of its terminals", %{args: [title]} = context do
    id = World.thread_id(context, title)
    HalC2.Terminal.put_scrollback(id, "term-1", "$ npm run dev\nready on :3000\n")
    HalC2.Terminal.put_scrollback(id, "term-2", "$ npm test\n3 passed\n")
    Map.put(context, :kept_kinds, [])
  end

  step(
    "{string} on {string} shows its messages with their times and authors as it was",
    %{args: [title, machine]} = context,
    do: still_shows(context, title, machine)
  )

  step(
    "{string} on {string} shows its tool activity, plans and answered approvals as it was",
    %{args: [title, machine]} = context,
    do: still_shows(context, title, machine)
  )

  step(
    "{string} on {string} shows its runs and their outcomes as it was",
    %{args: [title, machine]} = context,
    do: still_shows(context, title, machine)
  )

  step "{string} on {string} shows its attachments as it was",
       %{args: [title, machine]} = context do
    context = still_shows(context, title, machine)
    path = Machines.on(context, machine, HalC2.Attachments, :path, [%{"id" => context.image}])
    assert File.read!(path) == <<0x89, "PNG cart">>
    context
  end

  step "{string} on {string} shows the scrollback of its terminals as it was",
       %{args: [title, machine]} = context do
    id = World.thread_id(context, title)

    assert Enum.sort(Machines.on(context, machine, HalC2.Terminal, :saved_scrollback, [id])) ==
             [
               {"term-1", "$ npm run dev\nready on :3000\n"},
               {"term-2", "$ npm test\n3 passed\n"}
             ]

    context
  end

  step "{string} has an image attachment", %{args: [title]} = context do
    furnish(context, title)
  end

  step "{string} has an attachment larger than the machines send at once",
       %{args: [title]} = context do
    id = World.thread_id(context, title)
    assert %{"status" => "completed"} = World.finish_turn(context, title, "write run-1.txt")
    recording = "#{String.replace(id, ~r/[^a-z0-9_-]/i, "-")}-recording"
    # Three pieces of a move and part of a fourth, no two of them alike.
    bytes = for n <- 1..400_000, into: <<>>, do: <<n::32>>
    File.mkdir_p!(HalC2.Attachments.dir())
    File.write!(Path.join(HalC2.Attachments.dir(), recording <> ".bin"), bytes)

    context
    |> World.add_message(title, "user", "Here is the recording", nil, %{
      "attachments" => [
        %{
          "type" => "file",
          "id" => recording,
          "name" => "recording.bin",
          "mimeType" => "application/octet-stream",
          "sizeBytes" => byte_size(bytes)
        }
      ]
    })
    |> Map.merge(%{recording: recording, recording_sha256: :crypto.hash(:sha256, bytes)})
  end

  step "the partial copy on {string} holds the attachment as a file",
       %{args: [machine]} = context do
    staged = Machines.on(context, machine, Machines, :incoming_move_files, [])
    assert context.recording_sha256 in staged
    # The source's bundle of the thread's checkpoints is a file too.
    assert [_ | _] = Machines.archive_bundles()

    context
  end

  step "once the move finishes the attachment on {string} is the same as it was on {string}",
       %{args: [machine, _source]} = context do
    send(context.held.pid, :release)
    context = held_result(context)
    moved!(context)
    path = Machines.on(context, machine, HalC2.Attachments, :path, [%{"id" => context.recording}])
    assert :crypto.hash(:sha256, File.read!(path)) == context.recording_sha256
    context
  end

  step "what {string} was sent of the checkpoints leaves out the files its checkout already has",
       %{args: [machine]} = context do
    staged = Machines.on(context, machine, Machines, :incoming_move_bundles, [])
    assert [_ | _] = staged

    # Read alone, each lacks the files of the repository both machines have.
    for bundle <- staged do
      empty = Mc.tmp_dir(context.mc, "empty")
      World.git!(empty, ["init", "-q", "--bare"])
      path = Path.join(empty, "sent.bundle")
      File.write!(path, bundle)
      assert {:error, _} = HalC2.Git.ok(empty, ["fetch", path, "refs/*:refs/*"])
    end

    context
  end

  step "the copy finishes", context do
    send(context.held.pid, :release)
    held_result(context)
  end

  step "the attachment on {string} is the same as it was on {string}",
       %{args: [machine, _source]} = context do
    assert {:ok, _} = context.imported
    path = Machines.on(context, machine, HalC2.Attachments, :path, [%{"id" => context.recording}])
    assert :crypto.hash(:sha256, File.read!(path)) == context.recording_sha256
    context
  end

  step "{string} keeps none of the copies it made to read the file",
       %{args: [machine]} = context do
    assert Machines.on(context, machine, Machines, :archive_bundles, []) == []
    context
  end

  step "neither machine keeps the copies it made for the move", context do
    assert Machines.archive_bundles() == []
    assert Machines.on(context, context.move_to, Machines, :incoming_moves, []) == []
    context
  end

  step "a client opens the image in {string}", %{args: [title]} = context do
    id = World.thread_id(context, title)
    assert {:ok, where} = HalC2.ThreadMove.locate(id)
    Map.put(context, :opened_at, where)
  end

  step "{string} serves the image", %{args: [machine]} = context do
    assert context.opened_at["machine"] == machine
    assert context.opened_at["mc"] == Atom.to_string(Machines.mc_of(context, machine))
    path = Machines.on(context, machine, HalC2.Attachments, :path, [%{"id" => context.image}])
    assert File.read!(path) == <<0x89, "PNG cart">>
    context
  end

  step "{string} has checkpoints for runs {int} to {int}",
       %{args: [title, from, to]} = context do
    runs(context, title, from, to)
  end

  step "the checkpoints of runs {int} to {int} exist in the repository of {string} on {string}",
       %{args: [from, to, project, machine]} = context do
    moved!(context)
    root = checkout(context, machine, project).root
    id = World.thread_id(context, "Alpha")
    checkpoints = Machines.on(context, machine, Machines, :entities, [id, "checkpoint"])

    for n <- from..to do
      assert %{"ref" => ref} =
               Enum.find(checkpoints, &(&1["appRunOrdinal"] == n and &1["status"] == "ready"))

      assert HalC2.Checkpoint.exists?(root, ref)
    end

    context
  end

  step "the diff of each of those runs is the same as it was on {string}",
       %{args: [_machine]} = context do
    id = World.thread_id(context, "Alpha")

    for {n, diff} <- context.diffs do
      assert {:ok, ^diff} =
               Machines.on(context, context.move_to, Machines, :turn_diff, [id, n - 1, n])
    end

    context
  end

  step "{string} had runs {int} to {int} on {string} and moved to {string}",
       %{args: [title, from, to, machine, dest]} = context do
    assert Machines.machine(context, machine) == :local

    context
    |> own_worktree(title, "feature/cart")
    |> runs(title, from, to)
    |> move(title, dest, [])
    |> tap(&moved!/1)
  end

  step "the workspace of {string} on {string} is as it was after run {int}",
       %{args: [title, machine, n]} = context do
    assert {:ok, _} = context.reply
    path = remote_thread(context, machine, title)["worktreePath"]

    for m <- 1..3//1 do
      file = Path.join(path, "run-#{m}.txt")
      if m <= n, do: assert(File.exists?(file)), else: refute(File.exists?(file))
    end

    context
  end

  step "{string} moves to {string} into a project that is not the same repository",
       %{args: [title, to]} = context do
    context = no_checkout(context, to)
    context = move(context, title, to, project: checkout(context, to, "scratch").id)
    moved!(context)
    context
  end

  step "runs {int} to {int} have no diff on {string}", %{args: [from, to, machine]} = context do
    id = World.thread_id(context, "Alpha")

    for n <- from..to,
        do:
          assert(
            {:error, _} = Machines.on(context, machine, Machines, :turn_diff, [id, n - 1, n])
          )

    context
  end

  step "{string} cannot be rewound to a run from before the move", %{args: [title]} = context do
    assert elem(rewind_moved(context, title, 1).reply, 0) == :error
    context
  end

  step "the user was told this before the move began", context do
    assert Enum.any?(context[:confirmation] || [], &(&1 =~ "Checkpoints of Alpha stay behind")),
           "not asked to confirm: #{inspect(context[:confirmation])}"

    context
  end

  step "{string} has a terminal running a development server", %{args: [title]} = context do
    id = World.thread_id(context, title)
    World.open_terminal(id, World.project(context, "shop").root)
    {:ok, _} = HalC2.Terminal.attach(%{"threadId" => id, "terminalId" => "term-1"}, self())

    HalC2.Terminal.write(%{
      "threadId" => id,
      "terminalId" => "term-1",
      "data" => "echo dev server ready\n"
    })

    await_output(id, "dev server ready")
    context
  end

  step "the user is told the terminal will be closed and asked to confirm", context do
    assert Enum.any?(
             context[:confirmation] || [],
             &(&1 =~ "The terminal term-1 of Alpha is running on laptop; it will be closed.")
           ),
           "not asked to confirm: #{inspect(context[:confirmation])}"

    context
  end

  step "after the move the terminal on {string} is closed", %{args: [machine]} = context do
    assert Machines.machine(context, machine) == :local
    moved!(context)
    assert HalC2.Terminal.running(World.thread_id(context, "Alpha")) == []
    context
  end

  step "its scrollback is readable in {string} on {string}",
       %{args: [title, machine]} = context do
    id = World.thread_id(context, title)

    assert [{"term-1", text}] =
             Machines.on(context, machine, HalC2.Terminal, :saved_scrollback, [id])

    assert text =~ "dev server ready"
    context
  end

  step "{string} on {string} is a fork of {string}",
       %{args: [fork, machine, title]} = context do
    assert Machines.machine(context, machine) == :local
    assert %{"status" => "completed"} = World.finish_turn(context, title, "write run-1.txt")
    World.fork(context, title, 1, fork)
  end

  step "{string} still names {string} as its parent", %{args: [fork, title]} = context do
    assert World.thread(context, fork)["lineage"]["parentThreadId"] ==
             World.thread_id(context, title)

    context
  end

  step "opening the parent of {string} opens {string} on {string}",
       %{args: [fork, _title, machine]} = context do
    parent = World.thread(context, fork)["lineage"]["parentThreadId"]
    assert {:ok, %{"machine" => ^machine}} = HalC2.ThreadMove.locate(parent)
    context
  end

  # --- the agent continues ---------------------------------------------------------------

  step "{string} runs on an agent whose provider can carry its session",
       %{args: [title]} = context do
    assert %{"status" => "completed"} = World.finish_turn(context, title, "write run-1.txt")
    context
  end

  step "{string} runs on an agent whose provider cannot carry its session",
       %{args: [title]} = context do
    HalC2.Steps.Providers.PortableSessions.run_handed_over(context, title, "Grok")
  end

  step "a new agent session starts on {string}", %{args: [machine]} = context do
    dir = HalC2.Steps.Providers.PortableSessions.acp_dir(context, machine)

    methods =
      for line <-
            dir |> Path.join("acp-trace.jsonl") |> File.read!() |> String.split("\n", trim: true),
          %{"in" => %{"method" => method}} <- [JSON.decode!(line)],
          do: method

    assert "session/new" in methods
    refute Enum.any?(methods, &(&1 in ~w(session/load session/resume)))
    context
  end

  step "the agent receives the trimmed account of the conversation that a handoff gives",
       context do
    assert context.remote_prompt =~ @history_start
    assert context.remote_prompt =~ "write run-1.txt"
    assert context.remote_prompt =~ "Carry on"
    context
  end

  step "the user sends a message in {string}", %{args: [title]} = context do
    prompt =
      remote_turn(context, context.move_to, World.thread_id(context, title), "Carry on")

    Map.put(context, :remote_prompt, prompt)
  end

  step "the user sends the first message in {string} since the move",
       %{args: [title]} = context do
    prompt =
      remote_turn(context, context.move_to, World.thread_id(context, title), "Carry on")

    Map.put(context, :remote_prompt, prompt)
  end

  step "the agent on {string} continues its own session from {string}",
       %{args: [machine, _from]} = context do
    assert %{"sessionCarried" => true} = moved!(context)
    methods = File.read!(Path.join(Machines.home(context, machine), "codex-methods.log"))
    assert methods =~ "thread/fork"
    context
  end

  step "it receives no transcript of the earlier conversation", context do
    refute context.remote_prompt =~ @history_start
    context
  end

  step "{string} moved to {string} with its agent's session",
       %{args: [title, to]} = context do
    assert %{"status" => "completed"} = World.finish_turn(context, title, "write run-1.txt")
    context = move(context, title, to, [])
    assert %{"sessionCarried" => true} = moved!(context)
    context
  end

  step "the agent on {string} cannot open the carried session", %{args: [machine]} = context do
    # The session was written by a newer Codex than the one there, which refuses it.
    ["env" | rest] =
      Machines.on(context, machine, Application, :get_env, [:hal_c2, :codex_command])

    Machines.on(context, machine, Application, :put_env, [
      :hal_c2,
      :codex_command,
      ["env", "FAKE_CODEX_VERSION=0.1.0" | rest]
    ])

    context
  end

  step "a new agent session starts with the trimmed account of the conversation", context do
    assert context.remote_prompt =~ @history_start
    assert context.remote_prompt =~ "write run-1.txt"
    context
  end

  step "the user is told the agent could not continue its own session", context do
    id = World.thread_id(context, "Alpha")
    items = Machines.on(context, context.move_to, Machines, :entities, [id, "turn-item"])

    assert %{"failure" => %{"message" => message}} =
             Enum.find(items, &(get_in(&1, ["failure", "code"]) == "session_not_carried"))

    assert message =~ "could not continue its own session"
    context
  end

  step "{string} is at {string} on {string} and at {string} on {string}",
       %{args: [project, here, local, there, machine]} = context do
    assert Machines.machine(context, local) == :local
    %{id: id, root: old} = World.project(context, project)
    root = home_path(context, local, here)
    File.mkdir_p!(Path.dirname(root))
    File.rename!(old, root)

    {:ok, _} =
      HalC2.Projects.mutate(%{
        "type" => "project.update",
        "projectId" => id,
        "workspaceRoot" => root
      })

    World.await_row(id, &(&1["workspaceRoot"] == root))

    context =
      context
      |> put_in([:projects, project], %{id: id, root: root})
      |> put_in([:checkouts, local, project], %{id: id, root: root})

    for %{id: id} <- checkouts(context, machine),
        do: Machines.on(context, machine, Machines, :delete_project, [id])

    dest = home_path(context, machine, there)
    File.mkdir_p!(Path.dirname(dest))
    World.git!(Path.dirname(dest), ["clone", "-q", context.bare, dest])
    World.git!(dest, ["remote", "set-url", "origin", "git@github.com:#{@repository}.git"])

    Machines.on(context, machine, Machines, :create_project, [
      "#{project}-#{machine}",
      project,
      dest
    ])

    put_in(context, [:checkouts, machine], %{
      project => %{id: "#{project}-#{machine}", root: dest}
    })
  end

  step "{string} moved to {string}", %{args: [title, to]} = context do
    assert %{"status" => "completed"} = World.finish_turn(context, title, "write run-1.txt")
    context = move(context, title, to, [])
    moved!(context)
    context
  end

  step "the agent is told the project moved from {string} to {string}",
       %{args: [from, to]} = context do
    assert context.remote_prompt =~ home_path(context, "laptop", from)
    assert context.remote_prompt =~ home_path(context, context.move_to, to)
    assert context.remote_prompt =~ "This thread moved to another machine"
    context
  end

  # --- moving back -----------------------------------------------------------------------

  step "{string} went from {string} to {string} and back to {string}",
       %{args: [title, from, to, back]} = context do
    assert Machines.machine(context, from) == :local
    assert back == from
    id = World.thread_id(context, title)
    assert %{"status" => "completed"} = World.finish_turn(context, title, "write run-1.txt")
    context = move(context, title, to, [])
    moved!(context)
    remote_turn(context, to, id, "Work on desktop")

    assert {:ok, %{"status" => "moved"}} =
             Machines.on(context, to, HalC2.ThreadMove, :move, [id, back, [confirmed: true]])

    context
  end

  step "the user opens {string} on {string}", %{args: [title, machine]} = context do
    assert Machines.machine(context, machine) == :local
    thread = World.thread(context, title)
    assert thread["movedTo"] == nil and thread["moving"] == nil
    Map.put(context, :opened_runs, World.runs(context, title))
  end

  step "it shows the runs made on {string}", %{args: [_machine]} = context do
    assert [%{"status" => "completed"}, %{"status" => "completed"}] =
             Enum.sort_by(context.opened_runs, & &1["ordinal"])

    context
  end

  step "none of its runs appear twice", context do
    ids = for run <- context.opened_runs, do: run["id"]
    ordinals = for run <- context.opened_runs, do: run["ordinal"]
    assert ids == Enum.uniq(ids) and ordinals == Enum.uniq(ordinals)
    context
  end

  # --- finding a moved thread ------------------------------------------------------------

  step "{string} moved from {string} to {string}", %{args: [title, from, to]} = context do
    assert Machines.machine(context, from) == :local
    context = move(context, title, to, [])
    moved!(context)
    context
  end

  step "{string} is asleep", %{args: [machine]} = context do
    assert Machines.machine(context, machine) == :local
    Mc.stop(context.mc)
    context
  end

  step "a client asks for {string} by its id", %{args: [title]} = context do
    id = World.thread_id(context, title)
    where = Machines.on(context, context.move_to, HalC2.ThreadMove, :locate, [id])
    Map.put(context, :located, {where, remote_thread(context, context.move_to, title)})
  end

  step "it is served by {string}", %{args: [machine]} = context do
    {where, thread} = context.located
    assert {:ok, %{"machine" => ^machine}} = where
    assert %{"title" => "Alpha"} = thread
    assert thread["movedTo"] == nil
    context
  end

  step "{string} moved to {string} and was deleted there", %{args: [title, to]} = context do
    context = move(context, title, to, [])
    moved!(context)
    id = World.thread_id(context, title)
    :ok = HalC2.Shell.subscribe(self())

    {:ok, _} =
      Machines.on(context, to, HalC2.Orchestration, :dispatch, [
        %{"type" => "thread.delete", "threadId" => id}
      ])

    await_shell(fn -> match?({:error, _}, HalC2.ThreadMove.locate(id)) end, "#{id} deleted")
    context
  end

  step "the user follows an old link to {string}", %{args: [title]} = context do
    Map.put(context, :located, HalC2.ThreadMove.locate(World.thread_id(context, title)))
  end

  step "the user is told the thread was deleted", context do
    assert {:error, message} = context.located
    assert message =~ "Alpha was deleted"
    context
  end

  # --- broken-off moves ------------------------------------------------------------------

  step "{string} is being copied to {string}", %{args: [title, to]} = context do
    hold(context, title, to, to, :staged)
  end

  step "{string} goes offline before it has confirmed the thread", %{args: [machine]} = context do
    Machines.stop(Machines.machine(context, machine))
    held_result(context)
  end

  step "{string} stays on {string} and can be used again", %{args: [title, machine]} = context do
    assert Machines.machine(context, machine) == :local
    not_moved!(context, title)
    assert %{"status" => "completed"} = World.finish_turn(context, title, "write run-2.txt")
    context
  end

  step "the user is told the move did not finish and can be tried again", context do
    assert {:error, %{"message" => message}} = context.move
    assert message =~ "did not finish"
    assert message =~ "can be moved again"
    context
  end

  step "a move of {string} to {string} broke off part way", %{args: [title, to]} = context do
    context = hold(context, title, to, to, :staged)
    assert [_] = Machines.on(context, to, Machines, :incoming_moves, [])
    Machines.stop(Machines.machine(context, to))
    context = held_result(context)
    assert {:error, _} = context.move
    context
  end

  step "{string} comes back online", %{args: [machine]} = context do
    home = Machines.home(context, machine)
    put_in(context, [:machines, machine], Machines.start(context, machine, :cluster, home))
  end

  step "{string} does not list {string}", %{args: [machine, title]} = context do
    id = World.thread_id(context, title)
    refute remote_row(context, machine, id)
    refute id in Machines.on(context, machine, Machines, :streams, [])
    context
  end

  step "the space used by the partial copy is freed", context do
    assert Machines.on(context, context.move_to, Machines, :incoming_moves, []) == []
    context
  end

  step "{string} has confirmed it holds {string}", %{args: [machine, title]} = context do
    hold(context, title, machine, "laptop", :accepted)
  end

  step "{string} goes offline before it has let go of {string}",
       %{args: [machine, title]} = context do
    assert Machines.machine(context, machine) == :local
    id = World.thread_id(context, title)
    dest = Machines.mc_of(context, context.move_to)
    Task.shutdown(context.held.task, :brutal_kill)
    Application.delete_env(:hal_c2, :thread_move_hook)
    context = %{context | mc: Mc.restart(context.mc)}
    :ok = HalC2.Shell.subscribe(self())
    Mc.ensure(HalC2.ThreadMove)
    :sys.get_state(HalC2.ThreadMove)

    # Back online, it has the sidebar of the machine it moved the thread to.
    await_shell(
      fn ->
        Enum.any?(HalC2.Shell.environments(), &(elem(&1, 0) == dest)) and
          match?({"thread", _}, HalC2.Shell.row(dest, id))
      end,
      "#{title} on #{context.move_to}"
    )

    context
  end

  step "{string} lives on {string}", %{args: [title, machine]} = context do
    id = World.thread_id(context, title)
    assert {:ok, %{"machine" => ^machine}} = HalC2.ThreadMove.locate(id)
    assert %{"movedTo" => nil} = Map.put_new(remote_row(context, machine, id), "movedTo", nil)
    context
  end

  step "when {string} comes back it lists {string} only under {string}",
       %{args: [machine, title, dest]} = context do
    assert Machines.machine(context, machine) == :local
    id = World.thread_id(context, title)
    assert %{"label" => ^dest} = World.thread(context, title)["movedTo"]
    dest_mc = Machines.mc_of(context, dest)

    assert [^dest_mc] =
             for(
               {{mc, ^id}, {"thread", row}} <- HalC2.Shell.rows(),
               row["movedTo"] == nil,
               do: mc
             )

    context
  end

  step "the cluster also has the machine {string}", %{args: [machine]} = context do
    context = put_in(context, [:machines, machine], Machines.start(context, machine, :cluster))
    clone(context, machine, "shop", "shop-#{machine}")
  end

  step "{string} is moving to {string}", %{args: [title, to]} = context do
    hold(context, title, to, to, :staged)
  end

  step "another client moves {string} to {string}", %{args: [title, to]} = context do
    second = HalC2.ThreadMove.move(World.thread_id(context, title), to, confirmed: true)
    Map.put(context, :second_move, second)
  end

  step "the second move is refused because {string} is already moving",
       %{args: [title]} = context do
    assert {:error, %{"code" => "thread_not_movable", "message" => message}} =
             context.second_move

    assert message == "#{title} is already moving to #{context.move_to}."
    send(context.held.pid, :release)
    context = held_result(context)
    moved!(context)
    context
  end

  # --- agents ----------------------------------------------------------------------------

  step "the thread {string} runs in full-access mode", %{args: [title]} = context do
    calling_thread(context, title, "default")
  end

  step "{string} runs in plan mode", %{args: [title]} = context do
    calling_thread(context, title, "plan")
  end

  step "the cluster has no machine {string}", %{args: [machine]} = context do
    refute Enum.any?(HalC2.Shell.environments(), &(elem(&1, 1)["label"] == machine))
    context
  end

  step "the agent of {string} moves {string} to {string}",
       %{args: [caller, title, to]} = context do
    context =
      if (context[:threads] || %{})[caller],
        do: context,
        else: calling_thread(context, caller, "default")

    result =
      World.mcp_tool(context, caller, "hal_c2_thread_move", %{
        "threadId" => World.thread_id(context, title),
        "machine" => to
      })

    Map.merge(context, %{mcp_result: result, move_to: to})
  end

  step "the agent receives where {string} now lives and whether its session was carried",
       %{args: [title]} = context do
    id = World.thread_id(context, title)
    [%{id: project}] = checkouts(context, context.move_to)

    assert {:ok, %{"threadId" => ^id, "projectId" => ^project} = result} = context.mcp_result
    assert result["machine"] == context.move_to and is_binary(result["environmentId"])
    assert is_boolean(result["sessionCarried"])
    context
  end

  step "the agent of {string} moves its own thread to {string}",
       %{args: [caller, to]} = context do
    Mc.ensure(HalC2.ThreadMove)
    result = World.mcp_tool(context, caller, "hal_c2_thread_move", %{"machine" => to})
    Map.merge(context, %{mcp_result: result, move_to: to, mover: caller})
  end

  step "the agent is told the move will happen when its turn ends", context do
    assert {:ok, %{"status" => "scheduled", "message" => message}} = context.mcp_result
    assert message =~ "when this turn ends"
    not_moved!(context, context.mover)
    assert Enum.any?(World.runs(context, context.mover), &(&1["status"] == "running"))
    context
  end

  step "when the turn ends {string} moves to {string}", %{args: [title, to]} = context do
    # Steering a waiting turn of the fake Codex with "say ..." ends it.
    context = World.send_turn(context, title, "say done")

    World.await_state(
      context,
      title,
      fn state ->
        HalC2.StreamState.get(state, "thread")[World.thread_id(context, title)]["movedTo"] != nil
      end,
      30_000
    )

    assert Enum.all?(World.runs(context, title), &(&1["status"] == "completed"))
    arrived!(context, title, to)
  end

  step "the agent of {string} asks where {string} can move", %{args: [caller, title]} = context do
    result =
      World.mcp_tool(context, caller, "hal_c2_thread_move_destinations", %{
        "threadId" => World.thread_id(context, title)
      })

    Map.put(context, :mcp_result, result)
  end

  step "it receives each machine with whether it is online and which of its projects can take {string}",
       %{args: [title]} = context do
    id = World.thread_id(context, title)
    assert {:ok, %{"threadId" => ^id, "machines" => [desktop]}} = context.mcp_result
    [%{id: project, root: root}] = checkouts(context, "desktop")

    assert %{"machine" => "desktop", "online" => true, "environmentId" => environment} = desktop
    assert is_binary(environment)

    assert [%{"id" => ^project, "workspaceRoot" => ^root, "sameRepository" => true}] =
             desktop["projects"]

    context
  end

  # --- helpers ---------------------------------------------------------------------------

  # A thread of "shop" whose agent calls the tools: full-access, in `interaction` mode,
  # with a turn running (only a running caller may change things).
  defp calling_thread(context, title, interaction) do
    context
    |> World.create_thread(title, "shop", %{
      "runtimeMode" => "full-access",
      "interactionMode" => interaction
    })
    |> World.working_thread(title)
  end

  # The thread lives on `machine` now: the cluster finds it there, and this machine keeps
  # only a forwarding record.
  defp arrived!(context, title, machine) do
    id = World.thread_id(context, title)
    assert {:ok, %{"machine" => ^machine}} = HalC2.ThreadMove.locate(id)
    assert World.thread(context, title)["movedTo"]["label"] == machine
    assert remote_row(context, machine, id)
    context
  end

  @doc "Rewinds a moved thread on the machine it moved to (`the user rewinds ...` after a move)."
  def rewind_moved(context, title, n) do
    id = World.thread_id(context, title)
    scope = HalC2.Checkpoint.scope_id(id)

    reply =
      Machines.on(context, context.move_to, HalC2.Orchestration, :dispatch, [
        %{
          "type" => "checkpoint.rollback",
          "commandId" => "cmd-#{System.unique_integer([:positive])}",
          "threadId" => id,
          "scopeId" => scope,
          "checkpointId" => HalC2.Checkpoint.checkpoint_id(scope, n)
        }
      ])

    Map.put(context, :reply, reply)
  end

  # The thread works in a new worktree of "shop" on `branch`, with a commit that was
  # never pushed.
  def own_worktree(context, title, branch) do
    Mc.ensure(
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Vcs.Registry},
        id: HalC2.Vcs.Registry
      )
    )

    %{root: root} = World.project(context, "shop")

    {:ok, %{"worktree" => %{"path" => path}}} =
      HalC2.Vcs.create_worktree(%{"cwd" => root, "refName" => "main", "newRefName" => branch})

    head = World.commit!(path, %{"cart.txt" => "cart\n"}, "Add the cart")
    context = World.patch_thread(context, title, %{"branch" => branch, "worktreePath" => path})
    Map.put(context, :worktree, %{path: path, branch: branch, root: root, head: head})
  end

  defp remote_thread(context, machine, title) do
    id = World.thread_id(context, title)
    [thread] = Machines.on(context, machine, Machines, :entities, [id, "thread"])
    thread
  end

  defp told!(context, text) do
    assert Enum.any?(context[:told] || [], &(&1 =~ text)),
           "not told in #{inspect(context[:told])}"

    context
  end

  # Gives the thread `fields` and remembers them to compare after the move.
  defp keep(context, title, fields) do
    context
    |> World.patch_thread(title, fields)
    |> Map.put(:kept, Map.keys(fields))
  end

  # The moved thread's kept fields and entities are as they were before the move.
  defp still_has(context, title, machine) do
    moved!(context)
    id = World.thread_id(context, title)
    before = HalC2.StreamState.get(context.before_move, "thread")[id]
    thread = remote_thread(context, machine, title)
    kept = context[:kept] || []
    assert Map.take(thread, kept) == Map.take(before, kept)
    still_shows(context, title, machine)
  end

  # The moved thread's entities of the kinds kept are as they were before the move,
  # paths in them now naming the destination's project.
  defp still_shows(context, title, machine) do
    moved!(context)
    id = World.thread_id(context, title)
    from = World.project(context, "shop").root
    to = checkout(context, machine, "shop").root

    for kind <- context[:kept_kinds] || [] do
      before =
        for entity <- HalC2.StreamState.list(context.before_move, kind),
            do: entity |> JSON.encode!() |> String.replace(from, to) |> JSON.decode!()

      there = Machines.on(context, machine, Machines, :entities, [id, kind])
      assert [_ | _] = before
      assert Enum.sort_by(there, & &1["id"]) == Enum.sort_by(before, & &1["id"])
    end

    context
  end

  # Completes runs `from` to `to`, each writing `run-<n>.txt`, remembering their diffs.
  defp runs(context, title, from, to) do
    id = World.thread_id(context, title)

    diffs =
      for n <- from..to do
        assert %{"status" => "completed", "ordinal" => ^n} =
                 World.finish_turn(context, title, "write run-#{n}.txt")

        {:ok, diff} = HalC2.Checkpoint.turn_diff(World.state(context, title), id, n - 1, n, false)
        {n, diff}
      end

    Map.put(context, :diffs, diffs)
  end

  defp await_output(id, text, acc \\ "") do
    receive do
      {:hal_c2_terminal, {^id, "term-1"}, %{"type" => "output", "data" => data}} ->
        acc = acc <> data
        if acc =~ text, do: :ok, else: await_output(id, text, acc)
    after
      5_000 -> flunk("no #{inspect(text)} in the terminal: #{inspect(acc)}")
    end
  end

  # Waits until `fun` holds, re-checking as the sidebar changes (the caller has
  # subscribed to `HalC2.Shell`).
  defp await_shell(fun, what) do
    unless fun.() do
      receive do
        {:hal_c2_shell, _} -> await_shell(fun, what)
      after
        10_000 -> flunk("the sidebar never showed #{what}")
      end
    end
  end

  # Starts moving `title` to `to` and holds it at `stage` on `machine` (where the
  # `:thread_move_hook` runs): `context.held` has the move's task and the held process.
  defp hold(context, title, to, machine, stage) do
    id = World.thread_id(context, title)
    hook = {Machines, :hold_move, [self(), stage]}
    Machines.on(context, machine, Application, :put_env, [:hal_c2, :thread_move_hook, hook])

    if Machines.machine(context, machine) == :local,
      do: ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :thread_move_hook) end)

    context = Map.put_new_lazy(context, :before_move, fn -> World.state(context, title) end)
    task = Task.async(fn -> HalC2.ThreadMove.move(id, to, confirmed: true) end)
    assert_receive {:move_held, pid, ^stage, ^id}, 30_000
    Map.merge(context, %{held: %{task: task, pid: pid}, move_to: to})
  end

  defp held_result(context) do
    result = Task.await(context.held.task, 60_000)

    told =
      case result do
        {:ok, %{"message" => message}} -> [message]
        {:error, %{"message" => message}} -> [message]
      end

    Map.merge(context, %{move: result, told: told})
  end

  # Moves a thread as the user does: a move that asks to confirm is confirmed, and what
  # the user was told (`context.told`) includes what they confirmed.
  defp move(context, title, to, opts) do
    id = World.thread_id(context, title)
    context = Map.put_new_lazy(context, :before_move, fn -> World.state(context, title) end)
    result = move_where_it_lives(id, to, opts)
    context = Map.merge(context, %{move: result, move_to: to})

    case result do
      {:ok, %{"status" => "confirm", "notes" => notes}} ->
        context
        |> Map.put(:confirmation, notes)
        |> move(title, to, Keyword.put(opts, :confirmed, true))

      {:ok, %{"message" => message} = result} ->
        Map.put(
          context,
          :told,
          (context[:confirmation] || []) ++ [message | result["notes"] || []]
        )

      {:error, %{"message" => message}} ->
        Map.put(context, :told, [message])
    end
  end

  # A thread that moved on is moved again by the machine that holds it now.
  defp move_where_it_lives(id, to, opts) do
    here = Atom.to_string(node())

    case HalC2.ThreadMove.locate(id) do
      {:ok, %{"mc" => mc}} when mc != here ->
        :erpc.call(String.to_atom(mc), HalC2.ThreadMove, :move, [id, to, opts], 60_000)

      _ ->
        HalC2.ThreadMove.move(id, to, opts)
    end
  end

  defp moved!(%{move: {:ok, %{"status" => "moved"} = result}}), do: result

  defp moved!(context) when is_map_key(context, :move),
    do: flunk("not moved: #{inspect(context.move)}")

  # The thread is still the source's own: not moving, not moved.
  defp not_moved!(context, title) do
    thread = World.thread(context, title)
    assert thread["moving"] == nil and thread["movedTo"] == nil
    context
  end

  defp on_claude(context, title) do
    World.patch_thread(context, title, %{
      "modelSelection" => %{"instanceId" => "claudeAgent", "model" => "claude-sonnet-4-6"}
    })
  end

  # "~/..." on a machine: under its user home.
  defp home_path(context, machine, "~/" <> rest),
    do: Path.join(Machines.user_home(context, machine), rest)

  # A clone of the scenario's repository on `machine`, added there as a project.
  defp clone(context, machine, title, id) do
    root = Path.join(Mc.tmp_dir(context.mc, "#{machine}-checkouts"), World.slug(title))
    World.git!(Path.dirname(root), ["clone", "-q", context.bare, root])
    World.git!(root, ["remote", "set-url", "origin", "git@github.com:#{@repository}.git"])
    Machines.on(context, machine, Machines, :create_project, [id, title, root])

    put_in(context, [Access.key(:checkouts, %{}), Access.key(machine, %{}), title], %{
      id: id,
      root: root
    })
  end

  defp checkouts(context, machine),
    do: context.checkouts |> Map.get(machine, %{}) |> Map.values()

  defp checkout(context, machine, title),
    do: get_in(context, [:checkouts, machine, title]) || flunk("no #{title} on #{machine}")

  # Gives a thread what a move carries: a finished run with its checkpoint, a message
  # with an image, and a terminal's scrollback.
  defp furnish(%{furnished: true} = context, _title), do: context

  defp furnish(context, title) do
    id = World.thread_id(context, title)
    assert %{"status" => "completed"} = World.finish_turn(context, title, "write run-1.txt")

    image = "#{id |> String.replace(~r/[^a-z0-9_-]/i, "-")}-cart"
    File.mkdir_p!(HalC2.Attachments.dir())
    File.write!(Path.join(HalC2.Attachments.dir(), image <> ".png"), <<0x89, "PNG cart">>)

    context =
      World.add_message(context, title, "user", "Here is the cart", nil, %{
        "attachments" => [
          %{
            "type" => "image",
            "id" => image,
            "name" => "cart.png",
            "mimeType" => "image/png",
            "sizeBytes" => 12
          }
        ]
      })

    HalC2.Terminal.put_scrollback(id, "term-1", "$ npm run dev\nready on :3000\n")
    Map.merge(context, %{furnished: true, image: image})
  end

  defp export(context, title, file) do
    path = Path.join(Mc.tmp_dir(context.mc, "exports"), file)
    assert [line] = Mc.run_task(Mix.Tasks.HalC2.Thread.Export, [title, path])
    assert line =~ "Exported #{title} to #{path}"
    Map.put(context, :thread_file, path)
  end

  defp ensure_file(%{thread_file: _} = context, _name), do: context
  defp ensure_file(context, name), do: context |> furnish("Alpha") |> export("Alpha", name)

  defp import_file(context, machine, opts) do
    result =
      Machines.on(context, machine, HalC2.ThreadArchive, :import_file, [context.thread_file, opts])

    Map.merge(context, %{imported: result, import_machine: machine})
  end

  defp refute_imported(context) do
    machine = context.import_machine
    id = (context[:legacy] || %{})[:id] || World.thread_id(context, "Alpha")
    rows = Machines.on(context, machine, Machines, :rows, [])
    refute Enum.any?(rows, fn {_, row} -> row["id"] == id end)

    streams =
      Machines.on(context, machine, HalC2.Store, :list_streams, [
        Machines.on(context, machine, HalC2.Store, :path, [])
      ])

    refute Enum.any?(streams, &(&1.id == id))
    assert Machines.on(context, machine, HalC2.Terminal, :saved_scrollback, [id]) == []

    if image = context[:image],
      do:
        assert(Machines.on(context, machine, HalC2.Attachments, :path, [%{"id" => image}]) == nil)

    context
  end

  defp remote_row(context, machine, id) do
    Machines.on(context, machine, Machines, :rows, [])
    |> Enum.find_value(fn
      {"thread", %{"id" => ^id} = row} -> row
      _ -> nil
    end)
  end

  # What a move carries arrived on `machine`: history, attachments, scrollback and
  # checkpoints in its checkout at `root`.
  defp carried!(context, machine, id, root) do
    here = World.state(context, "Alpha")
    messages = for m <- HalC2.StreamState.list(here, "message"), do: {m["id"], m["text"]}

    there =
      for m <- Machines.on(context, machine, Machines, :entities, [id, "message"]),
          do: {m["id"], m["text"]}

    assert Enum.sort(there) == Enum.sort(messages)

    runs = for r <- HalC2.StreamState.list(here, "run"), do: {r["id"], r["status"]}

    there_runs =
      for r <- Machines.on(context, machine, Machines, :entities, [id, "run"]),
          do: {r["id"], r["status"]}

    assert Enum.sort(there_runs) == Enum.sort(runs)

    path = Machines.on(context, machine, HalC2.Attachments, :path, [%{"id" => context.image}])
    assert Machines.on(context, machine, File, :read!, [path]) == <<0x89, "PNG cart">>

    assert Machines.on(context, machine, HalC2.Terminal, :saved_scrollback, [id]) ==
             HalC2.Terminal.saved_scrollback(id)

    checkpoints = Machines.on(context, machine, Machines, :entities, [id, "checkpoint"])
    assert [_ | _] = ready = Enum.filter(checkpoints, &(&1["status"] == "ready"))
    for c <- ready, do: assert(HalC2.Checkpoint.exists?(root, c["ref"]))

    # The agent's session: a copy placed on the machine, which the next run branches from.
    pts = Machines.on(context, machine, Machines, :entities, [id, "provider-thread"])
    assert [%{"path" => copy}] = for(%{"carriedSession" => s} <- pts, do: s)
    assert Machines.on(context, machine, File, :exists?, [copy])
    context
  end

  # Sends a message to a thread on a cluster member and returns what its agent was given.
  # Sends `text` on `machine` with the thread's agent (Codex unless it runs on Claude or
  # a fake ACP agent) and returns the prompt that agent was given.
  defp remote_turn(context, machine, id, text) do
    mc = Machines.mc_of(context, machine)

    {selection, inputs} =
      case context[:handoff] do
        %{selection: selection} ->
          dir = HalC2.Steps.Providers.PortableSessions.acp_dir(context, machine)
          {selection, Path.join(dir, "acp-inputs.jsonl")}

        nil when context.session.driver == "claudeAgent" ->
          {%{"instanceId" => "claudeAgent", "model" => "claude-sonnet-4-6"},
           Path.join(Machines.home(context, machine), "claude-inputs.jsonl")}

        nil ->
          {%{"instanceId" => "codex", "model" => "gpt-5.4"},
           Path.join(Machines.home(context, machine), "codex-inputs.jsonl")}
      end

    :ok = :erpc.call(mc, HalC2.Streams, :subscribe, [id, self(), nil])
    finished = length(finished_runs(context, machine, id))

    {:ok, _} =
      :erpc.call(mc, HalC2.Orchestration, :dispatch, [
        %{
          "type" => "message.dispatch",
          "commandId" => "cmd-#{System.unique_integer([:positive])}",
          "threadId" => id,
          "messageId" => "msg-#{System.unique_integer([:positive])}",
          "text" => text,
          "attachments" => [],
          "modelSelection" => selection,
          "dispatchMode" => %{"type" => "start_immediately"},
          "createdBy" => "user",
          "creationSource" => "web"
        }
      ])

    await_remote_run(context, machine, id, finished)
    [input | _] = inputs |> File.read!() |> String.split("\n", trim: true) |> Enum.reverse()

    case JSON.decode!(input) do
      text when is_binary(text) -> text
      parts -> Enum.map_join(parts, "\n", &(&1["text"] || ""))
    end
  end

  defp finished_runs(context, machine, id) do
    for run <- Machines.on(context, machine, Machines, :entities, [id, "run"]),
        run["status"] in ~w(completed failed interrupted),
        do: run
  end

  # Waits until the thread has more than `finished` finished runs.
  defp await_remote_run(context, machine, id, finished) do
    receive do
      {:hal_c2_stream, ^id, _} ->
        if length(finished_runs(context, machine, id)) > finished,
          do: :ok,
          else: await_remote_run(context, machine, id, finished)
    after
      15_000 -> flunk("the run in #{id} on #{machine} never finished")
    end
  end

  defp thread_fields(id, title, project) do
    %{
      "id" => id,
      "projectId" => project,
      "title" => title,
      "providerInstanceId" => "codex",
      "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
      "runtimeMode" => "full-access",
      "interactionMode" => "default",
      "branch" => nil,
      "worktreePath" => nil
    }
  end

  defp run(thread, id, at) do
    %{
      "id" => id,
      "threadId" => thread,
      "ordinal" => 1,
      "providerInstanceId" => "codex",
      "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
      "providerThreadId" => "pt-legacy",
      "userMessageId" => "m1",
      "status" => "completed",
      "requestedAt" => at,
      "startedAt" => at,
      "completedAt" => at
    }
  end

  defp message(thread, id, role, text, at, images) do
    %{
      "id" => id,
      "threadId" => thread,
      "runId" => "run-legacy",
      "role" => role,
      "text" => text,
      "createdBy" => if(role == "user", do: "user", else: "agent"),
      "attachments" =>
        for(
          image <- images,
          do: %{"type" => "image", "id" => image, "name" => "cart.png", "mimeType" => "image/png"}
        ),
      "streaming" => false,
      "createdAt" => at,
      "updatedAt" => at
    }
  end

  defp v1_event(stream, type, payload, at) do
    %{
      "eventId" => "ev-#{System.unique_integer([:positive])}",
      "aggregateKind" => "thread",
      "streamId" => stream,
      "streamVersion" => 0,
      "eventType" => type,
      "occurredAt" => at,
      "commandId" => nil,
      "causationEventId" => nil,
      "correlationId" => nil,
      "actorKind" => "server",
      "payloadJson" => JSON.encode!(payload),
      "metadataJson" => "{}",
      "applicationEventVersion" => 2
    }
  end

  defp v1_file(name, data),
    do: %{
      "fileName" => name,
      "sha256" => :crypto.hash(:sha256, data) |> Base.encode16(case: :lower),
      "dataBase64" => Base.encode64(data)
    }
end
