defmodule HalC2.Steps.Plugins.TokenEconomizerToolPrune do
  @moduledoc """
  Steps for `features/plugins/token-economizer-tool-prune.feature`, on the same MC
  and package as the loop guard's steps (`token_economizer_steps.exs`, whose
  background these scenarios share). What a project learned is seeded by writing
  tool pruning's evidence file before the turn, as the loop guard's envelope is.
  What Claude ran without is read from the fake Claude's launches
  (`--disallowedTools`), and what the plugin lists is read through its
  `toolPrune` call.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @id "token-economizer"
  @instance "claudeAgent"

  # --- settings and seeded evidence ----------------------------------------------------

  step "tool pruning only proposes", context do
    {_, context} =
      World.call!(context, "plugins.saveSettings", %{
        "id" => @id,
        "settings" => %{"toolPrune" => "propose"}
      })

    context
  end

  step "a project whose Claude had {string} loaded and unused for {int} sessions",
       %{args: [tool, sessions]} = context do
    seed(context, %{
      "streaks" => %{tool => %{"sessions" => sessions, "prompts" => sessions}},
      "loadedSessions" => %{tool => sessions},
      "sessions" => sessions,
      "prompts" => sessions
    })

    context
  end

  step "a project whose Claude had {string} loaded and unused for {int} sessions, held for a quiet project",
       %{args: [tool, sessions]} = context do
    seed(context, %{
      "streaks" => %{tool => %{"sessions" => sessions, "prompts" => sessions}},
      "loadedSessions" => %{tool => sessions},
      "sessions" => sessions,
      "prompts" => sessions,
      "liveStreaks" => %{tool => %{"sessions" => sessions, "prompts" => sessions}},
      "pending" => %{"items" => [tool], "since" => 0},
      "lastActivity" => 0
    })

    context
  end

  step "tool pruning folds a project's conversations as soon as it is quiet", context do
    {_, context} =
      World.call!(context, "plugins.saveSettings", %{
        "id" => @id,
        "settings" => %{"toolPruneQuietMinutes" => 0}
      })

    watch(context)
  end

  step "a project where {string} is turned off for Claude", %{args: [tool]} = context do
    seed(context, %{"off" => [tool]})
    context
  end

  step "a project whose Claude used {string}", %{args: [tool]} = context do
    seed(context, %{"used" => [tool]})
    context
  end

  # --- turns ----------------------------------------------------------------------------

  step "a Claude thread in the project runs a turn", context do
    run_thread(context, "First")
  end

  step "a Claude thread in the project runs a turn in which a subagent uses {string}",
       %{args: [tool]} = context do
    run_thread(context, "First", "subagent works on: Check the tests using #{tool}")
  end

  step "another Claude thread in the project runs a turn", context do
    run_thread(context, "Second")
  end

  # A turn the thread ran that the plugin's feed dropped every event of, as a feed
  # with a full queue drops them: the run is in the thread, and the feed counts it to
  # say so on the next event it delivers.
  step "the plugin missed a turn of that thread in which Claude used {string}",
       %{args: [tool]} = context do
    miss_turn(context, %{"type" => "dynamic_tool_call", "providerToolName" => tool})
  end

  # The subagent's own calls are in its child thread: the parent's history shows only
  # that it worked in the turn.
  step "the plugin missed a turn of that thread in which a Claude subagent worked", context do
    miss_turn(context, %{
      "type" => "subagent",
      "origin" => "provider_native",
      "subagentId" => "subagent-missed"
    })
  end

  step "that thread runs another turn", context do
    title = context.prune_thread
    context = World.post_message(context, title, "again")
    World.await_runs(context, title, ["completed", "completed", "completed"])
    context
  end

  step "tool pruning lists {string} as used for the project", %{args: [tool]} = context do
    project = World.project(context).id

    await_prune(context, fn status ->
      Enum.any?(
        status["projects"],
        &(&1["projectId"] == project and get_in(&1, ["tools", tool, "state"]) == "used")
      )
    end)

    context
  end

  step "tool pruning counts all {int} turns, but at most the one it heard as leaving {string} unused",
       %{args: [turns, tool]} = context do
    project = World.project(context).id

    {%{"value" => %{"projects" => projects}}, _client} =
      await_prune(context, fn status ->
        Enum.any?(status["projects"], &(&1["projectId"] == project and &1["prompts"] == turns))
      end)

    [summary] = for %{"projectId" => ^project} = p <- projects, do: p
    assert summary["tools"][tool]["unusedPrompts"] <= 1
    context
  end

  step "Claude ran the turn with {string} available", %{args: [tool]} = context do
    refute denied(context) =~ tool
    context
  end

  step "Claude ran the turn without {string}", %{args: [tool]} = context do
    assert denied(context) =~ tool
    context
  end

  step "Claude ran that turn without {string}", %{args: [tool]} = context do
    assert denied(context) =~ tool
    context
  end

  # --- the person, through the plugin's calls -------------------------------------------

  step "the person applies tool pruning's proposal for the project", context do
    call(context, "toolPruneApply", %{})
  end

  step "the person applies {string} by name for the project", %{args: [tool]} = context do
    call(context, "toolPruneApply", %{"tools" => [tool]})
  end

  step "the person restores tool pruning's tools for the project", context do
    call(context, "toolPruneRestore", %{})
  end

  step "the person applies {string} by name for a project that never ran",
       %{args: [tool]} = context do
    never = "never-#{System.unique_integer([:positive])}"
    input = %{"projectId" => never, "provider" => @instance, "tools" => [tool]}

    {reply, context} =
      World.call(context, "plugins.call", %{
        "id" => @id,
        "method" => "toolPruneApply",
        "input" => input
      })

    Map.merge(context, %{prune_reply: reply, never_project: never})
  end

  step "tool pruning answers that it has no evidence for that project", context do
    assert {:error, _, _} = context.prune_reply
    context
  end

  step "tool pruning keeps nothing for that project", context do
    input = %{"projectId" => context.never_project, "provider" => @instance}

    {{:ok, %{"projects" => []}}, context} =
      World.call(context, "plugins.call", %{
        "id" => @id,
        "method" => "toolPrune",
        "input" => input
      })

    plugin = Module.concat(HalC2Plugins, TokenEconomizer)
    refute File.exists?(plugin.toolprune_path({context.never_project, @instance}))
    context
  end

  step "{string} is refused", %{args: [tool]} = context do
    assert [%{"refused" => [^tool]}] = context.prune_reply["projects"]
    context
  end

  step "tool pruning proposes {string} for the project", %{args: [tool]} = context do
    assert tool in project_state(context)["proposed"]
    context
  end

  step "tool pruning lists {string} as off for the project", %{args: [tool]} = context do
    assert tool in project_state(context)["off"]
    context
  end

  step "tool pruning lists {string} as kept for the project", %{args: [tool]} = context do
    assert tool in project_state(context)["kept"]
    context
  end

  step "tool pruning lists nothing as off for the project", context do
    assert project_state(context)["off"] == []
    context
  end

  # --- helpers ---------------------------------------------------------------------------

  defp miss_turn(context, item) do
    title = context.prune_thread
    thread_id = World.thread_id(context, title)
    [last | _] = context |> World.runs(title) |> Enum.reverse()
    run = "run-missed-#{System.unique_integer([:positive])}"

    {:ok, _} =
      HalC2.Streams.commit(thread_id, :thread, [
        {"run", run,
         %{
           "s" =>
             Map.merge(Map.take(last, ~w(providerThreadId providerInstanceId)), %{
               "id" => run,
               "ordinal" => last["ordinal"] + 1,
               "status" => "completed"
             })
         }},
        {"turn-item", run <> "-i1",
         %{
           "s" =>
             Map.merge(item, %{
               "id" => run <> "-i1",
               "runId" => run,
               "ordinal" => 1,
               "status" => "completed"
             })
         }}
      ])

    [{_feed, %{dropped: dropped}}] =
      for {_, %{id: @id}} = feed <- HalC2.Plugins.Feed.lookup(:observe), do: feed

    :counters.add(dropped, 1, 2)
    context
  end

  defp seed(context, fields) do
    plugin = Module.concat(HalC2Plugins, TokenEconomizer)
    path = plugin.toolprune_path({World.project(context).id, @instance})
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(Map.merge(%{"unit" => "tool"}, fields)))
  end

  # A new thread, so a new provider conversation, which shape_run/2 shapes.
  defp run_thread(context, title, text \\ "hello") do
    context = World.launch_on(context, title, @instance, text)
    World.await_runs(context, title, ["completed"])
    Map.put(context, :prune_thread, title)
  end

  # The `--disallowedTools` of the fake Claude's latest launch.
  defp denied(context) do
    argv =
      context
      |> World.provider_log("claude")
      |> Enum.flat_map(fn
        %{"argv" => argv} -> [argv]
        _ -> []
      end)
      |> List.last()

    case Enum.drop_while(argv || [], &(&1 != "--disallowedTools")) do
      [_, tools | _] -> tools
      _ -> ""
    end
  end

  defp call(context, method, input) do
    input =
      Map.merge(input, %{
        "projectId" => World.project(context).id,
        "provider" => @instance
      })

    {{:ok, result}, context} =
      World.call(context, "plugins.call", %{"id" => @id, "method" => method, "input" => input})

    Map.put(context, :prune_reply, result)
  end

  # Watches the plugin's `toolPrune` topic; `await_prune/2` waits on it.
  defp watch(context) do
    sub = System.unique_integer([:positive])

    shape = %{
      "type" => "plugin",
      "environment" => context.mc.environment,
      "id" => @id,
      "topic" => "toolPrune"
    }

    client = context |> World.client("tool-prune") |> Mc.sub(sub, shape)
    context |> World.put_client("tool-prune", client) |> Map.put(:prune_watched, sub)
  end

  defp await_prune(context, fun) do
    Mc.await(
      World.client(context, "tool-prune"),
      &(&1["t"] == "plugin" and &1["id"] == context.prune_watched and is_map(&1["value"]) and
          fun.(&1["value"])),
      15_000
    )
  end

  defp project_state(context) do
    input = %{"projectId" => World.project(context).id, "provider" => @instance}

    {{:ok, %{"projects" => [project]}}, _context} =
      World.call(context, "plugins.call", %{
        "id" => @id,
        "method" => "toolPrune",
        "input" => input
      })

    project
  end
end
