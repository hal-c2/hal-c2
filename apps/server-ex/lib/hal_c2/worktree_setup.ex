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

  Snapshots live in memory: after a restart a thread shows no setup. A finished one stays
  readable for half a minute, so a late subscriber sees how it ended, then goes.
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
  # Colours, cursor movement and titles, then whatever control characters are left.
  @terminal_control ~r/\e\[[0-9;?]*[ -\/]*[@-~]|\e\][^\a\e]*(?:\a|\e\\)|\e[()][A-Za-z0-9]|\e[=>]/
  @stray_control ~r/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/
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
    do:
      {:ok,
       %{
         "cancelled" =>
           GenServer.call(__MODULE__, {:cancel, thread_id}, HalC2.Vcs.worktree_timeout() + 60_000)
       }}

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
      root: project["workspaceRoot"],
      claimed: nil,
      new_branch: nil,
      naming: nil,
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
        stop_naming(setup.naming)
        cleanup(thread_id, setup)
        state = update(state, thread_id, &finish(&1, "cancelled", nil))
        state = put_in(state.setups[thread_id].worker, nil)
        {:reply, true, state}

      _ ->
        {:reply, false, state}
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

  def handle_info({:expire, thread_id, ref}, state) do
    case state.setups[thread_id] do
      %{expiry: {_, ^ref}} ->
        state = %{state | setups: Map.delete(state.setups, thread_id)}

        HalC2.Watchers.notify(
          Map.get(state.watchers, thread_id, %{}),
          {:hal_c2_worktree_setup, thread_id, nil}
        )

        {:noreply, state}

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
    ref = make_ref()
    after_ms = Application.get_env(:hal_c2, :worktree_setup_retention, @retention)
    timer = Process.send_after(self(), {:expire, thread_id, ref}, after_ms)
    Map.put(setup, :expiry, {timer, ref})
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

      # A checkout cut short leaves what git started still writing, and the worktree
      # locked as "initializing". A claimed folder was free, so all of it is the setup's.
      HalC2.Git.stop_children(path)

      if setup.claimed do
        HalC2.Vcs.clear_worktree(setup.root, path, made_branch(setup, path))
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

    Orchestration.fail_prepared(thread_id, setup.run_id, "cancelled")
  rescue
    error -> Logger.warning("worktree cleanup for #{thread_id}: #{Exception.message(error)}")
  end

  # The branch the setup made, under the name it has now: naming it may have finished.
  # A folder without `.git` would answer for whatever repository is around it.
  defp made_branch(%{new_branch: nil}, _path), do: nil

  defp made_branch(%{new_branch: branch}, path) do
    with true <- File.exists?(Path.join(path, ".git")),
         {:ok, out} when out != "" <- HalC2.Git.ok(path, ["branch", "--show-current"]) do
      String.trim(out)
    else
      _ -> branch
    end
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

  @doc """
  What is typed into the terminal to run `command`: it prints `sentinel` and `start` on a
  line of its own as it begins, so the shell's prompt and echo before that are not its
  output, and `sentinel` with its exit status as it ends. The script is one quoted word,
  so a syntax error in it is its exit status and not the wrapper's, and it may end in a
  comment or hold a here-document. It runs in a child, so it may `exit`: a subshell that
  keeps the functions the user's shell startup defined, or for fish, which has none, a
  new fish.
  """
  def wrap_script(command, shell, sentinel) do
    body = command |> String.trim_trailing() |> String.replace(~r/\r?\n/, "\r")
    start = "printf '\\n#{sentinel}start\\n'"

    case Path.basename(shell || "") do
      "fish" ->
        # In fish's single quotes a backslash escapes a quote or a backslash.
        quoted = body |> String.replace("\\", "\\\\") |> String.replace("'", "\\'")

        "#{start}; #{shell} -c '#{quoted}'; printf '\\n#{sentinel}%s\\n' $status"

      # An interactive zsh takes `#` for a command unless told, before it reads the line.
      "zsh" ->
        "setopt interactive_comments\r" <> subshell(start, body, sentinel)

      _ ->
        subshell(start, body, sentinel)
    end
  end

  defp subshell(start, body, sentinel) do
    quoted = String.replace(body, "'", "'\\''")
    "( #{start}; eval '#{quoted}' ); printf '\\n#{sentinel}%s\\n' \"$?\""
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
  defp start_script(thread_id, root, path, script, set) do
    sentinel = "__hal_c2_setup_#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}_"
    line = wrap_script(script["command"], System.get_env("SHELL"), sentinel)

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
               "data" => line <> "\r"
             }
           ]) do
      set.(
        &Map.put(&1, "setupScript", %{
          "name" => script["name"],
          "command" => script["command"],
          "terminalId" => "setup"
        })
      )

      {thread_id, sentinel}
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

  defp await_script({thread_id, sentinel}, status, set, opts) do
    script = %{start: sentinel <> "start", exit: ~r/^#{sentinel}(\d+)$/}

    case collect({thread_id, "setup"}, script, false, "", [], set) do
      {0, tail} ->
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
  # which leaves no exit status, keeping the last lines as the stage's tail.
  defp collect(key, script, started, partial, tail, set) do
    receive do
      {:hal_c2_terminal, ^key, %{"type" => "output", "data" => data}} ->
        {lines, partial} = script_lines(partial, data)
        {started, lines} = from_start(started, lines, script.start)
        {output, rest} = Enum.split_while(lines, &(not Regex.match?(script.exit, &1)))
        next = tail(tail, output)

        case rest do
          [last | _] ->
            [_, code] = Regex.run(script.exit, last)
            {String.to_integer(code), next}

          [] ->
            if next != tail,
              do: set.(&set_stage(&1, "setup-script", "running", %{"tail" => next}))

            collect(key, script, started, partial, next, set)
        end

      {:hal_c2_terminal, ^key, %{"type" => type}} when type in ~w(exited closed) ->
        {nil, tail}

      {:hal_c2_terminal, ^key, _event} ->
        collect(key, script, started, partial, tail, set)
    end
  end

  defp from_start(true, lines, _start), do: {true, lines}

  defp from_start(false, lines, start) do
    case Enum.drop_while(lines, &(&1 != start)) do
      [] -> {false, []}
      [_start | lines] -> {true, lines}
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
        with {:ok, %{"branch" => generated}} <- HalC2.TextGeneration.branch_name(path, text || ""),
             name when name != "" <- sanitize(generated) do
          case HalC2.Vcs.rename_branch(path, old, name) do
            {:ok, new} ->
              HalC2.Vcs.Watch.refresh(path)

              Orchestration.dispatch(%{
                "type" => "thread.metadata.update",
                "threadId" => thread_id,
                "branch" => new,
                "worktreePath" => path
              })

            {:error, reason} ->
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
