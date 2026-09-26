defmodule T3.Steps.SourceControl.StatusAndChanges do
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.Steps.SourceControl.Shared
  alias T3.Test.Node
  alias T3.Test.Node.World

  defp git(context, args), do: World.git!(context.cwd, args)

  defp status(context) do
    assert {:ok, status} = context.reply
    status
  end

  step "a connected environment with the project {string} in a git repository",
       %{args: [title]} = context do
    Shared.thread_in_git_project(context, title)
  end

  # --- local status --------------------------------------------------------------------

  step "the user has changed {string} and added {string} on the branch {string}",
       %{args: [changed, added, branch]} = context do
    World.commit!(context.cwd, %{changed => "one\ntwo\nthree\n"}, "Add #{changed}")
    git(context, ["checkout", "-q", "-b", branch])
    File.write!(Path.join(context.cwd, changed), "one\n2\n3\nfour\n")
    File.write!(Path.join(context.cwd, added), "export const tax = 1\nexport const rate = 2\n")
    git(context, ["add", added])
    Map.put(context, :changed, %{changed => {3, 2}, added => {2, 0}})
  end

  step "the status names the branch {string}", %{args: [branch]} = context do
    assert status(context)["refName"] == branch
    context
  end

  step "it lists both files with their inserted and deleted line counts", context do
    files =
      for f <- status(context)["workingTree"]["files"],
          into: %{},
          do: {f["path"], {f["insertions"], f["deletions"]}}

    assert files == context.changed
    context
  end

  step "it says the working tree has changes", context do
    assert status(context)["hasWorkingTreeChanges"] == true
    context
  end

  step "{string} tracks {string} and is 2 commits ahead and 1 behind",
       %{args: [branch, "origin/" <> branch]} = context do
    git(context, ["checkout", "-q", "-b", branch])
    World.commit!(context.cwd, %{"upstream.ts" => "1\n"}, "Upstream work")
    git(context, ~w(push -q -u origin HEAD))
    git(context, ~w(reset -q --hard HEAD~1))
    World.commit!(context.cwd, %{"cart.ts" => "1\n"}, "Add cart")
    World.commit!(context.cwd, %{"tax.ts" => "1\n"}, "Add tax")
    context
  end

  step "the status says the branch has an upstream", context do
    assert status(context)["hasUpstream"] == true
    context
  end

  step "it reports 2 commits ahead and 1 behind", context do
    assert {status(context)["aheadCount"], status(context)["behindCount"]} == {2, 1}
    context
  end

  # --- the status stream ------------------------------------------------------------

  step "the agent's turn ends after editing a file", context do
    World.run_turn(context, context.thread_title, "write notes.md")
  end

  step "the thread's status shows the new change without the user asking for a refresh",
       context do
    {event, context} =
      World.await_vcs(context, &(&1["_tag"] == "localUpdated"), 10_000)

    assert event["local"]["hasWorkingTreeChanges"]
    assert Enum.any?(event["local"]["workingTree"]["files"], &(&1["path"] == "notes.md"))
    context
  end

  step "the user is looking at a thread in {string} with uncommitted changes",
       %{args: [title]} = context do
    root = World.project(context, title).root
    File.write!(Path.join(root, "cart.ts"), "export const cart = 1\n")
    context = World.watch_vcs(context, root)
    assert context.vcs.local["hasWorkingTreeChanges"]
    context
  end

  step "the user commits the changes", context do
    {events, context} =
      World.git_action(context, context.cwd, "commit", %{"commitMessage" => "Add the cart"})

    assert List.last(events)["kind"] == "action_finished"
    Map.put(context, :git_events, events)
  end

  step "the thread's status reports a clean working tree", context do
    {event, context} =
      World.await_vcs(
        context,
        &(&1["_tag"] == "localUpdated" and &1["local"]["hasWorkingTreeChanges"] == false)
      )

    assert event["local"]["workingTree"]["files"] == []
    context
  end

  # --- background fetches -----------------------------------------------------------

  defp fetch_interval(context, seconds) do
    Node.ensure(T3.BackgroundPolicy)

    World.put_settings(context, %{
      "backgroundActivity" => %{
        "profile" => "custom",
        "baseProfile" => "balanced",
        "overrides" => %{"automaticGitFetchInterval" => seconds * 1_000}
      }
    })
  end

  # A client lease on the checkout's status, as `server.reportClientActivity` takes it.
  defp show(context, in_front?) do
    context = World.watch_vcs(context, context.cwd)

    T3.BackgroundPolicy.report_client_activity("session", self(), %{
      "clientId" => "client-1",
      "clientKind" => "web",
      "visible" => in_front?,
      "focused" => in_front?,
      "scopes" => [%{"type" => "vcs-status", "cwd" => context.cwd}]
    })

    # Leases are cast; a call behind it sees the lease in place.
    assert T3.BackgroundPolicy.snapshot()["activeForegroundLeaseCount"] ==
             if(in_front?, do: 1, else: 0)

    context
  end

  defp watcher(context) do
    [{pid, _}] = Registry.lookup(T3.Vcs.Registry, context.cwd)
    pid
  end

  # Someone else pushes to the remote; only a fetch shows it here.
  defp upstream_moves(context) do
    other = Node.tmp_dir(context.node, "other")
    World.git!(other, ["clone", "-q", context.bare, "."])

    World.git!(
      other,
      ~w(-c user.email=o@example.com -c user.name=O commit -q --allow-empty -m remote)
    )

    World.git!(other, ~w(push -q origin HEAD:main))
    Map.put(context, :tracking_before, git(context, ~w(rev-parse origin/main)))
  end

  # Time passes until the watcher's armed timer fires: it is cancelled and its
  # message delivered now. Returns which message that was.
  defp elapse(context) do
    pid = watcher(context)
    {message, ref} = :sys.get_state(pid).timer
    remaining = Process.cancel_timer(ref)
    send(pid, message)
    _ = :sys.get_state(pid)
    {message, remaining}
  end

  step "the automatic Git fetch interval is {int} seconds", %{args: [seconds]} = context do
    fetch_interval(context, seconds)
  end

  step "a client in front is showing a thread in {string}", %{args: [title]} = context do
    assert World.project(context, title).root == context.cwd
    context |> show(true) |> upstream_moves()
  end

  step "{int} seconds pass", %{args: [seconds]} = context do
    {message, remaining} = elapse(context)
    assert message == :fetch
    assert remaining <= seconds * 1_000
    context
  end

  step "the node fetches from the remote and the ahead and behind counts are updated",
       context do
    {event, context} = World.await_vcs(context, &(&1["_tag"] == "remoteUpdated"))
    assert event["remote"]["behindCount"] == 1
    refute git(context, ~w(rev-parse origin/main)) == context.tracking_before
    context
  end

  step "a client shows a thread in {string} for several minutes", %{args: [title]} = context do
    assert World.project(context, title).root == context.cwd
    context = context |> show(true) |> upstream_moves()
    fired = for _ <- 1..6, do: elapse(context) |> elem(0)
    Map.put(context, :fired, fired)
  end

  step "the node never fetches from the remote without being asked", context do
    assert Enum.all?(context.fired, &(&1 == :fetch_off))
    assert git(context, ~w(rev-parse origin/main)) == context.tracking_before
    context
  end

  step "no client is showing a thread in {string}", %{args: [title]} = context do
    assert World.project(context, title).root == context.cwd
    # A client has the thread open in the background: subscribed, not in front.
    context |> fetch_interval(30) |> show(false) |> upstream_moves()
  end

  step "the fetch interval elapses", context do
    {message, _} = elapse(context)
    assert message == :fetch
    context
  end

  step "the node does not fetch {string} from the remote", %{args: [_title]} = context do
    assert git(context, ~w(rev-parse origin/main)) == context.tracking_before
    context
  end

  # --- pull requests ------------------------------------------------------------------

  defp pr(number, branch, state, draft?) do
    %{
      "number" => number,
      "title" => "Add tax",
      "url" => "https://github.com/acme/shop/pull/#{number}",
      "baseRefName" => "main",
      "headRefName" => branch,
      "state" => state,
      "isDraft" => draft?,
      "updatedAt" => "2026-09-20T10:00:00Z"
    }
  end

  step "{string} has an open draft pull request on GitHub", %{args: [branch]} = context do
    git(context, ["checkout", "-q", "-b", branch])

    World.cli_rules(context, [
      %{"args" => ["pr list", "--head #{branch}"], "stdout" => [pr(42, branch, "OPEN", true)]}
    ])
  end

  step "the status carries that pull request with its state open and marked as a draft",
       context do
    assert %{"number" => 42, "state" => "open", "isDraft" => true, "headRef" => "feature/tax"} =
             status(context)["pr"]

    context
  end

  step "{string} once had a merged pull request from the same branch name",
       %{args: [branch]} = context do
    World.cli_rules(context, [
      %{"args" => ["pr list", "--head #{branch}"], "stdout" => [pr(9, branch, "MERGED", false)]}
    ])
  end

  step "status is read on {string}", %{args: [branch]} = context do
    assert git(context, ~w(branch --show-current)) == branch
    {reply, context} = World.call(context, "vcs.refreshStatus", %{"cwd" => context.cwd})
    assert World.cli_calls(context, "--head #{branch}") != []
    Map.put(context, :reply, reply)
  end

  step "the status carries no pull request", context do
    assert status(context)["pr"] == nil
    context
  end

  # --- not a repository ---------------------------------------------------------------

  step "the project {string} is not in a git repository", %{args: [title]} = context do
    root = Node.tmp_dir(context.node, World.slug(title))
    World.create_project(context, title, %{"workspaceRoot" => root})
  end

  step "the status says it is not a repository", context do
    assert status(context)["isRepo"] == false
    context
  end

  step "{string} becomes a git repository", %{args: [title]} = context do
    assert {:ok, _} = context.reply
    assert File.dir?(Path.join(World.project(context, title).root, ".git"))
    context
  end

  step "the git actions for {string} become available", %{args: [title]} = context do
    {reply, context} =
      World.call(context, "vcs.refreshStatus", %{"cwd" => World.project(context, title).root})

    assert {:ok, %{"isRepo" => true}} = reply
    context
  end
end
