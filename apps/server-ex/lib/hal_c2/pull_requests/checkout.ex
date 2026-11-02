defmodule HalC2.PullRequests.Checkout do
  @moduledoc """
  Opening a pull request in a thread (`git.resolvePullRequest`,
  `git.preparePullRequestThread`). The checkout's primary remote names the host: the
  pull request is read through `gh` (GitHub, and any host not otherwise known),
  `glab` (GitLab), Bitbucket's API or a Forgejo CLI, from a number, `#number` or URL.

  `local` checks it out in the project's checkout as the host's CLI would (Forgejo:
  its `refs/pull/<n>/head` into `pulls/<n>`, brought to the head keeping uncommitted
  files). `worktree` gives it a worktree of its own: the head branch is fetched from
  the repository it lives in (a fork gets a remote named after its owner, reached
  the way the checkout's remote is), falling back to the host's pull request ref.
  The branch follows the pull request's own branch, best effort, so a push lands on
  it. A worktree that already holds the branch is reused and moved onto the head
  only when that loses nothing (`refresh/3`).

  A fork's branch is fetched under `hal-c2/pr-<n>/<branch>` (`hal-c2-pr-<n>/…` where a
  branch named `hal-c2` is in the way). The project's setup script is not run for the
  new worktree.
  """

  alias HalC2.{AgentSessions, Git, PullRequests, PullRequests.GitHub, SourceControl}
  alias HalC2.SourceControl.Forgejo

  @gh_fields "number,title,url,baseRefName,headRefName,state,isCrossRepository," <>
               "headRepository,headRepositoryOwner,headRefOid"
  @not_found "Pull request not found. Check the PR number or URL and try again."
  @in_root "This PR branch is already checked out in the main repo. Use Local, or switch the main repo off that branch before creating a worktree thread."

  @doc "`git.resolvePullRequest`."
  def resolve(%{"cwd" => cwd, "reference" => reference}) do
    with {:ok, pr} <- read(cwd, host(cwd), reference, "resolvePullRequest"),
         do: {:ok, %{"pullRequest" => resolved(pr)}}
  end

  @doc "`git.preparePullRequestThread`."
  def prepare(%{"cwd" => cwd, "reference" => reference, "mode" => mode}) do
    host = host(cwd)

    result =
      with {:ok, pr} <- read(cwd, host, reference, "preparePullRequestThread") do
        if mode == "local", do: local(cwd, host, pr), else: worktree(cwd, host, pr)
      end

    HalC2.Vcs.Watch.refresh(cwd)
    result
  end

  # --- reading -------------------------------------------------------------------------

  # The primary remote, its configured URL (before any `insteadOf`) and the host it is on.
  defp host(cwd) do
    remote = Git.primary_remote(cwd) || "origin"

    url =
      case Git.ok(cwd, ["config", "--get", "remote.#{remote}.url"]) do
        {:ok, url} -> String.trim(url)
        _ -> nil
      end

    parsed = url && PullRequests.parse_remote(url)

    kind =
      if parsed && parsed.kind in ~w(gitlab bitbucket forgejo), do: parsed.kind, else: "github"

    %{remote: remote, url: url, kind: kind, repository: parsed && parsed.repository}
  end

  # A pull request as `gh pr view` names it, plus `headRepository` (`owner/name`, nil
  # when the host does not say), `headOwner` and `headSha`.
  defp read(cwd, host, reference, operation) do
    reference = reference |> String.trim() |> String.replace(~r/^#(\d+)$/, "\\1")

    case fetch_pr(cwd, host, reference) do
      {:ok, %{"number" => number, "headRefName" => head} = pr}
      when is_integer(number) and is_binary(head) ->
        {:ok, pr}

      {:ok, _} ->
        error(operation, cwd, "The host answered in an unexpected shape.")

      {:error, {:not_found, _}} ->
        error(operation, cwd, @not_found)

      {:error, {_reason, detail}} ->
        error(operation, cwd, detail)
    end
  end

  defp fetch_pr(cwd, %{kind: "github"}, reference) do
    with {:ok, out} <- GitHub.gh(cwd, ["pr", "view", reference, "--json", @gh_fields]),
         {:ok, pr} <- decode(out) do
      owner = get_in(pr, ["headRepositoryOwner", "login"])
      repo = pr["headRepository"] || %{}

      # An older gh names the head repository and its owner but not its full name.
      full =
        repo["nameWithOwner"] ||
          if(is_binary(owner) and is_binary(repo["name"]), do: "#{owner}/#{repo["name"]}")

      {:ok,
       pr
       |> Map.drop(~w(headRepositoryOwner headRefOid))
       |> Map.merge(%{
         "isCrossRepository" => pr["isCrossRepository"] == true,
         "headRepository" => full,
         "headOwner" => owner || (full && full |> String.split("/") |> hd()),
         "headSha" => pr["headRefOid"]
       })}
    end
  end

  defp fetch_pr(cwd, %{kind: "gitlab"}, reference) do
    case SourceControl.Cli.run("glab", ["mr", "view", reference, "--output", "json"],
           cd: cwd,
           timeout: 30_000
         ) do
      {:ok, out, _} ->
        with {:ok, mr} <- decode(out), do: {:ok, gitlab(mr)}

      {:error, {_reason, detail}} = failure ->
        if detail =~ ~r/not found|404/i, do: {:error, {:not_found, detail}}, else: failure
    end
  end

  defp fetch_pr(_cwd, %{kind: "bitbucket", repository: repository}, reference) do
    with {:ok, number} <- number(reference, ~r/(?:^|\/pull-requests\/)(\d+)(?:$|[\/?#])/) do
      case SourceControl.bitbucket_get("/repositories/#{repository}/pullrequests/#{number}") do
        nil -> {:error, {:not_found, @not_found}}
        pr -> {:ok, bitbucket(pr)}
      end
    end
  end

  defp fetch_pr(cwd, %{kind: "forgejo"} = host, reference) do
    with {:ok, number} <- number(reference, ~r/(?:^|\/pulls\/)(\d+)(?:$|[\/?#])/),
         {:ok, body, _} <-
           Forgejo.api(
             cwd,
             [repository: host.repository, remote_url: host.url],
             "repos/#{Forgejo.encode_repository(host.repository)}/pulls/#{number}"
           ),
         {:ok, pr} <- decode(body),
         do: {:ok, forgejo(pr)}
  end

  defp number(reference, pattern) do
    case Regex.run(pattern, reference) do
      [_, number] ->
        {:ok, String.to_integer(number)}

      _ ->
        {:error,
         {:failed,
          "Specify a pull request number or #{if pattern.source =~ "pulls", do: "Forgejo", else: "Bitbucket"} pull request URL."}}
    end
  end

  defp decode(out) do
    case JSON.decode(out) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> {:error, {:failed, "The host answered in an unexpected shape."}}
    end
  end

  # As `normalizeGitLabMergeRequestRecord`: project ids decide when given, else the
  # projects' paths, compared without case.
  defp gitlab(mr) do
    source = gitlab_path(mr["source_project"])
    target = gitlab_path(mr["target_project"])

    cross? =
      case {mr["source_project_id"], mr["target_project_id"]} do
        {a, b} when is_integer(a) and is_integer(b) ->
          a != b

        _ ->
          is_binary(source) and is_binary(target) and
            String.downcase(source) != String.downcase(target)
      end

    %{
      "number" => mr["iid"],
      "title" => mr["title"],
      "url" => mr["web_url"],
      "baseRefName" => mr["target_branch"],
      "headRefName" => mr["source_branch"],
      "state" =>
        case mr["state"] do
          "merged" -> "MERGED"
          s when s in ["closed", "locked"] -> "CLOSED"
          _ -> "OPEN"
        end,
      "isCrossRepository" => cross?,
      "headRepository" => source,
      "headOwner" => source && source |> String.split("/") |> hd(),
      "headSha" => mr["sha"]
    }
  end

  defp gitlab_path(%{} = project),
    do:
      project["path_with_namespace"] ||
        get_in(project, ["namespace", "full_path"]) || get_in(project, ["namespace", "path"])

  defp gitlab_path(_), do: nil

  # A source repository that was deleted names no full name: the pull request is then
  # taken as from the same repository.
  defp bitbucket(pr) do
    source = get_in(pr, ["source", "repository"])
    head = source && source["full_name"]
    base = get_in(pr, ["destination", "repository", "full_name"])

    %{
      "number" => pr["id"],
      "title" => pr["title"],
      "url" => get_in(pr, ["links", "html", "href"]),
      "baseRefName" => get_in(pr, ["destination", "branch", "name"]),
      "headRefName" => get_in(pr, ["source", "branch", "name"]),
      "state" =>
        case pr["state"] do
          "MERGED" -> "MERGED"
          s when s in ["DECLINED", "SUPERSEDED"] -> "CLOSED"
          _ -> "OPEN"
        end,
      "isCrossRepository" => is_binary(head) and is_binary(base) and head != base,
      "headRepository" => head,
      "headOwner" =>
        (source && get_in(source, ["workspace", "slug"])) ||
          (head && head |> String.split("/") |> hd()),
      "headSha" => get_in(pr, ["source", "commit", "hash"])
    }
  end

  defp forgejo(pr) do
    head = get_in(pr, ["head", "repo"])
    base = get_in(pr, ["base", "repo"])

    %{
      "number" => pr["number"],
      "title" => pr["title"],
      "url" => pr["html_url"],
      "baseRefName" => get_in(pr, ["base", "ref"]),
      "headRefName" => get_in(pr, ["head", "ref"]),
      "state" =>
        cond do
          pr["merged"] == true -> "MERGED"
          pr["state"] == "closed" -> "CLOSED"
          true -> "OPEN"
        end,
      "isCrossRepository" =>
        is_map(head) and is_map(base) and head["full_name"] != base["full_name"],
      "headRepository" => head && head["full_name"],
      "headOwner" => head && get_in(head, ["owner", "login"]),
      "headSha" => get_in(pr, ["head", "sha"])
    }
  end

  defp resolved(pr),
    do: %{
      "number" => pr["number"],
      "title" => pr["title"],
      "url" => pr["url"],
      "baseBranch" => pr["baseRefName"],
      "headBranch" => pr["headRefName"],
      "state" => GitHub.state(pr)
    }

  # --- local ---------------------------------------------------------------------------

  defp local(cwd, host, pr) do
    with {:ok, branch} <- checkout(cwd, host, pr) do
      branch = branch || Git.current_branch(cwd) || pr["headRefName"]
      configure_upstream(cwd, host, pr, branch)

      {:ok,
       %{
         "pullRequest" => resolved(pr),
         "branch" => branch,
         "worktreePath" => nil,
         "isOnPullRequestHead" => true
       }}
    else
      {:error, {_reason, detail}} -> error("preparePullRequestThread", cwd, detail)
    end
  end

  defp checkout(cwd, %{kind: "github"}, pr) do
    with {:ok, _} <-
           GitHub.gh(cwd, ["pr", "checkout", "#{pr["number"]}", "--force"], timeout: 120_000),
         do: {:ok, nil}
  end

  defp checkout(cwd, %{kind: "gitlab"}, pr) do
    with {:ok, _, _} <-
           SourceControl.Cli.run("glab", ["mr", "checkout", "#{pr["number"]}"],
             cd: cwd,
             timeout: 120_000
           ),
         do: {:ok, nil}
  end

  # Bitbucket publishes no pull request ref: the head branch comes from the repository
  # it lives in.
  defp checkout(cwd, %{kind: "bitbucket"} = host, pr) do
    head = pr["headRefName"]

    with {:ok, remote} <- head_remote(cwd, host, pr) || {:ok, host.remote},
         {:ok, _} <- Git.ok(cwd, ["fetch", "--quiet", "--no-tags", remote, head]),
         {:ok, _} <- Git.ok(cwd, ["checkout", "--quiet", "-B", head, "FETCH_HEAD"]),
         do: {:ok, head}
  end

  # As fj's checkout (`checkoutChangeRequest`): the server's `refs/pull/<n>/head`,
  # fetched from the repository's SSH address when the checkout is reached over SSH,
  # into `pulls/<n>`, then brought to the head keeping uncommitted files.
  defp checkout(cwd, %{kind: "forgejo"} = host, pr) do
    branch = "pulls/#{pr["number"]}"

    with {:ok, urls} <- lookup(cwd, "forgejo", host.repository),
         url = if(ssh?(host.url), do: urls["sshUrl"], else: urls["url"]),
         {:ok, _} <-
           Git.ok(cwd, ["fetch", "--quiet", "--", url, "refs/pull/#{pr["number"]}/head"]),
         {:ok, _} <-
           if(rev(cwd, "refs/heads/#{branch}"),
             do: Git.ok(cwd, ["checkout", "--quiet", branch]),
             else: Git.ok(cwd, ["checkout", "--quiet", "-b", branch, "FETCH_HEAD"])
           ),
         {:ok, _} <- Git.ok(cwd, ["reset", "--quiet", "--keep", pr["headSha"] || "FETCH_HEAD"]),
         do: {:ok, branch}
  end

  # `HalC2.SourceControl.lookup/1`'s clone addresses, its failure as `{reason, detail}`.
  defp lookup(cwd, provider, repository) do
    case SourceControl.lookup(%{"provider" => provider, "repository" => repository, "cwd" => cwd}) do
      {:ok, urls} -> {:ok, urls}
      {:error, failure} -> {:error, {:failed, detail(failure)}}
    end
  end

  # --- worktree ------------------------------------------------------------------------

  # `hal-c2/pr-<n>/<branch>`, or `hal-c2-pr-<n>/<branch>` in a repository with a branch
  # named `hal-c2`, which git cannot put a branch under.
  defp fork_branch(cwd, number, fragment) do
    branch = "hal-c2/pr-#{number}/#{fragment}"
    if Git.branch_path_taken?(cwd, branch), do: "hal-c2-pr-#{number}/#{fragment}", else: branch
  end

  defp worktree(cwd, host, pr) do
    head = pr["headRefName"]

    branch =
      if pr["isCrossRepository"],
        do: fork_branch(cwd, pr["number"], fragment(head)),
        else: head

    with {:ok, root} <- Git.ok(cwd, ~w(rev-parse --show-toplevel)),
         root = String.trim(root),
         worktrees = worktrees(cwd) do
      # As `findLocalHeadBranch`: the branch itself, or for a fork's pull request a
      # branch elsewhere that only shares the head's bare name.
      existing =
        cond do
          worktrees[branch] -> {worktrees[branch], branch}
          branch != head and worktrees[head] not in [nil, root] -> {worktrees[head], head}
          true -> nil
        end

      case existing do
        {^root, _} ->
          error("preparePullRequestThread", cwd, @in_root)

        {path, ^branch} ->
          {:ok, prepared(pr, branch, path, reuse(path, host, pr, branch))}

        # Somebody else's work: handed back untouched.
        {path, _other} ->
          {:ok, prepared(pr, branch, path, false)}

        nil ->
          with :ok <- materialize(cwd, host, pr, branch),
               {:ok, %{"worktree" => %{"path" => path}}} <-
                 HalC2.Vcs.create_worktree(%{"cwd" => cwd, "refName" => branch}),
               do: {:ok, prepared(pr, branch, path, true)}
      end
    else
      {:error, {_status, detail}} -> error("preparePullRequestThread", cwd, detail)
      {:error, _} = error -> error
    end
  end

  defp prepared(pr, branch, path, on_head?),
    do: %{
      "pullRequest" => resolved(pr),
      "branch" => branch,
      "worktreePath" => path,
      "isOnPullRequestHead" => on_head?
    }

  # The head branch from the repository it lives in, following it, else the host's
  # pull request ref; a pull request whose head repository is unknown goes straight to
  # the ref. As `materializePullRequestHeadBranch`.
  defp materialize(cwd, host, pr, branch) do
    head = pr["headRefName"]

    primary =
      case head_remote(cwd, host, pr) do
        nil ->
          nil

        {:ok, remote} ->
          with {:ok, _} <- fetch_branch(cwd, remote, head),
               {:ok, _} <- Git.ok(cwd, ["branch", "--force", branch, "#{remote}/#{head}"]),
               {:ok, _} <- Git.ok(cwd, ["branch", "--set-upstream-to=#{remote}/#{head}", branch]),
               do: :ok

        failure ->
          failure
      end

    case primary do
      :ok ->
        :ok

      nil ->
        with {:error, cause} <- fetch_pr_branch(cwd, host, pr, branch),
             do: error("preparePullRequestThread", cwd, detail(cause))

      {:error, primary} ->
        with {:error, fallback} <- fetch_pr_branch(cwd, host, pr, branch) do
          error(
            "preparePullRequestThread",
            cwd,
            "Repository-head and pull-request-ref fetches both failed for pull request ##{pr["number"]}: " <>
              "#{detail(primary)}; #{detail(fallback)}"
          )
        end
    end
  end

  defp fetch_pr_branch(cwd, host, pr, branch) do
    case pr_ref(host, pr) do
      nil ->
        {:error, {:failed, "#{host.kind} has no pull request ref to fetch."}}

      ref ->
        with {:ok, _} <-
               Git.ok(cwd, [
                 "fetch",
                 "--quiet",
                 "--no-tags",
                 host.remote,
                 "+#{ref}:refs/heads/#{branch}"
               ]),
             do: :ok
    end
  end

  defp pr_ref(%{kind: "gitlab"}, pr), do: "refs/merge-requests/#{pr["number"]}/head"
  defp pr_ref(%{kind: "bitbucket"}, _pr), do: nil
  defp pr_ref(_host, pr), do: "refs/pull/#{pr["number"]}/head"

  defp fetch_branch(cwd, remote, head),
    do:
      Git.ok(cwd, [
        "fetch",
        "--quiet",
        "--no-tags",
        remote,
        "+refs/heads/#{head}:refs/remotes/#{remote}/#{head}"
      ])

  # Best effort: the branch follows the pull request's own branch, so a push lands on
  # the pull request. As `configurePullRequestHeadUpstream`.
  defp configure_upstream(cwd, host, pr, branch) do
    head = pr["headRefName"]

    with {:ok, remote} <- head_remote(cwd, host, pr),
         {:ok, _} <- fetch_branch(cwd, remote, head),
         do: Git.ok(cwd, ["branch", "--set-upstream-to=#{remote}/#{head}", branch])
  end

  # The remote the head branch lives on: the primary one for a pull request from the
  # same repository, a fork's own (added when missing), or nil when the host does not
  # say which repository a fork's pull request comes from.
  defp head_remote(cwd, host, pr) do
    repository = pr["headRepository"]

    cond do
      not pr["isCrossRepository"] ->
        {:ok, host.remote}

      not is_binary(repository) ->
        nil

      host.repository && String.downcase(repository) == String.downcase(host.repository) ->
        {:ok, host.remote}

      true ->
        with {:ok, urls} <- lookup(cwd, host.kind, repository) do
          url = if ssh?(host.url), do: urls["sshUrl"], else: urls["url"]
          owner = pr["headOwner"] || repository |> String.split("/") |> hd()
          ensure_remote(cwd, owner, url)
        end
    end
  end

  defp ssh?(nil), do: false

  defp ssh?(url),
    do: String.match?(url, ~r/^ssh:\/\//i) or String.match?(url, ~r/^[^\/:@]+@[^\/:]+:/)

  # A remote already at `url` (by `HalC2.AgentSessions.remote_key/1`), else a new one
  # named after `owner`, numbered when that name is taken. As `ensureRemote`.
  defp ensure_remote(cwd, owner, url) do
    remotes =
      case Git.ok(cwd, ["config", "--get-regexp", ~S"^remote\..*\.url$"]) do
        {:ok, out} ->
          for line <- String.split(out, "\n", trim: true),
              [_, name, value] <- [Regex.run(~r/^remote\.(.+)\.url (.*)$/, line)],
              do: {name, value}

        _ ->
          []
      end

    key = AgentSessions.remote_key(url)

    case Enum.find(remotes, fn {_, value} -> AgentSessions.remote_key(value) == key end) do
      {name, _} ->
        {:ok, name}

      nil ->
        names = MapSet.new(remotes, &elem(&1, 0))
        preferred = remote_name(owner)

        name =
          Stream.iterate(0, &(&1 + 1))
          |> Stream.map(&if(&1 == 0, do: preferred, else: "#{preferred}-#{&1}"))
          |> Enum.find(&(not MapSet.member?(names, &1)))

        with {:ok, _} <- Git.ok(cwd, ["remote", "add", name, url]), do: {:ok, name}
    end
  end

  defp remote_name(owner) do
    name = owner |> String.replace(~r/[^A-Za-z0-9._-]+/, "-") |> String.trim("-")
    if name == "", do: "fork", else: name
  end

  # A reused worktree: its branch follows the pull request's, then moves onto the head
  # the host's pull request ref names (else the head branch it follows) when that loses
  # nothing. Whether it is on the head afterwards.
  defp reuse(path, host, pr, branch) do
    # Read before the upstream is fetched: once it has jumped to a rewritten head there
    # is no telling a checkout that holds nothing of its own from one with commits.
    before = rev(path, "@{upstream}")
    configure_upstream(path, host, pr, branch)

    target =
      with ref when is_binary(ref) <- pr_ref(host, pr),
           {:ok, _} <- Git.ok(path, ["fetch", "--quiet", "--no-tags", host.remote, ref]) do
        rev(path, "FETCH_HEAD")
      else
        _ ->
          case Git.ok(path, ~w(rev-parse --abbrev-ref --symbolic-full-name @{upstream})) do
            {:ok, upstream} ->
              upstream = String.trim(upstream)
              if String.ends_with?(upstream, "/" <> pr["headRefName"]), do: rev(path, upstream)

            _ ->
              nil
          end
      end

    target != nil and refresh(path, target, before)
  end

  # As `refreshCheckedOutBranch`: forward when the head descends from the checkout; a
  # rewritten head only when the tree is clean and HEAD never left the commit its
  # upstream held, keeping that commit at `refs/hal-c2/pre-refresh/<branch>` (refs are
  # shared by every worktree, so each branch keeps its own).
  defp refresh(path, target, reset_when) do
    head = rev(path, "HEAD")

    cond do
      head == target ->
        true

      match?({:ok, out} when out != "", Git.ok(path, ~w(status --porcelain))) ->
        false

      match?({:ok, _}, Git.ok(path, ["merge-base", "--is-ancestor", head, target])) ->
        match?({:ok, _}, Git.ok(path, ["merge", "--ff-only", "--quiet", target]))

      head == reset_when ->
        with {:ok, branch} <- Git.ok(path, ~w(symbolic-ref --short HEAD)),
             ref = "refs/hal-c2/pre-refresh/" <> String.trim(branch),
             {:ok, _} <- Git.ok(path, ["update-ref", ref, head]),
             {:ok, _} <- Git.ok(path, ["reset", "--quiet", "--merge", target]),
             do: true,
             else: (_ -> false)

      true ->
        false
    end
  end

  defp rev(path, revision) do
    case Git.ok(path, ["rev-parse", "--verify", "--quiet", "#{revision}^{commit}"]) do
      {:ok, sha} -> String.trim(sha)
      _ -> nil
    end
  end

  defp worktrees(cwd) do
    case Git.ok(cwd, ~w(worktree list --porcelain)) do
      {:ok, out} ->
        for entry <- String.split(out, "\n\n", trim: true),
            lines = String.split(entry, "\n"),
            "worktree " <> path <- Enum.take(lines, 1),
            "branch refs/heads/" <> branch <-
              Enum.filter(lines, &String.starts_with?(&1, "branch ")),
            into: %{},
            do: {branch, path}

      _ ->
        %{}
    end
  end

  # As `sanitizeBranchFragment` in packages/shared/src/git.ts.
  defp fragment(raw) do
    fragment =
      raw
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/['"`]/, "")
      |> String.replace(~r/^[.\/\s_-]+|[.\/\s_-]+$/, "")
      |> String.replace(~r/[^a-z0-9\/_-]+/, "-")
      |> String.replace(~r/\/+/, "/")
      |> String.replace(~r/-+/, "-")
      |> String.replace(~r/^[.\/_-]+|[.\/_-]+$/, "")
      |> String.slice(0, 64)
      |> String.replace(~r/[.\/_-]+$/, "")

    if fragment == "", do: "update", else: fragment
  end

  defp detail({_status, detail}), do: to_string(detail)
  defp detail(%{} = failure), do: failure["detail"] || failure["message"] || inspect(failure)
  defp detail(detail), do: to_string(detail)

  defp error(operation, cwd, detail),
    do:
      {:error,
       %{
         "_tag" => "GitManagerError",
         "operation" => operation,
         "cwd" => cwd,
         "detail" => to_string(detail),
         "message" => "Git manager failed in #{operation}: #{detail}"
       }}
end
