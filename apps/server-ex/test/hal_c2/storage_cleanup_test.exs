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

  # A changed policy sweeps inside StorageCleanup, after the put. A call queued behind
  # that message returns once the sweep is done, so the test does not race its git calls.
  defp settings(storage) do
    {_, version} = HalC2.Settings.get()
    {:ok, _} = HalC2.Settings.put(%{"storageCleanup" => storage}, version)
    _ = :sys.get_state(HalC2.StorageCleanup, :infinity)
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

    File.write!(Path.join(path, ".gitignore"), ".env\n")
    git(path, ~w(add .gitignore))
    git(path, ~w(-c user.name=t -c user.email=t@t commit -q -m ignore))
    File.write!(Path.join(path, ".env"), "SECRET=1\n")

    # The rule goes on last: its change sweeps at once, and a clean worktree would go.
    settings(%{"worktreeUnchanged" => true})
    assert File.exists?(path)

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

  test "an unknown local-changes choice keeps the most", %{repo: repo} do
    for choice <- ["uncommited", nil, 3] do
      settings = %{"storageCleanup" => %{"worktreeKeepWhen" => choice}}
      assert HalC2.StorageCleanup.rules(settings, "p1")["worktreeKeepWhen"] == "any-local-files"
    end

    settings(%{"worktreeOnDelete" => true, "worktreeKeepWhen" => "uncommited"})
    path = thread(repo, "th-6", %{"deletedAt" => "2026-01-02T00:00:00.000Z"})
    ignore(path, ".env")

    :ok = HalC2.StorageCleanup.sweep()
    assert File.read!(Path.join(path, ".env")) == "SECRET=1\n"
    assert kept(path) == "Has ignored files (.env)"
  end

  test "a failed effect does not hold a deleted thread's worktree", %{repo: repo} do
    settings(%{"worktreeOnDelete" => true})
    path = thread(repo, "th-7", %{"deletedAt" => "2026-01-02T00:00:00.000Z"})

    # A title that failed to generate, kept a week for diagnosis, one that waits, and
    # a cleanup that failed for good: none of them is the deletion still running.
    for {id, type, status} <- [
          {"e1", "thread-title.generate", "failed"},
          {"e2", "thread-title.generate", "pending"},
          {"e3", "attachment.cleanup", "failed"}
        ] do
      record = %{"id" => id, "threadId" => "th-7", "type" => type, "status" => status}
      :ok = HalC2.Store.put_meta("effect:th-7:#{id}", JSON.encode!(record))
    end

    :ok = HalC2.StorageCleanup.sweep()
    refute File.exists?(path)
  end

  test "a tracked edit made just before removal keeps everything in the worktree",
       %{repo: repo} do
    settings(%{"worktreeOnDelete" => true, "worktreeKeepWhen" => "tracked-changes"})
    path = thread(repo, "th-8", %{"deletedAt" => "2026-01-02T00:00:00.000Z"})
    ignore(path, ".env")
    File.write!(Path.join(path, "notes.txt"), "mine\n")
    hook({__MODULE__, :edit_at_removing, []})

    :ok = HalC2.StorageCleanup.sweep()
    assert kept(path) == "Has uncommitted changes (1 file)"
    assert File.read!(Path.join(path, ".env")) == "SECRET=1\n"
    assert File.read!(Path.join(path, "notes.txt")) == "mine\n"
  end

  test "an ignored file written just before removal keeps the worktree", %{repo: repo} do
    settings(%{"worktreeOnDelete" => true})
    path = thread(repo, "th-10", %{"deletedAt" => "2026-01-02T00:00:00.000Z"})
    ignore(path, ".env")
    File.rm!(Path.join(path, ".env"))
    hook({__MODULE__, :write_env_at_removing, []})

    # Git deletes ignored files with the worktree; only the last look sees this one.
    :ok = HalC2.StorageCleanup.sweep()
    assert kept(path) == "Has ignored files (.env)"
    assert File.read!(Path.join(path, ".env")) == "SECRET=1\n"
  end

  for choice <- ["uncommitted-changes", "tracked-changes"] do
    test "a repository nested in the worktree keeps it under #{choice}, cleaned of nothing",
         %{repo: repo} do
      settings(%{"worktreeOnDelete" => true, "worktreeKeepWhen" => unquote(choice)})
      path = thread(repo, "th-9", %{"deletedAt" => "2026-01-02T00:00:00.000Z"})
      ignore(path, ".env")

      # An ignored folder holding a repository with a commit nowhere else.
      nested = Path.join([path, "deps", "lib"])
      File.mkdir_p!(nested)
      File.write!(Path.join(path, ".gitignore"), ".env\ndeps/\n")
      git(path, ~w(-c user.name=t -c user.email=t@t commit -q -am deps))
      git(nested, ~w(init -q))
      File.write!(Path.join(nested, "work.txt"), "unpushed\n")
      git(nested, ~w(add .))
      git(nested, ~w(-c user.name=t -c user.email=t@t commit -q -m work))

      :ok = HalC2.StorageCleanup.sweep()
      assert kept(path) == "Has a nested repository (deps/)"
      assert File.read!(Path.join(path, ".env")) == "SECRET=1\n"
      assert File.read!(Path.join(nested, "work.txt")) == "unpushed\n"
    end
  end

  test "a tracked edit made between the clean and the removal keeps the worktree",
       %{repo: repo} do
    settings(%{"worktreeOnDelete" => true, "worktreeKeepWhen" => "tracked-changes"})
    path = thread(repo, "th-11", %{"deletedAt" => "2026-01-02T00:00:00.000Z"})
    File.write!(Path.join(path, "notes.txt"), "draft\n")
    hook({__MODULE__, :edit_at_cleaned, []})

    # Without the look after the clean, Git refuses the removal and the sweep fails.
    :ok = HalC2.StorageCleanup.sweep()
    assert kept(path) == "Has uncommitted changes (1 file)"
    assert File.read!(Path.join(path, "a.txt")) == "edit\n"
  end

  test "too many untracked entries to look through keep the worktree", %{repo: repo} do
    settings(%{"worktreeOnDelete" => true, "worktreeKeepWhen" => "uncommitted-changes"})
    path = thread(repo, "th-12", %{"deletedAt" => "2026-01-02T00:00:00.000Z"})
    ignore(path, "*.log")

    # Ignored files don't count under this choice, but the look for nested
    # repositories reads them all, past its 64 KB limit.
    for n <- 1..1200,
        do:
          File.write!(
            Path.join(path, "build-output-#{String.pad_leading("#{n}", 40, "0")}.log"),
            ""
          )

    :ok = HalC2.StorageCleanup.sweep()
    assert kept(path) == "Untracked files exceed the inspection limit"
  end

  @doc false
  def edit_at_cleaned(:cleaned, path), do: File.write!(Path.join(path, "a.txt"), "edit\n")
  def edit_at_cleaned(_stage, _path), do: :ok

  @doc false
  # The sweep's `:removing` stage, inside the lease: the agent edits a tracked file.
  def edit_at_removing(:removing, path), do: File.write!(Path.join(path, "a.txt"), "edit\n")
  def edit_at_removing(_stage, _path), do: :ok

  @doc false
  def write_env_at_removing(:removing, path),
    do: File.write!(Path.join(path, ".env"), "SECRET=1\n")

  def write_env_at_removing(_stage, _path), do: :ok

  defp hook(mfa) do
    Application.put_env(:hal_c2, :storage_cleanup_hook, mfa)
    on_exit(fn -> Application.delete_env(:hal_c2, :storage_cleanup_hook) end)
  end

  # An ignored `.env` with a secret in it, its ignore rule committed.
  defp ignore(path, name) do
    File.write!(Path.join(path, ".gitignore"), name <> "\n")
    git(path, ~w(add .gitignore))
    git(path, ~w(-c user.name=t -c user.email=t@t commit -q -m ignore))
    File.write!(Path.join(path, name), "SECRET=1\n")
  end

  defp kept(path) do
    path = Path.expand(path)
    entry = Enum.find(HalC2.StorageCleanup.report() || [], &(&1["path"] == path))
    assert %{"outcome" => "kept", "reason" => reason} = entry
    reason
  end
end
