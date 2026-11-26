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
