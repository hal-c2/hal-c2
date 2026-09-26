defmodule T3.Steps.Platform.Upgrades do
  @moduledoc """
  Steps for `features/node/platform/upgrades.feature`. The node runs from a release
  laid out in its home (`T3.Test.Node.release/2`); bundles are built from variants of
  loaded modules (`T3.Test.Node.bundle/4`), and a restart arrives as
  `{:t3_restart, status}` instead of stopping the VM.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.Test.Node
  alias T3.Test.Node.World
  alias T3.Test.WsClient
  alias T3.Upgrade
  alias T3.Upgrade.Source

  @echo Path.expand("../../support/echo_rpc.py", __DIR__)
  @unreachable "http://127.0.0.1:1/{version}/{platform}.tar.gz"

  step "a node running from a release under the service wrapper", context do
    root = Node.release(context.node)
    Node.ensure(T3.Settings)
    Node.ensure(T3.Upgrade)
    assert Upgrade.capability() == "hot-upgrade"
    Map.put(context, :root, root)
  end

  # --- in place ---------------------------------------------------------------------

  step "a bundle whose changes are only ordinary modules", context do
    conn =
      ExUnit.Callbacks.start_supervised!(
        {T3.JsonRpc.Connection, cmd: ["python3", "-u", @echo], handler: self()}
      )

    assert {:ok, _} = T3.JsonRpc.Connection.call(conn, "echo", 1)

    context
    |> bundle(%{}, [Node.variant(T3.JsonRpc.Connection)])
    |> Map.merge(%{conn: conn, os_pid: T3.JsonRpc.Connection.os_pid(conn)})
  end

  step ~r/^a client asks the node to update(?: to (?:that version|it))?$/, context do
    input = Map.get_lazy(context, :input, fn -> %{"targetVersion" => context.target} end)
    {reply, context} = World.call(context, "server.updateServer", input)
    Map.put(context, :reply, reply)
  end

  step "the node loads the changed modules in place", context do
    assert {:ok, %{"method" => "hot-upgrade", "targetVersion" => target}} = context.reply
    assert target == context.target
    assert function_exported?(T3.JsonRpc.Connection, :__t3_variant__, 0)
    refute_received {:t3_restart, _}
    context
  end

  step "open sockets and provider sessions stay up", context do
    assert T3.JsonRpc.Connection.os_pid(context.conn) == context.os_pid
    assert {:ok, %{"params" => 2}} = T3.JsonRpc.Connection.call(context.conn, "echo", 2)
    client = WsClient.send_json(World.client(context), %{"t" => "ping"})
    {_, client} = Node.await(client, &(&1["t"] == "pong"))
    World.put_client(context, client)
  end

  step "the node reports the new version", context do
    assert Upgrade.version() == context.target

    assert {200, _, %{"serverVersion" => version}} =
             Node.request(context.node, :get, "/.well-known/t3/environment")

    assert version == context.target
    context
  end

  step "a client asks the node to update with progress", context do
    context = bundle(context)

    shape = %{
      "type" => "serverUpdate",
      "node" => Atom.to_string(node()),
      "input" => %{"targetVersion" => context.target}
    }

    client = World.client(context) |> Node.sub(5, shape)

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
      "the Erlang runtime" ->
        bundle(context, %{"erts" => "18.0"})

      "the OTP release" ->
        bundle(context, %{"otpRelease" => "30"})

      "the set of applications" ->
        bundle(context, %{"applications" => %{"t3" => "x", "more" => "1"}})

      "a native library" ->
        bundle(context, %{"nifs" => %{"t3" => "t3_nif.so"}})

      "the configuration" ->
        bundle(context, %{"config" => "d"})

      "a supervisor module" ->
        bundle(context, %{}, [Node.variant(T3.Streams)])
    end
  end

  step "the node installs the bundle", context do
    assert {:ok, %{"targetVersion" => target}} = context.reply
    assert target == context.target
    assert File.dir?(Path.join([context.root, "releases", target]))
    assert File.dir?(Path.join([context.root, "lib", "t3_bundle-#{target}"]))
    context
  end

  step "exits asking its service wrapper to start it again", context do
    assert_receive {:t3_restart, 75}, 3_000
    # Nothing was loaded in place.
    refute function_exported?(T3.Streams, :__t3_variant__, 0)
    context
  end

  step "it boots into the new version", context do
    assert start_version(context) == context.target
    boot(context.target)
    assert %{"status" => "committed", "targetVersion" => target} = Upgrade.outcome()
    assert target == context.target
    context
  end

  step "a node started directly from a release", context do
    System.delete_env("T3_SERVICE")
    assert Upgrade.release_root() == context.root
    context
  end

  step "a bundle that needs a restart", context do
    bundle(context, %{"erts" => "18.0"})
  end

  step "the update fails saying the node was not started by the service wrapper", context do
    assert {:error, _, %{"_tag" => "ServerSelfUpdateError", "reason" => reason}} = context.reply
    assert reason =~ "not started by bin/t3-service"
    refute_received {:t3_restart, _}
    context
  end

  step "a code-only bundle that fails to load in place", context do
    {mod, _pid} = blocker(context, :old)
    bundle(context, %{}, [{mod, blocker_beam(context, mod, 3)}])
  end

  step "the node restarts into the new version instead", context do
    assert {:ok, %{"targetVersion" => target}} = context.reply
    assert_receive {:t3_restart, 75}, 3_000
    assert start_version(context) == target

    assert %{"status" => "restarting", "targetVersion" => ^target} =
             context.node.home |> outcome_path() |> File.read!() |> JSON.decode!()

    context
  end

  # --- outcome ------------------------------------------------------------------------

  step "the node restarted into a new version", context do
    target = target()
    restarting(context, target)
    boot(target)
    Map.put(context, :target, target)
  end

  step "the node was restarting into a new version", context do
    target = target()
    restarting(context, target)
    Map.put(context, :target, target)
  end

  step "it booted the old version instead", context do
    boot(nil)
    context
  end

  step "a client reconnects", context do
    client = Node.connect(context.node) |> Node.sub(1, config_shape())
    {config, client} = Node.await(client, &(&1["t"] == "config"))
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

  step "a client follows the node's config", context do
    World.put_client(context, Node.config(World.client(context)))
  end

  step "the client receives a new ready with the node's new descriptor", context do
    {ready, client} = Node.await(World.client(context), &(&1["t"] == "config.ready"))
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

  step "another client asks the node to update", context do
    context = World.put_client(context, "other", Node.connect(context.node))
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

  step "the node runs from a checkout", context do
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

  step "the node already downloaded the target version", context do
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
    {node, peer} = Node.cluster(context.node)
    context = %{context | node: node, clients: %{}} |> Map.put(:peer, peer)
    target = target()
    archive = Node.bundle(node, target)
    :ok = :erpc.call(peer.name, Source, :put, [target, Upgrade.platform(), archive])
    refute File.exists?(cached(node, target))
    Map.put(context, :target, target)
  end

  step "the node updates to that version", context do
    Map.put(context, :reply, Upgrade.update(%{"targetVersion" => context.target}))
  end

  step "it fetches the bundle from the peer over a one-time link", context do
    assert {:ok, %{"targetVersion" => target}} = context.reply
    assert target == context.target
    assert File.regular?(cached(context.node, target))
    # The link the peer handed out was taken.
    assert links(context.peer.name) == []
    context
  end

  step "the link cannot be used twice", context do
    %{"port" => port, "path" => path} =
      :erpc.call(context.peer.name, Source, :offer, [context.target, Upgrade.platform()])

    peer = %{port: port}
    assert {200, _, _} = Node.request(peer, :get, path)
    assert {403, _, _} = Node.request(peer, :get, path)
    context
  end

  step "no cache or peer holds the target bundle", context do
    context = context |> bundle(%{}, [], false) |> serve()
    name = Path.basename(context.archive)
    File.cp!(context.archive, Path.join(context.served, name))
    File.cp!(context.archive <> ".sha256", Path.join(context.served, name <> ".sha256"))
    upgrade_url("http://127.0.0.1:#{context.http_port}/t3-node-{version}-{platform}.tar.gz")
    refute File.exists?(cached(context.node, context.target))
    context
  end

  step "the node updates", context do
    Map.put(context, :reply, Upgrade.update(%{"targetVersion" => context.target}))
  end

  step "it downloads the bundle for its platform from the release location", context do
    assert {:ok, %{"targetVersion" => target}} = context.reply
    cached = cached(context.node, target)
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

    upgrade_url("http://127.0.0.1:#{context.http_port}/t3-node-{version}-{platform}.tar.gz")
    Map.put(context, :version, Upgrade.version())
  end

  step "the update fails saying the bundle does not match its checksum", context do
    assert {:error, %{"reason" => reason}} = context.reply
    assert reason =~ "does not match its checksum"
    refute File.exists?(cached(context.node, context.target))
    context
  end

  step "the running version is unchanged", context do
    assert Upgrade.version() == context.version
    refute_received {:t3_restart, _}
    context
  end

  step "T3_UPGRADE_URL points to a private mirror", context do
    context = context |> bundle(%{}, [], false) |> serve()
    dir = Path.join([context.served, "mirror", context.target])
    File.mkdir_p!(dir)
    platform = Upgrade.platform()
    File.cp!(context.archive, Path.join(dir, "#{platform}.tgz"))
    File.cp!(context.archive <> ".sha256", Path.join(dir, "#{platform}.tgz.sha256"))
    upgrade_url("http://127.0.0.1:#{context.http_port}/mirror/{version}/{platform}.tgz")
    context
  end

  step "the node downloads a bundle", context do
    Map.put(context, :reply, Upgrade.update(%{"targetVersion" => context.target}))
  end

  step "it downloads from the mirror", context do
    assert {:ok, %{"targetVersion" => target}} = context.reply
    assert File.read!(cached(context.node, target)) == File.read!(context.archive)
    context
  end

  # --- maintainer tools ------------------------------------------------------------------

  step "a maintainer upgrades three nodes from a checkout", context do
    {node, b} = Node.cluster(context.node)
    {_node, c} = Node.cluster(node)
    context = %{context | node: node, clients: %{}}
    for peer <- [b, c], do: peer_release(peer)
    target = target()
    archive = Node.bundle(node, target)
    nodes = [node(), b.name, c.name]
    replies = Mix.Tasks.T3.Upgrade.roll_out(nodes, archive)
    Map.merge(context, %{target: target, peers: [b, c], replies: replies, archive: archive})
  end

  step "the first node receives the bundle", context do
    assert [{first, {:ok, %{"targetVersion" => target}}} | _] = context.replies
    assert first == node() and target == context.target
    assert File.read!(cached(context.node, target)) == File.read!(context.archive)
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

  step "nodes started from a checkout", context do
    System.delete_env("RELEASE_ROOT")
    assert Upgrade.release_root() == nil
    # A build directory holding a recompiled plain module and a recompiled supervisor.
    ebin = Path.join([Node.tmp_dir(context.node, "_build"), "_build", "dev", "lib", "t3", "ebin"])
    File.mkdir_p!(ebin)

    Code.ensure_loaded!(T3.Patch)

    for {mod, beam} <- [Node.variant(T3.Patch), Node.variant(T3.Streams)] do
      Node.remember_module(mod)
      File.write!(Path.join(ebin, "#{mod}.beam"), beam)
    end

    true = :code.add_patha(String.to_charlist(ebin))
    ExUnit.Callbacks.on_exit(fn -> :code.del_path(String.to_charlist(ebin)) end)
    context
  end

  step "a developer reloads them after editing code", context do
    Map.put(context, :report, Upgrade.reload_checkout())
  end

  step "only modules whose code changed are loaded", context do
    assert {:ok, %{changed: [T3.Patch]}} = context.report
    assert function_exported?(T3.Patch, :__t3_variant__, 0)
    context
  end

  step "the report lists modules that need a restart", context do
    assert {:ok, %{needs_restart: [T3.Streams]}} = context.report
    refute function_exported?(T3.Streams, :__t3_variant__, 0)
    context
  end

  step "a process is blocked inside a module being replaced", context do
    {mod, pid} = blocker(context, :current)
    Map.merge(context, %{blocker: mod, blocked: pid, next: {mod, blocker_beam(context, mod, 2)}})
  end

  step "new code loads", context do
    Map.put(context, :report, T3.Hot.reload([context.next]))
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
    {:push, _hello, state} = T3.Web.Socket.init([])
    # The shape socket state had before scopes were kept on it.
    Map.put(context, :old_state, state |> Map.delete(:scopes) |> Map.put(:v, 1))
  end

  step "the socket handles its next frame", context do
    Map.put(
      context,
      :handled,
      T3.Web.Socket.handle_in({~s({"t":"ping"}), [opcode: :text]}, context.old_state)
    )
  end

  step "its state is migrated to the new version's shape", context do
    assert {:push, {:text, pong}, state} = context.handled
    assert JSON.decode!(IO.iodata_to_binary(pong)) == %{"t" => "pong"}
    assert %{v: 2, scopes: :all} = state
    context
  end

  step "a client reads the descriptor of a node running from a release", context do
    Map.put(context, :response, Node.request(context.node, :get, "/.well-known/t3/environment"))
  end

  step "it offers in-place self-update", context do
    assert {200, _, %{"capabilities" => capabilities}} = context.response
    assert capabilities["serverSelfUpdate"] == "hot-upgrade"
    assert capabilities["serverSelfUpdateProgress"] == true
    context
  end

  step "a node running from a checkout does not", context do
    System.delete_env("RELEASE_ROOT")

    assert {200, _, %{"capabilities" => capabilities}} =
             Node.request(context.node, :get, "/.well-known/t3/environment")

    refute Map.has_key?(capabilities, "serverSelfUpdate")
    assert capabilities["serverSelfUpdateProgress"] == false
    context
  end

  # --- helpers ---------------------------------------------------------------------------

  defp target, do: "#{Upgrade.version()}-t#{System.unique_integer([:positive])}"

  # A bundle for a fresh target version, added to the node's cache unless `cache?` is false.
  defp bundle(context, changes \\ %{}, modules \\ [], cache? \\ true) do
    target = target()
    archive = Node.bundle(context.node, target, changes, modules)
    if cache?, do: :ok = Source.put(target, Upgrade.platform(), archive)
    Map.merge(context, %{target: target, archive: archive})
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
    path = outcome_path(context.node.home)
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
    :ok = ExUnit.Callbacks.stop_supervised(T3.Upgrade)
    Node.ensure(T3.Upgrade)
    # The outcome is read in handle_continue; a call returns after it ran.
    _ = :sys.get_state(T3.Upgrade)
  end

  defp config_shape, do: %{"type" => "config", "node" => Atom.to_string(node())}

  defp upgrade_url(url) do
    System.put_env("T3_UPGRADE_URL", url)
    ExUnit.Callbacks.on_exit(fn -> System.delete_env("T3_UPGRADE_URL") end)
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
    dir = Node.tmp_dir(context.node, "served")

    {:ok, pid} =
      :inets.start(:httpd,
        port: 0,
        server_name: ~c"t3test",
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
    mod = :"t3_steps_blocker_#{System.unique_integer([:positive])}"
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
    path = Path.join(Node.tmp_dir(context.node, "blocker"), "#{mod}.erl")

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
      JSON.encode!(Node.manifest(version))
    )

    File.write!(Path.join([root, "releases", "start_erl.data"]), "17.0.5 #{version}\n")

    for {key, value} <- [{"RELEASE_ROOT", root}, {"T3_UPGRADE_URL", @unreachable}],
        do: :ok = :erpc.call(name, System, :put_env, [key, value])
  end
end
