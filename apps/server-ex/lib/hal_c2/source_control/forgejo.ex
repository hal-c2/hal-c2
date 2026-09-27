defmodule HalC2.SourceControl.Forgejo do
  @moduledoc """
  Forgejo and Gitea servers, as the Node server reaches them (`ForgejoCli.ts`,
  `ForgejoSourceControlProvider.ts`): through `fj` (Forgejo CLI 0.6 or later) when it
  holds a login for the server, else through `tea`.

  `fj` keeps its tokens in its `keys.json`; the node reads the token and calls the
  server's API itself, after `fj whoami` has had the chance to renew it. fj 0.6 drops
  the path of a server mounted under a subpath, so such servers are left to `tea`,
  which makes each call (`tea api`). `Application.get_env(:hal_c2, :fj_keys_paths)`
  replaces where keys.json is looked for.

  A login is `%{"name", "url", "user", "default"}` and, for an SSH alias fj knows,
  `"ssh_host"`; tea's own login list has the same shape.
  """

  alias HalC2.SourceControl.{Cli, Http}

  @label "Forgejo / Gitea"
  @install_hint "Install `fj` 0.6 or later from https://codeberg.org/forgejo-contrib/forgejo-cli and run `fj --host <server-url> auth add-token`, or install `tea` 0.16 or later from https://gitea.com/gitea/tea and run `tea login add` for each Forgejo or Gitea server."
  @missing "Install Forgejo CLI (`fj` 0.6 or later) or Gitea CLI (`tea` 0.16 or later) and retry."
  @no_login "No matching Forgejo login. Use `fj auth login`, `fj auth add-token`, or `tea login add` for this server; choose a default when multiple tea accounts match."
  @whoami_ttl 30_000
  @authenticated {__MODULE__, :authenticated}

  # --- discovery ----------------------------------------------------------------------

  @doc """
  `server.discoverSourceControl`'s Forgejo entry for the checkout at `cwd`: fj when it
  is installed and holds a login (or its storage could not be read), else tea, unless
  tea is missing too and fj is not.
  """
  def discover(cwd) do
    remote_url = origin(cwd)
    credentials = fj_logins(remote_url)
    logins = with({:ok, list} <- credentials, do: list, else: (_ -> []))
    remote = parse_remote(remote_url || "")

    login =
      (remote && match_login(logins, remote)) || Enum.find(logins, &(&1["default"] == "true")) ||
        List.first(logins)

    fj = probe("fj", ["version"], cwd, fn -> fj_auth(cwd, credentials, login) end)

    if fj["status"] == "available" and (login != nil or match?({:error, _}, credentials)) do
      fj
    else
      tea = probe("tea", ["--version"], cwd, fn -> tea_auth(cwd) end)
      if tea["status"] == "available" or fj["status"] == "missing", do: tea, else: fj
    end
  end

  defp probe(exe, version_args, cwd, auth) do
    base = %{
      "kind" => "forgejo",
      "label" => @label,
      "executable" => exe,
      "installHint" => @install_hint
    }

    case Cli.run(exe, version_args, cd: cwd, timeout: 10_000) do
      {:ok, out, err} ->
        Map.merge(base, %{
          "status" => "available",
          "version" => option(Cli.first_line(out) || Cli.first_line(err)),
          "detail" => option(nil),
          "auth" => auth.()
        })

      {:error, {_, detail}} ->
        Map.merge(base, %{
          "status" => "missing",
          "version" => option(nil),
          "detail" => option(detail),
          "auth" => auth_json("unknown", nil, nil, nil)
        })
    end
  end

  defp fj_auth(_cwd, {:error, _}, _login),
    do:
      auth_json(
        "unknown",
        nil,
        nil,
        "Could not read fj authentication storage. Authenticate again with fj."
      )

  defp fj_auth(cwd, {:ok, _}, login) do
    args = if login, do: ["--host", login["url"], "whoami"], else: ["auth", "list"]

    case login && Cli.run("fj", args, cd: cwd, timeout: 10_000) do
      {:ok, _, _} ->
        host = host_of(login["url"])

        case account(cwd, login["url"]) do
          {:ok, account} -> auth_json("authenticated", account, host, nil)
          {:error, {_, detail}} -> auth_json("unknown", nil, host, detail)
        end

      _ ->
        auth_json(
          "unauthenticated",
          nil,
          nil,
          "Authenticate this server with `fj --host <server-url> auth add-token`."
        )
    end
  end

  # tea lists its logins; the default one (else the first) is the account.
  defp tea_auth(cwd) do
    case tea_logins(cwd) do
      {:ok, logins} when logins != [] ->
        login = Enum.find(logins, &(&1["default"] == "true")) || hd(logins)
        status = if login["valid"] == "true", do: "authenticated", else: "unauthenticated"
        auth_json(status, login["user"], host_of(login["url"]), nil)

      {:ok, []} ->
        auth_json(
          "unauthenticated",
          nil,
          nil,
          "Run `tea login add` to authenticate a Forgejo or Gitea server."
        )

      {:error, {_, detail}} ->
        auth_json("unauthenticated", nil, nil, detail)
    end
  end

  defp auth_json(status, account, host, detail),
    do: %{
      "status" => status,
      "account" => option(if(account in [nil, ""], do: nil, else: account)),
      "host" => option(host),
      "detail" => option(detail)
    }

  defp option(nil), do: %{"_tag" => "None"}
  defp option(value), do: %{"_tag" => "Some", "value" => value}

  # --- logins -------------------------------------------------------------------------

  @doc """
  Where fj keeps keys.json (fj's `ProjectDirs`, with its pre-0.6 organization name).
  """
  def keys_paths do
    Application.get_env(:hal_c2, :fj_keys_paths) || default_keys_paths()
  end

  defp default_keys_paths do
    home = System.user_home!()

    case :os.type() do
      {:unix, :darwin} ->
        for org <- ["forgejo-cli", "Cyborus"],
            do:
              Path.join([
                home,
                "Library",
                "Application Support",
                "#{org}.forgejo-cli",
                "keys.json"
              ])

      {:win32, _} ->
        app_data = System.get_env("APPDATA") || Path.join([home, "AppData", "Roaming"])

        for org <- ["forgejo-cli", "Cyborus"],
            do: Path.join([app_data, org, "forgejo-cli", "data", "keys.json"])

      _ ->
        data = System.get_env("XDG_DATA_HOME", "")

        data =
          if Path.type(data) == :absolute, do: data, else: Path.join([home, ".local", "share"])

        [Path.join([data, "forgejo-cli", "keys.json"])]
    end
  end

  @doc """
  fj's stored credentials, `%{"hosts" => %{host => %{"type", "token"}}, "aliases" => %{}}`,
  from the first keys.json there is; none when there is no file.
  """
  def keys do
    case Enum.find(keys_paths(), &File.exists?/1) do
      nil ->
        {:ok, %{"hosts" => %{}, "aliases" => %{}}}

      path ->
        with {:ok, raw} <- File.read(path),
             {:ok, %{"hosts" => %{} = hosts} = keys} <- JSON.decode(raw),
             true <- Enum.all?(hosts, fn {_, entry} -> valid_key?(entry) end) do
          {:ok, Map.put(keys, "aliases", keys["aliases"] || %{})}
        else
          {:error, reason} when is_atom(reason) ->
            {:error, {:unauthenticated, "Could not read fj authentication storage."}}

          _ ->
            {:error,
             {:unauthenticated,
              "fj authentication storage is invalid. Authenticate again with fj."}}
        end
    end
  end

  defp valid_key?(%{"type" => type, "token" => token})
       when type in ["Application", "OAuth"] and is_binary(token),
       do: true

  defp valid_key?(_), do: false

  @doc """
  fj's logins, one per server (per SSH alias when it has any). A server mounted under
  a path is left out: fj 0.6 cannot serve it. fj stores no scheme, so the URL is
  https unless `remote_url` is an explicit http remote on that server.
  """
  def logins_from_keys(keys, remote_url \\ nil) do
    remote = remote_url && parse_remote(remote_url)

    Enum.flat_map(Map.keys(keys["hosts"]), fn host ->
      case parse_remote("https://" <> host) do
        %{path: ""} = url ->
          scheme =
            if remote && not remote.ssh && remote.host == url.host &&
                 String.match?(remote_url, ~r/^http:\/\//i),
               do: "http",
               else: "https"

          login = %{
            "name" => host,
            "url" => "#{scheme}://#{host}",
            "user" => "",
            "default" => "false"
          }

          case for({alias, ^host} <- keys["aliases"] || %{}, do: alias) do
            [] -> [login]
            aliases -> Enum.map(aliases, &Map.put(login, "ssh_host", &1))
          end

        _ ->
          []
      end
    end)
  end

  @doc """
  fj's logins (`logins_from_keys/2`). Storage that cannot be read only counts when fj
  is installed: stale credentials from an uninstalled fj must not hide tea's logins.
  """
  def fj_logins(remote_url \\ nil) do
    case keys() do
      {:ok, keys} ->
        {:ok, logins_from_keys(keys, remote_url)}

      error ->
        case Cli.run("fj", ["version"], timeout: 10_000) do
          {:error, {:missing, _}} -> {:ok, []}
          _ -> error
        end
    end
  end

  @doc "tea's logins (`tea login list`)."
  def tea_logins(cwd) do
    case Cli.run("tea", ~w(login list --output json), cd: cwd) do
      {:ok, out, _} ->
        case JSON.decode(out) do
          {:ok, list} when is_list(list) ->
            {:ok,
             for(
               %{"name" => name, "url" => url, "user" => user} = login <- list,
               is_binary(name) and is_binary(url) and is_binary(user),
               do: Map.update(login, "default", "false", &to_string/1)
             )
             |> Enum.map(&Map.update(&1, "valid", nil, fn v -> v && to_string(v) end))}

          _ ->
            {:ok, []}
        end

      {:error, {:missing, _}} ->
        {:error, {:missing, @missing}}

      {:error, {reason, _}} ->
        {:error, {reason, "Forgejo CLI command failed."}}
    end
  end

  @doc """
  A remote or server URL as `%{host, hostname, ssh, path}` (`path` without slashes at
  either end or `.git`), or nil. SCP-style remotes are SSH.
  """
  def parse_remote(value) when is_binary(value) do
    cond do
      String.match?(value, ~r/^(?:https?|ssh):\/\//i) ->
        case URI.new(value) do
          {:ok, %URI{host: host} = uri} when is_binary(host) and host != "" ->
            hostname = String.downcase(host)

            port =
              if uri.port && uri.port != URI.default_port(uri.scheme),
                do: ":#{uri.port}",
                else: ""

            %{
              host: hostname <> port,
              hostname: hostname,
              ssh: String.downcase(uri.scheme) == "ssh",
              path: (uri.path || "") |> String.trim("/") |> String.replace_suffix(".git", "")
            }

          _ ->
            nil
        end

      match = Regex.run(~r/^(?:[^@\/]+@)?([^:\/]+):([^\/].*)$/, value) ->
        [_, host, path] = match
        host = String.downcase(host)
        %{host: host, hostname: host, ssh: true, path: String.replace_suffix(path, ".git", "")}

      true ->
        nil
    end
  end

  def parse_remote(_), do: nil

  @doc """
  The one login that serves `remote` (`matchForgejoLogin`): an SSH remote by the
  login's SSH alias or hostname, an HTTP one by host and mount path. Several logins
  on one server resolve to its default; otherwise none.
  """
  def match_login(logins, remote, requested_host \\ nil, host_only \\ false) do
    matches =
      logins
      |> Enum.filter(fn login ->
        url = parse_remote(login["url"])

        cond do
          url == nil ->
            false

          requested_host != nil and url.host != String.downcase(requested_host) ->
            false

          remote.ssh ->
            ssh = login["ssh_host"] && String.downcase(login["ssh_host"])
            ssh in [remote.host, remote.hostname] or url.hostname == remote.hostname

          true ->
            url.host == remote.host and
              ((host_only and remote.path == "") or url.path == "" or remote.path == url.path or
                 String.starts_with?(remote.path, url.path <> "/"))
        end
      end)
      |> Enum.uniq_by(& &1["name"])

    case matches do
      [one] ->
        one

      many ->
        if many |> Enum.map(& &1["url"]) |> Enum.uniq() |> length() == 1,
          do: Enum.find(many, &(&1["default"] == "true"))
    end
  end

  # --- repositories and API calls -----------------------------------------------------

  @doc """
  Which CLI and login serve a repository (`resolveTarget`): `%{command, login,
  repository, base_url}`. `opts`: `:repository` (`owner/name` or a URL), `:reference`
  (a change request URL), `:host`, `:remote_url` (the checkout's remote, else read
  from `cwd`) and `:host_only` (a server-wide call such as `/user`).
  """
  def resolve(cwd, opts \\ []) do
    repository = opts[:repository]
    reference_remote = opts[:reference] && parse_remote(opts[:reference])
    host = opts[:host] && String.downcase(opts[:host])

    remote_url =
      Enum.find([opts[:reference], repository, opts[:remote_url]], &(&1 && parse_remote(&1)))

    {remote_url, remote} =
      if remote_url == nil and (repository == nil or host != nil) do
        url = if host, do: host_remote(cwd, host), else: origin(cwd)
        {url, url && parse_remote(url)}
      else
        {remote_url, remote_url && parse_remote(remote_url)}
      end

    remote =
      if host && !(remote && remote.ssh) && !(remote && host in [remote.host, remote.hostname]),
        do: %{
          host: host,
          hostname: host |> String.split(":") |> hd(),
          ssh: false,
          path: (remote && remote.path) || ""
        },
        else: remote

    host_only = opts[:host_only] == true or (host != nil and (remote == nil or remote.path == ""))
    requested_host = if remote && remote.ssh, do: host

    select = fn logins ->
      if remote,
        do: match_login(logins, remote, requested_host, host_only),
        else:
          Enum.find(logins, &(&1["default"] == "true")) ||
            if(logins |> Enum.map(& &1["name"]) |> Enum.uniq() |> length() == 1,
              do: hd(logins)
            )
    end

    with {:ok, fj_logins} <- fj_logins(if(remote && !remote.ssh, do: remote_url)),
         {:ok, command, login} <-
           pick_login(cwd, fj_logins, select, remote, requested_host, host_only) do
      target(cwd, command, login, opts, reference_remote, remote, host_only)
    end
  end

  defp pick_login(cwd, fj_logins, select, remote, requested_host, host_only) do
    login = select.(fj_logins)

    ambiguous? =
      login == nil and
        Enum.any?(
          fj_logins,
          &(remote == nil or match_login([&1], remote, requested_host, host_only) != nil)
        )

    fj =
      cond do
        ambiguous? ->
          case Cli.run("fj", ["version"], cd: cwd, timeout: 10_000) do
            {:ok, _, _} ->
              {:error,
               {:unauthenticated,
                "Multiple fj logins match this repository. Specify its full server URL."}}

            {:error, {:missing, _}} ->
              nil

            {:error, {reason, _}} ->
              {:error, {reason, "Forgejo CLI command failed."}}
          end

        login ->
          case authenticate(cwd, login) do
            {:ok, _token} -> {:ok, :fj, login}
            {:error, {:missing, _}} -> nil
            error -> error
          end

        true ->
          nil
      end

    fj ||
      with {:ok, logins} <- tea_logins(cwd) do
        case select.(logins) do
          nil -> {:error, {:unauthenticated, @no_login}}
          login -> {:ok, :tea, login}
        end
      end
  end

  defp target(cwd, command, login, opts, reference_remote, remote, host_only) do
    base_url = String.trim_trailing(login["url"], "/")

    if host_only do
      {:ok, %{command: command, login: login["name"], repository: "", base_url: base_url}}
    else
      repository = opts[:repository]

      path =
        (reference_remote && reference_remote.path) ||
          if(repository && parse_remote(repository) == nil, do: repository) ||
          (remote && remote.path) || ""

      base_path = (URI.parse(login["url"]).path || "") |> String.trim("/")

      relative =
        if base_path != "" and length(String.split(path, "/")) > 2 and
             String.starts_with?(path, base_path <> "/"),
           do: String.replace_prefix(path, base_path <> "/", ""),
           else: path

      path =
        relative |> String.replace(~r/\/pulls\/\d+.*$/, "") |> String.replace_suffix(".git", "")

      owner =
        cond do
          String.contains?(path, "/") -> {:ok, nil}
          command == :fj -> account(cwd, login["url"])
          true -> {:ok, login["user"]}
        end

      with {:ok, owner} <- owner do
        repository = if owner, do: "#{owner}/#{path}", else: path

        if Regex.match?(~r/^[^\/\s]+\/[^\/\s]+$/, repository),
          do:
            {:ok,
             %{command: command, login: login["name"], repository: repository, base_url: base_url}},
          else:
            {:error,
             {:failed, "Specify a Forgejo repository as owner/repository or its full server URL."}}
      end
    end
  end

  @doc """
  One API call (`path` under `/api/v1/`) for the repository `target_opts` names
  (`resolve/2`): `{:ok, body, %{status, link}}`, or `{:error, {reason, detail}}` with
  the HTTP failure named. Options: `:method` (default `"GET"`) and `:body`.
  """
  def api(cwd, target_opts, path, opts \\ []) do
    method = opts[:method] || "GET"
    path = String.trim_leading(path, "/")
    host_only = path == "user" and method == "GET"

    with {:ok, target} <- resolve(cwd, Keyword.put(target_opts, :host_only, host_only)) do
      path = retarget(path, target_opts[:repository], target.repository)

      body =
        opts[:body] &&
          if(is_binary(opts[:body]), do: opts[:body], else: JSON.encode!(opts[:body]))

      case target.command do
        :fj -> fj_request(cwd, target, path, method, body)
        :tea -> tea_request(cwd, target, path, method, body)
      end
    end
  end

  # A repository's identity keeps the server's mount path; its API routes do not.
  defp retarget(path, asked, resolved) when is_binary(asked) and asked != resolved do
    prefix = "repos/" <> encode_repository(asked)

    if path == prefix or String.starts_with?(path, [prefix <> "/", prefix <> "?"]),
      do: "repos/" <> encode_repository(resolved) <> String.replace_prefix(path, prefix, ""),
      else: path
  end

  defp retarget(path, _asked, _resolved), do: path

  @doc "`owner/name` with each segment URL-encoded."
  def encode_repository(repository),
    do: repository |> String.split("/") |> Enum.map_join("/", &URI.encode_www_form/1)

  defp fj_request(cwd, target, path, method, body) do
    with {:ok, keys} <- keys(),
         token when is_binary(token) <-
           get_in(keys, ["hosts", target.login, "token"]) ||
             {:error, {:unauthenticated, "fj has no credentials for this server."}} do
      request(cwd, target.base_url, token, path, method, body)
    end
  end

  defp request(_cwd, base_url, token, path, method, body) do
    base = URI.parse(base_url <> "/api/v1/")
    url = URI.merge(base, path)

    if url.host != base.host or url.port != base.port or url.userinfo != nil or
         not String.starts_with?(url.path || "", base.path) do
      {:error, {:failed, "Invalid Forgejo API path."}}
    else
      method = method |> String.downcase() |> String.to_existing_atom()

      case Http.request(method, URI.to_string(url), [{"authorization", "token " <> token}],
             body: body
           ) do
        {:ok, status, headers, text} when status in 200..299 ->
          {:ok, text, %{status: status, link: headers["link"]}}

        {:ok, 404, _, _} ->
          {:error, {:not_found, "Forgejo repository or pull request was not found."}}

        {:ok, status, _, text} ->
          detail =
            if text != "",
              do: "Forgejo API request failed (HTTP #{status}): #{text}",
              else:
                "Forgejo API request failed (HTTP #{status}). Check this server's fj credentials and permissions."

          {:error, {http_reason(status), detail}}

        {:error, _} ->
          {:error, {:failed, "Forgejo API request failed or timed out."}}
      end
    end
  end

  # tea answers HTTP failures with exit 0; the status line it prints decides.
  defp tea_request(cwd, target, path, method, body) do
    args =
      ["api", "--include", "--login", target.login] ++
        if(target.repository != "", do: ["--repo", target.repository], else: []) ++
        ["--method", method] ++
        if(body, do: ["--data", "@-"], else: []) ++
        ["#{target.base_url}/api/v1/#{path}"]

    case Cli.run("tea", args, cd: cwd, input: body) do
      {:ok, out, err} ->
        status =
          case Regex.run(~r/^HTTP\/\S+ (\d{3})/m, err) do
            [_, status] -> String.to_integer(status)
            nil -> nil
          end

        link =
          case Regex.run(~r/^link:\s*(.+)$/mi, err) do
            [_, link] -> String.trim(link)
            nil -> nil
          end

        cond do
          status && status < 400 ->
            {:ok, out, %{status: status, link: link}}

          true ->
            detail =
              case status do
                s when s in [401, 403] ->
                  "Forgejo denied access. Check this server's `tea login` credentials and permissions."

                404 ->
                  "Forgejo repository or pull request was not found."

                429 ->
                  "Forgejo API rate limit exceeded."

                nil ->
                  "Forgejo API request failed without an HTTP status."

                s ->
                  "Forgejo API request failed (HTTP #{s})."
              end

            {:error, {http_reason(status), detail}}
        end

      {:error, {:missing, _}} ->
        {:error, {:missing, @missing}}

      {:error, {reason, _}} ->
        {:error, {reason, "Forgejo CLI command failed."}}
    end
  end

  defp http_reason(401), do: :unauthenticated
  defp http_reason(403), do: :forbidden
  defp http_reason(404), do: :not_found
  defp http_reason(429), do: :rate_limited
  defp http_reason(_), do: :failed

  @doc """
  The account fj is signed in as on the server at `base_url`: `{:ok, login}` from the
  server's `/api/v1/user`.
  """
  def account(cwd, base_url) do
    base_url = String.trim_trailing(base_url, "/")

    with {:ok, logins} <- fj_logins(base_url),
         %{} = login <-
           Enum.find(logins, &(String.trim_trailing(&1["url"], "/") == base_url)) ||
             {:error, {:unauthenticated, "fj has no credentials for this server."}},
         {:ok, token} <- authenticate(cwd, login),
         {:ok, text, _} <- request(cwd, base_url, token, "user", "GET", nil) do
      case JSON.decode(text) do
        {:ok, %{"login" => account}} when is_binary(account) and account != "" ->
          {:ok, account}

        _ ->
          {:error, {:failed, "Forgejo returned an invalid account response."}}
      end
    end
  end

  # fj renews an expired OAuth token during `whoami`; the token is read again after,
  # and believed for thirty seconds.
  defp authenticate(cwd, login) do
    now = System.monotonic_time(:millisecond)
    held = :persistent_term.get(@authenticated, %{})
    stored = with({:ok, keys} <- keys(), do: get_in(keys, ["hosts", login["name"], "token"]))

    case held[login["url"]] do
      {^stored, at} when is_binary(stored) and now - at < @whoami_ttl ->
        {:ok, stored}

      _ ->
        with {:ok, _, _} <- whoami(cwd, login["url"]),
             {:ok, keys} <- keys(),
             token when is_binary(token) <-
               get_in(keys, ["hosts", login["name"], "token"]) ||
                 {:error,
                  {:unauthenticated,
                   "fj has no credentials for this server. Authenticate again with fj."}} do
          :persistent_term.put(@authenticated, Map.put(held, login["url"], {token, now}))
          {:ok, token}
        end
    end
  end

  defp whoami(cwd, url) do
    case Cli.run("fj", ["--host", url, "whoami"], cd: cwd) do
      {:ok, _, _} = ok ->
        ok

      {:error, {:missing, _}} ->
        {:error, {:missing, @missing}}

      {:error, {:unauthenticated, _}} ->
        {:error,
         {:unauthenticated,
          "Authenticate this server with `fj auth login`, `fj auth add-token`, or `tea login add`."}}

      {:error, {reason, _}} ->
        {:error, {reason, "Forgejo CLI command failed."}}
    end
  end

  # --- remotes ------------------------------------------------------------------------

  defp origin(cwd) do
    case cwd && HalC2.Git.ok(cwd, ~w(remote get-url origin)) do
      {:ok, url} -> String.trim(url) |> then(&if(&1 == "", do: nil, else: &1))
      _ -> nil
    end
  end

  # The one HTTP remote on `host` (or the one origin its remotes share).
  defp host_remote(cwd, host) do
    case HalC2.Git.ok(cwd, ~w(remote -v)) do
      {:ok, out} ->
        urls =
          for line <- String.split(out, "\n"),
              [_, url] <- [Regex.run(~r/^\S+\s+(https?:\/\/\S+)\s+\(fetch\)$/, String.trim(line))],
              match?(%{host: ^host}, parse_remote(url)),
              uniq: true,
              do: url

        origins =
          urls
          |> Enum.map(
            &(URI.parse(&1)
              |> Map.merge(%{path: nil, query: nil, userinfo: nil})
              |> URI.to_string())
          )
          |> Enum.uniq()

        case {urls, origins} do
          {[url], _} -> url
          {_, [origin]} -> origin
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp host_of(url) do
    case url && parse_remote(url) do
      %{host: host} -> host
      _ -> nil
    end
  end
end
