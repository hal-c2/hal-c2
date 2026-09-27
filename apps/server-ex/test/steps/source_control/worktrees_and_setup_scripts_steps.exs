defmodule HalC2.Steps.SourceControl.WorktreesAndSetupScripts do
  @moduledoc """
  Steps for `features/source-control/worktrees-and-setup-scripts.feature`: new
  threads prepared in their own worktree (`HalC2.WorktreeSetup`, launched with
  `World.launch_in_worktree/4`), worktrees made and removed over `vcs.*`, and the
  agent's worktree tools (`HalC2.Mcp`). Setup progress arrives as snapshots, kept in
  order under `context.setup_snapshots`; the agent is the fake Codex app server.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.SourceControl.Shared
  alias HalC2.Test.Node
  alias HalC2.Test.Node.World

  @stages %{
    "Fetch base branch" => "fetch",
    "Check out files" => "checkout",
    "Init submodules" => "submodules",
    "Run setup script" => "setup-script",
    "Start agent" => "agent"
  }

  step "a connected environment with the git project {string} whose default branch is {string}",
       %{args: [title, branch]} = context do
    context = World.create_project(context, title)
    assert World.git!(World.project(context, title).root, ~w(branch --show-current)) == branch
    World.put_client(context, World.client(context))
  end

  # --- making worktrees ------------------------------------------------------------

  step "a worktree is created for the branch {string} with no path given",
       %{args: [branch]} = context do
    create_worktree(context, branch)
  end

  step "it is made in the HAL-C2 home's worktrees folder under the repository and branch names",
       context do
    %{path: path, root: root, branch: branch} = context.worktree
    name = String.replace(branch, "/", "-")
    assert path == Path.join([context.node.home, "worktrees", Path.basename(root), name])
    assert File.dir?(path)
    assert path in World.worktrees(root)
    assert World.git!(path, ~w(branch --show-current)) == branch
    context
  end

  step ~r/^"(?<project>[^"]+)" has nested submodules and the worktree submodules setting is (?<setting>recursive|top level only|skip)$/,
       %{args: [title, setting]} = context do
    context = with_submodules(context, title, nested: true)
    mode = %{"recursive" => "recursive", "top level only" => "top-level", "skip" => "none"}

    World.put_settings(context, %{
      "projectSettingsOverrides" => %{
        World.project(context, title).id => %{"worktreeSubmodules" => mode[setting]}
      }
    })
  end

  step "a worktree is created", context do
    create_worktree(context, "feature/modules")
  end

  step "every submodule is initialized, nested ones included", context do
    path = context.worktree.path
    assert File.exists?(Path.join(path, "tools/README.md"))
    assert File.exists?(Path.join(path, "tools/vendor/README.md"))
    context
  end

  step "only the top level submodules are initialized", context do
    path = context.worktree.path
    assert File.exists?(Path.join(path, "tools/README.md"))
    refute File.exists?(Path.join(path, "tools/vendor/README.md"))
    context
  end

  step "no submodule is initialized", context do
    path = context.worktree.path
    assert File.exists?(Path.join(path, ".gitmodules"))
    refute File.exists?(Path.join(path, "tools/README.md"))
    context
  end

  # --- launching into a new worktree -------------------------------------------------

  step "the project starts worktrees from origin and {string} has the remote {string}",
       %{args: [title, remote]} = context do
    root = World.project(context, title).root
    origin = World.git_remote(context, root, remote)

    # Origin moves ahead of the local branch, so the worktree shows which one it
    # started from.
    other = Path.join(Node.tmp_dir(context.node, "other"), "shop")
    World.git!(Path.dirname(other), ["clone", "-q", origin, other])

    World.git!(
      other,
      ~w(-c user.email=hal-c2@example.com -c user.name=HAL-C2 commit -q --allow-empty -m ahead)
    )

    World.git!(other, ~w(push -q origin main))

    context
    |> World.put_settings(%{
      "projectSettingsOverrides" => %{
        World.project(context, title).id => %{"newWorktreesStartFromOrigin" => true}
      }
    })
    |> Map.put(:origin_head, World.git!(other, ~w(rev-parse HEAD)))
  end

  step "{string} has no remote", %{args: [title]} = context do
    assert World.git!(World.project(context, title).root, ["remote"]) == ""
    context
  end

  step "the user sends the first message of a thread in a new worktree", context do
    launch(context, "list the files")
  end

  step "the user sends {string} as the first message of a thread in a new worktree",
       %{args: [text]} = context do
    context |> Shared.answering_writer() |> launch(text) |> Map.put(:first_message, text)
  end

  step "the fetch stage runs before the files are checked out", context do
    {checkout, context} =
      World.await_setup(context, &(World.setup_stage(&1, "checkout") != "pending"))

    assert World.setup_stage(checkout, "fetch") == "done"
    assert Enum.any?(context.setup_snapshots, &(World.setup_stage(&1, "fetch") == "running"))

    {done, context} = World.await_setup(context, &(&1["phase"] != "running"))
    assert done["phase"] == "done"
    assert World.git!(done["worktreePath"], ~w(rev-parse HEAD)) == context.origin_head
    context
  end

  step "the fetch stage is reported as skipped", context do
    {snapshot, context} = World.await_setup(context, &(&1["phase"] != "running"))
    assert World.setup_stage(snapshot, "fetch") == "skipped"
    assert snapshot["phase"] == "done"
    context
  end

  step "the worktree first sits on a temporary branch", context do
    {snapshot, context} = World.await_setup(context, & &1["worktreePath"])
    assert snapshot["branch"] =~ ~r/^hal-c2\/[0-9a-f]{8}$/
    Map.put(context, :worktree, %{path: snapshot["worktreePath"], branch: snapshot["branch"]})
  end

  step "the client names the new worktree's temporary branch {string}",
       %{args: [branch]} = context do
    Map.update(context, :strategy, %{"branch" => branch}, &Map.put(&1, "branch", branch))
  end

  step "the worktree first sits on the temporary branch {string}", %{args: [branch]} = context do
    {snapshot, context} = World.await_setup(context, & &1["worktreePath"])
    assert snapshot["branch"] == branch
    Map.put(context, :worktree, %{path: snapshot["worktreePath"], branch: branch})
  end

  step "{string} has a branch named {string}", %{args: [title, branch]} = context do
    World.git!(World.project(context, title).root, ["branch", branch])
    context
  end

  # Branches are files under refs/heads, so none can be made under a branch's own name.
  step "the worktree is made on a temporary branch beside {string}", %{args: [taken]} = context do
    {snapshot, context} = World.await_setup(context, &(&1["phase"] != "running"))
    assert snapshot["phase"] == "done", inspect(snapshot)
    assert snapshot["branch"] =~ ~r/^hal-c2-[0-9a-f]{8}$/
    assert World.git!(snapshot["worktreePath"], ~w(branch --show-current)) == snapshot["branch"]
    assert World.git!(World.project(context).root, ["rev-parse", "--verify", taken]) != ""
    context
  end

  step "the branch is renamed to a name the writer model derives from the message", context do
    %{path: path, branch: temporary} = context.worktree
    thread = await_thread(context.setup_thread, &(&1["branch"] not in [nil, temporary]))

    # The fake writer answers "claude branch" to the prompt carrying the message.
    assert thread["branch"] =~ "claude-branch"
    assert World.git!(path, ~w(branch --show-current)) == thread["branch"]
    assert Enum.any?(Shared.writer_prompts(context), &String.contains?(&1, context.first_message))
    context
  end

  step "the setup reports the stage {string} with its status", %{args: [label]} = context do
    id = Map.fetch!(@stages, label)
    {snapshot, context} = World.await_setup(context, &(&1["phase"] != "running"))
    assert snapshot["phase"] == "done"
    stage = Enum.find(snapshot["stages"], &(&1["id"] == id))
    assert stage, "the setup has no #{id} stage: #{inspect(snapshot["stages"])}"
    assert stage["status"] in ~w(done skipped)
    assert stage["endedAt"]
    context
  end

  step "{string} has submodules", %{args: [title]} = context do
    with_submodules(context, title, nested: false)
  end

  # --- setup scripts ------------------------------------------------------------------

  step "{string} has a setup script set to run when a worktree is created",
       %{args: [title]} = context do
    log = Path.join(Node.tmp_dir(context.node, "setup"), "cwd")
    context |> put_setup(title, "pwd > '#{log}'", false) |> Map.put(:setup_log, log)
  end

  step "the script runs in the thread's {string} terminal inside the new worktree",
       %{args: [terminal]} = context do
    {snapshot, context} = World.await_setup(context, &(&1["phase"] != "running"))
    assert %{"phase" => "done", "worktreePath" => path} = snapshot
    assert %{"terminalId" => ^terminal} = snapshot["setupScript"]
    assert World.setup_stage(snapshot, "setup-script") == "done"
    assert [_] = Registry.lookup(HalC2.Terminal.Registry, {context.setup_thread, terminal})
    assert String.trim(File.read!(context.setup_log)) == path
    context
  end

  step "{string} has a setup script that prints many lines", %{args: [title]} = context do
    put_setup(context, title, "for i in $(seq 1 12); do echo line $i; done; read _", false)
  end

  step "the setup script stage shows the last 5 lines of its output as it runs", context do
    tail = for i <- 8..12, do: "line #{i}"

    {snapshot, context} =
      World.await_setup(context, fn snapshot ->
        stage = Enum.find(snapshot["stages"], &(&1["id"] == "setup-script"))
        stage["status"] == "running" and Enum.map(stage["tail"], &String.trim/1) == tail
      end)

    assert snapshot["phase"] == "running"

    # The script waits for a line; give it one and it finishes.
    type(context, "\r")
    {done, context} = World.await_setup(context, &(&1["phase"] != "running"))
    assert done["phase"] == "done"
    context
  end

  step "the setup script must finish before the agent starts and it exits with {int}",
       %{args: [code]} = context do
    put_setup(context, nil, "(exit #{code})", false)
  end

  step "the setup script runs in the background and it exits with {int}",
       %{args: [code]} = context do
    context |> put_setup(nil, "(exit #{code})", true) |> Map.put(:script_exit, code)
  end

  step "the setup script stage is reported as failed", context do
    {snapshot, context} =
      World.await_setup(context, &(World.setup_stage(&1, "setup-script") == "failed"))

    stage = Enum.find(snapshot["stages"], &(&1["id"] == "setup-script"))
    assert stage["detail"] == "exited with #{context.script_exit}"
    context
  end

  step "the agent still starts", context do
    {snapshot, context} = World.await_setup(context, &(&1["phase"] != "running"))
    assert %{"phase" => "done", "error" => nil} = snapshot
    assert World.setup_stage(snapshot, "agent") == "done"
    assert %{"status" => "completed"} = await_run(context.setup_thread, "completed")
    context
  end

  # --- failures and cancelling ---------------------------------------------------------

  step "the branch cannot be checked out into a new worktree", context do
    # The branch the thread asks for exists already, so `git worktree add -b` refuses.
    World.git!(World.project(context).root, ~w(branch feature/tax))
    Map.put(context, :strategy, %{"branch" => "feature/tax"})
  end

  step "a thread's worktree setup is still checking out files", context do
    # A post-checkout hook holds `git worktree add` open; it reports its pid and
    # folder through a pipe once the files are on disk.
    root = World.project(context).root
    pipe = Path.join(Node.tmp_dir(context.node, "hook"), "checkout")
    {_, 0} = System.cmd("mkfifo", [pipe])
    hook = Path.join(root, ".git/hooks/post-checkout")
    File.write!(hook, "#!/bin/sh\necho \"$$ $(pwd)\" > '#{pipe}'\nexec sleep 600\n")
    File.chmod!(hook, 0o755)

    reader = Task.async(fn -> System.cmd("cat", [pipe]) end)
    context = launch(context, "list the files")
    {out, 0} = Task.await(reader, 15_000)
    [pid, path] = String.split(String.trim(out), " ", parts: 2)
    ExUnit.Callbacks.on_exit(fn -> System.cmd("kill", [pid], stderr_to_stdout: true) end)

    {snapshot, context} =
      World.await_setup(context, &(World.setup_stage(&1, "checkout") == "running"))

    assert snapshot["phase"] == "running"
    assert File.dir?(path)
    Map.put(context, :worktree, %{path: path, root: root})
  end

  step "the thread no longer points at a worktree", context do
    thread = await_thread(context.setup_thread, & &1)
    assert thread["worktreePath"] == nil
    context
  end

  step "the setup is reported as cancelled", context do
    assert context.setup_cancelled == true
    {snapshot, context} = World.await_setup(context, &(&1["phase"] != "running"))
    assert snapshot["phase"] == "cancelled"
    assert %{"status" => "cancelled"} = await_run(context.setup_thread, "cancelled")
    context
  end

  step "a thread's worktree setup has reached the agent stage", context do
    context = launch(context, "list the files")

    {snapshot, context} =
      World.await_setup(context, &(World.setup_stage(&1, "agent") != "pending"))

    Map.put(context, :worktree, %{
      path: snapshot["worktreePath"],
      root: World.project(context).root
    })
  end

  step "the worktree stays", context do
    %{path: path, root: root} = context.worktree
    assert File.dir?(path)
    assert path in World.worktrees(root)
    context
  end

  step "a thread's worktree is ready and its setup script finished", context do
    # The script has done its work and waits for a line before it exits.
    context = context |> put_setup(nil, "echo ready; read _", false) |> launch("list the files")

    {_, context} =
      World.await_setup(context, fn snapshot ->
        stage = Enum.find(snapshot["stages"], &(&1["id"] == "setup-script"))
        Enum.any?(stage["tail"], &(String.trim(&1) == "ready"))
      end)

    context
  end

  step "the thread's run cannot be released to the agent", context do
    # The run stops waiting for its workspace (it ended elsewhere) before the
    # setup hands it over.
    run = await_run(context.setup_thread, "preparing")
    HalC2.Orchestration.fail_prepared(context.setup_thread, run["id"], "cancelled")
    assert %{"status" => "cancelled"} = await_run(context.setup_thread, "cancelled")
    context
  end

  step "the setup reaches the agent stage", context do
    type(context, "\r")
    {_, context} = World.await_setup(context, &(World.setup_stage(&1, "agent") != "pending"))
    context
  end

  # --- reconnecting and restarting -------------------------------------------------------

  step "a thread's worktree setup is running the setup script", context do
    context =
      context |> put_setup(nil, "echo one; echo two; read _", false) |> launch("list the files")

    {_, context} =
      World.await_setup(context, fn snapshot ->
        stage = Enum.find(snapshot["stages"], &(&1["id"] == "setup-script"))
        Enum.any?(stage["tail"], &(String.trim(&1) == "two"))
      end)

    watch_setup(context)
  end

  step "the user's client drops and reconnects", context do
    conn = World.client(context).conn
    socket = Mint.HTTP.get_socket(conn)
    Mint.HTTP.close(conn)
    # What the old socket had already received is gone with it.
    flush_socket(socket)
    context = World.put_client(context, Node.connect(context.node))
    watch_setup(context)
  end

  step "it receives the setup's current stages, not a replay", context do
    current = HalC2.WorktreeSetup.subscribe(context.setup_thread, self())
    assert context.watched == current
    assert current["sequence"] > 1
    assert World.setup_stage(current, "checkout") == "done"
    assert World.setup_stage(current, "setup-script") == "running"
    context
  end

  step "a thread's worktree setup finished", context do
    context = launch(context, "list the files")
    {snapshot, context} = World.await_setup(context, &(&1["phase"] != "running"))
    assert snapshot["phase"] == "done"
    await_run(context.setup_thread, "completed")
    context
  end

  step "no setup progress is shown for that thread", context do
    assert HalC2.WorktreeSetup.subscribe(context.setup_thread, self()) == nil
    context = World.put_client(context, World.client(context))
    context = watch_setup(context)
    assert context.watched == nil
    context
  end

  # --- removing worktrees ------------------------------------------------------------------

  step "{string} has a worktree with no changes", %{args: [branch]} = context do
    add_worktree(context, branch)
  end

  step "the folder of the {string} worktree was deleted by hand", %{args: [branch]} = context do
    context = add_worktree(context, branch)
    File.rm_rf!(context.worktree.path)
    context
  end

  step "the {string} worktree has uncommitted changes", %{args: [branch]} = context do
    context = add_worktree(context, branch)
    File.write!(Path.join(context.worktree.path, "README.md"), "changed\n")
    assert World.git!(context.worktree.path, ~w(status --porcelain)) != ""
    context
  end

  step "the user removes that worktree", context do
    remove_worktree(context, false)
  end

  step "the user removes that worktree with force", context do
    remove_worktree(context, true)
  end

  step "its folder is gone and git no longer lists it", context do
    assert {:ok, _} = context.reply
    refute File.exists?(context.worktree.path)
    refute context.worktree.path in World.worktrees(context.worktree.root)
    context
  end

  step "git forgets it without an error", context do
    assert {:ok, _} = context.reply
    refute context.worktree.path in World.worktrees(context.worktree.root)
    context
  end

  step "its folder is gone", context do
    assert {:ok, _} = context.reply
    refute File.exists?(context.worktree.path)
    context
  end

  # --- the agent's worktree tools -------------------------------------------------------------

  step "the agent works in {string} without a worktree", %{args: [title]} = context do
    World.worktree_services()
    log = Path.join(Node.tmp_dir(context.node, "setup"), "cwd")

    context
    |> put_setup(title, "pwd > '#{log}'; echo setup-$((6*7))", false)
    |> World.create_thread("Work", title)
    |> Map.put(:setup_log, log)
  end

  step "the agent hands the thread off to a new worktree on {string} with a continuation prompt",
       %{args: [branch]} = context do
    # The project has no origin, so the agent branches from the local base.
    prompt = "write continued.txt"

    handoff(context, %{
      "branch" => branch,
      "continuationPrompt" => prompt,
      "startFromOrigin" => false
    })
    |> Map.merge(%{handoff_branch: branch, continuation: prompt})
  end

  step "the worktree is created and the thread points at it", context do
    assert {:ok, %{"worktreePath" => path, "branch" => branch}} = context.handoff
    assert branch == context.handoff_branch
    assert path in World.worktrees(World.project(context).root)
    assert World.git!(path, ~w(branch --show-current)) == branch
    thread = await_thread(World.thread_id(context, "Work"), &(&1["worktreePath"] == path))
    assert thread["branch"] == branch
    context
  end

  step "the setup script is started", context do
    {:ok, %{"worktreePath" => path, "setupScript" => script}} = context.handoff
    assert %{"status" => "started", "terminalId" => "setup"} = script

    key = %{"threadId" => World.thread_id(context, "Work"), "terminalId" => "setup"}
    {:ok, terminal} = HalC2.Terminal.attach(key, self())
    assert terminal["cwd"] == path
    await_output({key["threadId"], "setup"}, "setup-42", terminal["history"] || "")
    assert String.trim(File.read!(context.setup_log)) == path
    context
  end

  step "the agent continues in the worktree with the prompt", context do
    {:ok, %{"worktreePath" => path, "continuation" => continuation}} = context.handoff
    assert %{"status" => "scheduled", "delivery" => "queue_after_active"} = continuation

    id = World.thread_id(context, "Work")
    await_run(id, "completed")
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(id))

    assert Enum.any?(
             HalC2.StreamState.list(state, "message"),
             &(&1["role"] == "user" and &1["text"] == context.continuation)
           )

    # The fake agent writes the file into the checkout its turn runs in.
    assert File.exists?(Path.join(path, "continued.txt"))
    context
  end

  step "the thread already works in a worktree", context do
    in_worktree(context, "feature/tax")
  end

  step "the thread works in the worktree on {string}", %{args: [branch]} = context do
    in_worktree(context, branch)
  end

  step "the agent hands the thread off to a new worktree", context do
    handoff(context, %{"branch" => "feature/again", "startFromOrigin" => false})
  end

  step "the handoff is refused as already in a worktree", context do
    assert {:error, %{"code" => "already_in_worktree", "message" => message}} = context.handoff
    assert message =~ context.worktree.path
    branches = World.git!(context.worktree.root, ["branch", "--format=%(refname:short)"])
    refute "feature/again" in String.split(branches)
    context
  end

  step "the agent asks for its worktree status", context do
    Map.put(context, :handoff, tool(context, "hal_c2_worktree_status", %{}))
  end

  step "it learns it is attached, with the worktree path, branch and project root", context do
    %{path: path, root: root, branch: branch} = context.worktree

    assert {:ok,
            %{
              "attached" => true,
              "worktreePath" => ^path,
              "branch" => ^branch,
              "projectWorkspaceRoot" => ^root
            }} = context.handoff

    context
  end

  # --- helpers --------------------------------------------------------------------------------

  defp launch(context, text) do
    project = World.project(context)
    settings = HalC2.Settings.for_project(project.id)

    strategy =
      Map.merge(
        %{"startFromOrigin" => Map.get(settings, "newWorktreesStartFromOrigin", true)},
        context[:strategy] || %{}
      )

    World.launch_in_worktree(context, nil, text, strategy)
  end

  defp create_worktree(context, branch) do
    root = World.project(context).root

    {reply, context} =
      World.call(context, "vcs.createWorktree", %{
        "cwd" => root,
        "refName" => "main",
        "newRefName" => branch
      })

    assert {:ok, %{"worktree" => %{"path" => path, "refName" => ^branch}}} = reply
    Map.put(context, :worktree, %{path: path, root: root, branch: branch})
  end

  defp add_worktree(context, branch) do
    root = World.project(context).root
    path = Path.join(Node.tmp_dir(context.node, "worktree"), String.replace(branch, "/", "-"))
    World.git!(root, ["worktree", "add", "-q", "-b", branch, path, "main"])
    Map.put(context, :worktree, %{path: path, root: root, branch: branch})
  end

  defp remove_worktree(context, force) do
    %{path: path, root: root} = context.worktree

    {reply, context} =
      World.call(context, "vcs.removeWorktree", %{"cwd" => root, "path" => path, "force" => force})

    Map.put(context, :reply, reply)
  end

  # The project's one script, run when a worktree is created (`async` alongside the agent).
  defp put_setup(context, title, command, async) do
    project = World.project(context, title)

    scripts = [
      %{
        "id" => "setup",
        "name" => "Setup",
        "command" => command,
        "icon" => "configure",
        "runOnWorktreeCreate" => true,
        "async" => async
      }
    ]

    {:ok, _} =
      HalC2.Projects.mutate(%{
        "type" => "project.update",
        "projectId" => project.id,
        "scripts" => scripts
      })

    World.await_row(project.id, &(&1["scripts"] == scripts))
    context
  end

  # Makes `title`'s repository hold the submodule `tools` (which holds `vendor` when
  # `nested`), all from local repositories git may clone over `file://`.
  defp with_submodules(context, title, nested: nested) do
    Shared.put_env("GIT_CONFIG_COUNT", "1")
    Shared.put_env("GIT_CONFIG_KEY_0", "protocol.file.allow")
    Shared.put_env("GIT_CONFIG_VALUE_0", "always")

    tools = World.git_repo(context, "tools")

    if nested do
      vendor = World.git_repo(context, "vendor")
      World.git!(tools, ["submodule", "add", "-q", vendor, "vendor"])
      World.git!(tools, ~w(commit -q -m vendor))
    end

    root = World.project(context, title).root
    World.git!(root, ["submodule", "add", "-q", tools, "tools"])
    World.git!(root, ~w(commit -q -m tools))
    context
  end

  # Subscribes the user's client to the setup of `context.setup_thread` and keeps
  # the first event it gets as `context.watched`.
  defp watch_setup(context) do
    id = System.unique_integer([:positive])

    shape = %{
      "type" => "worktreeSetup",
      "node" => Atom.to_string(node()),
      "threadId" => context.setup_thread
    }

    client = Node.sub(World.client(context), id, shape)
    {frame, client} = Node.await(client, &(&1["t"] == "worktreeSetup" and &1["id"] == id), 5_000)
    context |> World.put_client(client) |> Map.put(:watched, frame["event"])
  end

  defp flush_socket(socket) do
    receive do
      {tag, ^socket, _} when tag in [:tcp, :ssl] -> flush_socket(socket)
      {tag, ^socket} when tag in [:tcp_closed, :ssl_closed] -> flush_socket(socket)
    after
      0 -> :ok
    end
  end

  defp type(context, data) do
    {:ok, _} =
      HalC2.Terminal.write(%{
        "threadId" => context.setup_thread,
        "terminalId" => "setup",
        "data" => data
      })
  end

  # A thread in the project, attached to a worktree of it on `branch`.
  defp in_worktree(context, branch) do
    World.worktree_services()
    context = context |> add_worktree(branch) |> World.create_thread("Work")
    %{path: path} = context.worktree

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.metadata.update",
        "threadId" => World.thread_id(context, "Work"),
        "worktreePath" => path,
        "branch" => branch
      })

    await_thread(World.thread_id(context, "Work"), &(&1["worktreePath"] == path))
    context
  end

  defp handoff(context, args),
    do: Map.put(context, :handoff, tool(context, "hal_c2_worktree_handoff", args))

  # Calls one of the agent's tools as the agent of the thread "Work".
  defp tool(context, name, arguments) do
    Node.ensure(HalC2.Mcp)
    %{authorization: auth} = HalC2.Mcp.server(World.thread_id(context, "Work"), "codex")

    body =
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments}
      })

    case HalC2.Mcp.handle(auth, body) do
      {200, %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}}} ->
        {:error, JSON.decode!(text)}

      {200, %{"result" => %{"structuredContent" => result}}} ->
        {:ok, result}
    end
  end

  # The thread's entity once it satisfies `fun`, following its stream.
  defp await_thread(id, fun) do
    :ok = HalC2.Streams.subscribe(id, self(), nil)
    follow_thread(id, fun)
  end

  defp follow_thread(id, fun) do
    thread =
      HalC2.StreamState.get(HalC2.Streams.Server.state(HalC2.Streams.ensure(id)), "thread")[id]

    if thread && fun.(thread) do
      thread
    else
      receive do
        {:hal_c2_stream, ^id, _} -> follow_thread(id, fun)
      after
        10_000 -> flunk("the thread never got there: #{inspect(thread)}")
      end
    end
  end

  # The thread's newest run once it has `status`.
  defp await_run(id, status) do
    :ok = HalC2.Streams.subscribe(id, self(), nil)
    follow_run(id, status)
  end

  defp follow_run(id, status) do
    runs = HalC2.StreamState.list(HalC2.Streams.Server.state(HalC2.Streams.ensure(id)), "run")

    case Enum.find(runs, &(&1["status"] == status)) do
      nil ->
        receive do
          {:hal_c2_stream, ^id, _} -> follow_run(id, status)
        after
          15_000 -> flunk("no #{status} run: #{inspect(runs)}")
        end

      run ->
        run
    end
  end

  defp await_output(key, text, buffer) do
    unless String.contains?(buffer, text) do
      receive do
        {:hal_c2_terminal, ^key, %{"type" => "output", "data" => data}} ->
          await_output(key, text, buffer <> data)
      after
        10_000 -> flunk("the terminal never printed #{text}: #{inspect(buffer)}")
      end
    end
  end
end
