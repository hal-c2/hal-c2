defmodule HalC2.Steps.SourceControl.PullRequestActions do
  @moduledoc """
  Steps for `features/source-control/pull-request-actions.feature`. GitHub is the fake
  `gh`: a Given reshapes pull request 42 as GitHub reports it (and reads it back through
  `pullRequests.detail`), a When runs the action over the WebSocket, and a Then checks
  what the MC asked of GitHub. The fake keeps no state, so the host-side effect of an
  action is the `gh` call that makes it.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.SourceControl.Shared
  alias HalC2.Test.Mc.World

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

  step "the repository has auto-merge switched off", context do
    Shared.reshape_repository(context, %{"autoMergeAllowed" => false})
  end

  step ~r/^pull request (?<number>\d+) can be merged (?<how>right now|now with failing optional checks)$/,
       %{args: [number, how]} = context do
    assert String.to_integer(number) == context.pr_number
    status = if how == "right now", do: "CLEAN", else: "UNSTABLE"
    Shared.reshape_pr(context, %{"mergeStateStatus" => status})
  end

  # --- maintainer edits --------------------------------------------------------------------

  step "the user opened pull request {int} from their fork of {string}",
       %{args: [number, @repository]} = context do
    assert number == context.pr_number

    context
    |> Map.put(:permission, "READ")
    |> Shared.reshape_pr(%{
      "isCrossRepository" => true,
      "state" => "OPEN",
      "viewerDidAuthor" => true,
      "viewerCanUpdate" => true
    })
    |> World.cli_rules([
      %{
        "args" => ["api graphql"],
        "stdin" => ["maintainerCanModify: $allow"],
        "stdout" => %{"data" => %{}}
      }
    ])
  end

  step ~r/^maintainer edits are (?<state>on|off)(?: for pull request 42)?$/,
       %{args: [state]} = context do
    # Only the author of a fork's pull request is given the choice.
    context
    |> Map.put(:permission, "READ")
    |> Shared.reshape_pr(%{
      "isCrossRepository" => true,
      "state" => "OPEN",
      "viewerDidAuthor" => true,
      "viewerCanUpdate" => true,
      "maintainerCanModify" => state == "on"
    })
  end

  step "pull request {int} comes from a branch of {string} itself",
       %{args: [number, @repository]} = context do
    assert number == context.pr_number

    context
    |> Map.put(:permission, "READ")
    |> Shared.reshape_pr(%{
      "isCrossRepository" => false,
      "viewerDidAuthor" => true,
      "viewerCanUpdate" => true,
      "maintainerCanModify" => false
    })
  end

  step "GitHub refuses the change", context do
    World.cli_rules(context, [
      %{
        "args" => ["api graphql"],
        "stdin" => ["maintainerCanModify: $allow"],
        "stderr" => "GraphQL: Something went wrong.\n",
        "exit" => 1
      }
    ])
  end

  step ~r/^the user (?<action>allows|stops) edits from maintainers$/,
       %{args: [action]} = context do
    act(
      context,
      42,
      if(action == "allows", do: "allow-maintainer-edits", else: "stop-maintainer-edits")
    )
  end

  step ~r{^maintainers of "acme/shop" (?<after>can|can no longer) push to the branch of pull request 42$},
       %{args: [can]} = context do
    assert {:ok, _} = context.reply

    assert [call] =
             context
             |> World.cli_calls("api graphql")
             |> Enum.filter(&(&1["stdin"] =~ "maintainerCanModify: $allow"))

    assert JSON.decode!(call["stdin"])["variables"]["allow"] == (can == "can")
    context
  end

  step "the user is told this also gives the branch's workflows access to the repository's secrets",
       context do
    notice = Shared.pr_detail!(context)["maintainerEdits"]["notice"]
    assert notice =~ "access to the repository's secrets"
    context
  end

  step "allowing edits from maintainers is not offered", context do
    refute "allow-maintainer-edits" in context.viewer["actions"]
    refute Map.has_key?(Shared.pr_detail!(context), "maintainerEdits")
    context
  end

  step "the user is told the change failed", context do
    assert is_binary(World.failure(context))
    context
  end

  step "maintainer edits read as off again", context do
    assert Shared.pr_detail!(context)["maintainerEdits"]["allowed"] == false
    context
  end

  # --- access ----------------------------------------------------------------------------

  step "pull request {int} was opened by someone else", %{args: [number]} = context do
    assert number == context.pr_number
    Shared.reshape_pr(context, %{"viewerDidAuthor" => false})
  end

  step "the user opened pull request {int} and has only read access to {string}",
       %{args: [number, @repository]} = context do
    assert number == context.pr_number

    context
    |> Map.put(:permission, "READ")
    |> Shared.reshape_pr(%{"viewerDidAuthor" => true, "viewerCanUpdate" => true})
  end

  @tries %{
    "mark pull request 42 ready for review" => "ready",
    "return pull request 42 to draft" => "draft",
    "close pull request 42" => "close",
    "reopen pull request 42" => "reopen",
    "update the branch of pull request 42" => "update-branch",
    "stop auto-merge on pull request 42" => "disable-auto-merge",
    "approve the workflows of fork pull request 42" => "approve-workflows"
  }

  step ~r/^the user tries to (?<action>mark pull request 42 ready for review|return pull request 42 to draft|close pull request 42|reopen pull request 42|update the branch of pull request 42|stop auto-merge on pull request 42|approve the workflows of fork pull request 42)$/,
       %{args: [action]} = context do
    extra = if @tries[action] == "update-branch", do: %{"updateMethod" => "merge"}, else: %{}
    act(context, 42, @tries[action], extra)
  end

  step "closing, reopening, marking ready and returning to draft are offered", context do
    assert ~w(close reopen ready draft) -- context.viewer["actions"] == []
    context
  end

  step "merging, auto-merge, reverting and approving workflows are not offered", context do
    for action <- ~w(merge enable-auto-merge disable-auto-merge revert approve-workflows) do
      refute action in context.viewer["actions"]
    end

    context
  end

  step "GitHub does not say the user may update its branch", context do
    Shared.reshape_pr(context, %{"viewerCanUpdateBranch" => false})
  end

  step "updating the branch is offered to nobody", context do
    for permission <- ~w(WRITE READ) do
      detail =
        context |> Map.put(:permission, permission) |> Shared.answer_pr() |> Shared.pr_detail!()

      refute "update-branch" in detail["viewerPermissions"]["actions"]
    end

    context
  end

  step "the page offered merging pull request {int}", %{args: [number]} = context do
    assert number == context.pr_number
    assert "merge" in Shared.pr_detail!(context)["viewerPermissions"]["actions"]
    context
  end

  step "the user's write access to {string} has since been withdrawn",
       %{args: [@repository]} = context do
    context |> Map.put(:permission, "READ") |> Shared.answer_pr()
  end

  step "the user merges pull request {int}", %{args: [number]} = context do
    act(context, number, "merge", %{"mergeMethod" => "merge"})
  end

  step "pull request {int} is not merged", %{args: [number]} = context do
    assert number == context.pr_number
    assert World.cli_calls(context, "pr merge") == []
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

  step "enabling auto-merge on pull request {int} is not offered", %{args: [number]} = context do
    assert number == context.pr_number
    viewer = Shared.pr_detail!(context)["viewerPermissions"]
    refute "enable-auto-merge" in viewer["actions"]

    # Nor done when asked anyway: the MC refuses it before GitHub is.
    context = act(context, number, "enable-auto-merge")
    assert World.failure(context) =~ "Auto-merge is not available here"
    assert World.cli_calls(context, "pr merge") == []
    Map.put(context, :viewer, viewer)
  end

  step "merging it directly still is, when the user may merge", context do
    assert "merge" in context.viewer["actions"]

    # A reader still may not.
    context = context |> Map.put(:permission, "READ") |> Shared.answer_pr()
    refute "merge" in Shared.pr_detail!(context)["viewerPermissions"]["actions"]
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
    assert List.last(args -- ["--include"]) == "repos/acme/shop/issues/#{number}/labels/bug"
    context
  end

  # --- checking out ----------------------------------------------------------------------

  step "the checkout's {string} is on github.com", %{args: [repository]} = context do
    context = World.github_project(context, repository)
    Map.merge(context, %{cwd: World.project(context, repository).root, checkout: repository})
  end

  # The pull request's branch on `host` holds a commit of its own, and github.com has a
  # same-named repository whose same-named branch and pull request ref hold another.
  step ~r/^pull request 42 of "(?<repository>[^"]+)" is on (?<forgejo>a Forgejo at |)(?<host>\S+)$/,
       %{args: [repository, forgejo, host]} = context do
    root = context.cwd
    branch = "feature/web"
    remotes = System.get_env("HAL_C2_FAKE_REMOTES")
    bare = Path.join([remotes, "@#{host}", "#{repository}.git"])
    File.mkdir_p!(Path.dirname(bare))
    World.git!(remotes, ["init", "-q", "--bare", "-b", "main", bare])
    World.git!(root, ["push", "-q", bare, "main"])

    World.git!(root, ["checkout", "-q", "-b", branch])
    World.commit!(root, %{"web.txt" => "github.com\n"}, "Same-named branch on github.com")

    World.git!(root, [
      "push",
      "-q",
      "origin",
      "HEAD:refs/heads/#{branch}",
      "HEAD:refs/pull/42/head"
    ])

    World.git!(root, ~w(checkout -q main))
    World.git!(root, ["checkout", "-q", "-B", branch])
    head = World.commit!(root, %{"web.txt" => "#{host}\n"}, "The pull request on #{host}")
    World.git!(root, ["push", "-q", bare, "HEAD:refs/heads/#{branch}", "HEAD:refs/pull/42/head"])
    World.git!(root, ~w(checkout -q main))
    World.git!(root, ["branch", "-q", "-D", branch])

    context =
      if forgejo != "" do
        url = "https://#{host}/#{repository}/pulls/42"

        pr = %{
          "number" => 42,
          "title" => "Web work",
          "html_url" => url,
          "state" => "open",
          "merged" => false,
          "base" => %{"ref" => "main", "repo" => %{"full_name" => repository}},
          "head" => %{"ref" => branch, "sha" => head, "repo" => %{"full_name" => repository}}
        }

        context
        |> Shared.forgejo_api(%{"/api/v1/repos/#{repository}/pulls/42" => {200, pr}}, host)
        |> Map.put(:reference, url)
      else
        url = "https://#{host}/#{repository}/pull/42"
        [owner, name] = String.split(repository, "/")

        context
        |> World.cli_rules(%{
          "args" => ["pr view #{url} "],
          "stdout" => %{
            "number" => 42,
            "title" => "Web work",
            "url" => url,
            "baseRefName" => "main",
            "headRefName" => branch,
            "state" => "OPEN",
            "isCrossRepository" => false,
            "headRepository" => %{"name" => name, "nameWithOwner" => repository},
            "headRepositoryOwner" => %{"login" => owner},
            "headRefOid" => head
          }
        })
        |> Map.put(:reference, url)
      end

    Map.merge(context, %{pr_head: head, pr_host: host})
  end

  # `ssh -G <alias>` answers from the scenario's own fake `ssh` rules (on its PATH), never a
  # global `:ssh_command`, which concurrent scenarios would share.
  step ~r/^the checkout's "(?<repository>[^"]+)" is reached as the (?<userless>userless|user-named) ssh alias "(?<alias>[^"]+)" for github.com$/,
       %{args: [repository, userless, alias_name]} = context do
    context = World.github_project(context, repository)
    root = World.project(context, repository).root

    context =
      context
      |> World.fake_cli(["ssh"])
      |> World.cli_rules(%{
        "cmd" => "ssh",
        "args" => ["-G", alias_name],
        "stdout" => "hostname github.com\n"
      })

    user = if userless == "user-named", do: "git@", else: ""
    World.git!(root, ["remote", "set-url", "origin", "#{user}#{alias_name}:#{repository}.git"])

    context
    |> Map.merge(%{cwd: root, checkout: repository})
    |> HalC2.Steps.SourceControl.PullRequestThreads.answer_view()
  end

  step "the user checks out pull request 42 by its github.com URL in this repository", context do
    {reply, context} =
      World.call(context, "git.preparePullRequestThread", %{
        "cwd" => context.cwd,
        "reference" => "https://github.com/acme/shop/pull/42",
        "mode" => "local"
      })

    Map.put(context, :reply, reply)
  end

  step "it is checked out through the checkout's own remote", context do
    assert {:ok, %{"branch" => "feature/tax", "isOnPullRequestHead" => true}} = context.reply
    assert World.git!(context.cwd, ~w(remote)) == "origin"
    assert World.git!(context.cwd, ~w(config branch.feature/tax.remote)) == "origin"
    assert World.git!(context.cwd, ~w(rev-parse HEAD)) == context.pr_head
    assert [_] = World.cli_calls(context, "pr checkout 42")
    context
  end

  step ~r/^the user checks out pull request 42 (?<where>in this repository|in a separate worktree)(?: from its review)?$/,
       %{args: [where]} = context do
    context = if context[:reference], do: context, else: context |> Map.put(:reference, "42")

    {reply, context} =
      World.call(context, "git.preparePullRequestThread", %{
        "cwd" => context.cwd,
        "reference" => context.reference,
        "mode" => if(where == "in this repository", do: "local", else: "worktree")
      })

    Map.put(context, :reply, reply)
  end

  step ~r/^the branch holds the pull request's commit from (?:a Forgejo at )?\S+$/, context do
    assert {:ok, %{"isOnPullRequestHead" => true} = prepared} = context.reply
    path = prepared["worktreePath"] || context.cwd
    assert World.git!(path, ~w(branch --show-current)) == prepared["branch"]
    assert World.git!(path, ~w(rev-parse HEAD)) == context.pr_head
    Map.put(context, :prepared, prepared)
  end

  step ~r/^it tracks the repository on (?:a Forgejo at )?(?<host>\S+)$/,
       %{args: [host]} = context do
    path = context.prepared["worktreePath"] || context.cwd
    branch = context.prepared["branch"]
    remote = World.git!(path, ["config", "branch.#{branch}.remote"])

    assert World.git!(path, ["config", "remote.#{remote}.url"]) ==
             "git@#{host}:#{context.checkout}.git"

    assert World.git!(path, ~w(rev-parse @{upstream})) == context.pr_head
    context
  end

  step ~r/^the repository has (?<state>uncommitted changes to tracked files|the pull request's branch (?:with commits not yet pushed|behind the pull request|with commits of its own and the pull request has moved on))$/,
       %{args: [state]} = context do
    context = HalC2.Steps.SourceControl.PullRequestThreads.answer_view(context)
    root = context.cwd

    case state do
      "uncommitted changes to tracked files" ->
        [file | _] = String.split(World.git!(root, ~w(ls-files)), "\n")
        path = Path.join(root, file)
        edited = File.read!(path) <> "my edit\n"
        File.write!(path, edited)
        Map.put(context, :edited, {path, edited})

      "the pull request's branch with commits not yet pushed" ->
        World.git!(root, ["checkout", "-q", "-b", "feature/tax", context.pr_head])
        mine = World.commit!(root, %{"mine.txt" => "mine\n"}, "Not pushed yet")
        World.git!(root, ~w(checkout -q main))
        Map.put(context, :mine, mine)

      "the pull request's branch behind the pull request" ->
        World.git!(root, ~w(branch feature/tax main))
        context

      "the pull request's branch with commits of its own and the pull request has moved on" ->
        World.git!(root, ~w(checkout -q -b feature/tax main))
        mine = World.commit!(root, %{"mine.txt" => "mine\n"}, "Not pushed yet")
        World.git!(root, ~w(checkout -q main))
        Map.put(context, :mine, mine)
    end
  end

  step "the checkout is refused and the changes are kept", context do
    assert World.failure(context) =~ "This repository has uncommitted changes."
    {path, edited} = context.edited
    assert File.read!(path) == edited
    assert World.git!(context.cwd, ~w(branch --show-current)) == "main"
    assert World.cli_calls(context, "pr checkout") == []
    context
  end

  step "the commits are kept and the user is told it is not on the latest commits", context do
    assert {:ok, %{"branch" => "feature/tax", "isOnPullRequestHead" => false}} = context.reply
    assert World.git!(context.cwd, ~w(branch --show-current)) == "feature/tax"
    assert World.git!(context.cwd, ~w(rev-parse HEAD)) == context.mine
    context
  end

  step "the checkout is refused and the branch is left as it was", context do
    assert World.failure(context) =~ "Nothing was changed."
    assert World.git!(context.cwd, ~w(branch --show-current)) == "main"
    assert World.git!(context.cwd, ~w(rev-parse feature/tax)) == context.mine
    assert World.cli_calls(context, "pr checkout") == []
    context
  end

  step "the branch moves forward to the pull request's latest commit", context do
    assert {:ok, %{"branch" => "feature/tax", "isOnPullRequestHead" => true}} = context.reply
    assert World.git!(context.cwd, ~w(branch --show-current)) == "feature/tax"
    assert World.git!(context.cwd, ~w(rev-parse HEAD)) == context.pr_head
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
