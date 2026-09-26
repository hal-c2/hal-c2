defmodule T3.Steps.Settings.General do
  @moduledoc """
  General settings the node itself acts on: auto-settling, response streaming,
  continuing after a restart, where new worktrees start and the text generation
  model. Each scenario's thread is "Ship checkout" in the project "shop".
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias T3.Orchestration.{Settlement, TurnWriter}
  alias T3.StreamState
  alias T3.Test.Node
  alias T3.Test.Node.World

  @thread "Ship checkout"
  @toggles %{
    "Auto-settle merged threads" => "sidebarAutoSettleOnMerge",
    "Start new worktrees from origin" => "newWorktreesStartFromOrigin"
  }

  # --- toggles -------------------------------------------------------------------------

  step ~r/^"(?<name>Auto-settle merged threads|Start new worktrees from origin)" is (?<state>on|off)$/,
       %{args: [name, state]} = context do
    World.update_settings(context, %{@toggles[name] => state == "on"})
  end

  step "\"Auto-settle inactive threads\" is on with {int} days", %{args: [days]} = context do
    World.update_settings(context, %{"sidebarAutoSettleAfterDays" => days})
  end

  step "\"Auto-settle inactive threads\" is off", context do
    World.update_settings(context, %{"sidebarAutoSettleAfterDays" => nil})
  end

  step ~r/^"Continue threads after restarts" is (?<state>on|off) for the project$/,
       %{args: [state]} = context do
    context = shop(context)

    World.update_settings(context, %{
      "projectSettingsOverrides" => %{
        World.project(context, "shop").id => %{
          "continueThreadsAfterServerUpdate" => state == "on"
        }
      }
    })
  end

  # --- auto-settle -----------------------------------------------------------------------

  step "every pull request linked to a thread has merged after the user last wrote in it",
       context do
    context
    |> ship_checkout()
    |> World.add_message(@thread, "user", "Ship it", World.iso_from_now(-World.days(1)))
    |> merged_pull_request()
  end

  step "every pull request linked to a thread has merged", context do
    context |> ship_checkout() |> merged_pull_request()
  end

  step "a thread has had no activity for {int} day(s)", %{args: [days]} = context do
    at = World.iso_from_now(-World.days(days) - 60_000)

    context
    |> ship_checkout()
    |> World.patch_thread(@thread, %{"createdAt" => at})
    |> World.add_message(@thread, "user", "Ship it", at)
  end

  step "the node sweeps threads", context do
    Node.ensure({Settlement, interval: nil})
    :ok = Settlement.sweep()
    context
  end

  # The sweep dispatches synchronously, so the thread entity already shows any settle.
  step "the thread is not settled for the merge", context do
    refute_settled(context)
  end

  step "the thread is not settled", context do
    refute_settled(context)
  end

  # --- response streaming ----------------------------------------------------------------

  step "the response streaming mode is {string}", %{args: [mode]} = context do
    World.update_settings(context, %{"responseStreamingMode" => mode})
  end

  # The agent's reply streams through the turn writer with the mode the orchestrator
  # resolves for the thread's project, then its 400 ms timer fires once.
  step "the agent writes a long reply", context do
    context = ship_checkout(context)
    id = World.thread_id(context, @thread)
    project = World.project(context, "shop").id

    {:ok, _} =
      T3.Streams.commit(id, :thread, [
        {"turn-item", "reply", %{"s" => %{"id" => "reply", "text" => ""}}}
      ])

    state = %{
      thread_id: id,
      turn: %{
        streaming_mode: T3.Settings.for_project(project)["responseStreamingMode"] || "paragraph"
      },
      items: %{"a" => %{id: "reply", message: nil, kind: :assistant}},
      buffer: %{},
      flush_timer: nil
    }

    reply = "Plan:\n\n```sh\nmix test\n```\n\nThen the las"
    state = state |> TurnWriter.buffer("a", "text", reply) |> TurnWriter.flush(:timer)
    streamed = reply_text(id)
    _ = TurnWriter.flush(state)

    Map.merge(context, %{streamed: streamed, finished: reply_text(id), reply_text: reply})
  end

  step "the reply appears a finished paragraph or closed code block at a time", context do
    assert context.streamed == "Plan:\n\n```sh\nmix test\n```\n\n"
    assert context.finished == context.reply_text
    context
  end

  step "the reply appears only when a boundary such as a tool call or the turn end comes",
       context do
    assert context.streamed == ""
    assert context.finished == context.reply_text
    context
  end

  # --- continuing after a restart --------------------------------------------------------

  # A codex run mid-turn on a provider thread that can resume, as the node left it.
  step "a turn was running when the node stopped", context do
    context = ship_checkout(context)
    id = World.thread_id(context, @thread)
    at = World.iso_from_now(-60_000)

    {:ok, _} =
      T3.Streams.commit(id, :thread, [
        {"provider-thread", "pt-1",
         %{
           "s" => %{
             "id" => "pt-1",
             "status" => "active",
             "nativeThreadRef" => %{"nativeId" => "native-1"}
           }
         }},
        {"run", "run-1",
         %{
           "s" => %{
             "id" => "run-1",
             "threadId" => id,
             "ordinal" => 1,
             "status" => "running",
             "requestedAt" => at,
             "providerThreadId" => "pt-1",
             "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"}
           }
         }}
      ])

    World.await_row(id, &(&1["activeRunId"] == "run-1"))
    context
  end

  step "the thread is asked to continue where it left off", context do
    state = thread_state(context)

    assert %{"status" => "interrupted"} = StreamState.get(state, "run")["run-1"]

    assert %{"text" => "Continue where you left off.", "createdBy" => "agent"} =
             StreamState.get(state, "message")["message:restart-continuation:run-1"]

    context
  end

  step "the thread stays interrupted", context do
    state = thread_state(context)

    assert [%{"id" => "run-1", "status" => "interrupted"}] = StreamState.list(state, "run")
    refute StreamState.get(state, "message")["message:restart-continuation:run-1"]
    context
  end

  # --- worktrees ---------------------------------------------------------------------

  # "shop" has an origin one commit ahead of its local main, not yet fetched.
  step "an agent creates a worktree for a thread without choosing a base", context do
    context = ship_checkout(context)
    root = World.project(context, "shop").root
    origin = Node.tmp_dir(context.node, "origin")
    World.git!(origin, ["clone", "-q", "--bare", root, "."])
    World.git!(root, ["remote", "add", "origin", origin])
    World.git!(root, ~w(fetch -q origin))

    upstream = Node.tmp_dir(context.node, "upstream")
    World.git!(upstream, ["clone", "-q", origin, "."])
    World.git!(upstream, ~w(config user.email t3@example.com))
    World.git!(upstream, ~w(config user.name T3))
    World.git!(upstream, ~w(commit -q --allow-empty -m upstream))
    World.git!(upstream, ~w(push -q origin main))

    {:ok, result} =
      T3.Mcp.Tools.call("t3_worktree_handoff", %{"branch" => "t3/ship-checkout"}, %{
        thread_id: World.thread_id(context, @thread),
        instance: "codex"
      })

    Map.merge(context, %{
      worktree: result,
      local_head: World.git!(root, ~w(rev-parse main)),
      origin_head: World.git!(upstream, ~w(rev-parse HEAD))
    })
  end

  step "the worktree starts from the latest matching branch on origin", context do
    assert %{"startedFromOrigin" => true, "baseRef" => "main"} = context.worktree
    assert worktree_head(context) == context.origin_head
    context
  end

  step "the worktree starts from the local branch", context do
    assert %{"startedFromOrigin" => false, "baseRef" => "main"} = context.worktree
    assert worktree_head(context) == context.local_head
    refute context.local_head == context.origin_head
    context
  end

  # --- text generation ---------------------------------------------------------------

  step "the text generation model is set to a model of an installed provider", context do
    context
    |> World.fake_text_clis([:claude, :codex])
    |> World.update_settings(%{
      "textGenerationModelSelection" => %{"instanceId" => "codex", "model" => "gpt-text"}
    })
  end

  # The title the node generates for a new thread's first message (`generate_title`).
  step "the node names a new thread", context do
    context = shop(context)
    root = World.project(context, "shop").root
    {:ok, title} = T3.TextGeneration.thread_title(root, "Fix the checkout total")
    Map.put(context, :title, title)
  end

  step "the title is written by that model", context do
    assert %{"title" => "codex title"} = context.title
    assert [%{"argv" => ["exec" | _] = argv, "prompt" => prompt}] = World.text_calls(context)
    assert Enum.at(argv, Enum.find_index(argv, &(&1 == "--model")) + 1) == "gpt-text"
    assert prompt =~ "Fix the checkout total"
    context
  end

  # --- helpers -------------------------------------------------------------------------

  defp shop(context),
    do: if(context.projects["shop"], do: context, else: World.create_project(context, "shop"))

  defp ship_checkout(context) do
    context = shop(context)

    context =
      if context.threads[@thread],
        do: context,
        else: World.create_thread(context, @thread, "shop")

    Map.put(context, :thread, @thread)
  end

  defp merged_pull_request(context) do
    id = World.thread_id(context, @thread)
    base = %{"threadId" => id, "host" => "github.com", "repository" => "acme/shop", "number" => 5}

    {:ok, _} =
      T3.Orchestration.dispatch(
        Map.merge(base, %{
          "type" => "thread.pull-request.link",
          "url" => "https://github.com/acme/shop/pull/5",
          "source" => "manual"
        })
      )

    {:ok, _} =
      T3.Orchestration.dispatch(
        Map.merge(base, %{
          "type" => "thread.pull-request-link.sync",
          "snapshot" => %{
            "state" => "merged",
            "title" => "PR 5",
            "mergedAt" => World.iso_from_now(0),
            "syncedAt" => World.iso_from_now(0)
          },
          "stack" => nil
        })
      )

    World.await_row(id, fn row ->
      Enum.any?(row["pullRequests"] || [], &(&1["snapshot"]["state"] == "merged"))
    end)

    context
  end

  defp refute_settled(context) do
    refute World.thread(context, @thread)["settledOverride"] == "settled"
    refute World.row(context, @thread)["settledOverride"] == "settled"
    context
  end

  defp reply_text(thread_id),
    do:
      StreamState.get(T3.Streams.Server.state(T3.Streams.ensure(thread_id)), "turn-item")["reply"][
        "text"
      ]

  defp thread_state(context),
    do: T3.Streams.Server.state(T3.Streams.ensure(World.thread_id(context, @thread)))

  defp worktree_head(context),
    do: World.git!(context.worktree["worktreePath"], ~w(rev-parse HEAD))
end
