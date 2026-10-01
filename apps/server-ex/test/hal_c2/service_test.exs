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
end
