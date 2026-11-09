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

    assert {:error, "plugin_failed", message} =
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

  test "the first report of a run is final", _context do
    review = start_review()
    first = %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []}
    {:ok, _} = HalC2.Plugins.call_tool("code_review_report", first, review["threadId"])
    settle()
    again = %{first | "verdict" => "request-changes", "summary" => "Wait, no."}

    assert {:error, "plugin_failed", message} =
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
    rules!(context, head: 1, association: "NONE")
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
    settle()
    assert %{"status" => "running", "threadId" => thread_id} = review()

    arguments = %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []}
    {:ok, _} = HalC2.Plugins.call_tool("code_review_report", arguments, thread_id)
    settle()

    assert %{"status" => "waiting"} = review()
    assert posts(context) == []
  end

  test "a push takes back the approval of a pull request nobody trusted, even pushed back",
       context do
    rules!(context, head: 1, association: "NONE")
    settle()
    {:error, _} = call("start", %{"repository" => "acme/api", "number" => 1})
    {:ok, _} = call("approve", %{"key" => @key, "headSha" => context.shas[1]})
    settle()
    assert %{"status" => "running", "threadId" => thread_id} = review()
    arguments = %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []}
    {:ok, _} = HalC2.Plugins.call_tool("code_review_report", arguments, thread_id)
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

    assert {:error, "plugin_failed", message} =
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

  test "an approval given again after a run stopped at a usage limit queues the review again",
       context do
    rules!(context, head: 1, association: "NONE")
    settle()
    {:error, _} = call("start", %{"repository" => "acme/api", "number" => 1})
    {:ok, _} = call("approve", %{"key" => @key, "headSha" => context.shas[1]})
    settle()
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

    assert {:error, "plugin_failed", message} =
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

    # Neither a save, which starts queued reviews when it makes room, nor a restart
    # starts the queue into the limit.
    save_settings(%{"concurrency" => 2})
    assert %{"status" => "queued"} = review()
    {:ok, _} = HalC2.Plugins.handle("restart", %{"id" => @id})
    settle()
    refresh()
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
