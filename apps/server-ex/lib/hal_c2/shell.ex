defmodule HalC2.Shell do
  @moduledoc """
  The cluster-wide sidebar: every project and thread row on every MC.

  Rows are `{kind, row}` where `kind` is `"project"` or `"thread"` and `row` is the
  shape the client renders (`HalC2.Projection.row/3`). This MC's rows come from the
  store's `shell` table and from stream servers as threads change; peers push theirs.
  They live in a protected ETS table keyed by `{mc, stream_id}`, so any process can
  read the whole shell without copying it through this server. When a peer goes down
  its rows stay, marked offline, so a sleeping laptop's threads remain visible. Only a
  machine removed from the cluster is dropped (`forget/1`).

  Each MC's environment descriptor (`HalC2.Environment.descriptor/0`) travels with its
  rows, so clients can list and label every machine, online or not.

  Subscribers receive `{:hal_c2_shell, {:rows, mc, [{id, {kind, row}}]}}`,
  `{:hal_c2_shell, {:environment, mc, descriptor}}` and
  `{:hal_c2_shell, {:mc, mc, :up | :down | :removed}}`.
  """

  use GenServer

  require Logger

  @table __MODULE__
  @mcs HalC2.Shell.Mcs

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Every known row as `{{mc, stream_id}, {kind, row}}`."
  @spec rows() :: [{{node, String.t()}, {String.t(), map}}]
  def rows do
    # Without the shell (tools, some tests) there are no rows.
    if :ets.whereis(@table) == :undefined, do: [], else: :ets.tab2list(@table)
  end

  @doc "One row as `{kind, row}`, or `nil`."
  def row(mc, id) do
    case :ets.lookup(@table, {mc, id}) do
      [{_, row}] -> row
      [] -> nil
    end
  end

  @doc "Every known MC's environment descriptor as `{mc, descriptor}`."
  @spec environments() :: [{node, map}]
  def environments, do: :ets.tab2list(@mcs)

  @doc """
  The MC that serves a client's shape or RPC for `environment_id`: this one or the
  cluster member with that environment, else `nil`.
  """
  @spec mc_for(String.t()) :: node | nil
  def mc_for(environment_id) do
    # Even if the MC became distributed (and changed its name) after the shell
    # recorded it.
    if environment_id == HalC2.Environment.id() do
      node()
    else
      Enum.find_value(environments(), fn {mc, descriptor} ->
        if descriptor["environmentId"] == environment_id, do: mc
      end)
    end
  end

  @doc "MCs whose shell is currently reachable, this one included."
  @spec online_mcs() :: [node]
  def online_mcs, do: GenServer.call(__MODULE__, :online_mcs)

  @doc """
  Drops the machine with `environment_id` and its rows: a member removed from the
  cluster (`HalC2.Cluster`) is not coming back, as an offline one is.
  """
  @spec forget(String.t()) :: :ok
  def forget(environment_id), do: GenServer.cast(__MODULE__, {:forget, environment_id})

  @spec subscribe(pid) :: :ok
  def subscribe(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})

  @doc "Replaces a local stream's row; called by stream servers after they recompute it."
  @spec put_row(String.t(), {String.t(), map}) :: :ok
  def put_row(stream_id, kind_row),
    do: GenServer.cast(__MODULE__, {:put_row, stream_id, kind_row})

  # --- server ------------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    :ets.new(@mcs, [:named_table, :protected, read_concurrency: true])
    :ok = :net_kernel.monitor_nodes(true)
    path = HalC2.Store.path()
    stored = HalC2.Store.list_shell(path)
    :ets.insert(@table, for({id, kind, row} <- stored, do: {{node(), id}, {kind, row}}))
    :ets.insert(@mcs, {node(), HalC2.Environment.descriptor()})
    # Peers already connected (this shell restarted) send theirs back, as on nodeup.
    for peer <- Node.list() do
      push_all(peer)
      GenServer.cast({__MODULE__, peer}, {:peer_hello, node()})
    end

    backfill(path, MapSet.new(stored, &elem(&1, 0)))
    identify_repositories()
    {:ok, %{subscribers: %{}, online: MapSet.new([node() | Node.list()])}}
  end

  # A hot upgrade runs this with the new code, so projects learn what it knows about
  # their checkouts without a restart, as they do when the shell starts.
  @impl true
  def code_change(_old_vsn, state, _extra) do
    identify_repositories()
    {:ok, state}
  end

  # Outside this server: it runs git per project and commits through the streams.
  defp identify_repositories, do: Task.start(&HalC2.Projects.identify_repositories/0)

  @impl true
  def handle_call(:online_mcs, _from, state), do: {:reply, MapSet.to_list(state.online), state}

  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, pid, ref)}}
  end

  @impl true
  def handle_cast({:put_row, stream_id, kind_row}, state) do
    case :ets.lookup(@table, {node(), stream_id}) do
      [{_, ^kind_row}] ->
        :ok

      _ ->
        :ets.insert(@table, {{node(), stream_id}, kind_row})
        for peer <- Node.list(), do: push_rows(peer, [{stream_id, kind_row}])
        notify(state, {:rows, node(), [{stream_id, kind_row}]})
    end

    {:noreply, state}
  end

  def handle_cast({:peer_environment, peer, descriptor}, state) do
    :ets.insert(@mcs, {peer, descriptor})
    notify(state, {:environment, peer, descriptor})
    {:noreply, state}
  end

  def handle_cast({:forget, environment_id}, state) do
    peers =
      for {peer, %{"environmentId" => ^environment_id}} <- :ets.tab2list(@mcs),
          peer != node(),
          do: peer

    for peer <- peers do
      :ets.match_delete(@table, {{peer, :_}, :_})
      :ets.delete(@mcs, peer)
      notify(state, {:mc, peer, :removed})
    end

    {:noreply, %{state | online: MapSet.difference(state.online, MapSet.new(peers))}}
  end

  def handle_cast({:peer_hello, peer}, state) do
    push_all(peer)
    {:noreply, state}
  end

  # Rows pushed by a peer: its full shell on connect, single rows afterwards.
  def handle_cast({:peer_rows, peer, rows}, state) do
    :ets.insert(@table, for({id, kind_row} <- rows, do: {{peer, id}, kind_row}))
    notify(state, {:rows, peer, rows})
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodeup, peer}, state) do
    push_all(peer)
    notify(state, {:mc, peer, :up})
    {:noreply, %{state | online: MapSet.put(state.online, peer)}}
  end

  def handle_info({:nodedown, peer}, state) do
    # A machine already forgotten has nothing left to mark offline.
    if MapSet.member?(state.online, peer), do: notify(state, {:mc, peer, :down})
    {:noreply, %{state | online: MapSet.delete(state.online, peer)}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}

  def handle_info(_other, state), do: {:noreply, state}

  defp push_rows(peer, rows), do: GenServer.cast({__MODULE__, peer}, {:peer_rows, node(), rows})

  defp push_all(peer) do
    GenServer.cast(
      {__MODULE__, peer},
      {:peer_environment, node(), HalC2.Environment.descriptor()}
    )

    push_rows(
      peer,
      for([id, kind_row] <- :ets.match(@table, {{node(), :"$1"}, :"$2"}), do: {id, kind_row})
    )
  end

  defp notify(state, message),
    do: for({pid, _} <- state.subscribers, do: send(pid, {:hal_c2_shell, message}))

  # Streams without a stored row (a store from before rows were kept) get one in the
  # background; boot does not wait for it.
  defp backfill(path, have) do
    missing =
      for %{id: id} <- HalC2.Store.list_streams(path), not MapSet.member?(have, id), do: id

    if missing != [] do
      Task.start(fn ->
        Logger.info("computing #{length(missing)} missing sidebar rows")

        for id <- missing,
            {_kind, _row} = kind_row <- [HalC2.Projection.rebuild(id)],
            do: put_row(id, kind_row)
      end)
    end
  end
end
