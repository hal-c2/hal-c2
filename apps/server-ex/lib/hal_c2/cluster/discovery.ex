defmodule HalC2.Cluster.Discovery do
  @moduledoc """
  Keeps this MC connected to every member of its cluster (`HalC2.Cluster`). Every ten
  seconds, and at once on `poll/0`, it tries each member it is not connected to: at the
  address that last reached it, then the addresses the member reported, then every
  address a strategy lists, and last each of those hosts at the cluster port, where a
  member that was elsewhere comes back once it can. A wrong address costs one failed
  handshake, since each MC's certificate and name are its own.

  A strategy is a module with `addresses/0`, listed in the `:cluster_strategies` config
  (`HalC2.Cluster.Tailscale` and `HalC2.Cluster.Static` unless set). Each has five
  seconds to answer, and the strategies are asked at once.

  One attempt runs at a time, in a task, so this process never waits on the network:
  a `poll/0` during an attempt makes one more right after it, however many came, and
  an attempt that crashes only ends early.

  A member no attempt has reached for five minutes (`:cluster_give_up_after`) is
  offline: it is tried only every five minutes (`:cluster_offline_interval`) from then
  on, until it is reached or `reconnect/1` asks for it. Clients see it through
  `HalC2.Shell.link/2` as a machine that stopped trying.
  """

  use GenServer

  alias HalC2.Cluster
  alias HalC2.Cluster.Epmd

  @doc "Addresses where members may be: `host` or `host:port` (the cluster port if none)."
  @callback addresses() :: [String.t()]

  @interval 10_000
  @give_up_after 300_000
  @offline_interval 300_000
  @strategy_timeout 5_000

  @doc """
  Starts the discovery. `attempt:` replaces what one attempt does (connecting the
  members), for tests that drive the scheduling without a network. It is given the
  ids to leave out (offline members between their rare tries) when it takes one
  argument, and may return `%{id => reached?}` for the members it looked at.
  """
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Looks for members now instead of at the next interval."
  def poll do
    if pid = Process.whereis(__MODULE__), do: send(pid, :poll)
    :ok
  end

  @doc "The ids of the members that are offline: discovery stopped trying them often."
  def offline do
    GenServer.call(__MODULE__, :offline)
  catch
    :exit, _ -> []
  end

  @doc """
  Tries the member `id` again at once and often, as if it had never failed. An
  offline member is no longer said to be, until attempts fail for long again.
  """
  def reconnect(id) do
    GenServer.call(__MODULE__, {:reconnect, id})
  catch
    :exit, _ -> :ok
  end

  @doc """
  Takes in what an attempt at `now` found, `%{id => true | false | :skipped}` for every
  member, into `failing` (`%{id => first failure}`): a reached member is cleared, a
  missed one keeps the time it first failed, a skipped one is kept as it was, and one
  no longer listed is no longer a member.
  """
  def settle(failing, results, now) do
    Enum.reduce(results, Map.take(failing, Map.keys(results)), fn
      {id, true}, acc -> Map.delete(acc, id)
      {_id, :skipped}, acc -> acc
      {id, _missed}, acc -> Map.put_new(acc, id, now)
    end)
  end

  @doc "The members of `failing` that have failed for `give_up` ms or longer at `now`."
  def offline(failing, now, give_up),
    do: for({id, since} <- failing, now - since >= give_up, into: MapSet.new(), do: id)

  @impl true
  def init(opts) do
    # An attempt that crashes must not take the discovery down with it: restarted, it
    # would poll at once and crash again on whatever broke the last attempt.
    Process.flag(:trap_exit, true)
    send(self(), :poll)
    attempt = Keyword.get(opts, :attempt, &connect_members/1)

    {:ok,
     %{
       task: nil,
       again: false,
       timer: nil,
       attempt: attempt,
       failing: %{},
       offline: MapSet.new(),
       tried_offline: nil
     }}
  end

  @impl true
  def handle_call(:offline, _from, state), do: {:reply, MapSet.to_list(state.offline), state}

  def handle_call({:reconnect, id}, _from, state) do
    state = tell(%{state | failing: Map.delete(state.failing, id)})
    send(self(), :poll)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:poll, %{task: nil} = state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    now = now()
    rare = setting(:cluster_offline_interval, @offline_interval)

    {skip, tried} =
      if state.tried_offline == nil or now - state.tried_offline >= rare,
        do: {MapSet.new(), now},
        else: {state.offline, state.tried_offline}

    attempt =
      if is_function(state.attempt, 1),
        do: fn -> state.attempt.(skip) end,
        else: state.attempt

    {:noreply, %{state | task: Task.async(attempt), timer: nil, tried_offline: tried}}
  end

  def handle_info(:poll, state), do: {:noreply, %{state | again: true}}

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    failing = if is_map(result), do: settle(state.failing, result, now()), else: state.failing
    {:noreply, finish(tell(%{state | failing: failing}))}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{task: %Task{ref: ref}} = state),
    do: {:noreply, finish(state)}

  # The exit of an attempt, which its monitor already reported.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  defp finish(state) do
    if state.again, do: send(self(), :poll)
    interval = setting(:cluster_poll_interval, @interval)
    %{state | task: nil, again: false, timer: Process.send_after(self(), :poll, interval)}
  end

  # Tells clients of each member that went offline or stopped being so.
  defp tell(state) do
    offline = offline(state.failing, now(), setting(:cluster_give_up_after, @give_up_after))
    for id <- MapSet.difference(offline, state.offline), do: HalC2.Shell.link(id, false)
    for id <- MapSet.difference(state.offline, offline), do: HalC2.Shell.link(id, true)
    %{state | offline: offline}
  end

  defp setting(key, default), do: Application.get_env(:hal_c2, key, default)

  defp now, do: System.monotonic_time(:millisecond)

  # Every member and whether it is connected after the attempt (`settle/3`): the
  # members that are not, except those in `skip`, are tried.
  defp connect_members(skip) do
    connected = Node.list()
    peers = Cluster.peers()

    known =
      for {id, _} <- peers, into: %{} do
        cond do
          Cluster.mc_name(id) in connected -> {id, true}
          id in skip -> {id, :skipped}
          true -> {id, false}
        end
      end

    missing = for {id, addresses} <- peers, known[id] == false, do: {id, addresses}

    if missing == [] do
      known
    else
      found =
        strategies()
        |> Task.async_stream(&strategy_addresses/1,
          timeout: @strategy_timeout,
          on_timeout: :kill_task
        )
        |> Enum.flat_map(fn
          {:ok, addresses} -> addresses
          {:exit, _timeout} -> []
        end)

      missing
      |> Task.async_stream(fn {id, addresses} -> {id, connect(id, addresses ++ found)} end,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.reduce(known, fn
        {:ok, {id, reached}}, acc -> Map.put(acc, id, reached)
        {:exit, _}, acc -> acc
      end)
    end
  end

  @doc """
  Tries to reach the member `id` at each of `candidates/3` in turn with `reach`
  (`Node.connect/1` but in tests) and returns whether one did. Afterwards the port
  mapper holds the address that reached it, or else the one it held before.
  """
  def connect(id, addresses, reach \\ &Node.connect/1) do
    host = Cluster.host(id)
    last = Epmd.lookup(host)
    mc = Cluster.mc_name(id)

    reached =
      Enum.any?(candidates(last, addresses, Cluster.dist_port()), fn {ip, port} ->
        Epmd.put(host, ip, port)
        reach.(mc) == true
      end)

    # Keep the address that last worked rather than the last one tried.
    case {reached, last} do
      {true, _} -> :ok
      {false, {ip, port}} -> Epmd.put(host, ip, port)
      {false, nil} -> Epmd.forget(host)
    end

    reached
  end

  @doc """
  Where to look for a member, in order and each once: the address that last reached
  it, the `addresses` known for it, and then each of their hosts at the cluster
  `port`, where a member that moved there is found again.
  """
  def candidates(last, addresses, port) do
    resolved = Enum.flat_map(addresses, &resolve/1)
    Enum.uniq(List.wrap(last) ++ resolved ++ for({ip, _} <- resolved, do: {ip, port}))
  end

  defp strategies,
    do:
      Application.get_env(:hal_c2, :cluster_strategies, [
        HalC2.Cluster.Tailscale,
        HalC2.Cluster.Static
      ])

  defp strategy_addresses(strategy) do
    strategy.addresses()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc "The IPv4 address and port of `host` or `host:port`, resolved, or none."
  @spec resolve(String.t()) :: [{:inet.ip4_address(), :inet.port_number()}]
  def resolve(address) do
    with {host, port} <- split(address),
         {:ok, ip} <- :inet.getaddr(to_charlist(host), :inet) do
      [{ip, port}]
    else
      _ -> []
    end
  end

  defp split(address) do
    case String.split(address, ":") do
      [host] ->
        {host, Cluster.dist_port()}

      [host, port] ->
        case Integer.parse(port) do
          {port, ""} when port in 1..65_535 -> {host, port}
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
