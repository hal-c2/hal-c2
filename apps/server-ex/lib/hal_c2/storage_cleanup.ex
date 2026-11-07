defmodule HalC2.StorageCleanup do
  @moduledoc """
  Removes what the user's storage settings say may go:
  thread worktrees under `<home>/worktrees` (after days idle, days after their
  thread settled, once merged, once their thread is deleted, or when their branch
  is already in the default branch), browser artifacts and rotated logs (`*.log.N`,
  `*.ndjson.N` under `<home>/logs`) past their age, and threads' temp folders
  (`HalC2.Scratch`), the one rule on by default, since nothing in them is anyone's
  to keep.

  A sweep runs an hour apart and when the cleanup settings change. It is
  deliberately timid: a worktree goes only when one thread owns it (alone, or with
  the subagents it delegated to on its branch), all of them idle, nothing (a
  terminal, a provider session, another project, unpublished submodule work)
  lives in it, it is a linked checkout on the thread's branch with nothing to lose,
  and all of that still holds, with the same rules, just before removal. What there
  is to lose is the rules' `worktreeKeepWhen`: "any-local-files" (the default)
  counts changed, untracked and ignored files besides `node_modules`;
  "uncommitted-changes" leaves out ignored files; "tracked-changes" counts only
  edits to tracked files, and the removal cleans away the untracked ones first. A
  repository nested in the worktree, outside `node_modules`, keeps it under every
  choice. Any other choice counts as "any-local-files".
  The last look and the removal hold the worktree's `HalC2.WorkspaceLease`, which
  terminals take while they start. The branch and path stay on the thread, so it
  can check the worktree out again.

  Each sweep's worktree results, removed, kept or failed and why, are its report
  (`report/0`).
  """

  use GenServer

  require Logger

  alias HalC2.Git

  @day_ms 86_400_000
  # Gives a project's settle script time to open the terminal that protects its worktree.
  @settle_grace_ms 60_000
  @measure_ms 30_000
  @report_limit 200
  @idle ~w(idle failed completed interrupted cancelled rolled_back)
  @off %{
    "worktreeKeepWhen" => "any-local-files",
    "worktreeAfterDays" => nil,
    "worktreeSettledAfterDays" => nil,
    "worktreeOnMerge" => false,
    "worktreeOnDelete" => false,
    "worktreeUnchanged" => false
  }

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Runs a sweep now and waits for it."
  def sweep, do: GenServer.call(__MODULE__, :sweep, :timer.minutes(5))

  @doc """
  The last sweep's worktree results, nil before the first: a list of
  `%{"kind" => "worktree", "outcome" => "removed" | "kept" | "failed", "reason",
  "path", "projectPath", "threadId", "threadTitle", "bytes"}`, failures and
  removals first, at most #{@report_limit}.
  """
  def report, do: GenServer.call(__MODULE__, :report)

  @doc "The worktree rules for a project: its override, else the environment's."
  def rules(settings, project_id) do
    case HalC2.Settings.resolve(settings, project_id)["worktreeCleanup"] do
      %{"mode" => "custom", "rules" => rules} -> Map.merge(@off, rules)
      %{"mode" => "off"} -> @off
      _ -> Map.merge(@off, Map.take(settings["storageCleanup"] || %{}, Map.keys(@off)))
    end
    |> Map.update!("worktreeKeepWhen", &keep_when/1)
  end

  # A choice this MC does not know (a typo, a newer client's) keeps the most.
  defp keep_when(choice) when choice in ["uncommitted-changes", "tracked-changes"], do: choice
  defp keep_when(_), do: "any-local-files"

  @impl true
  def init(nil) do
    HalC2.Settings.watch(self())
    timer = schedule(Application.get_env(:hal_c2, :storage_cleanup_first_ms, 60_000))
    {:ok, %{policy: current_policy(), timer: timer, report: nil}}
  end

  @impl true
  def handle_call(:sweep, _from, state), do: {:reply, :ok, %{state | report: run()}}

  def handle_call(:report, _from, state), do: {:reply, state.report, state}

  @impl true
  def handle_info(:tick, state) do
    {:noreply, %{state | report: run(), timer: schedule(:timer.hours(1))}}
  end

  # A changed policy is applied at once; other settings changes are not a reason to sweep.
  def handle_info({:hal_c2_settings, _mc, settings}, state) do
    policy = policy(settings)

    state =
      if state.policy != nil and policy != state.policy,
        do: %{state | report: run()},
        else: state

    {:noreply, %{state | policy: policy}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule(nil), do: nil
  defp schedule(ms), do: Process.send_after(self(), :tick, ms)

  # Held from the start, so the first change after it sweeps too.
  defp current_policy do
    policy(HalC2.Settings.settings())
  catch
    :exit, _ -> nil
  end

  defp policy(settings) do
    overrides =
      for {id, %{"worktreeCleanup" => rule}} <- settings["projectSettingsOverrides"] || %{},
          do: {id, rule}

    {settings["storageCleanup"], settings["worktreeCleanup"], Map.new(overrides)}
  end

  defp run do
    settings = HalC2.Settings.settings()
    now = System.system_time(:millisecond)

    report =
      try do
        worktrees(settings, now)
      rescue
        error ->
          Logger.warning("worktree cleanup failed: #{Exception.message(error)}")
          []
      end

    HalC2.Scratch.clear_leftovers()

    # An empty sidebar has not been read yet, and every folder would look like nobody's.
    if HalC2.Shell.rows() != [],
      do: HalC2.Scratch.sweep(scratch_threads(), HalC2.Scratch.idle_days(settings), now)

    for {dir, key} <- [
          {Path.join(HalC2.Paths.data_dir(), "browser-artifacts"), "browserArtifactsAfterDays"},
          {Path.join(HalC2.Paths.state_dir(), "logs"), "logsAfterDays"}
        ],
        do: files(dir, key, get_in(settings, ["storageCleanup", key]), now)

    report
  end

  # This MC's threads as `HalC2.Scratch.stale/4` reads them, a live session or a
  # background task keeping a thread running however long ago its last turn was.
  defp scratch_threads do
    for {{mc, id}, {"thread", thread}} <- HalC2.Shell.rows(),
        mc == node(),
        thread["deletedAt"] == nil do
      running? =
        thread["activeRunId"] != nil or (thread["pendingBackgroundTasks"] || []) != [] or
          session?(id)

      {id, activity_at(thread), running?}
    end
  end

  # --- worktrees -----------------------------------------------------------------

  defp worktrees(settings, now) do
    root = worktrees_root()
    {projects, threads} = local_rows()

    if any_policy?(settings, projects) and File.dir?(root) do
      {:ok, root} = real(root)
      {deleted, live} = Enum.split_with(threads, &(&1["deletedAt"] != nil))
      groups = Enum.group_by(live, &path/1)
      deleted_by_path = Enum.group_by(deleted, &path/1)

      # A deleted thread still owns the worktree its remaining subagents share, but
      # only its deletion rule acts on it; otherwise the live threads' owner does.
      candidates =
        for({path, group} <- groups) do
          Enum.find(deleted_by_path[path] || [], fn thread ->
            rules(settings, thread["projectId"])["worktreeOnDelete"] and
              owner([thread | group]) == thread
          end) || owner(group) || hd(group)
        end ++ Enum.reject(deleted, &Map.has_key?(groups, path(&1)))

      context = %{settings: settings, projects: projects, root: root, now: now}

      {entries, _memo} =
        Enum.reduce(candidates, {[], %{}}, fn thread, {entries, memo} ->
          group = groups[path(thread)] || []
          {entry, memo} = clean(thread, group, context, memo)
          {if(entry, do: [entry | entries], else: entries), memo}
        end)

      entries
      |> Enum.reverse()
      |> Enum.sort_by(&Map.fetch!(%{"failed" => 0, "removed" => 1, "kept" => 2}, &1["outcome"]))
      |> Enum.take(@report_limit)
    else
      []
    end
  end

  defp local_rows do
    rows = for {{mc, _id}, row} <- HalC2.Shell.rows(), mc == node(), do: row
    projects = for {"project", project} <- rows, into: %{}, do: {project["id"], project}
    threads = for {"thread", thread} <- rows, is_binary(thread["worktreePath"]), do: thread
    {projects, threads}
  end

  defp path(thread), do: Path.expand(thread["worktreePath"])

  defp any_policy?(settings, projects) do
    ids = [nil | Map.keys(settings["projectSettingsOverrides"] || %{}) ++ Map.keys(projects)]
    Enum.any?(ids, &enabled?(rules(settings, &1)))
  end

  defp enabled?(rules) do
    rules["worktreeAfterDays"] != nil or rules["worktreeSettledAfterDays"] != nil or
      rules["worktreeOnMerge"] or rules["worktreeOnDelete"] or rules["worktreeUnchanged"]
  end

  @doc """
  The one thread that owns a worktree `threads` share: the only one, or the top of
  a chain of subagents (or side chats) under one root. Nil when they are not that.
  """
  def owner([thread]), do: thread

  def owner(threads) do
    by_id = Map.new(threads, &{&1["id"], &1})
    lineage = &(&1["lineage"] || %{})

    case Enum.reject(threads, &Map.has_key?(by_id, lineage.(&1)["parentThreadId"])) do
      [top] ->
        root = lineage.(top)["rootThreadId"]

        chained? = fn chained?, thread, seen ->
          line = lineage.(thread)
          parent = by_id[line["parentThreadId"]]

          thread["id"] == top["id"] or
            (thread["id"] not in seen and
               (line["relationshipToParent"] == "subagent" or line["sideChat"] == true) and
               line["rootThreadId"] == root and parent != nil and
               chained?.(chained?, parent, [thread["id"] | seen]))
        end

        if Enum.all?(threads, &chained?.(chained?, &1, [])), do: top

      _ ->
        nil
    end
  end

  # One worktree: `{entry | nil, memo}`, nil when there was nothing to look at. `memo`
  # holds the default branches asked for and fetched this sweep, by repository.
  defp clean(thread, group, context, memo) do
    rules = rules(context.settings, thread["projectId"])
    path = path(thread)
    project = context.projects[thread["projectId"]]

    entry = %{
      "kind" => "worktree",
      "outcome" => "kept",
      "path" => path,
      "projectPath" => project && project["workspaceRoot"],
      "threadId" => thread["id"],
      "threadTitle" => thread["title"],
      "bytes" => nil
    }

    look = %{thread: thread, group: group, rules: rules, path: path, project: project}

    try do
      if enabled?(rules) and File.exists?(path) do
        case decide(look, context, memo) do
          {:keep, reason, memo} ->
            {Map.put(entry, "reason", reason), memo}

          {:remove, reason, head, memo} ->
            case HalC2.WorkspaceLease.with_lease(path, fn -> remove(look, head) end) do
              {:removed, bytes} ->
                Logger.info("storage cleanup removed the worktree of #{thread["id"]}")
                removed = Map.merge(entry, %{"outcome" => "removed", "bytes" => bytes})
                {Map.put(removed, "reason", reason), memo}

              {:keep, reason} ->
                {Map.put(entry, "reason", reason), memo}
            end
        end
      else
        {nil, memo}
      end
    rescue
      error ->
        reason = error |> Exception.message() |> String.split("\n") |> hd()
        Logger.warning("storage cleanup failed for #{thread["id"]}: #{reason}")
        {Map.merge(entry, %{"outcome" => "failed", "reason" => reason}), memo}
    end
  end

  # The first look, outside the lease: `{:remove, reason, head, memo}` or
  # `{:keep, reason, memo}`.
  defp decide(%{thread: thread, group: group, rules: rules, path: path} = look, context, memo) do
    deleted = deleted?(thread)
    members = if deleted, do: [thread | group], else: group

    keep =
      cond do
        deleted and not rules["worktreeOnDelete"] ->
          "No rules apply"

        length(members) > 1 and owner(members) == nil ->
          "Shared by #{length(members)} threads"

        look.project == nil ->
          "Project is unavailable"

        thread["branch"] == nil or not Enum.all?(group, &idle?/1) ->
          "Thread is running or has pending work"

        Enum.any?(group, &(&1["branch"] != thread["branch"])) ->
          "A subagent thread's branch differs from this worktree's branch"

        reason = busy(path) ->
          reason

        reason = checkout(path, context.root, thread["branch"], Map.values(context.projects)) ->
          reason

        reason = local_changes(path, rules["worktreeKeepWhen"]) ->
          reason

        settled_moments_ago?(group, context.now) ->
          "Settled moments ago"

        true ->
          nil
      end

    if keep do
      {:keep, keep, memo}
    else
      {:ok, head} = git(path, ~w(rev-parse HEAD))
      eligible(look, head, context.now, memo)
    end
  end

  defp deleted?(thread), do: thread["deletedAt"] != nil

  # Idle with nothing pending; a live session is checked separately (`busy/1`).
  defp idle?(thread) do
    thread["activeRunId"] == nil and thread["status"] in @idle and
      (thread["pendingBackgroundTasks"] || []) == [] and thread["pendingRuntimeRequest"] == nil
  end

  defp settled_moments_ago?(group, now) do
    Enum.any?(group, fn thread ->
      at = millis(thread["settledAt"])
      at != nil and now - max(at, activity_at(thread)) < @settle_grace_ms
    end)
  end

  # Why the worktree is in use: a running terminal, or a provider session of a
  # thread, working in it. Nil when nothing is.
  defp busy(path) do
    terminal? =
      Enum.any?(HalC2.Terminal.Hub.summaries(), fn t ->
        t["status"] in ["starting", "running"] and
          ((is_binary(t["worktreePath"]) and Path.expand(t["worktreePath"]) == path) or
             within?(Path.expand(t["cwd"] || "/"), path))
      end)

    session? =
      Enum.any?(HalC2.Shell.rows(), fn
        {{mc, id}, {"thread", %{"worktreePath" => wt}}} when mc == node() and is_binary(wt) ->
          within?(Path.expand(wt), path) and session?(id)

        _ ->
          false
      end)

    cond do
      terminal? -> "Open terminal"
      session? -> "Provider session is still open"
      true -> nil
    end
  end

  defp session?(thread_id) do
    Enum.any?(
      [
        HalC2.Codex.Registry,
        HalC2.Claude.Registry,
        HalC2.Acp.Registry,
        HalC2.Pi.Registry,
        HalC2.Muse.Registry
      ],
      &(Process.whereis(&1) != nil and Registry.lookup(&1, thread_id) != [])
    )
  end

  # Why `path` is not a linked checkout of `branch` of its own under the worktrees
  # root, holding no project. Nil when it is.
  defp checkout(path, root, branch, projects) do
    {:ok, parent} = real(Path.dirname(path))

    cond do
      real(path) != {:ok, Path.join(parent, Path.basename(path))} ->
        "Worktree is a symbolic link"

      not within?(path, root) or path == root ->
        "Outside the managed worktree folder"

      holds_project?(path, projects) ->
        "Contains a project checkout"

      not match?({:ok, %File.Stat{type: :regular}}, File.stat(Path.join(path, ".git"))) ->
        "Not a linked worktree"

      git(path, ~w(symbolic-ref --quiet HEAD)) != {:ok, "refs/heads/#{branch}"} ->
        "Repository or branch changed"

      true ->
        nil
    end
  end

  defp holds_project?(path, projects) do
    Enum.any?(projects, fn %{"workspaceRoot" => root} ->
      root = Path.expand(root)
      within?(root, path) or within?(real_or_self(root), path)
    end)
  end

  # Why the checkout at `path` has something to lose under `keep_when`: changed or
  # staged files, untracked ones (whatever the repository's own status settings
  # hide) unless only tracked edits count, and, for "any-local-files", ignored
  # files besides installed dependencies, which can be secrets or local data. Nil
  # when it has none.
  defp local_changes(path, keep_when) do
    untracked = if keep_when == "tracked-changes", do: "no", else: "all"
    status = ~w(status --porcelain=v1 -z --ignore-submodules=none --untracked-files=#{untracked})

    case Git.ok(path, status) do
      {:ok, out} when byte_size(out) > 64 * 1024 ->
        "Local changes exceed the inspection limit"

      {:ok, out} ->
        case changed_files(String.split(out, <<0>>, trim: true), 0) do
          0 -> if keep_when == "any-local-files", do: ignored_files(path)
          1 -> "Has uncommitted changes (1 file)"
          count -> "Has uncommitted changes (#{count} files)"
        end

      {:error, _} ->
        "Local changes could not be read"
    end
  end

  # A rename or copy record is followed by the path it came from.
  defp changed_files([], count), do: count

  defp changed_files([record | rest], count) do
    rest = if Regex.match?(~r/^([RC].|.[RC]) /, record), do: Enum.drop(rest, 1), else: rest
    changed_files(rest, count + 1)
  end

  defp ignored_files(path) do
    case Git.ok(path, ~w(ls-files --others --ignored --exclude-standard --directory -z)) do
      {:ok, out} when byte_size(out) <= 64 * 1024 ->
        out
        |> String.split(<<0>>, trim: true)
        |> Enum.find(&(not dependencies?(&1)))
        |> case do
          nil -> nil
          file -> "Has ignored files (#{file})"
        end

      {:ok, _} ->
        "Ignored files exceed the inspection limit"

      {:error, _} ->
        "Ignored files could not be read"
    end
  end

  defp eligible(%{thread: thread, group: group, rules: rules} = look, head, now, memo) do
    deleted = deleted?(thread)
    activity = Enum.max(Enum.map([thread | group], &activity_at/1))
    days = rules["worktreeAfterDays"]
    settled_days = rules["worktreeSettledAfterDays"]
    settled_at = if not deleted, do: millis(thread["settledAt"])
    settled_for = settled_at && now - max(settled_at, activity)
    old = not deleted and days != nil and activity < now - days * @day_ms
    settled = settled_for != nil and settled_days != nil and settled_for >= settled_days * @day_ms

    cond do
      deleted ->
        {:remove, "Thread was deleted", head, memo}

      old ->
        {:remove, "Inactive for #{div(now - activity, @day_ms)} days", head, memo}

      settled ->
        {:remove, "Settled for #{div(settled_for, @day_ms)} days", head, memo}

      rules["worktreeUnchanged"] or rules["worktreeOnMerge"] ->
        repo = Path.expand(look.project["workspaceRoot"])

        case default_branch(repo, memo) do
          {:none, memo} ->
            {:keep, "No remote is configured for merged-worktree cleanup", memo}

          {{remote, nil}, memo} when is_binary(remote) ->
            {:keep, "Default branch is unavailable", memo}

          {{remote, branch}, memo} ->
            memo = fetch_once(memo, repo, remote, branch)
            {:ok, base} = git(look.path, ["rev-parse", "refs/remotes/#{remote}/#{branch}"])

            integrated =
              match?(
                {:ok, %{status: 0}},
                Git.run(look.path, ["merge-base", "--is-ancestor", head, base])
              )

            cond do
              integrated and rules["worktreeUnchanged"] ->
                {:remove, "No commits beyond the default branch", head, memo}

              rules["worktreeOnMerge"] and merged?(look, branch, head, integrated) ->
                {:remove, "Pull request was merged", head, memo}

              true ->
                {:keep, not_yet(rules, activity, settled_for, now), memo}
            end
        end

      true ->
        {:keep, not_yet(rules, activity, settled_for, now), memo}
    end
  end

  # A pull request merged with the branch's commits in the default branch, or, when
  # it was squashed, merged into the default branch from this branch at this head.
  defp merged?(look, default, head, integrated) do
    branch = look.thread["branch"]

    case HalC2.Vcs.branch_pull_request(look.path, branch) do
      %{"state" => "merged"} = pr ->
        integrated or
          (pr["headRef"] == branch and pr["baseRef"] == default and pr["headSha"] == head)

      _ ->
        false
    end
  end

  defp not_yet(rules, activity, settled_for, now) do
    cond do
      rules["worktreeAfterDays"] != nil ->
        "Inactive for #{div(now - activity, @day_ms)} of #{rules["worktreeAfterDays"]} days"

      rules["worktreeSettledAfterDays"] != nil and settled_for == nil ->
        "Not settled"

      rules["worktreeSettledAfterDays"] != nil ->
        "Settled for #{div(settled_for, @day_ms)} of #{rules["worktreeSettledAfterDays"]} days"

      rules["worktreeOnMerge"] ->
        "Not merged"

      true ->
        "Has commits beyond the default branch"
    end
  end

  # `{{remote, branch | nil}, memo}`, or `{:none, memo}` without a remote. With no
  # local record of the remote's default branch only the remote can say it, asked
  # once a sweep: "main" may be a feature branch.
  defp default_branch(repo, memo) do
    remote =
      case git(repo, ~w(remote)) do
        {:ok, remotes} ->
          names = String.split(remotes, "\n", trim: true)
          if "origin" in names, do: "origin", else: List.first(names)

        _ ->
          nil
      end

    key = {:default, repo, remote}

    cond do
      remote == nil ->
        {:none, memo}

      Map.has_key?(memo, key) ->
        {{remote, memo[key]}, memo}

      true ->
        branch =
          case git(repo, ["symbolic-ref", "refs/remotes/#{remote}/HEAD"]) do
            {:ok, "refs/remotes/" <> rest} -> rest |> String.split("/", parts: 2) |> List.last()
            _ -> remote_default(repo, remote)
          end

        {{remote, branch}, Map.put(memo, key, branch)}
    end
  end

  defp remote_default(repo, remote) do
    with {:ok, out} <-
           Git.ok(repo, ["ls-remote", "--symref", "--", remote, "HEAD"], timeout: 20_000),
         [_, branch] <- Regex.run(~r/^ref: refs\/heads\/(.+)\tHEAD\r?$/m, out) do
      branch
    else
      _ -> nil
    end
  end

  defp fetch_once(memo, repo, remote, branch) do
    key = {:fetched, repo, remote, branch}

    if Map.has_key?(memo, key) do
      memo
    else
      _ = Git.run(repo, ["fetch", remote, branch])
      Map.put(memo, key, true)
    end
  end

  # Inside the worktree's lease: everything checked again against fresh rows and
  # settings, so a new turn, session, terminal, thread or rule change cancels the
  # removal, measured, checked once more, then removed. `{:removed, bytes}` or
  # `{:keep, reason}`.
  defp remove(%{thread: thread, path: path, rules: rules} = look, head) do
    with nil <- changed_since(look),
         _ = hook(:measuring, path),
         bytes = measure(path),
         nil <- changed_since(look),
         nil <-
           if(checkout_head(path, thread["branch"]) != head, do: "Commit changed since check"),
         nil <- local_changes(path, rules["worktreeKeepWhen"]),
         nil <-
           if(rules(HalC2.Settings.settings(), thread["projectId"]) != rules,
             do: "Settings changed since check"
           ),
         {:ok, force} <- submodules(path, rules["worktreeKeepWhen"]),
         _ = hook(:removing, path),
         nil <- last_look(path, rules["worktreeKeepWhen"]) do
      repo = look.project["workspaceRoot"]

      # Git requires force for submodules; the checks above are what keeps them safe.
      case HalC2.Vcs.remove_worktree(%{"cwd" => repo, "path" => path, "force" => force}) do
        {:ok, _} -> {:removed, bytes}
        {:error, error} -> raise error["message"] || inspect(error)
      end
    else
      {:keep, reason} -> {:keep, reason}
      reason when is_binary(reason) -> {:keep, reason}
    end
  end

  # Right before removal, so that only the removal itself is left to race: the local
  # changes `keep_when` counts, again, then, under a choice that lets ignored files
  # go, a repository nested in the worktree, whose commits may be nowhere else, since
  # Git deletes an ignored one with the worktree. Nil when the worktree may go.
  defp last_look(path, keep_when) do
    with nil <- local_changes(path, keep_when),
         nil <- if(keep_when != "any-local-files", do: nested_repository(path)) do
      if keep_when == "tracked-changes", do: clean_untracked(path)
    end
  end

  # Under "tracked-changes" untracked files may go too, but Git refuses to remove a
  # worktree that has them, so they are cleaned first; no other choice ever cleans.
  # One `-f` never lets the clean delete a nested repository, and anything made
  # meanwhile, a tracked edit or a file left after the clean, keeps the worktree
  # rather than failing or going with a forced removal.
  defp clean_untracked(path) do
    with {:ok, _} <- Git.ok(path, ~w(clean -fdxq)),
         _ = hook(:cleaned, path),
         nil <- local_changes(path, "tracked-changes"),
         {:ok, left} <- Git.ok(path, ~w(ls-files --others --directory -z)) do
      case Enum.reject(String.split(left, <<0>>, trim: true), &dependencies?/1) do
        [] -> nil
        [entry | _] -> "Has untracked files (#{entry})"
      end
    else
      {:error, _} -> "Untracked files could not be cleaned"
      reason -> reason
    end
  end

  # What the clean would skip besides installed dependencies: the untracked and
  # ignored entries it would not remove whole, which are nested repositories or
  # folders holding one.
  defp nested_repository(path) do
    dry = ~w(-c core.quotePath=false clean -ndx)

    with {:ok, others} <- Git.ok(path, ~w(ls-files --others --directory -z)),
         {:ok, plan} <- Git.ok(path, dry, env: [{"LC_ALL", "C"}]),
         true <- byte_size(others) <= 64 * 1024 and byte_size(plan) <= 64 * 1024 do
      removed =
        for "Would remove " <> entry <- String.split(plan, "\n", trim: true),
            into: MapSet.new(),
            do: String.trim_trailing(entry, "/")

      others
      |> String.split(<<0>>, trim: true)
      |> Enum.find(&(String.trim_trailing(&1, "/") not in removed and not dependencies?(&1)))
      |> case do
        nil -> nil
        entry -> "Has a nested repository (#{entry})"
      end
    else
      false -> "Untracked files exceed the inspection limit"
      {:error, _} -> "Untracked files could not be read"
    end
  end

  defp dependencies?(entry), do: Regex.match?(~r{(^|/)node_modules/$}, entry)

  defp checkout_head(path, branch) do
    with {:ok, "refs/heads/" <> ^branch} <- git(path, ~w(symbolic-ref --quiet HEAD)),
         {:ok, head} <- git(path, ~w(rev-parse HEAD)),
         do: head,
         else: (_ -> nil)
  end

  # Why the worktree may no longer go, from fresh rows. Nil when it still may.
  defp changed_since(%{thread: thread, group: group, path: path} = look) do
    {projects, threads} = local_rows()
    deleted = deleted?(thread)
    latest = Enum.filter(threads, &(not deleted?(&1) and path(&1) == path))
    owner = owner(if deleted, do: [thread | latest], else: latest)
    previous = Map.new(group, &{&1["id"], &1})

    cond do
      holds_project?(path, Map.values(projects)) ->
        "Contains a project checkout"

      reason = busy(path) ->
        reason

      deleted and not rules(HalC2.Settings.settings(), thread["projectId"])["worktreeOnDelete"] ->
        "Thread or cleanup settings changed since check"

      deleted and deletion_pending?(thread["id"]) ->
        "Thread deletion is still pending"

      length(latest) != length(group) or owner == nil or owner["id"] != thread["id"] or
          Enum.any?(latest, &changed?(&1, previous[&1["id"]], look)) ->
        "Thread activity or shared worktree changed since check"

      true ->
        nil
    end
  end

  defp changed?(latest, nil, _look), do: latest != nil

  defp changed?(latest, previous, look) do
    latest["branch"] != look.thread["branch"] or latest["settledAt"] != previous["settledAt"] or
      not idle?(latest) or activity_at(latest) != activity_at(previous)
  end

  # A deleted thread's own cleanup (its terminals, attachments) still waits or runs:
  # its worktree waits for it. Finished effects are deleted, and failed ones (any
  # type, kept a week for diagnosis) will not run again, so neither holds it.
  defp deletion_pending?(thread_id) do
    HalC2.Orchestration.Effects.effects(thread_id)
    |> Enum.any?(
      &(&1["type"] in ["terminal.cleanup", "attachment.cleanup"] and
          &1["status"] in ["pending", "running"])
    )
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # The bytes a removal frees: files in the worktree, not those reached through a
  # link or still held by another hard link, counted for at most #{@measure_ms}ms.
  # Nil when it ran out of time or could not read a folder.
  defp measure(path) do
    deadline = System.monotonic_time(:millisecond) + @measure_ms
    walk([path], 0, deadline)
  end

  defp walk([], bytes, _deadline), do: bytes

  defp walk([path | rest], bytes, deadline) do
    cond do
      System.monotonic_time(:millisecond) > deadline ->
        nil

      true ->
        case File.lstat(path) do
          {:ok, %File.Stat{type: :directory}} ->
            case File.ls(path) do
              {:ok, names} -> walk(Enum.map(names, &Path.join(path, &1)) ++ rest, bytes, deadline)
              _ -> nil
            end

          {:ok, %File.Stat{type: :regular, links: 1, size: size}} ->
            walk(rest, bytes + size, deadline)

          _ ->
            walk(rest, bytes, deadline)
        end
    end
  end

  # Whether the worktree's submodules hold work found nowhere else (a commit no
  # remote has, a local change): `{:keep, reason}`; else `{:ok, force?}`, force
  # when it has submodules, which Git will not remove without it.
  defp submodules(path, keep_when) do
    {:ok, git_dir} = git(path, ~w(rev-parse --absolute-git-dir))
    stored = File.dir?(Path.join(git_dir, "modules"))

    if stored or File.exists?(Path.join(path, ".gitmodules")) do
      script = ~S(printf "%s\0" "$toplevel/$sm_path")

      case Git.ok(path, ["submodule", "foreach", "--recursive", "--quiet", script]) do
        {:ok, out} ->
          paths = String.split(out, <<0>>, trim: true)

          case Enum.find_value(paths, &submodule_loss(&1, keep_when)) do
            nil -> {:ok, stored or paths != []}
            reason -> {:keep, reason}
          end

        {:error, _} ->
          {:keep, "Submodules could not be inspected"}
      end
    else
      {:ok, false}
    end
  end

  defp submodule_loss(path, keep_when) do
    case git(path, ~w(rev-list --max-count=1 HEAD --all --reflog --not --remotes)) do
      {:ok, ""} ->
        with reason when is_binary(reason) <- local_changes(path, keep_when),
             do:
               "Submodule " <>
                 String.downcase(String.first(reason)) <> String.slice(reason, 1..-1//1)

      {:ok, _} ->
        "Submodule has commits not on a remote-tracking ref"

      {:error, _} ->
        "Submodule repository could not be inspected"
    end
  end

  # Tests pause a sweep at a stage (`:measuring`, `:removing`) of a worktree's
  # removal: `{module, function, args}`, called with the stage and the path.
  defp hook(stage, path) do
    case Application.get_env(:hal_c2, :storage_cleanup_hook) do
      {m, f, a} -> apply(m, f, a ++ [stage, path])
      nil -> :ok
    end
  end

  # PR refreshes must not reset the clock, so only messages and runs count.
  defp activity_at(thread) do
    ~w(createdAt latestUserMessageAt latestRunRequestedAt latestRunStartedAt latestRunCompletedAt)
    |> Enum.map(&millis(thread[&1]))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> 0 end)
  end

  defp millis(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, time, _} -> DateTime.to_unix(time, :millisecond)
      _ -> nil
    end
  end

  defp millis(_at), do: nil

  # --- files -----------------------------------------------------------------------

  # Files past `days` old under `dir`; for logs only rotated ones, in any subfolder.
  # The setting is read again before each removal.
  defp files(_dir, _key, nil, _now), do: :ok

  defp files(dir, key, days, now) do
    with true <- File.dir?(dir),
         {:ok, ^dir} <- real(dir),
         {:ok, names} <- File.ls(dir) do
      for name <- names,
          path = Path.join(dir, name),
          {:ok, stat} <- [File.lstat(path, time: :posix)] do
        cond do
          stat.type == :directory and key == "logsAfterDays" ->
            files(path, key, days, now)

          stat.type == :regular and stat.mtime * 1000 < now - days * @day_ms and
            (key != "logsAfterDays" or Regex.match?(~r/\.(log|ndjson)\.\d+$/, name)) and
              get_in(HalC2.Settings.settings(), ["storageCleanup", key]) == days ->
            File.rm(path)

          true ->
            :ok
        end
      end
    end

    :ok
  end

  # --- paths -----------------------------------------------------------------------

  defp git(cwd, args) do
    with {:ok, out} <- Git.ok(cwd, args), do: {:ok, String.trim(out)}
  end

  defp within?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp real(path), do: HalC2.Paths.real(path)

  defp real_or_self(path), do: with({:ok, real} <- real(path), do: real, else: (_ -> path))

  defp worktrees_root, do: Path.join(HalC2.Paths.data_dir(), "worktrees")
end
