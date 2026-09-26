defmodule T3.Steps.SourceControl do
  @moduledoc """
  Steps several `features/source-control/` files share; their setup lives in
  `T3.Steps.SourceControl.Shared` (`test/steps/support/source_control.exs`).
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.Steps.SourceControl.Shared
  alias T3.Test.Node.World

  step "a connected environment with a thread in the git project {string}",
       %{args: [title]} = context do
    Shared.thread_in_git_project(context, title)
  end

  step "a connected environment with a thread in the git project {string} on the branch {string}",
       %{args: [title, branch]} = context do
    context = Shared.thread_in_git_project(context, title)
    World.git!(context.cwd, ["checkout", "-q", "-b", branch])
    context
  end

  step "a connected environment with the GitHub project {string}", %{args: [repo]} = context do
    context
    |> World.github_project(repo)
    |> then(&World.put_client(&1, World.client(&1)))
  end

  step "status is read for {string}", %{args: [title]} = context do
    {reply, context} =
      World.call(context, "vcs.refreshStatus", %{"cwd" => World.project(context, title).root})

    Map.put(context, :reply, reply)
  end

  step "the user initializes Git for {string}", %{args: [title]} = context do
    {reply, context} =
      World.call(context, "vcs.init", %{"cwd" => World.project(context, title).root})

    Map.put(context, :reply, reply)
  end

  step ~r/^the user looks up "(?<repository>[^"]+)" on (?<host>GitHub|GitLab|Forgejo|Azure DevOps|Bitbucket)$/,
       %{args: [repository, host]} = context do
    provider = Shared.provider(host)
    context = Shared.answer_lookup(context, provider, repository)

    {reply, context} =
      World.call(context, "sourceControl.lookupRepository", %{
        "provider" => provider,
        "repository" => repository
      })

    Map.merge(context, %{reply: reply, looked_up: repository})
  end

  step "the user pushes", context do
    {events, context} = World.git_action(context, context.cwd, "push")
    Map.put(context, :git_events, events)
  end

  step "the checkout is on a detached HEAD", context do
    World.git!(context.cwd, ~w(checkout -q --detach))
    context
  end

  step "the GitHub CLI is not installed", context do
    World.remove_cli(context, "gh")
  end

  step "the GitHub CLI is not signed in", context do
    T3.PullRequests.invalidate(%{})

    World.cli_rules(context, %{
      "args" => ["api user"],
      "stderr" => "To get started with GitHub CLI, please run:  gh auth login\n",
      "exit" => 1
    })
  end

  step "the writer model is unreachable", context do
    World.fake_writer(
      context,
      "cat > /dev/null\necho 'connect ECONNREFUSED 127.0.0.1:443' >&2\nexit 1\n"
    )
  end

  step "the action fails with {string}", %{args: [message]} = context do
    assert World.failure(context) =~ message
    context
  end

  step "the action fails with a message starting {string}", %{args: [prefix]} = context do
    assert String.starts_with?(World.failure(context), prefix),
           "#{inspect(World.failure(context))} does not start with #{inspect(prefix)}"

    context
  end

  step "the user unlinks pull request {int}", %{args: [number]} = context do
    title = context[:pr_thread] || "Tax work"
    id = World.thread_id(context, title)
    repository = context[:repository] || "acme/shop"

    {{:ok, _}, context} =
      World.dispatch(context, %{
        "type" => "thread.pull-request.unlink",
        "threadId" => id,
        "host" => "github.com",
        "repository" => repository,
        "number" => number
      })

    World.await_row(id, fn row ->
      not Enum.any?(
        row["pullRequests"] || [],
        &(&1["number"] == number and &1["source"] != "stack-dismissed")
      )
    end)

    context
  end
end
