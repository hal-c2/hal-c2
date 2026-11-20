defmodule HalC2.Steps.Plugins.PluginProviders do
  @moduledoc """
  Steps for `features/plugins/plugin-providers.feature`: the `host-probe` plugin
  (`HalC2.Steps.Support.PluginHost`) calls `Host.provider_instances/3`, and the user
  changes settings as a client does (`hal-c2.readSettings` and `hal-c2.writeSettings`).
  Turning the plugin off, removing it and a rescan answer once the host has taken its
  instances out, so the checks read the settings document straight after.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.Plugins.Fixtures
  alias HalC2.Steps.Support.PluginHost
  alias HalC2.Test.Mc.World

  @probe "host-probe"
  @users %{"driver" => "claudeAgent", "displayName" => "Claude at work", "enabled" => true}

  step "an MC with the user's own provider instance {string}", %{args: [id]} = context do
    context
    |> Fixtures.ensure()
    |> write(&put_in(&1, [Access.key("providerInstances", %{}), id], @users))
  end

  # --- what the plugin does --------------------------------------------------------------

  step "it puts the instance {string} for Claude named {string}",
       %{args: [name, label]} = context do
    put(context, name, %{"driver" => "claudeAgent", "displayName" => label})
  end

  step "it put the instance {string} for Claude named {string}",
       %{args: [name, label]} = context do
    put!(context, name, %{"driver" => "claudeAgent", "displayName" => label})
  end

  step "it put the instance {string} for Claude with the base URL {string}",
       %{args: [name, url]} = context do
    put!(context, name, claude(url))
  end

  step "it puts the instance {string} for Claude with the base URL {string}",
       %{args: [name, url]} = context do
    put!(context, name, claude(url))
  end

  step "it puts the instance {string} for Claude with the sensitive variable {string} set to {string}",
       %{args: [name, variable, value]} = context do
    put!(context, name, %{
      "driver" => "claudeAgent",
      "environment" => [%{"name" => variable, "value" => value, "sensitive" => true}]
    })
  end

  step "it removes the instance {string}", %{args: [name]} = context do
    PluginHost.call(context, "provider_instances", "remove", %{"name" => name})
  end

  step "it lists its instances", context do
    PluginHost.call(context, "provider_instances", "list", %{})
  end

  # --- what the user does ----------------------------------------------------------------

  step("the user turns the plugin off", context, do: disable(context))
  step("the user turned the plugin off", context, do: disable(context))

  step "the user turns the plugin on again", context do
    {_, context} =
      World.call!(context, "plugins.enable", %{
        "id" => @probe,
        "acceptPermissions" => ["providers:configure"]
      })

    assert %{"status" => "running"} = Fixtures.entry(@probe)
    context
  end

  step "the plugin is removed from the MC", context do
    File.rm_rf!(Path.join([context.mc.home, "plugins", @probe]))
    Fixtures.rescan(context)
  end

  step "an update of the plugin no longer asks for {string}", %{args: [_permission]} = context do
    file = Path.join([context.mc.home, "plugins", @probe, "plugin.json"])
    manifest = file |> File.read!() |> JSON.decode!()

    manifest = %{
      manifest
      | "version" => "1.1.0",
        "permissions" => [%{"id" => "threads:read", "reason" => "The scenario."}]
    }

    File.write!(file, JSON.encode!(manifest))
    Fixtures.rescan(context)
  end

  step "the user deletes the instance {string} in Settings → Providers",
       %{args: [id]} = context do
    delete(context, id)
  end

  step "the user deleted the instance {string} in Settings → Providers",
       %{args: [id]} = context do
    delete(context, id)
  end

  step "the user added an instance of their own as {string}", %{args: [id]} = context do
    add(context, id)
  end

  step "the user adds an instance of their own as {string}", %{args: [id]} = context do
    add(context, id)
  end

  # A client that keeps the document it read and saves twice, both before the host has
  # taken in either save: its second save still carries the host's record as read.
  step "the user deletes {string} and adds one of their own under that id, saving twice at once",
       %{args: [id]} = context do
    {%{"settings" => read, "version" => version}, context} =
      World.call!(context, "hal-c2.readSettings", %{})

    deleted = Map.update!(read, "providerInstances", &Map.delete(&1, id))

    {%{"version" => version}, context} =
      World.call!(context, "hal-c2.writeSettings", %{"settings" => deleted, "version" => version})

    {_, context} =
      World.call!(context, "hal-c2.writeSettings", %{
        "settings" => put_in(read, ["providerInstances", id], @users),
        "version" => version
      })

    {_, context} = World.call!(context, "plugins.list", %{})
    context
  end

  # --- checks ----------------------------------------------------------------------------

  step "Settings → Providers has the instance {string} named {string}",
       %{args: [id, label]} = context do
    assert %{"driver" => "claudeAgent", "displayName" => ^label} = instance(id)
    context
  end

  step "Settings → Providers has no instance {string}", %{args: [id]} = context do
    refute instance(id)
    context
  end

  step "the plugin lists only the instance {string}", %{args: [name]} = context do
    assert [%{"name" => ^name}] = listed(context)
    context
  end

  step "the plugin lists no instances", context do
    assert listed(context) == []
    context
  end

  step "{string} is not among them", %{args: [id]} = context do
    assert {:ok, %{"instances" => instances}} = context.reply
    refute Enum.any?(instances, &(&1["instanceId"] == id))
    context
  end

  step "the user's instance {string} is as it was", %{args: [id]} = context do
    assert instance(id) == @users
    context
  end

  step "the instance {string} runs Claude with the base URL {string}",
       %{args: [id, url]} = context do
    assert HalC2.Settings.instance_env(id)["ANTHROPIC_BASE_URL"] == url
    context
  end

  step "the settings document holds {string} of {string} redacted",
       %{args: [variable, id]} = context do
    assert %{"environment" => [%{"name" => ^variable, "value" => "", "valueRedacted" => true}]} =
             instance(id)

    context
  end

  step "the agent of {string} is given {string} as {string}",
       %{args: [id, variable, value]} = context do
    assert HalC2.Settings.instance_env(id)[variable] == value
    context
  end

  step "the MC refuses the call saying it {string}", %{args: [text]} = context do
    assert PluginHost.refusal(context) =~ text
    context
  end

  step("the plugin {string} added the instance {string}", context, do: context)
  step("the user opens Settings → Providers", context, do: context)
  step("{string} is marked as added by the plugin {string}", context, do: context)
  step("the user can still rename, switch off or delete it", context, do: context)

  # --- helpers ---------------------------------------------------------------------------

  defp put(context, name, instance) do
    PluginHost.call(context, "provider_instances", "put", %{
      "name" => name,
      "instance" => instance
    })
  end

  defp put!(context, name, instance) do
    {_, context} =
      PluginHost.call!(context, "provider_instances", "put", %{
        "name" => name,
        "instance" => instance
      })

    context
  end

  defp claude(url) do
    %{
      "driver" => "claudeAgent",
      "environment" => [%{"name" => "ANTHROPIC_BASE_URL", "value" => url, "sensitive" => false}]
    }
  end

  defp listed(context) do
    {%{"instances" => instances}, _} =
      PluginHost.call!(context, "provider_instances", "list", %{})

    instances
  end

  defp disable(context) do
    {_, context} = World.call!(context, "plugins.disable", %{"id" => @probe})
    context
  end

  defp instance(id), do: (HalC2.Settings.settings()["providerInstances"] || %{})[id]

  defp delete(context, id),
    do: write(context, &Map.update!(&1, "providerInstances", fn all -> Map.delete(all, id) end))

  defp add(context, id),
    do: write(context, &put_in(&1, [Access.key("providerInstances", %{}), id], @users))

  # As a client saves settings: the document it read, changed, with that version. The
  # host hears of the save before the client is answered, so the call after it answers
  # once the host has taken in the change.
  defp write(context, fun) do
    {%{"settings" => settings, "version" => version}, context} =
      World.call!(context, "hal-c2.readSettings", %{})

    {_, context} =
      World.call!(context, "hal-c2.writeSettings", %{
        "settings" => fun.(settings),
        "version" => version
      })

    {_, context} = World.call!(context, "plugins.list", %{})
    context
  end
end
