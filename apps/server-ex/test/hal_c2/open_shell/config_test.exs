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
    # Clients are trusted by a CA of their own, not the one that signed the gateway's certificate.
    assert toml =~ ~s(client_ca_path = "#{Path.join(OpenShell.pki_dir(), "client-ca.crt")}")
    assert toml =~ ~s(guest_tls_ca = "#{Path.join(OpenShell.pki_dir(), "ca.crt")}")
    assert toml =~ "[openshell.drivers.podman]\n"
    # A review bounds its disk through driver config; 0.1.7 refuses it otherwise.
    assert toml =~ "allow_driver_config = true\n"
    assert toml =~ "enable_bind_mounts = false\n"
    assert toml =~ "sandbox_pids_limit = 512\n"
    assert Config.pids_limit() < 2048
  end

  test "images are pinned by digest" do
    toml =
      Config.render(%{
        port: 1,
        driver: "docker",
        socket: "/Users/me/.docker/run/docker.sock",
        network: "bridge"
      })

    for key <- ~w(default_image sandbox_runtime_image supervisor_image) do
      assert [_, ref] = Regex.run(~r/^#{key} = "([^"]+)"$/m, toml)
      assert ref =~ ~r/@sha256:[0-9a-f]{64}\z/
    end
  end

  test "each home's gateway keeps its sandboxes apart from another home's", %{tmp_dir: dir} do
    render = fn driver ->
      Config.render(%{
        port: 1,
        driver: driver,
        socket: "/run/user/1000/#{driver}.sock",
        network: if(driver == "docker", do: "bridge")
      })
    end

    scope = "hal-c2-" <> OpenShell.instance()
    assert render.("docker") =~ ~s(\nsandbox_label = "#{scope}"\n)
    assert render.("podman") =~ ~s(\nnetwork_name = "#{scope}"\n)
    refute render.("podman") =~ "sandbox_label"

    FakeOpenShell.put_env(home: Path.join(dir, "other"))
    refute render.("docker") =~ scope
    refute render.("podman") =~ scope
  end

  # On Docker Desktop the supervisors' host network is the VM's, where the gateway's
  # loopback is not; over a bridge they reach it as `host.docker.internal`.
  test "Docker's supervisors reach the gateway on the network the platform chose" do
    docker = fn network ->
      Config.render(%{port: 1, driver: "docker", socket: "/d.sock", network: network})
    end

    assert docker.("bridge") =~ ~s(\nsupervisor_network_mode = "bridge"\n)
    # The gateway still listens on loopback only; Desktop forwards the name to it.
    assert docker.("bridge") =~ ~s(bind_address = "127.0.0.1:1"\n)
    refute docker.("bridge") =~ "grpc_endpoint"

    refute Config.render(%{port: 1, driver: "podman", socket: "/p.sock"}) =~
             "supervisor_network_mode"

    # No silent default: OpenShell's would leave a Mac's sandboxes unable to start, and
    # the host network leaves rootless Docker's unable to reach the gateway.
    assert_raise FunctionClauseError, fn -> docker.(nil) end
    assert_raise FunctionClauseError, fn -> docker.("host") end
  end

  # As sqlx-sqlite 0.9 parses it: the filename ends at the first `?`, then is
  # percent-decoded.
  test "the database URL names the home's database, whatever its path", %{tmp_dir: dir} do
    FakeOpenShell.put_env(home: Path.join(dir, "mc%20home?x=1#y"))
    ["--db-url", "sqlite:" <> url] = Enum.take(Config.args(), -2)
    [file, "mode=rwc"] = String.split(url, "?", parts: 2)
    assert URI.decode(file) == OpenShell.db_path()
  end

  test "a path with quotes or control characters stays one TOML string" do
    toml = Config.render(%{port: 1, driver: "podman", socket: ~s(/run/a"b\\c\nd)})
    assert toml =~ ~S(socket_path = "/run/a\"b\\c\u000Ad") <> "\n"
  end

  # OpenShell's `OPENSHELL_*` variables override `gateway.toml`, and its drivers read
  # `DOCKER_HOST` and `CONTAINER_HOST`: the gateway inherits none of the caller's.
  test "the gateway runs with its own environment and none of the caller's", %{tmp_dir: dir} do
    bin = Path.join(dir, "gateway")
    File.write!(bin, "#!/bin/sh\nenv\necho \"args: $*\"\n")
    File.chmod!(bin, 0o755)

    inherited =
      for var <- ~w(OPENSHELL_PODMAN_SOCKET OPENSHELL_BIND_ADDRESS OPENSHELL_SERVER_PORT
                    OPENSHELL_SANDBOX_RUNTIME_IMAGE OPENSHELL_SUPERVISOR_IMAGE
                    OPENSHELL_ENABLE_MTLS_AUTH OPENSHELL_OTLP_ENDPOINT OPENSHELL_OCSF_JSON
                    OTEL_EXPORTER_OTLP_ENDPOINT DOCKER_HOST CONTAINER_HOST),
          do: {var, "inherited"}

    [exe | args] = Config.command(bin, ["--x"])

    {out, 0} =
      System.cmd(exe, args,
        env: [{"OPENSHELL_TELEMETRY_ENABLED", "true"}, {"HOME", "/elsewhere"} | inherited]
      )

    env =
      for line <- String.split(out, "\n"),
          [k, v] <- [String.split(line, "=", parts: 2)],
          into: %{},
          do: {k, v}

    for {var, _} <- inherited, do: refute(Map.has_key?(env, var), var)

    pinned = Map.new(Config.environment())
    assert Map.take(env, Map.keys(pinned)) == pinned
    assert pinned["OPENSHELL_TELEMETRY_ENABLED"] == "false"
    assert pinned["OPENSHELL_DISABLE_TLS"] == "false"
    assert pinned["OPENSHELL_ENABLE_OPERATOR_AUTH"] == "false"
    assert pinned["HOME"] |> String.starts_with?(OpenShell.root())
    assert pinned["XDG_CONFIG_HOME"] |> String.starts_with?(OpenShell.root())
    assert out =~ "args: --x"
  end
end
