defmodule HalC2.Test.DevServer do
  @moduledoc """
  A stand-in for a dev server, for the preview forward's tests: it listens on
  one address and tells `owner` (a pid on any MC) about its connections. It
  lives in `test/support` so a test can start it on a peer MC as well.

    * `echo/3` sends back every byte it gets. Each connection is reported as
      `{:dev_server, :accepted, conn}`; `send(conn, :close)` closes it from the
      server's side, and one the client closed is reported as
      `{:dev_server, :closed, conn}`.
    * `websocket/3` answers a page with HTML and a websocket upgrade with an
      echo of each text message. `{:dev_server, :ws_open, conn}` and
      `{:dev_server, :ws_closed, conn}` report each socket, and
      `send(conn, :close)` closes it from the server's side.

  Both return `{port, server}` and stop, with their connections, on `stop/1`
  or when `owner` ends (not when it is only cut off from the server's MC).
  """

  @socket [:binary, active: false, reuseaddr: true, packet: :raw]

  @doc "An echo server on `ip` at `port` (0 for a free one)."
  def echo(ip, port, owner), do: hold(owner, fn -> echo_listen(ip, port, owner) end)

  @doc "An HTTP server with a websocket echo on `ip` at `port` (0 for a free one)."
  def websocket(ip, port, owner) do
    hold(owner, fn ->
      {:ok, server} =
        Bandit.start_link(
          plug: {__MODULE__.Plug, owner},
          ip: ip,
          port: port,
          startup_log: false
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      port
    end)
  end

  def stop(server), do: send(server, :stop)

  @doc """
  Watches `pid` on this MC from a process of its own, for a test on another MC
  that may be cut off from this one while it ends: `down/1` gives its reason.
  """
  def watch(pid) do
    spawn(fn ->
      ref = Process.monitor(pid)
      reason = receive(do: ({:DOWN, ^ref, :process, _, reason} -> reason))
      receive(do: ({:reason, from} -> send(from, {:reason, reason})))
    end)
  end

  @doc "Waits for the process `watch/1` watches to end, and gives its reason."
  def down(watcher) do
    send(watcher, {:reason, self()})
    receive(do: ({:reason, reason} -> reason))
  end

  # Runs `start` in a process of its own that outlives the caller (an `:erpc`
  # call's process ends as soon as it returns) and holds what it starts until
  # `owner` ends; its shutdown takes what it linked down with it.
  defp hold(owner, start) do
    caller = self()
    ref = make_ref()

    server =
      spawn(fn ->
        owned = Process.monitor(owner)
        send(caller, {ref, start.()})

        receive do
          :stop -> :ok
          {:DOWN, ^owned, :process, _, reason} when reason != :noconnection -> :ok
        end

        exit(:shutdown)
      end)

    receive do
      {^ref, port} -> {port, server}
    end
  end

  defp echo_listen(ip, port, owner) do
    {:ok, listen} = :gen_tcp.listen(port, [{:ip, ip} | @socket])
    {:ok, port} = :inet.port(listen)
    spawn_link(fn -> accept(listen, owner) end)
    port
  end

  # Until the server stops, which closes `listen`.
  defp accept(listen, owner) do
    with {:ok, socket} <- :gen_tcp.accept(listen) do
      conn = spawn_link(fn -> receive(do: ({:socket, socket} -> echo(socket, owner))) end)
      :ok = :gen_tcp.controlling_process(socket, conn)
      send(conn, {:socket, socket})
      send(owner, {:dev_server, :accepted, conn})
      accept(listen, owner)
    end
  end

  defp echo(socket, owner) do
    :ok = :inet.setopts(socket, active: :once)

    receive do
      {:tcp, ^socket, data} ->
        :ok = :gen_tcp.send(socket, data)
        echo(socket, owner)

      {:tcp_closed, ^socket} ->
        send(owner, {:dev_server, :closed, self()})

      :close ->
        :gen_tcp.close(socket)
    end
  end

  defmodule Plug do
    @moduledoc false
    @behaviour Elixir.Plug

    @impl true
    def init(owner), do: owner

    @impl true
    def call(%{request_path: "/ws"} = conn, owner) do
      conn
      |> WebSockAdapter.upgrade(HalC2.Test.DevServer.Socket, owner, [])
      |> Elixir.Plug.Conn.halt()
    end

    def call(conn, _owner) do
      conn
      |> Elixir.Plug.Conn.put_resp_content_type("text/html")
      |> Elixir.Plug.Conn.send_resp(200, "<html>dev server</html>")
    end
  end

  defmodule Socket do
    @moduledoc false
    @behaviour WebSock

    @impl true
    def init(owner) do
      send(owner, {:dev_server, :ws_open, self()})
      {:ok, owner}
    end

    @impl true
    def handle_in({text, opcode: :text}, owner), do: {:push, {:text, text}, owner}
    def handle_in(_frame, owner), do: {:ok, owner}

    @impl true
    def handle_info(:close, owner), do: {:stop, :normal, owner}
    def handle_info(_message, owner), do: {:ok, owner}

    @impl true
    def terminate(_reason, owner) do
      send(owner, {:dev_server, :ws_closed, self()})
      :ok
    end
  end
end
