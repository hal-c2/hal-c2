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

  step "thread {string} records {string} as its branch pull request",
       %{args: [thread, pr]} = context do
    {repository, number} = parse(pr)

    assert %{"repository" => ^repository, "number" => ^number} =
             World.thread(context, thread)["branchPullRequest"]

    context
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

  defp link(context, thread, pr, source, host \\ "github.com") do
    command(
      context,
      thread,
      "thread.pull-request.link",
      Map.merge(key(pr, host), %{"url" => url(pr, host), "source" => source})
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
end
