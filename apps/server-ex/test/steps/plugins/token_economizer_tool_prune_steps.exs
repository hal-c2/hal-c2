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
      "pending" => %{"items" => [tool], "since" => 0},
      "lastActivity" => 0
    })

    context
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

  step "another Claude thread in the project runs a turn", context do
    run_thread(context, "Second")
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

  defp seed(context, fields) do
    plugin = Module.concat(HalC2Plugins, TokenEconomizer)
    path = plugin.toolprune_path({World.project(context).id, @instance})
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(Map.merge(%{"unit" => "tool"}, fields)))
  end

  # A new thread, so a new provider conversation, which shape_run/2 shapes.
  defp run_thread(context, title) do
    context = World.launch_on(context, title, @instance, "hello")
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
