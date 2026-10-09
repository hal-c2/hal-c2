defmodule HalC2.Steps.SourceControl.PullRequestList do
  @moduledoc """
  The fake GitHub holds a few pull requests in each repository and answers a
  `gh pr list` search the way GitHub would for the qualifier it carries: one rule
  per repository, state and qualifier, so a listing that sends the wrong search
  gets the wrong rows.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.SourceControl.Shared
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @me "monalisa"

  defp success, do: [%{"name" => "ci", "status" => "COMPLETED", "conclusion" => "SUCCESS"}]
  defp failure, do: [%{"name" => "ci", "status" => "COMPLETED", "conclusion" => "FAILURE"}]
  defp label(name), do: %{"name" => name, "color" => "d73a4a"}

  defp fixture do
    %{
      "acme/shop" => [
        Shared.gh_pr("acme/shop", 1, %{
          "title" => "Add the tax table",
          "author" => %{"login" => @me},
          "labels" => [label("bug")],
          "reviewDecision" => "APPROVED",
          "statusCheckRollup" => success(),
          "updatedAt" => "2026-09-20T00:00:00Z"
        }),
        Shared.gh_pr("acme/shop", 2, %{
          "title" => "Fix cart rounding",
          "isDraft" => true,
          "reviewRequests" => [%{"login" => @me}],
          "reviewDecision" => "CHANGES_REQUESTED",
          "statusCheckRollup" => failure(),
          "updatedAt" => "2026-09-19T00:00:00Z"
        }),
        Shared.gh_pr("acme/shop", 3, %{"state" => "CLOSED", "title" => "An old idea"}),
        Shared.gh_pr("acme/shop", 4, %{"state" => "MERGED", "author" => %{"login" => @me}})
      ],
      "acme/api" => [
        Shared.gh_pr("acme/api", 10, %{
          "title" => "Tax rounding in the API",
          "reviewRequests" => [%{"login" => @me}],
          "reviewDecision" => "REVIEW_REQUIRED",
          "labels" => [label("bug")],
          "statusCheckRollup" => failure(),
          "updatedAt" => "2026-09-18T00:00:00Z"
        }),
        Shared.gh_pr("acme/api", 11, %{
          "title" => "Document the endpoints",
          "author" => %{"login" => "hubot"},
          "isDraft" => true,
          "statusCheckRollup" => success(),
          "updatedAt" => "2026-09-17T00:00:00Z"
        })
      ]
    }
  end

  defp requested?(pr), do: Enum.any?(pr["reviewRequests"], &(&1["login"] == @me))
  defp author?(pr, login), do: pr["author"]["login"] == login
  defp labelled?(pr, name), do: Enum.any?(pr["labels"], &(&1["name"] == name))

  defp checks?(pr, conclusion),
    do: Enum.any?(pr["statusCheckRollup"], &(&1["conclusion"] == conclusion))

  # What GitHub's search does with each qualifier the MC may send.
  defp qualifiers do
    [
      {"review-requested:#{@me}", &requested?/1},
      {"--author #{@me}", &author?(&1, @me)},
      {"draft:true", & &1["isDraft"]},
      {"draft:false", &(not &1["isDraft"])},
      {"review:changes_requested", &(&1["reviewDecision"] == "CHANGES_REQUESTED")},
      {"review:required", &(&1["reviewDecision"] == "REVIEW_REQUIRED")},
      {"status:failure", &checks?(&1, "FAILURE")},
      {"status:success", &checks?(&1, "SUCCESS")},
      {~s(label:"bug"), &labelled?(&1, "bug")},
      {~s(author:"octocat"), &author?(&1, "octocat")},
      {~s(author:"#{@me}"), &author?(&1, @me)},
      {"tax label:bug", &(&1["title"] =~ ~r/tax/i)}
    ]
  end

  defp search_rules do
    for {repository, prs} <- fixture(),
        {state, raw} <- [{"open", "OPEN"}, {"closed", "CLOSED"}, {"merged", "MERGED"}],
        in_state = Enum.filter(prs, &(&1["state"] == raw)),
        {qualifier, keep} <- qualifiers() ++ [{nil, fn _ -> true end}] do
      %{
        "args" =>
          ["pr list", "--repo github.com/#{repository}", "--state #{state}"] ++
            List.wrap(qualifier),
        "stdout" => Enum.filter(in_state, keep)
      }
    end
  end

  defp list(context, input \\ %{}) do
    {reply, context} =
      World.call(context, "pullRequests.list", Map.put_new(input, "state", "open"))

    Map.put(context, :reply, reply)
  end

  defp entries(context) do
    assert {:ok, %{"entries" => entries}} = context.reply
    entries
  end

  defp listed(context), do: MapSet.new(entries(context), &{&1["repository"], &1["number"]})

  defp expected(fun) do
    for {repository, prs} <- fixture(),
        pr <- prs,
        pr["state"] == "OPEN",
        fun.(pr),
        into: MapSet.new() do
      {repository, pr["number"]}
    end
  end

  step "a connected environment with the GitHub projects {string} and {string}",
       %{args: [first, second]} = context do
    context
    |> World.github_project(first)
    |> World.github_project(second)
    |> World.cli_rules(search_rules())
    |> then(&World.put_client(&1, World.client(&1)))
  end

  step "the GitHub CLI is installed and signed in", context do
    HalC2.PullRequests.invalidate(%{})

    {reply, context} =
      World.call(context, "pullRequests.routingIdentity", %{"host" => "github.com"})

    assert {:ok, %{"viewer" => @me}} = reply
    context
  end

  @involvement %{
    "from all involvement" => {"all", "in either project"},
    "the user is reviewing" => {"reviewing", "where the user's review is requested"},
    "the user authored" => {"authored", "the user opened"}
  }

  step ~r/^the user lists pull requests (?<involvement>from all involvement|the user is reviewing|the user authored)$/,
       %{args: [involvement]} = context do
    {value, _} = @involvement[involvement]
    list(context, %{"involvement" => value})
  end

  step ~r/^only pull requests (?<which>in either project|where the user's review is requested|the user opened) are listed$/,
       %{args: [which]} = context do
    wanted =
      case which do
        "in either project" -> expected(fn _ -> true end)
        "where the user's review is requested" -> expected(&requested?/1)
        "the user opened" -> expected(&author?(&1, @me))
      end

    assert listed(context) == wanted

    if which =~ "review is requested",
      do: assert(Enum.all?(entries(context), & &1["viewerReviewRequested"]))

    context
  end

  step ~r/^the user lists (?<state>open|closed|merged) pull requests$/,
       %{args: [state]} = context do
    list(context, %{"state" => state})
  end

  step ~r/^every listed pull request is (?<state>open|closed|merged)$/,
       %{args: [state]} = context do
    assert [_ | _] = entries(context)
    assert Enum.all?(entries(context), &(&1["state"] == state)), inspect(entries(context))
    context
  end

  defp filters do
    %{
      "drafts only" => {%{"draft" => "only"}, & &1["isDraft"]},
      "drafts hidden" => {%{"draft" => "hide"}, &(not &1["isDraft"])},
      "changes requested" =>
        {%{"review" => "changes-requested"}, &(&1["reviewDecision"] == "CHANGES_REQUESTED")},
      "review required" =>
        {%{"review" => "review-required"}, &(&1["reviewDecision"] == "REVIEW_REQUIRED")},
      "failing checks" => {%{"checks" => "failing"}, &checks?(&1, "FAILURE")},
      "passing checks" => {%{"checks" => "passing"}, &checks?(&1, "SUCCESS")},
      ~s(the label "bug") => {%{"labels" => [["bug"]]}, &labelled?(&1, "bug")},
      ~s(the author "octocat") => {%{"author" => "octocat"}, &author?(&1, "octocat")},
      "the author being the user" => {%{"author" => "@me"}, &author?(&1, "monalisa")}
    }
  end

  step ~r/^the user lists open pull requests with (?<filter>.+)$/, %{args: [filter]} = context do
    {filters, _} = filters()[filter] || flunk("no filter #{inspect(filter)}")
    list(context, %{"filters" => filters})
  end

  step ~r/^only pull requests matching (?<filter>.+) are listed$/, %{args: [filter]} = context do
    {_, keep} = filters()[filter]
    wanted = expected(keep)
    assert MapSet.size(wanted) > 0
    # Some open pull request is left out, so the filter did something.
    assert MapSet.size(wanted) < MapSet.size(expected(fn _ -> true end))
    assert listed(context) == wanted
    context
  end

  step "the user searches pull requests for {string}", %{args: [query]} = context do
    context |> list(%{"query" => query}) |> Map.put(:query, query)
  end

  step "the search runs on GitHub for each project", context do
    for repository <- ["acme/shop", "acme/api"] do
      assert Enum.any?(
               World.cli_calls(context, "--repo github.com/#{repository}"),
               &Enum.any?(&1["args"], fn arg -> String.contains?(arg, ~s("#{context.query}")) end)
             ),
             "no search of #{repository} for #{context.query}"
    end

    context
  end

  step "matching pull requests are listed", context do
    assert listed(context) == MapSet.new([{"acme/shop", 1}, {"acme/api", 10}])
    context
  end

  step "{string} has {int} open pull requests", %{args: [repository, n]} = context do
    prs =
      for number <- n..1//-1 do
        at = DateTime.add(~U[2026-09-01 00:00:00Z], number * 60) |> DateTime.to_iso8601()
        Shared.gh_pr(repository, number, %{"updatedAt" => at})
      end

    context
    |> World.cli_rules(%{
      "args" => ["pr list", "--repo github.com/#{repository}", "--state open"],
      "stdout" => prs
    })
    |> Map.merge(%{many: {repository, prs}})
  end

  step "the user loads more pull requests", context do
    {repository, prs} = context.many
    context = list(context)
    first = entries(context)
    assert {:ok, %{"nextCursors" => cursors}} = context.reply
    assert [{_, cursor}] = Map.to_list(cursors)
    [boundary | _] = String.split(cursor, "|")

    # GitHub answers the carried-on search with what is no newer than the boundary.
    older = Enum.filter(prs, &(&1["updatedAt"] <= boundary))

    context
    |> World.cli_rules(%{
      "args" => ["pr list", "--repo github.com/#{repository}", "updated:<=#{boundary}"],
      "stdout" => older
    })
    |> list(%{"cursors" => cursors})
    |> Map.put(:first_page, first)
  end

  step "the next pull requests follow without repeating any", context do
    {repository, prs} = context.many
    numbers = &for(e <- &1, e["repository"] == repository, do: e["number"])
    first = numbers.(context.first_page)
    second = numbers.(entries(context))
    all = Enum.map(prs, & &1["number"])

    assert first == Enum.take(all, length(first))
    assert second != []
    assert second == all |> Enum.drop(length(first)) |> Enum.take(length(second))
    context
  end

  step "the rows arrive first and their line counts follow", context do
    rows = entries(context)
    assert Enum.all?(rows, &(&1["additions"] == 0 and &1["deletions"] == 0))

    refs = for r <- rows, do: Map.take(r, ["projectId", "repository", "number"])

    data =
      for {ref, index} <- Enum.with_index(refs), into: %{} do
        {"s#{index}", %{"pullRequest" => %{"additions" => ref["number"] * 10, "deletions" => 1}}}
      end

    context =
      World.cli_rules(context, %{
        "args" => ["api graphql"],
        "stdin" => ["additions deletions"],
        "stdout" => %{"data" => data}
      })

    {{:ok, %{"stats" => stats}}, context} =
      World.call(context, "pullRequests.listStats", %{"refs" => refs})

    assert Enum.sort(for s <- stats, do: {s["repository"], s["number"], s["additions"]}) ==
             Enum.sort(for r <- refs, do: {r["repository"], r["number"], r["number"] * 10})

    context
  end

  step ~r/^the project "(?<title>[^"]+)" has its remote on (?<host>GitLab|Forgejo|Azure DevOps|Bitbucket)$/,
       %{args: [title, host]} = context do
    url =
      %{
        "GitLab" => "git@gitlab.com:acme/infra.git",
        "Forgejo" => "https://codeberg.org/acme/infra.git",
        "Azure DevOps" => "https://dev.azure.com/acme/infra/_git/infra",
        "Bitbucket" => "git@bitbucket.org:acme/infra.git"
      }[host]

    context = World.create_project(context, title)
    World.git!(World.project(context, title).root, ["remote", "add", "origin", url])
    context
  end

  # Backlog: the MC has no change request driver for hosts other than GitHub.
  step "the open change requests of {string} are listed", %{args: [title]} = context do
    id = World.project(context, title).id
    assert Enum.any?(entries(context), &(&1["projectId"] == id)), inspect(context.reply)
    context
  end

  step "the user lists pull requests", context do
    list(context)
  end

  step "{word} is listed as not configured with {string}", %{args: [host, detail]} = context do
    assert {:ok, %{"providers" => providers}} = context.reply
    kind = %{"GitLab" => "gitlab"}[host]

    assert %{"configured" => false, "detail" => ^detail} =
             Enum.find(providers, &(&1["kind"] == kind))

    # The GitHub projects are still listed beside it.
    assert [_ | _] = entries(context)
    context
  end

  step ~r/^"(?<repository>[^"]+)" reports it is unavailable because (?<reason>.+)$/,
       %{args: [_repository, reason]} = context do
    assert {:error, message, detail} = context.reply
    assert %{"_tag" => "PullRequestUnavailableError", "provider" => "github"} = detail

    case reason do
      "the GitHub CLI is required and how to install it" ->
        assert detail["reason"] == "cli-missing"
        assert message =~ "is required" and message =~ "https://cli.github.com/"

      "the user should run gh auth login and retry" ->
        assert detail["reason"] == "cli-unauthenticated"
        assert message =~ "gh auth login" and message =~ "retry"
    end

    context
  end

  step "{string} cannot be read", %{args: [repository]} = context do
    World.cli_rules(context, %{
      "args" => ["pr list", "--repo github.com/#{repository}"],
      "stderr" => "HTTP 502: Bad Gateway\n",
      "exit" => 1
    })
  end

  step "the pull requests of {string} are listed", %{args: [repository]} = context do
    assert Enum.map(entries(context), & &1["repository"]) |> Enum.uniq() == [repository]
    context
  end

  step "{string} reports its own error with the host's reason, phrased for the user",
       %{args: [repository]} = context do
    assert {:ok, %{"errors" => errors}} = context.reply
    assert [%{"message" => message, "reason" => reason, "detail" => detail}] = errors
    # Words a user can act on, whatever the host; what it said stays in `detail`.
    assert reason == "github.com did not answer in time. Try again."
    assert message == "#{repository} could not be read: #{reason}"
    assert detail == "HTTP 502: Bad Gateway"
    refute message =~ "502"
    context
  end

  step "the user is looking at the pull request list", context do
    Mc.ensure(HalC2.PullRequests.Refreshes)
    id = System.unique_integer([:positive])
    shape = %{"type" => "pullRequestRefreshes", "mc" => Atom.to_string(node())}
    client = Mc.sub(World.client(context), id, shape)
    {frame, client} = Mc.await(client, &(&1["t"] == "pullRequestRefreshes" and &1["id"] == id))

    context
    |> World.put_client(client)
    |> Map.put(:refreshes, {id, frame["revision"]})
  end

  step "someone merges a pull request from HAL-C2", context do
    context =
      World.cli_rules(context, [
        Shared.permissions_rule("WRITE"),
        %{"args" => ["pr merge 1", "--squash"]}
      ])

    {reply, context} =
      World.call(
        context,
        "pullRequests.runAction",
        %{
          "projectId" => World.project(context, "acme/shop").id,
          "repository" => "acme/shop",
          "number" => 1,
          "action" => "merge",
          "mergeMethod" => "squash"
        },
        "someone"
      )

    assert {:ok, _} = reply
    context
  end

  step "the client is told to refresh the list", context do
    {id, before} = context.refreshes

    {frame, client} =
      Mc.await(World.client(context), &(&1["t"] == "pullRequestRefreshes" and &1["id"] == id))

    assert frame["revision"] > before
    World.put_client(context, client)
  end

  step "the user refreshes the pull request list by hand", context do
    context = list(context)

    before = %{
      user: length(World.cli_calls(context, "api user")),
      list: length(World.cli_calls(context, "pr list"))
    }

    {{:ok, _}, context} = World.call(context, "pullRequests.invalidate", %{})
    Map.put(context, :calls_before, before)
  end

  step "the MC reads the pull requests afresh", context do
    context = list(context)
    assert length(World.cli_calls(context, "api user")) == context.calls_before.user + 1
    assert length(World.cli_calls(context, "pr list")) > context.calls_before.list
    context
  end
end
