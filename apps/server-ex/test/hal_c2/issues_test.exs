defmodule HalC2.IssuesTest do
  use ExUnit.Case, async: false

  alias HalC2.Issues

  @moduletag :tmp_dir
  @fake_gh Path.expand("../support/fake_gh.py", __DIR__)
  @input %{"projectId" => "p1", "repository" => "acme/widgets"}

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    previous = Application.get_env(:hal_c2, :gh_command)
    Application.put_env(:hal_c2, :gh_command, @fake_gh)
    System.put_env("FAKE_GH_RULES", Path.join(dir, "rules.json"))
    System.put_env("FAKE_GH_LOG", Path.join(dir, "gh.log"))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:hal_c2, :gh_command, previous),
        else: Application.delete_env(:hal_c2, :gh_command)

      System.delete_env("FAKE_GH_RULES")
      System.delete_env("FAKE_GH_LOG")
    end)

    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)
    :ok = HalC2.Shell.subscribe(self())
    project!(dir, "p1", "https://github.com/acme/widgets.git")
    File.write!(Path.join(dir, "gh.log"), "")
    %{dir: dir}
  end

  test "a listing reads page after page up to its limit, filtered as asked", %{dir: dir} do
    rules!(dir, [
      graphql(["issues(first: $first", ~s("after":"c1")], issues_page([issue(3)], false, nil)),
      graphql(["issues(first: $first"], issues_page([issue(1), issue(2)], true, "c1"))
    ])

    input =
      Map.merge(@input, %{
        "state" => "all",
        "labels" => ["bug"],
        "milestone" => 4,
        "since" => "2026-10-01T00:00:00Z",
        "limit" => 3
      })

    assert {:ok, %{"issues" => issues, "truncated" => false}} = Issues.handle("list", input)
    assert Enum.map(issues, & &1["number"]) == [1, 2, 3]

    assert [first, second] = graphql_calls(dir)
    assert %{"first" => 3, "after" => nil, "states" => nil, "labels" => ["bug"]} = first

    assert first["filter"] == %{"milestoneNumber" => "4", "since" => "2026-10-01T00:00:00Z"}
    assert %{"first" => 1, "after" => "c1"} = second
  end

  test "a listing that stops at its limit with more on GitHub says it was cut short", %{dir: dir} do
    rules!(dir, [graphql(["issues(first: $first"], issues_page([issue(1), issue(2)], true, "c1"))])

    assert {:ok, %{"issues" => [_, _], "truncated" => true}} =
             Issues.handle("list", Map.put(@input, "limit", 2))

    assert [_] = graphql_calls(dir)
  end

  test "an issue is answered in the host-neutral shape", %{dir: dir} do
    raw =
      issue(7, %{
        "state" => "CLOSED",
        "stateReason" => "NOT_PLANNED",
        "milestone" => %{"number" => 2, "title" => "Beta", "dueOn" => "2026-11-30T07:00:00Z"},
        "parent" => ref(1, "acme/other"),
        "blockedBy" => %{"nodes" => [ref(5)]},
        "closedByPullRequestsReferences" => %{
          "nodes" => [
            %{
              "number" => 12,
              "title" => "Fix",
              "url" => "u",
              "state" => "MERGED",
              "repository" => %{"nameWithOwner" => "acme/widgets"}
            }
          ]
        },
        "issueType" => %{"name" => "Bug"}
      })

    rules!(dir, [graphql([~s("number":7)], %{"repository" => %{"issue" => raw}})])

    assert {:ok, issue} = Issues.handle("detail", Map.put(@input, "number", 7))

    assert %{
             "repository" => "acme/widgets",
             "number" => 7,
             "state" => "closed",
             "stateReason" => "not_planned",
             "milestone" => %{"number" => 2, "title" => "Beta", "dueOn" => "2026-11-30"},
             "parent" => %{"repository" => "acme/other", "number" => 1},
             "blockedBy" => [%{"repository" => "acme/widgets", "number" => 5}],
             "subIssues" => [],
             "pullRequests" => [%{"number" => 12, "state" => "merged"}],
             "issueType" => "Bug"
           } = issue
  end

  test "an issue that is not there says so", %{dir: dir} do
    rules!(dir, [graphql([], %{"repository" => %{"issue" => nil}})])

    assert {:error, "Issue acme/widgets#8 was not found, or this login cannot see it."} =
             Issues.handle("detail", Map.put(@input, "number", 8))
  end

  test "an issue is created and changed over REST, and read back", %{dir: dir} do
    rules!(dir, [
      %{
        "args" => ["--method POST", "repos/acme/widgets/issues --input"],
        "stdout" => %{"number" => 9}
      },
      %{
        "args" => ["--method PATCH", "repos/acme/widgets/issues/9"],
        "stdout" => %{"number" => 9}
      },
      graphql([~s("number":9)], %{"repository" => %{"issue" => issue(9)}})
    ])

    assert {:ok, %{"number" => 9}} =
             Issues.handle(
               "create",
               Map.merge(@input, %{"title" => " Add limits ", "milestone" => 2})
             )

    assert {:ok, %{"number" => 9}} =
             Issues.handle(
               "update",
               Map.merge(@input, %{
                 "number" => 9,
                 "state" => "closed",
                 "stateReason" => "not_planned",
                 "milestone" => nil
               })
             )

    assert [%{"title" => "Add limits", "milestone" => 2}] = rest_inputs(dir, "POST")

    assert [%{"state" => "closed", "state_reason" => "not_planned", "milestone" => nil} = patch] =
             rest_inputs(dir, "PATCH")

    refute Map.has_key?(patch, "title")

    # Assignees set outright are checked as logins too, before GitHub is asked.
    assert {:error, "assignees must be a list of logins."} =
             Issues.handle("create", Map.merge(@input, %{"title" => "x", "assignees" => ["a/b"]}))

    assert {:error, "assignees must be a list of logins."} =
             Issues.handle(
               "update",
               Map.merge(@input, %{"number" => 9, "assignees" => "dana"})
             )

    assert length(calls(dir)) == 4

    # An empty assignee list on update clears the list at GitHub, unlike an absent one.
    assert {:ok, %{"number" => 9}} =
             Issues.handle("update", Map.merge(@input, %{"number" => 9, "assignees" => []}))

    assert [_, %{"assignees" => []}] = rest_inputs(dir, "PATCH")
  end

  test "assignees are added and removed by login, the others kept", %{dir: dir} do
    rules!(dir, [
      %{
        "args" => ["--method POST", "repos/acme/widgets/issues/9/assignees"],
        "stdout" => %{"number" => 9, "assignees" => [%{"login" => "alice"}, %{"login" => "dana"}]}
      },
      %{
        "args" => ["--method DELETE", "repos/acme/widgets/issues/9/assignees"],
        "stdout" => %{"number" => 9, "assignees" => [%{"login" => "bob"}]}
      }
    ])

    input = Map.merge(@input, %{"number" => 9, "assignees" => ["dana"]})

    assert {:ok, %{"number" => 9, "assignees" => ["alice", "dana"]}} =
             Issues.handle("addAssignees", input)

    input = Map.put(input, "assignees", ["alice"])
    assert {:ok, %{"assignees" => ["bob"]}} = Issues.handle("removeAssignees", input)

    assert [%{"assignees" => ["dana"]}] = rest_inputs(dir, "POST")
    assert [%{"assignees" => ["alice"]}] = rest_inputs(dir, "DELETE")

    # The shape cases are the planner suite's own (`HalC2.Test.LoginCases`),
    # so a drift in either copy of the login shape fails both suites.
    for bad <-
          [
            [],
            [" "],
            ["dana", 7],
            Enum.map(1..11, &"user#{&1}")
          ] ++ Enum.map(HalC2.Test.LoginCases.bad(), &[&1]),
        do: assert({:error, _} = Issues.handle("addAssignees", Map.put(input, "assignees", bad)))

    assert length(calls(dir)) == 2

    # A login is trimmed, and named once whatever its case, even by more than ten copies.
    assert {:ok, _} =
             Issues.handle(
               "addAssignees",
               Map.put(input, "assignees", [" dana ", "dana", "Dana"])
             )

    assert [_, %{"assignees" => ["dana"]}] = rest_inputs(dir, "POST")

    assert {:ok, _} =
             Issues.handle(
               "addAssignees",
               Map.put(input, "assignees", List.duplicate("dana", 11))
             )

    assert [_, _, %{"assignees" => ["dana"]}] = rest_inputs(dir, "POST")

    # No realistic raw count is capped in front of the de-dup: many copies of
    # one login are that one assignee.
    assert {:ok, _} =
             Issues.handle(
               "addAssignees",
               Map.put(input, "assignees", List.duplicate("dana", 101))
             )

    # Only a list far past any real assignee list is refused up front.
    assert {:error, _} =
             Issues.handle(
               "addAssignees",
               Map.put(input, "assignees", List.duplicate("dana", 301))
             )

    assert [_, _, _, %{"assignees" => ["dana"]}] = rest_inputs(dir, "POST")

    # The endpoint takes several logins in one request.
    assert {:ok, _} = Issues.handle("addAssignees", Map.put(input, "assignees", ["dana", "erin"]))
    assert [_, _, _, _, %{"assignees" => ["dana", "erin"]}] = rest_inputs(dir, "POST")

    # Managed users' underscores, a bot's suffix and the longest login are
    # logins: the planner suite's own good cases (`HalC2.Test.LoginCases`).
    for good <- HalC2.Test.LoginCases.good() do
      assert {:ok, _} =
               Issues.handle("addAssignees", Map.put(input, "assignees", [good]))
    end

    longest = String.duplicate("a", 39)

    assert {:ok, _} =
             Issues.handle(
               "addAssignees",
               Map.put(input, "assignees", ["dana_acme", "copilot[bot]", longest])
             )

    assert [
             _,
             _,
             _,
             _,
             _,
             _,
             _,
             _,
             _,
             _,
             %{"assignees" => ["dana_acme", "copilot[bot]", ^longest]}
           ] =
             rest_inputs(dir, "POST")
  end

  test "a change GitHub made is answered as made when reading it back fails", %{dir: dir} do
    rules!(dir, [
      %{
        "args" => ["--method POST", "repos/acme/widgets/issues --input"],
        "stdout" => %{"number" => 9, "html_url" => "issue-url"}
      },
      %{"args" => ["api graphql"], "exit" => 1, "stderr" => "HTTP 502: Bad Gateway\n"}
    ])

    assert {:ok, %{"repository" => "acme/widgets", "number" => 9, "url" => "issue-url"}} =
             Issues.handle("create", Map.put(@input, "title", "Add limits"))
  end

  test "a listing refuses a state or milestone it cannot ask for", %{dir: dir} do
    rules!(dir, [])

    assert {:error, ~s("clsoed" is not one of open, closed, all.)} =
             Issues.handle("list", Map.put(@input, "state", "clsoed"))

    assert {:error, ~s(milestone takes text or a number, not %{"number" => 4}.)} =
             Issues.handle("list", Map.put(@input, "milestone", %{"number" => 4}))

    assert graphql_calls(dir) == []
  end

  test "a comment is posted as written, its indentation kept", %{dir: dir} do
    rules!(dir, [
      %{
        "args" => ["--method POST", "repos/acme/widgets/issues/9/comments"],
        "stdout" => %{"html_url" => "https://github.com/acme/widgets/issues/9#c1"}
      }
    ])

    body = "    mix test\n"

    assert {:ok, %{"url" => "https://github.com/acme/widgets/issues/9#c1"}} =
             Issues.handle("comment", Map.merge(@input, %{"number" => 9, "body" => body}))

    assert [%{"body" => ^body}] = rest_inputs(dir, "POST")

    assert {:error, "body is required."} =
             Issues.handle("comment", Map.merge(@input, %{"number" => 9, "body" => "  "}))
  end

  test "a milestone's due date is a day, kept at noon UTC on GitHub", %{dir: dir} do
    answer = %{
      "number" => 2,
      "title" => "Beta",
      "state" => "open",
      "due_on" => "2026-11-30T12:00:00Z",
      "html_url" => "https://github.com/acme/widgets/milestone/2",
      "open_issues" => 3,
      "closed_issues" => 1
    }

    rules!(dir, [
      %{"args" => ["milestones?state=closed"], "stdout" => [answer]},
      %{"args" => ["--method POST", "repos/acme/widgets/milestones"], "stdout" => answer},
      %{"args" => ["--method PATCH", "repos/acme/widgets/milestones/2"], "stdout" => answer}
    ])

    assert {:ok, %{"milestones" => [milestone]}} =
             Issues.handle("milestones", Map.put(@input, "state", "closed"))

    assert milestone == %{
             "number" => 2,
             "title" => "Beta",
             "description" => nil,
             "state" => "open",
             "dueOn" => "2026-11-30",
             "url" => "https://github.com/acme/widgets/milestone/2",
             "openIssues" => 3,
             "closedIssues" => 1
           }

    assert {:ok, _} =
             Issues.handle(
               "createMilestone",
               Map.merge(@input, %{"title" => "Beta", "dueOn" => "2026-11-30"})
             )

    assert {:ok, _} =
             Issues.handle("updateMilestone", Map.merge(@input, %{"number" => 2, "dueOn" => nil}))

    assert {:error, "\"30/11\" is not a date (YYYY-MM-DD)."} =
             Issues.handle(
               "updateMilestone",
               Map.merge(@input, %{"number" => 2, "dueOn" => "30/11"})
             )

    assert [%{"title" => "Beta", "due_on" => "2026-11-30T12:00:00Z"}] = rest_inputs(dir, "POST")
    assert [%{"due_on" => nil}] = rest_inputs(dir, "PATCH")
  end

  test "milestones are read page after page until a short one", %{dir: dir} do
    numbered = fn range -> for n <- range, do: %{"number" => n, "title" => "M#{n}"} end

    rules!(dir, [
      %{"args" => ["milestones?state=all&per_page=100&page=1"], "stdout" => numbered.(1..100)},
      %{"args" => ["milestones?state=all&per_page=100&page=2"], "stdout" => numbered.(101..102)}
    ])

    assert {:ok, %{"milestones" => milestones}} =
             Issues.handle("milestones", Map.put(@input, "state", "all"))

    assert Enum.map(milestones, & &1["number"]) == Enum.to_list(1..102)
    assert length(calls(dir)) == 2
  end

  test "sub-issues and dependencies are changed by the node ids of both issues", %{dir: dir} do
    rules!(dir, [
      graphql(["other: repository(", ~s("other":5)], %{
        "issue" => %{"issue" => %{"id" => "I_7"}},
        "other" => %{"issue" => nil}
      }),
      graphql(["other: repository("], %{
        "issue" => %{"issue" => %{"id" => "I_7"}},
        "other" => %{"issue" => %{"id" => "I_9"}}
      }),
      graphql(["removeBlockedBy(input"], %{"removeBlockedBy" => %{}}),
      graphql(["addSubIssue(input"], %{"addSubIssue" => %{}})
    ])

    sub = %{"repository" => "acme/other", "number" => 9}

    assert {:ok, %{"ok" => true}} =
             Issues.handle("addSubIssue", Map.merge(@input, %{"number" => 7, "subIssue" => sub}))

    assert {:ok, %{"ok" => true}} =
             Issues.handle(
               "removeBlockedBy",
               Map.merge(@input, %{"number" => 7, "blockedBy" => %{"number" => 9}})
             )

    assert {:error, "Issue acme/widgets#5 was not found, or this login cannot see it."} =
             Issues.handle(
               "addBlockedBy",
               Map.merge(@input, %{"number" => 7, "blockedBy" => %{"number" => 5}})
             )

    assert {:error, "subIssue must be {repository, number}."} =
             Issues.handle("addSubIssue", Map.merge(@input, %{"number" => 7, "subIssue" => 9}))

    assert [pair, add, pair2, remove, _pair3] = graphql_calls(dir)

    assert %{"owner" => "acme", "number" => 7, "otherOwner" => "acme", "otherName" => "other"} =
             pair

    assert add == %{"issue" => "I_7", "other" => "I_9"}
    assert %{"otherName" => "widgets", "other" => 9} = pair2
    assert remove == %{"issue" => "I_7", "other" => "I_9"}
  end

  test "a board reads its fields and each item's values by field name", %{dir: dir} do
    rules!(dir, [
      graphql(["items(first: $first", ~s("after":"c1")], board([draft_item()], false, nil)),
      graphql(["items(first: $first"], board([issue_item()], true, "c1"))
    ])

    input = %{"projectId" => "p1", "owner" => "acme", "number" => 3}
    assert {:ok, read} = Issues.handle("board", input)

    assert %{"owner" => "acme", "number" => 3, "title" => "Roadmap", "url" => "board-url"} = read
    assert read["truncated"] == false

    assert [
             %{"name" => "Title", "type" => "other"},
             %{"name" => "Target date", "type" => "date"},
             %{"name" => "Status", "type" => "singleSelect", "options" => [_, _]},
             %{"name" => "Sprint", "type" => "iteration", "iterations" => [_, _]}
           ] = read["fields"]

    assert [issue, draft] = read["items"]

    assert issue == %{
             "id" => "PVTI_7",
             "content" => %{
               "kind" => "issue",
               "repository" => "acme/widgets",
               "number" => 7,
               "title" => "Rate limits",
               "url" => "u",
               "state" => "open"
             },
             "fields" => %{
               "Target date" => "2026-11-02",
               "Status" => "Doing",
               "Sprint" => "Sprint 1",
               "Points" => 3
             }
           }

    assert %{"content" => %{"kind" => "draft", "number" => nil}, "fields" => %{}} = draft
  end

  test "a board that stops at its limit with more items on GitHub says it was cut short", %{
    dir: dir
  } do
    rules!(dir, [graphql(["items(first: $first"], board([issue_item()], true, "c1"))])
    input = %{"projectId" => "p1", "owner" => "acme", "number" => 3, "limit" => 1}
    assert {:ok, %{"items" => [_], "truncated" => true}} = Issues.handle("board", input)
  end

  test "a board field is set by its name, an option by name and an iteration by title", %{
    dir: dir
  } do
    notes = %{"id" => "F_notes", "name" => "Notes", "dataType" => "TEXT"}
    project = update_in(project()["fields"]["nodes"], &(&1 ++ [notes]))

    rules!(dir, [
      graphql(["{ id fields(first: 50)"], %{
        "repositoryOwner" => %{"projectV2" => Map.take(project, ["id", "fields"])}
      }),
      graphql(["updateProjectV2ItemFieldValue"], %{"updateProjectV2ItemFieldValue" => %{}}),
      graphql(["clearProjectV2ItemFieldValue"], %{"clearProjectV2ItemFieldValue" => %{}})
    ])

    set = fn field, value ->
      Issues.handle("setBoardField", %{
        "projectId" => "p1",
        "owner" => "acme",
        "number" => 3,
        "itemId" => "PVTI_7",
        "field" => field,
        "value" => value
      })
    end

    assert {:ok, %{"ok" => true}} = set.("target date", "2026-11-09")
    assert {:ok, %{"ok" => true}} = set.("Status", "done")
    assert {:ok, %{"ok" => true}} = set.("Sprint", "Sprint 0")
    assert {:ok, %{"ok" => true}} = set.("Status", nil)
    assert {:ok, %{"ok" => true}} = set.("Notes", 3)
    assert {:error, "Notes takes text or a number, not [\"a\"]."} = set.("Notes", ["a"])
    assert {:error, "Status has no option \"Later\"."} = set.("Status", "Later")
    assert {:error, "Title cannot be set here."} = set.("Title", "x")

    assert {:error, "The board acme/3 has no field \"Due\"."} = set.("Due", "2026-11-09")

    changes = for vars <- graphql_calls(dir), Map.has_key?(vars, "item"), do: vars

    assert [
             %{"project" => "PVT_3", "field" => "F_target", "value" => %{"date" => "2026-11-09"}},
             %{"field" => "F_status", "value" => %{"singleSelectOptionId" => "O_done"}},
             %{"field" => "F_sprint", "value" => %{"iterationId" => "IT_0"}},
             %{"field" => "F_status"} = clear,
             %{"field" => "F_notes", "value" => %{"text" => "3"}}
           ] = changes

    refute Map.has_key?(clear, "value")
  end

  test "an issue is added to a board by its node id, in the project's repository by default", %{
    dir: dir
  } do
    rules!(dir, [
      graphql(["issueOrPullRequest(number: $content)"], %{
        "repositoryOwner" => %{"projectV2" => %{"id" => "PVT_3"}},
        "repository" => %{"issueOrPullRequest" => %{"id" => "I_7"}}
      }),
      graphql(["addProjectV2ItemById"], %{
        "addProjectV2ItemById" => %{"item" => %{"id" => "PVTI_7"}}
      })
    ])

    assert {:ok, %{"itemId" => "PVTI_7"}} =
             Issues.handle("addBoardItem", %{
               "projectId" => "p1",
               "owner" => "acme",
               "number" => 3,
               "item" => %{"number" => 7}
             })

    # An item with no repository is the project's.
    assert [lookup, %{"project" => "PVT_3", "content" => "I_7"}] = graphql_calls(dir)
    assert %{"contentOwner" => "acme", "contentName" => "widgets", "content" => 7} = lookup
  end

  test "an issue asks for every sub-issue a parent may have and a board item for every field's value",
       %{dir: dir} do
    rules!(dir, [
      graphql([~s("number":7)], %{"repository" => %{"issue" => issue(7)}}),
      graphql(["items(first: $first"], board([], false, nil))
    ])

    assert {:ok, _} = Issues.handle("detail", Map.put(@input, "number", 7))

    assert {:ok, _} =
             Issues.handle("board", %{"projectId" => "p1", "owner" => "acme", "number" => 3})

    [detail, board] = for %{"stdin" => stdin} <- calls(dir), do: JSON.decode!(stdin)["query"]

    # GitHub allows a parent 100 sub-issues.
    assert page_size(detail, "subIssues") == 100
    assert page_size(board, "fieldValues") >= page_size(board, "fields")
  end

  test "boards are listed page after page, each with its owner", %{dir: dir} do
    page = fn nodes, more?, cursor ->
      %{
        "repositoryOwner" => %{
          "projectsV2" => %{
            "pageInfo" => %{"hasNextPage" => more?, "endCursor" => cursor},
            "nodes" => nodes
          }
        }
      }
    end

    rules!(dir, [
      graphql(
        ["projectsV2(first: 100", ~s("after":"c1")],
        page.([listed(3, "Roadmap")], false, nil)
      ),
      graphql(["projectsV2(first: 100"], page.([listed(1, "Bugs"), nil], true, "c1"))
    ])

    assert {:ok, %{"boards" => boards}} = Issues.handle("boards", %{"projectId" => "p1"})

    assert [%{"number" => 1, "title" => "Bugs", "owner" => "acme"}, %{"number" => 3}] = boards
    assert [%{"owner" => "acme", "after" => nil}, %{"after" => "c1"}] = graphql_calls(dir)
  end

  test "a board gh may not read for want of the project scope says how to grant it", %{dir: dir} do
    rules!(dir, [
      %{
        "args" => ["api graphql"],
        "exit" => 1,
        "stderr" =>
          "gh: Your token has not been granted the required scopes to execute this query. " <>
            "The 'projectsV2' field requires one of the following scopes: ['read:project']\n"
      }
    ])

    assert {:error, message} = Issues.handle("boards", %{"projectId" => "p1"})
    assert message =~ "gh auth refresh -s project"

    rules!(dir, [
      %{
        "args" => ["api graphql"],
        "exit" => 1,
        "stderr" =>
          "GraphQL: Your token has not been granted the required scopes to execute this query. " <>
            "The 'addProjectV2ItemById' field requires one of the following scopes: ['project']\n"
      }
    ])

    assert {:error, message} =
             Issues.handle("addBoardItem", %{
               "projectId" => "p1",
               "owner" => "acme",
               "number" => 3,
               "item" => %{"repository" => "acme/widgets", "number" => 7}
             })

    assert message =~ "gh auth refresh -s project"
  end

  test "a login missing another scope is told GitHub's own words", %{dir: dir} do
    refused =
      "Your token has not been granted the required scopes to execute this query. " <>
        "The 'issues' field requires one of the following scopes: ['repo']"

    rules!(dir, [%{"args" => ["api graphql"], "exit" => 1, "stderr" => "GraphQL: #{refused}\n"}])

    assert {:error, message} = Issues.handle("list", @input)
    assert message =~ "['repo']"
    refute message =~ "project"
  end

  test "gh missing or signed out is told as pull requests tell it", %{dir: dir} do
    rules!(dir, [
      %{"args" => ["api"], "exit" => 1, "stderr" => "gh: not logged in. Run gh auth login\n"}
    ])

    assert {:error, message} = Issues.handle("milestones", @input)
    assert message == HalC2.PullRequests.requirement(:unauthenticated)

    Application.put_env(:hal_c2, :gh_command, "hal-c2-test-no-gh")
    assert {:error, message} = Issues.handle("milestones", @input)
    assert message == HalC2.PullRequests.requirement(:missing)
  end

  test "projects on other hosts, unknown projects and unknown methods are refused", %{dir: dir} do
    project!(dir, "p2", "git@gitlab.com:acme/web.git")

    assert {:error, "Issues on gitlab.com cannot be read here yet."} =
             Issues.handle("list", %{"projectId" => "p2"})

    assert {:error, "No project \"nope\" with a git remote is on this MC."} =
             Issues.handle("list", %{"projectId" => "nope"})

    assert {:error, "issues.merge is not served by this MC."} = Issues.handle("merge", @input)

    assert {:error, _} = Issues.handle("detail", Map.put(@input, "repository", "not a repo"))
    assert {:error, _} = Issues.handle("detail", Map.put(@input, "repository", 42))
    assert File.read!(Path.join(dir, "gh.log")) == ""

    assert Issues.write?("setBoardField") and Issues.write?("comment")
    assert Issues.write?("addAssignees") and Issues.write?("removeAssignees")
    refute Issues.write?("board") or Issues.write?("list")
  end

  # --- fixtures --------------------------------------------------------------------------

  defp project!(dir, id, remote) do
    repo = Path.join(dir, id)
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: repo)
    {_, 0} = System.cmd("git", ["remote", "add", "origin", remote], cd: repo)

    {:ok, _} =
      HalC2.Projects.mutate(%{
        "type" => "project.create",
        "projectId" => id,
        "title" => id,
        "workspaceRoot" => repo
      })

    assert_receive {:hal_c2_shell, {:rows, _, [{^id, _}]}}, 1_000
  end

  defp rules!(dir, rules), do: File.write!(Path.join(dir, "rules.json"), JSON.encode!(rules))

  defp calls(dir) do
    dir
    |> Path.join("gh.log")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
  end

  defp graphql_calls(dir) do
    for %{"args" => ["api", "graphql" | _], "stdin" => stdin} <- calls(dir),
        do: JSON.decode!(stdin)["variables"]
  end

  defp rest_inputs(dir, method) do
    for %{"args" => args, "stdin" => stdin} <- calls(dir),
        Enum.join(args, " ") =~ "--method #{method}",
        do: JSON.decode!(stdin)
  end

  # How many nodes of `connection` a GraphQL document asks for.
  defp page_size(query, connection) do
    [size] = Regex.run(~r/\b#{connection}\(first: (\d+)/, query, capture: :all_but_first)
    String.to_integer(size)
  end

  defp graphql(stdin, data),
    do: %{"args" => ["api graphql"], "stdin" => stdin, "stdout" => %{"data" => data}}

  defp ref(number, repository \\ "acme/widgets"),
    do: %{"number" => number, "repository" => %{"nameWithOwner" => repository}}

  defp issue(number, fields \\ %{}) do
    Map.merge(
      %{
        "number" => number,
        "title" => "Issue #{number}",
        "state" => "OPEN",
        "repository" => %{"nameWithOwner" => "acme/widgets"}
      },
      fields
    )
  end

  defp listed(number, title),
    do: %{"number" => number, "title" => title, "url" => "board-#{number}", "closed" => false}

  defp issues_page(nodes, more?, cursor) do
    %{
      "repository" => %{
        "issues" => %{
          "pageInfo" => %{"hasNextPage" => more?, "endCursor" => cursor},
          "nodes" => nodes
        }
      }
    }
  end

  defp project do
    %{
      "id" => "PVT_3",
      "title" => "Roadmap",
      "url" => "board-url",
      "fields" => %{
        "nodes" => [
          %{"id" => "F_title", "name" => "Title", "dataType" => "TITLE"},
          %{"id" => "F_target", "name" => "Target date", "dataType" => "DATE"},
          %{
            "id" => "F_status",
            "name" => "Status",
            "dataType" => "SINGLE_SELECT",
            "options" => [
              %{"id" => "O_doing", "name" => "Doing"},
              %{"id" => "O_done", "name" => "Done"}
            ]
          },
          %{
            "id" => "F_sprint",
            "name" => "Sprint",
            "dataType" => "ITERATION",
            "configuration" => %{
              "iterations" => [
                %{
                  "id" => "IT_1",
                  "title" => "Sprint 1",
                  "startDate" => "2026-10-19",
                  "duration" => 14
                }
              ],
              "completedIterations" => [
                %{
                  "id" => "IT_0",
                  "title" => "Sprint 0",
                  "startDate" => "2026-10-05",
                  "duration" => 14
                }
              ]
            }
          },
          %{}
        ]
      }
    }
  end

  defp board(items, more?, cursor) do
    %{
      "repositoryOwner" => %{
        "projectV2" =>
          Map.put(project(), "items", %{
            "pageInfo" => %{"hasNextPage" => more?, "endCursor" => cursor},
            "nodes" => items
          })
      }
    }
  end

  defp issue_item do
    named = fn value, name -> Map.put(value, "field", %{"name" => name}) end

    %{
      "id" => "PVTI_7",
      "content" => %{
        "__typename" => "Issue",
        "number" => 7,
        "title" => "Rate limits",
        "url" => "u",
        "state" => "OPEN",
        "repository" => %{"nameWithOwner" => "acme/widgets"}
      },
      "fieldValues" => %{
        "nodes" => [
          %{"__typename" => "ProjectV2ItemFieldTextValue", "text" => "Rate limits"},
          named.(%{"date" => "2026-11-02"}, "Target date"),
          named.(%{"name" => "Doing"}, "Status"),
          named.(%{"title" => "Sprint 1"}, "Sprint"),
          named.(%{"number" => 3}, "Points"),
          %{"__typename" => "ProjectV2ItemFieldLabelValue"}
        ]
      }
    }
  end

  defp draft_item do
    %{
      "id" => "PVTI_d",
      "content" => %{"__typename" => "DraftIssue", "title" => "Idea"},
      "fieldValues" => %{"nodes" => []}
    }
  end
end
