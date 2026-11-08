defmodule HalC2.OpenShell.ConfigTest do
  # The paths come from the app env's `:home`.
  use ExUnit.Case, async: false

  alias HalC2.OpenShell
  alias HalC2.OpenShell.Config
  alias HalC2.Test.FakeOpenShell

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    FakeOpenShell.put_env(home: Path.join(dir, "mc"))
  end

  test "the gateway listens on loopback with mTLS required and operators off" do
    toml =
      Config.render(%{
        port: 17_670,
        driver: "podman",
        socket: "/run/user/1000/podman/podman.sock"
      })

    assert toml =~ ~s(bind_address = "127.0.0.1:17670"\n)
    assert toml =~ "disable_tls = false\n"
    assert toml =~ "allow_unauthenticated_users = false\n"
    assert toml =~ "[openshell.gateway.mtls_auth]\nenabled = true\noperator_enabled = false\n"
    assert toml =~ ~s(client_ca_path = "#{Path.join(OpenShell.pki_dir(), "ca.crt")}")
    assert toml =~ "[openshell.drivers.podman]\n"
    assert toml =~ "allow_driver_config = false\n"
    assert toml =~ "enable_bind_mounts = false\n"
    assert toml =~ "sandbox_pids_limit = 512\n"
    assert Config.pids_limit() < 2048
  end

  test "images are pinned by digest" do
    toml = Config.render(%{port: 1, driver: "docker", socket: "/run/user/1000/docker.sock"})

    for key <- ~w(default_image sandbox_runtime_image supervisor_image) do
      assert [_, ref] = Regex.run(~r/^#{key} = "([^"]+)"$/m, toml)
      assert ref =~ ~r/@sha256:[0-9a-f]{64}\z/
    end
  end

  test "a path with quotes or control characters stays one TOML string" do
    toml = Config.render(%{port: 1, driver: "podman", socket: ~s(/run/a"b\\c\nd)})
    assert toml =~ ~S(socket_path = "/run/a\"b\\c\u000Ad") <> "\n"
  end

  test "telemetry is off and nothing it could be sent to is inherited" do
    env = Map.new(Config.environment())
    assert env["OPENSHELL_TELEMETRY_ENABLED"] == "false"
    assert env["OPENSHELL_DISABLE_TLS"] == "false"
    assert env["OPENSHELL_ENABLE_OPERATOR_AUTH"] == "false"
    assert env["XDG_CONFIG_HOME"] |> String.starts_with?(OpenShell.root())

    unset = Config.unset_environment()

    for var <- ~w(OPENSHELL_OTLP_ENDPOINT OPENSHELL_OTLP_OCSF_ENDPOINT OPENSHELL_OCSF_JSON
                  OTEL_EXPORTER_OTLP_ENDPOINT OTEL_TRACES_EXPORTER OPENSHELL_TELEMETRY_ENDPOINT),
        do: assert(var in unset, var)

    assert MapSet.disjoint?(MapSet.new(unset), MapSet.new(Map.keys(env)))
  end
end
