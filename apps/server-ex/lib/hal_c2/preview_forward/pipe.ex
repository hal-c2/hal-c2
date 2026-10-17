defmodule HalC2.PreviewForward.Pipe do
  @moduledoc """
  One end of one forwarded connection, owning its socket: the browser's on the
  client's MC (`:accept`), the dev server's on the thread's MC (`:dial`). The
  two ends send each other `{:preview_forward, :data, chunk}` (at most
  `@chunk` bytes) and answer each with `{:preview_forward, :ack}`; an end
  reads its socket only while fewer than `@window` of its chunks are unacked,
  so a slow reader slows the writer instead of filling a mailbox. Each end
  monitors the other: a socket closed or an end gone closes the other socket,
  after the bytes already sent (distribution keeps a pair's messages ahead of
  the `:DOWN`).
  """

  use GenServer, restart: :temporary

  @chunk 65_536
  @window 4
  @dial_timeout 5_000
  @socket [:binary, active: false, packet: :raw, buffer: @chunk]

  def start_link(side), do: GenServer.start_link(__MODULE__, side)

  @impl true
  def init({:accept, grant}),
    do: {:ok, %{side: :accept, grant: grant, socket: nil, peer: nil, unacked: 0, armed: false}}

  def init({:dial, port, peer}) do
    state = %{side: :dial, socket: nil, peer: peer, unacked: 0, armed: false}
    Process.monitor(peer)
    {:ok, state, {:continue, {:dial, port}}}
  end

  @impl true
  def handle_continue({:dial, port}, state) do
    case dial(port) do
      {:ok, socket} -> {:noreply, arm(%{state | socket: socket})}
      {:error, _} -> {:stop, :normal, state}
    end
  end

  @impl true
  # The listener hands the browser's socket over once this end owns it. Its
  # reads are a chunk at most, as the dev server's are.
  def handle_info({:socket, socket}, %{side: :accept, grant: grant} = state) do
    _ = :inet.setopts(socket, buffer: @chunk)
    state = %{state | socket: socket}

    case :erpc.call(node(grant), HalC2.PreviewForward, :dial, [grant, self()], @dial_timeout) do
      {:ok, peer} ->
        Process.monitor(peer)
        {:noreply, arm(%{state | peer: peer})}

      {:error, _} ->
        {:stop, :normal, state}
    end
  catch
    :error, {:erpc, _} -> {:stop, :normal, state}
    :exit, _ -> {:stop, :normal, state}
  end

  # A read is one chunk: the socket's buffer is `@chunk` bytes.
  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    send(state.peer, {:preview_forward, :data, data})
    {:noreply, arm(%{state | unacked: state.unacked + 1, armed: false})}
  end

  # An app that has closed its end refuses the chunk, which is dropped: the pipe ends
  # when it reads the close, after what the app wrote before it (a pipe that ended on
  # the refusal would drop those bytes, such as a dev server's last response).
  def handle_info({:preview_forward, :data, chunk}, state) do
    _ = :gen_tcp.send(state.socket, chunk)
    send(state.peer, {:preview_forward, :ack})
    {:noreply, state}
  end

  def handle_info({:preview_forward, :ack}, state),
    do: {:noreply, arm(%{state | unacked: state.unacked - 1})}

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state),
    do: {:stop, :normal, state}

  def handle_info({:tcp_error, socket, _}, %{socket: socket} = state),
    do: {:stop, :normal, state}

  # The other end is gone: what it sent is already written.
  def handle_info({:DOWN, _ref, :process, _, _}, state), do: {:stop, :normal, state}

  @impl true
  def terminate(_reason, %{socket: nil}), do: :ok

  def terminate(_reason, %{socket: socket}) do
    :gen_tcp.shutdown(socket, :write)
    :gen_tcp.close(socket)
  end

  defp arm(%{armed: false, unacked: unacked, socket: socket} = state)
       when unacked < @window and socket != nil do
    # A socket already gone says so only here.
    with {:error, _} <- :inet.setopts(socket, active: :once),
         do: send(self(), {:tcp_closed, socket})

    %{state | armed: true}
  end

  defp arm(state), do: state

  # `localhost` on this machine: IPv4 first, as most dev servers bind, then
  # IPv6. Tests running two MCs on one machine give the thread's MC a loopback
  # address of its own.
  defp dial(port) do
    Application.get_env(:hal_c2, :preview_forward_loopback, [
      {127, 0, 0, 1},
      {0, 0, 0, 0, 0, 0, 0, 1}
    ])
    |> Enum.reduce_while({:error, :econnrefused}, fn ip, _error ->
      family = if tuple_size(ip) == 8, do: [:inet6], else: []

      case :gen_tcp.connect(ip, port, family ++ @socket, @dial_timeout) do
        {:ok, socket} -> {:halt, {:ok, socket}}
        {:error, reason} -> {:cont, {:error, reason}}
      end
    end)
  end
end
