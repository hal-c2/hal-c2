defmodule HalC2.Steps.SourceControl.RepositoryDiscoveryClonePublish do
  @moduledoc """
  Steps for `features/source-control/repository-discovery-clone-publish.feature`:
  tool discovery against fake host CLIs, lookups, clones from local bare
  repositories, project clones (`HalC2.ProjectClones`) and publishing.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.FakeHttp
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World
  alias HalC2.SourceControl.Forgejo
  alias HalC2.Steps.SourceControl.FakeBitbucket
  alias HalC2.Steps.SourceControl.Shared

  # tool => {label, version line, auth rule (nil for version control), account host}
  @tools %{
    "jj" => {"Jujutsu", "jj 0.30.0", nil, nil},
    "gh" =>
      {"GitHub", "gh version 2.81.0 (2025-10-01)",
       %{
         "args" => ["auth status"],
         "stdout" => %{
           "hosts" => %{
             "github.com" => [
               %{
                 "state" => "success",
                 "active" => true,
                 "login" => "octocat",
                 "host" => "github.com"
               }
             ]
           }
         }
       }, "github.com"},
    "glab" =>
      {"GitLab", "glab 1.50.0 (2025-01-10)",
       %{
         "args" => ["auth status"],
         "stderr" =>
           "gitlab.com\n  ✓ Logged in to gitlab.com as octocat (/home/u/.config/glab-cli/config.yml)\n"
       }, "gitlab.com"},
    "tea" =>
      {"Forgejo / Gitea", "Version: 0.10.1",
       %{
         "args" => ["login list"],
         "stdout" => [
           %{
             "name" => "codeberg",
             "url" => "https://codeberg.org",
             "user" => "octocat",
             "default" => "true",
             "valid" => "true"
           }
         ]
       }, "codeberg.org"},
    "az" =>
      {"Azure DevOps", "azure-cli 2.60.0",
       %{"args" => ["account show"], "stdout" => "octocat@example.com\n"}, "dev.azure.com"}
  }

  # --- discovery -----------------------------------------------------------------

  step "git is installed and signed in on the MC's machine", context do
    {version, 0} = System.cmd("git", ["--version"])
    Map.merge(context, %{tool: "Git", version: String.trim(version), account: nil})
  end

  step ~r/^(?<tool>jj|gh|glab|tea|az) is installed and signed in on the MC's machine$/,
       %{args: [tool]} = context do
    {label, version, auth, host} = Map.fetch!(@tools, tool)

    rules =
      [%{"cmd" => tool, "args" => ["--version"], "stdout" => version <> "\n"}] ++
        if auth, do: [Map.put(auth, "cmd", tool)], else: []

    context
    |> World.fake_cli([tool])
    |> World.cli_rules(rules)
    |> Map.merge(%{
      tool: label,
      version: version,
      account: auth && if(tool == "az", do: "octocat@example.com", else: "octocat"),
      host: host
    })
  end

  step "the user asks which source control tools are available", context do
    # Only the tools the scenario installed are found: a CLI the machine itself has
    # (a CI runner's `az` takes seconds to start) would answer instead.
    for exe <- ~w(jj gh glab az),
        !(context[:cli] && File.exists?(Path.join(context.cli.bin, exe))),
        do: World.put_app_env(:"#{exe}_command", "hal-c2-test-no-#{exe}")

    {result, context} = World.call!(context, "server.discoverSourceControl", %{})
    Map.put(context, :discovery, result)
  end

  step ~r/^(?<name>.+) is reported available with its version and signed-in account$/,
       %{args: [name]} = context do
    assert name == context.tool
    item = discovered(context, name)
    assert item["status"] == "available"
    assert item["version"] == %{"_tag" => "Some", "value" => context.version}

    if context.account do
      assert item["auth"]["status"] == "authenticated"
      assert item["auth"]["account"] == %{"_tag" => "Some", "value" => context.account}
      assert item["auth"]["host"] == %{"_tag" => "Some", "value" => context.host}
    else
      refute Map.has_key?(item, "auth")
    end

    context
  end

  step "GitHub is reported missing with how to install the GitHub CLI", context do
    item = discovered(context, "GitHub")
    assert item["status"] == "missing"
    assert item["installHint"] =~ "https://cli.github.com/"
    context
  end

  step "GitHub is reported not authenticated and the user is told to run gh auth login",
       context do
    item = discovered(context, "GitHub")
    assert item["status"] == "available"
    assert item["auth"]["status"] == "unauthenticated"
    assert %{"_tag" => "Some", "value" => detail} = item["auth"]["detail"]
    assert detail =~ "gh auth login"
    context
  end

  step "the MC was started with a Bitbucket access token in its environment", context do
    Shared.fake_bitbucket(context)
  end

  step "Bitbucket is reported available and signed in", context do
    item = discovered(context, "Bitbucket")
    assert item["status"] == "available"
    assert item["auth"]["status"] == "authenticated"
    assert item["auth"]["account"] == %{"_tag" => "Some", "value" => "octocat"}
    context
  end

  # The MC reads Bitbucket's environment: a closed port stands for an unreachable
  # Bitbucket, and "names the account" starts the fake one.
  step ~r/^the MC was started with (?<credentials>an access token|an email address and an API token|an email address without an API token|nothing)$/,
       %{args: [credentials]} = context do
    for name <-
          ~w(HAL_C2_BITBUCKET_ACCESS_TOKEN HAL_C2_BITBUCKET_EMAIL HAL_C2_BITBUCKET_API_TOKEN HAL_C2_BITBUCKET_API_BASE_URL),
        do: unset_env(name)

    Shared.put_env("HAL_C2_BITBUCKET_API_BASE_URL", "http://127.0.0.1:1/2.0")

    case credentials do
      "an access token" ->
        Shared.put_env("HAL_C2_BITBUCKET_ACCESS_TOKEN", FakeBitbucket.token())

      "an email address and an API token" ->
        Shared.put_env("HAL_C2_BITBUCKET_EMAIL", FakeBitbucket.email())
        Shared.put_env("HAL_C2_BITBUCKET_API_TOKEN", FakeBitbucket.api_token())

      "an email address without an API token" ->
        Shared.put_env("HAL_C2_BITBUCKET_EMAIL", FakeBitbucket.email())

      "nothing" ->
        :ok
    end

    context
  end

  step ~r/^Bitbucket (?<answer>names the account|cannot be reached|is not asked) when asked who the account is$/,
       %{args: [answer]} = context do
    if answer == "names the account", do: start_fake_bitbucket_api(context), else: context
  end

  step "Bitbucket is reported signed in as that account", context do
    item = discovered(context, "Bitbucket")
    assert item["auth"]["status"] == "authenticated"
    assert item["auth"]["account"] == %{"_tag" => "Some", "value" => "octocat"}
    context
  end

  step ~r/^Bitbucket is reported configured, with "(?<detail>[^"]+)" and no account$/,
       %{args: [detail]} = context do
    item = assert_bitbucket_unknown(context, detail)
    refute match?(%{"_tag" => "Some"}, item["auth"]["account"])
    context
  end

  step ~r/^Bitbucket is reported configured as the email address, with "(?<detail>[^"]+)"$/,
       %{args: [detail]} = context do
    item = assert_bitbucket_unknown(context, detail)
    assert item["auth"]["account"] == %{"_tag" => "Some", "value" => FakeBitbucket.email()}
    context
  end

  step "Bitbucket is reported not authenticated and told which variables to set", context do
    item = discovered(context, "Bitbucket")
    assert item["auth"]["status"] == "unauthenticated"
    assert %{"_tag" => "Some", "value" => detail} = item["auth"]["detail"]
    assert detail =~ "HAL_C2_BITBUCKET_EMAIL"
    assert detail =~ "HAL_C2_BITBUCKET_ACCESS_TOKEN"
    context
  end

  # fj's keys.json names the server without a scheme; a server under a subpath keeps
  # its path, which fj 0.6 cannot serve. The account lookup after `whoami` finds
  # nothing listening, which leaves fj reported with an unknown account.
  step ~r/^both fj and tea are installed and fj holds a login for "(?<server>[^"]+)"$/,
       %{args: [server]} = context do
    server = if server == "codeberg.org", do: "127.0.0.1:1", else: server
    keys = Path.join(Mc.tmp_dir(context.mc, "forgejo-cli"), "keys.json")

    File.write!(
      keys,
      JSON.encode!(%{
        "hosts" => %{server => %{"type" => "Application", "token" => "fj-token"}},
        "aliases" => %{}
      })
    )

    previous = Application.get_env(:hal_c2, :fj_keys_paths)
    Application.put_env(:hal_c2, :fj_keys_paths, [keys])
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:hal_c2, :fj_keys_paths, previous) end)

    context
    |> World.fake_cli(["fj", "tea"])
    |> World.cli_rules([
      %{"cmd" => "fj", "args" => ["version"], "stdout" => "fj v0.6.0\n"},
      %{"cmd" => "fj", "args" => ["whoami"], "stdout" => "octocat\n"},
      %{"cmd" => "tea", "args" => ["--version"], "stdout" => "Version: 0.10.1\n"},
      %{"cmd" => "tea", "args" => ["login list"], "stdout" => []}
    ])
  end

  step ~r/^Forgejo is reported through (?<cli>fj|tea)$/, %{args: [cli]} = context do
    item = discovered(context, "Forgejo / Gitea")
    assert item["executable"] == cli
    assert item["status"] == "available"
    context
  end

  # --- Forgejo logins and reads ------------------------------------------------------
  # fj is the Forgejo CLI, tea the Gitea CLI. A scenario that does not use fj has it
  # uninstalled and its storage pointed at a file that does not exist.

  step ~r/^the Forgejo CLIs hold (?<logins>.+)$/, %{args: [logins]} = context do
    hold_logins(context, logins)
  end

  step ~r/^the MC reads a Forgejo repository whose remote is (?<remote>.+)$/,
       %{args: [remote]} = context do
    cwd = Mc.tmp_dir(context.mc, "forgejo-remote")
    Map.put(context, :reply, Forgejo.resolve(cwd, remote_url: remote_address(remote)))
  end

  step ~r/^(?:that login|the default login) is used$/, context do
    assert {:ok, %{login: login}} = context.reply
    assert login == context.expected_login
    context
  end

  step ~r/^the user is told (?<what>to choose a default login|no matching login was found)$/,
       %{args: [what]} = context do
    fragment =
      if what == "to choose a default login",
        do: "choose a default",
        else: "No matching Forgejo login"

    assert {:error, {:unauthenticated, message}} = context.reply
    assert message =~ fragment, "#{inspect(message)} does not say #{inspect(fragment)}"
    context
  end

  step ~r/^the Forgejo CLI is signed in to "(?<server>[^"]+)" and stores its tokens in its data folder$/,
       %{args: [server]} = context do
    data = Mc.tmp_dir(context.mc, "xdg-data")
    File.mkdir_p!(Path.join(data, "forgejo-cli"))
    keys = keys_map(%{server => fj_host("data-token")})
    File.write!(Path.join([data, "forgejo-cli", "keys.json"]), JSON.encode!(keys))
    Shared.put_env("XDG_DATA_HOME", data)
    # config/test.exs empties the keys path list; this scenario reads fj's default location.
    World.put_app_env(:fj_keys_paths, nil)

    context
    |> Map.put(:keys_map, keys)
    |> with_forgejo_api(%{"/api/v1/repos/acme/notes" => {200, repo_json("acme/notes", server)}})
    |> fj_installed([whoami_rule("octocat")])
  end

  step "the MC reads a repository on {string}", %{args: [_server]} = context do
    {reply, context} = lookup_forgejo(context, "acme/notes")
    assert {:ok, _} = reply, "the read failed: #{inspect(reply)}"
    Map.put(context, :reply, reply)
  end

  step ~r/^the stored token of "[^"]+" is used for the request$/, context do
    requests = FakeHttp.requests(context.forgejo)
    assert requests != []
    assert Enum.all?(requests, &(&1["authorization"] == "token data-token"))
    context
  end

  step "the server is reached over https unless the checkout's remote is an explicit http address of that server",
       context do
    assert [%{"url" => "https://codeberg.org"}] = Forgejo.logins_from_keys(context.keys_map)

    assert [%{"url" => "http://codeberg.org"}] =
             Forgejo.logins_from_keys(context.keys_map, "http://codeberg.org/acme/notes.git")

    context
  end

  step "the Forgejo CLI's stored credentials cannot be read", context do
    dir = Mc.tmp_dir(context.mc, "forgejo-unreadable")
    context |> with_fj_storage(dir) |> fj_installed()
  end

  step "the Forgejo CLI's stored credentials are damaged", context do
    context |> fj_storage_file("{not json") |> fj_installed()
  end

  step "stored credentials remain from an uninstalled Forgejo CLI and the Gitea CLI has a login",
       context do
    context
    |> fj_storage_file(JSON.encode!(keys_map(%{"codeberg.org" => fj_host("stale-token")})))
    |> fj_missing()
    |> tea_logins([tea_login("codeberg", "https://codeberg.org", "true")], [
      tea_api_rule("codeberg", "https://codeberg.org", "acme/notes", "codeberg.org", "200 OK")
    ])
  end

  step "the Gitea CLI's login is used", context do
    assert {:ok, _} = context.reply
    assert World.cli_calls(context, "api") != []
    context
  end

  step "the Forgejo CLI has no credentials for the server after it renewed them", context do
    path = Path.join(Mc.tmp_dir(context.mc, "forgejo-renewed"), "keys.json")

    context =
      fj_storage_file(
        context,
        JSON.encode!(keys_map(%{"codeberg.org" => fj_host("gone-token")})),
        path
      )

    fj_installed(context, [
      whoami_rule("octocat", "printf '%s' '#{JSON.encode!(keys_map(%{}))}' > #{path}")
    ])
  end

  step "the Forgejo CLI holds an expired token for {string}", %{args: [server]} = context do
    path = Path.join(Mc.tmp_dir(context.mc, "forgejo-expired"), "keys.json")
    renewed = JSON.encode!(keys_map(%{server => fj_host("renewed-token")}))

    context =
      context
      |> fj_storage_file(JSON.encode!(keys_map(%{server => fj_host("expired-token")})), path)
      |> with_forgejo_api(%{
        "/api/v1/repos/acme/notes" => {200, repo_json("acme/notes", server)},
        "/api/v1/repos/acme/other" => {200, repo_json("acme/other", server)}
      })

    fj_installed(context, [whoami_rule("octocat", "printf '%s' '#{renewed}' > #{path}")])
  end

  step "the MC reads two repositories there within half a minute", context do
    {first, context} = lookup_forgejo(context, "acme/notes")
    {second, context} = lookup_forgejo(context, "acme/other")
    Map.put(context, :replies, [first, second])
  end

  step "the Forgejo CLI is asked to renew its token once", context do
    assert [_] = World.cli_calls(context, "whoami")
    context
  end

  step "both reads use the renewed token", context do
    assert Enum.all?(context.replies, &match?({:ok, _}, &1))
    requests = FakeHttp.requests(context.forgejo)
    assert length(requests) == 2
    assert Enum.all?(requests, &(&1["authorization"] == "token renewed-token"))
    context
  end

  step ~r/^the Forgejo CLI is signed in to "(?<server>[^"]+)" as "(?<login>[^"]+)"$/,
       %{args: [server, login]} = context do
    context
    |> with_forgejo_api(%{
      "/api/v1/user" => {200, %{"login" => login}},
      "/api/v1/repos/ada/notes" => {200, repo_json("ada/notes", server)},
      "/api/v1/repos/acme/notes" => {200, repo_json("acme/notes", server)}
    })
    |> fj_storage_file(JSON.encode!(keys_map(%{server => fj_host("ada-token")})))
    |> fj_installed([whoami_rule(login)])
  end

  step ~r/^the repository read is "(?<read>[^"]+)"$/, %{args: [read]} = context do
    if String.starts_with?(read, "nothing") do
      assert {:error, _, _} = context.reply

      assert World.failure(context) =~
               "Specify a Forgejo repository as owner/repository or its full server URL."

      assert FakeHttp.requests(context.forgejo) == []
    else
      assert {:ok, %{"nameWithOwner" => ^read}} = context.reply
      path = "/api/v1/repos/#{read}"
      assert Enum.any?(FakeHttp.requests(context.forgejo), &(&1["path"] == path))
    end

    context
  end

  # A server mounted under a path: fj cannot serve it, so the login is tea's.
  step ~r/^the Forgejo CLI is signed in to "(?<server>[^"]+\/[^"]+)"$/,
       %{args: [server]} = context do
    context
    |> no_fj()
    |> tea_logins([tea_login("forgejo", "https://#{server}", "true")], [
      tea_api_rule("forgejo", "https://#{server}", "acme/notes", server, "200 OK")
    ])
  end

  step ~r/^the MC reads the repository "(?<repository>[^"]+)" there$/,
       %{args: [repository]} = context do
    {reply, context} = lookup_forgejo(context, repository)
    Map.put(context, :reply, reply)
  end

  step ~r/^the request goes to the server's api below "(?<server>[^"]+)"$/,
       %{args: [server]} = context do
    assert [_ | _] = World.cli_calls(context, "https://#{server}/api/v1/repos/acme/notes")
    context
  end

  step ~r/^the repository is named "(?<name>[^"]+)" without the prefix$/,
       %{args: [name]} = context do
    assert {:ok, %{"nameWithOwner" => ^name}} = context.reply
    context
  end

  # fj is installed with a token for codeberg.org, so its own HTTP path serves the read.
  step ~r/^the repository is read through (?<cli>fj|tea)$/, %{args: [cli]} = context do
    case cli do
      "fj" ->
        context
        |> fj_storage_file(JSON.encode!(keys_map(%{"codeberg.org" => fj_host("ada-token")})))
        |> fj_installed()
        |> Map.put(:cli, :fj)

      "tea" ->
        no_fj(context)
    end
  end

  step ~r/^the Forgejo server answers with (?<answer>"[^"]+"(?: or "[^"]+")?)$/,
       %{args: [answer]} = context do
    status =
      case answer do
        "\"not found\"" -> "404 Not Found"
        "\"unauthorized\" or \"forbidden\"" -> "403 Forbidden"
        "\"too many requests\"" -> "429 Too Many Requests"
      end

    if Map.get(context, :cli) == :fj do
      {code, _} = Integer.parse(status)
      with_forgejo_api(context, %{"/api/v1/repos/acme/notes" => {code, %{"message" => status}}})
    else
      tea_logins(context, [tea_login("codeberg", "https://codeberg.org", "true")], [
        tea_api_rule("codeberg", "https://codeberg.org", "acme/notes", "codeberg.org", status)
      ])
    end
  end

  step "the MC reads a Forgejo repository", context do
    {reply, context} = lookup_forgejo(context, "acme/notes")

    # Only fj's own HTTP path leaves a request in the Forgejo API log.
    if Map.get(context, :cli) == :fj,
      do:
        assert(
          Enum.any?(
            FakeHttp.requests(context.forgejo),
            &(&1["path"] == "/api/v1/repos/acme/notes")
          )
        )

    Map.put(context, :reply, reply)
  end

  step "neither the Forgejo CLI nor the Gitea CLI is installed", context do
    World.put_app_env(:tea_command, "hal-c2-test-no-tea")
    no_fj(context)
  end

  step "the user is told to install the Forgejo CLI 0.6 or later or the Gitea CLI 0.16 or later",
       context do
    assert World.failure(context) =~
             "Install Forgejo CLI (`fj` 0.6 or later) or Gitea CLI (`tea` 0.16 or later)"

    context
  end

  # --- lookup and clone ----------------------------------------------------------

  step "the repository's name, web address and clone addresses are returned", context do
    assert {:ok, repository} = context.reply
    assert repository["nameWithOwner"] == context.looked_up
    [_owner, name] = String.split(context.looked_up, "/")
    assert repository["url"] =~ ~r{^https://.+/#{name}(\.git)?$}
    assert repository["sshUrl"] =~ ~r{^git@.+/#{name}(\.git)?$}
    context
  end

  step ~r/^the user clones "(?<repository>[^"]+)" from GitHub over (?<protocol>ssh|https)$/,
       %{args: [repository, protocol]} = context do
    bare = World.git_remote(context, World.git_repo(context, "shop"))
    urls = %{"sshUrl" => bare, "url" => "file://" <> bare}
    context = World.cli_rules(context, lookup_rule(repository, urls))
    dest = Path.join(Mc.tmp_dir(context.mc, "clones"), "shop")

    {reply, context} =
      World.call(context, "sourceControl.cloneRepository", %{
        "provider" => "github",
        "repository" => repository,
        "protocol" => protocol,
        "destinationPath" => dest
      })

    Map.merge(context, %{reply: reply, urls: urls, dest: dest})
  end

  step ~r/^the clone uses the repository's (?<protocol>ssh|https) address$/,
       %{args: [protocol]} = context do
    url = if protocol == "ssh", do: context.urls["sshUrl"], else: context.urls["url"]
    assert {:ok, %{"remoteUrl" => ^url, "cwd" => cwd}} = context.reply
    assert World.git!(cwd, ~w(remote get-url origin)) == url
    assert File.exists?(Path.join(cwd, "README.md"))
    context
  end

  step "the user clones without naming a repository or address", context do
    dest = Path.join(Mc.tmp_dir(context.mc, "clones"), "nothing")

    {reply, context} =
      World.call(context, "sourceControl.cloneRepository", %{"destinationPath" => dest})

    Map.put(context, :reply, reply)
  end

  # --- project clones --------------------------------------------------------------

  # The GitHub address is rewritten (git's `url.<base>.insteadOf`) to a local bare
  # repository, so the clone runs git's real transport and progress.
  step "the user adds a project by cloning {string}", %{args: [url]} = context do
    bare = World.git_remote(context, World.git_repo(context, "shop"))
    Shared.put_env("GIT_CONFIG_COUNT", "1")
    Shared.put_env("GIT_CONFIG_KEY_0", "url.file://#{bare}.insteadOf")
    Shared.put_env("GIT_CONFIG_VALUE_0", url)

    context
    |> start_clone(%{"remoteUrl" => url})
    |> Map.put(:remote_url, url)
  end

  step "the project appears straight away", context do
    assert {:ok, %{"projectId" => id, "cwd" => cwd}} = context.reply
    row = World.await_row(id, & &1)
    assert row["workspaceRoot"] == cwd
    assert File.dir?(cwd)
    context
  end

  step "the clone's progress is streamed until the files are in place", context do
    id = context.clone_id
    done = await_clones(&match?(%{"phase" => "done"}, clone(&1, id)))
    seen = Process.get(:clone_snapshots, [])
    stages = for list <- seen, %{"stage" => stage} <- [clone(list, id)], uniq: true, do: stage
    assert "receiving" in stages, "no progress was streamed: #{inspect(stages)}"
    assert %{"percent" => 100, "remoteUrl" => url} = clone(done, id)
    assert url == context.remote_url
    assert File.exists?(Path.join(context.dest, "README.md"))
    context
  end

  # The host answers with an address whose transport (`git-remote-hal_c2_hang`) never
  # replies, so the clone stays connecting until it is cancelled.
  step "a clone of {string} is in progress", %{args: [repository]} = context do
    context = World.fake_cli(context, ["gh"])
    helper = Path.join(context.cli.bin, "git-remote-hal_c2_hang")
    File.write!(helper, "#!/bin/sh\nexec cat > /dev/null\n")
    File.chmod!(helper, 0o755)
    url = "hal_c2_hang::#{repository}"

    context
    |> World.cli_rules(lookup_rule(repository, %{"url" => url, "sshUrl" => url}))
    |> start_clone(%{"repository" => repository, "protocol" => "https"})
    |> tap(
      &await_clones(fn list -> match?(%{"phase" => "running"}, clone(list, &1.clone_id)) end)
    )
    |> Map.put(:cancel, fn context ->
      {reply, context} =
        World.call(context, "projectClone.cancel", %{"projectId" => context.clone_id})

      Map.put(context, :reply, reply)
    end)
  end

  step "the clone stops and is reported as cancelled", context do
    assert {:ok, %{"applied" => true}} = context.reply
    id = context.clone_id
    list = await_clones(&match?(%{"phase" => "cancelled"}, clone(&1, id)))
    assert %{"endedAt" => ended} = clone(list, id)
    assert is_binary(ended)
    # Cancelling again finds nothing running.
    {reply, context} = World.call(context, "projectClone.cancel", %{"projectId" => id})
    assert reply == {:ok, %{"applied" => false}}
    context
  end

  # The host's address points at a repository that is not reachable yet.
  step "the clone of {string} failed because the network dropped",
       %{args: [repository]} = context do
    context = failed_clone(context, repository)
    # The network is back: the host's repository can be reached again.
    World.git_remote(context, World.git_repo(context, "shop")) |> File.rename!(context.bare)
    context
  end

  step "the user retries it", context do
    if context[:planner] do
      HalC2.Steps.Planning.Planner.retry(context)
    else
      {reply, context} =
        World.call(context, "projectClone.retry", %{"projectId" => context.clone_id})

      Map.put(context, :reply, reply)
    end
  end

  step "the clone starts again into the same project", context do
    assert {:ok, %{"applied" => true}} = context.reply
    id = context.clone_id
    list = await_clones(&match?(%{"phase" => "done"}, clone(&1, id)))
    assert clone(list, id)["destinationPath"] == context.dest
    assert File.exists?(Path.join(context.dest, "README.md"))
    context
  end

  step "one clone finished and another failed", context do
    context = failed_clone(context, "acme/broken")
    failed = %{id: context.clone_id, dest: context.dest, bare: context.bare}
    bare = World.git_remote(context, World.git_repo(context, "shop"))
    context = start_clone(context, %{"remoteUrl" => bare})
    done_id = context.clone_id
    await_clones(&match?(%{"phase" => "done"}, clone(&1, done_id)))
    Map.merge(context, %{done_id: done_id, failed: failed})
  end

  # A finished clone is forgotten when its timer (`@forget_done_after`) fires; the
  # step delivers that timer's message now, to every clone, instead of waiting.
  step "some time passes", context do
    flush_clones()
    for id <- [context.done_id, context.failed.id], do: send(HalC2.ProjectClones, {:forget, id})
    context
  end

  step "the finished clone is no longer reported", context do
    list = await_clones(&(clone(&1, context.done_id) == nil))
    assert %{"phase" => "failed"} = clone(list, context.failed.id)
    context
  end

  step "the failed clone is still reported until it is retried", context do
    %{id: id, bare: bare} = context.failed
    {:ok, list} = HalC2.ProjectClones.subscribe(self())
    assert %{"phase" => "failed"} = clone(list, id)
    World.git_remote(context, World.git_repo(context, "broken")) |> File.rename!(bare)

    {{:ok, %{"applied" => true}}, context} =
      World.call(context, "projectClone.retry", %{"projectId" => id})

    await_clones(&match?(%{"phase" => phase} when phase in ["running", "done"], clone(&1, id)))
    context
  end

  # --- publish ---------------------------------------------------------------------

  step "the project {string} is a git repository with commits and no remote",
       %{args: [title]} = context do
    context = World.create_project(context, title)
    root = World.project(context, title).root
    assert World.git!(root, ~w(remote)) == ""
    Map.put(context, :cwd, root)
  end

  step "the project {string} is a git repository with no commits", %{args: [title]} = context do
    root = Mc.tmp_dir(context.mc, World.slug(title))
    World.git!(root, ~w(init -q -b main))
    context = World.create_project(context, title, %{"workspaceRoot" => root})
    Map.put(context, :cwd, root)
  end

  step ~r/^the user publishes "(?<title>[^"]+)" to (?<host>GitHub|GitLab)(?: as a (?<visibility>private|public) repository)?$/,
       %{args: [title, host | rest]} = context do
    publish(context, title, host, List.first(rest) || "private", "https")
  end

  # Both addresses of the new repository are local bare repositories, so each protocol
  # can be checked against the address it was given.
  step ~r/^the user publishes "(?<title>[^"]+)" to GitHub choosing (?<protocol>https|ssh)$/,
       %{args: [title, protocol]} = context do
    publish(context, title, "GitHub", "private", protocol)
  end

  step ~r/^the remote added to "(?<title>[^"]+)" uses the (?<protocol>https|ssh) address of the new repository$/,
       %{args: [_title, protocol]} = context do
    expected = if protocol == "ssh", do: context.published.ssh_bare, else: context.published.bare
    assert World.git!(context.cwd, ~w(remote get-url origin)) == expected
    context
  end

  step ~r/^the repository is created on (?:GitHub|GitLab) as (?<visibility>private|public)$/,
       %{args: [visibility]} = context do
    assert_created(context, visibility)
  end

  step "the repository is created and added as the remote", context do
    context = assert_created(context, "private")
    assert World.git!(context.cwd, ~w(remote get-url origin)) == context.published.bare
    context
  end

  step "it is added as the remote and the current branch is pushed and tracked", context do
    %{bare: bare} = context.published
    assert {:ok, %{"status" => "pushed", "upstreamBranch" => "origin/main"}} = context.reply
    assert World.git!(context.cwd, ~w(remote get-url origin)) == bare
    assert World.git!(context.cwd, ~w(rev-parse --abbrev-ref main@{upstream})) == "origin/main"
    assert World.git!(bare, ~w(rev-parse main)) == World.git!(context.cwd, ~w(rev-parse HEAD))
    context
  end

  step "the result says the remote was added without pushing", context do
    assert {:ok, %{"status" => "remote_added"} = result} = context.reply
    refute Map.has_key?(result, "upstreamBranch")
    assert World.git!(context.published.bare, ~w(for-each-ref)) == ""
    context
  end

  # --- helpers -------------------------------------------------------------------

  defp discovered(context, label) do
    %{"versionControlSystems" => vcs, "sourceControlProviders" => providers} = context.discovery
    Enum.find(vcs ++ providers, &(&1["label"] == label)) || flunk("#{label} was not reported")
  end

  defp lookup_rule(repository, urls),
    do: %{
      "cmd" => "gh",
      "args" => ["repo view #{repository} "],
      "stdout" => Map.put(urls, "nameWithOwner", repository)
    }

  defp host_name("github"), do: "github.com"
  defp host_name("gitlab"), do: "gitlab.com"

  defp publish(context, title, host, visibility, protocol) do
    provider = Shared.provider(host)
    repository = "acme/" <> World.slug(title)
    dir = Mc.tmp_dir(context.mc, "published")
    bare = Path.join(dir, "#{World.slug(title)}.git")
    ssh_bare = Path.join(dir, "#{World.slug(title)}-ssh.git")
    exe = if provider == "github", do: "gh", else: "glab"

    context =
      context
      |> World.fake_cli(["gh", "glab"])
      |> World.cli_rules([
        # The host's new, empty repository.
        %{
          "cmd" => exe,
          "args" => ["repo create #{repository}"],
          "run" => "git init -q --bare #{bare} && git init -q --bare #{ssh_bare}",
          "stdout" => "https://#{host_name(provider)}/#{repository}\n"
        }
      ])
      |> Shared.answer_lookup(provider, repository, %{"url" => bare, "sshUrl" => ssh_bare})

    {reply, context} =
      World.call(context, "sourceControl.publishRepository", %{
        "cwd" => World.project(context, title).root,
        "provider" => provider,
        "repository" => repository,
        "visibility" => visibility,
        "protocol" => protocol
      })

    Map.merge(context, %{
      reply: reply,
      published: %{exe: exe, repository: repository, bare: bare, ssh_bare: ssh_bare}
    })
  end

  # Bitbucket: the environment is cleared, and restored when the scenario ends.
  defp unset_env(name) do
    previous = System.get_env(name)
    System.delete_env(name)
    ExUnit.Callbacks.on_exit(fn -> if previous, do: System.put_env(name, previous) end)
  end

  defp start_fake_bitbucket_api(context) do
    server = Mc.ensure({Bandit, plug: FakeBitbucket, port: 0, ip: :loopback})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    Shared.put_env("HAL_C2_BITBUCKET_API_BASE_URL", "http://127.0.0.1:#{port}/2.0")
    context
  end

  defp assert_bitbucket_unknown(context, detail) do
    item = discovered(context, "Bitbucket")
    assert item["auth"]["status"] == "unknown"
    assert item["auth"]["detail"] == %{"_tag" => "Some", "value" => detail}
    item
  end

  # Forgejo logins. fj's logins come from its keys (`keys_map/2`); tea's from its list.
  defp hold_logins(context, phrase) do
    git = "https://git.example.com"

    case phrase do
      "one login for \"git.example.com\"" ->
        context
        |> no_fj()
        |> tea_logins([tea_login("git", git, "false")])
        |> Map.put(:expected_login, "git")

      "one login for \"git.example.com\" with the SSH alias \"ssh.example\"" ->
        keys =
          keys_map(%{"git.example.com" => fj_host("alias-token")}, %{
            "ssh.example" => "git.example.com"
          })

        context
        |> fj_storage_file(JSON.encode!(keys))
        |> fj_installed([whoami_rule("octocat")])
        |> tea_logins([])
        |> Map.put(:expected_login, "git.example.com")

      "two logins for \"git.example.com\", one of them the default" ->
        context
        |> no_fj()
        |> tea_logins([tea_login("work", git, "false"), tea_login("home", git, "true")])
        |> Map.put(:expected_login, "home")

      "two logins for \"git.example.com\", neither the default" ->
        no_fj(context)
        |> tea_logins([tea_login("work", git, "false"), tea_login("home", git, "false")])

      "logins for two servers" ->
        no_fj(context)
        |> tea_logins([
          tea_login("one", git, "false"),
          tea_login("two", "https://other.example.com", "false")
        ])

      "a login for \"git.example.com/forgejo\"" ->
        no_fj(context)
        |> tea_logins([tea_login("forgejo", git <> "/forgejo", "false")])
    end
  end

  defp remote_address(remote) do
    case remote do
      "an https address on \"git.example.com\"" -> "https://git.example.com/acme/notes.git"
      "an SSH address on \"ssh.example\"" -> "git@ssh.example:acme/notes.git"
      "an https address on a third server" -> "https://third.example.com/acme/notes.git"
      "an address on \"git.example.com/other\"" -> "https://git.example.com/other/acme/notes.git"
    end
  end

  # fj uninstalled, and its storage a file that does not exist.
  defp no_fj(context) do
    context
    |> with_fj_storage(Path.join(Mc.tmp_dir(context.mc, "forgejo-none"), "keys.json"))
    |> fj_missing()
  end

  defp fj_missing(context) do
    World.put_app_env(:fj_command, "hal-c2-test-no-fj")
    context
  end

  defp with_fj_storage(context, path) do
    World.put_app_env(:fj_keys_paths, [path])
    context
  end

  # fj's storage holds `json` (or, given a path, is written there).
  defp fj_storage_file(context, json, path \\ nil) do
    path = path || Path.join(Mc.tmp_dir(context.mc, "forgejo-keys"), "keys.json")
    File.write!(path, json)

    context
    |> with_fj_storage(path)
    |> Map.put(:keys_path, path)
  end

  defp fj_installed(context, rules \\ []) do
    context
    |> World.fake_cli(["fj"])
    |> World.cli_rules([
      %{"cmd" => "fj", "args" => ["version"], "stdout" => "fj v0.6.0\n"} | rules
    ])
  end

  defp whoami_rule(account, run \\ nil) do
    rule = %{"cmd" => "fj", "args" => ["whoami"], "stdout" => "#{account}\n"}
    if run, do: Map.put(rule, "run", run), else: rule
  end

  defp tea_logins(context, logins, extra \\ []) do
    context
    |> World.fake_cli(["tea"])
    |> World.cli_rules([
      %{"cmd" => "tea", "args" => ["--version"], "stdout" => "Version: 0.10.1\n"},
      %{"cmd" => "tea", "args" => ["login list"], "stdout" => logins} | extra
    ])
  end

  defp tea_login(name, url, default) do
    %{"name" => name, "url" => url, "user" => "octocat", "default" => default, "valid" => "true"}
  end

  defp tea_api_rule(login, base, repository, host, status) do
    %{
      "cmd" => "tea",
      "args" => ["api", "--login #{login}", "#{base}/api/v1/repos/#{repository}"],
      "stderr" => "HTTP/2.0 #{status}\n",
      "stdout" =>
        if(String.starts_with?(status, "200"), do: repo_json(repository, host), else: %{})
    }
  end

  defp keys_map(hosts, aliases \\ %{}), do: %{"hosts" => hosts, "aliases" => aliases}

  defp fj_host(token), do: %{"type" => "Application", "token" => token}

  defp repo_json(repository, host) do
    %{
      "full_name" => repository,
      "clone_url" => "https://#{host}/#{repository}.git",
      "ssh_url" => "git@#{host}:#{repository}.git"
    }
  end

  # The server the Forgejo API calls reach (`HAL_C2_FORGEJO_API_BASE_URL`); `:forgejo`
  # is the log of its requests.
  defp with_forgejo_api(context, routes) do
    {base, log} = FakeHttp.start(routes)
    Shared.put_env("HAL_C2_FORGEJO_API_BASE_URL", base)
    Map.put(context, :forgejo, log)
  end

  defp lookup_forgejo(context, repository) do
    World.call(context, "sourceControl.lookupRepository", %{
      "provider" => "forgejo",
      "repository" => repository
    })
  end

  defp assert_created(context, visibility) do
    %{exe: exe, repository: repository} = context.published

    assert [%{"cmd" => ^exe}] =
             World.cli_calls(context, "repo create #{repository} --#{visibility}"),
           "#{exe} did not create #{repository} as #{visibility}: #{inspect(World.cli_calls(context, "repo create"))}"

    context
  end

  # Starts a project clone of `source` into a new folder, following its snapshots.
  defp start_clone(context, source) do
    Mc.ensure(HalC2.ProjectClones)
    {:ok, _} = HalC2.ProjectClones.subscribe(self())
    id = "clone-#{System.unique_integer([:positive])}"
    dest = Path.join(Mc.tmp_dir(context.mc, "clones"), id)

    {reply, context} =
      World.call(
        context,
        "projectClone.start",
        Map.merge(
          %{
            "projectId" => id,
            "title" => "shop",
            "createdAt" => World.iso_from_now(0),
            "destinationPath" => dest
          },
          source
        )
      )

    assert {:ok, _} = reply
    Map.merge(context, %{reply: reply, clone_id: id, dest: dest})
  end

  defp failed_clone(context, repository) do
    bare = Path.join(Mc.tmp_dir(context.mc, "unreachable"), "shop.git")

    context =
      World.cli_rules(context, lookup_rule(repository, %{"url" => bare, "sshUrl" => bare}))

    context = start_clone(context, %{"repository" => repository, "protocol" => "https"})
    id = context.clone_id
    await_clones(&match?(%{"phase" => "failed"}, clone(&1, id)))
    Map.put(context, :bare, bare)
  end

  defp clone(list, id), do: Enum.find(list, &(&1["projectId"] == id))

  # The next snapshot list (from the subscription) for which `fun` holds; every list
  # seen is kept in the process dictionary.
  defp await_clones(fun) do
    receive do
      {:hal_c2_project_clones, _node, list} ->
        Process.put(:clone_snapshots, Process.get(:clone_snapshots, []) ++ [list])
        if fun.(list), do: list, else: await_clones(fun)
    after
      10_000 ->
        flunk(
          "no clone snapshot matched; last: #{inspect(List.last(Process.get(:clone_snapshots, [])))}"
        )
    end
  end

  defp flush_clones do
    receive do
      {:hal_c2_project_clones, _node, _list} -> flush_clones()
    after
      0 -> :ok
    end
  end
end
