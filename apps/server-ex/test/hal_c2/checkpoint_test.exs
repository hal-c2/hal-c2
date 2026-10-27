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

  test "outside a repository the checkpoint is missing" do
    # tmp_dir sits inside this repository's checkout, so use the system temp dir.
    outside =
      System.tmp_dir!() |> Path.join("hal-c2-no-repo-#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)

    scope = Checkpoint.scope_id("t")
    assert Checkpoint.capture_run(outside, scope, 1, "r", "n", "t", nil)["status"] == "missing"
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
