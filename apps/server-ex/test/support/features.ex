defmodule HalC2.Test.Features do
  @moduledoc """
  Runs the repo's Gherkin specification (`features/`) against this MC.

  Only scenarios tagged `@mc` and not `@dropped` become tests; the rest belong
  to other surfaces. `@backlog` and `@backlog-mc` scenarios (and example tables)
  are left out unless `backlog: true` (`mix features --backlog`), since they name
  behaviour the MC does not have yet. Step definitions live in `test/steps/`, one file per feature
  directory, on the harness in `HalC2.Test.Mc`. `mix features` runs them, or
  `HAL_C2_FEATURES=<globs> mix test --only cucumber`; globs are relative to `features/`.
  """

  @root Path.expand("../../../../features", __DIR__)

  @doc "The feature directory the specification lives in."
  def root, do: @root

  @doc "Compiles the selected `@mc` scenarios into ExUnit modules."
  def compile!(globs, opts \\ []) do
    backlog? = Keyword.get(opts, :backlog, false)
    patterns = Enum.map(globs, &Path.join(@root, &1))

    %Cucumber.Discovery.DiscoveryResult{
      features: features,
      step_registry: step_registry,
      hook_modules: hook_modules,
      parameter_types: parameter_types
    } =
      Cucumber.Discovery.discover(
        features: patterns,
        steps: ["test/steps/**/*_steps.exs"],
        support: ["test/steps/support/**/*.exs"]
      )

    features =
      features
      |> Enum.map(&select_mc_scenarios(&1, backlog?))
      |> Enum.reject(&(&1.scenarios == [] and &1.rules == []))
      # Module names come from the file path: `Features.Threads.SettleTest`.
      |> Enum.map(&%{&1 | file: Path.relative_to(&1.file, Path.dirname(@root))})

    Cucumber.RunCoordinator.ensure_started()

    Cucumber.Compiler.compile_all!(
      features,
      step_registry,
      hook_modules,
      parameter_types,
      Application.get_env(:cucumber, :messages)
    )
  end

  defp select_mc_scenarios(feature, backlog?) do
    select = fn scenarios, inherited ->
      scenarios
      |> Enum.filter(&mc?(&1, inherited))
      |> Enum.flat_map(&without_backlog(&1, inherited, backlog?))
    end

    rules =
      feature.rules
      |> Enum.map(&%{&1 | scenarios: select.(&1.scenarios, feature.tags ++ &1.tags)})
      |> Enum.reject(&(&1.scenarios == []))

    %{feature | scenarios: select.(feature.scenarios, feature.tags), rules: rules}
  end

  defp without_backlog(scenario, _inherited, true), do: [scenario]

  defp without_backlog(scenario, inherited, false) do
    cond do
      backlog?(inherited) or backlog?(scenario.tags) ->
        []

      examples = Map.get(scenario, :examples) ->
        case Enum.reject(examples, &backlog?(&1.tags)) do
          [] when examples != [] -> []
          kept -> [%{scenario | examples: kept}]
        end

      true ->
        [scenario]
    end
  end

  defp backlog?(tags), do: "backlog" in tags or "backlog-mc" in tags

  # Example tables carry tags too; an outline runs when any of its tables is a
  # MC table. (No feature uses per-table surface tags today.)
  defp mc?(scenario, inherited) do
    tags =
      inherited ++
        scenario.tags ++
        Enum.flat_map(Map.get(scenario, :examples) || [], & &1.tags)

    "mc" in tags and "dropped" not in tags
  end
end
