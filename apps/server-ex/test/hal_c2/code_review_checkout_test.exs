unless Code.ensure_loaded?(HalC2Plugins.CodeReview.Checkout),
  do: Code.require_file("../../../../plugins/code-review/mc/checkout.ex", __DIR__)

defmodule HalC2.CodeReviewCheckoutTest do
  @moduledoc """
  `HalC2Plugins.CodeReview.Checkout.same_patch?/4`, which tells a push that only
  rebased a reviewed change, against a real repository.
  """
  use ExUnit.Case, async: true

  alias HalC2Plugins.CodeReview.Checkout

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    git!(dir, ~w(init -q -b main))
    commit!(dir, "README.md", "start\n", "Start")
    start = rev!(dir, "HEAD")

    # The change, on the first base.
    git!(dir, ~w(checkout -q -b change))
    commit!(dir, "src/limits.ts", "export const limit = 1;\n", "Limit")
    head = rev!(dir, "HEAD")

    # The base moves on, and the change is rebased onto it.
    git!(dir, ~w(checkout -q main))
    commit!(dir, "NOTES.md", "notes\n", "Notes")
    moved = rev!(dir, "HEAD")
    git!(dir, ~w(checkout -q -b rebased change))
    git!(dir, ["rebase", "-q", "main"])
    rebased = rev!(dir, "HEAD")

    # The plugin's clone is bare, as the one `prepare/5` makes.
    clone = Path.join(dir, "clone.git")
    git!(dir, ["clone", "-q", "--mirror", dir, clone])

    %{dir: clone, start: start, head: head, moved: moved, rebased: rebased}
  end

  test "a change only rebased onto a newer base is the same patch", c do
    assert c.rebased != c.head

    assert Checkout.same_patch?(c.dir, c.start, c.head, %{
             "mergeBase" => c.moved,
             "headSha" => c.rebased
           })
  end

  test "a change that differs after the rebase is not", c do
    work = Path.dirname(c.dir)
    git!(work, ~w(checkout -q rebased))
    commit!(work, "src/limits.ts", "export const limit = 2;\n", "More")
    git!(work, ["push", "-q", c.dir, "HEAD:refs/heads/more"])
    pushed = rev!(work, "HEAD")

    refute Checkout.same_patch?(c.dir, c.start, c.head, %{
             "mergeBase" => c.moved,
             "headSha" => pushed
           })
  end

  test "a reviewed head the repository no longer has, or no merge base, is not", c do
    gone = String.duplicate("1", 40)
    new = %{"mergeBase" => c.moved, "headSha" => c.rebased}

    refute Checkout.same_patch?(c.dir, c.start, gone, new)
    refute Checkout.same_patch?(c.dir, nil, c.head, new)
    refute Checkout.same_patch?(c.dir, c.start, c.head, %{new | "mergeBase" => nil})
  end

  test "an empty change is not the same as another empty one", c do
    refute Checkout.same_patch?(c.dir, c.head, c.head, %{
             "mergeBase" => c.rebased,
             "headSha" => c.rebased
           })
  end

  defp commit!(dir, file, text, message) do
    path = Path.join(dir, file)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
    git!(dir, ["add", file])
    git!(dir, ["commit", "-q", "-m", message])
  end

  defp rev!(dir, rev), do: git!(dir, ["rev-parse", rev]) |> String.trim()

  defp git!(dir, args) do
    env = [
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_AUTHOR_NAME", "Test"},
      {"GIT_AUTHOR_EMAIL", "test@example.com"},
      {"GIT_COMMITTER_NAME", "Test"},
      {"GIT_COMMITTER_EMAIL", "test@example.com"}
    ]

    {out, 0} = System.cmd("git", args, cd: dir, env: env, stderr_to_stdout: true)
    out
  end
end
