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

  # File names are read from each file's header only, as a changed line can look
  # like one. A deleted file is named by its old path alone.
  defp parse(diff) do
    diff
    |> String.split("\n")
    |> Enum.reduce({%{}, nil, 0, 0, false}, fn text, {files, file, old, new, header?} = acc ->
      cond do
        String.starts_with?(text, "diff --git ") ->
          {files, nil, 0, 0, true}

        header? and String.starts_with?(text, "--- ") ->
          {files, header_path(text, "a/") || file, 0, 0, true}

        header? and String.starts_with?(text, "+++ ") ->
          {files, header_path(text, "b/") || file, 0, 0, true}

        match = Regex.run(~r/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/, text) ->
          [_, old, new] = match
          {files, file, String.to_integer(old), String.to_integer(new), false}

        header? or file == nil ->
          acc

        String.starts_with?(text, "+") ->
          {mark(files, file, {"new", new}, "added"), file, old, new + 1, false}

        String.starts_with?(text, "-") ->
          {mark(files, file, {"old", old}, "deleted"), file, old + 1, new, false}

        String.starts_with?(text, " ") ->
          files = files |> mark(file, {"new", new}, "context") |> mark(file, {"old", old}, "context")
          {files, file, old + 1, new + 1, false}

        true ->
          acc
      end
    end)
    |> elem(0)
  end

  # The path of a `---`/`+++` line, nil for /dev/null. Git quotes a path with
  # unusual characters as a C string ("a/\303\251.ts") and ends one with a space
  # in a tab.
  defp header_path(<<_marker::binary-size(4), path::binary>>, prefix) do
    path = String.trim_trailing(path, "\t")

    path =
      if String.starts_with?(path, "\"") and String.ends_with?(path, "\""),
        do: path |> binary_part(1, byte_size(path) - 2) |> unquote_c(<<>>),
        else: path

    if String.starts_with?(path, prefix), do: String.replace_prefix(path, prefix, "")
  end

  defp unquote_c(<<?\\, a, b, c, rest::binary>>, acc) when a in ?0..?3 and b in ?0..?7 and c in ?0..?7,
    do: unquote_c(rest, <<acc::binary, (a - ?0) * 64 + (b - ?0) * 8 + (c - ?0)>>)

  defp unquote_c(<<?\\, char, rest::binary>>, acc), do: unquote_c(rest, <<acc::binary, escaped(char)>>)
  defp unquote_c(<<char, rest::binary>>, acc), do: unquote_c(rest, <<acc::binary, char>>)
  defp unquote_c(<<>>, acc), do: acc

  defp escaped(?n), do: ?\n
  defp escaped(?t), do: ?\t
  defp escaped(?r), do: ?\r
  defp escaped(?a), do: 7
  defp escaped(?b), do: ?\b
  defp escaped(?f), do: ?\f
  defp escaped(?v), do: ?\v
  defp escaped(char), do: char

  defp mark(files, file, key, kind),
    do: Map.update(files, file, %{key => kind}, &Map.put(&1, key, kind))

  # Each review gets a worktree of its own, so whatever is left at `path` goes.
  defp place(root, path, sha) do
    File.rm_rf(path)
    git(root, ["worktree", "prune"])
    File.mkdir_p!(Path.dirname(path))

    with {:ok, _} <- git(root, ["worktree", "add", "-q", "--detach", "--force", path, sha]),
         do: :ok
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
