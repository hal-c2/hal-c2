defmodule HalC2.Test.OldMc do
  @moduledoc """
  A cluster member on the release before watched services took a ref: a peer whose
  `HalC2.PullRequests.Refreshes` exports only `subscribe/1` and `unsubscribe/1`, and
  sends its changes bare, as that release did. Nothing else of the MC runs there.

  The stub tells `observer` (`reset/2`) `{:old_mc_unsubscribed, pid}` for each
  unsubscribe it takes, so a test can wait on a socket letting go of it.
  """

  @stub ~S"""
  defmodule HalC2.PullRequests.Refreshes do
    use GenServer

    def subscribe(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})
    def unsubscribe(pid), do: GenServer.cast(__MODULE__, {:unsubscribe, pid})
    def bump, do: GenServer.cast(__MODULE__, :bump)
    def reset(observer), do: GenServer.call(__MODULE__, {:reset, observer})
    def watchers, do: GenServer.call(__MODULE__, :watchers)

    def init(observer), do: {:ok, %{revision: 0, watchers: %{}, observer: observer}}

    def handle_call({:subscribe, pid}, _from, state) do
      watchers = Map.put_new_lazy(state.watchers, pid, fn -> Process.monitor(pid) end)
      {:reply, {:ok, state.revision}, %{state | watchers: watchers}}
    end

    def handle_call({:reset, observer}, _from, state) do
      for {_, monitor} <- state.watchers, do: Process.demonitor(monitor, [:flush])
      {:reply, :ok, %{revision: 0, watchers: %{}, observer: observer}}
    end

    def handle_call(:watchers, _from, state), do: {:reply, Map.keys(state.watchers), state}

    def handle_cast({:unsubscribe, pid}, state) do
      {monitor, watchers} = Map.pop(state.watchers, pid)
      if monitor, do: Process.demonitor(monitor, [:flush])
      send(state.observer, {:old_mc_unsubscribed, pid})
      {:noreply, %{state | watchers: watchers}}
    end

    def handle_cast(:bump, state) do
      revision = state.revision + 1
      for {pid, _} <- state.watchers, do: send(pid, {:hal_c2_pull_request_refreshes, node(), revision})
      {:noreply, %{state | revision: revision}}
    end

    def handle_info({:DOWN, _, :process, pid, _}, state),
      do: {:noreply, %{state | watchers: Map.delete(state.watchers, pid)}}
  end
  """

  @doc """
  Starts the old member, linked to the caller, telling `observer`; answers
  `{peer, node}`. Starts distribution on 127.0.0.1 if this node has none.
  """
  def start(observer) do
    unless Node.alive?() do
      {_, 0} = System.cmd("epmd", ["-daemon"])
      name = :"hal_c2_old_mc_test#{System.unique_integer([:positive])}@127.0.0.1"
      {:ok, _} = :net_kernel.start(name, %{name_domain: :longnames})
    end

    {:ok, peer, node} =
      :peer.start_link(%{
        name: :"hal_c2_old_mc#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true,
        # Booting a BEAM with the whole code path is slow on a loaded machine.
        wait_boot: 60_000,
        args: Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
      })

    # Loaded before anything there asks for the module, so the current one never is.
    {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:elixir])
    [_] = :erpc.call(node, Code, :compile_string, [@stub])

    {:ok, _} =
      :erpc.call(node, GenServer, :start, [
        HalC2.PullRequests.Refreshes,
        observer,
        [name: HalC2.PullRequests.Refreshes]
      ])

    {peer, node}
  end

  @doc "Forgets every watcher and the revision; tells `observer` from now on."
  def reset(node, observer),
    do: :erpc.call(node, HalC2.PullRequests.Refreshes, :reset, [observer])

  @doc "Bumps the old member's revision; answers once it has told its watchers."
  def bump(node) do
    :erpc.call(node, HalC2.PullRequests.Refreshes, :bump, [])
    watchers(node)
  end

  @doc "The pids the old member tells its changes to."
  def watchers(node), do: :erpc.call(node, HalC2.PullRequests.Refreshes, :watchers, [])
end
