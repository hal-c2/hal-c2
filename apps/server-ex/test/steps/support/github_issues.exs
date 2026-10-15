defmodule HalC2.Steps.Support.GitHubIssues do
  @moduledoc """
  A fake GitHub for issues, milestones and boards (`HalC2.Issues`), as rules for the
  fake `gh` (`test/support/fake_gh.py`, through `World.cli_rules/2`) and checks of
  what it was asked (`World.cli_calls/2`). Shared by the step files of
  `features/plugins/host-issues.feature` and `features/planning/`.

  Node ids are derived from what they name, so a check can tell which issue, board
  item or field a change was about: issue `#n` is `I_n`, its item on a board
  `PVTI_n`, a board field `PVTF_<name>`, and a board `PVT_<owner>_<number>`.
  """

  import ExUnit.Assertions

  alias HalC2.Test.Mc.World

  @doc "Issue `#number`'s node id."
  def issue_id(number), do: "I_#{number}"

  @doc "The node id of issue `#number`'s item on a board."
  def item_id(number), do: "PVTI_#{number}"

  @doc "The node id of the board field `name`."
  def field_id(name), do: "PVTF_" <> String.replace(name, " ", "_")

  @doc """
  An issue of `repository` as GitHub's GraphQL answers it. `fields` override the
  defaults; refs such as `"parent"`, `"subIssues"`, `"blockedBy"` may be given as
  numbers in the same repository and closing pull requests as numbers in
  `"pullRequests"`.
  """
  def issue(repository, number, fields \\ %{}) do
    {refs, fields} = Map.split(fields, ~w(parent subIssues blockedBy blocking pullRequests))
    ref = fn n -> %{"number" => n, "repository" => %{"nameWithOwner" => repository}} end
    connection = fn key -> %{"nodes" => Enum.map(refs[key] || [], ref)} end

    Map.merge(
      %{
        "number" => number,
        "title" => "Issue #{number}",
        "body" => "",
        "state" => "OPEN",
        "stateReason" => nil,
        "url" => "https://github.com/#{repository}/issues/#{number}",
        "createdAt" => "2026-10-01T00:00:00Z",
        "updatedAt" => "2026-10-02T00:00:00Z",
        "closedAt" => nil,
        "repository" => %{"nameWithOwner" => repository},
        "author" => %{"login" => "monalisa"},
        "assignees" => %{"nodes" => []},
        "labels" => %{"nodes" => []},
        "milestone" => nil,
        "issueType" => nil,
        "parent" => refs["parent"] && ref.(refs["parent"]),
        "subIssues" => connection.("subIssues"),
        "subIssuesSummary" => %{"total" => length(refs["subIssues"] || []), "completed" => 0},
        "blockedBy" => connection.("blockedBy"),
        "blocking" => connection.("blocking"),
        "closedByPullRequestsReferences" => %{
          "nodes" =>
            for n <- refs["pullRequests"] || [] do
              %{
                "number" => n,
                "title" => "PR #{n}",
                "url" => "https://github.com/#{repository}/pull/#{n}",
                "state" => "OPEN",
                "repository" => %{"nameWithOwner" => repository}
              }
            end
        }
      },
      fields
    )
  end

  @doc """
  GitHub answering for `issues` (GraphQL issue nodes, see `issue/3`): their listing,
  each one read, and the changes `HalC2.Issues` makes to them, which it accepts.
  A new issue is `#13`. With `more`, every page of the listing says another follows.
  """
  def answers(context, repository, issues, more \\ false) do
    numbers = Enum.uniq(Enum.map(issues, & &1["number"]) ++ [5, 7, 8, 9, 12, 13])
    new = Enum.find(issues, &(&1["number"] == 13)) || issue(repository, 13)

    context
    |> World.cli_rules(
      [
        graphql(["issues(first: $first"], %{
          "repository" => %{
            "issues" => %{
              "pageInfo" => %{"hasNextPage" => more, "endCursor" => more && "next"},
              "nodes" => issues
            }
          }
        }),
        rest(["--method POST", "repos/#{repository}/issues --input"], %{"number" => 13}),
        graphql(["{ ...IssueFields", ~s("number":13)], %{"repository" => %{"issue" => new}})
      ] ++
        for issue <- issues do
          graphql(["{ ...IssueFields", ~s("number":#{issue["number"]})], %{
            "repository" => %{"issue" => issue}
          })
        end ++
        for n <- numbers do
          rest(["--method PATCH", "repos/#{repository}/issues/#{n} "], %{"number" => n})
        end ++
        for n <- numbers do
          rest(["repos/#{repository}/issues/#{n}/comments"], %{
            "html_url" => "https://github.com/#{repository}/issues/#{n}#issuecomment-1"
          })
        end ++
        for a <- numbers, b <- numbers, a != b do
          graphql(["other: repository(", ~s("number":#{a}), ~s("other":#{b})], %{
            "issue" => %{"issue" => %{"id" => issue_id(a)}},
            "other" => %{"issue" => %{"id" => issue_id(b)}}
          })
        end ++
        for mutation <- ~w(addSubIssue removeSubIssue addBlockedBy removeBlockedBy) do
          graphql([mutation <> "(input"], %{mutation => %{"clientMutationId" => nil}})
        end
    )
  end

  @doc """
  GitHub listing `issues` (see `answers/4`) from now on, leaving how it answers changes
  as it was.
  """
  def lists(context, repository, issues) do
    World.cli_rules(context, [
      graphql(["issues(first: $first"], %{
        "repository" => %{
          "issues" => %{
            "pageInfo" => %{"hasNextPage" => false, "endCursor" => false},
            "nodes" => issues
          }
        }
      })
      | for issue <- issues do
          graphql(["{ ...IssueFields", ~s("number":#{issue["number"]})], %{
            "repository" => %{"issue" => issue}
          })
        end
    ])
  end

  @doc """
  The board `owner/number` with `fields` (names; "Status" is a single select with
  "Todo", "Doing" and "Done", a name ending in "date" a date, anything else text)
  and `items` (`%{"number", "repository", "fields" => %{name => value}}`). With
  `more`, every page of items says another follows.
  """
  def board(context, board, fields, items, more \\ false) do
    [owner, number] = String.split(board, "/")
    number = String.to_integer(number)

    field_nodes =
      for name <- fields do
        cond do
          name == "Status" ->
            %{
              "id" => field_id(name),
              "name" => name,
              "dataType" => "SINGLE_SELECT",
              "options" => for(o <- ~w(Todo Doing Done), do: %{"id" => "OPT_" <> o, "name" => o})
            }

          String.ends_with?(String.downcase(name), "date") ->
            %{"id" => field_id(name), "name" => name, "dataType" => "DATE"}

          true ->
            %{"id" => field_id(name), "name" => name, "dataType" => "TEXT"}
        end
      end

    item_nodes =
      for item <- items do
        %{
          "id" => item_id(item["number"]),
          "content" => %{
            "__typename" => "Issue",
            "number" => item["number"],
            "title" => "Issue #{item["number"]}",
            "url" => "https://github.com/#{item["repository"]}/issues/#{item["number"]}",
            "state" => "OPEN",
            "repository" => %{"nameWithOwner" => item["repository"]}
          },
          "fieldValues" => %{
            "nodes" =>
              for {name, value} <- item["fields"] || %{} do
                key =
                  if String.ends_with?(String.downcase(name), "date"), do: "date", else: "text"

                %{key => value, "field" => %{"name" => name}}
              end
          }
        }
      end

    project = %{
      "id" => "PVT_#{owner}_#{number}",
      "title" => "Board #{number}",
      "url" => "https://github.com/orgs/#{owner}/projects/#{number}",
      "fields" => %{"nodes" => field_nodes},
      "items" => %{
        "pageInfo" => %{"hasNextPage" => more, "endCursor" => more && "next"},
        "nodes" => item_nodes
      }
    }

    World.cli_rules(context, [
      graphql(["items(first: $first", ~s("number":#{number})], %{
        "repositoryOwner" => %{"projectV2" => project}
      }),
      graphql(["{ id fields(first: 50)", ~s("number":#{number})], %{
        "repositoryOwner" => %{"projectV2" => Map.drop(project, ["items"])}
      }),
      graphql(["issueOrPullRequest(number: $content)"], %{
        "repositoryOwner" => %{"projectV2" => %{"id" => project["id"]}},
        "repository" => %{"issueOrPullRequest" => %{"id" => issue_id(0)}}
      }),
      graphql(["addProjectV2ItemById"], %{
        "addProjectV2ItemById" => %{"item" => %{"id" => item_id(0)}}
      }),
      graphql(["updateProjectV2ItemFieldValue"], %{
        "updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => item_id(0)}}
      }),
      graphql(["clearProjectV2ItemFieldValue"], %{
        "clearProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => item_id(0)}}
      })
    ])
  end

  @doc """
  `owner`'s boards, as `%{"number", "title", "closed"}` maps, listed in one page.
  """
  def boards(context, owner, boards) do
    nodes =
      for board <- boards do
        Map.merge(
          %{"url" => "https://github.com/orgs/#{owner}/projects/#{board["number"]}"},
          board
        )
      end

    World.cli_rules(context, [
      graphql(["projectsV2(first: 100", ~s("owner":"#{owner}")], %{
        "repositoryOwner" => %{
          "projectsV2" => %{
            "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil},
            "nodes" => nodes
          }
        }
      })
    ])
  end

  @doc "gh's login lacks the `project` scope: every board query is refused as GitHub refuses it."
  def without_project_scope(context) do
    World.cli_rules(
      context,
      for field <- ~w(projectV2 projectsV2) do
        %{
          "args" => ["api graphql"],
          "stdin" => [field],
          "exit" => 1,
          "stderr" =>
            "gh: Your token has not been granted the required scopes to execute this query. " <>
              "The '#{field}' field requires one of the following scopes: ['read:project'], " <>
              "but your token has only been granted the: ['gist', 'read:org', 'repo'] scopes.\n"
        }
      end
    )
  end

  @doc "The REST calls with `method` to a path ending in `suffix`, with their decoded input."
  def rest_calls(context, method, suffix) do
    for call <- World.cli_calls(context, "--method #{method}"),
        Enum.any?(call["args"], &String.ends_with?(&1, suffix)),
        do: decode(call["stdin"])
  end

  @doc "The variables of the GraphQL calls whose document contains `fragment`."
  def graphql_calls(context, fragment) do
    for call <- World.cli_calls(context, "api graphql"),
        %{"query" => query} = body = decode(call["stdin"]),
        String.contains?(query, fragment),
        do: body["variables"]
  end

  @doc "Asserts GitHub was asked to change issue `#number` with a PATCH holding `expected`."
  def assert_patched(context, number, expected) do
    changes = rest_calls(context, "PATCH", "/issues/#{number}")

    assert Enum.any?(changes, &(Map.take(&1, Map.keys(expected)) == expected)),
           "GitHub was not asked to change ##{number} with #{inspect(expected)}: #{inspect(changes)}"

    context
  end

  @doc "Asserts the GraphQL `mutation` was asked for issue `#number` and the other issue `#other`."
  def assert_related(context, mutation, number, other) do
    asked = graphql_calls(context, mutation <> "(input")

    assert %{"issue" => issue_id(number), "other" => issue_id(other)} in asked,
           "GitHub was not asked to #{mutation} ##{number} and ##{other}: #{inspect(asked)}"

    context
  end

  @doc "Asserts the board field `field` of issue `#number`'s item was asked to become the date `date`."
  def assert_board_date(context, field, number, date) do
    asked = graphql_calls(context, "updateProjectV2ItemFieldValue")

    expected = %{
      "item" => item_id(number),
      "field" => field_id(field),
      "value" => %{"date" => date}
    }

    assert Enum.any?(asked, &(Map.take(&1, ~w(item field value)) == expected)),
           "GitHub was not asked to set #{field} of ##{number} to #{date}: #{inspect(asked)}"

    context
  end

  defp graphql(stdin, data),
    do: %{"args" => ["api graphql"], "stdin" => stdin, "stdout" => %{"data" => data}}

  defp rest(args, answer), do: %{"args" => args, "stdout" => answer}

  defp decode(""), do: %{}
  defp decode(text), do: JSON.decode!(text)
end
