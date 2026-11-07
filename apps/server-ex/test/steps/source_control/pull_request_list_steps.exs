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
      {"tax label:bug", &(&1["title"] =~ ~r/tax/i)},
      {~s("tax"), &(&1["title"] =~ ~r/tax/i)},
      {~s("is:merged"), fn _ -> false end}
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
      ~s(the author "alice") => {%{"author" => "alice"}, &author?(&1, "alice")},
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

  defp bad_gateway(repository) do
    %{
      "args" => ["api graphql"],
      "repository" => repository,
      "stderr" => "HTTP 502: Bad Gateway\n",
      "exit" => 1
    }
  end

  # On the steps' clock, so how long the repository is held back can be followed.
  step "{string} cannot be read", %{args: [repository]} = context do
    context
    |> clock()
    |> World.capture_log()
    |> World.cli_rules(bad_gateway(repository))
    |> Map.put(:failing, repository)
  end

  step "GitHub gives up on reading more than {int} of them at once", %{args: [most]} = context do
    context = clock(context)
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

  step "{string} reports its own error with the host's reason, phrased for the user, and when it is read again",
       %{args: [repository]} = context do
    # Words a user can act on, whatever the host; what it said stays in `detail`.
    message = held_back(context, repository, now(context) + 30_000)
    refute message =~ "502"
    context
  end

  # `repository`'s one error says it is read again at `until`; returns its message.
  defp held_back(context, repository, until) do
    assert {:ok, %{"errors" => errors}} = context.reply
    assert [%{"message" => message, "reason" => reason, "detail" => detail}] = errors

    assert reason ==
             "github.com did not answer in time. #{repository} is read again at " <>
               "#{at(until)} UTC; refresh to read it now."

    assert message == "#{repository} could not be read: #{reason}"
    assert detail == "HTTP 502: Bad Gateway"
    message
  end

  # --- a repository GitHub keeps giving up on (`HalC2.GitHub.Limits`) ---------------

  defp listings_of(context, repository) do
    [owner, name] = String.split(repository, "/")

    Enum.filter(World.pull_listings(context), fn %{"variables" => v} ->
      v["q"] =~ "repo:#{repository} " or (v["owner"] == owner and v["name"] == name)
    end)
  end

  defp gave_up_logged(context, repository) do
    ~r/#{Regex.escape(repository)} could not be read: HTTP 502/
    |> Regex.scan(World.logged(context))
    |> length()
  end

  step "the pull requests are listed again without the user asking", context do
    before = for {r, _} <- fixture(), into: %{}, do: {r, length(listings_of(context, r))}
    context |> Map.put(:listed_before, before) |> list()
  end

  step "{string} is not asked of GitHub again", %{args: [repository]} = context do
    assert length(listings_of(context, repository)) == context.listed_before[repository]
    context
  end

  step "the pull requests of {string} are still read", %{args: [repository]} = context do
    assert length(listings_of(context, repository)) > context.listed_before[repository]
    assert Enum.any?(entries(context), &(&1["repository"] == repository))
    context
  end

  step "{string} reports when it is read again, 30 seconds on, keeping what GitHub said",
       %{args: [repository]} = context do
    held_back(context, repository, now(context) + 30_000)
    Map.put(context, :until, now(context) + 30_000)
  end

  step "GitHub giving up is logged once, not on every listing", context do
    assert gave_up_logged(context, context.failing) == 1
    context
  end

  # Lists in the background once the hold is over: GitHub is asked, gives up again,
  # and the repository is held back for `hold`.
  defp gives_up_again(context, hold) do
    move_clock(context, context.until)
    before = length(listings_of(context, context.failing))
    logged = gave_up_logged(context, context.failing)
    context = list(context)
    assert length(listings_of(context, context.failing)) > before
    assert gave_up_logged(context, context.failing) == logged + 1
    until = now(context) + hold
    held_back(context, context.failing, until)
    Map.put(context, :until, until)
  end

  step "the hold doubles each time GitHub gives up again and never passes 15 minutes",
       context do
    Enum.reduce([60, 120, 240, 480, 900, 900], context, fn seconds, context ->
      context = gives_up_again(context, seconds * 1_000)

      # Not a moment early.
      move_clock(context, context.until - 1)
      before = length(listings_of(context, context.failing))
      context = list(context)
      assert length(listings_of(context, context.failing)) == before
      context
    end)
  end

  step "a hand refresh reads {string} at once", %{args: [repository]} = context do
    before = length(listings_of(context, repository))
    {{:ok, _}, context} = World.call(context, "pullRequests.invalidate", %{})
    context = list(context)
    assert length(listings_of(context, repository)) > before
    # It failed again, which counts like any failure: the hold, already at its
    # longest, starts over from now.
    until = now(context) + 900_000
    held_back(context, repository, until)
    Map.put(context, :until, until)
  end

  step "the first read that succeeds ends the hold and the doubling", context do
    move_clock(context, context.until)
    context = context |> drop_rule(bad_gateway(context.failing)) |> list()
    assert {:ok, %{"errors" => []}} = context.reply

    context
    |> World.cli_rules(bad_gateway(context.failing))
    |> Map.put(:until, now(context))
    |> gives_up_again(30_000)
  end

  step "15 minutes after the page shrank, a listing tries the usual size again", context do
    {repository, _} = context.many
    move_clock(context, now(context) + 900_000)
    before = length(listings_of(context, repository))
    context = list(context)
    [tried | _] = context |> listings_of(repository) |> Enum.drop(before)
    assert tried["variables"]["first"] == 50
    assert {:ok, %{"errors" => []}} = context.reply

    # It shrank to the same size again, which is kept afresh for the next listing.
    worked = context |> listings_of(repository) |> List.last() |> get_in(["variables", "first"])
    before = length(listings_of(context, repository))
    context = list(context)
    again = context |> listings_of(repository) |> Enum.drop(before)
    assert again != [] and Enum.all?(again, &(&1["variables"]["first"] <= worked))
    context
  end

  step "the second listing asks for no page larger than the one that worked", context do
    {repository, _} = context.many
    before = context.listed_before[repository]
    {first, again} = context |> listings_of(repository) |> Enum.split(before)
    worked = first |> List.last() |> get_in(["variables", "first"])
    assert worked < 50
    assert again != []
    assert Enum.all?(again, &(&1["variables"]["first"] <= worked))
    assert {:ok, %{"errors" => []}} = context.reply
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

  defp unlimit(context), do: drop_rule(context, @rate_limited)

  defp drop_rule(context, rule) do
    rules = context.cli.rules |> File.read!() |> JSON.decode!() |> List.delete(rule)
    File.write!(context.cli.rules, JSON.encode!(rules))
    context
  end

  # The time every GitHub project's error says calls resume, "HH:MM:SS".
  # A pause on the whole account also holds back the read of who is signed in, so the
  # listing fails as a whole rather than project by project.
  defp paused_until(context) do
    [until] =
      context
      |> messages()
      |> Enum.map(fn message ->
        assert [_, at] = Regex.run(~r/until it resets at (\d\d:\d\d:\d\d) UTC/, message)
        at
      end)
      |> Enum.uniq()

    until
  end

  # What the listing said went wrong: one message per GitHub project, or one for all.
  defp messages(context) do
    case context.reply do
      {:ok, %{"errors" => errors}} ->
        assert errors |> Enum.map(& &1["repository"]) |> Enum.sort() == ["acme/api", "acme/shop"]
        Enum.map(errors, & &1["message"])

      {:error, message, _} ->
        [message]
    end
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

  # --- GitHub's own numbers, from the headers `gh api --include` shows -----------------

  # Puts `status` and `headers` ahead of the answer to every GraphQL read.
  defp head(context, status, headers \\ %{}) do
    World.cli_rules(context, %{
      "args" => ["api graphql"],
      "head" => %{"status" => status, "headers" => headers}
    })
  end

  defp http_date(ms),
    do: ms |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

  step ~r/^the host rate limits a read and says to retry (?<retry>in 120 seconds|at a date and time given in full)$/,
       %{args: [retry]} = context do
    context = clock(context)
    until = now(context) + 120_000
    value = if retry == "in 120 seconds", do: "120", else: http_date(until)

    context
    |> World.cli_rules(@rate_limited)
    |> head("HTTP/2.0 403 Forbidden", %{"Retry-After" => value})
    |> relist()
    |> Map.put(:until, until)
  end

  step "the user lists pull requests before then", context do
    move_clock(context, context.until - 1_000)
    context |> Map.put(:graphql_before, graphql_calls(context)) |> relist()
  end

  step "no request goes to the host until that time", context do
    assert graphql_calls(context) == context.graphql_before
    assert paused_until(context) == at(context.until)
    # GitHub's own time was enough: its budget was not asked for.
    assert World.cli_calls(context, "api rate_limit") == []
    context
  end

  step "an earlier time from an older request never shortens a pause that is already longer",
       context do
    account = HalC2.GitHub.account("github.com")

    assert HalC2.GitHub.Limits.limited(account, :all, now(context), now(context) + 500) ==
             context.until

    still_paused(context, context.until)
  end

  step "GitHub reported that fewer than a tenth of its read quota is left until it resets",
       context do
    context = clock(context)
    reset = div(now(context), 1_000) + 600

    context =
      context
      |> head("HTTP/2.0 200 OK", %{
        "X-RateLimit-Limit" => "5000",
        "X-RateLimit-Remaining" => "499",
        "X-RateLimit-Reset" => "#{reset}",
        "X-RateLimit-Resource" => "graphql"
      })
      |> relist()

    assert {:ok, %{"errors" => []}} = context.reply
    Map.put(context, :until, reset * 1_000)
  end

  step "a background refresh needs to read pull requests", context do
    context |> Map.put(:graphql_before, graphql_calls(context)) |> relist()
  end

  step "it waits until the quota resets", context do
    assert graphql_calls(context) == context.graphql_before
    assert paused_until(context) == at(context.until)
    # Saving quota is not a limit reached.
    for message <- messages(context), do: assert(message =~ "nearly used up", message)
    context
  end

  step "a read the user asked for is still sent while any quota is left", context do
    query = "query={viewer{login}}"
    context = World.cli_rules(context, %{"args" => ["api graphql -f #{query}"], "stdout" => "{}"})
    before = graphql_calls(context)

    # What `pullRequests.update` and the other asked-for RPCs read runs like this.
    assert {:ok, _} =
             HalC2.GitHub.asked(fn ->
               HalC2.GitHub.gh(context.cwd, ["api", "graphql", "-f", query])
             end)

    assert graphql_calls(context) == before + 1
    # And the background refresh is still held back.
    still_paused(context, context.until)
  end

  # The answer GitHub refuses a read with: the head `gh api --include` shows, gh's
  # message, and when the pause it should cause ends, if it should cause one.
  defp refusal(~s("forbidden" and nothing about a limit), _now),
    do: {"HTTP/2.0 403 Forbidden", %{}, "gh: Forbidden (HTTP 403)", nil}

  defp refusal(~s("too many requests" and a time to retry in 120 seconds), now),
    # Its text names no limit, so the status alone must tell.
    do:
      {"HTTP/2.0 429 Too Many Requests", %{"Retry-After" => "120"}, "gh: Too Many Requests",
       now + 120_000}

  defp refusal(~s("forbidden", no quota left and a reset time 60 seconds on), now) do
    reset = div(now, 1_000) + 60

    {"HTTP/2.0 403 Forbidden",
     %{"X-RateLimit-Remaining" => "0", "X-RateLimit-Reset" => "#{reset}"},
     "gh: Forbidden (HTTP 403)", reset * 1_000}
  end

  defp refusal(~s("forbidden" with text saying the rate limit was exceeded), now),
    do:
      {"HTTP/2.0 403 Forbidden", %{}, "gh: API rate limit exceeded for user ID 7. (HTTP 403)",
       now + 30_000}

  defp refusal(~s("not modified"), _now),
    do: {"HTTP/2.0 304 Not Modified", %{}, "gh: HTTP 304", nil}

  defp refusal(~s("unauthorized"), _now),
    do: {"HTTP/2.0 401 Unauthorized", %{}, "gh: Bad credentials (HTTP 401)", nil}

  defp refusal("a server error", _now),
    do: {"HTTP/2.0 502 Bad Gateway", %{}, "gh: HTTP 502: Bad Gateway", nil}

  step ~r/^GitHub refuses a re-read of data that may be unchanged with (?<answer>.+)$/,
       %{args: [answer]} = context do
    context = clock(context)
    {status, headers, said, until} = refusal(answer, now(context))
    HalC2.PullRequests.invalidate(%{})

    context
    |> World.cli_rules(%{"args" => ["api graphql"], "stderr" => said <> "\n", "exit" => 1})
    |> head(status, headers)
    |> Map.put(:until, until)
  end

  # The listing fails as `said` expects, and asking again goes to GitHub again.
  defp not_paused(context, said) do
    assert context.until == nil

    refused = fn context ->
      for message <- messages(context), do: assert(said.(message), message)
      context
    end

    before = graphql_calls(context)
    context = context |> refused.() |> relist() |> refused.()
    assert graphql_calls(context) > before
    context
  end

  step "the read fails without pausing the host", context do
    not_paused(context, &(not (&1 =~ "paused")))
  end

  step "the user is told to sign in to GitHub again", context do
    not_paused(context, &(&1 =~ "gh auth login" and not (&1 =~ "paused")))
  end

  step "the read fails with GitHub's status and without pausing it", context do
    # The message is put in words a user can act on; GitHub's own is the detail.
    assert {:ok, %{"errors" => [_, _] = errors}} = context.reply
    for %{"detail" => detail} <- errors, do: assert(detail =~ "HTTP 502")
    not_paused(context, &(not (&1 =~ "paused")))
  end

  step ~r/^the host is paused (for 120 seconds|until the reset time|with the usual back-off)$/,
       context do
    assert paused_until(context) == at(context.until)
    still_paused(context, context.until)
  end

  # --- GitHub's own review decision, search text and continuations ----------------

  defp shop_rule(context, pulls, extra \\ %{}) do
    World.cli_rules(
      context,
      Map.merge(
        %{"args" => ["api graphql"], "repository" => "acme/shop", "pulls" => pulls},
        extra
      )
    )
  end

  step "pull request 42 on GitHub has an approving review", context do
    Map.put(context, :approving, [%{"state" => "APPROVED", "author" => %{"login" => "hubot"}}])
  end

  step ~r/^GitHub reports its review decision as (?<decision>review required|approved|nothing)$/,
       %{args: [decision]} = context do
    reported =
      %{"review required" => "REVIEW_REQUIRED", "approved" => "APPROVED", "nothing" => nil}[
        decision
      ]

    pr =
      Shared.gh_pr("acme/shop", 42, %{
        "reviewDecision" => reported,
        "latestReviews" => context.approving
      })

    shop_rule(context, [pr], %{"stdin" => ["PullRequestListSearch", "is:open "]})
  end

  step ~r/^its row shows it as (?<shown>waiting for a review|approved)$/,
       %{args: [shown]} = context do
    row = Enum.find(entries(context), &(&1["number"] == 42))
    assert row, "pull request 42 is not listed: #{inspect(context.reply)}"

    assert row["reviewDecision"] ==
             if(shown == "approved", do: "approved", else: "review-required")

    context
  end

  step "the words {string} are looked for in titles and bodies", %{args: [words]} = context do
    searches =
      Enum.filter(World.pull_listings(context), &(&1["query"] =~ "PullRequestListSearch"))

    assert searches != []
    assert Enum.all?(searches, &(&1["variables"]["q"] =~ ~s("#{words}")))
    Map.put(context, :searches, searches)
  end

  step "the search is not narrowed to merged pull requests", context do
    for search <- context.searches do
      q = search["variables"]["q"]
      assert q =~ "is:open"
      refute q =~ ~r/(^| )is:merged( |$)/
    end

    context
  end

  step "{string} has one closed pull request and one merged pull request", context do
    # The fixture's acme/shop: #3 closed, #4 merged.
    context
  end

  step "only the closed pull request is listed", context do
    assert listed(context) == MapSet.new([{"acme/shop", 3}])
    context
  end

  step "GitHub's search answers nothing at all for {string}", %{args: [repository]} = context do
    context
    |> World.cli_rules([
      %{
        "args" => ["api graphql"],
        "repository" => repository,
        "stdin" => ["PullRequestListSearch"],
        "pulls" => []
      },
      %{
        "args" => ["api graphql"],
        "repository" => repository,
        "stdin" => ["PullRequestListIndexed"],
        "pulls" => []
      }
    ])
    |> Map.put(:unindexed, repository)
  end

  step "the open pull requests of {string} are listed the long way",
       %{args: [repository]} = context do
    numbers = for e <- entries(context), e["repository"] == repository, do: e["number"]
    assert Enum.sort(numbers) == [1, 2]

    assert Enum.any?(
             World.pull_listings(context),
             &(&1["query"] =~ "PullRequestListRepository")
           ),
           "the repository's own list was not read"

    context
  end

  step "no pull request in {string} matches the words {string}",
       %{args: [repository, _words]} = context do
    World.cli_rules(context, %{
      "args" => ["api graphql"],
      "repository" => repository,
      "stdin" => ["PullRequestListSearch"],
      "pulls" => []
    })
  end

  step "no pull requests are listed for {string}", %{args: [repository]} = context do
    assert {:ok, _} = context.reply
    refute Enum.any?(entries(context), &(&1["repository"] == repository))
    context
  end

  step "the repository is not read the long way", context do
    refute Enum.any?(
             World.pull_listings(context),
             &(&1["query"] =~ "PullRequestListRepository")
           )

    context
  end

  step "a client lists pull requests carrying on from a cursor it made up", context do
    list(context, %{"cursors" => %{"github.com acme/shop" => "made-up"}})
  end

  step "no pull requests are listed", context do
    assert {:error, _, _} = context.reply
    context
  end

  step "the first page of the list carried on for {string} only",
       %{args: [repository]} = context do
    prs =
      for number <- 200..1//-1 do
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

  step "only {string} is read", %{args: [repository]} = context do
    assert Enum.map(entries(context), & &1["repository"]) |> Enum.uniq() == [repository]
    context
  end

  step "{string} is not asked again", %{args: [repository]} = context do
    # Asked once, for the first page the load-more step read before carrying on.
    assert length(listings_of(context, repository)) == 1
    context
  end

  step "{string} is open as the project and as two worktrees",
       %{args: [repository]} = context do
    Enum.reduce(["shop worktree one", "shop worktree two"], context, fn title, context ->
      context = World.create_project(context, title)
      World.github_remote(context, World.project(context, title).root, repository)
      context
    end)
  end

  step "each pull request of {string} is listed once", %{args: [repository]} = context do
    numbers = for e <- entries(context), e["repository"] == repository, do: e["number"]
    assert Enum.sort(numbers) == [1, 2]
    context
  end

  step "{string} exists on github.com and on a self-hosted GitHub",
       %{args: [repository]} = context do
    context = World.create_project(context, "shop enterprise")
    root = World.project(context, "shop enterprise").root
    World.git!(root, ["remote", "add", "origin", "git@github.example.com:#{repository}.git"])
    context
  end

  step "the pull requests of both are listed under their own host", context do
    for host <- ["github.com", "github.example.com"] do
      numbers =
        for e <- entries(context),
            e["host"] == host and e["repository"] == "acme/shop",
            do: e["number"]

      assert Enum.sort(numbers) == [1, 2], "nothing listed under #{host}"
    end

    context
  end

  step "the host returns one unreadable row in the middle of a page", context do
    prs =
      for number <- 150..1//-1 do
        at = DateTime.add(~U[2026-09-01 00:00:00Z], number * 60) |> DateTime.to_iso8601()
        Shared.gh_pr("acme/shop", number, %{"updatedAt" => at})
      end

    shop_rule(context, List.insert_at(prs, 50, %{"number" => "unreadable"}), %{
      "stdin" => ["is:open "]
    })
  end

  step "the readable rows are listed", context do
    numbers = for e <- entries(context), e["repository"] == "acme/shop", do: e["number"]
    assert length(numbers) == 99
    assert numbers == Enum.to_list(150..52//-1)
    context
  end

  step "more can still be loaded", context do
    assert {:ok, %{"nextCursors" => cursors, "truncated" => true}} = context.reply
    assert Map.has_key?(cursors, "github.com acme/shop")
    context
  end

  step "several pull requests were updated at the same instant across a page boundary",
       context do
    prs =
      for number <- 150..1//-1,
          do: Shared.gh_pr("acme/shop", number, %{"updatedAt" => "2026-09-20T00:00:00Z"})

    context
    |> shop_rule(prs, %{"stdin" => ["is:open "]})
    |> Map.merge(%{many: {"acme/shop", prs}})
  end

  step "every one of them is listed exactly once", context do
    numbers = &for(e <- &1, e["repository"] == "acme/shop", do: e["number"])
    all = numbers.(context.first_page) ++ numbers.(entries(context))
    assert Enum.sort(all) == Enum.to_list(1..150)
    context
  end

  step "the list is not narrowed", context do
    assert listed(context) == expected(fn _ -> true end)
    context
  end

  step "GitHub answers a listing of open pull requests with one row that cannot be read",
       context do
    pulls =
      fixture()["acme/shop"]
      |> Enum.filter(&(&1["state"] == "OPEN"))
      |> List.insert_at(1, %{"number" => "unreadable", "title" => 7})

    shop_rule(context, pulls, %{"stdin" => ["is:open "]})
  end

  step "the other pull requests are listed", context do
    numbers = for e <- entries(context), e["repository"] == "acme/shop", do: e["number"]
    assert Enum.sort(numbers) == [1, 2]
    context
  end

  step "the listing does not fail", context do
    assert {:ok, %{"errors" => []}} = context.reply
    context
  end

  step "the user is {string} and a review of pull request 1 is requested of {string}",
       %{args: [viewer, requested]} = context do
    pulls = [
      Shared.gh_pr("acme/shop", 1, %{"reviewRequests" => [%{"login" => requested}]}),
      Shared.gh_pr("acme/shop", 2, %{
        "author" => %{"login" => viewer},
        "reviewRequests" => [%{"login" => viewer}]
      })
    ]

    context =
      context
      |> World.cli_rules(%{
        "args" => ["api user"],
        "stdout" => %{"id" => 9, "login" => viewer}
      })
      |> shop_rule(pulls, %{"stdin" => ["PullRequestListSearch", "is:open "]})

    HalC2.PullRequests.invalidate(%{})
    context
  end

  step "pull request 2 was written by {string} and lists {string} among its requested reviewers",
       context do
    context
  end

  step "pull request 1 is flagged as awaiting the user's review", context do
    assert %{"viewerReviewRequested" => true} = Enum.find(entries(context), &(&1["number"] == 1))
    context
  end

  step "pull request 2 is not", context do
    assert %{"viewerReviewRequested" => false} = Enum.find(entries(context), &(&1["number"] == 2))
    context
  end

  step "pull request 1 on GitHub has a review requested of the team {string} and of no person",
       %{args: [_team]} = context do
    pr =
      Shared.gh_pr("acme/shop", 1, %{
        "reviewRequests" => [%{"slug" => "core", "name" => "Core"}]
      })

    shop_rule(context, [pr], %{"stdin" => ["review-requested:#{@me}"]})
  end

  step "the user lists pull requests where their review is requested", context do
    list(context, %{"involvement" => "reviewing"})
  end

  step "pull request 1 is listed", context do
    assert Enum.any?(entries(context), &(&1["number"] == 1))
    context
  end

  # --- the other hosts (`HalC2.PullRequests.Hosts`) ---------------------------------
  #
  # One fixture item (title, state, draft, author, reviewers, labels, pipeline)
  # is answered by each host in its own shape: GitLab, Forgejo and Azure from
  # the fake CLI under their own names, Bitbucket from a local API server.

  defmodule HostedBitbucket do
    @moduledoc false
    @behaviour Plug

    def init(opts), do: opts

    def call(conn, %{test: test, token: token, user: user, items: items}) do
      conn = Plug.Conn.fetch_query_params(conn)
      send(test, {:hosted_bitbucket, conn.request_path, conn.query_params})

      cond do
        Plug.Conn.get_req_header(conn, "authorization") != ["Bearer " <> token] ->
          Plug.Conn.send_resp(conn, 401, "")

        conn.request_path == "/2.0/user" ->
          json(conn, user)

        String.ends_with?(conn.request_path, "/pullrequests") ->
          params = conn.query_params
          rows = Enum.filter(items, &(&1["state"] == params["state"]))
          rows = filter_title(rows, params["q"])
          pagelen = String.to_integer(params["pagelen"] || "50")
          page = String.to_integer(params["page"] || "1")
          json(conn, %{"values" => rows |> Enum.drop((page - 1) * pagelen) |> Enum.take(pagelen)})

        true ->
          Plug.Conn.send_resp(conn, 404, "")
      end
    end

    defp filter_title(rows, nil), do: rows

    defp filter_title(rows, q) do
      case Regex.run(~r/title ~ "((?:\\.|[^"])*)"/, q) do
        [_, words] ->
          words = words |> String.replace("\\\"", "\"") |> String.replace("\\\\", "\\")

          Enum.filter(
            rows,
            &String.contains?(String.downcase(&1["title"]), String.downcase(words))
          )

        _ ->
          rows
      end
    end

    defp json(conn, body),
      do:
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, JSON.encode!(body))
  end

  @hosted_token "bitbucket-list-token"

  defp h(number, fields \\ %{}) do
    Map.merge(
      %{
        "number" => number,
        "title" => "Change #{number}",
        "state" => "open",
        "draft" => false,
        "author" => "alice",
        "reviewers" => [],
        "labels" => [],
        "created" => "2026-09-01T00:00:00Z",
        "updated" => "2026-09-20T00:00:00Z",
        "pipeline" => nil,
        "raw_state" => nil,
        "wip" => false,
        "omit_draft" => false,
        "merged_at" => nil,
        "participants" => nil,
        "azure" => %{}
      },
      fields
    )
  end

  defp hosted_fixture do
    [
      h(1, %{"labels" => ["bug"], "reviewers" => [@me], "pipeline" => "success"}),
      h(2, %{
        "draft" => true,
        "author" => "bob",
        "updated" => "2026-09-19T00:00:00Z",
        "pipeline" => "failed"
      }),
      h(3, %{"updated" => "2026-09-18T00:00:00Z"}),
      h(4, %{"state" => "closed", "updated" => "2026-09-17T00:00:00Z"}),
      h(5, %{"state" => "merged", "author" => "bob", "updated" => "2026-09-16T00:00:00Z"})
    ]
  end

  defp gitlab_raw(it, repo) do
    %{
      "iid" => it["number"],
      "title" => it["title"],
      "web_url" => "https://gitlab.com/#{repo}/-/merge_requests/#{it["number"]}",
      "source_branch" => "feature/#{it["number"]}",
      "target_branch" => "main",
      "state" =>
        it["raw_state"] ||
          %{"open" => "opened", "closed" => "closed", "merged" => "merged"}[it["state"]],
      "draft" => it["draft"],
      "work_in_progress" => it["wip"],
      "merged_at" => it["merged_at"] || if(it["state"] == "merged", do: it["updated"]),
      "author" => %{"username" => it["author"], "name" => it["author"]},
      "reviewers" => for(r <- it["reviewers"], do: %{"username" => r}),
      "labels" => it["labels"],
      "created_at" => it["created"],
      "updated_at" => it["updated"],
      "sha" => "abc#{it["number"]}",
      "head_pipeline" => it["pipeline"] && %{"status" => it["pipeline"]}
    }
  end

  defp forgejo_raw(it, repo) do
    raw = %{
      "number" => it["number"],
      "title" => it["title"],
      "html_url" => "https://codeberg.org/#{repo}/pulls/#{it["number"]}",
      "state" => if(it["state"] == "open", do: "open", else: "closed"),
      "merged" => it["state"] == "merged",
      "user" => %{"login" => it["author"]},
      "head" => %{"ref" => "feature/#{it["number"]}", "sha" => "abc#{it["number"]}"},
      "base" => %{"ref" => "main"},
      "labels" => for(name <- it["labels"], do: %{"name" => name, "color" => "d73a4a"}),
      "requested_reviewers" => for(r <- it["reviewers"], do: %{"login" => r}),
      "created_at" => it["created"],
      "updated_at" => it["updated"]
    }

    if it["omit_draft"], do: raw, else: Map.put(raw, "draft", it["draft"])
  end

  defp azure_raw(it, _repo) do
    base = %{
      "pullRequestId" => it["number"],
      "title" => it["title"],
      "status" =>
        it["raw_state"] ||
          %{"open" => "active", "closed" => "abandoned", "merged" => "completed"}[it["state"]],
      "isDraft" => it["draft"],
      "sourceRefName" => "refs/heads/feature/#{it["number"]}",
      "targetRefName" => "refs/heads/main",
      "creationDate" => it["created"],
      "closedDate" => if(it["state"] == "open", do: nil, else: it["updated"]),
      "createdBy" => %{"uniqueName" => it["author"], "displayName" => it["author"]},
      "reviewers" => for(r <- it["reviewers"], do: %{"uniqueName" => r}),
      "repository" => %{
        "name" => "shop",
        "webUrl" => "https://dev.azure.com/acme/shop/_git/shop",
        "project" => %{"name" => "shop"}
      },
      "_links" => %{
        "web" => %{
          "href" => "https://dev.azure.com/acme/shop/_git/shop/pullrequest/#{it["number"]}"
        }
      }
    }

    Map.merge(base, it["azure"])
  end

  defp bitbucket_raw(it, repo) do
    %{
      "id" => it["number"],
      "title" => it["title"],
      "state" =>
        it["raw_state"] ||
          %{"open" => "OPEN", "closed" => "DECLINED", "merged" => "MERGED"}[it["state"]],
      "draft" => it["draft"],
      "author" => %{
        "username" => it["author"],
        "nickname" => it["author"],
        "display_name" => it["author"]
      },
      "source" => %{"branch" => %{"name" => "feature/#{it["number"]}"}},
      "destination" => %{"branch" => %{"name" => "main"}},
      "links" => %{
        "html" => %{"href" => "https://bitbucket.org/#{repo}/pull-requests/#{it["number"]}"}
      },
      "reviewers" => for(r <- it["reviewers"], do: %{"username" => r, "nickname" => r}),
      "participants" =>
        it["participants"] ||
          for(r <- it["reviewers"], do: %{"user" => %{"username" => r}, "approved" => false}),
      "created_on" => it["created"],
      "updated_on" => it["updated"]
    }
  end

  defp hosted_rules(context, "GitLab", items, repo, _opts) do
    by_param = [
      {"opened", Enum.filter(items, &(&1["state"] == "open"))},
      {"closed", Enum.filter(items, &(&1["state"] == "closed"))},
      {"merged", Enum.filter(items, &(&1["state"] == "merged"))},
      {"all", items}
    ]

    rules =
      for {param, rows} <- by_param,
          {chunk, index} <- Enum.with_index(Enum.chunk_every(rows, 100)) do
        %{
          "cmd" => "glab",
          # "&page=" so page=1 does not also match inside per_page=100.
          "args" => ["api", "state=#{param}", "&page=#{index + 1}"],
          "stdout" => Enum.map(chunk, &gitlab_raw(&1, repo))
        }
      end

    World.cli_rules(
      context,
      [%{"cmd" => "glab", "args" => ["api user"], "stdout" => %{"username" => @me}}] ++
        rules ++
        [%{"cmd" => "glab", "args" => ["api", "merge_requests"], "stdout" => []}]
    )
  end

  defp hosted_rules(context, "Forgejo", items, repo, _opts) do
    by_param = [
      {"open", Enum.filter(items, &(&1["state"] == "open"))},
      {"closed", Enum.filter(items, &(&1["state"] != "open"))},
      {"all", items}
    ]

    rules =
      for {param, rows} <- by_param,
          {chunk, index} <- Enum.with_index(Enum.chunk_every(rows, 50)) do
        %{
          "cmd" => "tea",
          "args" => ["api", "state=#{param}", "&page=#{index + 1}"],
          "stderr" => "HTTP/2.0 200 OK\n",
          "stdout" => Enum.map(chunk, &forgejo_raw(&1, repo))
        }
      end

    World.cli_rules(
      context,
      [
        %{
          "cmd" => "tea",
          "args" => ["login list"],
          "stdout" => [
            %{
              "name" => "codeberg",
              "url" => "https://codeberg.org",
              "user" => @me,
              "default" => "true",
              "valid" => "true"
            }
          ]
        },
        %{
          "cmd" => "tea",
          "args" => ["api", "/api/v1/user"],
          "stderr" => "HTTP/2.0 200 OK\n",
          "stdout" => %{"login" => @me}
        }
      ] ++
        rules ++
        [
          %{
            "cmd" => "tea",
            "args" => ["api", "/pulls?"],
            "stderr" => "HTTP/2.0 200 OK\n",
            "stdout" => []
          }
        ]
    )
  end

  defp hosted_rules(context, "Azure DevOps", items, repo, opts) do
    by_param = [
      {"active", Enum.filter(items, &(&1["state"] == "open"))},
      {"abandoned", Enum.filter(items, &(&1["state"] == "closed"))},
      {"completed", Enum.filter(items, &(&1["state"] == "merged"))},
      {"all", items}
    ]

    # Skip rules first: a later page's call also carries the first page's words.
    rules =
      for {param, rows} <- by_param,
          {chunk, index} <- Enum.with_index(Enum.chunk_every(rows, 100)),
          index > 0 do
        %{
          "cmd" => "az",
          "args" => ["pr list", "--status #{param}", "--skip #{index * 100}"],
          "stdout" => Enum.map(chunk, &azure_raw(&1, repo))
        }
      end ++
        for {param, rows} <- by_param do
          %{
            "cmd" => "az",
            "args" => ["pr list", "--status #{param}"],
            "stdout" => rows |> Enum.take(100) |> Enum.map(&azure_raw(&1, repo))
          }
        end

    viewer = %{
      "cmd" => "az",
      "args" => ["account show"],
      "stdout" => opts[:azure_viewer] || %{"name" => @me}
    }

    World.cli_rules(
      context,
      [viewer] ++ rules ++ [%{"cmd" => "az", "args" => ["pr list"], "stdout" => []}]
    )
  end

  defp hosted_rules(context, "Bitbucket", items, repo, opts) do
    server =
      Mc.ensure(
        {Bandit,
         plug:
           {HostedBitbucket,
            %{
              test: self(),
              token: @hosted_token,
              user: opts[:bitbucket_user] || %{"username" => @me},
              items: Enum.map(items, &bitbucket_raw(&1, repo))
            }},
         port: 0,
         ip: :loopback}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    Shared.put_env("HAL_C2_BITBUCKET_API_BASE_URL", "http://127.0.0.1:#{port}/2.0")
    Shared.put_env("HAL_C2_BITBUCKET_ACCESS_TOKEN", @hosted_token)
    context
  end

  defp hosted_remote("GitLab", repo), do: "git@gitlab.com:#{repo}.git"
  defp hosted_remote("Forgejo", repo), do: "https://codeberg.org/#{repo}.git"
  defp hosted_remote("Bitbucket", repo), do: "git@bitbucket.org:#{repo}.git"

  defp hosted_project(context, host, items, opts \\ []) do
    opts = Map.new(opts)
    title = opts[:title] || "hosted"
    repo = opts[:repository] || "acme/shop"

    remote =
      opts[:remote] ||
        if host == "Azure DevOps" do
          [owner, name] = String.split(repo, "/") |> Enum.take(-2)
          "https://dev.azure.com/#{owner}/#{name}/_git/#{name}"
        else
          hosted_remote(host, repo)
        end

    context = World.create_project(context, title)
    project = World.project(context, title)
    World.git!(project.root, ["remote", "add", "origin", remote])

    context
    |> World.fake_cli(["glab", "az", "tea"])
    |> hosted_rules(host, items, repo, opts)
    |> Map.put(:hosted, %{
      host: host,
      items: items,
      id: project.id,
      repository: repo,
      title: title
    })
  end

  defp hosted_entries(context),
    do: Enum.filter(entries(context), &(&1["projectId"] == context.hosted.id))

  defp hosted_numbers(context), do: Enum.map(hosted_entries(context), & &1["number"])

  step "a project on {word}", %{args: [host]} = context do
    hosted_project(context, host, hosted_fixture())
  end

  step "a project on Azure DevOps", context do
    hosted_project(context, "Azure DevOps", hosted_fixture())
  end

  step "a project on {word} with 200 open change requests", %{args: [host]} = context do
    items =
      for number <- 200..1//-1 do
        at = DateTime.add(~U[2026-09-01 00:00:00Z], number * 60) |> DateTime.to_iso8601()
        h(number, %{"updated" => at})
      end

    hosted_project(context, host, items)
  end

  step "a project on Azure DevOps with 200 open change requests", context do
    items =
      for number <- 200..1//-1 do
        at = DateTime.add(~U[2026-09-01 00:00:00Z], number * 60) |> DateTime.to_iso8601()
        h(number, %{"updated" => at})
      end

    hosted_project(context, "Azure DevOps", items)
  end

  step "the user lists change requests", context do
    list(context, %{"state" => "all"})
  end

  step "the user lists open merge requests", context do
    list(context, %{"state" => "open"})
  end

  step "the user lists merge requests", context do
    list(context, %{"state" => "open"})
  end

  step ~r/^the user lists merge requests with (?<filter>passing checks|failing checks|pending checks)$/,
       %{args: [filter]} = context do
    checks =
      %{
        "passing checks" => "passing",
        "failing checks" => "failing",
        "pending checks" => "pending"
      }[filter]

    list(context, %{"filters" => %{"checks" => checks}})
  end

  step ~r/^the user searches pull requests for `(?<words>.+)`$/, %{args: [words]} = context do
    context |> list(%{"query" => words}) |> Map.put(:query, words)
  end

  step "the user loads more change requests", context do
    context = list(context)
    assert {:ok, %{"nextCursors" => cursors}} = context.reply
    first = hosted_numbers(context)

    context
    |> list(%{"cursors" => cursors})
    |> Map.put(:first_hosted, first)
  end

  step ~r/^only change requests matching (?<filter>.+) are listed$/,
       %{args: [filter]} = context do
    keep =
      %{
        "drafts hidden" => &(not &1["draft"]),
        ~s(the label "bug") => &("bug" in &1["labels"]),
        ~s(the author "alice") => &(&1["author"] == "alice"),
        "review required" => &(&1["number"] == 1)
      }[filter] || flunk("no hosted filter #{inspect(filter)}")

    wanted =
      for it <- context.hosted.items, it["state"] == "open", keep.(it), do: it["number"]

    assert wanted != []
    assert Enum.sort(hosted_numbers(context)) == Enum.sort(wanted)
    context
  end

  step "the next change requests follow without repeating or skipping any", context do
    assert context.first_hosted == Enum.to_list(200..102//-1)
    assert hosted_numbers(context) == Enum.to_list(101..3//-1)
    context
  end

  step "the open change requests are listed unnarrowed", context do
    wanted = for it <- context.hosted.items, it["state"] == "open", do: it["number"]
    assert Enum.sort(hosted_numbers(context)) == Enum.sort(wanted)
    context
  end

  step "the words are searched for as plain text", context do
    case context.hosted.host do
      "GitLab" ->
        calls = World.cli_calls(context, "merge_requests")
        assert Enum.any?(calls, &(Enum.join(&1["args"], " ") =~ "search=tax%26state%3Dall"))

      "Bitbucket" ->
        assert_received {:hosted_bitbucket, _path, %{"q" => q, "state" => "OPEN"}}
        assert q == ~s(title ~ "a\\" OR state=\\"MERGED")
    end

    assert Enum.all?(hosted_entries(context), &(&1["state"] == "open"))
    context
  end

  step "no other filter is added", context do
    case context.hosted.host do
      "GitLab" ->
        calls = World.cli_calls(context, "merge_requests")

        assert Enum.all?(
                 calls,
                 &(Enum.join(&1["args"], " ") =~ "state=opened" and
                     not (Enum.join(&1["args"], " ") =~ "&state=all"))
               )

      "Bitbucket" ->
        :ok
    end

    context
  end

  step "a GitLab merge request whose latest pipeline {word}",
       %{args: [pipeline]} = context do
    status =
      %{"passed" => "success", "failed" => "failed", "was" => "canceled", "is" => "running"}[
        pipeline
      ]

    hosted_project(context, "GitLab", [h(1, %{"pipeline" => status}), h(2)])
  end

  step ~r/^a GitLab merge request whose latest pipeline (?<pipeline>was canceled|is running)$/,
       %{args: [pipeline]} = context do
    status = if pipeline == "was canceled", do: "canceled", else: "running"
    hosted_project(context, "GitLab", [h(1, %{"pipeline" => status}), h(2)])
  end

  step "it is listed", context do
    assert hosted_numbers(context) == [1]
    context
  end

  step ~r/^a change request on (?<host>Azure DevOps|Bitbucket|GitLab) that the host calls (?<state>.+)$/,
       %{args: [host, state]} = context do
    item =
      case {host, state} do
        {"GitLab", "closed with a merge time"} ->
          h(1, %{
            "state" => "merged",
            "raw_state" => "closed",
            "merged_at" => "2026-09-20T00:00:00Z"
          })

        {"GitLab", raw} ->
          h(1, %{"raw_state" => raw})

        {"Azure DevOps", "a state not known"} ->
          h(1, %{"raw_state" => "somethingElse"})

        {"Azure DevOps", raw} ->
          state_name =
            %{"active" => "open", "completed" => "merged", "abandoned" => "closed"}[raw]

          h(1, %{"state" => state_name, "raw_state" => raw})

        {"Bitbucket", raw} ->
          h(1, %{"state" => "closed", "raw_state" => String.upcase(raw)})
      end

    hosted_project(context, host, [item])
  end

  step ~r/^a change request on (?<host>GitLab|Forgejo|Azure DevOps|Bitbucket) that (?<marking>is flagged as a draft|is flagged as work in progress, the older name|has no flag and .*)$/,
       %{args: [host, marking]} = context do
    item =
      case marking do
        "is flagged as a draft" ->
          h(1, %{"draft" => true})

        "is flagged as work in progress, the older name" ->
          h(1, %{"wip" => true})

        ~s(has no flag and a title starting "[WIP]") ->
          h(1, %{"omit_draft" => true, "title" => "[WIP] Change 1"})

        ~s(has no flag and a title starting "WIP:" in any case) ->
          h(1, %{"omit_draft" => true, "title" => "wip: Change 1"})

        ~s(has no flag and "WIP:" only in the middle of its title) ->
          h(1, %{"omit_draft" => true, "title" => "A WIP: Change 1"})
      end

    hosted_project(context, host, [item])
  end

  step ~r/^it is shown as (?<shown>open|closed|merged|a draft|not a draft)$/,
       %{args: [shown]} = context do
    assert [entry] = hosted_entries(context)

    if shown in ["a draft", "not a draft"],
      do: assert(entry["isDraft"] == (shown == "a draft")),
      else: assert(entry["state"] == shown)

    context
  end

  step "the project {string} has its remote on GitLab at {string}",
       %{args: [title, repo]} = context do
    hosted_project(context, "GitLab", hosted_fixture(), title: title, repository: repo)
  end

  step "the merge requests of {string} are listed", %{args: [repo]} = context do
    assert hosted_numbers(context) != []
    assert Enum.all?(hosted_entries(context), &(&1["repository"] == repo))

    calls = World.cli_calls(context, "merge_requests")
    encoded = URI.encode(repo, &URI.char_unreserved?/1)
    assert Enum.any?(calls, &(Enum.join(&1["args"], " ") =~ "projects/#{encoded}/"))
    context
  end

  step "an open merge request on GitLab", context do
    hosted_project(context, "GitLab", [h(1)])
  end

  step "the row shows no added or removed line counts", context do
    assert [%{"additions" => 0, "deletions" => 0}] = hosted_entries(context)
    context
  end

  step "a Forgejo repository with merged pull requests and pull requests closed without merging",
       context do
    items =
      Enum.flat_map(1..120, fn n ->
        at = fn m -> DateTime.add(~U[2026-09-01 00:00:00Z], m * 60) |> DateTime.to_iso8601() end

        [
          h(1000 + n, %{"state" => "merged", "updated" => at.(2 * n)}),
          h(2000 + n, %{"state" => "closed", "updated" => at.(2 * n - 1)})
        ]
      end)
      |> Enum.sort_by(& &1["updated"], :desc)

    hosted_project(context, "Forgejo", items)
  end

  step "the list is filled to its page size when there are enough", context do
    assert length(hosted_entries(context)) == 99
    context
  end

  # --- Azure and Bitbucket specifics ------------------------------------------------

  step ~r/^pull request 7 on Azure DevOps comes with (?<given>.+)$/,
       %{args: [given]} = context do
    web = "https://dev.azure.com/acme/shop/_git/shop/pullrequest/7"

    {azure, expected} =
      case given do
        "a web link" ->
          {%{}, web}

        "no web link but the repository's web address" ->
          {%{"_links" => %{}}, web}

        ~s|only a programming address under "dev.azure.com/org", project "My App" and repository "web"| ->
          {%{
             "_links" => %{},
             "url" =>
               "https://dev.azure.com/org/My%20App/_apis/git/repositories/1/pullRequests/7",
             "repository" => %{"name" => "web", "project" => %{"name" => "My App"}}
           }, "https://dev.azure.com/org/My%20App/_git/web/pullrequest/7"}

        ~s|only a programming address under "org.visualstudio.com", project "app" and repository "web"| ->
          {%{
             "_links" => %{},
             "url" => "https://org.visualstudio.com/app/_apis/git/repositories/1/pullRequests/7",
             "repository" => %{"name" => "web", "project" => %{"name" => "app"}}
           }, "https://org.visualstudio.com/app/_git/web/pullrequest/7"}

        "nothing but a programming address of another kind" ->
          {%{
             "_links" => %{},
             "url" => "https://example.test/api/pullRequests/7",
             "repository" => %{"name" => "web", "project" => %{"name" => "app"}}
           }, "https://example.test/api/pullRequests/7"}
      end

    context
    |> hosted_project("Azure DevOps", [h(7, %{"azure" => azure})])
    |> Map.put(:azure_link, expected)
  end

  step ~r/^its link is (?<link>.+)$/, %{args: [_link]} = context do
    assert [%{"url" => url}] = hosted_entries(context)
    assert url == context.azure_link
    context
  end

  step "an open pull request on Azure DevOps", context do
    hosted_project(context, "Azure DevOps", [h(1)])
  end

  step "its row shows no labels", context do
    assert [%{"labels" => []}] = hosted_entries(context)
    context
  end

  step "the row claims no added or removed lines", context do
    assert [%{"additions" => 0, "deletions" => 0}] = hosted_entries(context)
    context
  end

  defp without_env(name) do
    previous = System.get_env(name)
    System.delete_env(name)

    ExUnit.Callbacks.on_exit(fn ->
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)
    end)
  end

  step "the project's remote is {string}", %{args: [remote]} = context do
    context = World.create_project(context, "server repo")
    project = World.project(context, "server repo")
    World.git!(project.root, ["remote", "add", "origin", remote])
    Map.put(context, :server_project, project)
  end

  step "no Bitbucket API address is configured", context do
    without_env("HAL_C2_BITBUCKET_API_BASE_URL")
    Shared.put_env("HAL_C2_BITBUCKET_ACCESS_TOKEN", @hosted_token)
    context
  end

  step "a Bitbucket API address is configured", context do
    project = context.server_project

    items = [h(1)]

    server =
      Mc.ensure(
        {Bandit,
         plug:
           {HostedBitbucket,
            %{
              test: self(),
              token: @hosted_token,
              user: %{"username" => @me},
              items: Enum.map(items, &bitbucket_raw(&1, "proj/repo"))
            }},
         port: 0,
         ip: :loopback}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    Shared.put_env("HAL_C2_BITBUCKET_API_BASE_URL", "http://127.0.0.1:#{port}/2.0")
    Shared.put_env("HAL_C2_BITBUCKET_ACCESS_TOKEN", @hosted_token)

    Map.put(context, :hosted, %{
      host: "Bitbucket",
      items: items,
      id: project.id,
      repository: "proj/repo"
    })
  end

  step "{string} reports that its host cannot be browsed here yet",
       %{args: [_repository]} = context do
    assert {:ok, %{"providers" => providers}} = context.reply

    assert %{"configured" => false, "detail" => "This host cannot be browsed here yet."} =
             Enum.find(providers, &(&1["host"] == "bitbucket.example.com"))

    refute Enum.any?(entries(context), &(&1["projectId"] == context.server_project.id))
    context
  end

  step "nothing about {string} is sent to bitbucket.org", context do
    # With credentials set but no API address, a read sent to Bitbucket Cloud
    # would have answered (or failed) as a read of the repository; the listing
    # instead left the host unconfigured, which only happens before any request.
    assert {:ok, %{"errors" => errors}} = context.reply
    refute Enum.any?(errors, &(&1["projectId"] == context.server_project.id))
    context
  end

  step "the pull requests of {string} are read through the configured address",
       %{args: [_repository]} = context do
    assert hosted_numbers(context) == [1]
    assert_received {:hosted_bitbucket, "/2.0/repositories/proj/repo/pullrequests", _params}
    context
  end

  step "the Azure CLI answers for the current sign-in with no account", context do
    hosted_project(context, "Azure DevOps", [h(1)], azure_viewer: %{})
  end

  step "the user lists their pull requests on Azure DevOps", context do
    list(context, %{"state" => "open"})
  end

  step "the user lists their pull requests on Bitbucket", context do
    list(context, %{"state" => "open"})
  end

  step "Bitbucket answers for the configured credentials with no account name", context do
    hosted_project(context, "Bitbucket", [h(1)], bitbucket_user: %{"display_name" => "Octo"})
  end

  step ~r/^a project whose Bitbucket repository is not written as workspace\/repository$/,
       context do
    hosted_project(context, "Bitbucket", [h(1)], repository: "acme/team/shop")
  end

  step "the user lists its pull requests", context do
    list(context, %{"state" => "open"})
  end

  step "the host of {string} cannot filter by author", %{args: [_repository]} = context do
    items =
      for number <- 600..1//-1 do
        at = DateTime.add(~U[2026-09-01 00:00:00Z], number * 60) |> DateTime.to_iso8601()
        author = if rem(number, 100) == 0, do: "octocat", else: "bob"
        h(number, %{"author" => author, "updated" => at})
      end

    hosted_project(context, "GitLab", items)
  end

  step "the user lists pull requests by the author {string}", %{args: [author]} = context do
    list(context, %{"filters" => %{"author" => author}})
  end

  step "the MC reads further pages of {string} until the page is full", context do
    pages =
      World.cli_calls(context, "merge_requests")
      |> Enum.map(fn call ->
        case Regex.run(~r/&page=(\d+)/, Enum.join(call["args"], " ")) do
          [_, page] -> String.to_integer(page)
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    assert Enum.max(pages) > 1
    Map.put(context, :hosted_pages, pages)
  end

  step "it stops after five reads when the filter matches little", context do
    assert Enum.max(context.hosted_pages) == 5
    # Only the octocat rows of the first five hundred survived the filter.
    assert Enum.sort(hosted_numbers(context)) == [200, 300, 400, 500, 600]
    context
  end

  step "the list offers more when more is left", context do
    assert {:ok, %{"truncated" => true, "nextCursors" => cursors}} = context.reply
    assert cursors != %{}
    context
  end
end
