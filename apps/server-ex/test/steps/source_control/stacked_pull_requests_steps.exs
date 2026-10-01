defmodule HalC2.Steps.SourceControl.StackedPullRequests do
  @moduledoc """
  Steps for `features/source-control/stacked-pull-requests.feature`. The fake GitHub
  answers a native stack (`context.stack`: its base and layers, bottom first); the
  client reads it with `pullRequests.stack` and hands back the heads it saw, as the
  stack menu does.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.SourceControl.Shared
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @stack_number 7
  @unsupported "This stack action is not supported or has no expected head revision."

  step "the stack onto {string} of pull requests {int}, {int} and {int}, bottom to top",
       %{args: [base, a, b, c]} = context do
    layers = for n <- [a, b, c], do: %{number: n, sha: sha("a", n), state: "open"}

    context
    |> Shared.open_pull_request(c)
    |> Map.merge(%{stack: %{base: base, layers: layers}, rebased: %{}})
    |> answer_stack()
    |> World.cli_rules(%{
      "args" => ["--method PUT", "merge-async"],
      "stdout" => %{"status" => "merged", "details" => %{}}
    })
  end

  # --- reading -------------------------------------------------------------------------

  step "the user asks for the stack of pull request {int}", %{args: [number]} = context do
    {stack, context} = read_stack(context, number)
    Map.put(context, :read, stack)
  end

  step "the layers {int}, {int} and {int} are listed in order with their heads",
       %{args: numbers} = context do
    assert %{"number" => @stack_number, "base" => base, "layers" => layers} = context.read
    assert base == context.stack.base
    assert Enum.map(layers, & &1["number"]) == numbers
    assert Enum.map(layers, & &1["headSha"]) == Enum.map(numbers, &sha("a", &1))
    assert Enum.map(layers, & &1["headBranch"]) == Enum.map(numbers, &"feature/#{&1}")
    context
  end

  # --- merging -------------------------------------------------------------------------

  step "the user merges the stack at pull request {int} by {word}",
       %{args: [number, method]} = context do
    merge(context, number, method)
  end

  step "the user merges the stack at pull request {int}", %{args: [number]} = context do
    merge(context, number, nil)
  end

  step "pull requests {int} and {int} are merged or queued", %{args: [below, target]} = context do
    assert {:ok, _} = context.reply
    # GitHub merges a layer together with the open layers below it in one request.
    assert [call] = World.cli_calls(context, "merge-async")
    assert Enum.join(call["args"], " ") =~ "repos/acme/shop/pulls/#{target}/merge-async"
    body = JSON.decode!(call["stdin"])
    assert body["sha"] == sha("a", target)
    assert body["merge_method"] == context.merge_method

    assert Enum.map(context.sent_heads, & &1["number"]) == [below, target]
    context
  end

  step "pull request {int} stays open", %{args: [number]} = context do
    assert World.cli_calls(context, "pulls/#{number}/") == []
    assert World.cli_calls(context, "pr merge #{number}") == []
    assert World.cli_calls(context, "pr close #{number}") == []
    context
  end

  step "someone pushed to pull request {int} after the user read the stack",
       %{args: [number]} = context do
    {stack, context} = read_stack(context, context.pr_number)
    heads = for l <- stack["layers"], do: Map.take(l, ["number", "headSha"])

    context
    |> Map.put(:seen_heads, heads)
    |> update_layer(number, &%{&1 | sha: sha("c", number)})
  end

  step "the merge is refused and nothing is merged", context do
    assert World.failure(context) == "The stack changed. Refresh it before trying again."
    assert World.cli_calls(context, "merge-async") == []
    assert World.cli_calls(context, "pr merge") == []
    context
  end

  step "a stack merge is asked for without the layers' heads", context do
    run(context, %{"action" => "merge", "mergeMethod" => "merge"}, nil)
  end

  step "it is refused with {string}", %{args: [message]} = context do
    assert World.failure(context) == message
    assert World.cli_calls(context, "merge-async") == []
    context
  end

  # --- rebasing ------------------------------------------------------------------------

  step "the user rebases the stack", context do
    checkout = checkout(context)
    {stack, context} = read_stack(context, context.pr_number)
    heads = for l <- stack["layers"], do: Map.take(l, ["number", "headSha"])

    context
    |> run(%{"action" => "update-branch", "updateMethod" => "rebase"}, heads)
    |> Map.put(:checkout, checkout)
  end

  step "the user updates the stack's branches by merge", context do
    {stack, context} = read_stack(context, context.pr_number)
    heads = for l <- stack["layers"], do: Map.take(l, ["number", "headSha"])
    run(context, %{"action" => "update-branch", "updateMethod" => "merge"}, heads)
  end

  step "the action is refused", context do
    assert World.failure(context) == @unsupported
    assert rebases(context) == []
    context
  end

  step "{int}, {int} and {int} are rebased in that order onto {string} on GitHub",
       %{args: [a, b, c, base]} = context do
    assert {:ok, _} = context.reply
    assert context.stack.base == base

    assert rebases(context) ==
             for(n <- [a, b, c], do: %{"id" => "PR_#{n}", "sha" => sha("a", n)})

    context
  end

  step "the local checkout is not touched", context do
    assert checkout(context) == context.checkout
    context
  end

  step "rebasing pull request {int} will conflict", %{args: [number]} = context do
    context |> Map.put(:conflict, number) |> answer_stack()
  end

  step "{int} and {int} stay rebased", %{args: [a, b]} = context do
    assert {:error, _, _} = context.reply
    # Every layer was asked for; the ones before the conflict are not undone.
    assert [%{"id" => first}, %{"id" => second}, %{"id" => failed}] = rebases(context)
    assert [first, second] == ["PR_#{a}", "PR_#{b}"]
    assert failed == "PR_#{context.conflict}"
    context
  end

  step "the user is told how many layers finished before the failure", context do
    assert World.failure(context) ==
             "Stack rebase stopped at PR ##{context.conflict} after 2 layers. " <>
               "Earlier updates remain on GitHub; resolve the failing layer before retrying."

    context
  end

  # --- linking -------------------------------------------------------------------------

  step "the user links pull request {int} to the thread {string}",
       %{args: [number, title]} = context do
    link(context, number, title)
  end

  step "{string} also lists {int} and {int} as layers of its stack",
       %{args: [title, a, b]} = context do
    links = World.await_row(World.thread_id(context, title), &layers_linked?(&1, [a, b]))
    [manual] = Enum.filter(links["pullRequests"], &(&1["source"] == "manual"))
    assert %{"kind" => "native", "layers" => layers} = manual["stack"]
    assert Enum.map(layers, & &1["number"]) == Enum.map(context.stack.layers, & &1.number)
    context
  end

  step "pull request {int} was linked to {string} through its stack",
       %{args: [number, title]} = context do
    [bottom | _] = context.stack.layers
    context = link(context, bottom.number + 1, title)
    World.await_row(World.thread_id(context, title), &layers_linked?(&1, [number]))
    Map.merge(context, %{pr_thread: title, repository: "acme/shop"})
  end

  step "the next sync does not bring {int} back", %{args: [number]} = context do
    reads = length(World.cli_calls(context, "stacks?pull_request="))
    # A newer snapshot makes the sweep read the stack again.
    context = answer_summaries(context, "2026-09-03T00:00:00Z")
    HalC2.PullRequests.Sync.request(%{"repository" => "acme/shop", "number" => number - 1})
    :ok = HalC2.PullRequests.Sync.sweep()
    assert length(World.cli_calls(context, "stacks?pull_request=")) > reads

    row = World.await_row(World.thread_id(context, context.pr_thread), & &1)

    assert [%{"source" => "stack-dismissed"}] =
             Enum.filter(row["pullRequests"], &(&1["number"] == number))

    context
  end

  # --- helpers -------------------------------------------------------------------------

  defp sha(prefix, number), do: String.duplicate(prefix, 38) <> "#{number}"

  defp read_stack(context, number) do
    ref = %{Shared.pr_ref(context) | "number" => number}
    {reply, context} = World.call(context, "pullRequests.stack", ref)
    assert {:ok, %{} = stack} = reply
    {stack, context}
  end

  defp merge(context, number, method) do
    {heads, context} =
      case context[:seen_heads] do
        nil ->
          {stack, context} = read_stack(context, number)
          layers = Enum.take_while(stack["layers"], &(&1["number"] <= number))
          {for(l <- layers, do: Map.take(l, ["number", "headSha"])), context}

        seen ->
          {Enum.filter(seen, &(&1["number"] <= number)), context}
      end

    context
    |> Map.merge(%{pr_number: number, merge_method: method || "merge"})
    |> run(%{"action" => "merge", "mergeMethod" => method || "merge"}, heads)
  end

  defp run(context, input, heads) do
    input =
      Shared.pr_ref(context)
      |> Map.merge(input)
      |> Map.put("stackNumber", @stack_number)
      |> then(&if(heads, do: Map.put(&1, "expectedStackHeads", heads), else: &1))

    {reply, context} = World.call(context, "pullRequests.runAction", input)
    Map.merge(context, %{reply: reply, sent_heads: heads, acted: true})
  end

  defp update_layer(context, number, fun) do
    layers = Enum.map(context.stack.layers, &if(&1.number == number, do: fun.(&1), else: &1))
    context |> put_in([:stack, :layers], layers) |> answer_stack()
  end

  # The stack as GitHub's REST API and the rebase's GraphQL reads give it.
  defp answer_stack(context) do
    %{base: base, layers: layers} = context.stack

    stack = %{
      "id" => 9001,
      "number" => @stack_number,
      "html_url" => "https://github.com/acme/shop/stacks/#{@stack_number}",
      "base" => %{"ref" => base},
      "pull_requests" =>
        for l <- layers do
          %{
            "number" => l.number,
            "title" => "Layer #{l.number}",
            "state" => l.state,
            "draft" => false,
            "merged_at" => nil,
            "head" => %{"ref" => "feature/#{l.number}", "sha" => l.sha}
          }
        end
    }

    access =
      Map.new(layers, fn l ->
        {"pr#{l.number}",
         %{"headRepository" => %{"viewerPermission" => "WRITE"}, "maintainerCanModify" => false}}
      end)

    {rebase_rules, _} =
      Enum.map_reduce(layers, [], fn l, done ->
        read = %{
          "args" => ["api graphql"],
          "stdin" => ["processed: nodes(ids: $processed)", "\"number\":#{l.number}"],
          "stdout" => %{
            "data" => %{
              "processed" => for(d <- done, do: %{"headRefOid" => d}),
              "repository" => %{
                "pullRequest" => %{
                  "id" => "PR_#{l.number}",
                  "headRefOid" => l.sha,
                  "baseRef" => %{"compare" => %{"behindBy" => 3}}
                }
              }
            }
          }
        }

        update =
          if context[:conflict] == l.number,
            do: %{"stderr" => "GraphQL: Merge conflict in src/tax.ts\n", "exit" => 1},
            else: %{
              "stdout" => %{
                "data" => %{
                  "updatePullRequestBranch" => %{
                    "pullRequest" => %{"headRefOid" => sha("b", l.number)}
                  }
                }
              }
            }

        update =
          Map.merge(update, %{
            "args" => ["api graphql"],
            "stdin" => ["updatePullRequestBranch(", "\"id\":\"PR_#{l.number}\""]
          })

        {[read, update], done ++ [sha("b", l.number)]}
      end)

    context
    |> World.cli_rules(
      [
        %{"args" => ["stacks?pull_request="], "stdout" => [stack]},
        %{"args" => ["stacks/#{@stack_number}"], "stdout" => stack},
        %{
          "args" => ["api graphql"],
          "stdin" => ["headRepository { viewerPermission } maintainerCanModify"],
          "stdout" => %{"data" => %{"repository" => access}}
        }
      ] ++ List.flatten(rebase_rules)
    )
    |> answer_summaries("2026-09-02T00:00:00Z")
  end

  defp answer_summaries(context, updated_at) do
    pr = %{
      "title" => "Layer",
      "url" => "https://github.com/acme/shop/pull/42",
      "state" => "OPEN",
      "isDraft" => false,
      "headRefName" => "feature/42",
      "baseRefName" => "feature/41",
      "updatedAt" => updated_at,
      "mergedAt" => nil,
      "author" => %{"login" => "octocat"}
    }

    World.cli_rules(context, %{
      "args" => ["api graphql"],
      "stdin" => ["PullRequestSummaries"],
      "stdout" => %{"data" => Map.new(0..2, &{"s#{&1}", %{"pullRequest" => pr}})}
    })
  end

  # The updates the rebase sent, in order: the layer and the head it expected.
  defp rebases(context) do
    for call <- World.cli_calls(context, "api graphql"),
        String.contains?(call["stdin"] || "", "updatePullRequestBranch("),
        %{"query" => query, "variables" => vars} = JSON.decode!(call["stdin"]) do
      assert query =~ "updateMethod: REBASE"
      %{"id" => vars["id"], "sha" => vars["sha"]}
    end
  end

  defp checkout(context) do
    for args <- [~w(rev-parse HEAD), ~w(status --porcelain), ~w(for-each-ref)],
        do: World.git!(context.cwd, args)
  end

  defp link(context, number, title) do
    Mc.ensure({HalC2.PullRequests.Sync, interval: nil})

    context =
      if (context[:threads] || %{})[title],
        do: context,
        else: World.create_thread(context, title, "acme/shop")

    id = World.thread_id(context, title)

    {{:ok, _}, context} =
      World.dispatch(context, %{
        "type" => "thread.pull-request.link",
        "threadId" => id,
        "host" => "github.com",
        "repository" => "acme/shop",
        "number" => number,
        "url" => "https://github.com/acme/shop/pull/#{number}",
        "source" => "manual"
      })

    World.await_row(id, &Enum.any?(&1["pullRequests"] || [], fn l -> l["number"] == number end))
    :ok = HalC2.PullRequests.Sync.sweep()
    context
  end

  defp layers_linked?(row, numbers) do
    linked = for l <- row["pullRequests"] || [], l["source"] == "stack", do: l["number"]
    Enum.all?(numbers, &(&1 in linked))
  end
end
