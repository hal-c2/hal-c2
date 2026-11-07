defmodule HalC2.WorktreeSetup do
  @moduledoc """
  Preparing a new thread's git worktree before its first turn (`subscribeWorktreeSetup`,
  `worktreeSetup.cancel`, `worktreeSetup.retry`).

  A thread launched with the `worktree` strategy gets a `preparing` run; a worker then
  fetches the base branch when asked, adds the worktree on a temporary
  `hal-c2/<hex>` branch (`temporary_branch/2`, renamed in the background from the
  first message), fills
  its submodules, runs the project's setup script in a terminal, and releases the run
  (`HalC2.Orchestration.release_prepared/2`). Its progress is a `WorktreeSetupSnapshot`
  that subscribers get on every change. Until the agent starts the setup can be
  cancelled, which removes the worktree and cancels the run. One that failed before the
  agent can be retried: the same run goes on from the worktree, if it got that far.

  Snapshots live in memory: after a restart a thread shows no setup. A finished one stays
  readable for half a minute, so a late subscriber sees how it ended, then goes. One that
  can be retried stays until the retry, or until the thread goes on without it.
  """

  use GenServer

  require Logger

  alias HalC2.Orchestration

  # A `submodules` stage joins after `checkout` when the worktree has submodules.
  @stages ~w(fetch checkout setup-script agent)
  @tail_lines 5
  # What a client is shown (packages/contracts/src/worktreeSetup.ts) and what a script
  # that never ends a line can make the worker hold.
  @line_max 400
  @detail_max 200
  @error_max 1_000
  @partial_max 4_096
  @retention 30_000
  # How long a shell's startup may take before the script has begun. A script that has
  # begun may take as long as it likes.
  @start_timeout 60_000
  # Colours, cursor movement and titles, then whatever control characters are left.
  @terminal_control ~r/\e\[[0-9;?]*[ -\/]*[@-~]|\e\][^\a\e]*(?:\a|\e\\)|\e[()][A-Za-z0-9]|\e[=>]/
  @stray_control ~r/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/
  @untrusted "the checkout's setup script was not run; import or save the setup action under Settings → Project → Actions first"

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  # --- API -------------------------------------------------------------------------

  @doc """
  Starts preparing `thread_id`'s worktree for its `run_id`; `strategy` is the
  launch's `worktree` workspace strategy.
  """
  def start(thread_id, run_id, project, strategy, message_text) do
    GenServer.call(__MODULE__, {:start, thread_id, run_id, project, strategy, message_text})
  end

  @doc """
  Adds `pid` as a subscriber under `ref` (`HalC2.Watchers`); returns the snapshot, or nil
  when none is tracked.
  """
  def subscribe(thread_id, pid, ref \\ nil),
    do: GenServer.call(__MODULE__, {:subscribe, thread_id, pid, ref})

  def unsubscribe(thread_id, pid, ref \\ nil),
    do: GenServer.cast(__MODULE__, {:unsubscribe, thread_id, pid, ref})

  @doc "`worktreeSetup.cancel`: stops a setup that has not handed off to the agent."
  def cancel(%{"threadId" => thread_id}),
    do:
      {:ok,
       %{
         "cancelled" =>
           GenServer.call(__MODULE__, {:cancel, thread_id}, HalC2.Vcs.worktree_timeout() + 60_000)
       }}

  @doc """
  `worktreeSetup.retry`: runs again a setup that failed before the agent started, in the
  worktree it made. A thread that has gone on without it cannot.
  """
  def retry(%{"threadId" => thread_id}),
    do: {:ok, %{"retried" => GenServer.call(__MODULE__, {:retry, thread_id})}}

  @doc """
  The thread went on without its setup: a new turn, or it was deleted or moved. A failed
  setup goes now; a running one is marked, so that its failure is not kept for a retry.
  """
  def superseded(thread_id), do: GenServer.cast(__MODULE__, {:superseded, thread_id})

  # --- server ----------------------------------------------------------------------

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)
    {:ok, %{setups: %{}, watchers: %{}}}
  end

  @impl true
  def handle_call({:start, thread_id, run_id, project, strategy, text}, _from, state) do
    at = now()
    previous = state.setups[thread_id]
    with %{expiry: {timer, _}} <- previous, do: Process.cancel_timer(timer)

    snapshot = %{
      "threadId" => thread_id,
      "phase" => "running",
      "startedAt" => at,
      "endedAt" => nil,
      "branch" => strategy["branch"],
      "baseRef" => strategy["baseRef"],
      "worktreePath" => nil,
      "setupScript" => nil,
      "stages" => Enum.map(@stages, &stage/1),
      "error" => nil,
      # Clients keep the highest they saw, so a replacing setup counts on.
      "sequence" => if(previous, do: previous.snapshot["sequence"] + 1, else: 0)
    }

    server = self()
    worker = spawn_link(fn -> run(server, thread_id, run_id, project, strategy, text) end)

    setup = %{
      snapshot: snapshot,
      worker: worker,
      run_id: run_id,
      launch: {project, strategy, text},
      root: project["workspaceRoot"],
      claimed: nil,
      new_branch: nil,
      naming: nil,
      renaming: nil,
      cancelling: false,
      cancellable: true,
      superseded: false
    }

    state = put_in(state.setups[thread_id], setup)
    broadcast(state, thread_id)
    {:reply, :ok, state}
  end

  def handle_call({:subscribe, thread_id, pid, ref}, _from, state) do
    thread_watchers = HalC2.Watchers.add(Map.get(state.watchers, thread_id, %{}), pid, ref)
    watchers = Map.put(state.watchers, thread_id, thread_watchers)
    {:reply, get_in(state.setups, [thread_id, :snapshot]), %{state | watchers: watchers}}
  end

  # The removal can take minutes, and every other thread's setup talks to this server, so
  # it runs apart and the caller gets its answer when it has finished.
  def handle_call({:cancel, thread_id}, from, state) do
    case state.setups[thread_id] do
      %{cancellable: true, worker: worker} = setup when is_pid(worker) ->
        Process.unlink(worker)
        Process.exit(worker, :kill)
        stop_naming(setup.naming)
        server = self()

        spawn_link(fn ->
          try do
            cleanup(thread_id, setup)
          after
            send(server, {:cancelled, thread_id, setup.run_id, from})
          end
        end)

        setup = %{setup | worker: nil, cancellable: false, cancelling: true}
        {:noreply, put_in(state.setups[thread_id], setup)}

      # Already going ahead; the clicks a slow removal draws are not refused.
      %{cancelling: true, snapshot: %{"phase" => "running"}} ->
        {:reply, true, state}

      _ ->
        {:reply, false, state}
    end
  end

  def handle_call({:retry, thread_id}, _from, state) do
    with %{snapshot: snapshot, run_id: run_id, launch: launch} = setup <-
           state.setups[thread_id],
         true <- can_retry?(setup),
         :ok <- Orchestration.retry_prepared(thread_id, run_id) do
      server = self()
      path = snapshot["worktreePath"]
      worker = spawn_link(fn -> rerun(server, thread_id, run_id, launch, path) end)
      state = put_in(state.setups[thread_id], retried(setup, worker))
      broadcast(state, thread_id)
      {:reply, true, state}
    else
      _ -> {:reply, false, state}
    end
  end

  # Progress from the worker: snapshot changes, and notes on what to undo.
  # A cancel can end the setup while the worker's last word waits in the queue.
  def handle_call({:update, thread_id, fun}, _from, state) do
    if get_in(state.setups, [thread_id, :snapshot, "phase"]) == "running",
      do: {:reply, :ok, update(state, thread_id, fun)},
      else: {:reply, :ok, state}
  end

  # The worktree's folder, and its branch if the add will make one, claimed before
  # `git worktree add` so a cancel during the checkout still removes them.
  def handle_call({:claim, thread_id, path, new_branch}, _from, state) do
    state =
      if setup = state.setups[thread_id],
        do: put_in(state.setups[thread_id], %{setup | claimed: path, new_branch: new_branch}),
        else: state

    {:reply, :ok, state}
  end

  # Started here so that no cancel falls between the task starting and it being known.
  # A cancel can kill the worker while this call waits in the queue.
  def handle_call({:name_branch, thread_id, path, old, text}, {worker, _}, state) do
    case state.setups[thread_id] do
      %{worker: ^worker, run_id: run_id} ->
        naming = rename_later(thread_id, run_id, path, old, text)
        {:reply, :ok, put_in(state.setups[thread_id].naming, naming)}

      _ ->
        {:reply, :ok, state}
    end
  end

  # What a cancel deletes follows the name; HEAD says nothing, as the script can move it.
  # Known before git takes it, as a cancel can come at any point of the rename: then the
  # branch has one name or the other. `to` nil is a rename that failed.
  def handle_call({:renaming, thread_id, run_id, to}, _from, state) do
    case state.setups[thread_id] do
      %{run_id: ^run_id, new_branch: branch} = setup when is_binary(branch) ->
        {:reply, :ok, put_in(state.setups[thread_id], %{setup | renaming: to})}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:renamed, thread_id, run_id}, _from, state) do
    case state.setups[thread_id] do
      %{run_id: ^run_id, renaming: name} = setup when is_binary(name) ->
        setup = %{setup | new_branch: name, renaming: nil}
        {:reply, :ok, put_in(state.setups[thread_id], setup)}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:uncancellable, thread_id}, _from, state) do
    state =
      if state.setups[thread_id],
        do: put_in(state.setups[thread_id].cancellable, false),
        else: state

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:unsubscribe, thread_id, pid, ref}, state) do
    watchers =
      case HalC2.Watchers.remove(Map.get(state.watchers, thread_id, %{}), pid, ref) do
        empty when empty == %{} -> Map.delete(state.watchers, thread_id)
        thread_watchers -> Map.put(state.watchers, thread_id, thread_watchers)
      end

    {:noreply, %{state | watchers: watchers}}
  end

  def handle_cast({:superseded, thread_id}, state) do
    case state.setups[thread_id] do
      %{snapshot: %{"phase" => "failed"} = snapshot} ->
        {:noreply, if(retryable?(snapshot), do: forget(state, thread_id), else: state)}

      %{snapshot: %{"phase" => "running"}} ->
        {:noreply, put_in(state.setups[thread_id].superseded, true)}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:EXIT, worker, reason}, state) do
    case Enum.find(state.setups, fn {_, setup} -> setup.worker == worker end) do
      {thread_id, setup} ->
        state = put_in(state.setups[thread_id].worker, nil)

        state =
          case reason do
            :normal ->
              state

            {:shutdown, {:failed, message}} ->
              failed(state, thread_id, setup, message)

            other ->
              Logger.warning("worktree setup for #{thread_id} crashed: #{inspect(other)}")
              failed(state, thread_id, setup, "Worktree setup failed.")
          end

        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:cancelled, thread_id, run_id, from}, state) do
    GenServer.reply(from, true)

    case state.setups[thread_id] do
      %{run_id: ^run_id, snapshot: %{"phase" => "running"}} ->
        {:noreply, update(state, thread_id, &finish(&1, "cancelled", nil))}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:expire, thread_id, ref}, state) do
    case state.setups[thread_id] do
      %{expiry: {_, ^ref}} ->
        {:noreply, forget(state, thread_id)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    watchers =
      for {id, w} <- state.watchers,
          w = HalC2.Watchers.down(w, ref, pid),
          w != %{},
          into: %{},
          do: {id, w}

    {:noreply, %{state | watchers: watchers}}
  end

  # A server updated in place by a release upgrade from before subscriptions had refs kept each
  # thread's watchers as a set of pids, watched without one.
  @impl true
  def code_change(_old, state, _extra) do
    watchers =
      Map.new(state.watchers, fn
        {id, %MapSet{} = pids} ->
          {id, Enum.reduce(pids, %{}, &HalC2.Watchers.add(&2, &1, nil))}

        entry ->
          entry
      end)

    # One from before retries has no launch to run again, so it ends like any other.
    setups =
      Map.new(state.setups, fn {id, setup} ->
        {id, Map.put_new(setup, :superseded, not is_map_key(setup, :launch))}
      end)

    {:ok, %{state | watchers: watchers, setups: setups}}
  end

  defp forget(state, thread_id) do
    state = %{state | setups: Map.delete(state.setups, thread_id)}

    HalC2.Watchers.notify(
      Map.get(state.watchers, thread_id, %{}),
      {:hal_c2_worktree_setup, thread_id, nil}
    )

    state
  end

  # A delegated child's caller hears of this failure at once and may hand the task to
  # another agent, so its first message is not run later: the agent's stage ends here.
  # Without a worktree, what was queued behind it waits for a retry.
  defp failed(state, thread_id, setup, message) do
    delegated = Orchestration.delegated?(thread_id)
    hold = setup.snapshot["worktreePath"] == nil

    Orchestration.fail_prepared(thread_id, setup.run_id, "failed", failure(message),
      hold_queue: hold
    )

    update(state, thread_id, fn snapshot ->
      ended = finish(snapshot, "failed", message)
      if delegated, do: set_stage(ended, "agent", "skipped", %{}), else: ended
    end)
  end

  # How a preparation failure is recorded on the run.
  defp failure(message),
    do: %{
      "class" => "validation_error",
      "message" => message,
      "code" => nil,
      "retryable" => false
    }

  defp update(state, thread_id, fun) do
    case state.setups[thread_id] do
      nil ->
        state

      setup ->
        snapshot = fun.(setup.snapshot) |> Map.update!("sequence", &(&1 + 1))
        setup = %{setup | snapshot: snapshot}
        state = put_in(state.setups[thread_id], retain(setup, thread_id))
        broadcast(state, thread_id)
        state
    end
  end

  # A setup that ended starts its way out, once.
  defp retain(%{snapshot: %{"phase" => "running"}} = setup, _thread_id), do: setup
  defp retain(%{expiry: _} = setup, _thread_id), do: setup

  defp retain(setup, thread_id) do
    if not setup.superseded and retryable?(setup.snapshot) do
      setup
    else
      ref = make_ref()
      after_ms = Application.get_env(:hal_c2, :worktree_setup_retention, @retention)
      timer = Process.send_after(self(), {:expire, thread_id, ref}, after_ms)
      Map.put(setup, :expiry, {timer, ref})
    end
  end

  # Failed before the agent's stage began: the run's message has not reached an agent.
  defp retryable?(%{"phase" => "failed", "stages" => stages}),
    do: Enum.any?(stages, &(&1["id"] == "agent" and &1["status"] == "pending"))

  defp retryable?(_snapshot), do: false

  @doc "Whether `setup` may run again: it failed before its agent, its worker has ended, and the thread waits for it."
  def can_retry?(%{worker: nil, superseded: false, snapshot: snapshot}),
    do: retryable?(snapshot)

  def can_retry?(_setup), do: false

  @doc "`setup` as a retry leaves it, with `worker` running it."
  def retried(setup, worker),
    do: %{setup | snapshot: again(setup.snapshot), worker: worker, cancellable: true}

  # `snapshot` as a retry starts it: what the worktree's being there settled stays.
  defp again(snapshot) do
    kept = if snapshot["worktreePath"], do: ~w(fetch checkout submodules), else: []

    stages =
      Enum.map(snapshot["stages"], &if(&1["id"] in kept, do: &1, else: stage(&1["id"])))

    %{
      snapshot
      | "phase" => "running",
        "endedAt" => nil,
        "error" => nil,
        "setupScript" => nil,
        "stages" => stages
    }
    |> Map.update!("sequence", &(&1 + 1))
  end

  defp broadcast(state, thread_id) do
    snapshot = state.setups[thread_id].snapshot

    HalC2.Watchers.notify(
      Map.get(state.watchers, thread_id, %{}),
      {:hal_c2_worktree_setup, thread_id, snapshot}
    )
  end

  # A cancelled setup leaves nothing behind: no worktree, no workspace on the thread.
  # Each step goes ahead whatever became of the one before it.
  defp cleanup(thread_id, setup) do
    if path = setup.snapshot["worktreePath"] || setup.claimed do
      attempt(thread_id, fn ->
        HalC2.Terminal.close(%{
          "threadId" => thread_id,
          "terminalId" => "setup",
          "deleteHistory" => true
        })
      end)

      attempt(thread_id, fn -> remove_workspace(thread_id, setup, path) end)
    end

    # The worktree is gone, so what was queued behind it is held.
    attempt(thread_id, fn ->
      Orchestration.fail_prepared(thread_id, setup.run_id, "cancelled", nil, hold_queue: true)
    end)
  end

  defp attempt(thread_id, fun) do
    fun.()
  rescue
    error -> Logger.warning("worktree cleanup for #{thread_id}: #{Exception.message(error)}")
  catch
    :exit, reason -> Logger.warning("worktree cleanup for #{thread_id}: #{inspect(reason)}")
  end

  defp remove_workspace(thread_id, setup, path) do
    # A checkout cut short leaves what git started still writing, and the worktree
    # locked as "initializing". A claimed folder was free, so all of it is the setup's.
    HalC2.Git.stop_children(path)

    if setup.claimed do
      branches = Enum.reject([setup.new_branch, setup.renaming], &is_nil/1)
      HalC2.Vcs.clear_worktree(setup.root, path, branches)
    else
      HalC2.Git.run(setup.root, ["worktree", "unlock", path])
      HalC2.Vcs.remove_worktree(%{"cwd" => setup.root, "path" => path, "force" => true})
    end

    Orchestration.dispatch(%{
      "type" => "thread.metadata.update",
      "threadId" => thread_id,
      "worktreePath" => nil,
      "branch" => nil
    })
  end

  # Gone when this returns, so nothing it would write lands after the cancel's own.
  defp stop_naming(nil), do: :ok

  defp stop_naming(naming) do
    ref = Process.monitor(naming)
    Process.exit(naming, :kill)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    end
  end

  # --- the worker ------------------------------------------------------------------

  defp run(server, thread_id, run_id, project, strategy, text) do
    root = project["workspaceRoot"]
    set = fn fun -> GenServer.call(server, {:update, thread_id, fun}) end
    status = fn id, status, extra -> set.(&set_stage(&1, id, status, extra)) end
    Orchestration.progress_prepared(thread_id, run_id, "worktree")

    # Fetch first when asked and the remote has the base branch.
    start_ref =
      if strategy["startFromOrigin"] == true and origin?(root) do
        status.("fetch", "running", %{})
        _ = HalC2.Git.run(root, ["fetch", "origin", strategy["baseRef"]])
        status.("fetch", "done", %{})

        if match?(
             {:ok, _},
             HalC2.Git.ok(root, ["rev-parse", "--verify", "origin/#{strategy["baseRef"]}"])
           ),
           do: "origin/#{strategy["baseRef"]}",
           else: strategy["baseRef"]
      else
        status.("fetch", "skipped", %{})
        strategy["baseRef"]
      end

    status.("checkout", "running", %{})

    # A client may name the worktree's temporary branch itself (the terminal client
    # does); it is renamed like the MC's own.
    temporary =
      case strategy["branch"] do
        nil -> temporary_branch(root, nil)
        requested -> if temporary?(requested), do: temporary_branch(root, requested)
      end

    branch = temporary || strategy["branch"]

    path = HalC2.Vcs.worktree_path(root, branch)

    unless File.exists?(path) do
      new_branch = if not HalC2.Vcs.branch?(root, branch), do: branch
      GenServer.call(server, {:claim, thread_id, path, new_branch})
    end

    {path, branch} =
      case HalC2.Vcs.create_worktree(
             %{
               "cwd" => root,
               "refName" => start_ref,
               "newRefName" => branch,
               "path" => path,
               "submodules" => false
             },
             on_progress: &status.("checkout", "running", %{"percent" => &1})
           ) do
        {:ok, %{"worktree" => %{"path" => path, "refName" => branch}}} -> {path, branch}
        {:error, error} -> fail("Could not create the worktree: #{message(error)}")
      end

    set.(&Map.merge(&1, %{"worktreePath" => path, "branch" => branch}))

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.metadata.update",
        "threadId" => thread_id,
        "worktreePath" => path,
        "branch" => branch
      })

    status.("checkout", "done", %{"percent" => 100})
    submodules(root, path, set, status)

    if branch == temporary,
      do: GenServer.call(server, {:name_branch, thread_id, path, branch, text})

    script_and_agent(server, thread_id, run_id, project, path)
  end

  # A retry goes on from the worktree when the setup got that far. The project is read
  # again, as the retry may be for a script the user has just corrected.
  defp rerun(server, thread_id, run_id, {project, strategy, text}, path) do
    project =
      case HalC2.Shell.row(node(), project["id"]) do
        {"project", row} -> row
        _ -> project
      end

    if path,
      do: script_and_agent(server, thread_id, run_id, project, path),
      else: run(server, thread_id, run_id, project, strategy, text)
  end

  defp script_and_agent(server, thread_id, run_id, project, path) do
    root = project["workspaceRoot"]
    set = fn fun -> GenServer.call(server, {:update, thread_id, fun}) end
    status = fn id, status, extra -> set.(&set_stage(&1, id, status, extra)) end
    Orchestration.progress_prepared(thread_id, run_id, "setup")

    {setup, wait} =
      case setup_script(project, root, path) do
        :none ->
          status.("setup-script", "skipped", %{})
          {nil, nil}

        {:skip, reason} ->
          status.("setup-script", "skipped", %{"detail" => reason})
          {nil, nil}

        {:run, script} ->
          status.("setup-script", "running", %{})
          {script, start_script(thread_id, root, path, script, set)}
      end

    # A blocking script finishes before the agent starts.
    if wait && setup["async"] == false, do: await_script(wait, status, set, fatal: true)

    GenServer.call(server, {:uncancellable, thread_id})
    status.("agent", "running", %{})

    case Orchestration.release_prepared(thread_id, run_id) do
      :ok -> status.("agent", "done", %{})
      {:error, reason} -> fail("The agent could not start: #{message(reason)}")
    end

    if wait && setup["async"] != false, do: await_script(wait, status, set, fatal: false)
    set.(&finish(&1, "done", nil))
  end

  # Submodules get their own stage, shown only when the worktree has any.
  defp submodules(root, path, set, status) do
    if File.exists?(Path.join(path, ".gitmodules")) do
      set.(&add_stage(&1, "submodules", after: "checkout"))
      status.("submodules", "running", %{})

      case HalC2.Vcs.init_submodules(root, path) do
        :ok ->
          status.("submodules", "done", %{})

        :none ->
          status.("submodules", "skipped", %{})

        {:error, detail} ->
          status.("submodules", "warning", %{"detail" => message(detail)})
      end
    end
  end

  defp origin?(root), do: match?({:ok, _}, HalC2.Git.ok(root, ~w(remote get-url origin)))

  # `hal-c2/<8 hex>`, or `hal-c2-<8 hex>` in a repository with a branch named `hal-c2`,
  # where git cannot put a branch under `hal-c2/`. Clients generate `hal-c2/<uuid>` too.
  @temporary ~r/^hal-c2[\/-](?:[0-9a-f]{8}|[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})$/

  @doc "Whether `branch` is a worktree's temporary branch, renamed from the first message."
  def temporary?(branch), do: Regex.match?(@temporary, String.downcase(String.trim(branch)))

  @doc """
  A temporary branch git can create in `root`: `requested` (a client's) when nothing is
  in its way, else `hal-c2/<hex>`, else `hal-c2-<hex>`.
  """
  def temporary_branch(root, requested) do
    hex = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    [requested, "hal-c2/" <> hex, "hal-c2-" <> hex]
    |> Enum.reject(&is_nil/1)
    |> Enum.find(&(not HalC2.Git.branch_path_taken?(root, &1)))
    |> Kernel.||("hal-c2-" <> hex)
  end

  @doc """
  The script to run in a new worktree at `path`: `{:run, script}` for the first of the
  project's saved actions marked to run on worktree creation. With no saved setup action,
  a marked script in the worktree's `hal-c2.json` returns `{:skip, reason}` until the user
  imports or saves it; no marked file script returns `:none`. Like the clients' import,
  the first marked script wins; the file has no per-platform field, so a Windows variant
  has to come after the POSIX one.
  """
  def setup_script(project, _root, path) do
    case Enum.find(saved_scripts(project), &setup?/1) do
      %{} = script ->
        {:run, script}

      nil ->
        case Enum.find(HalC2.ProjectFile.scripts(path), &setup?/1) do
          nil -> :none
          %{} -> {:skip, @untrusted}
        end
    end
  end

  defp setup?(script), do: script["runOnWorktreeCreate"] == true

  # The project's actions as the clients resolve them (`resolveProjectScripts`): its own
  # list in settings, else the environment's defaults once the legacy fields are folded.
  # Before that, the legacy `projectScriptOverrides` map (which TS clients still write
  # back with every settings change; null there meant the defaults), else the scripts
  # its row carries, else the defaults.
  defp saved_scripts(project) do
    {settings, _} = HalC2.Settings.get()
    id = project["id"]
    defaults = settings["defaultProjectScripts"] || []
    legacy = settings["projectScriptOverrides"] || %{}
    own = project["scripts"] || []

    cond do
      is_list(
        scripts = get_in(settings, ["projectSettingsOverrides", id, "defaultProjectScripts"])
      ) ->
        scripts

      settings["projectSettingsFolded"] == true ->
        defaults

      is_map_key(legacy, id) ->
        legacy[id] || defaults

      true ->
        if own == [], do: defaults, else: own
    end
  end

  @doc """
  What a setup script's terminal adds to its environment: where the project and the
  worktree are, as project scripts the clients run see them (the T3CODE_ names are what
  scripts written before the rename use). It can run before a client attaches, so
  nothing advertises truecolor: tools that probe for it wait on a reply nobody sends.
  """
  def script_env(root, path) do
    %{
      "COLORTERM" => "",
      "HAL_C2_PROJECT_ROOT" => root,
      "T3CODE_PROJECT_ROOT" => root,
      "HAL_C2_WORKTREE_PATH" => path,
      "T3CODE_WORKTREE_PATH" => path
    }
  end

  @doc """
  What the terminal's shell runs for `command`: it prints `sentinel` and `start` on a
  line of its own as it begins, so what the shell's startup prints before that is not its
  output, and `sentinel` with its exit status as it ends. The script is one quoted word,
  so a syntax error in it is its exit status and not the wrapper's, and it may end in a
  comment or hold a here-document. It runs in a child, so it may `exit`: a subshell that
  keeps the functions the user's shell startup defined, or for fish, which has none, a
  new fish.
  """
  def wrap_script(command, shell, sentinel) do
    body = command |> String.trim_trailing() |> String.replace(~r/\r\n?/, "\n")
    start = "printf '\\n#{sentinel}start\\n'"

    case Path.basename(shell || "") do
      "fish" ->
        # In fish's single quotes a backslash escapes a quote or a backslash.
        quoted = body |> String.replace("\\", "\\\\") |> String.replace("'", "\\'")

        "#{start}; #{shell} -c '#{quoted}'; printf '\\n#{sentinel}%s\\n' $status"

      # An interactive zsh takes `#` for a command unless told, before it reads the line.
      "zsh" ->
        "setopt interactive_comments\n" <> subshell(start, body, sentinel)

      _ ->
        subshell(start, body, sentinel)
    end
  end

  defp subshell(start, body, sentinel) do
    quoted = String.replace(body, "'", "'\\''")
    "( #{start}; eval '#{quoted}' ); printf '\\n#{sentinel}%s\\n' \"$?\""
  end

  # What follows the script in its terminal: the user's shell, for whoever opens it.
  defp then_shell(shell) do
    case Path.basename(shell || "") do
      "fish" -> "exec $SHELL"
      "zsh" -> "exec $SHELL -o nopromptsp"
      _ -> "exec ${SHELL:-/bin/sh}"
    end
  end

  @doc """
  Adds `data` from a terminal to `partial`, the line it was still writing: `{lines,
  partial}`. A carriage return ends a line too, so a redrawn progress bar is one line per
  redraw. Lines come without terminal control; of an endless line only the tail is kept.
  """
  def script_lines(partial, data) do
    {lines, [rest]} = (partial <> data) |> String.split(~r/\r\n|\r|\n/) |> Enum.split(-1)

    rest =
      if byte_size(rest) > @partial_max,
        do: String.slice(rest, -@partial_max..-1//1),
        else: rest

    {Enum.map(lines, &plain/1), rest}
  end

  defp plain(line) do
    line
    |> String.replace(@terminal_control, "")
    |> String.replace(@stray_control, "")
    |> String.trim_trailing()
  end

  # Runs the script in the thread's "setup" terminal; its exit status comes back as a
  # line the wrapper prints after it, under a token nothing the script prints can know.
  # The script is the shell's argument, as anything typed into a starting shell can be
  # read by whatever its startup runs. A retry's script gets a shell of its own too.
  defp start_script(thread_id, root, path, script, set) do
    sentinel = "__hal_c2_setup_#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}_"
    shell = System.get_env("SHELL")
    command = wrap_script(script["command"], shell, sentinel) <> "\n" <> then_shell(shell)
    terminal = %{"threadId" => thread_id, "terminalId" => "setup"}

    input =
      Map.merge(terminal, %{
        "cwd" => path,
        "command" => command,
        "env" => Map.merge(%{"NO_COLOR" => "1", "FORCE_COLOR" => "0"}, script_env(root, path))
      })

    with {:ok, _} <- terminal(:close, [Map.put(terminal, "deleteHistory", true)]),
         {:ok, %{"status" => status}} when status != "error" <- terminal(:attach, [input, self()]) do
      set.(
        &Map.put(&1, "setupScript", %{
          "name" => script["name"],
          "command" => script["command"],
          "terminalId" => "setup"
        })
      )

      {thread_id, sentinel, now_ms() + start_timeout()}
    else
      _ -> fail("Could not start the setup script.")
    end
  end

  defp start_timeout,
    do: Application.get_env(:hal_c2, :worktree_setup_start_timeout, @start_timeout)

  defp now_ms, do: System.monotonic_time(:millisecond)

  # The terminal service may be down; that is a script that cannot start.
  defp terminal(fun, args) do
    apply(HalC2.Terminal, fun, args)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp await_script({thread_id, sentinel, deadline}, status, set, opts) do
    script = %{start: sentinel <> "start", exit: ~r/^#{sentinel}(\d+)$/, deadline: deadline}

    case read_script({thread_id, "setup"}, script, set) do
      :not_started ->
        # Its shell goes too, or the script could still begin after this says it did not.
        terminal(:close, [%{"threadId" => thread_id, "terminalId" => "setup"}])
        status.("setup-script", "failed", %{"detail" => "did not start"})

        if opts[:fatal] do
          seconds = div(start_timeout(), 1000)
          fail("The setup script did not start within #{seconds} seconds.")
        end

      # Nothing is left to read in a shell whose script went well; a failed one stays open
      # with its error.
      {0, tail} ->
        terminal(:close, [%{"threadId" => thread_id, "terminalId" => "setup"}])
        status.("setup-script", "done", %{"detail" => "exited with 0", "tail" => tail})

      {nil, tail} ->
        status.("setup-script", "failed", %{
          "detail" => "exited with no exit code",
          "tail" => tail
        })

        if opts[:fatal], do: fail("Setup script exited with no exit code.")

      {code, tail} ->
        status.("setup-script", "failed", %{"detail" => "exited with #{code}", "tail" => tail})
        if opts[:fatal], do: fail("Setup script exited with #{code}.")
    end
  end

  # Reads the terminal from the wrapper's first line to its last or the terminal's end,
  # which leaves no exit status, keeping the last lines as the stage's tail. Without that
  # first line by the deadline, nothing is running and nothing will end: `:not_started`.
  # Until then the tail is what the shell's startup prints, the line it is still writing
  # included, as it may be asking the user something in the setup terminal. `set` gets
  # each change to the snapshot.
  @doc false
  def read_script(key, script, set), do: collect(key, script, false, "", [], set)

  defp collect(key, script, started, partial, tail, set) do
    wait = if started, do: :infinity, else: max(script.deadline - now_ms(), 0)

    receive do
      {:hal_c2_terminal, ^key, %{"type" => "output", "data" => data}} ->
        {lines, rest} = script_lines(partial, data)
        was = if started, do: tail, else: shown(script, tail, partial)

        case from_start(started, lines, script.start) do
          {true, lines} when started ->
            output(key, script, lines, rest, tail, set)

          # The script begins: what the startup printed leaves the tail.
          {true, lines} ->
            if was != [], do: set.(&set_stage(&1, "setup-script", "running", %{"tail" => []}))
            output(key, script, lines, rest, [], set)

          {false, startup} ->
            next = tail(tail, startup)
            shown = shown(script, next, rest)

            if shown != was,
              do: set.(&set_stage(&1, "setup-script", "running", %{"tail" => shown}))

            collect(key, script, false, rest, next, set)
        end

      {:hal_c2_terminal, ^key, %{"type" => type}} when type in ~w(exited closed) ->
        {nil, tail}

      {:hal_c2_terminal, ^key, _event} ->
        collect(key, script, started, partial, tail, set)
    after
      wait -> :not_started
    end
  end

  defp output(key, script, lines, partial, tail, set) do
    {output, rest} = Enum.split_while(lines, &(not Regex.match?(script.exit, &1)))
    next = tail(tail, output)

    case rest do
      [last | _] ->
        [_, code] = Regex.run(script.exit, last)
        {String.to_integer(code), next}

      [] ->
        if next != tail,
          do: set.(&set_stage(&1, "setup-script", "running", %{"tail" => next}))

        collect(key, script, true, partial, next, set)
    end
  end

  # The startup's lines and the one it is still writing, unless that is the start line
  # arriving in pieces.
  defp shown(script, tail, partial) do
    line = plain(partial)
    if String.starts_with?(script.start, line), do: tail, else: tail(tail, [line])
  end

  defp from_start(true, lines, _start), do: {true, lines}

  defp from_start(false, lines, start) do
    case Enum.split_while(lines, &(&1 != start)) do
      {startup, []} -> {false, startup}
      {_startup, [_start | lines]} -> {true, lines}
    end
  end

  defp tail(tail, lines) do
    shown = lines |> Enum.reject(&(&1 == "")) |> Enum.map(&String.slice(&1, 0, @line_max))
    Enum.take(tail ++ shown, -@tail_lines)
  end

  # The temporary branch gets a name from the first message, in the background. The
  # worktree works on its temporary branch if that fails. A cancel stops it.
  defp rename_later(thread_id, run_id, path, old, text) do
    {:ok, naming} =
      Task.start(fn ->
        renaming = &GenServer.call(__MODULE__, {:renaming, thread_id, run_id, &1})

        with {:ok, %{"branch" => generated}} <- HalC2.TextGeneration.branch_name(path, text || ""),
             name when name != "" <- sanitize(generated) do
          case HalC2.Vcs.rename_branch(path, old, name, renaming) do
            {:ok, new} ->
              HalC2.Vcs.Watch.refresh(path)
              GenServer.call(__MODULE__, {:renamed, thread_id, run_id})

              Orchestration.dispatch(%{
                "type" => "thread.metadata.update",
                "threadId" => thread_id,
                "branch" => new,
                "worktreePath" => path
              })

            {:error, reason} ->
              renaming.(nil)

              Orchestration.warn_prepared(
                thread_id,
                run_id,
                "The branch was not renamed",
                message(reason)
              )
          end
        else
          {:error, reason} -> Logger.warning("branch name not generated: #{message(reason)}")
          _ -> :ok
        end
      end)

    naming
  end

  defp sanitize(raw) do
    raw
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/['"`]/, "")
    |> String.replace(~r/[^a-z0-9\/_-]+/, "-")
    |> String.replace(~r/\/+/, "/")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
    |> String.slice(0, 64)
  end

  # --- snapshots -------------------------------------------------------------------

  defp stage(id),
    do: %{
      "id" => id,
      "status" => "pending",
      "startedAt" => nil,
      "endedAt" => nil,
      "percent" => nil,
      "detail" => nil,
      "tail" => []
    }

  defp add_stage(snapshot, id, after: previous) do
    index = Enum.find_index(snapshot["stages"], &(&1["id"] == previous)) + 1
    %{snapshot | "stages" => List.insert_at(snapshot["stages"], index, stage(id))}
  end

  @doc false
  def set_stage(snapshot, id, status, extra) do
    at = now()

    stages =
      Enum.map(snapshot["stages"], fn
        %{"id" => ^id} = stage ->
          stage
          |> Map.merge(extra)
          |> Map.update!("detail", &clamp(&1, @detail_max))
          |> Map.put("status", status)
          |> then(
            &if(status == "running" and &1["startedAt"] == nil,
              do: Map.put(&1, "startedAt", at),
              else: &1
            )
          )
          |> then(
            &if(status in ~w(done skipped failed warning),
              do: Map.put(&1, "endedAt", at),
              else: &1
            )
          )

        stage ->
          stage
      end)

    %{snapshot | "stages" => stages}
  end

  @doc """
  `snapshot` ended as `phase` (`done`, `failed` or `cancelled`) with `error`. A stage still
  running ends with it; one that never started stays as it was.
  """
  def finish(snapshot, phase, error) do
    at = now()
    settled = if phase == "cancelled", do: "skipped", else: phase

    stages =
      Enum.map(snapshot["stages"], fn
        %{"status" => "running"} = stage -> %{stage | "status" => settled, "endedAt" => at}
        stage -> stage
      end)

    Map.merge(snapshot, %{
      "phase" => phase,
      "endedAt" => at,
      "error" => clamp(error, @error_max),
      "stages" => stages
    })
  end

  defp clamp(nil, _max), do: nil

  defp clamp(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end

  defp fail(message), do: exit({:shutdown, {:failed, message}})

  defp message(%{"message" => message}), do: message
  defp message(%{"detail" => detail}) when is_binary(detail), do: detail
  defp message(reason) when is_binary(reason), do: reason
  defp message(reason), do: inspect(reason)

  defp now, do: HalC2.Orchestration.Entities.now()
end
