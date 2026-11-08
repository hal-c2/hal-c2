defmodule HalC2.Steps.SourceControl.PullRequestReview do
  @moduledoc """
  Steps for `features/source-control/pull-request-review.feature`. GitHub is the fake
  `gh` (`HalC2.Steps.SourceControl.Shared.open_pull_request/3` for the pull request
  itself); `context.review` holds its conversation (`pr view` and the review-thread
  read) and `context.viewed` the files the user marked viewed, answered afresh on
  each change. A write is checked as the call the MC made to GitHub.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.SourceControl.Shared
  alias HalC2.Test.Mc.World

  @me "monalisa"
  @base "1111111111111111111111111111111111111111"
  @commits [
    "c0ffee0000000000000000000000000000000001",
    "c0ffee0000000000000000000000000000000002"
  ]
  @check_runs %{
    "pending" => %{"status" => "IN_PROGRESS"},
    "action-required" => %{"status" => "COMPLETED", "conclusion" => "ACTION_REQUIRED"},
    "success" => %{"status" => "COMPLETED", "conclusion" => "SUCCESS"},
    "failure" => %{"status" => "COMPLETED", "conclusion" => "FAILURE"},
    "skipped" => %{"status" => "COMPLETED", "conclusion" => "SKIPPED"},
    "neutral" => %{"status" => "COMPLETED", "conclusion" => "NEUTRAL"},
    "cancelled" => %{"status" => "COMPLETED", "conclusion" => "CANCELLED"}
  }

  step "the open pull request {int} by {string}", %{args: [number, author]} = context do
    context
    |> Shared.open_pull_request(number, %{
      "author" => %{"login" => author, "avatarUrl" => nil},
      "labels" => %{"nodes" => [%{"name" => "bug", "color" => "d73a4a"}]},
      "reviewRequests" => %{"nodes" => [%{"requestedReviewer" => %{"login" => "hubot"}}]},
      "baseRef" => %{"compare" => %{"behindBy" => 2}}
    })
    |> Map.merge(%{
      review: %{threads: [thread("T1", "src/cart.ts", 12)], reactions: []},
      viewed: %{}
    })
    |> answer_review()
    |> World.cli_rules([
      %{"args" => ["pr comment #{number}"], "stdout" => ""},
      %{"args" => ["--method POST", "pulls/#{number}/reviews"], "stdout" => "{}"},
      %{
        "args" => ["api graphql"],
        "stdin" => ["addPullRequestReviewThreadReply"],
        "stdout" => ok()
      },
      %{
        "args" => ["api graphql"],
        "stdin" => ["ReviewThread(input: { threadId"],
        "stdout" => ok()
      },
      %{"args" => ["api graphql"], "stdin" => ["Reaction(input: { subjectId"], "stdout" => ok()},
      %{"args" => ["api graphql"], "stdin" => ["FileAsViewed(input"], "stdout" => ok()},
      %{"args" => ["api graphql"], "stdin" => ["updatePullRequest(input"], "stdout" => ok()},
      %{"args" => ["api graphql"], "stdin" => ["updateIssueComment(input"], "stdout" => ok()},
      %{
        "args" => ["api graphql"],
        "stdin" => ["node(id: $subjectId)"],
        "stdout" => %{
          "data" => %{
            "repository" => %{"pullRequest" => %{"id" => Shared.pr_node_id()}},
            "node" => %{"id" => "IC_9", "pullRequest" => %{"id" => Shared.pr_node_id()}}
          }
        }
      }
    ])
  end

  # --- reading -----------------------------------------------------------------------------

  step "the user opens pull request {int}", %{args: [number]} = context do
    assert number == context.pr_number
    Map.put(context, :detail, Shared.pr_detail!(context))
  end

  step "the user sees its title, description, branches, author, labels, reviewers and mergeability",
       context do
    assert %{
             "title" => "Add the tax table",
             "body" => "Adds the tax table.",
             "headBranch" => "feature/42",
             "baseBranch" => "main",
             "author" => %{"login" => "octocat"},
             "labels" => [%{"name" => "bug"}],
             "reviewers" => [%{"login" => "hubot"}],
             "mergeability" => "mergeable"
           } = context.detail

    context
  end

  step "whether its branch is behind the base", context do
    assert %{"baseComparison" => "behind", "behindBy" => 2} = context.detail
    context
  end

  step "the user opens the conversation of pull request {int}", %{args: [number]} = context do
    assert number == context.pr_number
    read_activity(context)
  end

  step "comments, reviews and events are listed in order", context do
    comments = context.activity["comments"]

    assert Enum.map(comments, &{&1["kind"], &1["id"]}) == [
             {"issue-comment", "IC_1"},
             {"review-comment", "RC_T1"},
             {"review", "R_1"},
             {"review", "R_2"}
           ]

    times = Enum.map(comments, & &1["createdAt"])
    assert times == Enum.sort(times)
    # A dismissal is shown as its own event, carrying why the review was dismissed.
    assert %{"reviewState" => "DISMISSED", "body" => "Outdated after the rebase"} =
             List.last(comments)

    context
  end

  step "a review thread on pull request {int} refers to code that has since changed",
       %{args: [number]} = context do
    assert number == context.pr_number

    context
    |> update_in(
      [:review, :threads],
      &(&1 ++ [thread("T2", "src/tax.ts", 3, %{"isOutdated" => true})])
    )
    |> answer_review()
  end

  step "the user reads the review threads", context do
    read_activity(context)
  end

  step "that thread is listed among the outdated ones", context do
    outdated = for t <- context.activity["reviewThreads"], t["isOutdated"], do: t["id"]
    current = for t <- context.activity["reviewThreads"], not t["isOutdated"], do: t["id"]
    assert {outdated, current} == {["T2"], ["T1"]}
    context
  end

  step ~r/^a check on pull request (?<number>\d+) is (?<state>[a-z-]+)$/,
       %{args: [number, state]} = context do
    assert String.to_integer(number) == context.pr_number
    run = Map.fetch!(@check_runs, state)

    context
    |> Map.put(:check_state, state)
    |> Shared.reshape_pr(%{"commits" => Shared.pr_commits([run])})
  end

  step "the user reads the checks of pull request {int}", %{args: [number]} = context do
    assert number == context.pr_number
    {reply, context} = World.call(context, "pullRequests.checks", Shared.pr_ref(context))

    context
    |> Map.put(:reply, reply)
    |> then(fn context ->
      case reply do
        {:ok, %{"checks" => checks}} -> Map.put(context, :checks, checks)
        _ -> context
      end
    end)
  end

  step ~r/^that check is reported as (?<state>[a-z-]+)$/, %{args: [state]} = context do
    assert state == context.check_state

    assert {:ok, %{"state" => "open", "checks" => [%{"name" => "build", "status" => ^state}]}} =
             context.reply

    context
  end

  # --- writing -----------------------------------------------------------------------------

  step "the user comments {string} on pull request {int}", %{args: [body, number]} = context do
    assert number == context.pr_number
    call(context, "pullRequests.comment", %{"body" => body})
  end

  step "the comment appears in the conversation", context do
    assert {:ok, _} = context.reply

    assert [%{"args" => args, "stdin" => "Looks good"}] =
             World.cli_calls(context, "pr comment 42")

    assert ["--body-file", "-"] -- args == []
    context
  end

  step "the user comments with only spaces on pull request {int}", %{args: [number]} = context do
    assert number == context.pr_number
    call(context, "pullRequests.comment", %{"body" => "   "})
  end

  step "the user commented {string} on pull request {int}", %{args: [body, number]} = context do
    assert number == context.pr_number
    context = context |> put_in([:review, :comment], body) |> answer_review() |> read_activity()
    assert %{"id" => "IC_9", "author" => %{"login" => @me}} = mine = comment(context, body)
    Map.put(context, :mine, mine)
  end

  step "the user edits the comment to {string}", %{args: [body]} = context do
    call(context, "pullRequests.updateComment", %{
      "commentId" => context.mine["id"],
      "kind" => context.mine["kind"],
      "body" => body
    })
  end

  step "the comment reads {string}", %{args: [body]} = context do
    assert {:ok, _} = context.reply
    assert %{"commentId" => "IC_9", "body" => ^body} = mutation(context, "updateIssueComment")
    context
  end

  step "the user may edit pull request {int}", %{args: [number]} = context do
    assert number == context.pr_number
    detail = Shared.pr_detail!(context)
    assert detail["capabilities"]["edit"]["changeRequest"] == true
    assert "draft" in detail["viewerPermissions"]["actions"]
    context
  end

  step "the user changes its title to {string}", %{args: [title]} = context do
    context |> Map.put(:title, title) |> call("pullRequests.update", %{"title" => title})
  end

  step "pull request {int} has the new title", %{args: [number]} = context do
    assert number == context.pr_number
    assert {:ok, _} = context.reply
    variables = mutation(context, "updatePullRequest")
    assert variables == %{"pullRequestId" => Shared.pr_node_id(), "title" => context.title}
    context
  end

  step "the user saves the title and description of pull request {int} unchanged",
       %{args: [number]} = context do
    assert number == context.pr_number
    # The editor sends only what changed: nothing here.
    call(context, "pullRequests.update", %{})
  end

  step "the user left a comment on line {int} of {string} in pull request {int}",
       %{args: [line, path, number]} = context do
    assert number == context.pr_number

    Map.put(context, :line_comments, [
      %{
        "path" => path,
        "body" => "Round after the tax.",
        "position" => %{"kind" => "added", "newLine" => line}
      }
    ])
  end

  step "pull request {int} is the user's own", %{args: [number]} = context do
    assert number == context.pr_number
    Shared.reshape_pr(context, %{"viewerDidAuthor" => true})
  end

  step ~r/^the user submits the review as (?<verdict>comment|approve|request changes)$/,
       %{args: [verdict]} = context do
    verdict = String.replace(verdict, " ", "-")

    context
    |> Map.put(:verdict, verdict)
    |> call("pullRequests.submitReview", %{
      "verdict" => verdict,
      "body" => "",
      "comments" => context.line_comments
    })
  end

  step "the review and its line comment arrive on GitHub together", context do
    assert {:ok, _} = context.reply
    assert [call] = World.cli_calls(context, "pulls/42/reviews")

    event = %{
      "comment" => "COMMENT",
      "approve" => "APPROVE",
      "request-changes" => "REQUEST_CHANGES"
    }

    assert JSON.decode!(call["stdin"]) == %{
             "event" => event[context.verdict],
             "body" => "",
             "comments" => [
               %{
                 "path" => "src/cart.ts",
                 "line" => 12,
                 "side" => "RIGHT",
                 "body" => "Round after the tax."
               }
             ]
           }

    context
  end

  step "the user submits a comment review with no summary and no line comments", context do
    call(context, "pullRequests.submitReview", %{
      "verdict" => "comment",
      "body" => "",
      "comments" => []
    })
  end

  step "a review thread on line {int} of {string}", %{args: [line, path]} = context do
    context = read_activity(context)

    assert %{"id" => id} =
             Enum.find(
               context.activity["reviewThreads"],
               &(&1["path"] == path and &1["line"] == line)
             )

    Map.put(context, :thread_id, id)
  end

  step "the user replies {string}", %{args: [body]} = context do
    context
    |> Map.put(:reply_body, body)
    |> call("pullRequests.replyToThread", %{"threadId" => context.thread_id, "body" => body})
  end

  step "the reply is added to that thread", context do
    assert {:ok, _} = context.reply

    assert mutation(context, "addPullRequestReviewThreadReply") == %{
             "threadId" => context.thread_id,
             "body" => context.reply_body
           }

    context
  end

  step ~r/^an? (?<state>unresolved|resolved) review thread$/, %{args: [state]} = context do
    context =
      context
      |> update_in([:review, :threads], fn [t | rest] ->
        [%{t | "isResolved" => state == "resolved"} | rest]
      end)
      |> answer_review()
      |> read_activity()

    [thread | _] = context.activity["reviewThreads"]
    assert thread["isResolved"] == (state == "resolved")
    Map.put(context, :thread_id, thread["id"])
  end

  step ~r/^the user (?<verb>resolves|unresolves) it$/, %{args: [verb]} = context do
    call(context, "pullRequests.setThreadResolution", %{
      "threadId" => context.thread_id,
      "resolved" => verb == "resolves"
    })
  end

  step "the thread is resolved", context do
    assert_resolution(context, "resolveReviewThread")
  end

  step "the thread is open again", context do
    assert_resolution(context, "unresolveReviewThread")
  end

  step "the user reacted with a heart to the description of pull request {int}",
       %{args: [number]} = context do
    assert number == context.pr_number

    context =
      context
      |> put_in([:review, :reactions], [
        %{
          "content" => "HEART",
          "viewerHasReacted" => true,
          "reactors" => %{
            "totalCount" => 2,
            "nodes" => [%{"login" => @me}, %{"login" => "hubot"}]
          }
        }
      ])
      |> answer_review()
      |> read_activity()

    assert [%{"content" => "heart", "count" => 2, "viewerHasReacted" => true}] =
             context.activity["reactions"]

    context
  end

  step "the user reacts with a heart to the description of pull request {int}",
       %{args: [number]} = context do
    assert number == context.pr_number
    toggle_heart(context)
  end

  step "the user reacts with a heart again", context do
    toggle_heart(context)
  end

  step "the heart count goes up by one and includes the user", context do
    assert_reaction(context, "addReaction")
  end

  step "the user's heart is removed", context do
    assert_reaction(context, "removeReaction")
  end

  # --- viewed files ------------------------------------------------------------------------

  step "the user marks {string} viewed in pull request {int}",
       %{args: [path, number]} = context do
    assert number == context.pr_number
    mark(context, path, true)
  end

  step "{string} is marked viewed in pull request {int}", %{args: [path, number]} = context do
    assert number == context.pr_number
    context = context |> put_in([:viewed, path], "VIEWED") |> answer_review()
    assert viewed_state(context, path) == "viewed"
    Map.put(context, :viewed_path, path)
  end

  step "the user marks it not viewed", context do
    mark(context, context.viewed_path, false)
  end

  step ~r/^GitHub records "(?<path>[^"]+)" as (?<state>viewed|not viewed)(?: for the user)?$/,
       %{args: [path, state]} = context do
    assert {:ok, _} = context.reply

    assert [call] =
             context
             |> World.cli_calls("api graphql")
             |> Enum.filter(&(&1["stdin"] =~ "FileAsViewed"))

    %{"query" => query, "variables" => variables} = JSON.decode!(call["stdin"])
    verb = if state == "viewed", do: "markFileAsViewed", else: "unmarkFileAsViewed"
    assert query =~ "f0: #{verb}("
    assert variables == %{"pullRequestId" => Shared.pr_node_id(), "path0" => path}
    context
  end

  # GitHub itself dismisses a viewed mark when the file changes after it.
  step "the author pushes a change to {string}", %{args: [path]} = context do
    context |> put_in([:viewed, path], "DISMISSED") |> answer_review()
  end

  step "the file is reported as changed since it was viewed", context do
    assert viewed_state(context, context.viewed_path) == "dismissed"
    context
  end

  # --- code ----------------------------------------------------------------------------------

  step "pull request {int} changes {int} files", %{args: [number, count]} = context do
    assert number == context.pr_number
    files = for i <- 1..count, do: changed_file(i)

    rules =
      for {page, n} <- Enum.with_index(Enum.chunk_every(files, 100), 1),
          do: %{"args" => ["pulls/#{number}/files?per_page=100&page=#{n}"], "stdout" => page}

    # The same files' viewed marks, a GraphQL page of a hundred at a time.
    viewed_rules =
      files
      |> Enum.map(& &1["filename"])
      |> Enum.chunk_every(100)
      |> Enum.with_index(1)
      |> Enum.map(fn {paths, page} ->
        last? = page * 100 >= count

        %{
          "args" => ["api graphql"],
          "stdin" => [
            "viewerViewedState",
            if(page == 1, do: "\"after\":null", else: "\"after\":\"vc#{page - 1}\"")
          ],
          "stdout" => %{
            "data" => %{
              "repository" => %{
                "pullRequest" => %{
                  "files" => %{
                    "pageInfo" => %{
                      "hasNextPage" => not last?,
                      "endCursor" => if(last?, do: nil, else: "vc#{page}")
                    },
                    "nodes" =>
                      for(path <- paths, do: %{"path" => path, "viewerViewedState" => "VIEWED"})
                  }
                }
              }
            }
          }
        }
      end)

    context
    |> Map.put(:changed_files, files)
    |> World.cli_rules(
      [
        %{
          "args" => ["pr diff #{number}"],
          "exit" => 1,
          "stderr" => "HTTP 406: Sorry, the diff exceeded the maximum number of files (300)."
        }
        | rules
      ] ++ viewed_rules
    )
  end

  step "the user opens its code", context do
    {status, body} = World.http_post(context, "/api/pull-requests/diff", Shared.pr_ref(context))
    context = Map.put(context, :diff_read, {status, body})

    if status == 200 do
      slices =
        case body["nextCursor"] do
          nil -> [body]
          next -> [body | diff_slices(context, %{}, next)]
        end

      Map.put(context, :slices, slices)
    else
      context
    end
  end

  step "the files arrive in slices and every file's line counts are known", context do
    assert length(context.slices) == 5
    assert Enum.all?(Enum.drop(context.slices, -1), &(&1["truncated"] or &1["nextCursor"]))

    counted =
      context.slices
      |> Enum.flat_map(&(patch_counts(&1["patch"]) ++ omitted(&1)))
      |> Enum.reduce(%{}, fn {path, counts}, acc ->
        Map.update(acc, path, counts, &merge_counts(&1, counts))
      end)

    expected =
      for f <- context.changed_files,
          into: %{},
          do: {f["filename"], {f["additions"], f["deletions"]}}

    assert counted == expected
    context
  end

  step "the user scopes the code of pull request {int} to one of its commits",
       %{args: [number]} = context do
    assert number == context.pr_number
    context = read_activity(context)
    assert [_, %{"oid" => commit}] = context.activity["commits"]

    context =
      World.cli_rules(context, [
        %{
          "args" => ["commits/#{commit}?per_page=100&page=1", "--jq"],
          "stdout" => [
            %{
              "filename" => "src/tax.ts",
              "status" => "added",
              "patch" => "@@ -0,0 +1 @@\n+export const rate = 0.2",
              "additions" => 1,
              "deletions" => 0
            }
          ]
        }
      ])

    context
    |> Map.put(:commit, commit)
    |> Map.put(:slices, diff_slices(context, %{"commit" => commit}))
  end

  step "only that commit's changes are shown", context do
    assert [%{"patch" => patch, "nextCursor" => nil}] = context.slices
    assert patch_counts(patch) == [{"src/tax.ts", {1, 0}}]
    assert [_] = World.cli_calls(context, "commits/#{context.commit}")
    assert World.cli_calls(context, "pr diff") == []
    context
  end

  step "the user expands the unchanged lines around a change in {string}",
       %{args: [path]} = context do
    old = context[:expand_old] || "export const total = (items) => sum(items)\n"
    new = context[:expand_new] || "export const total = (items) => round(sum(items))\n"

    context =
      World.cli_rules(context, [
        %{
          "args" => ["repos/acme/shop/pulls/42", "--jq"],
          "stdout" => context[:expand_refs] || "#{@base}\t#{Shared.pr_sha()}\n"
        },
        %{
          "args" => ["pulls/42/files?per_page=100&page=1"],
          "stdout" => [%{"filename" => path, "status" => "modified"}]
        },
        %{"args" => ["contents/#{path}?ref=#{@base}"], "stdout" => old},
        %{"args" => ["contents/#{path}?ref=#{Shared.pr_sha()}"], "stdout" => new}
      ])

    context
    |> Map.put(:sides, {old, new})
    |> call("pullRequests.diffFileContents", %{
      "changeType" => "change",
      "oldPath" => path,
      "newPath" => path
    })
  end

  step "the file's contents on both sides are shown", context do
    {old, new} = context.sides
    assert {:ok, %{"oldContents" => ^old, "newContents" => ^new}} = context.reply
    context
  end

  # --- permissions, dismissals, verdicts ---------------------------------------------------

  step "the user looks at what they may do on pull request {int}", %{args: [number]} = context do
    assert number == context.pr_number
    Map.put(context, :detail, Shared.pr_detail!(context))
  end

  step "commenting, approving and requesting changes are offered", context do
    permissions = context.detail["viewerPermissions"]
    assert permissions["comment"] == true
    assert "approve" in permissions["verdicts"]
    assert "request-changes" in permissions["verdicts"]
    context
  end

  step "the user replies with only spaces", context do
    call(context, "pullRequests.replyToThread", %{
      "threadId" => context.thread_id,
      "body" => "   "
    })
  end

  step "the user edits the comment to only spaces", context do
    call(context, "pullRequests.updateComment", %{
      "commentId" => context.mine["id"],
      "kind" => context.mine["kind"],
      "body" => "   "
    })
  end

  step "the comment still reads {string}", %{args: [body]} = context do
    # Nothing was sent to the host, and the conversation still has the old words.
    assert context
           |> World.cli_calls("api graphql")
           |> Enum.filter(&(JSON.decode!(&1["stdin"])["query"] =~ "updateIssueComment(")) == []

    context = read_activity(context)
    assert comment(context, body)
    context
  end

  step "a review on pull request {int} that was dismissed with the reason {string}",
       %{args: [number, reason]} = context do
    assert number == context.pr_number

    context
    |> Map.put(:dismissal, reason)
    |> put_in([:review, :dismissal], reason)
    |> answer_review()
  end

  step "the review is shown as dismissed with that reason", context do
    assert %{"reviewState" => "DISMISSED", "body" => body} =
             Enum.find(context.activity["comments"], &(&1["id"] == "R_2"))

    assert body == context.dismissal
    context
  end

  step "a bot review on pull request {int} that was dismissed with the reason {string}",
       %{args: [number, reason]} = context do
    assert number == context.pr_number

    context
    |> Map.put(:dismissal, reason)
    |> put_in([:review, :dismissal], reason)
    |> answer_review()
  end

  step "the review's own text is only an HTML comment", context do
    context |> put_in([:review, :dismissed_body], "<!-- bot marker -->") |> answer_review()
  end

  step "the review is shown with the reason {string}", %{args: [reason]} = context do
    assert %{"reviewState" => "DISMISSED", "body" => ^reason} =
             Enum.find(context.activity["comments"], &(&1["id"] == "R_2"))

    context
  end

  step "twelve people reacted with a heart to a comment on pull request {int}",
       %{args: [number]} = context do
    assert number == context.pr_number

    group = %{
      "content" => "HEART",
      "viewerHasReacted" => false,
      "reactors" => %{
        "totalCount" => 12,
        # The MC asks GitHub for ten names at most (`reactors(first: 10)`).
        "nodes" => for(i <- 1..10, do: %{"login" => "user#{i}"})
      }
    }

    context
    |> update_in([:review, :threads], fn [t | rest] ->
      [put_in(t, ["comments", "nodes", Access.at(0), "reactionGroups"], [group]) | rest]
    end)
    |> answer_review()
  end

  step "the heart shows a count of 12", context do
    assert %{"content" => "heart", "count" => 12} = heart(context)
    context
  end

  step "at most ten of the people who reacted are named", context do
    assert length(heart(context)["actors"]) <= 10
    context
  end

  defp heart(context) do
    %{"reactions" => reactions} =
      Enum.find(context.activity["comments"], &(&1["id"] == "RC_T1"))

    Enum.find(reactions, &(&1["content"] == "heart"))
  end

  step "the host reports no review decision for pull request {int}",
       %{args: [number]} = context do
    assert number == context.pr_number
    Map.put(context, :latest_reviews, [])
  end

  step ~r/^"(?<login>[^"]+)" last approved it and nobody asked for changes$/,
       %{args: [login]} = context do
    answer_summary(context, [%{"author" => %{"login" => login}, "state" => "APPROVED"}])
  end

  step ~r/^"(?<approver>[^"]+)" last approved it and "(?<changer>[^"]+)" last asked for changes$/,
       %{args: [approver, changer]} = context do
    answer_summary(context, [
      %{"author" => %{"login" => approver}, "state" => "APPROVED"},
      %{"author" => %{"login" => changer}, "state" => "CHANGES_REQUESTED"}
    ])
  end

  # `gh pr view --json <detail fields>`, as `pullRequests.summary` reads it.
  defp answer_summary(context, latest_reviews) do
    number = context.pr_number

    World.cli_rules(context, [
      %{
        "args" => ["pr view #{number}", "latestReviews,labels,statusCheckRollup,body"],
        "stdout" => %{
          "number" => number,
          "title" => "Add the tax table",
          "url" => "https://github.com/#{context.pr_repository}/pull/#{number}",
          "author" => %{"login" => "octocat"},
          "headRefName" => "feature/#{number}",
          "baseRefName" => "main",
          "state" => "OPEN",
          "isDraft" => false,
          "reviewDecision" => nil,
          "additions" => 10,
          "deletions" => 2,
          "createdAt" => "2026-09-01T00:00:00Z",
          "updatedAt" => "2026-09-02T00:00:00Z",
          "latestReviews" => latest_reviews,
          "labels" => [],
          "statusCheckRollup" => []
        }
      }
    ])
  end

  step ~r/^the verdict of the pull request is (?<verdict>.+)$/, %{args: [verdict]} = context do
    expected = %{"approved" => "approved", "needing changes" => "changes-requested"}[verdict]
    {reply, context} = World.call(context, "pullRequests.summary", Shared.pr_ref(context))
    assert {:ok, %{"reviewDecision" => ^expected}} = reply
    context
  end

  step "the branch of pull request {int} has a commit that merged the base branch in",
       %{args: [number]} = context do
    assert number == context.pr_number
    context |> put_in([:review, :merge_commit], true) |> answer_review()
  end

  step "the user opens the timeline of pull request {int}", %{args: [number]} = context do
    assert number == context.pr_number
    read_activity(context)
  end

  step "that commit is listed without line counts", context do
    [_, merge] = context.activity["commits"]
    refute Map.has_key?(merge, "additions")
    refute Map.has_key?(merge, "deletions")
    context
  end

  step "the other commits keep theirs", context do
    assert [%{"additions" => 1, "deletions" => 0} | _] = context.activity["commits"]
    context
  end

  step ~r/^a comment on pull request (?<number>\d+) by (?:the app )?"(?<login>[^"]+)", for whom the host sent no picture$/,
       %{args: [number, login]} = context do
    assert String.to_integer(number) == context.pr_number
    typename = if String.ends_with?(login, "[bot]"), do: "Bot", else: "User"

    context
    |> Map.put(:comment_login, login)
    |> put_in([:review, :extra_comment], {login, typename})
    |> answer_review()
  end

  step ~r/^the picture GitHub keeps for "(?<login>[^"]+)" is used$/,
       %{args: [login]} = context do
    author = comment_author(context, login)
    assert author["avatarUrl"] == "https://github.com/#{login}.png?size=80"
    context
  end

  step "no picture is made up, and the author is a bot", context do
    author = comment_author(context, context.comment_login)
    assert author["avatarUrl"] == nil
    assert author["isBot"] == true
    context
  end

  defp comment_author(context, login) do
    %{"author" => author} =
      Enum.find(context.activity["comments"], &(&1["author"] && &1["author"]["login"] == login))

    author
  end

  # --- checks --------------------------------------------------------------------------------

  # One run of a check as GitHub's GraphQL gives it, in workflow `workflow` when named.
  defp run(name, status, fields \\ %{}) do
    Map.merge(%{"__typename" => "CheckRun", "name" => name, "status" => status}, fields)
  end

  defp in_workflow(run, workflow) do
    Map.put(run, "checkSuite", %{"workflowRun" => %{"workflow" => %{"name" => workflow}}})
  end

  defp answer_checks(context, runs) do
    context
    |> Map.put(:check_runs, runs)
    |> Shared.reshape_pr(%{"commits" => Shared.pr_commits(runs)})
  end

  defp read_checks(context) do
    {reply, context} = World.call(context, "pullRequests.checks", Shared.pr_ref(context))
    assert {:ok, %{"checks" => checks}} = reply
    Map.merge(context, %{reply: reply, checks: checks})
  end

  step "the user reads the pull request's checks", context do
    read_checks(context)
  end

  step "the user reads its checks", context do
    read_checks(context)
  end

  step "a check {string} ran twice on pull request {int} and the second run is newer",
       %{args: [name, number]} = context do
    assert number == context.pr_number

    answer_checks(context, [
      run(name, "COMPLETED", %{
        "conclusion" => "FAILURE",
        "completedAt" => "2026-09-01T00:00:00Z"
      }),
      run("lint", "COMPLETED", %{
        "conclusion" => "SUCCESS",
        "completedAt" => "2026-09-02T00:00:00Z"
      }),
      run(name, "COMPLETED", %{
        "conclusion" => "SUCCESS",
        "completedAt" => "2026-09-03T00:00:00Z"
      })
    ])
    |> Map.put(:check_name, name)
  end

  step "{string} is listed once with the state of the newer run", %{args: [name]} = context do
    assert [%{"name" => ^name, "status" => "success"}] =
             Enum.filter(context.checks, &(&1["name"] == name))

    context
  end

  step "it stays at the position of the first run", context do
    assert [%{"name" => name}, %{"name" => "lint"}] = context.checks
    assert name == context.check_name
    context
  end

  step "a check passed at {string}", %{args: [at]} = context do
    Map.put(context, :passed_at, at)
  end

  step "it failed again at {string}", %{args: [at]} = context do
    answer_checks(context, [
      run("build", "COMPLETED", %{"conclusion" => "SUCCESS", "completedAt" => context.passed_at}),
      run("build", "COMPLETED", %{"conclusion" => "FAILURE", "completedAt" => at})
    ])
  end

  step "the check is shown as failed", context do
    assert [%{"name" => "build", "status" => "failure"}] = context.checks
    context
  end

  step ~r/^the check "(?<name>[^"]+)" of pull request (?<number>\d+) has a finished passing run and a run that (?<live>.+)$/,
       %{args: [name, number, live]} = context do
    assert String.to_integer(number) == context.pr_number

    live_run =
      case live do
        "is still running" ->
          run(name, "IN_PROGRESS", %{"startedAt" => "2026-09-01T00:00:00Z"})

        "is queued with no start time" ->
          run(name, "QUEUED")
      end

    passed =
      run(name, "COMPLETED", %{
        "conclusion" => "SUCCESS",
        "completedAt" => "2026-09-02T00:00:00Z"
      })

    context
    |> Map.merge(%{check_name: name, live_run: live_run, passed_run: passed})
    |> answer_checks([passed, live_run])
    |> answer_rollup()
  end

  # The same runs as `gh pr view --json statusCheckRollup` gives them, for the summary.
  defp answer_rollup(context) do
    rollup =
      Enum.map([context.passed_run, context.live_run], fn run ->
        run
        |> Map.delete("checkSuite")
        |> Map.put("workflowName", nil)
      end)

    number = context.pr_number

    World.cli_rules(context, [
      %{
        "args" => ["pr view #{number}", "latestReviews,labels,statusCheckRollup,body"],
        "stdout" => %{
          "number" => number,
          "title" => "Add the tax table",
          "url" => "https://github.com/#{context.pr_repository}/pull/#{number}",
          "author" => %{"login" => "octocat"},
          "headRefName" => "feature/#{number}",
          "baseRefName" => "main",
          "state" => "OPEN",
          "isDraft" => false,
          "additions" => 10,
          "deletions" => 2,
          "createdAt" => "2026-09-01T00:00:00Z",
          "updatedAt" => "2026-09-02T00:00:00Z",
          "latestReviews" => [],
          "labels" => [],
          "statusCheckRollup" => rollup
        }
      }
    ])
  end

  step "the checks of pull request {int} are read, in either order",
       %{args: [number]} = context do
    assert number == context.pr_number
    context = read_checks(context)
    first = context.checks

    context =
      context
      |> answer_checks([context.live_run, context.passed_run])
      |> read_checks()

    Map.put(context, :both_checks, [first, context.checks])
  end

  step "{string} is listed once as pending", %{args: [name]} = context do
    for checks <- context.both_checks do
      assert [%{"name" => ^name, "status" => "pending"}] =
               Enum.filter(checks, &(&1["name"] == name))
    end

    context
  end

  step "a watch on pull request {int} does not wake the agent with {string}",
       %{args: [number, _said]} = context do
    assert number == context.pr_number
    {reply, context} = World.call(context, "pullRequests.summary", Shared.pr_ref(context))
    assert {:ok, summary} = reply
    assert summary["checksState"] == "pending"

    heard = %{"state" => "open", "checksState" => "failing", "checksFailed" => true}

    snapshot = %{
      "state" => summary["state"],
      "checksState" => summary["checksState"],
      "mergeability" => summary["mergeability"]
    }

    refute :checks_passing in HalC2.PullRequests.Wakes.changes(heard, snapshot)
    context
  end

  step "the workflows {string} and {string} each have a check named {string}",
       %{args: [first, second, name]} = context do
    answer_checks(context, [
      run(name, "COMPLETED", %{"conclusion" => "SUCCESS"}) |> in_workflow(first),
      run(name, "COMPLETED", %{"conclusion" => "SUCCESS"}) |> in_workflow(second)
    ])
  end

  step "the checks are listed as {string} and {string}", %{args: [first, second]} = context do
    assert Enum.map(context.checks, & &1["name"]) == [first, second]
    context
  end

  step "pull request {int} has the check {string} of workflow {string}, which failed",
       %{args: [number, name, workflow]} = context do
    assert number == context.pr_number

    Map.put(context, :check_runs, [
      run(name, "COMPLETED", %{
        "conclusion" => "FAILURE",
        "completedAt" => "2026-09-01T00:00:00Z"
      })
      |> in_workflow(workflow)
    ])
  end

  step "the check {string} of workflow {string}, which passed",
       %{args: [name, workflow]} = context do
    runs =
      context.check_runs ++
        [
          run(name, "COMPLETED", %{
            "conclusion" => "SUCCESS",
            "completedAt" => "2026-09-02T00:00:00Z"
          })
          |> in_workflow(workflow)
        ]

    answer_checks(context, runs)
  end

  step "both checks are listed, and the failure is not hidden by the newer pass", context do
    by_name = Map.new(context.checks, &{&1["name"], &1["status"]})
    assert by_name == %{"Linux tests" => "failure", "tests" => "success"}
    context
  end

  step "pull request {int} comes from a fork and its workflows are awaiting approval",
       %{args: [number]} = context do
    assert number == context.pr_number
    sha = Shared.pr_sha()

    context
    |> Shared.reshape_pr(%{
      "isCrossRepository" => true,
      "headRepositoryOwner" => %{"login" => "forker"}
    })
    |> World.cli_rules([
      %{
        "args" => ["pr list", "--head feature/#{number}"],
        "stdout" => [
          %{
            "number" => number,
            "headRefOid" => sha,
            "isCrossRepository" => true,
            "headRepositoryOwner" => %{"login" => "forker"}
          }
        ]
      },
      %{
        "args" => ["run list", "--commit #{sha}"],
        "stdout" => [
          %{
            "databaseId" => 99,
            "workflowName" => "CI",
            "url" => "https://github.com/acme/shop/actions/runs/99"
          }
        ]
      }
    ])
  end

  step "the waiting workflows are listed as action-required", context do
    assert %{"name" => "CI", "status" => "action-required"} =
             Enum.find(context.checks, &(&1["name"] == "CI"))

    context
  end

  step "the pull request is not reported as passing", context do
    refute Enum.all?(context.checks, &(&1["status"] == "success"))
    assert Enum.any?(context.checks, &(&1["status"] == "action-required"))
    context
  end

  step "pull request {int} has 130 checks and the first 100 of them passed",
       %{args: [number]} = context do
    assert number == context.pr_number
    checks = for i <- 1..130, do: named_run(i, if(i == 101, do: "FAILURE", else: "SUCCESS"))

    context
    |> Map.put(:all_checks, checks)
    |> answer_paged_checks(checks, Shared.pr_sha())
  end

  step "the 101st failed", context do
    # Part of the setup above: run 101 is the failing one.
    assert Enum.at(context.all_checks, 100)["conclusion"] == "FAILURE"
    context
  end

  defp named_run(i, conclusion) do
    %{
      "__typename" => "CheckRun",
      "name" => "check#{i}",
      "status" => "COMPLETED",
      "conclusion" => conclusion,
      "completedAt" => "2026-09-01T00:00:00Z"
    }
  end

  # The detail's first page of contexts says there are more; the rest are read
  # through `gh pr view --json statusCheckRollup,headRefOid` at head `view_head`.
  defp answer_paged_checks(context, checks, view_head) do
    first = %{
      "nodes" => [
        %{
          "commit" => %{
            "statusCheckRollup" => %{
              "contexts" => %{
                "nodes" => Enum.take(checks, 100),
                "pageInfo" => %{"hasNextPage" => true}
              }
            }
          }
        }
      ]
    }

    rollup =
      for c <- checks do
        %{
          "__typename" => "CheckRun",
          "name" => c["name"],
          "status" => c["status"],
          "conclusion" => c["conclusion"],
          "startedAt" => "2026-09-01T00:00:00Z",
          "completedAt" => c["completedAt"]
        }
      end

    context
    |> Shared.reshape_pr(%{"commits" => first})
    |> World.cli_rules([
      %{
        "args" => ["pr view #{context.pr_number}", "statusCheckRollup,headRefOid"],
        "stdout" => %{"headRefOid" => view_head, "statusCheckRollup" => rollup}
      }
    ])
  end

  step "all 130 checks are read", context do
    assert length(context.checks) == 130
    context
  end

  step "the pull request is reported as failing", context do
    assert Enum.any?(context.checks, &(&1["status"] == "failure"))
    context
  end

  step "pull request {int} has more checks than one read holds", %{args: [number]} = context do
    assert number == context.pr_number
    checks = for i <- 1..130, do: named_run(i, "SUCCESS")
    Map.put(context, :all_checks, checks)
  end

  step "the author pushes while the rest of the checks are being read", context do
    pushed = String.duplicate("a", 40)
    answer_paged_checks(context, context.all_checks, pushed)
  end

  step "the read fails with {string}", %{args: [message]} = context do
    assert {:error, _error, detail} = context.reply
    assert detail["detail"] == message or detail["message"] =~ message
    context
  end

  step "the checks of the older push are not shown as the checks of the new one", context do
    assert {:error, _, _} = context.reply
    context
  end

  # --- diffs, expansion and viewed marks -----------------------------------------------------

  step "line 12 of {string} was removed in pull request {int} and a different line 12 was added",
       %{args: [path, number]} = context do
    assert number == context.pr_number

    Map.put(context, :line_comments, [
      %{
        "path" => path,
        "body" => "This removal loses the rounding.",
        "position" => %{"kind" => "deleted", "oldLine" => 12}
      }
    ])
  end

  step "the user comments on the removed line 12 and submits the review", context do
    call(context, "pullRequests.submitReview", %{
      "verdict" => "comment",
      "body" => "",
      "comments" => context.line_comments
    })
  end

  step "the comment arrives on the removed line", context do
    assert {:ok, _} = context.reply
    assert [call] = World.cli_calls(context, "pulls/42/reviews")

    assert [%{"line" => 12, "side" => "LEFT", "path" => "src/cart.ts"}] =
             JSON.decode!(call["stdin"])["comments"]

    context
  end

  step "the user wrote 3 line comments and a summary for pull request {int}",
       %{args: [number]} = context do
    assert number == context.pr_number

    comments =
      for line <- [12, 20, 31] do
        %{
          "path" => "src/cart.ts",
          "body" => "Remark on line #{line}.",
          "position" => %{"kind" => "added", "newLine" => line}
        }
      end

    Map.merge(context, %{line_comments: comments, summary: "Nearly there."})
  end

  step "the user submits the review with the verdict {string}", %{args: [verdict]} = context do
    call(context, "pullRequests.submitReview", %{
      "verdict" => verdict,
      "body" => context.summary,
      "comments" => context.line_comments
    })
  end

  step "GitHub receives the comments, the summary and the verdict in one request", context do
    assert {:ok, _} = context.reply
    assert [call] = World.cli_calls(context, "pulls/42/reviews")
    sent = JSON.decode!(call["stdin"])
    assert sent["event"] == "COMMENT"
    assert sent["body"] == context.summary
    assert length(sent["comments"]) == 3
    context
  end

  step "nobody else sees any of them before that request is accepted", context do
    # The one reviews request is the only write the MC made to GitHub.
    writes =
      Enum.filter(World.cli_calls(context), fn call ->
        Enum.join(call["args"], " ") =~ ~r/--method POST|pr comment/
      end)

    assert length(writes) == 1
    context
  end

  @main_tip "2222222222222222222222222222222222222222"

  step "main gained lines in {string} after pull request {int} branched from it",
       %{args: [path, number]} = context do
    assert number == context.pr_number

    # What the file reads at main's tip now, which expanding must not use.
    World.cli_rules(context, [
      %{
        "args" => ["contents/#{path}?ref=#{@main_tip}"],
        "stdout" =>
          "export const gained = true\nexport const total = (items) => round(sum(items))\n"
      }
    ])
  end

  step "the unchanged lines are shown", context do
    {old, new} = context.sides
    assert {:ok, %{"oldContents" => ^old, "newContents" => ^new}} = context.reply
    context
  end

  step "the old side is {string} as it was at the merge base, not at main's tip",
       %{args: [path]} = context do
    assert [_] = World.cli_calls(context, "contents/#{path}?ref=#{@base}")
    assert World.cli_calls(context, "contents/#{path}?ref=#{@main_tip}") == []
    context
  end

  step "a client asks for the diff of pull request {int} from a position it was not given",
       %{args: [number]} = context do
    assert number == context.pr_number

    {status, body} =
      World.http_post(
        context,
        "/api/pull-requests/diff",
        Map.put(Shared.pr_ref(context), "cursor", "page-9")
      )

    assert status == 502
    Map.put(context, :told, body["detail"])
  end

  step "a client asks for the code of pull request {int} at the commit {string}",
       %{args: [number, commit]} = context do
    assert number == context.pr_number

    {status, body} =
      World.http_post(
        context,
        "/api/pull-requests/diff",
        Map.put(Shared.pr_ref(context), "commit", commit)
      )

    assert status == 502
    Map.put(context, :told, body["detail"])
  end

  step "the host's answer for one page of the changed files of pull request {int} is cut off part-way",
       %{args: [number]} = context do
    assert number == context.pr_number

    World.cli_rules(context, [
      %{
        "args" => ["pr diff #{number}"],
        "exit" => 1,
        "stderr" => "HTTP 406: Sorry, the diff exceeded the maximum number of files (300)."
      },
      %{
        "args" => ["pulls/#{number}/files?per_page=100&page=1"],
        "stdout" => "[{\"filename\": \"src/a.ts\", \"status\": \"modi"
      }
    ])
  end

  step "the read fails", context do
    assert {status, _body} = context.diff_read
    assert status == 502
    context
  end

  step "the diff is not shown as complete", context do
    refute match?({200, %{"truncated" => false}}, context.diff_read)
    assert context[:slices] in [nil, []]
    context
  end

  step "the host withholds the changes of {string} in pull request {int} because they are too large",
       %{args: [path, number]} = context do
    assert number == context.pr_number

    context
    |> Map.put(:withheld, path)
    |> World.cli_rules([
      %{
        "args" => ["pr diff #{number}"],
        "exit" => 1,
        "stderr" => "HTTP 406: Sorry, the diff exceeded the maximum number of files (300)."
      },
      %{
        "args" => ["pulls/#{number}/files?per_page=100&page=1"],
        "stdout" => [
          %{"filename" => path, "status" => "modified", "additions" => 5000, "deletions" => 40},
          %{
            "filename" => "src/cart.ts",
            "status" => "modified",
            "patch" => "@@ -1 +1 @@\n-a\n+b",
            "additions" => 1,
            "deletions" => 1
          }
        ]
      }
    ])
  end

  step "{string} is listed with its added and removed line counts and no changes",
       %{args: [path]} = context do
    assert [slice] = context.slices
    assert slice["patch"] =~ "b/#{path}"

    assert Enum.member?(
             slice["omittedFileStats"],
             %{"path" => path, "additions" => 5000, "deletions" => 40}
           )

    section =
      slice["patch"]
      |> String.split("diff --git ")
      |> Enum.find(&String.contains?(&1, "b/#{path}"))

    body =
      section
      |> String.split("\n")
      |> Enum.reject(&(String.starts_with?(&1, "--- ") or String.starts_with?(&1, "+++ ")))

    refute Enum.any?(body, &(String.starts_with?(&1, "+") or String.starts_with?(&1, "-")))
    context
  end

  step ~r/^"(?<path>[^"]+)" is larger than one megabyte$/, %{args: [path]} = context do
    context
    |> Map.put(:expand_old, String.duplicate("x", 1_100_000))
    |> Map.put(:expand_new, "export const total = 1\n")
    |> tap(fn _ -> assert path != "" end)
  end

  step ~r/^"(?<path>[^"]+)" is a binary file$/, %{args: [_path]} = context do
    context
    |> Map.put(:expand_old, <<"PNG", 0, 1, 2, 3>>)
    |> Map.put(:expand_new, <<"PNG", 0, 4, 5, 6>>)
  end

  step "the host reports no usable base and head for pull request {int}",
       %{args: [number]} = context do
    assert number == context.pr_number
    Map.put(context, :expand_refs, "not-a-sha\talso-not-a-sha\n")
  end

  @root_commit "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  step "the commit being reviewed is the first commit of the repository and adds {string}",
       %{args: [path]} = context do
    context
    |> Map.merge(%{root_path: path, root_commit: @root_commit, pr_ref: Shared.pr_ref(context)})
    |> World.cli_rules([
      %{
        "args" => ["commits/#{@root_commit}", "parents[0].sha"],
        "stdout" => "\t#{@root_commit}\n"
      },
      %{
        "args" => ["commits/#{@root_commit}?per_page=100&page=1", ".files"],
        "stdout" => [%{"filename" => path, "status" => "added"}]
      },
      %{
        "args" => ["contents/#{path}?ref=#{@root_commit}"],
        "stdout" => "# Acme Shop\n"
      }
    ])
  end

  step "the file's contents are shown without asking for a parent version", context do
    assert {:ok, %{"oldContents" => "", "newContents" => "# Acme Shop\n"}} = context.reply

    contents = World.cli_calls(context, "contents/#{context.root_path}?ref=")
    assert length(contents) == 1
    assert hd(contents)["args"] |> Enum.join(" ") =~ "ref=#{@root_commit}"
    context
  end

  step "pull request {int} does not change {string}", %{args: [number, path]} = context do
    assert number == context.pr_number

    context
    |> Map.put(:unchanged_path, path)
    |> World.cli_rules([
      %{
        "args" => ["repos/acme/shop/pulls/42", "--jq"],
        "stdout" => "#{@base}\t#{Shared.pr_sha()}\n"
      },
      %{
        "args" => ["pulls/42/files?per_page=100&page=1"],
        "stdout" => [%{"filename" => "src/cart.ts", "status" => "modified"}]
      },
      %{"args" => ["contents/#{path}?ref="], "stdout" => "secret: hunter2\n"}
    ])
  end

  step "a client asks for the contents of {string} as a file of pull request {int}",
       %{args: [path, number]} = context do
    assert number == context.pr_number

    call(context, "pullRequests.diffFileContents", %{
      "changeType" => "change",
      "oldPath" => path,
      "newPath" => path
    })
  end

  step "it is told the file was not found", context do
    assert {:error, _error, detail} = context.reply
    assert (detail["detail"] || "") =~ "not found"
    # The file's contents were never asked for, let alone handed out.
    assert World.cli_calls(context, "contents/#{context.unchanged_path}?ref=") == []
    context
  end

  step "the user reads which files they have viewed", context do
    {reply, context} = World.call(context, "pullRequests.filesViewed", Shared.pr_ref(context))
    Map.put(context, :reply, reply)
  end

  step "the marks of the first 500 files are returned", context do
    assert {:ok, %{"files" => files}} = context.reply
    assert length(files) == 500
    context
  end

  step "the answer says it was cut short", context do
    assert {:ok, %{"truncated" => true}} = context.reply
    context
  end

  step "the user marks {string} and {string} viewed together in GitHub pull request {int}",
       %{args: [first, second, number]} = context do
    assert number == context.pr_number
    Map.put(context, :batch, [first, second])
  end

  step "GitHub stores the mark for {string} and refuses {string}",
       %{args: [stored, _refused]} = context do
    context =
      context
      |> put_in([:viewed, stored], "VIEWED")
      |> answer_review()
      |> World.cli_rules([
        %{
          "args" => ["api graphql"],
          "stdin" => ["FileAsViewed(input"],
          "exit" => 1,
          "stderr" => "GraphQL: Could not mark the file as viewed.\n"
        }
      ])
      |> Map.put(:detail_reads, detail_read_count(context))

    call(context, "pullRequests.setFilesViewed", %{
      "files" => Enum.map(context.batch, &%{"path" => &1, "viewed" => true})
    })
  end

  step "the user is told the marks could not all be saved", context do
    assert {:error, _, _} = context.reply
    context
  end

  step "{string} reads as viewed and {string} does not, without reopening the pull request",
       %{args: [viewed, unviewed]} = context do
    {reply, context} = World.call(context, "pullRequests.filesViewed", Shared.pr_ref(context))
    assert {:ok, %{"files" => files}} = reply
    by_path = Map.new(files, &{&1["path"], &1["state"]})
    assert by_path[viewed] == "viewed"
    assert by_path[unviewed] in [nil, "unviewed"]
    # No fresh detail read was needed to learn the stored mark.
    assert detail_read_count(context) == context.detail_reads
    context
  end

  step ~r/^pull request (?<number>\d+) on (?<host>[A-Za-z ]+) renamed "(?<old>[^"]+)" to "(?<new>[^"]+)" (?<edited>.+)$/,
       %{args: [number, host, old, new, edited]} = context do
    assert String.to_integer(number) == context.pr_number
    assert host == "GitHub"

    patch =
      if edited =~ "without",
        do: "",
        else:
          "@@ -1 +1 @@\n-export const total = (items) => sum(items)\n+export const total = (items) => round(sum(items))"

    file = %{
      "filename" => new,
      "previous_filename" => old,
      "status" => "renamed",
      "additions" => if(patch == "", do: 0, else: 1),
      "deletions" => if(patch == "", do: 0, else: 1)
    }

    file = if patch == "", do: file, else: Map.put(file, "patch", patch)

    context
    |> Map.merge(%{rename_old: old, rename_new: new})
    |> World.cli_rules([
      %{
        "args" => ["pr diff #{number}"],
        "exit" => 1,
        "stderr" => "HTTP 406: Sorry, the diff exceeded the maximum number of files (300)."
      },
      %{
        "args" => ["pulls/#{number}/files?per_page=100&page=1"],
        "stdout" => [file]
      },
      %{
        "args" => ["repos/acme/shop/pulls/42", "--jq"],
        "stdout" => "#{@base}\t#{Shared.pr_sha()}\n"
      },
      %{
        "args" => ["contents/#{old}?ref=#{@base}"],
        "stdout" => "export const total = (items) => sum(items)\n"
      },
      %{
        "args" => ["contents/#{new}?ref=#{Shared.pr_sha()}"],
        "stdout" => "export const total = (items) => round(sum(items))\n"
      }
    ])
  end

  step "the user reads the code of pull request {int}", %{args: [number]} = context do
    assert number == context.pr_number
    Map.put(context, :slices, diff_slices(context, %{}))
  end

  step ~r/^"(?<new>[^"]+)" is shown as renamed from "(?<old>[^"]+)" (?<shown>.+)$/,
       %{args: [new, old, shown]} = context do
    assert [slice] = context.slices
    assert slice["patch"] =~ "rename from #{old}"
    assert slice["patch"] =~ "rename to #{new}"

    if shown =~ "with that line" do
      assert slice["patch"] =~ "+export const total = (items) => round(sum(items))"
    else
      refute slice["patch"] =~ ~r/^@@/m
    end

    context
  end

  step "expanding its unchanged lines reads the old side from {string}",
       %{args: [old]} = context do
    context =
      call(context, "pullRequests.diffFileContents", %{
        "changeType" => "rename-changed",
        "oldPath" => old,
        "newPath" => context.rename_new
      })

    assert {:ok, %{"oldContents" => "export const total = (items) => sum(items)\n"}} =
             context.reply

    assert [_] = World.cli_calls(context, "contents/#{old}?ref=#{@base}")
    context
  end

  # --- hosts that cannot, and subjects of another pull request -------------------------------

  @hosts %{
    "Azure DevOps" => {"azure-devops", "https://dev.azure.com/acme/infra/_git/infra"},
    "Bitbucket" => {"bitbucket", "git@bitbucket.org:acme/infra.git"},
    "Forgejo" => {"forgejo", "https://codeberg.org/acme/infra.git"}
  }

  # A project whose checkout's remote is on the named host, and a reference to
  # change request 7 there. The host is never asked anything.
  defp open_on_host(context, host) do
    {kind, url} = @hosts[host] || {"unknown", "https://git.example.com/acme/infra.git"}
    title = "on-#{kind}"
    context = World.create_project(context, title)
    project = World.project(context, title)
    World.git!(project.root, ["remote", "add", "origin", url])

    repository =
      url
      |> String.replace(~r/^(git@[^:]+:|https:\/\/[^\/]+\/)/, "")
      |> String.replace_suffix(".git", "")

    Map.merge(context, %{
      host_ref: %{"projectId" => project.id, "repository" => repository, "number" => 7},
      host_root: project.root,
      host_calls: Enum.count(World.cli_calls(context), &(&1["cwd"] == project.root))
    })
  end

  defp host_call(context, method, payload) do
    {reply, context} = World.call(context, method, Map.merge(context.host_ref, payload))
    Map.put(context, :reply, reply)
  end

  step "an open change request on {word}", %{args: [host]} = context do
    open_on_host(context, host)
  end

  step ~r/^an open change request on (?<host>Azure DevOps)$/, %{args: [host]} = context do
    open_on_host(context, host)
  end

  step "the user tries to post a comment", context do
    host_call(context, "pullRequests.comment", %{"body" => "Hello"})
  end

  step "the user tries to comment on a line", context do
    host_call(context, "pullRequests.submitReview", %{
      "verdict" => "comment",
      "body" => "",
      "comments" => [
        %{
          "path" => "src/cart.ts",
          "body" => "Round after the tax.",
          "position" => %{"kind" => "added", "newLine" => 12}
        }
      ]
    })
  end

  step "the user tries to reply to a conversation", context do
    host_call(context, "pullRequests.replyToThread", %{"threadId" => "T1", "body" => "Fixed"})
  end

  step "the user tries to resolve a conversation", context do
    host_call(context, "pullRequests.setThreadResolution", %{
      "threadId" => "T1",
      "resolved" => true
    })
  end

  step "the user tries to approve", context do
    host_call(context, "pullRequests.submitReview", %{
      "verdict" => "approve",
      "body" => "",
      "comments" => []
    })
  end

  step "the user tries to react to a comment", context do
    host_call(context, "pullRequests.setReaction", %{
      "subjectId" => "IC_1",
      "content" => "heart",
      "reacted" => true
    })
  end

  step "an open change request on a host that does not support editing title and description",
       context do
    open_on_host(context, "an unknown host")
  end

  step "an open change request on a host that does not support editing comments", context do
    open_on_host(context, "an unknown host")
  end

  step "the user rewrites the title and description", context do
    host_call(context, "pullRequests.update", %{"title" => "A new title"})
  end

  step "the user rewrites the comments", context do
    host_call(context, "pullRequests.updateComment", %{
      "commentId" => "IC_1",
      "kind" => "issue-comment",
      "body" => "New words"
    })
  end

  step "nothing is sent to the host", context do
    assert Enum.count(World.cli_calls(context), &(&1["cwd"] == context.host_root)) ==
             context.host_calls

    context
  end

  step "a comment that belongs to pull request 7", context do
    other = %{
      "data" => %{
        "repository" => %{"pullRequest" => %{"id" => Shared.pr_node_id()}},
        "node" => %{"id" => "IC_OTHER", "pullRequest" => %{"id" => "PR_other7"}}
      }
    }

    context
    |> Map.merge(%{other_comment: "IC_OTHER", other_thread: "T_OTHER"})
    |> World.cli_rules([
      %{
        "args" => ["api graphql"],
        "stdin" => ["node(id: $subjectId)", "\"subjectId\":\"IC_OTHER\""],
        "stdout" => other
      },
      %{
        "args" => ["api graphql"],
        "stdin" => ["node(id: $threadId)", "\"threadId\":\"T_OTHER\""],
        "stdout" => %{
          "data" => %{
            "viewer" => %{"login" => @me},
            "repository" => %{"pullRequest" => %{"id" => Shared.pr_node_id()}},
            "node" => %{
              "pullRequest" => %{"id" => "PR_other7"},
              "comments" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => []}
            }
          }
        }
      }
    ])
  end

  step "the user tries to react to it as part of pull request {int}",
       %{args: [number]} = context do
    assert number == context.pr_number

    call(context, "pullRequests.setReaction", %{
      "subjectId" => context.other_comment,
      "content" => "heart",
      "reacted" => true
    })
  end

  step "the user tries to edit it as part of pull request {int}", %{args: [number]} = context do
    assert number == context.pr_number

    call(context, "pullRequests.updateComment", %{
      "commentId" => context.other_comment,
      "kind" => "issue-comment",
      "body" => "Edited"
    })
  end

  step "the user tries to load more replies of its thread as part of pull request {int}",
       %{args: [number]} = context do
    assert number == context.pr_number
    call(context, "pullRequests.threadComments", %{"threadId" => context.other_thread})
  end

  # --- a very long conversation, and words on stdin ------------------------------------------

  step "a pull request on {word} whose conversation runs to more than ten full pages",
       %{args: [host]} = context do
    assert host == "GitHub"

    rules =
      for page <- 1..10 do
        cursor = if page == 1, do: "\"cursor\":null", else: "\"cursor\":\"tc#{page - 1}\""

        %{
          "args" => ["api graphql"],
          "stdin" => ["reviewThreads(first", cursor],
          "stdout" => %{
            "data" => %{
              "viewer" => %{"login" => @me},
              "repository" => %{
                "pullRequest" => %{
                  "reviewThreads" => %{
                    "pageInfo" => %{"hasNextPage" => true, "endCursor" => "tc#{page}"},
                    "nodes" => [thread("TP#{page}", "src/cart.ts", page)]
                  },
                  "author" => %{"login" => "octocat", "avatarUrl" => nil},
                  "reactionGroups" => [],
                  "comments" => %{"nodes" => []},
                  "reviews" => %{"nodes" => []},
                  "reviewRequests" => %{"nodes" => []},
                  "latestReviews" => %{"nodes" => []},
                  "reviewDismissals" => %{"nodes" => []},
                  "commits" => %{"nodes" => []}
                }
              }
            }
          }
        }
      end

    World.cli_rules(context, rules)
  end

  step "the user opens its conversation", context do
    read_activity(context)
  end

  step "the pages read so far are shown", context do
    assert length(context.activity["reviewThreads"]) == 10
    assert Enum.any?(context.activity["comments"], &(&1["id"] == "RC_TP1"))
    assert Enum.any?(context.activity["comments"], &(&1["id"] == "RC_TP10"))
    context
  end

  step "the conversation says it was cut short", context do
    assert context.activity["commentsTruncated"] == true
    context
  end

  step "the user types {string}", %{args: [words]} = context do
    Map.put(context, :words, words)
  end

  step "the user submits a review through the MC on {word}", %{args: [host]} = context do
    assert host == "GitHub"

    call(context, "pullRequests.submitReview", %{
      "verdict" => "comment",
      "body" => context.words,
      "comments" => []
    })
  end

  step "the user searches pull requests through the MC on {word}", %{args: [host]} = context do
    assert host == "GitHub"

    context =
      World.cli_rules(context, [
        %{"args" => ["api graphql"], "stdin" => ["PullRequestList"], "pulls" => []}
      ])

    {reply, context} = World.call(context, "pullRequests.list", %{"query" => context.words})
    Map.put(context, :reply, reply)
  end

  step "the words reach the host through its standard input rather than its arguments",
       context do
    calls = World.cli_calls(context)
    assert Enum.any?(calls, &(&1["stdin"] =~ context.words))

    refute Enum.any?(calls, fn call ->
             Enum.any?(call["args"], &(&1 =~ context.words))
           end)

    context
  end

  step "the words are not in any error that is reported", context do
    case context.reply do
      {:ok, _} -> context
      {:error, error, detail} -> refute inspect({error, detail}) =~ context.words
    end

    context
  end

  # --- teams, single-field edits, full check reads -------------------------------------------

  step "the team {string} was asked to review pull request {int} on GitHub",
       %{args: [team, number]} = context do
    assert number == context.pr_number
    [org, slug] = String.split(team, "/", parts: 2)

    Shared.reshape_pr(context, %{
      "reviewRequests" => %{
        "nodes" => [
          %{
            "requestedReviewer" => %{
              "slug" => slug,
              "name" => "Core Team",
              "avatarUrl" => "https://github.com/#{team}.png",
              "organization" => %{"login" => org}
            }
          }
        ]
      }
    })
  end

  step "a user whose login is {string} approved it", %{args: [login]} = context do
    context |> Map.put(:approver, login) |> put_in([:review, :approver], login) |> answer_review()
  end

  step "reviewers lists {string} with its name and avatar, and {string} apart from it",
       %{args: [team, login]} = context do
    detail = context.detail

    assert %{
             "login" => ^team,
             "name" => "Core Team",
             "avatarUrl" => "https://github.com/acme/core.png"
           } = Enum.find(detail["reviewers"], &(&1["login"] == team))

    # The detail named the team before any conversation read happened.
    before_conversation = World.cli_calls(context, "author,comments,reviews,commits") == []

    context = read_activity(context)

    approving =
      for c <- context.activity["comments"],
          c["reviewState"] == "APPROVED",
          do: c["author"]["login"]

    assert approving == [login]

    Map.merge(context, %{
      team: team,
      team_before_conversation: before_conversation,
      approving: approving
    })
  end

  step "only {string} is marked as approving", %{args: [login]} = context do
    assert context.approving == [login]
    refute Enum.any?(context.activity["comments"], &(&1["author"]["login"] == context.team))
    context
  end

  step "the team is listed before the conversation has loaded", context do
    assert context.team_before_conversation
    context
  end

  step ~r/^an open change request on (?<host>.+) with a title and a description$/,
       %{args: [host]} = context do
    assert host == "GitHub"
    detail = Shared.pr_detail!(context)
    assert detail["title"] == "Add the tax table"
    assert detail["body"] == "Adds the tax table."
    Map.put(context, :detail, detail)
  end

  step ~r/^the user changes only its (?<field>title|description)$/,
       %{args: [field]} = context do
    payload =
      case field do
        "title" -> %{"title" => "Add tax to the cart"}
        "description" -> %{"body" => "Adds the tax table, carefully."}
      end

    context |> Map.put(:changed_field, field) |> call("pullRequests.update", payload)
  end

  step ~r/^only the (?<field>title|description) is sent to the host$/,
       %{args: [field]} = context do
    assert {:ok, _} = context.reply
    variables = mutation(context, "updatePullRequest")
    key = if field == "title", do: "title", else: "body"
    assert Map.keys(variables) |> Enum.sort() == ["pullRequestId", key] |> Enum.sort()
    context
  end

  step "the other one still reads as before", context do
    detail = Shared.pr_detail!(context)

    case context.changed_field do
      "title" -> assert detail["body"] == "Adds the tax table."
      "description" -> assert detail["title"] == "Add the tax table"
    end

    context
  end

  step "a GitHub host that does not support conditional reads of check results", context do
    # No call the MC makes to `gh` carries a conditional header; this read
    # primes nothing a later one could reuse.
    context = read_checks(context)

    refute Enum.any?(World.cli_calls(context), fn call ->
             Enum.join(call["args"], " ") =~ ~r/if-none-match|etag/i
           end)

    Map.put(context, :detail_reads, detail_read_count(context))
  end

  step "the checks are read in full each time", context do
    assert [%{"name" => "build", "status" => "success"}] = context.checks

    assert detail_read_count(context) ==
             context.detail_reads + 1

    context
  end

  # How many detail reads (`@core_query`, named by its `viewerCanUpdateBranch`
  # field in the request on stdin) the MC has made so far.
  defp detail_read_count(context) do
    Enum.count(World.cli_calls(context, "api graphql"), &(&1["stdin"] =~ "viewerCanUpdateBranch"))
  end

  # --- helpers -------------------------------------------------------------------------------

  defp ok, do: %{"data" => %{}}

  defp call(context, method, payload) do
    {reply, context} = World.call(context, method, Map.merge(Shared.pr_ref(context), payload))
    Map.put(context, :reply, reply)
  end

  defp read_activity(context) do
    {reply, context} = World.call(context, "pullRequests.activity", Shared.pr_ref(context))
    assert {:ok, activity} = reply
    Map.put(context, :activity, activity)
  end

  defp comment(context, body), do: Enum.find(context.activity["comments"], &(&1["body"] == body))

  # The variables of the one GraphQL mutation named `name` the MC sent.
  defp mutation(context, name) do
    assert [call] =
             context
             |> World.cli_calls("api graphql")
             |> Enum.filter(&(JSON.decode!(&1["stdin"])["query"] =~ ~r/\b#{name}\(/))

    JSON.decode!(call["stdin"])["variables"]
  end

  defp assert_resolution(context, name) do
    assert {:ok, _} = context.reply
    assert mutation(context, name) == %{"threadId" => context.thread_id}
    context
  end

  # As the reaction bar does: pressing a reaction the user already gave takes it back.
  defp toggle_heart(context) do
    context = read_activity(context)

    given =
      Enum.any?(
        context.activity["reactions"],
        &(&1["content"] == "heart" and &1["viewerHasReacted"])
      )

    call(context, "pullRequests.setReaction", %{
      "subjectId" => nil,
      "content" => "heart",
      "reacted" => not given
    })
  end

  defp assert_reaction(context, name) do
    assert {:ok, _} = context.reply
    assert mutation(context, name) == %{"subjectId" => Shared.pr_node_id(), "content" => "HEART"}
    context
  end

  defp mark(context, path, viewed) do
    call(context, "pullRequests.setFilesViewed", %{
      "files" => [%{"path" => path, "viewed" => viewed}]
    })
  end

  defp viewed_state(context, path) do
    {reply, _} = World.call(context, "pullRequests.filesViewed", Shared.pr_ref(context))
    assert {:ok, %{"files" => files}} = reply
    assert %{"state" => state} = Enum.find(files, &(&1["path"] == path))
    state
  end

  defp thread(id, path, line, fields \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "path" => path,
        "line" => line,
        "diffSide" => "RIGHT",
        "isResolved" => false,
        "isOutdated" => false,
        "comments" => %{
          "totalCount" => 1,
          "pageInfo" => %{"hasNextPage" => false},
          "nodes" => [
            %{
              "id" => "RC_#{id}",
              "author" => %{"login" => "hubot", "avatarUrl" => nil},
              "body" => "Should this round?",
              "createdAt" => "2026-09-03T12:00:00Z",
              "reactionGroups" => []
            }
          ]
        }
      },
      fields
    )
  end

  # The conversation (`gh pr view`), its review threads and the viewed marks, as
  # `context.review` and `context.viewed` now describe them.
  defp answer_review(context) do
    number = context.pr_number
    review = context.review

    mine =
      if review[:comment],
        do: [
          %{
            "id" => "IC_9",
            "author" => %{"login" => @me},
            "body" => review.comment,
            "createdAt" => "2026-09-07T00:00:00Z"
          }
        ],
        else: []

    extra =
      case review[:extra_comment] do
        {login, typename} ->
          [
            %{
              "id" => "IC_X",
              "author" => %{"login" => login, "__typename" => typename},
              "body" => "A remark.",
              "createdAt" => "2026-09-06T00:00:00Z"
            }
          ]

        _ ->
          []
      end

    view = %{
      "author" => %{"login" => "octocat"},
      "comments" =>
        [
          %{
            "id" => "IC_1",
            "author" => %{"login" => "hubot"},
            "body" => "Please add tests.",
            "createdAt" => "2026-09-03T00:00:00Z"
          }
        ] ++
          mine ++
          extra,
      "reviews" => [
        # GitHub's empty review around a line comment is read from its thread instead.
        %{
          "id" => "R_0",
          "author" => %{"login" => "hubot"},
          "body" => "",
          "state" => "COMMENTED",
          "submittedAt" => "2026-09-03T12:00:00Z"
        },
        %{
          "id" => "R_1",
          "author" => %{"login" => review[:approver] || "hubot"},
          "body" => "Nice.",
          "state" => "APPROVED",
          "submittedAt" => "2026-09-04T00:00:00Z"
        },
        %{
          "id" => "R_2",
          "author" => %{"login" => "hubot"},
          "body" => review[:dismissed_body] || "",
          "state" => "DISMISSED",
          "submittedAt" => "2026-09-05T00:00:00Z"
        }
      ],
      "commits" => []
    }

    threads = %{
      "data" => %{
        "viewer" => %{"login" => @me},
        "repository" => %{
          "pullRequest" => %{
            "reviewThreads" => %{
              "pageInfo" => %{"hasNextPage" => false},
              "nodes" => review.threads
            },
            "author" => %{"login" => "octocat", "avatarUrl" => nil},
            "reactionGroups" => review.reactions,
            "comments" => %{"nodes" => []},
            "reviews" => %{"nodes" => []},
            "reviewRequests" => %{"nodes" => []},
            "latestReviews" => %{"nodes" => []},
            "reviewDismissals" => %{
              "nodes" => [
                %{
                  "dismissalMessage" => review[:dismissal] || "Outdated after the rebase",
                  "review" => %{"id" => "R_2"}
                }
              ]
            },
            "commits" => %{
              "nodes" =>
                for {oid, i} <- Enum.with_index(@commits, 1) do
                  %{
                    "commit" => %{
                      "oid" => oid,
                      "messageHeadline" => "Commit #{i}",
                      "committedDate" => "2026-09-0#{i}T00:00:00Z",
                      "additions" => i,
                      "deletions" => 0,
                      "parents" => %{
                        "totalCount" => if(review[:merge_commit] && i == 2, do: 2, else: 1)
                      },
                      "authors" => %{
                        "nodes" => [%{"name" => "Octocat", "user" => %{"login" => "octocat"}}]
                      }
                    }
                  }
                end
            }
          }
        }
      }
    }

    viewed = %{
      "data" => %{
        "repository" => %{
          "pullRequest" => %{
            "files" => %{
              "pageInfo" => %{"hasNextPage" => false},
              "nodes" =>
                for(
                  path <- Enum.uniq(["src/cart.ts", "src/tax.ts"] ++ Map.keys(context.viewed)),
                  do: %{"path" => path, "viewerViewedState" => context.viewed[path] || "UNVIEWED"}
                )
            }
          }
        }
      }
    }

    World.cli_rules(context, [
      %{"args" => ["pr view #{number}", "author,comments,reviews,commits"], "stdout" => view},
      %{"args" => ["api graphql"], "stdin" => ["reviewThreads(first"], "stdout" => threads},
      %{"args" => ["api graphql"], "stdin" => ["viewerViewedState"], "stdout" => viewed}
    ])
  end

  # Most files carry their hunks; every 25th is too large for GitHub to inline and
  # every 40th a binary with nothing to count.
  defp changed_file(i) do
    cond do
      rem(i, 40) == 0 ->
        %{
          "filename" => "assets/logo#{i}.png",
          "status" => "added",
          "additions" => 0,
          "deletions" => 0
        }

      rem(i, 25) == 0 ->
        %{
          "filename" => "data/rates#{i}.json",
          "status" => "modified",
          "additions" => 4000,
          "deletions" => 12
        }

      true ->
        %{
          "filename" => "src/file#{i}.ts",
          "status" => "modified",
          "patch" => "@@ -1 +1,2 @@\n-a\n+b\n+c",
          "additions" => 2,
          "deletions" => 1
        }
    end
  end

  defp diff_slices(context, extra, cursor \\ nil) do
    body =
      context
      |> Shared.pr_ref()
      |> Map.merge(extra)
      |> then(&if(cursor, do: Map.put(&1, "cursor", cursor), else: &1))

    assert {200, slice} = World.http_post(context, "/api/pull-requests/diff", body)

    case slice["nextCursor"] do
      nil -> [slice]
      next -> [slice | diff_slices(context, extra, next)]
    end
  end

  # `{path, {additions, deletions}}` per file section of a patch, from its hunk lines.
  defp patch_counts(patch) do
    patch
    |> String.split(~r/^diff --git /m, trim: true)
    |> Enum.map(fn section ->
      [header | lines] = String.split(section, "\n")
      [_, path] = Regex.run(~r/ b\/(.+)$/, header)

      body =
        Enum.reject(lines, &(String.starts_with?(&1, "--- ") or String.starts_with?(&1, "+++ ")))

      {path,
       {Enum.count(body, &String.starts_with?(&1, "+")),
        Enum.count(body, &String.starts_with?(&1, "-"))}}
    end)
  end

  defp omitted(slice),
    do:
      for(s <- slice["omittedFileStats"] || [], do: {s["path"], {s["additions"], s["deletions"]}})

  # A withheld file's section counts nothing; its stats say what it holds.
  defp merge_counts({0, 0}, counts), do: counts
  defp merge_counts(counts, {0, 0}), do: counts
end
