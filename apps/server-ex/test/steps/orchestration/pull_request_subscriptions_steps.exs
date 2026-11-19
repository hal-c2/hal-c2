defmodule HalC2.Steps.Orchestration.PullRequestSubscriptions do
  @moduledoc """
  Steps for `features/mc/orchestration/pull-request-subscriptions.feature`. The pull
  request and "the MC reads it" are `forgejo_pull_requests_steps.exs`'s; these call
  the subscription tools as the thread's agent over MCP, keeping a refusal in
  `context.refusal`.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Mc.World

  step ~r/^the agent of "(?<thread>[^"]+)" (?<verb>subscribes to|unsubscribes from) "(?<pr>[^"]+)"(?: for "(?<events>[^"]+)")?$/,
       %{args: [thread, verb, pr | events]} = context do
    tool =
      if verb == "subscribes to", do: "subscribe_pull_request", else: "unsubscribe_pull_request"

    [repository, number] = String.split(pr, "#")

    arguments =
      %{
        "host" => "codeberg.org",
        "repository" => repository,
        "number" => String.to_integer(number)
      }
      |> then(fn args ->
        case events do
          [list] when is_binary(list) and list != "" ->
            Map.put(args, "events", String.split(list, ", "))

          _ ->
            args
        end
      end)

    case World.mcp_tool(context, thread, tool, arguments) do
      {:ok, _} -> context
      {:error, _code, message} -> Map.put(context, :refusal, message)
    end
  end

  step "a legacy client sets {string} as the linked pull request of {string}",
       %{args: [pr, thread]} = context do
    [repository, number] = String.split(pr, "#")

    context =
      World.command(context, %{
        "type" => "thread.metadata.update",
        "threadId" => World.thread_id(context, thread),
        "linkedPullRequest" => %{
          "projectId" => World.project(context).id,
          "repository" => repository,
          "number" => String.to_integer(number),
          "url" => "https://codeberg.org/#{repository}/pulls/#{number}"
        }
      })

    assert {:ok, _} = context.reply
    context
  end

  step "the agent of {string} lists no pull request subscriptions",
       %{args: [thread]} = context do
    assert {:ok, %{"subscriptions" => []}} =
             World.mcp_tool(context, thread, "list_pull_request_subscriptions")

    context
  end

  step "the agent of {string} lists {string} on {string} subscribed to {string}",
       %{args: [thread, pr, host, events]} = context do
    [repository, number] = String.split(pr, "#")

    assert {:ok, %{"subscriptions" => [subscription]}} =
             World.mcp_tool(context, thread, "list_pull_request_subscriptions")

    assert %{"host" => ^host, "repository" => ^repository} = subscription
    assert subscription["number"] == String.to_integer(number)
    assert subscription["events"] == String.split(events, ", ")
    context
  end

  step "the subscription is refused with {string}", %{args: [text]} = context do
    assert context[:refusal] =~ text
    context
  end
end
