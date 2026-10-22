defmodule HalC2.Steps.Plugins.HostIssues do
  @moduledoc """
  Steps for `features/plugins/host-issues.feature`: the `host-probe` plugin
  (`HalC2.Steps.Support.PluginHost`) calls `Host.issues/3` against the fake GitHub of
  `HalC2.Steps.Support.GitHubIssues`. The "GitHub is asked to ..." checks and the
  missing `project` scope are shared with `features/planning/`.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.Support.{GitHubIssues, PluginHost}
  alias HalC2.Test.Mc.World

  # --- repositories ----------------------------------------------------------------------

  step "an MC with the project {string} whose remote is {string} on GitHub",
       %{args: [title, repository]} = context do
    context = World.create_project(context, title)
    World.github_remote(context, World.project(context, title).root, repository)

    World.cli_rules(context, [
      %{"args" => ["api user"], "stdout" => %{"id" => 7, "login" => "monalisa"}}
    ])
  end

  step "gh is signed in without the {string} scope", %{args: ["project"]} = context do
    GitHubIssues.without_project_scope(context)
  end

  # --- reading ---------------------------------------------------------------------------

  step "{string} has the open issue \#{int} in the milestone {string}, blocked by \#{int}, with the sub-issue \#{int} and closed by the pull request \#{int}",
       %{args: [repository, number, milestone, blocker, sub, pr]} = context do
    issue =
      GitHubIssues.issue(repository, number, %{
        "milestone" => %{"number" => 3, "title" => milestone, "dueOn" => "2026-11-15T07:00:00Z"},
        "blockedBy" => [blocker],
        "subIssues" => [sub],
        "pullRequests" => [pr]
      })

    GitHubIssues.answers(context, repository, [issue])
  end

  step "a plugin granted {string} lists the open issues of {string}",
       %{args: [permission, repository]} = context do
    context
    |> PluginHost.granted([permission])
    |> PluginHost.call("issues", "list", %{
      "projectId" => project_id(repository),
      "repository" => repository,
      "state" => "open"
    })
  end

  step "\#{int} is listed with its milestone, the issue blocking it, its sub-issues and the pull request that closes it",
       %{args: [number]} = context do
    assert {:ok, %{"issues" => issues}} = context.reply
    assert [%{"states" => ["OPEN"]}] = GitHubIssues.graphql_calls(context, "issues(first:")

    assert %{
             "repository" => "acme/api",
             "state" => "open",
             "milestone" => %{"number" => 3, "title" => "Beta", "dueOn" => "2026-11-15"},
             "blockedBy" => [%{"repository" => "acme/api", "number" => 5}],
             "subIssues" => [%{"repository" => "acme/api", "number" => 9}],
             "subIssuesSummary" => %{"total" => 1, "completed" => 0},
             "pullRequests" => [%{"number" => 12, "state" => "open"}]
           } = Enum.find(issues, &(&1["number"] == number))

    context
  end

  step "a plugin granted {string} reads \#{int} of {string}",
       %{args: [permission, number, repository]} = context do
    issue =
      GitHubIssues.issue(repository, number, %{
        "title" => "Rate limits",
        "body" => "Limit each token.",
        "labels" => %{"nodes" => [%{"name" => "backend"}]},
        "assignees" => %{"nodes" => [%{"login" => "octocat"}]},
        "parent" => 2
      })

    context
    |> GitHubIssues.answers(repository, [issue])
    |> PluginHost.granted([permission])
    |> PluginHost.call("issues", "detail", %{
      "projectId" => project_id(repository),
      "repository" => repository,
      "number" => number
    })
  end

  step "it gets \#{int} with its title, body, state, labels, assignees and parent",
       %{args: [number]} = context do
    assert {:ok,
            %{
              "number" => ^number,
              "title" => "Rate limits",
              "body" => "Limit each token.",
              "state" => "open",
              "labels" => ["backend"],
              "assignees" => ["octocat"],
              "parent" => %{"repository" => "acme/api", "number" => 2}
            }} = context.reply

    context
  end

  # --- milestones ------------------------------------------------------------------------

  step "it sets the due date of the milestone {string} of {string} to {string}",
       %{args: [title, repository, due]} = context do
    context =
      context
      |> milestones(repository, title, "2026-11-15T07:00:00Z")
      |> World.cli_rules([
        %{
          "args" => ["--method PATCH", "repos/#{repository}/milestones/3"],
          "stdout" => milestone(repository, title, due <> "T12:00:00Z")
        }
      ])

    input = %{"projectId" => project_id(repository), "repository" => repository}

    {%{"milestones" => listed}, context} =
      PluginHost.call!(context, "issues", "milestones", input)

    %{"number" => number} = Enum.find(listed, &(&1["title"] == title))

    {updated, context} =
      PluginHost.call!(
        context,
        "issues",
        "updateMilestone",
        Map.merge(input, %{"number" => number, "dueOn" => due})
      )

    assert updated["dueOn"] == due
    context
  end

  step "the milestones of {string} list {string} due on {string}",
       %{args: [repository, title, due]} = context do
    assert [%{"due_on" => due_on}] = GitHubIssues.rest_calls(context, "PATCH", "/milestones/3")
    assert String.starts_with?(due_on, due)

    # GitHub now holds the new date.
    context = milestones(context, repository, title, due <> "T12:00:00Z")
    input = %{"projectId" => project_id(repository), "repository" => repository}

    {%{"milestones" => listed}, context} =
      PluginHost.call!(context, "issues", "milestones", input)

    assert %{"dueOn" => ^due} = Enum.find(listed, &(&1["title"] == title))
    context
  end

  # --- changing issues -------------------------------------------------------------------

  step "it creates the issue {string} on \#{int} of {string}",
       %{args: [title, number, repository]} = context do
    change(context, repository, number, "create", %{"title" => title})
  end

  step "it closes it as completed on \#{int} of {string}",
       %{args: [number, repository]} = context do
    change(context, repository, number, "update", %{
      "number" => number,
      "state" => "closed",
      "stateReason" => "completed"
    })
  end

  step "it sets its labels to {string} on \#{int} of {string}",
       %{args: [label, number, repository]} = context do
    change(context, repository, number, "update", %{"number" => number, "labels" => [label]})
  end

  step "it adds {string} to its assignees on \#{int} of {string}",
       %{args: [login, number, repository]} = context do
    change(context, repository, number, "addAssignees", %{
      "number" => number,
      "assignees" => [login]
    })
  end

  step "it takes {string} off its assignees on \#{int} of {string}",
       %{args: [login, number, repository]} = context do
    change(context, repository, number, "removeAssignees", %{
      "number" => number,
      "assignees" => [login]
    })
  end

  step "it adds \#{int} as a sub-issue on \#{int} of {string}",
       %{args: [sub, number, repository]} = context do
    change(context, repository, number, "addSubIssue", %{
      "number" => number,
      "subIssue" => %{"number" => sub}
    })
  end

  step "it marks it blocked by \#{int} on \#{int} of {string}",
       %{args: [blocker, number, repository]} = context do
    change(context, repository, number, "addBlockedBy", %{
      "number" => number,
      "blockedBy" => %{"repository" => repository, "number" => blocker}
    })
  end

  step "it comments {string} on \#{int} of {string}",
       %{args: [body, number, repository]} = context do
    change(context, repository, number, "comment", %{"number" => number, "body" => body})
  end

  step "it closes \#{int} of {string}", %{args: [number, repository]} = context do
    context
    |> GitHubIssues.answers(repository, [GitHubIssues.issue(repository, number)])
    |> PluginHost.call("issues", "update", %{
      "projectId" => project_id(repository),
      "repository" => repository,
      "number" => number,
      "state" => "closed"
    })
  end

  step "GitHub is asked to create the issue {string}", %{args: [title]} = context do
    assert Enum.any?(
             GitHubIssues.rest_calls(context, "POST", "/issues"),
             &(&1["title"] == title)
           )

    context
  end

  step "GitHub is asked to close \#{int} as completed", %{args: [number]} = context do
    GitHubIssues.assert_patched(context, number, %{
      "state" => "closed",
      "state_reason" => "completed"
    })
  end

  step "the MC answers with \#{int} and its link but not its title or body",
       %{args: [number]} = context do
    assert {:ok, %{"number" => ^number, "url" => "https://" <> _} = answer} = context.reply
    refute Map.has_key?(answer, "title") or Map.has_key?(answer, "body")
    context
  end

  step "GitHub is asked to rename \#{int} to {string}", %{args: [number, title]} = context do
    GitHubIssues.assert_patched(context, number, %{"title" => title})
  end

  step "GitHub is asked to set the labels of \#{int} to {string}",
       %{args: [number, label]} = context do
    GitHubIssues.assert_patched(context, number, %{"labels" => [label]})
  end

  step "GitHub is asked to add {string} to the assignees of \#{int}",
       %{args: [login, number]} = context do
    assert %{"assignees" => [login]} in GitHubIssues.rest_calls(
             context,
             "POST",
             "/issues/#{number}/assignees"
           )

    context
  end

  step "GitHub is asked to take {string} off the assignees of \#{int}",
       %{args: [login, number]} = context do
    assert %{"assignees" => [login]} in GitHubIssues.rest_calls(
             context,
             "DELETE",
             "/issues/#{number}/assignees"
           )

    context
  end

  step "GitHub is asked to add \#{int} as a sub-issue of \#{int}",
       %{args: [sub, number]} = context do
    GitHubIssues.assert_related(context, "addSubIssue", number, sub)
  end

  step "GitHub is asked to mark \#{int} as blocked by \#{int}",
       %{args: [number, blocker]} = context do
    GitHubIssues.assert_related(context, "addBlockedBy", number, blocker)
  end

  step "GitHub is asked to comment {string} on \#{int}", %{args: [body, number]} = context do
    assert %{"body" => body} in GitHubIssues.rest_calls(
             context,
             "POST",
             "/issues/#{number}/comments"
           )

    context
  end

  # --- boards ----------------------------------------------------------------------------

  step "the board {string} has the fields {string}, {string} and {string}",
       %{args: [board | fields]} = context do
    context
    |> Map.put(:board_fields, fields)
    |> GitHubIssues.board(board, fields, [])
  end

  step "\#{int} of {string} is on {string} starting {string} with the target {string}",
       %{args: [number, repository, board, start, target]} = context do
    [start_field, target_field | _] = context.board_fields
    dates = %{start_field => start, target_field => target}

    context
    |> Map.put(:board_dates, dates)
    |> GitHubIssues.board(board, context.board_fields, [
      %{"number" => number, "repository" => repository, "fields" => dates}
    ])
  end

  step "a plugin granted {string} reads the board {string}",
       %{args: [permission, board]} = context do
    [owner, number] = String.split(board, "/")

    context
    |> PluginHost.granted([permission])
    |> PluginHost.call("issues", "board", %{
      "projectId" => project_id("acme/api"),
      "owner" => owner,
      "number" => String.to_integer(number)
    })
  end

  step "\#{int} is an item of {string} with those dates", %{args: [number, board]} = context do
    assert {:ok, %{"items" => items, "fields" => fields} = read} = context.reply
    assert "#{read["owner"]}/#{read["number"]}" == board

    assert Enum.map(fields, &{&1["name"], &1["type"]}) == [
             {"Start date", "date"},
             {"Target date", "date"},
             {"Status", "singleSelect"}
           ]

    assert %{"fields" => values} =
             Enum.find(
               items,
               &match?(%{"content" => %{"kind" => "issue", "number" => ^number}}, &1)
             )

    assert values == context.board_dates
    context
  end

  step "{string} has more open issues, and the board {string} more items, than a plugin asks for",
       %{args: [repository, board]} = context do
    issues = for n <- [1, 2], do: GitHubIssues.issue(repository, n)
    items = for n <- [1, 2], do: %{"number" => n, "repository" => repository}

    context
    |> GitHubIssues.answers(repository, issues, true)
    |> GitHubIssues.board(board, ["Start date"], items, true)
  end

  step "a plugin granted {string} lists {int} open issues of {string} and {int} items of {string}",
       %{args: [permission, issues, repository, items, board]} = context do
    [owner, number] = String.split(board, "/")
    context = PluginHost.granted(context, [permission])

    list =
      PluginHost.call(context, "issues", "list", %{
        "projectId" => project_id(repository),
        "repository" => repository,
        "state" => "open",
        "limit" => issues
      })

    list
    |> PluginHost.call("issues", "board", %{
      "projectId" => project_id(repository),
      "owner" => owner,
      "number" => String.to_integer(number),
      "limit" => items
    })
    |> Map.put(:replies, [list.reply])
  end

  step "both answers say more were left unread", context do
    assert [{:ok, %{"issues" => [_, _], "truncated" => true}}] = context.replies
    assert {:ok, %{"items" => [_, _], "truncated" => true}} = context.reply
    context
  end

  step "it sets {string} of \#{int} on the board {string} to {string}",
       %{args: [field, number, board, value]} = context do
    [owner, board_number] = String.split(board, "/")

    # The plugin read the board earlier; the item's id is the one GitHub gave it.
    context
    |> GitHubIssues.board(board, ["Start date", "Target date", "Status"], [
      %{"number" => number, "repository" => "acme/api"}
    ])
    |> Map.put(:board_change, {field, number})
    |> PluginHost.call("issues", "setBoardField", %{
      "projectId" => project_id("acme/api"),
      "owner" => owner,
      "number" => String.to_integer(board_number),
      "itemId" => GitHubIssues.item_id(number),
      "field" => field,
      "value" => value
    })
  end

  step "GitHub is asked to set that field of the item to {string}", %{args: [value]} = context do
    assert {:ok, %{"ok" => true}} = context.reply
    {field, number} = context.board_change
    GitHubIssues.assert_board_date(context, field, number, value)
  end

  step "GitHub is asked to set {string} of \#{int} on {string} to {string}",
       %{args: [field, number, _board, value]} = context do
    GitHubIssues.assert_board_date(context, field, number, value)
  end

  # --- refusals --------------------------------------------------------------------------

  step "it is told to run {string}", %{args: [command]} = context do
    assert PluginHost.refusal(context) =~ command
    context
  end

  step "it is told that issues on that host cannot be read yet", context do
    assert PluginHost.refusal(context) =~ "Issues on gitlab.com cannot be read here yet."
    context
  end

  # --- helpers ---------------------------------------------------------------------------

  defp change(context, repository, number, method, input) do
    context
    |> GitHubIssues.answers(repository, [GitHubIssues.issue(repository, number)])
    |> PluginHost.call(
      "issues",
      method,
      Map.merge(%{"projectId" => project_id(repository), "repository" => repository}, input)
    )
    |> tap(&assert({:ok, _} = &1.reply))
  end

  defp project_id(repository),
    do: Enum.find(HalC2.PullRequests.projects(), &(&1.repository == repository)).id

  defp milestones(context, repository, title, due_on) do
    World.cli_rules(context, [
      %{
        "args" => ["repos/#{repository}/milestones?state=open"],
        "stdout" => [milestone(repository, title, due_on)]
      }
    ])
  end

  defp milestone(repository, title, due_on) do
    %{
      "number" => 3,
      "title" => title,
      "description" => "",
      "state" => "open",
      "due_on" => due_on,
      "html_url" => "https://github.com/#{repository}/milestone/3",
      "open_issues" => 4,
      "closed_issues" => 2
    }
  end
end
