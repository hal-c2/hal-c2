defmodule HalC2.Steps.SourceControl.StatusAndChanges do
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.SourceControl.Shared
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

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
    Mc.ensure(HalC2.BackgroundPolicy)

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
    Mc.ensure(HalC2.BackgroundPolicy)
    context = World.watch_vcs(context, context.cwd)

    HalC2.BackgroundPolicy.report_client_activity("session", self(), %{
      "clientId" => "client-1",
      "clientKind" => "web",
      "visible" => in_front?,
      "focused" => in_front?,
      "scopes" => [%{"type" => "vcs-status", "cwd" => context.cwd}]
    })

    # Leases are cast; a call behind it sees the lease in place.
    assert HalC2.BackgroundPolicy.snapshot()["activeForegroundLeaseCount"] ==
             if(in_front?, do: 1, else: 0)

    context
  end

  defp watcher(context) do
    [{pid, _}] = Registry.lookup(HalC2.Vcs.Registry, context.cwd)
    pid
  end

  # Someone else pushes to the remote; only a fetch shows it here.
  defp upstream_moves(context) do
    other = Mc.tmp_dir(context.mc, "other")
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
    context = context |> shared_answers() |> show(true) |> upstream_moves()
    Map.put(context, :reply, {:ok, Map.merge(context.vcs.local, context.vcs.remote)})
  end

  step "{int} seconds pass", %{args: [seconds]} = context do
    if root = context[:codex_skills_read] do
      # A Codex skills read (providers/codex.feature) is bounded at 20 seconds of
      # its own; asking for the folder's skills is what waits it out.
      reply = HalC2.Environment.refresh_providers(%{"cwd" => root, "instanceId" => "codex"})

      context
      |> Map.merge(%{reply: reply, skills_cwd: root})
      |> Map.delete(:codex_skills_read)
    else
      {message, remaining} = elapse(context)
      assert message == :fetch
      assert remaining <= seconds * 1_000
      context
    end
  end

  step "the MC fetches from the remote and the ahead and behind counts are updated",
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

  step "the MC never fetches from the remote without being asked", context do
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

  step "the MC does not fetch {string} from the remote", %{args: [_title]} = context do
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

  # --- one answer per branch (`HalC2.PullRequests.Branches`) ----------------------------

  # The branch answers are shared, on a clock the scenario moves.
  defp shared_answers(context) do
    if context[:clock] do
      context
    else
      Mc.ensure(HalC2.PullRequests.Branches)
      ref = :atomics.new(1, signed: true)
      :atomics.put(ref, 1, DateTime.to_unix(~U[2026-11-03 10:00:00Z], :millisecond))
      Application.put_env(:hal_c2, :github_clock, fn -> :atomics.get(ref, 1) end)
      ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :github_clock) end)
      Map.put(context, :clock, ref)
    end
  end

  defp pass(context, ms), do: :atomics.add(context.clock, 1, ms)

  defp asked(context, branch), do: length(World.cli_calls(context, "--head #{branch}"))

  # The watcher's automatic fetch runs now; the pull request it holds afterwards.
  defp fetch_now(context) do
    {message, _} = elapse(context)
    assert message == :fetch
    :sys.get_state(watcher(context)).remote["pr"]
  end

  step "the host refuses the pull request lookup for {string} every time",
       %{args: [branch]} = context do
    context
    |> shared_answers()
    |> World.cli_rules(%{
      "args" => ["pr list", "--head #{branch}"],
      "stderr" => "error connecting to api.github.com\n",
      "exit" => 1
    })
    |> Map.put(:pr_branch, branch)
  end

  step ~r/^the host's last answer for "(?<branch>[^"]+)" was (?<answer>an open pull request|a merged pull request|no pull request at all)$/,
       %{args: [branch, answer]} = context do
    answer =
      case answer do
        "an open pull request" -> [pr(42, branch, "OPEN", false)]
        "a merged pull request" -> [pr(42, branch, "MERGED", false)]
        "no pull request at all" -> []
      end

    context
    |> shared_answers()
    |> World.cli_rules(%{"args" => ["pr list", "--head #{branch}"], "stdout" => answer})
    |> Map.put(:pr_branch, branch)
  end

  step "a client in front is showing a thread in {string} on {string}",
       %{args: [title, branch]} = context do
    assert World.project(context, title).root == context.cwd
    git(context, ["checkout", "-q", "-b", branch])
    context = context |> fetch_interval(30) |> show(true)
    Map.put(context, :asked_at, asked(context, branch))
  end

  step "the status's automatic fetch runs again and again", context do
    fetch_now(context)
    # The watcher asked when it started, and the failure is still waited out.
    assert asked(context, context.pr_branch) == 1
    context
  end

  step "the lookup is retried after 20 seconds, then 40 seconds, doubling up to 15 minutes",
       context do
    for wait <- [20, 40, 80, 160, 320, 640, 900, 900], reduce: 1 do
      asks ->
        pass(context, wait * 1_000 - 1)
        fetch_now(context)
        assert asked(context, context.pr_branch) == asks, "asked before #{wait} s"
        pass(context, 1)
        fetch_now(context)
        assert asked(context, context.pr_branch) == asks + 1, "not asked after #{wait} s"
        asks + 1
    end

    context
  end

  step "the first answer that succeeds brings back the normal rhythm", context do
    branch = context.pr_branch

    context =
      World.cli_rules(context, %{
        "args" => ["pr list", "--head #{branch}"],
        "stdout" => [pr(42, branch, "OPEN", false)]
      })

    asks = asked(context, branch)
    pass(context, 900_000)
    assert %{"number" => 42, "state" => "open"} = fetch_now(context)
    assert asked(context, branch) == asks + 1
    # An open pull request is believed for a minute.
    pass(context, 59_999)
    fetch_now(context)
    assert asked(context, branch) == asks + 1
    pass(context, 1)
    fetch_now(context)
    assert asked(context, branch) == asks + 2
    context
  end

  step "the status's automatic fetch runs over the next minutes", context do
    fetch_now(context)
    assert asked(context, context.pr_branch) == 1
    context
  end

  step ~r/^the host is asked again after about (?<count>\d+) minutes?$/,
       %{args: [count]} = context do
    wait = String.to_integer(count) * 60_000
    pass(context, wait - 1)
    fetch_now(context)
    assert asked(context, context.pr_branch) == 1
    pass(context, 1)
    fetch_now(context)
    assert asked(context, context.pr_branch) == 2
    context
  end

  step "the MC has found the pull request of the thread {string} on {string}",
       %{args: [thread, branch]} = context do
    context = shared_answers(context)
    Mc.ensure({HalC2.PullRequests.Discovery, interval: nil})

    context =
      World.command(context, %{
        "type" => "thread.metadata.update",
        "threadId" => World.thread_id(context, thread),
        "branch" => branch
      })

    assert {:ok, _} = context.reply
    # The sidebar row Discovery reads is written behind the command.
    HalC2.Streams.flush_shell(World.thread_id(context, thread))
    :ok = HalC2.PullRequests.Discovery.sweep()
    # The branch change also queued a run of Discovery's own behind the sweep, which may
    # read the row from before the sweep's write and ask GitHub to confirm it: it ends
    # before the count, with the sweep's row in the shell, rather than during the status.
    HalC2.Streams.flush_shell(World.thread_id(context, thread))
    for _ <- 1..2, do: :sys.get_state(HalC2.PullRequests.Discovery)
    assert %{"number" => 42} = World.thread(context, thread)["branchPullRequest"]
    Map.put(context, :asked_before, asked(context, branch))
  end

  step "the status did not ask the host about {string}", %{args: [branch]} = context do
    assert asked(context, branch) == context.asked_before
    context
  end

  step "the status asked the host about {string} again", %{args: [branch]} = context do
    assert asked(context, branch) == context.asked_before + 1
    context
  end

  step "the user refreshes the pull requests", context do
    context = Map.put(context, :asked_before, asked(context, "feature/tax"))
    {reply, context} = World.call(context, "pullRequests.invalidate", %{})
    assert {:ok, _} = reply
    context
  end

  step "the status's automatic fetch runs", context do
    fetch_now(context)
    context
  end

  # --- not a repository ---------------------------------------------------------------

  step "the project {string} is not in a git repository", %{args: [title]} = context do
    root = Mc.tmp_dir(context.mc, World.slug(title))
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
