defmodule HalC2Plugins.CodeReview.Checkout do
  @moduledoc """
  The checkout a review's agent works in: a detached worktree, at the pull request's
  head, of the plugin's own bare clone of the repository. Both live under the plugin's
  data directory, so the user's repository is never fetched into or given a worktree.
  The clone is fetched over HTTPS with gh's credentials, which a service has where it
  may have no SSH agent.
  """

  @doc """
  Fetches pull request `number` and its base branch `base` from `url` into the bare
  clone at `clone`, made on first use, and puts the worktree at `path` on its head.
  Answers `{:ok, %{"path", "headSha", "mergeBase"}}`.
  """
  def prepare(clone, path, url, number, base) do
    head_ref = "refs/hal-c2/code-review/#{number}/head"
    base_ref = "refs/hal-c2/code-review/#{number}/base"

    alone(clone, fn ->
      with :ok <- init(clone),
           {:ok, _} <-
             git(
               clone,
               credentials() ++
                 [
                   "fetch",
                   "-q",
                   "--no-tags",
                   # Reviews fetch side by side; FETCH_HEAD is the one file they would share.
                   "--no-write-fetch-head",
                   url,
                   "+refs/pull/#{number}/head:#{head_ref}",
                   "+refs/heads/#{base}:#{base_ref}"
                 ]
             ),
           {:ok, head} <- git(clone, ["rev-parse", head_ref]),
           :ok <- place(clone, path, head) do
        merge_base =
          case git(clone, ["merge-base", base_ref, head]) do
            {:ok, sha} -> sha
            _ -> base_ref
          end

        {:ok, %{"path" => path, "headSha" => head, "mergeBase" => merge_base}}
      end
    end)
  end

  @doc "Removes the worktree at `path` from the repository at `root`, if it is there."
  def remove(root, path) do
    alone(root, fn ->
      git(root, ["worktree", "remove", "--force", path])
      File.rm_rf(path)
      git(root, ["worktree", "prune"])
    end)

    :ok
  end

  @doc """
  The text of `file` at commit `sha` in the checkout at `path`, or nil when the commit
  has no such regular file, it is over `limit` bytes or it is not UTF-8 text. It is read
  from git rather than the worktree: the pull request decides what the worktree holds,
  links included.
  """
  def read(path, sha, file, limit) do
    with {:ok, entry} <- git(path, ["ls-tree", "-l", sha, "--", file]),
         [mode, "blob", object, size | _] when mode in ~w(100644 100755) <- String.split(entry),
         true <- String.to_integer(size) <= limit,
         {:ok, text} <- git(path, ["cat-file", "blob", object]),
         true <- String.valid?(text) do
      text
    else
      _ -> nil
    end
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

  # Reviews of one repository share its clone; one at a time changes it, or one's
  # prune takes another's worktree while it is being added.
  defp alone(repository, fun), do: :global.trans({{__MODULE__, repository}, self()}, fun, [node()])

  defp init(clone) do
    if File.dir?(clone) do
      :ok
    else
      File.mkdir_p!(Path.dirname(clone))

      with {:ok, _} <- git(Path.dirname(clone), ["init", "-q", "--bare", clone]), do: :ok
    end
  end

  # gh as git's only credential helper, as `gh auth setup-git` would make it.
  defp credentials do
    case System.find_executable(Application.get_env(:hal_c2, :gh_command, "gh")) do
      nil -> []
      gh -> ["-c", "credential.helper=", "-c", "credential.helper=!'#{gh}' auth git-credential"]
    end
  end

  # The clone is the plugin's, so the user's git config is left out: its `insteadOf`
  # can turn the HTTPS address back into SSH, and its hooks have no business here.
  defp git(cwd, args) do
    case System.cmd("git", args,
           cd: cwd,
           stderr_to_stdout: true,
           env: [{"GIT_TERMINAL_PROMPT", "0"}, {"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}]
         ) do
      {out, 0} ->
        {:ok, String.trim(out)}

      {out, _} ->
        said = out |> String.split("\n", trim: true) |> Enum.map_join(" ", &String.trim/1)
        {:error, "git #{command(args)} failed: #{said}"}
    end
  rescue
    e in [ErlangError, File.Error] -> {:error, "git #{command(args)} failed: #{Exception.message(e)}"}
  end

  defp command(["-c", _ | args]), do: command(args)
  defp command([command | _]), do: command
end
