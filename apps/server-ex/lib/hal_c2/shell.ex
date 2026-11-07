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

  Subscribers receive `{:hal_c2_shell, {:rows, mc, [{id, {kind, row}}]}}` (all of
  `mc`'s rows, possibly none, when they are sent whole),
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

  A client subscribes with `subscribe/3` and what it holds, and receives rows as
  `{:hal_c2_shell, {:rows, mc, rows, %{epoch: e, rev: r, reset: boolean}}}`.

  A client that asks for a `settled_limit` is sent, whenever an MC's rows go to it
  whole (its first subscribe, or a `reset`), only the newest settled threads of each
  project (`HalC2.Shell.Settled`), and is told how many it was not sent
  (`settled_left_out`, beside the version). Rows that change later are sent as to any
  client, a left-out one included.

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
  # `{pid, :plain | :client | {:client, settled_limit}}`
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
    # Without the shell (tools, some tests) there are no rows, as in `rows/0`.
    if :ets.whereis(@table) == :undefined do
      nil
    else
      case :ets.lookup(@table, {mc, id}) do
        [{_, row}] -> row
        [] -> nil
      end
    end
  end

  @doc "The members whose rows this MC holds, as of a version they sent."
  @spec held_mcs() :: [node]
  def held_mcs do
    if :ets.whereis(@versions) == :undefined,
      do: [],
      else: for({peer, _version} <- :ets.tab2list(@versions), do: peer)
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

  @doc """
  Tells clients whether discovery (`HalC2.Cluster.Discovery`) still tries the member
  with `environment_id` often (`trying`) or has stopped and counts it offline. Said
  only of a machine that is not online.
  """
  @spec link(String.t(), boolean) :: :ok
  def link(environment_id, trying),
    do: GenServer.cast(__MODULE__, {:link, environment_id, trying})

  @doc """
  Tells every reachable member this MC's environment again: after it moved to another
  version in place (`HalC2.Upgrade`), when no member connects anew to ask for it.
  """
  @spec announce() :: :ok
  def announce, do: GenServer.cast(__MODULE__, :announce)

  @spec subscribe(pid) :: :ok
  def subscribe(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})

  @doc """
  Subscribes a client that holds each MC's rows as of `have` (by MC name) and
  returns what it lacks: every MC as
  `%{mc:, online:, environment:, epoch:, rev:, reset:}` and the rows after its
  versions as `{mc, stream_id, kind, row}`. An MC marked `reset` is sent whole, and
  the client drops whatever rows of it it had.

  With `settled_limit: n`, an MC sent whole leaves out all but the `n` newest settled
  threads of each project, and its entry says how many it left out of each
  (`settled_left_out`). So do the resets this client is sent later.

  With `omit_idle_subagents: true` the rows returned here leave out idle subagent
  threads (`idle_subagent?/2`): a cold connect pays for the rows the sidebar shows,
  and a client reads a thread's family when it opens one (`family/1`). Only this
  snapshot is filtered; changes after it are sent as they come, so a subagent that
  starts work appears.
  """
  @spec subscribe(pid, %{String.t() => version},
          settled_limit: pos_integer | nil,
          omit_idle_subagents: boolean
        ) :: %{mcs: [map], rows: [tuple]}
  def subscribe(pid, have, opts \\ []),
    do:
      GenServer.call(
        __MODULE__,
        {:subscribe, pid, have, opts[:settled_limit], opts[:omit_idle_subagents] == true}
      )

  @live ~w(queued preparing starting running)

  @doc """
  Whether a thread's shell row is an idle subagent a snapshot may leave out: a
  subagent (by its lineage) with no live or queued run, nothing waiting on the
  user, no background work, and no subagent of its own. `parents` is the set of
  thread ids that have a subagent (`subagent_parents/1`).
  """
  @spec idle_subagent?(map, MapSet.t(String.t())) :: boolean
  def idle_subagent?(row, parents) do
    lineage = row["lineage"] || %{}

    lineage["relationshipToParent"] == "subagent" and is_binary(lineage["parentThreadId"]) and
      row["status"] not in @live and row["status"] != "waiting" and
      row["activeRunId"] == nil and
      row["activityRunStatus"] not in @live and row["activityRunStatus"] != "waiting" and
      row["pendingRuntimeRequest"] == nil and (row["pendingBackgroundTasks"] || []) == [] and
      not MapSet.member?(parents, row["id"])
  end

  @doc "The ids of threads that have a subagent among `rows` (`rows/0` tuples)."
  @spec subagent_parents([{{node, String.t()}, {String.t(), map}}]) :: MapSet.t(String.t())
  def subagent_parents(rows) do
    MapSet.new(
      for {_key, {"thread", row}} <- rows,
          (row["lineage"] || %{})["relationshipToParent"] == "subagent",
          is_binary((row["lineage"] || %{})["parentThreadId"]),
          do: row["lineage"]["parentThreadId"]
    )
  end

  @doc """
  A thread's family as shell rows (`{mc, id, "thread", row}`): its lineage chain
  root first, then its subagent tree breadth first — what a client that left idle
  subagents out of its snapshot reads when the thread is opened. Empty when this
  shell holds no row for the thread.
  """
  @spec family(String.t()) :: [{node, String.t(), String.t(), map}]
  def family(thread_id) do
    by_id =
      Map.new(for {{mc, id}, {"thread", row}} <- rows(), do: {id, {mc, id, "thread", row}})

    case by_id[thread_id] do
      nil ->
        []

      _ ->
        ancestors = lineage_chain(by_id, thread_id, MapSet.new([thread_id]))

        children =
          Enum.group_by(
            Map.values(by_id),
            fn {_, _, _, row} -> (row["lineage"] || %{})["parentThreadId"] end,
            fn {_, id, _, row} -> {id, (row["lineage"] || %{})["relationshipToParent"]} end
          )

        descendants = tree(children, [thread_id], MapSet.new([thread_id | ancestors]))
        for id <- ancestors ++ [thread_id] ++ descendants, do: by_id[id]
    end
  end

  # The thread's parents up to its root, root first; a lineage loop stops the walk.
  defp lineage_chain(by_id, id, seen) do
    case by_id[id] do
      {_, _, _, row} ->
        case (row["lineage"] || %{})["parentThreadId"] do
          parent when is_binary(parent) ->
            if MapSet.member?(seen, parent) or not Map.has_key?(by_id, parent),
              do: [],
              else: lineage_chain(by_id, parent, MapSet.put(seen, parent)) ++ [parent]

          _ ->
            []
        end

      _ ->
        []
    end
  end

  # Subagent descendants breadth first; a lineage loop is visited once.
  defp tree(_children, [], _seen), do: []

  defp tree(children, level, seen) do
    next =
      for parent <- level,
          {id, relationship} <- Map.get(children, parent, []),
          relationship == "subagent",
          not MapSet.member?(seen, id),
          do: id

    next = Enum.uniq(next)
    next ++ tree(children, next, MapSet.union(seen, MapSet.new(next)))
  end

  @doc "Replaces a local stream's row; called by stream servers after they recompute it."
  @spec put_row(String.t(), {String.t(), map}) :: :ok
  def put_row(stream_id, kind_row),
    do: GenServer.cast(__MODULE__, {:put_row, stream_id, kind_row})

  @doc """
  Returns once the rows the calling process put before this call are in the table.
  Only its own: another process's `put_row/2` may still be on its way, so the stream
  that writes a row is the one to call this (`HalC2.Streams.Server.flush_shell/1`).
  A no-op where no shell runs, or while it restarts (it reads the stored rows then).
  """
  @spec sync() :: :ok
  def sync do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :sync), else: :ok
  catch
    :exit, _ -> :ok
  end

  # --- server ------------------------------------------------------------------

  @impl true
  def init(_opts) do
    held = HalC2.Heir.claim(@heir, @tables)
    for name <- @tables, name not in held, do: :ets.new(name, table_options(name))
    :ok = :net_kernel.monitor_nodes(true)
    path = HalC2.Store.path()
    # A thread an import has not finished is not shown, nor settled by recovery, which
    # works from these rows: a write to it here would keep a retry from continuing it.
    # The marks are read after the rows: an import marks a thread before its stream
    # (and its stored row) exists, so a row read here whose import is unfinished has
    # its mark by now, while the shell alone restarting under a running import could
    # otherwise snapshot the marks before it and show the thread partway.
    rows = HalC2.Store.list_shell(path)
    unfinished = HalC2.Import.PreviousInstall.unfinished(path)
    stored = for {id, _, _} = row <- rows, id not in unfinished, do: row
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
    backfill(path, MapSet.union(unfinished, MapSet.new(stored, &elem(&1, 0))))
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

  # From a socket of the release before the settled limit.
  def handle_call({:subscribe, pid, have}, from, state),
    do: handle_call({:subscribe, pid, have, nil, false}, from, state)

  # From a socket of the release before idle subagents could be left out.
  def handle_call({:subscribe, pid, have, limit}, from, state),
    do: handle_call({:subscribe, pid, have, limit, false}, from, state)

  def handle_call({:subscribe, pid, have, limit, omit_idle?}, _from, state) do
    kind = client_kind(limit)

    {mcs, rows} =
      Enum.map_reduce(:ets.tab2list(@mcs), [], fn {mc, descriptor}, rows ->
        {epoch, rev} = version = version_of(state, mc)
        {from, reset?} = lacking(version, Map.get(have, Atom.to_string(mc)))

        {sent, entry} =
          for_client(kind, rows_after(mc, from), %{epoch: epoch, rev: rev, reset: reset?})

        mc_rows = for {id, {kind, row}} <- sent, do: {mc, id, kind, row}

        entry =
          Map.merge(entry, %{
            mc: mc,
            online: MapSet.member?(state.online, mc),
            environment: descriptor
          })

        {entry, mc_rows ++ rows}
      end)

    rows =
      if omit_idle? do
        parents = subagent_parents(:ets.tab2list(@table))

        Enum.reject(rows, fn
          {_mc, _id, "thread", row} -> idle_subagent?(row, parents)
          _ -> false
        end)
      else
        rows
      end

    put_subscriber(pid, kind)
    {:reply, %{mcs: mcs, rows: rows}, state}
  end

  defp client_kind(limit) when is_integer(limit) and limit > 0, do: {:client, limit}
  defp client_kind(_limit), do: :client

  # What a client subscriber is sent of an MC's changed rows at `version`: all of
  # them, or, sent whole to one with a settled limit, the trimmed rows and the counts
  # of those left out.
  defp for_client({:client, limit}, rows, %{reset: true} = version) do
    {rows, left_out} = HalC2.Shell.Settled.trim(rows, limit)
    {rows, Map.put(version, :settled_left_out, left_out)}
  end

  defp for_client(_kind, rows, version), do: {rows, version}

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

  def handle_cast({:link, environment_id, trying}, state) do
    for {peer, %{"environmentId" => ^environment_id}} <- :ets.tab2list(@mcs),
        peer != node(),
        not MapSet.member?(state.online, peer),
        do: notify({:mc, peer, if(trying, do: :down, else: :offline)})

    {:noreply, state}
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

  def handle_cast(:announce, state) do
    descriptor = HalC2.Environment.descriptor()

    for peer <- state.online,
        peer != node(),
        do: cast(peer, {:peer_environment, node(), descriptor})

    {:noreply, state}
  end

  # From a member on another HAL-C2 version, whose messages this one does not know.
  # Members on other versions stay connected (`HalC2.Cluster`), so this must not crash.
  def handle_cast(_other, state), do: {:noreply, state}

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
  # subscribers get `plain`, and a reset even when empty: it tells them they have all
  # of `mc`'s rows, as `HalC2.Push` needs of a member that joins with none.
  defp notify(mc, plain \\ nil, rows, version)

  defp notify(_mc, _plain, [], %{reset: false}), do: :ok

  defp notify(mc, plain, rows, %{reset: reset?} = version) do
    plain = plain || rows

    subscribers = :ets.tab2list(@subscribers)

    # Trimmed once for each limit the subscribers asked for.
    sent =
      for {_pid, kind} <- subscribers, kind != :plain, uniq: true, into: %{} do
        {kind, for_client(kind, rows, version)}
      end

    for {pid, kind} <- subscribers do
      case kind do
        :plain ->
          if plain != [] or reset?, do: send(pid, {:hal_c2_shell, {:rows, mc, plain}})

        client ->
          {rows, version} = sent[client]
          send(pid, {:hal_c2_shell, {:rows, mc, rows, version}})
      end
    end
  end

  defp notify(message),
    do: for({pid, _} <- :ets.tab2list(@subscribers), do: send(pid, {:hal_c2_shell, message}))

  @doc "The version this MC's rows are at, or nil where no shell runs."
  @spec version() :: version | nil
  def version do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :version)
  catch
    :exit, _ -> nil
  end

  # Streams without a stored row (a store from before rows were kept) get one in the
  # background; boot does not wait for it.
  defp backfill(path, have) do
    streams = HalC2.Store.list_streams(path)
    # As in `init/1`: the marks after the list, so a stream an import that began
    # while this shell was starting has just made is left to that import.
    unfinished = HalC2.Import.PreviousInstall.unfinished(path)

    # Only projects and threads have sidebar rows (`HalC2.Projection.row/3`).
    missing =
      for %{id: id, kind: kind} <- streams,
          kind in ["project", "thread"],
          not MapSet.member?(have, id),
          id not in unfinished,
          do: id

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
