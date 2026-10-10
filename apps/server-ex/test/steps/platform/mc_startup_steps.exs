defmodule HalC2.Steps.Platform.NodeStartup do
  @moduledoc "Steps for features/mc/platform/mc-startup.feature."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias Exqlite.Sqlite3
  alias HalC2.Paths
  alias HalC2.Test.{Mc, Storage, WsClient}
  alias HalC2.Test.Mc.World

  # Boot configuration is read the way an MC boots: `config/config.exs` for the
  # build (dev from a checkout, prod in a release), then `config/runtime.exs` with
  # the process environment. Listeners are checked through `HalC2.Web.child_spec/1`
  # under that configuration, so no step binds the real default port.

  # --- the printed URL -------------------------------------------------------------------

  # With the scenario's user (`HalC2.Test.Storage`) the MC starts from a checkout
  # under their home, as `mix hal_c2.server` does there.
  step "a developer starts the MC from a checkout", context do
    if context[:storage_user] do
      Storage.start_checkout(context, :checkout)
    else
      [line, pairing] = World.mix_output(Mix.Tasks.HalC2.Server, :announce)
      Map.merge(context, %{printed: line, pairing_hint: pairing, boot: boot_config(:dev)})
    end
  end

  step "a developer starts the MC from the main checkout", context do
    Storage.start_checkout(context, :checkout)
  end

  step "a developer starts the MC from a linked git worktree", context do
    Storage.start_checkout(context, :worktree)
  end

  step "it prints a WebSocket URL on loopback with the MC's own access token", context do
    assert [_, port, token] =
             Regex.run(~r{ws://127\.0\.0\.1:(\d+)/ws\?token=(\S+)$}, context.printed),
           "printed #{inspect(context.printed)}"

    assert String.to_integer(port) == context.mc.port
    assert token == File.read!(Path.join(context.mc.home, "access-token"))
    Map.put(context, :url, {String.to_integer(port), token})
  end

  step "it says how to pair a client, since that token is not a pairing code", context do
    assert context.pairing_hint =~ "mise run mc:pair"
    assert context.pairing_hint =~ "not a pairing code"
    context
  end

  step "a client can connect with that URL", context do
    {port, token} = context.url
    assert {:ok, client} = WsClient.connect(port, "/ws?token=#{token}")
    client = WsClient.send_json(client, %{"t" => "ping"})
    assert {%{"t" => "pong"}, _} = Mc.await(client, &(&1["t"] == "pong"))
    context
  end

  # --- port, home and bind host -----------------------------------------------------------

  step "no port is configured", context do
    World.put_os_env("HAL_C2_MC_PORT", nil)
    Map.put(context, :boot_env, :dev)
  end

  step "no port is configured for a release", context do
    World.put_os_env("HAL_C2_MC_PORT", nil)
    Map.put(context, :boot_env, :prod)
  end

  step "HAL_C2_MC_PORT is {int} and HAL_C2_HOME is {string}", %{args: [port, home]} = context do
    clear_home_env()
    World.put_os_env("HAL_C2_MC_PORT", to_string(port))
    World.put_os_env("HAL_C2_HOME", home)
    Map.put(context, :boot_env, :prod)
  end

  step "the bind host is set to {string} in the environment", %{args: [host]} = context do
    World.put_os_env("HAL_C2_MC_HOST", nil)
    World.put_os_env("HAL_C2_HOST", host)
    Map.put(context, :boot_env, :prod)
  end

  step "it serves clients on port {int}", %{args: [port]} = context do
    assert {_ip, ^port} = listener(boot_config(context.boot_env))
    context
  end

  step "it listens for cluster members on port {int}, not on {int} as one run from a checkout does",
       %{args: [release, checkout]} = context do
    assert boot_config(context.boot_env)[:cluster_port] == release
    assert Keyword.get(boot_config(:dev), :cluster_port, HalC2.Cluster.dist_port()) == checkout
    context
  end

  step "it serves clients on {string}", %{args: [host]} = context do
    {:ok, ip} = :inet.parse_address(String.to_charlist(host))
    assert {^ip, _port} = listener(boot_config(context.boot_env))
    context
  end

  step "no home directory is configured", context do
    Storage.user(context)
  end

  step "its settings are in {string}", %{args: [dir]} = context do
    expected = Storage.path(context, dir)
    assert Paths.config_dir() == expected
    :ok = World.merge_settings(%{"providers" => %{"grok" => %{"enabled" => false}}})
    assert File.regular?(Path.join(expected, "settings.json"))
    context
  end

  step ~r/^its database, secrets and worktrees are in (?<dir>.+)$/, %{args: [dir]} = context do
    expected = where(context, dir)
    assert Paths.data_dir() == expected
    assert HalC2.Store.home_path() == Path.join(expected, "hal-c2.sqlite")
    assert File.regular?(HalC2.Store.home_path())
    :ok = HalC2.Connect.Secrets.put("relay-token", "s3cret")
    assert File.regular?(Path.join(expected, "secrets/relay-token.bin"))
    worktree = HalC2.Vcs.worktree_path("/code/app", "feature/login")
    assert String.starts_with?(worktree, Path.join(expected, "worktrees") <> "/")
    context
  end

  step ~r/^its logs are in (?<dir>.+)$/, %{args: [dir]} = context do
    expected = where(context, dir)
    assert Path.join(Paths.state_dir(), "logs") == expected
    assert HalC2.Environment.server_config()["observability"]["logsDirectoryPath"] == expected

    for path <- [HalC2.Traces.path(), HalC2.ProviderLog.path("thread-1")],
        do: assert(String.starts_with?(path, expected <> "/"), path)

    context
  end

  step "its downloaded tools are in {string}", %{args: [dir]} = context do
    expected = Storage.path(context, dir)
    assert String.starts_with?(HalC2.Acp.Antigravity.managed_dir(), expected <> "/")
    context
  end

  step ~r/^its database is in (?<dir>.+)$/, %{args: [dir]} = context do
    expected = where(context, dir)
    assert HalC2.Store.home_path() == Path.join(expected, "hal-c2.sqlite")
    assert File.regular?(HalC2.Store.home_path())
    context
  end

  step "the user's home has a {string} directory", %{args: [dir]} = context do
    context = Storage.user(context)
    File.mkdir_p!(Storage.path(context, dir))
    context
  end

  step "nothing is written to the user's XDG directories", context do
    for dir <- ~w(~/.config/hal-c2 ~/.local/share/hal-c2 ~/.local/state/hal-c2 ~/.cache/hal-c2),
        do: Storage.assert_untouched(context, Storage.path(context, dir))

    context
  end

  step "a user starts the MC from a release", context do
    Storage.start(context)
  end

  step "the MC starts from a checkout or a release", context do
    World.put_os_env("HAL_C2_HOST", nil)
    World.put_os_env("HAL_C2_MC_HOST", nil)
    boots = [boot_config(:dev), boot_config(:prod)]
    Map.put(context, :boots, boots)
  end

  step "only clients on the same machine can reach it", context do
    for boot <- context.boots, do: assert({{127, 0, 0, 1}, _} = listener(boot))

    # The running MC, too: its listener is on loopback, and no other address answers.
    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(HalC2.Web.Listener)

    if ip = lan_address() do
      assert {:error, _} = :gen_tcp.connect(ip, port, [], 1_000)
    end

    context
  end

  step "a user starts the MC with a LAN or tailnet host address", context do
    ip = lan_address() || flunk("this machine has no non-loopback IPv4 address")
    host = ip |> :inet.ntoa() |> to_string()
    World.put_app_env(:host, host)
    %{context | mc: Mc.restart(context.mc), clients: %{}} |> Map.put(:lan_host, host)
  end

  step "clients on that network can reach it", context do
    assert {:ok, {{200, body}, _}} = lan_request(context, :get, "/.well-known/hal-c2/environment")
    assert JSON.decode!(body)["environmentId"] == context.mc.environment
    context
  end

  step "its pairing links use that address", context do
    [link] = World.mix_output(Mix.Tasks.HalC2.Pair, :run, [[]])
    base = "http://#{context.lan_host}:#{context.mc.port}/?token="
    assert String.starts_with?(link, base), link

    # The link's token pairs over that address.
    token = String.replace_prefix(link, base, "")

    form =
      URI.encode_query(%{
        "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
        "subject_token" => token,
        "subject_token_type" => "urn:hal-c2:params:oauth:token-type:environment-bootstrap",
        "client_label" => "Laptop"
      })

    assert {:ok, {{200, body}, _}} = lan_request(context, :post, "/oauth/token", form)
    assert %{"access_token" => _} = JSON.decode!(body)
    context
  end

  # --- the runtime record -----------------------------------------------------------------

  # The scenario's MC is up once its listener is bound (`HalC2.Test.Mc.start/3`).
  step "the MC is serving clients", context do
    assert {200, _, _} = Mc.request(context.mc, :get, "/.well-known/hal-c2/environment")
    context
  end

  step "its state directory holds a runtime record naming its process, port, origin and start time",
       context do
    path = Path.join(Paths.state_dir(), "server-runtime.json")
    assert path == HalC2.RuntimeRecord.path()
    record = path |> File.read!() |> JSON.decode!()
    assert record["version"] == 1
    assert record["pid"] == String.to_integer(System.pid())
    assert record["port"] == context.mc.port
    assert record["origin"] == "http://127.0.0.1:#{context.mc.port}"
    assert {:ok, _, _} = DateTime.from_iso8601(record["startedAt"])
    Map.put(context, :runtime_record, record)
  end

  step "that origin serves the MC's environment descriptor", context do
    assert {200, %{"environmentId" => id, "orchestrationProtocolVersion" => 3}} =
             Mc.http(context.runtime_record["origin"], :get, "/.well-known/hal-c2/environment")

    assert id == context.mc.environment
    context
  end

  step "its state directory holds no runtime record", context do
    refute File.exists?(HalC2.RuntimeRecord.path())
    context
  end

  # --- identity ---------------------------------------------------------------------------

  step "the MC starts for the first time", context do
    if context[:storage_user] do
      Storage.first_start(context)
    else
      fresh = Mc.tmp_dir(context.mc, "fresh-home")
      %{context | mc: Mc.restart(%{context.mc | home: fresh}), clients: %{}}
    end
  end

  step "it writes an access token file readable only by its owner", context do
    path = Path.join(context.mc.home, "access-token")
    assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o600
    Map.put(context, :token_file, path)
  end

  step "local tools connect with that token", context do
    token = File.read!(context.token_file)
    assert {:ok, client} = WsClient.connect(context.mc.port, "/ws?token=#{token}")
    client = WsClient.send_json(client, %{"t" => "ping"})
    assert {%{"t" => "pong"}, _} = Mc.await(client, &(&1["t"] == "pong"))
    context
  end

  step "the MC started once and recorded its environment id", context do
    # A fresh process: nothing cached from an earlier MC in this VM.
    :persistent_term.erase({HalC2.Environment, :id})
    context = %{context | mc: Mc.restart(context.mc), clients: %{}}

    {200, _, %{"environmentId" => id}} =
      Mc.request(context.mc, :get, "/.well-known/hal-c2/environment")

    assert File.read!(Path.join(context.mc.home, "environment-id")) == id
    Map.put(context, :environment_id, id)
  end

  step "the MC restarts on another port", context do
    old_port = context.mc.port
    # A new process reads its identity from the home again.
    :persistent_term.erase({HalC2.Environment, :id})
    mc = Mc.restart(%{context.mc | port: 0})
    assert mc.port != old_port
    %{context | mc: mc, clients: %{}}
  end

  step "it reports the same environment id", context do
    assert {200, _, %{"environmentId" => id}} =
             Mc.request(context.mc, :get, "/.well-known/hal-c2/environment")

    assert id == context.environment_id
    context
  end

  step "no label is configured", context do
    World.put_os_env("HAL_C2_LABEL", nil)
    context
  end

  step "HAL_C2_LABEL is {string}", %{args: [label]} = context do
    World.put_os_env("HAL_C2_LABEL", label)
    context
  end

  step "a client reads the MC's environment descriptor", context do
    assert {200, _, descriptor} =
             Mc.request(context.mc, :get, "/.well-known/hal-c2/environment")

    Map.put(context, :descriptor, descriptor)
  end

  step "the label is the machine's host name", context do
    {:ok, host} = :inet.gethostname()
    assert context.descriptor["label"] == List.to_string(host)
    context
  end

  step "the label is {string}", %{args: [label]} = context do
    assert context.descriptor["label"] == label
    context
  end

  step "it names the environment id, label, platform and server version", context do
    d = context.descriptor
    assert d["environmentId"] == context.mc.environment
    assert is_binary(d["label"]) and d["label"] != ""
    assert %{"os" => os, "arch" => arch} = d["platform"]
    assert os in ~w(linux darwin win32) and is_binary(arch)
    assert d["serverVersion"] == HalC2.Upgrade.version()
    context
  end

  step "it declares orchestration protocol version {int}", %{args: [version]} = context do
    assert context.descriptor["orchestrationProtocolVersion"] == version
    context
  end

  step "it lists the MC's capabilities", context do
    capabilities = context.descriptor["capabilities"]
    assert capabilities["serverResolvedCommandContext"] == true
    assert capabilities["attachmentUploads"] == true
    # A checkout cannot install versions, so it does not offer to.
    refute Map.has_key?(capabilities, "serverSelfUpdate")
    context
  end

  # --- the service wrapper ----------------------------------------------------------------

  step "the MC runs under the service wrapper", context do
    bin = Path.join(Mc.tmp_dir(context.mc, "release"), "bin")
    File.mkdir_p!(bin)
    wrapper = Path.join(bin, "hal-c2-service")
    File.cp!(Path.join(project_dir(), "rel/overlays/bin/hal-c2-service"), wrapper)
    File.chmod!(wrapper, 0o755)
    log = Path.join(bin, "starts.log")

    # A stand-in for bin/hal_c2: the first start exits asking for a restart (75, what
    # `HalC2.Upgrade` stops with), the second with an ordinary failure.
    File.write!(Path.join(bin, "hal_c2"), """
    #!/bin/sh
    echo "$* service=$HAL_C2_SERVICE" >> "#{log}"
    [ "$(wc -l < "#{log}")" -eq 1 ] && exit 75
    exit 3
    """)

    File.chmod!(Path.join(bin, "hal_c2"), 0o755)
    Map.put(context, :wrapper, %{path: wrapper, log: log})
  end

  step "the MC exits asking for a restart", context do
    {_, status} = System.cmd(context.wrapper.path, ["--flag"], env: [{"HAL_C2_SERVICE", nil}])
    Map.put(context, :wrapper_status, status)
  end

  step "the wrapper starts the MC again", context do
    assert ["start --flag service=1", "start --flag service=1"] =
             context.wrapper.log |> File.read!() |> String.split("\n", trim: true)

    context
  end

  step "any other exit stops the wrapper", context do
    assert context.wrapper_status == 3
    context
  end

  step "the MC is running under the service wrapper", context do
    bin = Path.join(Mc.tmp_dir(context.mc, "release"), "bin")
    File.mkdir_p!(bin)
    wrapper = Path.join(bin, "hal-c2-service")
    File.cp!(Path.join(project_dir(), "rel/overlays/bin/hal-c2-service"), wrapper)
    File.chmod!(wrapper, 0o755)
    log = Path.join(bin, "starts.log")
    [ready, stopping, release] = for name <- ~w(ready stopping release), do: Path.join(bin, name)
    {_, 0} = System.cmd("mkfifo", [ready, stopping, release])

    # A stand-in for bin/hal_c2 that says when it is up and when it was told to stop,
    # and then stops only once it is let go, as an MC closing its threads takes a while.
    File.write!(Path.join(bin, "hal_c2"), """
    #!/bin/sh
    trap 'echo told > "#{stopping}"; read _ < "#{release}"; echo stopped >> "#{log}"; exit 0' TERM
    echo up > "#{ready}"
    while :; do sleep 1 & wait $!; done
    """)

    File.chmod!(Path.join(bin, "hal_c2"), 0o755)

    Map.put(context, :wrapper, %{
      path: wrapper,
      log: log,
      ready: ready,
      stopping: stopping,
      release: release
    })
  end

  # systemd and launchd signal the process they started, which is the wrapper. Says
  # whether the wrapper was still there while the MC was stopping, then its exit status.
  step "the service manager stops the wrapper", %{wrapper: wrapper} = context do
    script = """
    "$0" & pid=$!
    read _ < "$1"
    kill -TERM "$pid"
    read _ < "$2"
    case "$(ps -o stat= -p "$pid")" in ""|Z*) waited=no ;; *) waited=yes ;; esac
    echo go > "$3"
    wait "$pid"
    echo "$waited $?"
    """

    {out, 0} =
      System.cmd("sh", [
        "-c",
        script,
        wrapper.path,
        wrapper.ready,
        wrapper.stopping,
        wrapper.release
      ])

    Map.put(context, :wrapper_stop, String.trim(out))
  end

  step "the MC is told to stop and the wrapper waits for it", context do
    assert context.wrapper_stop == "yes 0"
    assert File.read!(context.wrapper.log) == "stopped\n"
    context
  end

  step "a user asks to install the background service", context do
    Mc.release(context.mc, service: false)
    user_home = Mc.tmp_dir(context.mc, "user-home")
    World.put_app_env(:service_user_home, user_home)
    World.put_app_env(:service_platform, {:unix, :linux})
    for name <- ~w(HAL_C2_MC_HOME HAL_C2_HOME), do: World.put_os_env(name, nil)
    tools = Storage.service_manager(context)
    assert {:ok, status} = HalC2.Service.install()
    Map.merge(context, %{service: status, service_tools: tools})
  end

  step "the MC is registered with the system's service manager", context do
    unit = File.read!(context.service["unitPath"])
    release = System.get_env("RELEASE_ROOT")
    assert unit =~ "ExecStart=#{release}/bin/hal-c2-service"
    # The user named no home, so the service finds the MC's directories itself.
    refute unit =~ "HAL_C2_MC_HOME"
    refute unit =~ "HAL_C2_HOME"
    assert context.service["installed"] and context.service["current"]
    assert "systemctl --user daemon-reload" in calls(context)
    assert "systemctl --user restart hal-c2.service" in calls(context)
    context
  end

  step "it starts on login", context do
    assert File.read!(context.service["unitPath"]) =~ "WantedBy=default.target"
    assert "systemctl --user enable hal-c2.service" in calls(context)
    # Lingering keeps it running after the user logs out.
    assert File.exists?(Path.join(Path.dirname(context.service_tools), "linger"))
    context
  end

  step "the user can see its status and remove it again", context do
    assert %{"installed" => true, "current" => true, "logPath" => log} = HalC2.Service.status()
    assert log == Path.join([context.mc.home, "logs", "boot-service.log"])

    assert :ok = HalC2.Service.uninstall()
    assert "systemctl --user disable --now hal-c2.service" in calls(context)
    refute HalC2.Service.status()["installed"]

    refute File.exists?(context.service["unitPath"])
    # The MC's state stays.
    assert File.exists?(Path.join(context.mc.home, "hal-c2.sqlite"))
    context
  end

  # --- release packaging and sidecars -----------------------------------------------------

  step "a maintainer builds a release bundle", context do
    version = HalC2.Upgrade.version()
    out = Mc.tmp_dir(context.mc, "out")
    path = Mix.Tasks.HalC2.Bundle.bundle(out, fake_release(context, version))
    Map.merge(context, %{bundle: path, bundle_out: out, bundle_version: version})
  end

  step "it writes one archive named for the version and platform", context do
    name = "hal-c2-mc-#{context.bundle_version}-#{HalC2.Upgrade.platform()}.tar.gz"
    assert Path.basename(context.bundle) == name
    assert Path.wildcard(Path.join(context.bundle_out, "*.tar.gz")) == [context.bundle]
    {:ok, entries} = :erl_tar.table(String.to_charlist(context.bundle), [:compressed])
    entries = Enum.map(entries, &to_string/1)
    assert Enum.any?(entries, &String.starts_with?(&1, "releases/#{context.bundle_version}"))
    assert Enum.any?(entries, &String.starts_with?(&1, "erts-17.0.5"))
    context
  end

  step "an executable single-file MC named the same without the extension", context do
    single = String.replace_suffix(context.bundle, ".tar.gz", "")
    assert File.stat!(single).mode |> Bitwise.band(0o111) != 0
    # The bundle rides unchanged behind the script.
    assert String.ends_with?(File.read!(single), File.read!(context.bundle))
    context
  end

  step "a SHA-256 file beside each", context do
    for path <- [context.bundle, String.replace_suffix(context.bundle, ".tar.gz", "")] do
      sum = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
      assert File.read!(path <> ".sha256") == "#{sum}  #{Path.basename(path)}\n"
    end

    context
  end

  # --- the single-file MC ---------------------------------------------------------------

  step "the single-file MC of a release", context do
    Map.merge(context, single_file(context, HalC2.Upgrade.version()))
  end

  step "a user ran the single-file MC of a release", context do
    context = Map.merge(context, single_file(context, HalC2.Upgrade.version()))
    run_single(context, context.single, [])
    File.write!(context.starts, "")
    # A file the release did not ship, to tell whether it is unpacked again.
    File.write!(Path.join([context.release_root, "bin", "local"]), "")
    context
  end

  step "the MC has since upgraded itself to {string}", %{args: [version]} = context do
    # What `HalC2.Upgrade` leaves behind after installing a version.
    File.mkdir_p!(Path.join([context.release_root, "releases", version]))

    File.write!(
      Path.join([context.release_root, "releases/start_erl.data"]),
      "17.0.5 #{version}\n"
    )

    context
  end

  step "the install was cut off before it named the release to start", context do
    # The release is in place, but start_erl.data and the finished mark never landed.
    releases = Path.join(context.release_root, "releases")
    File.rm!(Path.join(releases, "start_erl.data"))
    File.rm!(Path.join(releases, "#{HalC2.Upgrade.version()}.installed"))
    context
  end

  step "a user runs it with {string}", %{args: [arg]} = context do
    run_single(context, context.single, [arg])
  end

  step "a user runs the single-file MC of {string}", %{args: [version]} = context do
    %{single: single} = single_file(context, version)
    run_single(context, single, [])
  end

  step "the release and its runtime are unpacked in the MC's data directory", context do
    root = context.release_root
    assert root == Path.join([context.single_home, "data", "release"])
    version = HalC2.Upgrade.version()

    for dir <- ["lib/hal_c2-#{version}/ebin", "releases/#{version}", "erts-17.0.5/bin"],
        do: assert(File.dir?(Path.join(root, dir)), "#{dir} is not unpacked")

    assert File.read!(Path.join(root, "releases/start_erl.data")) == "17.0.5 #{version}\n"
    # bin/hal_c2 reads the cookie even with distribution off; the bundle has none.
    cookie = Path.join(root, "releases/COOKIE")
    assert File.read!(cookie) =~ ~r/^[0-9a-f]{64}$/
    assert Bitwise.band(File.stat!(cookie).mode, 0o077) == 0
    # Nothing is left half-unpacked beside it.
    assert File.ls!(Path.join(context.single_home, "data")) == ["release"]
    context
  end

  step "the service wrapper starts the release with {string}", %{args: [arg]} = context do
    assert starts(context) == ["#{HalC2.Upgrade.version()} #{arg}"]
    context
  end

  step "the service wrapper starts {string} with {string}", %{args: [version, arg]} = context do
    assert starts(context) == [String.trim("#{version} #{arg}")]
    context
  end

  step "the installed release is left as it was", context do
    assert File.exists?(Path.join([context.release_root, "bin", "local"]))
    context
  end

  step "the versions installed before are kept", context do
    version = HalC2.Upgrade.version()

    for dir <- [
          "releases/#{version}",
          "lib/hal_c2-#{version}",
          "releases/9.9.9",
          "lib/hal_c2-9.9.9"
        ],
        do: assert(File.dir?(Path.join(context.release_root, dir)), "#{dir} is missing")

    context
  end

  step "the machine has Node {int} or newer", %{args: [major]} = context do
    node = System.find_executable("node") || flunk("node is not installed")
    {"v" <> version, 0} = System.cmd(node, ["--version"])
    assert version |> String.split(".") |> hd() |> String.to_integer() >= major
    World.put_os_env("HAL_C2_NODE_COMMAND", nil)
    Mc.ensure(HalC2.Settings)
    context
  end

  step "the MC needs the Cursor provider", context do
    # The release's own layout (`lib/hal_c2-<version>/priv`, where mix.exs stages the
    # sidecar), put first on the code path so the application resolves to it.
    lib =
      Path.join([Mc.tmp_dir(context.mc, "rel"), "lib", "hal_c2-#{HalC2.Upgrade.version()}"])

    sidecar = Path.join(lib, "priv/cursor-acp/main.mjs")
    File.mkdir_p!(Path.dirname(sidecar))
    File.write!(sidecar, "")
    ebin = Path.join(lib, "ebin")
    File.mkdir_p!(ebin)
    true = :code.add_patha(String.to_charlist(ebin))

    command =
      try do
        HalC2.Acp.command("cursor")
      after
        :code.del_path(String.to_charlist(ebin))
      end

    Map.merge(context, %{acp_command: command, sidecar: sidecar})
  end

  step "it runs the sidecar shipped inside the release", context do
    assert {:ok, ["node", script, "--mode", _], _env} = context.acp_command
    assert script == context.sidecar
    context
  end

  # --- the desktop bootstrap --------------------------------------------------------------

  step "the desktop app launches the MC in bootstrap mode", context do
    World.put_os_env("HAL_C2_BOOTSTRAP_STDIN", "1")
    # Everything the bootstrap sets comes back when the scenario ends.
    # Restored after the scenario; a key that was unset stays unset.
    for key <- [:home, :port, :host, :desktop_token] do
      previous = Application.fetch_env(:hal_c2, key)
      World.put_app_env(key, nil)
      with {:ok, value} <- previous, do: Application.put_env(:hal_c2, key, value)
      if previous == :error, do: Application.delete_env(:hal_c2, key)
    end

    context
  end

  step "the desktop app launches the MC in bootstrap mode with the HAL-C2 home {string}",
       %{args: [home]} = context do
    context = Storage.user(context)
    desktop_bootstrap(context, %{"halC2Home" => Storage.path(context, home)})
  end

  step "the desktop app launches the MC in bootstrap mode without a HAL-C2 home", context do
    context = Storage.user(context)
    desktop_bootstrap(context, %{})
  end

  step "it writes the port, host, HAL-C2 home and bootstrap token as one line on standard input",
       context do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    hal_c2_home = Mc.tmp_dir(context.mc, "desktop-hal-c2")
    token = "desktop-#{System.unique_integer([:positive])}"

    line =
      JSON.encode!(%{
        "port" => port,
        "host" => "127.0.0.1",
        "halC2Home" => hal_c2_home,
        "desktopBootstrapToken" => token
      })

    {:ok, stdin} = StringIO.open(line <> "\n")

    :ok =
      Task.async(fn ->
        Process.group_leader(self(), stdin)
        HalC2.Desktop.configure()
      end)
      |> Task.await()

    # The MC's services come up under what the bootstrap configured, as they do
    # after `HalC2.Desktop.configure/0` in `HalC2.Application`.
    for child <- [
          HalC2.RuntimeRecord,
          HalC2.Web,
          HalC2.Shell,
          HalC2.Streams,
          HalC2.Auth,
          HalC2.Store
        ],
        do: ExUnit.Callbacks.stop_supervised(child)

    :persistent_term.erase({HalC2.Web, :token})
    HalC2.Paths.ensure!()

    for child <- [
          {HalC2.Store, path: HalC2.Store.home_path()},
          HalC2.Auth,
          HalC2.Streams,
          HalC2.Shell,
          HalC2.Web
        ],
        do: Mc.ensure(child)

    Map.merge(context, %{desktop: %{port: port, hal_c2_home: hal_c2_home, token: token}})
  end

  step "the MC listens on that host and port", context do
    port = context.desktop.port
    assert {:ok, {{127, 0, 0, 1}, ^port}} = ThousandIsland.listener_info(HalC2.Web.Listener)

    assert {200, _, %{"environmentId" => _}} =
             Mc.request(%{port: port}, :get, "/.well-known/hal-c2/environment")

    # The window pairs with the token it passed.
    assert {200, %{"access_token" => _}} = Mc.exchange(%{port: port}, context.desktop.token)
    context
  end

  step "the token never appears in the process arguments or environment", context do
    token = context.desktop.token
    refute Enum.any?(System.get_env(), fn {_k, v} -> String.contains?(v, token) end)
    refute Enum.any?(:init.get_arguments(), &(inspect(&1) =~ token))

    case File.read("/proc/#{System.pid()}/cmdline") do
      {:ok, cmdline} -> refute cmdline =~ token
      {:error, _} -> :ok
    end

    context
  end

  # --- importing an earlier install's history ---------------------------------------------

  step "a consistent snapshot of a TypeScript server's database", context do
    source = Path.join(Mc.tmp_dir(context.mc, "ts"), "state.sqlite")

    events = [
      {"project", "project-1", "project.created",
       %{"projectId" => "project-1", "title" => "api"}},
      {"thread", "thread-1", "thread.created",
       %{"id" => "thread-1", "title" => "Fix login", "projectId" => "project-1"}},
      {"thread", "thread-2", "thread.created",
       %{"id" => "thread-2", "title" => "Add search", "projectId" => "project-1"}},
      {"thread", "thread-2", "thread.visited",
       %{"id" => "thread-2", "title" => "Add search v2", "projectId" => "project-1"}}
    ]

    write_ts_log(source, events)
    Map.merge(context, %{ts_source: source, ts_events: events})
  end

  step "an operator imports it into the MC's home", context do
    # The import runs offline, against a stopped MC's store.
    for child <- [
          HalC2.RuntimeRecord,
          HalC2.Web,
          HalC2.Shell,
          HalC2.Streams,
          HalC2.Auth,
          HalC2.Store
        ],
        do: ExUnit.Callbacks.stop_supervised(child)

    lines = World.mix_output(Mix.Tasks.HalC2.Import, :run, [[context.ts_source]])
    GenServer.stop(HalC2.Store)

    Map.merge(context, %{
      import_output: Enum.join(lines, "\n"),
      mc: Mc.start(context.mc.home)
    })
  end

  step "every thread stream is copied into the MC's store", context do
    store = HalC2.Store.home_path()

    for {stream, title} <- [{"thread-1", "Fix login"}, {"thread-2", "Add search v2"}] do
      state = HalC2.StreamState.load(store, stream)
      assert %{^stream => %{"title" => ^title}} = HalC2.StreamState.get(state, "thread")
    end

    context
  end

  step "the import reports how many streams and events it moved", context do
    assert context.import_output =~ "Imported 3 streams"
    assert context.import_output =~ ~r/events:\s+4 -> \d+/
    context
  end

  step "an operator runs the import with no source", context do
    error = assert_raise Mix.Error, fn -> Mix.Tasks.HalC2.Import.run([]) end
    Map.put(context, :refusal, error.message)
  end

  step "it refuses with the expected usage", context do
    assert context.refusal == "usage: mix hal_c2.import PATH/TO/state.sqlite"
    context
  end

  # --- cluster boot -----------------------------------------------------------------------

  step "the release starts", context do
    home = Mc.tmp_dir(context.mc, "release")
    context |> Map.put(:release_home, home) |> Map.put(:release_env, release_env(home))
  end

  step "it boots with TLS distribution whose options are in the MC's data directory",
       context do
    # The MC names itself and writes the options when it starts (`HalC2.Cluster`).
    optfile = Path.join([context.release_home, "data", "cluster", "ssl_dist.conf"])
    env = context.release_env
    assert env["RELEASE_DISTRIBUTION"] == "none"
    assert env["RELEASE_COOKIE"] == "hal_c2"
    assert env["ELIXIR_ERL_OPTIONS"] =~ "-proto_dist inet_tls -ssl_dist_optfile #{optfile}"
    context
  end

  step "asking the release for named distribution leaves the cluster flags out", context do
    env = release_env(context.release_home, "sname")
    assert env["RELEASE_DISTRIBUTION"] == "sname"
    refute env["ELIXIR_ERL_OPTIONS"] =~ "-proto_dist"
    context
  end

  # --- helpers ----------------------------------------------------------------------------

  defp project_dir, do: Path.dirname(Mix.Project.project_file())

  # The `:hal_c2` config an MC boots with in `env`, from the current process environment.
  defp boot_config(env) do
    config = Path.join(project_dir(), "config")
    base = Config.Reader.read!(Path.join(config, "config.exs"), env: env, target: :host)
    runtime = Config.Reader.read!(Path.join(config, "runtime.exs"), env: env, target: :host)
    Config.Reader.merge(base, runtime)[:hal_c2]
  end

  # Every variable that names the MC's home, now and from before the rename.
  @home_env ~w(HAL_C2_MC_HOME HAL_C2_HOME T3_HOME T3CODE_HOME XDG_DATA_HOME)

  defp clear_home_env, do: for(name <- @home_env, do: World.put_os_env(name, nil))

  # A release root as `mix release` lays one out, for `version` on ERTS 17.0.5. Its
  # bin/hal-c2-service stands in for the wrapper and logs which version it would start
  # (from start_erl.data, as bin/hal_c2 reads it) and its arguments to `starts.log` in
  # the scenario's home.
  defp fake_release(context, version) do
    root = Mc.tmp_dir(context.mc, "rel")

    for dir <- ["bin", "lib/hal_c2-#{version}/ebin", "releases/#{version}", "erts-17.0.5/bin"],
        do: File.mkdir_p!(Path.join(root, dir))

    File.write!(Path.join(root, "releases/start_erl.data"), "17.0.5 #{version}\n")

    File.write!(
      Path.join([root, "releases", version, "upgrade.json"]),
      JSON.encode!(Mc.manifest(version))
    )

    File.cp!(
      Path.join(project_dir(), "rel/overlays/bin/hal-c2-data-dir"),
      Path.join(root, "bin/hal-c2-data-dir")
    )

    wrapper = Path.join(root, "bin/hal-c2-service")

    File.write!(wrapper, """
    #!/bin/sh
    here="$(cd "$(dirname "$0")" && pwd)"
    echo "$(cut -d' ' -f2 "$here/../releases/start_erl.data") $*" >> "#{starts_log(context)}"
    """)

    File.chmod!(wrapper, 0o755)
    root
  end

  defp starts_log(context), do: Path.join(context.mc.home, "starts.log")

  defp starts(context),
    do:
      context
      |> starts_log()
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)

  # The single-file MC built from a fake release of `version`, and the MC home it
  # runs in (HAL_C2_MC_HOME).
  defp single_file(context, version) do
    out = Mc.tmp_dir(context.mc, "out")
    bundle = Mix.Tasks.HalC2.Bundle.bundle(out, fake_release(context, version))
    home = context[:single_home] || Mc.tmp_dir(context.mc, "mc-home")

    %{
      single: String.replace_suffix(bundle, ".tar.gz", ""),
      single_home: home,
      release_root: Path.join([home, "data", "release"]),
      starts: starts_log(context)
    }
  end

  defp run_single(context, single, args) do
    env =
      [{"HAL_C2_MC_HOME", context.single_home}] ++
        for(name <- @home_env -- ["HAL_C2_MC_HOME"], do: {name, nil})

    {out, status} = System.cmd(single, args, env: env, stderr_to_stdout: true)
    assert status == 0, out
    context
  end

  # What rel/env.sh.eex exports, sourced the way the release script does, with
  # `mc_home` as the MC's root (HAL_C2_MC_HOME).
  defp release_env(mc_home, distribution \\ nil) do
    script = Path.join(project_dir(), "rel/env.sh.eex")

    {out, 0} =
      System.cmd(
        "sh",
        [
          "-c",
          ~s(. "$0"; printf '%s\\n' "$RELEASE_DISTRIBUTION" "${ELIXIR_ERL_OPTIONS:-}" "${RELEASE_COOKIE:-}"),
          script
        ],
        env:
          [
            {"HAL_C2_MC_HOME", mc_home},
            {"RELEASE_ROOT", Path.join(project_dir(), "rel/overlays")},
            {"RELEASE_DISTRIBUTION", distribution},
            {"ELIXIR_ERL_OPTIONS", nil},
            {"RELEASE_COOKIE", nil}
          ] ++ for(name <- @home_env -- ["HAL_C2_MC_HOME"], do: {name, nil})
      )

    [dist, opts, cookie] = String.split(out, "\n") |> Enum.take(3)
    %{"RELEASE_DISTRIBUTION" => dist, "ELIXIR_ERL_OPTIONS" => opts, "RELEASE_COOKIE" => cookie}
  end

  # `{ip, port}` of the listener `HalC2.Web` would start under `boot`.
  defp listener(boot) do
    %{start: {Bandit, :start_link, [opts]}} =
      with_app_env([port: boot[:port], host: boot[:host]], fn -> HalC2.Web.child_spec([]) end)

    {opts[:ip], opts[:port]}
  end

  # Runs `fun` with `:hal_c2` env keys set (nil unsets), then puts them back.
  defp with_app_env(pairs, fun) do
    previous = for {key, _} <- pairs, do: {key, Application.fetch_env(:hal_c2, key)}

    for {key, value} <- pairs,
        do:
          if(value == nil,
            do: Application.delete_env(:hal_c2, key),
            else: Application.put_env(:hal_c2, key, value)
          )

    try do
      fun.()
    after
      for {key, old} <- previous do
        case old do
          {:ok, value} -> Application.put_env(:hal_c2, key, value)
          :error -> Application.delete_env(:hal_c2, key)
        end
      end
    end
  end

  # An up, non-loopback IPv4 address of this machine.
  defp lan_address do
    {:ok, interfaces} = :inet.getifaddrs()

    Enum.find_value(interfaces, fn {_name, opts} ->
      flags = opts[:flags] || []

      if :up in flags and :loopback not in flags,
        do:
          Enum.find_value(opts, fn
            {:addr, {_, _, _, _} = ip} -> ip
            _ -> nil
          end)
    end)
  end

  defp lan_request(context, method, path, form \\ nil) do
    {:ok, _} = Application.ensure_all_started(:inets)
    url = ~c"http://#{context.lan_host}:#{context.mc.port}#{path}"

    request =
      if form,
        do: {url, [], ~c"application/x-www-form-urlencoded", form},
        else: {url, []}

    case :httpc.request(method, request, [], body_format: :binary) do
      {:ok, {{_, status, _}, headers, body}} -> {:ok, {{status, body}, headers}}
      other -> other
    end
  end

  # Starts the MC as the desktop app does: `bootstrap` (and the port, host and token)
  # on standard input, then the MC on the home it names.
  defp desktop_bootstrap(context, bootstrap) do
    World.put_os_env("HAL_C2_BOOTSTRAP_STDIN", "1")

    # Restored after the scenario; a key that was unset stays unset.
    for key <- [:home, :port, :host, :desktop_token] do
      previous = Application.fetch_env(:hal_c2, key)
      World.put_app_env(key, nil)
      with {:ok, value} <- previous, do: Application.put_env(:hal_c2, key, value)
      if previous == :error, do: Application.delete_env(:hal_c2, key)
    end

    Application.put_env(:hal_c2, :home, Storage.release_spec())
    line = JSON.encode!(Map.merge(%{"desktopBootstrapToken" => "desktop-token"}, bootstrap))
    {:ok, stdin} = StringIO.open(line <> "\n")

    :ok =
      Task.async(fn ->
        Process.group_leader(self(), stdin)
        HalC2.Desktop.configure()
      end)
      |> Task.await()

    put_in(context, [:mc, :spec], Application.get_env(:hal_c2, :home))
  end

  # Where a feature's directory is: a quoted path, or `the checkout's "..."`.
  defp where(context, "the checkout's \"" <> rest),
    do: Path.join(context.checkout, String.trim_trailing(rest, "\""))

  defp where(context, "\"" <> rest), do: Storage.path(context, String.trim_trailing(rest, "\""))

  defp calls(context),
    do: context.service_tools |> File.read!() |> String.split("\n", trim: true)

  # An earlier install's event table (orchestration_events).
  defp write_ts_log(path, events) do
    {:ok, db} = Sqlite3.open(path)

    :ok =
      Sqlite3.execute(db, """
      CREATE TABLE orchestration_events (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT, aggregate_kind TEXT, stream_id TEXT,
        event_type TEXT, payload_json TEXT, occurred_at TEXT, application_event_version INTEGER)
      """)

    {:ok, stmt} =
      Sqlite3.prepare(
        db,
        "INSERT INTO orchestration_events (aggregate_kind, stream_id, event_type, payload_json, occurred_at, application_event_version) VALUES (?1, ?2, ?3, ?4, ?5, ?6)"
      )

    for {agg, stream, type, payload} <- events do
      :ok =
        Sqlite3.bind(stmt, [
          agg,
          stream,
          type,
          JSON.encode!(payload),
          "2026-09-01T12:00:00.000Z",
          if(agg == "project", do: nil, else: 2)
        ])

      :done = Sqlite3.step(db, stmt)
    end

    Sqlite3.release(db, stmt)
    Sqlite3.close(db)
  end
end
