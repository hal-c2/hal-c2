defmodule HalC2.PullRequests.Refreshes do
  @moduledoc """
  A revision that moves whenever a pull request is changed or refreshed through this
  MC (`pullRequests.subscribeRefreshes`). Subscribers (`HalC2.Watchers`) get the
  current revision, then `{:hal_c2_pull_request_refreshes, mc, revision}` on every
  bump, and refetch what they show.
  """

  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Adds `pid`'s subscription `ref`; returns `{:ok, revision}`."
  def subscribe(pid, ref \\ nil), do: GenServer.call(__MODULE__, {:subscribe, pid, ref})

  def unsubscribe(pid, ref \\ nil), do: GenServer.cast(__MODULE__, {:unsubscribe, pid, ref})

  @doc "Tells every subscriber to read again."
  def bump, do: GenServer.cast(__MODULE__, :bump)

  @impl true
  def init(nil), do: {:ok, %{revision: 0, watchers: %{}}}

  @impl true
  def handle_call({:subscribe, pid, ref}, _from, state) do
    watchers = HalC2.Watchers.add(state.watchers, pid, ref)
    {:reply, {:ok, state.revision}, %{state | watchers: watchers}}
  end

  @impl true
  def handle_cast({:unsubscribe, pid, ref}, state) do
    watchers = HalC2.Watchers.remove(state.watchers, pid, ref)
    {:noreply, %{state | watchers: watchers}}
  end

  def handle_cast(:bump, state) do
    revision = state.revision + 1

    HalC2.Watchers.notify(state.watchers, {:hal_c2_pull_request_refreshes, node(), revision})

    {:noreply, %{state | revision: revision}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, %{state | watchers: Map.delete(state.watchers, pid)}}
end
