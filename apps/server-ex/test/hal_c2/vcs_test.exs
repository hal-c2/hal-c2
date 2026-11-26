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

  test "a ref that looks like a git option is refused before git runs", %{repo: repo} do
    for ref <- ["--force", "--orphan=x", "-D", "--delete-merged=main", "a b", "a..b"] do
      assert {:error, %{"_tag" => "GitCommandError"}} =
               Vcs.switch_ref(%{"cwd" => repo, "refName" => ref}),
             ref

      assert {:error, %{"_tag" => "GitCommandError"}} =
               Vcs.create_ref(%{"cwd" => repo, "refName" => ref}),
             ref
    end

    # The checkout is untouched: still on main, no new branches.
    assert Vcs.local_status(repo)["refName"] == "main"

    assert git!(repo, ["branch", "--format=%(refname:short)"]) |> String.split("\n", trim: true) ==
             ["main"]
  end

  # `tmp` sits inside the checkout: without `GIT_CEILING_DIRECTORIES` (test_helper.exs) git
  # would find the checkout from a scratch folder, and a git action there would commit
  # and push the developer's work.
  test "a scratch folder under tmp is not the checkout around it", %{tmp_dir: dir} do
    plain = Path.join(dir, "plain")
    File.mkdir_p!(plain)
    refute Vcs.local_status(plain)["isRepo"]
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

  # Git resolves a relative path against the repository, and so do the MC's checks.
  test "a relative worktree path is the repository's", %{repo: repo, tmp_dir: dir} do
    assert {:ok, %{"worktree" => %{"path" => path}}} =
             Vcs.create_worktree(%{
               "cwd" => repo,
               "refName" => "main",
               "newRefName" => "rel",
               "path" => "../rel-wt"
             })

    assert path == Path.join(dir, "rel-wt")
    assert File.exists?(Path.join(path, "a.txt"))

    assert {:ok, nil} = Vcs.remove_worktree(%{"cwd" => repo, "path" => "../rel-wt"})
    refute File.exists?(path)
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

  # `:global`'s lock let waiters retry after random sleeps of up to 8 s, in any order: a
  # dozen threads launched at once in one repository left one waiting past a scenario's
  # patience before its worktree was made.
  test "renames waiting on one repository take their turns in the order they asked",
       %{repo: repo} do
    lease = start_supervised!(HalC2.WorkspaceLease)
    test = self()
    for n <- 0..4, do: git!(repo, ["branch", "temp-#{n}"])
    :erlang.trace(lease, true, [:receive])

    rename = fn n, on_name ->
      spawn(fn ->
        send(test, {:renamed, n, Vcs.rename_branch(repo, "temp-#{n}", "fix-#{n}", on_name)})
      end)
    end

    # The first holds the turn until told to go on.
    first =
      rename.(0, fn _ ->
        send(test, :holding)
        receive do: (:go -> :ok)
      end)

    assert_receive :holding

    for n <- 1..4 do
      pid = rename.(n, fn _ -> send(test, {:turn, n}) end)
      assert_receive {:trace, ^lease, :receive, {:"$gen_call", {^pid, _}, {:acquire, _}}}
    end

    :erlang.trace(lease, false, [:receive])
    send(first, :go)

    turns = for _ <- 1..4, do: receive(do: ({:turn, n} -> n))
    assert turns == [1, 2, 3, 4]
    for n <- 0..4, do: assert_receive({:renamed, ^n, {:ok, _}})
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

  # Git's auto maintenance after another thread's fetch pruned the entry `git worktree add`
  # had made and not yet locked; the add failed where a second one goes through.
  test "a worktree whose entry a prune took away mid-add is added again", %{
    repo: repo,
    tmp_dir: dir
  } do
    git = Path.join(dir, "git-pruned")

    # The first add fails as git does then: its branch made, its entry gone.
    File.write!(git, """
    #!/bin/sh
    case "$*" in *"worktree add"*)
      if [ ! -e "$0.failed" ]; then
        touch "$0.failed"
        for arg; do shift; [ "$arg" = "-b" ] && break; done
        git branch "$1" "$3"
        echo "fatal: could not open '.git/worktrees/x/locked' for writing: No such file or directory" >&2
        exit 128
      fi;;
    esac
    exec git "$@"
    """)

    File.chmod!(git, 0o755)
    Application.put_env(:hal_c2, :git_command, git)
    on_exit(fn -> Application.delete_env(:hal_c2, :git_command) end)

    assert {:ok, %{"worktree" => %{"path" => path, "refName" => "pruned"}}} =
             Vcs.create_worktree(%{
               "cwd" => repo,
               "refName" => "main",
               "newRefName" => "pruned",
               "path" => Path.join(dir, "pruned")
             })

    assert File.exists?(git <> ".failed")
    assert git!(path, ~w(branch --show-current)) == "pruned\n"

    # Into a folder that was there already, the branch the failed add made goes too.
    File.rm!(git <> ".failed")
    existing = Path.join(dir, "existing")
    File.mkdir_p!(existing)

    assert {:ok, %{"worktree" => %{"path" => ^existing}}} =
             Vcs.create_worktree(%{
               "cwd" => repo,
               "refName" => "main",
               "newRefName" => "pruned-again",
               "path" => existing
             })

    assert File.exists?(git <> ".failed")
    assert git!(existing, ~w(branch --show-current)) == "pruned-again\n"
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

  # A fresh branch look-up that sees its pull request open asks the sync sweep
  # to read it again only where a link to it has left the sweep, and names the
  # repository the host named (here `acme/app`, not the `alice/app` origin).
  test "a branch look-up revives only a linked pull request that left the sweep",
       %{repo: repo, tmp_dir: dir} do
    git!(repo, ~w(remote set-url origin https://github.com/alice/app.git))
    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Shell)

    test = self()
    sync = spawn(fn -> sync_dummy(test) end)
    Process.register(sync, HalC2.PullRequests.Sync)
    on_exit(fn -> if Process.alive?(sync), do: Process.exit(sync, :kill) end)

    fetch = fn _cwd, _branch ->
      {:ok,
       %{
         "number" => 12,
         "state" => "open",
         "url" => "https://github.com/acme/app/pull/12"
       }}
    end

    start_supervised!({HalC2.PullRequests.Branches, fetch: fetch})

    link = %{
      "host" => "github.com",
      "repository" => "acme/app",
      "number" => 12,
      "url" => "https://github.com/acme/app/pull/12",
      "source" => "manual"
    }

    put_thread = fn snapshot, extra ->
      row =
        Map.merge(
          %{"id" => "t1", "pullRequests" => [Map.put(link, "snapshot", snapshot)]},
          extra
        )

      HalC2.Shell.put_row("t1", {"thread", row})
      :ok = HalC2.Shell.sync()
      :ok = HalC2.PullRequests.Branches.forget(repo)
    end

    put_thread.(%{"state" => "closed", "closedAt" => "2026-08-24T00:00:00Z"}, %{})
    assert %{"number" => 12} = Vcs.branch_pull_request(repo, "feature/x")

    assert_receive {:sync_cast, {:request, ref}}
    assert ref["repository"] == "acme/app"
    assert ref["number"] == 12

    put_thread.(%{"state" => "open"}, %{})
    assert %{"number" => 12} = Vcs.branch_pull_request(repo, "feature/x")
    refute_receive {:sync_cast, _}, 100

    # An open snapshot on a settled thread would stay revivable forever:
    # asking again on every fresh look-up repeats a host read, and a settled
    # thread hears nothing anyway.
    put_thread.(%{"state" => "open"}, %{"settledOverride" => "settled"})
    assert %{"number" => 12} = Vcs.branch_pull_request(repo, "feature/x")
    refute_receive {:sync_cast, _}, 100

    # Settled by override or on its own, a closed snapshot still revives.
    put_thread.(
      %{"state" => "closed", "closedAt" => "2026-08-24T00:00:00Z"},
      %{"settledAt" => "2026-09-01T00:00:00Z"}
    )

    assert %{"number" => 12} = Vcs.branch_pull_request(repo, "feature/x")
    assert_receive {:sync_cast, {:request, _ref}}
  end

  defp sync_dummy(test) do
    receive do
      {:"$gen_cast", message} -> send(test, {:sync_cast, message})
    end

    sync_dummy(test)
  end

  defp commit!(repo, message),
    do: git!(repo, ~w(-c user.name=t -c user.email=t@t commit -q -m) ++ [message])

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end
end
