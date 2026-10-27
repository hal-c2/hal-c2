defmodule HalC2.Checkpoint do
  @moduledoc """
  Workspace checkpoints: a hidden git commit per finished run, under
  `refs/hal-c2/orchestration-v2/checkpoints/…`, so a client can diff what each turn changed.

  A thread has one root checkpoint scope. Ordinal 0 of the scope is the workspace
  before the first run; ordinal `n` is the workspace after run `n`. Scope ids,
  checkpoint ids, and refs are the ones earlier installs derived, so threads imported
  from them keep their diffs.

  Captures stage the whole worktree into a private index next to the repository's
  own, so the user's staging area is never touched.
  """

  alias HalC2.Orchestration.Entities

  @refs_prefix "refs/hal-c2/orchestration-v2/checkpoints"
  # Checkpoints written under the earlier `t3` ref prefix; recorded refs name them directly.
  @legacy_refs_prefix "refs/t3/orchestration-v2/checkpoints"
  @diff_max_bytes 10_000_000
  # Staging a workspace that holds a repository with no commit yet fails; naming
  # those repositories and staging again recovers it, within limits: past them the
  # capture fails instead of spending unbounded work on probing.
  @recovery_max_candidates 64
  @recovery_timeout_ms 5_000
  @recovery_listing_max_bytes 16 * 1024 * 1024
  @identity [
    {"GIT_AUTHOR_NAME", "HAL-C2"},
    {"GIT_AUTHOR_EMAIL", "hal-c2@users.noreply.github.com"},
    {"GIT_COMMITTER_NAME", "HAL-C2"},
    {"GIT_COMMITTER_EMAIL", "hal-c2@users.noreply.github.com"}
  ]
  # Flush objects and refs before publishing them; an unclean restart must not leave
  # empty ref files that break every later fetch.
  @durable ~w(-c core.fsync=objects,reference -c core.fsyncMethod=fsync)
  @index_config ~w(-c core.fsmonitor=false -c sparse.expectFilesOutsideOfPatterns=false)

  @doc "The id of a thread's root checkpoint scope."
  def scope_id(thread_id), do: "checkpoint-scope:thread:#{uri(thread_id)}:name:root"

  @doc "The id of the checkpoint at `ordinal` in a scope."
  def checkpoint_id(scope_id, ordinal), do: "checkpoint:scope:#{uri(scope_id)}:name:#{ordinal}"

  @doc "The git ref holding the checkpoint at `ordinal` in a scope."
  def ref(scope_id, ordinal) do
    key = :crypto.hash(:sha256, scope_id) |> Base.encode16(case: :lower) |> binary_part(0, 32)
    "#{@refs_prefix}/#{Base.url_encode64(key, padding: false)}/ordinal/#{ordinal}"
  end

  defp uri(part), do: URI.encode(part, &URI.char_unreserved?/1)

  @doc "A new root scope entity (`OrchestrationV2CheckpointScope`) for a thread."
  def scope(thread_id, run_id, node_id, provider_thread_id, cwd, at) do
    %{
      "id" => scope_id(thread_id),
      "threadId" => thread_id,
      "runId" => run_id,
      "nodeId" => node_id,
      "parentScopeId" => nil,
      "providerThreadId" => provider_thread_id,
      "kind" => "root_run",
      "ordinalWithinParent" => 0,
      "advancesAppRunCount" => true,
      "cwd" => cwd,
      "createdAt" => at
    }
  end

  @doc """
  Captures the workspace before run `ordinal + 1` unless that checkpoint exists, so
  the run's diff has a starting point. Failures are logged; the run goes ahead.
  """
  def baseline(cwd, scope_id, ordinal) do
    ref = ref(scope_id, ordinal)

    with true <- repo?(cwd),
         nil <- existing(cwd, ref),
         {:error, reason} <- capture(cwd, ref) do
      require Logger
      Logger.warning("checkpoint baseline failed in #{cwd}: #{inspect(reason)}")
    end

    :ok
  end

  @doc """
  Captures the workspace after run `ordinal` and returns its checkpoint entity
  (`OrchestrationV2Checkpoint`), with the files changed since the previous one.
  """
  def capture_run(cwd, scope_id, ordinal, run_id, node_id, thread_id, at) do
    ref = ref(scope_id, ordinal)

    {status, files} =
      cond do
        not repo?(cwd) ->
          {"missing", []}

        true ->
          case capture(cwd, ref) do
            :ok -> {"ready", changed_files(cwd, scope_id, ordinal, ref)}
            {:error, reason} -> capture_failed(cwd, ref, reason)
          end
      end

    %{
      "id" => checkpoint_id(scope_id, ordinal),
      "threadId" => thread_id,
      "scopeId" => scope_id,
      "runId" => run_id,
      "nodeId" => node_id,
      "parentCheckpointId" => if(ordinal > 0, do: checkpoint_id(scope_id, ordinal - 1)),
      "ordinalWithinScope" => ordinal,
      "appRunOrdinal" => ordinal,
      "ref" => ref,
      "status" => status,
      "files" => files,
      "capturedAt" => at || Entities.now()
    }
  end

  # The files changed since the previous checkpoint. A summary that cannot be
  # worked out leaves the checkpoint ready with none listed: the capture itself
  # is what a rewind needs.
  defp changed_files(cwd, scope_id, ordinal, ref) do
    with previous when is_binary(previous) <-
           existing(cwd, ref(scope_id, max(ordinal - 1, 0))),
         {:ok, numstat} <-
           git(
             cwd,
             ~w(diff --numstat -z --no-color --no-ext-diff --no-textconv) ++
               ["#{previous}^{commit}", "#{ref}^{commit}"]
           ) do
      numstat_files(numstat)
    else
      _ -> []
    end
  end

  defp capture_failed(cwd, ref, reason) do
    require Logger
    Logger.warning("checkpoint capture failed in #{cwd} for #{ref}: #{inspect(reason)}")
    {"error", []}
  end

  @doc """
  The checkpoints of the baselines before run `ordinal` (the workspace before the
  thread's first run and just before this one), recorded when
  the run completes: ready when `baseline/3` captured them, missing otherwise. They
  belong to no run; rewinding to before the first run names ordinal 0.
  """
  def baselines(cwd, scope_id, ordinal, node_id, thread_id, at) do
    repo = repo?(cwd)

    for n <- Enum.uniq([0, max(ordinal - 1, 0)]) do
      found = repo && existing(cwd, ref(scope_id, n))

      %{
        "id" => checkpoint_id(scope_id, n),
        "threadId" => thread_id,
        "scopeId" => scope_id,
        "runId" => nil,
        "nodeId" => node_id,
        "parentCheckpointId" => nil,
        "ordinalWithinScope" => n,
        "appRunOrdinal" => nil,
        "ref" => found || ref(scope_id, n),
        "status" => if(found, do: "ready", else: "missing"),
        "files" => [],
        "capturedAt" => at
      }
    end
  end

  @doc """
  The patch between two turn counts of a thread (`orchestration.getTurnDiff`): turn 0
  is the workspace before the first run. `state` is the thread's `HalC2.StreamState`.
  """
  def turn_diff(state, thread_id, from, to, ignore_whitespace \\ true)

  def turn_diff(_state, thread_id, same, same, _ignore_whitespace),
    do: {:ok, diff_result(thread_id, same, same, "")}

  def turn_diff(state, thread_id, from, to, ignore_whitespace) do
    completed =
      for run <- HalC2.StreamState.list(state, "run"),
          run["status"] == "completed",
          into: MapSet.new(),
          do: run["id"]

    # Turn counts name the completed runs still standing, in order: a run that
    # was rewound no longer counts, so the run after a rewind takes the number
    # the rewound run held.
    ready =
      state
      |> HalC2.StreamState.list("checkpoint")
      |> Enum.filter(
        &(&1["status"] == "ready" and is_integer(&1["appRunOrdinal"]) and
            MapSet.member?(completed, &1["runId"]))
      )
      |> Enum.sort_by(& &1["appRunOrdinal"])
      |> Enum.with_index(1)
      |> Map.new(fn {checkpoint, turn} -> {turn, checkpoint} end)

    scopes = HalC2.StreamState.get(state, "checkpoint-scope")

    with {:to, %{} = to_checkpoint} <- {:to, ready[to]},
         {:scope, %{"cwd" => cwd}} <- {:scope, scopes[to_checkpoint["scopeId"]]},
         {:from, from_ref} when is_binary(from_ref) <-
           {:from,
            if(from == 0,
              do: start_ref(state, cwd),
              else: ready[from] && resolved(cwd, ready[from]["ref"])
            )},
         {:ok, diff} <-
           diff_git(
             cwd,
             ~w(diff --patch --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/) ++
               if(ignore_whitespace, do: ["--ignore-all-space"], else: []) ++
               ["#{from_ref}^{commit}", "#{resolved(cwd, to_checkpoint["ref"])}^{commit}"],
             max_bytes: @diff_max_bytes
           ) do
      {:ok, diff_result(thread_id, from, to, diff)}
    else
      {:to, nil} -> {:error, "turn #{to} has no checkpoint"}
      {:scope, _} -> {:error, "the checkpoint's workspace is unknown"}
      {:from, _} -> {:error, "turn #{from} has no checkpoint"}
      {:error, :too_large} -> {:error, "the diff is larger than #{@diff_max_bytes} bytes"}
      {:error, reason} -> {:error, "git diff failed: #{inspect(reason)}"}
    end
  end

  # A patch past the cap fails the request rather than sending a cut-off patch.
  defp diff_git(cwd, args, opts) do
    case HalC2.Git.run(cwd, args, opts) do
      {:ok, %{truncated: true}} -> {:error, :too_large}
      {:ok, %{status: 0, out: out}} -> {:ok, out}
      {:ok, %{status: status, err: err}} -> {:error, {status, String.trim(err)}}
      error -> error
    end
  end

  # The workspace before the thread's first run: ordinal 0 of its first root scope.
  # A fork holds its source's scope before its own, whose ordinal 0 was never taken.
  defp start_ref(state, cwd) do
    state
    |> HalC2.StreamState.list("checkpoint-scope")
    |> Enum.filter(&(&1["kind"] == "root_run"))
    |> Enum.find_value(&existing(cwd, ref(&1["id"], 0)))
  end

  # A derived checkpoint ref as it exists in `cwd`, taken before the rename or since.
  # Checkpoints written before the rename live under `refs/t3/…`; reads of a
  # `refs/hal-c2/…` ref fall back to that namespace, writes only use the new one.
  defp existing(cwd, ref) do
    Enum.find([ref, legacy_ref(ref)], &ref_commit?(cwd, &1))
  end

  # The ref as it can be read in `cwd`: the old namespace's when only it exists.
  defp resolved(cwd, ref), do: existing(cwd, ref) || ref

  defp legacy_ref(ref),
    do: String.replace_prefix(ref, @refs_prefix <> "/", @legacy_refs_prefix <> "/")

  defp ref_commit?(cwd, ref),
    do: match?({:ok, _}, git(cwd, ["rev-parse", "--verify", "--quiet", "#{ref}^{commit}"]))

  defp diff_result(thread_id, from, to, diff),
    do: %{"threadId" => thread_id, "fromTurnCount" => from, "toTurnCount" => to, "diff" => diff}

  @doc """
  Puts the worktree back to the checkpoint at `ref`: tracked files as captured,
  files the checkpoint lacks removed (ignored ones kept), the index left at HEAD.
  """
  def restore(cwd, ref) do
    ref = resolved(cwd, ref)

    with {:ok, commit} <- git(cwd, ["rev-parse", "--verify", "--quiet", "#{ref}^{commit}"]),
         commit = String.trim(commit),
         {:ok, tracked} <-
           git(cwd, ["ls-files", "--cached", "--with-tree=#{commit}", "-z", "--", "."]),
         # An empty index and checkpoint have nothing for the pathspec to match.
         {:ok, _} <-
           if(tracked == "",
             do: {:ok, ""},
             else: git(cwd, ~w(restore --source #{commit} --worktree --staged -- .))
           ),
         # Restoring away the last tracked file can remove a nested workspace directory.
         :ok <- File.mkdir_p(cwd),
         :ok <- clean(cwd) do
      if exists?(cwd, "HEAD"), do: git(cwd, ~w(reset --quiet -- .))
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, "checkpoint #{ref} is missing"}
    end
  end

  defp clean(cwd) do
    case git(cwd, ~w(clean -fd -- .)) do
      {:ok, _} ->
        :ok

      # Git can remove every child, then fail to remove `./` itself.
      {:error, {1, "warning: failed to remove ./" <> _}} = error ->
        if File.ls(cwd) == {:ok, []}, do: :ok, else: error

      error ->
        error
    end
  end

  @doc "Deletes a checkpoint ref in both the current and the old namespace; a missing one is fine."
  def delete_ref(cwd, ref) do
    for target <- Enum.uniq([ref, legacy_ref(ref)]),
        do: git(cwd, ["update-ref", "-d", target])

    :ok
  end

  @doc "Whether `cwd` is inside a git worktree."
  def repo?(cwd),
    do: File.dir?(cwd) and git(cwd, ~w(rev-parse --is-inside-work-tree)) == {:ok, "true\n"}

  @doc "Whether a checkpoint ref resolves to a commit, under either namespace."
  def exists?(cwd, ref), do: existing(cwd, ref) != nil

  @doc "Commits the whole worktree (tracked and untracked, minus ignored) to `ref`."
  def capture(cwd, ref) do
    with {:ok, common} <- git(cwd, ~w(rev-parse --path-format=absolute --git-common-dir)) do
      index = Path.join(String.trim(common), "hal-c2-checkpoint-index-#{Entities.new_id("i")}")
      env = [{"GIT_INDEX_FILE", index} | @identity]
      sparse = sparse_checkout?(cwd)

      try do
        with :ok <- seed_index(cwd, index, env, sparse),
             :ok <- stage(cwd, env, sparse),
             {:ok, tree} <- git(cwd, @index_config ++ @durable ++ ["write-tree"], env: env),
             {:ok, commit} <-
               git(
                 cwd,
                 @durable ++
                   ["commit-tree", String.trim(tree), "-m", "hal-c2 checkpoint ref=#{ref}"],
                 env: env
               ),
             {:ok, _} <- git(cwd, @durable ++ ["update-ref", ref, String.trim(commit)]) do
          :ok
        end
      after
        File.rm(index)
        File.rm(index <> ".lock")
      end
    end
  end

  # Whether the worktree is a sparse checkout this git can stage sparsely
  # (`git add --sparse`); a git without it stages the checkout as it stands.
  defp sparse_checkout?(cwd) do
    with {:ok, "true\n"} <- git(cwd, ~w(config --bool core.sparseCheckout)),
         {:ok, %{out: out, err: err}} <- HalC2.Git.run(cwd, ~w(add -h)) do
      Regex.match?(~r/--(\[no-\])?sparse\b/, out <> err)
    else
      _ -> false
    end
  end

  # Stages the whole worktree into the private index. Preserve absent skipped
  # entries in a sparse checkout, but capture present nonignored files outside
  # the cone. A repository inside the workspace with no commit yet cannot be
  # staged; when staging fails for one, name and leave out each such
  # repository and stage again (within the recovery limits above).
  defp stage(cwd, env, sparse) do
    case add_all(cwd, env, sparse, []) do
      {:ok, _} -> :ok
      {:error, _} = error -> recover_stage(cwd, env, sparse, error)
    end
  end

  defp add_all(cwd, env, sparse, exclusions) do
    git(
      cwd,
      @index_config ++
        @durable ++
        ["add"] ++
        if(sparse, do: ["--sparse"], else: []) ++ ["-A", "--", "." | exclusions],
      env: env
    )
  end

  # One budget covers discovery, the probes of each candidate, and the retry.
  defp recover_stage(cwd, env, sparse, error) do
    case within(@recovery_timeout_ms, fn -> stage_without_unborn(cwd, env, sparse, error) end) do
      {:ok, result} -> result
      _ -> error
    end
  end

  defp stage_without_unborn(cwd, env, sparse, error) do
    with {:ok, %{status: 0, out: untracked, truncated: false}} <-
           HalC2.Git.run(cwd, ~w(ls-files --others --exclude-standard -z -- .),
             env: env,
             max_bytes: @recovery_listing_max_bytes
           ) do
      # An untracked folder git will not descend into is listed as one entry
      # ending in `/`: a repository of its own inside the workspace.
      candidates =
        untracked
        |> String.split(<<0>>, trim: true)
        |> Enum.filter(&String.ends_with?(&1, "/"))

      exclusions =
        if length(candidates) <= @recovery_max_candidates do
          for entry <- candidates,
              File.exists?(Path.join([cwd, entry, ".git"])),
              not match?(
                {:ok, _},
                git(Path.join(cwd, entry), ~w(rev-parse --verify --quiet HEAD^{commit}))
              ),
              do: ":(exclude,literal)#{entry}"
        end

      case exclusions do
        [_ | _] -> add_all(cwd, env, sparse, exclusions) |> ok()
        _ -> error
      end
    else
      _ -> error
    end
  end

  # Runs `fun` in a task given `ms` to finish; killing the task takes the git
  # processes it started with it. `{:ok, result}` or `:timeout`/exit.
  defp within(ms, fun) do
    trap = Process.flag(:trap_exit, true)
    task = Task.async(fun)

    try do
      case Task.yield(task, ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> {:ok, result}
        {:exit, reason} -> {:exit, reason}
        nil -> :timeout
      end
    after
      receive do
        {:EXIT, pid, _reason} when pid == task.pid -> :ok
      after
        0 -> :ok
      end

      Process.flag(:trap_exit, trap)
    end
  end

  # Starts the private index at HEAD. Copying the repository's own index keeps its
  # stat data, so `git add` rehashes only changed files instead of the whole tree.
  defp seed_index(cwd, index, env, sparse) do
    cond do
      not match?({:ok, _}, git(cwd, ~w(rev-parse --verify --quiet HEAD^{commit}))) ->
        :ok

      reuse_index(cwd, index, env, sparse) ->
        :ok

      # Rebuilding a non-cone sparse index loses its exclusions and would
      # publish them as deletions; fail instead.
      sparse and git(cwd, ~w(config --bool core.sparseCheckoutCone)) != {:ok, "true\n"} ->
        {:error, "Cannot rebuild a checkpoint index for non-cone sparse checkout."}

      true ->
        File.rm(index)

        # A fresh sparse index represents excluded directories without
        # marking them deleted.
        if sparse,
          do:
            ok(
              git(cwd, @index_config ++ ~w(-c index.sparse=true read-tree --reset HEAD), env: env)
            ),
          else: ok(git(cwd, ~w(read-tree HEAD), env: env))
    end
  end

  defp reuse_index(cwd, index, env, sparse) do
    with {:ok, path} <- git(cwd, ~w(rev-parse --path-format=absolute --git-path index)),
         path = String.trim(path),
         {:ok, %{mtime: mtime}} <- File.stat(path, time: :posix),
         # Stay below the source timestamp to keep git's racy-entry check.
         time when time > 0 <- mtime - 1,
         :ok <- File.cp(path, index),
         {:ok, _} <- git(cwd, @index_config ++ ~w(read-tree --reset HEAD), env: env),
         :ok <- File.touch(index, time),
         {:ok, listing} <-
           git(cwd, @index_config ++ ~w(ls-files --full-name --sparse -v -z), env: env) do
      records =
        for <<tag, _space, name::binary>> <-
              String.split(listing, <<0>>, trim: true),
            do: {tag, name}

      # Assume-unchanged (lowercase tag) entries would hide real changes from
      # `git add`. Skip-worktree (S) entries are a sparse checkout's own
      # exclusions, but a manually skipped file the sparse rules select needs
      # a fresh index too.
      skipped =
        for {?S, name} <- records,
            not String.ends_with?(name, "/"),
            do: name

      not Enum.any?(records, fn {tag, _} -> tag in ?a..?z or (tag == ?S and not sparse) end) and
        (skipped == [] or
           (Enum.all?(skipped, &String.valid?/1) and
              not_sparse_selected?(cwd, env, skipped)))
    else
      _ -> false
    end
  end

  # Whether none of the skipped files is selected by the sparse-checkout rules:
  # any selected one carries a manual skip-worktree flag, not an exclusion.
  defp not_sparse_selected?(cwd, env, skipped) do
    case git(cwd, @index_config ++ ~w(sparse-checkout check-rules -z),
           env: env,
           input: Enum.join(skipped, <<0>>) <> <<0>>
         ) do
      {:ok, ""} -> true
      _ -> false
    end
  end

  defp ok({:ok, _}), do: :ok
  defp ok(error), do: error

  @doc "Parses `git diff --numstat -z` into file summaries (`OrchestrationV2CheckpointFileSummary`)."
  def numstat_files(numstat) do
    numstat
    |> String.split(<<0>>)
    |> parse_numstat([])
    |> Enum.sort_by(& &1["path"])
  end

  defp parse_numstat([], acc), do: acc

  defp parse_numstat([record | rest], acc) do
    case Regex.run(~r/^(\d+|-)\t(\d+|-)\t(.*)$/s, record) do
      # Renames and copies put the source and destination in the next two records.
      [_, added, deleted, ""] ->
        case rest do
          [_source, dest | rest] -> parse_numstat(rest, add_file(acc, dest, added, deleted))
          _ -> acc
        end

      [_, added, deleted, path] ->
        parse_numstat(rest, add_file(acc, path, added, deleted))

      nil ->
        parse_numstat(rest, acc)
    end
  end

  defp add_file(acc, "", _, _), do: acc

  defp add_file(acc, path, added, deleted),
    do: [
      %{
        "path" => path,
        "kind" => "modified",
        "additions" => count(added),
        "deletions" => count(deleted)
      }
      | acc
    ]

  defp count("-"), do: 0
  defp count(n), do: String.to_integer(n)

  defp git(cwd, args, opts \\ []), do: HalC2.Git.ok(cwd, args, opts)
end
