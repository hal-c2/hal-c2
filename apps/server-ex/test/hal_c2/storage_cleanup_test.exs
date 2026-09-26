defmodule HalC2.StorageCleanupTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    Application.put_env(:hal_c2, :storage_cleanup_first_ms, nil)
    on_exit(fn -> Application.delete_env(:hal_c2, :storage_cleanup_first_ms) end)

    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)
    start_supervised!(HalC2.Settings)
    start_supervised!({Registry, keys: :unique, name: HalC2.Codex.Registry})
    start_supervised!({Registry, keys: :unique, name: HalC2.Claude.Registry}, id: :claude)
    start_supervised!({Registry, keys: :unique, name: HalC2.Acp.Registry}, id: :acp)
    start_supervised!({Registry, keys: :unique, name: HalC2.Vcs.Registry}, id: :vcs)
    start_supervised!(HalC2.StorageCleanup)

    # A clone, so the default branch is known (`origin/HEAD`).
    origin = Path.join(dir, "origin.git")
    seed = Path.join(dir, "seed")
    repo = Path.join(dir, "repo")
    git(dir, ~w(init -q --bare -b main) ++ [origin])
    git(dir, ~w(init -q -b main) ++ [seed])
    File.write!(Path.join(seed, "a.txt"), "a\n")
    git(seed, ~w(add .))
    git(seed, ~w(-c user.name=t -c user.email=t@t commit -q -m first))
    git(seed, ["push", "-q", origin, "main"])
    git(dir, ["clone", "-q", origin, repo])

    {:ok, _} =
      HalC2.Projects.mutate(%{
        "type" => "project.create",
        "projectId" => "p1",
        "title" => "Repo",
        "workspaceRoot" => repo
      })

    %{repo: repo}
  end

  defp git(cwd, args), do: {_, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)

  defp settings(storage) do
    {_, version} = HalC2.Settings.get()
    {:ok, _} = HalC2.Settings.put(%{"storageCleanup" => storage}, version)
  end

  # A thread on its own new worktree, branched from main.
  defp thread(repo, id, extra \\ %{}) do
    {:ok, %{"worktree" => %{"path" => path}}} =
      HalC2.Vcs.create_worktree(%{
        "cwd" => repo,
        "refName" => "main",
        "newRefName" => "hal-c2/#{id}"
      })

    :ok = HalC2.Shell.subscribe(self())

    {:ok, _} =
      HalC2.Streams.commit(id, :thread, [
        {"thread", id,
         %{
           "s" =>
             Map.merge(
               %{
                 "id" => id,
                 "projectId" => "p1",
                 "title" => id,
                 "branch" => "hal-c2/#{id}",
                 "worktreePath" => path,
                 "createdAt" => "2026-01-01T00:00:00.000Z"
               },
               extra
             )
         }}
      ])

    assert_receive {:hal_c2_shell, {:rows, _, [{^id, _}]}}, 2_000
    path
  end

  test "a worktree whose branch is already in main goes; one with changes stays", %{repo: repo} do
    settings(%{"worktreeUnchanged" => true})
    gone = thread(repo, "th-1")
    kept = thread(repo, "th-2")
    File.write!(Path.join(kept, "a.txt"), "changed\n")

    :ok = HalC2.StorageCleanup.sweep()

    refute File.exists?(gone)
    assert File.exists?(kept)
    # The thread keeps its branch, so the worktree can come back.
    assert {:ok, _} = HalC2.Git.ok(repo, ~w(rev-parse --verify hal-c2/th-1))
  end

  test "nothing goes without a rule, and ignored files other than dependencies keep a worktree",
       %{repo: repo} do
    path = thread(repo, "th-3")
    :ok = HalC2.StorageCleanup.sweep()
    assert File.exists?(path)

    settings(%{"worktreeUnchanged" => true})
    File.write!(Path.join(path, ".gitignore"), ".env\n")
    git(path, ~w(add .gitignore))
    git(path, ~w(-c user.name=t -c user.email=t@t commit -q -m ignore))
    File.write!(Path.join(path, ".env"), "SECRET=1\n")

    :ok = HalC2.StorageCleanup.sweep()
    assert File.exists?(path)
  end

  test "a deleted thread's worktree goes when that is the rule", %{repo: repo} do
    settings(%{"worktreeOnDelete" => true})
    path = thread(repo, "th-4", %{"deletedAt" => "2026-01-02T00:00:00.000Z"})

    :ok = HalC2.StorageCleanup.sweep()
    refute File.exists?(path)
  end

  test "a project can turn cleanup off for itself", %{repo: repo} do
    {_, version} = HalC2.Settings.get()

    {:ok, _} =
      HalC2.Settings.put(
        %{
          "storageCleanup" => %{"worktreeUnchanged" => true},
          "projectSettingsOverrides" => %{"p1" => %{"worktreeCleanup" => %{"mode" => "off"}}}
        },
        version
      )

    path = thread(repo, "th-5")
    :ok = HalC2.StorageCleanup.sweep()
    assert File.exists?(path)
  end
end
