defmodule HalC2.JsonRpc.Connection do
  @moduledoc """
  Owns one JSON-RPC subprocess (a Codex app-server or an ACP agent).

  Callers use `call/4`, `request/5` and `notify/3`. Incoming notifications and server-to-client
  requests go to the `:handler` pid as `{:json_rpc, conn, message}`; the handler
  answers requests with `respond/3`. If the subprocess exits, pending calls fail with
  `{:error, :closed}` and the connection stops (a call written once the subprocess has
  closed its stdin fails so too, and `stop/1` of a stopped one is a no-op); with `:program` (the subprocess's
  name, as its user knows it) they fail with the exit instead, in the words that
  program's own client used (`"Codex App Server process exited with code 1"`). With `:log` (a thread id), every
  line the subprocess sends also goes to `HalC2.ProviderLog`. With `:stderr_prefix`,
  stderr lines starting with it reach the handler as `{:invalid, line}`, like a
  non-JSON stdout line, and are not logged; the rest of stderr is discarded. With
  `:stderr_tail` and `:program`, an exit also carries the last lines of stderr, as
  `"stderr"` beside the message: why a program that died on start died.

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
  # How long a program's exit has to arrive once its output ended or a write to it
  # failed, before its calls fail without it.
  @grace_ms 250

  @type option ::
          {:cmd, [String.t()]}
          | {:handler, pid}
          | {:dialect, JsonRpc.dialect()}
          | {:cd, String.t()}
          | {:env, [{String.t(), String.t()}]}
          | {:log, String.t() | nil}
          | {:stderr_prefix, String.t() | nil}
          | {:stderr_tail, boolean}
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

  @spec respond(GenServer.server(), JsonRpc.id(), {:ok, term} | {:error, map}) :: :ok
  def respond(conn, id, reply), do: GenServer.cast(conn, {:respond, id, reply})

  @spec os_pid(GenServer.server()) :: pos_integer
  def os_pid(conn), do: GenServer.call(conn, :os_pid)

  @spec stop(GenServer.server()) :: :ok
  def stop(conn) do
    GenServer.stop(conn)
  catch
    :exit, {reason, _} when reason in [:noproc, :normal] -> :ok
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
           exit_status: nil,
           stderr: "",
           broken: nil
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
  # A connection that has stopped writing answers at once, in the words it failed in.
  def handle_call({:call, _method, _params}, _from, %{broken: error} = state)
      when error != nil,
      do: {:reply, {:error, error}, state}

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
      {:error, reason} when state.program == nil and reason in [:epipe, :closed] ->
        {:reply, {:error, :closed}, state}

      {:error, reason} when state.program == nil ->
        {:reply, {:error, reason}, state}

      {:error, reason} ->
        state = write_failed(reason, state)
        {:noreply, %{state | pending: Map.put(state.pending, {:unwritten, id}, from)}}
    end
  end

  def handle_call(:os_pid, _from, state), do: {:reply, Subprocess.os_pid(state.sub), state}

  @impl true
  # A call whose reply goes to the handler as a message. Ahead of the broken guard: on
  # a broken connection it is answered with the write error, as a call is.
  def handle_cast({:ask, method, params, tag}, state) do
    case handle_call({:call, method, params}, {:handler, tag}, state) do
      {:noreply, state} ->
        {:noreply, state}

      {:reply, reply, state} ->
        send(state.handler, {:json_rpc, self(), {:reply, tag, reply}})
        {:noreply, state}
    end
  end

  def handle_cast(_message, %{broken: error} = state) when error != nil, do: {:noreply, state}

  def handle_cast({:notify, method, params}, state),
    do: cast_line(JsonRpc.notification(state.dialect, method, params), state)

  def handle_cast({:respond, id, reply}, state),
    do: cast_line(JsonRpc.response(state.dialect, id, reply), state)

  defp cast_line(line, state) do
    case Subprocess.write_line(state.sub, line) do
      {:error, reason} when state.program != nil -> {:noreply, write_failed(reason, state)}
      _ -> {:noreply, checkpoint(state)}
    end
  end

  # A program that stopped reading its input while its output stays open would leave
  # every call waiting on an answer to a request it never read (upstream #27924). A
  # `:program` connection whose write fails takes no more: what is sent from then on
  # fails at once with the write error. A program that is dying closes its stdin
  # too, so its exit gets `@grace_ms` to arrive first and be the error, with what it
  # printed (`{:subprocess_eof, _}`); otherwise the open calls fail with the write
  # error and the owner gets it as the exit reason, `{:shutdown, {:write_failed, error}}`.
  defp write_failed(reason, state) do
    error = %{"message" => "#{state.program} stopped taking input (write failed: #{reason})"}
    Process.send_after(self(), :write_failed, @grace_ms)
    %{state | broken: error}
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
      if state.program do
        durable? = state.sub.durable != nil
        # A durable program's before the stop, which removes its dir and its stderr with
        # it; an owned one's once it has exited, as a live one's stderr has no end yet.
        tail = fn -> if state.stderr_tail, do: Subprocess.stderr_tail(state.sub), else: "" end
        early = if durable?, do: tail.(), else: ""

        status =
          case state.exit_status || exit_within_grace(state.sub) do
            {:ok, status} -> status
            status when is_integer(status) -> status
            _ -> nil
          end

        stderr = if durable? or status == nil, do: early, else: tail.()

        # A program that closed its output and runs on can answer nothing more
        # (upstream #24600): its calls fail now, not when it is made to stop.
        broken =
          state.broken ||
            if status == nil and not durable?,
              do: %{"message" => "Input from #{state.program} ended while it was still running"}

        %{state | exit_status: status, stderr: stderr, broken: broken}
      else
        state
      end

    {:stop, :normal, state}
  catch
    :exit, _ -> {:stop, :normal, state}
  end

  def handle_info(:write_failed, %{broken: error} = state),
    do: {:stop, {:shutdown, {:write_failed, error}}, state}

  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  # The program's exit can arrive before its output ends; kept for the eof above.
  def handle_info(other, state) do
    case Subprocess.exit_status(state.sub, other) do
      {:ok, status} -> {:noreply, %{state | exit_status: status}}
      :error -> {:noreply, state}
    end
  end

  # An owned program's exit, if it comes within `@grace_ms` of its output ending; a
  # durable one's is read from its dir.
  defp exit_within_grace(%Subprocess{durable: nil, proc: %{exit_ref: ref}}) do
    receive do
      {^ref, {:ok, status}} -> status
    after
      @grace_ms -> nil
    end
  end

  defp exit_within_grace(sub), do: Subprocess.stop(sub, 1_000)

  @impl true
  def terminate(_reason, state) do
    error =
      case {state.program, state.exit_status} do
        {program, status} when is_binary(program) and is_integer(status) ->
          %{"message" => "#{program} process exited with code #{status}"}
          |> then(&if state.stderr != "", do: Map.put(&1, "stderr", state.stderr), else: &1)

        _ when state.broken != nil ->
          state.broken

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
      |> Map.put_new(:methods, %{})
      |> Map.put_new(:earlier, %{})
      |> Map.put_new(:offset, 0)
      |> Map.put_new(:broken, nil)
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
