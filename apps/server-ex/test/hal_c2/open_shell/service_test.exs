defmodule HalC2.OpenShell.ServiceTest do
  # The service manager is chosen through the app env.
  use ExUnit.Case, async: false

  alias HalC2.OpenShell
  alias HalC2.OpenShell.Config
  alias HalC2.OpenShell.Service
  alias HalC2.Test.FakeOpenShell
  alias HalC2.Test.Storage

  @moduletag :tmp_dir

  # xmerl ships with OTP but is no dependency of the MC, so Mix leaves it off the path.
  setup_all do
    [ebin] = Path.wildcard(Path.join([to_string(:code.root_dir()), "lib", "xmerl-*", "ebin"]))
    true = :code.add_patha(String.to_charlist(ebin))
    :ok
  end

  @state %{
    "mode" => "managed",
    "version" => "0.1.7",
    "port" => 17_670,
    "driver" => "podman",
    "socket" => "/run/user/1000/podman/podman.sock",
    "endpoint" => "https://127.0.0.1:17670"
  }

  setup %{tmp_dir: dir} do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    log = Storage.fake_service_manager(bin)

    FakeOpenShell.put_env(
      home: Path.join(dir, "mc dir"),
      service_platform: {:unix, :linux},
      service_user_home: Path.join(dir, "user"),
      systemctl_command: Path.join(bin, "systemctl"),
      loginctl_command: Path.join(bin, "loginctl"),
      launchctl_command: Path.join(bin, "launchctl")
    )

    %{log: log}
  end

  describe "systemd" do
    test "the unit runs the pinned gateway with its environment pinned" do
      unit = Service.render(:systemd, @state)
      lines = String.split(unit, "\n")

      assert "Wants=podman.socket" in lines
      assert "UMask=0077" in lines
      assert "NoNewPrivileges=yes" in lines

      # The user manager's environment is not the gateway's: it starts from an empty one.
      [exec] = for "ExecStart=" <> argv <- lines, do: argv
      assert exec =~ ~r{\A/usr/bin/env -i }
      assert exec =~ " OPENSHELL_TELEMETRY_ENABLED=false "
      assert exec =~ " OPENSHELL_DISABLE_TLS=false "
      refute Enum.any?(lines, &String.starts_with?(&1, "Environment="))

      # The home has a space in it: every path is one quoted argument.
      assert exec =~ ~s("#{OpenShell.gateway_bin("0.1.7")}" --config "#{OpenShell.config_path()}")

      refute unit =~ "docker.sock"
      refute Service.render(:systemd, %{@state | "driver" => "docker"}) =~ "podman.socket"
    end

    test "install writes the unit, enables and restarts it; uninstall takes it away", %{log: log} do
      assert :ok = Service.install(@state)
      path = Service.unit_path(:systemd)
      assert File.read!(path) == Service.render(:systemd, @state)

      assert Storage.service_calls(log) == [
               "systemctl --user daemon-reload",
               "systemctl --user enable #{Service.name(:systemd)}",
               "systemctl --user restart #{Service.name(:systemd)}",
               "systemctl --user enable --now #{Service.reap_name(:timer)}"
             ]

      # The reaper, beside it, so a review's lease ends while the MC is down too.
      for {path, unit} <- Service.reaper(:systemd), do: assert(File.read!(path) == unit)

      assert %{"installed" => true, "running" => true, "current" => true} = Service.status(@state)
      assert %{"current" => false} = Service.status(%{@state | "version" => "0.1.8"})

      assert :ok = Service.stop()
      assert %{"running" => false} = Service.status(@state)

      File.rm!(log)
      assert :ok = Service.uninstall()
      refute File.exists?(path)

      assert Storage.service_calls(log) == [
               "systemctl --user stop #{Service.name(:systemd)}",
               "systemctl --user disable --now #{Service.reap_name(:timer)}",
               "systemctl --user disable #{Service.name(:systemd)}",
               "systemctl --user daemon-reload"
             ]

      for {path, _} <- Service.reaper(:systemd), do: refute(File.exists?(path))

      assert %{"installed" => false, "running" => false} = Service.status(@state)
      assert :ok = Service.uninstall()
    end

    test "the reaper runs openshell reap every minute with the MC's home", %{tmp_dir: dir} do
      System.put_env("HAL_C2_MC_HOME", Path.join(dir, "mc dir"))
      System.put_env("XDG_DATA_HOME", Path.join(dir, "xdg data"))
      System.delete_env("XDG_STATE_HOME")

      on_exit(fn ->
        System.delete_env("HAL_C2_MC_HOME")
        System.delete_env("XDG_DATA_HOME")
      end)

      [{service, unit}, {timer, schedule}] = Service.reaper(:systemd)
      assert Path.basename(service) == "hal-c2-openshell-#{OpenShell.instance()}-reap.service"
      assert Path.basename(timer) == "hal-c2-openshell-#{OpenShell.instance()}-reap.timer"
      assert Path.basename(timer) == Service.reap_name(:timer)

      lines = String.split(unit, "\n")
      assert "Type=oneshot" in lines
      [exec] = for "ExecStart=" <> argv <- lines, do: argv
      root = HalC2.Service.quote_value(OpenShell.root())
      assert String.ends_with?(exec, " hal_c2.openshell reap --root #{root}")
      assert ~s(Environment=HAL_C2_MC_HOME="#{Path.join(dir, "mc dir")}") in lines

      # Every XDG base, overridden or not, so the user manager's own cannot move it.
      assert ~s(Environment=XDG_DATA_HOME="#{Path.join(dir, "xdg data")}") in lines

      assert "Environment=XDG_STATE_HOME=#{Path.join(HalC2.Paths.user_home(), ".local/state")}" in lines

      assert "OnUnitActiveSec=1min" in String.split(schedule, "\n")
      assert schedule =~ "WantedBy=timers.target"

      # A unit from before the reaper is not current, so install repairs it.
      File.mkdir_p!(Path.dirname(Service.unit_path(:systemd)))
      File.write!(Service.unit_path(:systemd), Service.render(:systemd, @state))
      assert %{"installed" => true, "current" => false} = Service.status(@state)
    end

    test "a unit that is not loaded is already stopped", %{log: log} do
      Storage.service_state(log, "not-loaded", true)
      assert :ok = Service.stop()
      assert :ok = Service.uninstall()
    end

    test "a stop that fails leaves the unit in place", %{log: log} do
      assert :ok = Service.install(@state)
      Storage.service_state(log, "stop-fails", true)

      assert {:error, _} = Service.stop()
      assert {:error, _} = Service.uninstall()
      assert File.exists?(Service.unit_path(:systemd))
    end

    test "uninstall stops a gateway whose unit file is already gone", %{log: log} do
      assert :ok = Service.install(@state)
      File.rm!(Service.unit_path(:systemd))
      File.rm!(log)

      assert :ok = Service.uninstall()

      assert Storage.service_calls(log) == [
               "systemctl --user stop #{Service.name(:systemd)}",
               "systemctl --user disable --now #{Service.reap_name(:timer)}"
             ]

      refute File.exists?(Path.join(Path.dirname(log), "active"))
    end

    test "a systemd without a user manager is refused before anything is written", %{log: log} do
      Storage.service_state(log, "no-user-manager", true)
      assert {:error, "[user-manager-unavailable] " <> _} = Service.install(@state)
      refute File.exists?(Service.unit_path(:systemd))
      assert Storage.service_calls(log) == []
    end
  end

  describe "launchd" do
    setup do
      Application.put_env(:hal_c2, :service_platform, {:unix, :darwin})
      :ok
    end

    test "the plist is well formed and runs the gateway with its environment" do
      state = %{@state | "driver" => "docker", "socket" => "/Users/me/.docker/run/docker.sock"}
      plist = Service.render(:launchd, state)

      {doc, _} = apply(:xmerl_scan, :string, [String.to_charlist(plist), [quiet: true]])
      dict = dict(xpath(doc, "/plist/dict"))

      assert dict["Label"] == Service.name(:launchd)
      # launchd's own environment (`launchctl setenv`) would reach the gateway otherwise.
      assert dict["ProgramArguments"] == Config.command(OpenShell.gateway_bin("0.1.7"))
      assert ["/usr/bin/env", "-i" | _] = dict["ProgramArguments"]
      refute Map.has_key?(dict, "EnvironmentVariables")
      assert dict["WorkingDirectory"] == OpenShell.root()
      assert dict["Umask"] == 63
      assert dict["RunAtLoad"] == true
      assert dict["KeepAlive"] == %{"SuccessfulExit" => false}
      assert dict["StandardErrorPath"] == OpenShell.log_path()
    end

    test "install bootstraps the agent, uninstall boots it out", %{log: log} do
      assert :ok = Service.install(@state)
      path = Service.unit_path(:launchd)
      assert path =~ "Library/LaunchAgents/#{Service.name(:launchd)}.plist"

      uid = HalC2.Service.uid()

      [{reaper, plist}] = Service.reaper(:launchd)

      assert Storage.service_calls(log) == [
               "launchctl bootout gui/#{uid}/#{Service.name(:launchd)}",
               "launchctl bootstrap gui/#{uid} #{path}",
               "launchctl bootout gui/#{uid}/#{Service.reap_name(:launchd)}",
               "launchctl bootstrap gui/#{uid} #{reaper}"
             ]

      {doc, _} = apply(:xmerl_scan, :string, [String.to_charlist(plist), [quiet: true]])
      dict = dict(xpath(doc, "/plist/dict"))
      assert dict["Label"] == "io.github.halc2.openshell.#{OpenShell.instance()}.reap"
      assert dict["Label"] == Service.reap_name(:launchd)
      assert Path.basename(reaper) == Service.reap_name(:launchd) <> ".plist"
      assert dict["StartInterval"] == 60
      root = OpenShell.root()

      assert ["hal_c2.openshell", "reap", "--root", ^root] =
               Enum.take(dict["ProgramArguments"], -4)

      assert Map.has_key?(dict["EnvironmentVariables"], "XDG_DATA_HOME")

      File.rm!(log)
      assert :ok = Service.uninstall()
      refute File.exists?(path)
      refute File.exists?(reaper)

      assert Storage.service_calls(log) == [
               "launchctl bootout gui/#{uid}/#{Service.name(:launchd)}",
               "launchctl bootout gui/#{uid}/#{Service.reap_name(:launchd)}"
             ]

      refute File.exists?(Path.join(Path.dirname(log), "loaded"))
    end

    test "an agent that is not loaded is already stopped" do
      assert :ok = Service.stop()
      assert :ok = Service.uninstall()
    end

    test "a bootout that fails is an error, and leaves the agent and its plist", %{log: log} do
      assert :ok = Service.install(@state)
      Storage.service_state(log, "stop-fails", true)

      assert {:error, message} = Service.stop()
      assert message =~ "Boot-out failed: 5"
      assert {:error, _} = Service.uninstall()
      assert {:error, _} = Service.install(@state)
      assert File.exists?(Service.unit_path(:launchd))
      assert %{"running" => true} = Service.status(@state)
    end

    test "uninstall boots out an agent whose plist is already gone", %{log: log} do
      assert :ok = Service.install(@state)
      File.rm!(Service.unit_path(:launchd))
      File.rm!(log)

      assert :ok = Service.uninstall()

      assert Storage.service_calls(log) == [
               "launchctl bootout gui/#{HalC2.Service.uid()}/#{Service.name(:launchd)}",
               "launchctl bootout gui/#{HalC2.Service.uid()}/#{Service.reap_name(:launchd)}"
             ]

      refute File.exists?(Path.join(Path.dirname(log), "loaded"))
    end
  end

  for platform <- [{:unix, :linux}, {:unix, :darwin}] do
    test "a unit by this home's name that another home wrote is left alone (#{elem(platform, 1)})",
         %{log: log, tmp_dir: dir} do
      Application.put_env(:hal_c2, :service_platform, unquote(Macro.escape(platform)))
      manager = Service.manager()
      name = Service.name(manager)

      # Another home's unit, under this home's name.
      FakeOpenShell.put_env(home: Path.join(dir, "other"))
      refute Service.name(manager) == name
      other = Service.render(manager, @state)
      FakeOpenShell.put_env(home: Path.join(dir, "mc dir"))
      File.mkdir_p!(Path.dirname(Service.unit_path(manager)))
      File.write!(Service.unit_path(manager), other)

      assert %{"installed" => true, "foreign" => true, "running" => false, "current" => false} =
               Service.status(@state)

      for result <- [
            Service.install(@state),
            Service.start(),
            Service.stop(),
            Service.uninstall()
          ] do
        assert {:error, "[unit-not-ours] " <> _} = result
      end

      assert Storage.service_calls(log) == []
      assert File.read!(Service.unit_path(manager)) == other

      File.rm!(Service.unit_path(manager))
      assert :ok = Service.install(@state)
      assert %{"foreign" => false, "current" => true} = Service.status(@state)
    end
  end

  for platform <- [{:unix, :linux}, {:unix, :darwin}] do
    test "a reaper by this home's name that another home wrote is left alone (#{elem(platform, 1)})",
         %{log: log, tmp_dir: dir} do
      Application.put_env(:hal_c2, :service_platform, unquote(Macro.escape(platform)))
      manager = Service.manager()
      paths = Service.reaper_paths(manager)

      # Another home's reaper, under this home's names.
      FakeOpenShell.put_env(home: Path.join(dir, "other"))
      refute Service.reaper_paths(manager) == paths
      others = for {_, unit} <- Service.reaper(manager), do: unit
      FakeOpenShell.put_env(home: Path.join(dir, "mc dir"))

      for {path, unit} <- Enum.zip(paths, others) do
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, unit)
      end

      for result <- [Service.install(@state), Service.stop(), Service.uninstall()] do
        assert {:error, "[unit-not-ours] " <> message} = result
        assert message =~ "another home's reaper"
      end

      assert Storage.service_calls(log) == []
      refute File.exists?(Service.unit_path(manager))
      assert for(path <- paths, do: File.read!(path)) == others

      for path <- paths, do: File.rm!(path)
      assert :ok = Service.install(@state)
      assert %{"foreign" => false, "current" => true} = Service.status(@state)

      # Its own gateway with another home's reaper beside it is not this home's.
      File.write!(hd(paths), hd(others))

      assert %{"installed" => true, "foreign" => true, "current" => false} =
               Service.status(@state)
    end
  end

  test "two homes' reapers have names of their own", %{tmp_dir: dir} do
    names = fn ->
      for manager <- [:systemd, :timer, :launchd], do: Service.reap_name(manager)
    end

    mine = names.()
    FakeOpenShell.put_env(home: Path.join(dir, "other"))
    assert Enum.all?(Enum.zip(mine, names.()), fn {a, b} -> a != b end)
  end

  test "no service manager means no service" do
    Application.put_env(:hal_c2, :service_platform, {:win32, :nt})
    assert {:error, _} = Service.install(@state)
    assert %{"installed" => false} = Service.status(@state)
  end

  defp xpath(doc, path), do: hd(apply(:xmerl_xpath, :string, [String.to_charlist(path), doc]))

  # A plist value as Elixir terms.
  defp dict(element) do
    element
    |> children()
    |> Enum.chunk_every(2)
    |> Map.new(fn [key, value] -> {text(key), value(value)} end)
  end

  defp value({:xmlElement, :string, _, _, _, _, _, _, _, _, _, _} = e), do: text(e)

  defp value({:xmlElement, :integer, _, _, _, _, _, _, _, _, _, _} = e),
    do: String.to_integer(text(e))

  defp value({:xmlElement, true, _, _, _, _, _, _, _, _, _, _}), do: true
  defp value({:xmlElement, false, _, _, _, _, _, _, _, _, _, _}), do: false

  defp value({:xmlElement, :array, _, _, _, _, _, _, _, _, _, _} = e),
    do: Enum.map(children(e), &value/1)

  defp value({:xmlElement, :dict, _, _, _, _, _, _, _, _, _, _} = e), do: dict(e)

  defp children({:xmlElement, _, _, _, _, _, _, _, content, _, _, _}),
    do: Enum.filter(content, &(elem(&1, 0) == :xmlElement))

  defp text({:xmlElement, _, _, _, _, _, _, _, content, _, _, _}),
    do:
      content
      |> Enum.map(fn {:xmlText, _, _, _, value, _} -> List.to_string(value) end)
      |> Enum.join()
end
