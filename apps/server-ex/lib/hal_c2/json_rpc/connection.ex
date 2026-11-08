defmodule HalC2.JsonRpc.Connection do
  @moduledoc """
  Owns one JSON-RPC subprocess (a Codex app-server or an ACP agent).

  Callers use `call/4`, `request/5` and `notify/3`. Incoming notifications and server-to-client
  requests go to the `:handler` pid as `{:json_rpc, conn, message}`; the handler
  answers requests with `respond/3`. If the subprocess exits, pending calls fail with
  `{:error, :closed}` and the connection stops (so does a call written once the
  subprocess has closed its stdin, and `stop/1` of a stopped one is a no-op); with `:program` (the subprocess's
  name, as its user knows it) they fail with the exit instead, in the words that
  program's own client used (`"Codex App Server process exited with code 1"`, its code as
  `"exitCode"`). With `:log` (a thread id), every
  line the subprocess sends also goes to `HalC2.ProviderLog`. With `:stderr_prefix`,
  stderr lines starting with it reach the handler as `{:invalid, line}`, like a
  non-JSON stdout line, and are not logged; the rest of stderr is discarded. With
  `:stderr_tail` and `:program`, an exit also carries the last lines of stderr, as
  `"stderr"` beside the message: why a program that died on start died; `:whole`
  keeps every line of its last 4,096 bytes. With `:eof_grace` (ms) and `:program`, a
  program whose output ends and that has not exited that long after is not waited
  on: calls fail at once with `"<program> input stream ended."` (upstream #21323),
  and the stop that follows ends it.

  With `:durable` (a thread id) the subprocess outlives the MC. After each batch of
  output the handler then gets `{:json_rpc, conn, {:checkpoint, checkpoint}}` to save
  with its state (`HalC2.Subprocess.Durable.save/3`), and `:adopt` starts a connection
  on a program an earlier MC saved so. A call that was out when that MC went has no
  caller any more: its reply reaches the handler as
  `{:json_rpc, conn, {:response_after_restart, method, reply}}`.

  The state is versioned so a hot upgrade can migrate it in `code_change/3`.
  """

  use GenServer

  alias HalC2.{JsonRpc, Subprocess}

  @state_version 1

  @type option ::
          {:cmd, [String.t()]}
          | {:handler, pid}
          | {:dialect, JsonRpc.dialect()}
          | {:cd, String.t()}
          | {:env, [{String.t(), String.t()}]}
          | {:log, String.t() | nil}
          | {:stderr_prefix, String.t() | nil}
          | {:stderr_tail, boolean | :whole}
          | {:eof_grace, non_neg_integer | nil}
          | {:program, String.t() | nil}
          | {:durable, String.t() | nil}
          | {:adopt, %{dir: String.t(), offset: non_neg_integer, channel: map}}

  @spec start_link([option]) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, hibernate_after: 15_000)

  @spec call(GenServer.server(), String.t(), term, timeout) :: {:ok, term} | {:error, term}
  # A tail call, so a caller waiting on a reply (for minutes, in a turn) runs no
  # `Connection` code meanwhile: a `try` here kept every caller on the old version
  # across an upgrade, and the next one killed them. A call that reaches a
  # connection already stopped exits (`:noproc`); `HalC2.Acp` treats that as closed.
  def call(conn, method, params, timeout \\ 30_000),
    do: GenServer.call(conn, {:call, method, params}, timeout)

  @doc """
  Sends a call without waiting for its reply, adding it to `reqids` under `label`.
  The reply reaches the caller as a message; take it out with
  `:gen_server.check_response/3`. A caller that is also the connection's `:handler`
  gets it after every notification the subprocess sent before it (both come from this
  process); any other caller has no such order.
  """
  @spec request(GenServer.server(), String.t(), term, term, :gen_server.request_id_collection()) ::
          :gen_server.request_id_collection()
  def request(conn, method, params, label, reqids),
    do: :gen_server.send_request(conn, {:call, method, params}, label, reqids)

  @doc """
  Sends a call whose reply reaches the `:handler` as `{:json_rpc, conn, {:reply, tag, reply}}`,
  in the one stream of messages its notifications come in: after every notification the
  subprocess sent before the reply, and before any it sent after. A connection that
  closes first replies as `call/4` would.
  """
  @spec ask(GenServer.server(), String.t(), term, term) :: :ok
  def ask(conn, method, params, tag), do: GenServer.cast(conn, {:ask, method, params, tag})

  @spec notify(GenServer.server(), String.t(), term) :: :ok
  def notify(conn, method, params), do: GenServer.cast(conn, {:notify, method, params})

  @doc """
  Writes a notification and says whether it reached the subprocess's stdin: `notify/3`
  for a message the caller must not lose (an answer it would otherwise drop).
  """
  @spec deliver(GenServer.server(), String.t(), term) :: :ok | {:error, term}
  def deliver(conn, method, params) do
    GenServer.call(conn, {:deliver, method, params})
  catch
    :exit, _ -> {:error, :closed}
  end

  @spec respond(GenServer.server(), JsonRpc.id(), {:ok, term} | {:error, map}) :: :ok
  def respond(conn, id, reply), do: GenServer.cast(conn, {:respond, id, reply})

  @spec os_pid(GenServer.server()) :: pos_integer
  def os_pid(conn), do: GenServer.call(conn, :os_pid)

  # A connection whose program already exited has stopped on its own.
  @spec stop(GenServer.server()) :: :ok
  def stop(conn) do
    GenServer.stop(conn)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    adopt = opts[:adopt]

    case subprocess(opts) do
      {:ok, sub} ->
        {:ok,
         %{
           v: @state_version,
           sub: sub,
           handler: Keyword.fetch!(opts, :handler),
           dialect: Keyword.get(opts, :dialect, :bare),
           next_id: if(adopt, do: adopt.channel.next_id, else: 1),
           pending: %{},
           methods: %{},
           offset: if(adopt, do: adopt.offset, else: 0),
           earlier: if(adopt, do: adopt.channel.methods, else: %{}),
           log: Keyword.get(opts, :log),
           program: Keyword.get(opts, :program),
           stderr_tail: Keyword.get(opts, :stderr_tail, false),
           eof_grace: Keyword.get(opts, :eof_grace),
           input_ended: false,
           exit_status: nil,
           stderr: ""
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp subprocess(opts) do
    case opts[:adopt] do
      %{dir: dir, offset: offset} ->
        Subprocess.adopt(dir, offset, opts[:stderr_prefix])

      nil ->
        cmd = Keyword.fetch!(opts, :cmd)

        Subprocess.start(
          cmd,
          Keyword.take(opts, [:cd, :env, :stderr_prefix, :stderr_tail, :durable])
        )
    end
  end

  @impl true
  def handle_call({:call, method, params}, from, state) do
    id = state.next_id

    case Subprocess.write_line(state.sub, JsonRpc.request(state.dialect, id, method, params)) do
      :ok ->
        {:noreply,
         checkpoint(%{
           state
           | next_id: id + 1,
             pending: Map.put(state.pending, id, from),
             methods: Map.put(state.methods, id, method)
         })}

      # The agent closed its stdin, dying or about to, before this call reached it:
      # the call has met a closed connection, as one sent after the close does.
      {:error, reason} when reason in [:epipe, :closed] ->
        {:reply, {:error, :closed}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:deliver, method, params}, _from, state) do
    reply = Subprocess.write_line(state.sub, JsonRpc.notification(state.dialect, method, params))
    {:reply, reply, checkpoint(state)}
  end

  def handle_call(:os_pid, _from, state), do: {:reply, Subprocess.os_pid(state.sub), state}

  @impl true
  def handle_cast({:notify, method, params}, state) do
    Subprocess.write_line(state.sub, JsonRpc.notification(state.dialect, method, params))
    {:noreply, checkpoint(state)}
  end

  def handle_cast({:ask, method, params, tag}, state) do
    case handle_call({:call, method, params}, {:handler, tag}, state) do
      {:noreply, state} ->
        {:noreply, state}

      {:reply, reply, state} ->
        send(state.handler, {:json_rpc, self(), {:reply, tag, reply}})
        {:noreply, state}
    end
  end

  def handle_cast({:respond, id, reply}, state) do
    Subprocess.write_line(state.sub, JsonRpc.response(state.dialect, id, reply))
    {:noreply, checkpoint(state)}
  end

  @impl true
  def handle_info({:subprocess_lines, _reader, lines}, state) do
    state = Enum.reduce(lines, state, &handle_line/2)
    Subprocess.ack(state.sub)
    {:noreply, state}
  end

  def handle_info({:subprocess_offset, _reader, offset}, state),
    do: {:noreply, checkpoint(%{state | offset: offset}, false)}

  def handle_info({:subprocess_stderr, _reader, lines}, state) do
    for line <- lines, do: send(state.handler, {:json_rpc, self(), {:invalid, line}})
    {:noreply, state}
  end

  def handle_info({:subprocess_eof, _reader}, state) do
    # The exit status is read here, while the subprocess can still be asked, so a
    # call left open fails with the exit rather than a bare close.
    state =
      if state.program, do: ended(state, grace(state)), else: state

    {:stop, :normal, state}
  catch
    :exit, _ -> {:stop, :normal, state}
  end

  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  # The program's exit can arrive before its output ends; kept for the eof above.
  def handle_info(other, state) do
    case Subprocess.exit_status(state.sub, other) do
      {:ok, status} -> {:noreply, %{state | exit_status: status}}
      :error -> {:noreply, state}
    end
  end

  # Whether a program whose output ended is still running `:eof_grace` later.
  defp grace(%{eof_grace: grace, exit_status: nil} = state) when is_integer(grace) do
    case Subprocess.exited(state.sub, grace) do
      {:ok, status} -> status
      :running -> :running
      :unknown -> nil
    end
  end

  defp grace(state), do: state.exit_status

  defp ended(state, :running), do: %{state | input_ended: true}

  defp ended(state, status) do
    # Before the stop, which removes a durable program's dir and its stderr with it.
    stderr =
      case state.stderr_tail do
        :whole -> Subprocess.stderr_tail(state.sub, 1_000, :all)
        true -> Subprocess.stderr_tail(state.sub)
        _ -> ""
      end

    status =
      case status || Subprocess.stop(state.sub, 1_000) do
        {:ok, status} -> status
        status when is_integer(status) -> status
        _ -> nil
      end

    %{state | exit_status: status, stderr: stderr}
  end

  # The calls still waiting fail with `:closed`, or with an error the program's end
  # names, marked `"ended" => true`: an error reply of the program's own never is.
  @impl true
  def terminate(_reason, state) do
    error =
      case {state.program, state.exit_status} do
        {program, _} when is_binary(program) and state.input_ended ->
          %{"message" => "#{program} input stream ended.", "ended" => true}

        {program, status} when is_binary(program) and is_integer(status) ->
          %{
            "message" => "#{program} process exited with code #{status}",
            "exitCode" => status,
            "ended" => true
          }
          |> then(&if state.stderr != "", do: Map.put(&1, "stderr", state.stderr), else: &1)

        _ ->
          :closed
      end

    for {_id, from} <- state.pending, do: reply(state, from, {:error, error})
    # The subprocess may already be gone (its exit is why this connection stops).
    try do
      Subprocess.stop(state.sub)
    catch
      :exit, _ -> :ok
    end
  end

  @impl true
  def code_change(_old_vsn, state, _extra), do: {:ok, migrate(state)}

  # Every older state shape migrates forward here; new fields get defaults.
  defp migrate(state),
    do:
      state
      |> Map.put_new(:program, nil)
      |> Map.put_new(:exit_status, nil)
      |> Map.put_new(:stderr_tail, false)
      |> Map.put_new(:stderr, "")
      |> Map.put_new(:eof_grace, nil)
      |> Map.put_new(:input_ended, false)
      |> Map.put_new(:methods, %{})
      |> Map.put_new(:earlier, %{})
      |> Map.put_new(:offset, 0)
      |> Map.put(:v, @state_version)

  # After what the program wrote and after what it was sent: one that goes quiet on a
  # request (a long tool run) would otherwise leave a checkpoint that never heard of it.
  defp checkpoint(state, wrote \\ true)

  defp checkpoint(%{sub: %{durable: %{dir: dir}}} = state, wrote) do
    checkpoint = %{
      dir: dir,
      wrote: wrote,
      offset: state.offset,
      channel: %{next_id: state.next_id, methods: Map.merge(state.earlier, state.methods)}
    }

    send(state.handler, {:json_rpc, self(), {:checkpoint, checkpoint}})
    state
  end

  defp checkpoint(state, _wrote), do: state

  defp handle_line(line, state) do
    HalC2.ProviderLog.native(Map.get(state, :log), line)

    case JsonRpc.decode(line, state.dialect) do
      {:response, id, reply} ->
        {from, pending} = Map.pop(state.pending, id)
        if from, do: reply(state, from, reply)
        {method, earlier} = Map.pop(state.earlier, id)

        if method,
          do: send(state.handler, {:json_rpc, self(), {:response_after_restart, method, reply}})

        %{state | pending: pending, earlier: earlier, methods: Map.delete(state.methods, id)}

      message ->
        send(state.handler, {:json_rpc, self(), message})
        state
    end
  end

  defp reply(state, {:handler, tag}, reply),
    do: send(state.handler, {:json_rpc, self(), {:reply, tag, reply}})

  defp reply(_state, from, reply), do: GenServer.reply(from, reply)
end
