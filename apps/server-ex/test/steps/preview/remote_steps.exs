defmodule HalC2.Steps.Preview.Remote do
  @moduledoc """
  Steps for `features/preview/remote.feature`: browser tabs, local server
  suggestions and agent browser hosts of another node, reached through a socket
  on this one.

  The second node is a `:peer` VM running the whole app (`context.peer`); both
  run on this machine, so the second node's "machine" is told apart by the
  `lsof` it runs, which lists only its own dev server.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Node
  alias HalC2.Test.Node.World
  alias HalC2.Test.WsClient

  @sub 91
  @remote_thread "th-remote"

  # --- tabs on another node ------------------------------------------------------------------

  step "the client is connected to one node of a cluster", context do
    cluster(context)
  end

  step "the desktop is connected to one node of a cluster", context do
    cluster(context)
  end

  step "a thread on a second node has browser tabs", context do
    {:ok, %{"tabId" => tab}} =
      :erpc.call(context.peer, HalC2.Preview, :open, [
        %{"threadId" => @remote_thread, "url" => "http://localhost:5173/"}
      ])

    Map.put(context, :tab, tab)
  end

  step "the client watches the second node's browser tabs", context do
    client = context |> World.client() |> watch(%{"type" => "preview"}, context.peer) |> ping()
    World.put_client(context, "default", client)
  end

  step "it receives the second node's tab changes as they happen", context do
    %{peer: peer, tab: tab} = context
    url = "http://localhost:5173/cart"
    input = %{"threadId" => @remote_thread, "tabId" => tab, "url" => url}
    {:ok, _} = :erpc.call(peer, HalC2.Preview, :navigate, [input])
    {:ok, %{"serverEpoch" => epoch}} = :erpc.call(peer, HalC2.Preview, :list, [input])

    {frame, _client} =
      Node.await(World.client(context), fn frame ->
        frame["t"] == "preview" and frame["id"] == @sub and frame["event"]["tabId"] == tab
      end)

    assert %{"threadId" => @remote_thread, "serverEpoch" => ^epoch} = frame["event"]
    assert frame["event"]["snapshot"]["navStatus"]["url"] == url
    # This node's own tabs have their own run.
    Node.ensure(HalC2.Preview)

    assert HalC2.Preview.list(%{"threadId" => @remote_thread}) |> elem(1) |> Map.get("serverEpoch") !=
             epoch

    context
  end

  step "the client opens a browser tab for a thread on the second node", context do
    Node.ensure(HalC2.Preview)
    input = %{"threadId" => @remote_thread, "url" => "http://localhost:5173/"}

    {reply, client} =
      Node.call(World.client(context), context.peer_environment, "preview.open", input)

    assert {:ok, %{"tabId" => tab}} = reply

    context
    |> World.put_client("default", client)
    |> Map.put(:tab, tab)
  end

  step "the tab is kept by the second node", context do
    {:ok, remote} = :erpc.call(context.peer, HalC2.Preview, :list, [%{"threadId" => @remote_thread}])
    assert [%{"tabId" => tab}] = remote["sessions"]
    assert tab == context.tab
    {:ok, local} = HalC2.Preview.list(%{"threadId" => @remote_thread})
    assert local["sessions"] == []
    context
  end

  # --- local servers -------------------------------------------------------------------------

  # A server on each "machine"; the second node's `lsof` lists only its own.
  step "a dev server is running on the second node's machine", context do
    dev = serve_html()
    here = serve_html()
    dir = Node.tmp_dir(context.node, "peer-bin")
    lsof = Path.join(dir, "lsof")
    File.write!(lsof, "#!/bin/sh\nprintf 'p4242\\ncvite\\nn127.0.0.1:#{dev}\\n'\n")
    File.chmod!(lsof, 0o755)
    path = :erpc.call(context.peer, System, :get_env, ["PATH"])
    :ok = :erpc.call(context.peer, System, :put_env, ["PATH", dir <> ":" <> path])
    Map.merge(context, %{dev_port: dev, first_port: here})
  end

  step "the client watches the second node's local servers", context do
    client = World.client(context) |> watch(%{"type" => "localServers"}, context.peer)

    {frame, client} =
      Node.await(client, &(&1["t"] == "localServers" and &1["id"] == @sub), 10_000)

    context
    |> World.put_client("default", client)
    |> Map.put(:servers, frame["list"]["servers"])
  end

  step "the second node's dev server is suggested", context do
    url = "http://localhost:#{context.dev_port}"

    assert [%{"port" => port, "url" => ^url, "processName" => "vite", "pid" => 4242}] =
             context.servers

    assert port == context.dev_port
    context
  end

  step "servers on the first node's machine are not", context do
    refute Enum.any?(context.servers, &(&1["port"] == context.first_port))
    # This node's own suggestions do include it.
    Node.ensure(HalC2.LocalServers)
    assert {:ok, %{"servers" => servers}} = HalC2.LocalServers.subscribe(self())
    assert Enum.any?(servers, &(&1["port"] == context.first_port))
    context
  end

  # --- refusals ------------------------------------------------------------------------------

  step ~r/^the client watches (?<activity>.+) on a node the server does not know$/,
       %{args: [activity]} = context do
    shape =
      case activity do
        "browser tabs" -> %{"type" => "preview"}
        "local servers" -> %{"type" => "localServers"}
        "agent browser work" -> %{"type" => "previewAutomation", "host" => host("desktop-1")}
      end

    client = World.client(context) |> watch(shape, :nobody@nowhere)
    {frame, client} = Node.await(client, &(&1["t"] == "error"))

    context
    |> World.put_client("default", client)
    |> Map.put(:error_frame, frame)
  end

  step "the request fails with {string}", %{args: [reason]} = context do
    assert %{"t" => "error", "reason" => ^reason} = context.error_frame
    context
  end

  step "a node of the cluster has stopped answering", context do
    peer = start_peer(context)
    environment(peer)
    true = :erlang.monitor_node(peer, true)
    :ok = :erpc.call(peer, :init, :stop, [])
    assert_receive {:nodedown, ^peer}, 10_000
    Map.put(context, :peer, peer)
  end

  step "the client watches that node's browser tabs", context do
    client = World.client(context) |> watch(%{"type" => "preview"}, context.peer)
    {frame, client} = Node.await(client, &(&1["t"] == "error"), 10_000)

    context
    |> World.put_client("default", client)
    |> Map.put(:error_frame, frame)
  end

  step "the request fails saying the node is unavailable", context do
    assert %{"id" => @sub, "reason" => "node unavailable: " <> _} = context.error_frame
    context
  end

  # --- agent browser hosts -------------------------------------------------------------------

  step "an agent runs in a thread on the second node", context do
    Map.put(context, :scope, %{thread_id: @remote_thread, instance: "codex"})
  end

  step "the desktop offers its browser to the second node", context do
    offer(context, context.peer)
  end

  step "the agent's browser actions reach the desktop", context do
    %{peer: peer, scope: scope} = context

    task =
      Task.async(fn ->
        :erpc.call(peer, HalC2.PreviewAutomation, :invoke, [scope, "status", %{}])
      end)

    {request, context} = request(context)
    assert %{"operation" => "status", "threadId" => @remote_thread} = request

    response = %{
      "clientId" => "desktop-1",
      "connectionId" => context.connection_id,
      "requestId" => request["requestId"],
      "ok" => true,
      "result" => %{"tabId" => "tab-1", "url" => "http://localhost:5173/"}
    }

    {{:ok, _}, client} =
      Node.call(
        World.client(context),
        context.peer_environment,
        "previewAutomation.respond",
        response
      )

    assert {:ok, %{"tabId" => "tab-1"}} = Task.await(task)
    World.put_client(context, "default", client)
  end

  step "a desktop is offering its browser to a node", context do
    Node.ensure(HalC2.PreviewAutomation)

    context
    |> Map.put(:scope, %{thread_id: "th-agent", instance: "codex"})
    |> offer(node())
  end

  # With an action in flight, so its fate can be checked.
  step "the desktop's connection to the server closes", context do
    scope = context.scope
    task = Task.async(fn -> HalC2.PreviewAutomation.invoke(scope, "click", %{}) end)
    {%{"operation" => "click"}, context} = request(context)
    Mint.HTTP.close(World.client(context).conn)

    context
    |> Map.update!(:clients, &Map.delete(&1, "default"))
    |> Map.put(:task, task)
  end

  step "the node stops sending it the agent's browser actions", context do
    assert {:error,
            %{"_tag" => "PreviewAutomationClientDisconnectedError", "clientId" => "desktop-1"}} =
             Task.await(context.task)

    refute Map.has_key?(:sys.get_state(HalC2.PreviewAutomation).clients, "desktop-1")

    assert {:error, %{"_tag" => "PreviewAutomationNoAvailableHostError"}} =
             HalC2.PreviewAutomation.invoke(context.scope, "click", %{})

    context
  end

  step "any action it had not answered fails as disconnected", context do
    # Awaited by the previous step, which needed the drop to have happened.
    assert :sys.get_state(HalC2.PreviewAutomation).pending == %{}
    context
  end

  step "a client is watching a node's browser tabs", context do
    Node.ensure(HalC2.Preview)
    client = context |> World.client() |> watch(%{"type" => "preview"}, node()) |> ping()
    assert map_size(:sys.get_state(HalC2.Preview).watchers) == 1
    World.put_client(context, "default", client)
  end

  step "the client stops watching", context do
    client = context |> World.client() |> Node.unsub(@sub) |> ping()
    World.put_client(context, "default", client)
  end

  step "the node stops sending it tab changes", context do
    assert :sys.get_state(HalC2.Preview).watchers == %{}
    {:ok, _} = HalC2.Preview.open(%{"threadId" => "th-local", "url" => "http://localhost:5173/"})
    client = World.client(context) |> WsClient.send_json(%{"t" => "ping"})
    {_pong, skipped, _client} = WsClient.recv_until(client, &(&1["t"] == "pong"))
    assert Enum.filter(skipped, &(&1["t"] == "preview")) == []
    context
  end

  # --- helpers -------------------------------------------------------------------------------

  defp cluster(context) do
    peer = Node.start_peer(context.node)
    %{"environmentId" => environment} = environment(peer)
    Map.merge(context, %{peer: peer, peer_environment: environment})
  end

  # The peer's environment descriptor, once this node's shell has it (RPCs route by it).
  defp environment(peer) do
    HalC2.Shell.subscribe(self())

    case List.keyfind(HalC2.Shell.environments(), peer, 0) do
      {^peer, descriptor} ->
        descriptor

      nil ->
        assert_receive {:halc2_shell, {:environment, ^peer, descriptor}}, 10_000
        descriptor
    end
  end

  # Like `Node.start_peer/1`, but its controller outlives the node (`peer_down:
  # :continue`), so the scenario can stop the node and still clean up after it.
  defp start_peer(context) do
    unless :erlang.is_alive() do
      {_, 0} = System.cmd("epmd", ["-daemon"])
      name = :"halc2features#{System.unique_integer([:positive])}@127.0.0.1"
      {:ok, _} = :net_kernel.start(name, %{name_domain: :longnames})
    end

    {:ok, peer, name} =
      :peer.start(%{
        name: :"halc2peer#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true,
        peer_down: :continue,
        args: Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
      })

    ExUnit.Callbacks.on_exit(fn -> :peer.stop(peer) end)
    home = Path.join(context.node.home, "peer-gone")

    for {key, value} <- [start_node: true, home: home, port: 0],
        do: :ok = :erpc.call(name, Application, :put_env, [:hal_c2, key, value])

    {:ok, _} = :erpc.call(name, Application, :ensure_all_started, [:hal_c2])
    name
  end

  defp watch(client, shape, node),
    do: Node.sub(client, @sub, Map.put(shape, "node", Atom.to_string(node)))

  defp ping(client) do
    client = WsClient.send_json(client, %{"t" => "ping"})
    {_, client} = Node.await(client, &(&1["t"] == "pong"))
    client
  end

  defp host(client_id), do: %{"clientId" => client_id, "environmentId" => "env-desktop"}

  defp offer(context, node) do
    client =
      World.client(context)
      |> watch(%{"type" => "previewAutomation", "host" => host("desktop-1")}, node)

    {frame, client} =
      Node.await(client, &(&1["t"] == "previewAutomation" and &1["event"]["type"] == "connected"))

    context
    |> World.put_client("default", client)
    |> Map.put(:connection_id, frame["event"]["connectionId"])
  end

  defp request(context) do
    {frame, client} =
      Node.await(World.client(context), fn frame ->
        frame["t"] == "previewAutomation" and frame["event"]["type"] == "request"
      end)

    assert frame["event"]["connectionId"] == context.connection_id
    {frame["event"]["request"], World.put_client(context, "default", client)}
  end

  defp serve_html do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen)
    pid = spawn(fn -> receive(do: (:go -> accept(listen))) end)
    :ok = :gen_tcp.controlling_process(listen, pid)
    send(pid, :go)
    ExUnit.Callbacks.on_exit(fn -> Process.exit(pid, :kill) end)
    port
  end

  defp accept(listen) do
    {:ok, socket} = :gen_tcp.accept(listen)
    _ = :gen_tcp.recv(socket, 0, 1_000)

    :gen_tcp.send(
      socket,
      "HTTP/1.1 200 OK\r\ncontent-type: text/html\r\ncontent-length: 13\r\nconnection: close\r\n\r\n<html></html>"
    )

    :gen_tcp.close(socket)
    accept(listen)
  end
end
