defmodule HalC2.ClusterPropTest do
  @moduledoc """
  Cluster membership without a network.

  `HalC2.Cluster` runs against a fake transport (`HalC2.Prop.ClusterTransport`) and a
  model of the member table: for each other machine its fingerprint, label, addresses
  and whether it is a member, plus which members are connected. Commands admit and
  remove machines, gossip tables in from members (newer than anything seen, with a
  clock an hour ahead, or older than what is known), connect members, fire the gossip
  timer, change version and restart the process. After each one the cluster must say
  what the model says: in `peers/0` (what discovery tries), `status/0`, the tables it
  gossips, the certificates it pins and the members it stays connected to; and a copy
  of its own entry gossiped an hour ahead leaves its own stamped later still.

  `HalC2.Cluster.Discovery` runs against an attempt the test holds open, so the test
  decides when each attempt ends and how: one attempt at a time, polls during one
  coalesce into a single next attempt, a crashed attempt only ends early, and an idle
  discovery always has its next attempt scheduled.

  `HalC2.Cluster.Discovery.connect/3` is checked against a reachability the test picks:
  it tries the documented candidates in order, stops at the first that reaches the
  member, which includes a member that moved to the cluster port at a host it had, and
  leaves the port mapper at the address that worked or the one it held before.

  `HalC2.Cluster.merge/3` is checked on its own: any three updates of one machine's
  entry merge to one table whatever their order, grouping or repetition.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Cluster
  alias HalC2.Cluster.{Discovery, Epmd}
  alias HalC2.Prop.ClusterTransport

  @moduletag timeout: :infinity
  @moduletag :capture_log

  @ids ["m1", "m2", "m3", "Bad_id"]
  @fingerprints for c <- ~w(a b c), do: String.duplicate(c, 64)

  property "the cluster's members are the ones its table says, wherever they are read",
    numtests: HalC2.Prop.numtests(100),
    max_size: 30 do
    HalC2.Prop.scratch_home("cluster-id")
    # Cached from here on, so every case is the same machine.
    _ = HalC2.Environment.id()
    Application.put_env(:hal_c2, :cluster_listen, "127.0.0.1")

    forall cmds <- commands(__MODULE__) do
      trap_exit do
        HalC2.Prop.scratch_home("cluster")
        ClusterTransport.install()
        HalC2.Prop.start_services([Cluster])
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()
        drain()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ------------------------------------------------------------------

  # members: id => %{fp, label, addresses, member}; connected: ids of connected members
  def initial_state, do: %{own: HalC2.Environment.id(), members: %{}, connected: MapSet.new()}

  def command(state) do
    known = Map.keys(state.members)
    any_id = oneof(@ids ++ [state.own])

    frequency([
      {4, {:call, __MODULE__, :admit, [any_id, fingerprint(), label(), addresses(), version()]}},
      {3, {:call, __MODULE__, :remove, [oneof([any_id | known])]}},
      {4, {:call, __MODULE__, :gossip, [gossip_entries(state)]}},
      {3, {:call, __MODULE__, :nodeup, [oneof(["stranger" | @ids])]}},
      {2, {:call, __MODULE__, :peers, []}},
      {2, {:call, __MODULE__, :status, []}},
      {2, {:call, __MODULE__, :tick, []}},
      {1, {:call, __MODULE__, :version_changed, []}},
      {1, {:call, __MODULE__, :restart, []}}
    ])
  end

  defp fingerprint, do: frequency([{6, oneof(@fingerprints)}, {1, "not-a-fingerprint"}])
  defp label, do: frequency([{4, oneof(["box", "laptop"])}, {1, nil}, {1, 7}])
  defp version, do: frequency([{6, :current}, {1, "0.0.0-other"}])

  # A machine announces strings, each once, but the wire may carry anything.
  defp addresses do
    frequency([
      {6, resize(3, list(oneof(["10.0.0.1:4370", "10.0.0.2:5000", "10.0.0.2", 3])))},
      {1, "10.0.0.1"}
    ])
  end

  # Entries as a member gossips them: newer than anything this machine has seen, or,
  # for machines it knows, older than what it has; now and then an entry for this
  # machine itself (or a copy of what it says of itself), or one that is not an entry at
  # all.
  defp gossip_entries(state) do
    resize(
      3,
      list(
        let {id, kind, fp, label, addresses} <-
              {oneof([state.own | @ids]),
               oneof([:admitted, :removed, :stale_admitted, :stale_removed, :malformed, :echo]),
               oneof(@fingerprints), label(), addresses()} do
          # An entry older than what this machine knows needs one it knows.
          stale? = kind in [:stale_admitted, :stale_removed]
          kind = if stale? and not Map.has_key?(state.members, id), do: :admitted, else: kind
          kind = if kind == :echo and id != state.own, do: :admitted, else: kind

          {id, kind, %{fp: fp, label: label, addresses: addresses}}
        end
      )
    )
  end

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :admit, [id, fp, label, addresses, version]}) do
    if admissible?(state, id, fp, version),
      do: put_member(state, id, fp, label, addresses, true),
      else: state
  end

  def next_state(state, _result, {:call, _, :remove, [id]}) do
    if id != state.own and member?(state, id),
      do: drop(put_in(state.members[id].member, false), id),
      else: state
  end

  def next_state(state, _result, {:call, _, :gossip, [entries]}) do
    Enum.reduce(Map.new(entries, fn {id, kind, f} -> {id, {kind, f}} end), state, fn
      {id, _}, state when id == state.own ->
        state

      {id, {:admitted, f}}, state ->
        put_member(state, id, f.fp, f.label, f.addresses, true)

      {id, {:removed, f}}, state ->
        drop(put_member(state, id, f.fp, f.label, f.addresses, false), id)

      # Older than what this machine knows, and what is not an entry, change nothing.
      _, state ->
        state
    end)
  end

  def next_state(state, _result, {:call, _, :nodeup, [id]}) do
    if member?(state, id), do: update_in(state.connected, &MapSet.put(&1, id)), else: state
  end

  def next_state(state, _result, {:call, _, :version_changed, []}),
    do: %{state | connected: MapSet.new()}

  def next_state(state, _result, _call), do: state

  defp admissible?(state, id, fp, version) do
    id != state.own and id != "Bad_id" and fp in @fingerprints and version == :current
  end

  defp put_member(state, id, fp, label, addresses, member) do
    entry = %{
      fp: fp,
      label: if(is_binary(label), do: label),
      addresses:
        if(is_list(addresses),
          do: addresses |> Enum.filter(&is_binary/1) |> Enum.uniq(),
          else: []
        ),
      member: member
    }

    put_in(state.members[id], entry)
  end

  defp drop(state, id), do: update_in(state.connected, &MapSet.delete(&1, id))
  defp member?(state, id), do: match?(%{member: true}, state.members[id])

  def postcondition(state, {:call, _, :admit, [id, fp, _, _, version]} = call, {result, seen}) do
    next = next_state(state, result, call)

    answer =
      cond do
        not admissible?(state, id, fp, :current) ->
          result == {:error, :invalid_member}

        version != :current ->
          match?({:error, {:other_version, "0.0.0-other", _}}, result)

        true ->
          match?({:ok, %{"id" => own, "members" => _}} when own == state.own, result) and
            view(state, elem(result, 1)["members"]) == next.members
      end

    answer and observed?(state, next, seen)
  end

  def postcondition(state, {:call, _, :remove, [id]} = call, {result, seen}) do
    expected =
      cond do
        id == state.own -> {:error, :cannot_remove_self}
        member?(state, id) -> :ok
        true -> {:error, :not_a_member}
      end

    result == expected and observed?(state, next_state(state, result, call), seen)
  end

  def postcondition(state, {:call, _, :nodeup, [id]} = call, {result, seen}) do
    next = next_state(state, result, call)
    mc = Cluster.mc_name(id)

    # A member that connects is sent the table; anyone else is cut off unanswered.
    told = for {^mc, {:merge, table}} <- seen.sent, do: view(state, table)

    told_ok =
      if member?(state, id), do: told != [] and List.last(told) == next.members, else: told == []

    told_ok and observed?(state, next, seen)
  end

  # The gossip timer: the table to every connected member, and to no one else.
  def postcondition(state, {:call, _, :tick, []}, {_result, seen}) do
    told = for {mc, {:merge, _}} <- seen.sent, do: mc

    Enum.sort(told) == Enum.sort(Enum.map(state.connected, &Cluster.mc_name/1)) and
      observed?(state, state, seen)
  end

  def postcondition(state, {:call, _, :peers, []}, {result, seen}) do
    expected = for {id, %{member: true} = m} <- state.members, do: {id, m.addresses}
    Enum.sort(result) == Enum.sort(expected) and observed?(state, state, seen)
  end

  def postcondition(state, {:call, _, :status, []}, {result, seen}) do
    expected =
      for {id, %{member: true} = m} <- state.members do
        %{
          "id" => id,
          "label" => m.label || id,
          "addresses" => m.addresses,
          "connected" => id in state.connected
        }
      end

    got = for m <- result["members"], do: Map.delete(m, "version")

    result["clustered"] == true and result["id"] == state.own and
      Enum.sort_by(got, & &1["id"]) == Enum.sort_by(expected, & &1["id"]) and
      observed?(state, state, seen)
  end

  # A member's copy of this machine's entry, newer than its own, has its own entry
  # stamped after it, so the copy does not hide what this machine says of itself. A copy
  # that says the same lends its time, so the next change is stamped after it too.
  def postcondition(state, {:call, _, :gossip, [entries]} = call, {newer, seen}) do
    kind = Map.new(entries, &{elem(&1, 0), elem(&1, 1)})[state.own]

    (kind not in [:admitted, :removed] or seen.own_updated > newer) and
      (kind != :echo or seen.own_updated >= newer) and
      observed?(state, next_state(state, newer, call), seen)
  end

  def postcondition(state, call, {result, seen}),
    do: observed?(state, next_state(state, result, call), seen)

  # What holds after every command: the pins are exactly the members' certificates and
  # this machine's, only members stay connected, and whatever table went out to a
  # member is the one the model has, never one from before the change.
  defp observed?(state, next, seen) do
    pins = for {_, %{member: true, fp: fp}} <- next.members, into: MapSet.new([seen.fp]), do: fp
    connected = MapSet.new(next.connected, &Cluster.mc_name/1)
    tables = for {_mc, {:merge, table}} <- seen.sent, do: view(state, table)
    changed? = next.members != state.members

    told =
      for {mc, {:merge, _}} <- seen.sent, into: MapSet.new(), do: mc

    seen.pins == pins and MapSet.new(seen.connected) == connected and
      Enum.all?(tables, &(&1 == next.members)) and
      (not changed? or MapSet.subset?(connected, told))
  end

  # A gossiped table as the model holds it: the other machines' entries.
  defp view(state, table) do
    for {id, entry} <- table, id != state.own, into: %{} do
      {id,
       %{
         fp: entry["fingerprint"],
         label: entry["label"],
         addresses: entry["addresses"],
         member: Cluster.member?(entry)
       }}
    end
  end

  # --- commands ---------------------------------------------------------------

  def admit(id, fp, label, addresses, version) do
    version = if version == :current, do: HalC2.Upgrade.version(), else: version

    entry = %{
      "id" => id,
      "fingerprint" => fp,
      "label" => label,
      "addresses" => addresses,
      "version" => version
    }

    observe(Cluster.admit(entry))
  end

  def remove(id), do: observe(Cluster.remove(id))

  def gossip(entries) do
    %{members: members, id: own} = :sys.get_state(Cluster)

    seen =
      for {_, entry} <- members,
          time <- [entry["admittedAt"], entry["removedAt"], entry["updatedAt"]],
          is_integer(time),
          reduce: 0,
          do: (latest -> max(latest, time))

    # A member whose clock runs an hour ahead.
    newer = max(System.os_time(:millisecond), seen) + 3_600_000

    incoming =
      Map.new(entries, fn {id, kind, f} ->
        fields = %{"fingerprint" => f.fp, "label" => f.label, "addresses" => f.addresses}

        entry =
          case kind do
            :admitted -> %{"admittedAt" => newer, "removedAt" => nil, "updatedAt" => newer}
            :removed -> %{"admittedAt" => 1, "removedAt" => newer, "updatedAt" => newer}
            :stale_admitted -> %{"admittedAt" => 1, "removedAt" => nil, "updatedAt" => 1}
            :stale_removed -> %{"admittedAt" => 1, "removedAt" => 2, "updatedAt" => 2}
            :malformed -> %{"admittedAt" => "yesterday"}
            :echo -> %{members[own] | "admittedAt" => newer, "updatedAt" => newer}
          end

        {id, Map.merge(fields, entry)}
      end)

    GenServer.cast(Cluster, {:merge, incoming})
    observe(newer)
  end

  def nodeup(id) do
    mc = Cluster.mc_name(id)
    ClusterTransport.connect(mc)
    send(Process.whereis(Cluster), {:nodeup, mc})
    observe(:ok)
  end

  def tick do
    send(Process.whereis(Cluster), :gossip)
    observe(:ok)
  end

  def peers, do: observe(Cluster.peers())
  def status, do: observe(Cluster.status())

  def version_changed do
    Cluster.version_changed()
    observe(:ok)
  end

  def restart do
    HalC2.Prop.restart_service(Cluster)
    observe(:ok)
  end

  # Syncs with the cluster process, so everything it sent is in the mailbox.
  defp observe(result) do
    fp = GenServer.call(Cluster, :fingerprint)
    pins = for {{:pin, fp}, true} <- :ets.match_object(Cluster, {{:pin, :_}, :_}), do: fp

    own = :sys.get_state(Cluster).members[HalC2.Environment.id()]

    {result,
     %{
       sent: drain(),
       pins: MapSet.new(pins),
       connected: ClusterTransport.connected(),
       fp: fp,
       own_updated: own["updatedAt"]
     }}
  end

  defp drain do
    receive do
      {:cluster_sent, mc, message} -> [{mc, message} | drain()]
    after
      0 -> []
    end
  end

  # --- discovery scheduling ---------------------------------------------------

  defmodule Scheduling do
    @moduledoc false
    # The discovery's attempts as the model sees them: whether one runs and whether
    # one more is due after it.

    use PropCheck
    use PropCheck.StateM

    alias HalC2.Cluster.Discovery

    def initial_state, do: %{running: true, again: false}

    def command(state) do
      frequency(
        [
          {4, {:call, __MODULE__, :poll, []}},
          {1, {:call, __MODULE__, :restart, []}}
        ] ++
          if(state.running,
            do: [{5, {:call, __MODULE__, :finish, [oneof([:ok, :crash])]}}],
            else: []
          )
      )
    end

    def precondition(state, {:call, _, :finish, _}), do: state.running
    def precondition(_state, _call), do: true

    def next_state(state, _result, {:call, _, :poll, []}),
      do: if(state.running, do: %{state | again: true}, else: %{state | running: true})

    def next_state(state, _result, {:call, _, :finish, [_]}),
      do: %{running: state.again, again: false}

    def next_state(_state, _result, {:call, _, :restart, []}),
      do: %{running: true, again: false}

    def postcondition(state, call, discovery) do
      next = next_state(state, nil, call)

      # Idle, it has the next attempt scheduled; running, nothing else is.
      discovery != nil and discovery.task != nil == next.running and
        discovery.again == next.again and
        discovery.timer != nil == not next.running
    end

    def poll do
      running? = :sys.get_state(Discovery).task != nil
      Discovery.poll()
      if not running?, do: await_attempt()
      settle()
    end

    def finish(how) do
      attempt = Process.get(:attempt)
      ref = Process.monitor(attempt)
      send(attempt, {:release, how})
      receive do: ({:DOWN, ^ref, :process, ^attempt, _} -> :ok)
      # The attempt's end, then the poll it may have sent itself.
      _ = :sys.get_state(Discovery)
      if :sys.get_state(Discovery).task != nil, do: await_attempt()
      settle()
    end

    def restart do
      attempt = Process.get(:attempt)
      ref = attempt && Process.monitor(attempt)
      HalC2.Prop.restart_service(Discovery)
      if ref, do: receive(do: ({:DOWN, ^ref, :process, ^attempt, _} -> :ok))
      await_attempt()
      settle()
    end

    def await_attempt do
      receive do
        {:attempt, pid} -> Process.put(:attempt, pid)
      after
        # A failsafe, not a wait: the attempt announces itself as it starts.
        5_000 -> Process.put(:attempt, nil)
      end
    end

    defp settle do
      if Process.whereis(Discovery), do: :sys.get_state(Discovery)
    end
  end

  property "discovery runs one attempt at a time and never stops looking",
    numtests: HalC2.Prop.numtests(100),
    max_size: 30 do
    Application.put_env(:hal_c2, :cluster_poll_interval, :timer.hours(1))

    forall cmds <- commands(Scheduling) do
      trap_exit do
        test = self()
        started = :ets.new(:attempts, [:public])

        # Each attempt says whether another is still alive as it starts.
        attempt = fn ->
          others = for {pid} <- :ets.tab2list(started), Process.alive?(pid), do: pid
          if others != [], do: send(test, :overlap)
          :ets.insert(started, {self()})
          send(test, {:attempt, self()})

          receive do
            {:release, :crash} -> exit(:boom)
            {:release, :ok} -> :ok
          end
        end

        Process.delete(:attempt)
        HalC2.Prop.start_services([{Discovery, attempt: attempt}])
        Scheduling.await_attempt()
        {history, state, result} = run_commands(Scheduling, cmds)
        HalC2.Prop.stop_services()

        overlap? =
          receive do
            :overlap -> true
          after
            0 -> false
          end

        flush_attempts()

        (result == :ok and not overlap?)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, {result, overlap?})))
        |> aggregate(command_names(cmds))
      end
    end
  end

  defp flush_attempts do
    receive do
      {:attempt, _} -> flush_attempts()
    after
      0 -> :ok
    end
  end

  # --- merging entries ---------------------------------------------------------

  property "merged entries do not depend on the order, grouping or repetition of updates",
    numtests: HalC2.Prop.numtests(500) do
    forall updates <- vector(3, member_entry()) do
      table = fn entry -> Cluster.merge(%{}, %{"b" => entry}, "a") end
      merge = &Cluster.merge(&1, &2, "a")

      results =
        for [x, y, z] <- permutations(updates) do
          {merge.(merge.(table.(x), table.(y)), table.(z)),
           merge.(table.(x), merge.(table.(y), table.(z))),
           merge.(merge.(table.(x), table.(x)), merge.(table.(y), table.(z)))}
        end

      tables = Enum.flat_map(results, &Tuple.to_list/1)

      (length(Enum.uniq(tables)) == 1)
      |> when_fail(IO.inspect(Enum.uniq(tables)))
    end
  end

  defp permutations([]), do: [[]]
  defp permutations(list), do: for(x <- list, rest <- permutations(list -- [x]), do: [x | rest])

  # Entries for one machine, with times close enough that updates tie.
  defp member_entry do
    let {fp, label, addresses, admitted, removed, updated, version} <-
          {oneof(@fingerprints), oneof(["box", "laptop", nil]),
           oneof([["10.0.0.1:4370"], ["10.0.0.2:5000"]]), range(1, 3), oneof([nil, 2, 3]),
           range(1, 3), oneof(["1.0.0", "1.0.1"])} do
      %{
        "fingerprint" => fp,
        "label" => label,
        "addresses" => addresses,
        "admittedAt" => admitted,
        "removedAt" => removed,
        "updatedAt" => updated,
        "version" => version
      }
    end
  end

  # --- where a member is looked for -------------------------------------------

  property "a member is tried where it was, where it said, and at the cluster port there" do
    forall {last, addresses, reachable} <- {last(), resize(4, list(address())), reachable()} do
      if :ets.whereis(Cluster) == :undefined, do: :ets.new(Cluster, [:named_table, :public])
      host = Cluster.host("m1")
      if last, do: Epmd.put(host, elem(last, 0), elem(last, 1)), else: Epmd.forget(host)
      port = Cluster.dist_port()

      parsed =
        for address <- addresses,
            {:ok, ip} <- [
              address
              |> String.split(":")
              |> hd()
              |> to_charlist()
              |> :inet.parse_ipv4strict_address()
            ],
            port <- port_of(address, port),
            do: {ip, port}

      expected = Enum.uniq(List.wrap(last) ++ parsed ++ for({ip, _} <- parsed, do: {ip, port}))

      reach = fn mc ->
        at = Epmd.lookup(host)
        send(self(), {:tried, mc, at})
        at in reachable
      end

      reached = Discovery.connect("m1", addresses, reach)
      tried = tried()
      first = Enum.find(expected, &(&1 in reachable))
      mc = Cluster.mc_name("m1")

      (Enum.all?(tried, &match?({^mc, _}, &1)) and
         Enum.map(tried, &elem(&1, 1)) ==
           Enum.take(
             expected,
             if(first, do: Enum.find_index(expected, &(&1 == first)) + 1, else: length(expected))
           ) and
         reached == (first != nil) and
         Epmd.lookup(host) == (first || last))
      |> when_fail(
        IO.inspect(%{expected: expected, tried: tried, reached: reached, at: Epmd.lookup(host)})
      )
    end
  end

  defp port_of(address, port) do
    case String.split(address, ":") do
      [_] -> [port]
      [_, p] -> for {p, ""} <- [Integer.parse(p)], p in 1..65_535, do: p
      _ -> []
    end
  end

  defp tried do
    receive do
      {:tried, mc, at} -> [{mc, at} | tried()]
    after
      0 -> []
    end
  end

  defp ip, do: oneof([{10, 0, 0, 1}, {10, 0, 0, 2}, {10, 0, 0, 3}])
  defp port_number, do: oneof([4370, 5000, 6000])
  defp last, do: oneof([nil, {ip(), port_number()}])
  defp reachable, do: resize(3, list({ip(), port_number()}))

  # `host` or `host:port`, and now and then what is neither.
  defp address do
    frequency([
      {4, let({{a, b, c, d}, p} <- {ip(), port_number()}, do: "#{a}.#{b}.#{c}.#{d}:#{p}")},
      {2, let({a, b, c, d} <- ip(), do: "#{a}.#{b}.#{c}.#{d}")},
      {1, oneof(["10.0.0.1:0", "10.0.0.1:x", "a:b:c"])}
    ])
  end
end
