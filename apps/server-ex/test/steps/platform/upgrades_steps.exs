defmodule HalC2.Steps.Platform.Upgrades do
  @moduledoc """
  Steps for `features/mc/platform/upgrades.feature`. The MC runs from a release
  laid out in its home (`HalC2.Test.Mc.release/2`); bundles are built from variants of
  loaded modules (`HalC2.Test.Mc.bundle/4`), and a restart arrives as
  `{:hal_c2_restart, status}` instead of stopping the VM.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

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
    {reply, context} = World.call(context, "server.updateServer", input)
    Map.put(context, :reply, reply)
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

  step ~r/^a bundle that changes (?<what>.+)$/, %{args: [what]} = context do
    case what do
      "the OTP release" ->
        bundle(context, %{"otpRelease" => "30"})

      "a dependency" ->
        bundle(context, %{"dependencies" => %{"exqlite" => "0.42.0"}})

      "the set of dependencies" ->
        bundle(context, %{"dependencies" => %{"exqlite" => "0.41.0", "more" => "1"}})

      "the platform's packages" ->
        bundle(context, %{"packages" => "q"})

      "the configuration" ->
        bundle(context, %{"config" => "d"})

      "a supervisor module" ->
        bundle(context, %{}, [Mc.variant(HalC2.Streams)])
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
    refute function_exported?(HalC2.Streams, :__hal_c2_variant__, 0)
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

  step "a code-only bundle that fails to load in place", context do
    {mod, _pid} = blocker(context, :old)
    bundle(context, %{}, [{mod, blocker_beam(context, mod, 3)}])
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

  step "MCs started from a checkout", context do
    System.delete_env("RELEASE_ROOT")
    assert Upgrade.release_root() == nil
    # A build directory holding a recompiled plain module and a recompiled supervisor.
    ebin =
      Path.join([Mc.tmp_dir(context.mc, "_build"), "_build", "dev", "lib", "hal_c2", "ebin"])

    File.mkdir_p!(ebin)

    Code.ensure_loaded!(HalC2.Patch)

    for {mod, beam} <- [Mc.variant(HalC2.Patch), Mc.variant(HalC2.Streams)] do
      Mc.remember_module(mod)
      File.write!(Path.join(ebin, "#{mod}.beam"), beam)
    end

    true = :code.add_patha(String.to_charlist(ebin))
    ExUnit.Callbacks.on_exit(fn -> :code.del_path(String.to_charlist(ebin)) end)
    context
  end

  step "another checkout holds edited code the MC was not started from", context do
    System.delete_env("RELEASE_ROOT")
    build = Path.join([Mc.tmp_dir(context.mc, "worktree"), "_build", "dev"])
    ebin = Path.join([build, "lib", "hal_c2", "ebin"])
    File.mkdir_p!(ebin)
    Code.ensure_loaded!(HalC2.Patch)

    for {mod, beam} <- [Mc.variant(HalC2.Patch), Mc.variant(HalC2.Streams)] do
      Mc.remember_module(mod)
      File.write!(Path.join(ebin, "#{mod}.beam"), beam)
    end

    ExUnit.Callbacks.on_exit(fn -> :code.del_path(String.to_charlist(ebin)) end)
    Map.put(context, :other_build, build)
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

  step "a bundle on this machine the MC has not seen that needs a restart", context do
    bundle(context, %{"otpRelease" => "30"}, [], false)
  end

  # --- code alone -------------------------------------------------------------------------

  step "a code-only bundle built with another patch of the Erlang runtime", context do
    bundle(context, %{"erts" => "17.0.6"}, [Mc.variant(HalC2.JsonRpc.Connection)])
  end

  # The bundle's own runtime is neither installed nor named for the next start.
  step "its next start uses the Erlang runtime it already has", context do
    data = Path.join([context.root, "releases", "start_erl.data"])
    assert File.read!(data) == "17.0.5 #{context.target}\n"
    assert %{"erts" => "17.0.5", "version" => version} = installed_manifest(context)
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
    assert {:ok, %{changed: [HalC2.Patch]}} = context.report
    assert function_exported?(HalC2.Patch, :__hal_c2_variant__, 0)
    context
  end

  step "the report lists modules that need a restart", context do
    assert {:ok, %{needs_restart: [HalC2.Streams]}} = context.report
    refute function_exported?(HalC2.Streams, :__hal_c2_variant__, 0)
    context
  end

  step "a process is blocked inside a module being replaced", context do
    {mod, pid} = blocker(context, :current)
    Map.merge(context, %{blocker: mod, blocked: pid, next: {mod, blocker_beam(context, mod, 2)}})
  end

  step "new code loads", context do
    Map.put(context, :report, HalC2.Hot.reload([context.next]))
  end

  step "that module is reported as lingering", context do
    mod = context.blocker
    assert {:ok, %{changed: [^mod], lingering: [^mod]}} = context.report
    assert mod.version() == 2
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
    assert %{v: 5, scopes: :all, monitors: %{}, shell: %{}} = state
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

  # --- helpers ---------------------------------------------------------------------------

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
    File.mkdir_p!(Path.join([root, "releases", version]))
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "bin"))

    File.write!(
      Path.join([root, "releases", version, "upgrade.json"]),
      JSON.encode!(Mc.manifest(version))
    )

    File.write!(Path.join([root, "releases", "start_erl.data"]), "17.0.5 #{version}\n")

    for {key, value} <- [{"RELEASE_ROOT", root}, {"HAL_C2_UPGRADE_URL", @unreachable}],
        do: :ok = :erpc.call(name, System, :put_env, [key, value])
  end
end
