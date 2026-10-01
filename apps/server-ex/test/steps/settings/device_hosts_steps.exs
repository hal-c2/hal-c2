defmodule HalC2.Steps.Settings.DeviceHosts do
  @moduledoc """
  SSH device hosts on an MC: `device.testHost` and `device.list` report them
  unavailable with the reason to add that machine as a cluster MC instead.
  Hosts are `%{"id", "label", "target"}` configs kept under `context.device_hosts`.
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  step "the user has opened the Integrations settings for the environment {string}",
       %{args: [_environment]} = context do
    context = World.fake_device_tools(context)
    Mc.ensure(HalC2.Devices)

    context
    |> World.put_client("default", World.client(context))
    |> Map.put(:device_hosts, %{})
  end

  step "a device host {string} with the SSH target {string}",
       %{args: [label, target]} = context do
    put_host(context, label, target)
  end

  step "the settings list a device host {string}", %{args: [label]} = context do
    context = put_host(context, label, World.slug(label))
    World.update_settings(context, %{"deviceHosts" => Map.values(context.device_hosts)})
  end

  step "{string} is listed as unavailable", %{args: [label]} = context do
    context = put_host(context, label, World.slug(label))
    context = World.update_settings(context, %{"deviceHosts" => Map.values(context.device_hosts)})
    {reply, context} = World.call(context, "device.list", %{})
    assert_unavailable(reply, context.device_hosts[label])
    context
  end

  step "the MC tests the connection to {string}", %{args: [label]} = context do
    {reply, context} = World.call(context, "device.testHost", context.device_hosts[label])
    Map.put(context, :reply, reply)
  end

  step "{string} is reported unavailable", %{args: [label]} = context do
    id = context.device_hosts[label]["id"]
    assert {:error, _, %{"_tag" => "DeviceHostUnavailableError", "hostId" => ^id}} = context.reply
    context
  end

  step "the reason says to run HAL-C2 on {string} and add it to this cluster as an MC",
       %{args: [target]} = context do
    {:error, _, %{"reason" => reason}} = context.reply
    assert reason =~ "Run HAL-C2 on #{target} and add it to this cluster as an MC"
    context
  end

  step "the MC lists devices", context do
    {reply, context} = World.call(context, "device.list", %{})
    Map.put(context, :reply, reply)
  end

  step "{string} is listed as unavailable with the same reason", %{args: [label]} = context do
    config = context.device_hosts[label]

    {{:error, _, %{"reason" => reason}}, context} =
      World.call(context, "device.testHost", config)

    assert_unavailable(context.reply, config, reason)
    context
  end

  step "the user retries {string}", %{args: [label]} = context do
    id = context.device_hosts[label]["id"]
    {reply, context} = World.call(context, "device.list", %{"retryHostId" => id})
    Map.put(context, :reply, reply)
  end

  step "{string} is still unavailable", %{args: [label]} = context do
    assert_unavailable(context.reply, context.device_hosts[label])
    context
  end

  defp put_host(context, label, target) do
    host = %{"id" => World.slug(label), "label" => label, "target" => target}
    put_in(context, [:device_hosts, label], host)
  end

  # Every platform of the host is unavailable, for `reason` when given.
  defp assert_unavailable(reply, config, reason \\ nil) do
    assert {:ok, %{"hosts" => hosts}} = reply
    host = Enum.find(hosts, &(&1["id"] == config["id"]))
    assert %{"kind" => "ssh", "platforms" => [_ | _] = platforms} = host

    for platform <- platforms do
      assert %{"available" => false, "reason" => said} = platform
      assert said =~ "Run HAL-C2 on #{config["target"]}"
      if reason, do: assert(said == reason)
    end
  end
end
