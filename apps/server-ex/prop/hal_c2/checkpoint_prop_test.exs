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
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end
end
