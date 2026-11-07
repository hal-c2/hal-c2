defmodule HalC2.ServiceTest do
  # The service manager is chosen through the app env.
  use ExUnit.Case, async: false

  alias HalC2.Service
  alias HalC2.Test.Storage

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    log = Storage.fake_service_manager(bin)

    env =
      [
        home: Path.join(dir, "mc"),
        service_platform: {:unix, :linux},
        service_user_home: Path.join(dir, "user"),
        systemctl_command: Path.join(bin, "systemctl"),
        loginctl_command: Path.join(bin, "loginctl")
      ]

    previous = for {key, _} <- env, do: {key, Application.fetch_env(:hal_c2, key)}
    for {key, value} <- env, do: Application.put_env(:hal_c2, key, value)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:hal_c2, key, value)
          :error -> Application.delete_env(:hal_c2, key)
        end
      end
    end)

    %{log: log}
  end

  test "lingering that is only switched off is switched on before the service changes",
       %{log: log} do
    assert {:ok, %{"current" => true, "problems" => []}} = Service.install()

    assert [
             "loginctl enable-linger --no-ask-password " <> _,
             "systemctl --user daemon-reload",
             "systemctl --user enable hal-c2.service",
             "systemctl --user restart hal-c2.service"
           ] = Storage.service_calls(log)
  end

  test "a systemd that cannot run user services is refused before anything is written",
       %{log: log} do
    Storage.service_state(log, "no-user-manager", true)
    assert {:error, "[user-manager-unavailable] " <> _} = Service.install()

    Storage.service_state(log, "no-user-manager", false)
    Storage.service_state(log, "no-logind", true)
    assert {:error, "[linger-unavailable] " <> _} = Service.install()

    assert Storage.service_calls(log) == []
    refute Service.status()["installed"]
  end

  test "status names every problem in the order systemd would hit them", %{log: log} do
    {:ok, _} = Service.install()
    for state <- ~w(linger enabled active), do: Storage.service_state(log, state, false)
    Service.mark_restart_pending("1.4.0")

    assert %{"installed" => true, "current" => false, "problems" => problems} = Service.status()

    assert problems == [
             "linger-disabled",
             "service-disabled",
             "service-stopped",
             "restart-pending"
           ]

    # The service questions are not asked of a user manager that does not answer.
    Storage.service_state(log, "no-user-manager", true)

    assert Service.status()["problems"] ==
             ["user-manager-unavailable", "linger-disabled", "restart-pending"]
  end

  test "restart starts the installed service again and clears restart-pending", %{log: log} do
    assert {:ok, false} = Service.restart()

    {:ok, _} = Service.install()
    Service.mark_restart_pending("1.4.0")
    assert "restart-pending" in Service.status()["problems"]

    File.rm!(log)
    assert {:ok, "Background service restarted."} = Service.command(["restart"])
    assert "systemctl --user restart hal-c2.service" in Storage.service_calls(log)
    assert %{"current" => true, "problems" => []} = Service.status()
  end

  test "a start clears restart-pending only on the version it names or a later one" do
    pending = fn -> "restart-pending" in Service.status()["problems"] end
    {:ok, _} = Service.install()

    Service.mark_restart_pending("1.4.0")
    Service.started("1.3.9")
    assert pending.()
    Service.started("1.4.0")
    refute pending.()

    Service.mark_restart_pending("1.4.0")
    Service.started("1.10.0")
    refute pending.()

    # A marker no version compares with stands only for what is installed, which runs.
    Service.mark_restart_pending("latest")
    Service.started("1.3.0")
    refute pending.()
  end

  # The programs a leaving MC kept, under the home it runs on now.
  defp kept_program(thread) do
    {:ok, sub} = HalC2.Subprocess.start(["sh", "-c", "while read l; do :; done"], durable: thread)
    HalC2.Orchestration.Recovery.leaving(true)
    :detached = HalC2.Subprocess.stop(sub)
    HalC2.Orchestration.Recovery.leaving(false)
    {sub.durable.dir, HalC2.Subprocess.os_pid(sub)}
  end

  describe "uninstall" do
    setup %{tmp_dir: dir} do
      Application.put_env(:hal_c2, :durable_programs, true)
      on_exit(fn -> Application.put_env(:hal_c2, :durable_programs, false) end)
      %{other: Path.join(dir, "other")}
    end

    test "stops the programs of the home the unit ran on, not this command's",
         %{tmp_dir: dir, other: other} do
      {:ok, _} = Service.install()
      {service_dir, service_pid} = kept_program("t1")

      # The command runs on another home, where an MC in the foreground keeps its own.
      Application.put_env(:hal_c2, :home, other)
      {own_dir, own_pid} = kept_program("t2")

      assert {:ok, "Background service removed."} = Service.command(["uninstall"])
      refute File.exists?(service_dir)
      assert HalC2.Subprocess.Orphans.gone?(service_pid)
      assert HalC2.Subprocess.Durable.attachable?(own_dir)
      refute HalC2.Subprocess.Orphans.gone?(own_pid)

      HalC2.Subprocess.Durable.stop(own_dir)
      assert String.starts_with?(service_dir, Path.join(dir, "mc"))
    end

    test "reads the home from a LaunchAgent too", %{tmp_dir: dir, other: other} do
      Application.put_env(:hal_c2, :service_platform, {:unix, :darwin})
      Application.put_env(:hal_c2, :launchctl_command, Path.join([dir, "bin", "launchctl"]))
      on_exit(fn -> Application.delete_env(:hal_c2, :launchctl_command) end)

      {:ok, %{"unitPath" => path}} = Service.install()
      assert String.ends_with?(path, ".plist")
      {service_dir, service_pid} = kept_program("t1")
      Application.put_env(:hal_c2, :home, other)

      assert {:ok, "Background service removed."} = Service.command(["uninstall"])
      refute File.exists?(service_dir)
      assert HalC2.Subprocess.Orphans.gone?(service_pid)
    end

    test "with no unit installed stops nothing", %{log: log} do
      {own_dir, own_pid} = kept_program("t1")

      assert {:ok, "Background service removed."} = Service.command(["uninstall"])
      assert HalC2.Subprocess.Durable.attachable?(own_dir)
      refute HalC2.Subprocess.Orphans.gone?(own_pid)
      refute File.exists?(log)

      HalC2.Subprocess.Durable.stop(own_dir)
    end

    # T3 Code's units, and the Node server's, kept no programs through a restart.
    test "a unit that names no home, as T3 Code's did, stops nothing" do
      {:ok, %{"unitPath" => path}} = Service.install()
      File.write!(path, String.replace(File.read!(path), ~r/^StandardOutput=.*$/m, ""))
      {own_dir, own_pid} = kept_program("t1")

      assert {:ok, "Background service removed."} = Service.command(["uninstall"])

      refute HalC2.Subprocess.Orphans.gone?(own_pid)
      HalC2.Subprocess.Durable.stop(own_dir)
    end
  end
end
