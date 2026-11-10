defmodule HalC2.CheckpointTest do
  use ExUnit.Case, async: true

  alias HalC2.Checkpoint

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    git!(dir, ~w(init -q -b main))
    File.write!(Path.join(dir, "a.txt"), "one\n")
    git!(dir, ~w(add a.txt))
    git!(dir, ~w(-c user.name=t -c user.email=t@t commit -q -m init))
    %{dir: dir}
  end

  test "ids and refs keep the format earlier installs wrote" do
    scope = Checkpoint.scope_id("thread-1")
    assert scope == "checkpoint-scope:thread:thread-1:name:root"

    assert Checkpoint.checkpoint_id(scope, 2) ==
             "checkpoint:scope:checkpoint-scope%3Athread%3Athread-1%3Aname%3Aroot:name:2"

    # sha256(scope)[0..32] as hex, then base64url.
    assert Checkpoint.ref(scope, 0) =~
             ~r"^refs/hal-c2/orchestration-v2/checkpoints/[A-Za-z0-9_-]{43}/ordinal/0$"
  end

  test "captures leave the user's index alone and summarize each run", %{dir: dir} do
    scope = Checkpoint.scope_id("t")
    File.write!(Path.join(dir, "staged.txt"), "staged\n")
    git!(dir, ~w(add staged.txt))

    assert :ok = Checkpoint.baseline(dir, scope, 0)
    File.write!(Path.join(dir, "a.txt"), "one\ntwo\n")
    File.write!(Path.join(dir, "new.txt"), "x\ny\n")

    checkpoint = Checkpoint.capture_run(dir, scope, 1, "run-1", "node-1", "t", nil)

    assert checkpoint["status"] == "ready"
    assert checkpoint["parentCheckpointId"] == Checkpoint.checkpoint_id(scope, 0)

    assert checkpoint["files"] == [
             %{"path" => "a.txt", "kind" => "modified", "additions" => 1, "deletions" => 0},
             %{"path" => "new.txt", "kind" => "modified", "additions" => 2, "deletions" => 0}
           ]

    assert git!(dir, ~w(diff --cached --name-only)) == "staged.txt\n"
  end

  test "turn diffs between checkpoints", %{dir: dir} do
    scope = Checkpoint.scope_id("t")
    :ok = Checkpoint.baseline(dir, scope, 0)
    File.write!(Path.join(dir, "a.txt"), "one\ntwo\n")
    first = Checkpoint.capture_run(dir, scope, 1, "run-1", "n", "t", nil)
    File.write!(Path.join(dir, "b.txt"), "b\n")
    second = Checkpoint.capture_run(dir, scope, 2, "run-2", "n", "t", nil)

    state = %HalC2.StreamState{
      entities: %{
        "run" => %{
          "run-1" => %{"id" => "run-1", "status" => "completed"},
          "run-2" => %{"id" => "run-2", "status" => "completed"}
        },
        "checkpoint" => %{first["id"] => first, second["id"] => second},
        "checkpoint-scope" => %{
          scope => Checkpoint.scope("t", "run-2", "n", "pt", dir, "2026-01-01T00:00:00Z")
        }
      }
    }

    assert {:ok, %{"diff" => whole}} = Checkpoint.turn_diff(state, "t", 0, 2)
    assert whole =~ "+++ b/a.txt"
    assert whole =~ "+++ b/b.txt"

    assert {:ok, %{"diff" => last}} = Checkpoint.turn_diff(state, "t", 1, 2)
    refute last =~ "a.txt"
    assert last =~ "+b"

    assert {:ok, %{"diff" => ""}} = Checkpoint.turn_diff(state, "t", 2, 2)
    assert {:error, _} = Checkpoint.turn_diff(state, "t", 0, 3)
  end

  test "a nested repository with no commit yet is left out of the capture", %{dir: dir} do
    nested = Path.join(dir, "vendor/lib")
    File.mkdir_p!(nested)
    git!(nested, ~w(init -q -b main))
    File.write!(Path.join(nested, "lib.txt"), "lib\n")

    scope = Checkpoint.scope_id("t")
    checkpoint = Checkpoint.capture_run(dir, scope, 1, "run-1", "n", "t", nil)

    assert checkpoint["status"] == "ready"
    tree = git!(dir, ["ls-tree", "-r", "--name-only", checkpoint["ref"]])
    assert tree =~ "a.txt"
    refute tree =~ "vendor"
  end

  test "more nested repositories than the recovery limit fail the capture", %{dir: dir} do
    for i <- 1..65 do
      nested = Path.join(dir, "nested-#{i}")
      File.mkdir_p!(nested)
      git!(nested, ~w(init -q -b main))
      File.write!(Path.join(nested, "lib.txt"), "lib\n")
    end

    scope = Checkpoint.scope_id("t")
    assert Checkpoint.capture_run(dir, scope, 1, "run-1", "n", "t", nil)["status"] == "error"
  end

  test "a cone sparse checkout keeps the folders it leaves out", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "src"))
    File.mkdir_p!(Path.join(dir, "docs"))
    File.write!(Path.join(dir, "src/a.ts"), "a\n")
    File.write!(Path.join(dir, "docs/guide.md"), "guide\n")
    git!(dir, ~w(add src docs))
    git!(dir, ~w(-c user.name=t -c user.email=t@t commit -q -m sparse))
    git!(dir, ~w(sparse-checkout set --cone src))
    refute File.exists?(Path.join(dir, "docs/guide.md"))

    scope = Checkpoint.scope_id("t")
    checkpoint = Checkpoint.capture_run(dir, scope, 1, "run-1", "n", "t", nil)

    assert checkpoint["status"] == "ready"
    assert git!(dir, ["show", "#{checkpoint["ref"]}:docs/guide.md"]) == "guide\n"
    refute Enum.any?(checkpoint["files"], &String.starts_with?(&1["path"], "docs/"))
  end

  test "a non-cone sparse checkout whose index cannot be reused fails saying why",
       %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "docs"))
    File.write!(Path.join(dir, "docs/guide.md"), "guide\n")
    git!(dir, ~w(add docs))
    git!(dir, ~w(-c user.name=t -c user.email=t@t commit -q -m sparse))
    git!(dir, ["sparse-checkout", "set", "--no-cone", "/*", "!/docs/"])
    git!(dir, ~w(update-index --assume-unchanged a.txt))

    assert {:error, "Cannot rebuild a checkpoint index for non-cone sparse checkout."} =
             Checkpoint.capture(dir, "refs/hal-c2/test/non-cone")
  end

  test "checkpoints under the old ref namespace still diff, restore and delete", %{dir: dir} do
    scope = Checkpoint.scope_id("t")
    :ok = Checkpoint.baseline(dir, scope, 0)
    File.write!(Path.join(dir, "a.txt"), "one\ntwo\n")
    first = Checkpoint.capture_run(dir, scope, 1, "run-1", "n", "t", nil)

    legacy = String.replace_prefix(first["ref"], "refs/hal-c2/", "refs/t3/")
    oid = String.trim(git!(dir, ["rev-parse", first["ref"]]))
    git!(dir, ["update-ref", legacy, oid])
    git!(dir, ["update-ref", "-d", first["ref"]])

    assert Checkpoint.exists?(dir, first["ref"])

    state = %HalC2.StreamState{
      entities: %{
        "run" => %{"run-1" => %{"id" => "run-1", "status" => "completed"}},
        "checkpoint" => %{first["id"] => first},
        "checkpoint-scope" => %{
          scope => Checkpoint.scope("t", "run-1", "n", "pt", dir, "2026-01-01T00:00:00Z")
        }
      }
    }

    assert {:ok, %{"diff" => diff}} = Checkpoint.turn_diff(state, "t", 0, 1)
    assert diff =~ "+two"

    File.write!(Path.join(dir, "a.txt"), "later\n")
    assert :ok = Checkpoint.restore(dir, first["ref"])
    assert File.read!(Path.join(dir, "a.txt")) == "one\ntwo\n"

    assert :ok = Checkpoint.delete_ref(dir, first["ref"])
    refute Checkpoint.exists?(dir, legacy)
  end

  test "rewound turns do not count in diff turn numbers", %{dir: dir} do
    scope = Checkpoint.scope_id("t")
    :ok = Checkpoint.baseline(dir, scope, 0)
    File.write!(Path.join(dir, "a.txt"), "one\ntwo\n")
    first = Checkpoint.capture_run(dir, scope, 1, "run-1", "n", "t", nil)
    File.write!(Path.join(dir, "b.txt"), "b\n")
    second = Checkpoint.capture_run(dir, scope, 2, "run-2", "n", "t", nil)
    # Rewound to run 1, then a new run (ordinal 3) completes.
    :ok = Checkpoint.restore(dir, first["ref"])
    File.write!(Path.join(dir, "c.txt"), "c\n")
    third = Checkpoint.capture_run(dir, scope, 3, "run-3", "n", "t", nil)

    rolled_back = %{second | "status" => "stale"}

    state = %HalC2.StreamState{
      entities: %{
        "run" => %{
          "run-1" => %{"id" => "run-1", "status" => "completed"},
          "run-2" => %{"id" => "run-2", "status" => "rolled_back"},
          "run-3" => %{"id" => "run-3", "status" => "completed"}
        },
        "checkpoint" => %{
          first["id"] => first,
          rolled_back["id"] => rolled_back,
          third["id"] => third
        },
        "checkpoint-scope" => %{
          scope => Checkpoint.scope("t", "run-3", "n", "pt", dir, "2026-01-01T00:00:00Z")
        }
      }
    }

    # Turn 2 is now the new run.
    assert {:ok, %{"diff" => diff}} = Checkpoint.turn_diff(state, "t", 1, 2)
    assert diff =~ "+++ b/c.txt"
    refute diff =~ "b.txt"
  end

  test "a capture is taken when git refuses line-ending changes (core.safecrlf)", %{dir: dir} do
    git!(dir, ~w(config core.safecrlf true))
    git!(dir, ~w(config core.autocrlf true))
    File.write!(Path.join(dir, "a.txt"), "one\ntwo\n")

    scope = Checkpoint.scope_id("t")
    checkpoint = Checkpoint.capture_run(dir, scope, 1, "run-1", "n", "t", nil)

    assert checkpoint["status"] == "ready"
    assert git!(dir, ["show", "#{checkpoint["ref"]}:a.txt"]) == "one\ntwo\n"
    # The user's own settings and index are unchanged.
    assert git!(dir, ~w(config core.safecrlf)) == "true\n"
    assert git!(dir, ~w(diff --cached --name-only)) == ""
  end

  test "a capture leaves a split index the repository still uses", %{dir: dir} do
    git!(dir, ~w(config core.splitIndex true))
    git!(dir, ~w(config splitIndex.sharedIndexExpire now))
    git!(dir, ~w(update-index --split-index))
    shared = Path.wildcard(Path.join(dir, ".git/sharedindex.*"))
    assert shared != []

    File.write!(Path.join(dir, "a.txt"), "one\ntwo\n")
    scope = Checkpoint.scope_id("t")
    assert Checkpoint.capture_run(dir, scope, 1, "run-1", "n", "t", nil)["status"] == "ready"

    for file <- shared, do: assert(File.exists?(file), "#{file} is gone")
    assert git!(dir, ~w(status --porcelain)) == " M a.txt\n"
  end

  test "flagged entries are captured as edited without touching the user's flags", %{dir: dir} do
    File.write!(Path.join(dir, "b.txt"), "bbbb\n")
    File.write!(Path.join(dir, "c.txt"), "cccc\n")
    git!(dir, ~w(add b.txt c.txt))
    git!(dir, ~w(-c user.name=t -c user.email=t@t commit -q -m more))
    git!(dir, ~w(update-index --assume-unchanged b.txt))
    git!(dir, ~w(update-index --skip-worktree c.txt))
    File.write!(Path.join(dir, "b.txt"), "BB!!\n")
    File.write!(Path.join(dir, "c.txt"), "CC!!\n")

    scope = Checkpoint.scope_id("t")
    checkpoint = Checkpoint.capture_run(dir, scope, 1, "run-1", "n", "t", nil)

    assert checkpoint["status"] == "ready"
    assert git!(dir, ["show", "#{checkpoint["ref"]}:b.txt"]) == "BB!!\n"
    assert git!(dir, ["show", "#{checkpoint["ref"]}:c.txt"]) == "CC!!\n"
    # The user's index keeps its flags.
    assert git!(dir, ~w(ls-files -v)) =~ "h b.txt"
    assert git!(dir, ~w(ls-files -v)) =~ "S c.txt"
  end

  test "a workspace folder its repository ignores gets missing checkpoints", %{dir: dir} do
    File.write!(Path.join(dir, ".gitignore"), "sub/\n")
    git!(dir, ~w(add .gitignore))
    git!(dir, ~w(-c user.name=t -c user.email=t@t commit -q -m ignore))
    sub = Path.join(dir, "sub")
    File.mkdir_p!(sub)
    File.write!(Path.join(sub, "new.txt"), "new\n")

    scope = Checkpoint.scope_id("t")
    assert Checkpoint.capture_run(sub, scope, 1, "run-1", "n", "t", nil)["status"] == "missing"
  end

  test "tracked files in an ignored workspace folder are still checkpointed", %{dir: dir} do
    File.write!(Path.join(dir, ".gitignore"), "sub/\n")
    git!(dir, ~w(add .gitignore))
    git!(dir, ~w(-c user.name=t -c user.email=t@t commit -q -m ignore))
    sub = Path.join(dir, "sub")
    File.mkdir_p!(sub)
    File.write!(Path.join(sub, "tracked.txt"), "v1\n")
    git!(dir, ~w(add -f sub/tracked.txt))
    git!(dir, ~w(-c user.name=t -c user.email=t@t commit -q -m tracked))
    File.write!(Path.join(sub, "tracked.txt"), "v2\n")
    File.write!(Path.join(sub, "ignored.txt"), "ignored\n")

    scope = Checkpoint.scope_id("t")
    checkpoint = Checkpoint.capture_run(sub, scope, 1, "run-1", "n", "t", nil)

    assert checkpoint["status"] == "ready"
    assert git!(sub, ["show", "#{checkpoint["ref"]}:sub/tracked.txt"]) == "v2\n"
    tree = git!(sub, ["ls-tree", "-r", "--name-only", checkpoint["ref"], "--", "."])
    refute tree =~ "ignored.txt"
  end

  test "restoring removes what a .gitignore from the undone work was hiding", %{dir: dir} do
    scope = Checkpoint.scope_id("t")
    first = Checkpoint.capture_run(dir, scope, 1, "run-1", "n", "t", nil)
    assert first["status"] == "ready"

    File.mkdir_p!(Path.join(dir, "web/node_modules"))
    File.write!(Path.join(dir, "web/.gitignore"), "node_modules/\n.env\n")
    File.write!(Path.join(dir, "web/node_modules/a.js"), "a\n")
    File.write!(Path.join(dir, "web/.env"), "secret\n")

    assert :ok = Checkpoint.restore(dir, first["ref"])
    refute File.exists?(Path.join(dir, "web/.gitignore"))
    refute File.exists?(Path.join(dir, "web/node_modules/a.js"))
    refute File.exists?(Path.join(dir, "web/.env"))
  end

  # `git clean` skips a nested repository on every pass, dry runs included:
  # one in the workspace must not read as files left behind, or every
  # restore in such a workspace fails. The repository itself is the user's,
  # and a restore leaves it alone.
  test "restoring succeeds with an untracked nested repository in the workspace",
       %{dir: dir} do
    scope = Checkpoint.scope_id("t")
    first = Checkpoint.capture_run(dir, scope, 1, "run-1", "n", "t", nil)
    assert first["status"] == "ready"

    nested = Path.join(dir, "vendor/lib")
    File.mkdir_p!(nested)
    git!(nested, ~w(init -q -b main))
    File.write!(Path.join(nested, "lib.txt"), "lib\n")

    File.write!(Path.join(dir, "a.txt"), "later\n")
    File.write!(Path.join(dir, "loose.txt"), "loose\n")

    assert :ok = Checkpoint.restore(dir, first["ref"])
    assert File.read!(Path.join(dir, "a.txt")) == "one\n"
    refute File.exists?(Path.join(dir, "loose.txt"))
    assert File.read!(Path.join(nested, "lib.txt")) == "lib\n"
  end

  test "a restore that cannot clear nested .gitignore hiding fails", %{dir: dir} do
    scope = Checkpoint.scope_id("t")
    first = Checkpoint.capture_run(dir, scope, 1, "run-1", "n", "t", nil)
    assert first["status"] == "ready"

    # Each level's .gitignore hides the next level's folder.
    levels = ~w(l1 l1/l2 l1/l2/l3 l1/l2/l3/l4 l1/l2/l3/l4/l5)

    for {level, next} <- Enum.zip(levels, tl(levels) ++ ["leaf"]) do
      File.mkdir_p!(Path.join(dir, level))
      File.write!(Path.join(dir, "#{level}/.gitignore"), "#{Path.basename(next)}/\n")
    end

    File.write!(Path.join(dir, "l1/l2/l3/l4/l5/leaf.txt"), "leaf\n")

    assert {:error, _} = Checkpoint.restore(dir, first["ref"])
  end

  test "restoring an empty checkpoint keeps a workspace folder inside a repository",
       %{dir: dir} do
    sub = Path.join(dir, "packages/app")
    File.mkdir_p!(sub)
    File.write!(Path.join(sub, "new.txt"), "x\n")

    empty = Path.join(dir, "empty-tree")
    File.write!(empty, "")
    tree = String.trim(git!(dir, ["hash-object", "-t", "tree", empty]))
    commit = String.trim(git!(dir, ["commit-tree", tree, "-m", "empty"]))
    ref = "refs/hal-c2/test/empty-subfolder"
    git!(dir, ["update-ref", ref, commit])

    assert :ok = Checkpoint.restore(sub, ref)
    assert File.ls!(sub) == []
    assert File.read!(Path.join(dir, "a.txt")) == "one\n"
  end

  test "restoring in a repository with no commits leaves nothing staged", %{tmp_dir: dir} do
    fresh = Path.join(dir, "fresh")
    File.mkdir_p!(fresh)
    git!(fresh, ~w(init -q -b main))
    File.write!(Path.join(fresh, "file.txt"), "v1\n")

    scope = Checkpoint.scope_id("t")
    first = Checkpoint.capture_run(fresh, scope, 1, "run-1", "n", "t", nil)
    assert first["status"] == "ready"
    File.write!(Path.join(fresh, "file.txt"), "v2\n")

    assert :ok = Checkpoint.restore(fresh, first["ref"])
    assert File.read!(Path.join(fresh, "file.txt")) == "v1\n"
    assert git!(fresh, ~w(diff --cached --name-only)) == ""
    assert git!(fresh, ~w(status --porcelain)) == "?? file.txt\n"
  end

  test "outside a repository the checkpoint is missing" do
    # tmp_dir sits inside this repository's checkout, so use the system temp dir.
    outside =
      System.tmp_dir!() |> Path.join("hal-c2-no-repo-#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)

    scope = Checkpoint.scope_id("t")
    assert Checkpoint.capture_run(outside, scope, 1, "r", "n", "t", nil)["status"] == "missing"
  end

  test "a capture is tried again for the lines git prints for a lock or a vanished file" do
    for message <- [
          "fatal: Unable to create '/r/.git/index.lock': File exists.",
          "fatal: Another git process seems to be running in this repository",
          ~s{error: open("f"): No such file or directory\nerror: unable to index file 'f'\nfatal: adding files failed},
          "error: unable to stat 'f': No such file or directory",
          "error: failed to insert into database"
        ] do
      assert Checkpoint.transient?(message), message
    end

    refute Checkpoint.transient?(
             "error: 'nested/' does not have a commit checked out\nerror: unable to index file 'nested/'"
           )

    refute Checkpoint.transient?("fatal: not a git repository (or any of the parent directories)")
    refute Checkpoint.transient?("fatal: cannot change to '/gone': No such file or directory")
  end

  test "parses renames in numstat" do
    numstat = "3\t1\tsrc.ex\u00000\t0\t\u0000old.ex\u0000new.ex\u0000-\t-\timg.png\u0000"

    assert Checkpoint.numstat_files(numstat) == [
             %{"path" => "img.png", "kind" => "modified", "additions" => 0, "deletions" => 0},
             %{"path" => "new.ex", "kind" => "modified", "additions" => 0, "deletions" => 0},
             %{"path" => "src.ex", "kind" => "modified", "additions" => 3, "deletions" => 1}
           ]
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir)
    out
  end
end
