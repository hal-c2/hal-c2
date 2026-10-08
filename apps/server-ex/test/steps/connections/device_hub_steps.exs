defmodule HalC2.Steps.Connections.DeviceHub do
  @moduledoc """
  Steps for `features/connections/device-hub.feature`.

  The MC's device tools are real processes run against fakes: `npm` installs
  the fake hub and agent-device from `test/support` on first use, the Android SDK
  is a directory of fake `adb` and `emulator` scripts under `ANDROID_HOME`, and a
  Mac is `config :hal_c2, :os_type` plus a fake `xcrun` on PATH. The fakes log every
  host command to `calls.log`, so a step can see what ran and in what order.
  `HalC2.Devices` starts on the first step that uses it, after the Given steps have
  shaped the machine.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @support Path.expand("../../support", __DIR__)
  @simulator %{
    "id" => "SIM-1",
    "name" => "iPhone 16",
    "version" => "iOS 18.0",
    "platform" => "ios",
    "physical" => false
  }
  @agent_thread "agent-thread"

  # --- the machine --------------------------------------------------------------------

  step "an MC with device support enabled", context do
    context |> machine() |> write_settings(%{"enableDeviceSupport" => true})
  end

  step "an MC with device support disabled", context do
    write_settings(context, %{"enableDeviceSupport" => false})
  end

  step "the MC runs on Linux", context do
    Application.put_env(:hal_c2, :os_type, {:unix, :linux})
    context
  end

  step "a Mac without Xcode command line tools", context do
    Application.put_env(:hal_c2, :os_type, {:unix, :darwin})
    assert System.find_executable("xcrun") == nil, "this machine has xcrun on PATH"
    context
  end

  step "no Android SDK is installed", context do
    System.delete_env("ANDROID_HOME")
    System.delete_env("ANDROID_SDK_ROOT")
    assert HalC2.Devices.platform_reason("android") =~ "Android SDK was not found"
    context
  end

  step "the SDK lacks platform tools", context do
    File.rm_rf!(Path.join(context.devices.sdk, "platform-tools"))
    context
  end

  step "the SDK lacks the emulator", context do
    File.rm_rf!(Path.join(context.devices.sdk, "emulator"))
    context
  end

  step "a shut-down simulator", context do
    mac(context, [Map.put(@simulator, "booted", false)])
  end

  # --- listing ------------------------------------------------------------------------

  step "a client lists devices", context do
    rpc(context, "device.list", %{})
  end

  step "a client lists devices for the first time", context do
    refute File.exists?(Path.join(context.mc.home, "tools"))
    rpc(context, "device.list", %{})
  end

  step "the MC installs and starts no device tools", context do
    assert {:ok, %{"hostStatus" => "disabled", "devices" => []}} = context.reply
    refute File.exists?(Path.join(context.mc.home, "tools"))
    assert HalC2.Devices.hub_origin() == nil
    refute File.exists?(context.devices.log)
    context
  end

  step "the MC installs the device hub under its home's tools folder", context do
    assert {:ok, %{"hostStatus" => "ready", "hosts" => [local | _]}} = context.reply

    assert %{"hubInstalled" => true, "tools" => %{"hub" => %{"installedVersions" => [version]}}} =
             local

    dir = Path.join([context.mc.home, "tools", "expo-device-hub", version])
    assert File.read!(Path.join(dir, ".install-complete")) == version <> "\n"

    assert File.exists?(
             Path.join([dir, "node_modules", "expo-device-hub", "dist", "server", "cli.mjs"])
           )

    context
  end

  step "runs it on a loopback port", context do
    assert "http://127.0.0.1:" <> port = HalC2.Devices.hub_origin()
    assert {:ok, 200, "ok"} = hub_get("/readyz")
    assert String.to_integer(port) != context.mc.port
    context
  end

  step ~r/^(?<platform>iOS|Android) devices are unavailable because "(?<reason>[^"]+)"$/,
       %{args: [platform, reason]} = context do
    assert {:ok, %{"hosts" => hosts}} = context.reply
    %{"platforms" => platforms} = Enum.find(hosts, &(&1["id"] == "local"))
    id = String.downcase(platform)

    assert %{"available" => false, "reason" => actual} =
             Enum.find(platforms, &(&1["platform"] == id))

    assert String.starts_with?(actual, reason), "#{platform}: #{actual}"
    context
  end

  # --- opening and closing ------------------------------------------------------------

  step "a client opens it in a thread", context do
    rpc(context, "device.open", %{"threadId" => "t1", "deviceId" => "SIM-1", "platform" => "ios"})
  end

  step "the MC boots the simulator", context do
    assert {:ok, %{"deviceId" => "SIM-1", "threadId" => "t1"}} = context.reply
    assert %{"booted" => true} = hub_simulator("SIM-1")
    assert %{"booted" => true} = device("SIM-1")
    context
  end

  step "the thread lists the device as open for the Device panel and for agents", context do
    {:ok, panel} = rpc(context, "device.list", %{}).reply
    assert [%{"threadId" => "t1", "deviceId" => "SIM-1", "platform" => "ios"}] = panel["sessions"]

    context = write_settings(context, %{"enableAgentDeviceAccess" => true})
    {result, context} = tool(context, "device_list", %{}, "t1")

    assert %{"structuredContent" => %{"open" => [%{"deviceId" => "SIM-1", "hostId" => "local"}]}} =
             result

    context
  end

  step "a client opens a shut-down simulator in a thread without booting", context do
    context
    |> mac([Map.put(@simulator, "booted", false)])
    |> rpc("device.open", %{
      "threadId" => "t1",
      "deviceId" => "SIM-1",
      "platform" => "ios",
      "boot" => false
    })
  end

  step "the device is recorded as open", context do
    assert {:ok, %{"deviceId" => "SIM-1"}} = context.reply
    assert [%{"threadId" => "t1", "deviceId" => "SIM-1"}] = HalC2.Devices.state()["sessions"]
    context
  end

  step "stays shut down", context do
    assert %{"booted" => false} = hub_simulator("SIM-1")
    refute calls(context) =~ "simctl"
    context
  end

  step "a client opens a device id the hub does not list", context do
    rpc(context, "device.open", %{
      "threadId" => "t1",
      "deviceId" => "nope",
      "platform" => "android"
    })
  end

  step "the MC answers that the device was not found", context do
    assert {:error, message, %{"_tag" => "DeviceNotFoundError", "deviceId" => "nope"}} =
             context.reply

    assert message =~ "Device nope was not found"
    assert HalC2.Devices.state()["sessions"] == []
    context
  end

  step "a thread with an open simulator", context do
    context
    |> mac([Map.put(@simulator, "booted", false)])
    |> open("t1", "SIM-1", "ios")
  end

  step "a thread with two open devices", context do
    second = %{@simulator | "id" => "SIM-2", "name" => "iPad Air"}

    context
    |> mac([Map.put(@simulator, "booted", true), Map.put(second, "booted", true)])
    |> open("t1", "SIM-1", "ios")
    |> open("t1", "SIM-2", "ios")
  end

  step "a simulator open in two threads", context do
    context
    |> mac([Map.put(@simulator, "booted", true)])
    |> open("t1", "SIM-1", "ios")
    |> open("t2", "SIM-1", "ios")
  end

  step "a client closes that device in the thread", context do
    rpc(context, "device.close", %{"threadId" => "t1", "deviceId" => "SIM-1"})
  end

  step "a client closes all devices in the thread", context do
    assert length(sessions("t1")) == 2
    rpc(context, "device.close", %{"threadId" => "t1"})
  end

  step "a client closes it and asks to power it off", context do
    rpc(context, "device.close", %{"threadId" => "t1", "deviceId" => "SIM-1", "shutdown" => true})
  end

  step "a client shuts the simulator down", context do
    rpc(context, "device.shutdown", %{"deviceId" => "SIM-1", "platform" => "ios"})
  end

  step "the thread no longer lists it", context do
    assert {:ok, nil} = context.reply
    assert sessions("t1") == []
    context
  end

  step "the thread lists no devices", context do
    assert {:ok, nil} = context.reply
    assert sessions("t1") == []
    context
  end

  step "the simulator keeps running", context do
    assert %{"booted" => true} = hub_simulator("SIM-1")
    refute calls(context) =~ "shutdown"
    context
  end

  step "the simulator shuts down", context do
    assert {:ok, nil} = context.reply
    assert %{"booted" => false} = hub_simulator("SIM-1")
    assert %{"booted" => false} = device("SIM-1")
    assert sessions("t1") == []
    context
  end

  step "neither thread lists it", context do
    assert {:ok, nil} = context.reply
    assert sessions("t1") == [] and sessions("t2") == []
    assert %{"booted" => false} = hub_simulator("SIM-1")
    context
  end

  # --- watching -------------------------------------------------------------------------

  step "a client subscribed to devices", context do
    devices()
    client = Mc.connect(context.mc)
    client = Mc.sub(client, 1, %{"type" => "devices", "mc" => Atom.to_string(node())})
    {%{"state" => %{"sessions" => []}}, client} = Mc.await(client, &(&1["t"] == "devices"))
    World.put_client(context, "watcher", client)
  end

  step "another client opens a device", context do
    rpc(context, "device.open", %{
      "threadId" => "t1",
      "deviceId" => "Pixel_9",
      "platform" => "android"
    })
  end

  step "the subscribed client receives the new device state", context do
    assert {:ok, %{"deviceId" => "emulator-5554"}} = context.reply

    {%{"state" => state}, client} =
      Mc.await(
        World.client(context, "watcher"),
        &(&1["t"] == "devices" and &1["state"]["sessions"] != []),
        5_000
      )

    assert [%{"threadId" => "t1", "deviceId" => "emulator-5554"}] = state["sessions"]
    assert Enum.any?(state["devices"], &match?(%{"id" => "emulator-5554", "booted" => true}, &1))
    World.put_client(context, "watcher", client)
  end

  # --- detail and actions -----------------------------------------------------------------

  step "a client asks for a booted device's detail", context do
    context
    |> booted("Android")
    |> rpc("device.detail", %{"deviceId" => "emulator-5580"})
  end

  step "the MC answers with its settings and foreground app", context do
    assert {:ok, detail} = context.reply

    assert %{
             "deviceId" => "emulator-5580",
             "settings" => %{
               "appearance" => "light",
               "textSize" => "large",
               "networkEnabled" => true
             },
             "foregroundApp" => %{"id" => "com.android.launcher"},
             "readAt" => _
           } = detail

    context
  end

  step ~r/^a client runs "(?<action>\w+)" on a booted (?<platform>iOS|Android) device$/,
       %{args: [action, platform]} = context do
    context = booted(context, platform)
    id = if platform == "iOS", do: "SIM-1", else: "emulator-5580"

    input =
      Map.merge(
        %{"deviceId" => id, "type" => action},
        case action do
          "setAppearance" -> %{"value" => "dark"}
          "openUrl" -> %{"url" => "https://example.com/welcome"}
          "sendPush" -> %{"appId" => "com.example.app", "payload" => "Hello"}
          "setOrientation" -> %{"value" => "landscape_left"}
          "launchApp" -> %{"appId" => "com.example.app"}
          "setLiquidGlass" -> %{"value" => "clear"}
        end
      )

    context
    |> Map.merge(%{action: input, platform: String.downcase(platform)})
    |> rpc("device.action", input)
  end

  step "the MC answers with the device's detail after the action", context do
    assert {:ok, %{"deviceId" => id, "settings" => settings} = detail} = context.reply
    assert id == context.action["deviceId"]
    calls = context |> calls() |> String.split("\n", trim: true)

    {command, read, fresh} =
      case context.action do
        %{"type" => "setAppearance"} ->
          {"xcrun simctl ui SIM-1 appearance dark", "xcrun simctl ui SIM-1 appearance",
           settings["appearance"] == "dark"}

        %{"type" => "openUrl"} ->
          {"xcrun simctl openurl SIM-1 https://example.com/welcome",
           "xcrun simctl ui SIM-1 appearance", true}

        %{"type" => "sendPush"} ->
          {"xcrun simctl push SIM-1 com.example.app -", "xcrun simctl ui SIM-1 appearance",
           File.read!(Path.join(context.devices.bin, "push.json")) ==
             ~s({"aps":{"alert":"Hello"}})}

        %{"type" => "setOrientation"} ->
          {"adb emu sensor set acceleration 9.81:0:0", "adb shell cmd uimode night", true}

        %{"type" => "launchApp"} ->
          {"adb shell monkey -p com.example.app -c android.intent.category.LAUNCHER 1",
           "adb shell dumpsys window", detail["foregroundApp"] == %{"id" => "com.example.app"}}
      end

    ran = Enum.find_index(calls, &(&1 == command))
    assert ran, "#{command} never ran: #{inspect(calls)}"
    assert Enum.any?(Enum.drop(calls, ran + 1), &(&1 == read)), "no read after #{command}"
    assert fresh, "the detail does not reflect #{inspect(context.action)}: #{inspect(detail)}"
    context
  end

  step "the MC answers that the action is unavailable on that platform", context do
    platform = context.platform

    assert {:error, _,
            %{
              "_tag" => "DeviceActionUnavailableError",
              "platform" => ^platform,
              "reason" => "unsupported"
            }} = context.reply

    # Refused before any host command ran.
    assert calls(context) == ""
    context
  end

  # --- the proxy ------------------------------------------------------------------------

  step "a client with read access opens a device's stream through the MC", context do
    ticket = ticket(["orchestration:read"])
    devices()
    {:ok, _} = HalC2.Devices.list(%{})

    response =
      http(
        context,
        "GET",
        base() <> "/vendor/serve-sim/helper/SIM-1/stream.mjpeg?wsTicket=#{ticket}",
        until: &(frames(&1) >= 3)
      )

    Map.put(context, :response, response)
  end

  step "the stream is relayed from the hub for as long as the client reads it", context do
    assert %{status: 200, headers: headers, closed: true} = context.response
    assert {"content-type", "multipart/x-mixed-replace; boundary=frame"} in headers
    assert {"cache-control", "no-store, no-transform"} in headers
    assert frames(context.response) >= 3
    # The client hung up; the hub's end of the stream closes with it.
    assert {:ok, 200, "closed"} = hub_get("/fake/streams-closed")
    context
  end

  step "a session without the operate scope", context do
    Map.put(context, :ticket, ticket(["orchestration:read"]))
  end

  step "it sends a control request through the device proxy", context do
    response =
      http(
        context,
        "POST",
        base() <> "/vendor/serve-emu/api/stream-mode?wsTicket=#{context.ticket}",
        body: ~s({"mode":"mjpeg"}),
        headers: [{"content-type", "application/json"}]
      )

    Map.put(context, :response, response)
  end

  step "the MC refuses it as needing the operate scope", context do
    assert %{status: 403, body: body} = context.response

    assert %{
             "_tag" => "EnvironmentScopeRequiredError",
             "code" => "insufficient_scope",
             "requiredScope" => "orchestration:operate"
           } = JSON.decode!(body)

    context
  end

  step "a request reaches the device proxy with an invalid credential", context do
    devices()
    response = http(context, "GET", base() <> "/api/devices?wsTicket=not-a-ticket")
    Map.put(context, :response, response)
  end

  step "the MC answers that the credential is invalid", context do
    assert %{status: 401, body: body} = context.response

    assert %{"_tag" => "EnvironmentAuthInvalidError", "reason" => "invalid_credential"} =
             JSON.decode!(body)

    context
  end

  step "a client asks the device proxy for the hub's shell route", context do
    devices()
    response = http(context, "GET", base() <> "/vendor/serve-sim/exec?token=#{HalC2.Web.token()}")
    Map.put(context, :response, response)
  end

  step "a client posts to a read-only device route", context do
    devices()

    response =
      http(context, "POST", base() <> "/api/devices?token=#{HalC2.Web.token()}", body: "{}")

    Map.put(context, :response, response)
  end

  step "the MC answers the method is not allowed", context do
    assert %{status: 405} = context.response
    context
  end

  step "a client that cannot set headers on an image stream", context do
    devices()
    {:ok, _} = HalC2.Devices.list(%{})
    {:ok, ticket, _} = HalC2.Auth.issue_ticket(context.access_token)
    Map.put(context, :ticket, ticket)
  end

  step "it opens the stream with a WebSocket ticket in the query", context do
    path = base() <> "/vendor/serve-sim/helper/SIM-1/stream.mjpeg?wsTicket=#{context.ticket}"
    # An `<img>` reconnects with the same address; the ticket is not used up.
    responses = for _ <- 1..2, do: http(context, "GET", path, until: &(frames(&1) >= 1))
    Map.merge(context, %{responses: responses, stream_path: path})
  end

  step "the MC accepts the ticket while it lasts", context do
    assert [%{status: 200}, %{status: 200}] = context.responses
    refute Enum.any?(context.responses, &(&1.body =~ "wsTicket"))

    # Once its five minutes are up, the same address is refused.
    true =
      :ets.update_element(
        HalC2.Auth.Tickets,
        context.ticket,
        {2, System.os_time(:millisecond) - 1}
      )

    assert %{status: 401} = http(context, "GET", context.stream_path)
    context
  end

  step "the device hub is not running", context do
    devices()
    assert HalC2.Devices.hub_origin() == nil
    context
  end

  step "the hub does not answer", context do
    devices()
    {:ok, _} = HalC2.Devices.list(%{})
    Map.put(context, :hub_query, "&fake=drop")
  end

  step "the hub does not answer in time", context do
    devices()
    {:ok, _} = HalC2.Devices.list(%{})
    Application.put_env(:hal_c2, :device_hub_answer_timeout, 200)
    Map.put(context, :hub_query, "&fake=hang")
  end

  step "the owning cluster member is offline", context do
    devices()
    peer = :"laptop@offline.example"
    # What a peer's shell pushes on connect; it stays listed after the peer goes down.
    send(HalC2.Shell, {:nodeup, peer})
    GenServer.cast(HalC2.Shell, {:peer_environment, peer, %{"environmentId" => "env-laptop"}})
    send(HalC2.Shell, {:nodedown, peer})
    # A call after the cast: the shell has handled it once this answers.
    refute peer in HalC2.Shell.online_mcs()
    assert Enum.any?(HalC2.Shell.environments(), &(elem(&1, 0) == peer))

    Map.put(
      context,
      :hub_base,
      "/api/device-hub/mcs/" <> URI.encode_www_form(Atom.to_string(peer))
    )
  end

  step "a client asks for a device route through the proxy", context do
    path =
      (context[:hub_base] || base()) <>
        "/api/devices?token=#{HalC2.Web.token()}" <> (context[:hub_query] || "")

    Map.put(context, :response, http(context, "GET", path))
  end

  # --- agents ---------------------------------------------------------------------------

  step "agents have not been granted device access", context do
    # The project lets its agents call the device tools, so the call reaches the
    # device service, which finds the environment has not granted agents access.
    context = World.create_project(context, "app")
    context = World.create_thread(context, "work", "app")
    project = World.project(context, "app").id

    context
    |> write_settings(%{
      "enableAgentDeviceAccess" => false,
      "projectSettingsOverrides" => %{project => %{"enableAgentDeviceAccess" => true}}
    })
    |> Map.put(:agent_thread, World.thread_id(context, "work"))
  end

  step "agents have been granted device access", context do
    write_settings(context, %{"enableAgentDeviceAccess" => true})
  end

  step "agents have device access on the environment", context do
    write_settings(context, %{"enableAgentDeviceAccess" => true})
  end

  step "the thread's project turns agent device access off", context do
    context = World.create_project(context, "app")
    context = World.create_thread(context, "work", "app")
    project = World.project(context, "app").id

    context
    |> write_settings(%{
      "projectSettingsOverrides" => %{project => %{"enableAgentDeviceAccess" => false}}
    })
    |> Map.put(:agent_thread, World.thread_id(context, "work"))
  end

  step "an agent asks for a device", context do
    agent_call(context, "device_open", %{})
  end

  step "an agent in that thread asks for a device", context do
    agent_call(context, "device_open", %{})
  end

  step "it is told device access requires device support, agent access and an available platform",
       context do
    assert agent_error(context) =~
             "Agent device access requires enabled device support, agent access, and an available simulator platform"

    assert sessions(context[:agent_thread]) == []
    context
  end

  step "the agent is told agent device access is turned off", context do
    assert agent_error(context) == "Agent device access is turned off for this environment."
    context
  end

  step "an agent lists devices", context do
    agent_call(context, "device_list", %{})
  end

  step "it sees every host's devices and why a host has none", context do
    assert %{"structuredContent" => listed} = context.agent_result

    assert %{"hosts" => [%{"id" => "local", "platforms" => platforms}], "devices" => devices} =
             listed

    assert %{"available" => false, "reason" => "iOS Simulators need macOS with Xcode."} =
             Enum.find(platforms, &(&1["platform"] == "ios"))

    assert %{"available" => true} = Enum.find(platforms, &(&1["platform"] == "android"))
    assert Enum.map(devices, & &1["id"]) == ["Pixel_9", "Broken"]
    assert %{"local" => %{"status" => "ready"}} = listed["hostStatuses"]
    context
  end

  step "which of them are open in its own thread", context do
    assert context.agent_result["structuredContent"]["open"] == []

    context =
      context
      |> rpc("device.open", %{
        "threadId" => @agent_thread,
        "deviceId" => "Pixel_9",
        "platform" => "android",
        "boot" => false
      })
      |> rpc("device.open", %{
        "threadId" => "someone-else",
        "deviceId" => "Broken",
        "platform" => "android",
        "boot" => false
      })

    context = agent_call(context, "device_list", %{})

    assert [%{"hostId" => "local", "deviceId" => "Pixel_9"}] =
             context.agent_result["structuredContent"]["open"]

    context
  end

  step "an agent opens an iOS Simulator", context do
    context
    |> mac([Map.put(@simulator, "booted", false)])
    |> agent_call("device_open", %{"platform" => "ios"})
  end

  step "the device opens in the thread for the user to watch", context do
    assert %{"structuredContent" => %{"device" => device}} = context.agent_result
    assert %{"id" => "SIM-1", "platform" => "ios", "booted" => true} = device
    assert [%{"deviceId" => "SIM-1", "platform" => "ios"}] = sessions(@agent_thread)
    assert %{"booted" => true} = hub_simulator("SIM-1")
    context
  end

  step "the agent is told the device command and arguments pinned to that device", context do
    assert %{
             "agentDevice" => %{"command" => command, "targetArgs" => args},
             "quickStart" => quick
           } =
             context.agent_result["structuredContent"]

    assert [
             "--platform",
             "ios",
             "--udid",
             "SIM-1",
             "--config",
             config,
             "--session",
             "hal-c2-" <> _
           ] =
             args

    assert File.exists?(command)
    assert %{"daemonAuthToken" => "fake-token"} = config |> File.read!() |> JSON.decode!()
    assert quick =~ "The user is watching iPhone 16 (iOS 18.0) in the Device panel."
    assert quick =~ "Drive it with #{command}."
    assert quick =~ Enum.join(args, " ")
    context
  end

  step "one of two Android Emulators is running", context do
    # The hub lists both; only Pixel_9 is running, and it is listed second.
    emulators = [
      %{"id" => "Broken", "name" => "Broken", "platform" => "android", "booted" => false},
      %{"id" => "emulator-5580", "name" => "Pixel_9", "platform" => "android", "booted" => true}
    ]

    put_env(context, "FAKE_HUB_EMULATORS", JSON.encode!(emulators))
  end

  step "an agent opens an Android device without naming one", context do
    agent_call(context, "device_open", %{"platform" => "android"})
  end

  step "the running emulator is opened", context do
    assert %{"structuredContent" => %{"device" => %{"id" => "emulator-5580", "booted" => true}}} =
             context.agent_result

    assert [%{"deviceId" => "emulator-5580"}] = sessions(@agent_thread)
    context
  end

  step "device support is turned off", context do
    write_settings(context, %{"enableDeviceSupport" => false})
  end

  step "the named device does not exist", context do
    Map.put(context, :agent_args, %{"deviceId" => "iPhone-99"})
  end

  step "no simulators or emulators exist", context do
    emulator = Path.join([context.devices.sdk, "emulator", "emulator"])
    File.write!(emulator, "#!/bin/sh\nexit 0\n")
    context
  end

  step "both iOS and Android devices exist and none is named", context do
    mac(context, [Map.put(@simulator, "booted", false)])
  end

  step "an agent opens a device", context do
    agent_call(context, "device_open", context[:agent_args] || %{})
  end

  step ~r/^the agent is told (?<advice>to ask the user to turn device support on|to list the devices for current ids|to list the devices to see why|to choose a platform or a device)$/,
       %{args: [advice]} = context do
    expected =
      case advice do
        "to ask the user to turn device support on" ->
          "Device support is off. Ask the user to enable it in the Device panel before installing or starting device tools."

        "to list the devices for current ids" ->
          "No device iPhone-99 on host local. Call device_list for current ids."

        "to list the devices to see why" ->
          "No simulators or emulators were found. Call device_list to see why."

        "to choose a platform or a device" ->
          "Both iOS and Android devices are available; pass platform or deviceId."
      end

    assert agent_error(context) == expected
    assert sessions(@agent_thread) == []
    context
  end

  step "an agent has opened a device in its thread", context do
    context = write_settings(context, %{"enableAgentDeviceAccess" => true})
    context = agent_call(context, "device_open", %{"deviceId" => "Pixel_9"})

    assert %{"structuredContent" => %{"device" => %{"id" => "emulator-5554"}}} =
             context.agent_result

    context
  end

  step "no device is open in the agent's thread", context do
    context = write_settings(context, %{"enableAgentDeviceAccess" => true})
    devices()
    assert sessions(@agent_thread) == []
    context
  end

  step "the agent asks for a device screenshot", context do
    agent_call(context, "device_screenshot", %{})
  end

  step "it receives the screen as an image with its width and height", context do
    assert %{"structuredContent" => shot, "content" => [_text, image]} = context.agent_result

    assert %{
             "device" => %{"id" => "emulator-5554"},
             "screenshot" => %{"mimeType" => "image/png", "width" => 390, "height" => 844}
           } = shot

    assert %{"type" => "image", "mimeType" => "image/png", "data" => data} = image
    assert <<0x89, "PNG", _::binary>> = Base.decode64!(data)
    context
  end

  step "the agent is told to open a device first", context do
    assert agent_error(context) == "No device is open in this thread. Call device_open first."
    context
  end

  step "the agent closes the device asking to shut it down", context do
    agent_call(context, "device_close", %{"shutdown" => true})
  end

  step "the device leaves the thread and powers off", context do
    assert %{"structuredContent" => %{}} = context.agent_result
    refute context.agent_result["isError"]
    assert sessions(@agent_thread) == []
    {:ok, 200, body} = hub_get("/api/devices")
    assert JSON.decode!(body)["emulators"] == []
    refute Enum.any?(HalC2.Devices.state()["devices"], & &1["booted"])
    context
  end

  # --- helpers ----------------------------------------------------------------------------

  # Fake npm and the fake Android SDK; every variable is restored after the scenario.
  defp machine(context) do
    bin = Mc.tmp_dir(context.mc, "bin")
    sdk = Mc.tmp_dir(context.mc, "sdk")
    log = Path.join(bin, "calls.log")

    script(Path.join(bin, "npm"), """
    #!/bin/sh
    # npm install --prefix DIR ... NAME@VERSION: installs the fake of NAME.
    while [ $# -gt 0 ]; do
      case "$1" in
        --prefix) prefix=$2; shift ;;
        *@*) spec=$1 ;;
      esac
      shift
    done
    case "$spec" in
      expo-device-hub@*) entry=expo-device-hub/dist/server/cli.mjs; fake=fake_device_hub.mjs ;;
      agent-device@*) entry=agent-device/bin/agent-device.mjs; fake=fake_agent_device.mjs ;;
      *) echo "404 Not Found - $spec" >&2; exit 1 ;;
    esac
    mkdir -p "$(dirname "$prefix/node_modules/$entry")"
    cp "#{@support}/$fake" "$prefix/node_modules/$entry"
    """)

    script(Path.join([sdk, "platform-tools", "adb"]), """
    #!/bin/sh
    # adb -s SERIAL ...: light mode at font scale 1.15; remembers the launched app.
    shift 2
    echo "adb $*" >> "#{log}"
    case "$*" in
      "shell cmd uimode night") echo "Night mode: no" ;;
      "shell settings get system font_scale") echo "1.15" ;;
      "shell settings get global animator_duration_scale") echo "1.0" ;;
      "shell settings get global wifi_on") echo "1" ;;
      "shell monkey -p "*) echo "$4" > "#{bin}/foreground" ;;
      "shell dumpsys window")
        app=$(cat "#{bin}/foreground" 2>/dev/null || echo com.android.launcher)
        echo "  mCurrentFocus=Window{1a2b u0 $app/.MainActivity}" ;;
    esac
    exit 0
    """)

    File.mkdir_p!(Path.join(sdk, "emulator"))
    File.cp!(Path.join(@support, "fake_emulator.sh"), Path.join([sdk, "emulator", "emulator"]))
    avdmanager = Path.join([sdk, "cmdline-tools", "latest", "bin", "avdmanager"])
    File.mkdir_p!(Path.dirname(avdmanager))
    File.cp!(Path.join(@support, "fake_emulator.sh"), avdmanager)

    context
    |> Map.put(:devices, %{bin: bin, sdk: sdk, log: log})
    |> put_env("PATH", bin <> ":" <> System.get_env("PATH", ""))
    |> put_env("ANDROID_HOME", sdk)
    |> put_env("ANDROID_SDK_ROOT", nil)
    |> put_env("FAKE_HUB_SIMULATORS", nil)
    |> put_env("FAKE_HUB_EMULATORS", nil)
    |> tap(fn _ ->
      ExUnit.Callbacks.on_exit(fn ->
        Application.delete_env(:hal_c2, :os_type)
        Application.delete_env(:hal_c2, :device_hub_answer_timeout)
      end)
    end)
  end

  # A Mac with Xcode: `xcrun simctl` keeps each simulator's ui settings in files.
  defp mac(context, simulators) do
    %{bin: bin, log: log} = context.devices
    Application.put_env(:hal_c2, :os_type, {:unix, :darwin})

    script(Path.join(bin, "xcrun"), """
    #!/bin/sh
    echo "xcrun $*" >> "#{log}"
    [ "$1" = simctl ] || exit 0
    case "$2" in
      ui)
        file="#{bin}/$3-$4"
        if [ -n "$5" ]; then echo "$5" > "$file"
        elif [ -f "$file" ]; then cat "$file"
        else
          case "$4" in
            appearance) echo light ;;
            content_size) echo large ;;
            increase_contrast) echo disabled ;;
          esac
        fi ;;
      push) cat > "#{bin}/push.json" ;;
    esac
    exit 0
    """)

    put_env(context, "FAKE_HUB_SIMULATORS", JSON.encode!(simulators))
  end

  # A booted device of `platform`, as the hub lists it.
  defp booted(context, "iOS"), do: mac(context, [Map.put(@simulator, "booted", true)])

  defp booted(context, "Android") do
    emulator = %{
      "id" => "emulator-5580",
      "name" => "Pixel_9",
      "version" => "Android 15.0",
      "platform" => "android",
      "booted" => true
    }

    put_env(context, "FAKE_HUB_EMULATORS", JSON.encode!([emulator]))
  end

  defp script(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    File.chmod!(path, 0o755)
  end

  defp put_env(context, name, value) do
    previous = System.get_env(name)
    ExUnit.Callbacks.on_exit(fn -> restore_env(name, previous) end)
    restore_env(name, value)
    context
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp write_settings(context, changes) do
    Mc.ensure(HalC2.Settings)
    {settings, version} = HalC2.Settings.get()

    settings =
      Map.merge(settings, changes, fn
        "projectSettingsOverrides", old, new -> Map.merge(old || %{}, new)
        _, _, new -> new
      end)

    {:ok, _} = HalC2.Settings.put(settings, version)
    context
  end

  defp devices do
    Mc.ensure(HalC2.Settings)
    Mc.ensure(HalC2.Devices)
  end

  # An RPC on the paired client; installing and booting take longer than most calls.
  defp rpc(context, method, payload) do
    devices()
    id = System.unique_integer([:positive])

    client =
      Mc.rpc(World.client(context, "paired"), context.mc.environment, id, method, payload)

    {frame, client} = Mc.await(client, Mc.reply?(id), 15_000)

    reply =
      case frame do
        %{"t" => "rpc.result", "result" => result} -> {:ok, result}
        %{"t" => "rpc.error", "error" => error} -> {:error, error, frame["detail"]}
      end

    context |> World.put_client("paired", client) |> Map.put(:reply, reply)
  end

  defp open(context, thread, id, platform) do
    context =
      rpc(context, "device.open", %{
        "threadId" => thread,
        "deviceId" => id,
        "platform" => platform
      })

    assert {:ok, %{"deviceId" => ^id}} = context.reply
    context
  end

  # The host commands the fakes ran, one per line.
  defp calls(context) do
    case File.read(context.devices.log) do
      {:ok, text} -> text
      {:error, :enoent} -> ""
    end
  end

  defp sessions(thread),
    do: Enum.filter(HalC2.Devices.state()["sessions"], &(&1["threadId"] == thread))

  defp device(id), do: Enum.find(HalC2.Devices.state()["devices"], &(&1["id"] == id))

  defp hub_simulator(id) do
    {:ok, 200, body} = hub_get("/api/devices")
    Enum.find(JSON.decode!(body)["simulators"], &(&1["id"] == id))
  end

  defp hub_get(path) do
    request = {String.to_charlist(HalC2.Devices.hub_origin() <> path), []}

    case :httpc.request(:get, request, [timeout: 5_000], body_format: :binary) do
      {:ok, {{_, status, _}, _, body}} -> {:ok, status, body}
      error -> error
    end
  end

  defp base, do: HalC2.Devices.hub_base_path()

  # A session with only `scopes`, and a WebSocket ticket for it.
  defp ticket(scopes) do
    {:ok, %{"credential" => credential}} =
      HalC2.Auth.create_pairing_link(%{"label" => "Viewer", "scopes" => scopes})

    {:ok, access, _, ^scopes} = HalC2.Auth.exchange(credential, %{"label" => "Viewer"})
    {:ok, ticket, _} = HalC2.Auth.issue_ticket(access)
    ticket
  end

  # One request to the MC's HTTP port. A response that never ends is read until
  # `until` holds, then the client hangs up (`closed: true`).
  defp http(context, method, path, opts \\ []) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", context.mc.port, mode: :passive)
    {:ok, conn, ref} = Mint.HTTP.request(conn, method, path, opts[:headers] || [], opts[:body])
    read(conn, ref, %{status: nil, headers: [], body: "", closed: false}, opts[:until])
  end

  defp read(conn, ref, response, until) do
    {:ok, conn, parts} = Mint.HTTP.recv(conn, 0, 10_000)

    {response, done} =
      Enum.reduce(parts, {response, false}, fn
        {:status, ^ref, status}, {r, d} -> {%{r | status: status}, d}
        {:headers, ^ref, headers}, {r, d} -> {%{r | headers: headers}, d}
        {:data, ^ref, data}, {r, d} -> {%{r | body: r.body <> data}, d}
        {:done, ^ref}, {r, _} -> {r, true}
        _, acc -> acc
      end)

    cond do
      done ->
        Mint.HTTP.close(conn)
        response

      until && response.status == 200 && until.(response) ->
        Mint.HTTP.close(conn)
        %{response | closed: true}

      true ->
        read(conn, ref, response, until)
    end
  end

  defp frames(%{body: body}), do: length(String.split(body, "--frame")) - 1

  defp agent_call(context, name, args) do
    thread = context[:agent_thread] || @agent_thread
    {result, context} = tool(context, name, args, thread)
    Map.put(context, :agent_result, result)
  end

  defp tool(context, name, arguments, thread) do
    devices()
    Mc.ensure(HalC2.Mcp)
    %{authorization: auth} = HalC2.Mcp.server(thread, "codex")

    body =
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments}
      })

    {200, %{"result" => result}} = HalC2.Mcp.handle(auth, body)
    {result, context}
  end

  defp agent_error(context) do
    assert %{"isError" => true, "content" => [%{"text" => text}]} = context.agent_result
    %{"message" => message} = JSON.decode!(text)
    message
  end
end
