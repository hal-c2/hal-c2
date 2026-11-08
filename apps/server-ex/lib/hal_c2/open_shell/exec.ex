defmodule HalC2.OpenShell.Exec do
  @moduledoc """
  One command running in a sandbox, on OpenShell's `ExecSandboxInteractive`
  stream: binary-safe stdin and output with no TTY and no size limit, half-close,
  cancellation and the exit status. `HalC2.OpenShell.Client.exec/4` starts it.

  Its owner (the caller of `exec/4`) receives, in order:

      {:openshell_exec, exec, {:stdout, binary}}
      {:openshell_exec, exec, {:stderr, binary}}
      {:openshell_exec, exec, {:exit, code}}        # last: the command exited
      {:openshell_exec, exec, {:error, reason}}     # last: the stream failed or was cancelled

  Exactly one `:exit` or `:error` ends the stream, and the process stops after it.
  It also stops, cancelling the stream, when its owner exits. The connection it was
  started on is its own, and it closes that when it stops.

  `send_stdin/2` returns once the gateway has taken the bytes, which is
  backpressure: the gateway takes no more than the command reads. It waits as long
  as that takes, so a command that does not read its stdin holds the writer until
  it is cancelled. `close_stdin/1` half-closes after every byte sent before it; the
  command sees end of input and its output keeps coming until it exits.
  """

  use GenServer, restart: :temporary

  alias HalC2.OpenShell.Proto.Openshell.V1, as: Pb
  alias Pb.OpenShell.Stub

  # Bytes per stdin message: well under the gateway's message limit, and small
  # enough that one write does not hold the connection for long.
  @chunk 65_536

  @doc false
  def start(channel, %Pb.ExecSandboxRequest{} = start, owner) do
    GenServer.start(__MODULE__, {channel, start, owner})
  end

  @doc "Writes `data` (iodata) to the command's stdin. `:ok` once the gateway took it."
  def send_stdin(exec, data) do
    with {:ok, writer} <- writer(exec) do
      data
      |> IO.iodata_to_binary()
      |> chunks()
      |> Enum.reduce_while(:ok, fn chunk, :ok ->
        case write(writer, %Pb.ExecSandboxInput{payload: {:stdin, chunk}}) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  @doc "Half-closes stdin, after everything `send_stdin/2` already returned for."
  def close_stdin(exec) do
    with {:ok, {conn, ref}} <- writer(exec, :close) do
      call_connection(conn, {:stream_body, ref, :eof})
    end
  end

  @doc "Tells a command started with `tty: true` its window size."
  def resize(exec, cols, rows) do
    with {:ok, writer} <- writer(exec) do
      write(writer, %Pb.ExecSandboxInput{
        payload: {:resize, %Pb.ExecSandboxWindowResize{cols: cols, rows: rows}}
      })
    end
  end

  @doc """
  Cancels the stream; the gateway stops the command. The owner gets
  `{:error, :cancelled}` unless the command already ended. Always `:ok`.
  """
  def cancel(exec) do
    GenServer.call(exec, :cancel)
  catch
    :exit, _ -> :ok
  end

  defp writer(exec, mode \\ :write) do
    GenServer.call(exec, {:writer, mode})
  catch
    :exit, _ -> {:error, :closed}
  end

  defp chunks(<<chunk::binary-size(@chunk), rest::binary>>), do: [chunk | chunks(rest)]
  defp chunks(<<>>), do: []
  defp chunks(rest), do: [rest]

  # A gRPC message on the open request: the 5-byte length prefix, then the message.
  # One binary, not iodata: the connection process splits only a binary to fit the
  # flow-control window, and sends iodata whole, past the window, as an error.
  defp write({conn, ref}, message) do
    body = Pb.ExecSandboxInput.encode(message) |> IO.iodata_to_binary()
    call_connection(conn, {:stream_body, ref, <<0, byte_size(body)::32, body::binary>>})
  end

  # The Mint adapter's connection process queues the body until HTTP/2 flow control
  # lets it out, and replies then. `GRPC.Stub.send_request/3` waits for that reply
  # with GenServer's 5 s default, which would turn a command that is slow to read
  # into a crash and let a later half-close overtake bytes still queued, so this
  # waits as long as flow control does. (The message is that adapter's own, in
  # grpc 1.0.6 as `mix.lock` pins it.)
  defp call_connection(conn, message) do
    case GenServer.call(conn, message, :infinity) do
      :ok -> :ok
      {:error, reason} -> {:error, {:stdin, reason}}
    end
  catch
    :exit, _ -> {:error, :closed}
  end

  # --- server ------------------------------------------------------------------------

  @impl true
  def init({channel, start, owner}) do
    Process.flag(:trap_exit, true)
    monitor = Process.monitor(owner)
    stream = Stub.exec_sandbox_interactive(channel, timeout: :infinity)

    stream =
      GRPC.Stub.send_request(stream, %Pb.ExecSandboxInput{payload: {:start, start}},
        end_stream: false
      )

    me = self()
    reader = spawn_link(fn -> read(stream, me) end)

    {:ok,
     %{
       channel: channel,
       stream: stream,
       owner: owner,
       monitor: monitor,
       reader: reader,
       done: false,
       stdin: :open
     }}
  end

  # Passes the gateway's output to the server as it comes, then how the stream
  # ended. Everything the owner gets comes from the server, which passes it on only
  # until the stream is settled: a cancel's ending is the last message even when the
  # reader, killed asynchronously, still sends after it.
  defp read(stream, exec) do
    ending =
      case GRPC.Stub.recv(stream, timeout: :infinity) do
        {:ok, events} ->
          Enum.reduce_while(events, {:error, :closed}, &forward(&1, &2, exec))

        {:error, error} ->
          {:error, reason(error)}
      end

    send(exec, {:ended, ending})
  end

  defp forward({:ok, %Pb.ExecSandboxEvent{payload: {:stdout, %{data: data}}}}, acc, exec) do
    send(exec, {:output, {:stdout, data}})
    {:cont, acc}
  end

  defp forward({:ok, %Pb.ExecSandboxEvent{payload: {:stderr, %{data: data}}}}, acc, exec) do
    send(exec, {:output, {:stderr, data}})
    {:cont, acc}
  end

  defp forward({:ok, %Pb.ExecSandboxEvent{payload: {:exit, %{exit_code: code}}}}, _acc, _),
    do: {:halt, {:exit, code}}

  defp forward({:ok, _other}, acc, _exec), do: {:cont, acc}
  defp forward({:error, error}, _acc, _exec), do: {:halt, {:error, reason(error)}}
  defp forward(_trailers_or_headers, acc, _exec), do: {:cont, acc}

  defp reason(%GRPC.RPCError{status: 1}), do: :cancelled
  defp reason(%GRPC.RPCError{} = error), do: HalC2.OpenShell.Client.rpc_error(error)
  defp reason(other), do: other

  @impl true
  def handle_call({:writer, _mode}, _from, %{done: true} = state),
    do: {:reply, {:error, :closed}, state}

  def handle_call({:writer, _mode}, _from, %{stdin: :closed} = state),
    do: {:reply, {:error, :stdin_closed}, state}

  def handle_call({:writer, mode}, _from, state) do
    %{
      channel: %{adapter_payload: %{conn_pid: conn}},
      payload: %{response: {:ok, %{request_ref: ref}}}
    } =
      state.stream

    state = if mode == :close, do: %{state | stdin: :closed}, else: state
    {:reply, {:ok, {conn, ref}}, state}
  end

  def handle_call(:cancel, _from, state), do: {:stop, :normal, :ok, stop_stream(state)}

  @impl true
  def handle_info({:output, _output}, %{done: true} = state), do: {:noreply, state}

  def handle_info({:output, output}, state) do
    send(state.owner, {:openshell_exec, self(), output})
    {:noreply, state}
  end

  def handle_info({:ended, _ending}, %{done: true} = state), do: {:stop, :normal, state}

  def handle_info({:ended, ending}, state) do
    send(state.owner, {:openshell_exec, self(), ending})
    {:stop, :normal, %{state | done: true}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{monitor: ref} = state),
    do: {:stop, :normal, stop_stream(state)}

  def handle_info({:EXIT, reader, :normal}, %{reader: reader} = state), do: {:noreply, state}

  def handle_info({:EXIT, reader, reason}, %{reader: reader} = state) do
    unless state.done,
      do: send(state.owner, {:openshell_exec, self(), {:error, {:reader, reason}}})

    {:stop, :normal, %{state | done: true}}
  end

  def handle_info({:EXIT, _other, _reason}, state), do: {:noreply, state}

  # The process buffering the response is linked to this one but outlives a
  # normal exit, so it is stopped here. Closing the connection is what stops the
  # command: the gateway drops the stream with it, and a write still queued for it
  # goes too. (A reset alone leaves that write queued, and grpc 1.0.6's connection
  # process crashes on it.)
  @impl true
  def terminate(_reason, state) do
    with %{payload: %{stream_response_pid: pid}} when is_pid(pid) <- state.stream,
         do: quietly(fn -> GenServer.stop(pid, :normal, 1_000) end)

    quietly(fn -> GRPC.Stub.disconnect(state.channel) end)
  end

  defp quietly(fun) do
    fun.()
    :ok
  catch
    :exit, _ -> :ok
  end

  # Settles the owner once, before `terminate/2` closes the connection. The reader
  # may still send before the kill reaches it; `done` drops what it sends.
  defp stop_stream(%{done: true} = state), do: state

  defp stop_stream(state) do
    Process.unlink(state.reader)
    Process.exit(state.reader, :kill)
    send(state.owner, {:openshell_exec, self(), {:error, :cancelled}})
    %{state | done: true}
  end
end
