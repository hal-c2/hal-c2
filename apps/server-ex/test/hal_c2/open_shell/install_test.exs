defmodule HalC2.OpenShell.InstallTest do
  # The MC's home, the platform facts and the service manager come from the app env.
  use ExUnit.Case, async: false

  alias HalC2.OpenShell
  alias HalC2.OpenShell.Client
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
    %{log: log, bin: bin, control: control, archives: Path.join(dir, "archives")}
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

  # The credential directories in the MC's OpenShell directory.
  defp credential_dirs, do: Path.wildcard(Path.join(OpenShell.root(), "pki*"))

  defp client_key,
    do: Path.join([OpenShell.credentials_dir(OpenShell.state()), "client", "tls.key"])

  # Something listening where the dev gateway would.
  defp listen(port) do
    {:ok, socket} = :gen_tcp.listen(port, ip: {127, 0, 0, 1}, reuseaddr: true)
    socket
  end

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
               "systemctl --user enable #{Service.name(:systemd)}",
               "systemctl --user restart #{Service.name(:systemd)}"
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

    test "an update whose gateway will not stop changes nothing, and takes no backup", ctx do
      assert {:ok, old} = install(ctx, "0.1.6")
      old_config = File.read!(OpenShell.config_path())
      old_ca = File.read!(Path.join(OpenShell.pki_dir(), "ca.crt"))
      File.mkdir_p!(Path.dirname(OpenShell.db_path()))
      File.write!(OpenShell.db_path(), "old database")
      File.write!(Path.join(ctx.bin, "stop-fails"), "")

      assert {:error, "[gateway-stop-failed]" <> _} = install(ctx, "0.1.7")
      assert OpenShell.state() == old
      assert File.read!(OpenShell.config_path()) == old_config
      assert File.read!(Path.join(OpenShell.pki_dir(), "ca.crt")) == old_ca
      assert File.read!(OpenShell.db_path()) == "old database"
      refute File.exists?(OpenShell.backup_dir("0.1.6"))

      FakeOpenShell.queue_certificates(ctx.control)
      assert {:error, "[gateway-stop-failed]" <> _} = Install.rotate(smoke: fn _ -> :ok end)
      assert File.read!(Path.join(OpenShell.pki_dir(), "ca.crt")) == old_ca
    end

    test "a failed update whose new gateway will not stop puts nothing back over it", ctx do
      assert {:ok, _} = install(ctx, "0.1.6")
      File.mkdir_p!(Path.dirname(OpenShell.db_path()))
      File.write!(OpenShell.db_path(), "old database")

      smoke = fn _ ->
        File.write!(Path.join(ctx.bin, "stop-fails"), "")
        {:error, "[smoke] no."}
      end

      assert {:error, message} = install(ctx, "0.1.7", smoke: smoke)
      assert message =~ "Stopping the new gateway failed too, so nothing was put back"
      backup = OpenShell.backup_dir("0.1.6")
      assert message =~ backup
      assert File.read!(Path.join(backup, "openshell.db")) == "old database"
    end

    for platform <- [{:unix, :linux}, {:unix, :darwin}] do
      test "nothing is changed or removed while the gateway will not stop (#{elem(platform, 1)})",
           ctx do
        assert {:ok, old} = install(ctx, "0.1.6")
        # The gateway runs under whichever service manager this is.
        Application.put_env(:hal_c2, :service_platform, unquote(platform))
        assert :ok = HalC2.OpenShell.Service.install(old)
        File.mkdir_p!(Path.dirname(OpenShell.db_path()))
        File.write!(OpenShell.db_path(), "old database")
        old_ca = File.read!(Path.join(OpenShell.pki_dir(), "ca.crt"))
        File.write!(Path.join(ctx.bin, "stop-fails"), "")

        assert {:error, "[gateway-stop-failed]" <> _} = install(ctx, "0.1.7")
        FakeOpenShell.queue_certificates(ctx.control)
        assert {:error, "[gateway-stop-failed]" <> _} = Install.rotate(smoke: fn _ -> :ok end)
        assert {:error, "[gateway-stop-failed]" <> _} = Install.uninstall()

        assert OpenShell.state() == old
        assert File.read!(Path.join(OpenShell.pki_dir(), "ca.crt")) == old_ca
        assert File.read!(OpenShell.db_path()) == "old database"
        assert File.exists?(OpenShell.gateway_bin("0.1.6"))
        assert File.exists?(Service.unit_path(Service.manager()))
      end
    end

    test "uninstall stops a gateway whose unit file is gone before removing its files", ctx do
      assert {:ok, _} = install(ctx, "0.1.7")
      File.rm!(Service.unit_path(:systemd))
      File.write!(ctx.log, "")

      assert :ok = Install.uninstall()
      assert "systemctl --user stop #{Service.name(:systemd)}" in Storage.service_calls(ctx.log)
      refute File.exists?(Path.join(ctx.bin, "active"))
      refute File.exists?(OpenShell.root())
    end

    test "the gateway a failed update puts back is checked for its own version", ctx do
      assert {:ok, old} = install(ctx, "0.1.6")

      # What answers on the gateway's port is still 0.1.6, so the new one fails its
      # check and the old one passes it.
      exec = fn _command, io -> io.exit.(0) end
      gateway = FakeOpenShell.start(OpenShell.pki_dir(), version: "0.1.6", exec: exec)
      old = %{old | "port" => gateway.port, "endpoint" => gateway.endpoint}
      OpenShell.put_state(old)
      {release, archive} = release(ctx, "0.1.7")

      assert {:error, message} = Install.install(release: release, archive: archive)
      assert message =~ "[version-mismatch]"
      assert message =~ "The previous gateway (0.1.6) is back in place."
      assert OpenShell.state() == old
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

      assert "systemctl --user disable #{Service.name(:systemd)}" in Storage.service_calls(
               ctx.log
             )
    end

    test "status names what needs attention", ctx do
      assert %{"problems" => ["not-installed"], "supported" => true} = Install.status()

      {:ok, _} = install(ctx, Manifest.version())

      # Nothing answers on the port the fake gateway's unit was given.
      assert %{"problems" => ["gateway-unreachable"], "mode" => "managed"} = Install.status()

      unit = Service.unit_path(:systemd)
      File.write!(unit, File.read!(unit) <> "# edited\n")
      assert "service-outdated" in Install.status()["problems"]

      FakeOpenShell.put_env(openshell_facts: %{@facts | landlock: false})
      assert %{"supported" => false, "problems" => ["landlock-missing" | _]} = Install.status()
    end
  end

  describe "two homes on one machine" do
    # Two MCs under one user share the service manager; each home has its own unit.
    defp home(ctx, name), do: FakeOpenShell.put_env(home: Path.join(ctx.tmp_dir, name))

    test "each installs, updates and uninstalls only its own gateway", ctx do
      assert {:ok, a} = install(ctx, "0.1.6")
      a_name = Service.name(:systemd)
      a_unit = Service.unit_path(:systemd)
      a_text = File.read!(a_unit)
      a_root = OpenShell.root()

      home(ctx, "mc-b")
      assert Service.name(:systemd) != a_name
      assert Service.unit_path(:systemd) != a_unit
      File.write!(ctx.log, "")
      FakeOpenShell.queue_certificates(ctx.control)

      assert {:ok, _} = install(ctx, "0.1.6")
      assert OpenShell.root() != a_root
      assert {:ok, _} = install(ctx, "0.1.7", drain: true)
      assert :ok = Install.uninstall()

      calls = Storage.service_calls(ctx.log)
      assert "systemctl --user restart #{Service.name(:systemd)}" in calls
      assert "systemctl --user disable #{Service.name(:systemd)}" in calls
      for call <- calls, do: refute(call =~ a_name, call)

      assert File.read!(a_unit) == a_text
      assert File.exists?(a_root)

      home(ctx, "mc")
      assert OpenShell.state() == a
      assert Service.status(a)["installed"]
    end

    test "a unit under this home's name that it did not write is left alone", ctx do
      assert {:ok, state} = install(ctx, "0.1.7")
      unit = Service.unit_path(:systemd)
      other = String.replace(File.read!(unit), OpenShell.root(), "/elsewhere/openshell")
      File.write!(unit, other)
      File.write!(ctx.log, "")

      for result <- [install(ctx, "0.1.7"), Install.rotate(), Install.uninstall(force: true)] do
        assert {:error, "[unit-not-ours] " <> _} = result
      end

      assert Storage.service_calls(ctx.log) == []
      assert File.read!(unit) == other
      assert OpenShell.state() == state
      assert "service-not-ours" in Install.status()["problems"]
      refute "service-outdated" in Install.status()["problems"]
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

      assert "systemctl --user restart #{Service.name(:systemd)}" in Storage.service_calls(
               ctx.log
             )
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

    test "a dev gateway is not changed while it runs, and uses new ones once restarted", ctx do
      {:ok, state} = install(ctx, "0.1.7", service: false)
      old_ca = File.read!(Path.join(OpenShell.pki_dir(), "ca.crt"))
      FakeOpenShell.queue_certificates(ctx.control)
      running = listen(state["port"])

      assert {:error, "[gateway-running]" <> _} = Install.rotate()
      assert {:error, "[gateway-running]" <> _} = install(ctx, "0.1.7", service: false)
      assert {:error, "[gateway-running]" <> _} = Install.uninstall()
      assert File.read!(Path.join(OpenShell.pki_dir(), "ca.crt")) == old_ca
      assert OpenShell.state() == state

      :gen_tcp.close(running)

      assert {:ok, "OpenShell's certificates were replaced. Start the dev gateway again" <> _} =
               HalC2.OpenShell.Command.command(["rotate"])

      refute File.read!(Path.join(OpenShell.pki_dir(), "ca.crt")) == old_ca
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
        "mode" => "managed",
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

    test "the isolation check's leftover sandboxes are deleted without a drain", ctx do
      FakeOpenShell.put_sandbox(
        ctx.gateway,
        "halc2-smoke-0",
        Map.merge(owned(), Install.probe_labels())
      )

      assert {:error, "[sandboxes-running] 1 of this MC's" <> _} =
               install(ctx, "0.1.7", service: false)

      refute Map.has_key?(FakeOpenShell.sandboxes(ctx.gateway), "halc2-smoke-0")

      FakeOpenShell.put_sandbox(
        ctx.gateway,
        "halc2-smoke-1",
        owned() |> Map.merge(Install.probe_labels())
      )

      assert :ok = Install.uninstall(drain: true)
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

  describe "draining a gateway that cannot be asked" do
    setup ctx do
      # It listens, but trusts other certificates than the MC holds.
      gateway = FakeOpenShell.start(Path.join(ctx.tmp_dir, "elsewhere"))
      FakeOpenShell.stranger(OpenShell.pki_dir())
      FakeOpenShell.put_sandbox(gateway, "review-1", owned())

      OpenShell.put_state(%{
        "mode" => "managed",
        "version" => "0.1.6",
        "port" => gateway.port,
        "endpoint" => gateway.endpoint,
        "driver" => "podman"
      })

      Map.put(ctx, :gateway, gateway)
    end

    test "is refused, even with drain, unless forced", ctx do
      for opts <- [[], [drain: true]] do
        assert {:error, "[sandboxes-unknown]" <> _} =
                 install(ctx, "0.1.7", [service: false] ++ opts)

        assert {:error, "[sandboxes-unknown]" <> _} = Install.uninstall(opts)
        assert OpenShell.state()["version"] == "0.1.6"
      end

      assert {:ok, %{"version" => "0.1.7"}} = install(ctx, "0.1.7", service: false, force: true)
      assert Map.keys(FakeOpenShell.sandboxes(ctx.gateway)) == ["review-1"]
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

      assert_received {:probe, ["bash", "-c", _script, _, port | rest]}
      assert port == to_string(gateway.port)
      {sockets, ["--" | hosts]} = Enum.split_while(rest, &(&1 != "--"))
      assert "/run/user/1000/podman/podman.sock" in sockets
      assert "/var/run/docker.sock" in sockets
      assert "host.openshell.internal" in hosts
      assert "host.containers.internal" in hosts
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

    test "a check whose sandbox cannot be deleted fails, and says which is left" do
      for {code, exec} <- [
            {"[probe-cleanup-failed]", fn _command, io -> io.exit.(0) end},
            {"[sandbox-not-isolated]", fn _command, io -> io.exit.(1) end}
          ] do
        File.rm_rf!(OpenShell.pki_dir())
        {gateway, state} = smoke_gateway(exec: exec, delete: :unspecified)

        assert {:error, message} = Install.smoke(state)
        assert String.starts_with?(message, code)

        assert [%{metadata: %{name: name, labels: labels}}] =
                 Map.values(FakeOpenShell.sandboxes(gateway))

        assert message =~ "[probe-cleanup-failed] The isolation check's sandbox #{name}"
        assert labels["halc2.github.io/purpose"] == "openshell-check"
      end
    end

    test "a check deletes what earlier checks left before it starts, or does not start" do
      test = self()
      exec = fn _command, io -> io.exit.(0) end
      {gateway, state} = smoke_gateway(exec: exec, notify: test)
      left = Map.merge(owned(), Install.probe_labels())
      FakeOpenShell.put_sandbox(gateway, "halc2-smoke-old", left)
      FakeOpenShell.put_sandbox(gateway, "review-1", owned())

      assert :ok = Install.smoke(state)
      assert Map.keys(FakeOpenShell.sandboxes(gateway)) == ["review-1"]

      File.rm_rf!(OpenShell.pki_dir())
      {gateway, state} = smoke_gateway(exec: exec, notify: test, delete: :unspecified)
      FakeOpenShell.put_sandbox(gateway, "halc2-smoke-old", left)
      flush_requests()

      assert {:error, "[probe-cleanup-failed] The isolation check's sandbox halc2-smoke-old" <> _} =
               Install.smoke(state)

      refute_received {:openshell_request, "CreateSandbox", _}
    end

    test "the isolation probe tries the gateway by the endpoint's own name" do
      # A gateway on IPv6 loopback only: 127.0.0.1 does not reach it, its name does.
      {:ok, socket} = :gen_tcp.listen(0, [:inet6, ip: {0, 0, 0, 0, 0, 0, 0, 1}])
      {:ok, port} = :inet.port(socket)

      [bash | args] =
        Install.isolation_probe(%{"endpoint" => "https://localhost:#{port}", "socket" => nil})

      {out, 1} = System.cmd(bash, args, stderr_to_stdout: true)
      assert out =~ "gateway via localhost"
      refute out =~ "gateway via 127.0.0.1"

      # A name is an argument, never shell.
      [bash | args] =
        Install.isolation_probe(%{"endpoint" => "https://a$(touch${IFS}x):#{port}"})

      assert "a$(touch${IFS}x)" in args
      assert {_, 1} = System.cmd(bash, args, cd: System.tmp_dir!(), stderr_to_stdout: true)
      refute File.exists?(Path.join(System.tmp_dir!(), "x"))
      :gen_tcp.close(socket)
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

  defp flush_requests do
    receive do
      {:openshell_request, _, _} -> flush_requests()
    after
      0 -> :ok
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
      assert mode(client_key()) == 0o600

      assert {:error, "[external]" <> _} = install(ctx, "0.1.7")
      assert Storage.service_calls(ctx.log) == []

      # Forgetting it leaves the gateway, and the user's sandboxes on it, alone.
      FakeOpenShell.put_sandbox(gateway, "theirs", %{"team" => "x"})
      assert :ok = Install.uninstall()
      assert OpenShell.state() == nil
      assert credential_dirs() == []
      assert Map.keys(FakeOpenShell.sandboxes(gateway)) == ["theirs"]
    end

    test "a gateway the given CA does not vouch for is not recorded", ctx do
      gateway = FakeOpenShell.start(Path.join(ctx.tmp_dir, "theirs"))
      other = FakeOpenShell.stranger(Path.join(ctx.tmp_dir, "other"))

      assert {:error, "[gateway-unreachable]" <> _} =
               Install.reuse(gateway.endpoint, Keyword.put(gateway.credentials, :ca, other[:ca]))

      assert OpenShell.state() == nil
      assert credential_dirs() == []
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
      assert credential_dirs() == []
      # It made no sandbox there and touched none.
      refute_received {:openshell_request, "CreateSandbox", _}
      refute_received {:openshell_request, "DeleteSandbox", _}
      assert Map.keys(FakeOpenShell.sandboxes(gateway)) == ["elsewhere"]
    end

    test "a refused gateway leaves the gateway the MC already uses in place", ctx do
      exec = fn _command, io -> io.exit.(0) end
      mine = FakeOpenShell.start(Path.join(ctx.tmp_dir, "mine"), exec: exec)
      assert {:ok, state} = Install.reuse(mine.endpoint, mine.credentials)
      ca_path = OpenShell.credentials(state)[:ca]
      ca = File.read!(ca_path)

      shared = FakeOpenShell.start(Path.join(ctx.tmp_dir, "shared"), exec: exec)
      FakeOpenShell.put_sandbox(shared, "elsewhere", %{OpenShell.owner_label() => "env-b"})

      assert {:error, "[shared-gateway]" <> _} =
               Install.reuse(shared.endpoint, shared.credentials)

      assert OpenShell.state() == state
      assert File.read!(ca_path) == ca
      assert credential_dirs() == [OpenShell.credentials_dir(state)]

      # A bad file name leaves it too.
      assert {:error, "Cannot read" <> _} = Install.reuse(shared.endpoint, [])
      assert OpenShell.state() == state
      assert File.read!(ca_path) == ca
      assert credential_dirs() == [OpenShell.credentials_dir(state)]
    end

    test "the MC keeps using its gateway until the next one has passed its checks", ctx do
      test = self()

      mine =
        FakeOpenShell.start(Path.join(ctx.tmp_dir, "mine"), exec: fn _, io -> io.exit.(0) end)

      assert {:ok, state} = Install.reuse(mine.endpoint, mine.credentials)

      # While the next gateway is checked, a reader of the state still gets this one.
      exec = fn _command, io ->
        send(test, {:during_check, OpenShell.endpoint(), Client.connect_unchecked()})
        io.exit.(0)
      end

      next = FakeOpenShell.start(Path.join(ctx.tmp_dir, "next"), exec: exec)
      assert {:ok, next_state} = Install.reuse(next.endpoint, next.credentials)

      assert_received {:during_check, {:ok, endpoint, credentials}, {:ok, conn}}
      assert endpoint == mine.endpoint
      assert credentials == OpenShell.credentials(state)
      assert {:ok, %{version: _}} = Client.health(conn)
      Client.disconnect(conn)

      assert OpenShell.endpoint() ==
               {:ok, next.endpoint, OpenShell.credentials(next_state)}

      # The one replaced stays for a connection that read it; the one before goes.
      third =
        FakeOpenShell.start(Path.join(ctx.tmp_dir, "third"), exec: fn _, io -> io.exit.(0) end)

      assert {:ok, third_state} = Install.reuse(third.endpoint, third.credentials)

      assert Enum.sort(credential_dirs()) ==
               Enum.sort(Enum.map([next_state, third_state], &OpenShell.credentials_dir/1))
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
