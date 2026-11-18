defmodule HalC2.Steps.Orchestration.ForgejoPullRequests do
  @moduledoc """
  Steps for `features/mc/orchestration/forgejo-pull-requests.feature`.

  The project's origin is on codeberg.org, a Forgejo host, and the server is a fake
  (`HalC2.Steps.SourceControl.Shared.forgejo_api/3`) answering from the one pull
  request the scenario keeps in an Agent (`context.forgejo_pr`), signed in as
  "octocat". "The MC reads it" is a sync sweep followed by a wake check of every
  thread, as in `pull_request_wakes_steps.exs`, whose outcome steps ("is not woken",
  "the message says") these scenarios share through `context.heard` and
  `context.wake`.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.StreamState
  alias HalC2.Steps.SourceControl.Shared
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @host "codeberg.org"
  @busy ~w(preparing starting running waiting queued)

  step "an MC with a project {string} on Forgejo {string}",
       %{args: [title, repository]} = context do
    context = World.create_project(context, title)
    root = World.project(context, title).root

    {_, 0} =
      System.cmd("git", ["remote", "add", "origin", "https://#{@host}/#{repository}.git"],
        cd: root
      )

    Mc.ensure({HalC2.PullRequests.Sync, interval: nil})
    Mc.ensure(HalC2.PullRequests.Wakes)

    pr =
      ExUnit.Callbacks.start_supervised!(
        {Agent,
         fn ->
           %{
             repository: repository,
             number: 7,
             state: "open",
             merged: false,
             status: "pending",
             reviews: [],
             comments: [],
             clock: 0
           }
         end},
        id: :forgejo_pr
      )

    context
    |> Map.merge(%{forgejo_pr: pr, heard: MapSet.new()})
    |> Shared.forgejo_api(routes(pr, repository), @host)
  end

  step ~r/^thread "(?<thread>[^"]+)" in "(?<project>[^"]+)" links Forgejo pull request "(?<pr>[^"]+)", which the MC has read once$/,
       %{args: [thread, project, pr]} = context do
    {repository, number} = parse(pr)

    context = World.named_thread(context, thread, project)

    context =
      World.command(context, %{
        "type" => "thread.pull-request.link",
        "threadId" => World.thread_id(context, thread),
        "host" => @host,
        "repository" => repository,
        "number" => number,
        "url" => "https://#{@host}/#{repository}/pulls/#{number}",
        "source" => "agent"
      })

    assert {:ok, _} = context.reply
    context |> Map.put(:forgejo_ref, {repository, number}) |> read()
  end

  step ~r/^(?<change>.+) and the MC reads it again$/, %{args: [change]} = context do
    Agent.update(context.forgejo_pr, fn pr ->
      pr = %{pr | clock: pr.clock + 1}
      at = at(pr.clock)

      case change do
        "its checks start failing" ->
          %{pr | status: "failure"}

        "a stranger comments" ->
          %{
            pr
            | comments: pr.comments ++ [%{"user" => %{"login" => "stranger"}, "created_at" => at}]
          }

        "collaborator \"maint\" requests changes" ->
          review = %{
            "id" => length(pr.reviews) + 1,
            "user" => %{"login" => "maint"},
            "state" => "REQUEST_CHANGES",
            "submitted_at" => at
          }

          %{pr | reviews: pr.reviews ++ [review]}

        "it is merged" ->
          %{pr | state: "closed", merged: true}
      end
    end)

    read(context)
  end

  step "the MC reads it again", context do
    read(context)
  end

  step "the agent of {string} is woken about {string}", %{args: [thread, summary]} = context do
    wakes =
      context
      |> World.entities(thread, "message")
      |> Enum.filter(&(get_in(&1, ["notification", "source", "kind"]) == "pull_request"))
      |> Enum.reject(&MapSet.member?(context.heard, &1["id"]))

    assert [wake] = wakes
    assert wake["notification"]["summary"] == summary
    context |> Map.update!(:heard, &MapSet.put(&1, wake["id"])) |> Map.put(:wake, wake)
  end

  step "thread {string} shows {string} as open with no stack",
       %{args: [thread, pr]} = context do
    link =
      context
      |> World.thread(thread)
      |> HalC2.Projection.PullRequests.of()
      |> Enum.find(&("#{&1["repository"]}##{&1["number"]}" == pr))

    assert link["snapshot"]["state"] == "open"
    assert link["stack"] == nil
    context
  end

  # --- the host ---------------------------------------------------------------------

  defp routes(pr, repository) do
    base = "/api/v1/repos/#{repository}"
    read = fn key -> fn _conn -> {200, Agent.get(pr, &Map.fetch!(&1, key))} end end

    %{
      "/api/v1/user" => {200, %{"login" => "octocat"}},
      "#{base}/collaborators" => {200, [%{"login" => "maint"}]},
      "#{base}/pulls/7" => fn _conn -> {200, Agent.get(pr, &pull/1)} end,
      "#{base}/pulls/7/reviews" => read.(:reviews),
      "#{base}/issues/7/comments" => read.(:comments),
      "#{base}/commits/abc123/status" => fn _conn ->
        status = Agent.get(pr, & &1.status)
        {200, %{"state" => status, "total_count" => 1, "statuses" => [%{"status" => status}]}}
      end
    }
  end

  defp pull(pr) do
    %{
      "number" => pr.number,
      "title" => "Fix the cart",
      "html_url" => "https://#{@host}/#{pr.repository}/pulls/#{pr.number}",
      "state" => pr.state,
      "merged" => pr.merged,
      "merged_at" => if(pr.merged, do: at(pr.clock)),
      "mergeable" => true,
      "head" => %{"ref" => "fix-cart", "sha" => "abc123"},
      "base" => %{"ref" => "main", "repo" => %{"owner" => %{"login" => "acme"}}},
      "updated_at" => at(pr.clock),
      "user" => %{"login" => "octocat"}
    }
  end

  defp at(clock), do: "2030-01-01T10:00:#{String.pad_leading("#{clock}", 2, "0")}Z"

  # --- the MC -----------------------------------------------------------------------

  # The second sweep takes the read the first one asked for; then every thread is
  # checked for news on rows that hold what the sync wrote, and every turn a wake
  # started has ended.
  defp read(context) do
    flush(context)
    {repository, number} = context.forgejo_ref
    HalC2.PullRequests.Sync.request(%{"repository" => repository, "number" => number})
    :ok = HalC2.PullRequests.Sync.sweep()
    :ok = HalC2.PullRequests.Sync.sweep()
    flush(context)
    :ok = HalC2.PullRequests.Wakes.sweep()

    for {title, _id} <- context.threads do
      World.await_thread(context, title, fn state ->
        not Enum.any?(StreamState.list(state, "run"), &(&1["status"] in @busy))
      end)
    end

    context
  end

  defp flush(context) do
    for {_title, id} <- context.threads, do: :ok = HalC2.Streams.flush_shell(id)
    :ok = GenServer.call(HalC2.Shell, :sync)
  end

  defp parse(pr) do
    [repository, number] = String.split(pr, "#")
    {repository, String.to_integer(number)}
  end
end
