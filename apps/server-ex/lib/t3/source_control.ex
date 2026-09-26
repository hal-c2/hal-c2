defmodule T3.SourceControl do
  @moduledoc """
  Source control hosts through their own CLIs: which are installed and signed in
  (`server.discoverSourceControl`), and repository lookup, clone, and publish
  (`sourceControl.*`) for GitHub (`gh`) and GitLab (`glab`). Forgejo / Gitea
  (`tea`), Azure DevOps (`az`) and Bitbucket (its REST API) are discovered and
  looked up only.

  `Option` fields travel in their JSON encoding: `%{"_tag" => "Some", "value" => v}`
  or `%{"_tag" => "None"}`.
  """

  @timeout 10_000

  @vcs [
    {"git", "Git", "git", true,
     "Install Git from https://git-scm.com/downloads or with your package manager."},
    {"jj", "Jujutsu", "jj", false,
     "Install Jujutsu with `brew install jj` or from https://github.com/jj-vcs/jj."}
  ]

  @providers [
    {"github", "GitHub", "gh", ~w(auth status --json hosts),
     "Install the GitHub command-line tool (`gh`) via https://cli.github.com/ or your package manager (for example `brew install gh`)."},
    {"gitlab", "GitLab", "glab", ~w(auth status),
     "Install the GitLab command-line tool (`glab`) from https://gitlab.com/gitlab-org/cli or your package manager (for example `brew install glab`)."},
    {"forgejo", "Forgejo / Gitea", "tea", ~w(login list --output json),
     "Install the Gitea/Forgejo command-line tool (`tea`) from https://gitea.com/gitea/tea."},
    {"azure-devops", "Azure DevOps", "az", ~w(account show --query user.name -o tsv),
     "Install the Azure command-line tools (`az`), then enable Azure DevOps support with `az extension add --name azure-devops`."}
  ]

  @doc "`server.discoverSourceControl`."
  def discover(_input \\ %{}) do
    vcs =
      Task.async_stream(@vcs, fn {kind, label, exe, implemented, hint} ->
        tool(label, exe, hint) |> Map.merge(%{"kind" => kind, "implemented" => implemented})
      end)

    providers =
      Task.async_stream(@providers, fn {kind, label, exe, auth_args, hint} ->
        item = tool(label, exe, hint)

        auth =
          if item["status"] == "available",
            do: auth(kind, cmd(exe, auth_args)),
            else: auth_json("unknown", nil, nil, nil)

        Map.merge(item, %{"kind" => kind, "auth" => auth})
      end)

    {:ok,
     %{
       "versionControlSystems" => for({:ok, item} <- vcs, do: item),
       "sourceControlProviders" => for({:ok, item} <- providers, do: item) ++ [bitbucket()]
     }}
  end

  @bitbucket_hint "Set T3CODE_BITBUCKET_EMAIL and T3CODE_BITBUCKET_API_TOKEN on the server (use a Bitbucket API token with pull request, repository, and user read scopes)."

  # Bitbucket has no CLI: it is always offered, signed in through the server's
  # environment (an access token, or an email with an API token), which `/user` checks.
  defp bitbucket do
    %{token: token, email: email, authorization: authorization} = bitbucket_config()

    auth =
      case authorization && bitbucket_get("/user") do
        %{} = user ->
          account = user["username"] || user["display_name"] || user["account_id"]
          auth_json("authenticated", account, "bitbucket.org", nil)

        _ when is_binary(token) ->
          auth_json("unknown", nil, "bitbucket.org", "Bitbucket access token is configured.")

        _ when is_binary(authorization) ->
          auth_json("unknown", email, "bitbucket.org", "Bitbucket API token is configured.")

        _ ->
          auth_json(
            "unauthenticated",
            nil,
            "bitbucket.org",
            "Set T3CODE_BITBUCKET_EMAIL and T3CODE_BITBUCKET_API_TOKEN, or T3CODE_BITBUCKET_ACCESS_TOKEN."
          )
      end

    %{
      "kind" => "bitbucket",
      "label" => "Bitbucket",
      "status" => "available",
      "version" => option(nil),
      "installHint" => @bitbucket_hint,
      "detail" => option(nil),
      "auth" => auth
    }
  end

  defp bitbucket_config do
    env =
      &(System.get_env(&1, "") |> String.trim() |> then(fn v -> if v == "", do: nil, else: v end))

    token = env.("T3CODE_BITBUCKET_ACCESS_TOKEN")
    email = env.("T3CODE_BITBUCKET_EMAIL")
    api_token = env.("T3CODE_BITBUCKET_API_TOKEN")

    authorization =
      cond do
        token -> "Bearer " <> token
        email && api_token -> "Basic " <> Base.encode64(email <> ":" <> api_token)
        true -> nil
      end

    %{
      base: env.("T3CODE_BITBUCKET_API_BASE_URL") || "https://api.bitbucket.org/2.0",
      token: token,
      email: email,
      authorization: authorization
    }
  end

  # A Bitbucket API GET's decoded JSON object, or nil.
  defp bitbucket_get(path) do
    %{base: base, authorization: authorization} = bitbucket_config()
    url = String.trim_trailing(base, "/") <> path
    headers = if authorization, do: [{~c"authorization", to_charlist(authorization)}], else: []

    case :httpc.request(
           :get,
           {to_charlist(url), headers},
           [timeout: @timeout, ssl: :httpc.ssl_verify_host_options(true)],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, body}} ->
        case JSON.decode(body) do
          {:ok, %{} = user} -> user
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp tool(label, exe, hint) do
    base = %{"label" => label, "executable" => exe, "installHint" => hint}

    case cmd(exe, ["--version"]) do
      {:ok, out, _} ->
        Map.merge(base, %{
          "status" => "available",
          "version" => option(first_line(out)),
          "detail" => option(nil)
        })

      {:error, reason} ->
        Map.merge(base, %{
          "status" => "missing",
          "version" => option(nil),
          "detail" => option(reason)
        })
    end
  end

  defp auth("github", {:ok, out, _}) do
    accounts =
      case JSON.decode(out) do
        {:ok, %{"hosts" => hosts}} -> hosts |> Map.values() |> List.flatten()
        _ -> []
      end

    # The active signed-in account, else any signed-in one.
    signed_in = Enum.filter(accounts, &(&1["state"] == "success"))

    case Enum.find(signed_in, &(&1["active"] == true)) || List.first(signed_in) do
      %{} = account ->
        auth_json("authenticated", account["login"], account["host"], nil)

      nil ->
        auth_json("unauthenticated", nil, nil, "Run `gh auth login` to sign in to GitHub.")
    end
  end

  # glab reports on stderr.
  defp auth("gitlab", {:ok, out, err}) do
    case Regex.run(~r/Logged in to (\S+) as ([^\s(]+)/, out <> "\n" <> err) do
      [_, host, account] -> auth_json("authenticated", account, host, nil)
      nil -> auth_json("unknown", nil, nil, "GitLab CLI auth status could not be parsed.")
    end
  end

  # tea lists its logins; the default one (else the first) is the account.
  defp auth("forgejo", {:ok, out, _}) do
    logins =
      case JSON.decode(out) do
        {:ok, list} when is_list(list) -> Enum.filter(list, &is_map/1)
        _ -> []
      end

    case Enum.find(logins, &(&1["default"] in ["true", true])) || List.first(logins) do
      %{} = login ->
        status = if login["valid"] in ["true", true], do: "authenticated", else: "unauthenticated"
        host = with url when is_binary(url) <- login["url"], do: URI.parse(url).host
        auth_json(status, login["user"], host, nil)

      nil ->
        auth_json(
          "unauthenticated",
          nil,
          nil,
          "Run `tea login add` to authenticate a Forgejo or Gitea server."
        )
    end
  end

  defp auth("azure-devops", {:ok, out, _}) do
    case first_line(out) do
      nil ->
        auth_json(
          "unknown",
          nil,
          "dev.azure.com",
          "Azure CLI account status could not be parsed."
        )

      account ->
        auth_json("authenticated", account, "dev.azure.com", nil)
    end
  end

  defp auth(_kind, {:ok, out, _}), do: auth_json("authenticated", first_line(out), nil, nil)

  defp auth(_kind, {:error, reason}), do: auth_json("unauthenticated", nil, nil, reason)

  defp auth_json(status, account, host, detail),
    do: %{
      "status" => status,
      "account" => option(account),
      "host" => option(host),
      "detail" => option(detail)
    }

  @doc "`sourceControl.lookupRepository`: a repository's name and clone URLs."
  def lookup(%{"provider" => provider, "repository" => repository} = input) do
    case provider do
      "github" ->
        with {:ok, out, _} <-
               cmd("gh", ["repo", "view", repository, "--json", "nameWithOwner,url,sshUrl"],
                 cd: input["cwd"]
               ),
             {:ok, %{"nameWithOwner" => name, "url" => url, "sshUrl" => ssh}} <- JSON.decode(out) do
          {:ok, repo("github", name, url, ssh)}
        else
          error -> repository_error("github", "lookupRepository", error)
        end

      "gitlab" ->
        with {:ok, out, _} <-
               cmd("glab", ["repo", "view", repository, "-F", "json"], cd: input["cwd"]),
             {:ok, %{"path_with_namespace" => name} = info} <- JSON.decode(out) do
          {:ok,
           repo(
             "gitlab",
             name,
             info["web_url"] || info["http_url_to_repo"],
             info["ssh_url_to_repo"]
           )}
        else
          error -> repository_error("gitlab", "lookupRepository", error)
        end

      "azure-devops" ->
        args =
          ~w(repos show --detect true --repository) ++
            [repository | ~w(--only-show-errors --output json)]

        with {:ok, out, _} <- cmd("az", args, cd: input["cwd"]),
             {:ok, %{"name" => name, "remoteUrl" => url, "sshUrl" => ssh} = info} <-
               JSON.decode(out) do
          name =
            case info["project"] do
              %{"name" => project} when is_binary(project) -> project <> "/" <> name
              _ -> name
            end

          {:ok, repo("azure-devops", name, url, ssh)}
        else
          error -> repository_error("azure-devops", "lookupRepository", error)
        end

      "forgejo" ->
        forgejo_lookup(repository, input["cwd"])

      "bitbucket" ->
        with [workspace, slug] <- String.split(repository, "/", parts: 2),
             %{"full_name" => name, "links" => links} <-
               bitbucket_get("/repositories/#{URI.encode(workspace)}/#{URI.encode(slug)}") do
          clone = fn kind ->
            Enum.find_value(
              links["clone"] || [],
              &(String.downcase(&1["name"] || "") == kind && &1["href"])
            )
          end

          url = clone.("https") || get_in(links, ["html", "href"]) || name
          {:ok, repo("bitbucket", name, url, clone.("ssh") || url)}
        else
          _ ->
            repository_error(
              "bitbucket",
              "lookupRepository",
              {:error, "Bitbucket repository #{repository} could not be read."}
            )
        end

      other ->
        repository_error(
          other,
          "lookupRepository",
          {:error, "#{other} repositories are not supported here yet."}
        )
    end
  end

  # Through `tea`: its default login (or its only one) reads the repository from the
  # server's API. tea answers HTTP failures with exit 0, so the status line decides.
  defp forgejo_lookup(repository, cwd) do
    logins =
      case cmd("tea", ~w(login list --output json), cd: cwd) do
        {:ok, out, _} ->
          case JSON.decode(out) do
            {:ok, list} when is_list(list) -> list
            _ -> []
          end

        _ ->
          []
      end

    login =
      Enum.find(logins, &(&1["default"] in ["true", true])) ||
        if(length(logins) == 1, do: hd(logins))

    with %{"name" => name, "url" => base} <-
           login || {:error, "No Forgejo login. Use `tea login add` for this server."},
         path = repository |> String.split("/") |> Enum.map_join("/", &URI.encode/1),
         url = String.trim_trailing(base, "/") <> "/api/v1/repos/" <> path,
         {:ok, out, err} <-
           cmd("tea", ["api", "--include", "--login", name, "--method", "GET", url], cd: cwd),
         [_, status] when status < "400" <-
           Regex.run(~r/^HTTP\/\S+ (\d{3})/m, err) ||
             {:error, "Forgejo did not answer."},
         {:ok, %{"full_name" => full_name} = info} <- JSON.decode(out) do
      {:ok, repo("forgejo", full_name, info["clone_url"], info["ssh_url"])}
    else
      [_, status] ->
        repository_error(
          "forgejo",
          "lookupRepository",
          {:error, "Forgejo answered HTTP #{status}."}
        )

      error ->
        repository_error("forgejo", "lookupRepository", error)
    end
  end

  @doc "The URL to clone from, and the repository when it was looked up."
  def remote(input) do
    cond do
      is_binary(input["remoteUrl"]) ->
        {:ok, input["remoteUrl"], nil}

      is_binary(input["repository"]) ->
        with {:ok, repository} <- lookup(Map.put_new(input, "provider", "github")) do
          url =
            if protocol(input) == "ssh", do: repository["sshUrl"], else: repository["url"]

          {:ok, url, repository}
        end

      true ->
        repository_error(
          input["provider"] || "unknown",
          "cloneRepository",
          {:error, "A repository or remote URL is required."}
        )
    end
  end

  # `auto` follows gh's own git protocol setting.
  defp protocol(%{"protocol" => protocol}) when protocol in ["ssh", "https"], do: protocol

  defp protocol(_input) do
    case cmd("gh", ~w(config get git_protocol)) do
      {:ok, out, _} -> if String.trim(out) == "ssh", do: "ssh", else: "https"
      _ -> "https"
    end
  end

  @doc "`sourceControl.cloneRepository`: clones and waits for it."
  def clone(%{"destinationPath" => dest} = input) do
    dest = Path.expand(dest)

    with {:ok, url, repository} <- remote(input),
         {:ok, _} <- T3.Git.ok(Path.dirname(dest), ["clone", url, dest]) do
      {:ok, %{"cwd" => dest, "remoteUrl" => url, "repository" => repository}}
    else
      {:error, {_status, detail}} ->
        repository_error(input["provider"] || "unknown", "cloneRepository", {:error, detail})

      error ->
        error
    end
  end

  @doc """
  `sourceControl.publishRepository`: creates the repository on the host, adds it
  as a remote, and pushes the current branch when there is one to push.
  """
  def publish(%{"cwd" => cwd, "provider" => provider, "repository" => name} = input) do
    remote_name = input["remoteName"] || "origin"
    visibility = "--" <> (input["visibility"] || "private")

    created =
      case provider do
        "github" -> cmd("gh", ["repo", "create", name, visibility], cd: cwd)
        "gitlab" -> cmd("glab", ["repo", "create", name, visibility], cd: cwd)
        other -> {:error, "#{other} repositories are not supported here yet."}
      end

    with {:ok, _, _} <- created,
         {:ok, repository} <-
           lookup(%{"provider" => provider, "repository" => name, "cwd" => cwd}),
         url = if(protocol(input) == "ssh", do: repository["sshUrl"], else: repository["url"]),
         {:ok, _} <- T3.Git.ok(cwd, ["remote", "add", remote_name, url]) do
      branch = T3.Git.current_branch(cwd)

      pushed =
        branch &&
          match?({:ok, _}, T3.Git.ok(cwd, ["push", "-u", remote_name, branch]))

      {:ok,
       %{
         "repository" => repository,
         "remoteName" => remote_name,
         "remoteUrl" => url,
         "branch" => branch || "main",
         "status" => if(pushed, do: "pushed", else: "remote_added")
       }
       |> then(
         &if(pushed, do: Map.put(&1, "upstreamBranch", "#{remote_name}/#{branch}"), else: &1)
       )}
    else
      {:error, %{"_tag" => _} = error} ->
        {:error, error}

      {:error, {_status, detail}} ->
        repository_error(provider, "publishRepository", {:error, detail})

      error ->
        repository_error(provider, "publishRepository", error)
    end
  end

  defp repo(provider, name, url, ssh),
    do: %{"provider" => provider, "nameWithOwner" => name, "url" => url, "sshUrl" => ssh || url}

  defp repository_error(provider, operation, error) do
    detail =
      case error do
        {:error, message} when is_binary(message) -> message
        {:ok, _, _} -> "The host answered in an unexpected shape."
        other -> inspect(other)
      end

    {:error,
     %{
       "_tag" => "SourceControlRepositoryError",
       "provider" => provider,
       "operation" => operation,
       "detail" => detail,
       "message" => detail
     }}
  end

  # `gh` is the one `T3.PullRequests` and `T3.GitActions` run too.
  # Runs a CLI, giving up after `@timeout`: `{:ok, stdout, stderr}` when it exits 0,
  # else `{:error, first line of what it said}`.
  # `Application.get_env(:t3, :gh_command)` (and so on per CLI) stands in for the CLI.
  defp cmd(exe, args, opts \\ []) do
    command = Application.get_env(:t3, :"#{exe}_command", exe)

    with path when is_binary(path) <-
           System.find_executable(command) || {:error, "#{exe} is not installed"} do
      cd = if opts[:cd] && File.dir?(opts[:cd]), do: [cd: opts[:cd]], else: []

      task =
        Task.async(fn ->
          [path | args]
          |> Exile.stream([stderr: :consume, ignore_epipe: true] ++ cd)
          |> Enum.reduce({[], [], nil}, fn
            {:stdout, data}, {out, err, status} -> {[out, data], err, status}
            {:stderr, data}, {out, err, status} -> {out, [err, data], status}
            {:exit, status}, {out, err, _} -> {out, err, status}
          end)
        end)

      case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {out, err, {:status, 0}}} ->
          {:ok, IO.iodata_to_binary(out), IO.iodata_to_binary(err)}

        {:ok, {out, err, _}} ->
          said = first_line(IO.iodata_to_binary(err)) || first_line(IO.iodata_to_binary(out))
          {:error, said || "#{exe} failed"}

        nil ->
          {:error, "#{exe} did not answer in time"}
      end
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp first_line(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != ""))
  end

  defp option(nil), do: %{"_tag" => "None"}
  defp option(value), do: %{"_tag" => "Some", "value" => value}
end
