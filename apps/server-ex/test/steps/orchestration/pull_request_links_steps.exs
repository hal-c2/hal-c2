defmodule HalC2.Steps.Orchestration.PullRequestLinks do
  @moduledoc "Steps for features/mc/orchestration/pull-request-links.feature."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Projection.PullRequests
  alias HalC2.Test.Mc.World

  # --- arranging --------------------------------------------------------------------

  step "thread {string} exists in {string} on branch {string}",
       %{args: [thread, project, branch]} = context do
    World.named_thread(context, thread, project, %{"branch" => branch})
  end

  step ~r/^pull request "(?<pr>[^"]+)" (?:is|was) linked to "(?<thread>[^"]+)"(?: by the user)?$/,
       %{args: [pr, thread]} = context do
    context |> link(thread, pr, "manual") |> ok!()
  end

  step "pull request {string} is linked to {string} as a layer of a native stack",
       %{args: [pr, thread]} = context do
    stack_layer(context, thread, pr)
  end

  step "pull request {string} was unlinked from the stack of {string}",
       %{args: [pr, thread]} = context do
    context
    |> stack_layer(thread, pr)
    |> command(thread, "thread.pull-request.unlink", key(pr))
    |> ok!()
  end

  step ~r/^pull request "(?<pr>[^"]+)" was linked to "(?<thread>[^"]+)" as one the thread created(?<unlinked> and then unlinked)?$/,
       %{args: [pr, thread | unlinked]} = context do
    context = context |> link(thread, pr, "created") |> ok!()

    if List.first(unlinked) in [nil, ""],
      do: context,
      else: context |> command(thread, "thread.pull-request.unlink", key(pr)) |> ok!()
  end

  step ~r/^pull request "(?<pr>[^"]+)" is (?:the thread's legacy linked pull request|linked to "(?<thread>[^"]+)" through metadata)$/,
       %{args: args} = context do
    [pr | rest] = args
    thread = List.first(rest) || context.thread

    context
    |> command(thread, "thread.metadata.update", %{"linkedPullRequest" => legacy(context, pr)})
    |> ok!()
  end

  step "the MC discovered pull request {string} for the branch of {string}",
       %{args: [pr, thread]} = context do
    context |> discover(thread, pr) |> ok!()
  end

  step "{string} has no visible linked pull requests", %{args: [thread]} = context do
    assert PullRequests.visible(links(context, thread)) == []
    assert World.thread(context, thread)["branchPullRequest"] != nil
    context
  end

  step "the MC started discovering the pull request for {string}",
       %{args: [thread]} = context do
    Map.put(context, :expected, expected(context, thread))
  end

  step "the thread's branch changed before discovery finished", context do
    context |> command(context.thread, "thread.metadata.update", %{"branch" => "other"}) |> ok!()
  end

  step "the thread's worktree changed before discovery finished", context do
    worktree = HalC2.Test.Mc.tmp_dir(context.mc, "worktree")

    context
    |> command(context.thread, "thread.metadata.update", %{"worktreePath" => worktree})
    |> ok!()
  end

  step "the project's workspace root changed before discovery finished", context do
    project = World.project(context)
    root = HalC2.Test.Mc.tmp_dir(context.mc, "moved")

    {:ok, _} =
      HalC2.Projects.mutate(%{
        "type" => "project.update",
        "projectId" => project.id,
        "workspaceRoot" => root
      })

    World.await_row(project.id, &(&1["workspaceRoot"] == root))
    context
  end

  step "the thread's linked pull request changed before discovery finished", context do
    context
    |> command(context.thread, "thread.metadata.update", %{
      "linkedPullRequest" => legacy(context, "acme/app#20")
    })
    |> ok!()
  end

  # --- acting -----------------------------------------------------------------------

  step "a client links pull request {int} of {string} on {string} to {string}",
       %{args: [number, repository, host, thread]} = context do
    link(context, thread, "#{repository}##{number}", "manual", host)
  end

  step "a client links pull request {string} to {string} again",
       %{args: [pr, thread]} = context do
    link(context, thread, pr, "manual")
  end

  step ~r/^(?<who>the user|an agent) links pull request "(?<pr>[^"]+)" to "(?<thread>[^"]+)"$/,
       %{args: [who, pr, thread]} = context do
    context
    |> link(thread, pr, if(who == "the user", do: "manual", else: "agent"))
    |> ok!()
  end

  step "a client unlinks pull request {string} from {string}", %{args: [pr, thread]} = context do
    command(context, thread, "thread.pull-request.unlink", key(pr))
  end

  step "a client updates the metadata of {string} with linked pull request {string}",
       %{args: [thread, pr]} = context do
    context
    |> command(thread, "thread.metadata.update", %{"linkedPullRequest" => legacy(context, pr)})
    |> ok!()
  end

  step "the MC syncs the host state of {string} as merged", %{args: [pr]} = context do
    snapshot = %{"state" => "merged", "title" => "PR", "syncedAt" => World.iso_from_now(0)}

    context
    |> command(context.thread, "thread.pull-request-link.sync", sync(pr, snapshot))
    |> ok!()
  end

  step "the MC syncs the host state of {string} for {string}",
       %{args: [pr, thread]} = context do
    snapshot = %{"state" => "open", "title" => "PR", "syncedAt" => World.iso_from_now(0)}
    command(context, thread, "thread.pull-request-link.sync", sync(pr, snapshot))
  end

  step "the MC discovers pull request {string} for the branch of {string}",
       %{args: [pr, thread]} = context do
    context |> discover(thread, pr) |> ok!()
  end

  step "the discovery result is applied", context do
    discover(context, context.thread, "acme/app#7", context.expected)
  end

  step "the MC applies a discovered pull request for {string}", %{args: [thread]} = context do
    discover(context, thread, "acme/app#7")
  end

  # --- refreshing host state ----------------------------------------------------------

  # The threads with an active pull request are the ones whose links the MC asks the
  # host about when it refreshes (`HalC2.PullRequests.Sync`). The project is a GitHub
  # checkout and `gh` is a fake that says every pull request it is asked about is open,
  # so a thread counts as active exactly when `gh` is asked about its pull request.
  # Beside the settled thread, "still-open" links an open pull request and stays active.
  step "{string} links pull request {string} and settled after it merged",
       %{args: [thread, pr]} = context do
    merged = %{
      "state" => "merged",
      "title" => "PR",
      "mergedAt" => World.iso_from_now(-60_000),
      "syncedAt" => World.iso_from_now(0)
    }

    World.github_remote(context, World.project(context, "demo").root, "acme/app")

    context =
      context
      |> World.cli_rules([
        %{"args" => ["stacks?pull_request="], "stdout" => []},
        %{
          "args" => ["api graphql"],
          "stdin" => ["PullRequestSummaries"],
          "stdout" => %{"data" => Map.new(0..3, &{"s#{&1}", %{"pullRequest" => open_summary()}})}
        }
      ])
      |> link(thread, pr, "manual")
      |> ok!()
      |> command(thread, "thread.pull-request-link.sync", sync(pr, merged))
      |> ok!()
      |> command(thread, "thread.settle", %{})
      |> ok!()

    World.await_row(World.thread_id(context, thread), fn row ->
      row["settledOverride"] == "settled" and
        match?([%{"snapshot" => %{"state" => "merged"}}], row["pullRequests"])
    end)

    # The sync starts knowing the settled thread; the open one is linked under its eyes
    # and read at once.
    HalC2.Test.Mc.ensure({HalC2.PullRequests.Sync, interval: nil})

    context =
      context
      |> World.create_thread("still-open", "demo", %{"branch" => "feature/y"})
      |> link("still-open", "acme/app#13", "manual")
      |> ok!()

    World.await_row(World.thread_id(context, "still-open"), fn row ->
      match?([%{"snapshot" => %{"state" => "open"}}], row["pullRequests"])
    end)

    Map.put(context, :thread, thread)
  end

  step "the MC refreshes pull request state", context do
    before = length(summary_reads(context))
    :ok = HalC2.PullRequests.Sync.sweep()
    Map.put(context, :refresh_reads, Enum.drop(summary_reads(context), before))
  end

  step "{string} is not listed among the threads with an active pull request",
       %{args: [thread]} = context do
    [%{"number" => settled}] = links(context, thread)
    [%{"number" => open}] = links(context, "still-open")

    # The refresh asked the host about the open pull request, and not about this one,
    # neither now nor at any time since it settled.
    assert [_ | _] = context.refresh_reads
    assert Enum.any?(context.refresh_reads, &(&1 =~ "pullRequest(number: #{open})"))
    refute Enum.any?(summary_reads(context), &(&1 =~ "pullRequest(number: #{settled})"))

    assert %{"settledOverride" => "settled"} = World.thread(context, thread)
    assert [%{"snapshot" => %{"state" => "merged"}}] = links(context, thread)
    context
  end

  # --- outcomes ---------------------------------------------------------------------

  step ~r/^thread "(?<thread>[^"]+)" (?:lists pull request|lists|shows) "(?<pr>[^"]+)"(?: again)?$/,
       %{args: [thread, pr]} = context do
    assert pr in visible(context, thread)
    context
  end

  step "thread {string} lists pull request {string} once", %{args: [thread, pr]} = context do
    assert Enum.count(links(context, thread), &(PullRequests.key(&1) == full_key(pr))) == 1
    context
  end

  step "thread {string} lists pull requests {string} and {string}",
       %{args: [thread, a, b]} = context do
    assert visible(context, thread) == [a, b]
    context
  end

  step ~r/^thread "(?<thread>[^"]+)" (?:no longer lists|does not show) "(?<pr>[^"]+)"$/,
       %{args: [thread, pr]} = context do
    refute pr in visible(context, thread)
    context
  end

  step "the thread's activity time moves to the link time", context do
    assert {:ok, _} = context.reply
    [link] = links(context, context.thread)
    assert World.thread(context, context.thread)["updatedAt"] == link["linkedAt"]
    assert link["linkedAt"] > context.before_updated
    context
  end

  step "no event is recorded", context do
    assert {:ok, _} = context.reply
    assert World.state(context, context.thread).seq == context.before_seq
    context
  end

  step "a later stack sync does not link {string} again", %{args: [pr]} = context do
    # The sync names the layer again and offers it back as a stack link.
    context = stack_sync(context, context.thread, pr)
    context |> link(context.thread, pr, "stack") |> ok!()
    refute pr in visible(context, context.thread)

    assert Enum.find(links(context, context.thread), &(PullRequests.key(&1) == full_key(pr)))[
             "source"
           ] ==
             "stack-dismissed"

    context
  end

  # What the turn writer and discovery do when they find a pull request the thread made.
  step "the MC finding {string} for {string} again does not link it",
       %{args: [pr, thread]} = context do
    seq = World.state(context, thread).seq
    :ok = HalC2.PullRequests.Opened.link(World.thread_id(context, thread), [url(pr)])
    assert World.state(context, thread).seq == seq

    # The same link sent on a read from before the unlink.
    context
    |> link(thread, pr, "created", "github.com", %{"automatic" => true})
    |> ok!()

    assert World.state(context, thread).seq == seq
    refute pr in visible(context, thread)
    context
  end

  step "thread {string} has no legacy linked pull request", %{args: [thread]} = context do
    assert {:ok, _} = context.reply
    assert World.thread(context, thread)["linkedPullRequest"] == nil
    context
  end

  step "the link shows state merged", context do
    assert [%{"snapshot" => %{"state" => "merged"}}] = links(context, context.thread)
    context
  end

  step "the thread's activity time is unchanged", context do
    assert World.thread(context, context.thread)["updatedAt"] == context.before_updated
    context
  end

  step ~r/^thread "(?<thread>[^"]+)" (?:still )?records "(?<pr>[^"]+)" as its branch pull request$/,
       %{args: [thread, pr]} = context do
    {repository, number} = parse(pr)

    World.await_row(
      World.thread_id(context, thread),
      &match?(%{"repository" => ^repository, "number" => ^number}, &1["branchPullRequest"]),
      5_000
    )

    assert %{"repository" => ^repository, "number" => ^number} =
             World.thread(context, thread)["branchPullRequest"]

    context
  end

  step ~r/^thread "(?<thread>[^"]+)" records no branch pull request(?: from that look-up)?$/,
       %{args: [thread]} = context do
    assert World.thread(context, thread)["branchPullRequest"] == nil
    context
  end

  # --- branch discovery (`HalC2.PullRequests.Discovery`) -----------------------------
  #
  # The project is a GitHub checkout of "acme/app" and `gh` is a fake. A look-up is a
  # `pr list --head <branch>` call in the fake's log, and a sweep is
  # `Discovery.sweep/0` (the service started without its timer), after the sidebar
  # rows the service reads have been flushed.

  step "{string} is created", %{args: [thread]} = context do
    context = discoverable(context)
    watched = "#{thread}-created"

    context
    |> World.named_thread(watched, "demo", %{"branch" => "feature/x"})
    |> Map.merge(%{watched: watched, thread: thread})
    |> flush()
  end

  # `"{thread}" is settled|unarchived` is the MCP thread-tools outcome step,
  # which delegates here for this file: "unarchived" is the discovery trigger
  # (archived first, discovery watching, then unarchived) and "settled"
  # arranges the thread the sync cadence then observes.
  def arrange_state(context, thread, "unarchived") do
    context = context |> command(thread, "thread.archive", %{}) |> ok!()
    World.await_row(World.thread_id(context, thread), &(&1["archivedAt"] != nil))

    context
    |> discoverable()
    |> command(thread, "thread.unarchive", %{})
    |> ok!()
    |> flush()
  end

  def arrange_state(context, thread, "settled") do
    context = context |> command(thread, "thread.settle", %{}) |> ok!()
    World.await_row(World.thread_id(context, thread), &(&1["settledOverride"] == "settled"))
    context
  end

  step "the branch or worktree of {string} is changed", %{args: [thread]} = context do
    context
    |> discoverable()
    |> command(thread, "thread.metadata.update", %{"branch" => "feature/y"})
    |> ok!()
    |> flush()
  end

  # "the user un-settles {string}" is the shared threads step, which
  # delegates here for this file: the thread is settled and discovery is
  # watching before the un-settle lands.
  def un_settle_trigger(context, thread) do
    context = context |> command(thread, "thread.settle", %{}) |> ok!()
    World.await_row(World.thread_id(context, thread), &(&1["settledOverride"] == "settled"))

    context
    |> discoverable()
    |> command(thread, "thread.unsettle", %{})
    |> ok!()
    |> flush()
  end

  step "a turn of {string} ends", %{args: [thread]} = context do
    context |> discoverable() |> World.add_run(thread, "completed")
  end

  # A checkpoint is captured in the same commit that ends its run
  # (`HalC2.Orchestration.TurnWriter`), so a completed run carrying one is
  # what a capture looks like to the row discovery watches.
  step "a checkpoint of {string} is captured", %{args: [thread]} = context do
    at = World.iso_from_now(0)

    context
    |> discoverable()
    |> World.add_run(thread, "completed", nil, %{"checkpointId" => "cp-1"})
    |> World.put_entity(thread, "checkpoint", "cp-1", %{
      "s" => %{
        "id" => "cp-1",
        "threadId" => World.thread_id(context, thread),
        "status" => "ready",
        "createdAt" => at,
        "updatedAt" => at
      }
    })
  end

  # What "a minute passes" means here (the step itself lives in the auto-settle
  # steps and delegates for this file): discovery starts and its minute tick lands.
  def minute_passes(context) do
    context = github_checkout(context)
    pid = HalC2.Test.Mc.ensure({HalC2.PullRequests.Discovery, interval: 60_000})
    context = Map.put(context, :branch_before, branch_calls(context, nil))
    send(pid, :tick)
    context
  end

  step "the MC looks for the pull request of the branch of {string}",
       %{args: [thread]} = context do
    watched = context[:watched] || thread
    branch = World.thread(context, watched)["branch"]

    World.await_row(
      World.thread_id(context, watched),
      &(&1["branchPullRequest"] != nil),
      5_000
    )

    assert branch_calls(context, branch) > (context[:branch_before] || 0),
           "gh was never asked about #{branch}: #{inspect(World.cli_calls(context))}"

    context
  end

  step "thread {string} exists in {string} on branch {string} in the same worktree as {string}",
       %{args: [thread, project, branch, other]} = context do
    context
    |> github_checkout()
    |> World.named_thread(thread, project, %{
      "branch" => branch,
      "worktreePath" => World.thread(context, other)["worktreePath"]
    })
    |> Map.put(:thread, other)
  end

  step "thread {string} is settled and records no branch pull request",
       %{args: [thread]} = context do
    context = context |> command(thread, "thread.settle", %{}) |> ok!()
    World.await_row(World.thread_id(context, thread), &(&1["settledOverride"] == "settled"))
    assert World.thread(context, thread)["branchPullRequest"] == nil
    context
  end

  step "pull request {string} exists for {string}", %{args: [pr, branch]} = context do
    context =
      context
      |> github_checkout()
      |> branch_answer(branch, pr_entry(pr, "OPEN"))

    # Discovery belongs to this MC's boot set, with its timer (and so its
    # start-up backfill), as in `HalC2.Application`; "the MC starts" (the
    # shared restart step) starts it again.
    HalC2.Test.Mc.ensure({HalC2.PullRequests.Discovery, interval: 60_000})
    context
  end

  step "the MC starts and five look-ups for {string} have failed",
       %{args: [_thread]} = context do
    # No `pr list` rule answers, so every look-up fails.
    context = if context[:cli], do: context, else: World.fake_cli(context)
    context = github_remote_only(context)
    pid = HalC2.Test.Mc.ensure({HalC2.PullRequests.Discovery, interval: 60_000})
    for _ <- 1..4, do: :ok = HalC2.PullRequests.Discovery.sweep()
    Map.put(context, :discovery, pid)
  end

  step "the MC no longer looks for the branch pull request of {string} on its periodic sweep",
       %{args: [thread]} = context do
    refute Map.has_key?(
             :sys.get_state(context.discovery).backfill,
             World.thread_id(context, thread)
           )

    before = branch_calls(context, nil)
    :ok = HalC2.PullRequests.Discovery.sweep()
    assert branch_calls(context, nil) == before
    assert World.thread(context, thread)["branchPullRequest"] == nil
    context
  end

  step "the branch {string} has a pull request in a repository that is not the one of {string}",
       %{args: [branch, _project]} = context do
    context
    |> github_checkout()
    |> branch_answer(branch, pr_entry("acme/other#7", "OPEN"))
  end

  step "the folder of {string} has no remote the MC recognises",
       %{args: [project]} = context do
    root = World.project(context, project).root
    World.git!(root, ["remote", "add", "origin", "https://git.example.com/acme/app.git"])
    if context[:cli], do: context, else: World.fake_cli(context)
  end

  step "the host is not asked about {string}", %{args: [thing]} = context do
    assert asked_about(context, thing) == (context[:asked_before] || 0),
           "the host was asked about #{thing}"

    context
  end

  step "thread {string} is in a worktree that has been removed",
       %{args: [thread]} = context do
    worktree = HalC2.Test.Mc.tmp_dir(context.mc, "gone-worktree")

    context =
      context
      |> github_checkout()
      |> command(thread, "thread.metadata.update", %{"worktreePath" => worktree})
      |> ok!()

    File.rm_rf!(worktree)
    context
  end

  step "the pull request of {string} is looked up from the folder of {string}",
       %{args: [branch, project]} = context do
    calls =
      for call <- World.cli_calls(context, "pr list"), branch in call["args"], do: call

    assert [_ | _] = calls
    assert Enum.all?(calls, &(&1["cwd"] == World.project(context, project).root))
    context
  end

  step "thread {string} has no worktree of its own and records {string} as its branch pull request",
       %{args: [thread, pr]} = context do
    context
    |> github_checkout()
    |> discover(thread, pr)
    |> ok!()
  end

  step("{string} is merged", %{args: [pr]} = context, do: serve_state(context, pr, "MERGED"))
  step("{string} is closed", %{args: [pr]} = context, do: serve_state(context, pr, "CLOSED"))
  step("{string} is open", %{args: [pr]} = context, do: serve_state(context, pr, "OPEN"))

  step "thread {string} is in its own worktree and records the merged {string} as its branch pull request",
       %{args: [thread, pr]} = context do
    worktree = HalC2.Test.Mc.tmp_dir(context.mc, "own-worktree")

    context
    |> github_checkout()
    |> serve_state(pr, "MERGED")
    |> command(thread, "thread.metadata.update", %{"worktreePath" => worktree})
    |> ok!()
    |> discover(thread, pr)
    |> ok!()
  end

  step ~r/^thread "(?<thread>[^"]+)" has only the legacy single link, to the (?<state>merged|open) "(?<pr>[^"]+)"$/,
       %{args: [thread, state, pr]} = context do
    # An older payload: `linkedPullRequest` set, `pullRequests` explicitly empty.
    context
    |> github_checkout()
    |> serve_state(pr, if(state == "merged", do: "MERGED", else: "OPEN"))
    |> World.patch_thread(thread, %{
      "linkedPullRequest" => legacy(context, pr),
      "pullRequests" => []
    })
  end

  step "a new pull request {string} is open for {string}", %{args: [pr, branch]} = context do
    branch_answer(context, branch, pr_entry(pr, "OPEN"))
  end

  step ~r/^the linked pull request of "(?<thread>[^"]+)" is (?:still )?"(?<pr>[^"]+)"$/,
       %{args: [thread, pr]} = context do
    {_repository, number} = parse(pr)
    assert World.thread(context, thread)["linkedPullRequest"]["number"] == number
    context
  end

  step "thread {string} exists in {string} on branch {string} with pull request {string}",
       %{args: [thread, project, branch, pr]} = context do
    context
    |> github_checkout()
    |> branch_answer(branch, pr_entry(pr, "OPEN"))
    |> World.named_thread(thread, project, %{"branch" => branch})
    |> Map.put(:thread, "t1")
  end

  step "the look-up for {string} fails", %{args: [branch]} = context do
    World.cli_rules(context, %{
      "args" => ["pr list", "--head #{branch}"],
      "stderr" => "error connecting to api.github.com\n",
      "exit" => 1
    })
  end

  step "the MC looks for branch pull requests", context do
    HalC2.Test.Mc.ensure({HalC2.PullRequests.Discovery, interval: nil})
    context = Map.put(context, :asked_before, asked_about(context, "feature/x"))
    flush(context)
    :ok = HalC2.PullRequests.Discovery.sweep()
    context
  end

  step "the MC looks for branch pull requests and finds none for {string}",
       %{args: [branch]} = context do
    context = branch_answer(context, branch, [])
    HalC2.Test.Mc.ensure({HalC2.PullRequests.Discovery, interval: nil})
    flush(context)
    :ok = HalC2.PullRequests.Discovery.sweep()
    context
  end

  step "the host is asked about {string} once", %{args: [thing]} = context do
    assert asked_about(context, thing) == (context[:asked_before] || 0) + 1
    context
  end

  step "both {string} and {string} record the pull request it answered",
       %{args: [a, b]} = context do
    for thread <- [a, b] do
      assert %{"number" => 7} = World.thread(context, thread)["branchPullRequest"]
    end

    context
  end

  # A look-up that found #7 and has not recorded it: the answer is in discovery's
  # cache (a sweep found it) and the thread records none (cleared since), so the
  # next sweep must confirm the cached answer with the host before writing it,
  # and its write carries what it was decided from (`expected`).
  step "the MC found {string} for the branch of {string}", %{args: [pr, thread]} = context do
    context =
      context
      |> github_checkout()
      |> branch_answer("feature/x", pr_entry(pr, "OPEN"))

    HalC2.Test.Mc.ensure({HalC2.PullRequests.Discovery, interval: nil})
    flush(context)
    :ok = HalC2.PullRequests.Discovery.sweep()
    assert World.thread(context, thread)["branchPullRequest"] != nil

    context
    |> command(thread, "thread.pull-request.sync", %{
      "projectId" => World.thread(context, thread)["projectId"],
      "expected" => expected(context, thread),
      "branchPullRequest" => nil
    })
    |> ok!()
    |> flush()
    |> Map.put(:found_pr, pr)
  end

  step "the branch came to show another pull request before the result was recorded",
       context do
    branch_answer(context, "feature/x", pr_entry("acme/app#9", "OPEN"))
  end

  step "{string} changed state before the result was recorded", %{args: [pr]} = context do
    branch_answer(context, "feature/x", pr_entry(pr, "CLOSED"))
  end

  step "the folder of {string} was changed before the result was recorded",
       %{args: [project]} = context do
    context = in_flight_lookup(context)
    moved = HalC2.Test.Mc.tmp_dir(context.mc, "moved-folder")

    {:ok, _} =
      HalC2.Projects.mutate(%{
        "type" => "project.update",
        "projectId" => World.project(context, project).id,
        "workspaceRoot" => moved
      })

    World.await_row(World.project(context, project).id, &(&1["workspaceRoot"] == moved))
    context
  end

  step "project {string} was deleted before the result was recorded",
       %{args: [project]} = context do
    context = in_flight_lookup(context)
    id = World.project(context, project).id

    {:ok, _} =
      HalC2.Projects.mutate(%{"type" => "project.delete", "projectId" => id, "force" => true})

    await_until(fn ->
      case HalC2.Shell.row(node(), id) do
        nil -> true
        {_kind, row} -> row["deletedAt"] != nil
      end
    end)

    context
  end

  step "the look-up finishes", context do
    case context[:lookup_task] do
      nil ->
        flush(context)
        :ok = HalC2.PullRequests.Discovery.sweep()

      task ->
        :ok = Task.await(task, 15_000)
    end

    Map.delete(context, :lookup_task)
  end

  # Starts a sweep whose confirming host read is still answering (the fake
  # sleeps), so the scenario can change what the look-up was decided from
  # before its write lands.
  defp in_flight_lookup(context) do
    context =
      World.cli_rules(context, %{
        "args" => ["pr list", "--head feature/x"],
        "sleep" => 2,
        "stdout" => [pr_entry(context.found_pr, "OPEN")]
      })

    before = branch_calls(context, "feature/x")
    task = Task.async(fn -> HalC2.PullRequests.Discovery.sweep() end)
    await_cli(context, &(branch_calls(&1, "feature/x") > before))
    Map.put(context, :lookup_task, task)
  end

  # --- host sync (`HalC2.PullRequests.Sync`) -------------------------------------------
  #
  # The fake's batched summary read answers from `context.pr_nodes` (see
  # `serve/1` below), so "asked about #12" is a `PullRequestSummaries` call
  # naming it. Cadence time is the sweep's own last-read clock; a step that
  # runs a sweep "N minutes after the last read" moves that clock back
  # instead of waiting.

  step "pull request {string} is linked to {string} and to {string}",
       %{args: [pr, a, b]} = context do
    # Both links already carry a snapshot, so the sweep — not the
    # read-at-once for a newly linked pull request — is what reads them.
    snapshot = %{"state" => "open", "title" => "PR", "syncedAt" => World.iso_from_now(0)}

    context
    |> github_checkout()
    |> serve_state(pr, "CLOSED")
    |> World.named_thread(b, "demo", %{"branch" => "feature/y"})
    |> link(a, pr, "manual")
    |> ok!()
    |> command(a, "thread.pull-request-link.sync", sync(pr, snapshot))
    |> ok!()
    |> link(b, pr, "manual")
    |> ok!()
    |> command(b, "thread.pull-request-link.sync", sync(pr, snapshot))
    |> ok!()
    |> Map.put(:thread, a)
    |> Map.put(:answered, "closed")
    |> Map.put(:sync_pr, pr)
  end

  step "both {string} and {string} show the state it answered",
       %{args: [a, b]} = context do
    for thread <- [a, b] do
      assert [%{"snapshot" => %{"state" => state}}] = links(context, thread)
      assert state == context.answered
    end

    context
  end

  step "a client links pull request {string} to {string}", %{args: [pr, thread]} = context do
    context =
      context
      |> github_checkout()
      |> serve_state(pr, "OPEN")

    HalC2.Test.Mc.ensure({HalC2.PullRequests.Sync, interval: nil})
    flush(context)

    context
    |> link(thread, pr, "manual")
    |> ok!()
  end

  step "the MC reads {string} from the host and records its state on {string}",
       %{args: [_pr, thread]} = context do
    World.await_row(
      World.thread_id(context, thread),
      &match?([%{"snapshot" => %{"state" => "open"}}], &1["pullRequests"]),
      5_000
    )

    context
  end

  step ~r/^pull request "(?<pr>[^"]+)" is linked to "(?<thread>[^"]+)" and its last read said (?<state>open|closed)$/,
       %{args: [pr, thread, state]} = context do
    snapshot = %{"state" => state, "title" => "PR", "syncedAt" => World.iso_from_now(0)}

    context =
      context
      |> github_checkout()
      |> serve_state(pr, String.upcase(state))
      |> link(thread, pr, "manual")
      |> ok!()
      |> command(thread, "thread.pull-request-link.sync", sync(pr, snapshot))
      |> ok!()

    HalC2.Test.Mc.ensure({HalC2.PullRequests.Sync, interval: nil})
    flush(context)
    # The last read: a real sweep, which starts the cadence clock.
    :ok = HalC2.PullRequests.Sync.sweep()
    Map.put(context, :sync_pr, pr)
  end

  step "{string} is active", %{args: [thread]} = context do
    assert World.thread(context, thread)["settledOverride"] != "settled"
    assert World.thread(context, thread)["settledAt"] == nil
    context
  end

  step "{string} was reopened on the host", %{args: [pr]} = context do
    serve_state(context, pr, "OPEN")
  end

  step "thread {string} shows {string} as open", %{args: [thread, pr]} = context do
    {_, number} = parse(pr)
    link = Enum.find(links(context, thread), &(&1["number"] == number))
    assert link["snapshot"]["state"] == "open"
    context
  end

  step "pull request {string} is linked only to the archived thread {string}",
       %{args: [pr, thread]} = context do
    context
    |> github_checkout()
    |> serve_state(pr, "OPEN")
    |> link(thread, pr, "manual")
    |> ok!()
    |> command(thread, "thread.archive", %{})
    |> ok!()
    |> tap(fn context ->
      World.await_row(World.thread_id(context, thread), &(&1["archivedAt"] != nil))
    end)
  end

  step "pull request {string} is linked to {string} with the state {string}",
       %{args: [pr, thread, state]} = context do
    snapshot = %{"state" => state, "title" => "PR", "syncedAt" => World.iso_from_now(0)}

    context
    |> github_checkout()
    |> link(thread, pr, "manual")
    |> ok!()
    |> command(thread, "thread.pull-request-link.sync", sync(pr, snapshot))
    |> ok!()
    |> Map.put(:sync_pr, pr)
  end

  step "the sweep goes on to the other linked pull requests", context do
    # The host answers again (a working summaries rule replaces the failing
    # one) and the same sweep service reads the link it could not read before.
    context = serve_state(context, context.sync_pr, "OPEN")
    :ok = HalC2.PullRequests.Sync.sweep()
    assert summary_calls(context, context.sync_pr) > context.summary_before
    context
  end

  step "pull request {string} changed state on the host", %{args: [pr]} = context do
    snapshot = %{"state" => "open", "title" => "PR", "syncedAt" => World.iso_from_now(0)}

    context
    |> github_checkout()
    |> serve_state(pr, "CLOSED")
    |> link(context.thread, pr, "manual")
    |> ok!()
    |> command(context.thread, "thread.pull-request-link.sync", sync(pr, snapshot))
    |> ok!()
    |> Map.put(:sync_pr, pr)
  end

  step "the host answers the state of {string} but fails to report its stack",
       %{args: [_pr]} = context do
    World.cli_rules(context, %{
      "args" => ["stacks?pull_request="],
      "stderr" => "error connecting to api.github.com\n",
      "exit" => 1
    })
  end

  step "thread {string} has not recorded the new state", %{args: [thread]} = context do
    assert [%{"snapshot" => %{"state" => "open"}}] = links(context, thread)
    context
  end

  step "the host recovers and the sync sweep runs again", context do
    {_repository, number} = parse(context.sync_pr)

    context =
      World.cli_rules(context, %{
        "args" => ["stacks?pull_request="],
        "stdout" => [
          %{
            "id" => 42,
            "number" => 1,
            "html_url" => "https://github.com/acme/app/stacks/1",
            "base" => "main",
            "pull_requests" => [
              %{"number" => number, "head" => %{"ref" => "feature/x"}, "state" => "closed"},
              %{"number" => number + 1, "head" => %{"ref" => "feature/y"}, "state" => "open"}
            ]
          }
        ]
      })

    flush(context)
    :ok = HalC2.PullRequests.Sync.sweep()
    context
  end

  step "thread {string} shows the new state and the layers of the stack",
       %{args: [thread]} = context do
    {_repository, number} = parse(context.sync_pr)
    by_number = Map.new(links(context, thread), &{&1["number"], &1})

    assert by_number[number]["snapshot"]["state"] == "closed"

    assert Enum.map(by_number[number]["stack"]["layers"], & &1["number"]) == [
             number,
             number + 1
           ]

    assert by_number[number + 1]["source"] == "stack"
    context
  end

  step "the MC is reading {string} from the host", %{args: [pr]} = context do
    snapshot = %{"state" => "closed", "title" => "PR", "syncedAt" => World.iso_from_now(0)}
    thread = context.thread

    context =
      context
      |> github_checkout()
      |> serve_state(pr, "CLOSED", %{"sleep" => 3})
      |> link(thread, pr, "manual")
      |> ok!()
      |> command(thread, "thread.pull-request-link.sync", sync(pr, snapshot))
      |> ok!()

    context = Map.put(context, :summary_before, summary_calls(context, pr))

    HalC2.Test.Mc.ensure({HalC2.PullRequests.Sync, interval: nil})
    flush(context)
    task = Task.async(fn -> HalC2.PullRequests.Sync.sweep() end)
    await_cli(context, &(summary_calls(&1, pr) > context.summary_before))
    Map.merge(context, %{read_task: task, sync_pr: pr})
  end

  step "a client asks to refresh {string}", %{args: [pr]} = context do
    {repository, number} = parse(pr)

    {:ok, _} =
      HalC2.PullRequests.invalidate(%{
        "reference" => %{
          "projectId" => World.project(context, "demo").id,
          "repository" => repository,
          "number" => number
        }
      })

    context
  end

  step "the read in flight finishes", context do
    :ok = Task.await(context.read_task, 15_000)
    Map.delete(context, :read_task)
  end

  step "the next sweep reads {string} again, even if its last read was a minute ago",
       %{args: [pr]} = context do
    # The refresh queued during the read starts a sweep of its own, although
    # the link's closed snapshot would not be due for another quarter hour.
    await_cli(context, &(summary_calls(&1, pr) >= context.summary_before + 2))
    :ok = HalC2.PullRequests.Sync.sweep()
    context
  end

  # "the sync sweep runs" is the shared source-control step, which
  # delegates here for this file.
  def sync_sweep_now(context), do: sync_sweep(context, 0)

  step("the sync sweep runs again", context, do: sync_sweep(context, 0))

  step("the sync sweep runs a minute after the last read", context,
    do: sync_sweep(context, 60_000)
  )

  step("the sync sweep runs 15 minutes after the last read", context,
    do: sync_sweep(context, 15 * 60_000)
  )

  step "the host is asked about {string}", %{args: [thing]} = context do
    assert asked_about(context, thing) > (context[:asked_before] || 0)
    context
  end

  # Runs one sweep, with the sweep's last-read clock moved back `age` ms so
  # cadence rows need not wait. Remembers how often the host had been asked
  # about the scenario's pull request and the thread's log position, for the
  # "asked" and "no event is recorded" steps.
  defp sync_sweep(context, age) do
    HalC2.Test.Mc.ensure({HalC2.PullRequests.Sync, interval: nil})

    if age > 0 do
      now = System.system_time(:millisecond)

      :sys.replace_state(HalC2.PullRequests.Sync, fn state ->
        %{
          state
          | last_synced: Map.new(state.last_synced, fn {key, _at} -> {key, now - age} end)
        }
      end)
    end

    context =
      context
      |> Map.put(:asked_before, context[:sync_pr] && asked_about(context, context.sync_pr))
      |> Map.put(:summary_before, context[:sync_pr] && summary_calls(context, context.sync_pr))
      |> Map.put(:before_seq, context[:thread] && World.state(context, context.thread).seq)
      |> Map.put(:reply, {:ok, nil})

    flush(context)
    :ok = HalC2.PullRequests.Sync.sweep()
    context
  end

  # --- which threads are linked (`pullRequests.linkedThreads`) ------------------------

  step "pull request {string} on {string} is linked to thread {string}",
       %{args: [pr, host, thread]} = context do
    context |> link(thread, pr, "manual", host) |> ok!()
  end

  step "pull request {string} on {string} is linked to the archived thread {string}",
       %{args: [pr, host, thread]} = context do
    context
    |> World.named_thread(thread, "demo", %{"branch" => "feature/y"})
    |> link(thread, pr, "manual", host)
    |> ok!()
    |> command(thread, "thread.archive", %{})
    |> ok!()
    |> Map.put(:thread, "t1")
    |> tap(fn context ->
      World.await_row(World.thread_id(context, thread), &(&1["archivedAt"] != nil))
    end)
  end

  step "thread {string} was deleted and still carries a link to {string}",
       %{args: [thread, pr]} = context do
    context
    |> World.named_thread(thread, "demo", %{"branch" => "feature/z"})
    |> link(thread, pr, "manual")
    |> ok!()
    |> command(thread, "thread.delete", %{})
    |> ok!()
    |> Map.put(:thread, "t1")
    |> tap(fn context ->
      World.await_row(World.thread_id(context, thread), &(&1["deletedAt"] != nil))
    end)
  end

  step "{string} and {string} are both linked to pull request {string}",
       %{args: [a, b, pr]} = context do
    context
    |> World.named_thread(b, "demo", %{"branch" => "feature/y"})
    |> link(a, pr, "manual")
    |> ok!()
    |> link(b, pr, "manual")
    |> ok!()
    |> Map.put(:thread, a)
  end

  step "{string} was updated more recently than {string}", %{args: [newer, older]} = context do
    before = World.row(context, older)["updatedAt"]

    context =
      context
      |> command(newer, "thread.metadata.update", %{"title" => "Renamed #{newer}"})
      |> ok!()

    World.await_row(World.thread_id(context, newer), &(&1["updatedAt"] > before))
    context
  end

  step "thread {string} is linked to a pull request numbered {int} in {string} on {string}",
       %{args: [thread, number, repository, host]} = context do
    route = if String.contains?(host, "forge"), do: "pulls", else: "pull"

    context
    |> World.named_thread(thread, "demo", %{"branch" => "feature/z"})
    |> command(thread, "thread.pull-request.link", %{
      "host" => host,
      "repository" => repository,
      "number" => number,
      "url" => "https://#{host}/#{repository}/#{route}/#{number}",
      "source" => "manual"
    })
    |> ok!()
    |> Map.put(:thread, "t1")
  end

  step "pull request {string} is a layer of the stack of {string}",
       %{args: [pr, thread]} = context do
    context |> stack_layer(thread, pr) |> Map.put(:dismissed_pr, pr)
  end

  step "the user dismissed it from {string}", %{args: [thread]} = context do
    context
    |> command(thread, "thread.pull-request.unlink", key(context.dismissed_pr))
    |> ok!()
  end

  step "thread {string} carries only the legacy single link to {string}",
       %{args: [thread, pr]} = context do
    # No `pullRequests` on the thread at all: the shell synthesizes the one
    # legacy link, which is what the listing must find.
    World.patch_thread(context, thread, %{"linkedPullRequest" => legacy(context, pr)})
  end

  step "the MC cannot read its thread records", context do
    World.patch_thread(context, context.thread, %{"pullRequests" => "unreadable"})
  end

  step "a client asks which threads are linked to {string} on {string}",
       %{args: [pr, host]} = context do
    ask_linked(context, pr, host)
  end

  step "a client asks which threads are linked to {string}", %{args: [pr]} = context do
    ask_linked(context, pr, "github.com")
  end

  step "a client asks which threads are linked to pull request {int} of {string} on {string}",
       %{args: [number, repository, host]} = context do
    ask_linked(context, "#{repository}##{number}", host)
  end

  step "{string} and {string} are listed", %{args: [a, b]} = context do
    assert listed_ids(context) |> Enum.sort() == Enum.sort([id_of(context, a), id_of(context, b)])
    context
  end

  # "{string} is listed" / "is not listed" and "{string} comes before
  # {string}" are shared steps over `context.listing`, which `ask_linked/3`
  # fills with the threads' scenario names, in the order returned.

  defp ask_linked(context, pr, host) do
    {repository, number} = parse(pr)
    flush(context)

    {reply, context} =
      World.call(context, "pullRequests.linkedThreads", %{
        "projectId" => World.project(context, "demo").id,
        "host" => host,
        "repository" => repository,
        "number" => number
      })

    names = Map.new(context[:threads] || %{}, fn {name, id} -> {id, name} end)

    listing =
      case reply do
        {:ok, %{"threads" => threads}} -> Enum.map(threads, &(names[&1["id"]] || &1["title"]))
        _ -> []
      end

    Map.merge(context, %{reply: reply, listing: listing})
  end

  defp listed_ids(context) do
    assert {:ok, %{"threads" => threads}} = context.reply
    Enum.map(threads, & &1["id"])
  end

  defp id_of(context, thread), do: World.thread_id(context, thread)

  # --- a reference tied to a checkout (`HalC2.PullRequests.sync_key/1`) ----------------

  step "the project's checkout is on GitHub", context do
    checkout_from(context, "git@github.com:acme/app.git")
  end

  step "the project's checkout is on Azure DevOps", context do
    checkout_from(context, "https://dev.azure.com/org/project/_git/web")
  end

  step "the project's checkout is the Azure DevOps repository {string} of {string}",
       %{args: [repository, org_project]} = context do
    checkout_from(context, "https://dev.azure.com/#{org_project}/_git/#{repository}")
  end

  step "the project's checkout was cloned from {string}", %{args: [remote]} = context do
    checkout_from(context, remote)
  end

  step "a client names pull request {int} of {string} without a host",
       %{args: [number, repository]} = context do
    name_pr(context, repository, number, nil)
  end

  step "a client names pull request {int} of {string} on {string}",
       %{args: [number, repository, host]} = context do
    name_pr(context, repository, number, host)
  end

  step "a client names pull request {int} of {string}",
       %{args: [number, repository]} = context do
    name_pr(context, repository, number, nil)
  end

  step "the pull request is identified as number {int} of {string} on {string}",
       %{args: [number, repository, host]} = context do
    assert context.identified ==
             %{"host" => host, "repository" => repository, "number" => number}

    context
  end

  step "the pull request is not identified", context do
    assert context.identified == nil
    context
  end

  defp checkout_from(context, remote) do
    root = World.project(context, "demo").root
    System.cmd("git", ["remote", "remove", "origin"], cd: root, stderr_to_stdout: true)
    World.git!(root, ["remote", "add", "origin", remote])
    context
  end

  defp name_pr(context, repository, number, host) do
    ref =
      %{
        "projectId" => World.project(context, "demo").id,
        "repository" => repository,
        "number" => number
      }
      |> then(&if host, do: Map.put(&1, "host", host), else: &1)

    Map.put(context, :identified, HalC2.PullRequests.sync_key(ref))
  end

  # --- helpers ----------------------------------------------------------------------

  defp parse(pr) do
    [repository, number] = String.split(pr, "#")
    {repository, String.to_integer(number)}
  end

  defp key(pr, host \\ "github.com") do
    {repository, number} = parse(pr)
    %{"host" => host, "repository" => repository, "number" => number}
  end

  defp url(pr, host \\ "github.com") do
    {repository, number} = parse(pr)
    "https://#{host}/#{repository}/pull/#{number}"
  end

  defp full_key(pr), do: PullRequests.key(key(pr))

  defp legacy(context, pr) do
    {repository, number} = parse(pr)

    %{
      "projectId" => World.project(context).id,
      "repository" => repository,
      "number" => number,
      "url" => url(pr)
    }
  end

  defp links(context, thread), do: PullRequests.of(World.thread(context, thread))

  # What GitHub says of an open pull request, as `gh api graphql` answers.
  defp open_summary do
    %{
      "title" => "PR",
      "url" => "https://github.com/acme/app/pull/13",
      "state" => "OPEN",
      "isDraft" => false,
      "headRefName" => "feature/y",
      "baseRefName" => "main",
      "reviewDecision" => "REVIEW_REQUIRED",
      "updatedAt" => "2026-09-02T00:00:00Z",
      "mergedAt" => nil,
      "author" => %{"login" => "octocat"}
    }
  end

  # The queries the MC sent `gh` for pull request summaries, oldest first.
  defp summary_reads(context) do
    for call <- World.cli_calls(context, "graphql"),
        call["stdin"] =~ "PullRequestSummaries",
        do: call["stdin"]
  end

  defp visible(context, thread) do
    for link <- PullRequests.visible(links(context, thread)),
        do: "#{link["repository"]}##{link["number"]}"
  end

  # Dispatches to the engine, remembering the log position and activity time before.
  defp command(context, thread, type, fields) do
    context = Map.put(context, :thread, thread)

    context
    |> Map.put(:before_seq, World.state(context, thread).seq)
    |> Map.put(:before_updated, World.thread(context, thread)["updatedAt"])
    |> World.command(
      Map.merge(%{"type" => type, "threadId" => World.thread_id(context, thread)}, fields)
    )
  end

  defp link(context, thread, pr, source, host \\ "github.com", fields \\ %{}) do
    command(
      context,
      thread,
      "thread.pull-request.link",
      key(pr, host)
      |> Map.merge(%{"url" => url(pr, host), "source" => source})
      |> Map.merge(fields)
    )
  end

  defp ok!(context) do
    assert {:ok, _} = context.reply, "command failed: #{inspect(context.reply)}"
    context
  end

  defp sync(pr, snapshot, stack \\ nil),
    do: Map.merge(key(pr), %{"snapshot" => snapshot, "stack" => stack})

  # The base pull request #12 heads a native stack whose other layer is `pr`.
  defp stack_sync(context, thread, pr) do
    {_, number} = parse(pr)

    stack = %{
      "kind" => "native",
      "id" => "s1",
      "layers" => [%{"number" => 12}, %{"number" => number}]
    }

    snapshot = %{"state" => "open", "title" => "PR", "syncedAt" => World.iso_from_now(0)}

    context
    |> command(thread, "thread.pull-request-link.sync", sync("acme/app#12", snapshot, stack))
    |> ok!()
  end

  defp stack_layer(context, thread, pr) do
    context
    |> link(thread, "acme/app#12", "manual")
    |> ok!()
    |> stack_sync(thread, pr)
    |> link(thread, pr, "stack")
    |> ok!()
  end

  # What `HalC2.PullRequests.Discovery` decides from: the thread and its project as seen.
  defp expected(context, thread) do
    row = World.thread(context, thread)
    {"project", project} = HalC2.Shell.row(node(), row["projectId"])

    %{
      "workspaceRoot" => project["workspaceRoot"],
      "branch" => row["branch"],
      "worktreePath" => row["worktreePath"],
      "linkedPullRequest" => row["linkedPullRequest"],
      "branchPullRequest" => row["branchPullRequest"]
    }
  end

  defp discover(context, thread, pr, expected \\ nil) do
    {repository, number} = parse(pr)
    project_id = World.thread(context, thread)["projectId"]

    command(context, thread, "thread.pull-request.sync", %{
      "projectId" => project_id,
      "expected" => expected || expected(context, thread),
      "branchPullRequest" => %{
        "projectId" => project_id,
        "repository" => repository,
        "number" => number,
        "url" => url(pr)
      }
    })
  end

  # --- the fake GitHub host -----------------------------------------------------------

  # The demo project as a GitHub checkout of "acme/app", `gh` a fake whose
  # branch look-ups answer #7 and whose stack reads answer none, until a
  # step answers more specifically (later rules win in `cli_rules/2`).
  defp github_checkout(context) do
    context = github_remote_only(context)

    if context[:gh_rules] do
      context
    else
      context
      |> World.cli_rules([
        %{"args" => ["stacks?pull_request="], "stdout" => []},
        %{"args" => ["pr list"], "stdout" => [pr_entry("acme/app#7", "OPEN")]}
      ])
      |> Map.put(:gh_rules, true)
    end
  end

  defp github_remote_only(context) do
    if context[:gh_remote] do
      context
    else
      World.github_remote(context, World.project(context, "demo").root, "acme/app")
      Map.put(context, :gh_remote, true)
    end
  end

  # Discovery running without its timer, with the branch look-ups so far counted.
  defp discoverable(context) do
    context = github_checkout(context)
    HalC2.Test.Mc.ensure({HalC2.PullRequests.Discovery, interval: nil})
    context |> flush() |> Map.put(:branch_before, branch_calls(context, nil))
  end

  defp branch_answer(context, branch, entries) do
    World.cli_rules(context, %{
      "args" => ["pr list", "--head #{branch}"],
      "stdout" => List.wrap(entries)
    })
  end

  defp pr_entry(pr, state) do
    {repository, number} = parse(pr)

    %{
      "number" => number,
      "url" => "https://github.com/#{repository}/pull/#{number}",
      "state" => state,
      "mergedAt" => if(state == "MERGED", do: "2026-09-01T00:00:00Z"),
      "closedAt" => if(state == "CLOSED", do: "2026-09-01T00:00:00Z")
    }
  end

  # The host's word on a pull request, in the fake's batched summary read.
  defp serve_state(context, pr, state, rule_extra \\ %{}) do
    {_repository, number} = parse(pr)

    node = %{
      "number" => number,
      "title" => "PR",
      "url" => url(pr),
      "state" => state,
      "isDraft" => false,
      "mergeable" => "MERGEABLE",
      "headRefName" => "feature/x",
      "baseRefName" => "main",
      "updatedAt" => "2026-09-01T00:00:00Z",
      "mergedAt" => if(state == "MERGED", do: "2026-09-01T00:00:00Z"),
      "closedAt" => if(state == "CLOSED", do: "2026-09-01T00:00:00Z"),
      "author" => %{"login" => "octocat"},
      "commits" => %{"nodes" => []},
      "comments" => %{"nodes" => []},
      "reviews" => %{"nodes" => []}
    }

    context
    |> Map.update(:pr_nodes, %{pr => node}, &Map.put(&1, pr, node))
    |> serve(rule_extra)
  end

  defp serve(context, rule_extra) do
    rule =
      Map.merge(
        %{
          "args" => ["api graphql"],
          "stdin" => ["PullRequestSummaries"],
          "summaries" => context.pr_nodes,
          "viewer" => "monalisa",
          "pr-links" => true
        },
        rule_extra
      )

    existing =
      context.cli.rules |> File.read!() |> JSON.decode!() |> Enum.reject(& &1["pr-links"])

    File.write!(context.cli.rules, JSON.encode!([rule | existing]))
    context
  end

  defp branch_calls(context, branch) do
    if context[:cli] do
      Enum.count(World.cli_calls(context, "pr list"), &(branch == nil or branch in &1["args"]))
    else
      0
    end
  end

  defp summary_calls(context, pr) do
    {_repository, number} = parse(pr)
    Enum.count(summary_reads(context), &(&1 =~ "pullRequest(number: #{number})"))
  end

  # How often the host has been asked about a branch ("feature/x") or a pull
  # request ("acme/app#12") so far.
  defp asked_about(context, thing) do
    if String.contains?(thing, "#"),
      do: summary_calls(context, thing),
      else: branch_calls(context, thing)
  end

  # The sidebar rows the sync and discovery services read, up to date
  # (a stream puts its row after a debounce; flushing it is the receipt).
  defp flush(context) do
    for {_title, id} <- context[:threads] || %{}, do: :ok = HalC2.Streams.flush_shell(id)
    :ok = GenServer.call(HalC2.Shell, :sync)
    context
  end

  # The fake `gh` writes its log from another OS process; there is no
  # message to wait on (`HalC2.Test.Mc.World.await_provider_log/4` waits the
  # same way).
  defp await_cli(context, fun), do: await_until(fn -> fun.(context) end)

  defp await_until(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_loop(fun, deadline)
  end

  defp await_loop(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline,
        do: flunk("what the step waits for never happened")

      receive do
      after
        20 -> await_loop(fun, deadline)
      end
    end
  end
end
