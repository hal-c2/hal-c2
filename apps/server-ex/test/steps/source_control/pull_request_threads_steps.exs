defmodule HalC2.Steps.SourceControl.PullRequestThreads do
  @moduledoc """
  Steps for `features/source-control/pull-request-threads.feature`: opening a pull
  request in a thread (`git.resolvePullRequest`, `git.preparePullRequestThread`) and
  the links a thread keeps (`thread.pull-request.link`, `HalC2.PullRequests.Discovery`,
  `HalC2.PullRequests.Sync`, `pullRequests.linkedThreads`).

  Pull request 42 of "acme/shop" has a real head: a commit pushed to the fake
  GitHub's `refs/pull/42/head` (and to its branch, unless it comes from a fork).
  Links are made on the thread "Tax work" unless a step names another.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.SourceControl.Shared
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @repository "acme/shop"
  @url "https://github.com/acme/shop/pull/42"

  # --- resolving and preparing ---------------------------------------------------------

  step ~r/^the user asks to work on the pull request (?<reference>\S+)$/,
       %{args: [reference]} = context do
    context = answer_view(context)
    root = World.project(context, @repository).root

    {reply, context} =
      World.call(context, "git.resolvePullRequest", %{"cwd" => root, "reference" => reference})

    Map.put(context, :reply, reply)
  end

  step "pull request {int} of {string} is resolved with its title, branches and state",
       %{args: [number, repository]} = context do
    assert {:ok, %{"pullRequest" => pr}} = context.reply

    assert pr == %{
             "number" => number,
             "title" => "Charge tax at checkout",
             "url" => "https://github.com/#{repository}/pull/#{number}",
             "baseBranch" => "main",
             "headBranch" => "feature/tax",
             "state" => "open"
           }

    context
  end

  step "the user is told the pull request was not found", context do
    assert {:error, _, %{"detail" => detail}} = context.reply
    assert detail == "Pull request not found. Check the PR number or URL and try again."
    context
  end

  step "pull request {int} comes from the fork branch {string}",
       %{args: [42, branch]} = context do
    answer_view(context, %{"headRefName" => branch, "isCrossRepository" => true})
  end

  step "a worktree for pull request {int} exists with local commits", %{args: [42]} = context do
    context = context |> answer_view() |> prepare("worktree")
    assert {:ok, %{"worktreePath" => path, "isOnPullRequestHead" => true}} = context.reply
    World.commit!(path, %{"local.txt" => "mine\n"}, "Local work")
    Map.put(context, :existing_worktree, path)
  end

  step "the main checkout is on pull request {int}'s branch", %{args: [42]} = context do
    context = answer_view(context)
    World.git!(context.cwd, ~w(checkout -q feature/tax))
    context
  end

  step "{string} has a setup script for new worktrees", %{args: [repository]} = context do
    project = World.project(context, repository)

    {:ok, _} =
      HalC2.Projects.mutate(%{
        "type" => "project.update",
        "projectId" => project.id,
        "scripts" => [
          %{
            "id" => "setup",
            "name" => "Setup",
            "command" => "echo ran > setup-ran.txt",
            "icon" => "configure",
            "runOnWorktreeCreate" => true,
            "async" => false
          }
        ]
      })

    World.await_row(project.id, &match?([_], &1["scripts"]))
    context
  end

  # As the pull request dialog does: the pull request is prepared, then the thread is
  # made on the branch and worktree it was prepared in.
  step ~r/^the user starts a thread on pull request 42 in (?<mode>the local checkout|a new worktree)$/,
       %{args: [mode]} = context do
    mode = mode_of(mode)
    context = answer_view(context)

    context =
      if mode == "local",
        do: context |> discovery() |> branch_answer("feature/tax", 42, "OPEN"),
        else: context

    context = prepare(context, mode)

    case context.reply do
      {:ok, prepared} ->
        context
        |> World.create_thread("PR 42", @repository, %{
          "branch" => prepared["branch"],
          "worktreePath" => prepared["worktreePath"]
        })
        |> Map.put(:prepared, prepared)

      _refused ->
        context
    end
  end

  step "the project's checkout switches to the pull request's branch", context do
    assert %{"branch" => "feature/tax", "worktreePath" => nil, "isOnPullRequestHead" => true} =
             context.prepared

    assert World.git!(context.cwd, ~w(branch --show-current)) == "feature/tax"
    assert World.git!(context.cwd, ~w(rev-parse HEAD)) == context.pr_head
    context
  end

  step "the new thread is linked to pull request {int}", %{args: [number]} = context do
    :ok = HalC2.PullRequests.Discovery.sweep()
    row = World.await_row(World.thread_id(context, "PR 42"), &(&1["branchPullRequest"] != nil))
    assert %{"number" => ^number, "url" => @url} = row["branchPullRequest"]
    context
  end

  step "the pull request's head is fetched into a worktree of its own", context do
    %{"worktreePath" => path, "branch" => "feature/tax"} = context.prepared
    assert path != context.cwd and File.dir?(path)
    assert World.git!(path, ~w(rev-parse HEAD)) == context.pr_head
    assert World.git!(path, ~w(branch --show-current)) == "feature/tax"
    assert World.git!(path, ~w(rev-parse --abbrev-ref @{upstream})) == "origin/feature/tax"
    # The main checkout stays where it was.
    assert World.git!(context.cwd, ~w(branch --show-current)) == "main"
    context
  end

  step "the new thread works in that worktree", context do
    row = World.await_row(World.thread_id(context, "PR 42"), & &1)
    assert row["worktreePath"] == context.prepared["worktreePath"]
    assert row["branch"] == "feature/tax"
    context
  end

  step "the worktree is on the branch {string} with no upstream", %{args: [branch]} = context do
    assert %{"branch" => ^branch, "worktreePath" => path} = context.prepared
    assert World.git!(path, ~w(branch --show-current)) == branch
    assert World.git!(path, ~w(rev-parse HEAD)) == context.pr_head

    assert {_, status} =
             System.cmd("git", ~w(rev-parse --abbrev-ref @{upstream}),
               cd: path,
               stderr_to_stdout: true
             )

    assert status != 0
    context
  end

  step "the existing worktree is reused", context do
    assert %{"worktreePath" => path} = context.prepared
    assert path == context.existing_worktree
    assert World.git!(path, ~w(log -1 --format=%s)) == "Local work"
    context
  end

  step "the user is told the checkout is not on the pull request's head", context do
    assert context.prepared["isOnPullRequestHead"] == false
    context
  end

  step "the user is told to use the local checkout or switch the main checkout off that branch",
       context do
    assert World.failure(context) ==
             "This PR branch is already checked out in the main repo. Use Local, or switch the main repo off that branch before creating a worktree thread."

    context
  end

  step "the setup script does not run", context do
    assert %{"worktreePath" => path} = context.prepared
    assert File.dir?(path)
    refute File.exists?(Path.join(path, "setup-ran.txt"))
    refute File.exists?(Path.join(context.cwd, "setup-ran.txt"))
    context
  end

  # --- linking -------------------------------------------------------------------------

  step "the thread {string} has no linked pull request", %{args: [title]} = context do
    context = thread(context, title)
    row = World.await_row(World.thread_id(context, title), & &1)
    assert (row["pullRequests"] || []) == [] and row["branchPullRequest"] == nil
    context
  end

  step "the user links pull request {int} to {string}", %{args: [number, title]} = context do
    link(context, @repository, number, title)
  end

  step "{string} lists pull request {int} with its current state",
       %{args: [title, number]} = context do
    link = await_link(context, title, number, &(&1["snapshot"] != nil))
    assert %{"state" => "open", "title" => "Pull request 42"} = link["snapshot"]
    assert link["source"] == "manual"
    context
  end

  step "pull request {int} is linked to {string}", %{args: [number, title]} = context do
    context = link(context, @repository, number, title)
    await_link(context, title, number, &(&1["snapshot"] != nil))
    Map.merge(context, %{pr_thread: title, repository: @repository})
  end

  step "{string} no longer lists pull request {int}", %{args: [title, number]} = context do
    row = World.await_row(World.thread_id(context, title), & &1)
    refute Enum.any?(row["pullRequests"] || [], &(&1["number"] == number))
    context
  end

  step "the user links {string} pull request {int} and {string} pull request {int} to {string}",
       %{args: [repo_a, a, repo_b, b, title]} = context do
    context
    |> link(repo_a, a, title)
    |> link(repo_b, b, title)
    |> Map.put(:linked, [{repo_a, a}, {repo_b, b}])
  end

  step "{string} lists both pull requests", %{args: [title]} = context do
    wanted = context.linked

    row =
      World.await_row(World.thread_id(context, title), fn row ->
        Enum.all?(wanted, fn {repo, n} ->
          Enum.any?(row["pullRequests"] || [], &(&1["repository"] == repo and &1["number"] == n))
        end)
      end)

    assert length(row["pullRequests"]) == 2

    for link <- row["pullRequests"],
        do:
          assert(link["url"] == "https://github.com/#{link["repository"]}/pull/#{link["number"]}")

    context
  end

  step "the agent in {string} opens pull request {int} and links it with its tool",
       %{args: [title, number]} = context do
    Mc.ensure(HalC2.Mcp)
    context = thread(context, title)
    %{authorization: auth} = HalC2.Mcp.server(World.thread_id(context, title), "codex")

    body =
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "link_pull_request",
          "arguments" => %{"url" => "https://github.com/acme/shop/pull/#{number}"}
        }
      })

    assert {200, %{"result" => %{"structuredContent" => linked}}} = HalC2.Mcp.handle(auth, body)
    assert %{"number" => ^number, "alreadyLinked" => false} = linked
    Map.put(context, :expected_source, "agent")
  end

  step "{string} lists pull request {int}", %{args: [title, number]} = context do
    link = await_link(context, title, number, & &1)
    assert link["source"] == context.expected_source
    assert link["url"] == "https://github.com/acme/shop/pull/#{number}"
    context
  end

  step "the user creates a pull request from {string}", %{args: [title]} = context do
    context =
      context
      |> Shared.answering_writer()
      |> World.cli_rules([
        %{"args" => ["pr list"], "stdout" => []},
        %{"args" => ["pr create"], "stdout" => "https://github.com/acme/shop/pull/43\n"}
      ])

    World.git!(context.cwd, ~w(checkout -q -b feature/tax))
    World.commit!(context.cwd, %{"tax.txt" => "10%\n"}, "Charge tax")
    context = World.create_thread(context, title, @repository, %{"branch" => "feature/tax"})
    id = World.thread_id(context, title)
    {events, context} = World.git_action(context, context.cwd, "create_pr", %{"threadId" => id})
    last = List.last(events)
    assert last["kind"] == "action_finished", "the action failed: #{inspect(last)}"
    assert %{"status" => "created", "number" => 43} = last["result"]["pr"]
    Map.merge(context, %{expected_source: "created", created_pr: 43})
  end

  step "{string} lists the new pull request", %{args: [title]} = context do
    link = await_link(context, title, context.created_pr, & &1)
    assert link["source"] == "created"
    assert link["url"] == "https://github.com/acme/shop/pull/43"
    context
  end

  # --- discovery -----------------------------------------------------------------------

  step "{string} is on the branch {string} with no linked pull request",
       %{args: [title, branch]} = context do
    context = World.create_thread(context, title, @repository, %{"branch" => branch})
    row = World.await_row(World.thread_id(context, title), & &1)
    assert row["branchPullRequest"] == nil and (row["pullRequests"] || []) == []
    Map.put(context, :branch, branch)
  end

  step "someone opens a pull request for {string} on GitHub", %{args: [branch]} = context do
    branch_answer(context, branch, 42, "OPEN")
  end

  # The MC sweeps unsettled threads every minute (`Discovery`'s timer); the sweep is
  # run here rather than waited for.
  step "within a minute {string} shows that pull request as its branch's",
       %{args: [title]} = context do
    context = discovery(context)
    :ok = HalC2.PullRequests.Discovery.sweep()
    row = World.await_row(World.thread_id(context, title), &(&1["branchPullRequest"] != nil))

    assert %{"number" => 42, "url" => @url, "repository" => @repository} =
             row["branchPullRequest"]

    context
  end

  step "{string} shows pull request {int} which has merged", %{args: [title, number]} = context do
    context = World.create_thread(context, title, @repository, %{"branch" => "feature/tax"})
    id = World.thread_id(context, title)
    project = World.project(context, @repository)

    # What an earlier discovery wrote.
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.pull-request.sync",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => id,
        "projectId" => project.id,
        "expected" => %{
          "workspaceRoot" => project.root,
          "branch" => "feature/tax",
          "worktreePath" => nil,
          "linkedPullRequest" => nil,
          "branchPullRequest" => nil
        },
        "branchPullRequest" => %{
          "projectId" => project.id,
          "repository" => @repository,
          "number" => number,
          "url" => "https://github.com/acme/shop/pull/#{number}"
        }
      })

    World.await_row(id, &(&1["branchPullRequest"]["number"] == number))

    context
    |> summaries(%{"state" => "MERGED", "mergedAt" => "2026-09-20T00:00:00Z"})
    |> Map.put(:pr_thread, title)
  end

  step "{string} now has the open pull request {int}", %{args: [branch, number]} = context do
    branch_answer(context, branch, number, "OPEN")
  end

  step "the thread's pull requests are checked again", context do
    context = discovery(context)
    :ok = HalC2.PullRequests.Discovery.sweep()
    assert World.cli_calls(context, "--head feature/tax") != []
    context
  end

  step "{string} shows pull request {int}", %{args: [title, number]} = context do
    row =
      World.await_row(
        World.thread_id(context, title),
        &(&1["branchPullRequest"]["number"] == number)
      )

    assert row["branchPullRequest"]["url"] == "https://github.com/acme/shop/pull/#{number}"
    context
  end

  # --- sync ----------------------------------------------------------------------------

  step "a review is submitted on pull request {int} on GitHub", %{args: [42]} = context do
    summaries(context, %{
      "reviewDecision" => "APPROVED",
      "updatedAt" => "2026-09-03T00:00:00Z",
      "latestReviews" => %{
        "nodes" => [%{"state" => "APPROVED", "author" => %{"login" => "hubot"}}]
      }
    })
  end

  step "{string} shows the new review state after the next sync", %{args: [title]} = context do
    :ok = HalC2.PullRequests.Sync.sweep()
    link = await_link(context, title, 42, &(&1["snapshot"]["reviewDecision"] == "approved"))
    assert link["snapshot"]["updatedAt"] == "2026-09-03T00:00:00Z"
    context
  end

  step "pull request {int} is linked to {string} and has merged",
       %{args: [number, title]} = context do
    context =
      context
      |> summaries(%{"state" => "MERGED", "mergedAt" => "2026-09-20T00:00:00Z"})
      |> link(@repository, number, title)

    await_link(context, title, number, &(&1["snapshot"]["state"] == "merged"))
    context
  end

  step "the sync sweep runs", context do
    reads = summary_reads(context)
    :ok = HalC2.PullRequests.Sync.sweep()
    Map.put(context, :reads_before, reads)
  end

  step "pull request {int} is not read again", %{args: [42]} = context do
    assert context.reads_before >= 1
    assert summary_reads(context) == context.reads_before
    context
  end

  step "pull request {int} is linked to {string} and to the archived thread {string}",
       %{args: [number, title, archived]} = context do
    context = context |> link(@repository, number, title) |> link(@repository, number, archived)
    id = World.thread_id(context, archived)
    {{:ok, _}, context} = World.dispatch(context, %{"type" => "thread.archive", "threadId" => id})
    World.await_row(id, &(&1["archivedAt"] != nil))
    Map.put(context, :pr_number, number)
  end

  step "the user asks which threads are linked to pull request {int}",
       %{args: [number]} = context do
    {reply, context} =
      World.call(context, "pullRequests.linkedThreads", %{
        "projectId" => World.project(context, @repository).id,
        "repository" => @repository,
        "number" => number
      })

    Map.put(context, :reply, reply)
  end

  step "both {string} and {string} are listed", %{args: [a, b]} = context do
    assert {:ok, %{"threads" => threads}} = context.reply
    assert threads |> Enum.map(& &1["title"]) |> Enum.sort() == Enum.sort([a, b])
    archived = Enum.find(threads, &(&1["title"] == b))
    assert archived["archivedAt"] != nil
    assert Enum.find(threads, &(&1["title"] == a))["archivedAt"] == nil
    context
  end

  # --- helpers -------------------------------------------------------------------------

  defp mode_of("the local checkout"), do: "local"
  defp mode_of("a new worktree"), do: "worktree"

  # Pull request 42's head on the fake GitHub, and `gh pr view` answering for it (by
  # number and by URL) with `fields` over the defaults; `gh pr checkout` checks it out
  # as `gh` would. Once per scenario, unless `fields` change.
  defp answer_view(context, fields \\ %{}) do
    if context[:pr_view] && fields == %{} do
      context
    else
      pr =
        Map.merge(
          %{
            "number" => 42,
            "title" => "Charge tax at checkout",
            "url" => @url,
            "baseRefName" => "main",
            "headRefName" => "feature/tax",
            "state" => "OPEN",
            "isCrossRepository" => false
          },
          fields
        )

      context = push_head(context, pr)

      context
      |> World.cli_rules([
        %{"args" => ["pr view 42 "], "stdout" => pr},
        %{"args" => ["pr view #{@url} "], "stdout" => pr},
        %{
          "args" => ["pr view 9999 "],
          "stderr" =>
            "GraphQL: Could not resolve to a PullRequest with the number of 9999. (repository.pullRequest)\n",
          "exit" => 1
        },
        %{
          "args" => ["pr checkout 42 --force"],
          "run" =>
            "git fetch -q origin +refs/pull/42/head:refs/heads/#{pr["headRefName"]} && " <>
              "git checkout -q #{pr["headRefName"]}"
        }
      ])
      |> Map.put(:pr_view, pr)
    end
  end

  # A commit only the pull request has, at `refs/pull/42/head` on the fake GitHub, and
  # on its branch there unless it comes from a fork. The checkout stays on main.
  defp push_head(%{pr_head: _} = context, _pr), do: context

  defp push_head(context, pr) do
    root = context.cwd
    World.git!(root, ~w(checkout -q -b pr-head-source))
    head = World.commit!(root, %{"tax.txt" => "tax\n"}, "Charge tax")
    World.git!(root, ~w(push -q origin HEAD:refs/pull/42/head))

    unless pr["isCrossRepository"],
      do: World.git!(root, ["push", "-q", "origin", "HEAD:refs/heads/#{pr["headRefName"]}"])

    World.git!(root, ~w(checkout -q main))
    World.git!(root, ~w(branch -q -D pr-head-source))
    if not pr["isCrossRepository"], do: World.git!(root, ["fetch", "-q", "origin"])
    Map.put(context, :pr_head, head)
  end

  defp prepare(context, mode) do
    {reply, context} =
      World.call(context, "git.preparePullRequestThread", %{
        "cwd" => World.project(context, @repository).root,
        "reference" => "42",
        "mode" => mode
      })

    Map.put(context, :reply, reply)
  end

  defp discovery(context) do
    Mc.ensure({HalC2.PullRequests.Discovery, interval: nil})
    context
  end

  # `gh pr list --head <branch>`: the branch's latest pull request.
  defp branch_answer(context, branch, number, state) do
    World.cli_rules(context, %{
      "args" => ["pr list", "--head #{branch}"],
      "stdout" => [
        %{
          "number" => number,
          "url" => "https://github.com/acme/shop/pull/#{number}",
          "state" => state,
          "mergedAt" => nil,
          "closedAt" => nil
        }
      ]
    })
  end

  defp thread(context, title) do
    if (context[:threads] || %{})[title],
      do: context,
      else: World.create_thread(context, title, @repository)
  end

  # A manual link, as the link dialog makes it, synced by `HalC2.PullRequests.Sync`.
  defp link(context, repository, number, title) do
    context = context |> thread(title) |> sync()
    id = World.thread_id(context, title)

    {{:ok, _}, context} =
      World.dispatch(context, %{
        "type" => "thread.pull-request.link",
        "threadId" => id,
        "host" => "github.com",
        "repository" => repository,
        "number" => number,
        "url" => "https://github.com/#{repository}/pull/#{number}",
        "source" => "manual"
      })

    World.await_row(id, fn row ->
      Enum.any?(
        row["pullRequests"] || [],
        &(&1["repository"] == repository and &1["number"] == number)
      )
    end)

    context
  end

  defp sync(context) do
    Mc.ensure({HalC2.PullRequests.Sync, interval: nil})
    context = World.cli_rules(context, %{"args" => ["stacks?pull_request="], "stdout" => []})
    if context[:summaries], do: context, else: summaries(context, %{})
  end

  # GitHub's summary of every pull request asked about, as `fields` over an open one.
  defp summaries(context, fields) do
    pr =
      Map.merge(
        %{
          "title" => "Pull request 42",
          "url" => @url,
          "state" => "OPEN",
          "isDraft" => false,
          "headRefName" => "feature/tax",
          "baseRefName" => "main",
          "reviewDecision" => "REVIEW_REQUIRED",
          "updatedAt" => "2026-09-02T00:00:00Z",
          "mergedAt" => nil,
          "author" => %{"login" => "octocat"}
        },
        fields
      )

    context
    |> World.cli_rules(%{
      "args" => ["api graphql"],
      "stdin" => ["PullRequestSummaries"],
      "stdout" => %{"data" => Map.new(0..3, &{"s#{&1}", %{"pullRequest" => pr}})}
    })
    |> Map.put(:summaries, pr)
  end

  defp summary_reads(context),
    do:
      context
      |> World.cli_calls("graphql")
      |> Enum.count(&(&1["stdin"] =~ "PullRequestSummaries"))

  defp await_link(context, title, number, fun) do
    row =
      World.await_row(World.thread_id(context, title), fn row ->
        Enum.any?(row["pullRequests"] || [], &(&1["number"] == number and fun.(&1)))
      end)

    Enum.find(row["pullRequests"], &(&1["number"] == number and fun.(&1)))
  end
end
