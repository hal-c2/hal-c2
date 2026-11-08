defmodule HalC2.OpenShell.InstallTest do
  # The MC's home, the platform facts and the service manager come from the app env.
  use ExUnit.Case, async: false

  alias HalC2.OpenShell
  alias HalC2.OpenShell.Install
  alias HalC2.OpenShell.Manifest
  alias HalC2.OpenShell.Service
  alias HalC2.Test.FakeOpenShell
  alias HalC2.Test.Storage

  @moduletag :tmp_dir

  @facts %{
    os: :linux,
    arch: "x86_64",
    glibc: {2, 39},
    kernel: {6, 8},
    landlock: true,
    runtime: %{
      kind: :podman,
      socket: "/run/user/1000/podman/podman.sock",
      owner_uid: 1000,
      uid: 1000,
      reachable: true,
      version: "5.2.1",
      rootless: true
    }
  }

  setup %{tmp_dir: dir} do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    log = Storage.fake_service_manager(bin)

    FakeOpenShell.put_env(
      home: Path.join(dir, "mc"),
      openshell_facts: @facts,
      service_platform: {:unix, :linux},
      service_user_home: Path.join(dir, "user"),
      systemctl_command: Path.join(bin, "systemctl"),
      loginctl_command: Path.join(bin, "loginctl"),
      launchctl_command: Path.join(bin, "launchctl")
    )

    control = Path.join(dir, "control")
    FakeOpenShell.queue_certificates(control)
    %{log: log, control: control, archives: Path.join(dir, "archives")}
  end

  defp release(%{control: control, archives: archives}, version),
    do: FakeOpenShell.release(control, archives, version)

  defdelegate tar(dir, name, entries), to: FakeOpenShell

  defp sha256(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  defp install(context, version, opts \\ []) do
    {release, archive} = release(context, version)
    Install.install(opts ++ [release: release, archive: archive, smoke: fn _ -> :ok end])
  end

  defp mode(path), do: File.stat!(path).mode |> Bitwise.band(0o777)

  defp owned, do: %{OpenShell.owner_label() => OpenShell.owner()}

  # The gateway trusts `client-ca.crt` for clients: the MC's certificate comes from
  # it, and the gateway's own certificate does not.
  defp assert_client_authority do
    pki = OpenShell.pki_dir()
    ca = Path.join(pki, "ca.crt")
    client_ca = Path.join(pki, "client-ca.crt")

    assert File.read!(client_ca) != File.read!(ca)
    assert FakeOpenShell.signed_by?(Path.join([pki, "client", "tls.crt"]), client_ca)
    refute FakeOpenShell.signed_by?(Path.join([pki, "client", "tls.crt"]), ca)
    assert FakeOpenShell.signed_by?(Path.join([pki, "server", "tls.crt"]), ca)
    refute FakeOpenShell.signed_by?(Path.join([pki, "server", "tls.crt"]), client_ca)
    assert File.read!(OpenShell.config_path()) =~ ~s(client_ca_path = "#{client_ca}")
    assert Path.wildcard(Path.join(OpenShell.root(), "**/ca.key"), match_dot: true) == []
  end

  describe "extract/2" do
    test "takes an archive holding only the gateway binary", %{tmp_dir: dir} do
      for name <- [~c"openshell-gateway", ~c"./openshell-gateway"] do
        archive = tar(Path.join(dir, "a"), "good.tar.gz", [{name, "#!/bin/sh\n"}])
        out = Path.join(dir, "out-#{System.unique_integer([:positive])}")
        File.mkdir_p!(out)

        assert {:ok, bin} = Install.extract(archive, out)
        assert File.read!(bin) == "#!/bin/sh\n"
        assert mode(bin) == 0o755
      end
    end

    test "refuses anything else in it, a link, or a path out of the directory", %{tmp_dir: dir} do
      target = Path.join(dir, "elsewhere")
      File.write!(target, "x")
      link = Path.join(dir, "link")
      File.ln_s!(target, link)

      for entries <- [
            [{~c"openshell-gateway", "a"}, {~c"README", "b"}],
            [{~c"openshell-gateway", to_charlist(link)}],
            [{~c"gateway", "a"}],
            [{~c"../openshell-gateway", "a"}],
            [{~c"bin/openshell-gateway", "a"}]
          ] do
        archive = tar(Path.join(dir, "a"), "bad.tar.gz", entries)
        out = Path.join(dir, "out")

        assert {:error, "[bad-archive]" <> _} = Install.extract(archive, out)
        refute File.exists?(Path.join(dir, "openshell-gateway"))
        File.rm_rf!(out)
      end
    end

    test "verify/2 takes only the pinned hash", %{tmp_dir: dir} do
      archive = tar(dir, "g.tar.gz", [{~c"openshell-gateway", "a"}])
      assert :ok = Install.verify(archive, sha256(archive))
      assert {:error, "[hash-mismatch]" <> _} = Install.verify(archive, String.duplicate("0", 64))
    end
  end

  describe "install/1" do
    test "a fresh install issues owner-only keys, deletes the CA key and starts the unit", ctx do
      assert {:ok, state} = install(ctx, "0.1.7")

      assert %{"mode" => "managed", "version" => "0.1.7", "driver" => "podman", "previous" => nil} =
               state

      assert state["endpoint"] == "https://127.0.0.1:#{state["port"]}"
      assert OpenShell.state() == state

      pki = OpenShell.pki_dir()
      refute File.exists?(Path.join(pki, "ca.key"))
      assert Path.wildcard(Path.join(OpenShell.root(), "**/ca.key"), match_dot: true) == []
      assert mode(pki) == 0o700
      assert mode(Path.join([pki, "client", "tls.key"])) == 0o600
      assert mode(Path.join([pki, "server", "tls.key"])) == 0o600
      assert mode(Path.join([pki, "jwt", "signing.pem"])) == 0o600
      assert mode(Path.join(pki, "ca.crt")) == 0o644
      assert mode(Path.join(pki, "client-ca.crt")) == 0o644
      assert mode(OpenShell.config_path()) == 0o600
      assert mode(OpenShell.gateway_bin("0.1.7")) == 0o755

      assert File.read!(Service.unit_path(:systemd)) == Service.render(:systemd, state)

      assert Storage.service_calls(ctx.log) == [
               "systemctl --user daemon-reload",
               "systemctl --user enable hal-c2-openshell.service",
               "systemctl --user restart hal-c2-openshell.service",
               "systemctl --user enable --now hal-c2-openshell-reap.timer"
             ]

      assert_client_authority()

      calls = File.read!(Path.join(ctx.control, "calls"))
      assert calls =~ "generate-certs --output-dir"
      assert calls =~ "config preflight -- --config"

      assert File.ls!(Path.join(OpenShell.root(), "staging")) == []
    end

    test "a failed preflight or a wrong hash installs nothing", ctx do
      File.write!(Path.join(ctx.control, "preflight"), "1")
      assert {:error, message} = install(ctx, "0.1.7")
      assert message =~ "config preflight"
      assert message =~ "failed (1)"
      assert OpenShell.state() == nil
      refute File.exists?(Service.unit_path(:systemd))

      File.rm!(Path.join(ctx.control, "preflight"))
      {release, archive} = release(ctx, "0.1.7")

      assert {:error, "[hash-mismatch]" <> _} =
               Install.install(
                 release: %{release | sha256: String.duplicate("a", 64)},
                 archive: archive
               )

      assert OpenShell.state() == nil
      assert Storage.service_calls(ctx.log) == []
    end

    test "an unsupported machine is refused before anything is fetched", ctx do
      FakeOpenShell.put_env(openshell_facts: %{@facts | runtime: nil})
      assert {:error, "[podman-missing]" <> _} = install(ctx, "0.1.7")
      refute File.exists?(OpenShell.root())
    end

    test "an update whose gateway fails its check puts the previous one back", ctx do
      assert {:ok, old} = install(ctx, "0.1.6")
      old_config = File.read!(OpenShell.config_path())
      old_ca = File.read!(Path.join(OpenShell.pki_dir(), "ca.crt"))
      File.mkdir_p!(Path.dirname(OpenShell.db_path()))
      File.write!(OpenShell.db_path(), "old database")

      smoke = fn
        %{"version" => "0.1.7"} -> {:error, "[version-mismatch] boom."}
        _ -> :ok
      end

      assert {:error, message} = install(ctx, "0.1.7", smoke: smoke)
      assert message =~ "[version-mismatch] boom."
      assert message =~ "The previous gateway (0.1.6) is back in place."

      assert OpenShell.state() == old
      assert File.read!(OpenShell.config_path()) == old_config
      assert File.read!(Path.join(OpenShell.pki_dir(), "ca.crt")) == old_ca
      assert File.read!(OpenShell.db_path()) == "old database"
      assert File.read!(Service.unit_path(:systemd)) == Service.render(:systemd, old)
      assert File.exists?(OpenShell.gateway_bin("0.1.6"))

      assert {:ok, new} = install(ctx, "0.1.7")
      assert %{"version" => "0.1.7", "previous" => "0.1.6", "port" => port} = new
      assert port == old["port"]
      assert File.read!(Service.unit_path(:systemd)) =~ OpenShell.gateway_bin("0.1.7")
      assert File.exists?(Path.join(OpenShell.backup_dir("0.1.6"), "openshell.db"))
      # The certificates carry over an update; only `rotate` replaces them.
      assert File.read!(Path.join(OpenShell.pki_dir(), "ca.crt")) == old_ca
    end

    # Found by prop/hal_c2/openshell_install_prop_test.exs.
    test "a failed fresh install leaves no database behind", ctx do
      smoke = fn _ ->
        File.write!(OpenShell.db_path(), "migrated")
        {:error, "[smoke] no."}
      end

      assert {:error, message} = install(ctx, "0.1.7", smoke: smoke)
      assert message =~ "Nothing was installed."
      refute File.exists?(OpenShell.db_path())
    end

    # Found by prop/hal_c2/openshell_install_prop_test.exs.
    test "the dev run over a service install removes the service", ctx do
      {:ok, _} = install(ctx, "0.1.6")
      assert {:ok, %{"mode" => "foreground"}} = install(ctx, "0.1.7", service: false)
      refute File.exists?(Service.unit_path(:systemd))

      assert "systemctl --user disable --now hal-c2-openshell.service" in Storage.service_calls(
               ctx.log
             )
    end

    test "status names what needs attention", ctx do
      assert %{"problems" => ["not-installed"], "supported" => true} = Install.status()

      {:ok, _} = install(ctx, Manifest.version())

      # Nothing answers on the port the fake gateway's unit was given.
      assert %{"problems" => ["gateway-unreachable"], "mode" => "managed"} = Install.status()

      File.write!(Service.unit_path(:systemd), "edited")
      assert "service-outdated" in Install.status()["problems"]

      FakeOpenShell.put_env(openshell_facts: %{@facts | landlock: false})
      assert %{"supported" => false, "problems" => ["landlock-missing" | _]} = Install.status()
    end
  end

  describe "rotate/1" do
    test "issues new certificates and restarts the gateway on them", ctx do
      {:ok, _} = install(ctx, "0.1.7")
      old_ca = File.read!(Path.join(OpenShell.pki_dir(), "ca.crt"))
      old_client_ca = File.read!(Path.join(OpenShell.pki_dir(), "client-ca.crt"))

      FakeOpenShell.queue_certificates(ctx.control)
      File.write!(ctx.log, "")

      assert {:ok, _} = Install.rotate(smoke: fn _ -> :ok end)
      refute File.read!(Path.join(OpenShell.pki_dir(), "ca.crt")) == old_ca
      refute File.read!(Path.join(OpenShell.pki_dir(), "client-ca.crt")) == old_client_ca
      refute File.exists?(Path.join(OpenShell.pki_dir(), "ca.key"))
      assert_client_authority()
      assert mode(Path.join([OpenShell.pki_dir(), "client", "tls.key"])) == 0o600
      assert "systemctl --user restart hal-c2-openshell.service" in Storage.service_calls(ctx.log)
    end

    test "a failed check keeps the old certificates", ctx do
      {:ok, _} = install(ctx, "0.1.7")
      old_ca = File.read!(Path.join(OpenShell.pki_dir(), "ca.crt"))
      old_client_ca = File.read!(Path.join(OpenShell.pki_dir(), "client-ca.crt"))
      FakeOpenShell.queue_certificates(ctx.control)

      # The new certificates fail their check; the old ones pass it again.
      Process.put(:smoke_calls, 0)

      smoke = fn _ ->
        calls = Process.put(:smoke_calls, Process.get(:smoke_calls) + 1)
        if calls == 0, do: {:error, "nope."}, else: :ok
      end

      assert {:error, message} = Install.rotate(smoke: smoke)
      assert message =~ "back in place"
      assert File.read!(Path.join(OpenShell.pki_dir(), "ca.crt")) == old_ca
      assert File.read!(Path.join(OpenShell.pki_dir(), "client-ca.crt")) == old_client_ca
    end

    test "there is nothing to rotate without a gateway this MC runs" do
      assert {:error, "[not-installed]" <> _} = Install.rotate()
      OpenShell.put_state(%{"mode" => "external", "endpoint" => "https://127.0.0.1:1"})
      assert {:error, "[external]" <> _} = Install.rotate()
    end
  end

  describe "the dev run" do
    test "stages the gateway and runs it in the foreground without inherited telemetry", ctx do
      assert {:ok, %{"mode" => "foreground"}} = install(ctx, "0.1.7", service: false)
      assert Storage.service_calls(ctx.log) == []
      refute File.exists?(Service.unit_path(:systemd))

      assert {:ok, line} = Install.foreground_command()

      {out, 0} =
        System.cmd("sh", ["-c", line],
          env: [
            {"OTEL_EXPORTER_OTLP_ENDPOINT", "http://collector"},
            {"OPENSHELL_DISABLE_TLS", "true"},
            {"OPENSHELL_PODMAN_SOCKET", "/run/elsewhere.sock"},
            {"DOCKER_HOST", "unix:///run/elsewhere.sock"}
          ]
        )

      assert out =~ "OPENSHELL_TELEMETRY_ENABLED=false"
      assert out =~ "OPENSHELL_DISABLE_TLS=false"
      refute out =~ "OTEL_EXPORTER_OTLP_ENDPOINT"
      refute out =~ "elsewhere"
      assert out =~ "args: --config #{OpenShell.config_path()} --db-url sqlite:"
    end

    test "only a foreground install has a foreground command", ctx do
      assert {:error, "[not-installed]" <> _} = Install.foreground_command()
      {:ok, _} = install(ctx, "0.1.7")
      assert {:error, "[managed]" <> _} = Install.foreground_command()
    end
  end

  describe "draining" do
    setup ctx do
      # The installed gateway is the fake, with its certificates in the MC's pki dir.
      gateway = FakeOpenShell.start(OpenShell.pki_dir())

      OpenShell.put_state(%{
        "mode" => "foreground",
        "version" => "0.1.6",
        "port" => gateway.port,
        "endpoint" => gateway.endpoint,
        "driver" => "podman"
      })

      FakeOpenShell.put_sandbox(gateway, "review-1", owned())
      FakeOpenShell.put_sandbox(gateway, "theirs", %{"team" => "x"})
      Map.put(ctx, :gateway, gateway)
    end

    test "an update refuses while this MC's sandboxes run, and drain deletes only those", ctx do
      assert {:error, "[sandboxes-running] 1 of this MC's" <> _} =
               install(ctx, "0.1.7", service: false)

      assert OpenShell.state()["version"] == "0.1.6"

      assert Map.keys(FakeOpenShell.sandboxes(ctx.gateway)) |> Enum.sort() == [
               "review-1",
               "theirs"
             ]

      assert {:ok, %{"version" => "0.1.7"}} = install(ctx, "0.1.7", service: false, drain: true)
      assert Map.keys(FakeOpenShell.sandboxes(ctx.gateway)) == ["theirs"]
    end

    test "uninstall refuses the same way, then removes the gateway's files", ctx do
      assert {:error, "[sandboxes-running]" <> _} = Install.uninstall()
      assert File.exists?(OpenShell.root())

      assert :ok = Install.uninstall(drain: true)
      assert Map.keys(FakeOpenShell.sandboxes(ctx.gateway)) == ["theirs"]
      refute File.exists?(OpenShell.root())
      refute File.exists?(Path.dirname(OpenShell.db_path()))
    end
  end

  describe "smoke/2" do
    defp smoke_gateway(opts) do
      gateway = FakeOpenShell.start(OpenShell.pki_dir(), opts)

      state = %{
        "mode" => "foreground",
        "version" => Manifest.version(),
        "port" => gateway.port,
        "endpoint" => gateway.endpoint,
        "driver" => "podman",
        "socket" => "/run/user/1000/podman/podman.sock"
      }

      {gateway, state}
    end

    test "passes a gateway that is what the MC pinned and keeps sandboxes in", _ctx do
      test = self()

      exec = fn command, io ->
        send(test, {:probe, command})
        io.exit.(0)
      end

      {gateway, state} = smoke_gateway(exec: exec, notify: test)
      assert :ok = Install.smoke(state)

      assert_received {:probe, ["bash", "-c", probe]}
      assert probe =~ "/run/user/1000/podman/podman.sock"
      assert probe =~ "/var/run/docker.sock"
      assert probe =~ "/dev/tcp/$h/#{gateway.port}"
      assert_received {:openshell_request, "CreateWorkspace", "hal-c2"}
      assert FakeOpenShell.sandboxes(gateway) == %{}
    end

    test "fails a sandbox that reaches the runtime or the gateway, and deletes it" do
      exec = fn _command, io ->
        io.stdout.("socket /var/run/docker.sock\n")
        io.exit.(1)
      end

      {gateway, state} = smoke_gateway(exec: exec)

      assert {:error,
              "[sandbox-not-isolated] A sandbox workload reached what it must not: socket /var/run/docker.sock"} =
               Install.smoke(state)

      assert FakeOpenShell.sandboxes(gateway) == %{}
    end

    test "fails another version, or an identity that is an operator" do
      {_, state} = smoke_gateway(version: "0.0.1")
      assert {:error, "[version-mismatch]" <> _} = Install.smoke(state, isolation: false)

      File.rm_rf!(OpenShell.pki_dir())
      {_, state} = smoke_gateway(roles: ["openshell-operator"])
      assert {:error, "[operator-identity]" <> _} = Install.smoke(state, isolation: false)
    end

    test "fails a gateway that does not answer" do
      state = %{"mode" => "foreground", "endpoint" => "https://127.0.0.1:#{Install.free_port()}"}
      FakeOpenShell.stranger(OpenShell.pki_dir())
      assert {:error, "[gateway-unreachable]" <> _} = Install.smoke(state)
    end

    test "a gateway that answers plaintext gRPC is caught" do
      {:ok, store} = Agent.start_link(fn -> %{} end)

      {:ok, server} =
        Bandit.start_link(
          plug: {FakeOpenShell.Plug, %{store: store}},
          scheme: :http,
          ip: {127, 0, 0, 1},
          port: 0,
          startup_log: false
        )

      {:ok, {_, port}} = ThousandIsland.listener_info(server)
      assert Install.plaintext_answers?("https://127.0.0.1:#{port}")

      {gateway, _} = smoke_gateway([])
      refute Install.plaintext_answers?(gateway.endpoint)
      refute Install.plaintext_answers?("https://127.0.0.1:#{Install.free_port()}")
    end
  end

  describe "reuse/2" do
    test "refuses plaintext and malformed endpoints" do
      assert {:error, "[plaintext-refused]" <> _} = Install.reuse("http://127.0.0.1:1", [])
      assert {:error, "[bad-endpoint]" <> _} = Install.reuse("127.0.0.1:1", [])
      assert OpenShell.state() == nil
    end

    test "uses a gateway the user runs once it passes the checks", ctx do
      exec = fn _command, io -> io.exit.(0) end
      gateway = FakeOpenShell.start(Path.join(ctx.tmp_dir, "theirs"), exec: exec)

      assert {:ok, %{"mode" => "external", "endpoint" => endpoint}} =
               Install.reuse(gateway.endpoint, gateway.credentials)

      assert endpoint == gateway.endpoint
      assert OpenShell.state()["mode"] == "external"
      assert mode(Path.join([OpenShell.pki_dir(), "client", "tls.key"])) == 0o600

      assert {:error, "[external]" <> _} = install(ctx, "0.1.7")
      assert Storage.service_calls(ctx.log) == []

      # Forgetting it leaves the gateway, and the user's sandboxes on it, alone.
      FakeOpenShell.put_sandbox(gateway, "theirs", %{"team" => "x"})
      assert :ok = Install.uninstall()
      assert OpenShell.state() == nil
      refute File.exists?(OpenShell.pki_dir())
      assert Map.keys(FakeOpenShell.sandboxes(gateway)) == ["theirs"]
    end

    test "a gateway the given CA does not vouch for is not recorded", ctx do
      gateway = FakeOpenShell.start(Path.join(ctx.tmp_dir, "theirs"))
      other = FakeOpenShell.stranger(Path.join(ctx.tmp_dir, "other"))

      assert {:error, "[gateway-unreachable]" <> _} =
               Install.reuse(gateway.endpoint, Keyword.put(gateway.credentials, :ca, other[:ca]))

      assert OpenShell.state() == nil
      refute File.exists?(OpenShell.pki_dir())
    end

    test "is refused while this MC runs its own", ctx do
      {:ok, _} = install(ctx, "0.1.7")
      assert {:error, "[managed]" <> _} = Install.reuse("https://127.0.0.1:1", [])
    end

    test "a gateway that holds another environment's sandboxes is refused and left alone",
         ctx do
      exec = fn _command, io -> io.exit.(0) end
      gateway = FakeOpenShell.start(Path.join(ctx.tmp_dir, "theirs"), exec: exec, notify: self())
      FakeOpenShell.put_sandbox(gateway, "elsewhere", %{OpenShell.owner_label() => "env-b"})

      assert {:error, "[shared-gateway] 1 other HAL-C2 environment(s)" <> _ = message} =
               Install.reuse(gateway.endpoint, gateway.credentials)

      assert message =~ "does not share a gateway"
      assert OpenShell.state() == nil
      refute File.exists?(OpenShell.pki_dir())
      # It made no sandbox there and touched none.
      refute_received {:openshell_request, "CreateSandbox", _}
      refute_received {:openshell_request, "DeleteSandbox", _}
      assert Map.keys(FakeOpenShell.sandboxes(gateway)) == ["elsewhere"]
    end

    test "a refused gateway leaves the gateway the MC already uses in place", ctx do
      exec = fn _command, io -> io.exit.(0) end
      mine = FakeOpenShell.start(Path.join(ctx.tmp_dir, "mine"), exec: exec)
      assert {:ok, state} = Install.reuse(mine.endpoint, mine.credentials)
      ca = File.read!(Path.join(OpenShell.pki_dir(), "ca.crt"))

      shared = FakeOpenShell.start(Path.join(ctx.tmp_dir, "shared"), exec: exec)
      FakeOpenShell.put_sandbox(shared, "elsewhere", %{OpenShell.owner_label() => "env-b"})

      assert {:error, "[shared-gateway]" <> _} =
               Install.reuse(shared.endpoint, shared.credentials)

      assert OpenShell.state() == state
      assert File.read!(Path.join(OpenShell.pki_dir(), "ca.crt")) == ca
      refute File.exists?(OpenShell.pki_dir() <> ".previous")

      # A bad file name leaves it too.
      assert {:error, "Cannot read" <> _} = Install.reuse(shared.endpoint, [])
      assert OpenShell.state() == state
      assert File.read!(Path.join(OpenShell.pki_dir(), "ca.crt")) == ca
    end

    test "status reports a gateway that became shared, and check fails", ctx do
      exec = fn _command, io -> io.exit.(0) end
      gateway = FakeOpenShell.start(Path.join(ctx.tmp_dir, "theirs"), exec: exec)
      assert {:ok, state} = Install.reuse(gateway.endpoint, gateway.credentials)

      assert %{"problems" => [], "sharedWith" => []} = Install.status()
      assert :ok = Install.smoke(state)

      FakeOpenShell.put_sandbox(gateway, "elsewhere", %{OpenShell.owner_label() => "env-b"})
      assert %{"problems" => ["gateway-shared"], "sharedWith" => ["env-b"]} = Install.status()
      assert {:error, "[shared-gateway]" <> _} = Install.smoke(state)

      # Forgetting it still works, and still leaves theirs alone.
      assert :ok = Install.uninstall()
      assert Map.keys(FakeOpenShell.sandboxes(gateway)) == ["elsewhere"]
    end
  end
end
