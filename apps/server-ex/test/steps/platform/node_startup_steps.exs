defmodule HalC2.Steps.Platform.NodeStartup do
  @moduledoc "Steps for features/node/platform/node-startup.feature."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias Exqlite.Sqlite3
  alias HalC2.Test.{Node, WsClient}
  alias HalC2.Test.Node.World

  # Boot configuration is read the way a node boots: `config/config.exs` for the
  # build (dev from a checkout, prod in a release), then `config/runtime.exs` with
  # the process environment. Listeners are checked through `HalC2.Web.child_spec/1`
  # under that configuration, so no step binds the real default port.

  # --- the printed URL -------------------------------------------------------------------

  step "a developer starts the node from a checkout", context do
    [line] = World.mix_output(Mix.Tasks.HalC2.Server, :announce)
    Map.merge(context, %{printed: line, boot: boot_config(:dev)})
  end

  step "it prints a WebSocket URL on loopback with the node's own access token", context do
    assert [_, port, token] =
             Regex.run(~r{ws://127\.0\.0\.1:(\d+)/ws\?token=(\S+)$}, context.printed),
           "printed #{inspect(context.printed)}"

    assert String.to_integer(port) == context.node.port
    assert token == File.read!(Path.join(context.node.home, "access-token"))
    Map.put(context, :url, {String.to_integer(port), token})
  end

  step "a client can connect with that URL", context do
    {port, token} = context.url
    assert {:ok, client} = WsClient.connect(port, "/ws?token=#{token}")
    client = WsClient.send_json(client, %{"t" => "ping"})
    assert {%{"t" => "pong"}, _} = Node.await(client, &(&1["t"] == "pong"))
    context
  end

  # --- port, home and bind host -----------------------------------------------------------

  step "no port is configured", context do
    World.put_os_env("HAL_C2_NODE_PORT", nil)
    Map.put(context, :boot_env, :dev)
  end

  step "HAL_C2_NODE_PORT is {int} and HAL_C2_HOME is {string}", %{args: [port, home]} = context do
    clear_home_env()
    World.put_os_env("HAL_C2_NODE_PORT", to_string(port))
    World.put_os_env("HAL_C2_HOME", home)
    Map.put(context, :boot_env, :prod)
  end

  step "the home directory is set with its name from before the rename, T3CODE_HOME={string}",
       %{args: [home]} = context do
    clear_home_env()
    World.put_os_env("T3CODE_HOME", home)
    Map.put(context, :boot_env, :prod)
  end

  step "the bind host is set to {string} in the environment", %{args: [host]} = context do
    World.put_os_env("HAL_C2_NODE_HOST", nil)
    World.put_os_env("HAL_C2_HOST", host)
    Map.put(context, :boot_env, :prod)
  end

  step "it serves clients on port {int}", %{args: [port]} = context do
    assert {_ip, ^port} = listener(boot_config(context.boot_env))
    context
  end

  step "it serves clients on {string}", %{args: [host]} = context do
    {:ok, ip} = :inet.parse_address(String.to_charlist(host))
    assert {^ip, 3780} = listener(boot_config(context.boot_env))
    context
  end

  step "its database, logs and worktrees live under {string}", %{args: [home]} = context do
    boot = boot_config(context.boot_env)
    assert boot[:home] == home

    paths =
      with_app_env([home: home], fn ->
        [
          HalC2.Store.home_path(),
          HalC2.Traces.path(),
          HalC2.ProviderLog.path("thread-1"),
          HalC2.Vcs.worktree_path("/code/app", "feature/login")
        ]
      end)

    for path <- paths, do: assert(String.starts_with?(path, home <> "/"), path)
    context
  end

  step "no home directory is configured", context do
    clear_home_env()
    context
  end

  step "its state lives in the checkout's {string} directory", %{args: [dir]} = context do
    {top, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"], cd: project_dir())
    top = String.trim(top)
    expected = Path.join(top, dir)
    # A checkout that only has the sandbox from before the rename keeps it.
    legacy = Path.join(top, ".t3/elixir")

    if File.dir?(expected) or not File.dir?(legacy),
      do: assert(context.boot[:home] == expected),
      else: assert(context.boot[:home] == legacy)

    context
  end

  step "the user's home holds the node state of an install from before the rename", context do
    user_home = Node.tmp_dir(context.node, "user-home")
    File.mkdir_p!(Path.join(user_home, ".t3/elixir"))
    Map.put(context, :user_home, user_home)
  end

  step "a user starts the node from a release", context do
    user_home = context[:user_home] || Node.tmp_dir(context.node, "user-home")
    Map.merge(context, %{user_home: user_home, boot: release_boot(user_home)})
  end

  step "its state lives in {string}", %{args: ["~/" <> rest]} = context do
    assert context.boot[:home] == Path.join(context.user_home, rest)
    context
  end

  step "the node starts from a checkout or a release", context do
    World.put_os_env("HAL_C2_HOST", nil)
    World.put_os_env("HAL_C2_NODE_HOST", nil)
    boots = [boot_config(:dev), release_boot(Node.tmp_dir(context.node, "user-home"))]
    Map.put(context, :boots, boots)
  end

  step "only clients on the same machine can reach it", context do
    for boot <- context.boots, do: assert({{127, 0, 0, 1}, _} = listener(boot))

    # The running node, too: its listener is on loopback, and no other address answers.
    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(HalC2.Web.Listener)

    if ip = lan_address() do
      assert {:error, _} = :gen_tcp.connect(ip, port, [], 1_000)
    end

    context
  end

  step "a user starts the node with a LAN or tailnet host address", context do
    ip = lan_address() || flunk("this machine has no non-loopback IPv4 address")
    host = ip |> :inet.ntoa() |> to_string()
    World.put_app_env(:host, host)
    %{context | node: Node.restart(context.node), clients: %{}} |> Map.put(:lan_host, host)
  end

  step "clients on that network can reach it", context do
    assert {:ok, {{200, body}, _}} = lan_request(context, :get, "/.well-known/hal-c2/environment")
    assert JSON.decode!(body)["environmentId"] == context.node.environment
    context
  end

  step "its pairing links use that address", context do
    [link] = World.mix_output(Mix.Tasks.HalC2.Pair, :run, [[]])
    base = "http://#{context.lan_host}:#{context.node.port}/?token="
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

  # --- identity ---------------------------------------------------------------------------

  step "the node starts for the first time", context do
    fresh = Node.tmp_dir(context.node, "fresh-home")
    %{context | node: Node.restart(%{context.node | home: fresh}), clients: %{}}
  end

  step "it writes an access token file readable only by its owner", context do
    path = Path.join(context.node.home, "access-token")
    assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o600
    Map.put(context, :token_file, path)
  end

  step "local tools connect with that token", context do
    token = File.read!(context.token_file)
    assert {:ok, client} = WsClient.connect(context.node.port, "/ws?token=#{token}")
    client = WsClient.send_json(client, %{"t" => "ping"})
    assert {%{"t" => "pong"}, _} = Node.await(client, &(&1["t"] == "pong"))
    context
  end

  step "the node started once and recorded its environment id", context do
    # A fresh process: nothing cached from an earlier node in this VM.
    :persistent_term.erase({HalC2.Environment, :id})
    context = %{context | node: Node.restart(context.node), clients: %{}}

    {200, _, %{"environmentId" => id}} =
      Node.request(context.node, :get, "/.well-known/hal-c2/environment")

    assert File.read!(Path.join(context.node.home, "environment-id")) == id
    Map.put(context, :environment_id, id)
  end

  step "the node restarts on another port", context do
    old_port = context.node.port
    # A new process reads its identity from the home again.
    :persistent_term.erase({HalC2.Environment, :id})
    node = Node.restart(%{context.node | port: 0})
    assert node.port != old_port
    %{context | node: node, clients: %{}}
  end

  step "it reports the same environment id", context do
    assert {200, _, %{"environmentId" => id}} =
             Node.request(context.node, :get, "/.well-known/hal-c2/environment")

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

  step "a client reads the node's environment descriptor", context do
    assert {200, _, descriptor} =
             Node.request(context.node, :get, "/.well-known/hal-c2/environment")

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
    assert d["environmentId"] == context.node.environment
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

  step "it lists the node's capabilities", context do
    capabilities = context.descriptor["capabilities"]
    assert capabilities["serverResolvedCommandContext"] == true
    assert capabilities["attachmentUploads"] == true
    # A checkout cannot install versions, so it does not offer to.
    refute Map.has_key?(capabilities, "serverSelfUpdate")
    context
  end

  # --- the service wrapper ----------------------------------------------------------------

  step "the node runs under the service wrapper", context do
    bin = Path.join(Node.tmp_dir(context.node, "release"), "bin")
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

  step "the node exits asking for a restart", context do
    {_, status} = System.cmd(context.wrapper.path, ["--flag"], env: [{"HAL_C2_SERVICE", nil}])
    Map.put(context, :wrapper_status, status)
  end

  step "the wrapper starts the node again", context do
    assert ["start --flag service=1", "start --flag service=1"] =
             context.wrapper.log |> File.read!() |> String.split("\n", trim: true)

    context
  end

  step "any other exit stops the wrapper", context do
    assert context.wrapper_status == 3
    context
  end

  step "a user asks to install the background service", context do
    Node.release(context.node, service: false)
    user_home = Node.tmp_dir(context.node, "user-home")
    World.put_app_env(:service_user_home, user_home)
    World.put_app_env(:service_platform, {:unix, :linux})
    tools = fake_service_manager(context)
    assert {:ok, status} = HalC2.Service.install()
    Map.merge(context, %{service: status, service_tools: tools})
  end

  step "the node is registered with the system's service manager", context do
    unit = File.read!(context.service["unitPath"])
    release = System.get_env("RELEASE_ROOT")
    assert unit =~ "ExecStart=#{release}/bin/hal-c2-service"
    assert unit =~ "Environment=HAL_C2_NODE_HOME=#{context.node.home}"
    assert context.service["installed"] and context.service["current"]
    assert "--user daemon-reload" in calls(context)
    assert "--user restart hal-c2.service" in calls(context)
    context
  end

  step "it starts on login", context do
    assert File.read!(context.service["unitPath"]) =~ "WantedBy=default.target"
    assert "--user enable hal-c2.service" in calls(context)
    # Lingering keeps it running after the user logs out.
    assert File.exists?(Path.join(Path.dirname(context.service_tools), "linger"))
    context
  end

  step "the user can see its status and remove it again", context do
    assert %{"installed" => true, "current" => true, "logPath" => log} = HalC2.Service.status()
    assert log == Path.join([context.node.home, "logs", "boot-service.log"])

    assert :ok = HalC2.Service.uninstall()
    assert "--user disable --now hal-c2.service" in calls(context)
    refute HalC2.Service.status()["installed"]

    refute File.exists?(context.service["unitPath"])
    # The node's state stays.
    assert File.exists?(Path.join(context.node.home, "hal-c2.sqlite"))
    context
  end

  # --- release packaging and sidecars -----------------------------------------------------

  step "a maintainer builds a release bundle", context do
    root = Node.tmp_dir(context.node, "rel")
    version = HalC2.Upgrade.version()

    for dir <- ["bin", "lib/hal_c2-#{version}/ebin", "releases/#{version}", "erts-17.0.5/bin"],
        do: File.mkdir_p!(Path.join(root, dir))

    File.write!(Path.join(root, "releases/start_erl.data"), "17.0.5 #{version}\n")

    File.write!(
      Path.join([root, "releases", version, "upgrade.json"]),
      JSON.encode!(Node.manifest(version))
    )

    out = Node.tmp_dir(context.node, "out")
    path = Mix.Tasks.HalC2.Bundle.bundle(out, root)
    Map.merge(context, %{bundle: path, bundle_out: out, bundle_version: version})
  end

  step "it writes one archive named for the version and platform", context do
    name = "hal-c2-node-#{context.bundle_version}-#{HalC2.Upgrade.platform()}.tar.gz"
    assert Path.basename(context.bundle) == name
    assert Path.wildcard(Path.join(context.bundle_out, "*.tar.gz")) == [context.bundle]
    {:ok, entries} = :erl_tar.table(String.to_charlist(context.bundle), [:compressed])
    entries = Enum.map(entries, &to_string/1)
    assert Enum.any?(entries, &String.starts_with?(&1, "releases/#{context.bundle_version}"))
    assert Enum.any?(entries, &String.starts_with?(&1, "erts-17.0.5"))
    context
  end

  step "a SHA-256 file beside it", context do
    sum = :crypto.hash(:sha256, File.read!(context.bundle)) |> Base.encode16(case: :lower)

    assert File.read!(context.bundle <> ".sha256") ==
             "#{sum}  #{Path.basename(context.bundle)}\n"

    context
  end

  step "the machine has Node {int} or newer", %{args: [major]} = context do
    node = System.find_executable("node") || flunk("node is not installed")
    {"v" <> version, 0} = System.cmd(node, ["--version"])
    assert version |> String.split(".") |> hd() |> String.to_integer() >= major
    World.put_os_env("HAL_C2_NODE_COMMAND", nil)
    Node.ensure(HalC2.Settings)
    context
  end

  step "the node needs the Cursor provider", context do
    # The release's own layout (`lib/hal_c2-<version>/priv`, where mix.exs stages the
    # sidecar), put first on the code path so the application resolves to it.
    lib =
      Path.join([Node.tmp_dir(context.node, "rel"), "lib", "hal_c2-#{HalC2.Upgrade.version()}"])

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

  step "the desktop app names its Electron binary for the node", context do
    electron = "/Applications/HAL-C2.app/Contents/MacOS/HAL-C2"
    World.put_os_env("HAL_C2_NODE_COMMAND", electron)
    World.put_os_env("HAL_C2_NODE_ELECTRON", "1")
    Node.ensure(HalC2.Settings)
    Map.put(context, :electron, electron)
  end

  step "the node starts a JavaScript sidecar", context do
    Map.put(context, :acp_command, HalC2.Acp.command("cursor"))
  end

  step "it runs it with that binary in Node mode", context do
    assert {:ok, [binary | _], env} = context.acp_command
    assert binary == context.electron
    assert {"ELECTRON_RUN_AS_NODE", "1"} in env
    # Only the sidecar runs as Node; the node's own environment (and its terminals) do not.
    assert System.get_env("ELECTRON_RUN_AS_NODE") == nil
    context
  end

  # --- the desktop bootstrap --------------------------------------------------------------

  step "the desktop app launches the node in bootstrap mode", context do
    World.put_os_env("HAL_C2_BOOTSTRAP_STDIN", "1")
    # Everything the bootstrap sets comes back when the scenario ends.
    for key <- [:home, :port, :host, :desktop_token],
        do: World.put_app_env(key, Application.get_env(:hal_c2, key))

    context
  end

  step "it writes the port, host, HAL-C2 home and bootstrap token as one line on standard input",
       context do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    hal_c2_home = Node.tmp_dir(context.node, "desktop-hal-c2")
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

    # The node's services come up under what the bootstrap configured, as they do
    # after `HalC2.Desktop.configure/0` in `HalC2.Application`.
    for child <- [HalC2.Web, HalC2.Shell, HalC2.Streams, HalC2.Auth, HalC2.Store],
        do: ExUnit.Callbacks.stop_supervised(child)

    :persistent_term.erase({HalC2.Web, :token})

    for child <- [
          {HalC2.Store, path: HalC2.Store.home_path()},
          HalC2.Auth,
          HalC2.Streams,
          HalC2.Shell,
          HalC2.Web
        ],
        do: Node.ensure(child)

    Map.merge(context, %{desktop: %{port: port, hal_c2_home: hal_c2_home, token: token}})
  end

  step "the node listens on that host and port", context do
    port = context.desktop.port
    assert {:ok, {{127, 0, 0, 1}, ^port}} = ThousandIsland.listener_info(HalC2.Web.Listener)

    assert {200, _, %{"environmentId" => _}} =
             Node.request(%{port: port}, :get, "/.well-known/hal-c2/environment")

    # The window pairs with the token it passed.
    assert {200, %{"access_token" => _}} = Node.exchange(%{port: port}, context.desktop.token)
    context
  end

  step "keeps its state under the {string} directory of that HAL-C2 home",
       %{args: [dir]} = context do
    home = Path.join(context.desktop.hal_c2_home, dir)
    assert Application.fetch_env!(:hal_c2, :home) == home
    assert HalC2.Store.home_path() == Path.join(home, "hal-c2.sqlite")
    assert File.exists?(Path.join(home, "access-token"))
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

  # --- importing a Node server's history --------------------------------------------------

  step "a consistent snapshot of a TypeScript server's database", context do
    source = Path.join(Node.tmp_dir(context.node, "ts"), "state.sqlite")

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

  step "an operator imports it into the node's home", context do
    # The import runs offline, against a stopped node's store.
    for child <- [HalC2.Web, HalC2.Shell, HalC2.Streams, HalC2.Auth, HalC2.Store],
        do: ExUnit.Callbacks.stop_supervised(child)

    lines = World.mix_output(Mix.Tasks.HalC2.Import, :run, [[context.ts_source]])
    GenServer.stop(HalC2.Store)

    Map.merge(context, %{
      import_output: Enum.join(lines, "\n"),
      node: Node.start(context.node.home)
    })
  end

  step "every thread stream is copied into the node's store", context do
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

  step "the home directory holds cluster boot arguments", context do
    home = Node.tmp_dir(context.node, "clustered")
    :ok = HalC2.Cluster.init(home, "100.64.0.9")
    Map.put(context, :cluster_home, home)
  end

  step "the release starts", context do
    Map.put(context, :release_env, release_env(context.cluster_home))
  end

  step "it starts with cluster distribution over mutual TLS", context do
    args_file = Path.join([context.cluster_home, "cluster", "vm.args"])
    assert context.release_env["ELIXIR_ERL_OPTIONS"] =~ "-args_file #{args_file}"
    # The release script starts no distribution of its own; the flags do.
    assert context.release_env["RELEASE_DISTRIBUTION"] == "none"

    args = File.read!(args_file)
    assert args =~ "-proto_dist inet_tls"
    assert args =~ "-name hal_c2@100.64.0.9"
    [_, conf_file] = Regex.run(~r/-ssl_dist_optfile (\S+)/, args)
    {:ok, [conf]} = :file.consult(String.to_charlist(conf_file))
    assert conf[:server][:verify] == :verify_peer
    assert conf[:server][:fail_if_no_peer_cert] == true
    assert conf[:client][:verify] == :verify_peer
    context
  end

  step "without them it starts with distribution off", context do
    env = release_env(Node.tmp_dir(context.node, "standalone"))
    assert env["RELEASE_DISTRIBUTION"] == "none"
    refute (env["ELIXIR_ERL_OPTIONS"] || "") =~ "-args_file"
    context
  end

  # --- helpers ----------------------------------------------------------------------------

  defp project_dir, do: Path.dirname(Mix.Project.project_file())

  # The `:hal_c2` config a node boots with in `env`, from the current process environment.
  defp boot_config(env) do
    config = Path.join(project_dir(), "config")
    base = Config.Reader.read!(Path.join(config, "config.exs"), env: env, target: :host)
    runtime = Config.Reader.read!(Path.join(config, "runtime.exs"), env: env, target: :host)
    Config.Reader.merge(base, runtime)[:hal_c2]
  end

  # Every variable that names the node's home, now and from before the rename.
  @home_env ~w(HAL_C2_NODE_HOME HAL_C2_HOME T3_HOME T3CODE_HOME)

  defp clear_home_env, do: for(name <- @home_env, do: World.put_os_env(name, nil))

  # A release boots with the HAL_C2_NODE_HOME its env.sh settles on for this user.
  defp release_boot(user_home) do
    home = release_env(nil, [{"HOME", user_home}])["HAL_C2_NODE_HOME"]
    previous = System.get_env("HAL_C2_NODE_HOME")
    System.put_env("HAL_C2_NODE_HOME", home)

    try do
      boot_config(:prod)
    after
      if previous,
        do: System.put_env("HAL_C2_NODE_HOME", previous),
        else: System.delete_env("HAL_C2_NODE_HOME")
    end
  end

  # What rel/env.sh.eex exports, sourced the way the release script does, with
  # `node_home` as the node's state directory (nil: the script resolves it).
  defp release_env(node_home, env \\ []) do
    script = Path.join(project_dir(), "rel/env.sh.eex")

    {out, 0} =
      System.cmd(
        "sh",
        [
          "-c",
          ~s(. "$0"; printf '%s\\n' "$HAL_C2_NODE_HOME" "$RELEASE_DISTRIBUTION" "${ELIXIR_ERL_OPTIONS:-}"),
          script
        ],
        env:
          [
            {"HAL_C2_NODE_HOME", node_home},
            {"RELEASE_DISTRIBUTION", nil},
            {"ELIXIR_ERL_OPTIONS", nil}
          ] ++ for(name <- @home_env -- ["HAL_C2_NODE_HOME"], do: {name, nil}) ++ env
      )

    [home, dist, opts] = String.split(out, "\n") |> Enum.take(3)
    %{"HAL_C2_NODE_HOME" => home, "RELEASE_DISTRIBUTION" => dist, "ELIXIR_ERL_OPTIONS" => opts}
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
    url = ~c"http://#{context.lan_host}:#{context.node.port}#{path}"

    request =
      if form,
        do: {url, [], ~c"application/x-www-form-urlencoded", form},
        else: {url, []}

    case :httpc.request(method, request, [], body_format: :binary) do
      {:ok, {{_, status, _}, headers, body}} -> {:ok, {{status, body}, headers}}
      other -> other
    end
  end

  # systemctl and loginctl stand-ins on PATH: they log their arguments and keep the
  # unit's enabled and active state in files, so status reads what install did.
  defp fake_service_manager(context) do
    bin = Node.tmp_dir(context.node, "service-bin")
    File.mkdir_p!(bin)
    log = Path.join(bin, "calls.log")

    File.write!(Path.join(bin, "systemctl"), """
    #!/bin/sh
    echo "$*" >> "#{log}"
    state="#{bin}"
    case "$2" in
      enable) touch "$state/enabled" ;;
      restart) touch "$state/active" ;;
      disable) rm -f "$state/enabled" "$state/active" ;;
      is-enabled) [ -f "$state/enabled" ] || exit 1 ;;
      is-active) [ -f "$state/active" ] || exit 3 ;;
    esac
    exit 0
    """)

    File.write!(Path.join(bin, "loginctl"), """
    #!/bin/sh
    case "$1" in
      enable-linger) touch "#{bin}/linger" ;;
      show-user) [ -f "#{bin}/linger" ] && echo Linger=yes || echo Linger=no ;;
    esac
    """)

    for tool <- ["systemctl", "loginctl"], do: File.chmod!(Path.join(bin, tool), 0o755)
    World.put_os_env("PATH", bin <> ":" <> System.get_env("PATH"))
    log
  end

  defp calls(context),
    do: context.service_tools |> File.read!() |> String.split("\n", trim: true)

  # The TypeScript server's event table (apps/server's orchestration_events).
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
