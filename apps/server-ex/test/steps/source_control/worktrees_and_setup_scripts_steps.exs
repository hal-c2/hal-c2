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
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

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

  # Every 50th character is a slash, so no part of the ref passes the filesystem's limit.
  step "two branches of {int} characters that share their first {int}",
       %{args: [length, shared]} = context do
    branch = fn letter ->
      for i <- 0..(length - 1), into: "" do
        cond do
          rem(i, 50) == 49 and i < length - 1 -> "/"
          i < shared -> "a"
          true -> letter
        end
      end
    end

    Map.put(context, :long_branches, [branch.("b"), branch.("c")])
  end

  step "a worktree is created for each with no path given", context do
    {worktrees, context} =
      Enum.map_reduce(context.long_branches, context, fn branch, context ->
        context = create_worktree(context, branch)
        {context.worktree, context}
      end)

    Map.put(context, :worktrees, worktrees)
  end

  step "each folder name is {int} characters: the start of the branch and a hash of the whole name",
       %{args: [length]} = context do
    for %{path: path, branch: branch} <- context.worktrees do
      assert_short_folder(path, branch, length)
    end

    context
  end

  step "the two folders differ", context do
    [first, second] = Enum.map(context.worktrees, &Path.basename(&1.path))
    refute first == second
    context
  end

  step "each branch keeps its full name", context do
    for %{path: path, branch: branch} <- context.worktrees,
        do: assert(World.git!(path, ~w(branch --show-current)) == branch)

    context
  end

  # Every character but the first is a four-byte emoji, so the cut falls among them.
  step "a worktree is created with no path given for a long branch whose 40th character is an emoji",
       context do
    branch = "a" <> String.duplicate("😀", 60)
    assert String.at(branch, 39) == "😀"
    create_worktree(context, branch)
  end

  step "its folder name holds whole characters only", context do
    %{path: path, branch: branch} = context.worktree
    assert String.valid?(Path.basename(path))
    assert_short_folder(path, branch, 40)
    context
  end

  step "it is made in the HAL-C2 home's worktrees folder under the repository and branch names",
       context do
    %{path: path, root: root, branch: branch} = context.worktree
    name = String.replace(branch, "/", "-")
    assert path == Path.join([context.mc.home, "worktrees", Path.basename(root), name])
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

  # The project's own setting, with no hal-c2.json to fall back on.
  step "the submodule setting is {string} and the project has no worktree script of its own",
       %{args: ["skip"]} = context do
    context = with_submodules(context, "shop", nested: false)
    project = World.project(context, "shop")
    refute File.exists?(Path.join(project.root, "hal-c2.json"))
    refute File.exists?(Path.join(project.root, "t3.json"))

    World.put_settings(context, %{
      "projectSettingsOverrides" => %{project.id => %{"worktreeSubmodules" => "none"}}
    })
  end

  step "submodules are not initialized", context do
    path = context.worktree.path
    assert File.exists?(Path.join(path, ".gitmodules"))
    refute File.exists?(Path.join(path, "tools/README.md"))
    context
  end

  # --- the temporary branch's prefix (`WorktreeSetup.temporary_branch/2`) -------------

  step "no branch named after the prefix", context do
    root = World.project(context).root
    assert {_, 1} = System.cmd("git", ~w(show-ref --verify --quiet refs/heads/hal-c2), cd: root)
    context
  end

  step "a local branch named exactly <prefix>", context do
    World.git!(World.project(context).root, ~w(branch hal-c2))
    context
  end

  step "a worktree thread is provisioned", context do
    context = context |> Shared.answering_writer() |> launch("Add tax to the cart")
    {snapshot, context} = World.await_setup(context, & &1["worktreePath"])
    Map.put(context, :worktree, %{path: snapshot["worktreePath"], branch: snapshot["branch"]})
  end

  step "its temporary branch is {string}", %{args: [form]} = context do
    pattern =
      form
      |> Regex.escape()
      |> String.replace("<prefix>", "hal-c2")
      |> String.replace("<hex>", "[0-9a-f]{8}")

    assert context.worktree.branch =~ Regex.compile!("^#{pattern}$")
    context
  end

  step "the background rename to a generated name still runs for it", context do
    %{path: path, branch: temporary} = context.worktree
    thread = await_thread(context.setup_thread, &(&1["branch"] not in [nil, temporary]))
    assert thread["branch"] =~ "claude-branch"
    assert World.git!(path, ~w(branch --show-current)) == thread["branch"]
    context
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
    other = Path.join(Mc.tmp_dir(context.mc, "other"), "shop")
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

  # A project from `thread_in_git_project` has an origin: this takes it away.
  step "{string} has no remote", %{args: [title]} = context do
    root = World.project(context, title).root

    for remote <- String.split(World.git!(root, ["remote"]), "\n", trim: true),
        do: World.git!(root, ["remote", "remove", remote])

    assert World.git!(root, ["remote"]) == ""
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

  # Or several: "hal-c2 and hal-c2-fix-login".
  step "the branch {string} already exists", %{args: [branches]} = context do
    for branch <- String.split(branches, " and "),
        do: World.git!(World.project(context).root, ["branch", branch])

    context
  end

  step "{string} and the hundred numbered names after it already exist",
       %{args: [branch]} = context do
    root = World.project(context).root

    for name <- [branch | Enum.map(1..100, &"#{branch}-#{&1}")],
        do: World.git!(root, ["branch", name])

    context
  end

  step "the temporary branch of a new worktree is renamed to {string}",
       %{args: [name]} = context do
    context = Shared.answering_writer(context)
    Shared.put_env("FAKE_TEXT_ANSWER", JSON.encode!(%{"branch" => name}))
    context = launch(context, "Add tax to the cart")
    {snapshot, context} = World.await_setup(context, & &1["worktreePath"])
    Map.put(context, :worktree, %{path: snapshot["worktreePath"], branch: snapshot["branch"]})
  end

  step "the worktree's branch is {string}", %{args: [branch]} = context do
    thread = await_thread(context.setup_thread, &(&1["branch"] == branch))
    assert World.git!(thread["worktreePath"], ~w(branch --show-current)) == branch
    context
  end

  step "the user is told no available branch name could be found for {string}",
       %{args: [name]} = context do
    item = await_error_item(context.setup_thread)
    assert item["failure"]["message"] == "Could not find an available branch name for '#{name}'."
    context
  end

  step "the worktree stays on its temporary branch", context do
    %{path: path, branch: temporary} = context.worktree
    assert temporary =~ ~r/^hal-c2\/[0-9a-f]{8}$/
    assert World.git!(path, ~w(branch --show-current)) == temporary
    assert await_thread(context.setup_thread, & &1)["branch"] == temporary
    context
  end

  # --- checkout progress and time limits ---------------------------------------------

  # A filter that takes its time on each file, so git reports between them.
  step "{string} is large enough that checking out its files takes a while",
       %{args: [title]} = context do
    root = World.project(context, title).root
    World.git!(root, ["config", "filter.slow.smudge", "sleep 0.05; cat"])
    World.git!(root, ["config", "filter.slow.clean", "cat"])

    files =
      Map.new(1..20, &{"file-#{&1}.slow", "#{&1}\n"})
      |> Map.put(".gitattributes", "*.slow filter=slow\n")

    World.commit!(root, files, "Many files")
    context
  end

  step "the \"Check out files\" stage reports the share of files checked out as it grows",
       context do
    {_, context} = World.await_setup(context, &(&1["phase"] != "running"))

    shares =
      context.setup_snapshots
      |> Enum.map(&Enum.find(&1["stages"], fn stage -> stage["id"] == "checkout" end))
      |> Enum.filter(&(&1["status"] == "running" and &1["percent"]))
      |> Enum.map(& &1["percent"])

    assert length(Enum.uniq(shares)) >= 2, inspect(shares)
    assert shares == Enum.sort(shares)
    context
  end

  step "the stage ends at its full share when the checkout finishes", context do
    {snapshot, context} = World.await_setup(context, &(&1["phase"] != "running"))
    checkout = Enum.find(snapshot["stages"], &(&1["id"] == "checkout"))
    assert %{"status" => "done", "percent" => 100} = checkout
    context
  end

  # Git that hangs on the one command: the scenario's time limit is cut to a moment, and
  # what it would be otherwise is read once that limit has been seen to stop git.
  step ~r/^"(?<project>[^"]+)" is so large that (?<action>checking out files|removing the worktree) takes 2 minutes$/,
       %{args: [_title, action]} = context do
    command = if action == "removing the worktree", do: "worktree remove", else: "worktree add"

    context =
      if action == "removing the worktree",
        do: add_worktree(context, "feature/big"),
        else: context

    git = Path.join(Mc.tmp_dir(context.mc, "git"), "git-hangs")

    File.write!(
      git,
      "#!/bin/sh\ncase \"$*\" in *\"#{command}\"*) exec sleep 120;; esac\nexec git \"$@\"\n"
    )

    File.chmod!(git, 0o755)
    World.put_app_env(:git_command, git)
    World.put_app_env(:worktree_timeout, 300)
    context
  end

  step "git hangs on {string} once its new worktree is made", context do
    git = Path.join(Mc.tmp_dir(context.mc, "git"), "git-hangs")

    File.write!(
      git,
      "#!/bin/sh\ncase \"$*\" in *\"worktree add\"*) git \"$@\"; exec sleep 120;; esac\nexec git \"$@\"\n"
    )

    File.chmod!(git, 0o755)
    World.put_app_env(:git_command, git)
    World.put_app_env(:worktree_timeout, 300)
    context
  end

  # What `git worktree add` starts to fill the worktree goes on after git itself is
  # stopped, and puts back what is removed around it.
  step "git is stopped on {string} while it is still filling its new worktree", context do
    dir = Mc.tmp_dir(context.mc, "git")
    git = Path.join(dir, "git-fills")
    writer = Path.join(dir, "writer")

    File.write!(git, """
    #!/bin/sh
    case "$*" in
    *"worktree add"*)
      git "$@"
      while [ "$1" != "-b" ]; do shift; done
      path=$3
      echo "$path" > "#{writer}.path"
      (i=0; while [ $i -lt 600 ]; do mkdir -p "$path"; : > "$path/late"; sleep 0.05; i=$((i + 1)); done) &
      echo $! > "#{writer}.pid"
      exec sleep 120;;
    esac
    exec git "$@"
    """)

    File.chmod!(git, 0o755)
    World.put_app_env(:git_command, git)
    World.put_app_env(:worktree_timeout, 300)
    Map.put(context, :writer, writer)
  end

  step "nothing is still writing where the worktree was", context do
    pid = String.trim(File.read!(context.writer <> ".pid"))
    assert {_, status} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
    assert status != 0, "the checkout's writer #{pid} is still running"
    refute File.exists?(String.trim(File.read!(context.writer <> ".path")))
    context
  end

  step "a thread's worktree setup is running its script while its branch is being named",
       context do
    context = context |> Shared.answering_writer() |> put_setup(nil, "read _", false)
    writer = Path.join(Mc.tmp_dir(context.mc, "writer"), "held")
    File.write!(writer, "#!/bin/sh\nexec sleep 600\n")
    File.chmod!(writer, 0o755)
    Application.put_env(:hal_c2, :text_claude_command, writer)

    context = launch(context, "list the files")

    {snapshot, context} =
      World.await_setup(context, &(World.setup_stage(&1, "setup-script") == "running"))

    naming = :sys.get_state(HalC2.WorktreeSetup).setups[context.setup_thread].naming
    assert Process.alive?(naming)

    Map.merge(context, %{
      naming: naming,
      worktree: %{path: snapshot["worktreePath"], root: World.project(context).root}
    })
  end

  step "a thread's worktree setup is running its script after its branch was named", context do
    context = context |> Shared.answering_writer() |> put_setup(nil, "read _", false)
    context = launch(context, "list the files")

    {_, context} =
      World.await_setup(context, &(World.setup_stage(&1, "setup-script") == "running"))

    await_thread(context.setup_thread, &(&1["branch"] =~ "claude-branch"))
    context
  end

  step "a thread's worktree setup has renamed its branch and not yet said so", context do
    dir = Mc.tmp_dir(context.mc, "git")
    renamed = Path.join(dir, "renamed")
    {_, 0} = System.cmd("mkfifo", [renamed])
    git = Path.join(dir, "git-renames")

    File.write!(git, """
    #!/bin/sh
    case "$*" in *"branch -m"*) git "$@"; echo > "#{renamed}"; exec sleep 600;; esac
    exec git "$@"
    """)

    File.chmod!(git, 0o755)
    World.put_app_env(:git_command, git)

    context = context |> Shared.answering_writer() |> put_setup(nil, "read _", false)
    context = launch(context, "list the files")

    {_, context} =
      World.await_setup(context, &(World.setup_stage(&1, "setup-script") == "running"))

    # Opening the pipe waits for git to have taken the name.
    {_, 0} = System.cmd("cat", [renamed])
    context
  end

  step "a thread's setup script has switched its worktree to the branch {string}",
       %{args: [branch]} = context do
    World.git!(World.project(context).root, ["branch", branch])
    switched = Path.join(Mc.tmp_dir(context.mc, "script"), "switched")
    {_, 0} = System.cmd("mkfifo", [switched])
    context = put_setup(context, nil, "git switch #{branch}; echo > #{switched}; read _", false)
    context = launch(context, "list the files")

    # Opening the pipe waits for the script to have switched.
    {_, 0} = System.cmd("cat", [switched])
    context
  end

  step "the branch {string} is still in {string}", %{args: [branch, title]} = context do
    assert World.git!(World.project(context, title).root, ~w(branch --list) ++ [branch]) =~ branch
    context
  end

  step "the branch {string} is not left in {string}", %{args: [branch, title]} = context do
    refute World.git!(World.project(context, title).root, ~w(branch --list)) =~ branch
    context
  end

  step "the checkout of a new worktree in {string} fails partway", %{args: [title]} = context do
    root = World.project(context, title).root
    File.write!(Path.join(root, ".gitattributes"), "* filter=broken\n")
    World.git!(root, ~w(add .gitattributes))
    World.git!(root, ~w(-c user.name=t -c user.email=t@t commit -q -m attributes))
    World.git!(root, ~w(config filter.broken.smudge false))
    World.git!(root, ~w(config filter.broken.required true))
    context
  end

  step "the branch is no longer being named", context do
    refute Process.alive?(context.naming)
    context
  end

  step "what the checkout started is no longer running", context do
    {_, status} = System.cmd("kill", ["-0", context.hook_pid], stderr_to_stdout: true)
    assert status != 0, "the checkout's hook #{context.hook_pid} is still running"
    context
  end

  step "the setup fails when the limit stops git", context do
    {snapshot, context} = World.await_setup(context, &(&1["phase"] != "running"))
    assert snapshot["phase"] == "failed", inspect(snapshot)
    context
  end

  step "neither the worktree nor its new branch is left in {string}",
       %{args: [title]} = context do
    root = World.project(context, title).root
    assert [_root_only] = String.split(World.git!(root, ~w(worktree list)), "\n")
    refute World.git!(root, ~w(branch --list)) =~ "hal-c2"
    context
  end

  step "the user removes the worktree", context do
    remove_worktree(context, false)
  end

  step "the git command is not stopped by the usual 30 second limit", context do
    context =
      if context[:setup_thread] do
        {snapshot, context} = World.await_setup(context, &(&1["phase"] != "running"))
        assert snapshot["error"] =~ "timed out after 300 ms"
        context
      else
        assert elem(context.reply, 0) == :error
        assert inspect(context.reply) =~ "timed out after 300 ms"
        context
      end

    Application.delete_env(:hal_c2, :worktree_timeout)
    assert HalC2.Vcs.worktree_timeout() > 30_000
    context
  end

  step "it is stopped only after 5 minutes", context do
    assert HalC2.Vcs.worktree_timeout() == 5 * 60_000
    context
  end

  # --- what a worktree's branch and folder are ---------------------------------------

  step "a worktree is created for the new branch {string} based on {string}",
       %{args: [branch, "origin/" <> base]} = context do
    context = Shared.thread_in_git_project(context, "store")
    root = World.project(context, "store").root
    World.git!(root, ["branch", base])
    World.git!(root, ["push", "-q", "origin", base])
    World.git!(root, ["fetch", "-q", "origin"])

    {reply, context} =
      World.call(context, "vcs.createWorktree", %{
        "cwd" => root,
        "refName" => "origin/#{base}",
        "newRefName" => branch
      })

    assert {:ok, %{"worktree" => %{"path" => path}}} = reply
    World.commit!(path, %{"tax.txt" => "10%\n"}, "Charge tax")
    Map.put(context, :worktree, %{path: path, root: root, branch: branch})
  end

  step "the pull request for {string} is created", %{args: [branch]} = context do
    context = World.create_thread(context, "Tax", "store", %{"branch" => branch})

    {events, context} =
      World.git_action(context, context.worktree.path, "create_pr", %{
        "threadId" => World.thread_id(context, "Tax")
      })

    last = List.last(events)
    assert last["kind"] == "action_finished", "the action failed: #{inspect(last)}"
    context
  end

  step "it targets {string}", %{args: [base]} = context do
    assert [%{"args" => args}] = World.cli_calls(context, "pr create")
    assert Enum.at(args, Enum.find_index(args, &(&1 == "--base")) + 1) == base
    context
  end

  step "its folder under the repository's name is {string}", %{args: [folder]} = context do
    %{path: path, root: root} = context.worktree
    assert Path.basename(path) == folder
    assert Path.basename(Path.dirname(path)) == Path.basename(root)
    assert File.dir?(path)
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
    log = Path.join(Mc.tmp_dir(context.mc, "setup"), "cwd")
    # What the script's terminal tells the tools in it comes back beside its folder.
    command =
      ~s(pwd > '#{log}'; printf '%s|%s|%s' "$NO_COLOR" "$FORCE_COLOR" "$COLORTERM" > '#{log}.env')

    context |> put_setup(title, command, false) |> Map.put(:setup_log, log)
  end

  step "the script runs in the thread's {string} terminal inside the new worktree",
       %{args: [terminal]} = context do
    {snapshot, context} = World.await_setup(context, &(&1["phase"] != "running"))
    assert %{"phase" => "done", "worktreePath" => path} = snapshot
    assert %{"terminalId" => ^terminal} = snapshot["setupScript"]
    assert World.setup_stage(snapshot, "setup-script") == "done"
    # The script succeeded, so its idle terminal is closed by now (upstream #13673).
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

  step "{string} has a setup script that prints colored text and cursor movements",
       %{args: [title]} = context do
    command = ~S"printf '\033[1;31mred\033[0m \033[2K\033[1Gplain\033[?25l\n'"
    context |> put_setup(title, command, false) |> Map.put(:expected_tail, ["red plain"])
  end

  step "{string} has a setup script that prints a progress bar that redraws one line with carriage returns",
       %{args: [title]} = context do
    command = ~S"printf 'bar 10%%\rbar 50%%\rbar 100%%\n'"

    context
    |> put_setup(title, command, false)
    |> Map.put(:expected_tail, ["bar 10%", "bar 50%", "bar 100%"])
  end

  step "{string} has a setup script that prints a single line of 1,000 characters",
       %{args: [title]} = context do
    command = ~S"printf 'x%.0s' $(seq 1 1000); echo"

    context
    |> put_setup(title, command, false)
    |> Map.put(:expected_tail, [String.duplicate("x", 400)])
  end

  step "{string} has a setup script that prints output that never ends a line",
       %{args: [title]} = context do
    command = ~S"printf 'x%.0s' $(seq 1 20000)"

    context
    |> put_setup(title, command, false)
    |> Map.put(:expected_tail, [String.duplicate("x", 400)])
  end

  step "the setup script stage shows the same text without the colors and movement", context do
    shows_expected_tail(context)
  end

  step "the setup script stage shows each redraw as a line of its own", context do
    shows_expected_tail(context)
  end

  step "the setup script stage shows the first 400 characters of it", context do
    shows_expected_tail(context)
  end

  step "the setup script stage shows no more than the last few thousand characters kept in memory",
       context do
    {lines, partial} = HalC2.WorktreeSetup.script_lines("", String.duplicate("x", 20_000))
    assert lines == []
    assert String.length(partial) == 4_096
    shows_expected_tail(context)
  end

  step "{string} has a setup script that ends with a comment line", %{args: [title]} = context do
    ending_script(context, title, "(exit 4)\n# all done", 4)
  end

  step "{string} has a setup script that reads from its input until it is closed",
       %{args: [title]} = context do
    context
    |> ending_script(title, "echo waiting; cat > /dev/null; exit 5", 5)
    |> Map.put(:script_reads, true)
  end

  step "{string} has a setup script that prints a line that looks like a completion mark",
       %{args: [title]} = context do
    command = "echo __hal_c2_setup_000000000000_0; exit 6"

    context
    |> ending_script(title, command, 6)
    |> Map.put(:script_prints, "__hal_c2_setup_000000000000_0")
  end

  step "{string} has a setup script that is a few lines long with a here-document",
       %{args: [title]} = context do
    ending_script(context, title, "cat <<EOF\nhello from here\nEOF\n(exit 7)", 7)
  end

  step "{string} has a setup script that has a syntax error on its last line",
       %{args: [title]} = context do
    ending_script(context, title, "echo a\nif true; then echo b; fi; fi", 2)
  end

  # --- the shell that starts ------------------------------------------------------------

  # The setup script is one whose end the wrong shell's wrapper would miss or misread.
  step "the environment's shell setting is a shell that is not there", context do
    Shared.put_env("SHELL", Path.join(Mc.tmp_dir(context.mc, "no-shell"), "fish"))
    ending_script(context, nil, "echo ran; (exit 3)", 3)
  end

  step "the shell that starts is the system's fallback shell", context do
    assert [program | _] = HalC2.Terminal.shell()
    refute program == System.get_env("SHELL")
    assert File.exists?(program)
    context
  end

  step "the setup script stage ends with the script's own exit status", context do
    context =
      if context[:script_reads] do
        {_, context} = World.await_setup(context, &(tail(&1) == ["waiting"]))
        type(context, "\x04")
        context
      else
        context
      end

    {snapshot, context} = World.await_setup(context, &(&1["phase"] != "running"))
    stage = Enum.find(snapshot["stages"], &(&1["id"] == "setup-script"))
    assert stage["status"] == "failed"
    assert stage["detail"] == "exited with #{context.script_exit}", inspect(stage)
    context
  end

  step "nothing the script printed is taken for its end", context do
    {snapshot, context} = World.await_setup(context, &(&1["phase"] != "running"))
    assert snapshot["error"] == "Setup script exited with #{context.script_exit}."
    if text = context[:script_prints], do: assert(text in tail(snapshot))
    context
  end

  step "a setup script that must finish before the agent starts", context do
    put_setup(context, nil, "echo started; read _", false)
  end

  step "its terminal is closed while it is still running", context do
    context = launch(context, "list the files")
    {_, context} = World.await_setup(context, &(tail(&1) == ["started"]))

    {:ok, _} =
      HalC2.Terminal.close(%{"threadId" => context.setup_thread, "terminalId" => "setup"})

    context
  end

  step "the setup stops waiting for it", context do
    context
  end

  # --- a script that cannot depend on the shell's startup --------------------------------

  step "a blocking setup script that writes a file", context do
    put_setup(context, nil, "echo ran > setup-ran.txt", false)
  end

  step "a background setup script that writes a file", context do
    put_setup(context, nil, "echo ran > setup-ran.txt", true)
  end

  # `sh -i` reads `$ENV` as it starts. The terminal gives what it holds a moment to arrive.
  step "the shell's startup reads whatever is waiting on its input", context do
    shell_startup(context, "stty -icanon min 0 time 3; cat > /dev/null; stty icanon\n")
  end

  step "the shell's startup never finishes", context do
    World.put_app_env(:worktree_setup_start_timeout, 500)
    shell_startup(context, "read _\n")
  end

  step "the thread's worktree is prepared", context do
    launch(context, "list the files")
  end

  step "the setup finishes and the script wrote its file", context do
    {snapshot, context} = World.await_setup(context, &(&1["phase"] != "running"))
    assert snapshot["phase"] == "done"
    assert File.read!(Path.join(snapshot["worktreePath"], "setup-ran.txt")) == "ran\n"
    context
  end

  step "the setup script stage says it did not start", context do
    script = fn snapshot -> Enum.find(snapshot["stages"], &(&1["id"] == "setup-script")) end
    {snapshot, context} = World.await_setup(context, &(script.(&1)["status"] == "failed"))
    stage = script.(snapshot)
    assert %{"status" => "failed", "detail" => "did not start"} = stage
    Map.put(context, :settled, snapshot)
  end

  step "the setup can no longer begin behind the failure", context do
    refute "setup" in HalC2.Terminal.running(context.setup_thread)
    context
  end

  step "a setup script has {int} seconds to begin", %{args: [seconds]} = context do
    World.put_app_env(:worktree_setup_start_timeout, seconds * 1_000)
    Map.put(context, :start_seconds, seconds)
  end

  step "the script is still running after those {int} seconds", %{args: [seconds]} = context do
    {_, context} = World.await_setup(context, &(tail(&1) == ["started"]))
    # This one wait is the behaviour: the time to begin has to go by.
    Process.sleep(seconds * 1_000 + 200)
    context
  end

  step "the setup is still running", context do
    assert %{"phase" => "running"} = HalC2.WorktreeSetup.subscribe(context.setup_thread, self())
    type(context, "\r")
    {snapshot, context} = World.await_setup(context, &(&1["phase"] != "running"))
    assert snapshot["phase"] == "done"
    context
  end

  # --- retrying --------------------------------------------------------------------------

  step "a blocking setup script that fails until a file exists", context do
    put_setup(context, nil, ~S(test -e "$HAL_C2_PROJECT_ROOT/.setup-may-pass"), false)
  end

  step "the thread's setup failed on that script", context do
    context = launch(context, "list the files")
    {snapshot, context} = World.await_setup(context, &(&1["phase"] != "running"))
    assert snapshot["phase"] == "failed"
    Map.put(context, :settled, snapshot)
  end

  step "the file exists and the user retries the setup", context do
    File.write!(Path.join(World.project(context).root, ".setup-may-pass"), "")

    {reply, context} =
      World.call(context, "worktreeSetup.retry", %{"threadId" => context.setup_thread})

    assert {:ok, %{"retried" => true}} = reply
    context
  end

  step "the setup finishes in the same worktree", context do
    {snapshot, context} =
      World.await_setup(context, &(&1["phase"] == "done"))

    assert snapshot["worktreePath"] == context.settled["worktreePath"]
    assert World.setup_stage(snapshot, "setup-script") == "done"
    assert World.setup_stage(snapshot, "agent") == "done"
    Map.put(context, :settled, snapshot)
  end

  step "the conversation no longer shows the failure", context do
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(context.setup_thread))
    ids = state |> HalC2.StreamState.get("turn-item") |> Map.keys()
    refute Enum.any?(ids, &String.starts_with?(&1, "turn-item:workspace-preparation-failure:"))
    context
  end

  step "the agent starts on the first message", context do
    assert %{"status" => "completed"} = await_run(context.setup_thread, "completed")
    context
  end

  step "the user sends another message in that thread", context do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "commandId" => "follow-up",
        "threadId" => context.setup_thread,
        "messageId" => "follow-up",
        "text" => "go on without it",
        "attachments" => []
      })

    context
  end

  step "the setup is no longer tracked", context do
    thread_id = context.setup_thread
    assert_receive {:hal_c2_worktree_setup, ^thread_id, nil}, 15_000
    context
  end

  step "retrying the setup is refused", context do
    {reply, context} =
      World.call(context, "worktreeSetup.retry", %{"threadId" => context.setup_thread})

    assert {:ok, %{"retried" => false}} = reply
    context
  end

  step "the script's terminal asks tools for plain output without colour", context do
    {snapshot, context} = World.await_setup(context, &(&1["phase"] != "running"))
    assert snapshot["phase"] == "done"
    assert [no_color, force_color, _] = String.split(File.read!(context.setup_log <> ".env"), "|")
    assert {no_color, force_color} == {"1", "0"}
    context
  end

  step "a tool that probes the terminal for truecolour does not wait for an answer", context do
    assert [_, _, ""] = String.split(File.read!(context.setup_log <> ".env"), "|")
    context
  end

  step ~r/^a setup stage reports a (?<kind>detail|error) of 5,000 characters$/,
       %{args: [kind]} = context do
    context = hold_checkout(context)
    long = String.duplicate("x", 5_000)

    update =
      if kind == "detail",
        do: &HalC2.WorktreeSetup.set_stage(&1, "checkout", "running", %{"detail" => long}),
        else: &HalC2.WorktreeSetup.finish(&1, "failed", long)

    :ok = GenServer.call(HalC2.WorktreeSetup, {:update, context.setup_thread, update})
    Map.put(context, :long_kind, kind)
  end

  step "a client reads the setup", context do
    Map.put(context, :read_setup, HalC2.WorktreeSetup.subscribe(context.setup_thread, self()))
  end

  step ~r/^the (?<kind>detail|error) is cut to (?<limit>200|1,000) characters and ends with an ellipsis$/,
       %{args: [kind, limit]} = context do
    text =
      if kind == "detail",
        do: Enum.find(context.read_setup["stages"], &(&1["id"] == "checkout"))["detail"],
        else: context.read_setup["error"]

    assert String.length(text) == String.to_integer(String.replace(limit, ",", ""))
    assert String.ends_with?(text, "…")
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
    hold_checkout(context)
  end

  step "a thread's worktree setup is running a stage", context do
    hold_checkout(context)
  end

  step "the setup finishes", context do
    {snapshot, context} =
      World.await_setup(context, &(World.setup_stage(&1, "checkout") == "running"))

    Map.put(context, :settled, HalC2.WorktreeSetup.finish(snapshot, "done", nil))
  end

  # Git fails when its post-checkout hook is killed under it.
  step "the setup fails", context do
    {_, 0} = System.cmd("kill", ["-9", context.hook_pid])
    {snapshot, context} = World.await_setup(context, &(&1["phase"] != "running"))
    assert snapshot["phase"] == "failed", inspect(snapshot)
    Map.put(context, :settled, snapshot)
  end

  step "the setup is cancelled", context do
    {reply, context} =
      World.call(context, "worktreeSetup.cancel", %{"threadId" => context.setup_thread})

    assert {:ok, %{"cancelled" => true}} = reply
    {snapshot, context} = World.await_setup(context, &(&1["phase"] != "running"))
    Map.put(context, :settled, snapshot)
  end

  step "that stage is reported as {string}", %{args: [status]} = context do
    stage = Enum.find(context.settled["stages"], &(&1["id"] == "checkout"))
    assert stage["status"] == status
    assert stage["endedAt"]
    context
  end

  step "stages that never started are left as they were", context do
    agent = Enum.find(context.settled["stages"], &(&1["id"] == "agent"))
    assert %{"status" => "pending", "endedAt" => nil} = agent
    context
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
    context = World.put_client(context, Mc.connect(context.mc))
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

  # The half minute is the server's timer: the client reads the setup now, with more
  # than the scenario's 20 seconds of it still to run.
  step "a client reads the setup 20 seconds later", context do
    %{setups: setups} = :sys.get_state(HalC2.WorktreeSetup)
    %{expiry: {timer, _}} = setups[context.setup_thread]
    assert Process.read_timer(timer) > 20_000
    assert Process.read_timer(timer) <= 30_000
    watch_setup(context)
  end

  step "it sees the finished setup with its outcome", context do
    assert %{"phase" => "done", "error" => nil} = context.watched
    assert World.setup_stage(context.watched, "agent") == "done"
    context
  end

  step "the thread starts another worktree setup", context do
    root = World.project(context).root
    {reader, _pipe} = checkout_hook(context, root)
    finished = context.watched

    :ok =
      HalC2.WorktreeSetup.start(
        context.setup_thread,
        "run-again",
        %{"workspaceRoot" => root, "scripts" => []},
        %{"type" => "worktree", "baseRef" => "main", "startFromOrigin" => false},
        "again"
      )

    {out, 0} = Task.await(reader, 15_000)
    [pid, _] = String.split(String.trim(out), " ", parts: 2)
    ExUnit.Callbacks.on_exit(fn -> System.cmd("kill", [pid], stderr_to_stdout: true) end)
    Map.put(context, :replaced, finished)
  end

  step "clients see only the new setup from its first stage on", context do
    current = HalC2.WorktreeSetup.subscribe(context.setup_thread, self())
    assert current["sequence"] > context.replaced["sequence"]
    assert %{"phase" => "running", "error" => nil, "endedAt" => nil} = current
    assert World.setup_stage(current, "checkout") == "running"
    assert World.setup_stage(current, "agent") == "pending"
    %{setups: setups} = :sys.get_state(HalC2.WorktreeSetup)
    refute Map.has_key?(setups[context.setup_thread], :expiry)
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
    log = Path.join(Mc.tmp_dir(context.mc, "setup"), "cwd")

    context
    |> put_setup(title, "pwd > '#{log}'; echo \"setup done $((6*7))\"", false)
    |> World.create_thread("Work", title)
    |> Map.put(:setup_log, log)
  end

  step "the agent works in {string} without a worktree, and its hal-c2.json marks the setup script",
       %{args: [title]} = context do
    World.worktree_services()
    log = Path.join(Mc.tmp_dir(context.mc, "setup"), "cwd")
    root = World.project(context, title).root
    commit_setup_file(root, "pwd > '#{log}'; echo \"setup done $((6*7))\"")

    context
    |> World.create_thread("Work", title)
    |> Map.put(:setup_log, log)
  end

  step "the branch {string} changes the setup script's command", %{args: [branch]} = context do
    root = World.project(context).root
    World.git!(root, ["checkout", "-q", "-b", branch])
    commit_setup_file(root, "echo changed")
    World.git!(root, ["checkout", "-q", "-"])
    context
  end

  step "the agent hands the thread off to a new worktree of {string}",
       %{args: [base]} = context do
    handoff(context, %{"branch" => "feature/pay", "baseRef" => base, "startFromOrigin" => false})
  end

  step "the handoff skips the setup script until it is imported", context do
    assert {:ok, %{"setupScript" => script}} = context.handoff

    assert script == %{
             "status" => "skipped",
             "detail" =>
               "the checkout's setup script was not run; import or save the setup action under Settings → Project → Actions first"
           }

    context
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
    # Only the shell running the line prints "setup done 42": the terminal's echo of it
    # has `$((6*7))`, and the log's path, which it also echoes, holds no space.
    await_output({key["threadId"], "setup"}, "setup done 42", terminal["history"] || "")
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

  # --- many worktrees of one repository at once ------------------------------------

  step "the project starts worktrees from origin", context do
    project = World.project(context)
    origin = World.git_remote(context, project.root)

    context
    |> World.put_settings(%{
      "projectSettingsOverrides" => %{project.id => %{"newWorktreesStartFromOrigin" => true}}
    })
    |> Map.put(:remotes, %{"origin" => origin})
  end

  # --- the remote a base tracks -----------------------------------------------------

  step "the project starts worktrees from origin and {string} has the remotes {string} and {string}",
       %{args: [title, first, second]} = context do
    project = World.project(context, title)
    remotes = Map.new([first, second], &{&1, World.git_remote(context, project.root, &1)})

    context
    |> World.put_settings(%{
      "projectSettingsOverrides" => %{project.id => %{"newWorktreesStartFromOrigin" => true}}
    })
    |> Map.put(:remotes, remotes)
  end

  # The tracked remote moves ahead, so the worktree shows it was fetched from there.
  step "the base branch {string} tracks {string}", %{args: [branch, tracked]} = context do
    [remote, _] = String.split(tracked, "/", parts: 2)
    World.git!(World.project(context).root, ["branch", "--set-upstream-to=#{tracked}", branch])
    Map.put(context, :ahead, ahead(context, context.remotes[remote], branch))
  end

  step "the user sends the first message of a thread in a new worktree from {string}",
       %{args: [base]} = context do
    context
    |> Map.update(:strategy, %{"baseRef" => base}, &Map.put(&1, "baseRef", base))
    |> launch("list the files")
  end

  step "{string} is fetched and the worktree starts from it", %{args: [ref]} = context do
    {done, context} = World.await_setup(context, &(&1["phase"] != "running"))
    assert done["phase"] == "done"
    assert World.setup_stage(done, "fetch") == "done"
    assert World.git!(World.project(context).root, ["rev-parse", ref]) == context.ahead
    assert World.git!(done["worktreePath"], ~w(rev-parse HEAD)) == context.ahead
    context
  end

  # Its remote-tracking ref stays behind, at an older commit than the local branch.
  step "the base branch {string} tracks a remote branch that was deleted",
       %{args: [branch]} = context do
    root = World.project(context).root
    World.git!(root, ["branch", branch, "main"])
    World.git!(root, ["push", "-q", "-u", "origin", branch])
    World.git!(context.remotes["origin"], ["branch", "-D", branch])
    tree = World.git!(root, ["rev-parse", "#{branch}^{tree}"])

    commit =
      World.git!(root, [
        "-c",
        "user.email=hal-c2@example.com",
        "-c",
        "user.name=HAL-C2",
        "commit-tree",
        "-p",
        branch,
        "-m",
        "local",
        tree
      ])

    World.git!(root, ["update-ref", "refs/heads/#{branch}", commit])
    Map.put(context, :stale, World.git!(root, ["rev-parse", "origin/#{branch}"]))
  end

  step "no stale remote-tracking ref is used", context do
    {done, context} = World.await_setup(context, &(&1["phase"] != "running"))
    refute World.git!(done["worktreePath"], ~w(rev-parse HEAD)) == context.stale
    context
  end

  # --- a fetch that loses a ref's lock ----------------------------------------------

  # Origin moves ahead so the fetch must update the ref, whose lock is held as another
  # fetch would hold it. Origin's upload-pack lets go of it as the second fetch starts.
  step "a background fetch of {string} holds {string} while the worktree's fetch runs",
       %{args: [remote, ref]} = context do
    root = World.project(context).root
    [_, branch] = String.split(ref, "/", parts: 2)
    ahead = ahead(context, context.remotes[remote], branch)
    lock = hold_ref(root, "refs/remotes/#{ref}")
    dir = Mc.tmp_dir(context.mc, "upload-pack")
    count = Path.join(dir, "fetches")
    script = Path.join(dir, "upload-pack.sh")

    File.write!(script, """
    #!/bin/sh
    echo fetch >> '#{count}'
    [ "$(wc -l < '#{count}')" -ge 2 ] && rm -f '#{lock}'
    exec git-upload-pack "$@"
    """)

    File.chmod!(script, 0o755)
    World.git!(root, ["config", "remote.#{remote}.uploadpack", script])
    Map.merge(context, %{ahead: ahead, fetches: count, locked: {remote, ref}})
  end

  step "git reports it could not update {string}", %{args: [ref]} = context do
    {_, locked} = context.locked
    assert ref == "refs/remotes/#{locked}"
    launch(context, "list the files")
  end

  step "the worktree's fetch is tried once more and the worktree is made", context do
    {done, context} = World.await_setup(context, &(&1["phase"] != "running"))
    assert done["phase"] == "done"
    assert File.read!(context.fetches) == "fetch\nfetch\n"
    assert World.git!(done["worktreePath"], ~w(rev-parse HEAD)) == context.ahead
    context
  end

  step "a lock failure that persists tells the user a local reference could not be updated",
       context do
    root = World.project(context).root
    {remote, ref} = context.locked
    [_, branch] = String.split(ref, "/", parts: 2)
    World.git!(root, ["config", "--unset", "remote.#{remote}.uploadpack"])
    ahead(context, context.remotes[remote], branch)
    hold_ref(root, "refs/remotes/#{ref}")
    context = launch(context, "list the files again")
    {failed, context} = World.await_setup(context, &(&1["phase"] != "running"))
    assert failed["phase"] == "failed"
    assert failed["error"] =~ "a local reference could not be updated", inspect(failed)
    assert failed["worktreePath"] == nil
    context
  end

  # Every launch is accepted before any setup has gone far, so the checkouts, the base
  # records and the renames of all of them overlap.
  step "{int} threads are launched in new worktrees of the project at the same moment",
       %{args: [count]} = context do
    context = Shared.answering_writer(context)

    {ids, context} =
      Enum.map_reduce(1..count, context, fn n, context ->
        context = launch(context, "fix the cart total #{n}")
        {context.setup_thread, context}
      end)

    Map.put(context, :many_threads, ids)
  end

  step "each thread has its own worktree on its own branch", context do
    root = World.project(context).root

    threads =
      for id <- context.many_threads,
          do: await_thread(id, &(is_binary(&1["branch"]) and &1["branch"] =~ "claude-branch"))

    paths = Enum.map(threads, & &1["worktreePath"])
    branches = Enum.map(threads, & &1["branch"])
    assert length(Enum.uniq(paths)) == length(threads)
    assert length(Enum.uniq(branches)) == length(threads)

    for %{"worktreePath" => path, "branch" => branch} <- threads do
      assert path in World.worktrees(root)
      assert World.git!(path, ~w(branch --show-current)) == branch
    end

    Map.put(context, :many_branches, branches)
  end

  # A new branch has no upstream of its own: one started from `origin/main` must not
  # push to `main` (`HalC2.Vcs.create_worktree/2`).
  step "each branch records the base it started from", context do
    root = World.project(context).root

    for branch <- context.many_branches do
      assert World.git!(root, ["config", "--get", "branch.#{branch}.gh-merge-base"]) == "main"
    end

    context
  end

  step "each temporary branch is renamed from its thread's first message", context do
    root = World.project(context).root
    left = World.git!(root, ~w(branch --list hal-c2/*))
    assert left == "", "temporary branches left: #{left}"
    prompts = Shared.writer_prompts(context)

    for n <- 1..length(context.many_threads),
        do: assert(Enum.any?(prompts, &(&1 =~ "fix the cart total #{n}")))

    context
  end

  # --- a locked git config ------------------------------------------------------------

  step "another program holds the lock on the git config of {string}",
       %{args: [title]} = context do
    root = World.project(context, title).root

    lock =
      Path.join(
        World.git!(root, ~w(rev-parse --path-format=absolute --git-common-dir)),
        "config.lock"
      )

    File.write!(lock, "")
    ExUnit.Callbacks.on_exit(fn -> File.rm(lock) end)
    context |> Shared.answering_writer() |> Map.put(:config_lock, lock)
  end

  step "the thread starts in the new worktree", context do
    {snapshot, context} = World.await_setup(context, &(&1["phase"] != "running"))
    assert snapshot["phase"] == "done"
    path = snapshot["worktreePath"]
    assert File.dir?(path)
    run = await_run(context.setup_thread, "completed")
    assert run
    Map.put(context, :worktree, %{path: path, branch: snapshot["branch"]})
  end

  step "the branch's base is taken from the default branch when it is needed", context do
    root = World.project(context).root
    thread = await_thread(context.setup_thread, &(&1["branch"] =~ "claude-branch"))
    branch = thread["branch"]
    assert World.git!(context.worktree.path, ~w(branch --show-current)) == branch
    File.rm!(context.config_lock)

    assert {_, 1} =
             System.cmd("git", ["-C", root, "config", "--get", "branch.#{branch}.gh-merge-base"])

    assert HalC2.Git.base_branch(root, branch) == "main"
    context
  end

  # --- a thread whose worktree was deleted ------------------------------------------

  # A real worktree of the project on its own branch, with a commit of its own, whose
  # thread the user goes back to.
  step "the thread {string} worked in its own worktree on {string}",
       %{args: [title, branch]} = context do
    worked_in_worktree(context, title, branch)
  end

  step ~r/^the worktree was deleted and "(?<branch>[^"]+)" (?<state>still exists|was deleted but "origin\/[^"]+" was fetched|was deleted too|was deleted too and the project checkout is detached)$/,
       %{args: [branch, state]} = context do
    %{path: path, root: root} = context.lost
    assert branch == context.lost.branch

    if state =~ ~r/origin|detached/ do
      World.git_remote(context, root)
      World.git!(path, ["push", "-q", "origin", branch])
    end

    File.rm_rf!(path)

    if state != "still exists" do
      World.git!(root, ~w(worktree prune))
      World.git!(root, ["branch", "-D", branch])
      # The origin copy goes with the remote-tracking branch unless it was fetched.
      unless state =~ "origin",
        do: World.git!(root, ["update-ref", "-d", "refs/remotes/origin/#{branch}"])
    end

    # The project's own checkout has moved on, so the start of the remade branch says
    # which one it came from.
    start =
      case state do
        "was deleted too" ->
          World.git!(root, ~w(switch -q -c develop))
          World.commit!(root, %{"develop.txt" => "develop\n"}, "develop")
          World.git!(root, ~w(rev-parse HEAD))

        "was deleted too and the project checkout is detached" ->
          World.git!(root, ~w(switch -q --detach))
          World.commit!(root, %{"detached.txt" => "detached\n"}, "detached")
          World.git!(root, ~w(rev-parse origin/main))

        _ ->
          nil
      end

    put_in(context.lost[:start], start)
  end

  # Git still lists the worktree (its folder is gone), and the project's own checkout
  # has its branch, so it cannot be made again until the user frees it.
  step "the thread {string} lost its worktree and making it again fails",
       %{args: [title]} = context do
    context = worked_in_worktree(context, title, "feature/cart")

    %{path: path, root: root, branch: branch} = context.lost
    File.rm_rf!(path)
    World.git!(root, ~w(worktree prune))
    World.git!(root, ["switch", "-q", branch])
    context
  end

  step "the user sends the next message in {string}", %{args: [title]} = context do
    assert title == context.thread
    send_next(context, "carry on")
  end

  step ~r/^the worktree is made again (?<from>.+)$/, %{args: [from]} = context do
    World.await_latest_run(context, context.thread, "completed", 15_000)
    %{path: path, branch: branch, root: root} = context.lost
    assert File.dir?(path)
    assert World.git!(path, ~w(branch --show-current)) == branch
    assert %{"worktreePath" => ^path, "branch" => ^branch} = World.thread(context, context.thread)
    head = World.git!(path, ~w(rev-parse HEAD))

    cond do
      from == ~s(on "#{branch}") ->
        assert File.exists?(Path.join(path, "cart.txt"))

      from =~ "origin/" ->
        assert head == World.git!(root, ["rev-parse", "origin/#{branch}"])
        assert File.exists?(Path.join(path, "cart.txt"))
        assert World.git!(path, ~w(rev-parse --abbrev-ref @{upstream})) == "origin/#{branch}"

      true ->
        assert head == context.lost.start
        refute File.exists?(Path.join(path, "cart.txt"))
    end

    context
  end

  step "the turn runs in it", context do
    assert [%{"cwd" => cwd}] = World.codex_requests(context, "turn/start")
    assert cwd == context.lost.path
    context
  end

  step "the agent is not started", context do
    World.await_latest_run(context, context.thread, "failed", 15_000)
    assert World.codex_requests(context, "turn/start") == []
    refute File.exists?(context.lost.path)
    context
  end

  step "the thread says the worktree could not be made, naming the branch and the path, without raw git output",
       context do
    %{path: path, branch: branch} = context.lost
    item = await_error_item(World.thread_id(context, context.thread))
    message = item["failure"]["message"]
    assert item["title"] == "Worktree could not be made"
    assert message =~ ~s("#{branch}")
    assert message =~ path
    assert message =~ "Send the message again to retry."
    refute message =~ ~r/fatal|already|git worktree/i
    context
  end

  step "the user can send again to retry", context do
    %{path: path, root: root} = context.lost
    World.git!(root, ~w(switch -q main))
    context = send_next(context, "try again")
    World.await_latest_run(context, context.thread, "completed", 15_000)
    assert File.dir?(path)
    assert [%{"cwd" => ^path}] = World.codex_requests(context, "turn/start")
    context
  end

  step "the agent is working in the worktree of {string} with two messages queued behind it",
       %{args: [title]} = context do
    context = worked_in_worktree(context, title, "feature/cart")
    context = send_next(context, "wait for the cart")
    World.await_running(context, title)

    context
    |> World.queue_message(title, "carry on")
    |> World.queue_message(title, "and then the totals")
  end

  step "the worktree was deleted and making it again fails", context do
    %{path: path, root: root, branch: branch} = context.lost
    File.rm_rf!(path)
    World.git!(root, ~w(worktree prune))
    World.git!(root, ["switch", "-q", branch])
    context
  end

  step "the agent's turn ends", context do
    title = context.thread
    running = Enum.find(World.runs(context, title), &(&1["status"] == "running"))

    # The turn ends, it is not the user's Stop: a Stop holds the queue behind it.
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "threadId" => World.thread_id(context, title),
        "runId" => running["id"],
        "holdQueue" => false
      })

    context
  end

  step "the first queued message fails, saying the worktree could not be made and to resume the queue",
       context do
    [first, _] = context.queued
    state = World.await_thread(context, context.thread, &(run_status(&1, first) == "failed"))
    run = HalC2.StreamState.get(state, "run")[first]
    assert run["startedAt"] == nil
    item = await_error_item(World.thread_id(context, context.thread))
    assert item["title"] == "Worktree could not be made"
    assert item["failure"]["message"] =~ "Resume the queue to retry."
    refute item["failure"]["message"] =~ "Send the message again"
    context
  end

  step "the other one waits in the queue instead of starting", context do
    [_, second] = context.queued
    run = HalC2.StreamState.get(World.stream(context, context.thread), "run")[second]
    assert %{"status" => "queued", "queueHeld" => true} = run
    # Only the turn that was working ever reached the agent.
    assert length(World.codex_requests(context, "turn/start")) == 1
    context
  end

  step "it starts once the worktree can be made and the user resumes the queue", context do
    %{path: path, root: root} = context.lost
    [_, second] = context.queued
    World.git!(root, ~w(switch -q main))

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "queue.resume",
        "threadId" => World.thread_id(context, context.thread)
      })

    World.await_thread(context, context.thread, &(run_status(&1, second) == "completed"), 15_000)
    assert File.dir?(path)
    assert %{"cwd" => ^path} = List.last(World.codex_requests(context, "turn/start"))
    context
  end

  # --- helpers --------------------------------------------------------------------------------

  defp run_status(state, run_id), do: HalC2.StreamState.get(state, "run")[run_id]["status"]

  # A setup held in its checkout: a post-checkout hook keeps `git worktree add` open once
  # the files are on disk. `context.hook_pid` is the hook's.
  # A real worktree of the project on its own branch, with a commit of its own, whose
  # thread the user goes back to; `context.lost` names them.
  defp worked_in_worktree(context, title, branch) do
    root = World.project(context).root
    context = World.providers(context)

    context =
      World.create_thread(context, title, nil, %{
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"}
      })

    Mc.ensure(
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Vcs.Registry},
        id: HalC2.Vcs.Registry
      )
    )

    {:ok, %{"worktree" => %{"path" => path}}} =
      HalC2.Vcs.create_worktree(%{"cwd" => root, "refName" => "main", "newRefName" => branch})

    World.commit!(path, %{"cart.txt" => "cart\n"}, "cart totals")
    context = World.patch_thread(context, title, %{"worktreePath" => path, "branch" => branch})
    Map.merge(context, %{thread: title, lost: %{path: path, branch: branch, root: root}})
  end

  defp send_next(context, text) do
    selection = World.thread(context, context.thread)["modelSelection"]

    context
    |> World.command(
      World.message_command(context, context.thread, text, %{"modelSelection" => selection})
    )
    |> tap(&assert({:ok, _} = &1.reply, "message.dispatch failed: #{inspect(&1.reply)}"))
  end

  defp hold_checkout(context) do
    root = World.project(context).root
    {reader, _pipe} = checkout_hook(context, root)
    context = launch(context, "list the files")
    {out, 0} = Task.await(reader, 15_000)
    [pid, path] = String.split(String.trim(out), " ", parts: 2)
    ExUnit.Callbacks.on_exit(fn -> System.cmd("kill", [pid], stderr_to_stdout: true) end)

    {snapshot, context} =
      World.await_setup(context, &(World.setup_stage(&1, "checkout") == "running"))

    assert snapshot["phase"] == "running"
    assert File.dir?(path)
    Map.merge(context, %{worktree: %{path: path, root: root}, hook_pid: pid})
  end

  # The hook reports its pid and folder through a pipe; the task reads them.
  defp checkout_hook(context, root) do
    pipe = Path.join(Mc.tmp_dir(context.mc, "hook"), "checkout")
    {_, 0} = System.cmd("mkfifo", [pipe])
    hook = Path.join(root, ".git/hooks/post-checkout")
    File.write!(hook, "#!/bin/sh\necho \"$$ $(pwd)\" > '#{pipe}'\nexec sleep 600\n")
    File.chmod!(hook, 0o755)
    {Task.async(fn -> System.cmd("cat", [pipe]) end), pipe}
  end

  defp ending_script(context, title, command, code) do
    context |> put_setup(title, command, false) |> Map.put(:script_exit, code)
  end

  defp shows_expected_tail(context) do
    {snapshot, context} = World.await_setup(context, &(&1["phase"] != "running"))
    assert snapshot["phase"] == "done", inspect(snapshot)
    assert tail(snapshot) == context.expected_tail
    context
  end

  defp tail(snapshot), do: Enum.find(snapshot["stages"], &(&1["id"] == "setup-script"))["tail"]

  # The thread's error item once it has one, following its stream.
  defp await_error_item(id) do
    :ok = HalC2.Streams.subscribe(id, self(), nil)
    follow_error_item(id)
  end

  defp follow_error_item(id) do
    items =
      HalC2.StreamState.list(HalC2.Streams.Server.state(HalC2.Streams.ensure(id)), "turn-item")

    case Enum.find(items, & &1["failure"]) do
      nil ->
        receive do
          {:hal_c2_stream, ^id, _} -> follow_error_item(id)
        after
          15_000 -> flunk("no error item: #{inspect(items)}")
        end

      item ->
        item
    end
  end

  # A worktree folder `length` characters long: the start of `branch`, then a hash.
  defp assert_short_folder(path, branch, length) do
    name = Path.basename(path)
    assert String.length(name) == length
    assert [_, start, _hash] = Regex.run(~r/^(.+)-([0-9a-f]{8})$/u, name)
    assert String.starts_with?(String.replace(branch, "/", "-"), start)
    assert File.dir?(path)
  end

  # Pushes a new commit to `branch` of the bare repository `remote`; returns it.
  defp ahead(context, remote, branch) do
    clone = Path.join(Mc.tmp_dir(context.mc, "ahead"), "clone")
    World.git!(Path.dirname(clone), ["clone", "-q", "-b", branch, remote, clone])

    World.git!(
      clone,
      ~w(-c user.email=hal-c2@example.com -c user.name=HAL-C2 commit -q --allow-empty -m ahead)
    )

    World.git!(clone, ["push", "-q", "origin", branch])
    World.git!(clone, ~w(rev-parse HEAD))
  end

  # Takes `ref`'s lock in the repository at `root`, as a git command updating it does.
  defp hold_ref(root, ref) do
    git_dir = World.git!(root, ~w(rev-parse --path-format=absolute --git-common-dir))
    lock = Path.join(git_dir, ref <> ".lock")
    File.mkdir_p!(Path.dirname(lock))
    File.write!(lock, "")
    ExUnit.Callbacks.on_exit(fn -> File.rm(lock) end)
    lock
  end

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
    path = Path.join(Mc.tmp_dir(context.mc, "worktree"), String.replace(branch, "/", "-"))
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
  # Commits a hal-c2.json in `root` whose "Setup" runs `command` on new worktrees.
  defp commit_setup_file(root, command) do
    script = %{"name" => "Setup", "command" => command, "runOnWorktreeCreate" => true}
    File.write!(Path.join(root, "hal-c2.json"), JSON.encode!(%{"scripts" => [script]}))
    World.git!(root, ~w(add hal-c2.json))
    World.git!(root, ~w(commit -q -m hal-c2.json))
  end

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
      "mc" => Atom.to_string(node()),
      "threadId" => context.setup_thread
    }

    client = Mc.sub(World.client(context), id, shape)
    {frame, client} = Mc.await(client, &(&1["t"] == "worktreeSetup" and &1["id"] == id), 5_000)
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

  defp shell_startup(context, script) do
    path = Path.join(System.tmp_dir!(), "hal-c2-startup-#{System.unique_integer([:positive])}")
    File.write!(path, script)
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
    World.put_env("SHELL", "/bin/sh")
    World.put_env("ENV", path)
    context
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
    Mc.ensure(HalC2.Mcp)
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
