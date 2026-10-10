defmodule HalC2.SourceControl.ChangeRequests do
  @moduledoc """
  The change request of a branch on the hosts other than GitHub, for a checkout's
  status (`HalC2.Vcs`): a GitLab merge request through `glab`, an Azure DevOps pull
  request through `az`, a Forgejo or Gitea one through fj or tea
  (`HalC2.SourceControl.Forgejo`), and
  a Bitbucket one through its REST API.

  A host that cannot be asked (no CLI, not signed in, offline) has no change request,
  quietly, as an unreachable GitHub has none.
  """

  alias HalC2.SourceControl
  alias HalC2.SourceControl.{Cli, Forgejo}

  @timeout 10_000
  @bitbucket_states ~w(OPEN MERGED DECLINED SUPERSEDED)

  @doc """
  The newest change request whose source is `branch`, in any state, on the host of
  `remote` (`HalC2.PullRequests.parse_remote/1`, with the remote's `:url`), as a
  `VcsStatusChangeRequest`; nil when there is none or the host is not one of these.
  """
  def for_branch(cwd, %{kind: "gitlab"}, branch) do
    args = ["mr", "list", "--source-branch", branch, "--all", "--per-page", "1"]

    with [%{"iid" => number} = mr | _] <- cli_json("glab", args ++ ~w(--output json), cwd) do
      change_request(number, mr["title"], mr["web_url"], mr["target_branch"], mr["source_branch"],
        state: gitlab_state(mr["state"]),
        draft: mr["draft"] == true or mr["work_in_progress"] == true,
        updated_at: mr["updated_at"]
      )
    else
      _ -> nil
    end
  end

  def for_branch(cwd, %{kind: "azure-devops"}, branch) do
    args =
      ["repos", "pr", "list", "--detect", "true", "--source-branch", branch] ++
        ~w(--status all --top 1 --only-show-errors --output json)

    with [%{"pullRequestId" => number} = pr | _] <- cli_json("az", args, cwd) do
      change_request(
        number,
        pr["title"],
        azure_url(pr),
        branch_name(pr["targetRefName"]),
        branch_name(pr["sourceRefName"]),
        state: azure_state(pr["status"]),
        draft: pr["isDraft"] == true,
        updated_at: pr["closedDate"] || pr["creationDate"]
      )
    else
      _ -> nil
    end
  end

  def for_branch(cwd, %{kind: "forgejo", repository: repository} = remote, branch) do
    path =
      "repos/#{Forgejo.encode_repository(repository)}/pulls?state=all&sort=recentupdate&limit=50"

    # The remote's URL picks the login of its server.
    target = [repository: repository, remote_url: remote[:url]]

    with {:ok, body, _} <- Forgejo.api(cwd, target, path),
         {:ok, pulls} when is_list(pulls) <- JSON.decode(body),
         %{"number" => number} = pr <- Enum.find(pulls, &(get_in(&1, ["head", "ref"]) == branch)) do
      state =
        cond do
          pr["merged"] == true -> "merged"
          pr["state"] == "closed" -> "closed"
          true -> "open"
        end

      draft = Map.get(pr, "draft") || String.match?(pr["title"] || "", ~r/^(?:\[WIP\]|WIP:)/i)

      change_request(number, pr["title"], pr["html_url"], pr["base"]["ref"], pr["head"]["ref"],
        state: state,
        draft: draft == true,
        updated_at: pr["updated_at"]
      )
    else
      _ -> nil
    end
  end

  def for_branch(_cwd, %{kind: "bitbucket", repository: repository}, branch) do
    states = Enum.map_join(@bitbucket_states, " OR ", &~s(state = "#{&1}"))
    source = ~s(source.branch.name = "#{String.replace(branch, "\"", "\\\"")}")

    query =
      URI.encode_query(
        [{"q", "#{source} AND (#{states})"}, {"sort", "-updated_on"}, {"pagelen", "1"}] ++
          Enum.map(@bitbucket_states, &{"state", &1})
      )

    with [workspace, slug] <- repository |> String.split("/") |> Enum.take(-2),
         %{"values" => [%{"id" => number} = pr | _]} <-
           SourceControl.bitbucket_get(
             "/repositories/#{URI.encode(workspace)}/#{URI.encode(slug)}/pullrequests?#{query}"
           ) do
      change_request(
        number,
        pr["title"],
        get_in(pr, ["links", "html", "href"]),
        get_in(pr, ["destination", "branch", "name"]),
        get_in(pr, ["source", "branch", "name"]),
        state: bitbucket_state(pr["state"]),
        draft: pr["draft"] == true,
        updated_at: pr["updated_on"]
      )
    else
      _ -> nil
    end
  end

  def for_branch(_cwd, _remote, _branch), do: nil

  # A host's answer missing what a status has to name is no change request.
  defp change_request(number, title, url, base, head, opts)
       when is_integer(number) and is_binary(title) and is_binary(url) and is_binary(base) and
              is_binary(head) do
    %{
      "number" => number,
      "title" => title,
      "url" => url,
      "baseRef" => base,
      "headRef" => head,
      "state" => opts[:state],
      "isDraft" => opts[:draft],
      "updatedAt" => opts[:updated_at]
    }
  end

  defp change_request(_number, _title, _url, _base, _head, _opts), do: nil

  defp cli_json(exe, args, cwd) do
    with {:ok, out, _} <- Cli.run(exe, args, cd: cwd, timeout: @timeout),
         {:ok, list} when is_list(list) <- JSON.decode(out) do
      list
    else
      _ -> []
    end
  end

  defp gitlab_state(state) do
    case state |> to_string() |> String.trim() |> String.downcase() do
      "merged" -> "merged"
      "closed" -> "closed"
      _ -> "open"
    end
  end

  defp azure_state(status) do
    case status |> to_string() |> String.trim() |> String.downcase() do
      "completed" -> "merged"
      "abandoned" -> "closed"
      _ -> "open"
    end
  end

  defp bitbucket_state(state) do
    case state |> to_string() |> String.trim() |> String.upcase() do
      "MERGED" -> "merged"
      closed when closed in ["DECLINED", "SUPERSEDED"] -> "closed"
      _ -> "open"
    end
  end

  defp branch_name(ref) when is_binary(ref), do: String.replace_prefix(ref, "refs/heads/", "")
  defp branch_name(_ref), do: nil

  # Azure answers with a web link when asked for one, else it is hung on the
  # repository's own page.
  defp azure_url(%{"pullRequestId" => number} = pr) do
    web = get_in(pr, ["_links", "web", "href"])
    repository = get_in(pr, ["repository", "webUrl"])

    cond do
      is_binary(web) and web != "" -> web
      is_binary(repository) -> String.trim_trailing(repository, "/") <> "/pullrequest/#{number}"
      true -> nil
    end
  end
end
