defmodule HalC2.MachineFiles do
  @moduledoc """
  The other machines of the cluster as folders on this one, so the user's own
  editor, file manager and terminal open a thread's files wherever its MC runs.

  The folder (`root/0`, under this MC's state directory) holds one folder per other
  member, named by its label, mirroring that machine's absolute paths:
  `<root>/devbox/home/me/shop/src/cart.ts`. A member's folder appears when it joins
  and goes when it is removed; one that is offline keeps its folder, and what is
  read through it fails with EHOSTDOWN until it is back.

  The kernel sees it through the machine-files helper (`HalC2.MachineFiles.Helper`),
  which mounts it with FUSE and translates to 9P2000.L on its stdin and stdout. This
  process is that connection's server (`HalC2.MachineFiles.Session`): each request
  that needs a file runs `HalC2.MachineFiles.Share` on the member's MC over the
  cluster link, in a process of its own with a timeout, so a member that stops
  answering fails that request and nothing else waits on it. The helper starts with
  the first member and is restarted when it exits, as the other helpers are.

  Disabled unless `config :hal_c2, machine_files: true` (the MC's config sets it;
  tests and their peers leave it off).
  """

  use GenServer

  require Logger

  alias HalC2.MachineFiles.{NineP, Session, Share}

  @state_version 1
  @stable_uptime 30_000
  @backoff_base 1_000
  @backoff_max 60_000
  # A member that has not answered by then is unavailable for that request.
  @timeout 10_000
  # The helper sends nothing bigger: its msize is a megabyte and a bit.
  @max_message 2 * 1024 * 1024

  @type reason :: :not_a_member | :unsupported | :no_fuse | :no_helper | :not_ready | :unavailable

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Where this MC keeps the other machines' folders."
  def root, do: Path.join(HalC2.Paths.state_dir(), "machines")

  @doc """
  Where `path` on the machine with `environment_id` is on this one: the path itself
  for this machine, the path under its folder for another member, or why there is
  none.
  """
  @spec local_path(String.t(), String.t(), GenServer.server()) ::
          {:ok, String.t()} | {:error, reason, label :: String.t() | nil}
  def local_path(environment_id, path, server \\ __MODULE__) do
    if environment_id == HalC2.Environment.id() do
      {:ok, path}
    else
      GenServer.call(server, {:local_path, environment_id, path})
    end
  catch
    :exit, _ -> {:error, :not_ready, label(environment_id)}
  end

  @doc "What the user is told for `reason`, about a file on the machine `label`."
  @spec message(reason, String.t() | nil) :: String.t()
  def message(:not_a_member, _label),
    do: "The file is on a machine that is not in this machine's cluster."

  def message(reason, nil), do: message(reason, "another machine")
  def message(:no_fuse, label), do: on(label, "To open it here, install FUSE 3 (fuse3).")

  def message(:unsupported, label),
    do: on(label, "Opening another machine's files on #{platform()} is not supported yet.")

  def message(:no_helper, label),
    do: on(label, "This install is missing its machine-files helper; reinstall HAL-C2.")

  def message(:not_ready, label),
    do: on(label, "Its folder on this machine is not ready yet; try again in a moment.")

  def message(:unavailable, label), do: on(label, "\"#{label}\" is unavailable.")

  defp on(label, rest), do: "The file is on \"#{label}\". " <> rest

  defp platform do
    case :os.type() do
      {:win32, _} -> "Windows"
      {:unix, :darwin} -> "macOS"
      {_, os} -> to_string(os)
    end
  end

  defp label(environment_id) do
    Enum.find_value(HalC2.Shell.environments(), fn {_mc, descriptor} ->
      if descriptor["environmentId"] == environment_id, do: descriptor["label"]
    end)
  catch
    _, _ -> nil
  end

  @doc "Waits until the folder is mounted and answering, or `timeout`."
  def await_ready(server \\ __MODULE__, timeout \\ 30_000),
    do: GenServer.call(server, :await_ready, timeout)

  @doc "Returns once the cluster changes this process was told about are applied."
  def sync(server \\ __MODULE__), do: GenServer.call(server, :sync)

  @doc """
  The folder name of each member: its label made safe for a path, with the start of
  its environment id after it when two members share one.
  """
  @spec folders([{node, map}]) :: %{String.t() => map}
  def folders(environments) do
    named =
      for {mc, %{"environmentId" => id} = descriptor} <- environments, is_binary(id) do
        label = descriptor["label"] || id
        {folder_name(label, id), %{node: mc, environment: id, label: label}}
      end

    shared =
      named
      |> Enum.frequencies_by(&elem(&1, 0))
      |> Enum.filter(fn {_name, n} -> n > 1 end)
      |> MapSet.new(&elem(&1, 0))

    Map.new(named, fn {name, member} ->
      if MapSet.member?(shared, name),
        do: {"#{name}-#{String.slice(member.environment, 0, 8)}", member},
        else: {name, member}
    end)
  end

  defp folder_name(label, id) do
    name = label |> String.replace(["/", <<0>>], "-") |> String.trim()
    if name in ["", ".", ".."], do: id, else: name
  end

  # --- the server ---------------------------------------------------------------------

  @impl true
  def init(opts) do
    if Keyword.get_lazy(opts, :enabled, fn -> Application.get_env(:hal_c2, :machine_files) end) do
      Process.flag(:trap_exit, true)
      environments = Keyword.get(opts, :environments, &cluster/0)
      if Keyword.get(opts, :subscribe, true), do: HalC2.Shell.subscribe(self())

      state = %{
        v: @state_version,
        root: Keyword.get_lazy(opts, :root, &root/0),
        helper: Keyword.get(opts, :helper, HalC2.MachineFiles.Helper),
        timeout:
          Keyword.get_lazy(opts, :timeout, fn ->
            Application.get_env(:hal_c2, :machine_files_timeout, @timeout)
          end),
        ttl_ms: Keyword.get(opts, :ttl_ms, 1_000),
        environments: environments,
        members: %{},
        status: :idle,
        port: nil,
        os_pid: nil,
        started_at: nil,
        delay: 0,
        buffer: "",
        session: Session.new(),
        pending: %{},
        unavailable: MapSet.new(),
        waiting: []
      }

      {:ok, state, {:continue, :members}}
    else
      :ignore
    end
  end

  # The other MCs of the cluster this machine knows of, online or not.
  defp cluster, do: for({mc, d} <- HalC2.Shell.environments(), mc != node(), do: {mc, d})

  @impl true
  def handle_continue(:members, state), do: {:noreply, members(state)}

  @impl true
  def handle_call({:local_path, environment_id, path}, _from, state) do
    {:reply, resolve(state, environment_id, path), state}
  end

  def handle_call(:await_ready, from, state) do
    case state.status do
      :ready -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:noreply, %{state | waiting: [from | state.waiting]}}
    end
  end

  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info({:hal_c2_shell, {:rows, _, _}}, state), do: {:noreply, state}
  def handle_info({:hal_c2_shell, _change}, state), do: {:noreply, members(state)}

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    buffer = state.buffer <> data

    if NineP.valid_size?(buffer, @max_message) do
      {frames, rest} = NineP.frames(buffer)
      {:noreply, Enum.reduce(frames, %{state | buffer: rest}, &request/2)}
    else
      Logger.warning("the machine-files helper sent a message that does not parse")
      state.helper.close(port)
      {:noreply, exited(state)}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("the machine-files helper (pid #{state.os_pid}) exited with #{status}")
    {:noreply, exited(state)}
  end

  def handle_info({:answer, ref, answer}, state) do
    case Map.pop(state.pending, ref) do
      {nil, _} ->
        {:noreply, state}

      {{tag, folder, finish}, pending} ->
        {:noreply, answer(%{state | pending: pending}, tag, folder, finish, answer)}
    end
  end

  def handle_info(:restart, state), do: {:noreply, start(%{state | status: :idle})}
  def handle_info({:EXIT, _port, _reason}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port} = state) when port != nil do
    state.helper.unmount(state.root)
    state.helper.close(port)
  end

  def terminate(_reason, _state), do: :ok

  # --- members ------------------------------------------------------------------------

  defp members(state) do
    members = folders(state.environments.())
    state = %{state | members: members}
    # One that could not start tries again when the cluster changes: FUSE may be in now.
    if members != %{} and (state.status == :idle or match?({:error, _}, state.status)),
      do: start(state),
      else: state
  end

  defp resolve(state, environment_id, path) do
    case Enum.find(state.members, fn {_folder, m} -> m.environment == environment_id end) do
      nil ->
        {:error, :not_a_member, nil}

      {folder, member} ->
        cond do
          match?({:error, _}, state.status) ->
            {:error, elem(state.status, 1), member.label}

          state.status != :ready ->
            {:error, :not_ready, member.label}

          not connected?(member.node) ->
            {:error, :unavailable, member.label}

          true ->
            {:ok, Path.join([state.root, folder | tl(Path.split(path))])}
        end
    end
  end

  defp connected?(mc), do: mc == node() or mc in Node.list()

  # --- the helper ---------------------------------------------------------------------

  defp start(state) do
    with :ok <- state.helper.available(),
         :ok <- state.helper.prepare(state.root),
         {:ok, port, os_pid} <- state.helper.open(state.root, ttl_ms: state.ttl_ms) do
      Logger.info("the machine-files helper started (pid #{os_pid}) at #{state.root}")

      %{
        state
        | status: :starting,
          port: port,
          os_pid: os_pid,
          started_at: System.monotonic_time(:millisecond),
          buffer: "",
          session: Session.new(),
          pending: %{}
      }
    else
      {:error, reason} when reason in [:unsupported, :no_fuse, :no_helper] ->
        Logger.info("other machines' folders are not shown here: #{reason}")
        settle(%{state | status: {:error, reason}})

      {:error, reason} ->
        Logger.warning("the machine-files helper did not start: #{inspect(reason)}")
        restart_later(state)
    end
  end

  # The first exit restarts at once; further exits inside the stable window back off.
  defp exited(state) do
    restart_later(%{state | port: nil, os_pid: nil, buffer: "", pending: %{}})
  end

  defp restart_later(state) do
    uptime =
      if state.started_at, do: System.monotonic_time(:millisecond) - state.started_at, else: 0

    {wait, delay} =
      cond do
        uptime >= @stable_uptime -> {0, 0}
        state.delay == 0 -> {0, @backoff_base}
        true -> {state.delay, min(state.delay * 2, @backoff_max)}
      end

    Process.send_after(self(), :restart, wait)
    %{state | status: :restarting, delay: delay, started_at: nil}
  end

  defp settle(state) do
    reply = if state.status == :ready, do: :ok, else: state.status
    for from <- state.waiting, do: GenServer.reply(from, reply)
    %{state | waiting: []}
  end

  # --- 9P -----------------------------------------------------------------------------

  defp request({type, tag, body}, state) do
    msg = NineP.decode(type, body)
    # A flushed request is answered no more: the helper may give its tag to another.
    state =
      case msg do
        {:flush, old} ->
          %{state | pending: Map.reject(state.pending, &(elem(elem(&1, 1), 0) == old))}

        _ ->
          state
      end

    case Session.handle(state.session, msg, Map.keys(state.members)) do
      {:reply, reply, session} ->
        state = reply(%{state | session: session}, tag, reply)

        if match?({:attach, _}, msg) and state.status == :starting,
          do: settle(%{state | status: :ready}),
          else: state

      {:call, folder, fun, args, finish, session} ->
        call(%{state | session: session}, tag, folder, fun, args, finish)
    end
  end

  defp call(state, tag, folder, fun, args, finish) do
    case state.members do
      %{^folder => %{node: mc}} ->
        if connected?(mc) do
          ref = make_ref()
          parent = self()
          timeout = state.timeout
          spawn(fn -> send(parent, {:answer, ref, remote(mc, fun, args, timeout)}) end)
          %{state | pending: Map.put(state.pending, ref, {tag, folder, finish})}
        else
          answer(state, tag, folder, finish, {:error, :ehostdown})
        end

      _gone ->
        answer(state, tag, folder, finish, {:error, :enoent})
    end
  end

  defp remote(mc, fun, args, timeout) do
    :erpc.call(mc, Share, fun, args, timeout)
  catch
    :error, {:erpc, _reason} ->
      {:error, :ehostdown}

    kind, reason ->
      Logger.warning("#{inspect(mc)} failed #{fun}: #{inspect({kind, reason})}")
      {:error, :eio}
  end

  defp answer(state, tag, folder, finish, answer) do
    state = available(state, folder, answer != {:error, :ehostdown})
    {reply, session} = finish.(state.session, answer)
    reply(%{state | session: session}, tag, reply)
  end

  # Said once each time a member stops or starts answering, not once per request.
  defp available(state, folder, true) do
    if MapSet.member?(state.unavailable, folder) do
      Logger.info("#{label_of(state, folder)} is available again")
      %{state | unavailable: MapSet.delete(state.unavailable, folder)}
    else
      state
    end
  end

  defp available(state, folder, false) do
    if MapSet.member?(state.unavailable, folder) do
      state
    else
      Logger.warning("#{label_of(state, folder)} is unavailable")
      %{state | unavailable: MapSet.put(state.unavailable, folder)}
    end
  end

  defp label_of(state, folder), do: get_in(state.members, [folder, :label]) || folder

  defp reply(%{port: nil} = state, _tag, _reply), do: state

  defp reply(state, tag, reply) do
    state.helper.send(state.port, NineP.encode(tag, reply))
    state
  end
end
