defmodule HalC2.PreviewForwardTest do
  # Most cases forward to this MC itself, which takes the same path as another
  # MC (`:erpc` to the node, its grant, its pipes) without starting one; the
  # dev server listens on a loopback address of its own (127.0.0.2), as the
  # thread's MC is told to dial, so this MC's 127.0.0.1 and ::1 stay free.
  use ExUnit.Case, async: false

  alias HalC2.PreviewForward
  alias HalC2.Test.DevServer

  @dev {127, 0, 0, 2}
  @thread "th-forward"
  @registry HalC2.PreviewForward.Registry

  setup do
    start_supervised!(HalC2.Preview)
    start_supervised!(HalC2.PreviewForward)
    Application.put_env(:hal_c2, :preview_forward_loopback, [@dev])
    on_exit(fn -> Application.delete_env(:hal_c2, :preview_forward_loopback) end)
    :ok
  end

  describe "refusals" do
    test "a port none of the thread's tabs names is not forwarded" do
      {port, _} = DevServer.echo(@dev, 0, self())
      tab(port + 1)
      tab(port, "th-other")
      assert PreviewForward.forward(node(), @thread, port) == {:error, :not_open}
      assert PreviewForward.listening() == []
    end

    test "the MC's own ports are not forwarded, though a tab names them" do
      previous = Application.get_env(:hal_c2, :port)
      Application.put_env(:hal_c2, :port, 3781)
      on_exit(fn -> Application.put_env(:hal_c2, :port, previous) end)

      for port <- [HalC2.Web.port(), HalC2.Cluster.dist_port()] do
        tab(port)
        assert PreviewForward.forward(node(), @thread, port) == {:error, :reserved}
      end

      assert PreviewForward.listening() == []
    end

    test "an MC that does not answer is unavailable" do
      assert PreviewForward.forward(:nobody@nowhere, @thread, 3000) == {:error, :unavailable}
      assert PreviewForward.listening() == []
    end

    test "only loopback URLs at the port name it" do
      assert PreviewForward.loopback?("http://localhost:3000/cart?x=1#y", 3000)
      assert PreviewForward.loopback?("https://127.0.0.1:3000", 3000)
      assert PreviewForward.loopback?("http://[::1]:3000/", 3000)
      assert PreviewForward.loopback?("http://localhost/", 80)
      refute PreviewForward.loopback?("http://localhost:3001/", 3000)
      refute PreviewForward.loopback?("http://example.com:3000/", 3000)
      refute PreviewForward.loopback?("file://localhost:3000/", 3000)
      refute PreviewForward.loopback?(nil, 3000)
    end
  end

  describe "listening" do
    test "on the dev server's port of this machine's loopback when it is free" do
      {port, _} = DevServer.echo(@dev, 0, self())
      tab(port)
      assert PreviewForward.forward(node(), @thread, port) == {:ok, port}
      # Asked again, the same forward.
      assert PreviewForward.forward(node(), @thread, port) == {:ok, port}
      assert [{{_, @thread, ^port}, ^port}] = PreviewForward.listening()

      for socket <- :sys.get_state(listener(port)).sockets do
        {:ok, {ip, ^port}} = :inet.sockname(socket)
        assert ip in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}]
      end

      assert round_trip(port, "hello") == "hello"
    end

    test "on another free port when this machine's is taken" do
      {port, _} = DevServer.echo(@dev, 0, self())
      {:ok, busy} = :gen_tcp.listen(port, ip: {127, 0, 0, 1})
      tab(port)
      assert {:ok, other} = PreviewForward.forward(node(), @thread, port)
      assert other != port
      assert round_trip(other, "hello") == "hello"
      :gen_tcp.close(busy)
    end
  end

  describe "connections" do
    setup do
      {port, _} = DevServer.echo(@dev, 0, self())
      tab(port)
      {:ok, ^port} = PreviewForward.forward(node(), @thread, port)
      %{port: port}
    end

    test "carry bytes both ways, many chunks at a time", %{port: port} do
      socket = connect(port)
      data = :crypto.strong_rand_bytes(3 * 1024 * 1024 + 17)
      # Sent while the echo is read, or both ends' buffers fill.
      sender = Task.async(fn -> :gen_tcp.send(socket, data) end)
      assert {:ok, ^data} = :gen_tcp.recv(socket, byte_size(data), 10_000)
      assert Task.await(sender) == :ok
    end

    test "closed by the browser close at the dev server", %{port: port} do
      socket = connect(port)
      assert_receive {:dev_server, :accepted, conn}
      :gen_tcp.close(socket)
      assert_receive {:dev_server, :closed, ^conn}
    end

    test "closed by the dev server close at the browser, after what it sent", %{port: port} do
      socket = connect(port)
      assert_receive {:dev_server, :accepted, conn}
      :ok = :gen_tcp.send(socket, "last")
      assert {:ok, "last"} = :gen_tcp.recv(socket, 4, 5_000)
      send(conn, :close)
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5_000)
      # The forward goes on.
      assert round_trip(port, "again") == "again"
    end
  end

  describe "a forward closes" do
    test "with the thread's last tab at the port, and its connections with it" do
      {port, _} = DevServer.echo(@dev, 0, self())
      first = tab(port)
      second = tab(port)
      {:ok, ^port} = PreviewForward.forward(node(), @thread, port)
      ref = Process.monitor(listener(port))
      socket = connect(port)
      assert_receive {:dev_server, :accepted, _}

      {:ok, nil} = HalC2.Preview.close(%{"threadId" => @thread, "tabId" => first})
      # The grant has seen the close: it was sent before `close/1` returned.
      _ = :sys.get_state(grant())
      assert round_trip(port, "still") == "still"

      {:ok, nil} = HalC2.Preview.close(%{"threadId" => @thread, "tabId" => second})
      assert_receive {:DOWN, ^ref, :process, _, _}
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5_000)
      assert PreviewForward.listening() == []
      assert {:error, _} = :gen_tcp.connect({127, 0, 0, 1}, port, [], 1_000)
    end

    test "when the last tab at the port navigates elsewhere" do
      {port, _} = DevServer.echo(@dev, 0, self())
      tab = tab(port)
      {:ok, ^port} = PreviewForward.forward(node(), @thread, port)
      ref = Process.monitor(listener(port))
      url = "http://localhost:#{port + 1}/"
      {:ok, _} = HalC2.Preview.navigate(%{"threadId" => @thread, "tabId" => tab, "url" => url})
      assert_receive {:DOWN, ^ref, :process, _, _}
      assert PreviewForward.forward(node(), @thread, port) == {:error, :not_open}
    end
  end

  describe "with the thread on another MC" do
    @describetag :tmp_dir
    @describetag :cluster

    setup %{tmp_dir: dir} do
      unless Node.alive?() do
        {_, 0} = System.cmd("epmd", ["-daemon"])
        name = :"hal_c2_test#{System.unique_integer([:positive])}@127.0.0.1"
        {:ok, _} = Node.start(name, :longnames)
      end

      # Controlled over its standard io, so it can be cut off and still stopped.
      {:ok, peer, mc} =
        :peer.start_link(%{
          name: :"hal_c2_peer#{System.unique_integer([:positive])}",
          host: ~c"127.0.0.1",
          longnames: true,
          connection: :standard_io,
          args:
            Enum.flat_map(:code.get_path(), &[~c"-pa", &1]) ++
              [~c"-setcookie", ~c"#{Node.get_cookie()}"]
        })

      env = [start_mc: true, home: dir, port: 0, preview_forward_loopback: [@dev]]

      for {key, value} <- env,
          do: :ok = :peer.call(peer, Application, :put_env, [:hal_c2, key, value])

      {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:hal_c2])

      {port, _} = :peer.call(peer, DevServer, :echo, [@dev, 0, self()])
      url = "http://localhost:#{port}/"
      {:ok, _} = :peer.call(peer, HalC2.Preview, :open, [%{"threadId" => @thread, "url" => url}])
      {:ok, ^port} = PreviewForward.forward(mc, @thread, port)
      ref = Process.monitor(listener(port, mc))
      socket = connect(port)
      assert_receive {:dev_server, :accepted, _}, 5_000
      %{peer: peer, mc: mc, port: port, ref: ref, socket: socket}
    end

    test "it closes, with its connections, when the MC stops", context do
      %{peer: peer, port: port, ref: ref, socket: socket} = context
      assert round_trip(port, "hello") == "hello"
      :peer.stop(peer)
      assert_receive {:DOWN, ^ref, :process, _, _}, 10_000
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5_000)
      assert PreviewForward.listening() == []
    end

    test "it closes on both MCs when they are cut apart", context do
      %{peer: peer, mc: mc, ref: ref, socket: socket} = context

      [{_, grant, _, _}] =
        :peer.call(peer, DynamicSupervisor, :which_children, [HalC2.PreviewForward.Grants])

      watcher = :peer.call(peer, DevServer, :watch, [grant])
      true = Node.disconnect(mc)
      assert_receive {:DOWN, ^ref, :process, _, {:shutdown, {:grant, :noconnection}}}, 10_000
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5_000)
      # The thread's MC dropped its half too, and the connection it dialed.
      assert :peer.call(peer, DevServer, :down, [watcher]) == {:shutdown, {:down, :noconnection}}
      assert_receive {:dev_server, :closed, _}, 5_000
    end
  end

  defp tab(port, thread \\ @thread) do
    url = "http://localhost:#{port}/"
    {:ok, %{"tabId" => tab}} = HalC2.Preview.open(%{"threadId" => thread, "url" => url})
    tab
  end

  defp listener(port, mc \\ node()) do
    [{pid, _}] = Registry.lookup(@registry, {mc, @thread, port})
    pid
  end

  defp grant do
    [{_, pid, _, _}] = DynamicSupervisor.which_children(HalC2.PreviewForward.Grants)
    pid
  end

  defp connect(port) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    socket
  end

  defp round_trip(port, data) do
    socket = connect(port)
    :ok = :gen_tcp.send(socket, data)
    {:ok, echoed} = :gen_tcp.recv(socket, byte_size(data), 5_000)
    :gen_tcp.close(socket)
    echoed
  end
end
