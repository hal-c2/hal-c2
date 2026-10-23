defmodule HalC2.JsonRpc.Connection do
  @moduledoc """
  Owns one JSON-RPC subprocess (a Codex app-server or an ACP agent).

  Callers use `call/4`, `request/5` and `notify/3`. Incoming notifications and server-to-client
  requests go to the `:handler` pid as `{:json_rpc, conn, message}`; the handler
  answers requests with `respond/3`. If the subprocess exits, pending calls fail with
  `{:error, :closed}` and the connection stops. With `:log` (a thread id), every
  line the subprocess sends also goes to `HalC2.ProviderLog`. With `:stderr_prefix`,
  stderr lines starting with it reach the handler as `{:invalid, line}`, like a
  non-JSON stdout line, and are not logged; the rest of stderr is discarded.

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

  @spec start_link([option]) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, hibernate_after: 15_000)

  @spec call(GenServer.server(), String.t(), term, timeout) :: {:ok, term} | {:error, term}
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

  @spec notify(GenServer.server(), String.t(), term) :: :ok
  def notify(conn, method, params), do: GenServer.cast(conn, {:notify, method, params})

  @spec respond(GenServer.server(), JsonRpc.id(), {:ok, term} | {:error, map}) :: :ok
  def respond(conn, id, reply), do: GenServer.cast(conn, {:respond, id, reply})

  @spec os_pid(GenServer.server()) :: pos_integer
  def os_pid(conn), do: GenServer.call(conn, :os_pid)

  @spec stop(GenServer.server()) :: :ok
  def stop(conn), do: GenServer.stop(conn)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    cmd = Keyword.fetch!(opts, :cmd)
    spawn_opts = Keyword.take(opts, [:cd, :env, :stderr_prefix])

    case Subprocess.start(cmd, spawn_opts) do
      {:ok, sub} ->
        {:ok,
         %{
           v: @state_version,
           sub: sub,
           handler: Keyword.fetch!(opts, :handler),
           dialect: Keyword.get(opts, :dialect, :bare),
           next_id: 1,
           pending: %{},
           log: Keyword.get(opts, :log)
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:call, method, params}, from, state) do
    id = state.next_id

    case Subprocess.write_line(state.sub, JsonRpc.request(state.dialect, id, method, params)) do
      :ok ->
        {:noreply, %{state | next_id: id + 1, pending: Map.put(state.pending, id, from)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:os_pid, _from, state), do: {:reply, Subprocess.os_pid(state.sub), state}

  @impl true
  def handle_cast({:notify, method, params}, state) do
    Subprocess.write_line(state.sub, JsonRpc.notification(state.dialect, method, params))
    {:noreply, state}
  end

  def handle_cast({:respond, id, reply}, state) do
    Subprocess.write_line(state.sub, JsonRpc.response(state.dialect, id, reply))
    {:noreply, state}
  end

  @impl true
  def handle_info({:subprocess_lines, _reader, lines}, state) do
    state = Enum.reduce(lines, state, &handle_line/2)
    Subprocess.ack(state.sub)
    {:noreply, state}
  end

  def handle_info({:subprocess_stderr, _reader, lines}, state) do
    for line <- lines, do: send(state.handler, {:json_rpc, self(), {:invalid, line}})
    {:noreply, state}
  end

  def handle_info({:subprocess_eof, _reader}, state), do: {:stop, :normal, state}
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    for {_id, from} <- state.pending, do: GenServer.reply(from, {:error, :closed})
    Subprocess.stop(state.sub)
  end

  @impl true
  def code_change(_old_vsn, state, _extra), do: {:ok, migrate(state)}

  # Every older state shape migrates forward here; new fields get defaults.
  defp migrate(%{v: @state_version} = state), do: state
  defp migrate(state), do: Map.put(state, :v, @state_version)

  defp handle_line(line, state) do
    HalC2.ProviderLog.native(Map.get(state, :log), line)

    case JsonRpc.decode(line, state.dialect) do
      {:response, id, reply} ->
        {from, pending} = Map.pop(state.pending, id)
        if from, do: GenServer.reply(from, reply)
        %{state | pending: pending}

      message ->
        send(state.handler, {:json_rpc, self(), message})
        state
    end
  end
end
