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

  alias HalC2.{Git, TextGeneration, Vcs}
  alias HalC2.TextGeneration.Style

  @commit_actions ~w(commit commit_push commit_push_pr)

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

    try do
      result = run_action(input, emit)
      link_created(input["threadId"], result["pr"])
      emit.(%{"kind" => "action_finished", "result" => result})
      {:ok, result}
    catch
      {:git_action_error, message} ->
        emit.(%{
          "kind" => "action_failed",
          "phase" => Process.get(:git_action_phase),
          "message" => message
        })

        {:error, message}
    after
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

  defp fail!(message), do: throw({:git_action_error, message})

  defp phase!(emit, phase, label) do
    Process.put(:git_action_phase, phase)
    emit.(%{"kind" => "phase_started", "phase" => phase, "label" => label})
  end

  defp run_action(%{"cwd" => cwd, "action" => action} = input, emit) do
    status = Map.merge(Vcs.local_status(cwd), Vcs.remote_status(cwd) || %{})
    branch = status["refName"]
    commit? = action in @commit_actions
    feature? = input["featureBranch"] == true

    push? =
      action in ~w(push commit_push commit_push_pr) or
        (action == "create_pr" and (not status["hasUpstream"] or status["aheadCount"] > 0))

    pr? = action in ~w(create_pr commit_push_pr)

    cond do
      not status["isRepo"] ->
        fail!("#{cwd} is not a git repository.")

      feature? and not commit? ->
        fail!("Feature-branch checkout is only supported for commit actions.")

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

    if not feature? and (push? or pr?) and branch == nil,
      do: fail!("Cannot #{if pr?, do: "create a pull request", else: "push"} from detached HEAD.")

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
        pull_request(cwd, branch)
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

    name =
      unique_branch(existing, feature_branch_name(suggestion["branch"] || suggestion["subject"]))

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

  # Runs `git commit` with a trace2 event log, so hooks are reported as they start
  # and finish (`hook_started`, `hook_finished`) around the output lines they print
  # (`hook_output`), the way the Node server does. Returns `{exit status, stderr}`.
  defp traced_commit(cwd, args, emit) do
    trace =
      Path.join(System.tmp_dir!(), "hal-c2-git-trace2-#{System.unique_integer([:positive])}")

    File.write!(trace, "")
    Process.put(:git_trace, %{path: trace, offset: 0, hook: nil})

    {status, err, pending} =
      ["git" | args]
      |> Exile.stream(
        cd: cwd,
        env: [{"GIT_TRACE2_EVENT", trace}],
        stderr: :consume,
        ignore_epipe: true
      )
      |> Enum.reduce({nil, [], %{}}, fn
        {:exit, {:status, status}}, {_, err, pending} ->
          {status, err, pending}

        {:exit, _}, {_, err, pending} ->
          {1, err, pending}

        {stream, data}, {status, err, pending} ->
          trace_events(emit)
          buffer = Map.get(pending, stream, "") <> IO.iodata_to_binary(data)
          [rest | lines] = buffer |> String.split("\n") |> Enum.reverse()
          for line <- Enum.reverse(lines), do: hook_line(emit, stream, line)
          err = if stream == :stderr, do: [err, data], else: err
          {status, err, Map.put(pending, stream, rest)}
      end)

    trace_events(emit)
    for {stream, rest} <- pending, do: hook_line(emit, stream, rest)
    trace_events(emit)

    with %{hook: hook} when hook != nil <- Process.get(:git_trace) do
      emit.(%{
        "kind" => "hook_finished",
        "hookName" => hook,
        "exitCode" => 0,
        "durationMs" => nil
      })
    end

    File.rm(trace)
    {status, IO.iodata_to_binary(err)}
  end

  defp hook_line(emit, stream, line) do
    if (line = String.trim(line)) != "" do
      emit.(%{
        "kind" => "hook_output",
        "hookName" => Process.get(:git_trace).hook,
        "stream" => Atom.to_string(stream),
        "text" => line
      })
    end
  end

  # Emits the hook starts and exits git has traced since the last call.
  defp trace_events(emit) do
    %{path: path, offset: offset} = trace = Process.get(:git_trace)
    {:ok, contents} = File.read(path)
    complete = contents |> binary_part(offset, byte_size(contents) - offset)

    case :binary.matches(complete, "\n") do
      [] ->
        :ok

      matches ->
        {last, 1} = List.last(matches)
        chunk = binary_part(complete, 0, last)
        Process.put(:git_trace, %{trace | offset: offset + last + 1})

        for line <- String.split(chunk, "\n", trim: true),
            {:ok, record} <- [JSON.decode(line)],
            record["child_class"] == "hook" or record["category"] == "hook" do
          trace_event(emit, record)
        end
    end
  end

  defp trace_event(emit, %{"event" => "child_start"} = record) do
    hook = record["hook_name"]
    Process.put(:git_trace, %{Process.get(:git_trace) | hook: hook})
    Process.put({:git_hook_started, hook}, System.monotonic_time(:millisecond))
    emit.(%{"kind" => "hook_started", "hookName" => hook})
  end

  defp trace_event(emit, %{"event" => "child_exit"} = record) do
    hook = record["hook_name"] || Process.get(:git_trace).hook
    started = Process.delete({:git_hook_started, hook})
    Process.put(:git_trace, %{Process.get(:git_trace) | hook: nil})

    emit.(%{
      "kind" => "hook_finished",
      "hookName" => hook,
      "exitCode" => record["exitCode"],
      "durationMs" => started && System.monotonic_time(:millisecond) - started
    })
  end

  # Newer git runs hooks in parallel and logs only the region's end, not the child's exit.
  defp trace_event(emit, %{"event" => "region_leave", "label" => hook}) do
    if Process.get(:git_trace).hook == hook,
      do: trace_event(emit, %{"event" => "child_exit", "hook_name" => hook, "child_id" => nil})
  end

  defp trace_event(_emit, _record), do: :ok

  # Stages the chosen files (or everything) and writes the message; nil when
  # nothing is staged.
  defp suggestion(cwd, branch, input, include_branch) do
    case input["filePaths"] do
      [_ | _] = paths ->
        Git.run(cwd, ["reset"])
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
          |> then(&if(include_branch, do: Map.put(&1, "branch", subject), else: &1))

        nil ->
          {:ok, %{out: patch}} =
            Git.run(cwd, ~w(diff --no-ext-diff --cached --patch --minimal), max_bytes: 200_000)

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
    upstream = upstream(cwd)

    cond do
      upstream && status["aheadCount"] == 0 && status["behindCount"] == 0 ->
        %{"status" => "skipped_up_to_date", "branch" => branch, "upstreamBranch" => upstream}

      upstream ->
        git!(cwd, ["push"])
        %{"status" => "pushed", "branch" => branch, "upstreamBranch" => upstream}

      remote = Git.primary_remote(cwd) ->
        git!(cwd, ["push", "-u", remote, "HEAD:refs/heads/#{branch}"])

        %{
          "status" => "pushed",
          "branch" => branch,
          "upstreamBranch" => "#{remote}/#{branch}",
          "setUpstream" => true
        }

      true ->
        fail!("Cannot push because no git remote is configured for this repository.")
    end
  end

  defp upstream(cwd) do
    case Git.ok(cwd, ~w(rev-parse --abbrev-ref --symbolic-full-name @{upstream})) do
      {:ok, ref} -> String.trim(ref)
      _ -> nil
    end
  end

  # GitHub pull requests through `gh`: the open one for this branch, or a new one.
  defp pull_request(cwd, branch) do
    gh =
      System.find_executable(Application.get_env(:hal_c2, :gh_command, "gh")) ||
        fail!("Creating a PR needs the GitHub CLI (gh).")

    base =
      (Git.base_branch(cwd, branch) || "main")
      |> String.replace(~r{^[^/]+/}, "", global: false)
      |> then(&if(&1 == branch, do: "main", else: &1))

    case gh_json(
           gh,
           cwd,
           ~w(pr list --state open --limit 1 --json number,title,url,baseRefName,headRefName --head) ++
             [branch]
         ) do
      [%{"url" => url} = pr | _] ->
        %{
          "status" => "opened_existing",
          "url" => url,
          "number" => pr["number"],
          "baseBranch" => pr["baseRefName"],
          "headBranch" => pr["headRefName"],
          "title" => pr["title"]
        }

      _ ->
        base_ref = base_ref(cwd, base)
        range = "#{base_ref}...HEAD"
        {:ok, commits} = Git.ok(cwd, ["log", "--oneline", String.replace(range, "...", "..")])
        {:ok, %{out: stat}} = Git.run(cwd, ["diff", "--stat", range], max_bytes: 100_000)

        {:ok, %{out: patch}} =
          Git.run(cwd, ["diff", "--no-ext-diff", "--patch", "--minimal", range],
            max_bytes: 200_000
          )

        %{"title" => title, "body" => body} =
          case TextGeneration.pr_content(cwd, base, branch, commits, stat, patch,
                 policy: Style.policy(cwd),
                 template: Style.pr_template(cwd, base_ref)
               ) do
            {:ok, content} -> content
            {:error, reason} -> fail!("Could not write the PR description: #{reason}")
          end

        case Exile.stream(
               [
                 gh,
                 "pr",
                 "create",
                 "--base",
                 base,
                 "--head",
                 branch,
                 "--title",
                 title,
                 "--body-file",
                 "-"
               ],
               cd: cwd,
               input: [body],
               stderr: :consume
             )
             |> Enum.reduce({"", ""}, fn
               {:stdout, d}, {o, e} -> {o <> IO.iodata_to_binary(d), e}
               {:stderr, d}, {o, e} -> {o, e <> IO.iodata_to_binary(d)}
               {:exit, _}, acc -> acc
             end) do
          {out, err} ->
            case Regex.run(~r{https://\S+/pull/(\d+)}, out <> err) do
              [url, number] ->
                %{
                  "status" => "created",
                  "url" => url,
                  "number" => String.to_integer(number),
                  "baseBranch" => base,
                  "headBranch" => branch,
                  "title" => title
                }

              nil ->
                fail!("gh pr create failed: #{last_lines(err)}")
            end
        end
    end
  rescue
    error in [Exile.Stream.AbnormalExit] -> fail!("gh failed: #{Exception.message(error)}")
  end

  defp base_ref(cwd, base) do
    remote = Git.primary_remote(cwd)

    if remote &&
         match?({:ok, _}, Git.ok(cwd, ["rev-parse", "--verify", "--quiet", "#{remote}/#{base}"])),
       do: "#{remote}/#{base}",
       else: base
  end

  defp gh_json(gh, cwd, args) do
    case System.cmd(gh, args, cd: cwd, stderr_to_stdout: false) do
      {out, 0} -> JSON.decode!(out)
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
        action == "commit" and commit["status"] == "created" ->
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

  defp truncate(text) when byte_size(text) <= 72, do: text
  defp truncate(text), do: String.slice(text, 0, 69) |> String.trim_trailing() |> Kernel.<>("...")

  # --- helpers --------------------------------------------------------------------

  @doc "A `feature/…` branch name from free text."
  def feature_branch_name(raw) do
    fragment = TextGeneration.branch_fragment(raw)

    if String.starts_with?(fragment, "feature/"), do: fragment, else: "feature/#{fragment}"
  end

  defp unique_branch(existing, name) do
    if MapSet.member?(existing, name),
      do:
        Enum.find_value(
          Stream.iterate(2, &(&1 + 1)),
          &(not MapSet.member?(existing, "#{name}-#{&1}") && "#{name}-#{&1}")
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

  defp last_lines(text),
    do: text |> String.trim() |> String.split("\n") |> Enum.take(-3) |> Enum.join(" ")

  defp blank?(nil), do: true
  defp blank?(text), do: String.trim(text) == ""
end
