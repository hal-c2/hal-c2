defmodule HalC2.Steps.SourceControl.PullRequestActions do
  @moduledoc """
  Steps for `features/source-control/pull-request-actions.feature`. GitHub is the fake
  `gh`: a Given reshapes pull request 42 as GitHub reports it (and reads it back through
  `pullRequests.detail`), a When runs the action over the WebSocket, and a Then checks
  what the node asked of GitHub. The fake keeps no state, so the host-side effect of an
  action is the `gh` call that makes it.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.SourceControl.Shared
  alias HalC2.Test.Node.World

  @repository "acme/shop"
  @sha Shared.pr_sha()

  # --- the pull request ----------------------------------------------------------------

  step "the open pull request {int}", %{args: [number]} = context do
    Shared.open_pull_request(context, number)
  end

  step "the user has write access to {string}", %{args: [@repository]} = context do
    context |> Map.put(:permission, "WRITE") |> Shared.answer_pr()
  end

  step "the user has only read access to {string}", %{args: [@repository]} = context do
    context |> Map.put(:permission, "READ") |> Shared.answer_pr()
  end

  step "GitHub does not report whether the user may close pull request {int}",
       %{args: [number]} = context do
    assert number == context.pr_number
    context |> Map.put(:permission, "READ") |> Shared.reshape_pr(%{"viewerCanUpdate" => nil})
  end

  # "is a draft" and "is closed" set the pull request up before an action, and after
  # one they check that the action asked GitHub for it.
  step "pull request {int} is a draft", %{args: [number]} = context do
    if context.acted do
      acted!(context, number, ["pr", "ready", "#{number}"], ["--undo"])
      context
    else
      context = Shared.reshape_pr(context, %{"isDraft" => true})
      assert Shared.pr_detail!(context)["isDraft"] == true
      context
    end
  end

  step "pull request {int} is closed", %{args: [number]} = context do
    if context.acted do
      acted!(context, number, ["pr", "close", "#{number}"])
      context
    else
      context =
        Shared.reshape_pr(context, %{"state" => "CLOSED", "closedAt" => "2026-09-20T00:00:00Z"})

      assert Shared.pr_detail!(context)["state"] == "closed"
      context
    end
  end

  step "pull request {int} is behind its base", %{args: [number]} = context do
    assert number == context.pr_number

    context =
      Shared.reshape_pr(context, %{
        "baseRef" => %{"compare" => %{"behindBy" => 3}},
        "viewerCanUpdateBranch" => true
      })

    assert %{"baseComparison" => "behind", "behindBy" => 3} = Shared.pr_detail!(context)
    context
  end

  step "pull request {int} has pending checks", %{args: [number]} = context do
    assert number == context.pr_number

    context =
      Shared.reshape_pr(context, %{"commits" => Shared.pr_commits([%{"status" => "IN_PROGRESS"}])})

    assert [%{"status" => "pending"}] = Shared.pr_detail!(context)["checks"]
    context
  end

  step "auto-merge is enabled on pull request {int}", %{args: [number]} = context do
    assert number == context.pr_number
    context = Shared.reshape_pr(context, %{"autoMergeRequest" => %{"mergeMethod" => "SQUASH"}})
    assert Shared.pr_detail!(context)["autoMergeEnabled"] == true
    context
  end

  step "pull request {int} has merged", %{args: [number]} = context do
    assert number == context.pr_number

    context =
      Shared.reshape_pr(context, %{
        "state" => "MERGED",
        "mergedAt" => "2026-09-20T00:00:00Z",
        "closedAt" => "2026-09-20T00:00:00Z"
      })

    assert Shared.pr_detail!(context)["state"] == "merged"
    context
  end

  step "pull request {int} comes from a fork and its workflows wait for approval",
       %{args: [number]} = context do
    assert number == context.pr_number

    context =
      context
      |> World.cli_rules([
        %{
          "args" => ["pr list", "--head feature/#{number}"],
          "stdout" => [
            %{
              "number" => number,
              "headRefOid" => @sha,
              "isCrossRepository" => true,
              "headRepositoryOwner" => %{"login" => "forker"}
            }
          ]
        },
        %{
          "args" => ["run list", "--commit #{@sha}", "--status action_required"],
          "stdout" => [
            %{
              "databaseId" => 991,
              "workflowName" => "CI",
              "url" => "https://github.com/#{@repository}/actions/runs/991"
            }
          ]
        },
        %{"args" => ["--method POST", "actions/runs/991/approve"], "stdout" => ""}
      ])
      |> Shared.reshape_pr(%{
        "isCrossRepository" => true,
        "headRepositoryOwner" => %{"login" => "forker"}
      })

    detail = Shared.pr_detail!(context)
    assert detail["workflowApprovalsRequired"] == 1

    assert Enum.any?(
             detail["checks"],
             &(&1["name"] == "CI" and &1["status"] == "action-required")
           )

    context
  end

  step "pull request {int} was opened by {string}", %{args: [number, author]} = context do
    assert number == context.pr_number

    context
    |> Shared.reshape_pr(%{"author" => %{"login" => author, "avatarUrl" => nil}})
    |> World.cli_rules([
      %{
        "args" => ["api graphql"],
        "stdin" => ["assignableUsers"],
        "stdout" => %{
          "data" => %{
            "repository" => %{
              "assignableUsers" => %{
                "pageInfo" => %{"hasNextPage" => false},
                "nodes" => [
                  %{"login" => author, "name" => "The Octocat", "avatarUrl" => nil},
                  %{"login" => "octopus", "name" => "Octo Pus", "avatarUrl" => nil},
                  %{"login" => "hubot", "name" => "Hubot", "avatarUrl" => nil}
                ]
              },
              "pullRequest" => %{
                "author" => %{"login" => author},
                "reviewRequests" => %{"nodes" => []}
              }
            }
          }
        }
      }
    ])
  end

  step "pull request {int} has the label {string}", %{args: [number, label]} = context do
    assert number == context.pr_number

    context =
      context
      |> World.cli_rules([
        %{"args" => ["--method POST", "issues/#{number}/labels"], "stdout" => "[]"},
        %{"args" => ["--method DELETE", "issues/#{number}/labels/"], "stdout" => ""},
        %{
          "args" => ["api graphql"],
          "stdin" => ["orderBy: { field: NAME"],
          "stdout" => %{
            "data" => %{
              "repository" => %{
                "labels" => %{
                  "pageInfo" => %{"hasNextPage" => false},
                  "nodes" => [
                    %{"name" => "bug", "color" => "d73a4a", "description" => nil},
                    %{"name" => "tax", "color" => "0e8a16", "description" => nil}
                  ]
                },
                "pullRequest" => %{"labels" => %{"nodes" => [%{"name" => label}]}}
              }
            }
          }
        }
      ])

    {{:ok, %{"candidates" => candidates}}, context} =
      World.call(context, "pullRequests.labelCandidates", Shared.pr_ref(context))

    assert [^label] = for(%{"isApplied" => true, "name" => name} <- candidates, do: name)
    context
  end

  # --- actions ---------------------------------------------------------------------------

  step ~r/^the user merges pull request (?<number>\d+) with the (?<method>merge|squash|rebase) method$/,
       %{args: [number, method]} = context do
    act(context, number, "merge", %{"mergeMethod" => method})
  end

  step "the user marks it ready for review", context do
    act(context, context.pr_number, "ready")
  end

  step "the user returns pull request {int} to draft", %{args: [number]} = context do
    act(context, number, "draft")
  end

  step "the user closes pull request {int}", %{args: [number]} = context do
    act(context, number, "close")
  end

  step "the user reopens it", context do
    act(context, context.pr_number, "reopen")
  end

  step ~r/^the user updates its branch by (?<method>merge|rebase)$/,
       %{args: [method]} = context do
    context
    |> Map.put(:update_method, method)
    |> act(context.pr_number, "update-branch", %{"updateMethod" => method})
  end

  step "the user enables auto-merge", context do
    act(context, context.pr_number, "enable-auto-merge")
  end

  step "the user disables auto-merge", context do
    act(context, context.pr_number, "disable-auto-merge")
  end

  step "the user reverts it", context do
    context
    |> World.cli_rules([
      %{
        "args" => ["api graphql"],
        "stdin" => ["revertPullRequest"],
        "stdout" => %{
          "data" => %{"revertPullRequest" => %{"revertPullRequest" => %{"id" => "PR_revert"}}}
        }
      }
    ])
    |> act(context.pr_number, "revert")
  end

  step "the user approves its workflows", context do
    act(context, context.pr_number, "approve-workflows")
  end

  step ~r/^the user tries to (?<action>merge|revert|enable auto-merge on) pull request (?<number>\d+)$/,
       %{args: [action, number]} = context do
    action = %{"enable auto-merge on" => "enable-auto-merge"}[action] || action
    act(context, number, action)
  end

  step "the user looks at its actions", context do
    Map.put(context, :viewer, Shared.pr_detail!(context)["viewerPermissions"])
  end

  step "the user asks {string} and the team {string} to review pull request {int}",
       %{args: [user, team, number]} = context do
    context
    |> review_rule(number)
    |> request_reviews(number, [
      %{"kind" => "user", "id" => user},
      %{"kind" => "team", "id" => team |> String.split("/") |> List.last()}
    ])
  end

  step "the user asks {string} to review pull request {int}", %{args: [user, number]} = context do
    context
    |> review_rule(number)
    |> request_reviews(number, [%{"kind" => "user", "id" => user}])
  end

  step "the user searches reviewers for {string}", %{args: [query]} = context do
    {{:ok, %{"candidates" => candidates}}, context} =
      World.call(context, "pullRequests.reviewerCandidates", Shared.pr_ref(context))

    # The picker narrows what arrived by login or name, as `PullRequestReviewerPicker` does.
    needle = String.downcase(query)

    suggested =
      Enum.filter(candidates, fn c ->
        String.contains?(String.downcase(c["login"]), needle) or
          String.contains?(String.downcase(c["name"] || ""), needle)
      end)

    Map.put(context, :suggested, suggested)
  end

  step "the user adds {string} and removes {string}", %{args: [added, removed]} = context do
    context
    |> set_labels([added], true)
    |> set_labels([removed], false)
  end

  step "the user adds the label {string} to pull request {int}",
       %{args: [label, number]} = context do
    assert number == context.pr_number
    set_labels(context, [label], true)
  end

  # --- outcomes --------------------------------------------------------------------------

  step ~r/^pull request (?<number>\d+) is merged by (?<method>merge|squash|rebase)$/,
       %{args: [number, method]} = context do
    acted!(context, number, ["pr", "merge", number], ["--#{method}"])
    context
  end

  step "pull request {int} is no longer a draft", %{args: [number]} = context do
    call = acted!(context, number, ["pr", "ready", "#{number}"])
    refute "--undo" in call["args"]
    context
  end

  step "pull request {int} is open", %{args: [number]} = context do
    acted!(context, number, ["pr", "reopen", "#{number}"])
    context
  end

  step "pull request {int} is up to date with its base", %{args: [number]} = context do
    call = acted!(context, number, ["pr", "update-branch", "#{number}"])
    assert "--rebase" in call["args"] == (context.update_method == "rebase")
    context
  end

  step "GitHub will merge pull request {int} once it is ready", %{args: [number]} = context do
    acted!(context, number, ["pr", "merge", "#{number}"], ["--auto", "--merge"])
    context
  end

  step "pull request {int} will not be merged by itself", %{args: [number]} = context do
    acted!(context, number, ["pr", "merge", "#{number}"], ["--disable-auto"])
    context
  end

  step "a new pull request that reverts {int} is opened", %{args: [number]} = context do
    assert number == context.pr_number
    assert {:ok, _} = context.reply

    assert [call] =
             context
             |> World.cli_calls("api graphql")
             |> Enum.filter(&(&1["stdin"] =~ "revertPullRequest"))

    assert JSON.decode!(call["stdin"])["variables"] == %{"pullRequestId" => Shared.pr_node_id()}
    context
  end

  step "the workflows start", context do
    assert {:ok, _} = context.reply

    assert [%{"args" => args}] = World.cli_calls(context, "actions/runs/991/approve")
    assert ["--method", "POST"] -- args == []
    context
  end

  step "closing is offered", context do
    assert "close" in context.viewer["actions"]
    context
  end

  step "both are listed as requested reviewers", context do
    assert {:ok, _} = context.reply

    assert [call] = World.cli_calls(context, "requested_reviewers")
    assert "POST" in call["args"]

    assert JSON.decode!(call["stdin"]) == %{
             "reviewers" => ["hubot"],
             "team_reviewers" => ["core"]
           }

    context
  end

  step "{string} is not suggested", %{args: [login]} = context do
    assert context.suggested != [], "nothing matched the search"
    refute Enum.any?(context.suggested, &(&1["login"] == login))
    context
  end

  step "pull request {int} has only the label {string}", %{args: [number, label]} = context do
    assert number == context.pr_number
    assert {:ok, _} = context.reply

    assert [added] =
             World.cli_calls(context, "--method POST repos/acme/shop/issues/#{number}/labels")

    assert JSON.decode!(added["stdin"]) == %{"labels" => [label]}

    removed = World.cli_calls(context, "--method DELETE repos/acme/shop/issues/#{number}/labels/")
    assert [%{"args" => args}] = removed
    assert List.last(args) == "repos/acme/shop/issues/#{number}/labels/bug"
    context
  end

  # --- helpers ---------------------------------------------------------------------------

  defp act(context, number, action, extra \\ %{}) do
    number = if is_binary(number), do: String.to_integer(number), else: number
    assert number == context.pr_number

    {reply, context} =
      World.call(
        context,
        "pullRequests.runAction",
        Shared.pr_ref(context) |> Map.put("action", action) |> Map.merge(extra)
      )

    Map.merge(context, %{reply: reply, acted: true})
  end

  # The action succeeded and asked GitHub once with `args` (in order) and `flags`.
  defp acted!(context, number, args, flags \\ []) do
    assert "#{number}" == "#{context.pr_number}"
    assert {:ok, _} = context.reply

    calls =
      context
      |> World.cli_calls(Enum.join(Enum.take(args, 2), " "))
      |> Enum.filter(&(Enum.take(&1["args"], 3) == args))

    assert [call] = calls
    assert Enum.slice(call["args"], 3, 2) == ["--repo", "github.com/#{@repository}"]
    assert flags -- call["args"] == [], "#{inspect(call["args"])} lacks #{inspect(flags)}"
    call
  end

  defp review_rule(context, number) do
    World.cli_rules(context, [
      %{"args" => ["--method POST", "pulls/#{number}/requested_reviewers"], "stdout" => "{}"}
    ])
  end

  defp request_reviews(context, number, reviewers) do
    assert number == context.pr_number

    {reply, context} =
      World.call(
        context,
        "pullRequests.requestReviewers",
        Shared.pr_ref(context) |> Map.merge(%{"reviewers" => reviewers, "requested" => true})
      )

    Map.put(context, :reply, reply)
  end

  defp set_labels(context, labels, applied) do
    {reply, context} =
      World.call(
        context,
        "pullRequests.setLabels",
        Shared.pr_ref(context) |> Map.merge(%{"labels" => labels, "applied" => applied})
      )

    # The first refusal is what the user is told; a later change must not hide it.
    case context[:reply] do
      {:error, _, _} -> context
      _ -> Map.put(context, :reply, reply)
    end
  end
end
