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
    Map.put(context, :reply, reply)
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
    # The editor sends only what changed (`pullRequestEditing.logic.ts`): nothing here.
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

    context
    |> Map.put(:changed_files, files)
    |> World.cli_rules([
      %{
        "args" => ["pr diff #{number}"],
        "exit" => 1,
        "stderr" => "HTTP 406: Sorry, the diff exceeded the maximum number of files (300)."
      }
      | rules
    ])
  end

  step "the user opens its code", context do
    Map.put(context, :slices, diff_slices(context, %{}))
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
    old = "export const total = (items) => sum(items)\n"
    new = "export const total = (items) => round(sum(items))\n"

    context =
      World.cli_rules(context, [
        %{
          "args" => ["repos/acme/shop/pulls/42", "--jq"],
          "stdout" => "#{@base}\t#{Shared.pr_sha()}\n"
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
          mine,
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
          "author" => %{"login" => "hubot"},
          "body" => "Nice.",
          "state" => "APPROVED",
          "submittedAt" => "2026-09-04T00:00:00Z"
        },
        %{
          "id" => "R_2",
          "author" => %{"login" => "hubot"},
          "body" => "",
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
                %{"dismissalMessage" => "Outdated after the rebase", "review" => %{"id" => "R_2"}}
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
                      "parents" => %{"totalCount" => 1},
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
                  path <- ["src/cart.ts", "src/tax.ts"],
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
