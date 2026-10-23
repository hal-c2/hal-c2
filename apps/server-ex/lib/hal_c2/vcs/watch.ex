defmodule HalC2.Vcs.Watch do
  @moduledoc """
  One checkout's status for the clients watching it (`subscribeVcsStatus`).

  A watcher starts with its first subscriber and stops with its last. Subscribers
  get `{:hal_c2_vcs, cwd, event}` messages shaped as `VcsStatusStreamEvent`, only when
  something changed. Local status is read again when told (`refresh/1`: a turn
  ended, a git action ran); remote status is fetched on the background activity
  settings' `automaticGitFetchInterval` (never at 0) while a client in front shows
  this checkout (`HalC2.BackgroundPolicy`). An MC without automatic actions
  (`HAL_C2_MC_NO_AUTO_ACTIONS`) only fetches when asked (`vcs.refreshStatus`).
  """

  use GenServer, restart: :temporary

  alias HalC2.Vcs

  @registry HalC2.Vcs.Registry
  @supervisor HalC2.Vcs.Supervisor

  @doc "Adds `pid` as a subscriber under `ref` (`HalC2.Watchers`); returns the snapshot event."
  def subscribe(cwd, pid, ref \\ nil) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, cwd}) do
      {:ok, watch} -> GenServer.call(watch, {:subscribe, pid, ref}, 30_000)
      {:error, {:already_started, watch}} -> GenServer.call(watch, {:subscribe, pid, ref}, 30_000)
    end
  end

  def unsubscribe(cwd, pid, ref \\ nil) do
    if watch = lookup(cwd), do: GenServer.cast(watch, {:unsubscribe, pid, ref})
    :ok
  end

  @doc "Reads the checkout's status again if anyone watches it."
  def refresh(cwd) do
    if watch = lookup(cwd), do: GenServer.cast(watch, :refresh)
    :ok
  end

  @doc "Hands freshly read status to the watcher, if any, to publish."
  def publish(cwd, local, remote) do
    if watch = lookup(cwd), do: GenServer.cast(watch, {:publish, local, remote})
    :ok
  end

  def start_link(cwd),
    do: GenServer.start_link(__MODULE__, cwd, name: {:via, Registry, {@registry, cwd}})

  # Nil also when the registry is not running (an MC started without watchers).
  defp lookup(cwd) do
    case Registry.lookup(@registry, cwd) do
      [{pid, _}] -> pid
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @impl true
  def init(cwd) do
    {:ok,
     %{
       cwd: cwd,
       subscribers: %{},
       local: Vcs.local_status(cwd),
       remote: Vcs.remote_status(cwd, pr: true),
       timer: schedule_fetch()
     }}
  end

  @impl true
  def handle_call({:subscribe, pid, ref}, _from, state) do
    subscribers = HalC2.Watchers.add(state.subscribers, pid, ref)

    {:reply, %{"_tag" => "snapshot", "local" => state.local, "remote" => state.remote},
     %{state | subscribers: subscribers}}
  end

  @impl true
  def handle_cast({:unsubscribe, pid, ref}, state) do
    case HalC2.Watchers.remove(state.subscribers, pid, ref) do
      same when same == state.subscribers -> {:noreply, state}
      subscribers -> stop_if_idle(%{state | subscribers: subscribers})
    end
  end

  # A local change keeps the pull request last looked up; the timer refreshes it.
  def handle_cast(:refresh, state) do
    remote =
      with %{} = remote <- Vcs.remote_status(state.cwd),
           do: Map.put(remote, "pr", state.remote && state.remote["pr"])

    {:noreply, update(state, Vcs.local_status(state.cwd), remote)}
  end

  def handle_cast({:publish, local, remote}, state), do: {:noreply, update(state, local, remote)}

  @impl true
  def handle_info(:fetch, state) do
    scope = %{"type" => "vcs-status", "cwd" => state.cwd}

    state =
      if Application.get_env(:hal_c2, :auto_actions, true) and
           HalC2.BackgroundPolicy.run_scope_work?(scope) do
        update(state, state.local, Vcs.remote_status(state.cwd, fetch: true, pr: true))
      else
        state
      end

    {:noreply, %{state | timer: schedule_fetch()}}
  end

  def handle_info(:fetch_off, state), do: {:noreply, %{state | timer: schedule_fetch()}}

  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    case HalC2.Watchers.down(state.subscribers, ref, pid) do
      same when same == state.subscribers -> {:noreply, state}
      subscribers -> stop_if_idle(%{state | subscribers: subscribers})
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp update(state, local, remote) do
    if local != state.local, do: broadcast(state, %{"_tag" => "localUpdated", "local" => local})

    if remote != state.remote,
      do: broadcast(state, %{"_tag" => "remoteUpdated", "remote" => remote})

    %{state | local: local, remote: remote}
  end

  defp broadcast(state, event) do
    HalC2.Watchers.notify(state.subscribers, {:hal_c2_vcs, state.cwd, event})
  end

  defp stop_if_idle(%{subscribers: subscribers} = state) when map_size(subscribers) == 0,
    do: {:stop, :normal, state}

  defp stop_if_idle(state), do: {:noreply, state}

  # Checked again every 30 s while fetching is off, so turning it on takes effect.
  # The timer is kept as `{message, ref}`: what fires next, and when.
  defp schedule_fetch do
    case HalC2.BackgroundPolicy.settings()["automaticGitFetchInterval"] do
      ms when is_integer(ms) and ms > 0 -> {:fetch, Process.send_after(self(), :fetch, ms)}
      _ -> {:fetch_off, Process.send_after(self(), :fetch_off, 30_000)}
    end
  end
end
