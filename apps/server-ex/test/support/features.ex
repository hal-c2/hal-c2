defmodule HalC2.Test.Features do
  @moduledoc """
  Runs the repo's Gherkin specification (`features/`) against this node.

  Only scenarios tagged `@node` and not `@dropped` become tests; the rest belong
  to other surfaces. Step definitions live in `test/steps/`, one file per feature
  directory, on the harness in `HalC2.Test.Node`. `mix features` runs them, or
  `HALC2_FEATURES=<globs> mix test --only cucumber`; globs are relative to `features/`.
  """

  @root Path.expand("../../../../features", __DIR__)

  @doc "The feature directory the specification lives in."
  def root, do: @root

  @doc "Compiles the selected `@node` scenarios into ExUnit modules."
  def compile!(globs) do
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
      |> Enum.map(&select_node_scenarios/1)
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

  defp select_node_scenarios(feature) do
    rules =
      feature.rules
      |> Enum.map(fn rule ->
        %{rule | scenarios: Enum.filter(rule.scenarios, &node?(&1, feature.tags ++ rule.tags))}
      end)
      |> Enum.reject(&(&1.scenarios == []))

    %{
      feature
      | scenarios: Enum.filter(feature.scenarios, &node?(&1, feature.tags)),
        rules: rules
    }
  end

  # Example tables carry tags too; an outline runs when any of its tables is a
  # node table. (No feature uses per-table surface tags today.)
  defp node?(scenario, inherited) do
    tags =
      inherited ++
        scenario.tags ++
        Enum.flat_map(Map.get(scenario, :examples) || [], & &1.tags)

    "node" in tags and "dropped" not in tags
  end
end
