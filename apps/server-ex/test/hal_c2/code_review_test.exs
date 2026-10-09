defmodule HalC2.CodeReviewTest do
  @moduledoc """
  Regressions in the code-review plugin's MC process (`plugins/code-review/mc`), loaded
  and enabled through `HalC2.Plugins` as a user installs it, against a fake GitHub
  (`test/support/fake_gh.py`), a fake remote served over a fake `GIT_SSH_COMMAND`, and
  the fake Codex. They came out of the property model in
  `prop/hal_c2/code_review_prop_test.exs`.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @id "code-review"
  @server HalC2Plugins.CodeReview
  @key "acme/api#1"
  @package Path.expand("../../../../plugins/code-review", __DIR__)
  @support Path.expand("../support", __DIR__)
  @git_config ~w(GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_GLOBAL)

  setup %{tmp_dir: dir} do
    restore = [
      env(~w(PATH FAKE_GH_RULES FAKE_GH_LOG GIT_SSH_COMMAND FAKE_CODEX_GATE) ++ @git_config),
      app(~w(home gh_command codex_command settings_check_ms)a)
    ]

    on_exit(fn ->
      # The fake Codex turn still open ends, and its process with it.
      File.write(Path.join(dir, "gate/answer"), "")
      Enum.each(restore, & &1.())
    end)

    shas = remote!(dir)
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    File.ln_s!(Path.join(@support, "fake_gh.py"), Path.join(bin, "gh"))
    ssh = Path.join(dir, "fake-ssh")

    # Serves `git@github.com:acme/api.git` from `remotes/`; while `fetch.hold` exists a
    # fetch waits, and says so in `fetch.held`.
    File.write!(ssh, """
    #!/bin/sh
    for last; do :; done
    if [ -e '#{dir}/fetch.hold' ]; then
      touch '#{dir}/fetch.held'
      while [ -e '#{dir}/fetch.hold' ]; do sleep 0.05; done
    fi
    cd '#{dir}/remotes' && exec sh -c "$last"
    """)

    File.chmod!(ssh, 0o755)
    File.mkdir_p!(Path.join(dir, "gate"))
    System.put_env("PATH", bin <> ":" <> System.get_env("PATH"))
    System.put_env("FAKE_GH_RULES", Path.join(dir, "rules.json"))
    System.put_env("FAKE_GH_LOG", Path.join(dir, "gh.log"))
    System.put_env("GIT_SSH_COMMAND", ssh)
    # The plugin fetches GitHub over HTTPS, which the fake remote answers over SSH.
    System.put_env(%{
      "GIT_CONFIG_COUNT" => "1",
      "GIT_CONFIG_KEY_0" => "url.git@github.com:.insteadOf",
      "GIT_CONFIG_VALUE_0" => "https://github.com/"
    })

    # A user's own rewrite of the address, which the plugin's clone does not read.
    global = Path.join(dir, "gitconfig")
    File.write!(global, "[url \"#{dir}/nowhere/\"]\n\tinsteadOf = https://github.com/acme/\n")
    System.put_env("GIT_CONFIG_GLOBAL", global)

    System.put_env("FAKE_CODEX_GATE", Path.join(dir, "gate"))
    Application.put_env(:hal_c2, :home, Path.join(dir, "home"))
    Application.put_env(:hal_c2, :gh_command, "gh")

    Application.put_env(:hal_c2, :codex_command, [
      "python3",
      "-u",
      Path.join(@support, "fake_codex.py")
    ])

    Application.put_env(:hal_c2, :settings_check_ms, nil)
    context = %{dir: dir, shas: shas}
    rules!(context, head: 1)

    for child <- [
          {HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")},
          HalC2.Settings,
          HalC2.Streams,
          HalC2.Shell,
          HalC2.Orchestration.TurnWatch,
          {Registry, keys: :unique, name: HalC2.Codex.Registry},
          Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Claude.Registry},
            id: :claude_registry
          ),
          Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Acp.Registry},
            id: :acp_registry
          ),
          Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Pi.Registry},
            id: :pi_registry
          ),
          {DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one},
          HalC2.Mcp,
          Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Vcs.Registry},
            id: :vcs_registry
          ),
          {DynamicSupervisor, name: HalC2.Vcs.Supervisor, strategy: :one_for_one},
          HalC2.PullRequests.Refreshes,
          HalC2.Plugins
        ],
        do: start_supervised!(child)

    root = Path.join(dir, "api")
    git!(dir, ["clone", "-q", Path.join(dir, "remotes/acme/api.git"), root])
    git!(root, ["remote", "set-url", "origin", "git@github.com:acme/api.git"])
    :ok = HalC2.Shell.subscribe(self())

    {:ok, _} =
      HalC2.Projects.mutate(%{
        "type" => "project.create",
        "projectId" => "api",
        "title" => "api",
        "workspaceRoot" => root
      })

    assert_receive {:hal_c2_shell, {:rows, _, [{"api", _}]}}, 1_000
    {:ok, nil} = HalC2.PullRequests.invalidate(%{})

    plugins = Path.join(HalC2.Paths.data_dir(), "plugins")
    File.mkdir_p!(plugins)
    File.cp_r!(@package, Path.join(plugins, @id))
    {:ok, _} = HalC2.Plugins.handle("rescan", %{})
    {:ok, %{"plugins" => listed}} = HalC2.Plugins.handle("list", %{})
    permissions = Enum.find(listed, &(&1["id"] == @id))["permissions"] |> Enum.map(& &1["id"])
    {:ok, _} = HalC2.Plugins.handle("enable", %{"id" => @id, "acceptPermissions" => permissions})

    {:ok, _} =
      HalC2.Plugins.handle("saveSettings", %{
        "id" => @id,
        "settings" => %{
          "provider" => "codex",
          "model" => "fake/one",
          "prompt" => "Review \#{{pr.number}} in {{repository}}. answer from gate",
          "pollMinutes" => 60,
          "repositories" => ["acme/api"],
          "activation" => "selective",
          "publishing" => "draft",
          "reviewNewPushes" => false,
          "readReviewMd" => false
        }
      })

    settle()
    context
  end

  test "a look still waiting on GitHub ends when code-review is turned off", context do
    hold = Path.join(context.dir, "list.hold")
    File.write!(hold, "")
    on_exit(fn -> File.rm(hold) end)

    rules!(context,
      head: 1,
      list: "touch '#{context.dir}/list.held'; while [ -e '#{hold}' ]; do sleep 0.05; done"
    )

    send(@server, :poll)
    await_file(Path.join(context.dir, "list.held"))
    {:monitors, [{:process, look} | _]} = Process.info(Process.whereis(@server), :monitors)
    ref = Process.monitor(look)

    {:ok, _} = HalC2.Plugins.handle("disable", %{"id" => @id})

    assert_receive {:DOWN, ^ref, :process, _, _}, 1_000
  end

  test "a head pushed back to the commit reviewed is no longer changed since the review",
       context do
    review = start_review()

    {:ok, _} =
      HalC2.Plugins.call_tool(
        "code_review_report",
        %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []},
        review["threadId"]
      )

    rules!(context, head: 2)
    refresh()
    assert %{"changed" => true} = review()

    rules!(context, head: 1)
    refresh()
    assert %{"changed" => false, "headSha" => head} = review()
    assert head == context.shas[1]
  end

  test "a push while the checkout of a review is fetched leaves the review at the head it saw last",
       context do
    hold = Path.join(context.dir, "fetch.hold")
    File.write!(hold, "")
    on_exit(fn -> File.rm(hold) end)
    second = context.shas[2]
    {:ok, _} = call("start", %{"repository" => "acme/api", "number" => 1})
    await_file(Path.join(context.dir, "fetch.held"))

    push!(context, 2)
    rules!(context, head: 2)
    {:ok, _} = call("refresh", %{})
    await_look()
    assert %{"status" => "running", "headSha" => ^second} = review()
    File.rm!(hold)
    settle()

    assert %{"status" => "running", "reviewedSha" => ^second, "headSha" => ^second} = review()
  end

  test "a review asked for before its pull request is listed starts at the head of the pull request",
       context do
    rules!(context, head: 1, listed: false)
    refresh()
    assert review() == nil
    hold = Path.join(context.dir, "fetch.hold")
    File.write!(hold, "")
    on_exit(fn -> File.rm(hold) end)
    first = context.shas[1]
    {:ok, _} = call("start", %{"repository" => "acme/api", "number" => 1})
    await_file(Path.join(context.dir, "fetch.held"))

    assert %{"status" => "running", "headSha" => ^first} = review()
    File.rm!(hold)
    settle()
  end

  # --- helpers ----------------------------------------------------------------------------

  defp start_review do
    {:ok, _} = call("start", %{"repository" => "acme/api", "number" => 1})
    settle()
    assert %{"status" => "running", "checkout" => checkout} = review = review()
    assert File.dir?(checkout)
    review
  end

  defp call(method, input),
    do: HalC2.Plugins.handle("call", %{"id" => @id, "method" => method, "input" => input})

  defp refresh do
    {:ok, _} = call("refresh", %{})
    settle()
  end

  defp review do
    GenServer.call(@server, :snapshot)["reviews"] |> Enum.find(&(&1["key"] == @key))
  end

  # Returns once the plugin has nothing in flight and has heard from what ended.
  defp settle do
    pid = Process.whereis(@server)
    state = :sys.get_state(pid)
    {:parent, parent} = Process.info(pid, :parent)
    {:links, links} = Process.info(pid, :links)

    poller =
      case Process.info(pid, :monitors) do
        {:monitors, [{:process, poller} | _]} when state.polling != nil -> [poller]
        _ -> []
      end

    case Enum.filter(links, &(is_pid(&1) and &1 != parent)) ++ poller do
      [] ->
        :sys.get_state(pid)
        :ok

      kids ->
        refs = Enum.map(kids, &Process.monitor/1)
        assert_receive {:DOWN, ref, :process, _, _} when is_reference(ref), 15_000
        Enum.each(refs, &Process.demonitor(&1, [:flush]))
        settle()
    end
  end

  # Returns once the look for pull requests under way, if any, is applied.
  defp await_look do
    pid = Process.whereis(@server)

    with %{polling: polling} when polling != nil <- :sys.get_state(pid),
         {:monitors, [{:process, look} | _]} <- Process.info(pid, :monitors) do
      ref = Process.monitor(look)
      assert_receive {:DOWN, ^ref, :process, _, _}, 15_000
    end

    :sys.get_state(pid)
  end

  defp await_file(path) do
    {_, 0} =
      System.cmd("timeout", ["5", "sh", "-c", "until [ -e '#{path}' ]; do sleep 0.05; done"])
  end

  # The fake GitHub: pull request #1 of acme/api open at head commit `head`, listed
  # unless `listed: false`; `list` runs while it is listed.
  defp rules!(context, opts) do
    pr = %{
      "number" => 1,
      "title" => "Limits",
      "url" => "https://github.com/acme/api/pull/1",
      "author" => %{"login" => "octocat"},
      "headRefName" => "feature/1",
      "baseRefName" => "main",
      "state" => "OPEN",
      "isDraft" => false,
      "createdAt" => "2026-09-01T00:00:00Z",
      "updatedAt" => "2026-09-01T00:00:00Z",
      "reviewRequests" => [],
      "latestReviews" => [],
      "labels" => [],
      "statusCheckRollup" => [],
      "headRefOid" => context.shas[opts[:head]],
      "additions" => 2,
      "deletions" => 0
    }

    listing = if opts[:listed] == false, do: [], else: [pr]
    list = %{"args" => ["pr list", "--repo github.com/acme/api"], "stdout" => listing}
    list = if opts[:list], do: Map.put(list, "run", opts[:list]), else: list

    rules = [
      %{"args" => ["api user"], "stdout" => %{"id" => 7, "login" => "monalisa"}},
      list,
      # Pull request #1 read on its own, as asking for its review reads it.
      %{
        "args" => ["api graphql"],
        "stdin" => ["viewerCanUpdateBranch"],
        "stdout" => %{
          "data" => %{
            "repository" => %{
              "viewerPermission" => "WRITE",
              "pullRequest" =>
                Map.merge(pr, %{
                  "body" => "",
                  "changedFiles" => 1,
                  "isCrossRepository" => false,
                  "baseRef" => %{"compare" => %{"behindBy" => 0}},
                  "labels" => %{"nodes" => []},
                  "reviewRequests" => %{"nodes" => []},
                  "commits" => %{"nodes" => []}
                })
            }
          }
        }
      },
      %{
        "args" => ["api graphql"],
        "stdin" => ["viewerCanUpdate viewerDidAuthor }"],
        "stdout" => %{
          "data" => %{
            "repository" => %{
              "mergeCommitAllowed" => true,
              "squashMergeAllowed" => true,
              "rebaseMergeAllowed" => true,
              "viewerPermission" => "WRITE",
              "pullRequest" => %{"viewerCanUpdate" => true, "viewerDidAuthor" => false}
            }
          }
        }
      }
    ]

    File.write!(Path.join(context.dir, "rules.json"), JSON.encode!(rules))
  end

  # `remotes/acme/api.git`: `main`, and two head commits of pull request #1 off it,
  # the first at `refs/pull/1/head`. Returns `%{1 => sha, 2 => sha}`.
  defp remote!(dir) do
    bare = Path.join(dir, "remotes/acme/api.git")
    File.mkdir_p!(Path.dirname(bare))
    git!(dir, ["init", "-q", "--bare", "-b", "main", bare])
    seed = Path.join(dir, "seed")
    git!(dir, ["init", "-q", "-b", "main", seed])
    File.write!(Path.join(seed, "README.md"), "# api\n")
    git!(seed, ["add", "README.md"])
    git!(seed, ["commit", "-q", "-m", "Start"])
    git!(seed, ["push", "-q", bare, "main:main"])

    shas =
      Map.new(1..2, fn i ->
        File.mkdir_p!(Path.join(seed, "src"))
        File.write!(Path.join(seed, "src/limits.ts"), "export const limit = #{i};\n")
        git!(seed, ["add", "src/limits.ts"])
        git!(seed, ["commit", "-q", "-m", "Limit #{i}"])
        {i, git!(seed, ["rev-parse", "HEAD"])}
      end)

    git!(seed, ["push", "-q", bare, "#{shas[2]}:refs/fixtures/2", "#{shas[1]}:refs/pull/1/head"])
    shas
  end

  defp push!(context, i) do
    bare = Path.join(context.dir, "remotes/acme/api.git")
    git!(context.dir, ["--git-dir", bare, "update-ref", "refs/pull/1/head", context.shas[i]])
  end

  defp git!(dir, args) do
    config = ~w(-c user.name=Test -c user.email=test@example.com -c commit.gpgsign=false)
    {out, 0} = System.cmd("git", config ++ args, cd: dir, stderr_to_stdout: true)
    String.trim(out)
  end

  defp env(vars) do
    previous = Map.new(vars, &{&1, System.get_env(&1)})

    fn ->
      for {var, value} <- previous,
          do: if(value, do: System.put_env(var, value), else: System.delete_env(var))
    end
  end

  defp app(keys) do
    previous = Map.new(keys, &{&1, Application.fetch_env(:hal_c2, &1)})

    fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:hal_c2, key, value)
          :error -> Application.delete_env(:hal_c2, key)
        end
      end
    end
  end
end
