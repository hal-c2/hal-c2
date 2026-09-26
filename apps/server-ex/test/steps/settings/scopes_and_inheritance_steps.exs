defmodule HalC2.Steps.Settings.ScopesAndInheritance do
  @moduledoc """
  How a node stores its settings document (versioned `halc2.readSettings` /
  `halc2.writeSettings`, pushed to `config` subscribers) and how a project's
  overrides resolve over it (`HalC2.Settings.for_project/1`). The scenario's node
  is the first environment the Background names.
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias HalC2.Test.Node
  alias HalC2.Test.Node.World

  @environment_default %{"instanceId" => "claudeAgent", "model" => "claude-sonnet-4-6"}

  step "the user has environments {string} and {string}", %{args: [here, _other]} = context do
    Node.ensure(HalC2.Settings)

    context
    |> Map.put(:environment_label, here)
    |> World.put_client(World.client(context))
  end

  step "the project {string} has a checkout on each environment", %{args: [title]} = context do
    World.create_project(context, title)
  end

  # --- versioned writes --------------------------------------------------------------

  step "a client has read the settings at their current version", context do
    read(context, "default")
  end

  step "the client writes a changed settings document at that version", context do
    write(context, "default", "24-hour")
  end

  step "the node saves the document", context do
    assert HalC2.Settings.settings()["timestampFormat"] == "24-hour"
    context
  end

  step "the node answers with the next version", context do
    assert {:ok, %{"version" => version}} = context.reply
    assert version == context.read["default"]["version"] + 1
    assert {_, ^version} = HalC2.Settings.get()
    context
  end

  step "two clients have read the settings at the same version", context do
    context = context |> read("first") |> read("second")
    assert context.read["first"]["version"] == context.read["second"]["version"]
    context
  end

  step "the first client has saved a change", context do
    context = write(context, "first", "24-hour")
    assert {:ok, _} = context.reply
    context
  end

  step "the second client writes its change at the old version", context do
    write(context, "second", "12-hour")
  end

  step "the node refuses the write as stale settings", context do
    assert {:error, _, detail} = context.reply
    assert inspect(detail) =~ "StaleSettings"
    context
  end

  step "the first client's change is kept", context do
    assert HalC2.Settings.settings()["timestampFormat"] == "24-hour"
    context
  end

  step "a client is subscribed to this node's settings", context do
    World.put_client(context, "subscriber", Node.config(World.client(context, "subscriber")))
  end

  step "another client saves a settings change", context do
    context |> read("other") |> write("other", "24-hour")
  end

  step "the subscribed client receives the new settings document", context do
    {frame, client} =
      Node.await(
        World.client(context, "subscriber"),
        &(&1["t"] == "config.settings" and &1["settings"]["timestampFormat"] == "24-hour")
      )

    assert frame["settings"] == HalC2.Settings.settings()
    World.put_client(context, "subscriber", client)
  end

  # --- project overrides ---------------------------------------------------------------

  step "the environment's default runtime mode is full access", context do
    World.update_settings(context, %{
      "defaultRuntimeMode" => "full-access",
      "timestampFormat" => "24-hour",
      "defaultThreadEnvMode" => "local"
    })
  end

  step "the project {string} overrides the default runtime mode to approval required",
       %{args: [project]} = context do
    override(context, project, %{"defaultRuntimeMode" => "approval-required"})
  end

  step "the node resolves the settings for {string}", %{args: [project]} = context do
    Map.put(context, :resolved, HalC2.Settings.for_project(World.project(context, project).id))
  end

  step "the default runtime mode is approval required", context do
    assert context.resolved["defaultRuntimeMode"] == "approval-required"
    context
  end

  step "settings the project does not override keep the environment's values", context do
    environment = HalC2.Settings.settings()

    assert Map.delete(context.resolved, "defaultRuntimeMode") ==
             Map.delete(environment, "defaultRuntimeMode")

    assert environment["timestampFormat"] == "24-hour"
    context
  end

  # `timestampFormat` is not a `ProjectSettingsOverrides` key.
  step "the project {string} has an override for an environment-wide setting",
       %{args: [project]} = context do
    context
    |> World.update_settings(%{"timestampFormat" => "24-hour"})
    |> override(project, %{"timestampFormat" => "12-hour"})
  end

  step "that setting keeps the environment's value", context do
    assert context.resolved["timestampFormat"] == "24-hour"
    context
  end

  step "the project {string} overrides the default model with a model from {string}",
       %{args: [project, provider]} = context do
    assert provider == "Codex"

    context
    |> World.update_settings(%{"defaultModelSelection" => @environment_default})
    |> override(project, %{
      "defaultModelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"}
    })
  end

  step "the {string} provider is disabled on this environment", %{args: [provider]} = context do
    assert provider == "Codex"
    World.update_settings(context, %{"providers" => %{"codex" => %{"enabled" => false}}})
  end

  step "the default model is the environment's default model", context do
    assert context.resolved["defaultModelSelection"] == @environment_default
    context
  end

  defp read(context, client) do
    {{:ok, read}, context} = World.call(context, "halc2.readSettings", %{}, client)
    Map.update(context, :read, %{client => read}, &Map.put(&1, client, read))
  end

  defp write(context, client, format) do
    %{"settings" => settings, "version" => version} = context.read[client]
    document = Map.put(settings, "timestampFormat", format)

    {reply, context} =
      World.call(
        context,
        "halc2.writeSettings",
        %{"settings" => document, "version" => version},
        client
      )

    Map.put(context, :reply, reply)
  end

  defp override(context, project, values) do
    id = World.project(context, project).id
    World.update_settings(context, %{"projectSettingsOverrides" => %{id => values}})
  end
end
