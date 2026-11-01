defmodule HalC2.WorktreeSetupTest do
  use ExUnit.Case, async: false

  alias HalC2.{Orchestration, StreamState}

  @moduletag :tmp_dir
  @fake_codex Path.expand("../support/fake_codex.py", __DIR__)

  setup %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    git = &System.cmd("git", &1, cd: repo, stderr_to_stdout: true)
    {_, 0} = git.(~w(init -q -b main))
    {_, 0} = git.(~w(-c user.email=t@t -c user.name=t commit -q --allow-empty -m init))

    Application.put_env(:hal_c2, :home, Path.join(dir, "home"))
    Application.put_env(:hal_c2, :codex_command, ["python3", "-u", @fake_codex])
    on_exit(fn -> Application.delete_env(:hal_c2, :codex_command) end)

    start_supervised!(HalC2.Settings)
    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)
    start_supervised!(HalC2.Workspace)
    start_supervised!({Registry, keys: :unique, name: HalC2.Codex.Registry})
    start_supervised!({DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one})
    start_supervised!({Registry, keys: :unique, name: HalC2.Terminal.Registry}, id: :terminals)

    start_supervised!(
      {DynamicSupervisor, name: HalC2.Terminal.Supervisor, strategy: :one_for_one},
      id: :terminal_sup
    )

    start_supervised!(HalC2.Terminal.Hub)
    start_supervised!(HalC2.WorktreeSetup)

    :ok = HalC2.Shell.subscribe(self())
    %{repo: repo}
  end

  defp project(repo, scripts) do
    {:ok, _} =
      HalC2.Projects.mutate(%{
        "type" => "project.create",
        "projectId" => "p1",
        "workspaceRoot" => repo
      })

    assert_receive {:hal_c2_shell, {:rows, _, [{"p1", _}]}}, 1_000

    if scripts != [] do
      {:ok, _} =
        HalC2.Projects.mutate(%{
          "type" => "project.update",
          "projectId" => "p1",
          "scripts" => scripts
        })

      assert_receive {:hal_c2_shell, {:rows, _, [{"p1", {"project", %{"scripts" => [_ | _]}}}]}},
                     1_000
    end
  end

  defp launch(text, strategy \\ %{}) do
    thread_id = "thread-#{System.unique_integer([:positive])}"
    :ok = HalC2.WorktreeSetup.subscribe(thread_id, self()) |> then(fn _ -> :ok end)
    :ok = HalC2.Streams.subscribe(thread_id, self(), nil)

    {:ok, %{"threadId" => ^thread_id}} =
      Orchestration.launch_thread(launch_input(thread_id, text, strategy))

    thread_id
  end

  defp launch_input(thread_id, text, strategy) do
    %{
      "commandId" => "c",
      "threadId" => thread_id,
      "projectId" => "p1",
      "title" => "Work",
      "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
      "runtimeMode" => "full-access",
      "interactionMode" => "default",
      "workspaceStrategy" => Map.merge(%{"type" => "worktree", "baseRef" => "main"}, strategy),
      "initialMessage" => %{"messageId" => "m1", "text" => text, "attachments" => []}
    }
  end

  defp await_phase(thread_id, phase) do
    receive do
      {:hal_c2_worktree_setup, ^thread_id, %{"phase" => ^phase} = snapshot} -> snapshot
      {:hal_c2_worktree_setup, ^thread_id, _} -> await_phase(thread_id, phase)
    after
      15_000 -> flunk("setup never reached #{phase}")
    end
  end

  defp current(thread_id), do: HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))

  test "a thread in a new worktree runs its first turn there", %{repo: repo} do
    project(repo, [])
    thread_id = launch("list the files")
    snapshot = await_phase(thread_id, "done")

    assert %{"worktreePath" => path, "branch" => "hal-c2/" <> _} = snapshot
    assert File.dir?(path)

    assert Enum.map(snapshot["stages"], &{&1["id"], &1["status"]}) ==
             [
               {"fetch", "skipped"},
               {"checkout", "done"},
               {"setup-script", "skipped"},
               {"agent", "done"}
             ]

    state = await_completed(thread_id)
    assert %{"worktreePath" => ^path} = StreamState.get(state, "thread")[thread_id]
    assert [%{"status" => "completed"}] = StreamState.list(state, "run")
    assert [%{"cwd" => ^path}] = StreamState.list(state, "checkpoint-scope")
  end

  test "a launch retried after a reconnect while its worktree is prepared sends one message",
       %{repo: repo} do
    project(repo, [])
    thread_id = launch("list the files")

    # The client lost the answer and sends the same launch again, before the worktree
    # is ready.
    assert {:ok, %{"threadId" => ^thread_id, "resumed" => true}} =
             Orchestration.launch_thread(launch_input(thread_id, "list the files", %{}))

    await_phase(thread_id, "done")
    state = await_completed(thread_id)
    assert [%{"status" => "completed"}] = StreamState.list(state, "run")

    assert [%{"id" => "m1"}] =
             state |> StreamState.list("message") |> Enum.filter(&(&1["role"] == "user"))
  end

  test "a branch named hal-c2 does not stop a new worktree", %{repo: repo} do
    {_, 0} = System.cmd("git", ~w(branch hal-c2), cd: repo)
    project(repo, [])

    snapshot = launch("list the files") |> await_phase("done")
    assert snapshot["branch"] =~ ~r/^hal-c2-[0-9a-f]{8}$/
    assert HalC2.WorktreeSetup.temporary?(snapshot["branch"])

    # A client that names the temporary branch itself gets a free one instead.
    snapshot = launch("list the files", %{"branch" => "hal-c2/42a5d641"}) |> await_phase("done")
    assert snapshot["branch"] =~ ~r/^hal-c2-[0-9a-f]{8}$/
  end

  test "a client's temporary branch is kept when git can create it", %{repo: repo} do
    project(repo, [])
    snapshot = launch("list the files", %{"branch" => "hal-c2/42a5d641"}) |> await_phase("done")
    assert snapshot["branch"] == "hal-c2/42a5d641"
  end

  test "which branches sit on another's path" do
    assert HalC2.Git.branch_path_taken_by?(["hal-c2"], "hal-c2/42a5d641")
    assert HalC2.Git.branch_path_taken_by?(["hal-c2/pr-1/x"], "hal-c2")
    refute HalC2.Git.branch_path_taken_by?(["hal-c2"], "hal-c2")
    refute HalC2.Git.branch_path_taken_by?(["hal-c2-old", "hal-c2x/y"], "hal-c2/42a5d641")
    refute HalC2.Git.branch_path_taken_by?(["hal-c2/other"], "hal-c2/42a5d641")
  end

  # A thread's watchers went with their last pid, and kept the thread for no one.
  test "a thread's last watcher exiting leaves nothing kept for the thread" do
    server = Process.whereis(HalC2.WorktreeSetup)
    watcher = spawn(fn -> receive(do: (:never -> :ok)) end)
    HalC2.WorktreeSetup.subscribe("thread-gone", watcher, make_ref())

    # The trace of the server taking the `:DOWN` orders the read after it.
    :erlang.trace(server, true, [:receive])
    Process.exit(watcher, :kill)
    assert_receive {:trace, ^server, :receive, {:DOWN, _, :process, ^watcher, _}}, 5_000
    :erlang.trace(server, false, [:receive])

    refute Map.has_key?(:sys.get_state(server).watchers, "thread-gone")
  end

  test "a blocking setup script runs in the worktree before the agent", %{repo: repo} do
    project(repo, [
      %{
        "id" => "setup",
        "name" => "Setup",
        "command" => ~s(echo "$HAL_C2_PROJECT_ROOT $HAL_C2_WORKTREE_PATH" > setup.txt),
        "icon" => "configure",
        "runOnWorktreeCreate" => true,
        "async" => false
      }
    ])

    thread_id = launch("list the files")
    snapshot = await_phase(thread_id, "done")

    assert %{"status" => "done", "detail" => "exited with 0"} =
             Enum.find(snapshot["stages"], &(&1["id"] == "setup-script"))

    path = snapshot["worktreePath"]
    assert File.read!(Path.join(path, "setup.txt")) == "#{repo} #{path}\n"
  end

  # The repository's own hal-c2.json lists a PowerShell variant after the POSIX one.
  @project_file JSON.encode!(%{
                  "scripts" => [
                    %{"name" => "Dev", "command" => "echo dev"},
                    %{
                      "name" => " Setup Worktree ",
                      "command" => "echo file > setup.txt",
                      "runOnWorktreeCreate" => true,
                      "async" => false
                    },
                    %{
                      "name" => "Setup Worktree (Windows)",
                      "command" => "New-Item -ItemType File -Path setup.txt",
                      "runOnWorktreeCreate" => true
                    }
                  ]
                })

  test "a new worktree runs the setup script its hal-c2.json marks", %{repo: repo} do
    commit(repo, "hal-c2.json", @project_file)
    project(repo, [])

    snapshot = launch("list the files") |> await_phase("done")

    assert %{"status" => "done", "detail" => "exited with 0"} =
             Enum.find(snapshot["stages"], &(&1["id"] == "setup-script"))

    assert %{"name" => "Setup Worktree", "command" => "echo file > setup.txt"} =
             snapshot["setupScript"]

    assert File.read!(Path.join(snapshot["worktreePath"], "setup.txt")) == "file\n"
  end

  test "a saved setup script wins over hal-c2.json", %{repo: repo} do
    commit(repo, "hal-c2.json", @project_file)

    project(repo, [
      %{
        "id" => "setup",
        "name" => "Setup",
        "command" => "echo saved > setup.txt",
        "icon" => "configure",
        "runOnWorktreeCreate" => true,
        "async" => false
      }
    ])

    snapshot = launch("list the files") |> await_phase("done")
    assert File.read!(Path.join(snapshot["worktreePath"], "setup.txt")) == "saved\n"
  end

  test "hal-c2.json is read from the new worktree, not the project folder", %{repo: repo} do
    File.write!(Path.join(repo, "hal-c2.json"), @project_file)
    project(repo, [])

    snapshot = launch("list the files") |> await_phase("done")
    assert %{"status" => "skipped"} = Enum.find(snapshot["stages"], &(&1["id"] == "setup-script"))
  end

  test "a malformed hal-c2.json runs no setup script", %{repo: repo} do
    commit(
      repo,
      "hal-c2.json",
      ~s({"scripts": [{"name": "Setup", "command": "echo file > setup.txt", "runOnWorktreeCreate": true})
    )

    project(repo, [])

    snapshot = launch("list the files") |> await_phase("done")
    assert %{"status" => "skipped"} = Enum.find(snapshot["stages"], &(&1["id"] == "setup-script"))
    refute File.exists?(Path.join(snapshot["worktreePath"], "setup.txt"))

    assert [%{"status" => "completed"}] =
             await_completed(snapshot["threadId"]) |> StreamState.list("run")
  end

  test "a branch's changed setup script is not run", %{repo: repo} do
    commit(repo, "hal-c2.json", @project_file)

    changed =
      String.replace(@project_file, "echo file > setup.txt", "echo branch > setup.txt")

    commit_on(repo, "contrib", "hal-c2.json", changed)
    project(repo, [])

    snapshot = launch("list the files", %{"baseRef" => "contrib"}) |> await_phase("done")
    assert_untrusted(snapshot)
  end

  test "a setup script only a branch's hal-c2.json has is not run", %{repo: repo} do
    commit_on(repo, "contrib", "hal-c2.json", @project_file)
    project(repo, [])

    snapshot = launch("list the files", %{"baseRef" => "contrib"}) |> await_phase("done")
    assert_untrusted(snapshot)
  end

  defp assert_untrusted(snapshot) do
    assert %{
             "status" => "skipped",
             "detail" =>
               "this branch's hal-c2.json setup script differs from the main checkout's, so it was not run"
           } = Enum.find(snapshot["stages"], &(&1["id"] == "setup-script"))

    refute File.exists?(Path.join(snapshot["worktreePath"], "setup.txt"))

    assert [%{"status" => "completed"}] =
             await_completed(snapshot["threadId"]) |> StreamState.list("run")
  end

  test "which setup script a new worktree runs", %{tmp_dir: dir} do
    [root, worktree] = for name <- ~w(root checkout), do: Path.join(dir, name)
    File.mkdir_p!(root)
    File.mkdir_p!(worktree)
    setup = &HalC2.WorktreeSetup.setup_script(%{"id" => "p1", "scripts" => &1}, root, worktree)
    marked = &%{"name" => &1, "command" => "echo #{&1}", "runOnWorktreeCreate" => true}
    both = &for(dir <- [root, worktree], do: File.write!(Path.join(dir, &1), &2))

    assert setup.([]) == :none

    # The legacy t3.json, with comments and a trailing comma as the clients allow.
    both.("t3.json", """
    // shared with the team
    {"scripts": [{"name": "Old", "command": "echo old", "runOnWorktreeCreate": true},]}
    """)

    assert {:run, %{"name" => "Old"}} = setup.([])

    both.("hal-c2.json", @project_file)
    assert {:run, %{"name" => "Setup Worktree"}} = setup.([])

    # Saved actions without a setup script leave it to the file.
    assert {:run, %{"name" => "Setup Worktree"}} =
             setup.([%{"name" => "Dev", "command" => "echo dev"}])

    assert {:run, %{"name" => "Saved"}} = setup.([marked.("Saved")])

    # The main checkout's file vouches for the branch's script: the same command,
    # blocking the same way, under any name or place in the list.
    vouch = fn scripts ->
      File.write!(Path.join(root, "hal-c2.json"), JSON.encode!(%{"scripts" => scripts}))
      setup.([])
    end

    script = %{"command" => "echo file > setup.txt", "runOnWorktreeCreate" => true}
    async = Map.put(script, "async", true)

    assert {:run, %{"name" => "Setup Worktree"}} =
             vouch.([marked.("A"), Map.merge(script, %{"name" => "Other", "async" => false})])

    for untrusted <- [[], [Map.put(script, "name", "x")], [Map.put(async, "name", "x")]],
        do: assert({:skip, "this branch's" <> _} = vouch.(untrusted))

    assert {:skip, _} =
             vouch.([%{"name" => "x", "command" => "echo file > setup.txt", "async" => false}])

    File.rm!(Path.join(root, "hal-c2.json"))
    File.rm!(Path.join(root, "t3.json"))
    assert {:skip, _} = setup.([])
    assert {:run, %{"name" => "Saved"}} = setup.([marked.("Saved")])
    File.rm!(Path.join(worktree, "hal-c2.json"))
    File.rm!(Path.join(worktree, "t3.json"))

    # A project's own list in settings, then the environment's defaults, count as saved.
    {_, version} = HalC2.Settings.get()

    {:ok, version} =
      HalC2.Settings.put(%{"defaultProjectScripts" => [marked.("Default")]}, version)

    assert {:run, %{"name" => "Default"}} = setup.([])
    assert {:run, %{"name" => "Saved"}} = setup.([marked.("Saved")])

    # Until the legacy fields are folded, the old map comes before the row's scripts;
    # null there meant the defaults.
    {:ok, version} =
      HalC2.Settings.put(
        %{
          "defaultProjectScripts" => [marked.("Default")],
          "projectScriptOverrides" => %{"p1" => [marked.("Legacy")]}
        },
        version
      )

    assert {:run, %{"name" => "Legacy"}} = setup.([marked.("Saved")])

    {:ok, version} =
      HalC2.Settings.put(
        %{
          "defaultProjectScripts" => [marked.("Default")],
          "projectScriptOverrides" => %{"p1" => nil}
        },
        version
      )

    assert {:run, %{"name" => "Default"}} = setup.([marked.("Saved")])

    {:ok, version} =
      HalC2.Settings.put(
        %{
          "defaultProjectScripts" => [marked.("Default")],
          "projectScriptOverrides" => %{"p1" => [marked.("Legacy")]},
          "projectSettingsFolded" => true
        },
        version
      )

    assert {:run, %{"name" => "Default"}} = setup.([marked.("Saved")])

    {:ok, _} =
      HalC2.Settings.put(
        %{
          "defaultProjectScripts" => [marked.("Default")],
          "projectScriptOverrides" => %{"p1" => [marked.("Legacy")]},
          "projectSettingsOverrides" => %{"p1" => %{"defaultProjectScripts" => [marked.("Own")]}}
        },
        version
      )

    assert {:run, %{"name" => "Own"}} = setup.([marked.("Saved")])

    # A file that does not match the format declares nothing, scripts included.
    for bad <- [
          ~s({"scripts": [{"name": "Setup", "command": "  ", "runOnWorktreeCreate": true}]}),
          ~s({"iconPath": 3, "scripts": [{"name": "Setup", "command": "x", "runOnWorktreeCreate": true}]}),
          ~s({"scripts": [{"name": "Setup", "command": "x", "icon": "rocket", "runOnWorktreeCreate": true}]}),
          ~s({"scripts": [{"name": "Setup", "command": "x", "runOnWorktreeCreate": "yes"}]}),
          ~s([])
        ] do
      assert HalC2.ProjectFile.parse(bad) == :error
    end
  end

  test "cancelling setup removes the worktree and cancels the run", %{repo: repo} do
    project(repo, [
      %{
        "id" => "slow",
        "name" => "Slow",
        "command" => "sleep 30",
        "icon" => "configure",
        "runOnWorktreeCreate" => true,
        "async" => false
      }
    ])

    thread_id = launch("list the files")
    %{"worktreePath" => path} = await_running_script(thread_id)

    assert {:ok, %{"cancelled" => true}} = HalC2.WorktreeSetup.cancel(%{"threadId" => thread_id})
    await_phase(thread_id, "cancelled")
    refute File.exists?(path)

    state = current(thread_id)
    assert [%{"status" => "cancelled"}] = StreamState.list(state, "run")
    assert %{"worktreePath" => nil} = StreamState.get(state, "thread")[thread_id]
  end

  test "the server answers others while a cancel removes the worktree", %{
    repo: repo,
    tmp_dir: dir
  } do
    project(repo, [
      %{
        "id" => "slow",
        "name" => "Slow",
        "command" => "sleep 30",
        "icon" => "configure",
        "runOnWorktreeCreate" => true,
        "async" => false
      }
    ])

    thread_id = launch("list the files")
    await_running_script(thread_id)

    [started, hold] = for name <- ~w(started hold), do: Path.join(dir, name)
    for pipe <- [started, hold], do: {_, 0} = System.cmd("mkfifo", [pipe])
    git = Path.join(dir, "git-holds")

    File.write!(git, """
    #!/bin/sh
    case "$*" in *"worktree remove"*) echo > "#{started}"; cat "#{hold}" > /dev/null;; esac
    exec git "$@"
    """)

    File.chmod!(git, 0o755)
    Application.put_env(:hal_c2, :git_command, git)
    on_exit(fn -> Application.delete_env(:hal_c2, :git_command) end)

    cancel = Task.async(fn -> HalC2.WorktreeSetup.cancel(%{"threadId" => thread_id}) end)
    {_, 0} = System.cmd("cat", [started])
    assert %{setups: _} = :sys.get_state(HalC2.WorktreeSetup, 2_000)

    # A second click while it goes ahead is not told the cancel failed.
    assert {:ok, %{"cancelled" => true}} = HalC2.WorktreeSetup.cancel(%{"threadId" => thread_id})

    {_, 0} = System.cmd("sh", ["-c", "echo go > \"$0\"", hold])
    assert {:ok, %{"cancelled" => true}} = Task.await(cancel, 30_000)
  end

  test "a terminal that will not close does not stop the cleanup", %{repo: repo} do
    project(repo, [
      %{
        "id" => "slow",
        "name" => "Slow",
        "command" => "sleep 30",
        "icon" => "configure",
        "runOnWorktreeCreate" => true,
        "async" => false
      }
    ])

    thread_id = launch("list the files")
    %{"worktreePath" => path} = await_running_script(thread_id)

    # A terminal that does not answer makes closing it exit.
    [{terminal, _}] = Registry.lookup(HalC2.Terminal.Registry, {thread_id, "setup"})
    :sys.suspend(terminal)
    assert {:ok, %{"cancelled" => true}} = HalC2.WorktreeSetup.cancel(%{"threadId" => thread_id})
    await_phase(thread_id, "cancelled")
    refute File.exists?(path)

    state = current(thread_id)
    assert [%{"status" => "cancelled"}] = StreamState.list(state, "run")
    assert %{"worktreePath" => nil} = StreamState.get(state, "thread")[thread_id]
  end

  # Commits `file` on a new `branch` off main, leaving the checkout on main.
  defp commit_on(repo, branch, file, contents) do
    {_, 0} = System.cmd("git", ~w(checkout -q -b) ++ [branch], cd: repo)
    commit(repo, file, contents)
    {_, 0} = System.cmd("git", ~w(checkout -q main), cd: repo)
  end

  defp commit(repo, file, contents) do
    File.write!(Path.join(repo, file), contents)
    {_, 0} = System.cmd("git", ["add", file], cd: repo)

    {_, 0} =
      System.cmd("git", ~w(-c user.email=t@t -c user.name=t commit -q -m) ++ [file], cd: repo)
  end

  defp await_running_script(thread_id) do
    receive do
      {:hal_c2_worktree_setup, ^thread_id, %{"setupScript" => %{}} = snapshot} -> snapshot
      {:hal_c2_worktree_setup, ^thread_id, _} -> await_running_script(thread_id)
    after
      15_000 -> flunk("the setup script never started")
    end
  end

  defp await_completed(thread_id) do
    state = current(thread_id)

    if match?([%{"status" => "completed"}], StreamState.list(state, "run")) do
      state
    else
      receive do
        {:hal_c2_stream, ^thread_id, _} -> await_completed(thread_id)
      after
        15_000 -> flunk("the run never completed")
      end
    end
  end

  test "a finished setup is gone once its half minute is up" do
    alias HalC2.WorktreeSetup

    Application.put_env(:hal_c2, :worktree_setup_retention, 10)
    on_exit(fn -> Application.delete_env(:hal_c2, :worktree_setup_retention) end)

    :sys.replace_state(WorktreeSetup, fn state ->
      snapshot = %{"phase" => "running", "sequence" => 3, "stages" => []}
      put_in(state.setups["t"], %{snapshot: snapshot, cancellable: true, superseded: false})
    end)

    assert %{"phase" => "running"} = WorktreeSetup.subscribe("t", self())
    :ok = GenServer.call(WorktreeSetup, {:update, "t", &WorktreeSetup.finish(&1, "done", nil)})
    assert_receive {:hal_c2_worktree_setup, "t", %{"phase" => "done"}}
    assert_receive {:hal_c2_worktree_setup, "t", nil}, 1_000
    assert WorktreeSetup.subscribe("t", self()) == nil
  end

  test "a real shell runs a multi-line script given as its argument" do
    for shell <- ~w(/bin/sh /bin/bash /bin/zsh), File.exists?(shell) do
      line = HalC2.WorktreeSetup.wrap_script("echo one\r\n# two\necho three", shell, "END_")
      refute line =~ "\r"
      {out, _} = System.cmd(shell, ["-c", line])
      assert out =~ "one\nthree\n"
      assert out =~ "END_0\n"
    end
  end

  defp blocking_setup(repo, command) do
    project(repo, [
      %{
        "id" => "setup",
        "name" => "Setup",
        "command" => command,
        "icon" => "configure",
        "runOnWorktreeCreate" => true,
        "async" => false
      }
    ])
  end

  test "a retry that fails again can be retried, and keeps no expiry", %{repo: repo} do
    blocking_setup(repo, ~S(test -e "$HAL_C2_PROJECT_ROOT/.pass"))
    Application.put_env(:hal_c2, :worktree_setup_retention, 50)
    on_exit(fn -> Application.delete_env(:hal_c2, :worktree_setup_retention) end)

    thread_id = launch("list the files")
    %{"worktreePath" => path} = await_phase(thread_id, "failed")

    assert {:ok, %{"retried" => true}} = HalC2.WorktreeSetup.retry(%{"threadId" => thread_id})
    assert %{"worktreePath" => ^path} = await_phase(thread_id, "failed")
    refute Map.has_key?(:sys.get_state(HalC2.WorktreeSetup).setups[thread_id], :expiry)

    File.write!(Path.join(repo, ".pass"), "")
    assert {:ok, %{"retried" => true}} = HalC2.WorktreeSetup.retry(%{"threadId" => thread_id})
    assert %{"worktreePath" => ^path} = await_phase(thread_id, "done")
  end

  test "a retry runs the script as it is saved now", %{repo: repo} do
    script = %{
      "id" => "setup",
      "name" => "Setup",
      "icon" => "configure",
      "runOnWorktreeCreate" => true,
      "async" => false
    }

    project(repo, [Map.put(script, "command", "exit 3")])
    thread_id = launch("list the files")
    await_phase(thread_id, "failed")

    {:ok, _} =
      HalC2.Projects.mutate(%{
        "type" => "project.update",
        "projectId" => "p1",
        "scripts" => [Map.put(script, "command", "echo fixed > corrected.txt")]
      })

    assert_receive {:hal_c2_shell,
                    {:rows, _,
                     [
                       {"p1",
                        {"project",
                         %{"scripts" => [%{"command" => "echo fixed > corrected.txt"}]}}}
                     ]}},
                   1_000

    assert {:ok, %{"retried" => true}} = HalC2.WorktreeSetup.retry(%{"threadId" => thread_id})
    %{"worktreePath" => path} = await_phase(thread_id, "done")
    assert File.read!(Path.join(path, "corrected.txt")) == "fixed\n"
  end

  test "a retry for a script since removed runs none", %{repo: repo} do
    blocking_setup(repo, "exit 3")
    thread_id = launch("list the files")
    await_phase(thread_id, "failed")

    {:ok, _} =
      HalC2.Projects.mutate(%{
        "type" => "project.update",
        "projectId" => "p1",
        "scripts" => []
      })

    assert_receive {:hal_c2_shell, {:rows, _, [{"p1", {"project", %{"scripts" => []}}}]}}, 1_000

    assert {:ok, %{"retried" => true}} = HalC2.WorktreeSetup.retry(%{"threadId" => thread_id})
    assert %{"setupScript" => nil} = await_phase(thread_id, "done")
  end

  test "a retry can be cancelled, which removes the worktree", %{repo: repo} do
    blocking_setup(repo, ~S(test -e "$HAL_C2_PROJECT_ROOT/.pass" && sleep 30))
    thread_id = launch("list the files")
    %{"worktreePath" => path} = await_phase(thread_id, "failed")

    File.write!(Path.join(repo, ".pass"), "")
    assert {:ok, %{"retried" => true}} = HalC2.WorktreeSetup.retry(%{"threadId" => thread_id})
    assert {:ok, %{"cancelled" => true}} = HalC2.WorktreeSetup.cancel(%{"threadId" => thread_id})
    await_phase(thread_id, "cancelled")

    refute File.exists?(path)
    assert [%{"status" => "cancelled"}] = StreamState.list(current(thread_id), "run")
  end

  test "retrying a failed checkout makes the worktree", %{repo: repo} do
    project(repo, [])
    thread_id = launch("list the files", %{"baseRef" => "later"})
    assert %{"worktreePath" => nil} = await_phase(thread_id, "failed")

    {_, 0} = System.cmd("git", ~w(branch later), cd: repo)
    assert {:ok, %{"retried" => true}} = HalC2.WorktreeSetup.retry(%{"threadId" => thread_id})
    assert %{"worktreePath" => path} = await_phase(thread_id, "done")
    assert File.dir?(path)
  end

  test "deleting a thread forgets its failed setup", %{repo: repo} do
    blocking_setup(repo, "exit 3")
    thread_id = launch("list the files")
    await_phase(thread_id, "failed")

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.delete",
        "commandId" => "delete",
        "threadId" => thread_id
      })

    assert_receive {:hal_c2_worktree_setup, ^thread_id, nil}, 5_000
  end

  test "a hot reload keeps a setup running through it working" do
    setup = %{snapshot: %{"phase" => "running"}}

    {:ok, %{setups: %{"t" => %{superseded: false}}}} =
      HalC2.WorktreeSetup.code_change(nil, %{setups: %{"t" => setup}, watchers: %{}}, nil)
  end

  test "a setup whose thread was deleted while it ran is not kept for a retry", %{repo: repo} do
    blocking_setup(
      repo,
      ~S(until test -e "$HAL_C2_PROJECT_ROOT/.fail"; do sleep 0.05; done; exit 3)
    )

    Application.put_env(:hal_c2, :worktree_setup_retention, 3_600_000)
    on_exit(fn -> Application.delete_env(:hal_c2, :worktree_setup_retention) end)
    thread_id = launch("list the files")

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.delete",
        "commandId" => "delete",
        "threadId" => thread_id
      })

    assert %{superseded: true} = :sys.get_state(HalC2.WorktreeSetup).setups[thread_id]
    File.write!(Path.join(repo, ".fail"), "")
    await_phase(thread_id, "failed")

    assert %{expiry: _} = :sys.get_state(HalC2.WorktreeSetup).setups[thread_id]
    assert {:ok, %{"retried" => false}} = HalC2.WorktreeSetup.retry(%{"threadId" => thread_id})
  end

  test "a retry after a follow-up is refused and leaves the worktree alone", %{repo: repo} do
    project(repo, [
      %{
        "id" => "setup",
        "name" => "Setup",
        "command" => "exit 3",
        "icon" => "configure",
        "runOnWorktreeCreate" => true,
        "async" => false
      }
    ])

    thread_id = launch("list the files")
    %{"worktreePath" => path} = await_phase(thread_id, "failed")

    # The second run alone is enough to refuse, however the setup came to be still tracked.
    {:ok, _} =
      HalC2.Streams.transact(thread_id, :thread, fn state ->
        run = hd(StreamState.list(state, "run"))
        {[{"run", "later", %{"s" => %{run | "id" => "later"}}}], {:ok, nil}}
      end)

    assert {:ok, %{"retried" => false}} = HalC2.WorktreeSetup.retry(%{"threadId" => thread_id})
    assert File.dir?(path)
  end

  # An interactive zsh runs `#` as a command unless told otherwise before it reads the line.
  test "a script may end in a comment in every shell" do
    for shell <- ~w(/bin/sh /bin/bash /bin/zsh), File.exists?(shell) do
      line = HalC2.WorktreeSetup.wrap_script("(exit 4)\n# done", shell, "END_")
      {out, _} = System.cmd(shell, ["-c", String.replace(line, "\r", "\n")])
      assert out =~ "END_start\n"
      assert out =~ "END_4\n"
    end
  end

  test "a script's syntax error is its exit status, and the end still comes" do
    for shell <- ~w(/bin/sh /bin/bash /bin/zsh), File.exists?(shell) do
      line =
        HalC2.WorktreeSetup.wrap_script("echo a\nif true; then echo b; fi; fi", shell, "END_")

      {out, _} =
        System.cmd(shell, ["-c", String.replace(line, "\r", "\n")], stderr_to_stdout: true)

      assert out =~ "END_start\n"
      assert [_, status] = Regex.run(~r/END_(\d+)\n/, out)
      assert status != "0"
    end
  end

  test "a script's quotes and exit stay its own" do
    for shell <- ~w(/bin/sh /bin/bash /bin/zsh), File.exists?(shell) do
      line = HalC2.WorktreeSetup.wrap_script(~S(echo 'it'"'"'s' "a\\b"; exit 6), shell, "END_")
      {out, _} = System.cmd(shell, ["-c", String.replace(line, "\r", "\n")])
      assert out =~ "it's"
      assert out =~ "END_6\n"
    end
  end

  test "fish runs the script in a new fish, its quotes kept" do
    line = HalC2.WorktreeSetup.wrap_script(~S(echo 'a\b'; exit 6), "/usr/bin/fish", "END_")
    assert line =~ ~S(/usr/bin/fish -c 'echo \'a\\b\'; exit 6'; printf)
  end
end
