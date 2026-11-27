defmodule HalC2.CodeReviewTest do
  @moduledoc """
  Regressions in the code-review plugin's MC process (`plugins/code-review/mc`), loaded
  and enabled through `HalC2.Plugins` as a user installs it, against a fake GitHub
  (`test/support/fake_gh.py`), a fake remote served over a fake `GIT_SSH_COMMAND`, and
  the fake Codex. They came out of the property model in
  `prop/hal_c2/code_review_prop_test.exs`.
  """
  use ExUnit.Case, async: false

  alias HalC2.Test.{FakeOpenShell, FakeSandbox}

  @moduletag :tmp_dir
  @id "code-review"
  @server HalC2Plugins.CodeReview
  @key "acme/api#1"
  @package Path.expand("../../../../plugins/code-review", __DIR__)
  @support Path.expand("../support", __DIR__)
  @git_config ~w(GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_KEY_1
                 GIT_CONFIG_VALUE_1 GIT_CONFIG_KEY_2 GIT_CONFIG_VALUE_2 GIT_CONFIG_PARAMETERS
                 GIT_CONFIG_GLOBAL)

  defmodule Dropped do
    # A test conn whose answer cannot be sent, as Bandit raises once its peer has gone.
    def wrap(%Plug.Conn{adapter: {Plug.Adapters.Test.Conn, state}} = conn),
      do: %{conn | adapter: {__MODULE__, state}}

    def read_req_body(state, opts), do: Plug.Adapters.Test.Conn.read_req_body(state, opts)
    def send_resp(_state, _status, _headers, _body), do: raise("the connection is closed")
  end

  # Ahead of the rest, as what this MC holds is keyed by its node's name.
  setup context, do: if(context[:laptop], do: %{laptop: start_laptop()}, else: :ok)

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

    assert_receive {:hal_c2_shell, {:rows, _, [{"api", _}]}}, 5_000
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
          "readReviewMd" => false,
          # The fake agents run here: these tests review trusted pull requests on
          # this machine unless they say otherwise.
          "reviewTrustedOnThisMachine" => true
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
    ref = Process.monitor(look(Process.whereis(@server)))

    {:ok, _} = HalC2.Plugins.handle("disable", %{"id" => @id})

    assert_receive {:DOWN, ^ref, :process, _, _}, 1_000
  end

  # A look whose read of who stands behind #1 waits until `release/0` is called.
  defp hold_trust_read(context, opts) do
    hold = Path.join(context.dir, "trust.hold")
    File.write!(hold, "")
    on_exit(fn -> File.rm(hold) end)
    held = "touch '#{context.dir}/trust.held'; while [ -e '#{hold}' ]; do sleep 0.05; done"
    rules!(context, Keyword.put(opts, :trust, held))
    send(@server, :poll)
    await_file(Path.join(context.dir, "trust.held"))
    fn -> File.rm!(hold) end
  end

  test "a commenter taken off the trusted logins while GitHub is read asks for no review",
       context do
    save_settings(%{"trustedLogins" => ["hubot"]})

    comment = %{
      "author" => %{"__typename" => "Bot", "login" => "hubot"},
      "authorAssociation" => "NONE",
      "body" => "/review",
      "createdAt" => "2026-09-01T00:00:00Z"
    }

    release =
      hold_trust_read(context, head: 1, comments: [comment], updated: "2026-09-05T00:00:00Z")

    put_settings(%{"trustedLogins" => []})
    release.()
    await_look()
    settle()
    assert %{"status" => "ready"} = review()

    # Trusted when the look is applied, the same comment asks.
    save_settings(%{"trustedLogins" => ["hubot"]})
    rules!(context, head: 1, comments: [comment], updated: "2026-09-06T00:00:00Z")
    refresh()
    assert %{"trigger" => "command"} = review()
  end

  test "who added the old trigger label, read while the label changed, does not start a review",
       context do
    labeled = fn name, login ->
      %{
        "__typename" => "LabeledEvent",
        "createdAt" => "2026-09-01T00:00:00Z",
        "actor" => %{"__typename" => "User", "login" => login},
        "label" => %{"name" => name}
      }
    end

    release =
      hold_trust_read(context,
        head: 1,
        labels: ["agent-review", "ship-it"],
        updated: "2026-09-05T00:00:00Z",
        timeline: [labeled.("agent-review", "monalisa"), labeled.("ship-it", "stranger")]
      )

    put_settings(%{"label" => "ship-it"})
    release.()
    await_look()
    settle()
    assert %{"status" => "ready", "untrusted" => untrusted} = review()
    assert untrusted =~ "has not been read yet"

    # Read again for the label that is the trigger now, its adder is not trusted.
    refresh()
    assert %{"status" => "ready", "untrusted" => nil} = review()
  end

  test "a collaborator with a custom role is trusted by the permission it extends",
       context do
    save_settings(%{"label" => "ship-it"})

    labeled = %{
      "__typename" => "LabeledEvent",
      "createdAt" => "2026-09-01T00:00:00Z",
      "actor" => %{"__typename" => "User", "login" => "custodian"},
      "label" => %{"name" => "ship-it"}
    }

    label = fn answer, updated ->
      rules!(context,
        head: 1,
        labels: ["ship-it"],
        updated: updated,
        timeline: [labeled],
        permissions: [{"custodian", answer}]
      )

      refresh()
      review()
    end

    # A custom role over read, and one GitHub names no permission for, are not trusted.
    for {answer, at} <- [
          {%{"role_name" => "Docs", "permission" => "read"}, "2026-09-02T00:00:00Z"},
          {%{"role_name" => "Docs"}, "2026-09-03T00:00:00Z"}
        ] do
      assert %{"status" => "ready"} = review = label.(answer, at)
      refute review["trigger"]
      assert review["trust"]["labeled"]["login"] == "custodian"
    end

    # One over write is.
    assert %{"trigger" => "label"} =
             label.(
               %{"role_name" => "Security reviewer", "permission" => "write"},
               "2026-09-04T00:00:00Z"
             )
  end

  test "a label added by someone trusted and someone untrusted at the same time does not start a review",
       context do
    save_settings(%{"label" => "ship-it"})

    labeled = fn login ->
      %{
        "__typename" => "LabeledEvent",
        "createdAt" => "2026-09-01T00:00:00Z",
        "actor" => %{"__typename" => "User", "login" => login},
        "label" => %{"name" => "ship-it"}
      }
    end

    label = fn timeline, updated ->
      rules!(context, head: 1, labels: ["ship-it"], updated: updated, timeline: timeline)
      refresh()
      review()
    end

    # Within one second GitHub's order says nothing of which came last, in either order.
    for {timeline, at} <- [
          {[labeled.("monalisa"), labeled.("stranger")], "2026-09-02T00:00:00Z"},
          {[labeled.("stranger"), labeled.("monalisa")], "2026-09-03T00:00:00Z"}
        ] do
      assert %{"status" => "ready"} = review = label.(timeline, at)
      refute review["trigger"]
      %{"login" => last, "tied" => [%{"login" => tied}]} = review["trust"]["labeled"]
      assert Enum.sort([last, tied]) == ["monalisa", "stranger"]
    end

    # The same trusted login twice is still trusted.
    assert %{"trigger" => "label"} =
             label.([labeled.("monalisa"), labeled.("monalisa")], "2026-09-04T00:00:00Z")
  end

  test "an account that shares a trusted login but is not that user does not start a review",
       context do
    save_settings(%{"label" => "ship-it"})

    labeled = fn type, login ->
      %{
        "__typename" => "LabeledEvent",
        "createdAt" => "2026-09-01T00:00:00Z",
        "actor" => %{"__typename" => type, "login" => login},
        "label" => %{"name" => "ship-it"}
      }
    end

    label = fn timeline, updated ->
      rules!(context,
        head: 1,
        labels: ["ship-it"],
        updated: updated,
        timeline: timeline,
        permissions: [{"custodian", %{"role_name" => "write", "permission" => "write"}}]
      )

      refresh()
      review()
    end

    # A mannequin of an import with the user's login, or a collaborator's, is neither:
    # its permission is not read by the login, which names the user.
    for {timeline, at} <- [
          {[labeled.("Mannequin", "monalisa")], "2026-09-02T00:00:00Z"},
          {[labeled.("Mannequin", "custodian")], "2026-09-03T00:00:00Z"},
          # A bot with the user's login, at the same time as the user, is someone else.
          {[labeled.("User", "monalisa"), labeled.("Bot", "monalisa")], "2026-09-04T00:00:00Z"},
          {[labeled.("Bot", "monalisa"), labeled.("User", "monalisa")], "2026-09-05T00:00:00Z"}
        ] do
      assert %{"status" => "ready"} = review = label.(timeline, at)
      refute review["trigger"], inspect(timeline)
    end

    assert %{"trigger" => "label"} =
             label.([labeled.("User", "custodian")], "2026-09-06T00:00:00Z")
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

  test "a checkout drops the refs of attempts whose holder ended and keeps those still held",
       context do
    checkout = HalC2Plugins.CodeReview.Checkout
    # Who holds each attempt's refs, which `prepare` records and its sweep reads.
    held = HalC2Plugins.CodeReview.Checkout.Held
    remote = %{"url" => Path.join(context.dir, "remotes/acme/api.git")}
    clone = Path.join(context.dir, "sweep/api.git")

    prepare = fn n ->
      apply(checkout, :prepare, [clone, "#{clone}-#{n}", remote, 1, "main", :any])
    end

    refs = fn ->
      git!(clone, ["for-each-ref", "--format=%(refname)", "refs/hal-c2/code-review/1/"])
    end

    # The first checkout makes the clone, and gives its refs back.
    assert {:ok, _} = prepare.(1)
    :ok = apply(checkout, :release, [])

    live = spawn(fn -> receive do: (:done -> :ok) end)
    on_exit(fn -> send(live, :done) end)
    {dead, ended} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^ended, :process, ^dead, _}
    kept = "refs/hal-c2/code-review/1/attempt-900000001"
    gone = "refs/hal-c2/code-review/1/attempt-900000002"

    for attempt <- [kept, gone],
        side <- ~w(head base),
        do: git!(clone, ["update-ref", "#{attempt}/#{side}", context.shas[1]])

    :ets.insert(held, [{{clone, kept}, live}, {{clone, gone}, dead}])

    assert {:ok, %{"headRef" => head, "baseRef" => base}} = prepare.(2)
    listed = String.split(refs.(), "\n", trim: true)
    assert "#{kept}/head" in listed and "#{kept}/base" in listed
    assert head in listed and base in listed
    refute Enum.any?(listed, &String.starts_with?(&1, gone <> "/"))
    assert :ets.lookup(held, {clone, gone}) == []
    assert [{_, ^live}] = :ets.lookup(held, {clone, kept})
    :ok = apply(checkout, :release, [])
  end

  test "a review checkout has the submodules its head pins, nested ones too, which its removal takes",
       context do
    checkout = HalC2Plugins.CodeReview.Checkout
    inner = repo!(context.dir, "inner", "inner.txt")

    lib =
      repo!(context.dir, "lib", "lib.txt", [{"deep", "https://github.com/acme/inner.git", inner}])

    pinned = git!(lib.seed, ["rev-parse", "HEAD"])
    # A commit past the pinned one, which the checkout does not get.
    File.write!(Path.join(lib.seed, "lib.txt"), "later\n")
    git!(lib.seed, ["commit", "-qam", "Later"])
    git!(lib.seed, ["push", "-q", lib.bare, "HEAD:main"])
    head = pull!(context, 3, [{"third_party/lib", "https://github.com/acme/lib.git", pinned}])

    remote = %{"url" => "https://github.com/acme/api.git"}
    clone = Path.join(context.dir, "subs/api.git")
    prepare = fn path -> apply(checkout, :prepare, [clone, path, remote, 3, "main", :any]) end
    first = Path.join(context.dir, "subs/first")
    second = Path.join(context.dir, "subs/second")

    assert {:ok, %{"headSha" => ^head}} = prepare.(first)
    assert :ok = apply(checkout, :submodules, [clone, first, remote])
    assert File.read!(Path.join(first, "third_party/lib/lib.txt")) == "lib\n"
    assert File.read!(Path.join(first, "third_party/lib/deep/inner.txt")) == "inner\n"
    assert git!(Path.join(first, "third_party/lib"), ["rev-parse", "HEAD"]) == pinned
    # Every review of the repository shares the clone's config: nothing is registered there.
    refute File.read!(Path.join(clone, "config")) =~ "submodule"

    # The next checkout borrows what the first fetched: its submodules download nothing.
    assert {:ok, _} = prepare.(second)
    assert :ok = apply(checkout, :submodules, [clone, second, remote])
    assert File.read!(Path.join(second, "third_party/lib/deep/inner.txt")) == "inner\n"

    for sub <- ~w(third_party/lib third_party/lib/deep) do
      counts = git!(Path.join(second, sub), ["count-objects", "-v"])
      assert counts =~ ~r/^count: 0$/m and counts =~ ~r/^in-pack: 0$/m
    end

    :ok = apply(checkout, :release, [])
    :ok = apply(checkout, :remove, [clone, first])
    :ok = apply(checkout, :remove, [clone, second])
    refute File.exists?(first) or File.exists?(second)
    assert Path.wildcard(Path.join(clone, "worktrees/*")) == []
  end

  test "submodules whose paths have spaces reach the store the next checkout borrows from",
       context do
    checkout = HalC2Plugins.CodeReview.Checkout
    inner = repo!(context.dir, "inner", "inner.txt")
    lib = repo!(context.dir, "lib", "inner.txt")
    tail = repo!(context.dir, "tail", "inner.txt")

    # The first path git lists starts with a space, the last ends with one.
    pull!(context, 3, [
      {" leading lib", "https://github.com/acme/lib.git", lib},
      {"my dir", "https://github.com/acme/inner.git", inner},
      {"trailing lib ", "https://github.com/acme/tail.git", tail}
    ])

    remote = %{"url" => "https://github.com/acme/api.git"}
    clone = Path.join(context.dir, "subs/api.git")
    first = Path.join(context.dir, "subs/first")
    second = Path.join(context.dir, "subs/second")

    for path <- [first, second] do
      assert {:ok, _} = apply(checkout, :prepare, [clone, path, remote, 3, "main", :any])
      assert :ok = apply(checkout, :submodules, [clone, path, remote])
      assert File.read!(Path.join(path, " leading lib/inner.txt")) == "lib\n"
      assert File.read!(Path.join(path, "my dir/inner.txt")) == "inner\n"
      assert File.read!(Path.join(path, "trailing lib /inner.txt")) == "tail\n"
    end

    for sub <- [" leading lib", "my dir", "trailing lib "] do
      counts = git!(Path.join(second, sub), ["count-objects", "-v"])
      assert counts =~ ~r/^count: 0$/m and counts =~ ~r/^in-pack: 0$/m
    end

    :ok = apply(checkout, :release, [])
  end

  test "submodules are fetched with the certificate checked, whatever the environment says",
       context do
    checkout = HalC2Plugins.CodeReview.Checkout
    inner = repo!(context.dir, "inner", "inner.txt")

    lib =
      repo!(context.dir, "lib", "lib.txt", [{"deep", "https://github.com/acme/inner.git", inner}])

    pull!(context, 3, [{"lib", "https://github.com/acme/lib.git", lib}])
    remote = %{"url" => "https://github.com/acme/api.git"}
    clone = Path.join(context.dir, "subs/api.git")
    path = Path.join(context.dir, "subs/unchecked")
    assert {:ok, _} = apply(checkout, :prepare, [clone, path, remote, 3, "main", :any])

    # Each submodule fetch says whether git would check the certificate of its server.
    log = Path.join(context.dir, "ssl.log")
    ssh = Path.join(context.dir, "logging-ssh")

    File.write!(ssh, """
    #!/bin/sh
    for url in https://github.com/acme/lib.git https://github.com/acme/inner.git; do
      echo "$url $(git config --get-urlmatch http.sslVerify "$url")" >> '#{log}'
    done
    exec '#{System.get_env("GIT_SSH_COMMAND")}' "$@"
    """)

    File.chmod!(ssh, 0o755)
    System.put_env("GIT_SSH_COMMAND", ssh)
    included = Path.join(context.dir, "unchecked.gitconfig")
    File.write!(included, "[http \"https://github.com/acme/\"]\n\tsslVerify = false\n")

    # Beside the rewrite the fake remote needs: the check turned off for the submodules'
    # URLs, for their server through an included file, and for every server.
    System.put_env(%{
      "GIT_CONFIG_COUNT" => "3",
      "GIT_CONFIG_KEY_1" => "http.https://github.com/acme/inner.git.sslVerify",
      "GIT_CONFIG_VALUE_1" => "false",
      "GIT_CONFIG_KEY_2" => "include.path",
      "GIT_CONFIG_VALUE_2" => included,
      "GIT_CONFIG_PARAMETERS" => "'http.sslverify'='false'"
    })

    assert :ok = apply(checkout, :submodules, [clone, path, remote])
    assert File.read!(Path.join(path, "lib/deep/inner.txt")) == "inner\n"

    assert File.read!(log) |> String.split("\n", trim: true) |> Enum.uniq() == [
             "https://github.com/acme/lib.git ",
             "https://github.com/acme/inner.git "
           ]

    :ok = apply(checkout, :release, [])
  end

  # #1774: the MC's GitHub config starts with `helper =`, which drops the helpers
  # before it; re-exported empty, its GIT_CONFIG_VALUE_<n> must still reach git.
  test "submodules are fetched when the environment of the MC configures an empty value",
       context do
    checkout = HalC2Plugins.CodeReview.Checkout
    lib = repo!(context.dir, "lib", "lib.txt")
    pull!(context, 3, [{"lib", "https://github.com/acme/lib.git", lib}])
    remote = %{"url" => "https://github.com/acme/api.git"}
    clone = Path.join(context.dir, "subs/api.git")
    path = Path.join(context.dir, "subs/empty-value")
    assert {:ok, _} = apply(checkout, :prepare, [clone, path, remote, 3, "main", :any])

    included = Path.join(context.dir, "github.gitconfig")
    File.write!(included, "[credential \"https://example.invalid\"]\n\thelper =\n")

    System.put_env(%{
      "GIT_CONFIG_COUNT" => "2",
      "GIT_CONFIG_KEY_1" => "include.path",
      "GIT_CONFIG_VALUE_1" => included
    })

    assert :ok = apply(checkout, :submodules, [clone, path, remote])
    assert File.read!(Path.join(path, "lib/lib.txt")) == "lib\n"
    :ok = apply(checkout, :release, [])
  end

  test "a submodule its .gitmodules says not to update still gets its pinned commit", context do
    checkout = HalC2Plugins.CodeReview.Checkout
    inner = repo!(context.dir, "inner", "inner.txt")
    pull!(context, 3, [{"lib", "https://github.com/acme/inner.git", inner, "\tupdate = none\n"}])
    remote = %{"url" => "https://github.com/acme/api.git"}
    clone = Path.join(context.dir, "subs/api.git")
    path = Path.join(context.dir, "subs/none")

    assert {:ok, _} = apply(checkout, :prepare, [clone, path, remote, 3, "main", :any])
    assert :ok = apply(checkout, :submodules, [clone, path, remote])
    assert File.read!(Path.join(path, "lib/inner.txt")) == "inner\n"
    :ok = apply(checkout, :release, [])
  end

  test "a submodule its .gitmodules says to clone shallow reaches the store the next checkout borrows from",
       context do
    checkout = HalC2Plugins.CodeReview.Checkout
    lib = repo!(context.dir, "lib", "lib.txt")
    # A parent behind the pinned commit, which a depth-1 clone would leave out.
    File.write!(Path.join(lib.seed, "lib.txt"), "pinned\n")
    git!(lib.seed, ["commit", "-qam", "Pinned"])
    git!(lib.seed, ["push", "-q", lib.bare, "HEAD:main"])
    pull!(context, 3, [{"lib", "https://github.com/acme/lib.git", lib, "\tshallow = true\n"}])

    remote = %{"url" => "https://github.com/acme/api.git"}
    clone = Path.join(context.dir, "subs/api.git")
    first = Path.join(context.dir, "subs/first")
    second = Path.join(context.dir, "subs/second")

    for path <- [first, second] do
      assert {:ok, _} = apply(checkout, :prepare, [clone, path, remote, 3, "main", :any])
      assert :ok = apply(checkout, :submodules, [clone, path, remote])
      assert File.read!(Path.join(path, "lib/lib.txt")) == "pinned\n"
    end

    counts = git!(Path.join(second, "lib"), ["count-objects", "-v"])
    assert counts =~ ~r/^count: 0$/m and counts =~ ~r/^in-pack: 0$/m
    :ok = apply(checkout, :release, [])
  end

  test "a submodule over git:// is not fetched, as nothing times it out", context do
    checkout = HalC2Plugins.CodeReview.Checkout
    pull!(context, 3, [{"lib", "git://example.invalid/lib.git", context.shas[1]}])
    remote = %{"url" => "https://github.com/acme/api.git"}
    clone = Path.join(context.dir, "subs/api.git")
    path = Path.join(context.dir, "subs/plain-git")

    assert {:ok, _} = apply(checkout, :prepare, [clone, path, remote, 3, "main", :any])
    assert {:error, reason} = apply(checkout, :submodules, [clone, path, remote])
    assert reason =~ "transport 'git' not allowed"
    assert File.regular?(Path.join(path, "README.md"))
    :ok = apply(checkout, :release, [])
  end

  test "submodules fetched before another fails reach the store the next checkout borrows from",
       context do
    checkout = HalC2Plugins.CodeReview.Checkout
    inner = repo!(context.dir, "inner", "inner.txt")

    pull!(context, 3, [
      {"a-lib", "https://github.com/acme/inner.git", inner},
      {"z-lib", "git://example.invalid/lib.git", context.shas[1]}
    ])

    remote = %{"url" => "https://github.com/acme/api.git"}
    clone = Path.join(context.dir, "subs/api.git")
    first = Path.join(context.dir, "subs/first")
    second = Path.join(context.dir, "subs/second")

    assert {:ok, _} = apply(checkout, :prepare, [clone, first, remote, 3, "main", :any])
    assert {:error, reason} = apply(checkout, :submodules, [clone, first, remote])
    assert reason =~ "transport 'git' not allowed"
    :ok = apply(checkout, :remove, [clone, first])

    assert {:ok, _} = apply(checkout, :prepare, [clone, second, remote, 3, "main", :any])
    assert {:error, _} = apply(checkout, :submodules, [clone, second, remote])
    # The failed clone stops the update before any checkout, but the one cloned again
    # borrowed everything from the store.
    counts = git!(Path.join(second, "a-lib"), ["count-objects", "-v"])
    assert counts =~ ~r/^count: 0$/m and counts =~ ~r/^in-pack: 0$/m
    :ok = apply(checkout, :release, [])
  end

  # From hal-c2/hal-c2#1713: two first reviews made the store at once and git failed one.
  test "the store of submodules is made with the clone locked", context do
    checkout = HalC2Plugins.CodeReview.Checkout
    inner = repo!(context.dir, "inner", "inner.txt")
    pull!(context, 3, [{"lib", "https://github.com/acme/inner.git", inner}])
    remote = %{"url" => "https://github.com/acme/api.git"}
    clone = Path.join(context.dir, "subs/api.git")
    path = Path.join(context.dir, "subs/locked")
    assert {:ok, _} = apply(checkout, :prepare, [clone, path, remote, 3, "main", :any])
    :ok = apply(checkout, :release, [])

    # A git that says when it is making the store, and waits there until let go.
    hold = Path.join(context.dir, "init.hold")
    held = Path.join(context.dir, "init.held")
    real = System.find_executable("git")
    fake = Path.join(context.dir, "bin/git")

    File.write!(fake, """
    #!/bin/sh
    case "$*" in
      *"init -q --bare "*/hal-c2-submodules)
        touch '#{held}'
        while [ -e '#{hold}' ]; do sleep 0.05; done ;;
    esac
    exec '#{real}' "$@"
    """)

    File.write!(hold, "")
    File.chmod!(fake, 0o755)
    on_exit(fn -> File.rm(hold) end)

    making = Task.async(fn -> apply(checkout, :submodules, [clone, path, remote]) end)
    await_file(held)
    refute :global.set_lock({{checkout, clone}, self()}, [node()], 0)
    File.rm!(hold)

    assert :ok = Task.await(making, :infinity)
    assert File.read!(Path.join(path, "lib/inner.txt")) == "inner\n"
  end

  test "a checkout git could not add leaves nothing behind", context do
    checkout = HalC2Plugins.CodeReview.Checkout
    inner = repo!(context.dir, "inner", "inner.txt")
    pull!(context, 3, [{"lib", "https://github.com/acme/inner.git", inner}])
    remote = %{"url" => "https://github.com/acme/api.git"}
    clone = Path.join(context.dir, "subs/api.git")
    path = Path.join(context.dir, "subs/cut-short")

    # A git whose worktree add writes the checkout and then fails with its entry still
    # locked as initializing, as one cut off would.
    real = System.find_executable("git")
    fake = Path.join(context.dir, "bin/git")
    lock = Path.join(clone, "worktrees/cut-short/locked")

    File.write!(fake, """
    #!/bin/sh
    case "$*" in
      *"worktree add "*) '#{real}' "$@"; echo initializing > '#{lock}'; exit 1 ;;
    esac
    exec '#{real}' "$@"
    """)

    File.chmod!(fake, 0o755)

    assert {:error, _} = apply(checkout, :prepare, [clone, path, remote, 3, "main", :any])
    :ok = apply(checkout, :release, [])
    refute File.exists?(path)
    refute File.exists?(Path.dirname(lock))
    refute git!(context.dir, ["--git-dir", clone, "worktree", "list"]) =~ path
  end

  test "submodules are fetched through the SSH program GIT_SSH names", context do
    checkout = HalC2Plugins.CodeReview.Checkout
    inner = repo!(context.dir, "inner", "inner.txt")
    pull!(context, 3, [{"lib", "https://github.com/acme/inner.git", inner}])
    remote = %{"url" => "https://github.com/acme/api.git"}
    clone = Path.join(context.dir, "subs/api.git")
    path = Path.join(context.dir, "subs/wrapped")
    assert {:ok, _} = apply(checkout, :prepare, [clone, path, remote, 3, "main", :any])

    # A wrapper named by `GIT_SSH` alone, which says it ran.
    log = Path.join(context.dir, "wrapper.log")
    wrapper = Path.join(context.dir, "wrapper-ssh")

    File.write!(wrapper, """
    #!/bin/sh
    echo ran >> '#{log}'
    exec '#{System.get_env("GIT_SSH_COMMAND")}' "$@"
    """)

    File.chmod!(wrapper, 0o755)
    restore = env(~w(GIT_SSH))
    on_exit(restore)
    System.delete_env("GIT_SSH_COMMAND")
    System.put_env("GIT_SSH", wrapper)

    assert :ok = apply(checkout, :submodules, [clone, path, remote])
    assert File.read!(Path.join(path, "lib/inner.txt")) == "inner\n"
    assert File.read!(log) =~ "ran"
    :ok = apply(checkout, :release, [])
  end

  test "a submodule at a local path is not fetched, and its checkout is still made", context do
    checkout = HalC2Plugins.CodeReview.Checkout
    local = repo!(context.dir, "local", "secret.txt")
    pull!(context, 3, [{"lib", local.bare, git!(local.seed, ["rev-parse", "HEAD"])}])
    remote = %{"url" => "https://github.com/acme/api.git"}
    clone = Path.join(context.dir, "subs/api.git")
    path = Path.join(context.dir, "subs/local")

    assert {:ok, _} = apply(checkout, :prepare, [clone, path, remote, 3, "main", :any])
    assert {:error, reason} = apply(checkout, :submodules, [clone, path, remote])
    assert reason =~ "transport 'file' not allowed"
    refute File.exists?(Path.join(path, "lib/secret.txt"))
    assert File.regular?(Path.join(path, "README.md"))
    :ok = apply(checkout, :release, [])
  end

  test "a checkout whose head has no submodules is left as it is", context do
    checkout = HalC2Plugins.CodeReview.Checkout
    remote = %{"url" => "https://github.com/acme/api.git"}
    clone = Path.join(context.dir, "subs/api.git")
    path = Path.join(context.dir, "subs/plain")

    assert {:ok, _} = apply(checkout, :prepare, [clone, path, remote, 1, "main", :any])
    assert :ok = apply(checkout, :submodules, [clone, path, remote])
    refute File.exists?(Path.join(clone, "hal-c2-submodules"))
    :ok = apply(checkout, :release, [])
  end

  test "a checkout whose head is not the one it must be at is refused before anything is checked out",
       context do
    checkout = HalC2Plugins.CodeReview.Checkout
    remote = %{"url" => Path.join(context.dir, "remotes/acme/api.git")}
    clone = Path.join(context.dir, "only/api.git")
    path = Path.join(context.dir, "only/checkout")
    fetched = context.shas[1]

    published = fn ->
      git!(clone, ["for-each-ref", "--format=%(refname)", "refs/hal-c2/code-review/1/"])
    end

    for only <- [context.shas[2], nil] do
      assert {:error, {:head, ^fetched}} =
               apply(checkout, :prepare, [clone, path, remote, 1, "main", only])

      refute File.exists?(path)
      assert published.() == ""
    end

    assert {:ok, %{"headSha" => ^fetched}} =
             apply(checkout, :prepare, [clone, path, remote, 1, "main", fetched])

    :ok = apply(checkout, :release, [])
  end

  test "whether a commit has a regular .gitmodules is read from its tree", context do
    checkout = HalC2Plugins.CodeReview.Checkout
    repo = Path.join(context.dir, "trees")
    git!(context.dir, ["init", "-q", repo])
    File.write!(Path.join(repo, "modules"), "[submodule \"lib\"]\n")
    blob = git!(repo, ["hash-object", "-w", "modules"])

    # Trees made whole, as git refuses to stage a link at .gitmodules.
    tree = fn entry ->
      {sha, 0} =
        System.cmd("sh", ["-c", ~S(printf '%s\n' "$1" | git mktree), "sh", entry], cd: repo)

      String.trim(sha)
    end

    commit = &git!(repo, ["commit-tree", "-m", "Tree", tree.(&1)])
    regular? = &apply(checkout, :regular?, [repo, &1, ".gitmodules"])

    assert regular?.(commit.("100644 blob #{blob}\t.gitmodules"))
    assert regular?.(commit.("100755 blob #{blob}\t.gitmodules"))
    refute regular?.(commit.("120000 blob #{blob}\t.gitmodules"))
    refute regular?.(commit.("040000 tree #{tree.("100644 blob #{blob}\tx")}\t.gitmodules"))
    refute regular?.(commit.("100644 blob #{blob}\tREADME.md"))
  end

  test "the lines a report's comments may sit on are read from a diff of their files alone",
       context do
    checkout = HalC2Plugins.CodeReview.Checkout
    restore = app([:code_review_diff_bytes])
    on_exit(restore)
    repo = Path.join(context.dir, "diffs")
    git!(context.dir, ["init", "-q", repo])
    write = fn file, text -> File.write!(Path.join(repo, file), text) end
    numbered = Enum.map_join(1..10, &"line #{&1}\n")

    write.("a.txt", "a1\n")
    write.("b.txt", "b1\n")
    write.("old.txt", numbered)
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-q", "-m", "Base"])
    base = git!(repo, ["rev-parse", "HEAD"])
    write.("a.txt", "a2\n")
    write.("b.txt", "b2\n")
    git!(repo, ["mv", "old.txt", "new.txt"])
    write.("new.txt", String.replace(numbered, "line 10\n", "line ten\n"))
    git!(repo, ["commit", "-qam", "Head"])
    head = git!(repo, ["rev-parse", "HEAD"])
    lines = &apply(checkout, :diff_lines, [repo, base, head, &1])

    # No file asks git nothing, a path that names no checkout at all included.
    assert apply(checkout, :diff_lines, [Path.join(context.dir, "nowhere"), base, head, []]) ==
             {:ok, %{}}

    assert {:ok, %{"a.txt" => %{{"new", 1} => "added", {"old", 1} => "deleted"}} = only} =
             lines.(["a.txt"])

    assert Map.keys(only) == ["a.txt"]
    assert lines.(["missing.txt"]) == {:ok, %{}}

    # A renamed file still reads as a rename, not as a file added whole.
    assert {:ok, %{"new.txt" => renamed} = both} = lines.(["new.txt"])
    assert Map.keys(both) == ["new.txt"]
    assert renamed[{"new", 10}] == "added" and renamed[{"new", 7}] == "context"
    refute Map.has_key?(renamed, {"new", 1})

    # A diff past its cap places nothing.
    Application.put_env(:hal_c2, :code_review_diff_bytes, 16)
    assert lines.(["a.txt"]) == :error
  end

  test "an agent is told which submodules its checkout lacks" do
    settings = %{"prompt" => "Review", "readReviewMd" => false}
    review = %{"number" => 1, "repository" => "acme/api"}
    checkout = %{"path" => "/nowhere", "headSha" => "abc"}

    refute apply(@server, :prompt, [settings, review, checkout]) =~ "submodules"

    assert apply(@server, :prompt, [
             settings,
             review,
             Map.put(checkout, "submodules", "git submodule failed: no route")
           ]) =~
             "submodules could not all be fetched on the reviewing machine, so checks " <>
               "that need them are blocked there: git submodule failed: no route"

    # #1774: a sandbox never gets them, which is no setup problem on the machine.
    sandboxed =
      apply(@server, :prompt, [settings, review, Map.put(checkout, "submodules", :sandboxed)])

    assert sandboxed =~ "never fetched into a sandbox"
    assert sandboxed =~ "under notRun"
    refute sandboxed =~ "blocked there"
  end

  # #1795: a review on this machine quotes only what those it trusts wrote; anyone may
  # comment on a trusted pull request. A sandboxed one quotes everyone's.
  test "a review on this machine quotes the unresolved comments of those it trusts alone" do
    settings = %{"trustedLogins" => ["hubot"]}
    review = %{"trust" => %{"viewer" => "monalisa"}}

    thread = fn login, extra, body ->
      %{
        "isResolved" => false,
        "path" => "src/limits.ts",
        "line" => 3,
        "comments" => [%{"author" => Map.put(extra, "login", login), "body" => body}]
      }
    end

    threads = [
      thread.("octocat", %{"isUser" => true, "association" => "MEMBER"}, "a member's"),
      thread.("monalisa", %{"isUser" => true}, "the viewer's"),
      thread.("hubot", %{"isBot" => true}, "a listed bot's"),
      thread.("stranger", %{"isUser" => true, "association" => "NONE"}, "a stranger's"),
      thread.("monalisa", %{"isBot" => true}, "a bot named as the viewer's"),
      %{"isResolved" => false, "comments" => [%{"author" => nil, "body" => "a ghost's"}]},
      Map.put(
        thread.("octocat", %{"isUser" => true, "association" => "OWNER"}, "resolved"),
        "isResolved",
        true
      )
    ]

    quoted = &apply(@server, :existing_comments, [settings, review, &1, threads])

    here = Enum.join(quoted.(false), "\n")
    assert here =~ "a member's" and here =~ "the viewer's" and here =~ "a listed bot's"
    refute here =~ "a stranger's"
    refute here =~ "a bot named as the viewer's"
    refute here =~ "a ghost's"
    refute here =~ "resolved"

    sandboxed = Enum.join(quoted.(true), "\n")
    assert sandboxed =~ "a stranger's" and sandboxed =~ "a ghost's"
    refute sandboxed =~ "resolved"
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

  test "a push to a pull request the user asked to review is reviewed again in selective mode",
       context do
    save_settings(%{"reviewNewPushes" => true})
    review = start_review()

    {:ok, _} =
      HalC2.Plugins.call_tool(
        "code_review_report",
        %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []},
        review["threadId"]
      )

    push!(context, 2)
    rules!(context, head: 2)
    refresh()

    assert %{"status" => "running", "reviewedSha" => reviewed} = review()
    assert reviewed == context.shas[2]
  end

  test "a new run stops the agent it replaces, and tells it why its report is refused",
       context do
    save_settings(%{"reviewNewPushes" => true})
    old = start_review()
    # The review failed while the agent goes on, as across a restart of the plugin.
    event = %{"type" => "turn.finished", "threadId" => old["threadId"], "status" => "failed"}
    :ok = apply(@server, :handle_event, [event, %{}])
    settle()
    assert %{"status" => "failed"} = review()
    assert [%{"status" => "running"}] = active_runs(old["threadId"])

    push!(context, 2)
    rules!(context, head: 2)
    refresh()

    assert %{"status" => "running", "threadId" => new, "reviewedSha" => sha} = review()
    assert new != old["threadId"]
    assert [] = active_runs(old["threadId"])
    refute File.exists?(old["checkout"])

    assert Enum.any?(HalC2.Plugins.tools(old["threadId"]), &(&1["name"] == "code_review_report"))

    assert {:error, "plugin_failed", message, %{"plugin" => "code-review"}} =
             HalC2.Plugins.call_tool(
               "code_review_report",
               %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []},
               old["threadId"]
             )

    assert message =~ "replaced by a newer run for #{String.slice(sha, 0, 7)}"
    assert %{"status" => "running", "threadId" => ^new, "verdict" => nil} = review()
    refute Map.has_key?(review(), "replaced")
  end

  test "discarding a failed review stops the agent still working in its checkout", _context do
    review = start_review()
    event = %{"type" => "turn.finished", "threadId" => review["threadId"], "status" => "failed"}
    :ok = apply(@server, :handle_event, [event, %{}])
    settle()

    {:ok, _} = call("discard", %{"key" => @key})

    assert [] = active_runs(review["threadId"])
    refute File.exists?(review["checkout"])

    assert HalC2.Plugins.tools(review["threadId"])
           |> Enum.all?(&(&1["name"] != "code_review_report"))
  end

  # Its checkout went with the stop, so comments on its lines would land in the summary.
  test "a review stopped on this machine takes no report from its agent", _context do
    review = start_review()
    {:ok, _} = call("stop", %{"key" => @key})
    arguments = %{"verdict" => "approve", "summary" => "Fine.", "comments" => []}

    assert {:error, _, message, _} =
             HalC2.Plugins.call_tool("code_review_report", arguments, review["threadId"])

    assert message =~ "no longer running"
    settle()
    assert %{"status" => "failed", "error" => "Stopped.", "verdict" => nil} = review()
  end

  test "the first report of a run is final", _context do
    review = start_review()
    first = %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []}
    {:ok, _} = HalC2.Plugins.call_tool("code_review_report", first, review["threadId"])
    settle()
    again = %{first | "verdict" => "request-changes", "summary" => "Wait, no."}

    assert {:error, "plugin_failed", message, _} =
             HalC2.Plugins.call_tool("code_review_report", again, review["threadId"])

    assert message =~ "the first report is final"
    assert %{"verdict" => "approve", "summary" => "Looks right."} = review()
  end

  test "a review that changed since the user looked at it is not published", context do
    review = start_review()

    arguments = %{
      "verdict" => "comment",
      "summary" => "Two things.",
      "comments" => [
        %{"path" => "src/limits.ts", "line" => 1, "body" => "One."},
        %{"path" => "src/limits.ts", "line" => 1, "body" => "Two."}
      ]
    }

    {:ok, _} = HalC2.Plugins.call_tool("code_review_report", arguments, review["threadId"])
    settle()
    looked = seen()
    {:ok, _} = call("dismiss", %{"key" => @key, "commentId" => "c1"})

    assert {:error, %{"message" => message}} = call("publish", looked)
    assert message =~ "changed since you looked at it"
    assert {:error, _} = call("publish", %{"key" => @key})

    # Without how the post goes, as the user was shown it, nothing is posted either.
    assert {:error, %{"message" => message}} =
             call("publish", Map.delete(seen(), "verdict"))

    assert message =~ "Publishing needs what you were shown it would post"
    assert %{"status" => "waiting"} = review()
    assert posts(context) == []
  end

  test "a pull request nobody trusted is reviewed only at the commit the user approved, and never posted on its own",
       context do
    sandboxed!(context)
    {:ok, _} = put_settings(%{"publishing" => "automatic"})
    settle()

    assert {:error, %{"message" => message}} =
             call("start", %{"repository" => "acme/api", "number" => 1})

    assert message =~ "Approve it on the Reviews page"
    assert %{"status" => "ready", "untrusted" => why} = review = review()
    refute review["threadId"]
    assert why =~ "not a member or collaborator"

    assert {:error, _} = call("approve", %{"key" => @key, "headSha" => context.shas[2]})
    {:ok, _} = call("approve", %{"key" => @key, "headSha" => context.shas[1]})

    # It runs in a sandbox, whose agent reports an approval.
    assert_receive {:sandbox_reported, 200, _}, 15_000
    assert_receive {:openshell_request, "DeleteSandbox", _}, 15_000
    settle()
    assert %{"status" => "waiting", "sandboxed" => true} = review()
    assert posts(context) == []
  end

  test "a pull request nobody trusted whose head moved past the approved commit is refused before anything is checked out",
       context do
    sandboxed!(context)
    settle()
    {:error, _} = call("start", %{"repository" => "acme/api", "number" => 1})
    # GitHub still lists the approved commit, but the pull request's head is past it.
    push!(context, 2)
    {:ok, _} = call("approve", %{"key" => @key, "headSha" => context.shas[1]})
    await_review(&(&1["status"] == "failed"))

    assert review()["error"] =~ "has new commits since you approved it"
    checkouts = Path.join(HalC2.Plugins.Host.data_dir("code-review"), "checkouts")
    assert Path.wildcard(Path.join(checkouts, "*/pr-1/*")) == []
    refute_received {:openshell_request, "CreateSandbox", _}
  end

  test "a push takes back the approval of a pull request nobody trusted, even pushed back",
       context do
    sandboxed!(context)
    settle()
    {:error, _} = call("start", %{"repository" => "acme/api", "number" => 1})
    {:ok, _} = call("approve", %{"key" => @key, "headSha" => context.shas[1]})
    assert_receive {:sandbox_reported, 200, _}, 15_000
    assert_receive {:openshell_request, "DeleteSandbox", _}, 15_000
    settle()
    first = context.shas[1]
    assert %{"status" => "waiting", "approved" => ^first} = review()

    rules!(context, head: 2, association: "NONE")
    refresh()
    assert %{"approved" => nil} = review()

    # Back at the commit the user approved, it waits for the user again.
    rules!(context, head: 1, association: "NONE")
    refresh()
    assert %{"approved" => nil, "headSha" => ^first} = review()
    assert {:error, %{"message" => message}} = call("retry", %{"key" => @key})
    assert message =~ "Approve it on the Reviews page"
  end

  test "what an agent writes mentions nobody, loads nothing and hides nothing", _context do
    _ = start_review()
    neutral = &apply(@server, :neutral, [&1])

    assert neutral.("ask @acme/security and @octocat, not me@example.com") ==
             "ask @\u200Bacme/security and @\u200Boctocat, not me@\u200Bexample.com"

    # Markup around a mention does not keep it whole.
    assert neutral.("ask _@octocat_, __@acme/security__ and *@octocat*") ==
             "ask _@\u200Boctocat_, __@\u200Bacme/security__ and *@\u200Boctocat*"

    assert neutral.(neutral.("_@octocat_")) == neutral.("_@octocat_")

    assert neutral.("![x](https://example.com/p.png) <img src=x> <!-- hi --> a < b") ==
             "!\u200B[x](https://example.com/p.png) <\u200Bimg src=x> <\u200B!-- hi --> a < b"

    refute neutral.("<!-- hal-c2-code-review:acme/api#1@abc -->") =~ "hal-c2-code-review:"
  end

  test "a fence the prose of a comment leaves open does not let its suggestion out of its code block",
       _context do
    body = &apply(@server, :comment_body, [&1, &2])
    bait = "![x](https://example.com/p.png) @octocat"
    open = %{"body" => "Use this:\n```", "suggestion" => bait}

    assert body.(open, "old") == "Use this:\n```\n```\n\nSuggested change:\n\n```\n#{bait}\n```"
    assert body.(open, "new") == "Use this:\n```\n```\n\n```suggestion\n#{bait}\n```"

    # A lone carriage return ends a line on GitHub too.
    assert body.(%{open | "body" => "Use this:\r```"}, "old") ==
             "Use this:\n```\n```\n\nSuggested change:\n\n```\n#{bait}\n```"

    # One the prose opens in a list or a quote, or indents, which the reader could end
    # elsewhere, is no fence at all.
    for nested <- ["- ```", "> ~~~", "   ```", "1. > ```"] do
      [lead, mark] = Regex.run(~r/^(.*?)([`~])/, nested, capture: :all_but_first)
      broken = lead <> mark <> "​" <> String.slice(nested, String.length(lead) + 1, 99)

      assert body.(%{"body" => "Ok.\n#{nested}\n  x", "suggestion" => bait}, "new") ==
               "Ok.\n#{broken}\n  x\n\n```suggestion\n#{bait}\n```"
    end

    # A closed fence, and a fence of tildes inside one of backticks, stay as written.
    closed = "See:\n```\n~~~\n```\nDone."

    assert body.(%{"body" => closed, "suggestion" => "x"}, "new") ==
             "#{closed}\n\n```suggestion\nx\n```"
  end

  test "the preview of a review is what publishing it posts", context do
    review = start_review()

    arguments = %{
      "verdict" => "request-changes",
      "summary" => "Two things.",
      "comments" => [
        %{"path" => "src/limits.ts", "line" => 1, "body" => "One.", "severity" => "major"},
        %{"path" => "src/limits.ts", "line" => 1, "body" => "Two."}
      ]
    }

    {:ok, _} = HalC2.Plugins.call_tool("code_review_report", arguments, review["threadId"])
    settle()
    {:ok, _} = call("dismiss", %{"key" => @key, "commentId" => "c2"})

    assert {:ok, preview} = call("preview", %{"key" => @key})
    assert preview["version"] == review()["version"]
    assert [%{"path" => "src/limits.ts", "line" => 1, "body" => one}] = preview["comments"]
    assert one =~ "One."

    assert {:ok, _} =
             call("publish", Map.merge(seen(), Map.take(preview, ~w(version verdict))))

    assert [post] = posts(context)
    sent = post |> Jason.decode!() |> Map.fetch!("stdin") |> Jason.decode!()
    assert sent["body"] == preview["body"]
    assert sent["event"] == "REQUEST_CHANGES" and preview["verdict"] == review()["verdict"]
    assert Enum.map(sent["comments"], & &1["body"]) == [one]
  end

  test "a draft saved before reports were made safe is shown safe and is not published",
       context do
    review = start_review()
    arguments = %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []}
    {:ok, _} = HalC2.Plugins.call_tool("code_review_report", arguments, review["threadId"])
    settle()

    # As reviews.json held a waiting draft before: its text as the agent wrote it, and
    # no report version.
    raw = "Ping @octocat and @acme/core. ![x](https://example.com/x.png) <img src=x>\n```"

    comment = %{
      "id" => "c1",
      "path" => "src/limits.ts\nREADME.md",
      "line" => 1,
      "side" => "new",
      "body" => raw <> String.duplicate("y", 9_000),
      "severity" => "major",
      "position" => 1,
      "dismissed" => false
    }

    file = Path.join([context.dir, "home", "plugin-data", "code-review", "reviews.json"])
    saved = file |> File.read!() |> JSON.decode!()

    old =
      saved["reviews"][@key]
      |> Map.delete("report")
      |> Map.merge(%{
        "summary" => raw <> String.duplicate("x", 70_000),
        "comments" =>
          List.duplicate(comment, 40)
          |> Enum.with_index(1)
          |> Enum.map(fn {c, i} -> %{c | "id" => "c#{i}"} end),
        "validation" => %{"ran" => [%{"command" => "@octocat\nmix test", "result" => "ok"}]}
      })

    File.write!(file, JSON.encode!(put_in(saved, ["reviews", @key], old)))
    {:ok, _} = HalC2.Plugins.handle("restart", %{"id" => @id})
    settle()

    shown = review()
    texts = [shown["summary"] | Enum.map(shown["comments"], & &1["body"])]

    for text <- texts do
      refute text =~ ~r/@(?=[\w-])/u
      refute text =~ "!["
      refute text =~ ~r/<[A-Za-z]/
      # No code block left open.
      assert text |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "```")) |> rem(2) ==
               0
    end

    assert byte_size(shown["summary"]) <= 60_100
    assert length(shown["comments"]) <= 30
    assert Enum.all?(shown["comments"], &(byte_size(&1["body"]) <= 4_200))
    assert Enum.all?(shown["comments"], &(not String.contains?(&1["path"], "\n")))
    assert [%{"command" => "@\u200Boctocat mix test"}] = shown["validation"]["ran"]

    # What the plugin holds is as safe as what it shows.
    held = :sys.get_state(@server).reviews[@key]
    assert held["summary"] == shown["summary"]

    # It is not posted, from its preview or from Publish: it is reviewed again first.
    assert {:error, %{"message" => message}} = call("preview", %{"key" => @key})
    assert message =~ "review it again"
    assert {:error, %{"message" => message}} = call("publish", seen())
    assert message =~ "review it again"
    assert %{"status" => "waiting"} = review()
    assert posts(context) == []
  end

  test "a review whose post would change from its preview is not published", context do
    review = start_review()
    arguments = %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []}
    {:ok, _} = HalC2.Plugins.call_tool("code_review_report", arguments, review["threadId"])
    settle()
    {:ok, preview} = call("preview", %{"key" => @key})
    save_settings(%{"verdictAsComment" => true})

    assert {:error, %{"message" => message}} =
             call("publish", Map.merge(seen(), Map.take(preview, ~w(version verdict))))

    assert message =~ "changed since you looked at it"
    assert %{"status" => "waiting"} = review()
    assert posts(context) == []
  end

  test "a comment off the change that opens with a fence keeps its suggestion in its own block",
       _context do
    review = start_review()
    bait = "![x](https://example.com/p.png) @octocat"

    comment = %{
      "path" => "src/elsewhere.ts",
      "line" => 3,
      "side" => "old",
      "body" => "```ts\nconst limit = 2;",
      "suggestion" => bait
    }

    arguments = %{"verdict" => "comment", "summary" => "One note.", "comments" => [comment]}
    {:ok, _} = HalC2.Plugins.call_tool("code_review_report", arguments, review["threadId"])
    settle()

    assert %{"summary" => summary, "comments" => []} = review()

    assert summary ==
             "One note.\n\n`src/elsewhere.ts:3`:\n\n```ts\nconst limit = 2;\n```\n\n" <>
               "Suggested change:\n\n```\n#{bait}\n```"
  end

  test "counts in the settings are whole numbers", _context do
    for key <-
          ~w(reviewsPerAuthorPerDay reviewsPerRepositoryPerDay maxChangedLines concurrency pollMinutes) do
      assert {:error, %{"message" => message}} = save_settings_answer(%{key => 1.5})
      assert message =~ key
    end

    assert {:ok, _} = put_settings(%{"reviewsPerAuthorPerDay" => 2, "concurrency" => 1})
    settle()
  end

  test "a severity badge on an old-side comment that opens with a fence keeps its suggestion in its own block",
       context do
    # The pull request changes README.md, so its first line on the old side is in the diff.
    seed = Path.join(context.dir, "seed")
    git!(seed, ["checkout", "-q", context.shas[1]])
    File.write!(Path.join(seed, "README.md"), "# API\n")
    git!(seed, ["commit", "-q", "-am", "Rename"])
    head = git!(seed, ["rev-parse", "HEAD"])
    bare = Path.join(context.dir, "remotes/acme/api.git")
    git!(seed, ["push", "-q", bare, "#{head}:refs/pull/1/head"])
    context = put_in(context.shas[3], head)
    rules!(context, head: 3)

    review = start_review()
    bait = "![x](https://example.com/p.png) @octocat"

    comment = %{
      "path" => "README.md",
      "line" => 1,
      "side" => "old",
      "severity" => "high",
      "body" => "```ts\nconst limit = 2;",
      "suggestion" => bait
    }

    arguments = %{"verdict" => "comment", "summary" => "One note.", "comments" => [comment]}
    {:ok, _} = HalC2.Plugins.call_tool("code_review_report", arguments, review["threadId"])
    settle()

    expected =
      "🔴 **High:**\n\n```ts\nconst limit = 2;\n```\n\nSuggested change:\n\n```\n#{bait}\n```"

    assert {:ok, preview} = call("preview", %{"key" => @key})
    assert [%{"path" => "README.md", "body" => ^expected}] = preview["comments"]

    assert {:ok, _} =
             call("publish", Map.merge(seen(), Map.take(preview, ~w(version verdict))))

    assert [post] = posts(context)
    sent = post |> Jason.decode!() |> Map.fetch!("stdin") |> Jason.decode!()
    assert Enum.map(sent["comments"], & &1["body"]) == [expected]
  end

  test "a limit that asks of the user went past holds until enough reviews stop counting",
       context do
    report = fn review ->
      arguments = %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []}
      {:ok, _} = HalC2.Plugins.call_tool("code_review_report", arguments, review["threadId"])
      settle()
    end

    report.(start_review())
    {:ok, _} = call("retry", %{"key" => @key})
    settle()
    report.(review())

    # Two starts of octocat's, both asked for, against a limit of one: the next of the
    # watch's own has room once the newer of them stops counting, not the older.
    save_settings(%{"reviewNewPushes" => true, "reviewsPerAuthorPerDay" => 1})
    rules!(context, head: 2)
    refresh()

    newer = apply(@server, :starts, []) |> Enum.map(& &1["at"]) |> Enum.max()
    {:ok, newer, _} = DateTime.from_iso8601(newer)
    assert %{"limited" => %{"until" => until}} = review()
    assert until == newer |> DateTime.add(86_400, :second) |> DateTime.to_iso8601()
  end

  # A machine told of a start may have counted one of its own since this machine read
  # its starts: a partition took this machine's lock off it in between.
  test "a start runs only if the starts the machines told of it answer still leave room",
       context do
    first = start_review()
    arguments = %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []}
    {:ok, _} = HalC2.Plugins.call_tool("code_review_report", arguments, first["threadId"])
    settle()

    # The watch's own review of a push, which the limits hold back; the user's ask
    # before it counts.
    save_settings(%{
      "activation" => "automatic",
      "reviewNewPushes" => true,
      "reviewsPerAuthorPerDay" => 3
    })

    push!(context, 2)
    rules!(context, head: 2)
    refresh()
    assert %{"status" => "running"} = review = review()
    assert review["threadId"] != first["threadId"]
    peer = "hal_c2@laptop.hal-c2"

    row = fn id ->
      %{
        "id" => id,
        "at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "repository" => String.downcase(review["repository"]),
        "author" => String.downcase(review["author"])
      }
    end

    mine = Enum.find(apply(@server, :starts, []), &(&1["id"] == review["threadId"]))
    told = fn rows -> [%{"node" => peer, "machine" => "laptop", "result" => rows}] end
    ask = &GenServer.call(@server, {:told, @key, review["threadId"], [peer], &1})

    assert ask.(told.([mine, row.("laptop-1")])) == :ok
    assert %{"status" => "running"} = review()

    assert ask.(told.([mine, row.("laptop-1"), row.("laptop-2")])) == :limited

    assert %{"status" => "ready", "threadId" => nil, "limited" => %{"reason" => reason}} =
             review()

    assert reason =~ "had 3 reviews in the last day, the most the settings allow"
    assert Enum.any?(apply(@server, :starts, []), &(&1["id"] == review["threadId"]))
  end

  # A member of the cluster that has never answered this machine may be starting
  # reviews of its own: until they meet, each has only its share of the limits.
  test "a member of the cluster that has never answered counts as out of reach for the review limits",
       context do
    first = start_review()
    arguments = %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []}
    {:ok, _} = HalC2.Plugins.call_tool("code_review_report", arguments, first["threadId"])
    settle()

    Application.put_env(:hal_c2, :cluster_transport, __MODULE__.Unreached)
    Application.put_env(:hal_c2, :cluster_listen, "127.0.0.1")

    on_exit(fn ->
      for key <- [:cluster_transport, :cluster_listen], do: Application.delete_env(:hal_c2, key)
    end)

    start_supervised!(HalC2.Cluster)
    entry = %{"id" => "laptop", "fingerprint" => String.duplicate("a", 64), "label" => "laptop"}
    {:ok, _} = HalC2.Cluster.admit(Map.put(entry, "version", HalC2.Upgrade.version()))

    # The user's ask counted one; this machine's share of two is one.
    save_settings(%{
      "activation" => "automatic",
      "reviewNewPushes" => true,
      "reviewsPerAuthorPerDay" => 2
    })

    push!(context, 2)
    rules!(context, head: 2)
    refresh()

    assert %{"status" => "ready", "limited" => %{"reason" => reason, "apart" => apart}} =
             review()

    assert apart == ["hal_c2@laptop.hal-c2"]

    assert reason =~
             "this machine's share of what the settings allow while laptop is out of reach"
  end

  # Another machine of the cluster, which cannot open the sandbox the review needs,
  # hands it over (`take/1`).
  describe "a review another machine hands over" do
    @ask %{"repository" => "acme/api", "number" => 1, "trigger" => "watch"}

    test "starts here when this machine can run it as its own settings say" do
      assert take(@ask) == {:ok, nil}
      settle()
      assert %{"status" => "running", "trigger" => "watch"} = review()
    end

    test "is refused by a machine that cannot open the sandbox it needs either" do
      save_settings(%{"reviewTrustedOnThisMachine" => false})

      assert take(@ask) == {:error, "Review sandboxes can't run on this machine either."}
      settle()
      refute match?(%{"status" => status} when status in ~w(queued running), review())
    end

    test "is refused by a paused machine, as it leaves its own queue" do
      %{"threadId" => thread_id} = start_review()

      event = %{
        "type" => "turn.finished",
        "threadId" => thread_id,
        "status" => "failed",
        "errorClass" => "usage_limit",
        "error" => "Subscription quota exhausted.",
        "resetAt" => "2999-01-01T00:00:00Z"
      }

      :ok = apply(@server, :handle_event, [event, %{}])
      settle()
      assert %{"status" => "queued"} = review()

      assert take(@ask) == {:error, "Reviews are paused on this machine."}
    end

    test "is refused once its run of that commit failed here, unless the user asked again" do
      review = start_review()
      event = %{"type" => "turn.finished", "threadId" => review["threadId"], "status" => "failed"}
      :ok = apply(@server, :handle_event, [event, %{}])
      settle()
      assert %{"status" => "failed"} = review()

      assert take(@ask) == {:error, "Its review failed on this machine at this commit."}
      assert take(%{@ask | "trigger" => "user"}) == {:ok, nil}
      settle()
      assert %{"status" => "running"} = review()
    end

    test "is had already by a machine that reviewed that commit, which does not review it again" do
      first = start_review()
      arguments = %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []}
      {:ok, _} = HalC2.Plugins.call_tool("code_review_report", arguments, first["threadId"])
      settle()
      assert %{"status" => "waiting", "threadId" => thread_id} = review()

      assert take(@ask) == {:ok, nil}
      settle()
      assert %{"status" => "waiting", "threadId" => ^thread_id} = review()
    end
  end

  describe "a review another machine hands over, checked against" do
    @ask %{"repository" => "acme/api", "number" => 1, "trigger" => "watch"}

    test "the host of its project, as one of that name on another forge is another" do
      assert take(Map.put(@ask, "host", "gitlab.com")) ==
               {:error, "No project on this MC has the repository acme/api on gitlab.com."}

      assert take(Map.put(@ask, "host", "github.com")) == {:ok, nil}
      settle()
      assert %{"status" => "running"} = review()
    end

    test "a review of that commit kept in HAL-C2 here, which is not reviewed again" do
      save_settings(%{"publishing" => "local"})
      first = start_review()
      arguments = %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []}
      {:ok, _} = HalC2.Plugins.call_tool("code_review_report", arguments, first["threadId"])
      settle()
      assert %{"status" => "kept", "threadId" => thread_id} = review()

      assert take(@ask) == {:ok, nil}
      settle()
      assert %{"status" => "kept", "threadId" => ^thread_id} = review()
    end
  end

  # The machine handing a review over read the pull request after a push this machine
  # has not seen yet: the user's approval there is of the head read with it.
  # (Its name has no quote in it: the fake ssh runs in a directory named after it.)
  test "a review handed over approved there starts at the head read with it",
       context do
    sandboxed!(context)
    settle()
    {:error, _} = call("start", %{"repository" => "acme/api", "number" => 1})
    first = context.shas[1]
    assert %{"status" => "ready", "headSha" => ^first} = review()

    push!(context, 2)
    rules!(context, head: 2, association: "NONE")
    second = context.shas[2]
    ask = %{"repository" => "acme/api", "number" => 1, "trigger" => "user"}
    assert take(Map.put(ask, "approved", second)) == {:ok, nil}

    assert_receive {:sandbox_reported, 200, _}, 15_000
    assert_receive {:openshell_request, "DeleteSandbox", _}, 15_000
    settle()
    assert %{"status" => "waiting", "headSha" => ^second, "approved" => ^second} = review()
  end

  # This machine kept the user's approval of the head, and its run of it failed. The
  # machine handing it over saw a push since, the head pushed back after it: its ask
  # brings no approval, and the one kept here is no longer the user's.
  test "a review handed over unapproved there waits for the user, whatever was approved here",
       context do
    %{gateway: gateway} = sandboxed!(context)
    settle()
    {:error, _} = call("start", %{"repository" => "acme/api", "number" => 1})
    first = context.shas[1]
    FakeOpenShell.failing(gateway, ["CreateSandbox"])
    {:ok, _} = call("approve", %{"key" => @key, "headSha" => first})
    await_review(&(&1["status"] == "failed"))
    assert %{"approved" => ^first, "headSha" => ^first} = review()
    FakeOpenShell.failing(gateway, [])

    ask = %{"repository" => "acme/api", "number" => 1, "trigger" => "user"}
    assert {:error, message} = take(ask)
    assert message =~ "Approve it on the Reviews page"
    settle()
    assert %{"status" => "failed", "approved" => nil} = review()
  end

  # The machine that handed this one a review heard the user stopped it there only
  # once this one had taken it (`untake/1`).
  describe "a review handed over that the user stopped on the machine handing it" do
    test "is stopped here while it runs, its checkout gone" do
      %{"checkout" => checkout} = start_review()
      assert untake() == {:ok, nil}
      settle()
      assert %{"status" => "failed", "stopped" => true, "error" => "Stopped."} = review()
      refute File.dir?(checkout)
    end

    test "is stopped here before it starts" do
      %{"threadId" => thread_id} = start_review()

      event = %{
        "type" => "turn.finished",
        "threadId" => thread_id,
        "status" => "failed",
        "errorClass" => "usage_limit",
        "error" => "Subscription quota exhausted.",
        "resetAt" => "2999-01-01T00:00:00Z"
      }

      :ok = apply(@server, :handle_event, [event, %{}])
      settle()
      # The checkout of the run the limit stopped goes with it.
      assert %{"status" => "queued", "checkout" => checkout} = review()
      assert File.dir?(checkout)

      assert untake() == {:ok, nil}
      settle()
      assert %{"status" => "failed", "stopped" => true, "error" => "Stopped."} = review()
      refute File.dir?(checkout)
    end

    test "leaves a review that is over as it is" do
      assert untake() == {:ok, nil}
      refute review()
    end
  end

  # From the proof model of claims between machines: a machine handed a review that
  # another machine claimed at that head queued it, stepped back from that claim and
  # had no row left, so the machine handing it over, out of reach of the claim, read
  # that no one had it and handed it over again for as long as it was.
  @tag :laptop
  test "a review handed over that another machine claimed at that head is left there, and answers where",
       %{laptop: laptop} = context do
    head = context.shas[1]
    row = %{"sha" => head, "status" => "running", "claimed" => true}
    :ok = :erpc.call(laptop.node, :persistent_term, :put, [:claims, %{@key => row}])
    save_settings(%{"activation" => "automatic", "reviewNewPushes" => true})
    refresh()

    assert %{"status" => "ready", "elsewhere" => %{"machine" => "laptop", "claimed" => true}} =
             review()

    ask = %{"repository" => "acme/api", "number" => 1, "trigger" => "watch"}
    assert {:ok, %{"machine" => "laptop", "claimed" => true}} = take(ask)
    settle()
    assert %{"status" => "ready", "elsewhere" => %{"machine" => "laptop"}} = review()
  end

  # Compiled when the plugin starts, so unknown to the compiler here.
  defp take(ask), do: apply(@server, :take, [ask])
  defp untake, do: apply(@server, :untake, [%{"repository" => "acme/api", "number" => 1}])

  defmodule Unreached do
    @moduledoc false
    # The cluster's distribution, with no member ever connected.
    def start(_dir, _id), do: :ok
    def connected, do: []
    def disconnect(_mc), do: :ok
    def send(_mc, _message), do: :ok
    def version_changed(_dir), do: :ok
  end

  # What the clients show of a held review follows whether the machines it waits on are
  # in reach, so a machine coming back publishes it.
  test "a review held while a machine could not hear of its start is published again once that machine is back",
       context do
    first = start_review()
    arguments = %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []}
    {:ok, _} = HalC2.Plugins.call_tool("code_review_report", arguments, first["threadId"])
    settle()
    save_settings(%{"activation" => "automatic", "reviewNewPushes" => true})
    push!(context, 2)
    rules!(context, head: 2)
    refresh()
    assert %{"status" => "running", "threadId" => thread_id} = review()
    peer = "hal_c2@laptop.hal-c2"

    assert GenServer.call(@server, {:told, @key, thread_id, [peer], []}) == :limited
    assert %{"status" => "ready", "limited" => %{"apart" => [^peer]}} = review()

    {:ok, _} = HalC2.Plugins.subscribe_topic(self(), "code-review", "reviews")
    send(Process.whereis(@server), {:nodeup, String.to_atom(peer)})

    assert_receive {:hal_c2_plugin_topic, _, "code-review", "reviews", %{"reviews" => [_ | _]}},
                   1_000
  end

  test "a review held while a machine could not hear of its start is published again once that machine is gone again",
       context do
    first = start_review()
    arguments = %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []}
    {:ok, _} = HalC2.Plugins.call_tool("code_review_report", arguments, first["threadId"])
    settle()
    save_settings(%{"activation" => "automatic", "reviewNewPushes" => true})
    push!(context, 2)
    rules!(context, head: 2)
    refresh()
    assert %{"status" => "running", "threadId" => thread_id} = review()
    peer = "hal_c2@laptop.hal-c2"

    assert GenServer.call(@server, {:told, @key, thread_id, [peer], []}) == :limited
    assert %{"status" => "ready", "limited" => %{"apart" => [^peer]}} = review()

    {:ok, _} = HalC2.Plugins.subscribe_topic(self(), "code-review", "reviews")
    send(Process.whereis(@server), {:nodedown, String.to_atom(peer)})

    assert_receive {:hal_c2_plugin_topic, _, "code-review", "reviews", %{"reviews" => [_ | _]}},
                   1_000
  end

  # A review run again keeps the run before it for its own prompt; clients never read
  # it, so what they are sent leaves it out.
  test "a review run again on a new head sends clients none of the run before it",
       context do
    first = start_review()
    arguments = %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []}
    {:ok, _} = HalC2.Plugins.call_tool("code_review_report", arguments, first["threadId"])
    settle()
    save_settings(%{"activation" => "automatic", "reviewNewPushes" => true})
    push!(context, 2)
    rules!(context, head: 2)
    refresh()

    reviewed = first["reviewedSha"]

    assert %{
             "previous" => %{
               "verdict" => "approve",
               "summary" => "Looks right.",
               "reviewedSha" => ^reviewed
             }
           } = :sys.get_state(@server).reviews[@key]

    assert %{"status" => "running"} = shown = review()
    refute Map.has_key?(shown, "previous")
  end

  # Clients make a script value of every `reviews` they are sent, findings and all, so
  # a change that leaves what they show as it was sends nothing.
  test "the reviews clients follow are sent again only when they changed" do
    first = start_review()
    {:ok, _} = HalC2.Plugins.subscribe_topic(self(), "code-review", "reviews")

    # Asking again for the running review changes nothing the clients show.
    {:ok, _} = call("start", %{"repository" => "acme/api", "number" => 1})
    arguments = %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []}
    {:ok, _} = HalC2.Plugins.call_tool("code_review_report", arguments, first["threadId"])
    settle()

    # The first `reviews` sent is the report's, not the same value again.
    assert_receive {:hal_c2_plugin_topic, _, "code-review", "reviews", %{"reviews" => sent}},
                   1_000

    assert %{"status" => status} = Enum.find(sent, &(&1["key"] == @key))
    assert status != "running"
  end

  # A run reads where other machines have its head when it steps back, so a run the
  # limit held back, back at a head it never reviewed, showed it was limited while the
  # laptop had that head published.
  @tag :laptop
  test "a review the limit holds back shows where another machine has its head",
       %{laptop: laptop} = context do
    first = start_review()
    arguments = %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []}
    {:ok, _} = HalC2.Plugins.call_tool("code_review_report", arguments, first["threadId"])
    settle()
    save_settings(%{"activation" => "automatic", "reviewNewPushes" => true})
    push!(context, 2)
    rules!(context, head: 2)
    refresh()
    assert %{"status" => "running", "threadId" => thread_id} = review()

    # The pull request is back at the first head, which the laptop has published.
    back = context.shas[1]
    row = %{"sha" => back, "status" => "published", "claimed" => true}
    :ok = :erpc.call(laptop.node, :persistent_term, :put, [:claims, %{@key => row}])
    push!(context, 1)
    rules!(context, head: 1)
    refresh()
    assert %{"status" => "running", "headSha" => ^back} = review()

    # A desk machine out of reach never heard of the run starting.
    desk = "hal_c2@desk.hal-c2"
    assert GenServer.call(@server, {:told, @key, thread_id, [desk], []}) == :limited

    # The read of the laptop's claims it sends itself goes out once the server takes it.
    :sys.get_state(@server)
    settle()

    assert %{
             "status" => "ready",
             "limited" => %{"apart" => [^desk]},
             "elsewhere" => %{"machine" => "laptop", "status" => "published", "claimed" => true}
           } = review()
  end

  test "a review run again with the same findings is not published on what the run before showed",
       context do
    review = start_review()
    arguments = %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []}
    {:ok, _} = HalC2.Plugins.call_tool("code_review_report", arguments, review["threadId"])
    settle()
    looked = seen()

    {:ok, _} = call("retry", %{"key" => @key})
    settle()
    assert %{"status" => "running", "threadId" => again} = review()
    assert again != review["threadId"]
    {:ok, _} = HalC2.Plugins.call_tool("code_review_report", arguments, again)
    settle()

    assert %{"status" => "waiting", "version" => version} = review()
    assert version != looked["version"]
    assert {:error, %{"message" => message}} = call("publish", looked)
    assert message =~ "changed since you looked at it"
    assert posts(context) == []
  end

  # A path the agent named, in the review of another commit, can carry any marker.
  test "a review that names the marker of this commit inside its text does not stop the post",
       context do
    posted = reviewed_by("monalisa")
    marker = posted["body"] |> String.split("\n\n") |> List.last()
    other = "<!-- hal-c2-code-review:#{@key}@#{String.duplicate("0", 40)} -->"
    body = "One.\n\n- `src/#{marker}.ts:1` — One.\n\n#{other}"
    rules!(context, head: 1, reviews: [%{posted | "body" => body}])

    assert {:ok, _} = call("publish", seen())
    assert %{"status" => "published", "publishNote" => nil} = review()
    assert [_] = posts(context)
  end

  test "a thread whose review is published is told so when it reports again", _context do
    review = start_review()
    arguments = %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []}
    {:ok, _} = HalC2.Plugins.call_tool("code_review_report", arguments, review["threadId"])
    {:ok, _} = call("publish", seen())
    settle()

    assert {:error, "plugin_failed", message, _} =
             HalC2.Plugins.call_tool("code_review_report", arguments, review["threadId"])

    assert message =~ "already published"
  end

  test "stopping an idle thread cancels the task it left working, so nothing wakes it",
       context do
    review = start_review()
    thread_id = review["threadId"]

    {:ok, %{"taskId" => task_id, "childThreadId" => child}} =
      HalC2.Orchestration.Delegation.delegate(%{"id" => thread_id}, "codex", %{"task" => "wait"})

    {:ok, %{"taskId" => nested_id, "childThreadId" => nested}} =
      HalC2.Orchestration.Delegation.delegate(%{"id" => child}, "codex", %{"task" => "wait"})

    File.write!(Path.join(context.dir, "gate/answer"), "")
    await_idle(thread_id)
    event = %{"type" => "turn.finished", "threadId" => thread_id, "status" => "failed"}
    :ok = apply(@server, :handle_event, [event, %{}])
    settle()

    {:ok, _} = call("discard", %{"key" => @key})

    assert {:ok, %{"status" => "cancelled"}} =
             HalC2.Orchestration.Delegation.task_status(thread_id, task_id)

    assert {:ok, %{"status" => "cancelled"}} =
             HalC2.Orchestration.Delegation.task_status(child, nested_id)

    for stopped <- [thread_id, child, nested] do
      assert active_runs(stopped) == []
      assert sessions_stopped?(stopped)
    end

    runs = HalC2.StreamState.list(HalC2.Streams.state(thread_id), "run")
    assert [%{"status" => status}] = runs
    assert status not in ~w(queued preparing starting running waiting)
    refute File.exists?(review["checkout"])
  end

  test "stopping a thread cancels its queue, so no run starts in the removed checkout",
       _context do
    review = start_review()
    thread_id = review["threadId"]

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "threadId" => thread_id,
        "messageId" => "queued-message",
        "text" => "and another thing",
        "attachments" => [],
        "dispatchMode" => %{"type" => "queue_after_active"}
      })

    assert :ok = HalC2.Orchestration.stop_plugin_thread(thread_id, @id)

    runs = HalC2.StreamState.list(HalC2.Streams.state(thread_id), "run")
    assert length(runs) == 2
    assert Enum.count(runs, &(&1["status"] == "cancelled")) == 1
    assert active_runs(thread_id) == []
    assert sessions_stopped?(thread_id)
  end

  # The turn's end starts what is queued, off the runtime's process, so a queue cancelled
  # only after the interrupt races it (the agent's answer to the stop is held here, so
  # with that order the queue is still there to see).
  test "a stop cancels the queue before it asks the agent to stop", context do
    hold = hold_interrupts(context)
    review = start_review()
    thread_id = review["threadId"]

    queue_message(thread_id, "queued-message")
    :ok = HalC2.Streams.watch(thread_id, self())
    stop = Task.async(fn -> HalC2.Orchestration.stop_plugin_thread(thread_id, @id) end)
    state = await_interrupt_requested(thread_id)
    File.rm!(hold)
    assert :ok = Task.await(stop, 15_000)

    assert run_of(state, "queued-message")["status"] == "cancelled"
    assert run_of(HalC2.Streams.state(thread_id), "queued-message")["status"] == "cancelled"
  end

  test "a stop cancels the queue of a task before it asks the agent of the task to stop",
       context do
    hold = hold_interrupts(context)
    review = start_review()

    {:ok, %{"childThreadId" => child}} =
      HalC2.Orchestration.Delegation.delegate(%{"id" => review["threadId"]}, "codex", %{
        "task" => "wait"
      })

    queue_message(child, "queued-message")
    :ok = HalC2.Streams.watch(child, self())
    stop = Task.async(fn -> HalC2.Orchestration.stop_plugin_thread(review["threadId"], @id) end)
    state = await_interrupt_requested(child)
    File.rm!(hold)
    assert :ok = Task.await(stop, 15_000)

    assert run_of(state, "queued-message")["status"] == "cancelled"
    assert run_of(HalC2.Streams.state(child), "queued-message")["status"] == "cancelled"
  end

  test "a message queued mid-stop that a run starts is stopped before the stop answers",
       context do
    hold = hold_interrupts(context)
    review = start_review()
    assert_stop_stops_what_was_queued_meanwhile(review, review["threadId"], hold)
  end

  test "a message queued on a task mid-stop that a run starts is stopped before the stop answers",
       context do
    hold = hold_interrupts(context)
    review = start_review()

    {:ok, %{"childThreadId" => child}} =
      HalC2.Orchestration.Delegation.delegate(%{"id" => review["threadId"]}, "codex", %{
        "task" => "wait"
      })

    assert_stop_stops_what_was_queued_meanwhile(review, child, hold)
  end

  test "a message sent after the pass of a stop runs while a task below it is held up",
       context do
    review = start_review()
    thread_id = review["threadId"]

    # Only the Codex of the task holds its interrupt: the thread's next one starts without it.
    hold = hold_interrupts(context)

    {:ok, %{"childThreadId" => child}} =
      HalC2.Orchestration.Delegation.delegate(%{"id" => thread_id}, "codex", %{"task" => "wait"})

    await_stream(child, &running?/1)
    System.delete_env("FAKE_CODEX_HOLD_INTERRUPT")

    assert :busy = HalC2.Orchestration.stop_plugin_thread(thread_id, @id, 100)
    await_sessions_stopped(thread_id)

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "threadId" => thread_id,
        "messageId" => "next",
        "text" => "wait",
        "attachments" => [],
        "dispatchMode" => %{"type" => "queue_after_active"}
      })

    await_stream(thread_id, &running?/1)
    queue_message(thread_id, "behind")

    # The turn ends without holding the queue, as a user's Stop would.
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "threadId" => thread_id,
        "holdQueue" => false
      })

    await_stream(thread_id, &(run_of(&1, "behind")["startedAt"] != nil))

    File.rm!(hold)
    await_sessions_stopped(child)
  end

  test "a stop walks through a task that already ended to the task below it", _context do
    review = start_review()
    thread_id = review["threadId"]

    {:ok, %{"taskId" => task_id, "childThreadId" => child}} =
      HalC2.Orchestration.Delegation.delegate(%{"id" => thread_id}, "codex", %{"task" => "wait"})

    {:ok, %{"taskId" => nested_id, "childThreadId" => nested}} =
      HalC2.Orchestration.Delegation.delegate(%{"id" => child}, "codex", %{"task" => "wait"})

    {:ok, _} = HalC2.Orchestration.Delegation.cancel(thread_id, task_id)

    assert :ok = HalC2.Orchestration.stop_plugin_thread(thread_id, @id)

    assert {:ok, %{"status" => "cancelled"}} =
             HalC2.Orchestration.Delegation.task_status(child, nested_id)

    assert active_runs(nested) == []
    assert sessions_stopped?(nested)
  end

  test "a stop outlasts the deadline of its caller on an agent slow to go", context do
    System.put_env("FAKE_CODEX_IGNORE_INTERRUPT", "1")
    on_exit(fn -> System.delete_env("FAKE_CODEX_IGNORE_INTERRUPT") end)
    review = start_review()

    assert :busy = HalC2.Orchestration.stop_plugin_thread(review["threadId"], @id, 100)
    assert [_] = active_runs(review["threadId"])

    # The agent goes in its own time, after the caller stopped waiting, and is released.
    File.write!(Path.join(context.dir, "gate/answer"), "")
    await_sessions_stopped(review["threadId"])
    assert active_runs(review["threadId"]) == []
  end

  test "only the plugin that started a thread can stop it", _context do
    review = start_review()

    assert {:error, _} = HalC2.Orchestration.stop_plugin_thread(review["threadId"], "other")
    assert [_] = active_runs(review["threadId"])
  end

  test "a push to a followed pull request is seen after its repository stops being watched",
       context do
    review = start_review()

    {:ok, _} =
      HalC2.Plugins.call_tool(
        "code_review_report",
        %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []},
        review["threadId"]
      )

    save_settings(%{"repositories" => []})
    push!(context, 2)
    rules!(context, head: 2)
    refresh()

    assert %{"changed" => true, "headSha" => head} = review()
    assert head == context.shas[2]
  end

  test "a review stopped by a usage limit waits in the queue instead of failing", context do
    review = start_review()
    reset = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

    :ok =
      apply(@server, :handle_event, [
        %{
          "type" => "turn.finished",
          "threadId" => review["threadId"],
          "status" => "failed",
          "errorClass" => "usage_limit",
          "error" => "Subscription quota exhausted.",
          "resetAt" => reset
        },
        %{}
      ])

    settle()
    assert %{"status" => "queued"} = review()
    assert GenServer.call(@server, :snapshot)["problem"] =~ "usage limit"
    _ = context
  end

  @tag sandbox: [hang: true]
  test "an approval given again after a run stopped at a usage limit queues the review again",
       context do
    context = Map.merge(context, sandboxed!(context))
    settle()
    {:error, _} = call("start", %{"repository" => "acme/api", "number" => 1})
    {:ok, _} = call("approve", %{"key" => @key, "headSha" => context.shas[1]})
    assert_receive {:sandbox_turn, _}, 15_000
    assert %{"status" => "running", "threadId" => thread_id} = review()
    reset = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

    :ok =
      apply(@server, :handle_event, [
        %{
          "type" => "turn.finished",
          "threadId" => thread_id,
          "status" => "failed",
          "errorClass" => "usage_limit",
          "error" => "Subscription quota exhausted.",
          "resetAt" => reset
        },
        %{}
      ])

    settle()
    assert %{"status" => "queued", "reviewedSha" => sha} = review()
    assert sha == context.shas[1]
    # Its sandbox was deleted, files and all; the fake's directory outlives it.
    assert_receive {:openshell_request, "DeleteSandbox", _}, 5_000
    File.rm_rf!(Path.join(context.sandbox_root, "src"))

    {:ok, _} = call("unapprove", %{"key" => @key})
    assert %{"status" => "ready"} = review()

    # Its commit was checked out, but nothing reviewed it: approved again, it is queued.
    {:ok, _} = call("approve", %{"key" => @key, "headSha" => context.shas[1]})
    settle()
    assert review()["status"] in ~w(queued running)
  end

  test "a finished review settles its thread in the sidebar", context do
    review = start_review()

    {:ok, _} =
      HalC2.Plugins.call_tool(
        "code_review_report",
        %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []},
        review["threadId"]
      )

    settle()
    assert %{"settledOverride" => "settled"} = thread(review["threadId"])
    _ = context
  end

  test "a report whose validation lacks a reason goes back to the agent, and the review runs on",
       context do
    review = start_review()

    assert {:error, "plugin_failed", message, _} =
             HalC2.Plugins.call_tool(
               "code_review_report",
               %{
                 "verdict" => "approve",
                 "summary" => "Looks right.",
                 "validation" => %{"notRun" => [%{"check" => "the full suite", "reason" => " "}]}
               },
               review["threadId"]
             )

    assert message =~ "each validation.notRun entry needs a check and a reason"

    assert %{"status" => "running"} =
             GenServer.call(HalC2Plugins.CodeReview, :reviews)[review["key"]]

    _ = context
  end

  test "showing reviews on the page only unlists review threads there already are", context do
    review = start_review()
    assert %{"plugin" => %{"listed" => true}} = thread(review["threadId"])

    save_settings(%{"display" => "page"})
    settle()
    assert %{"plugin" => %{"listed" => false}} = thread(review["threadId"])

    save_settings(%{"display" => "both"})
    settle()
    assert %{"plugin" => %{"listed" => true}} = thread(review["threadId"])
    _ = context
  end

  test "the last display saved is the one review threads end with", context do
    review = start_review()
    thread_id = review["threadId"]
    hook = {__MODULE__, :hold, [thread_id, Process.whereis(@server), self()]}
    Application.put_env(:hal_c2, :streams_hook, hook)
    on_exit(fn -> Application.delete_env(:hal_c2, :streams_hook) end)

    # The listing for the page is held on its way to the thread...
    put_settings(%{"display" => "page"})
    assert_receive {:held, unlisting}, 5_000
    Application.delete_env(:hal_c2, :streams_hook)

    # ...while the threads are shown again, and lands after it.
    put_settings(%{"display" => "threads"})
    settle([unlisting])
    send(unlisting, :go)
    settle()

    assert %{"plugin" => %{"listed" => true}} = thread(thread_id)
    _ = context
  end

  test "a review discarded while the threads are listed again stays out of the list", context do
    review = start_review()
    thread_id = review["threadId"]

    {:ok, _} =
      HalC2.Plugins.call_tool(
        "code_review_report",
        %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []},
        thread_id
      )

    save_settings(%{"display" => "page"})
    hook = {__MODULE__, :hold, [thread_id, Process.whereis(@server), self()]}
    Application.put_env(:hal_c2, :streams_hook, hook)
    on_exit(fn -> Application.delete_env(:hal_c2, :streams_hook) end)

    # The listing for the threads is held on its way to the thread...
    put_settings(%{"display" => "threads"})
    assert_receive {:held, listing}, 5_000
    Application.delete_env(:hal_c2, :streams_hook)

    # ...while the review is discarded, and must not list it after it is gone.
    {:ok, _} = call("discard", %{"key" => @key})
    send(listing, :go)
    settle()

    assert %{"plugin" => %{"listed" => false}} = thread(thread_id)
    _ = context
  end

  test "a display saved while the checkout of a review is fetched lists its thread as it now says",
       context do
    hold = Path.join(context.dir, "fetch.hold")
    File.write!(hold, "")
    on_exit(fn -> File.rm(hold) end)
    {:ok, _} = call("start", %{"repository" => "acme/api", "number" => 1})
    await_file(Path.join(context.dir, "fetch.held"))

    put_settings(%{"display" => "page"})
    File.rm!(hold)
    settle()

    assert %{"status" => "running", "threadId" => thread_id} = review()
    assert %{"plugin" => %{"listed" => false}} = thread(thread_id)
  end

  test "a review runs with the model options picked in the settings", context do
    save_settings(%{"modelOptions" => %{"reasoningEffort" => "high", "effort" => "high"}})
    review = start_review()

    assert %{"modelSelection" => %{"options" => options}} = thread(review["threadId"])
    assert %{"value" => "high"} = Enum.find(options, &(&1["id"] in ["reasoningEffort", "effort"]))
    _ = context
  end

  test "model options a known model does not offer are left out of its run", context do
    save_settings(%{"model" => "", "modelOptions" => %{"reasoningEffort" => "high"}})
    review = start_review()

    assert %{"modelSelection" => selection} = thread(review["threadId"])
    assert selection["model"] in ["gpt-6-luna", "gpt-5.5"]
    refute Map.has_key?(selection, "options")
    _ = context
  end

  test "a usage-limit pause holds across a restart of the plugin", context do
    review = start_review()
    reset = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

    :ok =
      apply(@server, :handle_event, [
        %{
          "type" => "turn.finished",
          "threadId" => review["threadId"],
          "status" => "failed",
          "errorClass" => "usage_limit",
          "error" => "Subscription quota exhausted.",
          "resetAt" => reset
        },
        %{}
      ])

    settle()
    assert %{"status" => "queued"} = review()

    # Neither a save, which starts queued reviews when it makes room, nor a restart,
    # nor the timed look after it starts the queue into the limit. "Look now" is the
    # user's ask and ends the pause, so the look here is the timer's.
    save_settings(%{"concurrency" => 2})
    assert %{"status" => "queued"} = review()
    {:ok, _} = HalC2.Plugins.handle("restart", %{"id" => @id})
    settle()
    send(@server, :poll)
    await_look()
    settle()
    assert %{"status" => "queued"} = review()
    assert GenServer.call(@server, :snapshot)["problem"] =~ "usage limit"
    _ = context
  end

  test "a review under way keeps running through a settings save", context do
    review = start_review()
    pid = Process.whereis(@server)

    save_settings(%{"concurrency" => 2, "display" => "both", "repositories" => []})

    assert Process.whereis(@server) == pid
    assert %{"status" => "running", "threadId" => thread_id} = review()
    assert thread_id == review["threadId"]
    assert GenServer.call(@server, :snapshot)["watching"] == []
    _ = context
  end

  test "a new pace re-arms the wait for the next look, and only once", context do
    pid = Process.whereis(@server)
    %{timer: armed} = await_look()
    assert Process.read_timer(armed) > 59 * 60_000

    save_settings(%{"pollMinutes" => 5})

    %{timer: timer} = :sys.get_state(pid)
    refute Process.read_timer(armed)
    assert Process.read_timer(timer) in 1..(5 * 60_000)
    _ = context
  end

  test "a review saved before following was kept stays followed on an automatic re-queue",
       context do
    review = start_review()

    {:ok, _} =
      HalC2.Plugins.call_tool(
        "code_review_report",
        %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []},
        review["threadId"]
      )

    settle()

    # As reviews.json looked before the following flag: no such key.
    file = Path.join([context.dir, "home", "plugin-data", "code-review", "reviews.json"])
    saved = file |> File.read!() |> JSON.decode!()
    saved = put_in(saved, ["reviews", @key], Map.delete(saved["reviews"][@key], "following"))
    File.write!(file, JSON.encode!(saved))

    save_settings(%{"activation" => "automatic", "reviewNewPushes" => true})
    push!(context, 2)
    rules!(context, head: 2)
    refresh()

    assert %{"status" => "running", "following" => true} = review()
  end

  test "a plugin unsettling its thread clears the override, so it can settle again",
       context do
    review = start_review()

    {:ok, _} =
      HalC2.Plugins.call_tool(
        "code_review_report",
        %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []},
        review["threadId"]
      )

    settle()
    assert %{"settledOverride" => "settled"} = thread(review["threadId"])

    :ok =
      HalC2.Orchestration.organize_plugin_thread(review["threadId"], @id, %{"settled" => false})

    assert %{"settledOverride" => nil} = thread(review["threadId"])

    :ok =
      HalC2.Orchestration.organize_plugin_thread(review["threadId"], @id, %{"settled" => true})

    assert %{"settledOverride" => "settled"} = thread(review["threadId"])
    _ = context
  end

  # From the Maude model of claims between machines: a look that listed the old head
  # was applied after the run had claimed the new one and reported, and queued the
  # review again, which gave up its claim for another machine to start the commit.
  test "a look begun before a run claimed its commit does not queue the review again",
       context do
    save_settings(%{"reviewNewPushes" => true})
    at = System.monotonic_time()
    review = start_review()

    {:ok, _} =
      HalC2.Plugins.call_tool(
        "code_review_report",
        %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []},
        review["threadId"]
      )

    settle()
    %{"status" => reported} = review()

    entry =
      review
      |> Map.take(
        ~w(key repository number projectId title url author headBranch baseBranch isDraft labels reviewRequested changedLines updatedAt)
      )
      |> Map.put("headSha", String.duplicate("0", 40))

    found = %{
      at: at,
      problem: nil,
      unwatched: [],
      entries: [entry],
      read: [],
      sizes: %{},
      unknown_sizes: [],
      asked: %{},
      closed: [],
      elsewhere: %{}
    }

    send(Process.whereis(@server), {:polled, found})
    settle()
    assert %{"status" => ^reported} = review()
    assert %{@key => %{"claimed" => true}} = apply(@server, :claims, [[@key]])
    _ = context
  end

  # From the property model of claims between machines: a look that listed the new head
  # was left alone for beginning before the run claimed, and nothing looked again, so
  # the review showed the old head until the next look on the timer.
  test "a look begun before a run claimed that lists another head is followed by a new look",
       context do
    at = System.monotonic_time()
    review = start_review()
    second = context.shas[2]
    push!(context, 2)
    rules!(context, head: 2)

    send(Process.whereis(@server), {:polled, listing(review, at, second)})
    :sys.get_state(@server)
    settle()
    assert %{"status" => "running", "headSha" => ^second} = review()
  end

  test "a look begun before a run claimed that lists the head it holds starts no other",
       context do
    at = System.monotonic_time()
    %{"headSha" => head} = review = start_review()
    lists = list_calls(context)

    send(Process.whereis(@server), {:polled, listing(review, at, head)})
    :sys.get_state(@server)
    settle()
    assert list_calls(context) == lists
  end

  # From the Maude model of claims between machines: while the plugin restarted, its
  # claims were gone with its server and a peer read them as none, so it started the
  # commit this machine's review thread was still on.
  test "a plugin restarting tells its peers it cannot say what it holds, then holds it again",
       context do
    start_review()
    pid = Process.whereis(@server)
    {:parent, sup} = Process.info(pid, :parent)
    :sys.suspend(sup)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    assert {:ok, %{"result" => :restarting}} =
             HalC2.Plugins.Host.peer(@id, :claims, [[@key]])

    :sys.resume(sup)
    :sys.get_state(sup)
    assert %{@key => %{"claimed" => true}} = apply(@server, :claims, [[@key]])
    _ = context
  end

  # From the Maude model of claims between machines: a review queued again for a new
  # push gave up its claim on the commit it had reviewed and posted, so a machine
  # whose checkout of that commit was under way started and posted it again.
  test "a review queued for a new push still holds the commit it reviewed", context do
    save_settings(%{"reviewNewPushes" => true})
    review = start_review()

    {:ok, _} =
      HalC2.Plugins.call_tool(
        "code_review_report",
        %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []},
        review["threadId"]
      )

    settle()
    %{"status" => reported, "reviewedSha" => reviewed} = review()
    push!(context, 2)
    rules!(context, head: 2)
    refresh()

    assert %{"status" => "running", "reviewedSha" => head} = review()
    assert head != reviewed

    assert %{@key => %{"sha" => ^head, "held" => %{"sha" => ^reviewed, "status" => ^reported}}} =
             apply(@server, :claims, [[@key]])
  end

  # From the Maude model of claims between machines: a machine that posted a review
  # and stopped before it saved so loaded it as waiting, and nothing it or another
  # machine had kept said it was posted, so a publish posted the commit again.
  test "a review GitHub already has under the login gh uses is published without posting it again",
       context do
    rules!(context, head: 1, reviews: [reviewed_by("monalisa")])
    assert {:ok, _} = call("publish", seen())

    assert %{"status" => "published", "publishError" => nil, "publishNote" => note} = review()
    assert note =~ "already on the pull request"
    assert posts(context) == []
  end

  test "a review of the same commit under another login does not stop the post",
       context do
    rules!(context, head: 1, reviews: [reviewed_by("octocat")])
    assert {:ok, _} = call("publish", seen())
    assert %{"status" => "published", "publishNote" => nil} = review()
    assert [_] = posts(context)
  end

  # From the property model of hal-c2/hal-c2#688: a post waiting behind one GitHub still
  # held went out when its turn came, though the review had been run again since, and the
  # new run's own post then found its commit already on the pull request.
  test "a post whose run was replaced as it waited behind another posts nothing", context do
    hold = Path.join(context.dir, "post.hold")
    held = Path.join(context.dir, "post.held")
    File.write!(hold, "")

    rules!(context,
      head: 1,
      post: "touch '#{held}'; while [ -e '#{hold}' ]; do sleep 0.05; done"
    )

    report_findings()
    first = publishing()
    await_file(held)
    server = Process.whereis(@server)
    holder = kids(server)

    {:ok, _} = call("start", %{"repository" => "acme/api", "number" => 1})
    settle(holder)
    report_findings(holder)
    second = publishing()
    waiter = kids(server) -- holder

    {:ok, _} = call("start", %{"repository" => "acme/api", "number" => 1})
    settle(holder ++ waiter)
    assert %{"status" => "running", "checkout" => _} = review()

    File.rm!(hold)
    assert_receive {^first, {:ok, _}}, 15_000
    assert_receive {^second, {:error, message}}, 15_000
    assert message =~ "run again"
    settle()
    assert [_] = posts(context)
    assert %{"status" => "running"} = review()
  end

  # A run whose thread could not be made left its checkout for the review's next run,
  # which a review stopped, or failed and never started again, does not get.
  test "a review whose thread cannot be made keeps no checkout", context do
    fetch = Path.join(context.dir, "fetch.hold")
    hold = Path.join(context.dir, "detail.hold")
    on_exit(fn -> Enum.each([fetch, hold], &File.rm/1) end)
    rules!(context, head: 1, detail: "while [ -e '#{hold}' ]; do sleep 0.05; done")
    # Held at the fetch first, so the launch reads the pull request only once claimed.
    File.write!(fetch, "")
    {:ok, _} = call("start", %{"repository" => "acme/api", "number" => 1})
    await_file(Path.join(context.dir, "fetch.held"))
    File.write!(hold, "")
    File.rm!(fetch)
    await_review(&is_binary(&1["checkout"]))
    assert File.dir?(review()["checkout"])

    put_instance("codex", %{"enabled" => false})
    File.rm!(hold)
    settle()

    assert %{"status" => "failed", "error" => error} = review()
    assert error =~ "turned off"
    checkouts = Path.join(HalC2.Plugins.Host.data_dir("code-review"), "checkouts")
    assert Path.wildcard(Path.join(checkouts, "*/pr-1/*")) == []
  end

  # Stop reaches a run past its claim only through the server, so a launch reading the
  # pull request as Stop came went on to start the agent of a review shown as stopped.
  test "a review stopped between its claim and its launch never starts its agent", context do
    fetch = Path.join(context.dir, "fetch.hold")
    hold = Path.join(context.dir, "detail.hold")
    on_exit(fn -> Enum.each([fetch, hold], &File.rm/1) end)

    rules!(context,
      head: 1,
      detail: "while [ -e '#{hold}' ]; do sleep 0.05; done"
    )

    # Held at the fetch first, so the launch reads the pull request only once claimed.
    File.write!(fetch, "")
    {:ok, _} = call("start", %{"repository" => "acme/api", "number" => 1})
    await_file(Path.join(context.dir, "fetch.held"))
    File.write!(hold, "")
    File.rm!(fetch)
    await_review(&is_binary(&1["checkout"]))

    %{"checkout" => checkout, "threadId" => thread_id} = review()
    assert File.dir?(checkout)
    {:ok, _} = call("stop", %{"key" => @key})
    File.rm!(hold)
    settle()

    assert %{"status" => "failed", "error" => "Stopped."} = review()
    assert thread(thread_id) == nil
    checkouts = Path.join(HalC2.Plugins.Host.data_dir("code-review"), "checkouts")
    assert Path.wildcard(Path.join(checkouts, "*/pr-1/*")) == []
  end

  # Sandboxed reviews (#1412).
  describe "an untrusted pull request" do
    setup context, do: sandboxed!(context)

    test "is reviewed by an agent in a sandbox, which reports through the broker and is then deleted",
         %{gateway: g} do
      start_untrusted()

      # Codex runs in the sandbox's checkout, with none of this machine's environment.
      assert_receive {:sandbox_exec, ["codex", "app-server"],
                      %{workdir: "/review/src", environment: env}},
                     15_000

      refute Map.has_key?(env, "OPENAI_API_KEY")
      refute Map.has_key?(env, "PATH")
      assert env["HOME"] == "/review/home"

      # Codex reads its key from its login only: it signs in with the placeholder
      # OpenShell put in the sandbox's environment, never the key.
      assert_received {:sandbox_login, "openshell:resolve:env:fake_OPENAI_API_KEY"}

      assert_receive {:sandbox_reported, 200, body}, 15_000
      refute JSON.decode!(body)["result"]["isError"]
      assert_receive {:openshell_request, "DeleteSandbox", %{name: "review-" <> _ = name}}, 15_000
      assert_receive {:openshell_request, "DeleteProvider", %{name: ^name}}, 15_000

      settle()
      assert %{"sandboxed" => true, "verdict" => "approve", "status" => status} = review()
      assert status != "failed"
      assert FakeOpenShell.sandboxes(g) == %{}
      assert FakeOpenShell.providers(g) == %{}
    end

    test "is reviewed by Claude in a sandbox too, given the broker and no other tool of HAL-C2",
         %{gateway: g} do
      save_settings(%{"provider" => "claudeAgent", "model" => "claude-haiku-4-5"})
      start_untrusted()

      assert_receive {:sandbox_exec, ["claude" | args],
                      %{workdir: "/review/src", environment: env}},
                     15_000

      refute Map.has_key?(env, "ANTHROPIC_API_KEY")
      assert ["--allowedTools", "mcp__hal-c2"] in Enum.chunk_every(args, 2, 1)
      assert_receive {:sandbox_reported, 200, _}, 15_000
      assert_receive {:openshell_request, "DeleteProvider", _}, 15_000

      settle()
      assert %{"sandboxed" => true, "verdict" => "approve"} = review()
      assert FakeOpenShell.sandboxes(g) == %{}
    end

    # A sandboxed agent has no HAL-C2 workers, so keeping agents to them takes nothing.
    test "keeps the subagents of Claude in a sandbox while agents here are kept to the workers of HAL-C2" do
      {:ok, _} = HalC2.Settings.update(&Map.put(&1, "nativeSubagents", "hal-c2"))
      save_settings(%{"provider" => "claudeAgent", "model" => "claude-haiku-4-5"})
      start_untrusted()

      assert_receive {:sandbox_exec, ["claude" | args], _}, 15_000
      refute "--disallowedTools" in args
      assert_receive {:sandbox_reported, 200, _}, 15_000
      assert_receive {:openshell_request, "DeleteProvider", _}, 15_000
    end

    test "keeps the subagents of Codex in a sandbox while agents here are kept to the workers of HAL-C2" do
      {:ok, _} = HalC2.Settings.update(&Map.put(&1, "nativeSubagents", "hal-c2"))
      start_untrusted()

      assert_receive {:sandbox_thread_start, params}, 15_000
      refute get_in(params, ["config", "features"])
      assert_receive {:sandbox_reported, 200, _}, 15_000
      assert_receive {:openshell_request, "DeleteProvider", _}, 15_000
    end

    # Claude's launch arguments and home are this machine's: none of them reach the
    # sandbox or the agent's argv.
    test "gives Claude in a sandbox none of the launch arguments of this machine",
         %{tmp_dir: dir} do
      prompt = Path.join(dir, "host-prompt.txt")
      File.write!(prompt, "host-only instructions")

      launch_args =
        Enum.join(
          [
            ~s(--settings '{"env":{"HOST_TOKEN":"sk-host-token"},"apiKeyHelper":"host-helper"}'),
            "--mcp-config #{Path.join(dir, "host-mcp.json")}",
            "--add-dir #{dir}",
            "--append-system-prompt-file #{prompt}",
            "--dangerously-skip-permissions"
          ],
          " "
        )

      put_claude(%{"launchArgs" => launch_args, "homePath" => Path.join(dir, "claude-home")})
      assert_receive {:sandbox_exec, ["claude" | args], %{environment: env}}, 15_000
      argv = Enum.join(args, " ")

      for host <- [dir, "sk-host-token", "host-helper", "host-only", "--mcp-config"],
          do: refute(argv =~ host, "#{host} reached the sandbox's argv")

      refute "--dangerously-skip-permissions" in args
      refute Map.has_key?(env, "CLAUDE_CONFIG_DIR")
      refute Map.has_key?(env, "HOST_TOKEN")
      assert_receive {:sandbox_reported, 200, _}, 15_000
      assert_receive {:openshell_request, "DeleteProvider", _}, 15_000
    end

    # Loading it runs or reads the checkout's own configuration on this machine.
    test "loads no project environment for Claude in a sandbox", %{tmp_dir: dir} do
      HalC2.Settings.update(
        &Map.merge(&1, %{
          "projectEnvironment" => "dotenv",
          "projectEnvironmentFile" => Path.join(dir, "host.env")
        })
      )

      put_claude(%{})
      assert_receive {:sandbox_exec, ["claude" | _], _}, 15_000
      assert_receive {:sandbox_reported, 200, _}, 15_000
      assert_receive {:openshell_request, "DeleteProvider", _}, 15_000
      settle()

      # A file that is not there would have said so on the thread.
      %{"threadId" => thread_id} = review()
      items = HalC2.StreamState.get(HalC2.Streams.state(thread_id), "turn-item") || %{}
      refute Enum.any?(Map.keys(items), &String.starts_with?(&1, "turn-item:project-environment"))
    end

    # The sandbox runs the review image's Claude, not the one installed here.
    test "runs Claude in a sandbox on a model the Claude installed here is too old for",
         %{tmp_dir: dir} do
      claude = Path.join(dir, "old-claude")
      File.write!(claude, "#!/bin/sh\necho '2.1.0 (Claude Code)'\n")
      File.chmod!(claude, 0o755)
      put_instance("claudeAgent", %{"binaryPath" => claude})
      save_settings(%{"provider" => "claudeAgent", "model" => "claude-opus-5-5"})
      start_untrusted()

      assert_receive {:sandbox_exec, ["claude" | _], _}, 15_000
      assert_receive {:sandbox_reported, 200, _}, 15_000
      await_review(&(&1["verdict"] == "approve"))
    end

    # The sandbox runs the review image's Codex, not the one installed here.
    test "runs Codex in a sandbox while this release marks the Codex installed here broken" do
      FakeOpenShell.put_env(
        provider_compatibility: [
          %{
            "driver" => "codex",
            "halC2Range" => ">=0",
            "ranges" => [%{"range" => ">=0", "status" => "broken"}]
          }
        ]
      )

      start_untrusted()
      assert_receive {:sandbox_exec, ["codex", "app-server"], _}, 15_000
      assert_receive {:sandbox_reported, 200, _}, 15_000
      await_review(&(&1["verdict"] == "approve"))
    end

    # This machine's skills, and where they are, are not the sandbox's.
    test "sends Claude in a sandbox its message as written, with none of the skills of this machine",
         %{tmp_dir: dir} do
      home = Path.join(dir, "claude-home")

      for {name, frontmatter} <- [
            {"host-skill", "disable-model-invocation: true\n"},
            {"other-skill", ""}
          ] do
        skill = Path.join([home, "skills", name])
        File.mkdir_p!(skill)

        File.write!(
          Path.join(skill, "SKILL.md"),
          "---\ndescription: Here only.\n#{frontmatter}---\nDo it.\n"
        )
      end

      put_instance("claudeAgent", %{"homePath" => home})
      prompt = "Review with $host-skill and then $other-skill as asked"

      save_settings(%{
        "provider" => "claudeAgent",
        "model" => "claude-haiku-4-5",
        "prompt" => prompt
      })

      start_untrusted()
      assert_receive {:sandbox_prompt, content}, 15_000

      text =
        content
        |> List.wrap()
        |> Enum.map_join("\n", &if(is_map(&1), do: &1["text"], else: &1))

      assert text =~ prompt
      refute text =~ home
      assert_receive {:sandbox_reported, 200, _}, 15_000
    end

    # Claude keeps its task list in its own config folder, which in a sandbox is the
    # sandbox's: this machine's lists, whatever they are called, are not read.
    @tag sandbox: [task_update: %{"taskId" => "1", "status" => "in_progress"}]
    test "keeps the task list of Claude in a sandbox apart from the lists on this machine",
         %{tmp_dir: dir} do
      home = Path.join(dir, "claude-home")

      for list <- ["sandboxed-session", "host-list"] do
        tasks = Path.join([home, "tasks", list])
        File.mkdir_p!(tasks)

        File.write!(
          Path.join(tasks, "1.json"),
          JSON.encode!(%{"id" => "1", "subject" => "A task here", "status" => "pending"})
        )
      end

      put_instance("claudeAgent", %{
        "homePath" => home,
        "env" => %{"CLAUDE_CODE_TASK_LIST_ID" => "host-list"}
      })

      save_settings(%{"provider" => "claudeAgent", "model" => "claude-haiku-4-5"})
      start_untrusted()
      assert_receive {:sandbox_reported, 200, _}, 15_000
      await_review(&(&1["verdict"] == "approve"))
      thread_id = review()["threadId"]
      await_idle(thread_id)

      plans = HalC2.StreamState.list(HalC2.Streams.state(thread_id), "plan")
      refute inspect(plans) =~ "A task here"
    end

    # An agent of the sandbox's needs no CLI here: its driver comes from the settings,
    # and its model and options from the review's settings.
    test "reviews on an agent that is not installed on this machine, with the model and options picked" do
      FakeOpenShell.put_env(claude_command: ["hal-c2-test-no-claude"])

      HalC2.Settings.update(
        &put_in(&1, [Access.key("providerInstances", %{}), "claude-review"], %{
          "driver" => "claudeAgent"
        })
      )

      {:ok, providers} = HalC2.Plugins.Host.providers(@id)
      refute Enum.any?(providers, &(&1["instanceId"] == "claude-review"))

      save_settings(%{
        "provider" => "claude-review",
        "model" => "claude-haiku-4-5",
        "modelOptions" => %{"effort" => "high"}
      })

      start_untrusted()
      assert_receive {:sandbox_exec, ["claude" | args], _}, 15_000
      assert ["--model", "claude-haiku-4-5"] in Enum.chunk_every(args, 2, 1)
      assert_receive {:sandbox_reported, 200, _}, 15_000
      await_review(&(&1["verdict"] == "approve"))
    end

    test "asks for a model to be named when the agent that reviews is not installed on this machine" do
      FakeOpenShell.put_env(claude_command: ["hal-c2-test-no-claude"])
      save_settings(%{"provider" => "claudeAgent", "model" => ""})
      start_untrusted()
      await_review(&(&1["status"] == "failed"))

      assert review()["error"] =~
               "Install it here, or name the model to review with in the settings"
    end

    @tag sandbox: [reports: 2]
    test "takes one report of the two its agent sends at once", _context do
      start_untrusted()
      assert_receive {:sandbox_reported, first, one}, 15_000
      assert_receive {:sandbox_reported, second, other}, 15_000

      taken =
        for {200, body} <- [{first, one}, {second, other}],
            get_in(JSON.decode!(body), ["result", "structuredContent", "reported"]) == true,
            do: body

      assert length(taken) == 1
      assert_receive {:openshell_request, "DeleteSandbox", _}, 15_000
    end

    # Git here would run this machine's filters on what the pull request's attributes
    # route through them, and the agent changed only the sandbox's copy anyway.
    test "a sandboxed review takes no checkpoint of its checkout", _context do
      start_untrusted()
      assert_receive {:sandbox_reported, 200, _}, 15_000
      await_review(&(&1["verdict"] == "approve"))
      thread_id = review()["threadId"]
      await_idle(thread_id)

      assert HalC2.StreamState.list(HalC2.Streams.state(thread_id), "checkpoint") == []

      repos = Path.join(HalC2.Plugins.Host.data_dir("code-review"), "repos")
      [clone] = Path.wildcard(Path.join(repos, "**/*.git"))

      assert {"", 0} =
               System.cmd("git", ~w(for-each-ref refs/hal-c2/orchestration-v2/checkpoints),
                 cd: clone
               )
    end

    # A run stopped as its sandbox was made fails to open it, which for a review no
    # longer running removed nothing from its checkout.
    @tag sandbox: [hold: :checkout]
    test "a review stopped while its sandbox is made keeps no checkout", _context do
      start_untrusted()
      assert_receive {:sandbox_held, handler}, 15_000
      {:ok, _} = call("stop", %{"key" => @key})
      send(handler, :release)
      settle()
      assert %{"status" => "failed", "error" => "Stopped."} = review()
      checkouts = Path.join(HalC2.Plugins.Host.data_dir("code-review"), "checkouts")
      assert Path.wildcard(Path.join(checkouts, "*/pr-1/*")) == []
    end

    @tag sandbox: [report: nil, tokens: 1_000]
    test "a review past its token budget fails, saying so", _context do
      save_settings(%{"sandboxTokens" => 500})
      start_untrusted()
      assert_receive {:openshell_request, "DeleteSandbox", _}, 15_000
      await_review(&(&1["status"] == "failed"))
      assert review()["error"] =~ "used up its token budget"
    end

    @tag sandbox: [report: nil, tokens: 10, cached: 1_000]
    test "cache reads count against the budget of a Claude review", _context do
      save_settings(%{
        "sandboxTokens" => 500,
        "provider" => "claudeAgent",
        "model" => "claude-haiku-4-5"
      })

      start_untrusted()
      assert_receive {:openshell_request, "DeleteSandbox", _}, 15_000
      await_review(&(&1["status"] == "failed"))
      assert review()["error"] =~ "used up its token budget"
    end

    @tag sandbox: [report: nil, tokens: 10, subagent_tokens: 1_000]
    test "what subagents use counts against the budget of a Claude review", _context do
      save_settings(%{
        "sandboxTokens" => 500,
        "provider" => "claudeAgent",
        "model" => "claude-haiku-4-5"
      })

      start_untrusted()
      assert_receive {:openshell_request, "DeleteSandbox", _}, 15_000
      await_review(&(&1["status"] == "failed"))
      assert review()["error"] =~ "used up its token budget"
    end

    @tag sandbox: [report: nil, tokens: 10, subagent_tokens: 10, subagent_progress: 1_000]
    test "what a subagent writes counts against the budget of a Claude review", _context do
      save_settings(%{
        "sandboxTokens" => 500,
        "provider" => "claudeAgent",
        "model" => "claude-haiku-4-5"
      })

      start_untrusted()
      assert_receive {:openshell_request, "DeleteSandbox", _}, 15_000
      await_review(&(&1["status"] == "failed"))
      assert review()["error"] =~ "used up its token budget"
    end

    @tag sandbox: [report: nil, tokens: 10, cli_tokens: 1_000]
    test "what only the CLI counts goes against the budget of a Claude review", _context do
      save_settings(%{
        "sandboxTokens" => 500,
        "provider" => "claudeAgent",
        "model" => "claude-haiku-4-5"
      })

      start_untrusted()
      assert_receive {:openshell_request, "DeleteSandbox", _}, 15_000
      await_review(&(&1["status"] == "failed"))
      assert review()["error"] =~ "used up its token budget"
    end

    @tag sandbox: [report: nil, tokens: 10, subagent_tokens: 1_000]
    test "what subagents use counts against the budget of a Codex review", _context do
      save_settings(%{"sandboxTokens" => 500})
      start_untrusted()
      assert_receive {:openshell_request, "DeleteSandbox", _}, 15_000
      await_review(&(&1["status"] == "failed"))
      assert review()["error"] =~ "used up its token budget"
    end

    # The spend was counted only while a turn ran, so usage Codex told after it ended
    # never reached the budget.
    @tag sandbox: [hang: true, late_tokens: 1_000]
    test "what a Codex review spends after its turn ended counts against its budget",
         _context do
      save_settings(%{"sandboxTokens" => 500})
      start_untrusted()
      assert_receive {:sandbox_turn, _}, 15_000
      %{"threadId" => thread_id} = review()
      # The plugin, held, cannot close the sandbox as the turn ends: only the spend can.
      plugin = Process.whereis(@server)
      :sys.suspend(plugin)

      try do
        {:ok, _} =
          HalC2.Orchestration.dispatch(%{
            "type" => "run.interrupt",
            "threadId" => thread_id,
            "holdQueue" => false
          })

        assert_receive {:openshell_request, "DeleteSandbox", _}, 15_000
        assert HalC2.OpenShell.Review.ended(thread_id) == "tokens"
      after
        :sys.resume(plugin)
      end
    end

    @tag sandbox: [hang: true]
    test "a report taken whose answer cannot be sent still loses its sandbox", _context do
      start_untrusted()
      assert_receive {:sandbox_turn, _}, 15_000
      %{"threadId" => thread_id} = review()
      %{mcp: %{authorization: authorization}} = HalC2.OpenShell.Review.binding(thread_id)

      body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{
            "name" => "code_review_report",
            "arguments" => %{"verdict" => "approve", "summary" => "Fine.", "comments" => []}
          }
        })

      conn =
        Plug.Test.conn(:post, "/report", body)
        |> Plug.Conn.put_req_header("authorization", authorization)
        |> Dropped.wrap()

      assert_raise RuntimeError, fn -> HalC2.OpenShell.Broker.call(conn, []) end
      assert_receive {:openshell_request, "DeleteSandbox", _}, 15_000
      assert HalC2.OpenShell.Review.binding(thread_id) == nil
    end

    @tag sandbox: [hang: true]
    test "a review stopped from its row loses its sandbox", _context do
      start_untrusted()
      assert_receive {:sandbox_turn, _}, 15_000
      assert {:ok, _} = call("stop", %{"key" => @key})
      assert_receive {:openshell_request, "DeleteSandbox", _}, 15_000
      settle()
      assert %{"status" => "failed", "error" => "Stopped."} = review()
    end

    @tag sandbox: [hang: true]
    test "only the plugin that opened a sandbox closes it, launches in it or reads it",
         _context do
      alias HalC2.OpenShell.Review
      alias HalC2.Plugins.Host

      start_untrusted()
      assert_receive {:sandbox_turn, _}, 15_000
      %{"threadId" => thread_id, "projectId" => project} = review()

      assert {:error, _} = Review.close(thread_id, "stopped", "other")
      assert Review.binding(thread_id)

      # A sandbox another plugin opened or closed first is that plugin's.
      :ok = Review.close("other-thread", "time", "other")
      assert {:error, _} = Host.close_sandbox(@id, "other-thread")
      assert Host.sandbox_ended(@id, "other-thread") == nil

      assert {:error, _} =
               Host.launch_thread(
                 @id,
                 "review",
                 %{"threadId" => "other-thread", "projectId" => project, "title" => "Other"},
                 sandboxed: true
               )

      assert HalC2.Streams.get("other-thread", "thread", "other-thread") == nil

      # So is the sandbox of a thread another plugin started, which the review process
      # does not remember after a restart.
      {:ok, _} =
        HalC2.Orchestration.launch_thread(
          %{"threadId" => "other-started", "projectId" => project, "title" => "Other"},
          plugin: %{"id" => "other", "kind" => "other", "listed" => false}
        )

      assert {:error, _} = Host.close_sandbox(@id, "other-started")
      assert Review.ended("other-started") == nil
    end

    @tag sandbox: [hang: true]
    test "a stopped review takes no report from its sandbox", _context do
      start_untrusted()
      assert_receive {:sandbox_turn, _}, 15_000
      %{"threadId" => thread_id} = review()
      assert {:ok, _} = call("stop", %{"key" => @key})

      arguments = %{"verdict" => "approve", "summary" => "Fine.", "comments" => []}

      assert {:error, _, message, _} =
               HalC2.Plugins.call_tool("code_review_report", arguments, thread_id)

      assert message =~ "no longer running"
      settle()
      assert %{"status" => "failed", "error" => "Stopped.", "verdict" => nil} = review()
    end

    test "a review stopped before its sandbox is made gets none", %{dir: dir, gateway: g} do
      File.write!(Path.join(dir, "fetch.hold"), "")
      start_untrusted()
      await_file(Path.join(dir, "fetch.held"))
      %{"threadId" => thread_id} = review()
      assert {:ok, _} = call("stop", %{"key" => @key})
      # Closed by the time Stop returns, so the sandbox the run asks for next is refused.
      assert HalC2.OpenShell.Review.ended(thread_id) == "closed"
      File.rm!(Path.join(dir, "fetch.hold"))

      settle()
      refute_received {:openshell_request, "CreateSandbox", _}
      refute_received {:sandbox_exec, _, _}
      assert FakeOpenShell.sandboxes(g) == %{}
      assert %{"status" => "failed", "error" => "Stopped."} = review()
      # The run's claim is refused, and the checkout it fetched goes with it.
      checkouts = Path.join(HalC2.Plugins.Host.data_dir("code-review"), "checkouts")
      assert Path.wildcard(Path.join(checkouts, "*/pr-1/*")) == []
    end

    @tag sandbox: [hang: true]
    test "a review paused until its agent can work again loses its sandbox", %{gateway: g} do
      start_untrusted()
      assert_receive {:sandbox_turn, _}, 15_000
      %{"threadId" => thread_id} = review()

      event = %{
        "type" => "turn.finished",
        "threadId" => thread_id,
        "status" => "failed",
        "errorClass" => "usage_limit",
        "error" => "Subscription quota exhausted.",
        "resetAt" => "2999-01-01T00:00:00Z"
      }

      apply(@server, :handle_event, [event, %{}])
      assert_receive {:openshell_request, "DeleteSandbox", _}, 15_000
      settle()
      assert %{"status" => "queued"} = review()
      assert HalC2.OpenShell.Review.binding(thread_id) == nil
      assert FakeOpenShell.sandboxes(g) == %{}
    end

    test "a review whose agent cannot run in a sandbox fails before anything starts", %{
      gateway: g
    } do
      save_settings(%{"provider" => "cursor", "model" => "auto"})
      start_untrusted()
      await_review(&(&1["status"] == "failed"))
      assert review()["error"] =~ "cannot run in yet"
      assert FakeOpenShell.sandboxes(g) == %{}
    end
  end

  # From the property: an untrusted pull request on an MC with no OpenShell kept the
  # checkout of its failed run until the next run of it.
  test "an untrusted pull request whose sandbox cannot open fails and keeps no checkout",
       context do
    rules!(context, head: 1, association: "NONE")
    start_untrusted()
    await_review(&(&1["status"] == "failed"))
    assert review()["error"] =~ "sandboxes are not running"
    checkouts = Path.join(HalC2.Plugins.Host.data_dir("code-review"), "checkouts")
    assert Path.wildcard(Path.join(checkouts, "*/pr-1/*")) == []
  end

  test "a trusted pull request is reviewed in a sandbox unless the user reviews trusted ones here",
       context do
    sandboxed? = &apply(@server, :sandboxed?, [&1, &2])
    here = %{"reviewTrustedOnThisMachine" => true}
    review = start_review()
    assert %{"author" => %{"login" => "octocat"}} = review["trust"]
    assert sandboxed?.(%{}, review) == true
    assert sandboxed?.(%{"reviewTrustedOnThisMachine" => false}, review) == true
    assert sandboxed?.(here, review) == false

    # The old setting, stored as false while that was its default, sandboxes nothing less.
    assert sandboxed?.(%{"sandboxEveryReview" => false}, review) == true

    # One whose author was not read yet, or is no member or collaborator, is sandboxed
    # whatever the setting says.
    assert sandboxed?.(here, Map.delete(review, "trust")) == true
    rules!(context, head: 1, association: "NONE")
    refresh()
    assert sandboxed?.(here, review()) == true
  end

  # A comment dismissed while its review was being posted changed what the page showed
  # as posted, though GitHub had the comment.
  test "a comment of a review being posted stays as it was posted", context do
    hold = Path.join(context.dir, "post.hold")
    held = Path.join(context.dir, "post.held")
    File.write!(hold, "")

    rules!(context,
      head: 1,
      post: "touch '#{held}'; while [ -e '#{hold}' ]; do sleep 0.05; done"
    )

    review = start_review()

    arguments = %{
      "verdict" => "comment",
      "summary" => "One thing.",
      "comments" => [%{"path" => "src/limits.ts", "line" => 1, "body" => "One."}]
    }

    {:ok, _} = HalC2.Plugins.call_tool("code_review_report", arguments, review["threadId"])
    settle()
    posting = publishing()
    await_file(held)

    assert {:error, %{"message" => message}} =
             call("dismiss", %{"key" => @key, "commentId" => "c1"})

    assert message =~ "is being published"

    File.rm!(hold)
    assert_receive {^posting, {:ok, _}}, 15_000
    settle()
    assert %{"status" => "published", "comments" => [%{"dismissed" => false}]} = review()

    assert {:error, %{"message" => message}} =
             call("dismiss", %{"key" => @key, "commentId" => "c1"})

    assert message =~ "already published"
    assert [_] = posts(context)
  end

  # The code review property's model took a dismissal on a review kept under local
  # publishing, which the plugin refuses: a kept review is never posted.
  test "a comment of a review kept in HAL-C2 cannot be dismissed", context do
    rules!(context, head: 1)
    save_settings(%{"publishing" => "local"})
    review = start_review()

    arguments = %{
      "verdict" => "comment",
      "summary" => "One thing.",
      "comments" => [%{"path" => "src/limits.ts", "line" => 1, "body" => "One."}]
    }

    {:ok, _} = HalC2.Plugins.call_tool("code_review_report", arguments, review["threadId"])
    settle()

    assert {:error, %{"message" => message}} =
             call("dismiss", %{"key" => @key, "commentId" => "c1"})

    assert message =~ "not waiting to be published"
    assert %{"status" => "kept", "comments" => [%{"dismissed" => false}]} = review()
  end

  # While the plugin started again, its claims table was up before the claims saved on
  # disk were in it, so a peer reading it then was told this machine claimed nothing.
  test "a plugin starting again holds its saved claims from the moment a peer can read them",
       _context do
    start_review()
    pid = Process.whereis(@server)
    {:parent, sup} = Process.info(pid, :parent)
    :sys.suspend(sup)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    # The plugin's first call on the file server, finding where its reviews are,
    # waits there until the claims are checked.
    fs = Process.whereis(:file_server_2)
    :erlang.trace(fs, true, [:receive])
    :sys.suspend(fs)

    try do
      :sys.resume(sup)
      await_file_call(fs)
      assert apply(@server, :claims, [[@key]]) == :restarting
      assert apply(@server, :starts, []) == :restarting
    after
      :sys.resume(fs)
      :erlang.trace(fs, false, [:receive])
    end

    :sys.get_state(sup)
    :sys.get_state(@server)
    assert %{@key => %{"claimed" => true}} = apply(@server, :claims, [[@key]])
    assert [_] = apply(@server, :starts, [])
  end

  # --- helpers ----------------------------------------------------------------------------

  # Reports findings from the review's thread, starting a run first if there is none.
  defp report_findings(held \\ []) do
    review = if held == [], do: start_review(), else: review()

    {:ok, _} =
      HalC2.Plugins.call_tool(
        "code_review_report",
        %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []},
        review["threadId"]
      )

    settle(held)
    assert %{"status" => "waiting"} = review()
  end

  # Asks to publish #1 without waiting for GitHub. Returns the ref its reply comes with.
  defp publishing do
    ref = make_ref()
    shown = seen()

    send(
      @server,
      {:"$gen_call", {self(), ref}, {:publish, @key, shown["version"], shown["verdict"]}}
    )

    :sys.get_state(@server)
    ref
  end

  # The plugin's processes under way.
  defp kids(server) do
    {:parent, parent} = Process.info(server, :parent)
    {:links, links} = Process.info(server, :links)
    Enum.filter(links, &(is_pid(&1) and &1 != parent))
  end

  # What a look begun at `at` found: the pull request of `review` at the head `head`.
  defp listing(review, at, head) do
    entry =
      review
      |> Map.take(
        ~w(key repository number projectId title url author headBranch baseBranch isDraft labels reviewRequested changedLines updatedAt)
      )
      |> Map.put("headSha", head)

    %{
      at: at,
      problem: nil,
      unwatched: [],
      entries: [entry],
      read: [],
      sizes: %{},
      unknown_sizes: [],
      asked: %{},
      closed: [],
      elsewhere: %{}
    }
  end

  # How many times the fake GitHub listed the pull requests.
  defp list_calls(context) do
    Path.join(context.dir, "gh.log")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.count(&("pr" in JSON.decode!(&1)["args"] and "list" in JSON.decode!(&1)["args"]))
  end

  # A review of #1 waiting to be posted, and the review `login` posted of the same commit
  # with the plugin's marker.
  defp reviewed_by(login) do
    review = start_review()

    {:ok, _} =
      HalC2.Plugins.call_tool(
        "code_review_report",
        %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []},
        review["threadId"]
      )

    settle()
    %{"status" => "waiting", "reviewedSha" => reviewed} = review()

    %{
      "author" => %{"login" => login},
      "body" => "Looks right.\n\n<!-- hal-c2-code-review:#{@key}@#{reviewed} -->"
    }
  end

  # The reviews posted to pull request #1.
  defp posts(context) do
    context.dir
    |> Path.join("gh.log")
    |> File.stream!()
    |> Enum.filter(&(&1 =~ "pulls/1/reviews"))
  end

  # A `:streams_hook`: holds the first of the plugin's processes on its way to
  # `thread_id`'s stream until it is sent `:go`, and tells `test` it is held.
  def hold(thread_id, server, test, :ensured, thread_id) do
    {:links, links} = Process.info(self(), :links)

    if server in links do
      send(test, {:held, self()})
      receive do: (:go -> :ok)
    end

    :ok
  end

  def hold(_thread_id, _server, _test, _stage, _stream_id), do: :ok

  defp active_runs(thread_id) do
    HalC2.Streams.state(thread_id)
    |> HalC2.StreamState.list("run")
    |> Enum.filter(&(&1["status"] in ~w(preparing starting running waiting)))
  end

  defp sessions_stopped?(thread_id) do
    HalC2.Streams.state(thread_id)
    |> HalC2.StreamState.list("provider-session")
    |> Enum.all?(&(&1["status"] == "stopped"))
  end

  defp await_sessions_stopped(thread_id) do
    :ok = HalC2.Streams.watch(thread_id, self())
    await_stopped(thread_id)
    HalC2.Streams.Server.unsubscribe(thread_id, self())
  end

  defp await_stopped(thread_id) do
    unless sessions_stopped?(thread_id) do
      assert_receive {:hal_c2_stream, ^thread_id, _}, 15_000
      await_stopped(thread_id)
    end
  end

  defp await_idle(thread_id) do
    :ok = HalC2.Streams.watch(thread_id, self())
    await_no_runs(thread_id)
    HalC2.Streams.Server.unsubscribe(thread_id, self())
  end

  defp await_no_runs(thread_id) do
    if active_runs(thread_id) != [] do
      assert_receive {:hal_c2_stream, ^thread_id, _}, 15_000
      await_no_runs(thread_id)
    end
  end

  defp thread(thread_id) do
    HalC2.StreamState.get(HalC2.Streams.state(thread_id), "thread")[thread_id]
  end

  defp save_settings(overrides) do
    put_settings(overrides)
    settle()
  end

  # Saves the settings without waiting for what the plugin does with them.
  defp put_settings(overrides), do: {:ok, _} = save_settings_answer(overrides)

  # What the plugin answers a save of the settings with `overrides`.
  defp save_settings_answer(overrides) do
    settings =
      Map.merge(
        %{
          "provider" => "codex",
          "model" => "fake/one",
          "prompt" => "Review \#{{pr.number}} in {{repository}}. answer from gate",
          "pollMinutes" => 60,
          "repositories" => ["acme/api"],
          "activation" => "selective",
          "publishing" => "draft",
          "reviewNewPushes" => false,
          "readReviewMd" => false
        },
        overrides
      )

    HalC2.Plugins.handle("saveSettings", %{"id" => @id, "settings" => settings})
  end

  # While the stop waits on the agent, which `hold_interrupts/1` keeps from answering, its
  # next pass cannot cancel what is queued. So `start_next/1`, which is what the end of a
  # run calls, starts the message, and the stop's next pass interrupts it before the stop
  # answers.
  defp assert_stop_stops_what_was_queued_meanwhile(review, thread_id, hold) do
    :ok = HalC2.Streams.watch(thread_id, self())
    stop = Task.async(fn -> HalC2.Orchestration.stop_plugin_thread(review["threadId"], @id) end)
    await_interrupt_requested(thread_id)
    queue_message(thread_id, "mid-stop")

    {:ok, _} =
      HalC2.Streams.transact(thread_id, :thread, fn state ->
        {for run <- HalC2.StreamState.list(state, "run"),
             run["status"] in ~w(preparing starting running waiting) do
           HalC2.Orchestration.upsert(
             state,
             "run",
             run["id"],
             &Map.put(&1, "status", "interrupted")
           )
         end, {:ok, :ended}}
      end)

    # Calls the runtime, which waits on the held interrupt.
    next = Task.async(fn -> HalC2.Orchestration.start_next(thread_id) end)
    await_state(thread_id, &(run_of(&1, "mid-stop")["status"] != "queued"))

    File.rm!(hold)
    assert :ok = Task.await(stop, 15_000)
    Task.shutdown(next)

    assert active_runs(thread_id) == []
    assert run_of(HalC2.Streams.state(thread_id), "mid-stop")["status"] != "queued"
  end

  defp running?(state),
    do: Enum.any?(HalC2.StreamState.list(state, "run"), &(&1["status"] == "running"))

  defp await_stream(thread_id, done?) do
    :ok = HalC2.Streams.watch(thread_id, self())
    await_state(thread_id, done?)
    HalC2.Streams.Server.unsubscribe(thread_id, self())
  end

  defp await_state(thread_id, done?) do
    unless done?.(HalC2.Streams.state(thread_id)) do
      assert_receive {:hal_c2_stream, ^thread_id, _}, 5_000
      await_state(thread_id, done?)
    end
  end

  # The fake answers no `turn/interrupt` until the returned file is removed.
  defp hold_interrupts(context) do
    hold = Path.join(context.dir, "hold-interrupt")
    File.write!(hold, "")
    System.put_env("FAKE_CODEX_HOLD_INTERRUPT", hold)
    on_exit(fn -> System.delete_env("FAKE_CODEX_HOLD_INTERRUPT") end)
    hold
  end

  defp queue_message(thread_id, message_id) do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "threadId" => thread_id,
        "messageId" => message_id,
        "text" => "and another thing",
        "attachments" => [],
        "dispatchMode" => %{"type" => "queue_after_active"}
      })

    assert run_of(HalC2.Streams.state(thread_id), message_id)["status"] == "queued"
  end

  defp run_of(state, message_id) do
    state
    |> HalC2.StreamState.list("run")
    |> Enum.find(&(&1["userMessageId"] == message_id))
  end

  defp await_interrupt_requested(thread_id) do
    state = HalC2.Streams.state(thread_id)
    items = Map.keys(HalC2.StreamState.get(state, "turn-item"))

    if Enum.any?(items, &String.ends_with?(&1, ":signal:interrupt-request")) do
      state
    else
      receive do
        {:hal_c2_stream, ^thread_id, _} -> await_interrupt_requested(thread_id)
      after
        5_000 -> flunk("the thread was never asked to stop")
      end
    end
  end

  # An MC with OpenShell installed, whose pull request was opened by someone who is not
  # a member or collaborator (`start_untrusted/0`): the fake gateway, whose sandbox runs
  # `HalC2.Test.FakeSandbox` with the test's `:sandbox` tag.
  defp sandboxed!(context) do
    rules!(context, head: 1, association: "NONE")

    FakeOpenShell.put_env(
      service_user_home: Path.join(context.tmp_dir, "user"),
      service_platform: {:unix, :linux},
      openshell_broker: [host: "127.0.0.1", bind: "127.0.0.1", ips: ["127.0.0.1"]]
    )

    restore = env(~w(OPENAI_API_KEY ANTHROPIC_API_KEY))
    on_exit(restore)

    System.put_env(%{
      "OPENAI_API_KEY" => "sk-test-openai",
      "ANTHROPIC_API_KEY" => "sk-test-anthropic"
    })

    root = FakeSandbox.root()

    gateway =
      FakeOpenShell.start(HalC2.OpenShell.pki_dir(),
        notify: self(),
        exec: FakeSandbox.exec(root, self(), Map.get(context, :sandbox, []))
      )

    FakeOpenShell.install!(gateway)

    start_supervised!(HalC2.OpenShell.Review)
    :sys.get_state(HalC2.OpenShell.Review)
    %{gateway: gateway, sandbox_root: root}
  end

  # Reviews with Claude, whose instance has `config` in HAL-C2's settings.
  defp put_claude(config) do
    put_instance("claudeAgent", config)

    save_settings(%{"provider" => "claudeAgent", "model" => "claude-haiku-4-5"})
    start_untrusted()
  end

  # Starts the review of a pull request nobody trusted, as the user does: asking for it
  # reads it, and approving its head starts it.
  defp start_untrusted do
    assert {:error, %{"message" => message}} =
             call("start", %{"repository" => "acme/api", "number" => 1})

    assert message =~ "Approve it on the Reviews page"
    {:ok, _} = call("approve", %{"key" => @key, "headSha" => review()["headSha"]})
  end

  defp put_instance(instance, config),
    do: HalC2.Settings.update(&put_in(&1, [Access.key("providers", %{}), instance], config))

  defp await_review(done?) do
    HalC2.Plugins.subscribe_topic(self(), @id, "reviews")
    await_reviews(done?)
  end

  defp await_reviews(done?) do
    unless done?.(review() || %{}) do
      assert_receive {:hal_c2_plugin_topic, _, @id, "reviews", _}, 15_000
      await_reviews(done?)
    end
  end

  defp start_review do
    {:ok, _} = call("start", %{"repository" => "acme/api", "number" => 1})
    settle()
    assert %{"status" => "running", "checkout" => checkout} = review = review()
    assert File.dir?(checkout)
    # The agent's git in the checkout knows where the pull request came from.
    assert git!(checkout, ["config", "remote.origin.url"]) == "https://github.com/acme/api.git"
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

  # The review as the user sees it, to publish: its key and the version of its findings.
  # The review as the user saw it before publishing: its findings' version and, read
  # when it waits to be published, the verdict its post goes with.
  defp seen do
    shown = %{"key" => @key, "version" => review()["version"]}

    case call("preview", %{"key" => @key}) do
      {:ok, %{"verdict" => verdict}} -> Map.put(shown, "verdict", verdict)
      _ -> shown
    end
  end

  # Returns once the plugin has nothing in flight but the processes `held`, and has
  # heard from what ended.
  defp settle(held \\ []) do
    pid = Process.whereis(@server)
    {:parent, parent} = Process.info(pid, :parent)
    # Runs, posts and the look are all linked; what the plugin monitors besides
    # them includes whatever it is calling, such as the file server.
    {:links, links} = Process.info(pid, :links)

    case Enum.filter(links, &(is_pid(&1) and &1 != parent and &1 not in held)) do
      [] ->
        :sys.get_state(pid)
        :ok

      kids ->
        refs = Enum.map(kids, &Process.monitor/1)
        assert_receive {:DOWN, ref, :process, _, _} when is_reference(ref), 15_000
        Enum.each(refs, &Process.demonitor(&1, [:flush]))
        settle(held)
    end
  end

  # Returns once the look for pull requests under way, if any, is applied.
  defp await_look do
    pid = Process.whereis(@server)

    with %{polling: polling} when polling != nil <- :sys.get_state(pid),
         look when is_pid(look) <- look(pid) do
      ref = Process.monitor(look)
      assert_receive {:DOWN, ^ref, :process, _, _}, 15_000
    end

    :sys.get_state(pid)
  end

  # The look under way: the one process the plugin both links and monitors.
  defp look(pid) do
    {:links, links} = Process.info(pid, :links)
    {:monitors, monitors} = Process.info(pid, :monitors)
    Enum.find_value(monitors, fn {:process, p} -> p in links and p end)
  end

  # Waits for the plugin's server to call the file server `fs`, traced for receives.
  defp await_file_call(fs) do
    assert_receive {:trace, ^fs, :receive, {:"$gen_call", {from, _}, _}}, 5_000
    if from != Process.whereis(@server), do: await_file_call(fs)
  end

  defp await_file(path) do
    {_, 0} =
      System.cmd("timeout", ["5", "sh", "-c", "until [ -e '#{path}' ]; do sleep 0.05; done"])
  end

  # The fake GitHub: pull request #1 of acme/api open at head commit `head`, listed
  # unless `listed: false`; `list` runs while it is listed. Its author is a member of
  # the repository unless `association` says otherwise. It carries the `labels` (names),
  # its `comments` and `timeline` are the trust read's nodes, which `trust` runs ahead
  # of, and it was last updated at `updated`.
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
      "updatedAt" => opts[:updated] || "2026-09-01T00:00:00Z",
      "reviewRequests" => [],
      "latestReviews" => [],
      "labels" => Enum.map(opts[:labels] || [], &%{"name" => &1}),
      "statusCheckRollup" => [],
      "headRefOid" => context.shas[opts[:head]],
      "additions" => 2,
      "deletions" => 0
    }

    listing = if opts[:listed] == false, do: [], else: [pr]
    list = %{"args" => ["api graphql"], "repository" => "acme/api", "pulls" => listing}
    list = if opts[:list], do: Map.put(list, "run", opts[:list]), else: list

    reviews =
      for r <- opts[:reviews] || [],
          do:
            Map.merge(
              %{"id" => "PRR_1", "state" => "APPROVED", "submittedAt" => "2026-09-01T00:00:00Z"},
              r
            )

    # What GitHub answers for the role of each login in `permissions` on the repository.
    permissions =
      for {login, answer} <- opts[:permissions] || [],
          do: %{"args" => ["collaborators/#{login}/permission"], "stdout" => answer}

    rules = [
      %{"args" => ["api user"], "stdout" => %{"id" => 7, "login" => "monalisa"}},
      # Who stands behind pull request #1: octocat, a member unless `association` says.
      %{
        "args" => ["api graphql"],
        "stdin" => ["PullRequestTrust"],
        "run" => opts[:trust] || "true",
        "stdout" => %{
          "data" => %{
            "viewer" => %{"login" => "monalisa"},
            "repository" => %{
              "pullRequest" => %{
                "author" => %{"__typename" => "User", "login" => "octocat"},
                "authorAssociation" => opts[:association] || "MEMBER",
                "isCrossRepository" => false,
                "headRefOid" => context.shas[opts[:head]],
                "headRepositoryOwner" => %{"login" => "acme"},
                "comments" => %{"nodes" => opts[:comments] || []},
                "timelineItems" => %{"nodes" => opts[:timeline] || []}
              }
            }
          }
        }
      },
      list,
      # The pull request's reviews, read before a post, and the post.
      %{
        "args" => ["pr view", "author,comments,reviews,commits"],
        "stdout" => %{
          "author" => %{"login" => "octocat"},
          "comments" => [],
          "reviews" => reviews,
          "commits" => []
        }
      },
      Map.merge(
        %{"args" => ["--method POST", "pulls/1/reviews"], "stdout" => "{}"},
        if(opts[:post], do: %{"run" => opts[:post]}, else: %{})
      ),
      # Pull request #1 read on its own, as asking for its review reads it.
      %{
        "args" => ["api graphql"],
        "stdin" => ["viewerCanUpdateBranch"],
        "run" => opts[:detail] || "true",
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

    File.write!(Path.join(context.dir, "rules.json"), JSON.encode!(permissions ++ rules))
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

  # A bare node connected to this one (`@tag :laptop`), with no MC: only a `HalC2.Plugins.Host` whose
  # `peer/3` answers the code-review claims in its `:claims` persistent term, and no
  # shared starts. It stops with the test, and the distribution started for it too.
  defp start_laptop do
    alive? = Node.alive?()

    unless alive? do
      {_, 0} = System.cmd("epmd", ["-daemon"])
      name = :"hal_c2_test#{System.unique_integer([:positive])}@127.0.0.1"
      {:ok, _} = Node.start(name, :longnames)
    end

    {:ok, pid, node} =
      :peer.start_link(%{
        name: :"hal_c2_laptop#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true,
        args: [~c"-setcookie", Atom.to_charlist(Node.get_cookie())]
      })

    {:module, _} = :erpc.call(node, :code, :load_binary, [HalC2.Plugins.Host, ~c"laptop", stub()])

    on_exit(fn ->
      # Linked to the test's process, the peer may be shutting down already.
      try do
        :peer.stop(pid)
      catch
        :exit, _ -> :ok
      end

      unless alive?, do: Node.stop()
    end)

    %{pid: pid, node: node}
  end

  defp stub do
    source = ~S"""
    -module('Elixir.HalC2.Plugins.Host').
    -export([peer/3]).
    peer(<<"code-review">>, claims, [Keys]) ->
        Rows = maps:with(Keys, persistent_term:get(claims, #{})),
        {ok, #{<<"machine">> => <<"laptop">>, <<"result">> => Rows}};
    peer(<<"code-review">>, Function, _) when Function == starts; Function == count_start ->
        {ok, #{<<"machine">> => <<"laptop">>, <<"result">> => []}};
    peer(_, _, _) ->
        none.
    """

    {:ok, tokens, _} = :erl_scan.string(String.to_charlist(source))

    forms =
      tokens
      |> Enum.chunk_by(&match?({:dot, _}, &1))
      |> Enum.chunk_every(2)
      |> Enum.map(fn chunk ->
        {:ok, form} = :erl_parse.parse_form(Enum.concat(chunk))
        form
      end)

    {:ok, _, binary} = :compile.forms(forms)
    binary
  end

  # A bare `remotes/acme/<name>.git` with one commit of `file`, its text `<name>\n`,
  # and `subs` as its submodules: `{path, url, sha}`, or `{path, url, sha, lines}` with
  # more lines of its `.gitmodules` entry.
  defp repo!(dir, name, file, subs \\ []) do
    bare = Path.join(dir, "remotes/acme/#{name}.git")
    git!(dir, ["init", "-q", "--bare", "-b", "main", bare])
    seed = Path.join(dir, "seed-#{name}")
    git!(dir, ["init", "-q", "-b", "main", seed])
    File.write!(Path.join(seed, file), "#{name}\n")
    git!(seed, ["add", file])
    submodules!(seed, subs)
    git!(seed, ["commit", "-q", "-m", "Start"])
    git!(seed, ["push", "-q", bare, "main:main"])
    %{bare: bare, seed: seed}
  end

  # Pull request `number` of acme/api: a commit on `main` with `subs` as its
  # submodules. Answers its sha.
  defp pull!(context, number, subs) do
    seed = Path.join(context.dir, "seed")
    git!(seed, ["checkout", "-q", "--detach", "main"])
    submodules!(seed, subs)
    git!(seed, ["commit", "-q", "-m", "Submodules"])
    sha = git!(seed, ["rev-parse", "HEAD"])
    bare = Path.join(context.dir, "remotes/acme/api.git")
    git!(seed, ["push", "-q", bare, "#{sha}:refs/pull/#{number}/head"])
    sha
  end

  defp submodules!(_seed, []), do: :ok

  defp submodules!(seed, subs) do
    File.write!(
      Path.join(seed, ".gitmodules"),
      Enum.map_join(subs, fn sub ->
        {path, url} = {elem(sub, 0), elem(sub, 1)}
        lines = if tuple_size(sub) == 4, do: elem(sub, 3), else: ""
        "[submodule \"#{path}\"]\n\tpath = \"#{path}\"\n\turl = #{url}\n" <> lines
      end)
    )

    git!(seed, ["add", ".gitmodules"])

    for sub <- subs, {path, sha} = {elem(sub, 0), elem(sub, 2)} do
      sha = if is_map(sha), do: git!(sha.seed, ["rev-parse", "HEAD"]), else: sha
      git!(seed, ["update-index", "--add", "--cacheinfo", "160000,#{sha},#{path}"])
    end

    :ok
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
