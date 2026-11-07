defmodule HalC2.Steps.Platform.Upgrades do
  @moduledoc """
  Steps for `features/mc/platform/upgrades.feature`. The MC runs from a release
  laid out in its home (`HalC2.Test.Mc.release/2`); bundles are real releases built
  from variants of loaded modules (`HalC2.Test.Mc.bundle/4`), which the release
  handler installs into this VM, and a restart arrives as `{:hal_c2_restart, status}`
  instead of stopping the VM. A checkout's build is a copy of this one's with
  variants over it.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions
  import ExUnit.CaptureLog, only: [with_log: 1]

  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World
  alias HalC2.Test.WsClient
  alias HalC2.Upgrade
  alias HalC2.Upgrade.Source

  @echo Path.expand("../../support/echo_rpc.py", __DIR__)
  @unreachable "http://127.0.0.1:1/{version}/{platform}.tar.gz"

  step "an MC running from a release under the service wrapper", context do
    root = Mc.release(context.mc)
    Mc.ensure(HalC2.Settings)
    Mc.ensure(HalC2.Upgrade)
    assert Upgrade.capability() == "hot-upgrade"
    Map.put(context, :root, root)
  end

  # --- in place ---------------------------------------------------------------------

  step "a bundle whose changes are only ordinary modules", context do
    conn =
      ExUnit.Callbacks.start_supervised!(
        {HalC2.JsonRpc.Connection, cmd: ["python3", "-u", @echo], handler: self()}
      )

    assert {:ok, _} = HalC2.JsonRpc.Connection.call(conn, "echo", 1)

    context
    |> bundle(%{}, [Mc.variant(HalC2.JsonRpc.Connection)])
    |> Map.merge(%{conn: conn, os_pid: HalC2.JsonRpc.Connection.os_pid(conn)})
  end

  step ~r/^a client asks the MC to update(?: to (?:that version|it))?$/, context do
    input = Map.get_lazy(context, :input, fn -> %{"targetVersion" => context.target} end)

    {{reply, context}, log} =
      with_log(fn -> World.call(context, "server.updateServer", input) end)

    Map.merge(context, %{reply: reply, log: log})
  end

  step "the MC loads the changed modules in place", context do
    assert {:ok, %{"method" => "hot-upgrade", "targetVersion" => target}} = context.reply
    assert target == context.target
    assert function_exported?(HalC2.JsonRpc.Connection, :__hal_c2_variant__, 0)
    refute_received {:hal_c2_restart, _}
    context
  end

  step "open sockets and provider sessions stay up", context do
    assert HalC2.JsonRpc.Connection.os_pid(context.conn) == context.os_pid
    assert {:ok, %{"params" => 2}} = HalC2.JsonRpc.Connection.call(context.conn, "echo", 2)
    client = WsClient.send_json(World.client(context), %{"t" => "ping"})
    {_, client} = Mc.await(client, &(&1["t"] == "pong"))
    World.put_client(context, client)
  end

  step "the MC reports the new version", context do
    assert Upgrade.version() == context.target

    assert {200, _, %{"serverVersion" => version}} =
             Mc.request(context.mc, :get, "/.well-known/hal-c2/environment")

    assert version == context.target
    context
  end

  step "a client asks the MC to update with progress", context do
    context = bundle(context)

    shape = %{
      "type" => "serverUpdate",
      "mc" => Atom.to_string(node()),
      "input" => %{"targetVersion" => context.target}
    }

    client = World.client(context) |> Mc.sub(5, shape)

    {_end, frames, client} =
      WsClient.recv_until(client, &(&1["t"] == "end" and &1["id"] == 5), 10_000)

    context
    |> Map.put(:frames, Enum.filter(frames, &(&1["id"] == 5)))
    |> World.put_client(client)
  end

  step "it sees downloading, then installing, then complete", context do
    target = context.target

    assert [
             %{"event" => %{"type" => "progress", "stage" => "downloading"}},
             %{"event" => %{"type" => "progress", "stage" => "installing"}},
             %{"event" => %{"type" => "complete", "result" => %{"targetVersion" => ^target}}}
           ] = context.frames

    context
  end

  step "the progress stream ends", context do
    # The `end` frame closed the subscription; the id is free again.
    assert Enum.all?(context.frames, &(&1["t"] == "serverUpdate"))
    assert Upgrade.version() == context.target
    context
  end

  # --- restarts -----------------------------------------------------------------------

  step ~r/^a bundle that changes (?<what>.+) in place$/, %{args: [what]} = context do
    context = Map.put(context, :what, what)

    case what do
      "a supervisor module" ->
        context
        |> Map.put(:streams, Process.whereis(HalC2.Streams))
        |> bundle(%{}, [Mc.variant(HalC2.Streams)])

      # The release handler sets the environment of the applications in the release,
      # which here holds the MC's code as another application: an OTP one stands in.
      "the configuration" ->
        ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:stdlib, :upgrade_probe) end)
        bundle(context, %{"config" => "d", "sys.config" => [stdlib: [upgrade_probe: :changed]]})
    end
  end

  step "the MC takes the change without restarting", context do
    assert {:ok, %{"method" => "hot-upgrade", "targetVersion" => target}} = context.reply
    assert target == context.target
    refute_received {:hal_c2_restart, _}

    case context.what do
      "a supervisor module" ->
        assert function_exported?(HalC2.Streams, :__hal_c2_variant__, 0)
        assert Process.whereis(HalC2.Streams) == context.streams

      "the configuration" ->
        assert Application.get_env(:stdlib, :upgrade_probe) == :changed
    end

    context
  end

  step ~r/^a bundle that changes (?<what>(?!.* in place$).+)$/, %{args: [what]} = context do
    case what do
      "the OTP release" ->
        bundle(context, %{"otpRelease" => "30"})

      "the emulator's flags" ->
        bundle(context, %{"vmArgs" => "+S 1"})

      "code that loads a NIF" ->
        {mod, _beam} = nif = Mc.nif_module(context.mc)
        context |> Map.put(:native, mod) |> bundle(%{}, [nif])

      "a release from before release upgrades" ->
        bundle(context, %{"releaseUpgrades" => false})
    end
  end

  step "the MC installs the bundle", context do
    assert {:ok, %{"targetVersion" => target}} = context.reply
    assert target == context.target
    assert File.dir?(Path.join([context.root, "releases", target]))
    assert File.dir?(Path.join([context.root, "lib", "hal_c2_bundle-#{target}"]))
    context
  end

  step "exits asking its service wrapper to start it again", context do
    assert_receive {:hal_c2_restart, 75}, 3_000
    # Nothing was loaded in place.
    if mod = context[:native], do: refute(:code.is_loaded(mod))
    assert Upgrade.version() != context.target
    context
  end

  step "it boots into the new version", context do
    assert start_version(context) == context.target
    boot(context.target)
    assert %{"status" => "committed", "targetVersion" => target} = Upgrade.outcome()
    assert target == context.target
    context
  end

  step "an MC started directly from a release", context do
    System.delete_env("HAL_C2_SERVICE")
    assert Upgrade.release_root() == context.root
    context
  end

  step "a bundle that needs a restart", context do
    bundle(context, %{"otpRelease" => "30"})
  end

  step "the update fails saying the MC was not started by the service wrapper", context do
    assert {:error, _, %{"_tag" => "ServerSelfUpdateError", "reason" => reason}} = context.reply
    assert reason =~ "not started by bin/hal-c2-service"
    refute_received {:hal_c2_restart, _}
    context
  end

  step "a process still runs code from the update before", context do
    {mod, pid} = blocker(context, :old)
    Map.merge(context, %{blocker: mod, blocked: pid})
  end

  step "a bundle that replaces that code again", context do
    mod = context.blocker
    bundle(context, %{}, [{mod, blocker_beam(context, mod, 3), blocker_beam(context, mod, 2)}])
  end

  step "it says the process holding the old code is why", context do
    assert context.log =~ "did not install in place"
    assert context.log =~ inspect(context.blocked)
    assert Process.alive?(context.blocked)
    context
  end

  step "the MC restarts into the new version instead", context do
    assert {:ok, %{"targetVersion" => target}} = context.reply
    assert_receive {:hal_c2_restart, 75}, 3_000
    assert start_version(context) == target

    assert %{"status" => "restarting", "targetVersion" => ^target} =
             context.mc.home |> outcome_path() |> File.read!() |> JSON.decode!()

    context
  end

  # --- outcome ------------------------------------------------------------------------

  step "the MC restarted into a new version", context do
    target = target()
    restarting(context, target)
    boot(target)
    Map.put(context, :target, target)
  end

  step "the MC was restarting into a new version", context do
    target = target()
    restarting(context, target)
    Map.put(context, :target, target)
  end

  step "it booted the old version instead", context do
    boot(nil)
    context
  end

  step "a client reconnects", context do
    client = Mc.connect(context.mc) |> Mc.sub(1, config_shape())
    {config, client} = Mc.await(client, &(&1["t"] == "config"))
    context |> Map.put(:config, config) |> World.put_client(client)
  end

  step "the ready it receives says the update was committed", context do
    assert %{"status" => "committed", "targetVersion" => target} = context.config["updateOutcome"]
    assert target == context.target
    context
  end

  step "the ready it receives says the update was rolled back and why", context do
    assert %{"status" => "rolled-back", "reason" => reason} = context.config["updateOutcome"]
    assert reason =~ "instead of #{context.target}"
    context
  end

  step "a client follows the MC's config", context do
    World.put_client(context, Mc.config(World.client(context)))
  end

  step "the client receives a new ready with the MC's new descriptor", context do
    {ready, client} = Mc.await(World.client(context), &(&1["t"] == "config.ready"))
    assert ready["environment"]["serverVersion"] == context.target
    assert ready["updateOutcome"]["status"] == "committed"
    World.put_client(context, client)
  end

  # --- one at a time and refusals --------------------------------------------------------

  step "an update is in progress", context do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    test = self()

    # A release location that accepts the download and never answers.
    acceptor = spawn(fn -> accept_forever(listen, test, []) end)
    upgrade_url("http://127.0.0.1:#{port}/{version}.tar.gz")
    ExUnit.Callbacks.on_exit(fn -> Process.exit(acceptor, :kill) end)

    target = target()
    spawn(fn -> send(test, {:first_update, Upgrade.update(%{"targetVersion" => target})}) end)
    assert_receive :download_started, 5_000
    Map.put(context, :target, target)
  end

  step "another client asks the MC to update", context do
    context = World.put_client(context, "other", Mc.connect(context.mc))
    input = %{"targetVersion" => target()}
    {reply, context} = World.call(context, "server.updateServer", input, "other")
    Map.put(context, :reply, reply)
  end

  step "the second request does not start another update", context do
    assert {:error, _, %{"reason" => "A server update is already in progress."}} = context.reply
    refute_received :download_started
    refute_received {:first_update, _}
    context
  end

  step "the MC runs from a checkout", context do
    System.delete_env("RELEASE_ROOT")
    assert Upgrade.capability() == nil
    Map.put(context, :target, target())
  end

  step "the requested version is the running one", context do
    Map.put(context, :target, Upgrade.version())
  end

  step "no target version is given", context do
    Map.put(context, :input, %{})
  end

  step "the update fails saying {string}", %{args: [text]} = context do
    assert {:error, _, %{"_tag" => "ServerSelfUpdateError", "reason" => reason}} = context.reply
    assert reason =~ text
    context
  end

  # --- where bundles come from -------------------------------------------------------------

  step "the MC already downloaded the target version", context do
    upgrade_url(@unreachable)
    bundle(context)
  end

  step "it updates to that version", context do
    Map.put(context, :reply, Upgrade.update(%{"targetVersion" => context.target}))
  end

  step "it does not download it again", context do
    # The release location is unreachable, so only the cache could have served it.
    assert {:ok, %{"targetVersion" => target}} = context.reply
    assert target == context.target and Upgrade.version() == target
    context
  end

  step "a peer in the cluster holds the target bundle", context do
    upgrade_url(@unreachable)
    {mc, peer} = Mc.cluster(context.mc)
    context = %{context | mc: mc, clients: %{}} |> Map.put(:peer, peer)
    target = target()
    archive = Mc.bundle(mc, target)
    :ok = :erpc.call(peer.name, Source, :put, [target, Upgrade.platform(), archive])
    refute File.exists?(cached(mc, target))
    Map.put(context, :target, target)
  end

  step "the MC updates to that version", context do
    Map.put(context, :reply, Upgrade.update(%{"targetVersion" => context.target}))
  end

  step "it fetches the bundle from the peer over a one-time link", context do
    assert {:ok, %{"targetVersion" => target}} = context.reply
    assert target == context.target
    assert File.regular?(cached(context.mc, target))
    # The link the peer handed out was taken.
    assert links(context.peer.name) == []
    context
  end

  step "the link cannot be used twice", context do
    %{"port" => port, "path" => path} =
      :erpc.call(context.peer.name, Source, :offer, [context.target, Upgrade.platform()])

    peer = %{port: port}
    assert {200, _, _} = Mc.request(peer, :get, path)
    assert {403, _, _} = Mc.request(peer, :get, path)
    context
  end

  step "no cache or peer holds the target bundle", context do
    context = context |> bundle(%{}, [], false) |> serve()
    name = Path.basename(context.archive)
    File.cp!(context.archive, Path.join(context.served, name))
    File.cp!(context.archive <> ".sha256", Path.join(context.served, name <> ".sha256"))
    upgrade_url("http://127.0.0.1:#{context.http_port}/hal-c2-mc-{version}-{platform}.tar.gz")
    refute File.exists?(cached(context.mc, context.target))
    context
  end

  step "the MC updates", context do
    Map.put(context, :reply, Upgrade.update(%{"targetVersion" => context.target}))
  end

  step "it downloads the bundle for its platform from the release location", context do
    assert {:ok, %{"targetVersion" => target}} = context.reply
    cached = cached(context.mc, target)
    assert String.ends_with?(cached, "-#{Upgrade.platform()}.tar.gz")
    assert File.read!(cached) == File.read!(context.archive)
    context
  end

  step "a downloaded bundle whose SHA-256 does not match", context do
    context = context |> bundle(%{}, [], false) |> serve()
    name = Path.basename(context.archive)
    File.cp!(context.archive, Path.join(context.served, name))

    File.write!(
      Path.join(context.served, name <> ".sha256"),
      String.duplicate("0", 64) <> "  #{name}\n"
    )

    upgrade_url("http://127.0.0.1:#{context.http_port}/hal-c2-mc-{version}-{platform}.tar.gz")
    Map.put(context, :version, Upgrade.version())
  end

  step "the update fails saying the bundle does not match its checksum", context do
    assert {:error, %{"reason" => reason}} = context.reply
    assert reason =~ "does not match its checksum"
    refute File.exists?(cached(context.mc, context.target))
    context
  end

  step "the running version is unchanged", context do
    assert Upgrade.version() == context.version
    refute_received {:hal_c2_restart, _}
    context
  end

  step "HAL_C2_UPGRADE_URL points to a private mirror", context do
    context = context |> bundle(%{}, [], false) |> serve()
    dir = Path.join([context.served, "mirror", context.target])
    File.mkdir_p!(dir)
    platform = Upgrade.platform()
    File.cp!(context.archive, Path.join(dir, "#{platform}.tgz"))
    File.cp!(context.archive <> ".sha256", Path.join(dir, "#{platform}.tgz.sha256"))
    upgrade_url("http://127.0.0.1:#{context.http_port}/mirror/{version}/{platform}.tgz")
    context
  end

  step "the MC downloads a bundle", context do
    Map.put(context, :reply, Upgrade.update(%{"targetVersion" => context.target}))
  end

  step "it downloads from the mirror", context do
    assert {:ok, %{"targetVersion" => target}} = context.reply
    assert File.read!(cached(context.mc, target)) == File.read!(context.archive)
    context
  end

  # --- maintainer tools ------------------------------------------------------------------

  step "a maintainer upgrades three MCs from a checkout", context do
    {mc, b} = Mc.cluster(context.mc)
    {_mc, c} = Mc.cluster(mc)
    context = %{context | mc: mc, clients: %{}}
    for peer <- [b, c], do: peer_release(peer)
    target = target()
    archive = Mc.bundle(mc, target)
    mcs = [node(), b.name, c.name]
    replies = Mix.Tasks.HalC2.Upgrade.roll_out(mcs, archive)
    Map.merge(context, %{target: target, peers: [b, c], replies: replies, archive: archive})
  end

  step "the first MC receives the bundle", context do
    assert [{first, {:ok, %{"targetVersion" => target}}} | _] = context.replies
    assert first == node() and target == context.target
    assert File.read!(cached(context.mc, target)) == File.read!(context.archive)
    context
  end

  step "the other two fetch it from a peer that already has it", context do
    target = context.target

    for {peer, {name, reply}} <- Enum.zip(context.peers, tl(context.replies)) do
      assert name == peer.name
      assert {:ok, %{"method" => "hot-upgrade", "targetVersion" => ^target}} = reply
      # Their release location is unreachable, so the bundle came from the cluster.
      assert File.read!(cached(peer, target)) == File.read!(context.archive)
      assert :erpc.call(peer.name, Upgrade, :version, []) == target
    end

    context
  end

  # The MC's own build: `mix compile` changed a plain module and a supervisor.
  step "MCs started from a checkout", context do
    System.delete_env("RELEASE_ROOT")
    assert Upgrade.release_root() == nil
    Code.ensure_loaded!(HalC2.Patch)
    build = checkout(context, "checkout", [Mc.variant(HalC2.Patch), Mc.variant(HalC2.Streams)])
    own_build(build)
    Map.put(context, :streams, Process.whereis(HalC2.Streams))
  end

  step "MCs started from a checkout whose new code adds services", context do
    System.delete_env("RELEASE_ROOT")
    alias HalC2.Test.Services
    {:ok, _} = Supervisor.start_child(HalC2.Supervisor, Services)
    # Its boot task has run.
    assert Supervisor.which_children(Services) |> Enum.all?(&(elem(&1, 0) != :search_backfill))

    ExUnit.Callbacks.on_exit(fn ->
      Supervisor.terminate_child(HalC2.Supervisor, Services)
      Supervisor.delete_child(HalC2.Supervisor, Services)
    end)

    old = Process.whereis(HalC2.Test.OldService)

    build =
      checkout(context, "checkout", [
        {Services, HalC2.Test.Compile.beam(Services, Services.next())}
      ])

    own_build(build)
    Map.put(context, :old_service, old)
  end

  step "the new service runs without a restart", context do
    assert {:ok, %{changed: changed, services: services}} = context.report
    assert HalC2.Test.Services in changed
    assert {:started, HalC2.Test.NewService} in services
    assert Process.whereis(HalC2.Test.NewService)
    context
  end

  # It ran and ended before the reload, and its spec is back after it.
  step "a boot task that already ran does not run again", context do
    refute Enum.any?(
             Supervisor.which_children(HalC2.Test.Services),
             &(elem(&1, 0) == :search_backfill)
           )

    assert {:ok, %{services: services}} = context.report
    refute Enum.any?(services, &(elem(&1, 1) == :search_backfill))
    context
  end

  step "a new service that fails to start is reported as needing a restart", context do
    assert {:ok, %{needs_restart: [:broken_service]}} = context.report
    context
  end

  step "services it changed restart on their new specs, and ones it no longer lists stop",
       context do
    assert {:ok, %{services: services}} = context.report
    assert {:restarted, :changed_service} in services
    assert {:stopped, HalC2.Test.OldService} in services

    {_, agent, _, _} =
      List.keyfind(Supervisor.which_children(HalC2.Test.Services), :changed_service, 0)

    assert Agent.get(agent, & &1) == 2
    refute Process.alive?(context.old_service)
    context
  end

  step "another checkout holds edited code the MC was not started from", context do
    System.delete_env("RELEASE_ROOT")
    Code.ensure_loaded!(HalC2.Patch)
    build = checkout(context, "worktree", [Mc.variant(HalC2.Patch), Mc.variant(HalC2.Streams)])
    context |> Map.put(:other_build, build) |> Map.put(:streams, Process.whereis(HalC2.Streams))
  end

  step "a developer reloads the local MC from that checkout", context do
    assert {200, _, body} =
             Mc.request(context.mc, :post, "/api/dev/reload",
               bearer: HalC2.Web.token(),
               json: %{"build" => context.other_build}
             )

    modules = &Enum.map(body[&1], fn name -> Module.concat([name]) end)
    report = %{changed: modules.("changed"), needs_restart: modules.("needsRestart")}
    Map.put(context, :report, {:ok, report})
  end

  step "a bundle on this machine the MC has not seen", context do
    bundle(context, %{}, [Mc.variant(HalC2.JsonRpc.Connection)], false)
  end

  step "the MC already unpacked a bundle of the target version", context do
    upgrade_url(@unreachable)
    context = bundle(context, %{}, [Mc.variant(HalC2.JsonRpc.Connection)])
    assert {:ok, _} = Source.fetch(context.target, Upgrade.platform())
    context
  end

  step "that version is built again with other code", context do
    {_, beam} = again = Mc.variant(HalC2.JsonRpc.Connection)
    archive = Mc.bundle(context.mc, context.target, %{}, [again])
    :ok = Source.put(context.target, Upgrade.platform(), archive)
    Map.put(context, :built_last, beam)
  end

  step "it loads the code built last", context do
    assert {:ok, %{"targetVersion" => target}} = context.reply
    assert target == context.target

    {:ok, {_, md5}} = :beam_lib.md5(context.built_last)
    assert HalC2.JsonRpc.Connection.module_info(:md5) == md5

    context
  end

  step "an installed MC that keeps its files under a HAL_C2_HOME root", context do
    Map.put(context, :installed_root, Mc.tmp_dir(context.mc, "installed-root"))
  end

  step "a developer reloads the installed MC naming that root", context do
    reload_root(context, context.installed_root)
  end

  step "a developer reloads the installed MC naming the root {string}",
       %{args: [root]} = context do
    user_home = Mc.tmp_dir(context.mc, "user")
    root = String.replace_prefix(root, "~", user_home)
    context |> Map.put(:user_home, user_home) |> reload_root(root)
  end

  step "the reload looks for that MC in the root's MC directories", context do
    assert {:ok, home} = context.installed_home
    dirs = HalC2.Paths.mc_dirs(home, %{}, context.user_home)

    assert dirs.data == Path.join([context.installed_root, "data", "elixir"])
    assert dirs.state == Path.join([context.installed_root, "state", "elixir"])
    context
  end

  step "the reload is refused naming that root", context do
    assert {:error, reason} = context.installed_home
    assert reason =~ inspect(context.named_root)
    context
  end

  step "a bundle on this machine the MC has not seen that needs a restart", context do
    bundle(context, %{"otpRelease" => "30"}, [], false)
  end

  # --- code alone -------------------------------------------------------------------------

  step "a code-only bundle built with another patch of the Erlang runtime", context do
    other = HalC2.Test.Release.erts() <> ".1"
    bundle(context, %{"erts" => other}, [Mc.variant(HalC2.JsonRpc.Connection)])
  end

  # The bundle's own runtime is neither installed nor named for the next start.
  step "its next start uses the Erlang runtime it already has", context do
    erts = HalC2.Test.Release.erts()
    data = Path.join([context.root, "releases", "start_erl.data"])
    assert String.trim(File.read!(data)) == "#{erts} #{context.target}"
    assert %{"erts" => ^erts, "version" => version} = installed_manifest(context)
    assert version == context.target
    context
  end

  step ~r/^the only bundle at hand is another platform's, (?<kind>changing only code|needing a restart)$/,
       %{args: [kind]} = context do
    upgrade_url(@unreachable)

    {changes, modules} =
      case kind do
        "changing only code" -> {%{}, [Mc.variant(HalC2.JsonRpc.Connection)]}
        "needing a restart" -> {%{"otpRelease" => "30"}, []}
      end

    context = bundle(context, Map.put(changes, "platform", "plan9-mips"), modules, false)
    :ok = Source.put(context.target, "plan9-mips", context.archive)
    context
  end

  step "the bundle cached for the target version is another version's", context do
    context = bundle(context, %{}, [Mc.variant(HalC2.JsonRpc.Connection)], false)
    asked = target()
    :ok = Source.put(asked, Upgrade.platform(), context.archive)
    %{context | target: asked}
  end

  step "the update fails saying the bundle is not that version", context do
    assert {:error, _, %{"_tag" => "ServerSelfUpdateError", "reason" => reason}} = context.reply
    assert reason =~ "the bundle is not #{context.target}"
    assert Upgrade.version() != context.target
    assert start_version(context) != context.target
    context
  end

  step "the update fails saying a restart takes this platform's release", context do
    assert {:error, _, %{"_tag" => "ServerSelfUpdateError", "reason" => reason}} = context.reply
    assert reason =~ "takes the #{Upgrade.platform()} release"
    assert reason =~ "only the plan9-mips one was found"
    assert Upgrade.version() != context.target
    refute_received {:hal_c2_restart, _}
    context
  end

  step "the MC is clustered with another running from a release", context do
    {mc, peer} = Mc.cluster(context.mc)
    peer_release(peer)
    %{context | mc: mc, clients: %{}} |> Map.put(:peer, peer)
  end

  # Its release location is unreachable, so the bundle came from the MC asked.
  step "the other MC loaded that bundle's code too", context do
    assert {:ok, %{"members" => [%{"mc" => name, "outcome" => outcome}]}} = context.reply
    assert name == Atom.to_string(context.peer.name)
    # Moving to the version drops its connections, which can outrun its last word.
    assert outcome in ["updated", "left to run it"]
    assert :erpc.call(context.peer.name, Upgrade, :version, []) == context.target
    assert File.read!(cached(context.peer, context.target)) == File.read!(context.archive)

    assert :erpc.call(context.peer.name, :erlang, :function_exported, [
             HalC2.JsonRpc.Connection,
             :__hal_c2_variant__,
             0
           ])

    context
  end

  step "a developer reloads the local MC with that bundle", context do
    assert {200, _, result} =
             Mc.request(context.mc, :post, "/api/dev/reload",
               bearer: HalC2.Web.token(),
               json: %{"bundle" => context.archive, "version" => context.target}
             )

    Map.put(context, :reply, {:ok, result})
  end

  step "a developer reloads the local MC from a directory with no build", context do
    Map.put(
      context,
      :refused,
      Mc.request(context.mc, :post, "/api/dev/reload",
        bearer: HalC2.Web.token(),
        json: %{"build" => Mc.tmp_dir(context.mc, "empty")}
      )
    )
  end

  step "the developer is told it holds no compiled MC", context do
    assert {409, _, %{"reason" => reason}} = context.refused
    assert reason =~ "holds no compiled MC"
    context
  end

  step "a developer reloads them after editing code", context do
    Map.put(context, :report, Upgrade.reload_checkout())
  end

  step "a developer reloads the local MC with its own access token", context do
    assert {200, _, body} = reload(context, HalC2.Web.token())
    modules = &Enum.map(body[&1], fn name -> Module.concat([name]) end)
    report = %{changed: modules.("changed"), needs_restart: modules.("needsRestart")}
    Map.put(context, :report, {:ok, report})
  end

  step "someone asks the local MC to reload with another token", context do
    Map.put(context, :response, reload(context, "not-the-mc-token"))
  end

  step "the MC refuses and loads nothing", context do
    assert {401, _, _} = context.response
    refute function_exported?(HalC2.Patch, :__hal_c2_variant__, 0)
    context
  end

  step "only modules whose code changed are loaded", context do
    assert {:ok, %{changed: changed}} = context.report
    assert Enum.sort(changed) == [HalC2.Patch, HalC2.Streams]
    assert function_exported?(HalC2.Patch, :__hal_c2_variant__, 0)
    context
  end

  step "a changed supervisor runs its new code without restarting", context do
    assert {:ok, %{needs_restart: []}} = context.report
    assert function_exported?(HalC2.Streams, :__hal_c2_variant__, 0)
    assert Process.whereis(HalC2.Streams) == context.streams
    context
  end

  step "a process is blocked inside a module being replaced", context do
    {mod, pid} = blocker(context, :current)
    Map.merge(context, %{blocker: mod, blocked: pid})
  end

  step "an update replaces that module in place", context do
    mod = context.blocker

    context =
      bundle(context, %{}, [{mod, blocker_beam(context, mod, 2), blocker_beam(context, mod, 1)}])

    Map.put(context, :reply, Upgrade.update(%{"targetVersion" => context.target}))
  end

  step "the module's old code stays for the process still in it", context do
    assert {:ok, %{"targetVersion" => target}} = context.reply
    assert target == context.target
    refute_received {:hal_c2_restart, _}
    assert context.blocker.version() == 2
    assert :erlang.check_process_code(context.blocked, context.blocker)
    context
  end

  step "a service whose state the new version keeps in another shape", context do
    Mc.remember_module(HalC2.Test.Shaped)
    {:ok, pid} = Supervisor.start_child(HalC2.Supervisor, {HalC2.Test.Shaped, 1})

    ExUnit.Callbacks.on_exit(fn ->
      Supervisor.terminate_child(HalC2.Supervisor, HalC2.Test.Shaped)
      Supervisor.delete_child(HalC2.Supervisor, HalC2.Test.Shaped)
    end)

    assert HalC2.Test.Shaped.state() == {:v1, 1}
    Map.put(context, :shaped, pid)
  end

  step "an update replaces that service's module in place", context do
    beam = HalC2.Test.Compile.beam(HalC2.Test.Shaped, HalC2.Test.Shaped.next())
    context = bundle(context, %{}, [{HalC2.Test.Shaped, beam}])
    Map.put(context, :reply, Upgrade.update(%{"targetVersion" => context.target}))
  end

  step "the service migrated its state without restarting", context do
    assert {:ok, %{"targetVersion" => target}} = context.reply
    assert target == context.target
    refute_received {:hal_c2_restart, _}
    assert Process.whereis(HalC2.Test.Shaped) == context.shaped
    assert HalC2.Test.Shaped.state() == {:v2, 1, [:migrated]}
    context
  end

  step "no process runs the old code", context do
    refute :erlang.check_old_code(HalC2.Test.Shaped)
    refute Enum.any?(Process.list(), &:erlang.check_process_code(&1, HalC2.Test.Shaped))
    context
  end

  step "the process is not killed", context do
    assert Process.alive?(context.blocked)
    # It moves to the new code on its next qualified call.
    send(context.blocked, {:go, self()})
    assert_receive {:released, 2}, 1_000
    context
  end

  step "a client connected before an in-place update", context do
    {:push, _hello, state} = HalC2.Web.Socket.init([])
    # The shape socket state had before scopes were kept on it.
    Map.put(context, :old_state, state |> Map.delete(:scopes) |> Map.put(:v, 1))
  end

  step "the socket handles its next frame", context do
    Map.put(
      context,
      :handled,
      HalC2.Web.Socket.handle_in({~s({"t":"ping"}), [opcode: :text]}, context.old_state)
    )
  end

  step "its state is migrated to the new version's shape", context do
    assert {:push, {:text, pong}, state} = context.handled
    assert JSON.decode!(IO.iodata_to_binary(pong)) == %{"t" => "pong"}

    assert %{
             v: 11,
             following: %{},
             scopes: :all,
             monitors: %{},
             shell: %{},
             terminals: %{},
             lost: %{},
             terminal_windows: %{},
             by_stream: %{},
             by_terminal: %{}
           } = state

    context
  end

  step "a client reads the descriptor of an MC running from a release", context do
    Map.put(
      context,
      :response,
      Mc.request(context.mc, :get, "/.well-known/hal-c2/environment")
    )
  end

  step "it offers in-place self-update", context do
    assert {200, _, %{"capabilities" => capabilities}} = context.response
    assert capabilities["serverSelfUpdate"] == "hot-upgrade"
    assert capabilities["serverSelfUpdateProgress"] == true
    context
  end

  step "an MC running from a checkout does not", context do
    System.delete_env("RELEASE_ROOT")

    assert {200, _, %{"capabilities" => capabilities}} =
             Mc.request(context.mc, :get, "/.well-known/hal-c2/environment")

    refute Map.has_key?(capabilities, "serverSelfUpdate")
    assert capabilities["serverSelfUpdateProgress"] == false
    context
  end

  # --- exact versions, preflight, no service --------------------------------------------

  step ~r/^a client asks the MC to update to "(?<target>[^"]+)"$/, %{args: [target]} = context do
    context = Map.merge(context, %{target: target, version: Upgrade.version()})
    {reply, context} = World.call(context, "server.updateServer", %{"targetVersion" => target})
    Map.put(context, :reply, reply)
  end

  step "the update fails saying it is not an exact version", context do
    assert {:error, _, %{"_tag" => "ServerSelfUpdateError", "reason" => reason}} = context.reply
    assert reason =~ "is not an exact version"
    context
  end

  step "the running MC is left as it was", context do
    assert Upgrade.version() == context.version
    assert start_version(context) == context.version
    refute File.exists?(Source.cache_dir(context.target))
    refute_received {:hal_c2_restart, _}
    context
  end

  step "the MC downloaded and staged the target version", context do
    upgrade_url(@unreachable)
    Map.put(context, :version, Upgrade.version())
  end

  # The bundle's launcher starts its release the way a mix release's does, with the
  # release's code on the path, and evaluates what the MC asks: the preflight the
  # bundle carries, which finds a module whose native code does not load here.
  step "the staged version's own preflight says it cannot run here", context do
    {native, _} = nif = Mc.nif_module(context.mc)
    context = preflight_bundle(context, [nif])
    Map.put(context, :native, native)
  end

  step "the update fails with the preflight's reason", context do
    assert {:error, _, %{"_tag" => "ServerSelfUpdateError", "reason" => reason}} = context.reply
    assert reason =~ "#{context.target} cannot run on this machine"
    assert reason =~ "#{inspect(context.native)} does not load here"
    context
  end

  step "the running MC keeps serving without interruption", context do
    refute_received {:hal_c2_restart, _}
    assert Upgrade.version() == context.version
    # The next start is still this version, and the staged one's launchers did not go in.
    assert start_version(context) == context.version
    refute File.exists?(Path.join([context.root, "bin", "hal_c2"]))
    refute File.exists?(Path.join([context.root, "releases", "start_erl.data.previous"]))
    client = WsClient.send_json(World.client(context), %{"t" => "ping"})
    {_, client} = Mc.await(client, &(&1["t"] == "pong"))
    World.put_client(context, client)
  end

  step "an MC that is neither the desktop app's server nor a background service", context do
    System.delete_env("HAL_C2_SERVICE")
    refute HalC2.DesktopUpdate.available?()
    context
  end

  step "the update fails saying remote updates need the background service", context do
    assert {:error, _, %{"_tag" => "ServerSelfUpdateError", "reason" => reason}} = context.reply
    assert reason =~ "Remote updates that restart the MC need the background service"
    refute_received {:hal_c2_restart, _}
    Map.put(context, :reason, reason)
  end

  step "it says to run the service install command on the server machine", context do
    assert context.reason =~ "run `hal-c2-mc install` on the server machine"
    context
  end

  # --- downloads and installs ---------------------------------------------------------------

  # The release location is a loopback server whose behaviour each step sets
  # (`release_server/2`); a minute without data is a second here.
  step "the MC is downloading a version to install", context do
    Application.put_env(:hal_c2, :upgrade_download_idle_ms, 1_000)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :upgrade_download_idle_ms) end)
    context |> bundle(%{}, [], false) |> Map.put(:version, Upgrade.version())
  end

  step "the download is interrupted", context do
    release_server(context, :cut)
    Map.put(context, :reply, Upgrade.update(%{"targetVersion" => context.target}))
  end

  step "nothing is left that could be mistaken for an installed version", context do
    assert {:error, %{"reason" => reason}} = context.reply
    assert reason =~ "is not available"
    nothing_installed(context)
  end

  # Ten minutes is fifteen times the second without data a download may go: one that
  # keeps receiving has no limit to reach.
  step "the download is still receiving data after ten minutes", context do
    release_server(context, {:slow, 15, 100})
    Map.put(context, :reply, Upgrade.update(%{"targetVersion" => context.target}))
  end

  step "it carries on until it finishes", context do
    assert {:ok, %{"targetVersion" => target}} = context.reply
    assert target == context.target
    assert File.read!(cached(context.mc, target)) == File.read!(context.archive)
    context
  end

  step "a download that receives nothing for a minute fails and leaves nothing half-installed",
       context do
    context = context |> bundle(%{}, [], false) |> Map.put(:version, Upgrade.version())
    release_server(context, :stall)
    reply = Upgrade.update(%{"targetVersion" => context.target})
    assert {:error, %{"reason" => reason}} = reply
    assert reason =~ "sent nothing for 1000 ms"
    nothing_installed(context)
  end

  step "an earlier install of a version stopped before it finished", context do
    upgrade_url(@unreachable)
    context = bundle(context)

    # What an install cut off leaves: its directories still being written.
    for dir <- [
          Path.join([context.root, "releases", context.target <> ".partial"]),
          Path.join([context.root, "lib", "hal_c2_bundle-#{context.target}.partial"])
        ] do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "half"), "cut off")
    end

    context
  end

  step "it replaces the partial install with a complete one", context do
    assert {:ok, %{"targetVersion" => target}} = context.reply
    assert target == context.target and Upgrade.version() == target
    release = Path.join([context.root, "releases", target])
    lib = Path.join([context.root, "lib", "hal_c2_bundle-#{target}"])
    assert File.regular?(Path.join(release, "hal_c2.rel"))
    refute File.exists?(Path.join(release, "half"))
    refute File.exists?(Path.join(lib, "half"))
    assert Path.wildcard(Path.join([context.root, "**", "*.partial"]), match_dot: true) == []
    context
  end

  step "a version that is fully installed", context do
    upgrade_url(@unreachable)
    context = context |> Map.put(:version, Upgrade.version()) |> preflight_bundle([])
    assert {:ok, _} = Upgrade.update(%{"targetVersion" => context.target})
    assert_receive {:hal_c2_restart, 75}, 3_000
    assert start_version(context) == context.target
    Map.put(context, :installed, installed_files(context))
  end

  step "another install of the same version fails its checks", context do
    archive =
      Mc.bundle(context.mc, context.target, preflight_changes(), [
        preflight_module(),
        Mc.nif_module(context.mc)
      ])

    :ok = Source.put(context.target, Upgrade.platform(), archive)
    Map.put(context, :reply, Upgrade.update(%{"targetVersion" => context.target}))
  end

  step "the installed version is left in place", context do
    assert {:error, %{"reason" => reason}} = context.reply
    assert reason =~ "cannot run on this machine"
    refute_received {:hal_c2_restart, _}
    assert installed_files(context) == context.installed
    assert start_version(context) == context.target
    context
  end

  # --- the service wrapper ----------------------------------------------------------------

  # `bin/hal-c2-service` over a release whose `bin/hal_c2` stands in for the MC: it
  # notes the version `start_erl.data` names, and as the old version it installs the
  # new one and exits 75, as an update restart does; the new version fails to boot.
  step "a restart into a new version fails before it is ready", context do
    root = Mc.tmp_dir(context.mc, "service")
    File.mkdir_p!(Path.join(root, "bin"))
    File.mkdir_p!(Path.join(root, "releases"))
    service = Path.join(root, "bin/hal-c2-service")
    File.cp!(Path.expand("../../../rel/overlays/bin/hal-c2-service", __DIR__), service)
    File.chmod!(service, 0o755)
    File.write!(Path.join(root, "releases/start_erl.data"), "16.0 1.1.0\n")

    launcher = Path.join(root, "bin/hal_c2")

    File.write!(launcher, """
    #!/bin/sh
    releases="$(dirname "$0")/../releases"
    version=$(cut -d' ' -f2 "$releases/start_erl.data")
    echo "$version" >> "$releases/../started"
    case "$version:$(grep -c . "$releases/../started")" in
      1.1.0:1)
        cp "$releases/start_erl.data" "$releases/start_erl.data.previous"
        echo "16.0 1.2.0" > "$releases/start_erl.data"
        exit 75 ;;
      1.2.0:*) exit 1 ;;
      *) exit 0 ;;
    esac
    """)

    File.chmod!(launcher, 0o755)
    {_, status} = System.cmd("timeout", ["60", service], stderr_to_stdout: true)
    Map.merge(context, %{service_root: root, service_status: status})
  end

  step "the service wrapper starts the previous version again", context do
    root = context.service_root
    assert File.read!(Path.join(root, "started")) |> String.split() == ~w(1.1.0 1.2.0 1.1.0)
    assert File.read!(Path.join(root, "releases/start_erl.data")) =~ " 1.1.0"
    refute File.exists?(Path.join(root, "releases/start_erl.data.previous"))
    assert context.service_status == 0
    context
  end

  # --- removing old versions ----------------------------------------------------------------

  step ~r/^the MC has installed versions (?<versions>.+) and runs "(?<running>[^"]+)"$/,
       %{args: [versions, running]} = context do
    versions = Regex.scan(~r/"([^"]+)"/, versions, capture: :all_but_first) |> List.flatten()
    for version <- versions, do: old_version(context, version)
    runs(context, running)
  end

  step ~r/^"(?<version>[^"]+)" is the version an update would roll back to$/,
       %{args: [version]} = context do
    # The update restarting into the running version came from it, and the service
    # kept its release to go back to.
    previous = Path.join([context.root, "releases", "start_erl.data.previous"])
    File.write!(previous, "16.0 #{version}\n")
    outcome = outcome_path(context.mc.home)
    File.mkdir_p!(Path.dirname(outcome))

    File.write!(
      outcome,
      JSON.encode!(%{
        "id" => "hot-upgrade-t",
        "fromVersion" => version,
        "targetVersion" => context.running,
        "status" => "restarting"
      })
    )

    context
  end

  step "the MC starts after an update", context do
    boot(context.running)
    assert %{"status" => "committed"} = Upgrade.outcome()
    context
  end

  step "an SSH host whose MC was started from its installed version {string}",
       %{args: [version]} = context do
    System.delete_env("HAL_C2_SERVICE")
    old_version(context, version)
    runs(context, version)
  end

  step "the host still has {string} installed, which nothing uses",
       %{args: [version]} = context do
    old_version(context, version)
    context
  end

  step "that MC starts", context do
    boot(context.running)
    context
  end

  step "the MC has the old installed version {string}", %{args: [version]} = context do
    old_version(context, version)
    Map.put(context, :running, Upgrade.version())
  end

  step "a running process executes {string}", %{args: [version]} = context do
    # A process started from that release names it on its command line, as a VM's
    # `-boot <root>/releases/<version>/start` does.
    boot = Path.join([context.root, "releases", version, "start"])

    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        args: ["-c", "echo up; read line", boot]
      ])

    # It has its command line once it says so; it ends when the scenario closes its input.
    assert_receive {^port, {:data, "up\n"}}, 5_000
    Map.put(context, :holder, port)
  end

  step "{string} finished installing less than an hour ago", %{args: [version]} = context do
    File.touch!(Path.join([context.root, "releases", version]))
    context
  end

  step "the MC cannot read which versions are running", context do
    Application.put_env(:hal_c2, :upgrade_processes, fn -> {:error, "ps is missing"} end)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :upgrade_processes) end)
    context
  end

  step "the MC cannot read which version it would roll back to", context do
    File.write!(Path.join([context.root, "releases", "start_erl.data.previous"]), "garbled")
    context
  end

  step ~r/^the MC (?:removes versions nothing can use|starts again)$/, context do
    boot(nil)
    context
  end

  step "the installed version {string} is removed", %{args: [version]} = context do
    for path <- version_paths(context, version), do: refute(File.exists?(path), path)
    assert removing(context) == []
    context
  end

  step ~r/^(?<versions>".+) (?:is|are) kept$/, %{args: [versions]} = context do
    versions = Regex.scan(~r/"([^"]+)"/, versions, capture: :all_but_first) |> List.flatten()

    for version <- versions,
        path <- version_paths(context, version),
        do: assert(File.exists?(path), path)

    context
  end

  step "the MC is removing the old installed version {string}", %{args: [version]} = context do
    old_version(context, version)
    context |> Map.put(:running, Upgrade.version()) |> Map.put(:removing, version)
  end

  # Cut off after the release was set aside and before it was all deleted.
  step "the removal is interrupted", context do
    release = Path.join([context.root, "releases", context.removing])
    File.rename!(release, release <> ".removing")
    File.rm!(Path.join(release <> ".removing", "start.boot"))
    context
  end

  step "{string} is not taken for an installed version", %{args: [version]} = context do
    releases = Path.join(context.root, "releases")
    refute File.exists?(Path.join(releases, version))

    installed =
      for rel <- Path.wildcard(Path.join([releases, "*", "*.rel"])),
          do: rel |> Path.dirname() |> Path.basename()

    refute version in installed
    context
  end

  step "the next removal clears what was left", context do
    boot(nil)
    for path <- version_paths(context, context.removing), do: refute(File.exists?(path), path)
    assert removing(context) == []
    context
  end

  # --- helpers ---------------------------------------------------------------------------

  # --- helpers for preflight and removal ---------------------------------------------------

  # A restart bundle whose launcher runs the preflight it carries, with `modules` too.
  defp preflight_bundle(context, modules) do
    target = target()
    archive = Mc.bundle(context.mc, target, preflight_changes(), [preflight_module() | modules])
    :ok = Source.put(target, Upgrade.platform(), archive)
    Map.merge(context, %{target: target, archive: archive})
  end

  defp preflight_changes,
    do: %{"otpRelease" => "30", "bin" => %{"hal_c2" => preflight_launcher()}}

  defp preflight_module do
    {HalC2.Upgrade.Preflight, elem(:code.get_object_code(HalC2.Upgrade.Preflight), 1)}
  end

  # `bin/hal_c2 eval <expr>` as a mix release runs it: its release's code on the path.
  defp preflight_launcher do
    """
    #!/bin/sh
    RELEASE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
    export RELEASE_ROOT
    expr="$2"
    set --
    for dir in "$RELEASE_ROOT"/lib/*/ebin; do set -- "$@" -pa "$dir"; done
    exec "#{System.find_executable("elixir")}" "$@" -e "$expr"
    """
  end

  # Every file a version installed at the release root, with its content's hash.
  defp installed_files(context) do
    dirs = [
      Path.join([context.root, "bin"]),
      Path.join([context.root, "releases", context.target]),
      Path.join([context.root, "lib", "hal_c2_bundle-#{context.target}"])
    ]

    for dir <- dirs,
        file <- Path.wildcard(Path.join(dir, "**")),
        File.regular?(file),
        into: %{} do
      {file, :crypto.hash(:sha256, File.read!(file))}
    end
  end

  defp nothing_installed(context) do
    assert Upgrade.version() == context.version
    refute_received {:hal_c2_restart, _}
    cache = Source.cache_dir(context.target)
    assert Path.wildcard(Path.join(cache, "*"), match_dot: true) == []
    refute File.exists?(Path.join([context.root, "releases", context.target]))
    refute File.exists?(Path.join([context.root, "lib", "hal_c2_bundle-#{context.target}"]))
    context
  end

  # The release location for `context.archive`, at HAL_C2_UPGRADE_URL: `:cut` sends half
  # the bundle and hangs up, `{:slow, chunks, ms}` sends it in `chunks` pieces `ms`
  # apart, `:stall` sends its first piece and then nothing. Checksums come at once.
  defp release_server(context, mode) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    body = File.read!(context.archive)
    sum = File.read!(context.archive <> ".sha256")
    server = spawn(fn -> serve_release(listen, body, sum, mode, []) end)
    :ok = :gen_tcp.controlling_process(listen, server)
    ExUnit.Callbacks.on_exit(fn -> Process.exit(server, :kill) end)
    upgrade_url("http://127.0.0.1:#{port}/hal-c2-mc-{version}-{platform}.tar.gz")
  end

  defp serve_release(listen, body, sum, mode, held) do
    {:ok, socket} = :gen_tcp.accept(listen)
    {:ok, request} = read_request(socket, "")
    head = &"HTTP/1.1 200 OK\r\nContent-Length: #{&1}\r\nConnection: close\r\n\r\n"

    cond do
      request =~ ".sha256 " ->
        :gen_tcp.send(socket, [head.(byte_size(sum)), sum])
        :gen_tcp.close(socket)

      mode == :cut ->
        :gen_tcp.send(socket, [
          head.(byte_size(body)),
          binary_part(body, 0, div(byte_size(body), 2))
        ])

        :gen_tcp.close(socket)

      mode == :stall ->
        :gen_tcp.send(socket, [head.(byte_size(body)), binary_part(body, 0, 1)])

      match?({:slow, _, _}, mode) ->
        {:slow, chunks, ms} = mode
        :gen_tcp.send(socket, head.(byte_size(body)))
        size = div(byte_size(body), chunks) + 1

        send_slowly(socket, body, size, ms)
        :gen_tcp.close(socket)
    end

    serve_release(listen, body, sum, mode, [socket | held])
  end

  defp send_slowly(socket, body, size, _ms) when byte_size(body) <= size,
    do: :gen_tcp.send(socket, body)

  defp send_slowly(socket, body, size, ms) do
    <<chunk::binary-size(size), rest::binary>> = body
    :gen_tcp.send(socket, chunk)
    # The release location is slow, not the test: the download is what waits on it.
    Process.sleep(ms)
    send_slowly(socket, rest, size, ms)
  end

  defp read_request(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      with {:ok, data} <- :gen_tcp.recv(socket, 0, 10_000), do: read_request(socket, acc <> data)
    end
  end

  # An installed version nothing points at, two hours old: its release, its
  # application's and runtime's directories and its cached bundle.
  defp old_version(context, version) do
    [release, lib, erts, cache] = version_paths(context, version)
    File.mkdir_p!(release)

    HalC2.Upgrade.Appup.write_term!(
      Path.join(release, "hal_c2.rel"),
      {:release, {~c"hal_c2", String.to_charlist(version)}, {:erts, ~c"0.0-#{version}"},
       [{:hal_c2_old, String.to_charlist(version)}]}
    )

    File.write!(Path.join(release, "start.boot"), "boot")
    File.mkdir_p!(Path.join(lib, "ebin"))
    File.write!(Path.join([lib, "ebin", "hal_c2_old.app"]), "app")
    File.mkdir_p!(Path.join(erts, "bin"))
    File.mkdir_p!(cache)
    File.write!(Path.join(cache, Source.file_name(version, Upgrade.platform())), "bundle")
    old = System.os_time(:second) - 7200
    for path <- [release, lib, erts, cache], do: File.touch!(path, old)
  end

  defp version_paths(context, version) do
    [
      Path.join([context.root, "releases", version]),
      Path.join([context.root, "lib", "hal_c2_old-#{version}"]),
      Path.join(context.root, "erts-0.0-#{version}"),
      Source.cache_dir(version)
    ]
  end

  defp runs(context, version) do
    File.write!(Path.join([context.root, "releases", "start_erl.data"]), "16.0 #{version}\n")
    Map.put(context, :running, version)
  end

  defp removing(context) do
    for dir <- [
          context.root,
          Path.join(context.root, "releases"),
          Path.join(context.root, "lib"),
          Path.join(context.mc.home, "upgrades")
        ],
        path <- Path.wildcard(Path.join(dir, "*.removing"), match_dot: true),
        do: path
  end

  # A checkout's `_build/dev`: a copy of the MC's compiled application, `modules`
  # (`{module, beam}`) over it, whose beams the scenario's end loads back.
  # A reload moves the MC's code path into the checkout, which goes with the scenario.
  defp checkout(context, name, modules) do
    Mc.put_back_on_exit()
    source = Application.app_dir(:hal_c2)
    build = Path.join([Mc.tmp_dir(context.mc, name), "_build", "dev"])
    app = Path.join([build, "lib", "hal_c2"])
    File.mkdir_p!(app)
    File.cp_r!(Path.join(source, "ebin"), Path.join(app, "ebin"))
    File.cp_r!(Path.join(source, "consolidated"), Path.join(app, "consolidated"))
    File.ln_s!(Path.join(source, "priv"), Path.join(app, "priv"))

    for {mod, beam} <- modules do
      Mc.remember_module(mod)
      File.write!(Path.join([app, "ebin", "#{mod}.beam"]), beam)
    end

    build
  end

  # The build the MC started from (`Mix.Project.build_path/0`).
  defp own_build(build) do
    previous = System.get_env("MIX_BUILD_PATH")
    System.put_env("MIX_BUILD_PATH", build)

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: System.put_env("MIX_BUILD_PATH", previous),
        else: System.delete_env("MIX_BUILD_PATH")
    end)
  end

  defp reload(context, token),
    do: Mc.request(context.mc, :post, "/api/dev/reload", bearer: token)

  defp target, do: "#{Upgrade.version()}-t#{System.unique_integer([:positive])}"

  # A bundle for a fresh target version, added to the MC's cache unless `cache?` is false.
  defp bundle(context, changes \\ %{}, modules \\ [], cache? \\ true) do
    target = target()
    archive = Mc.bundle(context.mc, target, changes, modules)
    if cache?, do: :ok = Source.put(target, Upgrade.platform(), archive)
    Map.merge(context, %{target: target, archive: archive})
  end

  defp installed_manifest(context) do
    Path.join([context.root, "releases", context.target, "upgrade.json"])
    |> File.read!()
    |> JSON.decode!()
  end

  defp cached(%{home: home}, target),
    do: Path.join([home, "upgrades", target, Source.file_name(target, Upgrade.platform())])

  defp outcome_path(home), do: Path.join([home, "upgrades", "outcome.json"])

  defp start_version(context) do
    [_erts, version] =
      Path.join([context.root, "releases", "start_erl.data"]) |> File.read!() |> String.split()

    version
  end

  defp restarting(context, target) do
    path = outcome_path(context.mc.home)
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      JSON.encode!(%{
        "id" => "hot-upgrade-t",
        "fromVersion" => Upgrade.version(),
        "targetVersion" => target,
        "status" => "restarting"
      })
    )
  end

  # What the service wrapper's next start amounts to for the updater: the version that
  # booted (nil: the one before) and a fresh updater reading the pending outcome.
  defp boot(version) do
    if version, do: :persistent_term.put({Upgrade, :version}, version)
    :ok = ExUnit.Callbacks.stop_supervised(HalC2.Upgrade)
    Mc.ensure(HalC2.Upgrade)
    # The outcome is read in handle_continue; a call returns after it ran.
    _ = :sys.get_state(HalC2.Upgrade)
  end

  defp config_shape, do: %{"type" => "config", "mc" => Atom.to_string(node())}

  # `mix hal_c2.upgrade --release --root <root>` from a checkout on its dev profile.
  defp reload_root(context, root) do
    user_home = Map.get_lazy(context, :user_home, fn -> Mc.tmp_dir(context.mc, "user") end)

    Map.merge(context, %{
      user_home: user_home,
      named_root: root,
      installed_home: Mix.Tasks.HalC2.Upgrade.installed_home(root, :dev, user_home)
    })
  end

  defp upgrade_url(url) do
    System.put_env("HAL_C2_UPGRADE_URL", url)
    ExUnit.Callbacks.on_exit(fn -> System.delete_env("HAL_C2_UPGRADE_URL") end)
  end

  defp links(peer) do
    for {{Source, _token}, _} <- :erpc.call(peer, :persistent_term, :get, []), do: :link
  end

  defp accept_forever(listen, test, held) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        send(test, :download_started)
        accept_forever(listen, test, [socket | held])

      {:error, _} ->
        :ok
    end
  end

  # A static file server on loopback for release locations: `served` (its directory)
  # and `http_port`.
  defp serve(context) do
    {:ok, _} = Application.ensure_all_started(:inets)
    dir = Mc.tmp_dir(context.mc, "served")

    {:ok, pid} =
      :inets.start(:httpd,
        port: 0,
        server_name: ~c"hal_c2_test",
        server_root: String.to_charlist(dir),
        document_root: String.to_charlist(dir),
        bind_address: {127, 0, 0, 1}
      )

    ExUnit.Callbacks.on_exit(fn -> :inets.stop(:httpd, pid) end)
    Map.merge(context, %{served: dir, http_port: :httpd.info(pid)[:port]})
  end

  # A module compiled in the scenario with a process blocked inside it. With `:old`
  # a newer version is loaded over it, so the blocked process holds old code and the
  # next load cannot purge it. Returns `{module, pid}`.
  defp blocker(context, which) do
    mod = :"hal_c2_steps_blocker_#{System.unique_integer([:positive])}"
    {:module, ^mod} = :code.load_binary(mod, ~c"#{mod}.beam", blocker_beam(context, mod, 1))
    test = self()
    # Started through a fun, so the updater does not take it for a process of `mod`.
    pid = spawn(fn -> mod.wait(test) end)
    assert_receive {:waiting, ^pid}, 1_000

    ExUnit.Callbacks.on_exit(fn ->
      Process.exit(pid, :kill)
      :code.purge(mod)
      :code.delete(mod)
      :code.purge(mod)
    end)

    if which == :old,
      do: {:module, ^mod} = :code.load_binary(mod, ~c"#{mod}.beam", blocker_beam(context, mod, 2))

    {mod, pid}
  end

  # Version `version` of the blocker module, compiled but not loaded.
  defp blocker_beam(context, mod, version) do
    path = Path.join(Mc.tmp_dir(context.mc, "blocker"), "#{mod}.erl")

    File.write!(path, """
    -module(#{mod}).
    -export([version/0, wait/1]).
    version() -> #{version}.
    wait(Parent) ->
        Parent ! {waiting, self()},
        receive {go, From} -> From ! {released, #{mod}:version()} end.
    """)

    {:ok, ^mod, beam} = :compile.file(String.to_charlist(path), [:binary, :return_errors])
    beam
  end

  # A peer running from its own release, with no release location to fall back on.
  defp peer_release(%{name: name, home: home}) do
    root = Path.join(home, "release")
    version = :erpc.call(name, Upgrade, :version, [])
    HalC2.Test.Release.root(root, version, Mc.manifest(version))

    for {key, value} <- [{"RELEASE_ROOT", root}, {"HAL_C2_UPGRADE_URL", @unreachable}],
        do: :ok = :erpc.call(name, System, :put_env, [key, value])
  end
end
