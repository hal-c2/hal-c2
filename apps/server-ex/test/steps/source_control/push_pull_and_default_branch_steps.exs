defmodule HalC2.Steps.SourceControl.PushPullAndDefaultBranch do
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.SourceControl.Shared
  alias HalC2.Test.Node
  alias HalC2.Test.Node.World

  # --- checkouts and their upstreams ---------------------------------------------

  defp git(context, args), do: World.git!(context.cwd, args)

  defp head(cwd), do: World.git!(cwd, ~w(rev-parse HEAD))

  defp bare_head(context, branch),
    do: World.git!(context.bare, ["rev-parse", "refs/heads/#{branch}"])

  defp change(context, name) do
    World.commit!(context.cwd, %{"src/#{name}.ts" => "export const #{name} = 1\n"}, "Add #{name}")
  end

  defp branch(context, name) do
    git(context, ["checkout", "-q", "-b", name])
    context
  end

  defp track(context) do
    git(context, ~w(push -q -u origin HEAD))
    context
  end

  # Commits `n` changes, publishes them and forgets them locally: the branch is `n` behind.
  defp behind(context, n) do
    for i <- 1..n, do: change(context, "upstream#{i}#{System.unique_integer([:positive])}")
    git(context, ~w(push -q origin HEAD))
    git(context, ["reset", "-q", "--hard", "HEAD~#{n}"])
    context
  end

  defp snapshot(context) do
    Map.put(context, :checkout_before, %{
      head: head(context.cwd),
      branch: git(context, ~w(branch --show-current)),
      status: git(context, ~w(status --porcelain))
    })
  end

  defp pull(context) do
    {reply, context} = World.call(context, "vcs.pull", %{"cwd" => context.cwd})
    Map.put(context, :reply, reply)
  end

  defp result(context) do
    last = List.last(context.git_events)
    assert last["kind"] == "action_finished", "the action failed: #{inspect(last)}"
    last["result"]
  end

  step "a connected environment with a thread in the git project {string} with the remote {string}",
       %{args: [title, remote]} = context do
    context = Shared.thread_in_git_project(context, title)
    assert remote in String.split(git(context, ["remote"]), "\n")
    context
  end

  step "{string} tracks {string} and is 1 commit ahead", %{args: [name, _upstream]} = context do
    context = context |> branch(name) |> track()
    change(context, "cart")
    Map.put(context, :pushed, head(context.cwd))
  end

  step "{string} has the new commit", %{args: ["origin/" <> branch]} = context do
    assert bare_head(context, branch) == context.pushed
    context
  end

  step "the user is told where the branch was pushed", context do
    %{"push" => push, "toast" => toast} = result(context)
    assert push["status"] == "pushed"
    assert toast["title"] == "Pushed to #{push["upstreamBranch"]}"
    assert toast["title"] =~ "origin/feature/tax"
    context
  end

  step "{string} has never been pushed", %{args: [name]} = context do
    context = branch(context, name)
    change(context, "cart")
    refute World.git!(context.bare, ~w(branch --list)) =~ name

    Map.put(context, :pushed, head(context.cwd))
  end

  step "the branch is pushed to {string} and tracks it from now on",
       %{args: ["origin/" <> branch = upstream]} = context do
    %{"push" => push} = result(context)
    assert push["status"] == "pushed"
    assert push["setUpstream"] == true
    assert bare_head(context, branch) == context.pushed
    assert git(context, ~w(rev-parse --abbrev-ref --symbolic-full-name @{upstream})) == upstream
    context
  end

  step "{string} is level with its upstream", %{args: [name]} = context do
    context = branch(context, name)
    change(context, "cart")
    context |> track() |> Map.put(:pushed, head(context.cwd))
  end

  step "nothing is pushed and the push step is reported as already up to date", context do
    %{"push" => push} = result(context)
    assert push["status"] == "skipped_up_to_date"
    assert bare_head(context, "feature/tax") == context.pushed
    context
  end

  step "{string} is not the default branch and has no pull request", %{args: [name]} = context do
    context = branch(context, name)
    change(context, "cart")
    assert World.cli_calls(context, "pr create") == []
    context
  end

  step "the result offers to create a pull request", context do
    %{"toast" => %{"cta" => cta}} = result(context)
    assert cta["kind"] == "run_action"
    assert cta["action"] == %{"kind" => "create_pr"}
    context
  end

  step "the user commits on a branch with an upstream", context do
    context = context |> branch("feature/tax") |> track()
    File.write!(Path.join(context.cwd, "cart.ts"), "export const cart = 1\n")

    {events, context} =
      World.git_action(context, context.cwd, "commit", %{"commitMessage" => "Add the cart"})

    Map.put(context, :git_events, events)
  end

  step "the result offers to push the commit", context do
    %{"commit" => commit, "toast" => %{"cta" => cta}} = result(context)
    assert commit["status"] == "created"
    assert cta["kind"] == "run_action"
    assert cta["action"] == %{"kind" => "push"}
    context
  end

  # --- pulling -----------------------------------------------------------------------

  step "{string} is 2 commits behind its upstream and has no local commits",
       %{args: [name]} = context do
    context = context |> branch(name) |> track() |> behind(2)
    Map.put(context, :pushed, bare_head(context, name))
  end

  step "the user pulls", context do
    context |> snapshot() |> pull()
  end

  step "the branch has the 2 new commits", context do
    assert {:ok, %{"status" => "pulled", "refName" => "feature/tax"}} = context.reply
    assert head(context.cwd) == context.pushed
    assert git(context, ["rev-list", "--count", "#{context.checkout_before.head}..HEAD"]) == "2"
    context
  end

  step "{string} is 1 commit ahead and 1 behind its upstream", %{args: [name]} = context do
    context = context |> branch(name) |> track() |> behind(1)
    change(context, "local")
    status = HalC2.Vcs.remote_status(context.cwd)
    assert {status["aheadCount"], status["behindCount"]} == {1, 1}
    context
  end

  step "the pull fails without merging or rebasing anything", context do
    assert {:error, _, _} = context.reply
    assert head(context.cwd) == context.checkout_before.head
    git_dir = Path.join(context.cwd, ".git")
    refute File.exists?(Path.join(git_dir, "MERGE_HEAD"))
    refute File.exists?(Path.join(git_dir, "rebase-merge"))
    refute File.exists?(Path.join(git_dir, "rebase-apply"))
    context
  end

  step "the checkout has no upstream", context do
    branch(context, "feature/local")
  end

  step "the pull fails with {string}", %{args: [message]} = context do
    assert {:error, error, detail} = context.reply
    assert (detail || %{})["detail"] == message or error =~ message
    context
  end

  # --- pulling at start ----------------------------------------------------------------

  # The node refuses a second project for a folder, as the Node server does, but a
  # database from before that check can hold two; this one is written as stored data.
  defp stored_project(context, title, root) do
    id = String.replace(title, " ", "-")
    at = HalC2.Orchestration.Entities.now()

    project = %{
      "id" => id,
      "title" => title,
      "workspaceRoot" => root,
      "scripts" => [],
      "createdAt" => at,
      "updatedAt" => at,
      "deletedAt" => nil
    }

    {:ok, _} =
      HalC2.Streams.commit(id, :project, [{"project", id, HalC2.Patch.diff(nil, project)}])

    World.await_row(id, & &1)
    put_in(context, [:projects, title], %{id: id, root: root})
  end

  defp auto_pull(context, title) do
    id = World.project(context, title).id

    # `Node.restart/1` runs the boot's auto-pull, as the application does.
    World.put_settings(context, %{
      "projectSettingsOverrides" => %{id => %{"defaultAutoPull" => true}}
    })
  end

  step "{string} is set to pull automatically", %{args: [title]} = context do
    auto_pull(context, title)
  end

  step "its checkout is clean on {string} and 2 commits behind {string}",
       %{args: [branch, _upstream]} = context do
    assert git(context, ~w(branch --show-current)) == branch
    context |> behind(2) |> snapshot()
  end

  step "{string} is fast-forwarded to {string}",
       %{args: [branch, "origin/" <> branch]} = context do
    assert git(context, ~w(branch --show-current)) == branch
    assert head(context.cwd) == bare_head(context, branch)
    refute head(context.cwd) == context.checkout_before.head
    context
  end

  step "its checkout has uncommitted changes", context do
    context = behind(context, 2)
    File.write!(Path.join(context.cwd, "draft.ts"), "export const draft = 1\n")
    snapshot(context)
  end

  step "its checkout is on a branch other than the default", context do
    context |> branch("feature/tax") |> track() |> behind(2) |> snapshot()
  end

  step "its checkout has no upstream", context do
    context = behind(context, 2)
    git(context, ~w(branch -q --unset-upstream))
    snapshot(context)
  end

  step "its checkout has commits of its own to push", context do
    context = behind(context, 1)
    change(context, "local")
    snapshot(context)
  end

  step "its checkout has nothing new to pull", context do
    snapshot(context)
  end

  step "the checkout is left as it was", context do
    before = context.checkout_before
    assert head(context.cwd) == before.head
    assert git(context, ~w(branch --show-current)) == before.branch
    assert git(context, ~w(status --porcelain)) == before.status
    context
  end

  step "two projects set to pull automatically share one checkout that is behind its upstream",
       context do
    root = World.project(context, "shop").root

    context
    |> stored_project("shop again", root)
    |> auto_pull("shop")
    |> auto_pull("shop again")
    |> behind(2)
    |> snapshot()
  end

  step "the checkout is pulled once", context do
    pulls =
      git(context, ~w(reflog --format=%gs)) |> String.split("\n") |> Enum.filter(&(&1 =~ "pull"))

    assert length(pulls) == 1, "expected one pull, got #{inspect(pulls)}"
    assert head(context.cwd) == bare_head(context, "main")
    context
  end

  step "{string} is set to pull automatically and is behind its upstream",
       %{args: [title]} = context do
    context |> auto_pull(title) |> behind(2) |> snapshot()
  end

  step "the pull fails", context do
    # The remote is gone: the fetch before the pull fails, the pull after it too.
    File.rename!(context.bare, context.bare <> ".gone")
    World.capture_log(context)
  end

  step "the failure is written to the node's log", context do
    log = World.logged(context)
    assert log =~ "automatic pull of #{context.cwd} failed"
    assert head(context.cwd) == context.checkout_before.head
    context
  end

  step "the node finishes starting", context do
    # The config snapshot arrives once the node serves clients again.
    client = context.node |> Node.connect() |> Node.config()
    assert Process.whereis(HalC2.Shell)
    World.put_client(context, client)
  end
end
