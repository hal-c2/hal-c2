defmodule HalC2.Steps.Platform.OpenShell do
  @moduledoc """
  Steps for `features/mc/platform/openshell.feature`. The machine is the facts
  `HalC2.OpenShell.Platform` decides from (`:openshell_facts`), the gateway's
  release is a shell script (`HalC2.Test.FakeOpenShell.release/3`), the service
  manager is the test's systemctl stand-in, and a gateway that answers is
  `HalC2.Test.FakeOpenShell`. The check after an install or rotation is the
  `:smoke` seam, run against the fake by its own scenarios.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.OpenShell
  alias HalC2.OpenShell.{Client, Config, Install, Manifest, Service}
  alias HalC2.Test.{FakeOpenShell, Mc, Storage}

  @podman %{
    kind: :podman,
    socket: "/run/user/1000/podman/podman.sock",
    owner_uid: 1000,
    uid: 1000,
    reachable: true,
    version: "5.2.1",
    rootless: true
  }

  @linux %{
    os: :linux,
    arch: "x86_64",
    glibc: {2, 39},
    kernel: {6, 8},
    landlock: true,
    runtime: @podman
  }

  @machines %{
    "is an Intel Mac" => %{os: :darwin, arch: "x86_64", runtime: nil},
    "is Linux on riscv64" => %{@linux | arch: "riscv64"},
    "is Linux without Landlock" => %{@linux | landlock: false},
    "has no Podman" => %{@linux | runtime: nil},
    "runs Podman as root" => %{@linux | runtime: %{@podman | owner_uid: 0, rootless: false}},
    "names the root Docker daemon's socket" => %{
      @linux
      | runtime: %{
          @podman
          | kind: :docker,
            socket: "/var/run/docker.sock",
            owner_uid: 0,
            version: "28.1.0",
            rootless: false
        }
    }
  }

  step "a Linux machine with rootless Podman", context do
    dir = Mc.tmp_dir(context.mc, "openshell")
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    log = Storage.fake_service_manager(bin)

    FakeOpenShell.put_env(
      openshell_facts: @linux,
      service_platform: {:unix, :linux},
      service_user_home: Path.join(dir, "user"),
      systemctl_command: Path.join(bin, "systemctl"),
      loginctl_command: Path.join(bin, "loginctl"),
      launchctl_command: Path.join(bin, "launchctl")
    )

    control = Path.join(dir, "control")
    FakeOpenShell.queue_certificates(control)

    Map.put(context, :openshell, %{
      dir: dir,
      log: log,
      control: control,
      archives: Path.join(dir, "archives")
    })
  end

  step ~r/^a machine that (?<machine>.+)$/, %{args: [machine]} = context do
    put_facts(Map.fetch!(@machines, machine))
    context
  end

  step "the gateway rejects its configuration", context do
    File.write!(Path.join(context.openshell.control, "preflight"), "1")
    context
  end

  # --- installing -------------------------------------------------------------------

  step("the user installs OpenShell", context, do: installed(context, install(context)))

  step "the user installs OpenShell from an archive whose hash is not the pinned one", context do
    {release, archive} = release(context, Manifest.version())

    result =
      Install.install(release: %{release | sha256: String.duplicate("a", 64)}, archive: archive)

    installed(context, result)
  end

  step "the user installs OpenShell from an archive that also holds another file", context do
    archive =
      FakeOpenShell.tar(context.openshell.archives, "extra.tar.gz", [
        {~c"openshell-gateway", "#!/bin/sh\n"},
        {~c"README", "hello"}
      ])

    release = %{
      name: "openshell-gateway.tar.gz",
      url: "unused",
      sha256: :crypto.hash(:sha256, File.read!(archive)) |> Base.encode16(case: :lower),
      version: Manifest.version()
    }

    installed(context, Install.install(release: release, archive: archive))
  end

  step ~r/^OpenShell is installed(?: as a service)?$/, context do
    assert {:ok, _} = install(context)
    reset_calls(context)
    context
  end

  step "OpenShell 0.1.6 is installed and has a database", context do
    assert {:ok, old} = install(context, "0.1.6")
    File.mkdir_p!(Path.dirname(OpenShell.db_path()))
    File.write!(OpenShell.db_path(), "the 0.1.6 database")

    Map.put(context, :before, %{
      state: old,
      config: File.read!(OpenShell.config_path()),
      ca: ca(),
      unit: File.read!(Service.unit_path(:systemd))
    })
  end

  step "the user updates to OpenShell 0.1.7 and the new gateway fails its check", context do
    smoke = fn
      %{"version" => "0.1.7"} -> {:error, "[version-mismatch] The new gateway failed its check."}
      _ -> :ok
    end

    installed(context, install(context, "0.1.7", smoke: smoke))
  end

  step "the install is refused because {string}", %{args: [code]} = context do
    assert {:error, "[" <> rest} = context.result
    assert String.starts_with?(rest, code <> "]"), "got #{inspect(context.result)}"
    context
  end

  step "the install is refused because the preflight failed", context do
    assert {:error, message} = context.result
    assert message =~ "config preflight"
    context
  end

  # Certificates a refused install already issued stay for the next try, without the CA's key.
  step "no gateway is installed", context do
    assert OpenShell.state() == nil
    assert Path.wildcard(Path.join(OpenShell.root(), "**/ca.key"), match_dot: true) == []
    refute File.exists?(OpenShell.db_path())
    refute File.exists?(Service.unit_path(:systemd))
    context
  end

  step "the gateway runs as a service of the user's, on loopback", context do
    assert {:ok, state} = context.result
    assert %{"mode" => "managed", "version" => version, "port" => port} = state
    assert version == Manifest.version()
    assert state["endpoint"] == "https://127.0.0.1:#{port}"
    assert File.read!(OpenShell.config_path()) =~ ~s(bind_address = "127.0.0.1:#{port}")
    assert File.read!(Service.unit_path(:systemd)) == Service.render(:systemd, state)
    for {path, unit} <- Service.reaper(:systemd), do: assert(File.read!(path) == unit)

    assert Storage.service_calls(context.openshell.log) == [
             "systemctl --user daemon-reload",
             "systemctl --user enable hal-c2-openshell.service",
             "systemctl --user restart hal-c2-openshell.service",
             "systemctl --user enable --now hal-c2-openshell-reap.timer"
           ]

    context
  end

  step "its keys are readable by the user alone, and the CA's key is gone", context do
    pki = OpenShell.pki_dir()
    refute File.exists?(Path.join(pki, "ca.key"))
    assert mode(pki) == 0o700

    for key <- [["client", "tls.key"], ["server", "tls.key"], ["jwt", "signing.pem"]],
        do: assert(mode(Path.join([pki | key])) == 0o600)

    assert mode(OpenShell.config_path()) == 0o600
    context
  end

  step "the gateway accepts only mutual TLS, with no operator identity", context do
    config = File.read!(OpenShell.config_path())
    assert config =~ "disable_tls = false"
    assert config =~ "allow_unauthenticated_users = false"
    assert config =~ "operator_enabled = false"
    assert config =~ "pids_limit = #{Config.pids_limit()}"
    context
  end

  step "the gateway sends no telemetry", context do
    unit = File.read!(Service.unit_path(:systemd))
    # It starts from an empty environment, so no OTLP or OCSF endpoint reaches it.
    [exec] = for "ExecStart=" <> argv <- String.split(unit, "\n"), do: argv
    assert exec =~ ~r{\A/usr/bin/env -i }
    assert exec =~ " OPENSHELL_TELEMETRY_ENABLED=false "
    context
  end

  step "the MC's client certificate comes from a CA that is not the gateway's", context do
    assert_client_authority()
    context
  end

  step "the gateway is set to trust only that CA's certificates as clients", context do
    config = File.read!(OpenShell.config_path())
    assert config =~ ~s(client_ca_path = #{inspect(OpenShell.client_ca_path())})
    refute config =~ ~s(client_ca_path = #{inspect(Path.join(OpenShell.pki_dir(), "ca.crt"))})
    context
  end

  step "no CA's key is left", context do
    assert Path.wildcard(Path.join(OpenShell.root(), "**/ca.key"), match_dot: true) == []
    refute File.exists?(OpenShell.pki_dir() <> ".client")
    context
  end

  step "the MC's client certificate comes from a new CA of its own", context do
    assert {:ok, _} = context.result
    assert_client_authority()
    refute ca() == context.old_ca
    refute File.read!(OpenShell.client_ca_path()) == context.old_client_ca
    context
  end

  step "the user is told the previous gateway is back in place", context do
    assert {:error, message} = context.result
    assert message =~ "The previous gateway (0.1.6) is back in place."
    context
  end

  step "OpenShell 0.1.6 runs with its database, certificates and service as they were", context do
    before = context.before
    assert OpenShell.state() == before.state
    assert File.read!(OpenShell.config_path()) == before.config
    assert ca() == before.ca
    assert File.read!(OpenShell.db_path()) == "the 0.1.6 database"
    assert File.read!(Service.unit_path(:systemd)) == before.unit
    context
  end

  # --- draining ---------------------------------------------------------------------

  step "an OpenShell gateway this MC runs, with a sandbox of this MC's and one of someone else's",
       context do
    gateway = FakeOpenShell.start(OpenShell.pki_dir())

    OpenShell.put_state(%{
      "mode" => "foreground",
      "version" => "0.1.6",
      "port" => gateway.port,
      "endpoint" => gateway.endpoint,
      "driver" => "podman"
    })

    FakeOpenShell.put_sandbox(gateway, "review-1", %{OpenShell.owner_label() => OpenShell.owner()})

    FakeOpenShell.put_sandbox(gateway, "theirs", %{"team" => "x"})
    Map.put(context, :gateway, gateway)
  end

  step("the user updates OpenShell", context,
    do: installed(context, install(context, Manifest.version(), service: false))
  )

  step("the user updates OpenShell with a drain", context,
    do: installed(context, install(context, Manifest.version(), service: false, drain: true))
  )

  step "the update is refused because {string}", %{args: [code]} = context do
    assert {:error, "[" <> rest} = context.result
    assert String.starts_with?(rest, code <> "]"), "got #{inspect(context.result)}"
    assert OpenShell.state()["version"] == "0.1.6"

    assert Map.keys(FakeOpenShell.sandboxes(context.gateway)) |> Enum.sort() == [
             "review-1",
             "theirs"
           ]

    context
  end

  step "the update succeeds", context do
    assert {:ok, %{"version" => version}} = context.result
    assert version == Manifest.version()
    context
  end

  step "only the other sandbox remains", context do
    assert Map.keys(FakeOpenShell.sandboxes(context.gateway)) == ["theirs"]
    context
  end

  # --- rotating ---------------------------------------------------------------------

  step "the user rotates the gateway's certificates", context do
    context = new_certificates(context)
    installed(context, Install.rotate(smoke: fn _ -> :ok end))
  end

  step "the user rotates the gateway's certificates and the gateway fails its check", context do
    context = new_certificates(context)
    # The new certificates fail their check; the old ones pass it again.
    calls = :counters.new(1, [])

    smoke = fn _ ->
      :counters.add(calls, 1, 1)

      if :counters.get(calls, 1) == 1,
        do: {:error, "[smoke] The gateway failed its check."},
        else: :ok
    end

    installed(context, Install.rotate(smoke: smoke))
  end

  step "the gateway has new certificates, and the CA's key is gone", context do
    assert {:ok, _} = context.result
    refute ca() == context.old_ca
    refute File.exists?(Path.join(OpenShell.pki_dir(), "ca.key"))
    assert mode(Path.join([OpenShell.pki_dir(), "client", "tls.key"])) == 0o600
    context
  end

  step "the gateway's service restarted", context do
    assert "systemctl --user restart hal-c2-openshell.service" in Storage.service_calls(
             context.openshell.log
           )

    context
  end

  step "the user is told the previous certificates are back in place", context do
    assert {:error, message} = context.result
    assert message =~ "back in place"
    context
  end

  step "the gateway has its old certificates", context do
    assert ca() == context.old_ca
    context
  end

  # --- the check after start --------------------------------------------------------

  step "a gateway whose sandboxes can reach the container runtime's socket", context do
    exec = fn _command, io ->
      io.stdout.("socket /run/user/1000/podman/podman.sock\n")
      io.exit.(1)
    end

    smoke_gateway(context, exec: exec)
  end

  step "a gateway that gives the MC an operator's identity", context do
    smoke_gateway(context, roles: ["openshell-operator"])
  end

  step "the MC checks the gateway", context do
    Map.put(context, :result, Install.smoke(context.smoke_state))
  end

  step "the check fails because {string}", %{args: [code]} = context do
    assert {:error, "[" <> rest} = context.result
    assert String.starts_with?(rest, code <> "]"), "got #{inspect(context.result)}"
    context
  end

  step "the probe sandbox is deleted", context do
    assert FakeOpenShell.sandboxes(context.gateway) == %{}
    context
  end

  # --- a gateway the user runs ------------------------------------------------------

  step "a gateway the user runs, with its CA and a client certificate", context do
    exec = fn _command, io -> io.exit.(0) end

    gateway =
      FakeOpenShell.start(Path.join(context.openshell.dir, "theirs"), exec: exec, notify: self())

    FakeOpenShell.put_sandbox(gateway, "theirs", %{"team" => "x"})
    Map.put(context, :gateway, gateway)
  end

  step "the user points the MC at it", context do
    installed(context, Install.reuse(context.gateway.endpoint, context.gateway.credentials))
  end

  step "the user points the MC at a plaintext gateway", context do
    installed(context, Install.reuse("http://127.0.0.1:#{Install.free_port()}", []))
  end

  step "the MC refuses because {string}", %{args: [code]} = context do
    assert {:error, "[" <> rest} = context.result
    assert String.starts_with?(rest, code <> "]"), "got #{inspect(context.result)}"
    context
  end

  step "the MC uses that gateway without running one of its own", context do
    assert {:ok, %{"mode" => "external", "endpoint" => endpoint}} = context.result
    assert endpoint == context.gateway.endpoint
    assert mode(Path.join([OpenShell.pki_dir(), "client", "tls.key"])) == 0o600
    refute File.exists?(Service.unit_path(:systemd))
    assert Storage.service_calls(context.openshell.log) == []
    context
  end

  step "a gateway the user runs, with another HAL-C2 environment's sandbox on it", context do
    {context, gateway} = other_gateway(context, "theirs")
    Map.put(context, :gateway, gateway)
  end

  step "a second gateway with another HAL-C2 environment's sandbox on it", context do
    {context, second} = other_gateway(context, "second")
    Map.put(context, :second, second)
  end

  step "the user points the MC at the second gateway", context do
    installed(context, Install.reuse(context.second.endpoint, context.second.credentials))
  end

  step "the MC still uses the first gateway", context do
    assert OpenShell.state()["endpoint"] == context.gateway.endpoint
    assert Map.keys(FakeOpenShell.sandboxes(context.second)) == ["elsewhere"]
    context
  end

  step "the MC made no sandbox there and left the other environment's alone", context do
    refute_received {:openshell_request, "CreateSandbox", _}
    refute_received {:openshell_request, "DeleteSandbox", _}
    assert Map.has_key?(FakeOpenShell.sandboxes(context.gateway), "elsewhere")
    context
  end

  step "another HAL-C2 environment makes a sandbox on that gateway", context do
    flush_requests()

    FakeOpenShell.put_sandbox(context.gateway, "elsewhere", %{
      OpenShell.owner_label() => "env-b"
    })

    context
  end

  step "the MC connects but makes no sandbox there, and leaves the other environment's alone",
       context do
    assert context.status["sharedWith"] == ["env-b"]
    assert {:error, {:shared_gateway, ["env-b"]}} = Client.connect()
    refute_received {:openshell_request, "CreateSandbox", _}
    refute_received {:openshell_request, "DeleteSandbox", _}
    assert Map.has_key?(FakeOpenShell.sandboxes(context.gateway), "elsewhere")
    context
  end

  step "the user uninstalls OpenShell", context do
    Map.put(context, :result, Install.uninstall())
  end

  step "the MC forgets the gateway and leaves its sandboxes alone", context do
    assert :ok = context.result
    assert OpenShell.state() == nil
    refute File.exists?(OpenShell.pki_dir())
    assert Map.keys(FakeOpenShell.sandboxes(context.gateway)) == ["theirs"]
    context
  end

  step "the gateway's service is gone", context do
    assert :ok = context.result
    refute File.exists?(OpenShell.root())

    assert "systemctl --user disable --now hal-c2-openshell.service" in Storage.service_calls(
             context.openshell.log
           )

    context
  end

  # --- status and the dev run -------------------------------------------------------

  step "the user asks for OpenShell's status", context do
    Map.put(context, :status, Install.status())
  end

  step "the status says {string}", %{args: [problem]} = context do
    assert problem in context.status["problems"], "got #{inspect(context.status)}"
    context
  end

  step "a developer starts the gateway with the dev run", context do
    assert {:ok, %{"mode" => "foreground"}} = install(context, Manifest.version(), service: false)
    assert {:ok, line} = Install.foreground_command()

    {out, 0} =
      System.cmd("sh", ["-c", line],
        env: [
          {"OTEL_EXPORTER_OTLP_ENDPOINT", "http://collector"},
          {"OPENSHELL_DISABLE_TLS", "true"}
        ]
      )

    Map.put(context, :output, out)
  end

  step "the gateway runs in the foreground without telemetry it inherited", context do
    assert context.output =~ "OPENSHELL_TELEMETRY_ENABLED=false"
    assert context.output =~ "OPENSHELL_DISABLE_TLS=false"
    refute context.output =~ "OTEL_EXPORTER_OTLP_ENDPOINT"
    assert context.output =~ "args: --config #{OpenShell.config_path()}"
    context
  end

  step "no service of the gateway's is left", context do
    refute File.exists?(Service.unit_path(:systemd))

    assert "systemctl --user disable --now hal-c2-openshell.service" in Storage.service_calls(
             context.openshell.log
           )

    context
  end

  # --- helpers ----------------------------------------------------------------------

  defp put_facts(facts), do: FakeOpenShell.put_env(openshell_facts: facts)

  defp release(context, version),
    do: FakeOpenShell.release(context.openshell.control, context.openshell.archives, version)

  defp install(context, version \\ Manifest.version(), opts \\ []) do
    {release, archive} = release(context, version)
    Install.install(opts ++ [release: release, archive: archive, smoke: fn _ -> :ok end])
  end

  defp installed(context, result), do: Map.put(context, :result, result)

  defp reset_calls(context), do: File.write!(context.openshell.log, "")

  defp new_certificates(context) do
    old = ca()
    old_client = File.read!(OpenShell.client_ca_path())
    FakeOpenShell.queue_certificates(context.openshell.control)
    reset_calls(context)
    Map.merge(context, %{old_ca: old, old_client_ca: old_client})
  end

  # A gateway of the user's that holds a sandbox of another HAL-C2 environment.
  defp other_gateway(context, name) do
    exec = fn _command, io -> io.exit.(0) end

    gateway =
      FakeOpenShell.start(Path.join(context.openshell.dir, name), exec: exec, notify: self())

    FakeOpenShell.put_sandbox(gateway, "elsewhere", %{OpenShell.owner_label() => "env-b"})
    {context, gateway}
  end

  defp flush_requests do
    receive do
      {:openshell_request, _, _} -> flush_requests()
    after
      0 -> :ok
    end
  end

  # The client certificate is signed by the CA that gateway trusts as a client, not
  # by the gateway's own CA, and the gateway's certificate is the reverse.
  defp assert_client_authority do
    pki = OpenShell.pki_dir()
    ca = Path.join(pki, "ca.crt")
    client_ca = OpenShell.client_ca_path()
    client = Path.join([pki, "client", "tls.crt"])
    server = Path.join([pki, "server", "tls.crt"])

    refute File.read!(ca) == File.read!(client_ca)
    assert FakeOpenShell.signed_by?(client, client_ca)
    refute FakeOpenShell.signed_by?(client, ca)
    assert FakeOpenShell.signed_by?(server, ca)
    refute FakeOpenShell.signed_by?(server, client_ca)
  end

  defp smoke_gateway(context, opts) do
    gateway = FakeOpenShell.start(OpenShell.pki_dir(), opts)

    state = %{
      "mode" => "foreground",
      "version" => Manifest.version(),
      "port" => gateway.port,
      "endpoint" => gateway.endpoint,
      "driver" => "podman",
      "socket" => @podman.socket
    }

    Map.merge(context, %{gateway: gateway, smoke_state: state})
  end

  defp ca, do: File.read!(Path.join(OpenShell.pki_dir(), "ca.crt"))

  defp mode(path), do: File.stat!(path).mode |> Bitwise.band(0o777)
end
