defmodule HalC2.VcsTest do
  use ExUnit.Case, async: false

  alias HalC2.Vcs

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, Path.join(dir, "home"))
    start_supervised!({Registry, keys: :unique, name: HalC2.Vcs.Registry})
    start_supervised!({DynamicSupervisor, name: HalC2.Vcs.Supervisor, strategy: :one_for_one})

    origin = Path.join(dir, "origin.git")
    repo = Path.join(dir, "repo")
    other = Path.join(dir, "other")
    git!(dir, ["init", "-q", "--bare", "-b", "main", origin])
    git!(dir, ["clone", "-q", origin, repo])
    File.write!(Path.join(repo, "a.txt"), "one\n")
    git!(repo, ~w(add a.txt))
    commit!(repo, "init")
    git!(repo, ~w(push -q -u origin main))
    git!(repo, ~w(remote set-head origin main))
    git!(dir, ["clone", "-q", origin, other])
    %{repo: repo, other: other}
  end

  # An untracked text file counts its lines as inserted, as a staged one does.
  test "local status lists every change with its line counts", %{repo: repo} do
    File.write!(Path.join(repo, "a.txt"), "one\ntwo\n")
    File.write!(Path.join(repo, "staged.txt"), "s\n")
    git!(repo, ~w(add staged.txt))
    File.write!(Path.join(repo, "new file.txt"), "n\n")

    assert %{
             "isRepo" => true,
             "refName" => "main",
             "isDefaultRef" => true,
             "hasPrimaryRemote" => true,
             "hasWorkingTreeChanges" => true,
             "workingTree" => %{"files" => files, "insertions" => 3, "deletions" => 0}
           } = Vcs.local_status(repo)

    assert Enum.map(files, &{&1["path"], &1["insertions"]}) == [
             {"a.txt", 1},
             {"new file.txt", 1},
             {"staged.txt", 1}
           ]

    # The tmp dir sits inside this checkout, so use the system temp dir.
    plain =
      Path.join(System.tmp_dir!(), "hal-c2-not-a-repo-#{System.unique_integer([:positive])}")

    File.mkdir_p!(plain)
    on_exit(fn -> File.rm_rf!(plain) end)
    assert %{"isRepo" => false} = Vcs.local_status(plain)
  end

  test "a locked index leaves the checkout a repository, and the watcher's first snapshot too",
       %{repo: repo} do
    File.write!(Path.join(repo, ".git/index.lock"), "")

    assert %{"isRepo" => true, "refName" => "main"} = Vcs.local_status(repo)
    assert {:error, "Git index is locked" <> _} = Vcs.read_status(repo)

    assert %{"_tag" => "snapshot", "local" => %{"isRepo" => true, "refName" => "main"}} =
             HalC2.Vcs.Watch.subscribe(repo, self())
  end

  test "untracked files are read only up to a budget", %{repo: repo} do
    for n <- 1..520,
        do: File.write!(Path.join(repo, "u#{String.pad_leading("#{n}", 3, "0")}.txt"), "x\n")

    assert %{"workingTree" => %{"files" => files, "insertions" => 500}} = Vcs.local_status(repo)
    assert length(files) == 520
    assert Enum.count(files, &(&1["insertions"] == 0)) == 20
  end

  test "binary files spend the untracked budget as text files do", %{repo: repo} do
    for n <- 1..520,
        do: File.write!(Path.join(repo, "b#{String.pad_leading("#{n}", 3, "0")}.bin"), <<0, 1>>)

    File.write!(Path.join(repo, "z-text.txt"), "x\n")

    assert %{"workingTree" => %{"insertions" => 0}} = Vcs.local_status(repo)
  end

  test "a pull request found late does not roll back newer counts", %{repo: repo} do
    HalC2.Vcs.Watch.subscribe(repo, self())
    [{pid, _}] = Registry.lookup(HalC2.Vcs.Registry, repo)

    File.write!(Path.join(repo, "c.txt"), "c\n")
    git!(repo, ~w(add c.txt))
    commit!(repo, "local")
    :ok = HalC2.Vcs.Watch.refresh(repo)
    assert %{remote: %{"aheadCount" => 1}} = :sys.get_state(pid)

    stale = %{"aheadCount" => 0, "pr" => %{"number" => 42}}
    GenServer.cast(pid, {:pr_found, "main", stale})
    assert %{remote: %{"aheadCount" => 1, "pr" => %{"number" => 42}}} = :sys.get_state(pid)
  end

  test "ahead and behind, after a fetch", %{repo: repo, other: other} do
    File.write!(Path.join(other, "b.txt"), "b\n")
    git!(other, ~w(add b.txt))
    commit!(other, "from other")
    git!(other, ~w(push -q))

    File.write!(Path.join(repo, "c.txt"), "c\n")
    git!(repo, ~w(add c.txt))
    commit!(repo, "local")

    assert %{"hasUpstream" => true, "aheadCount" => 1, "behindCount" => 0} =
             Vcs.remote_status(repo)

    assert {:ok, %{"aheadCount" => 1, "behindCount" => 1, "refName" => "main"}} =
             Vcs.refresh_status(%{"cwd" => repo})
  end

  test "refs: current first, remote mirrors hidden, remote-only branches trackable", %{
    repo: repo,
    other: other
  } do
    git!(other, ~w(checkout -q -b remote-only))
    git!(other, ~w(push -q -u origin remote-only))
    git!(repo, ~w(fetch -q))

    {:ok, %{"refName" => "feature"}} =
      Vcs.create_ref(%{"cwd" => repo, "refName" => "feature", "switchRef" => true})

    assert {:ok, %{"refs" => refs, "isRepo" => true, "totalCount" => 3}} =
             Vcs.list_refs(%{"cwd" => repo})

    assert [%{"name" => "feature", "current" => true} | _] = refs
    names = Enum.map(refs, & &1["name"])
    assert "main" in names and "origin/remote-only" in names
    refute "origin/main" in names

    assert {:ok, %{"refs" => [%{"name" => "origin/remote-only"}]}} =
             Vcs.list_refs(%{"cwd" => repo, "refKind" => "remote", "query" => "ONLY"})

    # Switching to a remote ref checks out a local branch tracking it.
    assert {:ok, %{"refName" => "remote-only"}} =
             Vcs.switch_ref(%{"cwd" => repo, "refName" => "origin/remote-only"})

    assert %{"hasUpstream" => true} = Vcs.remote_status(repo)
  end

  test "pull fast-forwards, and says when there is nothing to pull", %{repo: repo, other: other} do
    assert {:ok, %{"status" => "skipped_up_to_date"}} = Vcs.pull(%{"cwd" => repo})

    File.write!(Path.join(other, "b.txt"), "b\n")
    git!(other, ~w(add b.txt))
    commit!(other, "from other")
    git!(other, ~w(push -q))

    assert {:ok, %{"status" => "pulled", "refName" => "main", "upstreamRef" => "origin/main"}} =
             Vcs.pull(%{"cwd" => repo})

    assert File.exists?(Path.join(repo, "b.txt"))
  end

  test "worktrees are created under the HAL-C2 home and removed again", %{
    repo: repo,
    tmp_dir: dir
  } do
    assert {:ok, %{"worktree" => %{"path" => path, "refName" => "wt/branch"}}} =
             Vcs.create_worktree(%{
               "cwd" => repo,
               "refName" => "main",
               "newRefName" => "wt/branch",
               "path" => nil
             })

    assert path == Path.join([dir, "home", "worktrees", "repo", "wt-branch"])
    assert File.exists?(Path.join(path, "a.txt"))

    assert {:ok, %{"refs" => refs}} = Vcs.list_refs(%{"cwd" => repo})
    assert %{"worktreePath" => ^path} = Enum.find(refs, &(&1["name"] == "wt/branch"))

    assert {:ok, nil} = Vcs.remove_worktree(%{"cwd" => repo, "path" => path})
    refute File.exists?(path)
    # Already gone is not an error.
    assert {:ok, nil} = Vcs.remove_worktree(%{"cwd" => repo, "path" => path})
  end

  test "a long branch's folder keeps its start, whole characters, and a hash of the branch",
       %{repo: repo} do
    long = &(String.duplicate("a", 45) <> &1)
    one = Path.basename(Vcs.worktree_path(repo, long.("/one")))
    two = Path.basename(Vcs.worktree_path(repo, long.("/two")))

    assert String.length(one) == 40 and String.length(two) == 40
    assert String.starts_with?(one, String.duplicate("a", 31) <> "-")
    assert one != two

    emoji = Path.basename(Vcs.worktree_path(repo, "a" <> String.duplicate("😀", 60)))
    assert String.valid?(emoji) and String.length(emoji) == 40
    assert Path.basename(Vcs.worktree_path(repo, "fix/cart")) == "fix-cart"
  end

  test "a rename under an existing branch's path is flattened", %{repo: repo} do
    git!(repo, ~w(branch hal-c2))
    git!(repo, ~w(branch temp))
    assert {:ok, "hal-c2-fix-cart"} = Vcs.rename_branch(repo, "temp", "hal-c2/fix-cart")
    assert {:ok, "feature/cart"} = Vcs.rename_branch(repo, "hal-c2-fix-cart", "feature/cart")
  end

  test "watchers get a snapshot, then only what changed", %{repo: repo} do
    assert %{"_tag" => "snapshot", "local" => %{"hasWorkingTreeChanges" => false}} =
             HalC2.Vcs.Watch.subscribe(repo, self())

    File.write!(Path.join(repo, "a.txt"), "changed\n")
    :ok = HalC2.Vcs.Watch.refresh(repo)

    assert_receive {:hal_c2_vcs, ^repo,
                    %{"_tag" => "localUpdated", "local" => %{"hasWorkingTreeChanges" => true}}},
                   2_000

    # Nothing changed, so nothing is sent.
    :ok = HalC2.Vcs.Watch.refresh(repo)
    refute_receive {:hal_c2_vcs, _, _}, 200
  end

  test "a new branch started from a remote ref has no upstream", %{repo: repo} do
    assert {:ok, %{"worktree" => %{"path" => path}}} =
             Vcs.create_worktree(%{
               "cwd" => repo,
               "refName" => "origin/main",
               "newRefName" => "wt/from-origin",
               "path" => nil
             })

    {out, status} =
      System.cmd("git", ~w(rev-parse --abbrev-ref @{upstream}), cd: path, stderr_to_stdout: true)

    assert status != 0, "it tracks #{out}"
  end

  test "a checkout stopped by the time limit keeps a branch that was already there", %{
    repo: repo,
    tmp_dir: dir
  } do
    git!(repo, ~w(branch kept))
    git = Path.join(dir, "git-hangs")

    File.write!(
      git,
      "#!/bin/sh\ncase \"$*\" in *\"worktree add\"*) exec sleep 120;; esac\nexec git \"$@\"\n"
    )

    File.chmod!(git, 0o755)
    Application.put_env(:hal_c2, :git_command, git)
    Application.put_env(:hal_c2, :worktree_timeout, 300)

    on_exit(fn ->
      Application.delete_env(:hal_c2, :git_command)
      Application.delete_env(:hal_c2, :worktree_timeout)
    end)

    assert {:error, _} =
             Vcs.create_worktree(%{
               "cwd" => repo,
               "refName" => "main",
               "newRefName" => "kept",
               "path" => Path.join(dir, "free")
             })

    assert git!(repo, ~w(branch --list kept)) =~ "kept"
  end

  test "refs answer for a primary remote that is not called origin", %{repo: repo} do
    git!(repo, ~w(remote rename origin github))

    assert {:ok, %{"hasPrimaryRemote" => true, "refs" => refs}} =
             Vcs.list_refs(%{
               "cwd" => repo,
               "refKind" => "remote",
               "includeMatchingRemoteRefs" => true
             })

    assert %{"remoteName" => "github", "isDefault" => true} =
             Enum.find(refs, &(&1["name"] == "github/main"))
  end

  defp commit!(repo, message),
    do: git!(repo, ~w(-c user.name=t -c user.email=t@t commit -q -m) ++ [message])

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end
end
