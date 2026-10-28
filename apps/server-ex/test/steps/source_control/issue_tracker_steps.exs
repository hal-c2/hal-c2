defmodule HalC2.Steps.SourceControl.IssueTracker do
  @moduledoc """
  Steps for `features/source-control/issue-tracker.feature`, run against the real
  package in the repository's `plugins/issue-tracker`, copied into the MC's
  plugins directory as a user would install it.

  Issues come from the fake GitHub (`HalC2.Steps.Support.GitHubIssues`). Every
  agent's prompt ends in "answer from gate", so the fake Codex holds its turn
  open until the scenario writes the gate file (`end_turns/1`). The plugin's
  `tracker` topic is watched from the start; `await_topic/3` waits on it for
  what changes outside a call (a look finishing, a turn ending). Agents call
  the plugin's tools through the MC's MCP endpoint as a thread's agent would.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.Plugins.Fixtures
  alias HalC2.Steps.Support.GitHubIssues
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @id "issue-tracker"
  @package Path.expand("../../../../../plugins/issue-tracker", __DIR__)
  @gate " answer from gate"
  @manifest @package |> Path.join("plugin.json") |> File.read!() |> JSON.decode!()
  @defaults Map.new(@manifest["settings"], &{&1["key"], &1["default"]})
  @roles %{
    "prioritising" => "approval-required",
    "followingUp" => "approval-required",
    "summarising" => "approval-required",
    "implementing" => "auto-accept-edits"
  }

  # --- background ------------------------------------------------------------------------

  step "an MC running the plugin {string} over GitHub issues", %{args: [@id]} = context do
    dir = Path.join([context.mc.home, "plugins", @id])
    File.mkdir_p!(Path.dirname(dir))
    File.cp_r!(@package, dir)

    context =
      context
      |> World.agents()
      |> Fixtures.ensure()
      |> Fixtures.rescan()

    World.worktree_services()
    Mc.ensure(HalC2.Mcp)
    accepted = Enum.map(Fixtures.entry(@id)["permissions"], & &1["id"])

    {_, context} =
      World.call!(context, "plugins.enable", %{"id" => @id, "acceptPermissions" => accepted})

    assert %{"status" => "running"} = Fixtures.entry(@id)

    context
    |> Map.merge(%{tracker: true, watched: %{}})
    |> save(settings())
    |> watch()
  end

  step "{string} follows {string}", %{args: [@id, repository]} = context do
    save(context, %{"repositories" => [repository]})
  end

  step "{string} also follows {string}", %{args: [@id, repository]} = context do
    save(context, %{"repositories" => [context.repository, repository]})
  end

  step "{string} follows no repositories in particular", %{args: [@id]} = context do
    save(context, %{"repositories" => []})
  end

  step "{string} follows only issues labelled {string}", %{args: [@id, label]} = context do
    save(context, %{"issueLabel" => label})
  end

  # --- the queue -------------------------------------------------------------------------

  step "{string} has the open issues \#{int} {string} and \#{int} {string}",
       %{args: [repository, one, title_one, two, title_two]} = context do
    answers(context, repository, [
      issue(repository, one, %{"title" => title_one}),
      issue(repository, two, %{"title" => title_two})
    ])
  end

  step "{string} has the open issue \#{int} labelled {string} and \#{int} without it",
       %{args: [repository, number, label, _other]} = context do
    # As GitHub answers a listing asked for that label: only the labelled issue.
    answers(context, repository, [
      issue(repository, number, %{"labels" => %{"nodes" => [%{"name" => label}]}})
    ])
  end

  step "{string} has the open issue \#{int}, blocked by \#{int}, in the milestone {string}",
       %{args: [repository, number, blocker, milestone]} = context do
    answers(context, repository, [
      issue(repository, number, %{
        "body" => "We need limits.",
        "blockedBy" => [blocker],
        "milestone" => %{"number" => 1, "title" => milestone, "dueOn" => "2026-11-30T00:00:00Z"}
      })
    ])
  end

  step "\#{int} {string} by {string} says {string}",
       %{args: [number, title, author, body]} = context do
    answers(context, context.repository, [
      issue(context.repository, number, %{
        "title" => title,
        "author" => %{"login" => author},
        "body" => body
      })
    ])
  end

  step "the issues of {string} cannot be read", %{args: [repository]} = context do
    [_owner, name] = String.split(repository, "/")

    World.cli_rules(context, [
      %{
        "args" => ["api graphql"],
        "stdin" => ["issues(first: $first", ~s("name":"#{name}")],
        "exit" => 1,
        "stderr" => "gh: Could not resolve to a Repository.\n"
      }
    ])
  end

  step("the tracker looks at GitHub", context, do: look!(context))
  step("the tracker has looked at GitHub", context, do: look!(context))

  step "\#{int} and \#{int} are listed with their titles, authors and labels",
       %{args: [one, two]} = context do
    issues = tracker!(context)["issues"]
    assert Enum.map(issues, & &1["number"]) == [one, two]

    for issue <- issues do
      assert is_binary(issue["title"]) and issue["title"] != ""
      assert is_binary(issue["author"])
      assert is_list(issue["labels"])
      refute Map.has_key?(issue, "body")
    end

    context
  end

  step "GitHub is asked only for issues labelled {string}", %{args: [label]} = context do
    # Not GitHubIssues.graphql_calls/2: it pattern-matches every call's stdin
    # as a GraphQL body, and a call logged with none (seen on CI) crashes it.
    asked =
      for call <- World.cli_calls(context, "api graphql"),
          {:ok, %{"query" => query, "variables" => variables}} <- [
            JSON.decode(call["stdin"] || "")
          ],
          String.contains?(query, "issues(first: $first"),
          do: variables

    assert Enum.any?(asked, &(&1["labels"] == [label])), inspect(asked)
    context
  end

  step "\#{int} is listed and \#{int} is not", %{args: [listed, unlisted]} = context do
    numbers = Enum.map(tracker!(context)["issues"], & &1["number"])
    assert listed in numbers
    refute unlisted in numbers
    context
  end

  step "the tracker says {string} could not be read", %{args: [repository]} = context do
    assert tracker!(context)["problem"] =~ "#{repository} could not be read"
    context
  end

  step "the user asks the plugin to look now", context do
    context
    |> Map.put(:checked_at, tracker!(context)["checkedAt"])
    |> tap(fn context ->
      {reply, _} = plugin(context, "refresh", %{})
      assert {:ok, _} = reply
    end)
  end

  step "the tracker looks at GitHub again", context do
    previous = context.checked_at

    {_, context} =
      await_topic(context, fn value ->
        value["checkedAt"] not in [nil, previous] and value["checkedAt"]
      end)

    context
  end

  step "the user opens \#{int}", %{args: [number]} = context do
    {reply, context} =
      plugin(context, "issue", %{"repository" => context.repository, "number" => number})

    assert {:ok, opened} = reply
    Map.put(context, :opened, opened)
  end

  step "they get \#{int} with its body, milestone and the issue blocking it",
       %{args: [number]} = context do
    opened = context.opened
    assert opened["number"] == number
    assert opened["body"] == "We need limits."
    assert opened["milestone"] == "Beta"
    assert opened["blockedBy"] == [%{"repository" => context.repository, "number" => 5}]
    context
  end

  # --- starting triage -------------------------------------------------------------------

  step "the user asks for {string} to be prioritised", %{args: [repository]} = context do
    start_run(context, "prioritise", %{"repository" => repository})
  end

  step "the user asks for a follow-up on \#{int}", %{args: [number]} = context do
    start_run(context, "followUp", %{"repository" => context.repository, "number" => number})
  end

  step "the user asks for \#{int} to be summarised", %{args: [number]} = context do
    start_run(context, "summarise", %{"repository" => context.repository, "number" => number})
  end

  step("a prioritising run is running in a thread of the configured agent", context,
    do: assert_run(context, "prioritise")
  )

  step("a follow-up run is running in a thread of the configured agent", context,
    do: assert_run(context, "followUp")
  )

  step("a summarising run is running in a thread of the configured agent", context,
    do: assert_run(context, "summarise")
  )

  step "its thread is asked with the queue of {string} filled in",
       %{args: [repository]} = context do
    text = prompt(context.thread)
    assert text =~ "Prioritise the open issues of #{repository}"
    assert text =~ "- #{repository}#7 Add limits"
    assert text =~ "- #{repository}#9 Flaky test"
    assert text =~ "issue_tracker_report"
    context
  end

  step "its thread is asked with \#{int}, its body and its reporter filled in",
       %{args: [number]} = context do
    text = prompt(context.thread)
    assert text =~ "Issue ##{number} of #{context.repository}"
    assert text =~ "Limits would be nice."
    assert text =~ "dana"
    context
  end

  step "its thread is asked with \#{int} and the other open titles filled in",
       %{args: [number]} = context do
    text = prompt(context.thread)
    assert text =~ "Summarise issue ##{number} of #{context.repository}"
    assert text =~ "Rate limiting"
    context
  end

  step "that thread runs with {string}", %{args: [mode]} = context do
    assert thread(context.thread)["runtimeMode"] == mode
    context
  end

  step "the prioritising agent must ask before acting and the follow-up agent runs automatically",
       context do
    save(context, %{
      "prioritising" => agent("approval-required"),
      "followingUp" => agent("auto")
    })
  end

  # --- reports and proposals -------------------------------------------------------------

  step "a prioritising run on {string}", %{args: [repository]} = context do
    context =
      answers(context, repository, [
        issue(repository, 7, %{"title" => "Add limits"}),
        issue(repository, 9, %{"title" => "Flaky test"})
      ])

    context |> look!() |> start_run("prioritise", %{"repository" => repository})
  end

  step "a follow-up run on \#{int}", %{args: [number]} = context do
    context =
      answers(context, context.repository, [
        issue(context.repository, number, %{"title" => "Add limits", "body" => "Limits."})
      ])

    start_run(context, "followUp", %{"repository" => context.repository, "number" => number})
  end

  step "a summarising run on \#{int}", %{args: [number]} = context do
    context =
      answers(context, context.repository, [
        issue(context.repository, number, %{"title" => "Add limits", "body" => "Limits."}),
        issue(context.repository, 11, %{"title" => "Rate limiting"})
      ])

    context
    |> look!()
    |> start_run("summarise", %{"repository" => context.repository, "number" => number})
  end

  step "its agent reports \#{int} before \#{int}, \#{int} {string} and \#{int} {string}, each with a reason",
       %{args: [first, second, first_too, high, second_too, low]} = context do
    assert first == first_too and second == second_too

    report!(context, %{
      "summary" => "Ranked.",
      "items" => [
        %{
          "repository" => context.repository,
          "number" => first,
          "priority" => high,
          "reason" => "Blocks the release."
        },
        %{
          "repository" => context.repository,
          "number" => second,
          "priority" => low,
          "reason" => "Nothing waits on it."
        }
      ]
    })

    context
  end

  step "the run is proposed with that order and those priorities", context do
    run = run!(context)
    assert run["status"] == "proposed"

    assert Enum.map(run["report"]["items"], &{&1["number"], &1["priority"]}) == [
             {9, "high"},
             {7, "low"}
           ]

    context
  end

  step "a proposed prioritising run with \#{int} {string} and \#{int} {string}",
       %{args: [first, high, second, low]} = context do
    repository = context.repository

    context =
      answers(context, repository, [
        issue(repository, second, %{"title" => "Add limits", "labels" => %{"nodes" => []}}),
        issue(repository, first, %{
          "title" => "Flaky test",
          "labels" => %{"nodes" => [%{"name" => "priority: low"}, %{"name" => "backend"}]}
        })
      ])

    context = context |> look!() |> start_run("prioritise", %{"repository" => repository})

    report!(context, %{
      "summary" => "Ranked.",
      "items" => [
        %{
          "repository" => repository,
          "number" => first,
          "priority" => high,
          "reason" => "Blocks."
        },
        %{"repository" => repository, "number" => second, "priority" => low, "reason" => "Later."}
      ]
    })

    assert run!(context)["status"] == "proposed"
    context
  end

  step "a proposed follow-up run on \#{int} with the comment {string}",
       %{args: [number, comment]} = context do
    context =
      answers(context, context.repository, [
        issue(context.repository, number, %{"title" => "Add limits", "body" => "Limits."})
      ])

    context =
      start_run(context, "followUp", %{"repository" => context.repository, "number" => number})

    report!(context, %{
      "summary" => "The body never says which limits.",
      "items" => [
        %{"repository" => context.repository, "number" => number, "comment" => comment}
      ]
    })

    assert run!(context)["status"] == "proposed"
    context
  end

  step "a proposed summarising run on \#{int} with a comment and the label {string}",
       %{args: [number, label]} = context do
    context =
      answers(context, context.repository, [
        issue(context.repository, number, %{"title" => "Add limits", "body" => "Limits."})
      ])

    context =
      start_run(context, "summarise", %{"repository" => context.repository, "number" => number})

    report!(context, %{
      "summary" => "Summarised.",
      "items" => [
        %{
          "repository" => context.repository,
          "number" => number,
          "comment" => "The short of it: per-key limits.",
          "labels" => [label]
        }
      ]
    })

    assert run!(context)["status"] == "proposed"
    context
  end

  step "GitHub accepts labelling \#{int} again", %{args: [number]} = context do
    World.cli_rules(context, [
      %{
        "args" => ["--method PATCH", "repos/#{context.repository}/issues/#{number} "],
        "stdout" => %{"number" => number}
      }
    ])
  end

  step "the comment was posted exactly once", context do
    calls = GitHubIssues.rest_calls(context, "POST", "/comments")
    assert length(calls) == 1, inspect(calls)
    context
  end

  step "another thread in a new worktree of {string} starts on \#{int}",
       %{args: [project, _number]} = context do
    [second, first] = context.implement_threads
    first_path = await_worktree(first)
    second_path = await_worktree(second)
    assert second_path != first_path
    assert thread(second)["projectId"] == World.project(context, project).id
    context
  end

  step "its agent reports a comment for \#{int}", %{args: [number]} = context do
    result =
      tool(context, "issue_tracker_report", %{
        "summary" => "Asked.",
        "items" => [
          %{"repository" => context.repository, "number" => number, "comment" => "More detail?"}
        ]
      })

    Map.put(context, :tool_result, result)
  end

  step "the triage agent is told {string}", %{args: [message]} = context do
    assert context.tool_result["isError"] == true, inspect(context.tool_result)
    assert inspect(context.tool_result) =~ message
    context
  end

  step "the triage run is still running", context do
    assert run!(context)["status"] == "running"
    context
  end

  step "its agent reports that \#{int} is ready to work on, with no comment",
       %{args: [number]} = context do
    report!(context, %{
      "summary" => "##{number} is ready to work on.",
      "items" => [%{"repository" => context.repository, "number" => number}]
    })

    context
  end

  step "the run is done with that summary", context do
    run = run!(context)
    assert run["status"] == "done"
    assert run["summary"] =~ "ready to work on"
    context
  end

  step "its agent reports a summary of \#{int} naming \#{int} its duplicate",
       %{args: [number, duplicate]} = context do
    report!(context, %{
      "summary" => "Rate limits, asked for twice.",
      "items" => [
        %{
          "repository" => context.repository,
          "number" => number,
          "comment" => "The short of it: per-key limits.",
          "duplicates" => [duplicate]
        }
      ]
    })

    context
  end

  step "the run is proposed with the summary and \#{int} named",
       %{args: [duplicate]} = context do
    run = run!(context)
    assert run["status"] == "proposed"
    assert run["summary"] =~ "twice"
    assert hd(run["report"]["items"])["duplicates"] == [duplicate]
    context
  end

  step "its agent reads the queue with the {string} tool", %{args: [name]} = context do
    Map.put(context, :read, tool!(context, name, %{}))
  end

  step "it gets the open issues the plugin last saw, with their bodies left out", context do
    issues = context.read["issues"]
    assert Enum.map(issues, & &1["number"]) == [7, 9]
    assert Enum.all?(issues, &(not Map.has_key?(&1, "body")))
    context
  end

  step "GitHub refuses to label \#{int}", %{args: [number]} = context do
    World.cli_rules(context, [
      %{
        "args" => ["--method PATCH", "repos/#{context.repository}/issues/#{number} "],
        "exit" => 1,
        "stderr" => "gh: Validation Failed: label does not exist.\n"
      }
    ])
  end

  step "the user applies the proposal", context do
    {reply, context} = plugin(context, "apply", %{"runId" => context.run["id"]})
    Map.put(context, :reply, reply)
  end

  step "the user dismisses the proposal", context do
    {reply, context} = plugin(context, "discard", %{"runId" => context.run["id"]})
    assert {:ok, _} = reply
    context
  end

  step "GitHub is asked to label \#{int} {string} and {string}",
       %{args: [number, first, second]} = context do
    GitHubIssues.assert_patched(context, number, %{"labels" => [first, second]})
  end

  step "GitHub is asked to label \#{int} {string}", %{args: [number, label]} = context do
    GitHubIssues.assert_patched(context, number, %{"labels" => [label]})
  end

  # "GitHub is asked to comment {string} on #{int}" is the host-issues steps' step.

  step "GitHub is asked for nothing", context do
    for number <- [5, 7, 9, 11] do
      assert GitHubIssues.rest_calls(context, "PATCH", "/issues/#{number}") == []
      assert GitHubIssues.rest_calls(context, "POST", "/issues/#{number}/comments") == []
    end

    context
  end

  step "the triage run is applied", context do
    assert {:ok, _} = context.reply
    assert run!(context)["status"] == "applied"
    context
  end

  step "the run is discarded", context do
    assert run!(context)["status"] == "discarded"
    context
  end

  step "the run stays proposed, told \#{int} failed", %{args: [number]} = context do
    assert {:error, _, _} = context.reply
    assert inspect(context.reply) =~ "#{context.repository}##{number}"
    run = run!(context)
    assert run["status"] == "proposed"
    assert run["error"] =~ "#{context.repository}##{number}"
    context
  end

  step("its agent's turn ends and it never reported", context, do: end_turns(context))

  step "the run is failed, saying it finished without reporting", context do
    {run, context} = await_run(context, &(&1["status"] == "failed"))
    assert run["error"] =~ "finished without reporting"
    context
  end

  # --- implementing ----------------------------------------------------------------------

  step "the user asks to implement \#{int}", %{args: [number]} = context do
    implement!(context, context.repository, number)
  end

  step "the user asks to implement \#{int} of {string}",
       %{args: [number, repository]} = context do
    {reply, context} =
      plugin(context, "implement", %{"repository" => repository, "number" => number})

    Map.put(context, :reply, reply)
  end

  step "a thread in a new worktree of {string} starts on \#{int}",
       %{args: [project, _number]} = context do
    id = context.thread

    thread =
      World.await_stream(
        id,
        fn state ->
          thread = HalC2.StreamState.get(state, "thread")[id]
          thread && thread["worktreePath"] && thread
        end,
        15_000
      )

    assert thread["projectId"] == World.project(context, project).id
    assert thread["worktreePath"] != World.project(context, project).root
    context
  end

  step "it is asked to open a pull request that closes \#{int}", %{args: [number]} = context do
    assert prompt(context.thread) =~ "open a pull request that closes ##{number}"
    context
  end

  step "an implementing thread on \#{int}", %{args: [number]} = context do
    context = given_issue(context, number)
    implement!(context, context.repository, number)
  end

  step "an implementing thread on \#{int} whose turn has finished",
       %{args: [number]} = context do
    context = given_issue(context, number)
    context = implement!(context, context.repository, number)
    context = end_turns(context)

    {_, context} =
      await_topic(context, fn value ->
        thread = value["threads"]["implement:#{context.repository}##{number}"]
        thread && thread["status"] != "running" && thread
      end)

    Map.put(context, :implement_number, number)
  end

  step "\#{int} shows its implementing thread done", %{args: [number]} = context do
    thread = tracker!(context)["threads"]["implement:#{context.repository}##{number}"]
    assert thread["threadId"] == context.thread
    assert thread["status"] == "completed"
    context
  end

  step "it is offered the read tool but not the report tool", context do
    names = tools(context.thread)
    assert "issue_tracker_read" in names, inspect(names)
    refute "issue_tracker_report" in names, inspect(names)
    context
  end

  step "no implementing thread starts", context do
    assert tracker!(context)["threads"] == %{}
    context
  end

  step "the user is told to add a checkout of {string} as a project",
       %{args: [repository]} = context do
    assert {:error, _, _} = context.reply
    assert inspect(context.reply) =~ "No project on this MC has #{repository} as its remote"
    context
  end

  # --- settings --------------------------------------------------------------------------

  step "the user saves the settings with a repository {string}", %{args: [bad]} = context do
    save_refused(context, %{"repositories" => [bad]})
  end

  step "the user saves the settings with no agent for prioritising", context do
    save_refused(context, %{
      "prioritising" => agent("approval-required") |> Map.put("provider", "")
    })
  end

  step "the user saves the settings with an empty follow-up prompt", context do
    save_refused(context, %{"followUpPrompt" => ""})
  end

  step "the user saves the settings with looking every 0 minutes", context do
    save_refused(context, %{"pollMinutes" => 0})
  end

  step "the save is refused, told {string}", %{args: [reason]} = context do
    assert {:error, _, _} = context.reply
    assert inspect(context.reply) =~ reason
    context
  end

  # --- helpers ---------------------------------------------------------------------------

  defp settings do
    prompts =
      Map.new(~w(prioritisePrompt followUpPrompt summarisePrompt implementPrompt), fn key ->
        {key, @defaults[key] <> @gate}
      end)

    agents = Map.new(@roles, fn {role, mode} -> {role, agent(mode)} end)

    Map.merge(prompts, agents)
    |> Map.merge(%{"repositories" => [], "issueLabel" => "", "pollMinutes" => 60})
  end

  defp agent(mode),
    do: %{
      "provider" => "codex",
      "model" => "fake/one",
      "modelOptions" => %{},
      "runtimeMode" => mode
    }

  defp issue(repository, number, fields) do
    defaults = %{"labels" => %{"nodes" => [%{"name" => "backend"}]}}
    GitHubIssues.issue(repository, number, Map.merge(defaults, fields))
  end

  defp answers(context, repository, issues) do
    context
    |> GitHubIssues.answers(repository, issues)
    |> Map.put(:github_issues, issues)
  end

  defp given_issue(context, number) do
    answers(context, context.repository, [
      issue(context.repository, number, %{
        "title" => "Add limits",
        "body" => "Limits would be nice."
      })
    ])
  end

  defp save(context, patch) do
    {_, context} =
      World.call!(context, "plugins.saveSettings", %{"id" => @id, "settings" => patch})

    context
  end

  defp save_refused(context, patch) do
    {reply, context} =
      World.call(context, "plugins.saveSettings", %{"id" => @id, "settings" => patch})

    Map.put(context, :reply, reply)
  end

  defp plugin(context, method, input),
    do: World.call(context, "plugins.call", %{"id" => @id, "method" => method, "input" => input})

  defp tracker!(context) do
    {reply, _} = plugin(context, "tracker", %{})
    assert {:ok, tracker} = reply
    tracker
  end

  defp run!(context),
    do:
      Enum.find(tracker!(context)["runs"], &(&1["id"] == context.run["id"])) ||
        flunk("the run is gone")

  # Looks again, and waits until that look (not an earlier one) has published.
  # A look already running — the one the plugin starts with, before the
  # scenario's project and answers exist — is drained first, or its empty
  # queue would answer for this one.
  defp look!(context) do
    {previous, context} =
      await_topic(context, fn value -> value["looking"] == false and value["checkedAt"] end)

    {reply, context} = plugin(context, "refresh", %{})
    assert {:ok, _} = reply

    {_, context} =
      await_topic(context, fn value ->
        value["checkedAt"] not in [nil, previous] and value["checkedAt"]
      end)

    context
  end

  defp start_run(context, method, input) do
    {reply, context} = plugin(context, method, input)
    assert {:ok, run} = reply
    assert %{"status" => "running", "threadId" => thread} = run
    World.await_row(thread, & &1, 10_000)
    Map.merge(context, %{run: run, thread: thread})
  end

  defp implement!(context, repository, number) do
    {reply, context} =
      plugin(context, "implement", %{"repository" => repository, "number" => number})

    assert {:ok, %{"threadId" => thread}} = reply
    World.await_row(thread, & &1, 10_000)

    context
    |> Map.put(:thread, thread)
    |> Map.update(:implement_threads, [thread], &[thread | &1])
  end

  defp await_worktree(thread_id) do
    World.await_stream(
      thread_id,
      fn state ->
        thread = HalC2.StreamState.get(state, "thread")[thread_id]
        thread && thread["worktreePath"]
      end,
      15_000
    )
  end

  defp assert_run(context, action) do
    run = run!(context)
    assert %{"status" => "running", "action" => ^action} = run

    assert %{"instanceId" => "codex", "model" => "fake/one"} =
             thread(context.thread)["modelSelection"]

    context
  end

  # Watches the plugin's `tracker` topic; `await_topic/2` waits on it.
  defp watch(context) do
    sub = System.unique_integer([:positive])

    shape = %{
      "type" => "plugin",
      "environment" => context.mc.environment,
      "id" => @id,
      "topic" => "tracker"
    }

    client = context |> World.client("tracker") |> Mc.sub(sub, shape)

    context
    |> World.put_client("tracker", client)
    |> put_in([:watched, "tracker"], {sub, nil})
  end

  defp await_topic(context, fun) do
    {sub, last} = context.watched["tracker"]

    if found = last && fun.(last) do
      {found, context}
    else
      {frame, client} =
        Mc.await(
          World.client(context, "tracker"),
          &(&1["t"] == "plugin" and &1["id"] == sub and !!fun.(&1["value"])),
          15_000
        )

      context =
        context
        |> World.put_client("tracker", client)
        |> put_in([:watched, "tracker"], {sub, frame["value"]})

      {fun.(frame["value"]), context}
    end
  end

  defp await_run(context, fun) do
    id = context.run["id"]
    await_topic(context, fn value -> Enum.find(value["runs"], &(&1["id"] == id and fun.(&1))) end)
  end

  # Lets the fake Codex finish every turn held at the gate.
  defp end_turns(context) do
    gate = Path.join(context.mc.home, "gate")
    File.mkdir_p!(gate)
    File.write!(Path.join(gate, "answer"), "I looked at it.")
    context
  end

  defp mcp(thread, method, params) do
    %{authorization: auth} = HalC2.Mcp.server(thread, "codex")
    body = JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})
    {200, %{"result" => result}} = HalC2.Mcp.handle(auth, body)
    result
  end

  defp tools(thread), do: Enum.map(mcp(thread, "tools/list", %{})["tools"], & &1["name"])

  defp tool(context, name, arguments),
    do: mcp(context.thread, "tools/call", %{"name" => name, "arguments" => arguments})

  defp tool!(context, name, arguments) do
    result = tool(context, name, arguments)
    assert result["isError"] != true, inspect(result)
    result["structuredContent"]
  end

  defp report!(context, arguments), do: tool!(context, "issue_tracker_report", arguments)

  defp prompt(thread_id) do
    World.await_stream(thread_id, fn state ->
      state
      |> HalC2.StreamState.list("message")
      |> Enum.find_value(&(&1["role"] == "user" and &1["text"]))
    end)
  end

  defp thread(thread_id) do
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))
    HalC2.StreamState.get(state, "thread")[thread_id]
  end
end
