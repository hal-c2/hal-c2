defmodule HalC2.Steps.Connections.Cluster do
  @moduledoc """
  Steps for `features/connections/cluster.feature`.

  The trust scenarios run `mix hal_c2.cluster` in the node's home and boot members as
  `:peer` nodes with the flags `HalC2.Cluster.vm_args/1` gives them: TLS distribution on
  the cluster port, each on its own loopback address, driven over stdio so the test VM
  never joins their cluster. The sidebar, streaming, upload and device scenarios make
  the scenario's node a distributed member and start the second member as a peer
  running the whole application, as `test/hal_c2/cluster_test.exs` does.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.{Node, WsClient}
  alias HalC2.Test.Node.World

  @tailnet_address "100.64.0.7"
  @simulator %{
    "id" => "SIM-1",
    "name" => "iPhone 16",
    "version" => "iOS 18.0",
    "platform" => "ios",
    "physical" => false,
    "booted" => true
  }

  # --- mix hal_c2.cluster -------------------------------------------------------------

  step "the user creates a cluster on a machine with its tailnet address", context do
    assert [_] = Node.run_task(Mix.Tasks.HalC2.Cluster, ["init", @tailnet_address])
    context
  end

  step "the machine has a cluster CA and its own certificate", context do
    dir = HalC2.Cluster.dir(context.node.home)
    ca = X509.Certificate.from_pem!(File.read!(Path.join(dir, "ca.pem")))
    cert = X509.Certificate.from_pem!(File.read!(Path.join(dir, "node.pem")))

    assert X509.Certificate.subject(cert, "CN") == ["hal_c2@#{@tailnet_address}"]
    assert X509.Certificate.issuer(cert) == X509.Certificate.subject(ca)
    assert mode(Path.join(dir, "ca.key")) == 0o600
    assert mode(Path.join(dir, "node.key")) == 0o600
    context
  end

  step "it can boot clustered", context do
    flags =
      ExUnit.CaptureIO.capture_io(fn -> Node.run_task(Mix.Tasks.HalC2.Cluster, ["vm-args"]) end)

    optfile = Path.join(HalC2.Cluster.dir(context.node.home), "ssl_dist.conf")

    for flag <- [
          "-name hal_c2@#{@tailnet_address}",
          "-proto_dist inet_tls",
          "-ssl_dist_optfile #{optfile}",
          "-start_epmd false",
          "-kernel inet_dist_listen_min 4370 inet_dist_listen_max 4370"
        ],
        do: assert(flags =~ flag)

    # The VM reads the TLS options with ssl_dist_sup at boot; both sides verify the peer.
    assert [server: server, client: client] = :ssl_dist_sup.consult(to_charlist(optfile))
    assert server[:verify] == :verify_peer and server[:fail_if_no_peer_cert]
    assert client[:verify] == :verify_peer
    context
  end

  step "the machine already has a cluster", context do
    :ok = HalC2.Cluster.init(context.node.home, @tailnet_address)
    Map.put(context, :ca, File.read!(Path.join(HalC2.Cluster.dir(context.node.home), "ca.pem")))
  end

  step "the user creates a cluster again", context do
    Map.put(context, :result, Node.run_task(Mix.Tasks.HalC2.Cluster, ["init", "100.64.0.8"]))
  end

  step "it is refused because the machine already has one", context do
    assert {:error, message} = context.result
    assert message =~ "already has a cluster"
    assert File.read!(Path.join(HalC2.Cluster.dir(context.node.home), "ca.pem")) == context.ca
    context
  end

  step "a cluster member that holds the CA key", context do
    :ok = HalC2.Cluster.init(context.node.home, @tailnet_address)
    assert File.exists?(Path.join(HalC2.Cluster.dir(context.node.home), "ca.key"))
    context
  end

  step "the user invites a new machine by address", context do
    file = Path.join(Node.tmp_dir(context.node, "invite"), "laptop.bundle")
    assert [_] = Node.run_task(Mix.Tasks.HalC2.Cluster, ["invite", "100.64.0.8", file])
    Map.put(context, :bundle, file)
  end

  step "a join bundle is written readable only by its owner", context do
    assert mode(context.bundle) == 0o600
    context
  end

  step "it contains the new machine's certificate and key", context do
    bundle = :erlang.binary_to_term(File.read!(context.bundle), [:safe])

    ca =
      X509.Certificate.from_pem!(
        File.read!(Path.join(HalC2.Cluster.dir(context.node.home), "ca.pem"))
      )

    cert = X509.Certificate.from_pem!(bundle.cert)
    key = X509.PrivateKey.from_pem!(bundle.key)

    assert bundle.address == "100.64.0.8"
    assert X509.Certificate.subject(cert, "CN") == ["hal_c2@100.64.0.8"]
    assert X509.Certificate.issuer(cert) == X509.Certificate.subject(ca)
    assert X509.PublicKey.derive(key) == X509.Certificate.public_key(cert)
    context
  end

  step "a join bundle for this machine", context do
    member = Node.tmp_dir(context.node, "member")
    :ok = HalC2.Cluster.init(member, @tailnet_address)
    file = Path.join(member, "bundle")
    File.write!(file, HalC2.Cluster.invite(member, "100.64.0.9"))
    Map.put(context, :bundle, file)
  end

  step "the user joins with it", context do
    Map.put(context, :printed, Node.run_task(Mix.Tasks.HalC2.Cluster, ["join", context.bundle]))
  end

  step "the machine becomes a member named after its address", context do
    home = context.node.home
    assert context.printed == ["Joined as hal_c2@100.64.0.9"]
    assert HalC2.Cluster.address(home) == "100.64.0.9"
    assert HalC2.Cluster.vm_args(home) =~ "-name hal_c2@100.64.0.9"
    # Only the member that invited can invite again.
    refute File.exists?(Path.join(HalC2.Cluster.dir(home), "ca.key"))
    context
  end

  step "the machine is not in a cluster", context do
    refute File.exists?(HalC2.Cluster.dir(context.node.home))
    context
  end

  step "the user asks for its cluster boot flags", context do
    Map.put(context, :result, Node.run_task(Mix.Tasks.HalC2.Cluster, ["vm-args"]))
  end

  step "it is refused because the machine is not in a cluster yet", context do
    assert context.result == {:error, "not in a cluster yet"}
    context
  end

  # --- mutual TLS -------------------------------------------------------------------

  step "two members of one cluster", context do
    context |> member(:a) |> member(:b)
  end

  step "both nodes start", context do
    context |> boot(:a) |> boot(:b)
  end

  step "they connect over TLS on the cluster port", context do
    %{a: a, b: b} = context.booted
    assert :peer.call(a.peer, :net_kernel, :connect_node, [b.node])
    assert :peer.call(a.peer, :erlang, :nodes, []) == [b.node]

    {:ok, info} = :peer.call(a.peer, :net_kernel, :node_info, [b.node])
    {:net_address, {ip, port}, _host, protocol, _family} = info[:address]
    assert protocol == :tls
    assert {:inet.ntoa(ip) |> to_string(), port} == {b.address, HalC2.Cluster.dist_port()}
    # No port mapper: the node neither starts one nor asks one where its peers listen.
    assert :peer.call(a.peer, :init, :get_argument, [:start_epmd]) == {:ok, [[~c"false"]]}
    context
  end

  step "each listens only on its cluster address", context do
    for {_, member} <- context.booted do
      {:ok, ip} = :inet.parse_address(to_charlist(member.address))
      assert {:ok, socket} = :gen_tcp.connect(ip, HalC2.Cluster.dist_port(), [])
      :gen_tcp.close(socket)
    end

    assert {:error, :econnrefused} =
             :gen_tcp.connect(~c"127.0.0.1", HalC2.Cluster.dist_port(), [])

    context
  end

  step "a node whose certificate was signed by a different cluster CA", context do
    context |> member(:a) |> member(:stranger, cluster: :other)
  end

  step "it tries to connect to a member", context do
    context = context |> boot(:a) |> boot(:stranger)
    %{a: a, stranger: stranger} = context.booted
    Map.put(context, :connected, :peer.call(stranger.peer, :net_kernel, :connect_node, [a.node]))
  end

  step "the TLS handshake fails", context do
    refute context.connected
    # The same handshake by hand: the member's certificate is not from the stranger's CA.
    %{a: a, stranger: stranger} = context.booted
    options = dial_options(stranger.home)
    {:ok, ip} = :inet.parse_address(to_charlist(a.address))

    assert {:error, {:tls_alert, {:unknown_ca, _}}} =
             :ssl.connect(ip, HalC2.Cluster.dist_port(), options, 5_000)

    context
  end

  step "it never joins the cluster", context do
    %{a: a, stranger: stranger} = context.booted
    assert :peer.call(a.peer, :erlang, :nodes, []) == []
    assert :peer.call(stranger.peer, :erlang, :nodes, []) == []
    context
  end

  step "a member whose certificate was revoked", context do
    context = context |> member(:a) |> member(:b) |> member(:removed)
    removed = context.members.removed.address
    # `mix hal_c2.cluster revoke` on each member (this scenario's node home is not one).
    :ok = HalC2.Cluster.revoke(context.members.a.home, removed)
    :ok = HalC2.Cluster.revoke(context.members.b.home, removed)
    context
  end

  step "it tries to connect", context do
    context = context |> boot(:a) |> boot(:b) |> boot(:removed)
    %{a: a, b: b, removed: removed} = context.booted

    Map.put(context, :connected, %{
      a: :peer.call(removed.peer, :net_kernel, :connect_node, [a.node]),
      b: :peer.call(removed.peer, :net_kernel, :connect_node, [b.node])
    })
  end

  step "the other members refuse it", context do
    %{a: a, b: b, removed: removed} = context.booted
    assert context.connected == %{a: false, b: false}
    assert :peer.call(removed.peer, :erlang, :nodes, []) == []
    # The refusal is about that certificate: the remaining members still connect.
    assert :peer.call(b.peer, :net_kernel, :connect_node, [a.node])
    assert :peer.call(a.peer, :erlang, :nodes, []) == [b.node]
    context
  end

  # --- discovery ---------------------------------------------------------------------

  step "two members on the same tailnet", context do
    context = context |> member(:a) |> member(:b)
    %{a: a, b: b} = context.members

    put_in(context.members, %{
      a: Map.put(a, :tailscale, tailnet(context, a, [b])),
      b: Map.put(b, :tailscale, tailnet(context, b, [a]))
    })
  end

  step "both are online", context do
    context |> boot(:a, app: true) |> boot(:b, app: true)
  end

  step "each discovers the other within about ten seconds", context do
    %{a: a, b: b} = context.booted
    assert await_nodeup(a, b.node)
    assert await_nodeup(b, a.node)
    context
  end

  step "HAL_C2_PEERS names a member's node", context do
    distribute()

    {:ok, peer, member} =
      :peer.start_link(%{
        name: :"hal_c2_member#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        args: [~c"-setcookie", Atom.to_charlist(:erlang.get_cookie())] ++ code_path_args()
      })

    System.put_env("HAL_C2_PEERS", Atom.to_string(member))
    ExUnit.Callbacks.on_exit(fn -> System.delete_env("HAL_C2_PEERS") end)
    :ok = :net_kernel.monitor_nodes(true)
    context |> Map.put(:member, member) |> Map.put(:member_peer, peer)
  end

  step "it connects to that member without tailnet discovery", context do
    member = context.member
    assert_receive {:nodeup, ^member}, 5_000
    # The node has no cluster certificate, so only the static list runs.
    assert [{:static, _, :worker, _}] = Supervisor.which_children(HalC2.ClusterSupervisor)
    context
  end

  # --- one socket, every member ------------------------------------------------------

  step "a client connected to one member of a two-machine cluster", context do
    context =
      context
      |> second_member()
      |> World.create_project("Home")
      |> World.create_thread("Local work")

    context = context |> remote_project("Garden") |> remote_thread("Garden work", "Garden")
    World.put_client(context, Node.connect(context.node))
  end

  step "it follows the shell", context do
    client = context |> World.client() |> Node.sub(1, %{"type" => "shell"})
    World.put_client(context, client)
  end

  step "it sees projects and threads from both machines", context do
    here = :erlang.node()
    there = context.second.node

    wanted = [
      {here, World.project(context, "Home").id},
      {here, World.thread_id(context, "Local work")},
      {there, context.remote["Garden"]},
      {there, context.remote["Garden work"]}
    ]

    {shell, client} =
      shell_until(
        World.client(context),
        &Enum.all?(wanted, fn key -> Map.has_key?(&1.rows, key) end)
      )

    assert Enum.map(wanted, &elem(shell.rows[&1], 0)) == [
             "project",
             "thread",
             "project",
             "thread"
           ]

    context |> World.put_client(client) |> Map.put(:shell, shell)
  end

  step "each row names the machine it lives on", context do
    # Rows carry their node; the node names its environment and the machine's label.
    here = Atom.to_string(:erlang.node())
    there = Atom.to_string(context.second.node)
    assert context.shell.nodes[here]["environment"]["environmentId"] == context.node.environment

    assert context.shell.nodes[there]["environment"]["environmentId"] ==
             context.second.environment

    assert context.shell.nodes[there]["environment"]["label"] == "garden-box"
    assert context.shell.nodes[there]["online"]
    context
  end

  step "a client follows the shell of a two-machine cluster", context do
    follow_remote_thread(context)
  end

  step "the other machine goes to sleep", context do
    sleep_second(context)
  end

  step "its threads stay listed", context do
    # A fresh follower still gets the thread, from the connected node's copy.
    {shell, client} = resubscribe(context)

    assert {"thread", %{"title" => "Garden work"}} =
             shell.rows[{context.second.node, context.remote["Garden work"]}]

    context |> World.put_client(client) |> Map.put(:shell, shell)
  end

  step "they are marked offline", context do
    refute context.shell.nodes[Atom.to_string(context.second.node)]["online"]
    context
  end

  step "a member's rows are marked offline", context do
    context |> follow_remote_thread() |> sleep_second()
  end

  step "that member reconnects", context do
    start_second(context, context.second.name, context.second.home)
  end

  step "its rows are marked online", context do
    there = Atom.to_string(context.second.node)

    {_, client} =
      Node.await(
        World.client(context),
        &(&1 == %{"t" => "shell.node", "id" => 1, "node" => there, "online" => true}),
        10_000
      )

    {shell, client} = resubscribe(World.put_client(context, client))
    assert shell.nodes[there]["online"]
    assert {"thread", _} = shell.rows[{context.second.node, context.remote["Garden work"]}]
    World.put_client(context, client)
  end

  step "a client reads a member's environment descriptor", context do
    context = second_member(context)
    {200, descriptor} = Node.http(context.node, :get, "/.well-known/hal-c2/environment")
    Map.put(context, :descriptor, descriptor)
  end

  step "it lists every member's environment id and label", context do
    assert Enum.sort(context.descriptor["cluster"]) ==
             Enum.sort([
               %{
                 "environmentId" => context.node.environment,
                 "label" => HalC2.Environment.descriptor()["label"]
               },
               %{"environmentId" => context.second.environment, "label" => "garden-box"}
             ])

    context
  end

  step "a client connected to the first member", context do
    context = second_member(context)

    {:ok, _} =
      :erpc.call(context.second.node, HalC2.Streams, :commit, [
        "remote-th",
        :thread,
        [{"thread", "remote-th", %{"s" => %{"id" => "remote-th", "title" => "On b"}}}]
      ])

    World.put_client(context, Node.connect(context.node))
  end

  step "it follows a thread that lives on the second member", context do
    shape = %{
      "type" => "stream",
      "node" => Atom.to_string(context.second.node),
      "stream" => "remote-th"
    }

    client = Node.sub(World.client(context), 2, shape)
    {_, client} = Node.await(client, &(&1["t"] == "live" and &1["id"] == 2), 5_000)
    World.put_client(context, client)
  end

  step "the thread streams over the client's one socket", context do
    {:ok, seq} =
      :erpc.call(context.second.node, HalC2.Streams, :commit, [
        "remote-th",
        :thread,
        [{"turn-item", "i1", %{"s" => %{"text" => "from b"}}}]
      ])

    {events, client} = Node.await(World.client(context), &(&1["t"] == "events" and &1["id"] == 2))
    assert [[^seq, "turn-item", "i1", %{"s" => %{"text" => "from b"}}, _at]] = events["events"]
    World.put_client(context, client)
  end

  step "the second member is offline", context do
    context |> second_member() |> sleep_second()
  end

  step "a client asks for something only the second member can serve", context do
    {reply, client} =
      Node.call(Node.connect(context.node), context.second.environment, "hal-c2.readSettings")

    context |> World.put_client(client) |> Map.put(:reply, reply)
  end

  step "that request fails saying the node is unavailable", context do
    assert {:error, error, _} = context.reply
    assert error =~ "node unavailable"
    context
  end

  step "the socket stays up", context do
    client = WsClient.send_json(World.client(context), %{"t" => "ping"})
    {%{"t" => "pong"}, client} = WsClient.recv(client, 1_000)
    World.put_client(context, client)
  end

  step "an upload link issued by the second member", context do
    context |> second_member() |> upload_link()
  end

  step "a client uploads to the first member with that link", context do
    Map.put(context, :upload_status, upload(context))
  end

  step "the first member forwards the upload to the second", context do
    assert context.upload_status == 204

    stored =
      :erpc.call(context.second.node, HalC2.Attachments, :path, [%{"id" => context.upload.id}])

    assert :erpc.call(context.second.node, File, :read!, [stored]) == png()
    assert HalC2.Attachments.path(%{"id" => context.upload.id}) == nil
    context
  end

  step "an upload link issued by a member that is no longer connected", context do
    context |> second_member() |> upload_link() |> sleep_second()
  end

  step "a client uploads with it", context do
    Map.put(context, :upload_status, upload(context))
  end

  step "the upload fails as a bad gateway", context do
    assert context.upload_status == 502
    context
  end

  step "a simulator running on the second member", context do
    home = Node.tmp_dir(context.node, "second")
    sdk = install_device_tools(home)

    context =
      second_member(context, home, [
        {~c"ANDROID_HOME", to_charlist(sdk)},
        {~c"FAKE_HUB_SIMULATORS", to_charlist(JSON.encode!([@simulator]))}
      ])

    {:ok, state} =
      :erpc.call(context.second.node, HalC2.Devices, :configure, [%{"enabled" => true}])

    assert state["hostStatus"] == "ready"
    Map.put(context, :hub, state["hubBasePath"])
  end

  step "a client connected to the first member watches it", context do
    # The Device panel lists devices, then shows the stream in an <img>.
    {200, devices} =
      Node.http(context.node, :get, "#{context.hub}/api/devices?token=#{HalC2.Web.token()}")

    assert [%{"id" => "SIM-1"}] = devices["simulators"]

    url =
      "http://127.0.0.1:#{context.node.port}#{context.hub}/vendor/serve-sim/helper/SIM-1/stream.mjpeg?token=#{HalC2.Web.token()}"

    {:ok, ref} = :httpc.request(:get, {to_charlist(url), []}, [], sync: false, stream: :self)
    ExUnit.Callbacks.on_exit(fn -> :httpc.cancel_request(ref) end)
    Map.put(context, :stream, ref)
  end

  step "the first member relays the stream from the second", context do
    ref = context.stream
    assert_receive {:http, {^ref, :stream_start, headers}}, 5_000
    assert {~c"content-type", ~c"multipart/x-mixed-replace; boundary=frame"} in headers
    assert_receive {:http, {^ref, :stream, frame}}, 5_000
    assert frame =~ "content-type: image/jpeg"
    :httpc.cancel_request(ref)
    context
  end

  # --- helpers -----------------------------------------------------------------------

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  defp code_path_args, do: Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

  # A cluster member's home on its own loopback address, so members can share the
  # cluster port on this machine. The first member creates the cluster; later ones
  # join it unless `cluster: :other` starts a separate one.
  defp member(context, name, opts \\ []) do
    members = Map.get(context, :members, %{})
    home = Node.tmp_dir(context.node, "member-#{name}")
    n = System.unique_integer([:positive])
    address = "127.#{rem(div(n, 250), 250) + 1}.#{rem(div(n, 62_500), 250)}.#{rem(n, 250) + 2}"

    case {members[:a], opts[:cluster]} do
      {%{home: first}, nil} ->
        :ok = HalC2.Cluster.join(home, HalC2.Cluster.invite(first, address))

      _ ->
        :ok = HalC2.Cluster.init(home, address)
    end

    Map.put(context, :members, Map.put(members, name, %{home: home, address: address}))
  end

  # Boots a member with its cluster flags. `app: true` also runs the whole node there.
  defp boot(context, name, opts \\ []) do
    %{home: home, address: address} = member = context.members[name]
    ["-name", _node | flags] = String.split(HalC2.Cluster.vm_args(home))

    {:ok, peer, node} =
      :peer.start_link(%{
        name: :hal_c2,
        host: to_charlist(address),
        longnames: true,
        connection: :standard_io,
        args: Enum.map(flags, &to_charlist/1) ++ code_path_args()
      })

    if opts[:app] do
      settings = [start_node: true, home: home, port: 0, tailscale_command: member.tailscale]

      for {key, value} <- settings,
          do: :ok = :peer.call(peer, Application, :put_env, [:hal_c2, key, value])

      {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:hal_c2], 30_000)
    end

    booted = Map.get(context, :booted, %{})
    Map.put(context, :booted, Map.put(booted, name, Map.merge(member, %{peer: peer, node: node})))
  end

  # A `tailscale` stand-in for `member` that lists `peers` as online tailnet machines.
  defp tailnet(context, member, peers) do
    state = Path.join(Node.tmp_dir(context.node, "tailscale"), "state.json")

    File.write!(
      state,
      JSON.encode!(%{
        "self" => %{"TailscaleIPs" => [member.address]},
        "peers" =>
          Map.new(peers, &{&1.address, %{"Online" => true, "TailscaleIPs" => [&1.address]}})
      })
    )

    ["env", "FAKE_TAILSCALE_STATE=#{state}", Path.expand("test/support/fake_tailscale.py")]
  end

  # Waits on `member` itself for its connection to `other` (discovery polls every 10s).
  defp await_nodeup(member, other) do
    code = """
    :ok = :net_kernel.monitor_nodes(true)

    other in Node.list() or
      receive do
        {:nodeup, ^other} -> true
      after
        10_000 -> false
      end
    """

    {result, _} = :peer.call(member.peer, Code, :eval_string, [code, [other: other]], 15_000)
    result
  end

  # The options a node dials other members with, from its `ssl_dist.conf`.
  defp dial_options(home) do
    conf = :ssl_dist_sup.consult(to_charlist(Path.join(HalC2.Cluster.dir(home), "ssl_dist.conf")))
    conf[:client] |> Keyword.delete(:verify_fun) |> Keyword.put(:active, false)
  end

  # Makes this VM a named node (as a clustered node boots) and restarts the node on it.
  defp distribute do
    unless :erlang.is_alive() do
      {_, 0} = System.cmd("epmd", ["-daemon"])

      {:ok, _} =
        :net_kernel.start(:"hal_c2_feature#{System.unique_integer([:positive])}@127.0.0.1", %{
          name_domain: :longnames
        })

      ExUnit.Callbacks.on_exit(fn -> :net_kernel.stop() end)
    end

    :ok
  end

  defp second_member(context, home \\ nil, env \\ [])

  defp second_member(%{second: _} = context, _home, _env), do: context

  defp second_member(context, home, env) do
    distribute()
    context = %{context | node: Node.restart(context.node)}
    name = :"hal_c2_member#{System.unique_integer([:positive])}"
    start_second(context, name, home || Node.tmp_dir(context.node, "second"), env)
  end

  # The second machine: a peer running the whole node, labelled "garden-box". Returns
  # once the connected node knows its environment.
  defp start_second(context, name, home, env \\ []) do
    {:ok, peer, node} =
      :peer.start_link(%{
        name: name,
        host: ~c"127.0.0.1",
        longnames: true,
        args: code_path_args(),
        env: [{~c"HAL_C2_LABEL", ~c"garden-box"} | env]
      })

    for {key, value} <- [start_node: true, home: home, port: 0],
        do: :ok = :erpc.call(node, Application, :put_env, [:hal_c2, key, value])

    {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:hal_c2], 30_000)

    assert_receive {:hal_c2_shell, {:environment, ^node, %{"environmentId" => environment}}},
                   10_000

    Map.put(context, :second, %{
      name: name,
      home: home,
      peer: peer,
      node: node,
      environment: environment
    })
  end

  defp sleep_second(context) do
    node = context.second.node
    :peer.stop(context.second.peer)
    assert_receive {:hal_c2_shell, {:node, ^node, :down}}, 5_000
    context
  end

  defp remote_project(context, title) do
    root = Node.tmp_dir(context.node, "garden")

    {:ok, _} =
      :erpc.call(context.second.node, HalC2.Projects, :mutate, [
        %{
          "type" => "project.create",
          "projectId" => "garden",
          "title" => title,
          "workspaceRoot" => root
        }
      ])

    put_in(context, [Access.key(:remote, %{}), title], "garden")
  end

  defp remote_thread(context, title, project) do
    id = "th-garden-#{System.unique_integer([:positive])}"

    {:ok, _} =
      :erpc.call(context.second.node, HalC2.Orchestration, :dispatch, [
        %{
          "type" => "thread.create",
          "threadId" => id,
          "projectId" => context.remote[project],
          "title" => title,
          "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"}
        }
      ])

    put_in(context, [:remote, title], id)
  end

  defp follow_remote_thread(context) do
    context =
      context
      |> second_member()
      |> remote_project("Garden")
      |> remote_thread("Garden work", "Garden")

    client = context.node |> Node.connect() |> Node.sub(1, %{"type" => "shell"})
    key = {context.second.node, context.remote["Garden work"]}
    {_, client} = shell_until(client, &Map.has_key?(&1.rows, key))
    World.put_client(context, client)
  end

  # Subscribes to the shell again (id 3) and returns its first frame, as a new window would.
  defp resubscribe(context) do
    client = Node.unsub(World.client(context), 1)
    client = Node.sub(client, 3, %{"type" => "shell"})
    {frame, client} = Node.await(client, &(&1["t"] == "shell" and &1["id"] == 3), 5_000)
    {shell(frame), client}
  end

  # Reads shell frames, folding row updates in, until `done?` holds for the sidebar.
  defp shell_until(client, done?, shell \\ %{rows: %{}, nodes: %{}}) do
    {frame, client} =
      Node.await(
        client,
        &(&1["t"] in ["shell", "shell.rows", "shell.node", "shell.environment"]),
        5_000
      )

    shell =
      case frame do
        %{"t" => "shell"} ->
          shell(frame)

        %{"t" => "shell.rows", "node" => node, "rows" => rows} ->
          node = String.to_existing_atom(node)

          update_in(
            shell.rows,
            &Enum.into(rows, &1, fn [id, kind, row] -> {{node, id}, {kind, row}} end)
          )

        %{"t" => "shell.node", "node" => node, "online" => online} ->
          put_in(shell, [:nodes, Access.key(node, %{}), "online"], online)

        %{"t" => "shell.environment", "node" => node, "environment" => environment} ->
          put_in(shell, [:nodes, Access.key(node, %{}), "environment"], environment)
      end

    if done?.(shell), do: {shell, client}, else: shell_until(client, done?, shell)
  end

  defp shell(%{"nodes" => nodes, "rows" => rows}) do
    %{
      nodes: Map.new(nodes, &{&1["node"], &1}),
      rows:
        Map.new(rows, fn [node, id, kind, row] ->
          {{String.to_existing_atom(node), id}, {kind, row}}
        end)
    }
  end

  defp png, do: <<0x89, "PNG">>

  defp upload_link(context) do
    {:ok, link} =
      :erpc.call(context.second.node, HalC2.Attachments, :create_upload_url, [
        %{"name" => "shot.png", "mimeType" => "image/png", "sizeBytes" => byte_size(png())}
      ])

    Map.put(context, :upload, %{id: link["attachmentId"], path: link["relativeUrl"]})
  end

  defp upload(context) do
    url = to_charlist("http://127.0.0.1:#{context.node.port}#{context.upload.path}")
    {:ok, {{_, status, _}, _, _}} = :httpc.request(:post, {url, [], ~c"image/png", png()}, [], [])
    status
  end

  # The pinned device tools, already installed, as `test/hal_c2/devices_test.exs` sets them up.
  defp install_device_tools(home) do
    support = Path.expand("test/support")

    tool = fn path, fake ->
      File.mkdir_p!(Path.dirname(path))
      File.cp!(Path.join(support, fake), path)
      File.chmod!(path, 0o755)
    end

    for {name, version, entry, fake} <- [
          {"expo-device-hub", "0.10.1", ~w(dist server cli.mjs), "fake_device_hub.mjs"},
          {"agent-device", "0.21.12", ~w(bin agent-device.mjs), "fake_agent_device.mjs"}
        ] do
      root = Path.join([home, "tools", name, version])
      tool.(Path.join([root, "node_modules", name | entry]), fake)
      File.write!(Path.join(root, ".install-complete"), version <> "\n")
    end

    sdk = Path.join(home, "sdk")
    tool.(Path.join([sdk, "platform-tools", "adb"]), "fake_adb.sh")
    tool.(Path.join([sdk, "emulator", "emulator"]), "fake_emulator.sh")
    tool.(Path.join([sdk, "cmdline-tools", "latest", "bin", "avdmanager"]), "fake_emulator.sh")
    sdk
  end
end
