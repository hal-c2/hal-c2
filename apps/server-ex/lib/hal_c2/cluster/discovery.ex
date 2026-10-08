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
  """

  use GenServer

  alias HalC2.Cluster
  alias HalC2.Cluster.Epmd

  @doc "Addresses where members may be: `host` or `host:port` (the cluster port if none)."
  @callback addresses() :: [String.t()]

  @interval 10_000
  @strategy_timeout 5_000

  @doc """
  Starts the discovery. `attempt:` replaces what one attempt does (connecting the
  members), for tests that drive the scheduling without a network.
  """
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Looks for members now instead of at the next interval."
  def poll do
    if pid = Process.whereis(__MODULE__), do: send(pid, :poll)
    :ok
  end

  @impl true
  def init(opts) do
    # An attempt that crashes must not take the discovery down with it: restarted, it
    # would poll at once and crash again on whatever broke the last attempt.
    Process.flag(:trap_exit, true)
    send(self(), :poll)
    attempt = Keyword.get(opts, :attempt, &connect_members/0)
    {:ok, %{task: nil, again: false, timer: nil, attempt: attempt}}
  end

  @impl true
  def handle_info(:poll, %{task: nil} = state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    {:noreply, %{state | task: Task.async(state.attempt), timer: nil}}
  end

  def handle_info(:poll, state), do: {:noreply, %{state | again: true}}

  def handle_info({ref, _result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{task: %Task{ref: ref}} = state),
    do: {:noreply, finish(state)}

  # The exit of an attempt, which its monitor already reported.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  defp finish(state) do
    if state.again, do: send(self(), :poll)
    interval = Application.get_env(:hal_c2, :cluster_poll_interval, @interval)
    %{state | task: nil, again: false, timer: Process.send_after(self(), :poll, interval)}
  end

  defp connect_members do
    connected = Node.list()

    missing =
      for {id, addresses} <- Cluster.peers(),
          Cluster.mc_name(id) not in connected,
          do: {id, addresses}

    if missing != [] do
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
      |> Task.async_stream(fn {id, addresses} -> connect(id, addresses ++ found) end,
        timeout: :infinity,
        ordered: false
      )
      |> Stream.run()
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
