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
               "systemctl --user enable hal-c2-openshell.service",
               "systemctl --user restart hal-c2-openshell.service"
             ]

      assert %{"installed" => true, "running" => true, "current" => true} = Service.status(@state)
      assert %{"current" => false} = Service.status(%{@state | "version" => "0.1.8"})

      assert :ok = Service.stop()
      assert %{"running" => false} = Service.status(@state)

      File.rm!(log)
      assert :ok = Service.uninstall()
      refute File.exists?(path)

      assert Storage.service_calls(log) == [
               "systemctl --user disable --now hal-c2-openshell.service",
               "systemctl --user daemon-reload"
             ]

      assert %{"installed" => false, "running" => false} = Service.status(@state)
      assert :ok = Service.uninstall()
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

      assert dict["Label"] == "io.github.halc2.openshell"
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
      assert path =~ "Library/LaunchAgents/io.github.halc2.openshell.plist"

      uid = HalC2.Service.uid()

      assert Storage.service_calls(log) == [
               "launchctl bootout gui/#{uid}/io.github.halc2.openshell",
               "launchctl bootstrap gui/#{uid} #{path}"
             ]

      File.rm!(log)
      assert :ok = Service.uninstall()
      refute File.exists?(path)

      assert Storage.service_calls(log) == [
               "launchctl bootout gui/#{uid}/io.github.halc2.openshell"
             ]
    end
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
