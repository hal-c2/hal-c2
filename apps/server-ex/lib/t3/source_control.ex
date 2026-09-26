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
       "sourceControlProviders" => for({:ok, item} <- providers, do: item)
     }}
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

  defp auth("gitlab", {:ok, out, _}) do
    case Regex.run(~r/Logged in to (\S+) as (\S+)/, out) do
      [_, host, account] -> auth_json("authenticated", account, host, nil)
      nil -> auth_json("authenticated", nil, nil, nil)
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
             info["http_url_to_repo"] || info["web_url"],
             info["ssh_url_to_repo"]
           )}
        else
          error -> repository_error("gitlab", "lookupRepository", error)
        end

      "azure-devops" ->
        with {:ok, out, _} <-
               cmd("az", ~w(repos show --detect true --repository #{repository} -o json),
                 cd: input["cwd"]
               ),
             {:ok, %{"name" => name, "remoteUrl" => url, "sshUrl" => ssh} = info} <-
               JSON.decode(out) do
          project = get_in(info, ["project", "name"])
          {:ok, repo("azure-devops", if(project, do: "#{project}/#{name}", else: name), url, ssh)}
        else
          error -> repository_error("azure-devops", "lookupRepository", error)
        end

      "forgejo" ->
        with {:ok, out, _} <- cmd("tea", ~w(login list --output json), cd: input["cwd"]),
             {:ok, logins} when is_list(logins) <- JSON.decode(out),
             %{"name" => login, "url" => base} <- tea_login(logins),
             {:ok, out, err} <-
               cmd(
                 "tea",
                 ~w(api --include --login #{login} --method GET) ++
                   ["#{String.trim_trailing(base, "/")}/api/v1/repos/#{repository}"],
                 cd: input["cwd"]
               ),
             {:ok, %{"full_name" => name, "clone_url" => url} = info} <- tea_json(out, err) do
          {:ok, repo("forgejo", name, url, info["ssh_url"])}
        else
          nil ->
            repository_error(
              "forgejo",
              "lookupRepository",
              {:error, "No matching Forgejo login. Use `tea login add` for this server."}
            )

          error ->
            repository_error("forgejo", "lookupRepository", error)
        end

      "bitbucket" ->
        with {:ok, %{"full_name" => name, "links" => links}} <-
               bitbucket_get("/repositories/#{repository}") do
          clone = Map.new(links["clone"] || [], &{String.downcase(&1["name"]), &1["href"]})
          url = clone["https"] || get_in(links, ["html", "href"]) || name
          {:ok, repo("bitbucket", name, url, clone["ssh"])}
        else
          error -> repository_error("bitbucket", "lookupRepository", error)
        end

      other ->
        repository_error(
          other,
          "lookupRepository",
          {:error, "#{other} repositories are not supported here yet."}
        )
    end
  end

  # The default tea login, or the only one.
  defp tea_login([login]), do: login
  defp tea_login(logins), do: Enum.find(logins, &(&1["default"] in [true, "true"]))

  # tea exits 0 on HTTP failures; `--include` puts the status line on stderr.
  defp tea_json(out, err) do
    case Regex.run(~r/^HTTP\/\S+ (\d{3})/m, err, capture: :all_but_first) do
      [status] when status < "400" -> JSON.decode(out)
      ["404"] -> {:error, "Forgejo repository or pull request was not found."}
      [status] -> {:error, "Forgejo API request failed (HTTP #{status})."}
      nil -> {:error, "Forgejo API request failed without an HTTP status."}
    end
  end

  # Bitbucket Cloud's REST API, signed in through the environment as the Node
  # server is: an access token, or an email with an API token.
  defp bitbucket_get(path) do
    base = System.get_env("T3CODE_BITBUCKET_API_BASE_URL", "https://api.bitbucket.org/2.0")

    auth =
      case System.get_env("T3CODE_BITBUCKET_ACCESS_TOKEN") do
        token when token not in [nil, ""] ->
          "Bearer " <> token

        _ ->
          with email when is_binary(email) <- System.get_env("T3CODE_BITBUCKET_EMAIL"),
               token when is_binary(token) <- System.get_env("T3CODE_BITBUCKET_API_TOKEN"),
               do: "Basic " <> Base.encode64("#{email}:#{token}")
      end

    if auth do
      headers = [
        {~c"authorization", String.to_charlist(auth)},
        {~c"accept", ~c"application/json"}
      ]

      case :httpc.request(
             :get,
             {String.to_charlist(String.trim_trailing(base, "/") <> path), headers},
             [timeout: @timeout, ssl: :httpc.ssl_verify_host_options(true)],
             body_format: :binary
           ) do
        {:ok, {{_, 200, _}, _, body}} ->
          JSON.decode(body)

        {:ok, {{_, 404, _}, _, _}} ->
          {:error, "Bitbucket repository was not found."}

        {:ok, {{_, status, _}, _, _}} ->
          {:error, "Bitbucket API request failed (HTTP #{status})."}

        {:error, reason} ->
          {:error, "Bitbucket API request failed: #{inspect(reason)}"}
      end
    else
      {:error,
       "Set T3CODE_BITBUCKET_EMAIL and T3CODE_BITBUCKET_API_TOKEN, or T3CODE_BITBUCKET_ACCESS_TOKEN."}
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
