defmodule HalC2.GitActions do
  @moduledoc """
  `git.runStackedAction`: commit, push, and open a pull request, in any stacked
  combination, reporting `GitActionProgressEvent`s as each phase runs.

  A missing commit message is written by a coding agent (`HalC2.TextGeneration`), as
  is a feature branch name when one is asked for, in the project's writing style
  (`HalC2.TextGeneration.Style`). Pull requests are GitHub's, via the `gh` CLI: an
  open one for the branch is reused, otherwise one is created with a generated
  title and body that follow the repository's pull request template.

  `start/2` runs an action in its own process and sends each event to the
  subscriber as `{:hal_c2_git_action, action_id, event}`.
  """

  alias HalC2.{Git, GitHub, PullRequests, TextGeneration, Vcs}
  alias HalC2.SourceControl.{ChangeRequests, Forgejo}
  alias HalC2.TextGeneration.Style

  @commit_actions ~w(commit commit_push commit_push_pr)
  # How much of a thread's history a pull request writer is given.
  @thread_history_chars 8_000

  @doc "Runs the action (`GitRunStackedActionInput`) in a new process."
  def start(%{"actionId" => action_id} = input, subscriber) do
    {:ok, _} =
      Task.start(fn ->
        emit = fn event ->
          send(subscriber, {:hal_c2_git_action, action_id, event_base(input) |> Map.merge(event)})
        end

        run(input, emit)
      end)

    :ok
  end

  defp event_base(input),
    do: %{"actionId" => input["actionId"], "cwd" => input["cwd"], "action" => input["action"]}

  @doc "Runs the action, calling `emit` with each progress event; returns the result or an error."
  def run(%{"cwd" => cwd} = input, emit) do
    # The phase running when an error is thrown, for the failure event.
    Process.put(:git_action_phase, nil)
    Process.put(:git_action_thread, input["threadId"])

    try do
      result = run_action(input, emit)
      link_created(input["threadId"], result["pr"])
      emit.(%{"kind" => "action_finished", "result" => result})
      {:ok, result}
    catch
      {:git_action_error, message, cta} ->
        emit.(
          Map.merge(
            %{
              "kind" => "action_failed",
              "phase" => Process.get(:git_action_phase),
              "message" => message
            },
            if(cta, do: %{"cta" => cta}, else: %{})
          )
        )

        {:error, message}
    after
      # A pull request it opened or pushed to is asked about again, not held.
      HalC2.PullRequests.Branches.forget(cwd)
      Vcs.Watch.refresh(cwd)
    end
  end

  # The pull request an action opened or found is linked to the thread it ran beside
  # (`source: "created"`). The action has already succeeded, so a link that cannot be
  # made is only logged.
  defp link_created(thread_id, %{"status" => status, "url" => url})
       when is_binary(thread_id) and status in ["created", "opened_existing"] do
    with %{} = key <- HalC2.Projection.PullRequests.parse_change_request_url(url),
         {:ok, _} <-
           HalC2.Orchestration.dispatch(
             Map.merge(Map.take(key, [:host, :repository, :number]) |> stringify(), %{
               "type" => "thread.pull-request.link",
               "commandId" => "server:pr-created-link:#{HalC2.Environment.uuid4()}",
               "threadId" => thread_id,
               "url" => url,
               "source" => "created"
             })
           ) do
      :ok
    else
      other ->
        require Logger
        Logger.warning("failed to link created pull request to #{thread_id}: #{inspect(other)}")
    end
  end

  defp link_created(_thread_id, _pr), do: :ok

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  # `cta` (`GitActionFailureCta`) is what the user can do about it, for a failure
  # with a known remedy.
  defp fail!(message, cta \\ nil), do: throw({:git_action_error, message, cta})

  defp phase!(emit, phase, label) do
    Process.put(:git_action_phase, phase)
    emit.(%{"kind" => "phase_started", "phase" => phase, "label" => label})
  end

  defp run_action(%{"cwd" => cwd, "action" => action} = input, emit) do
    with true <- action in @commit_actions,
         message when is_binary(message) <- Vcs.lock_error(cwd) do
      fail!(message)
    end

    status = Map.merge(Vcs.local_status(cwd), Vcs.remote_status(cwd) || %{})
    branch = status["refName"]
    commit? = action in @commit_actions
    feature? = input["featureBranch"] == true

    # A pull request needs its head published: a branch with no upstream, commits
    # its upstream lacks, or an upstream that is its base rather than itself (cut
    # from another branch, even one it is level with) is pushed first.
    push? =
      action in ~w(push commit_push commit_push_pr) or
        (action == "create_pr" and
           (not status["hasUpstream"] or status["aheadCount"] > 0 or
              not tracks_itself?(cwd, branch)))

    pr? = action in ~w(create_pr commit_push_pr)

    cond do
      not status["isRepo"] ->
        fail!("#{cwd} is not a git repository.")

      feature? and not commit? ->
        fail!("Feature-branch checkout is only supported for commit actions.")

      not feature? and (push? or pr?) and branch == nil ->
        fail!("Cannot #{if pr?, do: "create a pull request", else: "push"} from detached HEAD.")

      action == "create_pr" and status["hasWorkingTreeChanges"] ->
        fail!("Commit local changes before creating a PR.")

      true ->
        :ok
    end

    phases =
      for {wanted, phase} <- [
            {feature?, "branch"},
            {commit?, "commit"},
            {push?, "push"},
            {pr?, "pr"}
          ],
          wanted,
          do: phase

    emit.(%{"kind" => "action_started", "phases" => phases})

    {branch_step, branch, suggestion} =
      if feature? do
        phase!(emit, "branch", "Preparing feature branch...")
        feature_branch(cwd, branch, input)
      else
        {%{"status" => "skipped_not_requested"}, branch, nil}
      end

    commit_step =
      if commit?,
        do: commit(cwd, branch, input, suggestion, emit),
        else: %{"status" => "skipped_not_requested"}

    push_step =
      if push? do
        phase!(emit, "push", "Pushing...")
        push(cwd, branch)
      else
        %{"status" => "skipped_not_requested"}
      end

    pr_step =
      if pr? do
        phase!(emit, "pr", "Preparing PR...")
        pull_request(cwd, branch, push_step["status"] == "pushed")
      else
        %{"status" => "skipped_not_requested"}
      end

    result = %{
      "action" => action,
      "branch" => branch_step,
      "commit" => commit_step,
      "push" => push_step,
      "pr" => pr_step
    }

    Map.put(result, "toast", toast(cwd, result))
  end

  # --- steps ----------------------------------------------------------------------

  defp feature_branch(cwd, branch, input) do
    suggestion =
      suggestion(cwd, branch, input, true) ||
        fail!("Cannot create a feature branch because there are no changes to commit.")

    existing =
      case Git.ok(cwd, ~w(branch --list --no-column --format=%\(refname:short\))) do
        {:ok, out} -> out |> String.split("\n", trim: true) |> MapSet.new(&String.downcase/1)
        _ -> MapSet.new()
      end

    # The writer's own `fix/…` namespace stays; `feature/` goes on a name without one.
    name =
      unique_branch(existing, suggestion["branch"] || feature_branch_name(suggestion["subject"]))

    git!(cwd, ["checkout", "-b", name])
    {%{"status" => "created", "name" => name}, name, suggestion}
  end

  defp commit(cwd, branch, input, suggestion, emit) do
    if suggestion == nil and blank?(input["commitMessage"]),
      do: phase!(emit, "commit", "Generating commit message...")

    case suggestion || suggestion(cwd, branch, input, false) do
      nil ->
        %{"status" => "skipped_no_changes"}

      %{"subject" => subject, "body" => body} ->
        phase!(emit, "commit", "Committing...")
        args = ["commit", "-m", subject] ++ if(body == "", do: [], else: ["-m", body])

        case traced_commit(cwd, args, emit) do
          {0, _err} ->
            {:ok, sha} = Git.ok(cwd, ~w(rev-parse HEAD))
            %{"status" => "created", "commitSha" => String.trim(sha), "subject" => subject}

          {_status, err} ->
            fail!("git commit failed: #{last_lines(err)}")
        end
    end
  end

  # Runs `git commit` with its trace2 events on the pipe its stderr goes to (fd 3, a
  # copy of stderr), so hooks are reported as they start and finish (`hook_started`,
  # `hook_finished`) around the output lines they print (`hook_output`). A hook prints to that pipe too, so its start, its output and its
  # exit arrive in the order they happened; a trace file read beside the pipe could
  # show the exit first. Not fd 2: a git a hook runs inherits the target, and would
  # write its trace into output the hook reads. Returns `{exit status, stderr without
  # the trace}`.
  defp traced_commit(cwd, args, emit) do
    {status, trace} =
      ["sh", "-c", ~s(exec git "$@" 3>&2), "git" | args]
      |> Exile.stream(
        cd: cwd,
        env: [{"GIT_TRACE2_EVENT", "3"}],
        stderr: :consume,
        ignore_epipe: true
      )
      |> Enum.reduce({nil, %{sid: nil, hook: nil, children: %{}, err: [], pending: %{}}}, fn
        {:exit, {:status, status}}, {_, trace} -> {status, trace}
        {:exit, _}, {_, trace} -> {1, trace}
        {stream, data}, {status, trace} -> {status, trace_chunk(emit, trace, stream, data)}
      end)

    trace =
      Enum.reduce(trace.pending, trace, fn {stream, rest}, trace ->
        trace_line(emit, trace, stream, rest)
      end)

    if trace.hook,
      do: hook_finished(emit, trace.hook, nil)

    {status, trace.err |> Enum.reverse() |> Enum.join("\n")}
  end

  defp trace_chunk(emit, trace, stream, data) do
    buffer = Map.get(trace.pending, stream, "") <> IO.iodata_to_binary(data)
    [rest | lines] = buffer |> String.split("\n") |> Enum.reverse()
    trace = Enum.reduce(Enum.reverse(lines), trace, &trace_line(emit, &2, stream, &1))
    put_in(trace.pending[stream], rest)
  end

  # A line of this git's trace, of the trace of a git a hook runs (skipped), or one
  # printed by git or a hook. A hook's output without a final newline runs into the
  # record after it, so a record is looked for where it starts, not only at the start.
  defp trace_line(emit, trace, :stderr, line) do
    {output, record} =
      line
      |> :binary.matches(~s({"event":"))
      |> Enum.find_value({line, nil}, fn {at, _} -> split_record(trace, line, at) end)

    trace =
      if output != "" or record == nil, do: output_line(emit, trace, :stderr, output), else: trace

    case record do
      # A git a hook runs traces there too.
      {:nested, _} -> trace
      {:ok, record} -> trace_event(emit, %{trace | sid: trace.sid || record["sid"]}, record)
      nil -> trace
    end
  end

  defp trace_line(emit, trace, stream, line), do: output_line(emit, trace, stream, line)

  # The output before a record starting at `at`, and the record: this git's (its first
  # record names the session) or a nested git's, whose session is under it. Nil when
  # no record starts there.
  defp split_record(trace, line, at) do
    {output, json} = :erlang.split_binary(line, at)

    with {:ok, %{"event" => _, "sid" => sid} = record} when is_binary(sid) <- JSON.decode(json) do
      cond do
        trace.sid == nil and not String.contains?(sid, "/") -> {output, {:ok, record}}
        sid == trace.sid -> {output, {:ok, record}}
        trace.sid && String.starts_with?(sid, trace.sid <> "/") -> {output, {:nested, record}}
        true -> nil
      end
    else
      _ -> nil
    end
  end

  defp output_line(emit, trace, stream, line) do
    if (text = String.trim(line)) != "" do
      emit.(%{
        "kind" => "hook_output",
        "hookName" => trace.hook && trace.hook.name,
        "stream" => Atom.to_string(stream),
        "text" => text
      })
    end

    if stream == :stderr, do: %{trace | err: [line | trace.err]}, else: trace
  end

  defp trace_event(emit, trace, %{"event" => "child_start", "child_class" => "hook"} = record) do
    hook = %{name: record["hook_name"], started: System.monotonic_time(:millisecond)}
    emit.(%{"kind" => "hook_started", "hookName" => hook.name})
    %{trace | hook: hook, children: Map.put(trace.children, record["child_id"], hook.name)}
  end

  # The exit of a hook names its child, not the hook.
  defp trace_event(emit, trace, %{"event" => "child_exit", "child_id" => child} = record)
       when is_map_key(trace.children, child) do
    {name, children} = Map.pop(trace.children, child)
    trace = %{trace | children: children}

    if trace.hook && trace.hook.name == name do
      hook_finished(emit, trace.hook, record["code"])
      %{trace | hook: nil}
    else
      trace
    end
  end

  # Git without child events for hooks still ends the hook's region.
  defp trace_event(emit, %{hook: %{name: name} = hook} = trace, %{
         "event" => "region_leave",
         "category" => "hook",
         "label" => name
       }) do
    hook_finished(emit, hook, nil)
    %{trace | hook: nil}
  end

  defp trace_event(_emit, trace, _record), do: trace

  defp hook_finished(emit, hook, code) do
    emit.(%{
      "kind" => "hook_finished",
      "hookName" => hook.name,
      "exitCode" => code,
      "durationMs" => System.monotonic_time(:millisecond) - hook.started
    })
  end

  # Stages the chosen files (or everything) and writes the message; nil when
  # nothing is staged.
  defp suggestion(cwd, branch, input, include_branch) do
    case input["filePaths"] do
      [_ | _] = paths ->
        # A reset that fails (another git holds the index lock) stops the commit:
        # carrying on could commit files the user left out.
        case Git.run(cwd, ["reset"]) do
          {:ok, %{status: 0}} -> :ok
          {:ok, %{err: err}} -> fail!("git reset failed: #{last_lines(err)}")
          {:error, reason} -> fail!("git reset failed: #{reason}")
        end

        git!(cwd, ["--literal-pathspecs", "add", "-A", "--"] ++ paths)

      _ ->
        git!(cwd, ["add", "-A"])
    end

    {:ok, summary} = Git.ok(cwd, ~w(diff --cached --name-status))
    summary = String.trim(summary)

    if summary == "" do
      nil
    else
      case custom_message(input["commitMessage"]) do
        {subject, body} ->
          %{"subject" => subject, "body" => body}
          |> then(
            &if(include_branch, do: Map.put(&1, "branch", feature_branch_name(subject)), else: &1)
          )

        nil ->
          {:ok, %{out: patch}} =
            Git.run(
              cwd,
              ~w(diff --no-ext-diff --no-textconv --cached --patch --minimal),
              max_bytes: 200_000
            )

          policy = Style.policy(cwd)

          case TextGeneration.commit_message(cwd, branch, summary, patch, include_branch,
                 policy: policy
               ) do
            {:ok, generated} ->
              generated

            {:error, reason} ->
              fail!("Could not write a commit message: #{reason}")
          end
      end
    end
  end

  defp custom_message(nil), do: nil

  defp custom_message(message) do
    case message |> String.replace("\r\n", "\n") |> String.trim() |> String.split("\n") do
      [""] -> nil
      [subject | rest] -> {String.trim(subject), rest |> Enum.join("\n") |> String.trim()}
    end
  end

  defp push(cwd, branch) do
    status = Vcs.remote_status(cwd) || %{}
    upstream = Git.upstream(cwd, branch)
    # An upstream whose remote-tracking ref is gone (its branch was deleted and pruned)
    # still has config; treat it as unset so the push publishes the branch again.
    upstream = upstream && upstream_ref_exists?(cwd, upstream) && upstream
    upstream_name = upstream && upstream_branch_name(upstream)

    # A local branch named after its upstream under a remote's prefix
    # ("upstream/effect-atom" tracking "origin/effect-atom") is that branch.
    same? = upstream_name && Git.same_branch?(cwd, branch, upstream_name)

    cond do
      upstream && same? && status["aheadCount"] == 0 && status["behindCount"] == 0 ->
        %{"status" => "skipped_up_to_date", "branch" => branch, "upstreamBranch" => upstream.ref}

      upstream && upstream.remote && same? ->
        # A plain push refuses an upstream of a different name (push.default
        # simple), so an alias pushes to its upstream branch by name.
        args =
          if upstream_name == branch,
            do: ["push"],
            else: ["push", upstream.remote, "HEAD:refs/heads/#{upstream_name}"]

        push!(cwd, args, upstream.remote)
        %{"status" => "pushed", "branch" => branch, "upstreamBranch" => upstream.ref}

      # Cut from another branch: the upstream is its base, not its publish
      # target. Publish under its own name — to the configured push remote when
      # one is set, as git would, else to the base's remote — and remember the base.
      upstream && upstream.remote ->
        result = publish(cwd, branch, configured_push_remote(cwd, branch) || upstream.remote)

        # Publishing replaces the tracking that named the base, so remember
        # it as it was read: qualified with its remote when that is not the
        # primary one, or `base_branch/2` would take the primary remote's
        # branch of the same name instead.
        base =
          if upstream.remote == Git.primary_remote(cwd),
            do: upstream_name,
            else: upstream.ref

        remember_base(cwd, branch, base)
        result

      # Cut from a local branch: that branch is its base, as above, but it
      # names no remote to publish to, so the push remote fallback decides.
      upstream && is_nil(upstream.remote) && !same? ->
        remote =
          push_remote(cwd, branch) ||
            fail!("Cannot push because no git remote is configured for this repository.")

        result = publish(cwd, branch, remote)
        remember_base(cwd, branch, upstream_name)
        result

      remote = push_remote(cwd, branch) ->
        publish(cwd, branch, remote)

      true ->
        fail!("Cannot push because no git remote is configured for this repository.")
    end
  end

  # Whether `branch`'s upstream is the branch itself on a remote, as opposed to
  # a branch it was cut from.
  defp tracks_itself?(_cwd, nil), do: false

  defp tracks_itself?(cwd, branch) do
    case Git.upstream(cwd, branch) do
      %{remote: remote} = upstream when is_binary(remote) ->
        Git.same_branch?(cwd, branch, upstream_branch_name(upstream))

      _ ->
        false
    end
  end

  # Remembers the base a branch was cut from, unless one is remembered already
  # (set by the user or `gh`), which still names the base it means.
  defp remember_base(cwd, branch, base) do
    key = "branch.#{branch}.gh-merge-base"

    with {:error, _} <- Git.ok(cwd, ["config", "--get", key]),
         do: Git.ok(cwd, ["config", key, base])
  end

  defp upstream_branch_name(%{remote: nil, ref: name}), do: name

  defp upstream_branch_name(%{remote: remote, ref: ref}),
    do: String.replace_prefix(ref, "#{remote}/", "")

  # Publishes `branch` on `remote` under its own name (a branch named after the
  # remote's branch loses the remote's prefix) and tracks it there.
  defp publish(cwd, branch, remote) do
    name = String.replace_prefix(branch, "#{remote}/", "")
    push!(cwd, ["push", "-u", remote, "HEAD:refs/heads/#{name}"], remote)

    %{
      "status" => "pushed",
      "branch" => branch,
      "upstreamBranch" => "#{remote}/#{name}",
      "setUpstream" => true
    }
  end

  # The remote a first push goes to: the branch's pushRemote, the repository's
  # pushDefault, then the primary remote — as git's own settings name them.
  defp push_remote(cwd, branch),
    do: configured_push_remote(cwd, branch) || Git.primary_remote(cwd)

  # The push remote git's own settings name for `branch` (`branch.<name>.pushRemote`,
  # then `remote.pushDefault`), or nil when neither names a remote that exists.
  defp configured_push_remote(cwd, branch) do
    remotes = Git.remotes(cwd)

    configured =
      Enum.find_value(["branch.#{branch}.pushRemote", "remote.pushDefault"], fn key ->
        case Git.ok(cwd, ["config", "--get", key]) do
          {:ok, out} -> String.trim(out) |> then(&if(&1 == "", do: nil, else: &1))
          _ -> nil
        end
      end)

    if configured in remotes, do: configured
  end

  defp upstream_ref_exists?(cwd, %{remote: nil, ref: ref}),
    do: match?({:ok, _}, Git.ok(cwd, ["rev-parse", "--verify", "--quiet", "refs/heads/#{ref}"]))

  defp upstream_ref_exists?(cwd, %{ref: ref}),
    do: match?({:ok, _}, Git.ok(cwd, ["rev-parse", "--verify", "--quiet", "refs/remotes/#{ref}"]))

  # The open pull request for this branch, or a new one: on Forgejo through its API,
  # anywhere else through `gh`. `pushed?` says this action's push step ran and
  # pushed, which is what makes a configured push remote the published one.
  defp pull_request(cwd, branch, pushed?) do
    remote = Git.primary_remote(cwd)
    url = remote && remote_url(cwd, remote)
    target = url && PullRequests.parse_remote(url)

    case target do
      %{kind: "forgejo"} ->
        forgejo_pull_request(cwd, branch, Map.put(target, :url, url), pushed?)

      %{kind: kind} when kind not in ["unknown"] ->
        github_pull_request(cwd, branch, kind, target, pushed?)

      _ ->
        github_pull_request(cwd, branch, "github", target, pushed?)
    end
  end

  # The user asked for this pull request: its reads and the create go through a pause.
  # `kind` is the remote's host, which decides the change request template the text follows;
  # a host `gh` is not known to serve (self-hosted) is treated as GitHub. `target` is
  # the base repository as the primary remote names it (or nil), against which a
  # fork the branch was published to is told apart.
  defp github_pull_request(cwd, branch, kind, target, pushed?),
    do: GitHub.asked(fn -> create_github_pull_request(cwd, branch, kind, target, pushed?) end)

  defp create_github_pull_request(cwd, branch, kind, target, pushed?) do
    System.find_executable(Application.get_env(:hal_c2, :gh_command, "gh")) ||
      fail!("Creating a PR needs the GitHub CLI (gh).")

    {base, base_qualified} = pr_base(cwd, branch)
    {head_branch, fork_owner} = github_head(cwd, branch, target, pushed?)
    head = if fork_owner, do: "#{fork_owner}:#{head_branch}", else: head_branch
    lookup_owners = pr_lookup_owners(cwd, branch, fork_owner, pushed?)

    case existing_github_pull_request(cwd, head_branch, lookup_owners) do
      %{"url" => url} = pr ->
        %{
          "status" => "opened_existing",
          "url" => url,
          "number" => pr["number"],
          "baseBranch" => pr["baseRefName"],
          "headBranch" => pr["headRefName"],
          "title" => pr["title"]
        }

      _ ->
        %{"title" => title, "body" => body} =
          pr_content(cwd, base, base_qualified, branch, kind)

        args =
          ["pr", "create", "--base", base, "--head", head, "--title", title] ++
            ["--body-file", "-"]

        case GitHub.gh(cwd, args, input: body, timeout: 120_000) do
          {:ok, out} ->
            case Regex.run(~r{https://\S+/pull/(\d+)}, out) do
              [url, number] ->
                %{
                  "status" => "created",
                  "url" => url,
                  "number" => String.to_integer(number),
                  "baseBranch" => base,
                  "headBranch" => head_branch,
                  "title" => title
                }

              nil ->
                fail!("gh pr create failed: #{last_lines(out)}")
            end

          {:error, {_, detail}} ->
            fail!("gh pr create failed: #{detail}")
        end
    end
  end

  # The head owners an existing pull request may be from, in the order to
  # take them: the fork owner's alone, or — for a branch whose repository
  # cannot be told apart (`published_repositories/3` names more than one) —
  # every candidate's owner. Nil keeps "the base repository's own branch".
  defp pr_lookup_owners(cwd, branch, fork_owner, pushed?) do
    case published_repositories(cwd, branch, pushed?) do
      [_one, _two | _] = repositories ->
        repositories
        |> Enum.map(&(String.split(&1, "/") |> hd()))
        |> Enum.uniq_by(&String.downcase/1)

      _ ->
        if fork_owner, do: [fork_owner]
    end
  end

  # The open pull request from `head_branch`, or nil. `gh pr list --head` takes
  # a branch name only (`<owner>:<branch>` is not supported there), so a list
  # for a fork's branch also holds same-named branches on the base repository
  # and other forks: for a fork, more are fetched and only a named owner's
  # is taken, the first owner that has one winning.
  defp existing_github_pull_request(cwd, head_branch, fork_owners) do
    limit = if fork_owners, do: "100", else: "1"

    args =
      ~w(pr list --state open --limit) ++
        [limit] ++
        ~w(--json number,title,url,baseRefName,headRefName,headRepositoryOwner --head) ++
        [head_branch]

    case gh_json(cwd, args) do
      prs when is_list(prs) ->
        case fork_owners do
          nil ->
            Enum.find(prs, &own_pull_request?(&1, nil))

          owners ->
            Enum.find_value(owners, fn owner ->
              Enum.find(prs, &own_pull_request?(&1, owner))
            end)
        end

      _ ->
        nil
    end
  end

  # Whether a listed pull request is the fork's: only one whose head owner
  # `gh` names as the fork's owner is (`gh` always returns the owner when
  # asked, so a reply naming none matches nothing).
  defp own_pull_request?(_pr, nil), do: true

  defp own_pull_request?(pr, fork_owner) do
    case get_in(pr, ["headRepositoryOwner", "login"]) do
      login when is_binary(login) -> String.downcase(login) == String.downcase(fork_owner)
      _ -> false
    end
  end

  # The branch the pull request is from, as its remote has it (`pr_head/2`),
  # and the owner of the fork it was published to — nil when that is the base
  # repository itself, as `forgejo_head/4` tells it.
  defp github_head(cwd, branch, target, pushed?) do
    fork = fork_repository(cwd, branch, target && target.repository, pushed?)
    {pr_head(cwd, branch), fork && fork |> String.split("/") |> hd()}
  end

  # The fork the branch was published to as `owner/name` (nil when that is the
  # base repository itself), read from the published remote's push URL: git
  # pushes to `pushurl` when one is set, whatever the fetch URL names.
  defp fork_repository(cwd, branch, base_repository, pushed?) do
    with remote when is_binary(remote) <- published_remote(cwd, branch, pushed?),
         url when is_binary(url) <- push_url(cwd, remote),
         %{repository: repository} <- PullRequests.parse_remote(url),
         false <- same_repository?(repository, base_repository),
         [_owner, _name | _] <- String.split(repository, "/"),
         do: repository,
         else: (_ -> nil)
  end

  # The repositories the branch may already have a pull request from, in
  # the order to look in: where it was published (the published remote's
  # push URL, as `fork_repository/4` reads it), plus — when no push ran
  # and that remote fetches from a different repository than it pushes
  # to (`pushurl`) — the fetch repository. A push through `pushurl` and
  # a fetch update the same remote-tracking ref, so git's refs cannot
  # tell which repository an in-sync branch lives on; looking under
  # both finds its open pull request either way. Creating still uses
  # the push repository, as `fork_repository/4` tells it.
  defp published_repositories(cwd, branch, pushed?) do
    case published_remote(cwd, branch, pushed?) do
      remote when is_binary(remote) ->
        push = repository_at(push_url(cwd, remote))
        fetch = repository_at(remote_url(cwd, remote))

        if !pushed? && push && fetch && !same_repository?(push, fetch),
          do: [push, fetch],
          else: Enum.reject([push], &is_nil/1)

      _ ->
        []
    end
  end

  defp repository_at(url) when is_binary(url) do
    case PullRequests.parse_remote(url) do
      %{repository: repository} -> repository
      _ -> nil
    end
  end

  defp repository_at(_url), do: nil

  # Read from config, as `remote_url/2` reads the fetch URL: `git remote
  # get-url --push` would first expand the checkout's `insteadOf` rewrites,
  # which name transport aliases (or local paths), not the repository.
  defp push_url(cwd, remote) do
    case Git.ok(cwd, ["config", "--get", "remote.#{remote}.pushurl"]) do
      {:ok, url} -> String.trim(url)
      _ -> remote_url(cwd, remote)
    end
  end

  defp same_repository?(_repository, nil), do: false

  defp same_repository?(repository, base),
    do: String.downcase(repository) == String.downcase(base)

  # The remote the branch was published to, following `push/2`'s arms: an
  # alias is pushed to its upstream's remote by name, but every other push
  # honours the branch's push remote settings first — a same-named upstream
  # included, since a plain `git push` sends it to `pushRemote`. A configured
  # push remote is only the published one when the push ran (this action's,
  # or an earlier one the remote-tracking ref still shows): when publication
  # was skipped, the branch lives where its upstream says, however its push
  # settings are aimed.
  defp published_remote(cwd, branch, pushed?) do
    case Git.upstream(cwd, branch) do
      %{remote: remote} = upstream when is_binary(remote) ->
        name = upstream_branch_name(upstream)

        cond do
          name != branch and Git.same_branch?(cwd, branch, name) ->
            remote

          configured = configured_push_remote(cwd, branch) ->
            if pushed? or remote_branch?(cwd, configured, branch),
              do: configured,
              else: remote

          true ->
            remote
        end

      _ ->
        configured_push_remote(cwd, branch)
    end
  end

  # Whether `remote` is known to hold `branch` (under the name publishing
  # gives it there), from its remote-tracking ref.
  defp remote_branch?(cwd, remote, branch) do
    name = String.replace_prefix(branch, "#{remote}/", "")

    match?(
      {:ok, _},
      Git.ok(cwd, ["rev-parse", "--verify", "--quiet", "refs/remotes/#{remote}/#{name}"])
    )
  end

  # As the Forgejo provider's `createChangeRequest`: in the repository the primary
  # remote names, from `owner:branch` when the branch is pushed to a fork of it.
  defp forgejo_pull_request(cwd, branch, target, pushed?) do
    {base, base_qualified} = pr_base(cwd, branch)
    {head_branch, fork} = forgejo_head(cwd, branch, target, pushed?)
    owner = fork && fork |> String.split("/") |> hd()

    case existing_forgejo_pull_request(cwd, branch, head_branch, target, fork, pushed?) do
      [pr | _] ->
        %{
          "status" => "opened_existing",
          "url" => pr["url"],
          "number" => pr["number"],
          "baseBranch" => pr["baseRef"],
          "headBranch" => pr["headRef"],
          "title" => pr["title"]
        }

      [] ->
        %{"title" => title, "body" => body} =
          pr_content(cwd, base, base_qualified, branch, target.kind)

        request = %{
          "base" => base,
          "head" => if(owner, do: "#{owner}:#{head_branch}", else: head_branch),
          "title" => title,
          "body" => body
        }

        path = "repos/#{Forgejo.encode_repository(target.repository)}/pulls"

        with {:ok, out, _} <-
               Forgejo.api(cwd, [repository: target.repository, remote_url: target.url], path,
                 method: "POST",
                 body: request
               ),
             {:ok, %{"number" => number} = pr} <- JSON.decode(out) do
          %{
            "status" => "created",
            "url" => pr["html_url"],
            "number" => number,
            "baseBranch" => base,
            "headBranch" => head_branch,
            "title" => title
          }
        else
          {:error, {_reason, detail}} -> fail!("Forgejo could not create the PR: #{detail}")
          _ -> fail!("Forgejo answered the new PR in an unexpected shape.")
        end
    end
  end

  # Only a pull request from this branch's own repository is its pull
  # request: a fork can hold a branch of the same name. Where that
  # repository cannot be told apart (`published_repositories/3`), each
  # candidate is looked in, the push repository first.
  defp existing_forgejo_pull_request(cwd, branch, head_branch, target, fork, pushed?) do
    repositories =
      case published_repositories(cwd, branch, pushed?) do
        [_one, _two | _] = repositories -> repositories
        _ -> [fork || target.repository]
      end

    Enum.find_value(repositories, [], fn repository ->
      case ChangeRequests.forgejo_list(cwd, target, head_branch,
             state: "open",
             limit: 1,
             head_repository: repository
           ) do
        [] -> nil
        pulls -> pulls
      end
    end)
  end

  # The branch the pull request is from, as its remote has it (`pr_head/2`),
  # and the fork it was published to as `owner/name` (nil when that is the
  # target repository itself) — as `github_head/4` tells them, from where the
  # branch was published (`published_remote/3`, `push_url/2`), not from the
  # upstream it tracks.
  defp forgejo_head(cwd, branch, target, pushed?),
    do: {pr_head(cwd, branch), fork_repository(cwd, branch, target.repository, pushed?)}

  defp remote_url(cwd, remote) do
    case Git.ok(cwd, ["config", "--get", "remote.#{remote}.url"]) do
      {:ok, url} -> String.trim(url)
      _ -> nil
    end
  end

  # The branch name the pull request is from, as the remote has it: a local
  # alias of its upstream ("upstream/effect-atom" tracking "origin/effect-atom")
  # is published under the upstream's name, so that is its head. A branch cut
  # from another keeps its own name (its upstream is its base, not itself).
  defp pr_head(cwd, branch) do
    case Git.upstream(cwd, branch) do
      %{remote: remote} = upstream when is_binary(remote) ->
        name = upstream_branch_name(upstream)
        if Git.same_branch?(cwd, branch, name), do: name, else: branch

      _ ->
        branch
    end
  end

  # The base twice: as the host names it (its branch name, without the local
  # remote it was read from, which need not be the primary one) for `--base`,
  # and qualified with that remote for local git work, or the primary
  # remote's branch of the same name would be compared against instead.
  defp pr_base(cwd, branch) do
    base = Git.base_branch(cwd, branch) || "main"

    name =
      Enum.find_value(Git.remotes(cwd), base, fn remote ->
        case String.replace_prefix(base, "#{remote}/", "") do
          ^base -> nil
          stripped -> stripped
        end
      end)

    if name == branch, do: {"main", "main"}, else: {name, base}
  end

  # The title and body the text generator writes for the branch's commits
  # since `base`, compared against its qualified ref.
  defp pr_content(cwd, base, base_qualified, branch, kind) do
    base_ref = base_ref(cwd, base_qualified)
    range = "#{base_ref}...HEAD"
    {:ok, commits} = Git.ok(cwd, ["log", "--oneline", String.replace(range, "...", "..")])
    {:ok, %{out: stat}} = Git.run(cwd, ["diff", "--stat", range], max_bytes: 100_000)

    {:ok, %{out: patch}} =
      Git.run(
        cwd,
        ["diff", "--no-ext-diff", "--no-textconv", "--patch", "--minimal", range],
        max_bytes: 200_000
      )

    case TextGeneration.pr_content(cwd, base, branch, commits, stat, patch,
           policy: Style.policy(cwd),
           template: Style.pr_template(cwd, base_ref, kind),
           thread_history: thread_history(Process.get(:git_action_thread))
         ) do
      {:ok, content} -> content
      {:error, reason} -> fail!("Could not write the PR description: #{reason}")
    end
  end

  # What the thread the action ran beside did, so the description can say which checks it
  # ran, including in the turn that is running it. The thread's runs that were rolled back are not part of it. A thread this MC does
  # not hold gives nothing.
  defp thread_history(thread_id) when is_binary(thread_id) do
    HalC2.Streams.read(
      thread_id,
      &HalC2.Orchestration.Handoff.transcript(&1, 1_000_000, 0, @thread_history_chars,
        running: true
      )
    )
  end

  defp thread_history(_thread_id), do: nil

  defp base_ref(cwd, base) do
    remote = Git.primary_remote(cwd)

    if remote &&
         match?({:ok, _}, Git.ok(cwd, ["rev-parse", "--verify", "--quiet", "#{remote}/#{base}"])),
       do: "#{remote}/#{base}",
       else: base
  end

  defp gh_json(cwd, args) do
    case GitHub.gh(cwd, args) do
      {:ok, out} -> JSON.decode!(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # --- toast ----------------------------------------------------------------------

  defp toast(cwd, result) do
    %{"commit" => commit, "push" => push, "pr" => pr, "action" => action} = result
    default? = Vcs.local_status(cwd)["isDefaultRef"]
    sha = commit["commitSha"] && String.slice(commit["commitSha"], 0, 7)

    {title, description} =
      cond do
        pr["status"] in ["created", "opened_existing"] ->
          verb = if pr["status"] == "created", do: "Created", else: "Opened"
          {"#{verb} PR#{if pr["number"], do: " ##{pr["number"]}"}", pr["title"]}

        push["status"] == "pushed" ->
          target = push["upstreamBranch"] || push["branch"]
          {"Pushed#{if sha, do: " #{sha}"}#{if target, do: " to #{target}"}", commit["subject"]}

        commit["status"] == "created" ->
          {if(sha, do: "Committed #{sha}", else: "Committed changes"), commit["subject"]}

        true ->
          {"Done", nil}
      end

    cta =
      cond do
        action == "commit" and commit["status"] == "created" and not behind_upstream?(cwd) ->
          %{"kind" => "run_action", "label" => "Push", "action" => %{"kind" => "push"}}

        pr["url"] ->
          %{"kind" => "open_pr", "label" => "View PR", "url" => pr["url"]}

        action in ~w(push commit_push) and push["status"] == "pushed" and not default? ->
          %{"kind" => "run_action", "label" => "Create PR", "action" => %{"kind" => "create_pr"}}

        true ->
          %{"kind" => "none"}
      end

    %{"title" => title, "cta" => cta}
    |> then(&if(description, do: Map.put(&1, "description", truncate(description)), else: &1))
  end

  # A push from behind its upstream cannot fast-forward, so the commit's result offers none.
  defp behind_upstream?(cwd), do: ((Vcs.remote_status(cwd) || %{})["behindCount"] || 0) > 0

  defp truncate(text) when byte_size(text) <= 72, do: text
  defp truncate(text), do: String.slice(text, 0, 69) |> String.trim_trailing() |> Kernel.<>("...")

  # --- helpers --------------------------------------------------------------------

  @doc "A branch name from free text, under `feature/` unless it names a namespace."
  def feature_branch_name(raw), do: TextGeneration.namespaced_branch(raw)

  # A name no branch has, and no branch sits on the path of: a branch `fix` blocks every
  # `fix/…`, so the namespace becomes `fix-2/…` (the next number that is free).
  defp unique_branch(existing, name) do
    taken? = &(MapSet.member?(existing, &1) or Git.branch_path_taken_by?(existing, &1))

    segments = String.split(name, "/")

    blocker =
      Enum.find(
        for(n <- 1..(length(segments) - 1)//1, do: segments |> Enum.take(n) |> Enum.join("/")),
        &MapSet.member?(existing, &1)
      )

    name =
      if blocker do
        rest = String.replace_prefix(name, blocker, "")

        Enum.find_value(Stream.iterate(2, &(&1 + 1)), fn n ->
          candidate = "#{blocker}-#{n}" <> rest
          not Git.branch_path_taken_by?(existing, candidate) && candidate
        end)
      else
        name
      end

    if taken?.(name),
      do:
        Enum.find_value(
          Stream.iterate(2, &(&1 + 1)),
          &(not taken?.("#{name}-#{&1}") && "#{name}-#{&1}")
        ),
      else: name
  end

  defp git!(cwd, args) do
    case Git.run(cwd, args, max_bytes: 256 * 1024) do
      {:ok, %{status: 0}} -> :ok
      {:ok, %{err: err}} -> fail!("git #{hd(args)} failed: #{last_lines(err)}")
      {:error, reason} -> fail!("git #{hd(args)} failed: #{reason}")
    end
  end

  defp push!(cwd, args, remote) do
    case Git.run(cwd, args, max_bytes: 256 * 1024) do
      {:ok, %{status: 0}} ->
        :ok

      {:ok, %{err: err}} ->
        {hint, cta} = push_refusal(err, remote_repository(cwd, remote))

        # A named refusal (the workflow scope cases above) keeps its hint; a plain
        # rejection is said in fixed words, quoting none of the remote's output.
        case {hint, push_rejection(err)} do
          {"", message} when is_binary(message) -> fail!(message)
          _ -> fail!("git push failed: #{last_lines(err)}#{hint}", cta)
        end

      {:error, reason} ->
        fail!("git push failed: #{reason}")
    end
  end

  # The GitHub `owner/name` the remote pushes to, or nil.
  defp remote_repository(cwd, remote) do
    with {:ok, url} <- Git.ok(cwd, ["remote", "get-url", "--push", remote]),
         %{kind: "github", repository: repository} <- HalC2.PullRequests.parse_remote(url),
         do: repository,
         else: (_ -> nil)
  end

  # What to say and offer (`GitActionFailureCta`, or nil) when GitHub refuses a push
  # changing a workflow, from git's stderr and the GitHub repository pushed to (nil when
  # it is not one); `{"", nil}` for any other refusal.
  #
  # The credential lacks the `workflow` scope: the GitHub CLI's sign-in when it was made
  # for SSH (see `HalC2.Git.use_gh_for_github/0`), which `gh auth refresh` widens, or a
  # token of the user's own, which it cannot. A GitHub App's token lacks the Workflows
  # permission instead, which no sign-in here changes: the App's installation has to
  # grant it, from the repository's GitHub Apps settings (which list the installations
  # whether a user or an organization owns it), or the user's own when the repository
  # is not known.
  defp push_refusal(err, repository) do
    cond do
      err =~ ~r/without `workflow` scope/ ->
        {" GitHub refused it because it changes a workflow file and the sign-in that " <>
           "pushed lacks the workflow scope. If this machine pushes with the GitHub " <>
           "CLI's sign-in, run `gh auth refresh -s workflow` here, then try again; a " <>
           "token of your own needs the workflow scope.",
         %{
           "kind" => "copy_command",
           "label" => "Copy command",
           "command" => "gh auth refresh -s workflow"
         }}

      err =~ ~r/without `workflows` permission/ ->
        {" GitHub refused it because it changes a workflow file and the GitHub App " <>
           "whose token pushed lacks the Workflows permission. Grant the App read and " <>
           "write access to Workflows in its installation settings, then try again.",
         %{
           "kind" => "open_url",
           "label" => "Grant Workflows permission",
           "url" =>
             if(repository,
               do: "https://github.com/#{repository}/settings/installations",
               else: "https://github.com/settings/installations"
             )
         }}

      true ->
        {"", nil}
    end
  end

  # Why the remote turned a push away, from git's own rejection lines, said in
  # fixed words: a hook's or the server's own output is never quoted.
  defp push_rejection(err) do
    cond do
      err =~ "non-fast-forward" ->
        "The remote has commits this branch doesn't have. Pull or rebase, then push again."

      err =~ "[remote rejected]" ->
        "The remote rejected the push. Push this branch from a terminal to see the server's message."

      true ->
        nil
    end
  end

  defp last_lines(text),
    do: text |> String.trim() |> String.split("\n") |> Enum.take(-3) |> Enum.join(" ")

  defp blank?(nil), do: true
  defp blank?(text), do: String.trim(text) == ""
end
