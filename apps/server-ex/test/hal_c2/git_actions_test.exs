defmodule HalC2.GitActionsTest do
  use ExUnit.Case, async: false

  alias HalC2.GitActions

  @moduletag :tmp_dir
  @fake_claude Path.expand("../support/fake_claude_text.sh", __DIR__)

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:hal_c2, :text_claude_command)
    Application.put_env(:hal_c2, :text_claude_command, @fake_claude)
    on_exit(fn -> Application.put_env(:hal_c2, :text_claude_command, previous) end)

    origin = Path.join(dir, "origin.git")
    repo = Path.join(dir, "repo")
    git!(dir, ["init", "-q", "--bare", "-b", "main", origin])
    git!(dir, ["clone", "-q", origin, repo])
    git!(repo, ~w(config user.name t))
    git!(repo, ~w(config user.email t@t))
    File.write!(Path.join(repo, "a.txt"), "one\n")
    git!(repo, ~w(add a.txt))
    git!(repo, ~w(commit -q -m init))
    git!(repo, ~w(push -q -u origin main))
    %{repo: repo, origin: origin}
  end

  defp run(input) do
    me = self()
    result = GitActions.run(Map.put(input, "actionId", "a1"), &send(me, {:event, &1}))
    {result, events()}
  end

  defp events(acc \\ []) do
    receive do
      {:event, e} -> events([e | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "a commit with the user's message, offering to push next", %{repo: repo} do
    File.write!(Path.join(repo, "b.txt"), "b\n")

    {{:ok, result}, events} =
      run(%{"cwd" => repo, "action" => "commit", "commitMessage" => "Add b\n\nBecause."})

    assert %{"commit" => %{"status" => "created", "subject" => "Add b", "commitSha" => sha}} =
             result

    assert %{
             "title" => "Committed " <> short,
             "cta" => %{"kind" => "run_action", "label" => "Push"}
           } = result["toast"]

    assert String.starts_with?(sha, short)
    assert git!(repo, ~w(log -1 --format=%B)) =~ "Add b\n\nBecause."

    assert [%{"kind" => "action_started", "phases" => ["commit"]} | _] = events
    assert %{"kind" => "action_finished"} = List.last(events)
    # A message was given, so none was generated.
    refute Enum.any?(events, &(&1["label"] == "Generating commit message..."))
  end

  test "a commit on a branch behind its upstream offers no push", %{repo: repo} do
    other = repo <> "-other"
    git!(Path.dirname(repo), ["clone", "-q", Path.join(Path.dirname(repo), "origin.git"), other])
    git!(other, ~w(config user.name t))
    git!(other, ~w(config user.email t@t))
    File.write!(Path.join(other, "up.txt"), "up\n")
    git!(other, ~w(add up.txt))
    git!(other, ~w(commit -q -m up))
    git!(other, ~w(push -q origin main))
    git!(repo, ~w(fetch -q))

    File.write!(Path.join(repo, "b.txt"), "b\n")

    assert {{:ok, %{"commit" => %{"status" => "created"}, "toast" => %{"cta" => cta}}}, _} =
             run(%{"cwd" => repo, "action" => "commit", "commitMessage" => "Add b"})

    assert cta == %{"kind" => "none"}
  end

  # The upstream's branch was deleted and pruned: its config remains but its ref is gone.
  test "push publishes a branch again after its upstream was deleted and pruned", %{
    repo: repo,
    origin: origin
  } do
    git!(repo, ~w(checkout -q -b topic))
    git!(repo, ~w(push -q -u origin topic))
    git!(origin, ~w(branch -D topic))
    git!(repo, ~w(fetch -q --prune))
    File.write!(Path.join(repo, "t.txt"), "t\n")
    git!(repo, ~w(add t.txt))
    git!(repo, ~w(commit -q -m later))

    assert {{:ok, %{"push" => %{"status" => "pushed", "setUpstream" => true}}}, _} =
             run(%{"cwd" => repo, "action" => "push"})

    assert git!(origin, ~w(log -1 --format=%s topic)) == "later\n"
  end

  test "commit and push with a generated message", %{repo: repo, origin: origin} do
    File.write!(Path.join(repo, "b.txt"), "b\n")
    {{:ok, result}, events} = run(%{"cwd" => repo, "action" => "commit_push"})

    assert %{
             "commit" => %{"subject" => "Add greeting file"},
             "push" => %{"status" => "pushed", "upstreamBranch" => "origin/main"}
           } = result

    assert Enum.any?(events, &(&1["label"] == "Generating commit message..."))
    assert git!(origin, ~w(log -1 --format=%s main)) == "Add greeting file\n"
  end

  test "a feature branch named by the agent is created and published", %{
    repo: repo,
    origin: origin
  } do
    File.write!(Path.join(repo, "b.txt"), "b\n")

    {{:ok, result}, _} =
      run(%{"cwd" => repo, "action" => "commit_push", "featureBranch" => true})

    assert %{"branch" => %{"status" => "created", "name" => "feature/add-greeting"}} = result

    assert %{
             "push" => %{"setUpstream" => true, "upstreamBranch" => "origin/feature/add-greeting"}
           } = result

    assert git!(origin, ~w(branch --list feature/add-greeting)) =~ "feature/add-greeting"
  end

  test "nothing to commit is not an error; a push without a remote is", %{repo: repo} do
    {{:ok, %{"commit" => %{"status" => "skipped_no_changes"}}}, _} =
      run(%{"cwd" => repo, "action" => "commit"})

    git!(repo, ~w(remote remove origin))
    git!(repo, ~w(checkout -q -b lonely))
    File.write!(Path.join(repo, "c.txt"), "c\n")

    {{:error, message}, events} =
      run(%{"cwd" => repo, "action" => "commit_push", "commitMessage" => "c"})

    assert message =~ "no git remote"
    assert %{"kind" => "action_failed", "phase" => "push"} = List.last(events)
  end

  test "a commit while another git holds the index says so", %{repo: repo} do
    File.write!(Path.join(repo, "b.txt"), "b\n")
    File.write!(Path.join(repo, ".git/index.lock"), "")

    assert {{:error, message}, _} = run(%{"cwd" => repo, "action" => "commit"})
    assert message =~ "index is locked"
    refute message =~ "not a git repository"
  end

  # Review of #1837: a branch cut from another branch is published where its
  # pushRemote says, not necessarily to the remote it was cut from; the branch
  # it was cut from stays its recorded base.
  test "a branch cut from another is published to its push remote", %{
    repo: repo,
    origin: origin
  } do
    fork = Path.join(Path.dirname(repo), "fork.git")
    git!(Path.dirname(repo), ["clone", "-q", "--bare", origin, fork])
    git!(repo, ["remote", "add", "fork", fork])
    git!(repo, ~w(push -q origin main:dev))
    git!(repo, ~w(fetch -q origin))
    git!(repo, ~w(checkout -q -b feature/tax origin/dev))
    git!(repo, ~w(config branch.feature/tax.pushRemote fork))
    File.write!(Path.join(repo, "t.txt"), "t\n")
    git!(repo, ~w(add t.txt))
    git!(repo, ~w(commit -q -m tax))
    dev_before = git!(origin, ~w(rev-parse dev))

    assert {{:ok, %{"push" => push}}, _} = run(%{"cwd" => repo, "action" => "push"})
    assert push["status"] == "pushed"
    assert push["upstreamBranch"] == "fork/feature/tax"
    assert git!(fork, ~w(log -1 --format=%s feature/tax)) == "tax\n"
    assert git!(origin, ~w(rev-parse dev)) == dev_before
    assert git!(origin, ~w(branch --list feature/tax)) == ""
    assert git!(repo, ~w(config --get branch.feature/tax.gh-merge-base)) == "dev\n"
    assert git!(repo, ~w(config --get branch.feature/tax.remote)) == "fork\n"
  end

  # Follow-up to #1837 (#1851): a branch tracking a local branch was cut
  # from it, so publishing records it as the base before `push -u`
  # replaces the tracking that named it.
  test "a branch tracking a local branch keeps it as its base when published", %{
    repo: repo,
    origin: origin
  } do
    git!(repo, ~w(branch develop))
    git!(repo, ~w(checkout -q -b feature/tax))
    git!(repo, ["config", "branch.feature/tax.remote", "."])
    git!(repo, ["config", "branch.feature/tax.merge", "refs/heads/develop"])
    File.write!(Path.join(repo, "t.txt"), "t\n")
    git!(repo, ~w(add t.txt))
    git!(repo, ~w(commit -q -m tax))

    assert {{:ok, %{"push" => push}}, _} = run(%{"cwd" => repo, "action" => "push"})
    assert push["status"] == "pushed"
    assert push["upstreamBranch"] == "origin/feature/tax"
    assert git!(origin, ~w(log -1 --format=%s feature/tax)) == "tax\n"
    assert HalC2.Git.base_branch(repo, "feature/tax") == "develop"
    assert git!(repo, ~w(config --get branch.feature/tax.gh-merge-base)) == "develop\n"
    assert git!(repo, ~w(config --get branch.feature/tax.remote)) == "origin\n"
  end

  # Review of #1837: publishing a branch cut from a non-primary remote's
  # branch replaces its tracking, so the remembered base keeps its remote —
  # the bare name would resolve on the primary remote instead.
  test "a branch cut from a non-primary remote keeps that remote as its base after publishing",
       %{repo: repo, origin: origin} do
    dir = Path.dirname(repo)
    upstream = Path.join(dir, "upstream.git")
    git!(dir, ["clone", "-q", "--bare", origin, upstream])
    git!(repo, ["remote", "add", "upstream", upstream])
    git!(repo, ~w(push -q origin main:develop))
    git!(repo, ~w(push -q upstream main:develop))
    git!(repo, ~w(fetch -q origin))
    git!(repo, ~w(fetch -q upstream))
    git!(repo, ~w(checkout -q -b feature/tax upstream/develop))
    File.write!(Path.join(repo, "t.txt"), "t\n")
    git!(repo, ~w(add t.txt))
    git!(repo, ~w(commit -q -m tax))

    assert {{:ok, %{"push" => push}}, _} = run(%{"cwd" => repo, "action" => "push"})
    assert push["upstreamBranch"] == "upstream/feature/tax"

    assert git!(repo, ~w(config --get branch.feature/tax.gh-merge-base)) ==
             "upstream/develop\n"

    assert HalC2.Git.base_branch(repo, "feature/tax") == "upstream/develop"
  end

  # Review of #1837: the writer's log and patch for a pull request based on
  # a non-primary remote's branch are taken from that branch, not the
  # primary remote's branch of the same name; only `--base` is the bare name.
  test "pull request content is taken from the non-primary remote's base branch", %{
    repo: repo,
    origin: origin
  } do
    dir = Path.dirname(repo)
    log = fake_gh!(dir, "[]")
    upstream = Path.join(dir, "upstream.git")
    git!(dir, ["clone", "-q", "--bare", origin, upstream])
    git!(repo, ["remote", "add", "upstream", upstream])
    git!(repo, ~w(push -q origin main:develop))
    git!(repo, ~w(checkout -q -b tmpdev))
    File.write!(Path.join(repo, "up.txt"), "up\n")
    git!(repo, ~w(add up.txt))
    git!(repo, ~w(commit -q -m upstream-only))
    git!(repo, ~w(push -q upstream tmpdev:develop))
    git!(repo, ~w(checkout -q main))
    git!(repo, ~w(branch -q -D tmpdev))
    git!(repo, ~w(fetch -q origin))
    git!(repo, ~w(fetch -q upstream))
    git!(repo, ~w(checkout -q -b feature/tax upstream/develop))
    File.write!(Path.join(repo, "t.txt"), "t\n")
    git!(repo, ~w(add t.txt))
    git!(repo, ~w(commit -q -m tax))

    assert {{:ok, result}, _} = run(%{"cwd" => repo, "action" => "create_pr"})

    assert %{"pr" => %{"status" => "created", "number" => 7, "baseBranch" => "develop"}} =
             result

    # Only the commits and diff since the base are claimed here; the prompt
    # also lists recent subjects from the whole repository as style examples.
    [_style, compared] =
      dir |> Path.join("claude.log") |> File.read!() |> String.split("Commits:\n", parts: 2)

    assert compared =~ "tax"
    refute compared =~ "upstream-only"
    refute compared =~ "up.txt"
    assert File.read!(log) =~ "--base develop"
  end

  # Review of #1837: an alias branch is published under its upstream's name, so
  # the pull request is looked up and created with that name as its head.
  test "a pull request for an alias branch uses the published name as its head", %{
    repo: repo,
    origin: origin
  } do
    dir = Path.dirname(repo)
    log = Path.join(dir, "gh.log")

    gh = Path.join(dir, "gh")

    File.write!(gh, """
    #!/bin/sh
    echo "$@" >> #{log}
    if [ "$1 $2" = "pr list" ]; then echo '[]'; exit 0; fi
    if [ "$1 $2" = "pr create" ]; then echo 'https://github.com/acme/shop/pull/7'; exit 0; fi
    echo '{}'
    """)

    File.chmod!(gh, 0o755)

    claude = Path.join(dir, "claude")

    File.write!(claude, """
    #!/bin/sh
    cat > /dev/null
    printf '{"type":"result","structured_output":{"subject":"Add greeting file.","title":"Add greeting","body":"- says hello","branch":"add greeting"}}\\n'
    """)

    File.chmod!(claude, 0o755)

    previous_gh = Application.get_env(:hal_c2, :gh_command)
    Application.put_env(:hal_c2, :gh_command, gh)
    Application.put_env(:hal_c2, :text_claude_command, claude)
    on_exit(fn -> Application.put_env(:hal_c2, :gh_command, previous_gh) end)

    git!(repo, ["remote", "add", "upstream", origin])
    git!(repo, ~w(push -q origin main:effect-atom))
    git!(repo, ~w(fetch -q origin))
    git!(repo, ~w(checkout -q -b upstream/effect-atom origin/effect-atom))
    File.write!(Path.join(repo, "e.txt"), "e\n")
    git!(repo, ~w(add e.txt))
    git!(repo, ~w(commit -q -m effect))

    assert {{:ok, result}, _} = run(%{"cwd" => repo, "action" => "create_pr"})

    assert %{"push" => %{"status" => "pushed", "branch" => "upstream/effect-atom"}} = result
    assert %{"pr" => %{"status" => "created", "headBranch" => "effect-atom"}} = result

    calls = File.read!(log)
    assert calls =~ "--head effect-atom"
    refute calls =~ "--head upstream/effect-atom"
  end

  # Review finding r4705513530 on #1837: a branch published to a fork push
  # remote opens its pull request from the fork owner's head, and the
  # existing-PR lookup does not take a same-named branch on the base
  # repository for the fork's pull request. The remotes are given GitHub
  # addresses whose fetches and pushes git rewrites to the local bare
  # repositories (`insteadOf`), so the push still lands locally.
  test "a pull request for a branch published to a fork uses the fork owner's head", %{
    repo: repo,
    origin: origin
  } do
    dir = Path.dirname(repo)
    log = fake_gh!(dir, base_repo_pr_list())
    fork = fork_remotes!(repo, origin)
    git!(repo, ~w(push -q origin main:dev))
    git!(repo, ~w(fetch -q origin))
    git!(repo, ~w(checkout -q -b feature/tax origin/dev))
    git!(repo, ~w(config branch.feature/tax.pushRemote fork))
    File.write!(Path.join(repo, "t.txt"), "t\n")
    git!(repo, ~w(add t.txt))
    git!(repo, ~w(commit -q -m tax))

    assert {{:ok, result}, _} = run(%{"cwd" => repo, "action" => "create_pr"})

    assert %{"push" => %{"status" => "pushed", "upstreamBranch" => "fork/feature/tax"}} = result
    assert git!(fork, ~w(log -1 --format=%s feature/tax)) == "tax\n"

    # The open pull request #99 is from the base repository's own
    # feature/tax, so it is not this branch's pull request: a new one is
    # created from the fork.
    assert %{"pr" => %{"status" => "created", "number" => 7, "headBranch" => "feature/tax"}} =
             result

    create =
      log
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.find("", &String.starts_with?(&1, "pr create"))

    assert create =~ "--head forker:feature/tax"
    refute create =~ "--head feature/tax"
  end

  # The triangular case of the same finding: the branch tracks
  # `origin/feature/tax`, but `pushRemote` names the fork, so a plain
  # `git push` publishes it there and the pull request head must follow.
  test "a pull request for a branch tracking origin but pushing to a fork uses the fork owner's head",
       %{repo: repo, origin: origin} do
    dir = Path.dirname(repo)
    log = fake_gh!(dir, base_repo_pr_list())
    fork = fork_remotes!(repo, origin)
    git!(repo, ~w(checkout -q -b feature/tax))
    File.write!(Path.join(repo, "t.txt"), "t\n")
    git!(repo, ~w(add t.txt))
    git!(repo, ~w(commit -q -m tax))
    git!(repo, ~w(push -q -u origin feature/tax))
    git!(repo, ~w(config branch.feature/tax.pushRemote fork))
    File.write!(Path.join(repo, "t2.txt"), "t2\n")
    git!(repo, ~w(add t2.txt))
    git!(repo, ~w(commit -q -m tax-two))

    assert {{:ok, result}, _} = run(%{"cwd" => repo, "action" => "create_pr"})

    assert %{"push" => %{"status" => "pushed"}} = result
    assert git!(fork, ~w(log -1 --format=%s feature/tax)) == "tax-two\n"
    assert git!(origin, ~w(log -1 --format=%s feature/tax)) == "tax\n"

    assert %{"pr" => %{"status" => "created", "number" => 7, "headBranch" => "feature/tax"}} =
             result

    create =
      log
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.find("", &String.starts_with?(&1, "pr create"))

    assert create =~ "--head forker:feature/tax"
    refute create =~ "--head feature/tax"
  end

  # The reuse side of the same finding: when the fork's own pull request is
  # already open, it is the one opened — not the base repository's
  # same-named one listed before it, and nothing new is created. The fork
  # owner's login comes back in a different case, as `gh` may return it.
  test "an open pull request from the fork is reused", %{repo: repo, origin: origin} do
    dir = Path.dirname(repo)

    both =
      ~s([{"number":99,"title":"Base repo tax","url":"https://github.com/acme/shop/pull/99","baseRefName":"main","headRefName":"feature/tax","headRepositoryOwner":{"login":"acme"},"isCrossRepository":false},{"number":100,"title":"Fork tax","url":"https://github.com/acme/shop/pull/100","baseRefName":"main","headRefName":"feature/tax","headRepositoryOwner":{"login":"Forker"},"isCrossRepository":true}])

    log = fake_gh!(dir, both)
    fork = fork_remotes!(repo, origin)
    git!(repo, ~w(push -q origin main:dev))
    git!(repo, ~w(fetch -q origin))
    git!(repo, ~w(checkout -q -b feature/tax origin/dev))
    git!(repo, ~w(config branch.feature/tax.pushRemote fork))
    File.write!(Path.join(repo, "t.txt"), "t\n")
    git!(repo, ~w(add t.txt))
    git!(repo, ~w(commit -q -m tax))

    assert {{:ok, result}, _} = run(%{"cwd" => repo, "action" => "create_pr"})

    assert %{"push" => %{"status" => "pushed", "upstreamBranch" => "fork/feature/tax"}} = result
    assert git!(fork, ~w(log -1 --format=%s feature/tax)) == "tax\n"

    assert %{
             "pr" => %{
               "status" => "opened_existing",
               "number" => 100,
               "url" => "https://github.com/acme/shop/pull/100",
               "headBranch" => "feature/tax"
             }
           } = result

    refute File.read!(log) =~ "pr create"
  end

  # Review of #1837: a configured push remote is not a publication. A clean
  # branch in sync with its origin upstream skips the push, so its pull
  # request is still the origin one, however `pushRemote` is aimed.
  test "a branch in sync with origin reuses its pull request despite a fork push remote", %{
    repo: repo,
    origin: origin
  } do
    dir = Path.dirname(repo)
    log = fake_gh!(dir, base_repo_pr_list())
    fork = fork_remotes!(repo, origin)
    git!(repo, ~w(checkout -q -b feature/tax))
    File.write!(Path.join(repo, "t.txt"), "t\n")
    git!(repo, ~w(add t.txt))
    git!(repo, ~w(commit -q -m tax))
    git!(repo, ~w(push -q -u origin feature/tax))
    git!(repo, ~w(config branch.feature/tax.pushRemote fork))

    assert {{:ok, result}, _} = run(%{"cwd" => repo, "action" => "create_pr"})

    assert %{"pr" => %{"status" => "opened_existing", "number" => 99}} = result
    assert git!(fork, ~w(branch --list feature/tax)) == ""
    refute File.read!(log) =~ "pr create"
  end

  # Review of #1837: the fork owner comes from the remote's push URL — a
  # remote that fetches from the base repository but pushes to a fork
  # (`pushurl`) publishes there.
  test "a pull request for a branch pushed through a pushurl uses the fork owner's head", %{
    repo: repo,
    origin: origin
  } do
    dir = Path.dirname(repo)
    log = fake_gh!(dir, base_repo_pr_list())
    fork = Path.join(dir, "fork.git")
    git!(dir, ["clone", "-q", "--bare", origin, fork])
    git!(repo, ["config", "url.#{origin}.insteadOf", "https://github.com/acme/shop.git"])
    git!(repo, ["config", "url.#{fork}.insteadOf", "https://github.com/forker/shop.git"])
    git!(repo, ["remote", "set-url", "origin", "https://github.com/acme/shop.git"])
    git!(repo, ["remote", "set-url", "--push", "origin", "https://github.com/forker/shop.git"])
    git!(repo, ~w(checkout -q -b feature/tax))
    File.write!(Path.join(repo, "t.txt"), "t\n")
    git!(repo, ~w(add t.txt))
    git!(repo, ~w(commit -q -m tax))

    assert {{:ok, result}, _} = run(%{"cwd" => repo, "action" => "create_pr"})

    assert git!(fork, ~w(log -1 --format=%s feature/tax)) == "tax\n"
    assert git!(origin, ~w(branch --list feature/tax)) == ""

    assert %{"pr" => %{"status" => "created", "number" => 7, "headBranch" => "feature/tax"}} =
             result

    create =
      log
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.find("", &String.starts_with?(&1, "pr create"))

    assert create =~ "--head forker:feature/tax"
  end

  # Follow-up to #1837 (#1851): the branch was published to the base
  # repository and is in sync with it, so no push runs; `pushurl` has
  # since been aimed at a fork. Nothing in git's refs tells the two
  # apart, so the open pull request is looked for under both owners.
  test "an in-sync branch reuses the base repository's pull request despite a pushurl fork", %{
    repo: repo,
    origin: origin
  } do
    dir = Path.dirname(repo)
    log = fake_gh!(dir, base_repo_pr_list())
    fork = Path.join(dir, "fork.git")
    git!(dir, ["clone", "-q", "--bare", origin, fork])
    git!(repo, ["config", "url.#{origin}.insteadOf", "https://github.com/acme/shop.git"])
    git!(repo, ["config", "url.#{fork}.insteadOf", "https://github.com/forker/shop.git"])
    git!(repo, ["remote", "set-url", "origin", "https://github.com/acme/shop.git"])
    git!(repo, ~w(checkout -q -b feature/tax))
    File.write!(Path.join(repo, "t.txt"), "t\n")
    git!(repo, ~w(add t.txt))
    git!(repo, ~w(commit -q -m tax))
    git!(repo, ~w(push -q -u origin feature/tax))
    git!(repo, ["remote", "set-url", "--push", "origin", "https://github.com/forker/shop.git"])

    assert {{:ok, result}, _} = run(%{"cwd" => repo, "action" => "create_pr"})

    assert %{"pr" => %{"status" => "opened_existing", "number" => 99}} = result
    assert git!(fork, ~w(branch --list feature/tax)) == ""
    refute File.read!(log) =~ "pr create"
  end

  # The Forgejo twin of the in-sync `pushurl` case above.
  test "a Forgejo in-sync branch reuses the target repository's pull request despite a pushurl fork",
       %{repo: repo, origin: origin} do
    dir = Path.dirname(repo)
    log = fake_forgejo!(dir, [forgejo_pull(99, "feature/tax", "acme/shop")])
    fork = Path.join(dir, "fork.git")
    git!(dir, ["clone", "-q", "--bare", origin, fork])
    git!(repo, ["config", "url.#{origin}.insteadOf", "https://codeberg.org/acme/shop.git"])
    git!(repo, ["config", "url.#{fork}.insteadOf", "https://codeberg.org/forker/shop.git"])
    git!(repo, ["remote", "set-url", "origin", "https://codeberg.org/acme/shop.git"])
    git!(repo, ~w(checkout -q -b feature/tax))
    File.write!(Path.join(repo, "t.txt"), "t\n")
    git!(repo, ~w(add t.txt))
    git!(repo, ~w(commit -q -m tax))
    git!(repo, ~w(push -q -u origin feature/tax))
    git!(repo, ["remote", "set-url", "--push", "origin", "https://codeberg.org/forker/shop.git"])

    assert {{:ok, result}, _} = run(%{"cwd" => repo, "action" => "create_pr"})

    assert %{"pr" => %{"status" => "opened_existing", "number" => 99}} = result
    assert forgejo_posts(log) == []
  end

  # The Forgejo twin of the triangular GitHub case above: the branch
  # tracks `origin/feature/tax` (the target repository on codeberg.org),
  # but `pushRemote` names the fork, so the push lands there and the pull
  # request must be opened from the fork — not reuse the target
  # repository's own pull request #99 from a branch of the same name.
  test "a Forgejo pull request for a branch tracking origin but pushing to a fork uses the fork owner's head",
       %{repo: repo, origin: origin} do
    dir = Path.dirname(repo)
    log = fake_forgejo!(dir, [forgejo_pull(99, "feature/tax", "acme/shop")])
    fork = forgejo_fork_remotes!(repo, origin)
    git!(repo, ~w(checkout -q -b feature/tax))
    File.write!(Path.join(repo, "t.txt"), "t\n")
    git!(repo, ~w(add t.txt))
    git!(repo, ~w(commit -q -m tax))
    git!(repo, ~w(push -q -u origin feature/tax))
    git!(repo, ~w(config branch.feature/tax.pushRemote fork))
    File.write!(Path.join(repo, "t2.txt"), "t2\n")
    git!(repo, ~w(add t2.txt))
    git!(repo, ~w(commit -q -m tax-two))

    assert {{:ok, result}, _} = run(%{"cwd" => repo, "action" => "create_pr"})

    assert %{"push" => %{"status" => "pushed"}} = result
    assert git!(fork, ~w(log -1 --format=%s feature/tax)) == "tax-two\n"
    assert git!(origin, ~w(log -1 --format=%s feature/tax)) == "tax\n"

    assert %{"pr" => %{"status" => "created", "number" => 43, "headBranch" => "feature/tax"}} =
             result

    assert [post] = forgejo_posts(log)
    assert %{"head" => "forker:feature/tax", "base" => "main"} = JSON.decode!(post["body"])
  end

  # The Forgejo twin of the `pushurl` case above: the remote fetches from
  # the target repository but pushes to a fork, so the fork's owner is
  # the pull request's head owner.
  test "a Forgejo pull request for a branch pushed through a pushurl uses the fork owner's head",
       %{repo: repo, origin: origin} do
    dir = Path.dirname(repo)
    log = fake_forgejo!(dir, [forgejo_pull(99, "feature/tax", "acme/shop")])
    fork = Path.join(dir, "fork.git")
    git!(dir, ["clone", "-q", "--bare", origin, fork])
    git!(repo, ["config", "url.#{origin}.insteadOf", "https://codeberg.org/acme/shop.git"])
    git!(repo, ["config", "url.#{fork}.insteadOf", "https://codeberg.org/forker/shop.git"])
    git!(repo, ["remote", "set-url", "origin", "https://codeberg.org/acme/shop.git"])
    git!(repo, ["remote", "set-url", "--push", "origin", "https://codeberg.org/forker/shop.git"])
    git!(repo, ~w(checkout -q -b feature/tax))
    File.write!(Path.join(repo, "t.txt"), "t\n")
    git!(repo, ~w(add t.txt))
    git!(repo, ~w(commit -q -m tax))

    assert {{:ok, result}, _} = run(%{"cwd" => repo, "action" => "create_pr"})

    assert git!(fork, ~w(log -1 --format=%s feature/tax)) == "tax\n"
    assert git!(origin, ~w(branch --list feature/tax)) == ""

    assert %{"pr" => %{"status" => "created", "number" => 43, "headBranch" => "feature/tax"}} =
             result

    assert [post] = forgejo_posts(log)
    assert %{"head" => "forker:feature/tax", "base" => "main"} = JSON.decode!(post["body"])
  end

  # A branch cut from another (`feature/tax` from `origin/dev`) keeps its
  # own name as the pull request's head, though `branch.feature/tax.merge`
  # names `dev`, the branch it was cut from. The commit has since landed
  # on `dev`, so the action skips the push — its remembered base is main,
  # which its commits are read against.
  test "a Forgejo pull request for a branch cut from another uses the branch's own name as its head",
       %{repo: repo, origin: origin} do
    dir = Path.dirname(repo)
    log = fake_forgejo!(dir, [])
    forgejo_fork_remotes!(repo, origin)
    git!(repo, ~w(push -q origin main:dev))
    git!(repo, ~w(fetch -q origin))
    git!(repo, ~w(checkout -q -b feature/tax origin/dev))
    File.write!(Path.join(repo, "t.txt"), "t\n")
    git!(repo, ~w(add t.txt))
    git!(repo, ~w(commit -q -m tax))
    git!(repo, ~w(push -q origin feature/tax:dev))
    git!(repo, ~w(fetch -q origin))
    git!(repo, ~w(config branch.feature/tax.gh-merge-base main))

    assert {{:ok, result}, _} = run(%{"cwd" => repo, "action" => "create_pr"})

    assert %{"pr" => %{"status" => "created", "number" => 43, "headBranch" => "feature/tax"}} =
             result

    assert [post] = forgejo_posts(log)
    assert %{"head" => "feature/tax", "base" => "main"} = JSON.decode!(post["body"])
  end

  # What the fake `gh` answers `pr list` with in the fork tests: an open
  # pull request from the base repository's own `feature/tax`.
  defp base_repo_pr_list,
    do:
      ~s([{"number":99,"title":"Base repo tax","url":"https://github.com/acme/shop/pull/99","baseRefName":"main","headRefName":"feature/tax","headRepositoryOwner":{"login":"acme"},"isCrossRepository":false}])

  # Installs a fake `gh` answering `pr list` with `pr_list_json` and
  # `pr create` with pull request 7, plus the fake text generator the
  # create path asks for a title. Returns the `gh` call log's path.
  defp fake_gh!(dir, pr_list_json) do
    log = Path.join(dir, "gh.log")
    gh = Path.join(dir, "gh")

    File.write!(gh, """
    #!/bin/sh
    echo "$@" >> "#{log}"
    if [ "$1 $2" = "pr list" ]; then echo '#{pr_list_json}'; exit 0; fi
    if [ "$1 $2" = "pr create" ]; then echo 'https://github.com/acme/shop/pull/7'; exit 0; fi
    echo '{}'
    """)

    File.chmod!(gh, 0o755)
    fake_claude!(dir)

    previous_gh = Application.get_env(:hal_c2, :gh_command)
    Application.put_env(:hal_c2, :gh_command, gh)
    on_exit(fn -> Application.put_env(:hal_c2, :gh_command, previous_gh) end)
    log
  end

  # The fake text generator the create path asks for a title and body.
  defp fake_claude!(dir) do
    claude = Path.join(dir, "claude")

    File.write!(claude, """
    #!/bin/sh
    cat > "#{Path.join(dir, "claude.log")}"
    printf '{"type":"result","structured_output":{"subject":"Add greeting file.","title":"Add greeting","body":"- says hello","branch":"add greeting"}}\\n'
    """)

    File.chmod!(claude, 0o755)
    Application.put_env(:hal_c2, :text_claude_command, claude)
  end

  # A fake Forgejo server (codeberg.org) signed in with fj's token: its
  # pull list answers `listed`, a create answers pull request 43. Returns
  # the request log (`HalC2.Test.FakeHttp.requests/1`).
  defp fake_forgejo!(dir, listed) do
    keys = Path.join(dir, "keys.json")

    File.write!(
      keys,
      JSON.encode!(%{
        "hosts" => %{"codeberg.org" => %{"type" => "Application", "token" => "fj-token"}},
        "aliases" => %{}
      })
    )

    fj = Path.join(dir, "fj")
    File.write!(fj, "#!/bin/sh\nexit 0\n")
    File.chmod!(fj, 0o755)

    previous_keys = Application.get_env(:hal_c2, :fj_keys_paths)
    previous_fj = Application.get_env(:hal_c2, :fj_command)
    Application.put_env(:hal_c2, :fj_keys_paths, [keys])
    Application.put_env(:hal_c2, :fj_command, fj)

    on_exit(fn ->
      Application.put_env(:hal_c2, :fj_keys_paths, previous_keys)
      Application.put_env(:hal_c2, :fj_command, previous_fj)
    end)

    created = %{
      "number" => 43,
      "html_url" => "https://codeberg.org/acme/shop/pulls/43",
      "title" => "Add greeting"
    }

    {base, log} =
      HalC2.Test.FakeHttp.start(%{
        "/api/v1/repos/acme/shop/pulls" => fn
          %{method: "POST"} ->
            {201, created}

          conn ->
            {200, if(conn.query_string =~ "page=1", do: listed, else: [])}
        end
      })

    previous_base = System.get_env("HAL_C2_FORGEJO_API_BASE_URL")
    System.put_env("HAL_C2_FORGEJO_API_BASE_URL", base)

    on_exit(fn ->
      if previous_base,
        do: System.put_env("HAL_C2_FORGEJO_API_BASE_URL", previous_base),
        else: System.delete_env("HAL_C2_FORGEJO_API_BASE_URL")
    end)

    fake_claude!(dir)
    log
  end

  defp forgejo_pull(number, head, head_repository),
    do: %{
      "number" => number,
      "title" => "Change #{number}",
      "html_url" => "https://codeberg.org/acme/shop/pulls/#{number}",
      "state" => "open",
      "merged" => false,
      "base" => %{"ref" => "main"},
      "head" => %{"ref" => head, "repo" => %{"full_name" => head_repository}}
    }

  defp forgejo_posts(log),
    do: for(r <- HalC2.Test.FakeHttp.requests(log), r["method"] == "POST", do: r)

  # As `fork_remotes!/2`, on codeberg.org (a Forgejo host) instead of GitHub.
  defp forgejo_fork_remotes!(repo, origin) do
    dir = Path.dirname(repo)
    fork = Path.join(dir, "fork.git")
    git!(dir, ["clone", "-q", "--bare", origin, fork])
    git!(repo, ["config", "url.#{origin}.insteadOf", "https://codeberg.org/acme/shop.git"])
    git!(repo, ["config", "url.#{fork}.insteadOf", "https://codeberg.org/forker/shop.git"])
    git!(repo, ["remote", "set-url", "origin", "https://codeberg.org/acme/shop.git"])
    git!(repo, ["remote", "add", "fork", "https://codeberg.org/forker/shop.git"])
    fork
  end

  # Gives `repo` an `origin` naming `acme/shop` and a `fork` naming
  # `forker/shop`, both rewritten (`insteadOf`) to local bare repositories
  # so fetches and pushes still land locally. Returns the fork's path.
  defp fork_remotes!(repo, origin) do
    dir = Path.dirname(repo)
    fork = Path.join(dir, "fork.git")
    git!(dir, ["clone", "-q", "--bare", origin, fork])
    git!(repo, ["config", "url.#{origin}.insteadOf", "https://github.com/acme/shop.git"])
    git!(repo, ["config", "url.#{fork}.insteadOf", "https://github.com/forker/shop.git"])
    git!(repo, ["remote", "set-url", "origin", "https://github.com/acme/shop.git"])
    git!(repo, ["remote", "add", "fork", "https://github.com/forker/shop.git"])
    fork
  end

  test "feature branch names" do
    assert GitActions.feature_branch_name("Add Login Form!") == "feature/add-login-form"
    assert GitActions.feature_branch_name("feature/x y") == "feature/x-y"
    assert GitActions.feature_branch_name("...") == "feature/update"
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end
end
