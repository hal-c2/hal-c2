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

  When this server alone restarts, its tables, its subscribers and the versions it
  holds of its peers outlive it with its `HalC2.Heir`: readers never find the
  sidebar missing, subscribers stay subscribed, and peers are asked only for what
  changed. Its own rows start a new epoch from the store, and clients are sent them
  whole.

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
  # `{peer, version}`: what this MC holds of each peer's rows.
  @versions HalC2.Shell.Versions
  # `{pid, :plain | :client}`
  @subscribers HalC2.Shell.Subscribers
  @tables [@table, @mcs, @revs, @versions, @subscribers]
  @heir HalC2.Shell.Heir

  @typedoc "An MC's rows as of `rev` changes in the run of its shell named `epoch`."
  @type version :: {epoch :: String.t() | nil, rev :: non_neg_integer}

  # The heir starts first, and a restart of it takes the shell with it.
  def child_spec(opts) do
    server = %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
    HalC2.Heir.supervise(@heir, server, HalC2.Shell.Supervisor)
  end

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

  @doc """
  Returns once the rows put before this call are in the table: a caller that had a
  stream write its row (`HalC2.Streams.flush_shell/1`) can read it back. A no-op
  where no shell runs.
  """
  @spec sync() :: :ok
  def sync do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :sync), else: :ok
  end

  # --- server ------------------------------------------------------------------

  @impl true
  def init(_opts) do
    held = HalC2.Heir.claim(@heir, @tables)
    for name <- @tables, name not in held, do: :ets.new(name, table_options(name))
    :ok = :net_kernel.monitor_nodes(true)
    path = HalC2.Store.path()
    stored = HalC2.Store.list_shell(path)
    forget_former_names()

    # This run's version 0 is the rows in the store; rows kept from the last run that
    # differ from them were changes it lost on the way down.
    changed = replace_rows(node(), Map.new(stored, fn {id, kind, row} -> {id, {kind, row}} end))
    :ets.match_delete(@revs, {{node(), :_}, :_})
    :ets.insert(@mcs, {node(), HalC2.Environment.descriptor()})
    connected = transport().connected()
    state = %{online: MapSet.new([node() | connected]), own: new_version()}

    # Subscribers of the last run stay subscribed: clients are sent this MC's rows
    # whole in the new epoch, the rest what changed.
    for {pid, _kind} <- :ets.tab2list(@subscribers), do: Process.monitor(pid)
    {epoch, rev} = state.own
    all = for [id, kind_row] <- :ets.match(@table, {{node(), :"$1"}, :"$2"}), do: {id, kind_row}
    notify(node(), changed, all, %{epoch: epoch, rev: rev, reset: true})

    # Peers already connected (this shell restarted) hold rows of its last run, and
    # it may have missed changes of theirs: each sends the other what it lacks.
    for peer <- connected, do: hello(peer, true)
    backfill(path, MapSet.new(stored, &elem(&1, 0)))
    identify_repositories()
    {:ok, state}
  end

  # The tables belong to the heir while this server is down, so readers never find
  # them gone. Without it (a tree started before it existed) they go with this server.
  defp table_options(name) do
    base = [:named_table, :protected] ++ HalC2.Heir.option(@heir)
    if name in [@table, @mcs], do: [{:read_concurrency, true} | base], else: base
  end

  # This MC's rows kept under the name it had before it became distributed.
  defp forget_former_names do
    id = HalC2.Environment.id()

    for {mc, %{"environmentId" => ^id}} <- :ets.tab2list(@mcs), mc != node() do
      :ets.match_delete(@table, {{mc, :_}, :_})
      :ets.match_delete(@revs, {{mc, :_}, :_})
      :ets.delete(@mcs, mc)
    end
  end

  # The rows read from the store are this run's version 0.
  defp new_version, do: {Base.encode16(:crypto.strong_rand_bytes(6), case: :lower), 0}

  # The MC's own version is kept apart from its peers': its node name changes when
  # it becomes distributed.
  defp version_of(state, mc) do
    if mc == node(), do: state.own, else: held_version(mc)
  end

  defp held_version(peer) do
    case :ets.lookup(@versions, peer) do
      [{_, version}] -> version
      [] -> {nil, 0}
    end
  end

  # Makes `rows` (`id => {kind, row}`) the rows of `mc` and returns those that
  # changed. New rows go in before stale ones go out, so a reader sees each row as it
  # was or as it is, never missing.
  defp replace_rows(mc, rows) do
    old =
      Map.new(:ets.match(@table, {{mc, :"$1"}, :"$2"}), fn [id, kind_row] -> {id, kind_row} end)

    :ets.insert(@table, for({id, kind_row} <- rows, do: {{mc, id}, kind_row}))

    for {id, _} <- old, not Map.has_key?(rows, id) do
      :ets.delete(@table, {mc, id})
      :ets.delete(@revs, {mc, id})
    end

    for {id, kind_row} <- rows, Map.get(old, id) != kind_row, do: {id, kind_row}
  end

  # A hot upgrade runs this with the new code, so projects learn what it knows about
  # their checkouts without a restart, as they do when the shell starts.
  @impl true
  def code_change(_old_vsn, state, _extra) do
    identify_repositories()
    {:ok, migrate(state)}
  end

  # Before subscribers and the versions held of peers were kept in tables, and
  # before rows had versions. Peers upgrade too and say hello when they are back.
  defp migrate(%{subscribers: subscribers} = state) do
    for name <- @tables do
      if :ets.whereis(name) == :undefined,
        do: :ets.new(name, table_options(name)),
        else: :ets.setopts(name, HalC2.Heir.option(@heir))
    end

    :ets.insert(
      @subscribers,
      for({pid, sub} <- subscribers, do: {pid, if(is_tuple(sub), do: elem(sub, 1), else: :plain)})
    )

    :ets.insert(@versions, Map.to_list(Map.get(state, :versions, %{})))
    %{online: state.online, own: Map.get_lazy(state, :own, &new_version/0)}
  end

  defp migrate(state), do: state

  # Outside this server: it runs git per project and commits through the streams.
  defp identify_repositories, do: Task.start(&HalC2.Projects.identify_repositories/0)

  @impl true
  def handle_call(:online_mcs, _from, state), do: {:reply, MapSet.to_list(state.online), state}
  def handle_call(:version, _from, state), do: {:reply, state.own, state}
  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  def handle_call({:subscribe, pid}, _from, state) do
    put_subscriber(pid, :plain)
    {:reply, :ok, state}
  end

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

    put_subscriber(pid, :client)
    {:reply, %{mcs: mcs, rows: rows}, state}
  end

  defp put_subscriber(pid, kind) do
    Process.monitor(pid)
    :ets.insert(@subscribers, {pid, kind})
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

        for peer <- transport().connected(),
            do: push_rows(peer, {epoch, rev}, held, [{stream_id, kind_row, rev}], false)

        notify(node(), rows, %{epoch: epoch, rev: rev, reset: false})
        {:noreply, %{state | own: {epoch, rev}}}
    end
  end

  # Like rows, a descriptor from a peer that is not online was sent before it was
  # forgotten.
  def handle_cast({:peer_environment, peer, descriptor}, state) do
    if MapSet.member?(state.online, peer) do
      :ets.insert(@mcs, {peer, descriptor})
      notify({:environment, peer, descriptor})
    end

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
      :ets.delete(@versions, peer)
      :ets.delete(@mcs, peer)
      notify({:mc, peer, :removed})
    end

    {:noreply, %{state | online: MapSet.difference(state.online, MapSet.new(peers))}}
  end

  # A peer says what it holds of this MC and is sent the rest; `ask_back?` when it
  # wants to be told what this MC holds of it in return.
  def handle_cast({:peer_hello, peer, have, ask_back?}, state) do
    cast(peer, {:peer_environment, node(), HalC2.Environment.descriptor()})

    version = state.own
    {from, reset?} = lacking(version, have)

    rows =
      for {id, kind_row} <- rows_after(node(), from) do
        [{_, rev}] = :ets.lookup(@revs, {node(), id}) |> default_rev(id)
        {id, kind_row, rev}
      end

    push_rows(peer, version, if(reset?, do: 0, else: from), rows, reset?)
    if ask_back?, do: hello(peer, false)
    {:noreply, state}
  end

  # Rows pushed by a peer: what this MC lacked when it said hello, single rows
  # afterwards. `from` is the version they follow. A peer is online before anything
  # it sends arrives (`:net_kernel.monitor_nodes/1`), so rows from one that is not
  # were sent before it was forgotten, and are dropped with it.
  def handle_cast({:peer_rows, peer, {epoch, rev}, from, rows, reset?}, state) do
    {held_epoch, held_rev} = held_version(peer)

    cond do
      not MapSet.member?(state.online, peer) ->
        {:noreply, state}

      reset? ->
        {:noreply, put_peer_rows(state, peer, {epoch, rev}, rows, true)}

      epoch == held_epoch and from <= held_rev ->
        {:noreply, put_peer_rows(state, peer, {epoch, max(rev, held_rev)}, rows, false)}

      true ->
        # Rows between what is held and these never arrived: ask for all of them.
        hello(peer, false)
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
    hello(peer, false)
    notify({:mc, peer, :up})
    {:noreply, %{state | online: MapSet.put(state.online, peer)}}
  end

  def handle_info({:nodedown, peer}, state) do
    # A machine already forgotten has nothing left to mark offline.
    if MapSet.member?(state.online, peer), do: notify({:mc, peer, :down})
    {:noreply, %{state | online: MapSet.delete(state.online, peer)}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _}, state) do
    :ets.delete(@subscribers, pid)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # The rows read from the store when the shell started have no entry: version 0.
  defp default_rev([], id), do: [{id, 0}]
  defp default_rev(found, _id), do: found

  defp put_peer_rows(state, peer, {epoch, rev} = version, rows, reset?) do
    plain = for {id, kind_row, _rev} <- rows, do: {id, kind_row}

    if reset?,
      do: replace_rows(peer, Map.new(plain)),
      else: :ets.insert(@table, for({id, kind_row} <- plain, do: {{peer, id}, kind_row}))

    :ets.insert(@revs, for({id, _kind_row, rev} <- rows, do: {{peer, id}, rev}))
    :ets.insert(@versions, {peer, version})
    notify(peer, plain, %{epoch: epoch, rev: rev, reset: reset?})
    state
  end

  defp hello(peer, ask_back?) do
    cast(peer, {:peer_hello, node(), held_version(peer), ask_back?})
  end

  defp push_rows(peer, version, from, rows, reset?),
    do: cast(peer, {:peer_rows, node(), version, from, rows, reset?})

  defp cast(peer, message), do: transport().cast(peer, message)

  # Peers' shells are reached over Erlang distribution (`HalC2.Shell.Distribution`);
  # the property tests stand in for them.
  defp transport, do: Application.get_env(:hal_c2, :shell_transport, HalC2.Shell.Distribution)

  # Changed rows of `mc`: clients are told the version they bring it to. Plain
  # subscribers get `plain`, clients `rows`.
  defp notify(mc, plain \\ nil, rows, version)

  defp notify(_mc, _plain, [], %{reset: false}), do: :ok

  defp notify(mc, plain, rows, version) do
    plain = plain || rows

    for {pid, kind} <- :ets.tab2list(@subscribers) do
      case kind do
        :plain -> if plain != [], do: send(pid, {:hal_c2_shell, {:rows, mc, plain}})
        :client -> send(pid, {:hal_c2_shell, {:rows, mc, rows, version}})
      end
    end
  end

  defp notify(message),
    do: for({pid, _} <- :ets.tab2list(@subscribers), do: send(pid, {:hal_c2_shell, message}))

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

defmodule HalC2.Shell.Distribution do
  @moduledoc false
  # How `HalC2.Shell` reaches the shells of the MCs it is connected to.

  def connected, do: Node.list()
  def cast(peer, message), do: GenServer.cast({HalC2.Shell, peer}, message)
end
