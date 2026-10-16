defmodule HalC2.PreviewForward.Listener do
  @moduledoc """
  One forward on the client's MC: loopback sockets at the dev server's port
  (another free one when that is taken), a `Pipe` per accepted connection, and
  the thread's MC's `Grant` it holds. It stops, closing every connection, when
  the grant does or the thread's MC stops answering.
  """

  use GenServer, restart: :temporary

  alias HalC2.PreviewForward.Pipe

  @grant_timeout 5_000
  # Enough for a page's parallel requests and its sockets; beyond it a
  # forward that reaches itself (two MCs on one machine) stops growing.
  @max_connections 256
  @socket [:binary, active: false, reuseaddr: true, packet: :raw]

  def start_link({key, name}), do: GenServer.start_link(__MODULE__, key, name: name)

  @doc "The port this forward listens on."
  def port(pid) do
    GenServer.call(pid, :port)
  catch
    :exit, _ -> {:error, :closed}
  end

  @impl true
  def init({mc, thread, port}) do
    Process.flag(:trap_exit, true)

    with {:ok, grant} <- grant(mc, thread, port),
         {:ok, listening, bound} <- listen(port) do
      for socket <- listening, do: acceptor(socket)

      {:ok,
       %{grant: grant, ref: Process.monitor(grant), port: bound, sockets: listening, pipes: %{}}}
    else
      {:error, reason} -> {:stop, {:shutdown, reason}}
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, {:ok, state.port}, state}

  @impl true
  def handle_info({:accepted, socket}, state) when map_size(state.pipes) >= @max_connections do
    :gen_tcp.close(socket)
    {:noreply, state}
  end

  def handle_info({:accepted, socket}, state) do
    {:ok, pipe} = Pipe.start_link({:accept, state.grant})

    case :gen_tcp.controlling_process(socket, pipe) do
      :ok ->
        send(pipe, {:socket, socket})

      # Closed already: so is the pipe, which has nothing to carry.
      {:error, _} ->
        :gen_tcp.close(socket)
        GenServer.stop(pipe)
    end

    {:noreply, %{state | pipes: Map.put(state.pipes, pipe, true)}}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{ref: ref} = state),
    do: {:stop, {:shutdown, {:grant, reason}}, state}

  def handle_info({:EXIT, pid, _}, state) when is_map_key(state.pipes, pid),
    do: {:noreply, %{state | pipes: Map.delete(state.pipes, pid)}}

  # An acceptor only ends with its socket, which this process owns.
  def handle_info({:EXIT, _acceptor, reason}, state),
    do: {:stop, {:shutdown, {:acceptor, reason}}, state}

  defp grant(mc, thread, port) do
    :erpc.call(mc, HalC2.PreviewForward, :grant, [thread, port, self()], @grant_timeout)
  catch
    # Down, partitioned, or an MC without forwards.
    _, _ -> {:error, :unavailable}
  end

  # 127.0.0.1 and, where it can, ::1, both at `port` so `localhost` reaches
  # this forward whichever address the browser tries first; on any other port
  # when either is taken.
  defp listen(port) do
    case listen_both(port) do
      {:error, reason} when reason in [:eaddrinuse, :eacces] and port != 0 -> listen_both(0)
      other -> other
    end
  end

  defp listen_both(port) do
    with {:ok, v4} <- :gen_tcp.listen(port, [{:ip, {127, 0, 0, 1}} | @socket]),
         {:ok, bound} <- :inet.port(v4) do
      case :gen_tcp.listen(bound, [
             :inet6,
             {:ip, {0, 0, 0, 0, 0, 0, 0, 1}},
             {:ipv6_v6only, true} | @socket
           ]) do
        {:ok, v6} ->
          {:ok, [v4, v6], bound}

        # Another process holds ::1 at the port: a browser trying ::1 would
        # reach it instead.
        {:error, :eaddrinuse} when port != 0 ->
          :gen_tcp.close(v4)
          {:error, :eaddrinuse}

        # No IPv6 loopback here.
        {:error, _} ->
          {:ok, [v4], bound}
      end
    end
  end

  defp acceptor(socket) do
    listener = self()

    spawn_link(fn -> accept(socket, listener) end)
  end

  defp accept(socket, listener) do
    case :gen_tcp.accept(socket) do
      {:ok, connection} ->
        :ok = :gen_tcp.controlling_process(connection, listener)
        send(listener, {:accepted, connection})
        accept(socket, listener)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit({:shutdown, reason})
    end
  end
end
