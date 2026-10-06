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

  ## Versions

  Nobody is sent rows it already has. Each MC counts the changes to its own rows:
  a row's `rev` is the count at its latest change, and the MC's version is
  `{epoch, rev}`, where `epoch` names one run of this process. Whoever holds an MC's
  rows as of a version (a peer, or a client that kept them between connections) asks
  for the rows after it and gets only those; with another epoch, or none, it gets
  them all and drops the ones it had (`reset`).

  The count lives in memory, so an MC that restarts sends its rows whole once. Keeping
  it in the store would need a schema older MCs cannot open, to save a resend that
  only follows a restart.

  A client subscribes with `subscribe/2` and what it holds, and receives rows as
  `{:hal_c2_shell, {:rows, mc, rows, %{epoch: e, rev: r, reset: boolean}}}`.

  Between MCs, `peer_hello` carries the version one holds of the other and is
  answered with `peer_rows` from it. A change is pushed as the one row after the
  version the peer was last sent; a peer that finds a gap before it asks again.
  """

  use GenServer

  require Logger

  @table __MODULE__
  @mcs HalC2.Shell.Mcs
  # `{{mc, stream_id}, rev}`: the owning MC's count at each row's latest change.
  @revs HalC2.Shell.Revs

  @typedoc "An MC's rows as of `rev` changes in the run of its shell named `epoch`."
  @type version :: {epoch :: String.t() | nil, rev :: non_neg_integer}

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

  @doc """
  Subscribes a client that holds each MC's rows as of `have` (by MC name) and
  returns what it lacks: every MC as
  `%{mc:, online:, environment:, epoch:, rev:, reset:}` and the rows after its
  versions as `{mc, stream_id, kind, row}`. An MC marked `reset` is sent whole, and
  the client drops whatever rows of it it had.
  """
  @spec subscribe(pid, %{String.t() => version}) :: %{mcs: [map], rows: [tuple]}
  def subscribe(pid, have), do: GenServer.call(__MODULE__, {:subscribe, pid, have})

  @doc "Replaces a local stream's row; called by stream servers after they recompute it."
  @spec put_row(String.t(), {String.t(), map}) :: :ok
  def put_row(stream_id, kind_row),
    do: GenServer.cast(__MODULE__, {:put_row, stream_id, kind_row})

  # --- server ------------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    :ets.new(@mcs, [:named_table, :protected, read_concurrency: true])
    :ets.new(@revs, [:named_table, :protected])
    :ok = :net_kernel.monitor_nodes(true)
    path = HalC2.Store.path()
    stored = HalC2.Store.list_shell(path)
    :ets.insert(@table, for({id, kind, row} <- stored, do: {{node(), id}, {kind, row}}))
    :ets.insert(@mcs, {node(), HalC2.Environment.descriptor()})

    state = %{
      subscribers: %{},
      online: MapSet.new([node() | Node.list()]),
      own: new_version(),
      # What this MC holds of each peer's rows.
      versions: %{}
    }

    # Peers already connected (this shell restarted) hold rows of its last run and
    # it holds none of theirs: each sends the other what it lacks.
    for peer <- Node.list(), do: hello(peer, state, true)
    backfill(path, MapSet.new(stored, &elem(&1, 0)))
    identify_repositories()
    {:ok, state}
  end

  # The rows read from the store are this run's version 0.
  defp new_version, do: {Base.encode16(:crypto.strong_rand_bytes(6), case: :lower), 0}

  # The MC's own version is kept apart from its peers': its node name changes when
  # it becomes distributed.
  defp version_of(state, mc) do
    if mc == node(), do: state.own, else: Map.get(state.versions, mc, {nil, 0})
  end

  # A hot upgrade runs this with the new code, so projects learn what it knows about
  # their checkouts without a restart, as they do when the shell starts.
  @impl true
  def code_change(_old_vsn, state, _extra) do
    identify_repositories()

    # Before rows had versions. Peers upgrade too and say hello when they are back.
    state =
      if Map.has_key?(state, :versions) do
        state
      else
        if :ets.whereis(@revs) == :undefined, do: :ets.new(@revs, [:named_table, :protected])

        subscribers =
          Map.new(state.subscribers, fn {pid, ref} -> {pid, {ref, :plain}} end)

        Map.merge(state, %{own: new_version(), versions: %{}, subscribers: subscribers})
      end

    {:ok, state}
  end

  # Outside this server: it runs git per project and commits through the streams.
  defp identify_repositories, do: Task.start(&HalC2.Projects.identify_repositories/0)

  @impl true
  def handle_call(:online_mcs, _from, state), do: {:reply, MapSet.to_list(state.online), state}
  def handle_call(:version, _from, state), do: {:reply, state.own, state}

  def handle_call({:subscribe, pid}, _from, state),
    do: {:reply, :ok, put_subscriber(state, pid, :plain)}

  def handle_call({:subscribe, pid, have}, _from, state) do
    {mcs, rows} =
      Enum.map_reduce(:ets.tab2list(@mcs), [], fn {mc, descriptor}, rows ->
        {epoch, rev} = version = version_of(state, mc)
        {from, reset?} = lacking(version, Map.get(have, Atom.to_string(mc)))

        mc_rows = for {id, {kind, row}} <- rows_after(mc, from), do: {mc, id, kind, row}

        {%{
           mc: mc,
           online: MapSet.member?(state.online, mc),
           environment: descriptor,
           epoch: epoch,
           rev: rev,
           reset: reset?
         }, mc_rows ++ rows}
      end)

    {:reply, %{mcs: mcs, rows: rows}, put_subscriber(state, pid, :client)}
  end

  defp put_subscriber(state, pid, kind) do
    ref = Process.monitor(pid)
    %{state | subscribers: Map.put(state.subscribers, pid, {ref, kind})}
  end

  # Where someone holding `have` of an MC at `version` continues from: `{rev, false}`
  # for the rows after `rev`, or `{:all, true}` when what it holds is of no use.
  defp lacking({epoch, rev}, {epoch, held}) when epoch != nil and held <= rev, do: {held, false}
  defp lacking(_version, _have), do: {:all, true}

  # Version 0 is a version like any other: the rows an MC started with, which
  # whoever holds them as of 0 has.
  defp rows_after(mc, :all),
    do: for([id, kind_row] <- :ets.match(@table, {{mc, :"$1"}, :"$2"}), do: {id, kind_row})

  defp rows_after(mc, rev) do
    ids = :ets.select(@revs, [{{{mc, :"$1"}, :"$2"}, [{:>, :"$2", rev}], [:"$1"]}])
    for id <- ids, [{_, kind_row}] <- [:ets.lookup(@table, {mc, id})], do: {id, kind_row}
  end

  @impl true
  def handle_cast({:put_row, stream_id, kind_row}, state) do
    case :ets.lookup(@table, {node(), stream_id}) do
      [{_, ^kind_row}] ->
        {:noreply, state}

      _ ->
        {epoch, held} = state.own
        rev = held + 1
        :ets.insert(@table, {{node(), stream_id}, kind_row})
        :ets.insert(@revs, {{node(), stream_id}, rev})
        rows = [{stream_id, kind_row}]

        for peer <- Node.list(),
            do: push_rows(peer, {epoch, rev}, held, [{stream_id, kind_row, rev}], false)

        notify(state, node(), rows, %{epoch: epoch, rev: rev, reset: false})
        {:noreply, %{state | own: {epoch, rev}}}
    end
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
      :ets.match_delete(@revs, {{peer, :_}, :_})
      :ets.delete(@mcs, peer)
      notify(state, {:mc, peer, :removed})
    end

    {:noreply,
     %{
       state
       | online: MapSet.difference(state.online, MapSet.new(peers)),
         versions: Map.drop(state.versions, peers)
     }}
  end

  # A peer says what it holds of this MC and is sent the rest; `ask_back?` when it
  # wants to be told what this MC holds of it in return.
  def handle_cast({:peer_hello, peer, have, ask_back?}, state) do
    GenServer.cast(
      {__MODULE__, peer},
      {:peer_environment, node(), HalC2.Environment.descriptor()}
    )

    version = state.own
    {from, reset?} = lacking(version, have)

    rows =
      for {id, kind_row} <- rows_after(node(), from) do
        [{_, rev}] = :ets.lookup(@revs, {node(), id}) |> default_rev(id)
        {id, kind_row, rev}
      end

    push_rows(peer, version, if(reset?, do: 0, else: from), rows, reset?)
    if ask_back?, do: hello(peer, state, false)
    {:noreply, state}
  end

  # Rows pushed by a peer: what this MC lacked when it said hello, single rows
  # afterwards. `from` is the version they follow.
  def handle_cast({:peer_rows, peer, {epoch, rev}, from, rows, reset?}, state) do
    {held_epoch, held_rev} = version_of(state, peer)

    cond do
      reset? ->
        :ets.match_delete(@table, {{peer, :_}, :_})
        :ets.match_delete(@revs, {{peer, :_}, :_})
        {:noreply, put_peer_rows(state, peer, {epoch, rev}, rows, true)}

      epoch == held_epoch and from <= held_rev ->
        {:noreply, put_peer_rows(state, peer, {epoch, max(rev, held_rev)}, rows, false)}

      true ->
        # Rows between what is held and these never arrived: ask for all of them.
        hello(peer, state, false)
        {:noreply, state}
    end
  end

  # From a member still on a version before rows had versions, in the moment before
  # this MC drops it for that (`HalC2.Cluster.version_changed/0`). It says hello
  # again once it runs this version.
  def handle_cast({:peer_rows, _peer, _rows}, state), do: {:noreply, state}
  def handle_cast({:peer_hello, _peer}, state), do: {:noreply, state}

  @impl true
  def handle_info({:nodeup, peer}, state) do
    hello(peer, state, false)
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

  # The rows read from the store when the shell started have no entry: version 0.
  defp default_rev([], id), do: [{id, 0}]
  defp default_rev(found, _id), do: found

  defp put_peer_rows(state, peer, {epoch, rev} = version, rows, reset?) do
    :ets.insert(@table, for({id, kind_row, _rev} <- rows, do: {{peer, id}, kind_row}))
    :ets.insert(@revs, for({id, _kind_row, rev} <- rows, do: {{peer, id}, rev}))
    plain = for {id, kind_row, _rev} <- rows, do: {id, kind_row}
    notify(state, peer, plain, %{epoch: epoch, rev: rev, reset: reset?})
    put_in(state.versions[peer], version)
  end

  defp hello(peer, state, ask_back?) do
    have = Map.get(state.versions, peer)
    GenServer.cast({__MODULE__, peer}, {:peer_hello, node(), have, ask_back?})
  end

  defp push_rows(peer, version, from, rows, reset?),
    do: GenServer.cast({__MODULE__, peer}, {:peer_rows, node(), version, from, rows, reset?})

  # Changed rows of `mc`: clients are told the version they bring it to.
  defp notify(_state, _mc, [], %{reset: false}), do: :ok

  defp notify(state, mc, rows, version) do
    for {pid, {_ref, kind}} <- state.subscribers do
      case kind do
        :plain -> if rows != [], do: send(pid, {:hal_c2_shell, {:rows, mc, rows}})
        :client -> send(pid, {:hal_c2_shell, {:rows, mc, rows, version}})
      end
    end
  end

  defp notify(state, message),
    do: for({pid, _} <- state.subscribers, do: send(pid, {:hal_c2_shell, message}))

  @doc false
  # The version this MC's rows are at, for tests.
  def version, do: GenServer.call(__MODULE__, :version)

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
