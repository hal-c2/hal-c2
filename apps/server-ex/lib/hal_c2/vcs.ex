defmodule HalC2.Vcs do
  @moduledoc """
  Git for the Version Control panel: status (`vcs.refreshStatus`, and the stream in
  `HalC2.Vcs.Watch`), refs (`vcs.listRefs`, `vcs.switchRef`, `vcs.createRef`),
  `vcs.init`, `vcs.pull`, and worktrees (`vcs.createWorktree`,
  `vcs.removeWorktree`), in the shapes of `packages/contracts/src/git.ts`.

  Every change to a checkout refreshes its watched status.
  """

  alias HalC2.Git

  # A big repository's checkout or removal takes minutes.
  @worktree_timeout 300_000

  @refs_limit 100

  # --- status ---------------------------------------------------------------------

  @doc """
  `VcsStatusLocalResult` for a directory; a non-repository, and a checkout whose
  status cannot be read, report `isRepo: false`.
  """
  def local_status(cwd) do
    # A held `index.lock` does not stop `git status`, so a locked checkout is still one.
    case read_local_status(cwd, false) do
      {:ok, status} -> status
      {:error, _reason} -> not_a_repo()
    end
  end

  # `git status` gets 30 seconds, and its output a bound: one cut short would be
  # parsed as a different working tree.
  @status_timeout 30_000
  @status_max_bytes 50_000_000

  @index_locked "Git index is locked. Status will resume when the index lock is removed."

  @doc """
  `{:ok, status}`, or `{:error, reason}` when the index is locked by another git, git ran
  past its time limit or printed more than the limit (`:vcs_status_limits` overrides
  them). A folder that is no repository, or a machine without git, is `{:ok, not a repo}`.
  """
  def read_status(cwd), do: read_local_status(cwd, true)

  @doc "The message for a checkout whose index another git holds, or nil."
  def lock_error(cwd) do
    if File.dir?(cwd) and index_locked?(cwd, 5_000), do: @index_locked
  end

  defp read_local_status(cwd, check_lock?) do
    limits = Application.get_env(:hal_c2, :vcs_status_limits, [])
    max = limits[:max_bytes] || @status_max_bytes

    result =
      if File.dir?(cwd) do
        if check_lock? and index_locked?(cwd, limits[:timeout] || 5_000) do
          {:error, @index_locked}
        else
          Git.run(cwd, ~w(status --porcelain=2 --branch -z --untracked-files=all),
            timeout: limits[:timeout] || @status_timeout,
            max_bytes: max
          )
        end
      end

    case result do
      # No git on this machine: a folder with no `.git` in it is no repository, and
      # says so; one that has it is a checkout git cannot be started for.
      {:error, "git could not be started" <> _} = error ->
        if git_marker?(cwd), do: error, else: {:ok, not_a_repo()}

      {:ok, %{truncated: true}} ->
        {:error, "git status produced too much output (more than #{max} bytes)"}

      {:ok, %{status: 0, out: status}} ->
        {:ok, local_status(cwd, status)}

      {:error, reason} ->
        {:error, reason}

      _not_a_repository ->
        {:ok, not_a_repo()}
    end
  end

  defp git_marker?(dir) do
    File.exists?(Path.join(dir, ".git")) or
      (Path.dirname(dir) != dir and git_marker?(Path.dirname(dir)))
  end

  # Another git holds the index while its `index.lock` exists.
  defp index_locked?(cwd, timeout) do
    case Git.ok(cwd, ~w(rev-parse --git-path index.lock), timeout: timeout) do
      {:ok, path} -> File.exists?(Path.expand(String.trim(path), cwd))
      _ -> false
    end
  end

  defp local_status(cwd, status) do
    branch = parse_branch(status)
    changed = changed_paths(status)
    stats = numstat(cwd)
    default = default_branch(cwd)

    # Untracked and binary files have no line counts but are still changes.
    untracked = MapSet.new(untracked_paths(status))

    # Reading untracked files is bounded (`@untracked_budget`): past it they count none.
    {others, _spent} =
      changed
      |> Enum.reject(&Map.has_key?(stats, &1))
      |> Enum.map_reduce({0, 0}, fn path, budget ->
        untracked_file(cwd, path, MapSet.member?(untracked, path), budget)
      end)

    files =
      (for({path, {ins, del, previous}} <- stats, do: file(path, ins, del, previous)) ++ others)
      |> Enum.sort_by(& &1["path"])

    %{
      "isRepo" => true,
      "hasPrimaryRemote" => Git.primary_remote(cwd) == "origin",
      "isDefaultRef" => default_ref?(branch.head, default),
      "refName" => branch.head,
      "hasWorkingTreeChanges" => changed != [],
      "workingTree" => %{
        "files" => files,
        "insertions" => Enum.sum_by(files, & &1["insertions"]),
        "deletions" => Enum.sum_by(files, & &1["deletions"])
      }
    }
  end

  defp file(path, ins, del, nil), do: %{"path" => path, "insertions" => ins, "deletions" => del}

  defp file(path, ins, del, previous),
    do: file(path, ins, del, nil) |> Map.put("previousPath", previous)

  # An untracked text file counts its lines as all inserted; other changes without line
  # counts (binary, mode only) count none. Files past a megabyte are not read.
  # `path` is one git listed under `cwd`, and a link is never followed (`lstat`).
  @untracked_read_limit 1_000_000
  # A read stops for good once 500 files or 8 MB have been read (upstream #16771: counting
  # thousands of untracked files pegged the CPU); `budget` is `{files, bytes}` spent.
  @untracked_budget {500, 8_000_000}
  # sobelow_skip ["Traversal.FileModule"]
  defp untracked_file(cwd, path, true, {files, bytes} = budget) do
    {max_files, max_bytes} = @untracked_budget
    full = Path.join(cwd, path)

    with true <- files < max_files and bytes < max_bytes,
         {:ok, %{type: :regular, size: size}} when size <= @untracked_read_limit <-
           File.lstat(full),
         {:ok, data} <- File.read(full) do
      # A binary file was read as much as a text one: it spends the budget too.
      budget = {files + 1, bytes + byte_size(data)}
      untracked_lines(path, data, budget)
    else
      _ -> {file(path, 0, 0, nil), budget}
    end
  end

  defp untracked_file(_cwd, path, false, budget), do: {file(path, 0, 0, nil), budget}

  defp untracked_lines(path, data, budget) do
    if String.contains?(data, <<0>>) do
      {file(path, 0, 0, nil), budget}
    else
      lines =
        data
        |> :binary.matches("\n")
        |> length()
        |> Kernel.+(if data == "" or String.ends_with?(data, "\n"), do: 0, else: 1)

      {file(path, lines, 0, nil), budget}
    end
  end

  # Without a known default branch, main and master count as the default.
  defp default_ref?(nil, _default), do: false
  defp default_ref?(head, nil), do: head in ["main", "master"]
  defp default_ref?(head, default), do: head == default

  defp not_a_repo,
    do: %{
      "isRepo" => false,
      "hasPrimaryRemote" => false,
      "isDefaultRef" => false,
      "refName" => nil,
      "hasWorkingTreeChanges" => false,
      "workingTree" => %{"files" => [], "insertions" => 0, "deletions" => 0}
    }

  @doc """
  `VcsStatusRemoteResult`, or nil outside a repository. With `fetch: true` the
  upstream is fetched first so the behind count is current; with `pr: true` the
  branch's change request is looked up on its host (otherwise `pr` is nil), GitHub's
  answered from what the MC already holds of it (`HalC2.PullRequests.Branches`) unless
  `pr: :fresh`.
  """
  def remote_status(cwd, opts \\ []) do
    with true <- File.dir?(cwd),
         {:ok, %{status: 0, out: status}} <- Git.run(cwd, ~w(status --porcelain=2 --branch -z)) do
      branch = parse_branch(status)

      branch =
        if opts[:fetch] && branch.upstream do
          [remote | _] = String.split(branch.upstream, "/", parts: 2)
          Git.run(cwd, ["fetch", "--quiet", "--no-tags", remote], max_bytes: 64 * 1024)
          {:ok, %{out: status}} = Git.run(cwd, ~w(status --porcelain=2 --branch -z))
          parse_branch(status)
        else
          branch
        end

      default = default_branch(cwd)
      base = branch.head && Git.base_branch(cwd, branch.head)
      ahead_of_base = if base, do: count(cwd, "#{base}..HEAD"), else: 0
      default? = default_ref?(branch.head, default)

      %{
        "hasUpstream" => branch.upstream != nil,
        "aheadCount" => if(branch.upstream, do: branch.ahead, else: ahead_of_base),
        "behindCount" => if(branch.upstream, do: branch.behind, else: 0),
        "aheadOfDefaultCount" => if(branch.head && not default?, do: ahead_of_base, else: 0),
        "pr" =>
          if(opts[:pr] && branch.head,
            do: pull_request(cwd, branch.head, default?, opts[:pr] == :fresh)
          )
      }
    else
      _ -> nil
    end
  end

  @doc """
  `vcs.refreshStatus`: both halves, fetched fresh; watchers are told too. A status
  git could not give (it would not start, ran too long, printed too much) is an error.
  """
  def refresh_status(%{"cwd" => cwd}) do
    with {:ok, local} <- read_local_status(cwd, true) do
      remote = remote_status(cwd, fetch: true, pr: :fresh)
      HalC2.Vcs.Watch.publish(cwd, local, remote)
      {:ok, Map.merge(local, remote || empty_remote())}
    else
      {:error, reason} -> {:error, git_error(cwd, "vcs.refreshStatus", reason)}
    end
  end

  # The branch's latest change request on its host: GitHub's through `gh`, the other
  # hosts' through `HalC2.SourceControl.ChangeRequests`. On the default branch only an
  # open one counts: merged or closed matches there are reverse merges.
  @doc "The newest pull request whose head is `branch`, in any state, or nil."
  def branch_pull_request(cwd, branch), do: pull_request(cwd, branch, false, false)

  defp pull_request(cwd, branch, default?, fresh?) do
    with {:ok, url} <- Git.ok(cwd, ~w(remote get-url origin)),
         %{"state" => state} = pr <- host_pull_request(cwd, String.trim(url), branch, fresh?),
         true <- state == "open" or not default? do
      pr
    else
      _ -> nil
    end
  end

  defp host_pull_request(cwd, url, branch, fresh?) do
    if String.contains?(url, "github.com"),
      do: github_pull_request(cwd, branch, fresh?),
      else: other_host_change_request(cwd, url, branch)
  end

  # Asked once for every reader of the branch (`HalC2.PullRequests.Branches`).
  # Unauthenticated, offline or rate limited `gh` means no pull request, quietly.
  defp github_pull_request(cwd, branch, fresh?) do
    case HalC2.PullRequests.Branches.pull_request(cwd, branch, fresh: fresh?) do
      {:ok, %{} = pr} ->
        Map.take(pr, ~w(number title url baseRef headRef headSha state isDraft updatedAt))

      _ ->
        nil
    end
  end

  # A host that does not answer in ten seconds has no change request, as with `gh`.
  defp other_host_change_request(cwd, url, branch) do
    with %{} = remote <- HalC2.PullRequests.parse_remote(url) do
      remote = Map.put(remote, :url, url)

      task =
        Task.async(fn -> HalC2.SourceControl.ChangeRequests.for_branch(cwd, remote, branch) end)

      case Task.yield(task, 10_000) || Task.shutdown(task, :brutal_kill) do
        {:ok, change_request} -> change_request
        _ -> nil
      end
    end
  end

  defp empty_remote,
    do: %{"hasUpstream" => false, "aheadCount" => 0, "behindCount" => 0, "pr" => nil}

  defp parse_branch(status) do
    status
    |> String.split(<<0>>)
    |> Enum.reduce(%{head: nil, upstream: nil, ahead: 0, behind: 0}, fn
      "# branch.head " <> head, acc ->
        %{acc | head: if(String.starts_with?(head, "("), do: nil, else: head)}

      "# branch.upstream " <> upstream, acc ->
        %{acc | upstream: upstream}

      "# branch.ab " <> ab, acc ->
        case Regex.run(~r/^\+(\d+) -(\d+)$/, ab) do
          [_, ahead, behind] ->
            %{acc | ahead: String.to_integer(ahead), behind: String.to_integer(behind)}

          _ ->
            acc
        end

      _, acc ->
        acc
    end)
  end

  # Paths of changed entries in `git status --porcelain=2 -z`. A rename (`2`) is
  # followed by a record holding its original path, which is skipped.
  defp changed_paths(status) do
    status
    |> String.split(<<0>>, trim: true)
    |> parse_changed([])
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp untracked_paths(status) do
    for "? " <> path <- String.split(status, <<0>>, trim: true), do: path
  end

  defp parse_changed([], acc), do: acc
  defp parse_changed(["#" <> _ | rest], acc), do: parse_changed(rest, acc)

  defp parse_changed(["1 " <> fields | rest], acc),
    do: parse_changed(rest, [fields |> String.split(" ", parts: 8) |> List.last() | acc])

  defp parse_changed(["2 " <> fields | rest], acc) do
    path = fields |> String.split(" ", parts: 9) |> List.last()
    parse_changed(Enum.drop(rest, 1), [path | acc])
  end

  defp parse_changed(["u " <> fields | rest], acc),
    do: parse_changed(rest, [fields |> String.split(" ", parts: 10) |> List.last() | acc])

  defp parse_changed(["? " <> path | rest], acc), do: parse_changed(rest, [path | acc])
  defp parse_changed([_ | rest], acc), do: parse_changed(rest, acc)

  # Line counts against HEAD; before the first commit, staged plus unstaged.
  defp numstat(cwd) do
    case Git.run(cwd, ~w(diff HEAD --numstat -z --)) do
      {:ok, %{status: 0, out: out}} ->
        parse_numstat(out)

      _ ->
        Map.merge(
          numstat_of(cwd, ~w(diff --numstat -z)),
          numstat_of(cwd, ~w(diff --cached --numstat -z)),
          fn _, {a, b, p}, {c, d, q} -> {a + c, b + d, p || q} end
        )
    end
  end

  defp numstat_of(cwd, args) do
    case Git.ok(cwd, args) do
      {:ok, out} -> parse_numstat(out)
      _ -> %{}
    end
  end

  defp parse_numstat(out) do
    for %{"path" => path, "additions" => ins, "deletions" => del} = stat <-
          HalC2.Review.numstat(out),
        into: %{},
        do: {path, {ins, del, stat["previousPath"]}}
  end

  defp default_branch(cwd) do
    case Git.ok(cwd, ~w(symbolic-ref refs/remotes/origin/HEAD)) do
      {:ok, "refs/remotes/origin/" <> branch} -> String.trim(branch)
      _ -> nil
    end
  end

  defp count(cwd, range) do
    case Git.ok(cwd, ["rev-list", "--count", range]) do
      {:ok, n} -> String.to_integer(String.trim(n))
      _ -> 0
    end
  end

  # --- refs -----------------------------------------------------------------------

  @doc """
  `vcs.listRefs`: the current and default refs first, then by last commit; remote
  refs that mirror a local branch are left out unless asked for.
  """
  def list_refs(%{"cwd" => cwd} = input) do
    with true <- File.dir?(cwd),
         {:ok, root} <- Git.ok(cwd, ~w(rev-parse --show-toplevel)) do
      root = String.trim(root)
      remotes = remotes(cwd)
      default = default_branch(cwd)
      worktrees = worktree_branches(cwd)
      current = Git.current_branch(cwd)
      in_worktree = Enum.any?(worktrees, fn {_, path} -> path == root end)

      {:ok, out} =
        Git.ok(
          cwd,
          ~w(for-each-ref --format=%\(refname\)%09%\(committerdate:unix\)%09%\(symref\) refs/heads refs/remotes)
        )

      {locals, remote_refs} =
        out
        |> String.split("\n", trim: true)
        |> Enum.map(&String.split(&1, "\t"))
        |> Enum.filter(&match?([_, _, ""], &1))
        |> Enum.map(fn [ref, time, _] -> {ref, String.to_integer(time)} end)
        |> Enum.sort_by(fn {ref, time} -> {-time, ref} end)
        |> Enum.split_with(fn {ref, _} -> String.starts_with?(ref, "refs/heads/") end)

      locals =
        for {"refs/heads/" <> name, _} <- locals do
          path = worktrees[name]

          %{
            "name" => name,
            "current" => if(in_worktree, do: path == root, else: name == current),
            "isRemote" => false,
            "isDefault" => name == default,
            "worktreePath" => path
          }
        end

      remote_refs =
        for {"refs/remotes/" <> name, _} <- remote_refs do
          remote = Enum.find(remotes, &String.starts_with?(name, &1 <> "/"))
          branch = remote && String.replace_prefix(name, remote <> "/", "")

          %{
            "name" => name,
            "current" => false,
            "isRemote" => true,
            "isDefault" => remote == "origin" and branch == default,
            "worktreePath" => nil
          }
          |> then(&if(remote, do: Map.put(&1, "remoteName", remote), else: &1))
        end

      local_names = MapSet.new(locals, & &1["name"])

      remote_refs =
        if input["includeMatchingRemoteRefs"],
          do: remote_refs,
          else:
            Enum.reject(remote_refs, fn ref ->
              ref["remoteName"] == "origin" and
                MapSet.member?(local_names, String.replace_prefix(ref["name"], "origin/", ""))
            end)

      query = input["query"] && String.downcase(input["query"])

      refs =
        (locals ++ remote_refs)
        |> Enum.sort_by(fn ref ->
          cond do
            ref["current"] -> 0
            ref["isDefault"] -> 1
            true -> 2
          end
        end)
        |> Enum.filter(fn ref ->
          case input["refKind"] do
            "local" -> not ref["isRemote"]
            "remote" -> ref["isRemote"]
            _ -> true
          end
        end)
        |> Enum.filter(&(query == nil or String.contains?(String.downcase(&1["name"]), query)))

      cursor = input["cursor"] || 0
      limit = input["limit"] || @refs_limit
      page = refs |> Enum.drop(cursor) |> Enum.take(limit)
      total = length(refs)

      {:ok,
       %{
         "refs" => page,
         "isRepo" => true,
         "hasPrimaryRemote" => "origin" in remotes,
         "nextCursor" => if(cursor + length(page) < total, do: cursor + length(page)),
         "totalCount" => total
       }}
    else
      _ ->
        {:ok,
         %{
           "refs" => [],
           "isRepo" => false,
           "hasPrimaryRemote" => false,
           "nextCursor" => nil,
           "totalCount" => 0
         }}
    end
  end

  defp remotes(cwd) do
    case Git.ok(cwd, ["remote"]) do
      {:ok, out} -> out |> String.split("\n", trim: true) |> Enum.sort_by(&(-String.length(&1)))
      _ -> []
    end
  end

  # Branch name to the worktree it is checked out in, for worktrees still on disk.
  defp worktree_branches(cwd) do
    case Git.ok(cwd, ~w(worktree list --porcelain -z)) do
      {:ok, out} ->
        out
        |> String.split(<<0, 0>>, trim: true)
        |> Enum.flat_map(fn entry ->
          fields = String.split(entry, <<0>>, trim: true)

          path =
            Enum.find_value(
              fields,
              &(match?("worktree " <> _, &1) && String.replace_prefix(&1, "worktree ", ""))
            )

          branch =
            Enum.find_value(
              fields,
              &(match?("branch refs/heads/" <> _, &1) &&
                  String.replace_prefix(&1, "branch refs/heads/", ""))
            )

          prunable = Enum.any?(fields, &String.starts_with?(&1, "prunable"))

          if path && branch && not prunable && File.dir?(path), do: [{branch, path}], else: []
        end)
        |> Map.new()

      _ ->
        %{}
    end
  end

  @doc """
  `vcs.switchRef`. A remote ref checks out the local branch tracking it, creating
  one when there is none.
  """
  def switch_ref(%{"cwd" => cwd, "refName" => ref}) do
    local? = ref?(cwd, "refs/heads/#{ref}")
    remote? = ref?(cwd, "refs/remotes/#{ref}")
    tracking = if remote?, do: tracking_branch(cwd, ref)
    derived = ref |> String.split("/", parts: 2) |> List.last()

    args =
      cond do
        local? -> ["checkout", ref]
        remote? and tracking -> ["checkout", tracking]
        remote? and ref?(cwd, "refs/heads/#{derived}") -> ["checkout", ref]
        remote? -> ["checkout", "--track", ref]
        true -> ["checkout", ref]
      end

    # A stale ref must not turn into a path checkout that discards local edits.
    with :ok <- run(cwd, args ++ ["--"], "vcs.switchRef", "git checkout failed") do
      changed(cwd)
      {:ok, %{"refName" => Git.current_branch(cwd)}}
    end
  end

  defp tracking_branch(cwd, remote_ref) do
    case Git.ok(
           cwd,
           ~w(for-each-ref --format=%\(refname:short\)%09%\(upstream:short\) refs/heads)
         ) do
      {:ok, out} ->
        Enum.find_value(String.split(out, "\n", trim: true), fn line ->
          case String.split(line, "\t") do
            [branch, ^remote_ref] -> branch
            _ -> nil
          end
        end)

      _ ->
        nil
    end
  end

  @doc "`vcs.createRef`: a branch at HEAD, switched to when asked."
  def create_ref(%{"cwd" => cwd, "refName" => ref} = input) do
    with :ok <- run(cwd, ["branch", ref], "vcs.createRef", "git branch create failed"),
         {:ok, _} <- if(input["switchRef"], do: switch_ref(input), else: {:ok, nil}) do
      changed(cwd)
      {:ok, %{"refName" => ref}}
    end
  end

  @doc "`vcs.init`."
  def init(%{"cwd" => cwd}) do
    case Git.run(cwd, ["init"]) do
      {:ok, %{status: 0}} ->
        changed(cwd)
        {:ok, nil}

      result ->
        {:error,
         %{
           "_tag" => "VcsProcessExitError",
           "operation" => "vcs.init",
           "command" => "git init",
           "cwd" => cwd,
           "exitCode" => exit_code(result),
           "detail" => "git init failed",
           "message" => "git init failed in #{cwd}"
         }}
    end
  end

  @doc "`vcs.pull`: a fast-forward pull of the current branch from its upstream."
  def pull(%{"cwd" => cwd}) do
    status = remote_status(cwd)
    branch = Git.current_branch(cwd)

    cond do
      branch == nil ->
        {:error, git_error(cwd, "vcs.pull", "Cannot pull from detached HEAD.")}

      status == nil or not status["hasUpstream"] ->
        {:error,
         git_error(
           cwd,
           "vcs.pull",
           "Current branch has no upstream configured. Push with upstream first."
         )}

      true ->
        before = head(cwd)

        with :ok <- run(cwd, ~w(pull --ff-only), "vcs.pull", "git pull failed") do
          changed(cwd)

          upstream =
            case Git.ok(cwd, ~w(rev-parse --abbrev-ref --symbolic-full-name @{upstream})) do
              {:ok, ref} -> String.trim(ref)
              _ -> nil
            end

          {:ok,
           %{
             "status" =>
               if(before != nil and before == head(cwd), do: "skipped_up_to_date", else: "pulled"),
             "refName" => branch,
             "upstreamRef" => upstream
           }}
        end
    end
  end

  defp head(cwd) do
    case Git.ok(cwd, ~w(rev-parse HEAD)) do
      {:ok, sha} -> String.trim(sha)
      _ -> nil
    end
  end

  # --- worktrees ------------------------------------------------------------------

  @doc """
  `vcs.createWorktree`: checks out `refName` (or a new branch from it) in a new
  worktree, by default `<home>/worktrees/<repo>/<branch>`, with its submodules. A new
  branch remembers the branch it started from, for its pull request. `:on_progress` is
  called with the share of files checked out as git reports it.
  """
  def create_worktree(%{"cwd" => cwd, "refName" => ref} = input, opts \\ []) do
    branch = input["newRefName"] || ref
    path = input["path"] || worktree_path(cwd, branch)

    args =
      if input["newRefName"],
        # No upstream yet: a new branch started from `origin/dev` must not push to `dev`.
        do: ["worktree", "add", "--no-track", "-b", input["newRefName"], path, ref],
        else: ["worktree", "add", path, ref]

    fresh = not File.exists?(path)
    new_branch = input["newRefName"] && not branch?(cwd, input["newRefName"])

    with :ok <-
           run(
             cwd,
             args,
             "vcs.createWorktree",
             "git worktree add failed",
             [timeout: worktree_timeout(), stop_children: path] ++
               checkout_progress(opts[:on_progress])
           )
           |> tap(&if(fresh, do: clear_cut_short(&1, cwd, path, if(new_branch, do: branch)))) do
      if input["newRefName"], do: remember_base(cwd, input["newRefName"], ref)

      # `git worktree add` leaves submodules empty; filling them is best effort.
      # `HalC2.WorktreeSetup` passes `"submodules" => false` and fills them as its own stage.
      if input["submodules"] != false, do: init_submodules(cwd, path)
      changed(cwd)
      {:ok, %{"worktree" => %{"path" => path, "refName" => branch}}}
    end
  end

  # Git stopped before it could say anything, by the time limit, has not cleaned up after
  # itself as a git that fails does: what it left is the locked worktree and the branch
  # it was to make (`branch`, nil when there was none or it was there before), in a path
  # that was free. A git that fails cleans up its worktree but keeps the branch.
  defp clear_cut_short({:error, error}, cwd, path, branch)
       when not is_map_key(error, "exitCode"),
       do: clear_worktree(cwd, path, branch)

  defp clear_cut_short({:error, _}, cwd, _path, branch) when is_binary(branch) do
    Git.run(cwd, ["branch", "-D", branch])
    changed(cwd)
  end

  defp clear_cut_short(_result, _cwd, _path, _branch), do: :ok

  @doc """
  Takes away a worktree this MC made in a folder that was free, whole or cut short: the
  folder, git's record of it, and `branch` when that is one it made too (else nil), or
  the names in a list when it may have either.
  What git started for it must have stopped (`Git.stop_children/1`).
  """
  def clear_worktree(cwd, path, branch) do
    Git.run(cwd, ["worktree", "unlock", path])
    Git.run(cwd, ["worktree", "remove", "--force", path], timeout: worktree_timeout())
    File.rm_rf(path)
    Git.run(cwd, ["worktree", "prune"])
    for name <- List.wrap(branch), do: Git.run(cwd, ["branch", "-D", name])
    changed(cwd)
  end

  @doc "Whether `name` is a local branch of the checkout `cwd`."
  def branch?(cwd, name), do: ref?(cwd, "refs/heads/#{name}")

  @doc "How long `git worktree add` and `git worktree remove` may run, in ms."
  def worktree_timeout, do: Application.get_env(:hal_c2, :worktree_timeout, @worktree_timeout)

  # Git holds its progress back for a moment and words it for the locale; this asks for
  # it at once, in English. Each write is one percent more, so at most a hundred calls.
  defp checkout_progress(nil), do: []

  defp checkout_progress(on_progress) do
    [
      env: [{"GIT_PROGRESS_DELAY", "0"}, {"LC_ALL", "C"}],
      on_stderr: fn data ->
        case Regex.scan(~r/Updating files:\s+(\d+)%/, data) |> List.last() do
          [_, percent] -> on_progress.(String.to_integer(percent))
          nil -> :ok
        end
      end
    ]
  end

  # `branch.<name>.gh-merge-base`, which `Git.base_branch/2` reads: `ref` without its
  # remote, when it is a branch at all and not a tag or a commit.
  defp remember_base(cwd, branch, ref) do
    base =
      cond do
        ref?(cwd, "refs/heads/#{ref}") -> ref
        ref?(cwd, "refs/remotes/#{ref}") -> ref |> String.split("/", parts: 2) |> List.last()
        true -> nil
      end

    if base, do: Git.run(cwd, ["config", "branch.#{branch}.gh-merge-base", base])
  end

  @doc """
  Renames the branch `old` of the checkout `cwd` to `new`, or to `new-1` through
  `new-100` when that is taken: `{:ok, name}`, or `{:error, message}` leaving it as it was.
  `on_name` hears the name before git takes it; `Git.stop_children(cwd)` stops the rename.
  """
  def rename_branch(cwd, old, new, on_name \\ fn _name -> :ok end) do
    candidates = [new | Enum.map(1..100, &"#{new}-#{&1}")]

    case Enum.find(candidates, &branch_free?(cwd, &1)) do
      nil ->
        {:error, "Could not find an available branch name for '#{new}'."}

      name ->
        on_name.(name)

        case Git.ok(cwd, ["branch", "-m", "--", old, name], stop_children: cwd) do
          {:ok, _} -> {:ok, name}
          {:error, {_status, err}} -> {:error, err}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp branch_free?(cwd, name),
    do: not ref?(cwd, "refs/heads/#{name}") and not Git.branch_path_taken?(cwd, name)

  @doc "Where a new worktree of `cwd` on `branch` goes when no path is given."
  def worktree_path(cwd, branch) do
    Path.join([
      HalC2.Paths.data_dir(),
      "worktrees",
      Path.basename(cwd),
      String.replace(branch, "/", "-")
    ])
  end

  @doc """
  Fills the submodules of the new worktree at `path` (of the checkout `cwd`) as
  deep as the settings say. Returns `:none` when it has no submodules or they stay
  empty, `:ok` when they were filled, or `{:error, detail}`.
  """
  def init_submodules(cwd, path) do
    args =
      if File.exists?(Path.join(path, ".gitmodules")) do
        case submodules(cwd, path) do
          "none" -> nil
          "top-level" -> ~w(submodule update --init)
          _recursive -> ~w(submodule update --init --recursive)
        end
      end

    case args && Git.run(path, args) do
      nil -> :none
      {:ok, %{status: 0}} -> :ok
      {:ok, %{err: err}} -> {:error, String.trim(err)}
      {:error, reason} -> {:error, reason}
    end
  end

  # How deep a new worktree's submodules go: the project's settings, else the
  # checkout's hal-c2.json, else every level.
  defp submodules(cwd, worktree) do
    HalC2.Settings.for_project(HalC2.Projects.at(cwd))["worktreeSubmodules"] ||
      with {:ok, text} <- HalC2.ProjectFile.read(worktree),
           {:ok, %{"worktreeSubmodules" => mode}} <- JSON.decode(text) do
        mode
      else
        _ -> "recursive"
      end
  end

  @doc "`vcs.removeWorktree`; a worktree that is already gone is pruned instead."
  def remove_worktree(%{"cwd" => cwd, "path" => path} = input) do
    args = ["worktree", "remove"] ++ if(input["force"], do: ["--force"], else: []) ++ [path]

    case Git.run(cwd, args, timeout: worktree_timeout()) do
      {:ok, %{status: 0}} ->
        changed(cwd)
        {:ok, nil}

      {:ok, _} ->
        if File.exists?(path) do
          {:error, git_error(cwd, "vcs.removeWorktree", "git worktree remove failed")}
        else
          Git.run(cwd, ~w(worktree prune))
          changed(cwd)
          {:ok, nil}
        end

      {:error, reason} ->
        {:error, git_error(cwd, "vcs.removeWorktree", reason)}
    end
  end

  # --- helpers --------------------------------------------------------------------

  defp changed(cwd), do: HalC2.Vcs.Watch.refresh(cwd)

  defp ref?(cwd, ref), do: match?({:ok, _}, Git.ok(cwd, ["show-ref", "--verify", "--quiet", ref]))

  defp run(cwd, args, operation, detail, opts \\ []) do
    case Git.run(cwd, args, [max_bytes: 1024 * 1024] ++ opts) do
      {:ok, %{status: 0}} ->
        :ok

      {:ok, %{status: status, err: err}} ->
        # Git's own message says what went wrong ("would be overwritten", ...): its
        # error lines when it marks them, else the end of what it printed.
        lines = err |> String.trim() |> String.split("\n", trim: true)
        said = Enum.filter(lines, &String.starts_with?(&1, ["error: ", "fatal: "]))
        message = if(said == [], do: Enum.take(lines, -3), else: said) |> Enum.join(" ")

        {:error,
         git_error(cwd, operation, if(message == "", do: detail, else: message))
         |> Map.merge(%{
           "command" => "git #{hd(args)}",
           "exitCode" => exit_code({:ok, %{status: status}})
         })}

      {:error, reason} ->
        {:error, git_error(cwd, operation, reason)}
    end
  end

  defp exit_code({:ok, %{status: status}}) when is_integer(status), do: status
  defp exit_code(_), do: nil

  defp git_error(cwd, operation, detail),
    do: %{
      "_tag" => "GitCommandError",
      "operation" => operation,
      "command" => "git",
      "cwd" => cwd,
      "detail" => to_string(detail),
      "message" => "Git command failed in #{operation} (#{cwd}): #{detail}"
    }
end
