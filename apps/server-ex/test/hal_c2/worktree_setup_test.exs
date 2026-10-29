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
        "command" => "echo ready > setup.txt",
        "icon" => "configure",
        "runOnWorktreeCreate" => true,
        "async" => false
      }
    ])

    thread_id = launch("list the files")
    snapshot = await_phase(thread_id, "done")

    assert %{"status" => "done", "detail" => "exited with 0"} =
             Enum.find(snapshot["stages"], &(&1["id"] == "setup-script"))

    assert File.read!(Path.join(snapshot["worktreePath"], "setup.txt")) == "ready\n"
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

  test "which setup script a new worktree runs", %{tmp_dir: dir} do
    worktree = Path.join(dir, "checkout")
    File.mkdir_p!(worktree)
    setup = &HalC2.WorktreeSetup.setup_script(%{"id" => "p1", "scripts" => &1}, worktree)
    marked = &%{"name" => &1, "command" => "echo #{&1}", "runOnWorktreeCreate" => true}

    assert setup.([]) == nil

    # The legacy t3.json, with comments and a trailing comma as the clients allow.
    File.write!(Path.join(worktree, "t3.json"), """
    // shared with the team
    {"scripts": [{"name": "Old", "command": "echo old", "runOnWorktreeCreate": true},]}
    """)

    assert %{"name" => "Old"} = setup.([])

    File.write!(Path.join(worktree, "hal-c2.json"), @project_file)
    assert %{"name" => "Setup Worktree"} = setup.([])

    # Saved actions without a setup script leave it to the file.
    assert %{"name" => "Setup Worktree"} = setup.([%{"name" => "Dev", "command" => "echo dev"}])
    assert %{"name" => "Saved"} = setup.([marked.("Saved")])

    # A project's own list in settings, then the environment's defaults, count as saved.
    {_, version} = HalC2.Settings.get()

    {:ok, version} =
      HalC2.Settings.put(%{"defaultProjectScripts" => [marked.("Default")]}, version)

    assert %{"name" => "Default"} = setup.([])
    assert %{"name" => "Saved"} = setup.([marked.("Saved")])

    {:ok, _} =
      HalC2.Settings.put(
        %{
          "defaultProjectScripts" => [marked.("Default")],
          "projectSettingsOverrides" => %{"p1" => %{"defaultProjectScripts" => [marked.("Own")]}}
        },
        version
      )

    assert %{"name" => "Own"} = setup.([marked.("Saved")])

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
end
