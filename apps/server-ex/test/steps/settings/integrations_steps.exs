defmodule HalC2.Steps.Settings.Integrations do
  @moduledoc """
  The device hub half of Settings → Integrations, driven over `device.configure`
  and `device.list` on an MC whose device tools are the `HalC2.DevicesTest` fakes.
  npm is a fake on `PATH` so tool updates never reach the registry.
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  step "the user has opened the Integrations settings", context do
    context = World.fake_device_tools(context)
    World.put_client(context, "default", World.client(context))
  end

  step "the user turns on the device hub for this MC", context do
    Mc.ensure(HalC2.Devices)
    {reply, context} = World.call(context, "device.configure", %{"enabled" => true})
    Map.put(context, :reply, reply)
  end

  step "device support is stored as on", context do
    assert HalC2.Settings.settings()["enableDeviceSupport"] == true
    context
  end

  step "device support is stored as off", context do
    assert HalC2.Settings.settings()["enableDeviceSupport"] == false
    context
  end

  step "agent device access is stored as off", context do
    assert HalC2.Settings.settings()["enableAgentDeviceAccess"] == false
    context
  end

  step "the MC lists the simulators and emulators on its machine", context do
    assert {:ok, %{"hostStatus" => "ready", "devices" => devices}} = context.reply

    assert Enum.any?(devices, &match?(%{"id" => "Pixel_9", "platform" => "android"}, &1)),
           "expected the fake SDK's emulators in #{inspect(devices)}"

    context
  end

  step "the device hub and agent device access are on", context do
    context =
      World.update_settings(context, %{
        "enableDeviceSupport" => true,
        "enableAgentDeviceAccess" => true
      })

    Mc.ensure(HalC2.Devices)
    context
  end

  step "a client turns off the device hub and agent device access together", context do
    {reply, context} =
      World.call(context, "device.configure", %{"enabled" => false, "agentAccessEnabled" => false})

    assert {:ok, %{"hostStatus" => "disabled"}} = reply
    Map.put(context, :reply, reply)
  end

  step "the user checks device tool versions on this MC", context do
    Mc.ensure(HalC2.Devices)
    context = Map.put(context, :tools_before, tool_tree(context))
    {reply, context} = World.call(context, "device.list", %{"inspectOnly" => true})
    Map.put(context, :reply, reply)
  end

  step "the installed and required versions are reported", context do
    %{"hub" => hub, "agent" => agent} = local_tools(context.reply)

    assert %{"requiredVersion" => "0.10.1", "installedVersions" => ["0.10.1"]} = hub
    assert %{"requiredVersion" => "0.21.12", "installedVersions" => ["0.21.12"]} = agent
    context
  end

  step "no tool is installed and no device is started", context do
    assert tool_tree(context) == context.tools_before
    assert {:ok, %{"hostStatus" => "disabled", "sessions" => [], "devices" => []}} = context.reply
    assert %{"hub" => %{"runningVersion" => nil}} = local_tools(context.reply)
    context
  end

  step "the device hub tool is older than the required version", context do
    File.rm_rf!(Path.join([context.mc.home, "tools", "expo-device-hub", "0.10.1"]))
    World.fake_device_tools(context, hub: "0.9.0")
    fake_npm(context, :online)
  end

  step "this MC has no network access", context do
    fake_npm(context, :offline)
  end

  step "the user updates the device hub tool", context do
    Mc.ensure(HalC2.Devices)
    {reply, context} = World.call(context, "device.list", %{"updateTool" => "hub"})
    Map.put(context, :reply, reply)
  end

  step "the required version is installed", context do
    assert %{"hub" => %{"requiredVersion" => "0.10.1", "installedVersions" => versions}} =
             local_tools(context.reply)

    assert "0.10.1" in versions
    assert File.read!(npm_log(context)) =~ "install --prefix"
    context
  end

  step "the update fails with a device tool error", context do
    assert {:error, _, detail} = context.reply
    assert %{"_tag" => "DeviceOperationError", "operation" => "update device tool"} = detail
    assert inspect(detail) =~ "ENOTFOUND"
    context
  end

  defp local_tools({:ok, %{"hosts" => hosts}}),
    do: Enum.find(hosts, &(&1["id"] == "local"))["tools"]

  defp local_tools(reply), do: flunk("expected a device state, got #{inspect(reply)}")

  defp tool_tree(context) do
    root = Path.join(context.mc.home, "tools")
    Path.wildcard(Path.join(root, "**"), match_dot: true) |> Enum.sort()
  end

  defp npm_log(context), do: Path.join(context.mc.home, "npm.log")

  # An `npm` first on PATH: online it stages the fake hub where `npm install --prefix`
  # would, offline it fails the way npm does without DNS.
  defp fake_npm(context, mode) do
    bin = Mc.tmp_dir(context.mc, "bin")
    hub = Path.expand("../../support/fake_device_hub.mjs", __DIR__)

    body =
      case mode do
        :online ->
          """
          prefix="$3"; package="${6%@*}"
          mkdir -p "$prefix/node_modules/$package/dist/server"
          cp '#{hub}' "$prefix/node_modules/$package/dist/server/cli.mjs"
          """

        :offline ->
          """
          echo "npm ERR! code ENOTFOUND" >&2
          echo "npm ERR! network request to https://registry.npmjs.org/${6%@*} failed" >&2
          exit 1
          """
      end

    path = Path.join(bin, "npm")
    File.write!(path, "#!/bin/sh\necho \"$@\" >> '#{npm_log(context)}'\n" <> body)
    File.chmod!(path, 0o755)
    World.put_env("PATH", bin <> ":" <> System.get_env("PATH", ""))
    context
  end
end
