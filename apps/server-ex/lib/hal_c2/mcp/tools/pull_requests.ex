defmodule HalC2.Mcp.Tools.PullRequests do
  @moduledoc """
  MCP tools that link the pull requests an agent opens to its own thread, so HAL-C2
  tracks them beside it (`HalC2.Mcp.Tools`). A pull request is named by its URL, or
  by repository and number on the project's host.
  """

  import HalC2.Mcp.Tools, only: [command_id: 0, orchestration: 1, project_row: 1, thread: 1]

  alias HalC2.Orchestration
  alias HalC2.Projection.PullRequests

  @tools ~w(link_pull_request unlink_pull_request list_thread_pull_requests)

  def tools, do: @tools

  def run("link_pull_request", args, %{row: me}) do
    with {:ok, target} <- target(args, me) do
      existing = Enum.find(links(me["id"]), &same?(&1, target))

      if existing && existing["source"] != "stack-dismissed" do
        {:ok, Map.put(target, "alreadyLinked", true)}
      else
        with {:ok, _} <-
               orchestration(
                 Orchestration.dispatch(
                   Map.merge(target, %{
                     "type" => "thread.pull-request.link",
                     "commandId" => command_id(),
                     "threadId" => me["id"],
                     "source" => "agent"
                   })
                 )
               ),
             do: {:ok, Map.put(target, "alreadyLinked", false)}
      end
    end
  end

  def run("unlink_pull_request", args, %{row: me}) do
    with {:ok, target} <- target(args, me) do
      key = Map.take(target, ~w(host repository number))

      if Enum.any?(links(me["id"]), &same?(&1, target)) do
        with {:ok, _} <-
               orchestration(
                 Orchestration.dispatch(
                   Map.merge(key, %{
                     "type" => "thread.pull-request.unlink",
                     "commandId" => command_id(),
                     "threadId" => me["id"]
                   })
                 )
               ),
             do: {:ok, Map.put(key, "wasLinked", true)}
      else
        {:ok, Map.put(key, "wasLinked", false)}
      end
    end
  end

  def run("list_thread_pull_requests", _args, %{row: me}) do
    visible = Enum.reject(links(me["id"]), &(&1["source"] == "stack-dismissed"))
    chains = chains(visible)

    {:ok,
     %{
       "pullRequests" => Enum.map(visible, &entry(&1, chains)),
       "chains" =>
         for(
           {kind, layers} <- chains,
           do: %{"kind" => kind, "numbers" => Enum.map(layers, & &1["number"])}
         )
     }}
  end

  # --- helpers ----------------------------------------------------------------------------

  defp links(thread_id), do: PullRequests.of(thread(thread_id) || %{})

  # Links are compared by their normalized identity (`HalC2.Projection.
  # PullRequests.normalize/1`): lowercased host and repository, with a Forgejo
  # port recovered from the link's URL when the stored host has none.
  defp same?(link, target), do: key(link) == key(target)

  defp key(link), do: PullRequests.key(link)

  defp repository_key(link) do
    %{"host" => host, "repository" => repository} = PullRequests.normalize(link)
    "#{host}/#{repository}"
  end

  # Whichever shape the agent passed, as one host-level identity. A URL wins;
  # otherwise the repository is taken to be on the project's host.
  defp target(%{"url" => url}, _me) when is_binary(url) do
    case PullRequests.parse_change_request_url(url) do
      nil ->
        {:error, "invalid_request",
         "This is not a recognised pull request URL. Pass repository and number instead."}

      parsed ->
        {:ok,
         PullRequests.normalize(%{
           "host" => parsed.host,
           "authority" => parsed[:authority],
           "repository" => parsed.repository,
           "number" => parsed.number,
           "url" => url
         })
         |> Map.put("url", url)}
    end
  end

  defp target(%{"repository" => repository, "number" => number} = args, me)
       when is_binary(repository) and is_integer(number) do
    project = project_host(me["projectId"])

    case args["host"] || (project && project.host) do
      nil ->
        {:error, "invalid_request",
         "This thread's project has no recognised remote. Pass host or url."}

      host ->
        host = String.downcase(host)
        repository = String.downcase(repository)
        # The project's kind only describes its own host; another host gets
        # no URL guess and falls back to the `/pull/` shape.
        own = project && host == project.host
        url = url(own && project.kind, host, repository, number, own && project.remote_url)

        {:ok,
         PullRequests.normalize(%{
           "host" => host,
           "repository" => repository,
           "number" => number,
           "url" => url
         })
         |> Map.put("url", url)}
    end
  end

  defp target(_args, _me),
    do: {:error, "invalid_request", "Pass either url, or both repository and number."}

  # The project's host, its provider kind and its remote's URL, as the Node
  # server read them from the project's `repositoryIdentity` (a Forgejo
  # project's host keeps its web port). An identity without a provider (one
  # this MC recorded itself, a remote added after the project) falls back to
  # reading the checkout's origin.
  defp project_host(project_id) do
    case project_row(project_id) do
      %{"repositoryIdentity" => %{"provider" => kind} = identity} when is_binary(kind) ->
        remote_url = get_in(identity, ["locator", "remoteUrl"])

        %{
          host: identity_host(identity, kind, remote_url),
          kind: kind,
          remote_url: remote_url
        }

      %{"workspaceRoot" => root} ->
        with {:ok, url} <- HalC2.Git.ok(root, ~w(remote get-url origin)),
             %{host: host, kind: kind} <- HalC2.PullRequests.parse_remote(url) do
          %{host: host, kind: kind, remote_url: String.trim(url)}
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # `pullRequestHostOf` in the contracts: a Forgejo host is its remote's web
  # authority (port included); every other host is the canonical key's first
  # segment, or the kind itself when there is no key to read.
  defp identity_host(identity, "forgejo", remote_url) do
    case remote_url && URI.new(remote_url) do
      {:ok, %URI{scheme: scheme} = uri} when scheme in ["http", "https"] ->
        authority(uri)

      _ ->
        identity_host(identity, "unknown", remote_url)
    end
  end

  defp identity_host(identity, kind, _remote_url) do
    case identity["canonicalKey"] |> to_string() |> String.split("/", parts: 2) do
      [host | _] when host != "" -> String.downcase(String.trim(host))
      _ -> kind
    end
  end

  # The web URL a host writes for a change request (`changeRequestUrlFor` in
  # the shared package); a kind this does not know gets the `/pull/` shape.
  defp url("gitlab", host, repository, number, _remote_url),
    do: "https://#{host}/#{repository}/-/merge_requests/#{number}"

  defp url("forgejo", host, repository, number, remote_url),
    do: "#{forgejo_origin(host, remote_url)}/#{repository}/pulls/#{number}"

  defp url("bitbucket", host, repository, number, _remote_url),
    do: "https://#{host}/#{repository}/pull-requests/#{number}"

  defp url("azure-devops", host, repository, number, _remote_url),
    do: "https://#{host}/#{repository}/pullrequest/#{number}"

  defp url(_kind, host, repository, number, _remote_url),
    do: "https://#{host}/#{repository}/pull/#{number}"

  # A Forgejo server's web origin is its remote's, when the remote is on the
  # host being linked: the scheme and port the clone URL carries are the
  # server's own. SSH remotes name no web origin, so https on the host.
  defp forgejo_origin(host, remote_url) do
    case remote_url && URI.new(remote_url) do
      {:ok, %URI{scheme: scheme, host: remote_host} = uri}
      when scheme in ["http", "https"] and is_binary(remote_host) ->
        if String.downcase(remote_host) == host or authority(uri) == host,
          do: "#{scheme}://#{authority(uri)}",
          else: "https://#{host}"

      _ ->
        "https://#{host}"
    end
  end

  # URL#host: the port only when it is not the scheme's default.
  defp authority(%URI{host: host, port: port, scheme: scheme}) do
    host = String.downcase(host)
    if port == nil or port == URI.default_port(scheme), do: host, else: "#{host}:#{port}"
  end

  defp entry(link, chains) do
    snapshot = link["snapshot"] || %{}

    stack =
      Enum.find_value(chains, fn {kind, layers} ->
        index = Enum.find_index(layers, &(key(&1) == key(link)))

        if length(layers) > 1 and index,
          do: %{"kind" => kind, "position" => index + 1, "size" => length(layers)}
      end)

    %{
      "host" => PullRequests.normalize(link)["host"],
      "repository" => link["repository"],
      "number" => link["number"],
      "url" => link["url"],
      "source" => link["source"],
      "state" => snapshot["state"],
      "title" => snapshot["title"],
      "headBranch" => snapshot["headBranch"],
      "baseBranch" => snapshot["baseBranch"],
      "isDraft" => snapshot["isDraft"],
      "stack" => stack
    }
  end

  # How linked pull requests stack, bottom to top (`resolveThreadPullRequestChains` in
  # the shared package): host-native stacks first, then chains derived from each pull
  # request's base branch being another's head branch.
  defp chains(links) do
    native =
      links
      |> Enum.filter(& &1["stack"])
      |> Enum.group_by(&"#{repository_key(&1)}#stack:#{&1["stack"]["id"]}")
      |> Map.values()
      |> Enum.map(fn [first | _] = members ->
        order =
          (first["stack"]["layers"] || [])
          |> Enum.with_index()
          |> Map.new(fn {layer, index} -> {layer["number"], index} end)

        {"native", Enum.sort_by(members, &Map.get(order, &1["number"], 0))}
      end)

    placed = MapSet.new(for {_, layers} <- native, layer <- layers, do: key(layer))
    remaining = Enum.reject(links, &MapSet.member?(placed, key(&1)))
    branch = fn link, name -> "#{repository_key(link)}:#{name}" end

    # A head branch used twice cannot name a parent.
    by_head =
      Enum.reduce(remaining, %{}, fn link, acc ->
        case link["snapshot"] do
          nil ->
            acc

          snapshot ->
            Map.update(acc, branch.(link, snapshot["headBranch"]), link, fn _ -> :ambiguous end)
        end
      end)

    parent = fn link ->
      case link["snapshot"] &&
             Map.get(by_head, branch.(link, link["snapshot"]["baseBranch"])) do
        %{} = parent -> if key(parent) != key(link), do: parent
        _ -> nil
      end
    end

    has_child = MapSet.new(for link <- remaining, p = parent.(link), do: key(p))

    {derived, placed} =
      remaining
      |> Enum.reject(&MapSet.member?(has_child, key(&1)))
      |> Enum.reduce({[], placed}, fn top, {chains, placed} ->
        {layers, placed} = walk(top, parent, [], placed)
        {if(layers == [], do: chains, else: chains ++ [{"derived", layers}]), placed}
      end)

    # Cycles have no top; their links stay visible on their own.
    cycles = for link <- remaining, not MapSet.member?(placed, key(link)), do: {"derived", [link]}

    native ++ derived ++ cycles
  end

  defp walk(nil, _parent, layers, placed), do: {layers, placed}

  defp walk(link, parent, layers, placed) do
    if MapSet.member?(placed, key(link)),
      do: {layers, placed},
      else: walk(parent.(link), parent, [link | layers], MapSet.put(placed, key(link)))
  end
end
