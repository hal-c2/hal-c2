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

  # An empty home and PATH, so the lookup finds neither the developer's SDK in ~/Android
  # nor an `adb` on PATH (the `on_path` candidate in `HalC2.Devices.android_sdk/0`). Both
  # last the rest of the scenario, which only probes with `System.find_executable/1`.
  step "no Android SDK is installed", context do
    context
    |> put_env("HOME", Mc.tmp_dir(context.mc, "home"))
    |> put_env("PATH", Mc.tmp_dir(context.mc, "path"))
    |> put_env("ANDROID_HOME", nil)
    |> put_env("ANDROID_SDK_ROOT", nil)

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

    assert actual =~ reason, "#{platform}: #{actual}"
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

  # --- the Android SDK and Node.js ---------------------------------------------------------

  step ~r/^an Android SDK with platform tools and the emulator, (?<tools>and no command-line tools|and only the old command-line tools under tools\/bin|and both the old and the latest command-line tools)$/,
       %{args: [tools]} = context do
    sdk = context.devices.sdk
    legacy = Path.join([sdk, "tools", "bin", "avdmanager"])

    if tools != "and both the old and the latest command-line tools",
      do: File.rm_rf!(Path.join(sdk, "cmdline-tools"))

    if tools != "and no command-line tools", do: script(legacy, "#!/bin/sh\nexit 0\n")
    context
  end

  step "Android devices are unavailable because the tools are an older, unsupported version, naming the SDK folder and what to install",
       context do
    assert %{"available" => false, "reason" => reason} = android_platform(context)
    assert reason =~ "appear to be an older, unsupported version"
    assert reason =~ context.devices.sdk
    assert reason =~ "Install Android SDK Command-line Tools (latest)"
    context
  end

  step "Android devices are available", context do
    assert %{"available" => true} = android_platform(context)
    context
  end

  step "no ANDROID_HOME is set", context do
    context
    |> put_env("ANDROID_HOME", nil)
    |> put_env("ANDROID_SDK_ROOT", nil)
    |> put_env("HOME", Mc.tmp_dir(context.mc, "home"))
  end

  step ~r"^the SDK is in the user's home under Library/Android/sdk with every tool installed$",
       context do
    sdk = Path.join([System.get_env("HOME"), "Library", "Android", "sdk"])
    File.mkdir_p!(Path.dirname(sdk))
    File.rename!(context.devices.sdk, sdk)
    put_in(context.devices.sdk, sdk)
  end

  step "the device tools run with the SDK's platform-tools and emulator folders ahead of PATH",
       context do
    sdk = context.devices.sdk
    # The AVDs came from the SDK's own emulator.
    assert {:ok, %{"devices" => devices}} = context.reply
    assert Enum.any?(devices, &(&1["id"] == "Pixel_9"))

    {:ok, 200, body} = hub_get("/fake/env")
    prefix = Path.join(sdk, "platform-tools") <> ":" <> Path.join(sdk, "emulator") <> ":"
    assert String.starts_with?(JSON.decode!(body)["PATH"], prefix)
    context
  end

  step "the MC's machine has no node on its PATH", context do
    # Only the fakes' folder: npm and xcrun, but no node.
    context = put_env(context, "PATH", context.devices.bin)
    assert System.find_executable("node") == nil
    context
  end

  step "a client opens a device for the first time", context do
    refute File.exists?(Path.join(context.mc.home, "tools"))

    rpc(context, "device.open", %{
      "threadId" => "t1",
      "deviceId" => "Pixel_9",
      "platform" => "android"
    })
  end

  step "it fails saying device support requires Node.js and to put node on PATH, then retry",
       context do
    assert {:error, _, %{"_tag" => "DeviceHostUnavailableError", "reason" => reason}} =
             context.reply

    assert reason ==
             "Local device support requires Node.js. Install Node.js and make sure node is on PATH, then retry."

    context
  end

  step "no tool is installed", context do
    refute File.exists?(Path.join(context.mc.home, "tools"))
    assert HalC2.Devices.hub_origin() == nil
    assert sessions("t1") == []
    context
  end

  # --- booting and shutting down -----------------------------------------------------------

  step ~r/^an Android virtual device "(?<name>[^"]+)" that is not running$/,
       %{args: [name]} = context do
    script(Path.join([context.devices.sdk, "emulator", "emulator"]), """
    #!/bin/sh
    [ "$1" = "-list-avds" ] && echo "#{name}"
    exit 0
    """)

    Map.put(context, :avd, name)
  end

  step "a client has asked the MC to set up device support", context do
    rpc(context, "device.list", %{})
  end

  step "the device is listed by its name as not booted", context do
    assert {:ok, %{"devices" => devices}} = context.reply
    avd = context.avd

    assert [%{"id" => ^avd, "name" => ^avd, "platform" => "android", "booted" => false}] =
             devices

    context
  end

  step ~r/^a client opens "(?<name>[^"]+)" in a thread$/, %{args: [name]} = context do
    client = Mc.connect(context.mc)
    client = Mc.sub(client, 1, %{"type" => "devices", "mc" => Atom.to_string(node())})
    {_, client} = Mc.await(client, &(&1["t"] == "devices"))

    context
    |> World.put_client("watcher", client)
    |> rpc("device.open", %{"threadId" => "t1", "deviceId" => name, "platform" => "android"})
  end

  step ~r/^clients see "(?<name>[^"]+)" as booting until the boot finishes$/,
       %{args: [name]} = context do
    booting = &Enum.any?(&1["state"]["bootingDevices"], fn device -> device["id"] == name end)
    watcher = World.client(context, "watcher")
    {frame, watcher} = Mc.await(watcher, &(&1["t"] == "devices" and booting.(&1)), 5_000)
    assert [%{"threadId" => "t1", "name" => ^name}] = frame["state"]["bootingDevices"]

    {_, watcher} =
      Mc.await(watcher, &(&1["t"] == "devices" and &1["state"]["bootingDevices"] == []), 5_000)

    World.put_client(context, "watcher", watcher)
  end

  step "the thread's session names the emulator's serial", context do
    assert {:ok, %{"deviceId" => "emulator-5554", "threadId" => "t1"}} = context.reply
    assert [%{"deviceId" => "emulator-5554"}] = sessions("t1")
    context
  end

  step "the device is listed once, under that serial", context do
    avd = context.avd
    android = Enum.filter(HalC2.Devices.state()["devices"], &(&1["platform"] == "android"))
    assert [%{"id" => "emulator-5554", "name" => ^avd, "booted" => true}] = android
    context
  end

  step "a thread with an open iOS simulator that is being streamed", context do
    context =
      context
      |> mac([Map.put(@simulator, "booted", false)])
      |> open("t1", "SIM-1", "ios")

    assert %{"SIM-1" => capture} = hub_json("/fake/captures")
    stream = stream_open(context, "/vendor/serve-sim/helper/SIM-1/stream.mjpeg")
    Map.merge(context, %{capture: capture, stream: stream})
  end

  step "the simulator's stream capture is released", context do
    assert {:ok, nil} = context.reply
    # The hub ended the stream; the client sees its end instead of hanging on.
    assert %{status: 200, closed: false} = stream_finish(context.stream)
    refute Map.has_key?(hub_json("/fake/captures"), "SIM-1")
    context
  end

  step "opening it again starts a new capture", context do
    context = open(context, "t1", "SIM-1", "ios")
    assert %{"SIM-1" => capture} = hub_json("/fake/captures")
    assert capture > context.capture

    response =
      http(
        context,
        "GET",
        base() <> "/vendor/serve-sim/helper/SIM-1/stream.mjpeg?token=#{HalC2.Web.token()}",
        until: &(frames(&1) >= 1)
      )

    assert %{status: 200, closed: true} = response
    context
  end

  step "a booted iOS simulator in the MC's device list", context do
    context = context |> mac([Map.put(@simulator, "booted", true)]) |> rpc("device.list", %{})
    assert %{"booted" => true} = device("SIM-1")
    context
  end

  step "the hub rejects the shutdown request", context do
    Map.put(context, :reject_shutdown, true)
  end

  step ~r/^the hub then reports the simulator (?<state>off|booted|missing from a partial list)$/,
       %{args: [state]} = context do
    assert context.reject_shutdown
    reported = %{"off" => "off", "booted" => "booted", "missing from a partial list" => "missing"}
    hub_post("/fake/config", %{"rejectShutdown" => reported[state]})
    context
  end

  step ~r/^the shutdown (?<outcome>succeeds|fails)$/, %{args: [outcome]} = context do
    case outcome do
      "succeeds" ->
        assert {:ok, nil} = context.reply

      "fails" ->
        assert {:error, _, %{"_tag" => "DeviceOperationError", "reason" => "hub_rejected"}} =
                 context.reply
    end

    context
  end

  step ~r/^the simulator is listed as (?<listed>not booted|booted)$/,
       %{args: [listed]} = context do
    assert %{"booted" => booted} = device("SIM-1")
    assert booted == (listed == "booted")
    context
  end

  step "a thread with an open emulator", context do
    context =
      rpc(context, "device.open", %{
        "threadId" => "t1",
        "deviceId" => "Pixel_9",
        "platform" => "android"
      })

    assert {:ok, %{"deviceId" => "emulator-5554"}} = context.reply
    Map.put(context, :emulator, "emulator-5554")
  end

  step "the hub cannot list devices once the emulator is off", context do
    hub_post("/fake/config", %{"listFailsAfterShutdown" => true})
    context
  end

  step "a client closes the device and asks to power it off", context do
    rpc(context, "device.close", %{
      "threadId" => "t1",
      "deviceId" => context.emulator,
      "shutdown" => true
    })
  end

  step "the request succeeds", context do
    assert {:ok, nil} = context.reply
    # The list really could not be read afterwards.
    assert {:ok, 500, _} = hub_get("/api/devices")
    context
  end

  step "the emulator is listed as not booted", context do
    assert %{"booted" => false} = device(context.emulator)
    context
  end

  # --- accessibility and orientation ------------------------------------------------------

  step ~r/^a client turns (?<toggle>VoiceOver|network access) on for a booted (?<platform>iOS|Android) device$/,
       %{args: [toggle, platform]} = context do
    setting = if toggle == "VoiceOver", do: "voiceOver", else: "networkEnabled"
    action(context, platform, %{"type" => "setToggle", "setting" => setting, "value" => true})
  end

  step "the MC answers with the device's detail after the change", context do
    assert {:ok, %{"deviceId" => id, "settings" => settings}} = context.reply
    assert id == context.action["deviceId"]
    calls = context |> calls() |> String.split("\n", trim: true)

    {command, read, fresh} =
      case context.action do
        %{"setting" => "voiceOver"} ->
          {~r"^xcrun simctl spawn SIM-1 \S+/serve-sim-ax-settings set voiceover on$",
           ~r"^xcrun simctl spawn SIM-1 \S+/serve-sim-ax-settings status$",
           settings["voiceOver"] == true}

        %{"setting" => "networkEnabled"} ->
          {~r"^adb shell svc data enable$", ~r"^adb shell settings get global wifi_on$",
           settings["networkEnabled"] == true}
      end

    ran = Enum.find_index(calls, &(&1 =~ command))
    assert ran, "#{inspect(command)} never ran: #{inspect(calls)}"
    assert Enum.any?(Enum.drop(calls, ran + 1), &(&1 =~ read)), "no read after the change"
    assert fresh, "the detail does not reflect #{inspect(context.action)}: #{inspect(settings)}"
    context
  end

  step "no command runs on the device when it is unavailable", context do
    with {:error, _, _} <- context.reply, do: assert(calls(context) == "")
    context
  end

  step ~r/^a client sets the orientation of (?<device>an Android emulator|a physical Android phone) to landscape$/,
       %{args: [device]} = context do
    serial = if device == "an Android emulator", do: "emulator-5580", else: "R5CT20ABCDE"

    phone = %{
      "id" => serial,
      "name" => "Pixel 9",
      "version" => "Android 15.0",
      "platform" => "android",
      "booted" => true,
      "physical" => serial != "emulator-5580"
    }

    context
    |> put_env("FAKE_HUB_EMULATORS", JSON.encode!([phone]))
    |> rpc("device.action", %{
      "deviceId" => serial,
      "type" => "setOrientation",
      "value" => "landscape_left"
    })
  end

  step "the MC tilts the emulator's accelerometer to that side", context do
    assert {:ok, %{"deviceId" => "emulator-5580"}} = context.reply
    assert calls(context) =~ "adb emu sensor set acceleration 9.81:0:0\n"
    refute calls(context) =~ "user-rotation lock"
    context
  end

  step "the MC locks the phone's rotation to that side", context do
    assert {:ok, %{"deviceId" => "R5CT20ABCDE"}} = context.reply
    assert calls(context) =~ "adb shell cmd window user-rotation lock 1\n"
    refute calls(context) =~ "emu sensor"
    context
  end

  step "the hub install has no accessibility helper", context do
    put_env(context, "FAKE_NPM_NO_AX_HELPER", "1")
  end

  step "a client sets a colour filter on a booted iOS device", context do
    action(context, "iOS", %{"type" => "setColorFilter", "value" => "grayscale"})
  end

  step "the MC answers that the action requires a helper and to set up device support again",
       context do
    assert {:error, message,
            %{"_tag" => "DeviceActionUnavailableError", "reason" => "helper_missing"}} =
             context.reply

    assert message =~ "requires a helper missing from this install. Set up device support again."
    refute calls(context) =~ "spawn"
    context
  end

  # --- the proxy, in more detail ----------------------------------------------------------

  step "a session with the read scope and without the operate scope", context do
    devices()
    {:ok, _} = HalC2.Devices.list(%{})
    Map.put(context, :ticket, ticket(["orchestration:read"]))
  end

  step ~r/^it opens the WebSocket "(?<socket>[^"]+)" through the device proxy$/,
       %{args: [socket]} = context do
    ws = ws_open(context, base() <> socket <> "?wsTicket=#{context.ticket}")
    Map.merge(context, %{response: ws, socket: socket})
  end

  step "the MC answers by relaying the socket", context do
    assert %{status: 101, frames: [hello | _]} = context.response
    assert %{"hello" => context.socket} == hello
    ws_close(context.response)
    context
  end

  step "the MC answers that the operate scope is needed", context do
    assert %{status: 403, body: body} = context.response

    assert %{"code" => "insufficient_scope", "requiredScope" => "orchestration:operate"} =
             JSON.decode!(body)

    context
  end

  step "the hub receives the socket", context do
    assert Enum.any?(hub_requests(), &(&1["url"] == context.socket))
    context
  end

  step "the hub receives no request", context do
    path = context[:socket] || context.path
    refute Enum.any?(hub_requests(), &String.starts_with?(&1["url"], path))
    context
  end

  step ~r/^it (?<method>reads|posts) "(?<path>[^"]+)" through the device proxy$/,
       %{args: [method, path]} = context do
    url = base() <> path <> "?wsTicket=#{context.ticket}"

    response =
      if method == "reads",
        do: http(context, "GET", url),
        else:
          http(context, "POST", url,
            body: ~s({"fps":15}),
            headers: [{"content-type", "application/json"}]
          )

    Map.merge(context, %{response: response, path: path, method: method})
  end

  step ~r/^the MC answers with the stream (?<what>mode|settings)$/, %{args: [what]} = context do
    assert %{status: 200, body: body} = context.response

    case what do
      "mode" -> assert %{"mode" => "mjpeg"} = JSON.decode!(body)
      "settings" -> assert %{"fps" => 30} = JSON.decode!(body)
    end

    context
  end

  step "a client that authorises with a WebSocket ticket in the query, a cookie and a bearer header",
       context do
    devices()
    {:ok, _} = HalC2.Devices.list(%{})
    {:ok, ticket, _} = HalC2.Auth.issue_ticket(context.access_token)
    Map.put(context, :ticket, ticket)
  end

  step "it requests a device route through the proxy", context do
    path =
      base() <> "/api/devices?wsTicket=#{context.ticket}&hostId=local&token=leak&probe=1"

    headers = [
      {"cookie", "hal_c2_session=secret"},
      {"authorization", "Bearer #{context.access_token}"}
    ]

    Map.put(context, :response, http(context, "GET", path, headers: headers))
  end

  step "the request the hub receives has none of the ticket, the cookie or the bearer header",
       context do
    assert %{status: 200} = context.response
    assert [%{"url" => url, "headers" => headers}] = hub_requests("/api/devices?")
    refute url =~ "wsTicket"
    refute url =~ "token"
    refute Map.has_key?(headers, "cookie")
    refute Map.has_key?(headers, "authorization")
    Map.put(context, :hub_url, url)
  end

  step "it has no host id parameter, which belongs to the MC", context do
    assert context.hub_url == "/api/devices?probe=1"
    context
  end

  step "the Android hub refuses a change whose origin is not its own", context do
    devices()
    {:ok, _} = HalC2.Devices.list(%{})

    {:ok, {{_, status, _}, _, _}} =
      :httpc.request(
        :post,
        {String.to_charlist(
           HalC2.Devices.hub_origin() <> "/vendor/serve-emu/api/stream-settings"
         ), [{~c"origin", ~c"http://elsewhere.example"}], ~c"application/json", ~s({"fps":15})},
        [timeout: 5_000],
        body_format: :binary
      )

    assert status == 403
    context
  end

  step "a client with the operate scope posts a stream setting through the device proxy",
       context do
    ticket = ticket(["orchestration:read", "orchestration:operate"])

    response =
      http(context, "POST", base() <> "/vendor/serve-emu/api/stream-settings?wsTicket=#{ticket}",
        body: ~s({"fps":15}),
        headers: [
          {"content-type", "application/json"},
          {"origin", "http://127.0.0.1:#{context.mc.port}"}
        ]
      )

    Map.put(context, :response, response)
  end

  step "the hub accepts the change", context do
    assert %{status: 200} = context.response
    assert %{"fps" => 15} = hub_json("/vendor/serve-emu/api/stream-settings")
    context
  end

  step "a client has a device socket open through the proxy", context do
    devices()
    {:ok, _} = HalC2.Devices.list(%{})
    ws = ws_open(context, base() <> "/vendor/serve-emu/ws?token=#{HalC2.Web.token()}")
    assert %{status: 101, frames: [%{"hello" => "/vendor/serve-emu/ws"}]} = ws
    Map.put(context, :ws, ws)
  end

  step "the hub closes the socket", context do
    ws = ws_send(context.ws, {:text, ~s({"fake":"close"})})
    Map.merge(context, %{ws: ws, ending: :hub})
  end

  step "the client closes the socket", context do
    ws = ws_send(context.ws, :close)
    Map.merge(context, %{ws: ws, ending: :client})
  end

  # Another client socket, whose relay to the hub never gets its upgrade answered;
  # the ten seconds are shortened for the test.
  step "the hub fails to answer the upgrade within ten seconds", context do
    Application.put_env(:hal_c2, :device_hub_upgrade_timeout, 200)
    ws_close(context.ws)
    path = base() <> "/vendor/serve-emu/ws?token=#{HalC2.Web.token()}&fake=hang"
    ws = ws_open(context, path, greeting: false)
    assert %{status: 101} = ws
    Map.merge(context, %{ws: ws, ending: :upgrade})
  end

  step "the other end of the socket is closed too", context do
    case context.ending do
      :client -> assert {:ok, 200, "closed"} = hub_get("/fake/sockets-closed")
      _ -> assert ws_closed?(context.ws)
    end

    context
  end

  step "a client opens a device's MJPEG stream through the proxy", context do
    devices()
    {:ok, _} = HalC2.Devices.list(%{})
    path = base() <> "/vendor/serve-sim/helper/SIM-1/stream.mjpeg?token=#{HalC2.Web.token()}"
    Map.put(context, :response, http(context, "GET", path, until: &(frames(&1) >= 3)))
  end

  step "the response says it must not be stored or transformed", context do
    assert %{status: 200, headers: headers} = context.response
    assert {"cache-control", "no-store, no-transform"} in headers
    refute List.keymember?(headers, "content-encoding", 0)
    context
  end

  step "frames reach the client as the hub sends them", context do
    # The stream never ends, so the frames arrived while the hub was still sending,
    # each one as the hub wrote it.
    assert %{closed: true, body: body, chunks: chunks} = context.response
    assert chunks >= 2

    for frame <- body |> String.split("--frame", trim: true) |> Enum.drop(-1),
        do: assert(frame == "\r\ncontent-type: image/jpeg\r\ncontent-length: 4\r\n\r\njpeg\r\n")

    context
  end

  # --- agents, in more detail ---------------------------------------------------------------

  step "device support is on and no client has listed devices since the MC started", context do
    context =
      context |> write_settings(%{"enableAgentDeviceAccess" => true}) |> booted("Android")

    devices()
    assert HalC2.Devices.state()["devices"] == []
    assert HalC2.Devices.hub_origin() == nil
    context
  end

  step "a screenshot of a device is asked for by its id", context do
    agent_call(context, "device_screenshot", %{"deviceId" => "emulator-5580"})
  end

  step "the MC finds the device itself", context do
    assert %{"structuredContent" => %{"device" => %{"id" => "emulator-5580"}}} =
             context.agent_result

    assert %{"booted" => true} = device("emulator-5580")
    context
  end

  step "answers with its screen image", context do
    assert %{"content" => [_text, %{"type" => "image", "data" => data}]} = context.agent_result
    assert <<0x89, "PNG", _::binary>> = Base.decode64!(data)
    context
  end

  step "an agent has not opened a device in its thread", context do
    # Another thread's agent opened one, so the device command is installed.
    context = write_settings(context, %{"enableAgentDeviceAccess" => true})
    {result, context} = tool(context, "device_open", %{"deviceId" => "Pixel_9"}, "other-thread")
    assert %{"structuredContent" => %{"agentDevice" => %{"command" => command}}} = result
    assert sessions(@agent_thread) == []
    Map.put(context, :command, command)
  end

  step "the agent runs a device command without the device's config and session", context do
    {output, code} = System.cmd(context.command, ["snapshot", "-i"], stderr_to_stdout: true)
    Map.put(context, :command_result, {code, output})
  end

  step "the command fails telling the agent to open a device first", context do
    assert {1, output} = context.command_result
    assert output =~ "Call device_open first and include its --config and --session flags."
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
    # The accessibility helper serve-sim bundles, unless the scenario's install lacks it.
    if [ "$fake" = fake_device_hub.mjs ] && [ -z "$FAKE_NPM_NO_AX_HELPER" ]; then
      ax="$prefix/node_modules/expo-device-hub/vendor/serve-sim/dist/simax"
      mkdir -p "$ax" && touch "$ax/serve-sim-ax-settings"
    fi
    """)

    script(Path.join([sdk, "platform-tools", "adb"]), """
    #!/bin/sh
    # adb -s SERIAL ...: light mode at font scale 1.15; remembers the launched app
    # and whether wifi is on.
    shift 2
    echo "adb $*" >> "#{log}"
    case "$*" in
      "shell cmd uimode night") echo "Night mode: no" ;;
      "shell settings get system font_scale") echo "1.15" ;;
      "shell settings get global animator_duration_scale") echo "1.0" ;;
      "shell settings get global wifi_on") cat "#{bin}/wifi" 2>/dev/null || echo 1 ;;
      "shell svc wifi enable") echo 1 > "#{bin}/wifi" ;;
      "shell svc wifi disable") echo 0 > "#{bin}/wifi" ;;
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
        Application.delete_env(:hal_c2, :device_hub_upgrade_timeout)
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
      # spawn UDID HELPER set KEY VALUE | status: the accessibility helper's settings.
      spawn)
        case "$5" in
          set) echo "$7" > "#{bin}/$3-ax-$6" ;;
          status)
            sep=
            printf '{'
            for file in "#{bin}/$3-ax-"*; do
              [ -f "$file" ] || continue
              printf '%s"%s":"%s"' "$sep" "${file##*-ax-}" "$(cat "$file")"
              sep=,
            done
            printf '}\n' ;;
        esac ;;
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
    response = %{status: nil, headers: [], body: "", chunks: 0, closed: false}
    read(conn, ref, response, opts[:until])
  end

  defp read(conn, ref, response, until) do
    {:ok, conn, parts} = Mint.HTTP.recv(conn, 0, 10_000)

    {response, done} =
      Enum.reduce(parts, {response, false}, fn
        {:status, ^ref, status}, {r, d} -> {%{r | status: status}, d}
        {:headers, ^ref, headers}, {r, d} -> {%{r | headers: headers}, d}
        {:data, ^ref, data}, {r, d} -> {%{r | body: r.body <> data, chunks: r.chunks + 1}, d}
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

  defp android_platform(context) do
    assert {:ok, %{"hosts" => hosts}} = context.reply
    %{"platforms" => platforms} = Enum.find(hosts, &(&1["id"] == "local"))
    Enum.find(platforms, &(&1["platform"] == "android"))
  end

  # A device.action on a booted device of `platform`.
  defp action(context, platform, input) do
    context = booted(context, platform)
    id = if platform == "iOS", do: "SIM-1", else: "emulator-5580"
    input = Map.put(input, "deviceId", id)

    context
    |> Map.merge(%{action: input, platform: String.downcase(platform)})
    |> rpc("device.action", input)
  end

  defp hub_json(path) do
    {:ok, 200, body} = hub_get(path)
    JSON.decode!(body)
  end

  defp hub_post(path, value) do
    request =
      {String.to_charlist(HalC2.Devices.hub_origin() <> path), [], ~c"application/json",
       JSON.encode!(value)}

    {:ok, {{_, 200, _}, _, _}} =
      :httpc.request(:post, request, [timeout: 5_000], body_format: :binary)
  end

  # What reached the hub, optionally only the requests whose URL starts with `prefix`.
  defp hub_requests(prefix \\ "") do
    "/fake/requests" |> hub_json() |> Enum.filter(&String.starts_with?(&1["url"], prefix))
  end

  # A stream through the MC that stays open: read until the first frame, then hand
  # back the connection so a later step can read it to its end.
  defp stream_open(context, path) do
    url = base() <> path <> "?token=#{HalC2.Web.token()}"
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", context.mc.port, mode: :passive)
    {:ok, conn, ref} = Mint.HTTP.request(conn, "GET", url, [], nil)
    stream_read(%{conn: conn, ref: ref, status: nil, body: "", done: false}, &(frames(&1) >= 1))
  end

  defp stream_finish(stream) do
    stream = stream_read(stream, fn _ -> false end)
    Mint.HTTP.close(stream.conn)
    %{status: stream.status, closed: not stream.done}
  end

  defp stream_read(%{done: true} = stream, _), do: stream

  defp stream_read(stream, until) do
    if stream.status == 200 and until.(stream) do
      stream
    else
      {:ok, conn, parts} = Mint.HTTP.recv(stream.conn, 0, 10_000)
      ref = stream.ref

      stream =
        Enum.reduce(parts, %{stream | conn: conn}, fn
          {:status, ^ref, status}, s -> %{s | status: status}
          {:data, ^ref, data}, s -> %{s | body: s.body <> data}
          {:done, ^ref}, s -> %{s | done: true}
          _, s -> s
        end)

      stream_read(stream, until)
    end
  end

  # A WebSocket through the MC: its status, and the body of a refusal or the hub's
  # greeting. `greeting: false` returns as soon as the MC upgrades, for a socket the
  # hub never answers.
  defp ws_open(context, path, opts \\ []) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", context.mc.port, mode: :passive)
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, path, [])
    ws = %{conn: conn, ref: ref, status: nil, headers: [], body: "", frames: [], closed: false}
    ws = ws_upgrade(ws)

    if ws.status == 101 and Keyword.get(opts, :greeting, true),
      do: ws_greeting(ws),
      else: ws
  end

  defp ws_upgrade(ws) do
    {:ok, conn, parts} = Mint.HTTP.recv(ws.conn, 0, 10_000)
    ref = ws.ref

    {ws, done} =
      Enum.reduce(parts, {%{ws | conn: conn}, false}, fn
        {:status, ^ref, status}, {w, d} -> {%{w | status: status}, d}
        {:headers, ^ref, headers}, {w, d} -> {%{w | headers: headers}, d}
        {:data, ^ref, data}, {w, d} -> {%{w | body: w.body <> data}, d}
        {:done, ^ref}, {w, _} -> {w, true}
        _, acc -> acc
      end)

    cond do
      not done and not (ws.status == 101 and ws.headers != []) -> ws_upgrade(ws)
      ws.status != 101 -> ws
      true -> ws_new(ws)
    end
  end

  # The hub's first frame can arrive in the same packet as the upgrade response.
  defp ws_new(ws) do
    {:ok, conn, websocket} = Mint.WebSocket.new(ws.conn, ws.ref, ws.status, ws.headers)
    {:ok, websocket, frames} = Mint.WebSocket.decode(websocket, ws.body)
    %{ws | conn: conn, body: ""} |> Map.put(:websocket, websocket) |> ws_frames(frames)
  end

  defp ws_greeting(%{frames: [_ | _]} = ws), do: ws

  defp ws_greeting(ws) do
    {:frames, _, ws} = ws_recv(ws, 10_000)
    ws_greeting(ws)
  end

  defp ws_frames(ws, frames) do
    closed = Enum.any?(frames, &match?({:close, _, _}, &1))
    texts = for {:text, text} <- frames, do: JSON.decode!(text)
    %{ws | frames: ws.frames ++ texts, closed: ws.closed or closed}
  end

  defp ws_recv(ws, timeout) do
    case Mint.WebSocket.recv(ws.conn, 0, timeout) do
      {:ok, conn, parts} ->
        {websocket, frames} =
          Enum.reduce(parts, {ws.websocket, []}, fn
            {:data, _, data}, {websocket, acc} ->
              {:ok, websocket, frames} = Mint.WebSocket.decode(websocket, data)
              {websocket, acc ++ frames}

            _, acc ->
              acc
          end)

        {:frames, frames, ws_frames(%{ws | conn: conn, websocket: websocket}, frames)}

      {:error, conn, %Mint.TransportError{reason: :timeout}, _} ->
        {:timeout, %{ws | conn: conn}}

      {:error, conn, _, _} ->
        {:frames, [], %{ws | conn: conn, closed: true}}
    end
  end

  defp ws_send(ws, frame) do
    {:ok, websocket, data} = Mint.WebSocket.encode(ws.websocket, frame)
    {:ok, conn} = Mint.WebSocket.stream_request_body(ws.conn, ws.ref, data)
    %{ws | conn: conn, websocket: websocket}
  end

  defp ws_close(ws), do: Mint.HTTP.close(ws.conn)

  # Whether the MC ended the socket: a close frame, or the connection gone.
  defp ws_closed?(%{closed: true}), do: true

  defp ws_closed?(ws) do
    case ws_recv(ws, 5_000) do
      {:timeout, _} -> false
      {:frames, _, ws} -> ws_closed?(ws)
    end
  end
end
