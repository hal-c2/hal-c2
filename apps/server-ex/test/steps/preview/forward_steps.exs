defmodule HalC2.Steps.Preview.Forward do
  @moduledoc """
  Steps for the forwarded dev servers of `features/preview/remote.feature`
  (`preview.forward`): a client asks the MC it is connected to for a dev server
  of a thread on a second MC, which is a `:peer` VM on this machine.

  The second MC's "machine" has a loopback address of its own, 127.0.0.2: its
  dev server listens there and it dials there, so this MC's 127.0.0.1 and ::1
  stand for the user's machine. The feature's port 3000 is the dev server's,
  which the OS picks.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.DevServer
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World
  alias HalC2.Test.WsClient

  @machine {127, 0, 0, 2}
  @thread "th-forward"

  # --- background ----------------------------------------------------------------------------

  step "the client is connected to the MC on its own machine", context do
    Mc.ensure(HalC2.PreviewForward)
    World.put_client(context, World.client(context))
  end

  step "that MC is in a cluster with a second MC on another machine", context do
    peer =
      Mc.start_peer(context.mc, stoppable: true, env: [preview_forward_loopback: [@machine]])

    Map.merge(context, %{peer: peer, peer_environment: environment(peer)})
  end

  step "a dev server on the second MC's machine listens on port 3000 for that machine only",
       context do
    {port, _} = :erpc.call(context.peer, DevServer, :websocket, [@machine, 0, self()])
    Map.put(context, :dev_port, port)
  end

  # --- forwarding ----------------------------------------------------------------------------

  step "the client opens a browser tab at {string} for a thread on the second MC",
       %{args: [url]} = context do
    open_and_forward(context, context.peer_environment, url)
  end

  step "the client's MC forwards port 3000 for a thread on the second MC", context do
    context = open_and_forward(context, context.peer_environment, "http://localhost:3000")
    assert {:ok, %{"port" => port}} = context.forward_reply
    [{listener, _}] = Registry.lookup(HalC2.PreviewForward.Registry, forward_key(context))
    Map.merge(context, %{local_port: port, listener: Process.monitor(listener)})
  end

  step "the client's MC listens on port 3000 for its own machine only", context do
    assert {:ok, %{"port" => port}} = context.forward_reply
    assert port == context.dev_port
    [{listener, _}] = Registry.lookup(HalC2.PreviewForward.Registry, forward_key(context))

    for socket <- :sys.get_state(listener).sockets do
      assert {:ok, {ip, ^port}} = :inet.sockname(socket)
      assert ip in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}]
    end

    Map.put(context, :local_port, port)
  end

  step "a page asked of that port is answered by the second MC's dev server", context do
    assert page(context.local_port) == "<html>dev server</html>"
    context
  end

  step "a page from the forward opens a websocket to the dev server", context do
    {client, conn} = websocket(context.local_port)
    Map.merge(context, %{ws: client, ws_conn: conn})
  end

  step "messages pass both ways until either side closes it", context do
    %{ws: client, ws_conn: conn, local_port: port} = context
    client = WsClient.send_json(client, %{"hello" => "dev server"})
    assert {%{"hello" => "dev server"}, client} = WsClient.recv(client, 5_000)
    client = WsClient.send_json(client, %{"and" => "back"})
    assert {%{"and" => "back"}, client} = WsClient.recv(client, 5_000)

    # The page closes it: the dev server's end closes.
    Mint.HTTP.close(client.conn)
    assert_receive {:dev_server, :ws_closed, ^conn}, 5_000

    # The dev server closes another: the page is told, answers as a browser
    # does, and its end closes.
    {client, conn} = websocket(port)
    socket = Mint.HTTP.get_socket(client.conn)
    send(conn, :close)
    assert_receive {:tcp, ^socket, _} = message, 5_000
    {:ok, conn, [{:data, _, data}]} = Mint.WebSocket.stream(client.conn, message)
    assert {:ok, ws, [{:close, 1000, _}]} = Mint.WebSocket.decode(client.ws, data)
    {:ok, _ws, data} = Mint.WebSocket.encode(ws, :close)
    {:ok, _conn} = Mint.WebSocket.stream_request_body(conn, client.ref, data)
    assert_receive {:tcp_closed, ^socket}, 5_000
    context
  end

  step "port 3000 is in use on the client's machine", context do
    {:ok, busy} = :gen_tcp.listen(context.dev_port, ip: {127, 0, 0, 1})
    Map.put(context, :busy, busy)
  end

  step "the client's MC forwards the dev server on a free port of its own machine", context do
    assert {:ok, %{"port" => port}} = context.forward_reply
    assert port != context.dev_port
    assert page(port) == "<html>dev server</html>"
    Map.put(context, :local_port, port)
  end

  step "the client is told the address it forwards to", context do
    assert HalC2.PreviewForward.listening() == [{forward_key(context), context.local_port}]
    context
  end

  # --- refusals ------------------------------------------------------------------------------

  step ~r/^the client asks to forward (?<what>.+) of the second MC's machine for a thread$/,
       %{args: [what]} = context do
    port =
      case what do
        "a port none of the thread's tabs names" -> context.dev_port
        "the second MC's own port, even when a tab names it" -> peer(context, HalC2.Web, :port)
        "the cluster's port, even when a tab names it" -> peer(context, HalC2.Cluster, :dist_port)
      end

    if what =~ "even when a tab names it" do
      input = %{"threadId" => @thread, "url" => "http://localhost:#{port}/"}

      {{:ok, _}, _} =
        Mc.call(World.client(context), context.peer_environment, "preview.open", input)
    end

    forward(context, context.peer_environment, port)
  end

  @doc false
  # `the request is refused` (common steps) for a forward.
  def refused(context) do
    assert {:error, _message, %{"_tag" => "PreviewForwardError", "reason" => reason}} =
             context.forward_reply

    assert reason in ["not_open", "reserved"]
    context
  end

  step "nothing listens for it on the client's machine", context do
    assert HalC2.PreviewForward.listening() == []
    context
  end

  # --- closing -------------------------------------------------------------------------------

  step "the thread's last tab at port 3000 is closed", context do
    input = %{"threadId" => @thread, "tabId" => context.tab}

    {{:ok, _}, client} =
      Mc.call(World.client(context), context.peer_environment, "preview.close", input)

    World.put_client(context, "default", client)
  end

  step "the client's MC stops listening on port 3000", context do
    ref = context.listener
    assert_receive {:DOWN, ^ref, :process, _, _}, 10_000
    assert HalC2.PreviewForward.listening() == []
    assert {:error, :econnrefused} = :gen_tcp.connect({127, 0, 0, 1}, context.local_port, [])
    context
  end

  # With a live connection through the forward, to see what becomes of it.
  step "the second MC stops answering", context do
    %{peer: peer, local_port: port} = context
    {client, _conn} = websocket(port)
    true = :erlang.monitor_node(peer, true)
    :ok = :erpc.call(peer, :init, :stop, [])
    assert_receive {:nodedown, ^peer}, 10_000
    Map.put(context, :ws, client)
  end

  step "connections through it are closed rather than left hanging", context do
    socket = Mint.HTTP.get_socket(context.ws.conn)
    assert_receive {:tcp_closed, ^socket}, 5_000
    context
  end

  # --- this MC's own threads -----------------------------------------------------------------

  step "the client opens a browser tab at {string} for a thread on its own MC",
       %{args: [url]} = context do
    Mc.ensure(HalC2.Preview)
    open_and_forward(context, context.mc.environment, url)
  end

  step "nothing is forwarded", context do
    assert HalC2.PreviewForward.listening() == []
    context
  end

  step "the tab's address stays {string}", %{args: [url]} = context do
    url = local_url(context, url)
    assert {:ok, %{"port" => port}} = context.forward_reply
    assert "http://localhost:#{port}" == url
    {:ok, %{"sessions" => [tab]}} = HalC2.Preview.list(%{"threadId" => @thread})
    assert tab["navStatus"]["url"] == url
    context
  end

  # --- helpers -------------------------------------------------------------------------------

  # Opens the tab on the thread's MC, then asks this MC for its dev server, as
  # the desktop does before it opens the system browser.
  defp open_and_forward(context, environment, url) do
    url = local_url(context, url)
    input = %{"threadId" => @thread, "url" => url}
    {reply, client} = Mc.call(World.client(context), environment, "preview.open", input)
    assert {:ok, %{"tabId" => tab}} = reply

    context
    |> World.put_client("default", client)
    |> Map.put(:tab, tab)
    |> forward(environment, URI.parse(url).port)
  end

  defp forward(context, environment, port) do
    input = %{"environmentId" => environment, "threadId" => @thread, "port" => port}

    {reply, client} =
      Mc.call(World.client(context), context.mc.environment, "preview.forward", input)

    context
    |> World.put_client("default", client)
    |> Map.put(:forward_reply, reply)
  end

  defp local_url(context, url), do: String.replace(url, ":3000", ":#{context.dev_port}")

  defp forward_key(context), do: {context.peer, @thread, context.dev_port}

  defp peer(context, module, fun), do: :erpc.call(context.peer, module, fun, [])

  defp page(port) do
    {status, body} = Mc.http("http://127.0.0.1:#{port}", :get, "/")
    assert status == 200
    body
  end

  defp websocket(port) do
    {:ok, client} = WsClient.connect(port, "/ws")
    assert_receive {:dev_server, :ws_open, conn}, 5_000
    {client, conn}
  end

  # The peer's environment id, once this MC's shell has it (RPCs route by it).
  defp environment(peer) do
    HalC2.Shell.subscribe(self())

    case List.keyfind(HalC2.Shell.environments(), peer, 0) do
      {^peer, %{"environmentId" => id}} ->
        id

      nil ->
        assert_receive {:hal_c2_shell, {:environment, ^peer, %{"environmentId" => id}}}, 10_000
        id
    end
  end
end
