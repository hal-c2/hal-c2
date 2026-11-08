defmodule HalC2.Vcs.Watch do
  @moduledoc """
  One checkout's status for the clients watching it (`subscribeVcsStatus`).

  A watcher starts with its first subscriber and stops with its last. Subscribers
  get `{:hal_c2_vcs, cwd, event}` messages shaped as `VcsStatusStreamEvent`, only when
  something changed. Local status is read again when told (`refresh/1`: a turn
  ended, a git action ran); remote status is fetched on the background activity
  settings' `automaticGitFetchInterval` (never at 0) while a client in front shows
  this checkout (`HalC2.BackgroundPolicy`), and a clean checkout of its default branch
  that fell behind is fast-forwarded when the project says `defaultAutoPull`. An MC
  without automatic actions
  (`HAL_C2_MC_NO_AUTO_ACTIONS`) only fetches when asked (`vcs.refreshStatus`).
  """

  use GenServer, restart: :temporary

  alias HalC2.Git
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

  @doc """
  Reads the checkout's status again if anyone watches it. Whatever changed the checkout
  (a branch switched, a pull, a turn) may have changed the files Space pages are of, so
  they look again too (`HalC2.Space.Files`).
  """
  def refresh(cwd) do
    HalC2.Space.Files.changed(cwd)
    if watch = lookup(cwd), do: GenServer.cast(watch, :refresh)
    :ok
  end

  @doc """
  A turn in `cwd` ended: like `refresh/1`, and the branch's pull request is looked up
  again at once (someone may have opened one meanwhile), unless the checkout is on no
  branch or background work is paused for it.
  """
  def turn_ended(cwd) do
    HalC2.Space.Files.changed(cwd)
    if watch = lookup(cwd), do: GenServer.cast(watch, :turn_ended)
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
       timer: schedule_fetch(),
       pr_branch: Git.current_branch(cwd),
       lookup: nil
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

  # A local change keeps the pull request last looked up while the checkout stays on the
  # branch it was looked up for (`pr_branch`); the timer refreshes it.
  def handle_cast(:refresh, state) do
    branch = Git.current_branch(state.cwd)

    remote =
      with %{} = remote <- Vcs.remote_status(state.cwd) do
        pr = if branch == state.pr_branch, do: state.remote && state.remote["pr"]
        Map.put(remote, "pr", pr)
      end

    {:noreply, update(%{state | pr_branch: branch}, read_local(state), remote)}
  end

  # A turn's end looks the pull request up afresh, off this process so subscribers are not
  # held behind the host; turns ending meanwhile share the lookup that follows it.
  def handle_cast(:turn_ended, state) do
    {:noreply, state} = handle_cast(:refresh, state)
    scope = %{"type" => "vcs-status", "cwd" => state.cwd}

    cond do
      is_nil(state.pr_branch) or not HalC2.BackgroundPolicy.run_scope_work?(scope) ->
        {:noreply, state}

      state.lookup ->
        {:noreply, %{state | lookup: put_elem(state.lookup, 1, true)}}

      true ->
        {:noreply, start_lookup(state)}
    end
  end

  # Only the pull request is the lookup's: counts a refresh published meanwhile stay.
  def handle_cast({:pr_found, branch, found}, %{pr_branch: branch} = state) do
    remote = Map.put(state.remote || found, "pr", found["pr"])
    {:noreply, update(state, state.local, remote)}
  end

  def handle_cast({:pr_found, _other_branch, _remote}, state), do: {:noreply, state}

  def handle_cast({:publish, local, remote}, state), do: {:noreply, update(state, local, remote)}

  @impl true
  def handle_info(:fetch, state) do
    scope = %{"type" => "vcs-status", "cwd" => state.cwd}

    state =
      if Application.get_env(:hal_c2, :auto_actions, true) and
           HalC2.BackgroundPolicy.run_scope_work?(scope) do
        remote = Vcs.remote_status(state.cwd, fetch: true, pr: true)
        remote = maybe_auto_pull(state, remote)

        update(%{state | pr_branch: Git.current_branch(state.cwd)}, state.local, remote)
      else
        state
      end

    {:noreply, %{state | timer: schedule_fetch()}}
  end

  def handle_info(:fetch_off, state), do: {:noreply, %{state | timer: schedule_fetch()}}

  def handle_info({:DOWN, ref, :process, _pid, _}, %{lookup: {ref, again?, _}} = state) do
    state = %{state | lookup: nil}
    {:noreply, if(again?, do: start_lookup(state), else: state)}
  end

  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    case HalC2.Watchers.down(state.subscribers, ref, pid) do
      same when same == state.subscribers -> {:noreply, state}
      subscribers -> stop_if_idle(%{state | subscribers: subscribers})
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # A watched checkout that fell behind is fast-forwarded when its project says
  # `defaultAutoPull` and it is safe: on its default branch, clean, with nothing of its
  # own to push (the same rule as `HalC2.Projects.auto_pull/0` at boot).
  defp maybe_auto_pull(state, remote) do
    with %{"isRepo" => true, "isDefaultRef" => true, "hasWorkingTreeChanges" => false} <-
           Vcs.local_status(state.cwd),
         %{"hasUpstream" => true, "aheadCount" => 0, "behindCount" => behind} when behind > 0 <-
           remote,
         id when is_binary(id) <- HalC2.Projects.at(state.cwd),
         true <- HalC2.Settings.for_project(id)["defaultAutoPull"] == true,
         pulled <- Vcs.pull(%{"cwd" => state.cwd}) do
      case pulled do
        {:error, error} ->
          require Logger
          Logger.warning("automatic pull of #{state.cwd} failed: #{inspect(error)}")
          remote

        # The pre-pull status is stale (still behind): read the repository again.
        _ ->
          Vcs.remote_status(state.cwd, pr: true) || remote
      end
    else
      _ -> remote
    end
  end

  defp start_lookup(state) do
    watcher = self()
    {cwd, branch} = {state.cwd, state.pr_branch}

    {pid, ref} =
      spawn_monitor(fn ->
        if remote = Vcs.remote_status(cwd, pr: :fresh),
          do: GenServer.cast(watcher, {:pr_found, branch, remote})
      end)

    %{state | lookup: {ref, false, pid}}
  end

  # A status git cannot give right now (the index is locked) leaves the last one standing.
  defp read_local(state) do
    case Vcs.read_status(state.cwd) do
      {:ok, local} -> local
      {:error, _} -> state.local
    end
  end

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
