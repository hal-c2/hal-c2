defmodule HalC2.Steps.Connections.Cluster do
  @moduledoc """
  Steps for `features/connections/cluster.feature`.

  The trust, joining and discovery scenarios boot each machine as an unnamed `:peer`
  VM with the boot flags a release gives it, running the whole MC on its own
  loopback address and driven over stdio, so the test VM never joins their cluster.
  They cluster through the same commands a user runs (`HalC2.Cluster.Command`). The
  sidebar, streaming, upload and device scenarios make the scenario's MC a
  distributed MC and start the second member as a peer running the whole
  application, as `test/hal_c2/cluster_test.exs` does.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.{Mc, WsClient}
  alias HalC2.Test.Mc.World

  @other_version "999.0.0"

  @simulator %{
    "id" => "SIM-1",
    "name" => "iPhone 16",
    "version" => "iOS 18.0",
    "platform" => "ios",
    "physical" => false,
    "booted" => true
  }

  # --- an MC on its own --------------------------------------------------------------

  step "an MC starts", context do
    context |> machine(:a) |> boot(:a)
  end

  step "it has its own certificate, named after its environment", context do
    a = context.machines.a
    dir = HalC2.Cluster.dir(:peer.call(a.peer, HalC2.Paths, :data_dir, []))
    cert = X509.Certificate.from_pem!(File.read!(Path.join(dir, "mc.pem")))

    assert a.id == :peer.call(a.peer, HalC2.Environment, :id, [])
    assert X509.Certificate.subject(cert, "CN") == ["#{a.id}.hal-c2"]
    assert X509.Certificate.issuer(cert) == X509.Certificate.subject(cert)
    assert mode(Path.join(dir, "mc.key")) == 0o600
    assert :peer.call(a.peer, :erlang, :node, []) == HalC2.Cluster.mc_name(a.id)
    context
  end

  step "it listens for members over TLS on the cluster port without a port mapper", context do
    a = context.machines.a
    assert :peer.call(a.peer, HalC2.Cluster.Epmd, :listen_port, []) == context.cluster_port

    assert :peer.call(a.peer, Application, :get_env, [:kernel, :epmd_module]) ==
             HalC2.Cluster.Epmd

    # Anyone may reach the port, but only over TLS with a member's certificate.
    assert {:tls_alert, _} = handshake(context, a, verify: :verify_none)
    context
  end

  step "its cluster has only itself", context do
    status = status(context.machines.a)
    assert status["clustered"]
    assert status["label"] == "member-a"
    assert status["addresses"] == ["#{context.machines.a.address}:#{context.cluster_port}"]
    assert status["members"] == []
    context
  end

  # --- joining ------------------------------------------------------------------------

  step "two MCs that are not clustered", context do
    context |> machine(:a) |> boot(:a) |> machine(:b) |> boot(:b)
  end

  step "the user joins the second to the first with a pairing link from the first", context do
    %{a: a, b: b} = context.machines
    Map.put(context, :joined, command(b, ["join", invite(a)]))
  end

  step "each lists the other as a member", context do
    %{a: a, b: b} = context.machines
    assert [%{"id" => b_id, "label" => "member-b"}] = status(a)["members"]
    assert [%{"id" => a_id, "label" => "member-a"}] = status(b)["members"]
    assert {a_id, b_id} == {a.id, b.id}
    context
  end

  step "they are connected without restarting", context do
    %{a: a, b: b} = context.machines
    assert await_connected(a, b)
    assert await_connected(b, a)
    # The same VMs that were running before the join.
    assert Process.alive?(a.peer) and Process.alive?(b.peer)
    context
  end

  step "the command lists both machines as connected", context do
    %{a: a, b: b} = context.machines
    assert {:ok, text} = context.joined
    assert text =~ "This machine: member-b (#{b.id})"
    assert text =~ "  member-a (#{a.id}): connected"
    assert {:ok, text} = command(a, ["status"])
    assert text =~ "  member-b (#{b.id}): connected"
    context
  end

  step "the user joins the second with a standard pairing link from the first that names the first's certificate",
       context do
    %{a: a, b: b} = context.machines
    store = :peer.call(a.peer, HalC2.Store, :home_path, [])
    token = :peer.call(a.peer, HalC2.Auth, :create_pairing_token, [store])
    link = "#{origin(a)}/?token=#{token}#fingerprint=#{fingerprint(a)}"
    Map.put(context, :joined, command(b, ["join", link]))
  end

  step "the user joins the second with an admin pairing link from the first that names no certificate",
       context do
    %{a: a, b: b} = context.machines

    {:ok, %{"credential" => token}} =
      auth(a, :create_pairing_link, [%{"scopes" => ["access:write"], "label" => "Admin"}])

    Map.put(context, :joined, command(b, ["join", "#{origin(a)}/?token=#{token}"]))
  end

  step "the join is refused because the link is not a cluster invite", context do
    %{a: a, b: b} = context.machines
    assert {:error, message} = context.joined
    assert message =~ "not a cluster invite"
    assert status(a)["members"] == []
    assert status(b)["members"] == []
    context
  end

  step "the first makes a cluster invite", context do
    Map.put(context, :invite, invite(context.machines.a))
  end

  step "the invite carries the fingerprint of the first's certificate", context do
    assert pin(context.invite) == fingerprint(context.machines.a)
    context
  end

  step "the user joins the second with an invite from the first that names another certificate",
       context do
    %{a: a, b: b} = context.machines
    link = String.replace(invite(a), fingerprint(a), fingerprint(b))
    Map.put(context, :joined, command(b, ["join", link]))
  end

  step "the join is refused because the machine that answered is not the one the invite is from",
       context do
    assert {:error, message} = context.joined
    assert message =~ "not the one the invite is from"
    context
  end

  step "the second lists no other member", context do
    b = context.machines.b
    assert status(b)["members"] == []
    assert :peer.call(b.peer, Elixir.Node, :list, []) == []
    context
  end

  # The first really admits the second; a stand-in for the first's HTTP origin then
  # answers the second with a machine of its own added to the members.
  step "the second joins with an invite from the first whose answer was changed on the way to add a machine",
       context do
    %{a: a, b: b} = context.machines
    {:ok, entry} = :peer.call(b.peer, GenServer, :call, [HalC2.Cluster, :entry])
    {:ok, answer} = :peer.call(a.peer, HalC2.Cluster, :admit, [entry])
    added = %{answer["members"][a.id] | "fingerprint" => fingerprint(b), "label" => "added"}
    answer = put_in(answer["members"]["added"], added)

    {base, _log} =
      HalC2.Test.FakeHttp.start(%{
        "/oauth/token" => {200, %{"access_token" => "access"}},
        "/api/cluster/members" => {200, answer}
      })

    link = "#{base}/?token=invite#fingerprint=#{fingerprint(a)}"
    Map.put(context, :joined, command(b, ["join", link]))
  end

  step "the second connects to the first", context do
    %{a: a, b: b} = context.machines
    assert {:ok, _} = context.joined
    assert await_connected(b, a)
    context
  end

  step "the second does not list the added machine", context do
    %{a: a, b: b} = context.machines
    assert [%{"id" => id}] = status(b)["members"]
    assert id == a.id
    context
  end

  step "the join is refused because the link does not grant access:write", context do
    assert {:error, message} = context.joined
    assert message =~ "cannot add machines to a cluster"
    context
  end

  step "neither lists the other", context do
    %{a: a, b: b} = context.machines
    assert status(a)["members"] == []
    assert status(b)["members"] == []
    assert :peer.call(a.peer, Elixir.Node, :list, []) == []
    context
  end

  # --- from a client ------------------------------------------------------------------

  step "a client of the first asks it for a cluster invite", context do
    a = context.machines.a
    assert {:ok, invite} = client_call(a, :admin, "cluster.invite", %{})
    assert invite["link"] =~ "#{origin(a)}/?token="
    Map.put(context, :invite, invite)
  end

  step "a client of the second joins it with that invite", context do
    b = context.machines.b

    Map.put(
      context,
      :joined,
      client_call(b, :admin, "cluster.join", %{"link" => context.invite["link"]})
    )
  end

  step "the client sees both machines connected", context do
    %{a: a, b: b} = context.machines
    assert {:ok, %{"clustered" => true, "id" => b_id, "members" => [member]}} = context.joined
    assert b_id == b.id
    assert %{"id" => a_id, "label" => "member-a", "connected" => true} = member
    assert a_id == a.id
    context
  end

  step "a client of the first removes the second", context do
    %{a: a, b: b} = context.machines
    Map.put(context, :removed, client_call(a, :admin, "cluster.remove", %{"id" => b.id}))
  end

  step "the client sees the first alone again", context do
    assert {:ok, %{"clustered" => true, "members" => []}} = context.removed
    assert status(context.machines.a)["members"] == []
    context
  end

  step "a client paired with a standard link asks the first for a cluster invite", context do
    a = context.machines.a

    context
    |> Map.put(:invited, client_call(a, :standard, "cluster.invite", %{}))
    |> Map.put(:read, client_call(a, :standard, "cluster.status", %{}))
  end

  step "the MC refuses both, saying access is required", context do
    for {reply, scope} <- [{context.invited, "access:write"}, {context.read, "access:read"}] do
      assert {:error, _message, %{"_tag" => "EnvironmentScopeRequiredError"} = detail} = reply
      assert detail["requiredScope"] == scope
    end

    assert status(context.machines.a)["members"] == []
    context
  end

  step "an MC started without the cluster boot flags", context do
    context |> machine(:a) |> boot(:a, flags: false)
  end

  step "the user joins it to another machine", context do
    link = "http://127.0.0.1:9/?token=unused"
    Map.put(context, :joined, command(context.machines.a, ["join", link]))
  end

  step "the join is refused saying the MC was not started for clustering", context do
    assert {:error, message} = context.joined
    assert message =~ "MC was not started for clustering"
    assert {:ok, "Not clustering: " <> _} = command(context.machines.a, ["status"])
    context
  end

  step "a cluster of two members", context do
    cluster(context, [:a, :b])
  end

  step "a third machine joins through the second member", context do
    context = context |> machine(:c) |> boot(:c)
    %{b: b, c: c} = context.machines
    assert {:ok, _} = command(c, ["join", invite(b)])
    context
  end

  step "all three are connected to each other", context do
    %{a: a, b: b, c: c} = context.machines

    for {m, others} <- [{a, [b, c]}, {b, [a, c]}, {c, [a, b]}], other <- others do
      assert await_connected(m, other)
      assert %{"connected" => true} = Enum.find(status(m)["members"], &(&1["id"] == other.id))
    end

    context
  end

  # --- versions -----------------------------------------------------------------------

  step "the second restarts on another HAL-C2 version", context do
    context |> stop(:b) |> boot(:b, version: @other_version)
  end

  step "the second cannot connect to the first", context do
    %{a: a, b: b} = context.machines
    refute connect(context, b, a)
    assert :peer.call(a.peer, Elixir.Node, :list, []) == []
    context
  end

  step "the second lists the first as not connected, with the version the first runs", context do
    %{a: a, b: b} = context.machines
    version = :peer.call(a.peer, HalC2.Upgrade, :version, [])
    assert status(b)["version"] == @other_version
    assert [%{"id" => id, "connected" => false, "version" => ^version}] = status(b)["members"]
    assert id == a.id
    context
  end

  # As `HalC2.Upgrade` does once it has loaded a version in place.
  step "the first moves to that version in place", context do
    a = context.machines.a
    :peer.call(a.peer, :persistent_term, :put, [{HalC2.Upgrade, :version}, @other_version])
    :ok = :peer.call(a.peer, HalC2.Cluster, :version_changed, [])
    context
  end

  step "the two are connected again", context do
    %{a: a, b: b} = context.machines
    assert await_connected(a, b)
    assert await_connected(b, a)

    # The second learns the first's version from the table the first sends as it sees
    # the second come up. A call the first has answered is behind that send, and a call
    # to the second made from the first travels behind it on the same connection.
    status(a)

    members =
      :peer.call(a.peer, GenServer, :call, [
        {HalC2.Cluster, HalC2.Cluster.mc_name(b.id)},
        :status
      ])["members"]

    assert [%{"connected" => true, "version" => @other_version}] = members
    context
  end

  step "two MCs that are not clustered, the second on another HAL-C2 version", context do
    context |> machine(:a) |> boot(:a) |> machine(:b) |> boot(:b, version: @other_version)
  end

  step "the join is refused because the machines run different versions", context do
    assert {:error, message} = context.joined
    assert message =~ "different HAL-C2 versions"
    # It names both, so the user sees which machine to update.
    assert message =~ "the joining machine runs #{@other_version}"
    assert message =~ "the inviting one runs #{HalC2.Upgrade.version()}"
    context
  end

  # --- strangers ----------------------------------------------------------------------

  step "a member of a cluster and an MC that never joined it", context do
    context |> machine(:a) |> boot(:a) |> machine(:stranger) |> boot(:stranger)
  end

  step "the MC tries to connect to the member", context do
    %{a: a, stranger: stranger} = context.machines
    Map.put(context, :connected, connect(context, stranger, a))
  end

  step "the TLS handshake fails", context do
    refute context.connected
    # The same handshake by hand, with the stranger's certificate: the member does not
    # pin it.
    %{a: a, stranger: stranger} = context.machines
    dir = HalC2.Cluster.dir(:peer.call(stranger.peer, HalC2.Paths, :data_dir, []))

    assert {:tls_alert, _} =
             handshake(context, a,
               certfile: to_charlist(Path.join(dir, "mc.pem")),
               keyfile: to_charlist(Path.join(dir, "mc.key")),
               verify: :verify_none
             )

    context
  end

  step "it never joins the cluster", context do
    %{a: a, stranger: stranger} = context.machines
    assert :peer.call(a.peer, Elixir.Node, :list, []) == []
    assert :peer.call(stranger.peer, Elixir.Node, :list, []) == []
    assert status(a)["members"] == []
    context
  end

  # --- finding members ----------------------------------------------------------------

  step "both restart", context do
    context |> stop(:a) |> stop(:b) |> boot(:a) |> boot(:b)
  end

  step "they connect again at the addresses they reported", context do
    %{a: a, b: b} = context.machines
    assert await_connected(a, b)
    assert await_connected(b, a)
    assert %{"addresses" => [address]} = hd(status(a)["members"])
    assert address == "#{b.address}:#{context.cluster_port}"
    context
  end

  step "a cluster of two members whose recorded addresses are out of date", context do
    # Both come back on new addresses, so neither is where the other recorded it.
    context
    |> cluster([:a, :b])
    |> stop(:a)
    |> stop(:b)
    |> update_in([:machines, :a], &%{&1 | address: loopback_address()})
    |> update_in([:machines, :b], &%{&1 | address: loopback_address()})
  end

  step "the tailnet lists the second member's address", context do
    %{a: a, b: b} = context.machines
    put_in(context.machines.a.tailscale, tailnet(context, a, [b.address]))
  end

  step "HAL_C2_PEERS lists the second member's address", context do
    put_in(context.machines.a.env, [{~c"HAL_C2_PEERS", to_charlist(context.machines.b.address)}])
  end

  step "the first member looks for its peers", context do
    # The second is up first, so the first member's look when it starts can find it.
    context |> boot(:b) |> boot(:a)
  end

  step "it connects to the second member within about ten seconds", context do
    %{a: a, b: b} = context.machines
    assert await_connected(a, b, 12_000)
    context
  end

  # --- removing a member --------------------------------------------------------------

  step "a cluster of three members", context do
    cluster(context, [:a, :b, :c])
  end

  step "the user removes the third member on the first", context do
    assert {:ok, _} = command(context.machines.a, ["remove", "member-c"])
    context
  end

  step "no member admits the third any more", context do
    %{a: a, b: b, c: c} = context.machines

    for m <- [a, b] do
      assert await_disconnected(m, c)
      refute Enum.any?(status(m)["members"], &(&1["id"] == c.id))
      refute :peer.call(c.peer, Elixir.Node, :connect, [HalC2.Cluster.mc_name(m.id)])
    end

    context
  end

  step "the first two stay connected", context do
    %{a: a, b: b, c: c} = context.machines
    assert :peer.call(a.peer, Elixir.Node, :list, []) == [HalC2.Cluster.mc_name(b.id)]
    assert :peer.call(b.peer, Elixir.Node, :list, []) == [HalC2.Cluster.mc_name(a.id)]
    assert :peer.call(c.peer, Elixir.Node, :list, []) == []
    context
  end

  step "the first two list a project of the third", context do
    %{a: a, b: b, c: c} = context.machines

    project = %{
      "type" => "project.create",
      "projectId" => "garden",
      "title" => "Garden",
      "workspaceRoot" => Mc.tmp_dir(context.mc, "garden")
    }

    assert {:ok, _} = :peer.call(c.peer, HalC2.Projects, :mutate, [project])
    for m <- [a, b], do: assert(await_sidebar(m, c, true))
    context
  end

  step "the first two no longer list the third or its project", context do
    %{a: a, b: b, c: c} = context.machines

    for m <- [a, b] do
      assert await_sidebar(m, c, false)

      refute Enum.any?(:peer.call(m.peer, HalC2.Shell, :environments, []), fn {_mc, environment} ->
               environment["environmentId"] == c.id
             end)
    end

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
    World.put_client(context, Mc.connect(context.mc))
  end

  step "it follows the shell", context do
    client = context |> World.client() |> Mc.sub(1, %{"type" => "shell"})
    World.put_client(context, client)
  end

  step "it sees projects and threads from both machines", context do
    here = :erlang.node()
    there = context.second.mc

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
    # Rows carry their MC; the MC names its environment and the machine's label.
    here = Atom.to_string(:erlang.node())
    there = Atom.to_string(context.second.mc)
    assert context.shell.mcs[here]["environment"]["environmentId"] == context.mc.environment

    assert context.shell.mcs[there]["environment"]["environmentId"] ==
             context.second.environment

    assert context.shell.mcs[there]["environment"]["label"] == "garden-box"
    assert context.shell.mcs[there]["online"]
    context
  end

  step "a client follows the shell of a two-machine cluster", context do
    follow_remote_thread(context)
  end

  step "the other machine goes to sleep", context do
    sleep_second(context)
  end

  step "its threads stay listed", context do
    # A fresh follower still gets the thread, from the connected MC's copy.
    {shell, client} = resubscribe(context)

    assert {"thread", %{"title" => "Garden work"}} =
             shell.rows[{context.second.mc, context.remote["Garden work"]}]

    context |> World.put_client(client) |> Map.put(:shell, shell)
  end

  step "they are marked offline", context do
    refute context.shell.mcs[Atom.to_string(context.second.mc)]["online"]
    context
  end

  step "a member's rows are marked offline", context do
    context |> follow_remote_thread() |> sleep_second()
  end

  step "that member reconnects", context do
    start_second(context, context.second.name, context.second.home)
  end

  step "its rows are marked online", context do
    there = Atom.to_string(context.second.mc)

    {_, client} =
      Mc.await(
        World.client(context),
        &(&1 == %{"t" => "shell.mc", "id" => 1, "mc" => there, "online" => true}),
        10_000
      )

    {shell, client} = resubscribe(World.put_client(context, client))
    assert shell.mcs[there]["online"]
    assert {"thread", _} = shell.rows[{context.second.mc, context.remote["Garden work"]}]
    World.put_client(context, client)
  end

  step "a client reads a member's environment descriptor", context do
    context = second_member(context)
    {200, descriptor} = Mc.http(context.mc, :get, "/.well-known/hal-c2/environment")
    Map.put(context, :descriptor, descriptor)
  end

  step "it lists every member's environment id and label", context do
    assert Enum.sort(context.descriptor["cluster"]) ==
             Enum.sort([
               %{
                 "environmentId" => context.mc.environment,
                 "label" => HalC2.Environment.descriptor()["label"]
               },
               %{"environmentId" => context.second.environment, "label" => "garden-box"}
             ])

    context
  end

  step "a client connected to the first member", context do
    context = second_member(context)

    {:ok, _} =
      :erpc.call(context.second.mc, HalC2.Streams, :commit, [
        "remote-th",
        :thread,
        [{"thread", "remote-th", %{"s" => %{"id" => "remote-th", "title" => "On b"}}}]
      ])

    World.put_client(context, Mc.connect(context.mc))
  end

  step "it follows a thread that lives on the second member", context do
    follow_second(context, %{"mc" => Atom.to_string(context.second.mc)})
  end

  step "it follows a thread that lives on the second member by that member's environment",
       context do
    follow_second(context, %{"environment" => context.second.environment})
  end

  defp follow_second(context, target) do
    shape = Map.merge(%{"type" => "stream", "stream" => "remote-th"}, target)
    client = Mc.sub(World.client(context), 2, shape)
    {_, client} = Mc.await(client, &(&1["t"] == "live" and &1["id"] == 2), 5_000)
    World.put_client(context, client)
  end

  step "the thread streams over the client's one socket", context do
    {:ok, seq} =
      :erpc.call(context.second.mc, HalC2.Streams, :commit, [
        "remote-th",
        :thread,
        [{"turn-item", "i1", %{"s" => %{"text" => "from b"}}}]
      ])

    {events, client} = Mc.await(World.client(context), &(&1["t"] == "events" and &1["id"] == 2))
    assert [[^seq, "turn-item", "i1", %{"s" => %{"text" => "from b"}}, _at]] = events["events"]
    World.put_client(context, client)
  end

  step "the second member is offline", context do
    context |> second_member() |> sleep_second()
  end

  step "a client asks for something only the second member can serve", context do
    {reply, client} =
      Mc.call(Mc.connect(context.mc), context.second.environment, "hal-c2.readSettings")

    context |> World.put_client(client) |> Map.put(:reply, reply)
  end

  step "that request fails saying the MC is unavailable", context do
    assert {:error, error, _} = context.reply
    assert error =~ "MC unavailable"
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
      :erpc.call(context.second.mc, HalC2.Attachments, :path, [%{"id" => context.upload.id}])

    assert :erpc.call(context.second.mc, File, :read!, [stored]) == png()
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
    home = Mc.tmp_dir(context.mc, "second")
    sdk = install_device_tools(home)

    context =
      second_member(context, home, [
        {~c"ANDROID_HOME", to_charlist(sdk)},
        {~c"FAKE_HUB_SIMULATORS", to_charlist(JSON.encode!([@simulator]))}
      ])

    {:ok, state} =
      :erpc.call(context.second.mc, HalC2.Devices, :configure, [%{"enabled" => true}])

    assert state["hostStatus"] == "ready"
    Map.put(context, :hub, state["hubBasePath"])
  end

  step "a client connected to the first member watches it", context do
    # The Device panel lists devices, then shows the stream in an <img>.
    {200, devices} =
      Mc.http(context.mc, :get, "#{context.hub}/api/devices?token=#{HalC2.Web.token()}")

    assert [%{"id" => "SIM-1"}] = devices["simulators"]

    url =
      "http://127.0.0.1:#{context.mc.port}#{context.hub}/vendor/serve-sim/helper/SIM-1/stream.mjpeg?token=#{HalC2.Web.token()}"

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

  # A machine for the trust scenarios: its own home, loopback address and label. Every
  # machine in a scenario listens for members on one free port, apart from any MC
  # running on this computer.
  defp machine(context, name) do
    context = Map.put_new_lazy(context, :cluster_port, &free_port/0)

    machine = %{
      home: Mc.tmp_dir(context.mc, "machine-#{name}"),
      address: loopback_address(),
      label: "member-#{name}",
      tailscale: tailnet(context, nil, []),
      env: []
    }

    put_in(context, [Access.key(:machines, %{}), name], machine)
  end

  defp loopback_address do
    n = System.unique_integer([:positive])
    "127.#{rem(div(n, 250), 250) + 1}.#{rem(div(n, 62_500), 250)}.#{rem(n, 250) + 2}"
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  # Whether `machine` reaches `other` when told where it listens.
  defp connect(context, machine, other) do
    {:ok, ip} = :inet.parse_address(to_charlist(other.address))
    host = HalC2.Cluster.host(other.id)
    :peer.call(machine.peer, HalC2.Cluster.Epmd, :put, [host, ip, context.cluster_port])
    :peer.call(machine.peer, Elixir.Node, :connect, [HalC2.Cluster.mc_name(other.id)])
  end

  # Boots a machine's VM as a release does (`flags: false` leaves out the cluster boot
  # flags) and starts the whole MC in it, as `version:` when given.
  defp boot(context, name, opts \\ []) do
    machine = context.machines[name]
    optfile = Path.join(Mc.tmp_dir(context.mc, "dist"), "ssl_dist.conf")

    flags =
      if Keyword.get(opts, :flags, true),
        do: ~w(-proto_dist inet_tls -ssl_dist_optfile #{optfile} -setcookie hal_c2),
        else: []

    peer =
      case :peer.start_link(%{
             connection: :standard_io,
             args: Enum.map(flags, &to_charlist/1) ++ code_path_args(),
             env: [{~c"HAL_C2_LABEL", to_charlist(machine.label)} | machine.env]
           }) do
        {:ok, peer} -> peer
        {:ok, peer, _mc} -> peer
      end

    settings = [
      start_mc: true,
      home: machine.home,
      port: 0,
      host: machine.address,
      cluster_listen: machine.address,
      cluster_port: context.cluster_port,
      tailscale_command: machine.tailscale
    ]

    for {key, value} <- settings,
        do: :ok = :peer.call(peer, Application, :put_env, [:hal_c2, key, value])

    with version when version != nil <- opts[:version],
         do: :peer.call(peer, :persistent_term, :put, [{HalC2.Upgrade, :version}, version])

    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:hal_c2], 30_000)
    id = :peer.call(peer, HalC2.Environment, :id, [])
    put_in(context.machines[name], Map.merge(machine, %{peer: peer, id: id}))
  end

  defp stop(context, name) do
    :ok = :peer.stop(context.machines[name].peer)
    context
  end

  # Boots the machines and joins each later one to the first.
  defp cluster(context, [first | rest]) do
    context = context |> machine(first) |> boot(first)

    Enum.reduce(rest, context, fn name, context ->
      context = context |> machine(name) |> boot(name)
      %{^first => inviter, ^name => joiner} = context.machines
      assert {:ok, _} = command(joiner, ["join", invite(inviter)])
      context
    end)
  end

  defp command(machine, args),
    do: :peer.call(machine.peer, HalC2.Cluster.Command, :command, [args], 30_000)

  defp status(machine), do: :peer.call(machine.peer, HalC2.Cluster, :status, [])

  # One RPC over a fresh socket to the machine's MC, as the TUI and desktop send it.
  # `:admin` pairs the client with an admin link, `:standard` with a standard one.
  defp client_call(machine, pairing, method, payload) do
    scopes =
      case pairing do
        :admin -> ~w(orchestration:read access:read access:write)
        :standard -> :peer.call(machine.peer, HalC2.Auth, :standard_scopes, [])
      end

    link = %{"label" => "Client", "scopes" => scopes}
    {:ok, %{"credential" => pairing_token}} = auth(machine, :create_pairing_link, [link])
    {:ok, access, _, _} = auth(machine, :exchange, [pairing_token, %{"label" => "Client"}])
    {:ok, ticket, _} = auth(machine, :issue_ticket, [access])

    port = URI.parse(origin(machine)).port
    {:ok, client} = WsClient.connect(port, "/ws?wsTicket=#{ticket}", machine.address)
    {%{"t" => "hello"}, client} = WsClient.recv(client, 5_000)

    id = System.unique_integer([:positive])
    client = Mc.rpc(client, machine.id, id, method, payload)
    reply? = &(&1["id"] == id and &1["t"] in ["rpc.result", "rpc.error"])
    {frame, _client} = Mc.await(client, reply?, 30_000)

    case frame do
      %{"t" => "rpc.result", "result" => result} -> {:ok, result}
      %{"t" => "rpc.error", "error" => error} -> {:error, error, frame["detail"]}
    end
  end

  defp auth(machine, fun, args), do: :peer.call(machine.peer, HalC2.Auth, fun, args)

  # A link from `hal_c2.cluster invite` on the machine.
  defp invite(machine) do
    {:ok, text} = command(machine, ["invite"])
    [_, link] = Regex.run(~r/cluster join (\S+)/, text)
    link
  end

  # The fingerprint an invite names.
  defp pin(link), do: URI.decode_query(URI.parse(link).fragment)["fingerprint"]

  defp fingerprint(machine) do
    dir = HalC2.Cluster.dir(:peer.call(machine.peer, HalC2.Paths, :data_dir, []))
    cert = X509.Certificate.from_pem!(File.read!(Path.join(dir, "mc.pem")))
    HalC2.Cluster.fingerprint(cert)
  end

  defp origin(machine) do
    path = :peer.call(machine.peer, HalC2.RuntimeRecord, :path, [])
    JSON.decode!(File.read!(path))["origin"]
  end

  # Waits on `machine` itself for its connection to `other` (discovery looks every 10s).
  defp await_connected(machine, other, timeout \\ 15_000) do
    await_mc(machine, :nodeup, HalC2.Cluster.mc_name(other.id), timeout)
  end

  defp await_disconnected(machine, other) do
    await_mc(machine, :nodedown, HalC2.Cluster.mc_name(other.id), 15_000)
  end

  # Waits until `machine`'s sidebar has rows of `other` (`listed`) or has none.
  defp await_sidebar(machine, other, listed) do
    code = """
    :ok = HalC2.Shell.subscribe(self())

    wait = fn wait ->
      Enum.any?(HalC2.Shell.rows(), &match?({{^mc, _}, _}, &1)) == listed or
        receive do
          {:hal_c2_shell, _} -> wait.(wait)
        after
          15_000 -> false
        end
    end

    wait.(wait)
    """

    binding = [mc: HalC2.Cluster.mc_name(other.id), listed: listed]
    {result, _} = :peer.call(machine.peer, Code, :eval_string, [code, binding], 20_000)
    result
  end

  defp await_mc(machine, event, mc, timeout) do
    code = """
    :ok = :net_kernel.monitor_nodes(true)

    result =
      (mc in Node.list()) == (event == :nodeup) or
        receive do
          {^event, ^mc} -> true
        after
          timeout -> false
        end

    :net_kernel.monitor_nodes(false)
    result
    """

    binding = [mc: mc, event: event, timeout: timeout]
    {result, _} = :peer.call(machine.peer, Code, :eval_string, [code, binding], timeout + 5_000)
    result
  end

  # A TLS handshake with the machine's cluster port; returns the alert that ended it.
  defp handshake(context, machine, options) do
    {:ok, ip} = :inet.parse_address(to_charlist(machine.address))
    {:ok, _} = Application.ensure_all_started(:ssl)
    options = [active: false, versions: [:"tlsv1.3"]] ++ options

    # Under TLS 1.3 the server judges the client's certificate after the client
    # finished, so a refusal can arrive on the first read.
    case :ssl.connect(ip, context.cluster_port, options, 5_000) do
      {:ok, socket} ->
        result = :ssl.recv(socket, 0, 5_000)
        :ssl.close(socket)
        with {:error, {:tls_alert, _} = alert} <- result, do: alert

      {:error, {:tls_alert, _} = alert} ->
        alert
    end
  end

  # A `tailscale` stand-in whose tailnet lists `addresses` as online peers.
  defp tailnet(context, machine, addresses) do
    state = Path.join(Mc.tmp_dir(context.mc, "tailscale"), "state.json")

    File.write!(
      state,
      JSON.encode!(%{
        "self" => %{"TailscaleIPs" => List.wrap(machine && machine.address)},
        "peers" => Map.new(addresses, &{&1, %{"Online" => true, "TailscaleIPs" => [&1]}})
      })
    )

    ["env", "FAKE_TAILSCALE_STATE=#{state}", Path.expand("test/support/fake_tailscale.py")]
  end

  # Makes this VM a named MC (as a clustered MC boots) and restarts the MC on it.
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
    context = %{context | mc: Mc.restart(context.mc)}
    name = :"hal_c2_member#{System.unique_integer([:positive])}"
    start_second(context, name, home || Mc.tmp_dir(context.mc, "second"), env)
  end

  # The second machine: a peer running the whole MC, labelled "garden-box". Returns
  # once the connected MC knows its environment.
  defp start_second(context, name, home, env \\ []) do
    {:ok, peer, mc} =
      :peer.start_link(%{
        name: name,
        host: ~c"127.0.0.1",
        longnames: true,
        args: code_path_args(),
        env: [{~c"HAL_C2_LABEL", ~c"garden-box"} | env]
      })

    for {key, value} <- [start_mc: true, home: home, port: 0],
        do: :ok = :erpc.call(mc, Application, :put_env, [:hal_c2, key, value])

    {:ok, _} = :erpc.call(mc, Application, :ensure_all_started, [:hal_c2], 30_000)

    assert_receive {:hal_c2_shell, {:environment, ^mc, %{"environmentId" => environment}}},
                   10_000

    Map.put(context, :second, %{
      name: name,
      home: home,
      peer: peer,
      mc: mc,
      environment: environment
    })
  end

  defp sleep_second(context) do
    mc = context.second.mc
    :peer.stop(context.second.peer)
    assert_receive {:hal_c2_shell, {:mc, ^mc, :down}}, 5_000
    context
  end

  defp remote_project(context, title) do
    root = Mc.tmp_dir(context.mc, "garden")

    {:ok, _} =
      :erpc.call(context.second.mc, HalC2.Projects, :mutate, [
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
      :erpc.call(context.second.mc, HalC2.Orchestration, :dispatch, [
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

    client = context.mc |> Mc.connect() |> Mc.sub(1, %{"type" => "shell"})
    key = {context.second.mc, context.remote["Garden work"]}
    {_, client} = shell_until(client, &Map.has_key?(&1.rows, key))
    World.put_client(context, client)
  end

  # Subscribes to the shell again (id 3) and returns its first frame, as a new window would.
  defp resubscribe(context) do
    client = Mc.unsub(World.client(context), 1)
    client = Mc.sub(client, 3, %{"type" => "shell"})
    {frame, client} = Mc.await(client, &(&1["t"] == "shell" and &1["id"] == 3), 5_000)
    {shell(frame), client}
  end

  # Reads shell frames, folding row updates in, until `done?` holds for the sidebar.
  defp shell_until(client, done?, shell \\ %{rows: %{}, mcs: %{}}) do
    {frame, client} =
      Mc.await(
        client,
        &(&1["t"] in ["shell", "shell.rows", "shell.mc", "shell.environment"]),
        5_000
      )

    shell =
      case frame do
        %{"t" => "shell"} ->
          shell(frame)

        %{"t" => "shell.rows", "mc" => mc, "rows" => rows} ->
          mc = String.to_existing_atom(mc)

          update_in(
            shell.rows,
            &Enum.into(rows, &1, fn [id, kind, row] -> {{mc, id}, {kind, row}} end)
          )

        %{"t" => "shell.mc", "mc" => mc, "online" => online} ->
          put_in(shell, [:mcs, Access.key(mc, %{}), "online"], online)

        %{"t" => "shell.environment", "mc" => mc, "environment" => environment} ->
          put_in(shell, [:mcs, Access.key(mc, %{}), "environment"], environment)
      end

    if done?.(shell), do: {shell, client}, else: shell_until(client, done?, shell)
  end

  defp shell(%{"mcs" => mcs, "rows" => rows}) do
    %{
      mcs: Map.new(mcs, &{&1["mc"], &1}),
      rows:
        Map.new(rows, fn [mc, id, kind, row] ->
          {{String.to_existing_atom(mc), id}, {kind, row}}
        end)
    }
  end

  defp png, do: <<0x89, "PNG">>

  defp upload_link(context) do
    {:ok, link} =
      :erpc.call(context.second.mc, HalC2.Attachments, :create_upload_url, [
        %{"name" => "shot.png", "mimeType" => "image/png", "sizeBytes" => byte_size(png())}
      ])

    Map.put(context, :upload, %{id: link["attachmentId"], path: link["relativeUrl"]})
  end

  defp upload(context) do
    url = to_charlist("http://127.0.0.1:#{context.mc.port}#{context.upload.path}")
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
