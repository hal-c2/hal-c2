defmodule HalC2.Steps.Orchestration.PullRequestWakes do
  @moduledoc """
  Steps for `features/mc/orchestration/pull-request-wakes.feature`.

  The project is a GitHub checkout and `gh` is a fake whose batched summary read
  (`summaries` in `test/support/fake_gh.py`) answers from the pull requests the
  scenario keeps in `context.prs`, signed in as "monalisa". "The MC reads" is a sync
  sweep (`HalC2.PullRequests.Sync`) followed by a wake check of every thread
  (`HalC2.PullRequests.Wakes`). A wake is a message whose notification comes from a
  pull request; `context.heard` holds the ones a scenario has already counted.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Projection.PullRequests, as: Links
  alias HalC2.StreamState
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @busy ~w(preparing starting running waiting queued)

  # --- arranging --------------------------------------------------------------------

  step "an MC with a project {string} on GitHub {string}",
       %{args: [title, repository]} = context do
    context = World.create_project(context, title)
    World.github_remote(context, World.project(context, title).root, repository)
    Mc.ensure({HalC2.PullRequests.Sync, interval: nil})
    Mc.ensure(HalC2.PullRequests.Wakes)

    context
    |> Map.merge(%{prs: %{}, heard: MapSet.new(), clock: 0})
    |> World.cli_rules([%{"args" => ["stacks?pull_request="], "stdout" => []}])
    |> serve()
  end

  step ~r/^thread "(?<thread>[^"]+)" in "(?<project>[^"]+)" (?:also )?links pull request "(?<pr>[^"]+)", which the MC has read once$/,
       %{args: [thread, project, pr]} = context do
    context
    |> World.named_thread(thread, project)
    |> open(pr)
    |> link(thread, pr)
    |> read()
    |> tap(&assert(wakes(&1, thread) == []))
  end

  # A task's child as `delegate_task` records it, without a provider behind it: the
  # task's result is disposed of, so its end wakes nobody and only hands links over.
  step ~r/^thread "(?<thread>[^"]+)" works on a task "(?<parent>[^"]+)" delegated and links pull request "(?<pr>[^"]+)", which the MC has read once$/,
       %{args: [thread, parent, pr]} = context do
    parent_id = World.thread_id(context, parent)
    at = World.iso_from_now(0)

    context = World.named_thread(context, thread, "demo")
    child_id = World.thread_id(context, thread)
    task = "task-#{thread}"

    context
    |> World.put_entity(thread, "thread", child_id, %{
      "s" =>
        Map.put(World.thread(context, thread), "lineage", %{
          "relationshipToParent" => "subagent",
          "parentThreadId" => parent_id,
          "rootThreadId" => parent_id
        })
    })
    |> World.put_entity(parent, "subagent", task, %{
      "s" => %{
        "id" => task,
        "threadId" => parent_id,
        "origin" => "app_owned",
        "childThreadId" => child_id,
        "title" => thread,
        "completionWake" => "always",
        "completionDelivery" => %{"state" => "disposed", "observedByRunId" => nil},
        "status" => "running",
        "startedAt" => at,
        "updatedAt" => at
      }
    })
    |> World.put_entity(parent, "node", task, %{
      "s" => %{
        "id" => task,
        "threadId" => parent_id,
        "kind" => "subagent",
        "status" => "running",
        "startedAt" => at,
        "completedAt" => nil
      }
    })
    |> then(&if(&1.prs[pr], do: &1, else: open(&1, pr)))
    |> link(thread, pr)
    |> read()
    |> tap(&assert(wakes(&1, thread) == []))
  end

  step ~r/^the task of "(?<thread>[^"]+)" (?:ends|ended)$/, %{args: [thread]} = context do
    {context, at} = tick(context)

    context =
      case context[:working] do
        nil ->
          World.add_run(context, thread, "completed", at)

        run ->
          World.put_entity(context, thread, "run", run, %{
            "s" => %{"status" => "completed", "completedAt" => at}
          })
      end

    :ok = HalC2.Orchestration.Delegation.settle_if_quiet(World.thread_id(context, thread))
    context |> Map.delete(:working) |> check()
  end

  step "pull request {string} has failing checks, a conflict and a comment from its owner",
       %{args: [pr]} = context do
    context
    |> open(pr)
    |> change(pr, "its checks start failing")
    |> change(pr, "it comes to conflict with its base branch")
    |> change(pr, "the owner comments")
  end

  step "the agent of {string} was woken because the checks of {string} failed",
       %{args: [thread, pr]} = context do
    context
    |> change(pr, "its checks start failing")
    |> read()
    |> woken_once(thread, pr)
  end

  step "the agent of {string} is working", %{args: [thread]} = context do
    context = World.add_run(context, thread, "running")
    [run] = context |> World.entities(thread, "run") |> Enum.filter(&(&1["status"] == "running"))
    Map.put(context, :working, run["id"])
  end

  step "the user keeps {string} active", %{args: [thread]} = context do
    context
    |> World.command(%{
      "type" => "thread.unsettle",
      "threadId" => World.thread_id(context, thread)
    })
    |> tap(&assert({:ok, _} = &1.reply))
    |> tap(fn _ ->
      World.await_row(World.thread_id(context, thread), &(&1["settledOverride"] == "active"))
    end)
  end

  step "the host cannot be reached", context do
    World.cli_rules(context, %{
      "args" => ["api graphql"],
      "stdin" => ["PullRequestSummaries"],
      "stderr" => "error connecting to api.github.com\n",
      "exit" => 1
    })
  end

  # --- acting -----------------------------------------------------------------------

  step ~r/^(?<change>.+) and the MC reads "(?<pr>[^"]+)" again$/,
       %{args: [description, pr]} = context do
    context |> change(pr, description) |> read()
  end

  step "the MC reads {string} again", context do
    read(context)
  end

  step "the MC restarts and reads {string} again", context do
    read(%{context | mc: Mc.restart(context.mc), clients: %{}})
  end

  step "a client links pull request {string} to {string} and the MC reads it",
       %{args: [pr, thread]} = context do
    context |> link(thread, pr) |> read()
  end

  # The turn ends after every change so far, so what the agent posted falls within it.
  step "the turn of {string} ends", %{args: [thread]} = context do
    {context, at} = tick(context)

    context
    |> World.put_entity(thread, "run", context.working, %{
      "s" => %{"status" => "completed", "completedAt" => at}
    })
    |> Map.delete(:working)
    |> check()
  end

  # --- outcomes ---------------------------------------------------------------------

  step "the agent of {string} is woken once about {string}", %{args: [thread, pr]} = context do
    woken_once(context, thread, pr)
  end

  step ~r/^the agent of "(?<thread>[^"]+)" is not woken(?: again)?$/,
       %{args: [thread]} = context do
    assert wakes(context, thread) == [],
           "woken: #{inspect(Enum.map(wakes(context, thread), & &1["text"]))}"

    context
  end

  step "the message says {string}", %{args: [text]} = context do
    # A wake's text, or (in the delegation scenarios) a tool refusal's message.
    case {context[:wake], context[:mcp_result]} do
      {%{"text" => wake}, _} -> assert wake =~ text, "the message was:\n#{wake}"
      {_, {:error, _code, message}} -> assert message == text
      _ -> assert context.wake["text"] =~ text
    end

    context
  end

  step "the timeline of {string} shows the notification {string}",
       %{args: [thread, summary]} = context do
    item = World.state(context, thread) |> StreamState.get("turn-item")
    item = item["turn-item:user:#{context.wake["id"]}"]
    assert %{"type" => "notification", "summary" => ^summary} = item
    assert item["source"]["kind"] == "pull_request"
    context
  end

  step "thread {string} settles", %{args: [thread]} = context do
    Mc.ensure({HalC2.Orchestration.Settlement, interval: nil})
    :ok = HalC2.Orchestration.Settlement.sweep()
    World.await_row(World.thread_id(context, thread), &(&1["settledAt"] != nil))
    context
  end

  step "thread {string} links {string}", %{args: [thread, pr]} = context do
    assert [_] = Enum.filter(Links.visible(links(context, thread)), &(name(&1) == pr))
    context
  end

  step "thread {string} no longer links {string}", %{args: [thread, pr]} = context do
    refute Enum.any?(Links.visible(links(context, thread)), &(name(&1) == pr))
    context
  end

  step "thread {string} still shows {string} as open", %{args: [thread, pr]} = context do
    link = Enum.find(links(context, thread), &(name(&1) == pr))
    assert link["snapshot"]["state"] == "open"
    context
  end

  # --- the host ---------------------------------------------------------------------

  # A pull request as GitHub first says it is: open, mergeable, no checks yet.
  defp open(context, pr) do
    {repository, number} = parse(pr)

    state = %{
      "number" => number,
      "title" => "PR #{number}",
      "url" => "https://github.com/#{repository}/pull/#{number}",
      "state" => "OPEN",
      "isDraft" => false,
      "mergeable" => "MERGEABLE",
      "headRefName" => "feature/#{number}",
      "baseRefName" => "main",
      "updatedAt" => World.iso_from_now(0),
      "mergedAt" => nil,
      "closedAt" => nil,
      "author" => %{"__typename" => "User", "login" => "monalisa"},
      "commits" => %{"nodes" => []},
      "comments" => %{"nodes" => []},
      "reviews" => %{"nodes" => []}
    }

    context |> put_in([:prs, pr], state) |> serve()
  end

  defp change(context, pr, description) do
    {context, at} = tick(context)
    pr_state = Map.put(context.prs[pr], "updatedAt", at)

    pr_state =
      case description do
        "its checks start failing" ->
          checks(pr_state, "FAILURE")

        "its checks pass" ->
          checks(pr_state, "SUCCESS")

        "its checks pass without having failed" ->
          checks(pr_state, "SUCCESS")

        "its checks start running" ->
          checks(pr_state, "PENDING")

        "its title changes" ->
          Map.put(pr_state, "title", "A better title")

        "it comes to conflict with its base branch" ->
          Map.put(pr_state, "mergeable", "CONFLICTING")

        "it is merged" ->
          Map.merge(pr_state, %{"state" => "MERGED", "mergedAt" => at})

        "it is closed without merging" ->
          Map.merge(pr_state, %{"state" => "CLOSED", "closedAt" => at})

        "the owner comments" ->
          comment(pr_state, at, "owner-1", "User", "OWNER")

        "a collaborator comments" ->
          comment(pr_state, at, "collaborator-1", "User", "COLLABORATOR")

        "the account the MC is signed in as comments" ->
          comment(pr_state, at, "monalisa", "User", "NONE")

        "the agent comments as the account the MC is signed in as" ->
          comment(pr_state, at, "monalisa", "User", "OWNER")

        "Copilot comments" ->
          review(pr_state, at, "COMMENTED", "copilot-pull-request-reviewer", "Bot", "NONE")

        "Codex comments" ->
          comment(pr_state, at, "chatgpt-codex-connector", "Bot", "NONE")

        "a contributor from outside the repository comments" ->
          comment(pr_state, at, "outsider", "User", "CONTRIBUTOR")

        "a member publishes a review that asks for changes" ->
          review(pr_state, at, "CHANGES_REQUESTED", "member-1", "User", "MEMBER")

        "a member starts a review without publishing it" ->
          review(pr_state, at, "PENDING", "member-1", "User", "MEMBER")
      end

    context |> put_in([:prs, pr], pr_state) |> serve()
  end

  # Each change happens a second after the one before it, all after the thread began.
  defp tick(context) do
    clock = context.clock + 1
    {%{context | clock: clock}, World.iso_from_now(clock * 1_000)}
  end

  defp checks(pr, state),
    do:
      put_in(pr, ["commits", "nodes"], [
        %{"commit" => %{"statusCheckRollup" => %{"state" => state}}}
      ])

  defp comment(pr, at, login, type, association) do
    node = %{
      "createdAt" => at,
      "authorAssociation" => association,
      "author" => %{"__typename" => type, "login" => login}
    }

    update_in(pr, ["comments", "nodes"], &(&1 ++ [node]))
  end

  defp review(pr, at, state, login, type, association) do
    node = %{
      "state" => state,
      "submittedAt" => if(state == "PENDING", do: nil, else: at),
      "authorAssociation" => association,
      "author" => %{"__typename" => type, "login" => login}
    }

    update_in(pr, ["reviews", "nodes"], &(&1 ++ [node]))
  end

  # The fake's summary rule, replaced each time a pull request changes.
  defp serve(context) do
    rule = %{
      "args" => ["api graphql"],
      "stdin" => ["PullRequestSummaries"],
      "summaries" => context.prs,
      "viewer" => "monalisa",
      "pr-wakes" => true
    }

    existing =
      context.cli.rules |> File.read!() |> JSON.decode!() |> Enum.reject(& &1["pr-wakes"])

    File.write!(context.cli.rules, JSON.encode!([rule | existing]))
    context
  end

  # --- the MC -----------------------------------------------------------------------

  defp link(context, thread, pr) do
    {repository, number} = parse(pr)

    context =
      World.command(context, %{
        "type" => "thread.pull-request.link",
        "threadId" => World.thread_id(context, thread),
        "host" => "github.com",
        "repository" => repository,
        "number" => number,
        "url" => "https://github.com/#{repository}/pull/#{number}",
        "source" => "manual"
      })

    assert {:ok, _} = context.reply
    context
  end

  # Every link is read, on the sidebar rows that hold what the scenario changed; the
  # second sweep takes the reads the first one asked for.
  defp read(context) do
    flush(context)

    for {pr, _} <- context.prs, {repository, number} = parse(pr) do
      HalC2.PullRequests.Sync.request(%{"repository" => repository, "number" => number})
    end

    :ok = HalC2.PullRequests.Sync.sweep()
    :ok = HalC2.PullRequests.Sync.sweep()
    check(context)
  end

  # Every thread is checked for news on rows that hold what the sync wrote, and every
  # turn a wake started has ended.
  defp check(context) do
    flush(context)
    :ok = HalC2.PullRequests.Wakes.sweep()

    for {title, _id} <- context.threads do
      World.await_thread(context, title, fn state ->
        not Enum.any?(
          StreamState.list(state, "run"),
          &(&1["status"] in @busy and &1["id"] != context[:working])
        )
      end)
    end

    context
  end

  # The stream's sidebar row is put after a debounce (`World.put_entity/5`).
  defp flush(context) do
    for {_title, id} <- context.threads, do: :ok = HalC2.Streams.flush_shell(id)
    :ok = GenServer.call(HalC2.Shell, :sync)
  end

  # --- outcomes ---------------------------------------------------------------------

  # The wakes from a pull request the scenario has not counted yet, oldest first.
  defp wakes(context, thread) do
    context
    |> World.entities(thread, "message")
    |> Enum.filter(&(get_in(&1, ["notification", "source", "kind"]) == "pull_request"))
    |> Enum.reject(&MapSet.member?(context.heard, &1["id"]))
    |> Enum.sort_by(& &1["createdAt"])
  end

  defp woken_once(context, thread, pr) do
    {repository, number} = parse(pr)

    key =
      HalC2.Projection.PullRequests.key(%{
        "host" => "github.com",
        "repository" => repository,
        "number" => number
      })

    assert [wake] = wakes(context, thread)
    assert key in wake["notification"]["source"]["pullRequests"]
    assert wake["createdBy"] == "system"
    context |> Map.update!(:heard, &MapSet.put(&1, wake["id"])) |> Map.put(:wake, wake)
  end

  defp links(context, thread),
    do: HalC2.Projection.PullRequests.of(World.thread(context, thread))

  defp name(link), do: "#{link["repository"]}##{link["number"]}"

  defp parse(pr) do
    [repository, number] = String.split(pr, "#")
    {repository, String.to_integer(number)}
  end
end
