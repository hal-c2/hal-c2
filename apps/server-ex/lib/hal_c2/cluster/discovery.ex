defmodule HalC2.Cluster.Discovery do
  @moduledoc """
  Keeps this MC connected to every member of its cluster (`HalC2.Cluster`). Every ten
  seconds, and at once on `poll/0`, it tries each member it is not connected to: at the
  address that last reached it, then the addresses the member reported, then every
  address a strategy lists, and last each of those hosts at the cluster port, where a
  member that was elsewhere comes back once it can. A wrong address costs one failed
  handshake, since each MC's certificate and name are its own.

  A strategy is a module with `addresses/0`, listed in the `:cluster_strategies` config
  (`HalC2.Cluster.Tailscale` and `HalC2.Cluster.Static` unless set).
  """

  use GenServer

  alias HalC2.Cluster
  alias HalC2.Cluster.Epmd

  @doc "Addresses where members may be: `host` or `host:port` (the cluster port if none)."
  @callback addresses() :: [String.t()]

  @interval 10_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Looks for members now instead of at the next interval."
  def poll do
    if pid = Process.whereis(__MODULE__), do: send(pid, :poll)
    :ok
  end

  @impl true
  def init(nil) do
    send(self(), :poll)
    {:ok, %{task: nil, again: false, timer: nil}}
  end

  @impl true
  def handle_info(:poll, %{task: nil} = state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    {:noreply, %{state | task: Task.async(&connect_members/0), timer: nil}}
  end

  def handle_info(:poll, state), do: {:noreply, %{state | again: true}}

  def handle_info({ref, _result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{task: %Task{ref: ref}} = state),
    do: {:noreply, finish(state)}

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
      found = Enum.flat_map(strategies(), &strategy_addresses/1)

      missing
      |> Task.async_stream(fn {id, addresses} -> connect(id, addresses ++ found) end,
        timeout: :infinity,
        ordered: false
      )
      |> Stream.run()
    end
  end

  defp connect(id, addresses) do
    host = Cluster.host(id)
    last = Epmd.lookup(host)
    resolved = Enum.flat_map(addresses, &resolve/1)
    port = Cluster.dist_port()

    candidates =
      Enum.uniq(List.wrap(last) ++ resolved ++ for({ip, _} <- resolved, do: {ip, port}))

    reached =
      Enum.any?(candidates, fn {ip, port} ->
        Epmd.put(host, ip, port)
        Node.connect(Cluster.mc_name(id)) == true
      end)

    # Keep the address that last worked rather than the last one tried.
    with false <- reached, {ip, port} <- last, do: Epmd.put(host, ip, port)
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
