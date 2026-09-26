defmodule T3.Steps.Settings.ProjectDefaults do
  @moduledoc """
  Project default rows: an environment value, a project's override, and what
  `T3.Settings.for_project/1` resolves (the resolving step lives in
  `scopes_and_inheritance_steps.exs`).
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias T3.Test.Node.World

  @models %{"Sonnet" => %{"instanceId" => "claudeAgent", "model" => "claude-sonnet-4-6"}}

  step "{string} uses the default workspace {string}", %{args: [environment, mode]} = context do
    assert context.environment_label == environment
    World.update_settings(context, %{"defaultThreadEnvMode" => mode})
  end

  step "{string} overrides the default workspace to {string}",
       %{args: [project, mode]} = context do
    override(context, project, %{"defaultThreadEnvMode" => mode})
  end

  step "the default workspace is {string}", %{args: [mode]} = context do
    assert context.resolved["defaultThreadEnvMode"] == mode
    context
  end

  step "{string} uses the default model {string}", %{args: [environment, name]} = context do
    assert context.environment_label == environment
    World.update_settings(context, %{"defaultModelSelection" => Map.fetch!(@models, name)})
  end

  step "{string} overrides the default model with a model from a disabled provider",
       %{args: [project]} = context do
    context
    |> World.update_settings(%{"providers" => %{"codex" => %{"enabled" => false}}})
    |> override(project, %{
      "defaultModelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"}
    })
  end

  step "the default model is {string}", %{args: [name]} = context do
    assert context.resolved["defaultModelSelection"] == Map.fetch!(@models, name)
    context
  end

  defp override(context, project, values) do
    id = World.project(context, project).id
    World.update_settings(context, %{"projectSettingsOverrides" => %{id => values}})
  end
end
