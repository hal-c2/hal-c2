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
    layers = for n <- [a, b, c], do: layer(n)

    context
    |> Shared.open_pull_request(c)
    |> Map.merge(%{stack: %{base: base, layers: layers, number: @stack_number}, rebased: %{}})
    |> answer_stack()
    |> World.cli_rules(%{
      "args" => ["--method PUT", "merge-async"],
      "stdout" => %{"status" => "merged", "details" => %{}}
    })
  end

  # --- reading -------------------------------------------------------------------------

  step "the user asks for the stack of pull request {int}", %{args: [number]} = context do
    ref = %{Shared.pr_ref(context) | "number" => number}
    {reply, context} = World.call(context, "pullRequests.stack", ref)
    assert {:ok, stack} = reply
    Map.merge(context, %{read: stack, reply: reply})
  end

  step "pull request {int} has no stack", %{args: [number]} = context do
    assert number == 42
    assert context.read == nil
    context
  end

  step "GitHub does not offer stacks for {string}", %{args: [_repository]} = context do
    World.cli_rules(context, %{"args" => ["stacks?pull_request="], "stdout" => []})
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
    if is_function(context[:refused_with], 2) do
      context.refused_with.(context, message)
    else
      assert World.failure(context) == message
      assert World.cli_calls(context, "merge-async") == []
      context
    end
  end

  # --- rebasing ------------------------------------------------------------------------

  step "the user rebases the stack", context do
    checkout = checkout(context)

    {heads, context} =
      case context[:seen_heads] do
        nil ->
          {stack, context} = read_stack(context, context.pr_number)
          open = Enum.filter(stack["layers"], &(&1["state"] == "open"))
          {for(l <- open, do: Map.take(l, ["number", "headSha"])), context}

        seen ->
          {seen, context}
      end

    context
    |> run(%{"action" => "update-branch", "updateMethod" => "rebase"}, heads)
    |> Map.put(:checkout, checkout)
  end

  step "the user rebases the stack from pull request {int}", %{args: [number]} = context do
    {stack, context} = read_stack(context, number)
    heads = for l <- stack["layers"], do: Map.take(l, ["number", "headSha"])

    context
    |> Map.put(:pr_number, number)
    |> run(%{"action" => "update-branch", "updateMethod" => "rebase"}, heads)
  end

  step "it is refused because the stack no longer matches", context do
    assert World.failure(context) == "The stack changed. Refresh it before trying again."
    context
  end

  step "nothing is rebased", context do
    assert rebases(context) == []
    context
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

  # --- merge answers and layer states ---------------------------------------------------

  defp merge_async(context, put_answer, poll_answer \\ nil) do
    World.put_app_env(:stack_merge_backoff_ms, 5)

    rules = [
      %{"args" => ["--method PUT", "merge-async"], "stdout" => put_answer}
      | if(poll_answer,
          do: [%{"args" => ["merge-async/job-1"], "stdout" => poll_answer}],
          else: []
        )
    ]

    World.cli_rules(context, rules)
  end

  step "GitHub is asked once to merge pull request {int} by squash at the head the user reviewed",
       %{args: [number]} = context do
    assert {:ok, _} = context.reply
    assert [call] = World.cli_calls(context, "merge-async")
    assert Enum.join(call["args"], " ") =~ "repos/acme/shop/pulls/#{number}/merge-async"
    body = JSON.decode!(call["stdin"])
    assert body["sha"] == sha("a", number)
    assert body["merge_method"] == "squash"
    context
  end

  step "the layers below it are merged by that one request", context do
    assert World.cli_calls(context, "pr merge") == []
    assert Enum.map(context.sent_heads, & &1["number"]) == [41, 42, 43]
    context
  end

  step "GitHub's merge queue accepts the stack merge", context do
    merge_async(context, %{"status" => "enqueued", "details" => %{}})
  end

  step "the stack merge is accepted as submitted", context do
    assert {:ok, _} = context.reply
    assert [_] = World.cli_calls(context, "merge-async")
    context
  end

  step "the MC does not claim the layers are merged yet", context do
    {stack, context} = read_stack(context, context.pr_number)
    assert Enum.all?(stack["layers"], &(&1["state"] == "open"))
    context
  end

  step "GitHub accepts the stack merge and later reports that it failed", context do
    merge_async(
      context,
      %{"status" => "pending", "details" => %{"uuid" => "job-1"}},
      %{"status" => "failed", "details" => %{}}
    )
  end

  step "no layer is reported as merged", context do
    assert {:error, _, _} = context.reply
    context
  end

  step "GitHub is still working on the stack merge after five minutes", context do
    World.put_app_env(:stack_merge_deadline_ms, 30)

    merge_async(
      context,
      %{"status" => "pending", "details" => %{"uuid" => "job-1"}},
      %{"status" => "pending", "details" => %{"uuid" => "job-1"}}
    )
  end

  step "the MC stops polling instead of waiting without limit", context do
    assert {:error, _, _} = context.reply
    # The merge was asked for and its status polled, then the MC gave up polling.
    assert [_ | _] = World.cli_calls(context, "merge-async/job-1")
    context
  end

  step "GitHub answers a stack action with something the MC cannot read", context do
    merge_async(context, %{"status" => "surprise", "details" => %{}})
  end

  step "nothing is changed", context do
    assert {:error, _, _} = context.reply
    assert World.cli_calls(context, "pr merge") == []
    assert rebases(context) == []
    context
  end

  step "nothing is merged", context do
    assert World.cli_calls(context, "merge-async") == []
    assert World.cli_calls(context, "pr merge") == []
    context
  end

  step "the stack also has draft pull requests {int} and {int} above pull request {int}",
       %{args: [a, b, _below]} = context do
    layers = context.stack.layers ++ [%{layer(a) | draft: true}, %{layer(b) | draft: true}]
    context |> put_in([:stack, :layers], layers) |> answer_stack()
  end

  step "pull requests {int}, {int} and {int} are merged", %{args: numbers} = context do
    assert {:ok, _} = context.reply
    assert [_] = World.cli_calls(context, "merge-async")
    assert Enum.map(context.sent_heads, & &1["number"]) == numbers
    context
  end

  step "pull requests {int} and {int} stay open", %{args: numbers} = context do
    for n <- numbers do
      assert World.cli_calls(context, "pulls/#{n}/") == []
      assert World.cli_calls(context, "pr merge #{n}") == []
    end

    context
  end

  step "pull request {int} is already merged", %{args: [number]} = context do
    update_layer(context, number, &%{&1 | state: "closed", merged_at: "2026-09-20T00:00:00Z"})
  end

  step "pull request {int} was squash-merged into {string} and {int} and {int} are still open",
       %{args: [merged, _base, a, b]} = context do
    context =
      update_layer(context, merged, &%{&1 | state: "closed", merged_at: "2026-09-20T00:00:00Z"})

    assert Enum.all?([a, b], fn n ->
             Enum.find(context.stack.layers, &(&1.number == n)).state == "open"
           end)

    context
  end

  step "{int} and {int} are rebased onto {string} without {int}'s own commits",
       %{args: [a, b, base, _merged]} = context do
    assert {:ok, _} = context.reply
    assert context.stack.base == base
    assert rebases(context) == for(n <- [a, b], do: %{"id" => "PR_#{n}", "sha" => sha("a", n)})
    context
  end

  step "no conflict is reported", context do
    assert {:ok, _} = context.reply
    context
  end

  step "GitHub refuses to rebase pull request {int}", %{args: [number]} = context do
    context |> Map.put(:conflict, number) |> answer_stack()
  end

  step ~r/^pull request (?<number>\d+) comes from a fork whose owner (?<allows>allows|does not allow) maintainer updates$/,
       %{args: [number, allows]} = context do
    number = String.to_integer(number)

    context
    |> Map.put(:fork_layer, number)
    |> update_layer(number, &%{&1 | maintainer: allows == "allows", permission: "READ"})
  end

  step "the user has no write access to that fork", context do
    update_layer(context, context.fork_layer, &%{&1 | permission: "READ"})
  end

  step "no layer is rebased, including the ones below pull request {int}",
       %{args: [_number]} = context do
    assert rebases(context) == []
    context
  end

  step "pull request {int} is rebased with the other layers", %{args: [number]} = context do
    assert {:ok, _} = context.reply
    assert List.last(rebases(context))["id"] == "PR_#{number}"
    assert length(rebases(context)) == 3
    context
  end

  step "pull request {int} is already up to date with {string}",
       %{args: [number, _base]} = context do
    update_layer(context, number, &%{&1 | behind: 0})
  end

  step "pull request {int} is not rebased again", %{args: [number]} = context do
    refute Enum.any?(rebases(context), &(&1["id"] == "PR_#{number}"))
    context
  end

  step "pull requests {int} and {int} are rebased", %{args: numbers} = context do
    assert {:ok, _} = context.reply
    assert Enum.map(rebases(context), & &1["id"]) == Enum.map(numbers, &"PR_#{&1}")
    context
  end

  step "someone pushes to pull request {int} while the stack is being rebased",
       %{args: [number]} = context do
    context |> Map.put(:moved, %{number => sha("c", number)}) |> answer_stack()
  end

  step "the rebase stops at pull request {int} without rebasing the pushed revision",
       %{args: [number]} = context do
    assert {:error, _, _} = context.reply
    assert Enum.map(rebases(context), & &1["id"]) == ["PR_41", "PR_42"]
    assert number == 43
    context
  end

  step "someone pushes to pull request {int} after it was rebased but before pull request {int} was",
       %{args: [moved, _next]} = context do
    context |> Map.put(:moved_processed, moved) |> answer_stack()
  end

  step "pull request {int} is not rebased onto the new revision", %{args: [number]} = context do
    assert {:error, _, _} = context.reply
    refute Enum.any?(rebases(context), &(&1["id"] == "PR_#{number}"))
    context
  end

  step "the user is told which layer changed and how many finished before it", context do
    assert World.failure(context) ==
             "The stack changed at PR #41 after 1 layers. Earlier updates remain on GitHub. " <>
               "Refresh it before trying again."

    context
  end

  # --- a stack that changed after it was read --------------------------------------------

  defp seen(context) do
    {stack, context} = read_stack(context, context.pr_number)
    heads = for l <- stack["layers"], do: Map.take(l, ["number", "headSha"])
    Map.put(context, :seen_heads, heads)
  end

  step "pull request {int} left the stack after it was read", %{args: [number]} = context do
    context = seen(context)
    layers = Enum.reject(context.stack.layers, &(&1.number == number))
    context |> put_in([:stack, :layers], layers) |> answer_stack()
  end

  step "the stack was replaced by another stack", context do
    context |> put_in([:stack, :number], @stack_number + 5) |> answer_stack()
  end

  step "a layer was merged after the user looked", context do
    context = seen(context)
    update_layer(context, 41, &%{&1 | state: "closed", merged_at: "2026-09-20T00:00:00Z"})
  end

  step ~r/^the user merges the stack at (?<number>\d+)$/, %{args: [number]} = context do
    merge(context, String.to_integer(number), nil)
  end

  step "nothing is changed on GitHub", context do
    assert World.cli_calls(context, "merge-async") == []
    assert World.cli_calls(context, "pr merge") == []
    assert rebases(context) == []
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

  defp layer(number) do
    %{
      number: number,
      sha: sha("a", number),
      state: "open",
      draft: false,
      merged_at: nil,
      behind: 3,
      permission: "WRITE",
      maintainer: false
    }
  end

  @doc "Marks a stack layer draft, as GitHub's stack read reports it (for the shared draft step)."
  def mark_draft(context, number), do: update_layer(context, number, &%{&1 | draft: true})

  # The stack as GitHub's REST API and the rebase's GraphQL reads give it.
  defp answer_stack(context) do
    %{base: base, layers: layers} = context.stack
    number = context.stack[:number] || @stack_number

    stack = %{
      "id" => 9001,
      "number" => number,
      "html_url" => "https://github.com/acme/shop/stacks/#{number}",
      "base" => %{"ref" => base},
      "pull_requests" =>
        for l <- layers do
          %{
            "number" => l.number,
            "title" => "Layer #{l.number}",
            "state" => l.state,
            "draft" => l.draft,
            "merged_at" => l.merged_at,
            "head" => %{"ref" => "feature/#{l.number}", "sha" => l.sha}
          }
        end
    }

    access =
      Map.new(layers, fn l ->
        {"pr#{l.number}",
         %{
           "headRepository" => %{"viewerPermission" => l.permission},
           "maintainerCanModify" => l.maintainer
         }}
      end)

    {rebase_rules, _} =
      Enum.map_reduce(Enum.filter(layers, &(&1.state == "open")), [], fn l, done ->
        processed =
          Enum.map(done, fn
            {:moved, sha} -> %{"headRefOid" => sha}
            sha -> %{"headRefOid" => sha}
          end)

        read = %{
          "args" => ["api graphql"],
          "stdin" => ["processed: nodes(ids: $processed)", "\"number\":#{l.number}"],
          "stdout" => %{
            "data" => %{
              "processed" => processed,
              "repository" => %{
                "pullRequest" => %{
                  "id" => "PR_#{l.number}",
                  "headRefOid" => (context[:moved] || %{})[l.number] || l.sha,
                  "baseRef" => %{"compare" => %{"behindBy" => l.behind}}
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

        done_next =
          done ++
            [
              cond do
                context[:moved_processed] == l.number -> {:moved, sha("c", l.number)}
                l.behind == 0 -> l.sha
                true -> sha("b", l.number)
              end
            ]

        {[read, update], done_next}
      end)

    context
    |> World.cli_rules(
      [
        %{"args" => ["stacks?pull_request="], "stdout" => [stack]},
        %{"args" => ["stacks/#{number}"], "stdout" => stack},
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
