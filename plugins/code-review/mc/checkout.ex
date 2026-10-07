defmodule HalC2Plugins.CodeReview.Checkout do
  @moduledoc """
  The checkout a review's agent works in: a detached worktree of the project's
  repository, at the pull request's head, under the plugin's data directory. The
  pull request is fetched into refs of the plugin's own (`refs/hal-c2/code-review/`),
  so the user's branches, index and working tree are never touched.
  """

  @doc """
  Fetches pull request `number` of `repository` and its base branch `base` into the
  repository at `root`, and puts the worktree at `path` on its head. Answers
  `{:ok, %{"path", "headSha", "mergeBase"}}`.
  """
  def prepare(root, path, repository, number, base) do
    head_ref = "refs/hal-c2/code-review/#{number}/head"
    base_ref = "refs/hal-c2/code-review/#{number}/base"

    with {:ok, _} <-
           git(root, [
             "fetch",
             "-q",
             "--no-tags",
             # Reviews fetch side by side; FETCH_HEAD is the one file they would share.
             "--no-write-fetch-head",
             remote(root, repository),
             "+refs/pull/#{number}/head:#{head_ref}",
             "+refs/heads/#{base}:#{base_ref}"
           ]),
         {:ok, head} <- git(root, ["rev-parse", head_ref]),
         :ok <- place(root, path, head) do
      merge_base =
        case git(root, ["merge-base", base_ref, head]) do
          {:ok, sha} -> sha
          _ -> base_ref
        end

      {:ok, %{"path" => path, "headSha" => head, "mergeBase" => merge_base}}
    end
  end

  @doc "Removes the worktree at `path` from the repository at `root`, if it is there."
  def remove(root, path) do
    git(root, ["worktree", "remove", "--force", path])
    File.rm_rf(path)
    git(root, ["worktree", "prune"])
    :ok
  end

  @doc """
  The lines of the change `from`..`to` in the checkout at `path` a review comment
  can sit on, as `%{path => %{{side, line} => kind}}`: `side` is `"new"` or `"old"`
  and `kind` is `"added"`, `"deleted"` or `"context"`.
  """
  def diff_lines(path, from, to) do
    case git(path, ["diff", "--no-color", "--no-ext-diff", "-U3", from, to]) do
      {:ok, diff} -> parse(diff)
      _ -> %{}
    end
  end

  @doc """
  The position `pullRequests.submitReview` takes for a comment on `line` of `file`
  (`side` `"new"` or `"old"`), or nil when the change does not show that line.
  """
  def position(lines, file, line, side) do
    case {side, get_in(lines, [file, {side, line}])} do
      {"new", "added"} -> %{"kind" => "added", "newLine" => line}
      {"new", "context"} -> %{"kind" => "context", "newLine" => line}
      {"old", "deleted"} -> %{"kind" => "deleted", "oldLine" => line}
      {"old", "context"} -> %{"kind" => "context", "side" => "left", "oldLine" => line}
      _ -> nil
    end
  end

  defp parse(diff) do
    diff
    |> String.split("\n")
    |> Enum.reduce({%{}, nil, 0, 0}, fn text, {files, file, old, new} ->
      cond do
        String.starts_with?(text, "+++ b/") ->
          {files, String.trim_leading(text, "+++ b/"), 0, 0}

        String.starts_with?(text, "+++ ") or String.starts_with?(text, "--- ") ->
          {files, file, old, new}

        match = Regex.run(~r/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/, text) ->
          [_, old, new] = match
          {files, file, String.to_integer(old), String.to_integer(new)}

        file == nil ->
          {files, file, old, new}

        String.starts_with?(text, "+") ->
          {mark(files, file, {"new", new}, "added"), file, old, new + 1}

        String.starts_with?(text, "-") ->
          {mark(files, file, {"old", old}, "deleted"), file, old + 1, new}

        String.starts_with?(text, " ") ->
          files = files |> mark(file, {"new", new}, "context") |> mark(file, {"old", old}, "context")
          {files, file, old + 1, new + 1}

        true ->
          {files, file, old, new}
      end
    end)
    |> elem(0)
  end

  defp mark(files, file, key, kind),
    do: Map.update(files, file, %{key => kind}, &Map.put(&1, key, kind))

  # A worktree that is already there is moved to `sha`, dropping what an earlier
  # review left in it; one that is broken is made again.
  defp place(root, path, sha) do
    reused =
      File.exists?(Path.join(path, ".git")) and
        match?({:ok, _}, git(path, ["checkout", "-q", "--force", "--detach", sha])) and
        match?({:ok, _}, git(path, ["clean", "-fdq"]))

    if reused do
      :ok
    else
      File.rm_rf(path)
      git(root, ["worktree", "prune"])
      File.mkdir_p!(Path.dirname(path))

      with {:ok, _} <- git(root, ["worktree", "add", "-q", "--detach", "--force", path, sha]),
           do: :ok
    end
  end

  # The remote whose address names `repository`, else origin.
  defp remote(root, repository) do
    wanted = String.downcase(repository)

    case git(root, ["remote", "-v"]) do
      {:ok, out} ->
        Enum.find_value(String.split(out, "\n", trim: true), "origin", fn line ->
          case String.split(line) do
            [name, url | _] ->
              slug = url |> String.downcase() |> String.trim_trailing("/") |> String.trim_trailing(".git")
              if String.ends_with?(slug, "/" <> wanted) or String.ends_with?(slug, ":" <> wanted), do: name

            _ ->
              nil
          end
        end)

      _ ->
        "origin"
    end
  end

  defp git(cwd, args) do
    case System.cmd("git", args,
           cd: cwd,
           stderr_to_stdout: true,
           env: [{"GIT_TERMINAL_PROMPT", "0"}]
         ) do
      {out, 0} ->
        {:ok, String.trim(out)}

      {out, _} ->
        last = out |> String.trim() |> String.split("\n") |> List.last()
        {:error, "git #{hd(args)} failed: #{last}"}
    end
  rescue
    e in [ErlangError, File.Error] -> {:error, "git #{hd(args)} failed: #{Exception.message(e)}"}
  end
end
