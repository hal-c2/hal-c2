defmodule HalC2.Steps.SourceControl.RepositoryDiscoveryClonePublish do
  @moduledoc """
  Steps for `features/source-control/repository-discovery-clone-publish.feature`:
  tool discovery against fake host CLIs, lookups, clones from local bare
  repositories, project clones (`HalC2.ProjectClones`) and publishing.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.SourceControl.Shared
  alias HalC2.Test.Node
  alias HalC2.Test.Node.World

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

  step "git is installed and signed in on the node's machine", context do
    {version, 0} = System.cmd("git", ["--version"])
    Map.merge(context, %{tool: "Git", version: String.trim(version), account: nil})
  end

  step ~r/^(?<tool>jj|gh|glab|tea|az) is installed and signed in on the node's machine$/,
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

  step "the node was started with a Bitbucket access token in its environment", context do
    Shared.fake_bitbucket(context)
  end

  step "Bitbucket is reported available and signed in", context do
    item = discovered(context, "Bitbucket")
    assert item["status"] == "available"
    assert item["auth"]["status"] == "authenticated"
    assert item["auth"]["account"] == %{"_tag" => "Some", "value" => "octocat"}
    context
  end

  # fj's keys.json names the server without a scheme; a server under a subpath keeps
  # its path, which fj 0.6 cannot serve. The account lookup after `whoami` finds
  # nothing listening, which leaves fj reported with an unknown account.
  step ~r/^both fj and tea are installed and fj holds a login for "(?<server>[^"]+)"$/,
       %{args: [server]} = context do
    server = if server == "codeberg.org", do: "127.0.0.1:1", else: server
    keys = Path.join(Node.tmp_dir(context.node, "forgejo-cli"), "keys.json")

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
    dest = Path.join(Node.tmp_dir(context.node, "clones"), "shop")

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
    dest = Path.join(Node.tmp_dir(context.node, "clones"), "nothing")

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
    {reply, context} =
      World.call(context, "projectClone.retry", %{"projectId" => context.clone_id})

    Map.put(context, :reply, reply)
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
    root = Node.tmp_dir(context.node, World.slug(title))
    World.git!(root, ~w(init -q -b main))
    context = World.create_project(context, title, %{"workspaceRoot" => root})
    Map.put(context, :cwd, root)
  end

  step ~r/^the user publishes "(?<title>[^"]+)" to (?<host>GitHub|GitLab)(?: as a (?<visibility>private|public) repository)?$/,
       %{args: [title, host | rest]} = context do
    visibility = List.first(rest) || "private"
    provider = Shared.provider(host)
    repository = "acme/" <> World.slug(title)
    bare = Path.join(Node.tmp_dir(context.node, "published"), "#{World.slug(title)}.git")
    exe = if provider == "github", do: "gh", else: "glab"

    context =
      context
      |> World.fake_cli(["gh", "glab"])
      |> World.cli_rules([
        # The host's new, empty repository.
        %{
          "cmd" => exe,
          "args" => ["repo create #{repository}"],
          "run" => "git init -q --bare #{bare}",
          "stdout" => "https://#{host_name(provider)}/#{repository}\n"
        }
      ])
      |> Shared.answer_lookup(provider, repository, %{"url" => bare, "sshUrl" => bare})

    {reply, context} =
      World.call(context, "sourceControl.publishRepository", %{
        "cwd" => World.project(context, title).root,
        "provider" => provider,
        "repository" => repository,
        "visibility" => visibility,
        "protocol" => "https"
      })

    Map.merge(context, %{
      reply: reply,
      published: %{exe: exe, repository: repository, bare: bare}
    })
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

  defp assert_created(context, visibility) do
    %{exe: exe, repository: repository} = context.published

    assert [%{"cmd" => ^exe}] =
             World.cli_calls(context, "repo create #{repository} --#{visibility}"),
           "#{exe} did not create #{repository} as #{visibility}: #{inspect(World.cli_calls(context, "repo create"))}"

    context
  end

  # Starts a project clone of `source` into a new folder, following its snapshots.
  defp start_clone(context, source) do
    Node.ensure(HalC2.ProjectClones)
    {:ok, _} = HalC2.ProjectClones.subscribe(self())
    id = "clone-#{System.unique_integer([:positive])}"
    dest = Path.join(Node.tmp_dir(context.node, "clones"), id)

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
    bare = Path.join(Node.tmp_dir(context.node, "unreachable"), "shop.git")

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
