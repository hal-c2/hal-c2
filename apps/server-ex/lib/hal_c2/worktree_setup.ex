defmodule HalC2.WorktreeSetup do
  @moduledoc """
  Preparing a new thread's git worktree before its first turn (`subscribeWorktreeSetup`,
  `worktreeSetup.cancel`).

  A thread launched with the `worktree` strategy gets a `preparing` run; a worker then
  fetches the base branch when asked, adds the worktree on a temporary
  `hal-c2/<hex>` branch (`temporary_branch/2`, renamed in the background from the
  first message), fills
  its submodules, runs the project's setup script in a terminal, and releases the run
  (`HalC2.Orchestration.release_prepared/2`). Its progress is a `WorktreeSetupSnapshot`
  that subscribers get on every change. Until the agent starts the setup can be
  cancelled, which removes the worktree and cancels the run.

  Snapshots live in memory: after a restart a thread shows no setup.
  """

  use GenServer

  require Logger

  alias HalC2.Orchestration

  # A `submodules` stage joins after `checkout` when the worktree has submodules.
  @stages ~w(fetch checkout setup-script agent)
  @tail_lines 5
  @untrusted "this branch's hal-c2.json setup script differs from the main checkout's, so it was not run"

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
    do: {:ok, %{"cancelled" => GenServer.call(__MODULE__, {:cancel, thread_id}, 60_000)}}

  # --- server ----------------------------------------------------------------------

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)
    {:ok, %{setups: %{}, watchers: %{}}}
  end

  @impl true
  def handle_call({:start, thread_id, run_id, project, strategy, text}, _from, state) do
    at = now()

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
      "sequence" => 0
    }

    server = self()
    worker = spawn_link(fn -> run(server, thread_id, run_id, project, strategy, text) end)

    setup = %{
      snapshot: snapshot,
      worker: worker,
      run_id: run_id,
      root: project["workspaceRoot"],
      claimed: nil,
      cancellable: true
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

  def handle_call({:cancel, thread_id}, _from, state) do
    case state.setups[thread_id] do
      %{cancellable: true, worker: worker} = setup when is_pid(worker) ->
        Process.unlink(worker)
        Process.exit(worker, :kill)
        cleanup(thread_id, setup)
        state = update(state, thread_id, &finish(&1, "cancelled", nil))
        state = put_in(state.setups[thread_id].worker, nil)
        {:reply, true, state}

      _ ->
        {:reply, false, state}
    end
  end

  # Progress from the worker: snapshot changes, and notes on what to undo.
  def handle_call({:update, thread_id, fun}, _from, state),
    do: {:reply, :ok, update(state, thread_id, fun)}

  # The worktree's folder, claimed before `git worktree add` so a cancel during the
  # checkout still removes it.
  def handle_call({:claim, thread_id, path}, _from, state) do
    state =
      if state.setups[thread_id],
        do: put_in(state.setups[thread_id].claimed, path),
        else: state

    {:reply, :ok, state}
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
              Orchestration.fail_prepared(thread_id, setup.run_id, "failed", failure(message))
              update(state, thread_id, &finish(&1, "failed", message))

            other ->
              Logger.warning("worktree setup for #{thread_id} crashed: #{inspect(other)}")
              message = "Worktree setup failed."
              Orchestration.fail_prepared(thread_id, setup.run_id, "failed", failure(message))
              update(state, thread_id, &finish(&1, "failed", message))
          end

        {:noreply, state}

      nil ->
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

  # A server updated in place (`HalC2.Hot`) from before subscriptions had refs kept each
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

    {:ok, %{state | watchers: watchers}}
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
        state = put_in(state.setups[thread_id].snapshot, snapshot)
        broadcast(state, thread_id)
        state
    end
  end

  defp broadcast(state, thread_id) do
    snapshot = state.setups[thread_id].snapshot

    HalC2.Watchers.notify(
      Map.get(state.watchers, thread_id, %{}),
      {:hal_c2_worktree_setup, thread_id, snapshot}
    )
  end

  # A cancelled setup leaves nothing behind: no worktree, no workspace on the thread.
  defp cleanup(thread_id, setup) do
    path = setup.snapshot["worktreePath"] || setup.claimed

    if path do
      HalC2.Terminal.close(%{
        "threadId" => thread_id,
        "terminalId" => "setup",
        "deleteHistory" => true
      })

      # A checkout cut short leaves the worktree locked as "initializing".
      HalC2.Git.run(setup.root, ["worktree", "unlock", path])
      HalC2.Vcs.remove_worktree(%{"cwd" => setup.root, "path" => path, "force" => true})

      Orchestration.dispatch(%{
        "type" => "thread.metadata.update",
        "threadId" => thread_id,
        "worktreePath" => nil,
        "branch" => nil
      })
    end

    Orchestration.fail_prepared(thread_id, setup.run_id, "cancelled")
  rescue
    error -> Logger.warning("worktree cleanup for #{thread_id}: #{Exception.message(error)}")
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
    unless File.exists?(path), do: GenServer.call(server, {:claim, thread_id, path})

    {path, branch} =
      case HalC2.Vcs.create_worktree(%{
             "cwd" => root,
             "refName" => start_ref,
             "newRefName" => branch,
             "path" => path,
             "submodules" => false
           }) do
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

    status.("checkout", "done", %{})
    submodules(root, path, set, status)
    if branch == temporary, do: rename_later(thread_id, path, branch, text)

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
          status.("submodules", "warning", %{"detail" => String.slice(message(detail), 0, 200)})
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
  The script to run in a new worktree at `path` of the project checked out at `root`:
  `{:run, script}` for the one the project's saved actions mark to run on worktree
  creation, else for the one the worktree's own `hal-c2.json` marks (the branch's file,
  which the clients read from the thread's checkout too); `:none` when neither marks one.
  Like the clients' import, the first marked script wins; the file has no per-platform
  field, so a Windows variant has to come after the POSIX one.

  The user saved their actions, but anyone with a branch can write its file. So the
  file's script runs only when `root`'s own file marks one with the same command that
  blocks the agent the same way; otherwise it is `{:skip, reason}`. That keeps a branch
  from choosing the command, not from shaping what it does: the command still runs
  against the branch's files (its `mise.toml`, `package.json`, `mix.exs`), as a saved
  setup script does. Requiring the branch's commits to be in `root` would skip setup
  for worktrees off feature branches, which is what `delegate_task` makes.
  """
  def setup_script(project, root, path) do
    with nil <- Enum.find(saved_scripts(project), &setup?/1),
         %{} = script <- Enum.find(HalC2.ProjectFile.scripts(path), &setup?/1) do
      if Enum.any?(HalC2.ProjectFile.scripts(root), &same_setup?(&1, script)),
        do: {:run, script},
        else: {:skip, @untrusted}
    else
      nil -> :none
      script -> {:run, script}
    end
  end

  defp same_setup?(trusted, script),
    do:
      setup?(trusted) and trusted["command"] == script["command"] and
        trusted["async"] == false == (script["async"] == false)

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

  # Runs the script in the thread's "setup" terminal; its exit code comes back as a
  # marker line the command prints after it.
  defp start_script(thread_id, root, path, script, set) do
    token = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    input = %{
      "threadId" => thread_id,
      "terminalId" => "setup",
      "cwd" => path,
      "env" => Map.merge(%{"NO_COLOR" => "1", "FORCE_COLOR" => "0"}, script_env(root, path))
    }

    with {:ok, _} <- terminal(:open, [input]),
         {:ok, _} <- terminal(:attach, [input, self()]),
         {:ok, _} <-
           terminal(:write, [
             %{
               "threadId" => thread_id,
               "terminalId" => "setup",
               "data" => "#{script["command"]}; printf '\\n__hal_c2_setup_#{token}_%s\\n' $?\r"
             }
           ]) do
      set.(
        &Map.put(&1, "setupScript", %{
          "name" => script["name"],
          "command" => script["command"],
          "terminalId" => "setup"
        })
      )

      {thread_id, token}
    else
      _ -> fail("Could not start the setup script.")
    end
  end

  # The terminal service may be down; that is a script that cannot start.
  defp terminal(fun, args) do
    apply(HalC2.Terminal, fun, args)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp await_script({thread_id, token}, status, set, opts) do
    case collect({thread_id, "setup"}, Regex.compile!("__hal_c2_setup_#{token}_(\\d+)"), "", set) do
      {0, tail} ->
        status.("setup-script", "done", %{"detail" => "exited with 0", "tail" => tail})

      {code, tail} ->
        status.("setup-script", "failed", %{"detail" => "exited with #{code}", "tail" => tail})
        if opts[:fatal], do: fail("Setup script exited with #{code}.")
    end
  end

  # Reads the terminal until the marker, keeping the last lines as the stage's tail.
  defp collect(key, marker, buffer, set) do
    receive do
      {:hal_c2_terminal, ^key, %{"type" => "output", "data" => data}} ->
        buffer = String.slice(buffer <> strip_ansi(data), -8_000..-1//1)

        case Regex.run(marker, buffer) do
          [_, code] ->
            {String.to_integer(code), tail(buffer)}

          nil ->
            set.(&set_stage(&1, "setup-script", "running", %{"tail" => tail(buffer)}))
            collect(key, marker, buffer, set)
        end

      {:hal_c2_terminal, ^key, %{"type" => "exited"}} ->
        {1, tail(buffer)}

      {:hal_c2_terminal, ^key, _event} ->
        collect(key, marker, buffer, set)
    end
  end

  # The last lines of the script's output, without the exit marker.
  defp tail(buffer) do
    buffer
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.reject(&String.contains?(&1, "__hal_c2_setup_"))
    |> Enum.take(-@tail_lines)
    |> Enum.map(&String.slice(&1, 0, 200))
  end

  # The temporary branch gets a name from the first message, in the background.
  defp rename_later(thread_id, path, old, text) do
    Task.start(fn ->
      with {:ok, %{"branch" => generated}} <- HalC2.TextGeneration.branch_name(path, text || ""),
           new when new != "" <- available(path, sanitize(generated)),
           {:ok, _} <- HalC2.Git.ok(path, ["branch", "-m", old, new]) do
        HalC2.Vcs.Watch.refresh(path)

        Orchestration.dispatch(%{
          "type" => "thread.metadata.update",
          "threadId" => thread_id,
          "branch" => new,
          "worktreePath" => path
        })
      else
        {:error, reason} -> Logger.warning("branch name not generated: #{message(reason)}")
        _ -> :ok
      end
    end)
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

  defp available(path, name) do
    Enum.find([name | Enum.map(2..20, &"#{name}-#{&1}")], fn candidate ->
      match?(
        {:error, _},
        HalC2.Git.ok(path, ["rev-parse", "--verify", "refs/heads/#{candidate}"])
      ) and not HalC2.Git.branch_path_taken?(path, candidate)
    end) || ""
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

  defp set_stage(snapshot, id, status, extra) do
    at = now()

    stages =
      Enum.map(snapshot["stages"], fn
        %{"id" => ^id} = stage ->
          stage
          |> Map.merge(extra)
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

  defp finish(snapshot, phase, error),
    do: Map.merge(snapshot, %{"phase" => phase, "endedAt" => now(), "error" => error})

  defp fail(message), do: exit({:shutdown, {:failed, message}})

  defp message(%{"message" => message}), do: message
  defp message(%{"detail" => detail}) when is_binary(detail), do: detail
  defp message(reason) when is_binary(reason), do: reason
  defp message(reason), do: inspect(reason)

  defp strip_ansi(text), do: String.replace(text, ~r/\e\[[0-9;?]*[a-zA-Z]/, "")

  defp now, do: HalC2.Orchestration.Entities.now()
end
