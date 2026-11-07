defmodule HalC2.Steps.SourceControl.PullRequestPreviews do
  @moduledoc """
  Steps for the link preview scenarios of
  `features/source-control/pull-request-threads.feature`: `pullRequests.preview` and
  what it holds (`HalC2.PullRequests.Held`).

  The fake GitHub answers the narrow preview read of a pull request once a step asks
  for it (`answer_preview/2`); `preview_reads/2` counts how often it was asked. Time
  is the MC's pull request clock (`:pull_requests_clock`), moved by `at/2`.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.SourceControl.Shared
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @preview_fields "number title url state isDraft createdAt"
  @card ~w(projectId repository number title url author state isDraft createdAt)

  step "a client asks for the preview of pull request {int}", %{args: [number]} = context do
    case context[:gitlab] do
      nil -> context |> answer_preview(number) |> ask_preview(number)
      repository -> ask_preview(context, number, "default", repository)
    end
  end

  step "the answer carries the repository, number, title, link, author, state, draft flag and creation time",
       context do
    assert {:ok, preview} = context.reply
    assert preview |> Map.keys() |> Enum.sort() == Enum.sort(@card)

    assert %{
             "repository" => "acme/shop",
             "number" => 42,
             "title" => "Pull request 42",
             "url" => "https://github.com/acme/shop/pull/42",
             "author" => %{"login" => "octocat"},
             "state" => "open",
             "isDraft" => false,
             "createdAt" => "2026-09-01T00:00:00Z"
           } = preview

    context
  end

  step "it carries none of the conversation, checks or files", context do
    [read] = preview_requests(context, 42)

    for asked <- ~w(body comments reviewThreads statusCheckRollup files changedFiles),
        do: refute(read =~ asked, "the preview read asked for #{asked}")

    context
  end

  step "the preview of pull request {int} was read a few seconds ago",
       %{args: [number]} = context do
    context = context |> at(0) |> answer_preview(number) |> ask_preview(number)
    assert {:ok, _} = context.reply
    at(context, 5_000)
  end

  step "a client asks for it again", context do
    ask_preview(context, 42)
  end

  step "the answer comes without asking the host", context do
    assert {:ok, %{"number" => 42}} = context.reply
    assert preview_reads(context, 42) == 1
    context
  end

  step "a change made to pull request {int} from HAL-C2 or a refresh makes the next preview ask the host",
       %{args: [42]} = context do
    context = World.cli_rules(context, [%{"args" => ["pr comment 42"], "stdout" => ""}])

    {reply, context} =
      World.call(context, "pullRequests.comment", Map.put(ref(context, 42), "body", "Looks good"))

    assert {:ok, _} = reply
    context = ask_preview(context, 42)
    assert {:ok, _} = context.reply
    assert preview_reads(context, 42) == 2

    {reply, context} =
      World.call(context, "pullRequests.invalidate", %{"reference" => ref(context, 42)})

    assert {:ok, _} = reply
    context = ask_preview(context, 42)
    assert {:ok, _} = context.reply
    assert preview_reads(context, 42) == 3
    context
  end

  step "the details of pull request {int} are still being read", %{args: [42]} = context do
    context = context |> answer_preview(42) |> Shared.open_pull_request(42)
    dir = Mc.tmp_dir(context.mc, "detail-gate")
    started = Path.join(dir, "started")
    release = Path.join(dir, "release")
    for fifo <- [started, release], do: {_, 0} = System.cmd("mkfifo", [fifo])

    # The details read stops in the fake GitHub until the scenario lets it go.
    gate(context, "viewerCanUpdateBranch", "echo > #{started}; cat #{release} > /dev/null")

    client = World.client(context)
    id = System.unique_integer([:positive])
    client = Mc.rpc(client, context.mc.environment, id, "pullRequests.detail", ref(context, 42))
    # Reading the fifo returns once the fake GitHub is inside the details read.
    {_, 0} = System.cmd("cat", [started])

    context
    |> World.put_client(client)
    |> Map.put(:details_in_flight, %{id: id, release: release})
  end

  step "a client asks for its preview", context do
    if context[:details_in_flight],
      do: ask_preview(context, 42, "other"),
      else: ask_preview(context, 42)
  end

  step "the preview is answered without waiting for the details", context do
    assert {:ok, %{"number" => 42, "title" => "Pull request 42"}} = context.reply
    %{id: id, release: release} = context.details_in_flight
    {_, 0} = System.cmd("sh", ["-c", "echo > #{release}"])
    {frame, client} = Mc.await(World.client(context), Mc.reply?(id))
    assert frame["t"] == "rpc.result"
    World.put_client(context, client)
  end

  step "the details of pull request {int} were read {int} seconds ago",
       %{args: [42, seconds]} = context do
    context = context |> answer_preview(42) |> Shared.open_pull_request(42) |> at(0)
    assert %{"title" => "Add the tax table"} = Shared.pr_detail!(context)
    at(context, seconds * 1000)
  end

  step "it is answered from those details without asking the host", context do
    assert {:ok, %{"number" => 42, "title" => "Add the tax table"} = preview} = context.reply
    assert preview |> Map.keys() |> Enum.sort() == Enum.sort(@card)
    assert preview_reads(context, 42) == 0
    context
  end

  step "the details were read {int} seconds ago instead", %{args: [seconds]} = context do
    context |> at(seconds * 1000) |> ask_preview(42)
  end

  step "the host is asked for the preview", context do
    assert {:ok, %{"number" => 42, "title" => "Pull request 42"}} = context.reply
    assert preview_reads(context, 42) == 1
    context
  end

  step "the preview of pull request {int} is held", %{args: [number]} = context do
    context = context |> answer_preview(number) |> ask_preview(number)
    assert {:ok, %{"number" => ^number}} = context.reply
    context
  end

  step "the host is rate limited", context do
    context =
      World.cli_rules(context, [
        %{
          "args" => ["api graphql"],
          "stderr" => "GraphQL: API rate limit exceeded for user ID 7.\n",
          "exit" => 1
        }
      ])

    # The MC learns of the limit from a read the host turns away.
    context = context |> ask_preview(3)
    assert {:error, _, %{"detail" => detail}} = context.reply
    assert detail =~ "paused until it resets"
    context
  end

  step "a client asks for the previews of pull requests {int} and {int}",
       %{args: [first, second]} = context do
    asked = Map.new([first, second], &{&1, length(preview_requests(context, &1))})

    {replies, context} =
      Enum.map_reduce([first, second], context, fn number, context ->
        {reply, context} = World.call(context, "pullRequests.preview", ref(context, number))
        {{number, reply}, context}
      end)

    Map.merge(context, %{replies: Map.new(replies), asked: asked})
  end

  step "the preview of pull request {int} is returned", %{args: [number]} = context do
    assert {:ok, %{"number" => ^number, "title" => title}} = context.replies[number]
    assert title == "Pull request #{number}"
    context
  end

  step "pull request {int} is refused as paused until the limit resets",
       %{args: [number]} = context do
    assert {:error, _, %{"detail" => detail}} = context.replies[number]
    assert detail =~ ~r/paused until it resets at \d\d:\d\d:\d\d UTC/
    assert length(preview_requests(context, number)) == context.asked[number]
    context
  end

  step "the previews of {string} and {string} are held", %{args: repositories} = context do
    Enum.reduce(repositories, context, fn repository, context ->
      context = World.github_project(context, repository)
      context = World.create_thread(context, repository, repository)

      context =
        context |> answer_preview(42, repository) |> ask_preview(42, "default", repository)

      assert {:ok, %{"repository" => ^repository}} = context.reply
      context
    end)
  end

  step "a turn finishes in {string}", %{args: [repository]} = context do
    context |> World.run_turn(repository, "hello") |> Map.put(:turn_in, repository)
  end

  step "the preview of {string} is still answered without asking the host",
       %{args: [repository]} = context do
    context = ask_preview(context, 42, "default", repository)
    assert {:ok, %{"repository" => ^repository}} = context.reply
    assert length(preview_requests(context, 42, repository)) == 1

    # The project the turn ran in reads its previews fresh.
    finished = context.turn_in
    context = ask_preview(context, 42, "default", finished)
    assert {:ok, %{"repository" => ^finished}} = context.reply
    assert length(preview_requests(context, 42, finished)) == 2
    context
  end

  step "the host has no narrow read for a pull request", context do
    repository = "acme/notes"
    context = World.create_project(context, repository)
    root = World.project(context, repository).root
    World.git!(root, ["remote", "add", "origin", "git@gitlab.com:#{repository}.git"])

    context
    |> World.fake_cli(["glab"])
    |> World.cli_rules([
      %{
        "cmd" => "glab",
        "args" => ["mr view 42"],
        "stdout" => %{
          "iid" => 42,
          "title" => "Charge tax at checkout",
          "web_url" => "https://gitlab.com/#{repository}/-/merge_requests/42",
          "author" => %{"username" => "octocat", "avatar_url" => nil},
          "state" => "opened",
          "draft" => true,
          "created_at" => "2026-09-01T00:00:00Z",
          "description" => "The whole merge request",
          "source_branch" => "feature/tax",
          "target_branch" => "main"
        }
      }
    ])
    |> Map.put(:gitlab, repository)
  end

  step "the preview is made from the host's full answer", context do
    assert {:ok, preview} = context.reply

    assert preview == %{
             "projectId" => World.project(context, "acme/notes").id,
             "repository" => "acme/notes",
             "number" => 42,
             "title" => "Charge tax at checkout",
             "url" => "https://gitlab.com/acme/notes/-/merge_requests/42",
             "author" => %{"login" => "octocat", "avatarUrl" => nil},
             "state" => "open",
             "isDraft" => true,
             "createdAt" => "2026-09-01T00:00:00Z"
           }

    assert [_] = for(%{"cmd" => "glab"} = call <- World.cli_calls(context, "mr view"), do: call)
    context
  end

  # --- helpers -------------------------------------------------------------------------

  defp ref(context, number, repository \\ "acme/shop"),
    do: %{
      "projectId" => World.project(context, repository).id,
      "repository" => repository,
      "number" => number
    }

  defp ask_preview(context, number, client \\ "default", repository \\ "acme/shop") do
    {reply, context} =
      World.call(context, "pullRequests.preview", ref(context, number, repository), client)

    Map.put(context, :reply, reply)
  end

  # The fake GitHub answers the narrow read of pull request `number` of `repository`.
  defp answer_preview(context, number, repository \\ "acme/shop") do
    pr = Shared.gh_pr(repository, number)
    {owner, name} = repository |> String.split("/", parts: 2) |> List.to_tuple()

    World.cli_rules(context, [
      %{
        "args" => ["api graphql"],
        "stdin" => [
          @preview_fields,
          ~s("owner":"#{owner}"),
          ~s("name":"#{name}"),
          ~s("number":#{number})
        ],
        "stdout" => %{
          "data" => %{
            "repository" => %{
              "pullRequest" =>
                pr
                |> Map.take(~w(number title url state isDraft createdAt))
                |> Map.put("author", %{"login" => "octocat", "avatarUrl" => nil})
            }
          }
        }
      }
    ])
  end

  # The bodies of the narrow reads the fake GitHub was sent for `number` of `repository`.
  defp preview_requests(context, number, repository \\ "acme/shop") do
    {owner, name} = repository |> String.split("/", parts: 2) |> List.to_tuple()

    for call <- World.cli_calls(context, "api graphql"),
        request = JSON.decode!(call["stdin"]),
        request["query"] =~ @preview_fields,
        request["variables"] == %{"owner" => owner, "name" => name, "number" => number},
        do: call["stdin"]
  end

  defp preview_reads(context, number), do: length(preview_requests(context, number))

  # The MC's pull request clock, `offset` milliseconds after the scenario's start.
  defp at(context, offset) do
    start = context[:clock_start] || System.system_time(:millisecond)

    if context[:clock_start] == nil do
      previous = Application.get_env(:hal_c2, :pull_requests_clock)

      ExUnit.Callbacks.on_exit(fn ->
        if previous,
          do: Application.put_env(:hal_c2, :pull_requests_clock, previous),
          else: Application.delete_env(:hal_c2, :pull_requests_clock)
      end)
    end

    Application.put_env(:hal_c2, :pull_requests_clock, fn -> start + offset end)
    Map.put(context, :clock_start, start)
  end

  # Runs `script` in the fake GitHub before it answers the first rule whose stdin has `fragment`.
  defp gate(context, fragment, script) do
    rules = context.cli.rules |> File.read!() |> JSON.decode!()
    index = Enum.find_index(rules, &(fragment in (&1["stdin"] || [])))
    assert index, "no rule answers #{fragment}"
    rules = List.update_at(rules, index, &Map.put(&1, "run", script))
    File.write!(context.cli.rules, JSON.encode!(rules))
    context
  end
end
