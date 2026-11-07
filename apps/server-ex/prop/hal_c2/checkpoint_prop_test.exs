defmodule HalC2.CheckpointPropTest do
  @moduledoc """
  The round-trip law of `HalC2.Checkpoint`: a workspace restored to a captured
  checkpoint holds exactly the files that were there when it was captured, and
  capturing leaves the user's own staging area as it was. Each case runs in a
  real git repository of its own, so the cases stay few.
  """

  use ExUnit.Case, async: false
  use PropCheck

  alias HalC2.Checkpoint

  @paths ["a.txt", "b.txt", "src/c.txt", "src/d.txt", "docs/e.md"]
  @readme {"README.md", "readme\n"}

  property "restoring a checkpoint puts back the workspace it captured",
    numtests: HalC2.Prop.numtests(25) do
    forall {first, second} <- {snapshot(), snapshot()} do
      round_trip(first, second)
    end
  end

  # The same law for a workspace that is a folder inside a repository: the
  # folder itself stays (even restored empty) and files outside it are left
  # as they were.
  property "restoring a checkpoint in a subfolder keeps the folder and the rest of the repository",
    numtests: HalC2.Prop.numtests(25) do
    forall {first, second} <- {sub_snapshot(), sub_snapshot()} do
      sub_round_trip(first, second)
    end
  end

  # The same law with an untracked nested repository in the workspace:
  # `git clean` skips it on every pass, so it must neither fail the restore
  # as left behind nor be removed by it.
  property "restoring a checkpoint leaves an untracked nested repository alone",
    numtests: HalC2.Prop.numtests(25) do
    forall {first, second} <- {snapshot(), snapshot()} do
      nested_round_trip(first, second)
    end
  end

  defp nested_round_trip(first, second) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "hal-c2-checkpoint-prop-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    try do
      git!(dir, ~w(init -q -b main))
      write_snapshot(dir, %{"README.md" => "readme\n"})
      git!(dir, ~w(add README.md))
      git!(dir, ~w(-c user.name=t -c user.email=t@t commit -q -m init))

      nested = Path.join(dir, "vendor/lib")
      File.mkdir_p!(nested)
      git!(nested, ~w(init -q -b main))
      File.write!(Path.join(nested, "lib.txt"), "lib\n")

      write_snapshot(dir, first)
      :ok = Checkpoint.capture(dir, "refs/hal-c2/test/nested-first")
      write_snapshot(dir, second)
      :ok = Checkpoint.capture(dir, "refs/hal-c2/test/nested-second")

      :ok = Checkpoint.restore(dir, "refs/hal-c2/test/nested-first")
      first_back = read_snapshot(dir) == first
      :ok = Checkpoint.restore(dir, "refs/hal-c2/test/nested-second")
      second_back = read_snapshot(dir) == second
      nested_kept = File.read!(Path.join(nested, "lib.txt")) == "lib\n"

      first_back and second_back and nested_kept
    after
      File.rm_rf!(dir)
    end
  end

  defp sub_snapshot, do: oneof([exactly(%{}), snapshot()])

  defp sub_round_trip(first, second) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "hal-c2-checkpoint-prop-#{System.unique_integer([:positive])}"
      )

    sub = Path.join(dir, "packages/app")
    File.mkdir_p!(sub)

    try do
      git!(dir, ~w(init -q -b main))
      File.write!(Path.join(dir, "root.txt"), "root\n")
      git!(dir, ~w(add root.txt))
      git!(dir, ~w(-c user.name=t -c user.email=t@t commit -q -m init))

      write_snapshot(sub, first)
      :ok = Checkpoint.capture(sub, "refs/hal-c2/test/sub-first")
      write_snapshot(sub, second)
      :ok = Checkpoint.capture(sub, "refs/hal-c2/test/sub-second")

      :ok = Checkpoint.restore(sub, "refs/hal-c2/test/sub-first")
      first_back = File.dir?(sub) and read_snapshot(sub) == first
      :ok = Checkpoint.restore(sub, "refs/hal-c2/test/sub-second")
      second_back = File.dir?(sub) and read_snapshot(sub) == second
      root_kept = File.read!(Path.join(dir, "root.txt")) == "root\n"

      first_back and second_back and root_kept
    after
      File.rm_rf!(dir)
    end
  end

  # A workspace: each pooled path is absent or holds one of a few contents.
  defp snapshot do
    let contents <- vector(length(@paths), content()) do
      @paths
      |> Enum.zip(contents)
      |> Enum.reject(fn {_path, content} -> content == nil end)
      |> Map.new()
      |> Map.put(elem(@readme, 0), elem(@readme, 1))
    end
  end

  defp content do
    oneof([exactly(nil), "", "x\n", "one\ntwo\n", "no newline", "ünïcode\n"])
  end

  defp round_trip(first, second) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "hal-c2-checkpoint-prop-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    try do
      git!(dir, ~w(init -q -b main))
      write_snapshot(dir, %{"README.md" => "readme\n"})
      git!(dir, ~w(add README.md))
      git!(dir, ~w(-c user.name=t -c user.email=t@t commit -q -m init))

      # Something of the user's own is staged while the checkpoints are taken.
      File.write!(Path.join(dir, "staged.txt"), "staged\n")
      git!(dir, ~w(add staged.txt))

      write_snapshot(dir, first)
      :ok = Checkpoint.capture(dir, "refs/hal-c2/test/first")
      write_snapshot(dir, second)
      :ok = Checkpoint.capture(dir, "refs/hal-c2/test/second")

      staged_kept = git!(dir, ~w(diff --cached --name-only)) == "staged.txt\n"

      :ok = Checkpoint.restore(dir, "refs/hal-c2/test/first")
      first_back = read_snapshot(dir) == first
      :ok = Checkpoint.restore(dir, "refs/hal-c2/test/second")
      second_back = read_snapshot(dir) == second

      staged_kept and first_back and second_back
    after
      File.rm_rf!(dir)
    end
  end

  # Makes the worktree hold exactly `snapshot` (besides `.git` and the staged
  # file, which a restore also removes once it is not in a snapshot, so it is
  # only written before the captures, never expected back).
  defp write_snapshot(dir, snapshot) do
    for path <- @paths ++ ["README.md"], not Map.has_key?(snapshot, path) do
      File.rm(Path.join(dir, path))
    end

    for {path, content} <- snapshot do
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end
  end

  defp read_snapshot(dir) do
    dir
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: false)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(fn full -> {Path.relative_to(full, dir), File.read!(full)} end)
    |> Map.delete("staged.txt")
    # The nested repository's files are no part of any snapshot.
    |> Map.reject(fn {path, _content} -> String.starts_with?(path, "vendor/") end)
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end
end
