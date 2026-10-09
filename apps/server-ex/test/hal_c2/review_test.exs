defmodule HalC2.ReviewTest do
  use ExUnit.Case, async: false

  alias HalC2.Review

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)

    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    git!(repo, ~w(init -q -b main))
    File.write!(Path.join(repo, "a.txt"), "one\n")
    git!(repo, ~w(add a.txt))
    commit!(repo, "init")
    git!(repo, ~w(checkout -q -b feature))
    File.write!(Path.join(repo, "b.txt"), "b\n")
    git!(repo, ~w(add b.txt))
    commit!(repo, "feature")

    :ok = HalC2.Shell.subscribe(self())

    {:ok, _} =
      HalC2.Projects.mutate(%{
        "type" => "project.create",
        "projectId" => "p1",
        "workspaceRoot" => repo
      })

    assert_receive {:hal_c2_shell, {:rows, _, [{"p1", _}]}}, 1_000
    %{repo: repo}
  end

  test "the dirty worktree and the branch against main, untracked files included", %{repo: repo} do
    File.write!(Path.join(repo, "a.txt"), "one\ntwo\n")
    File.write!(Path.join(repo, "new.txt"), "fresh\n")

    assert {:ok, %{"sources" => [dirty, branch]}} = Review.diff_preview(%{"cwd" => repo})

    assert %{"kind" => "working-tree", "baseRef" => "HEAD", "truncated" => false} = dirty

    assert Enum.map(dirty["files"], &{&1["path"], &1["additions"]}) == [
             {"a.txt", 1},
             {"new.txt", 1}
           ]

    assert dirty["diff"] =~ "+++ b/new.txt"

    assert %{"baseRef" => "main", "headRef" => "feature", "title" => "Against main"} = branch
    assert [%{"path" => "b.txt"}] = branch["files"]

    # The untracked file was only added to a scratch index.
    assert git!(repo, ~w(status --porcelain)) =~ "?? new.txt"

    assert {:ok, %{"oldContents" => "", "newContents" => "fresh\n"}} =
             Review.file_contents(%{
               "cwd" => repo,
               "sourceKind" => "working-tree",
               "changeType" => "new",
               "baseRef" => "HEAD",
               "headRef" => nil,
               "oldPath" => "new.txt",
               "newPath" => "new.txt"
             })

    assert {:ok, %{"oldContents" => "", "newContents" => "b\n"}} =
             Review.file_contents(%{
               "cwd" => repo,
               "sourceKind" => "branch-range",
               "changeType" => "new",
               "baseRef" => "main",
               "headRef" => "feature",
               "oldPath" => "b.txt",
               "newPath" => "b.txt"
             })
  end

  test "only this MC's projects can be reviewed", %{tmp_dir: dir} do
    assert {:error, %{"_tag" => "VcsRepositoryDetectionError"}} =
             Review.diff_preview(%{"cwd" => dir})
  end

  test "a thread in its own worktree reviews that worktree", %{repo: repo, tmp_dir: dir} do
    # Outside the project's root and outside the MC's worktrees directory.
    worktree = Path.join(dir, "elsewhere/tax")
    git!(repo, ["worktree", "add", "-q", "-b", "tax", worktree, "feature"])
    File.write!(Path.join(worktree, "a.txt"), "one\ntwo\n")
    File.write!(Path.join(worktree, "new.txt"), "fresh\n")

    assert {:error, %{"_tag" => "VcsRepositoryDetectionError"}} =
             Review.diff_preview(%{"cwd" => worktree})

    for command <- [
          %{"type" => "thread.create", "projectId" => "p1", "title" => "Tax"},
          %{"type" => "thread.metadata.update", "worktreePath" => worktree, "branch" => "tax"}
        ] do
      {:ok, _} = HalC2.Orchestration.dispatch(Map.put(command, "threadId", "t1"))
    end

    assert_receive {:hal_c2_shell, {:rows, _, [{"t1", {"thread", %{"worktreePath" => ^worktree}}}]}},
                   1_000

    assert {:ok, %{"sources" => [dirty, _branch]}} = Review.diff_preview(%{"cwd" => worktree})
    assert Enum.map(dirty["files"], & &1["path"]) == ["a.txt", "new.txt"]
    # The project's own checkout is untouched by the worktree's changes.
    assert {:ok, %{"sources" => [%{"files" => []}, _]}} = Review.diff_preview(%{"cwd" => repo})

    assert {:ok, %{"oldContents" => "one\n", "newContents" => "one\ntwo\n"}} =
             Review.file_contents(%{
               "cwd" => worktree,
               "sourceKind" => "working-tree",
               "changeType" => "change",
               "baseRef" => "HEAD",
               "headRef" => nil,
               "oldPath" => "a.txt",
               "newPath" => "a.txt"
             })
  end

  test "a worktree under the MC's worktrees directory is reviewed before a thread names it",
       %{repo: repo, tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, Path.join(dir, "home"))
    on_exit(fn -> Application.delete_env(:hal_c2, :home) end)

    worktree = HalC2.Vcs.worktree_path(repo, "fix/tax")
    git!(repo, ["worktree", "add", "-q", "-b", "fix/tax", worktree, "feature"])
    File.write!(Path.join(worktree, "new.txt"), "fresh\n")

    assert {:ok, %{"sources" => [%{"files" => [%{"path" => "new.txt"}]}, _]}} =
             Review.diff_preview(%{"cwd" => worktree})
  end

  test "numstat keeps renames' previous paths" do
    assert [%{"path" => "new.ex", "previousPath" => "old.ex", "additions" => 2}] =
             Review.numstat("2\t0\t\u0000old.ex\u0000new.ex\u0000")
  end

  defp commit!(repo, message),
    do: git!(repo, ~w(-c user.name=t -c user.email=t@t commit -q -m) ++ [message])

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir)
    out
  end
end
