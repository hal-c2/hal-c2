defmodule HalC2.DevicesPropTest do
  @moduledoc """
  `HalC2.Devices`, the device hub's lifecycle, against a model of whether support is on,
  whether a hub runs, and how long the last restart waited. Commands turn support on and
  off, refresh devices (which starts the hub), make the hub exit as a crash would, refresh
  while a restart waits, and turn support off under an open whose boot never answers. The
  hub is `test/support/fake_device_hub.mjs` behind a fake npm, with an Android SDK whose
  only AVD's boot hangs.

  An exit is followed by a restart that clients see: the hub stopped, saying when it comes
  back, then a new hub ready. Real time decides whether the hub ran long enough to start
  over at the short wait, so the model allows that or the doubled wait, and the plain
  property below pins `HalC2.Devices.HubRestarts` itself.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Devices
  alias HalC2.Devices.HubRestarts

  @moduletag timeout: :infinity

  @support Path.expand("../../test/support", __DIR__)
  # Restarts wait 5 ms at first and at most 150 ms; a hub that ran 300 ms starts over.
  @base 5
  @off "Device support was turned off while the device was opening."

  property "the hub restarts after it exits and stops with device support",
    numtests: HalC2.Prop.numtests(25),
    max_size: 12 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        env = setup()
        {history, state, result} = run_commands(__MODULE__, cmds)
        teardown(env)

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # Each exit's wait, given when the hub started and exited: the short wait first and
  # after a run of a minute, otherwise double the last one, never past 30 times it.
  property "restart waits double while the hub keeps exiting and start over after a minute",
    numtests: HalC2.Prop.numtests(300) do
    forall {base, uptimes} <- {range(1, 2_000), list(range(0, 130_000))} do
      window = div(60_000 * base, 1_000)

      {_, _, _, ok} =
        Enum.reduce(uptimes, {HubRestarts.new(base), nil, 0, true}, fn uptime,
                                                                       {restarts, last, now, ok} ->
          restarts = HubRestarts.started(restarts, now)
          {delay, restarts} = HubRestarts.exited(restarts, now + uptime)

          expected =
            if last == nil or uptime >= window, do: base, else: min(last * 2, base * 30)

          {restarts, delay, now + uptime + delay, ok and delay == expected}
        end)

      ok
    end
  end

  defp setup do
    home = HalC2.Prop.scratch_home("devices")
    bin = Path.join(home, "bin")
    sdk = Path.join(home, "sdk")

    script(Path.join(bin, "npm"), """
    #!/bin/sh
    while [ $# -gt 0 ]; do
      case "$1" in
        --prefix) prefix=$2; shift ;;
        expo-device-hub@*) entry=expo-device-hub/dist/server/cli.mjs ;;
      esac
      shift
    done
    [ -n "$entry" ] || exit 1
    mkdir -p "$(dirname "$prefix/node_modules/$entry")"
    cp "#{@support}/fake_device_hub.mjs" "$prefix/node_modules/$entry"
    """)

    script(Path.join([sdk, "platform-tools", "adb"]), "#!/bin/sh\nexit 0\n")

    script(
      Path.join([sdk, "cmdline-tools", "latest", "bin", "avdmanager"]),
      "#!/bin/sh\nexit 0\n"
    )

    script(Path.join([sdk, "emulator", "emulator"]), """
    #!/bin/sh
    [ "$1" = "-list-avds" ] && echo Hang
    exit 0
    """)

    env =
      for {name, value} <- [
            {"PATH", bin <> ":" <> System.get_env("PATH", "")},
            {"ANDROID_HOME", sdk},
            {"ANDROID_SDK_ROOT", nil},
            {"FAKE_HUB_SIMULATORS", nil},
            {"FAKE_HUB_EMULATORS", nil}
          ] do
        previous = System.get_env(name)
        put_env(name, value)
        {name, previous}
      end

    Application.put_env(:hal_c2, :os_type, {:unix, :linux})
    Application.put_env(:hal_c2, :device_hub_restart_base, @base)
    HalC2.Prop.start_services([HalC2.Settings, Devices])
    {:ok, _} = Devices.subscribe(self())
    env
  end

  defp teardown(env) do
    HalC2.Prop.stop_services()
    for {name, value} <- env, do: put_env(name, value)
    Application.delete_env(:hal_c2, :os_type)
    Application.delete_env(:hal_c2, :device_hub_restart_base)
    flush()
  end

  defp script(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    File.chmod!(path, 0o755)
  end

  defp put_env(name, nil), do: System.delete_env(name)
  defp put_env(name, value), do: System.put_env(name, value)

  defp flush do
    receive do
      {:hal_c2_devices, _, _} -> flush()
    after
      0 -> :ok
    end
  end

  # --- model ------------------------------------------------------------------

  # enabled: device support is on. hub: the origin of the hub the model knows runs, or
  # nil. delay: the last restart's wait, nil before any.
  def initial_state, do: %{enabled: false, hub: nil, delay: nil}

  def command(state) do
    frequency(
      [
        {2, {:call, __MODULE__, :enable, []}},
        {1, {:call, __MODULE__, :disable, []}},
        {3, {:call, __MODULE__, :refresh, []}}
      ] ++
        if state.hub do
          [
            {8, {:call, __MODULE__, :crash, []}},
            {4, {:call, __MODULE__, :crash_then_refresh, []}},
            {2, {:call, __MODULE__, :disable_while_opening, []}}
          ]
        else
          []
        end
    )
  end

  def precondition(state, {:call, _, command, _})
      when command in [:crash, :crash_then_refresh, :disable_while_opening],
      do: state.hub != nil

  def precondition(_state, _call), do: true

  # A wait is the short one or double the last; the model takes whichever it was.
  def next_state(state, result, {:call, _, :crash, _}),
    do: %{
      state
      | hub: {:call, __MODULE__, :origin, [result]},
        delay: {:call, __MODULE__, :wait_of, [result]}
    }

  def next_state(state, result, {:call, _, :crash_then_refresh, _}),
    do: %{
      state
      | hub: {:call, __MODULE__, :origin, [result]},
        delay: {:call, __MODULE__, :wait_of, [result]}
    }

  def next_state(state, _result, {:call, _, :enable, _}), do: %{state | enabled: true}

  def next_state(state, _result, {:call, _, command, _})
      when command in [:disable, :disable_while_opening],
      do: %{state | enabled: false, hub: nil}

  def next_state(%{enabled: true} = state, result, {:call, _, :refresh, _}),
    do: %{state | hub: {:call, __MODULE__, :origin, [result]}}

  def next_state(state, _result, _call), do: state

  def postcondition(state, {:call, _, :refresh, _}, {reply, origin}) do
    if state.enabled,
      do:
        match?({:ok, %{"hostStatus" => "ready"}}, reply) and origin != nil and
          state.hub in [nil, origin],
      else: match?({:ok, %{"hostStatus" => "disabled", "devices" => []}}, reply) and origin == nil
  end

  def postcondition(state, {:call, _, :crash, _}, {delay, origin}),
    do: allowed?(state, delay) and origin not in [nil, state.hub]

  def postcondition(state, {:call, _, :crash_then_refresh, _}, {delay, reply, origin}),
    do:
      allowed?(state, delay) and origin not in [nil, state.hub] and
        match?({:ok, %{"hostStatus" => "ready"}}, reply)

  def postcondition(_state, {:call, _, :disable_while_opening, _}, {reply, origin}),
    do:
      match?({:error, %{"_tag" => "DeviceHostUnavailableError", "reason" => @off}}, reply) and
        origin == nil

  def postcondition(_state, {:call, _, :disable, _}, origin), do: origin == nil
  def postcondition(_state, {:call, _, :enable, _}, _), do: true

  defp allowed?(state, delay),
    do: delay == @base or (state.delay != nil and delay == min(state.delay * 2, @base * 30))

  # --- commands ---------------------------------------------------------------

  # The hub origin a command's result ends with, and the wait a crash's begins with.
  def origin(result), do: elem(result, tuple_size(result) - 1)
  def wait_of(result), do: elem(result, 0)

  def enable, do: write(true)

  def disable do
    write(false)
    Devices.hub_origin()
  end

  def refresh do
    reply = Devices.list(%{})
    {reply, Devices.hub_origin()}
  end

  # The hub exits; clients see it stopped with the wait, then a new hub ready.
  def crash do
    delay = exit_hub()
    await(&(&1["hostStatus"] == "ready"))
    {delay, Devices.hub_origin()}
  end

  # A refresh while the restart waits starts the hub at once; the restart then finds it
  # running and leaves it.
  def crash_then_refresh do
    delay = exit_hub()
    reply = Devices.list(%{})
    {delay, reply, Devices.hub_origin()}
  end

  def disable_while_opening do
    flush()

    task =
      Task.async(fn ->
        Devices.open(%{"threadId" => "t1", "deviceId" => "Hang", "platform" => "android"})
      end)

    await(&Enum.any?(&1["bootingDevices"], fn device -> device["id"] == "Hang" end))
    write(false)
    reply = Task.await(task, 30_000)
    {reply, Devices.hub_origin()}
  end

  defp exit_hub do
    flush()
    origin = Devices.hub_origin()
    request = {String.to_charlist(origin <> "/fake/exit"), [], ~c"text/plain", ""}
    {:ok, {{_, 200, _}, _, _}} = :httpc.request(:post, request, [timeout: 5_000], [])

    view = await(&(&1["hostStatus"] == "failed"))
    [_, ms] = Regex.run(~r/Restarting it in (\d+) ms\.$/, view["hostStatuses"]["local"]["detail"])
    String.to_integer(ms)
  end

  defp write(enabled) do
    {settings, version} = HalC2.Settings.get()
    {:ok, _} = HalC2.Settings.put(Map.put(settings, "enableDeviceSupport", enabled), version)
    # The settings reach the hub's server as a message; a call after it orders the two.
    _ = Devices.state()
    :ok
  end

  defp await(match) do
    receive do
      {:hal_c2_devices, _, view} -> if match.(view), do: view, else: await(match)
    after
      30_000 -> raise "no devices state matched"
    end
  end
end
