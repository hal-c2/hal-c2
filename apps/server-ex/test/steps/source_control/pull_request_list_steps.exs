defmodule HalC2.Steps.SourceControl.PullRequestList do
  @moduledoc """
  The fake GitHub holds a few pull requests in each repository and answers a
  pull request search the way GitHub would for the qualifier it carries: one rule
  per repository, state and qualifier, so a listing that sends the wrong search
  gets the wrong rows. A repository's own list answers with all of a state's.
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
      {"author:#{@me} ", &author?(&1, @me)},
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
        {qualifier, keep} <-
          qualifiers() ++ [{nil, fn _ -> true end}, {:own, fn _ -> true end}] do
      matches =
        case qualifier do
          :own ->
            ["PullRequestListRepository", ~s("states":["#{raw}"])]

          nil ->
            ["PullRequestListSearch", "is:#{state} "]

          # As it sits in the request's JSON.
          text ->
            [
              "PullRequestListSearch",
              "is:#{state} ",
              text |> JSON.encode!() |> String.slice(1..-2//1)
            ]
        end

      %{
        "args" => ["api graphql"],
        "repository" => repository,
        "stdin" => matches,
        "pulls" => Enum.filter(in_state, keep)
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
               World.pull_listings(context),
               &(&1["variables"]["q"] =~ "repo:#{repository} " and
                   &1["variables"]["q"] =~ ~s("#{context.query}"))
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
      "args" => ["api graphql"],
      "repository" => repository,
      "stdin" => ["is:open "],
      "pulls" => prs
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
      "args" => ["api graphql"],
      "repository" => repository,
      "stdin" => ["updated:<=#{boundary}"],
      "pulls" => older
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
      "args" => ["api graphql"],
      "repository" => repository,
      "stderr" => "HTTP 502: Bad Gateway\n",
      "exit" => 1
    })
  end

  step "GitHub gives up on reading more than {int} of them at once", %{args: [most]} = context do
    {repository, _prs} = context.many

    gave_up =
      for first <- (most + 1)..100 do
        %{
          "args" => ["api graphql"],
          "repository" => repository,
          "stdin" => [~s("first":#{first},)],
          "stderr" => "HTTP 504: 504 Gateway Timeout (https://api.github.com/graphql)\n",
          "exit" => 1
        }
      end

    World.cli_rules(context, gave_up)
  end

  step "all {int} open pull requests of {string} are listed",
       %{args: [count, repository]} = context do
    numbers = for e <- entries(context), e["repository"] == repository, do: e["number"]
    assert numbers == Enum.to_list(count..1//-1)
    context
  end

  step "no project reports an error", context do
    assert {:ok, %{"errors" => []}} = context.reply
    context
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
      list: length(World.pull_listings(context))
    }

    {{:ok, _}, context} = World.call(context, "pullRequests.invalidate", %{})
    Map.put(context, :calls_before, before)
  end

  step "the MC reads the pull requests afresh", context do
    context = list(context)
    assert length(World.cli_calls(context, "api user")) == context.calls_before.user + 1
    assert length(World.pull_listings(context)) > context.calls_before.list
    context
  end

  # --- rate limits (`HalC2.GitHub.Limits`), on a clock the steps move ---------------

  @rate_limited %{
    "args" => ["api graphql"],
    "stderr" => "GraphQL: API rate limit exceeded for user ID 7.\n",
    "exit" => 1
  }

  defp clock(context) do
    ref = :atomics.new(1, signed: true)
    :atomics.put(ref, 1, DateTime.to_unix(~U[2026-11-03 10:00:00Z], :millisecond))
    Application.put_env(:hal_c2, :github_clock, fn -> :atomics.get(ref, 1) end)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :github_clock) end)
    Map.put(context, :clock, ref)
  end

  defp now(context), do: :atomics.get(context.clock, 1)
  defp move_clock(context, ms), do: :atomics.put(context.clock, 1, ms)

  # Lists past the MC's own cache, so what is asked of GitHub is up to the gate.
  defp relist(context) do
    HalC2.PullRequests.invalidate(%{})
    list(context)
  end

  defp graphql_calls(context), do: length(World.cli_calls(context, "api graphql"))

  defp unlimit(context) do
    rules = context.cli.rules |> File.read!() |> JSON.decode!() |> List.delete(@rate_limited)
    File.write!(context.cli.rules, JSON.encode!(rules))
    context
  end

  # The time every GitHub project's error says calls resume, "HH:MM:SS".
  defp paused_until(context) do
    assert {:ok, %{"errors" => errors}} = context.reply
    assert errors |> Enum.map(& &1["repository"]) |> Enum.sort() == ["acme/api", "acme/shop"]

    [until] =
      errors
      |> Enum.map(fn %{"message" => message} ->
        assert [_, at] = Regex.run(~r/paused until it resets at (\d\d:\d\d:\d\d) UTC/, message)
        at
      end)
      |> Enum.uniq()

    until
  end

  defp at(ms), do: ms |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%H:%M:%S")

  # Lists again with nothing asked of GitHub, and the pause ending at `until`.
  defp still_paused(context, until) do
    before = graphql_calls(context)
    context = relist(context)
    assert graphql_calls(context) == before
    assert paused_until(context) == at(until)
    context
  end

  # GitHub turns a listing away while `until` holds the pause that follows.
  defp limited_again(context, pause) do
    context = relist(context)
    assert {:ok, %{"errors" => [_, _]}} = context.reply
    until = now(context) + pause
    context |> still_paused(until) |> Map.put(:until, until)
  end

  step "GitHub answers a read with a rate limit and no time to retry", context do
    context = context |> clock() |> World.cli_rules(@rate_limited) |> relist()
    Map.put(context, :until, now(context) + 30_000)
  end

  step "GitHub answers a read with a rate limit and its read budget resets in 10 minutes",
       context do
    context = clock(context)
    reset = div(now(context), 1_000) + 600
    budget = &%{"limit" => 5000, "remaining" => &1, "reset" => reset}

    context
    |> World.cli_rules([
      @rate_limited,
      %{
        "args" => ["api rate_limit"],
        "stdout" => %{"resources" => %{"graphql" => budget.(0), "core" => budget.(4999)}}
      }
    ])
    |> relist()
    |> Map.put(:until, reset * 1_000)
  end

  step "the host is paused after a rate limit", context do
    context = context |> clock() |> World.cli_rules(@rate_limited) |> relist()
    Map.put(context, :until, now(context) + 30_000)
  end

  step "the user lists pull requests again straight away", context do
    context |> Map.put(:graphql_before, graphql_calls(context)) |> relist()
  end

  step "no request goes to GitHub", context do
    assert graphql_calls(context) == context.graphql_before
    context
  end

  step ~r/^the projects on GitHub report they are paused until (the rate limit resets and when|the time GitHub gave)$/,
       context do
    assert paused_until(context) == at(context.until)
    context
  end

  step "the pause is 30 seconds the first time, doubles each time the limit is hit again and never passes 15 minutes",
       context do
    Enum.reduce([60, 120, 240, 480, 900, 900], context, fn seconds, context ->
      move_clock(context, context.until)
      limited_again(context, seconds * 1_000)
    end)
  end

  step "the first answer that succeeds ends the pause and the doubling", context do
    move_clock(context, context.until)
    context = context |> unlimit() |> relist()
    assert {:ok, %{"errors" => []}} = context.reply

    context
    |> World.cli_rules(@rate_limited)
    |> limited_again(30_000)
  end

  step "a read from another of GitHub's budgets is still sent", context do
    before = length(World.cli_calls(context, "api user"))
    HalC2.PullRequests.invalidate(%{})

    {reply, context} =
      World.call(context, "pullRequests.routingIdentity", %{"host" => "github.com"})

    assert {:ok, %{"viewer" => @me}} = reply
    assert length(World.cli_calls(context, "api user")) == before + 1
    context
  end

  step "the user comments on a pull request or merges it", context do
    context =
      World.cli_rules(context, [
        Shared.permissions_rule("WRITE"),
        %{"args" => ["pr merge 1", "--squash"]},
        %{"args" => ["pr comment 1"], "stdout" => ""}
      ])

    ref = %{
      "projectId" => World.project(context, "acme/shop").id,
      "repository" => "acme/shop",
      "number" => 1
    }

    {commented, context} =
      World.call(context, "pullRequests.comment", Map.put(ref, "body", "Looks good"))

    {merged, context} =
      World.call(
        context,
        "pullRequests.runAction",
        Map.merge(ref, %{"action" => "merge", "mergeMethod" => "squash"})
      )

    Map.put(context, :asked, [commented, merged])
  end

  step "the request is sent to the host", context do
    assert [{:ok, _}, {:ok, _}] = context.asked
    assert [_] = World.cli_calls(context, "pr comment 1")
    assert [_] = World.cli_calls(context, "pr merge 1")
    context
  end

  step "the pause is neither ended nor shortened by that request's answer", context do
    still_paused(context, context.until)
  end

  # Signs `login` in to github.com the way `gh auth login` and `gh auth switch` leave
  # it, in a gh configuration of the scenario's own, with no token in the environment.
  defp sign_in_as(context, login) do
    context =
      if context[:gh_config] do
        context
      else
        for name <- ~w(GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN),
            do: World.put_os_env(name, nil)

        config = Mc.tmp_dir(context.mc, "gh-config")
        World.put_os_env("GH_CONFIG_DIR", config)
        Map.put(context, :gh_config, config)
      end

    File.write!(Path.join(context.gh_config, "hosts.yml"), """
    github.com:
        users:
            monalisa: {}
            hubot: {}
        user: #{login}
    """)

    context
  end

  # What `gh api rate_limit` says of the GraphQL budget: `remaining`, resetting at `reset`.
  defp rate_limit_rule(remaining, reset) do
    budget = &%{"limit" => 5000, "remaining" => &1, "reset" => reset}

    %{
      "args" => ["api rate_limit"],
      "stdout" => %{"resources" => %{"graphql" => budget.(remaining), "core" => budget.(4999)}}
    }
  end

  step "GitHub rate limits the account signed in for {string}", %{args: [repository]} = context do
    context = context |> clock() |> sign_in_as("monalisa")
    reset = div(now(context), 1_000) + 600

    # Budget left when the limit hit: a secondary limit, on every budget of the account.
    context =
      context
      |> World.cli_rules([@rate_limited, rate_limit_rule(4000, reset)])
      |> relist()

    assert {:ok, %{"errors" => errors}} = context.reply
    assert repository in Enum.map(errors, & &1["repository"])
    Map.put(context, :until, now(context) + 30_000)
  end

  # A background read of each host through the MC's one way to `gh`.
  step "reads from a self-hosted GitHub are sent as usual", context do
    assert paused_until(context) == at(context.until)
    sent = fn host -> length(World.cli_calls(context, "api user --hostname #{host}")) end
    before = {sent.("github.com"), sent.("ghe.test")}

    assert {:error, {:rate_limited, _}} =
             HalC2.GitHub.gh(context.cwd, ~w(api user --hostname github.com))

    assert {:ok, _} = HalC2.GitHub.gh(context.cwd, ~w(api user --hostname ghe.test))
    assert {sent.("github.com"), sent.("ghe.test")} == {elem(before, 0), elem(before, 1) + 1}
    context
  end

  step "once another account is signed in on the same host, its reads are sent as usual",
       context do
    before = graphql_calls(context)
    context = context |> sign_in_as("hubot") |> unlimit() |> relist()
    assert {:ok, %{"errors" => []}} = context.reply
    assert graphql_calls(context) > before

    # The account that met the limit is still paused, every budget of it.
    context = sign_in_as(context, "monalisa")
    before = length(World.cli_calls(context, "api user"))
    assert {:error, {:rate_limited, detail}} = HalC2.GitHub.gh(context.cwd, ~w(api user))
    assert detail =~ "resets at #{at(context.until)} UTC"
    assert length(World.cli_calls(context, "api user")) == before
    context
  end

  step "GitHub reported that the quota of one signed-in account is used up", context do
    context = context |> clock() |> sign_in_as("monalisa")
    reset = div(now(context), 1_000) + 600

    context
    |> World.cli_rules([@rate_limited, rate_limit_rule(0, reset)])
    |> relist()
    |> still_paused(reset * 1_000)
  end

  step "another account is signed in on the same host with quota left", context do
    context |> sign_in_as("hubot") |> unlimit()
  end

  step "pull requests are read again with the second account", context do
    context |> Map.put(:graphql_before, graphql_calls(context)) |> relist()
  end

  step "the read is sent", context do
    assert graphql_calls(context) > context.graphql_before
    assert {:ok, %{"errors" => []}} = context.reply
    context
  end
end
