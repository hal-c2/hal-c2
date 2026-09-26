defmodule T3.Steps.SourceControl.PullRequestRouting do
  @moduledoc """
  Steps for `features/source-control/pull-request-routing.feature`. The scenario's
  node is the remote environment (`context.remote`); its fake `gh` is signed in as
  one account at a time, each with its own token.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.Steps.SourceControl.Shared
  alias T3.Test.Node.World

  @accounts %{"octocat" => 583_231, "hubot" => 480_938, "monalisa" => 7}

  step "{string} has the GitHub CLI signed in as {string}", %{args: [remote, login]} = context do
    assert remote == context.remote
    context |> World.github_project("acme/shop") |> sign_in(login)
  end

  step "{string} is now signed in as {string}", %{args: [remote, login]} = context do
    assert remote == context.remote
    sign_in(context, login)
  end

  step "{string} has no project on {string}", %{args: [remote, host]} = context do
    assert remote == context.remote
    # A project that is not on GitHub, and a gh that is signed in all the same.
    context = context |> World.create_project("notes") |> sign_in("octocat")

    refute Enum.any?(
             Map.values(context.projects),
             &String.contains?(World.git!(&1.root, ~w(remote -v)), host)
           )

    context
  end

  step "a client asks {string} who it is on {string}", %{args: [remote, host]} = context do
    assert remote == context.remote
    {reply, context} = World.call(context, "pullRequests.routingIdentity", %{"host" => host})
    Map.put(context, :reply, reply)
  end

  step "{string} answers with the account id and login of {string}",
       %{args: [_remote, login]} = context do
    assert {:ok, identity} = context.reply

    assert identity == %{
             "accountId" => "#{@accounts[login]}",
             "viewer" => login,
             "host" => "github.com",
             "provider" => "github"
           }

    context
  end

  step "the answer is that the provider is unsupported there", context do
    assert {:error, _,
            %{"_tag" => "PullRequestUnavailableError", "reason" => "provider-unsupported"}} =
             context.reply

    assert World.cli_calls(context, "api user") == []
    context
  end

  step "the client expects {string} to act as the account of {string}",
       %{args: [remote, login]} = context do
    context =
      context
      |> World.github_project("acme/shop")
      |> sign_in(login)
      |> Shared.open_pull_request(42)

    {reply, context} =
      World.call(context, "pullRequests.routingIdentity", %{"host" => "github.com"})

    assert {:ok, %{"accountId" => id, "viewer" => ^login}} = reply
    assert remote == context.remote
    Map.put(context, :expected_account, id)
  end

  step "the client merges a pull request through {string}", %{args: [remote]} = context do
    assert remote == context.remote

    input =
      context
      |> Shared.pr_ref()
      |> Map.merge(%{
        "host" => "github.com",
        "expectedAccountId" => context.expected_account,
        "action" => "merge",
        "mergeMethod" => "merge"
      })

    {reply, context} = World.call(context, "pullRequests.runAction", input)
    Map.put(context, :reply, reply)
  end

  step "the merge is refused with {string}", %{args: [message]} = context do
    assert World.failure(context) == message
    assert World.cli_calls(context, "pr merge") == []
    context
  end

  step "{string} verified its GitHub account {int} minutes ago",
       %{args: [remote, minutes]} = context do
    assert remote == context.remote
    context = context |> World.github_project("acme/shop") |> sign_in("octocat")
    fingerprint = :crypto.hash(:sha256, token("octocat")) |> Base.encode16(case: :lower)
    at = System.monotonic_time(:millisecond) - minutes * 60_000
    identity = %{"id" => "#{@accounts["octocat"]}", "login" => "octocat"}
    # The node's clock cannot be moved, so the verification is dated back where it is held.
    :persistent_term.put({T3.PullRequests, :viewers}, %{
      {"github.com", fingerprint} => {at, identity}
    })

    Map.put(context, :believed, identity)
  end

  step "the answer comes without asking GitHub again", context do
    assert {:ok, %{"accountId" => id, "viewer" => login}} = context.reply
    assert %{"id" => ^id, "login" => ^login} = context.believed
    assert World.cli_calls(context, "api user") == []
    # Only the local token was read, to know the account had not changed.
    assert [_] = World.cli_calls(context, "auth token")
    context
  end

  defp token(login), do: "gho_#{login}_token"

  defp sign_in(context, login) do
    World.cli_rules(context, [
      %{"args" => ["auth token"], "stdout" => token(login) <> "\n"},
      %{"args" => ["api user"], "stdout" => %{"id" => @accounts[login], "login" => login}}
    ])
  end
end
