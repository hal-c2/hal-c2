defmodule HalC2.Steps.Plugins.HostApi do
  @moduledoc """
  The grants and refusals every part of the host API shares
  (`features/plugins/host-*.feature`), on the `host-probe` plugin of
  `HalC2.Steps.Support.PluginHost`.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.Plugins.Fixtures
  alias HalC2.Steps.Support.PluginHost

  step "a plugin granted {string}", %{args: [permission]} = context do
    PluginHost.granted(context, [permission])
  end

  step "a plugin granted {string} and {string}", %{args: permissions} = context do
    PluginHost.granted(context, permissions)
  end

  step "a plugin granted only {string}", %{args: [permission]} = context do
    PluginHost.granted(context, [permission])
  end

  step "the MC refuses the call naming {string}", %{args: [permission]} = context do
    assert {:error, message, %{"_tag" => "PluginCallFailed"}} = context.reply
    assert message =~ permission
    Map.put(context, :refused, permission)
  end

  step "the refusal is recorded on the plugin", context do
    assert context.refused in Fixtures.entry(context.plugin)["denied"]
    context
  end
end
