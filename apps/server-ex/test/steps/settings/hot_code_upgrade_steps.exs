defmodule HalC2.Steps.Settings.HotCodeUpgrade do
  @moduledoc """
  Steps for features/settings/hot-code-upgrade.feature, and the release the
  background service and update scenarios share.

  The node runs from a release root on disk (`RELEASE_ROOT`) whose only code of
  its own is a probe module reporting the version it was built as. A later
  version is a bundle holding the probe rebuilt; a bundle that "changes a native
  library" differs in its manifest's `nifs`, which forces a restart. The service
  is the real `bin/hal-c2-service` around a stand-in `bin/hal_c2` that logs each boot and
  runs until the node signals the stop an update restart makes.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Node
  alias HalC2.Test.Node.World
  alias HalC2.Upgrade
  alias HalC2.Upgrade.Source

  @probe HalC2.Steps.Settings.HotCodeUpgrade.Probe
  @service Path.expand("../../../rel/overlays/bin/hal-c2-service", __DIR__)
  @echo Path.expand("../../support/echo_rpc.py", __DIR__)
  @unreachable "http://127.0.0.1:1/hal-c2-node-{version}-{platform}.tar.gz"

  # Stands in for the release's bin/hal_c2: logs the version start_erl.data names, then
  # fails if that version is marked broken, or runs until the node stops (a line
  # with the exit status on the `running` fifo), or stops at once.
  @fake_hal_c2 """
  #!/bin/sh
  root="$(cd "$(dirname "$0")/.." && pwd)"
  vsn="$(cut -d' ' -f2 "$root/releases/start_erl.data")"
  echo "$vsn" >> "$root/boots.log"
  echo "booted $vsn"
  [ -e "$root/broken-$vsn" ] && exit 1
  if [ -p "$root/running" ]; then
    status="$(cat "$root/running")"
    rm -f "$root/running"
    exit "$status"
  fi
  exit 0
  """

  # --- the release, shared with the other settings steps ------------------------------

  @doc """
  Makes the scenario's node run release `version` from a release root under its
  home, with `HalC2.Upgrade` and `HalC2.Settings` started. Kept in `context.release`
  (`%{root, version}`); a scenario that has one keeps it.
  """
  def running_release(context, version \\ "1.3.0")
  def running_release(%{release: %{}} = context, _version), do: context

  def running_release(context, version) do
    root = Node.tmp_dir(context.node, "release")
    release_root(root, version)
    File.mkdir_p!(Path.join(root, "bin"))
    File.cp!(@service, Path.join([root, "bin", "hal-c2-service"]))
    File.write!(Path.join([root, "bin", "hal_c2"]), @fake_hal_c2)
    File.chmod!(Path.join([root, "bin", "hal_c2"]), 0o755)
    World.put_env("RELEASE_ROOT", root)

    # Loading in place moves code paths and reloads the probe.
    path = :code.get_path()
    Code.put_compiler_option(:ignore_module_conflict, true)

    ExUnit.Callbacks.on_exit(fn ->
      :code.set_path(path)
      Code.put_compiler_option(:ignore_module_conflict, false)
      :code.purge(@probe)
      :code.delete(@probe)
      :persistent_term.erase({Upgrade, :version})
      :persistent_term.erase({Upgrade, :outcome})
    end)

    :persistent_term.erase({Upgrade, :outcome})
    :persistent_term.put({Upgrade, :version}, version)
    compile_probe(version)
    Node.ensure(HalC2.Settings)
    Node.ensure(HalC2.Upgrade)
    Map.put(context, :release, %{root: root, version: version})
  end

  @doc """
  Builds the bundle of `version` (`:hot` changes only the probe's code, `:native`
  also its native library) and returns `{context, archive}`, the archive with its
  `.sha256` beside it, in no node's cache yet.
  """
  def bundle(context, version, kind) do
    context = running_release(context)
    dir = Node.tmp_dir(context.node, "bundle")
    ebin = Path.join([dir, "lib", "hal_c2_probe-#{version}", "ebin"])
    File.mkdir_p!(ebin)
    [{mod, bin}] = compile_probe(version)
    File.write!(Path.join(ebin, "#{mod}.beam"), bin)
    # The running version stays loaded.
    compile_probe(Upgrade.version())
    write_manifest(dir, version, if(kind == :native, do: "changed", else: "same"))

    archive =
      Path.join(
        Node.tmp_dir(context.node, "build"),
        Source.file_name(version, Upgrade.platform())
      )

    :ok =
      :erl_tar.create(
        String.to_charlist(archive),
        for(entry <- ["lib", "releases"], do: {~c"#{entry}", ~c"#{Path.join(dir, entry)}"}),
        [:compressed]
      )

    File.write!(archive <> ".sha256", sha256(archive))
    {context, archive}
  end

  @doc "Builds the bundle of `version` and puts it in this node's cache."
  def cached_bundle(context, version, kind) do
    {context, archive} = bundle(context, version, kind)
    :ok = Source.put(version, Upgrade.platform(), archive)
    context
  end

  @doc """
  Starts `bin/hal-c2-service` for the scenario's release and waits for its first boot.
  The node's update restart (`:restart_exit`) ends that boot with its status.
  """
  def start_service(context) do
    context = running_release(context)
    root = context.release.root
    fifo = Path.join(root, "running")
    {_, 0} = System.cmd("mkfifo", [fifo])
    World.put_env("HAL_C2_SERVICE", "1")
    World.put_app_env(:restart_exit, &stop_boot(fifo, &1))

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [Path.join([root, "bin", "hal-c2-service"])]
      ])

    # A scenario that ends before the update lets the first boot go.
    ExUnit.Callbacks.on_exit(fn -> if File.exists?(fifo), do: stop_boot(fifo, 0) end)
    await_output(port, "booted #{context.release.version}")
    put_in(context, [:release, :service], port)
  end

  @doc "Waits for the service to exit; returns its status."
  def await_service(context), do: await_exit(context.release.service)

  @doc "The versions the service booted, in order."
  def boots(context) do
    Path.join(context.release.root, "boots.log")
    |> File.read!()
    |> String.split()
  end

  @doc "The version `releases/start_erl.data` names."
  def start_version(context) do
    Path.join([context.release.root, "releases", "start_erl.data"])
    |> File.read!()
    |> String.split()
    |> List.last()
  end

  @doc """
  Starts the scenario's node again as `version` booted by the service, as the
  release would after an update restart. Clients reconnect afterwards.
  """
  def boot_as(context, version) do
    ExUnit.Callbacks.stop_supervised(HalC2.Upgrade)
    :persistent_term.erase({Upgrade, :outcome})
    :persistent_term.put({Upgrade, :version}, version)
    compile_probe(version)
    node = Node.restart(context.node)
    Node.ensure(HalC2.Upgrade)
    # The outcome is settled once the updater has started.
    :sys.get_state(HalC2.Upgrade)
    %{context | node: node, clients: %{}}
  end

  @doc "The `updateOutcome` a client subscribing to the node's config is sent."
  def update_outcome(context) do
    client =
      Node.sub(World.client(context), 1, %{"type" => "config", "node" => Atom.to_string(node())})

    {frame, _client} = Node.await(client, &(&1["t"] == "config"))
    frame["updateOutcome"]
  end

  @doc "Asks `server.updateServer` for `version`; the reply is `context.reply`."
  def update_to(context, version) do
    {reply, context} = World.call(context, "server.updateServer", %{"targetVersion" => version})
    Map.put(context, :reply, reply)
  end

  # --- steps --------------------------------------------------------------------------------

  step "a node running release {string}", %{args: [version]} = context do
    context = running_release(context, version)
    assert Upgrade.version() == version
    assert apply(@probe, :version, []) == version
    context
  end

  # The node has a socket, a terminal and an agent session open when the update comes.
  step "release {string} changes only code", %{args: [version]} = context do
    context |> cached_bundle(version, :hot) |> open_sessions()
  end

  step "release {string} changes a native library", %{args: [version]} = context do
    cached_bundle(context, version, :native)
  end

  step "the node runs under its service", context do
    start_service(context)
  end

  # The bundle installs, but the version it names exits as soon as it starts.
  step "release {string} cannot boot", %{args: [version]} = context do
    context = cached_bundle(context, version, :native)
    File.write!(Path.join(context.release.root, "broken-#{version}"), "")
    start_service(context)
  end

  step "the user updates the node to {string}", %{args: [version]} = context do
    update_to(context, version)
  end

  step "the node runs {string}", %{args: [version]} = context do
    assert {:ok, %{"targetVersion" => ^version, "method" => "hot-upgrade"}} = context.reply
    assert Upgrade.version() == version
    assert apply(@probe, :version, []) == version
    assert start_version(context) == version
    assert %{"status" => "committed", "targetVersion" => ^version} = Upgrade.outcome()
    context
  end

  step "open connections, terminals and agent sessions stay up", context do
    %{terminal: terminal, shell: shell, conn: conn, os_pid: os_pid} = context.sessions

    client = HalC2.Test.WsClient.send_json(World.client(context), %{"t" => "ping"})
    {%{"t" => "pong"}, client} = HalC2.Test.WsClient.recv(client, 1_000)
    assert {:ok, %{"status" => "running", "pid" => ^shell}} = HalC2.Terminal.open(terminal)
    assert HalC2.JsonRpc.Connection.os_pid(conn) == os_pid
    assert {:ok, %{"params" => 2}} = HalC2.JsonRpc.Connection.call(conn, "echo", 2)
    World.put_client(context, client)
  end

  step "the node installs {string} and restarts", %{args: [version]} = context do
    assert {:ok, %{"targetVersion" => ^version}} = context.reply
    assert File.dir?(Path.join([context.release.root, "lib", "hal_c2_probe-#{version}", "ebin"]))
    assert await_service(context) == 0
    assert boots(context) == [context.release.version, version]
    assert start_version(context) == version
    boot_as(context, version)
  end

  step "after reconnecting the client is told the update committed", context do
    version = start_version(context)

    assert %{"status" => "committed", "fromVersion" => "1.3.0", "targetVersion" => ^version} =
             update_outcome(context)

    # The version that booted no longer needs the one it replaced.
    refute File.exists?(Path.join([context.release.root, "releases", "start_erl.data.previous"]))
    context
  end

  step "the node comes back on {string}", %{args: [version]} = context do
    assert {:ok, %{"targetVersion" => target}} = context.reply
    assert await_service(context) == 0
    assert boots(context) == [version, target, version]
    assert start_version(context) == version
    context = boot_as(context, version)
    assert Upgrade.version() == version
    context
  end

  step "the client is told the update rolled back", context do
    assert %{"status" => "rolled-back", "targetVersion" => "1.4.0", "reason" => reason} =
             update_outcome(context)

    assert reason =~ "started 1.3.0 instead of 1.4.0"
    context
  end

  # --- continuing cut-off turns ----------------------------------------------------------

  # The continuation's turn starts no real Codex.
  step "continuing threads after restarts is on for the project", context do
    World.put_app_env(:codex_command, ["hal-c2-test-no-codex"])
    context = World.create_project(context, "shop")

    World.update_settings(context, %{
      "projectSettingsOverrides" => %{
        World.project(context, "shop").id => %{"continueThreadsAfterServerUpdate" => true}
      }
    })
  end

  step "an agent is mid-turn in thread {string}", %{args: [title]} = context do
    context |> World.create_thread(title, "shop") |> mid_turn(title)
  end

  # Beside the scenario's thread, the node has cut-off turns the user moved on from:
  # one written in since (a newer queued message), one archived, one deleted.
  step "the node restarts to finish an update", context do
    context =
      for title <- ["Wrote since", "Archived", "Deleted"], reduce: context do
        context -> context |> World.create_thread(title, "shop") |> mid_turn(title)
      end

    context = World.add_run(context, "Wrote since", "queued")
    context = World.patch_thread(context, "Archived", %{"archivedAt" => World.iso_from_now(0)})
    deleted = World.thread_id(context, "Deleted")

    {:ok, _} = HalC2.Orchestration.dispatch(%{"type" => "thread.delete", "threadId" => deleted})
    World.await_row(deleted, & &1["deletedAt"])

    %{context | node: Node.restart(context.node), clients: %{}}
  end

  step "{string} is asked to continue where it left off", %{args: [title]} = context do
    assert [%{"createdBy" => "agent"}] = continuations(context, title)
    context
  end

  step "a thread the user wrote in since, archived or deleted is left alone", context do
    for title <- ["Wrote since", "Archived", "Deleted"],
        do: assert(continuations(context, title) == [], "#{title} was asked to continue")

    context
  end

  # --- where the release comes from ---------------------------------------------------------

  step "a cluster peer already downloaded {string}", %{args: [version]} = context do
    # Connected first: once the peer is up this process also hears of its node, which
    # the client's upgrade handshake cannot tell from socket messages.
    context = World.put_client(context, World.client(context))
    {context, archive} = bundle(context, version, :hot)
    peer = start_peer(context, "peer")
    :ok = :erpc.call(peer, Source, :put, [version, Upgrade.platform(), archive])
    World.put_env("HAL_C2_UPGRADE_URL", @unreachable)
    Map.merge(context, %{peers: [peer], build: archive})
  end

  step "the node fetches the release from the peer instead of the internet", context do
    assert {:ok, %{"targetVersion" => version}} = context.reply
    assert Upgrade.version() == version
    assert cached_sha256(version) == sha256(context.build)
    context
  end

  step "the downloaded {string} release does not match its checksum",
       %{args: [version]} = context do
    {context, archive} = bundle(context, version, :hot)
    File.write!(archive <> ".sha256", String.duplicate("0", 64))

    {:ok, {_ip, port}} =
      ThousandIsland.listener_info(
        Node.ensure(
          {Bandit,
           plug: {Plug.Static, at: "/", from: Path.dirname(archive)},
           ip: :loopback,
           port: 0,
           startup_log: false}
        )
      )

    World.put_env(
      "HAL_C2_UPGRADE_URL",
      "http://127.0.0.1:#{port}/hal-c2-node-{version}-{platform}.tar.gz"
    )

    context
  end

  step "the update fails and the node keeps running {string}", %{args: [version]} = context do
    assert {:error, "ServerSelfUpdateError", %{"reason" => reason}} = context.reply
    assert reason =~ "does not match its checksum"
    assert Upgrade.version() == version
    assert apply(@probe, :version, []) == version
    refute File.exists?(Path.join([context.release.root, "lib", "hal_c2_probe-1.4.0"]))
    context
  end

  # --- refusals -----------------------------------------------------------------------------

  step "the node runs from a source checkout", context do
    System.delete_env("RELEASE_ROOT")
    assert Upgrade.capability() == nil
    context
  end

  step "the node already runs {string}", %{args: [version]} = context do
    assert Upgrade.version() == version
    context
  end

  # The bundle needs a restart, and nothing started the node that would do one.
  step "the node was not started by its service", context do
    World.put_env("HAL_C2_SERVICE", "0")
    cached_bundle(context, "1.4.0", :native)
  end

  step ~r/^the user is told the update cannot run because (?<reason>.+)$/,
       %{args: [reason]} = context do
    expected =
      case reason do
        "a checkout updates with mix hal_c2.upgrade" -> "update it with `mix hal_c2.upgrade`"
        "it already runs that version" -> "already runs 1.3.0"
        "nothing would restart it" -> "was not started by bin/hal-c2-service"
      end

    assert {:error, "ServerSelfUpdateError", %{"reason" => message}} = context.reply
    assert message =~ expected
    assert Upgrade.version() == "1.3.0"
    context
  end

  # --- a cluster ------------------------------------------------------------------------------

  step "three connected nodes", context do
    context = running_release(context)
    peers = for name <- ["b", "c"], do: start_peer(context, name)
    # Peers reach this node's HTTP port for the build.
    World.put_app_env(:port, context.node.port)
    assert Enum.sort(Elixir.Node.list()) == Enum.sort(peers)
    Map.put(context, :peers, peers)
  end

  step "the developer upgrades the cluster to a new build", context do
    {context, archive} = bundle(context, "1.3.1", :hot)
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    ExUnit.Callbacks.on_exit(fn -> Mix.shell(shell) end)
    Mix.Tasks.HalC2.Upgrade.release([node() | context.peers], archive)
    Map.put(context, :build, archive)
  end

  step "the first node receives the build", context do
    assert_received {:mix_shell, :info, [line]}
    assert line == "#{node()}: hot-upgrade to 1.3.1"
    assert cached_sha256("1.3.1") == sha256(context.build)
    assert Upgrade.version() == "1.3.1"
    assert apply(@probe, :version, []) == "1.3.1"
    context
  end

  # Each peer knows only the first node, and the release download is unreachable.
  step "the other nodes fetch it from the first", context do
    sum = sha256(context.build)

    for peer <- context.peers do
      assert_received {:mix_shell, :info, [line]}
      assert line == "#{peer}: hot-upgrade to 1.3.1"
      assert :erpc.call(peer, Elixir.Node, :list, []) == [node()]
      assert :erpc.call(peer, Upgrade, :version, []) == "1.3.1"
      assert :erpc.call(peer, @probe, :version, []) == "1.3.1"
      home = :erpc.call(peer, Application, :fetch_env!, [:hal_c2, :home])

      archive =
        Path.join([home, "upgrades", "1.3.1", Source.file_name("1.3.1", Upgrade.platform())])

      assert sha256(archive) == sum
    end

    context
  end

  # --- helpers ------------------------------------------------------------------------------

  defp release_root(root, version) do
    File.mkdir_p!(Path.join(root, "releases"))
    File.mkdir_p!(Path.join(root, "lib"))
    write_manifest(root, version, "same")

    File.write!(
      Path.join([root, "releases", "start_erl.data"]),
      "#{:erlang.system_info(:version)} #{version}\n"
    )
  end

  defp write_manifest(dir, version, nifs) do
    rel = Path.join([dir, "releases", version])
    File.mkdir_p!(rel)

    File.write!(
      Path.join(rel, "upgrade.json"),
      JSON.encode!(%{
        "version" => version,
        "otpRelease" => System.otp_release(),
        "erts" => to_string(:erlang.system_info(:version)),
        "platform" => Upgrade.platform(),
        "applications" => %{"hal_c2_probe" => version},
        "nifs" => %{"hal_c2_probe" => nifs},
        "config" => "same"
      })
    )
  end

  defp compile_probe(version) do
    Code.compile_string("""
    defmodule #{inspect(@probe)} do
      def version, do: #{inspect(version)}
    end
    """)
  end

  defp sha256(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  defp cached_sha256(version) do
    Path.join([
      Application.fetch_env!(:hal_c2, :home),
      "upgrades",
      version,
      Source.file_name(version, Upgrade.platform())
    ])
    |> sha256()
  end

  defp open_sessions(context) do
    World.put_env("SHELL", "/bin/sh")
    Node.ensure({Registry, keys: :unique, name: HalC2.Terminal.Registry})
    Node.ensure({DynamicSupervisor, name: HalC2.Terminal.Supervisor, strategy: :one_for_one})
    Node.ensure(HalC2.Terminal.Hub)
    terminal = %{"threadId" => "th-upgrade", "terminalId" => "term-1", "cwd" => context.node.home}
    assert {:ok, %{"status" => "running", "pid" => shell}} = HalC2.Terminal.open(terminal)

    conn =
      Node.ensure({HalC2.JsonRpc.Connection, cmd: ["python3", "-u", @echo], handler: self()})

    assert {:ok, _} = HalC2.JsonRpc.Connection.call(conn, "echo", 1)

    context
    |> World.put_client(World.client(context))
    |> Map.put(:sessions, %{
      terminal: terminal,
      shell: shell,
      conn: conn,
      os_pid: HalC2.JsonRpc.Connection.os_pid(conn)
    })
  end

  defp mid_turn(context, title) do
    provider_thread = "pt-#{World.slug(title)}"

    {:ok, _} =
      HalC2.Streams.commit(World.thread_id(context, title), :thread, [
        {"provider-thread", provider_thread,
         %{
           "s" => %{
             "id" => provider_thread,
             "status" => "active",
             "nativeThreadRef" => %{"type" => "codex", "threadId" => "native-#{provider_thread}"}
           }
         }}
      ])

    World.add_run(context, title, "running", nil, %{"providerThreadId" => provider_thread})
  end

  defp continuations(context, title) do
    id = World.thread_id(context, title)

    HalC2.Streams.Server.state(HalC2.Streams.ensure(id))
    |> HalC2.StreamState.list("message")
    |> Enum.filter(&(&1["text"] == "Continue where you left off."))
  end

  # A second BEAM node running this checkout's code with its own home and HTTP
  # listener, on the scenario's release at 1.3.0, connected only to this node.
  defp start_peer(context, name) do
    unless Elixir.Node.alive?() do
      {_, 0} = System.cmd("epmd", ["-daemon"])

      {:ok, _} =
        Elixir.Node.start(
          :"hal_c2_test#{System.unique_integer([:positive])}@127.0.0.1",
          :longnames
        )

      ExUnit.Callbacks.on_exit(fn -> Elixir.Node.stop() end)
    end

    {:ok, _pid, peer} =
      :peer.start_link(%{
        name: :"hal_c2#{name}#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true,
        args: Enum.flat_map(:code.get_path(), &[~c"-pa", &1]) ++ [~c"-connect_all", ~c"false"]
      })

    home = Node.tmp_dir(context.node, "peer-#{name}")
    root = Path.join(home, "release")
    release_root(root, "1.3.0")

    for {key, value} <- [start_node: false, home: home, port: 0],
        do: :ok = :erpc.call(peer, Application, :put_env, [:hal_c2, key, value])

    {:ok, _} = :erpc.call(peer, Application, :ensure_all_started, [:hal_c2])
    {:ok, web} = :erpc.call(peer, Supervisor, :start_child, [HalC2.Supervisor, HalC2.Web])
    {:ok, {_ip, port}} = :erpc.call(peer, ThousandIsland, :listener_info, [web])
    :ok = :erpc.call(peer, Application, :put_env, [:hal_c2, :port, port])
    :ok = :erpc.call(peer, System, :put_env, ["RELEASE_ROOT", root])
    :ok = :erpc.call(peer, System, :put_env, ["HAL_C2_UPGRADE_URL", @unreachable])
    :ok = :erpc.call(peer, :persistent_term, :put, [{Upgrade, :version}, "1.3.0"])

    # The peer runs the probe at 1.3.0 too.
    [{@probe, probe}] = compile_probe("1.3.0")
    {:module, _} = :erpc.call(peer, :code, :load_binary, [@probe, ~c"probe", probe])

    {:ok, _} = :erpc.call(peer, Supervisor, :start_child, [HalC2.Supervisor, HalC2.Upgrade])
    peer
  end

  defp await_output(port, text, seen \\ "") do
    receive do
      {^port, {:data, data}} ->
        seen = seen <> data
        if String.contains?(seen, text), do: seen, else: await_output(port, text, seen)
    after
      5_000 -> flunk("the service never printed #{inspect(text)}; it printed #{inspect(seen)}")
    end
  end

  defp await_exit(port) do
    receive do
      {^port, {:data, _}} -> await_exit(port)
      {^port, {:exit_status, status}} -> status
    after
      10_000 -> flunk("the service did not exit")
    end
  end

  # Ends the service's running boot with `status`, as the node stopping would.
  defp stop_boot(fifo, status),
    do: System.cmd("timeout", ["5", "sh", "-c", "echo #{status} > \"$0\"", fifo])
end
