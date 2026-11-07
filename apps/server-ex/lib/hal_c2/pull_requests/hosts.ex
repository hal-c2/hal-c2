defmodule HalC2.PullRequests.Hosts do
  @moduledoc """
  Listing change requests on the hosts other than GitHub (`pullRequests.list`):
  GitLab through `glab api`, Forgejo through `HalC2.SourceControl.Forgejo`,
  Azure DevOps through `az repos pr list` and Bitbucket through its REST API
  (`HalC2.SourceControl.bitbucket_get/1`).

  Each read answers items in the shape `HalC2.PullRequests.GitHub.list/2` items
  carry (`number`, `title`, `url`, `author`, `headBranch`, `baseBranch`,
  `state`, `isDraft`, `mergeability`, `additions`, `deletions`, `createdAt`,
  `updatedAt`, `reviewRequestLogins`, `labels`, and where the host summarises
  them `reviewDecision` and `checksState`), newest update first. The host is
  asked for the requested state and, where it can search text, the query;
  involvement and the row filters are the caller's to apply, so a read walks up
  to five host pages to give that filtering enough rows to fill a page.
  A row missing what a listing must name is skipped, never fatal.
  """

  alias HalC2.SourceControl
  alias HalC2.SourceControl.{Cli, Forgejo}

  @kinds ~w(gitlab forgejo azure-devops bitbucket)
  @pages 5
  @timeout 30_000

  @doc "Whether this module lists projects of host kind `kind`."
  def kind?(kind), do: kind in @kinds

  @doc """
  The account signed in for `project`'s host: `{:ok, login}`, or
  `{:error, {reason, detail}}` in `HalC2.SourceControl.Cli`'s terms, where
  `:missing` and `:unauthenticated` mean the host is not configured here.
  """
  def viewer(%{kind: "gitlab", root: root}) do
    case glab_json(root, "user") do
      {:ok, %{"username" => login}} when is_binary(login) and login != "" ->
        {:ok, login}

      {:ok, _} ->
        {:error, {:failed, "GitLab CLI returned no username for the authenticated account."}}

      error ->
        error
    end
  end

  def viewer(%{kind: "forgejo", root: root, repository: repository}) do
    case Forgejo.api(root, [repository: repository], "user") do
      {:ok, body, _} ->
        case JSON.decode(body) do
          {:ok, %{"login" => login}} when is_binary(login) and login != "" -> {:ok, login}
          _ -> {:error, {:failed, "Forgejo returned no account for the current sign-in."}}
        end

      error ->
        error
    end
  end

  def viewer(%{kind: "azure-devops", root: root}) do
    case cli_json("az", ["account", "show", "--query", "user"], root) do
      {:ok, user} ->
        name = get_in(user || %{}, ["name"]) || get_in(user || %{}, ["user", "name"])

        if is_binary(name) and String.trim(name) != "",
          do: {:ok, String.trim(name)},
          else: {:error, {:failed, "Azure CLI returned no account for the current sign-in."}}

      error ->
        error
    end
  end

  def viewer(%{kind: "bitbucket", host: host}) do
    cond do
      bitbucket_server_unreachable?(host) ->
        {:error, {:missing, "This host cannot be browsed here yet."}}

      not bitbucket_configured?() ->
        {:error,
         {:missing,
          "Set HAL_C2_BITBUCKET_EMAIL and HAL_C2_BITBUCKET_API_TOKEN, or HAL_C2_BITBUCKET_ACCESS_TOKEN."}}

      true ->
        case SourceControl.bitbucket_get("/user") do
          %{} = user ->
            account = user["username"] || user["nickname"]

            if is_binary(account) and String.trim(account) != "",
              do: {:ok, String.trim(account)},
              else:
                {:error,
                 {:failed, "Bitbucket returned no account name for the configured credentials."}}

          nil ->
            {:error, {:failed, "Bitbucket could not be read."}}
        end
    end
  end

  def viewer(_project), do: {:error, {:missing, "This host cannot be browsed here yet."}}

  @doc """
  One project's change requests in the requested state, newest update first:
  `{:ok, %{items: items, more: more?}}`, where `more?` says the host had rows
  past the pages read. `opts`: `state`, `query`.
  """
  def list(project, opts) do
    case project.kind do
      "gitlab" -> gitlab_list(project, opts)
      "forgejo" -> forgejo_list(project, opts)
      "azure-devops" -> azure_list(project, opts)
      "bitbucket" -> bitbucket_list(project, opts)
      _ -> {:error, {:missing, "This host cannot be browsed here yet."}}
    end
  end

  # --- GitLab -------------------------------------------------------------------

  @gitlab_states %{"open" => "opened", "closed" => "closed", "merged" => "merged", "all" => "all"}

  defp gitlab_list(project, opts) do
    query =
      [
        {"state", @gitlab_states[opts.state] || "opened"},
        {"order_by", "updated_at"},
        {"sort", "desc"},
        {"per_page", "100"}
      ] ++ if(blank?(opts.query), do: [], else: [{"search", String.trim(opts.query)}])

    path = fn page ->
      "projects/#{URI.encode(project.repository, &URI.char_unreserved?/1)}/merge_requests?" <>
        URI.encode_query(query ++ [{"page", Integer.to_string(page)}])
    end

    with {:ok, rows, more} <- pages(fn page -> glab_json_list(project.root, path.(page)) end) do
      {:ok, %{items: rows |> Enum.flat_map(&gitlab_item/1) |> by_update(), more: more}}
    end
  end

  defp gitlab_item(
         %{
           "iid" => number,
           "title" => title,
           "web_url" => url,
           "source_branch" => head,
           "target_branch" => base,
           "created_at" => created,
           "updated_at" => updated
         } = raw
       )
       when is_integer(number) and is_binary(title) and is_binary(url) and is_binary(head) and
              is_binary(base) and is_binary(created) and is_binary(updated) do
    [
      %{
        "number" => number,
        "title" => title,
        "url" => url,
        "author" => actor(raw["author"], "username", "avatar_url"),
        "headBranch" => head,
        "headSha" => trimmed(raw["sha"]),
        "baseBranch" => base,
        "state" => gitlab_state(raw),
        "isDraft" => raw["draft"] == true or raw["work_in_progress"] == true,
        "mergeability" => gitlab_mergeability(raw),
        "reviewDecision" => nil,
        "additions" => 0,
        "deletions" => 0,
        "createdAt" => created,
        "updatedAt" => updated,
        "reviewRequestLogins" =>
          for(user <- raw["reviewers"] || [], login = trimmed(user["username"]), do: login),
        "labels" =>
          for label <- raw["labels"] || [] do
            if is_binary(label),
              do: %{"name" => label, "color" => nil},
              else: %{"name" => trimmed(label["name"]), "color" => trimmed(label["color"])}
          end
          |> Enum.reject(&(&1["name"] == nil)),
        "checksState" => gitlab_checks(get_in(raw, ["head_pipeline", "status"]))
      }
    ]
  end

  defp gitlab_item(_raw), do: []

  defp gitlab_state(raw) do
    cond do
      trimmed(raw["merged_at"]) != nil -> "merged"
      down(raw["state"]) == "merged" -> "merged"
      down(raw["state"]) == "closed" -> "closed"
      # `locked` is an open merge request whose discussion is locked.
      true -> "open"
    end
  end

  defp gitlab_mergeability(raw) do
    cond do
      raw["has_conflicts"] == true -> "conflicting"
      down(raw["merge_status"]) == "can_be_merged" -> "mergeable"
      down(raw["merge_status"]) == "cannot_be_merged" -> "conflicting"
      true -> "unknown"
    end
  end

  defp gitlab_checks(status) do
    case down(status) do
      "success" ->
        "passing"

      s when s in ["failed", "canceled"] ->
        "failing"

      s when s in ["running", "pending", "created", "preparing", "waiting_for_resource"] ->
        "pending"

      _ ->
        nil
    end
  end

  defp glab_json(root, path), do: cli_json("glab", ["api", path], root)

  defp glab_json_list(root, path) do
    case glab_json(root, path) do
      {:ok, rows} when is_list(rows) -> {:ok, rows}
      {:ok, _} -> {:error, {:failed, "GitLab answered in an unexpected shape."}}
      error -> error
    end
  end

  # --- Forgejo ------------------------------------------------------------------

  defp forgejo_list(project, opts) do
    asked = if opts.state in ["closed", "merged"], do: "closed", else: opts.state
    target = [repository: project.repository]

    path = fn page ->
      "repos/#{Forgejo.encode_repository(project.repository)}/pulls?state=#{asked}" <>
        "&sort=recentupdate&limit=50&page=#{page}"
    end

    fetch = fn page ->
      case Forgejo.api(project.root, target, path.(page)) do
        {:ok, body, _} ->
          case JSON.decode(body) do
            {:ok, rows} when is_list(rows) -> {:ok, rows}
            _ -> {:error, {:failed, "Forgejo answered in an unexpected shape."}}
          end

        error ->
          error
      end
    end

    with {:ok, rows, more} <- pages(fetch, 50) do
      items =
        rows
        |> Enum.flat_map(&forgejo_item/1)
        |> Enum.filter(&(opts.state == "all" or &1["state"] == opts.state))
        |> by_update()

      {:ok, %{items: items, more: more}}
    end
  end

  defp forgejo_item(
         %{
           "number" => number,
           "title" => title,
           "html_url" => url,
           "created_at" => created,
           "updated_at" => updated
         } =
           raw
       )
       when is_integer(number) and is_binary(title) and is_binary(url) and is_binary(created) and
              is_binary(updated) do
    head = get_in(raw, ["head", "ref"])
    base = get_in(raw, ["base", "ref"])

    if is_binary(head) and is_binary(base) do
      state =
        cond do
          raw["merged"] == true -> "merged"
          down(raw["state"]) == "closed" -> "closed"
          true -> "open"
        end

      draft =
        if Map.has_key?(raw, "draft") and not is_nil(raw["draft"]),
          do: raw["draft"] == true,
          else: String.match?(title, ~r/^(?:\[WIP\]|WIP:)/i)

      [
        %{
          "number" => number,
          "title" => title,
          "url" => url,
          "author" => actor(raw["user"], "login", "avatar_url"),
          "headBranch" => head,
          "headSha" => trimmed(get_in(raw, ["head", "sha"])),
          "baseBranch" => base,
          "state" => state,
          "isDraft" => draft,
          "mergeability" =>
            case raw["mergeable"] do
              true -> "mergeable"
              false -> "conflicting"
              _ -> "unknown"
            end,
          "reviewDecision" => nil,
          "additions" => 0,
          "deletions" => 0,
          "createdAt" => created,
          "updatedAt" => updated,
          "reviewRequestLogins" =>
            for(
              user <- raw["requested_reviewers"] || [],
              login = trimmed(user["login"]),
              do: login
            ),
          "labels" =>
            for(
              label <- raw["labels"] || [],
              name = trimmed(label["name"]),
              do: %{"name" => name, "color" => trimmed(label["color"])}
            ),
          "checksState" => nil
        }
      ]
    else
      []
    end
  end

  defp forgejo_item(_raw), do: []

  # --- Azure DevOps ---------------------------------------------------------------

  @azure_states %{
    "open" => "active",
    "closed" => "abandoned",
    "merged" => "completed",
    "all" => "all"
  }

  defp azure_list(project, opts) do
    repository = azure_repository(project.repository)
    status = @azure_states[opts.state] || "active"

    fetch = fn page ->
      args =
        [
          "repos",
          "pr",
          "list",
          "--detect",
          "true",
          "--repository",
          repository,
          "--status",
          status,
          "--include-links"
        ] ++
          if(page > 1, do: ["--skip", Integer.to_string((page - 1) * 100)], else: []) ++
          ["--top", "100"]

      case cli_json("az", args, project.root) do
        {:ok, rows} when is_list(rows) -> {:ok, rows}
        {:ok, _} -> {:error, {:failed, "Azure CLI answered in an unexpected shape."}}
        error -> error
      end
    end

    with {:ok, rows, more} <- pages(fetch) do
      {:ok, %{items: rows |> Enum.flat_map(&azure_item/1) |> by_update(), more: more}}
    end
  end

  # The name `az --repository` takes: the last segment of the remote's path (after
  # `_git/` in an HTTPS remote), spelled as the host spells it, so a remote that
  # writes a space as `%20` is not looked up literally.
  defp azure_repository(repository) do
    repository
    |> String.split("/")
    |> List.last()
    |> URI.decode()
  end

  defp azure_item(
         %{
           "pullRequestId" => number,
           "title" => title,
           "sourceRefName" => head,
           "targetRefName" => base,
           "creationDate" => created
         } =
           raw
       )
       when is_integer(number) and is_binary(title) and is_binary(head) and is_binary(base) and
              is_binary(created) do
    url = azure_url(raw)

    if is_binary(url) and url != "" do
      [
        %{
          "number" => number,
          "title" => title,
          "url" => url,
          "author" => azure_actor(raw["createdBy"]),
          "headBranch" => branch_name(head),
          "headSha" => nil,
          "baseBranch" => branch_name(base),
          "state" =>
            case down(raw["status"]) do
              "completed" -> "merged"
              "abandoned" -> "closed"
              _ -> "open"
            end,
          "isDraft" => raw["isDraft"] == true,
          "mergeability" =>
            case down(raw["mergeStatus"]) do
              "succeeded" -> "mergeable"
              s when s in ["conflicts", "failure", "rejectedbypolicy"] -> "conflicting"
              _ -> "unknown"
            end,
          "reviewDecision" => nil,
          "additions" => 0,
          "deletions" => 0,
          "createdAt" => created,
          # Azure keeps no last-touched time: the closing time stands in.
          "updatedAt" => trimmed(raw["closedDate"]) || created,
          "reviewRequestLogins" =>
            for(
              user <- raw["reviewers"] || [],
              login = trimmed(user["uniqueName"]) || trimmed(user["displayName"]),
              do: login
            ),
          "labels" => [],
          "checksState" => nil
        }
      ]
    else
      []
    end
  end

  defp azure_item(_raw), do: []

  defp azure_actor(raw) do
    login = trimmed(raw && raw["uniqueName"]) || trimmed(raw && raw["displayName"])

    if login,
      do: %{
        "login" => login,
        "name" => trimmed(raw["displayName"]),
        "avatarUrl" => trimmed(raw["imageUrl"])
      }
  end

  # Azure answers with a web link when asked for one, else it is hung on the
  # repository's own page, else built from its REST address when that names an
  # organization on a known Azure host; any other address is kept as it came.
  defp azure_url(%{"pullRequestId" => number} = pr) do
    web = trimmed(get_in(pr, ["_links", "web", "href"]))
    repository = trimmed(get_in(pr, ["repository", "webUrl"]))

    cond do
      web -> web
      repository -> String.trim_trailing(repository, "/") <> "/pullrequest/#{number}"
      true -> azure_url_from_api(pr) || trimmed(pr["url"])
    end
  end

  defp azure_url_from_api(%{"pullRequestId" => number} = pr) do
    project = trimmed(get_in(pr, ["repository", "project", "name"]))
    repository = trimmed(get_in(pr, ["repository", "name"]))
    url = trimmed(pr["url"])

    with true <- project != nil and repository != nil and url != nil,
         %URI{} = uri <- URI.parse(url),
         segments when is_list(segments) <- String.split(uri.path || "", "/", trim: true),
         true <- Enum.any?(segments, &(String.downcase(&1) == "_apis")),
         base when is_binary(base) <- azure_org_base(uri, segments) do
      "#{base}/#{URI.encode_www_form(project)}/_git/#{URI.encode_www_form(repository)}/pullrequest/#{number}"
      |> String.replace("+", "%20")
    else
      _ -> nil
    end
  end

  defp azure_org_base(%URI{host: "dev.azure.com"} = uri, [org | _]),
    do: "#{uri.scheme}://#{uri.host}/#{org}"

  defp azure_org_base(%URI{host: host} = uri, _segments)
       when is_binary(host) do
    if String.ends_with?(host, ".visualstudio.com"), do: "#{uri.scheme}://#{host}"
  end

  defp azure_org_base(_uri, _segments), do: nil

  # --- Bitbucket ------------------------------------------------------------------

  @bitbucket_states %{
    "open" => ["OPEN"],
    "closed" => ["DECLINED", "SUPERSEDED"],
    "merged" => ["MERGED"],
    "all" => ["OPEN", "MERGED", "DECLINED", "SUPERSEDED"]
  }

  defp bitbucket_list(project, opts) do
    cond do
      bitbucket_server_unreachable?(project.host) ->
        {:error, {:missing, "This host cannot be browsed here yet."}}

      not bitbucket_configured?() ->
        {:error, {:missing, "Bitbucket credentials are not configured."}}

      true ->
        case String.split(project.repository, "/") do
          [workspace, slug] ->
            states = @bitbucket_states[opts.state] || ["OPEN"]

            results =
              Enum.map(states, fn state ->
                pages(fn page -> bitbucket_page(workspace, slug, state, opts.query, page) end, 50)
              end)

            case Enum.find(results, &match?({:error, _}, &1)) do
              {:error, _} = error ->
                error

              nil ->
                items =
                  results
                  |> Enum.flat_map(fn {:ok, rows, _more} -> rows end)
                  |> Enum.flat_map(&bitbucket_item/1)
                  |> by_update()

                {:ok,
                 %{items: items, more: Enum.any?(results, fn {:ok, _rows, more} -> more end)}}
            end

          _ ->
            {:error, {:failed, "A Bitbucket repository is addressed as workspace/repository."}}
        end
    end
  end

  defp bitbucket_page(workspace, slug, state, query, page) do
    params =
      [
        {"state", state},
        {"sort", "-updated_on"},
        {"pagelen", "50"},
        {"page", Integer.to_string(page)}
      ] ++
        if blank?(query) do
          []
        else
          escaped =
            query |> String.trim() |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")

          [{"q", ~s(title ~ "#{escaped}")}]
        end

    path =
      "/repositories/#{URI.encode(workspace)}/#{URI.encode(slug)}/pullrequests?" <>
        URI.encode_query(params)

    case SourceControl.bitbucket_get(path) do
      %{"values" => rows} when is_list(rows) -> {:ok, rows}
      _ -> {:error, {:failed, "Bitbucket could not be read."}}
    end
  end

  defp bitbucket_item(
         %{"id" => number, "title" => title, "created_on" => created, "updated_on" => updated} =
           raw
       )
       when is_integer(number) and is_binary(title) and is_binary(created) and is_binary(updated) do
    url = trimmed(get_in(raw, ["links", "html", "href"]))
    head = trimmed(get_in(raw, ["source", "branch", "name"]))
    base = trimmed(get_in(raw, ["destination", "branch", "name"]))

    if url && head && base do
      [
        %{
          "number" => number,
          "title" => title,
          "url" => url,
          "author" =>
            actor(raw["author"], "username", nil) || actor(raw["author"], "nickname", nil),
          "headBranch" => head,
          "headSha" => trimmed(get_in(raw, ["source", "commit", "hash"])),
          "baseBranch" => base,
          "state" =>
            case raw["state"] |> to_string() |> String.upcase() do
              "MERGED" -> "merged"
              s when s in ["DECLINED", "SUPERSEDED"] -> "closed"
              _ -> "open"
            end,
          "isDraft" => raw["draft"] == true,
          "mergeability" => "unknown",
          "reviewDecision" => bitbucket_review_decision(raw),
          "additions" => 0,
          "deletions" => 0,
          "createdAt" => iso_utc(created),
          "updatedAt" => iso_utc(updated),
          "reviewRequestLogins" =>
            for(
              user <- raw["reviewers"] || [],
              login = trimmed(user["username"]) || trimmed(user["nickname"]),
              do: login
            ),
          "labels" => [],
          "checksState" => nil
        }
      ]
    else
      []
    end
  end

  defp bitbucket_item(_raw), do: []

  # Bitbucket keeps approvals on its participants; reviewers who have not
  # voted yet are a review still required.
  defp bitbucket_review_decision(raw) do
    participants = raw["participants"] || []

    cond do
      Enum.any?(participants, &(down(&1["state"]) == "changes_requested")) ->
        "changes-requested"

      Enum.any?(participants, &(&1["approved"] == true or down(&1["state"]) == "approved")) ->
        "approved"

      (raw["reviewers"] || []) != [] ->
        "review-required"

      true ->
        nil
    end
  end

  # Bitbucket stamps times with an offset; the listing sorts every host's rows
  # against each other as text, so they are written the way the others are.
  defp iso_utc(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> DateTime.to_iso8601(at)
      _ -> text
    end
  end

  # A Bitbucket Server remote is never read through Bitbucket Cloud: only
  # bitbucket.org itself, or a configured API address, is ever asked.
  defp bitbucket_server_unreachable?(host),
    do: host != "bitbucket.org" and blank?(System.get_env("HAL_C2_BITBUCKET_API_BASE_URL"))

  defp bitbucket_configured? do
    not blank?(System.get_env("HAL_C2_BITBUCKET_ACCESS_TOKEN")) or
      (not blank?(System.get_env("HAL_C2_BITBUCKET_EMAIL")) and
         not blank?(System.get_env("HAL_C2_BITBUCKET_API_TOKEN")))
  end

  # --- shared ---------------------------------------------------------------------

  # Up to five pages of a host's rows, a page being `size` rows when full:
  # `{:ok, rows, more?}`.
  defp pages(fetch, size \\ 100), do: pages(fetch, size, 1, [])

  defp pages(fetch, size, page, acc) do
    case fetch.(page) do
      {:ok, rows} ->
        acc = acc ++ rows

        cond do
          length(rows) < size -> {:ok, acc, false}
          page >= @pages -> {:ok, acc, true}
          true -> pages(fetch, size, page + 1, acc)
        end

      error ->
        error
    end
  end

  defp cli_json(exe, args, root) do
    args = if exe == "az", do: args ++ ["--only-show-errors", "--output", "json"], else: args

    case Cli.run(exe, args, cd: root, timeout: @timeout) do
      {:ok, out, _} ->
        case out |> String.trim() |> JSON.decode() do
          {:ok, decoded} -> {:ok, decoded}
          _ -> {:ok, nil}
        end

      error ->
        error
    end
  end

  defp actor(raw, login_key, avatar_key) do
    login = trimmed(raw && raw[login_key])

    if login do
      %{
        "login" => login,
        "name" => trimmed(raw["name"]) || trimmed(raw["display_name"]),
        "avatarUrl" => if(avatar_key, do: trimmed(raw[avatar_key]))
      }
    end
  end

  defp by_update(items), do: Enum.sort_by(items, & &1["updatedAt"], :desc)

  defp branch_name(ref), do: String.replace_prefix(ref, "refs/heads/", "")

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp trimmed(_value), do: nil

  defp down(value), do: value |> to_string() |> String.trim() |> String.downcase()
end
