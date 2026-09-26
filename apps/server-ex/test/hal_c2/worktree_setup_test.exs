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

    assert_receive {:halc2_shell, {:rows, _, [{"p1", _}]}}, 1_000

    if scripts != [] do
      {:ok, _} =
        HalC2.Projects.mutate(%{
          "type" => "project.update",
          "projectId" => "p1",
          "scripts" => scripts
        })

      assert_receive {:halc2_shell, {:rows, _, [{"p1", {"project", %{"scripts" => [_ | _]}}}]}},
                     1_000
    end
  end

  defp launch(text) do
    thread_id = "thread-#{System.unique_integer([:positive])}"
    :ok = HalC2.WorktreeSetup.subscribe(thread_id, self()) |> then(fn _ -> :ok end)
    :ok = HalC2.Streams.subscribe(thread_id, self(), nil)

    {:ok, %{"threadId" => ^thread_id}} =
      Orchestration.launch_thread(%{
        "commandId" => "c",
        "threadId" => thread_id,
        "projectId" => "p1",
        "title" => "Work",
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "workspaceStrategy" => %{"type" => "worktree", "baseRef" => "main"},
        "initialMessage" => %{"messageId" => "m1", "text" => text, "attachments" => []}
      })

    thread_id
  end

  defp await_phase(thread_id, phase) do
    receive do
      {:halc2_worktree_setup, ^thread_id, %{"phase" => ^phase} = snapshot} -> snapshot
      {:halc2_worktree_setup, ^thread_id, _} -> await_phase(thread_id, phase)
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

  defp await_running_script(thread_id) do
    receive do
      {:halc2_worktree_setup, ^thread_id, %{"setupScript" => %{}} = snapshot} -> snapshot
      {:halc2_worktree_setup, ^thread_id, _} -> await_running_script(thread_id)
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
        {:halc2_stream, ^thread_id, _} -> await_completed(thread_id)
      after
        15_000 -> flunk("the run never completed")
      end
    end
  end
end
