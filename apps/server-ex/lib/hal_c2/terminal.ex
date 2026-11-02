defmodule HalC2.Terminal do
  @moduledoc """
  A thread's terminal: one shell in a PTY (via erlexec), its scrollback, and the
  clients attached to it. Serves the `terminal.*` RPCs of
  `packages/contracts/src/terminal.ts` on the MC that owns the thread.

  Each terminal is a process registered by `{thread_id, terminal_id}`; it outlives
  its shell, so an exited terminal can still be attached and read. Output is sent
  to attached clients in batches of `@output_ms`, and the scrollback is written to
  `<home>/terminals/` after `@persist_ms` of quiet so it survives a restart.
  `HalC2.Terminal.Hub` lists every terminal for the metadata stream and polls which
  command each shell is running.

  Attached processes receive `{:hal_c2_terminal, {thread_id, terminal_id}, event}`, with
  events shaped as `TerminalAttachStreamEvent`. An attach also tells the
  attaching pid the events the attach itself produced (its flush, a shell it
  started) as `{:hal_c2_terminal_attach, {thread_id, terminal_id}, event}`,
  since its snapshot already holds them: a socket fans those out to the
  subscriptions it already held, and other direct subscribers may ignore the
  shape (it says nothing its snapshot does not).

  A close ends the process but not who follows it: the attached pids wait in the hub,
  and the next process under that key is handed them when it reports to the hub, and
  sends each a snapshot, so a client stays attached through a close and reopen. A pid that stops following calls
  `detach/3`, closed or not.
  """

  use GenServer, restart: :temporary

  require Logger

  alias HalC2.Terminal.{History, Hub}

  @registry HalC2.Terminal.Registry
  @supervisor HalC2.Terminal.Supervisor
  @default_cols 120
  @default_rows 30
  @output_ms 8
  @persist_ms 500
  @term_ms 1_000
  @stop_ms 5_000
  @call_timeout 15_000
  @default_terminal_id "term-1"
  @fallback_shells ~w(/bin/zsh /bin/bash /bin/sh)
  @excluded_env ~w(PORT ELECTRON_RENDERER_PORT ELECTRON_RUN_AS_NODE BINDIR ROOTDIR EMU PROGNAME)
  @excluded_env_prefixes ~w(HAL_C2_ VITE_ RELEASE_ ERL_)
  @appimage_env ~w(APPIMAGE APPDIR ARGV0 OWD)
  @appimage_search_paths ~w(PATH LD_LIBRARY_PATH XDG_DATA_DIRS GSETTINGS_SCHEMA_DIR)
  @max_file_name 255
  @hashed_prefix "terminal-hashed_"

  # --- API ------------------------------------------------------------------------

  @doc "`terminal.open`: starts the shell unless it is already running; returns its snapshot."
  def open(%{"threadId" => _, "terminalId" => _, "cwd" => cwd} = input) do
    with :ok <- check_cwd(cwd),
         {:ok, input} <- provider_env(input),
         do: call(ensure(input), {:open, input})
  end

  @doc """
  `terminal.attach`: sends `subscriber` the terminal's events from now on and
  returns its snapshot. A terminal that does not exist yet is opened when the
  input has a `cwd`, its shell running the input's `command` if it has one, after
  the shell's startup and with no output missed. Events the attach itself produces
  arrive as `{:hal_c2_terminal_attach, key, event}` (see the moduledoc).
  """
  def attach(%{"threadId" => thread_id, "terminalId" => terminal_id} = input, subscriber) do
    case {lookup(thread_id, terminal_id), input["cwd"]} do
      {nil, nil} ->
        {:error, lookup_error(thread_id, terminal_id)}

      {nil, cwd} ->
        with :ok <- check_cwd(cwd),
             {:ok, input} <- provider_env(input),
             do: call(ensure(input), {:attach, input, subscriber})

      {pid, _} ->
        case running_attach_env(input) do
          {:ok, input} -> call(pid, {:attach, input, subscriber})
          # Only starting a shell needs the provider: a running one can still be attached.
          {:error, _} = refused -> call(pid, {:attach_running, input, subscriber, refused})
        end
    end
  end

  @doc "Stops sending a terminal's events to `subscriber`."
  def detach(thread_id, terminal_id, subscriber) do
    # The hub may still hold it for a process that has not reported yet.
    Hub.forget(thread_id, terminal_id, subscriber)
    if pid = lookup(thread_id, terminal_id), do: GenServer.cast(pid, {:detach, subscriber})
    :ok
  end

  def write(%{"data" => data} = input), do: with_session(input, &call(&1, {:write, data}))

  def resize(%{"cols" => cols, "rows" => rows} = input),
    do: with_session(input, &call(&1, {:resize, cols, rows}))

  def clear(input), do: with_session(input, &call(&1, :clear))

  @doc "`terminal.restart`: a fresh shell with the given launch context and empty scrollback."
  def restart(%{"cwd" => cwd} = input) do
    with :ok <- check_cwd(cwd),
         {:ok, input} <- provider_env(input),
         do: call(ensure(input), {:restart, input})
  end

  @doc "`terminal.close`: one terminal, or every terminal of the thread without a `terminalId`."
  def close(%{"threadId" => thread_id} = input) do
    delete = input["deleteHistory"] == true

    pids =
      case input["terminalId"] do
        nil -> Registry.select(@registry, [{{{thread_id, :_}, :"$1", :_}, [], [:"$1"]}])
        terminal_id -> List.wrap(lookup(thread_id, terminal_id))
      end

    Enum.each(pids, &close_and_wait(&1, delete))

    # Scrollback of terminals that are not running is on disk only.
    if delete do
      input["terminalId"]
      |> case do
        nil -> saved_ids(thread_id)
        terminal_id -> [terminal_id]
      end
      |> Enum.each(&delete_history(thread_id, &1))
    end

    {:ok, nil}
  end

  # Returns once the terminal is gone and unregistered, so a `terminal.open` that
  # follows starts a new one instead of finding the closing one.
  defp close_and_wait(pid, delete) do
    ref = Process.monitor(pid)
    call(pid, {:close, delete})

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    after
      @call_timeout -> Process.demonitor(ref, [:flush])
    end
  end

  @doc "Writes the scrollback of a thread's running terminals to disk now."
  def save(thread_id) do
    for terminal_id <- running(thread_id),
        pid = lookup(thread_id, terminal_id),
        do: call(pid, :save)

    :ok
  end

  @doc "The ids of a thread's terminals that are running."
  def running(thread_id),
    do: Registry.select(@registry, [{{{thread_id, :"$1"}, :_, :_}, [], [:"$1"]}])

  @doc """
  `terminal.list`: the thread's terminals, running or with saved scrollback, in
  tab order (`default`, then `term-N` by number, then others by name).
  """
  def list(%{"threadId" => thread_id}) do
    running = running(thread_id)

    ids =
      (running ++ saved_ids(thread_id))
      |> Enum.uniq()
      |> Enum.sort_by(fn id ->
        case Regex.run(~r/^term-(\d+)$/, id) do
          [_, n] -> {1, String.to_integer(n), id}
          nil -> {if(id == "default", do: 0, else: 2), 0, id}
        end
      end)

    {:ok, %{"terminalIds" => ids}}
  end

  def start_link({thread_id, terminal_id}),
    do:
      GenServer.start_link(__MODULE__, {thread_id, terminal_id},
        name: via(thread_id, terminal_id)
      )

  defp with_session(%{"threadId" => thread_id, "terminalId" => terminal_id}, fun) do
    case lookup(thread_id, terminal_id) do
      nil -> {:error, lookup_error(thread_id, terminal_id)}
      pid -> fun.(pid)
    end
  end

  defp ensure(%{"threadId" => thread_id, "terminalId" => terminal_id}) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, {thread_id, terminal_id}}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp lookup(thread_id, terminal_id) do
    case Registry.lookup(@registry, {thread_id, terminal_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp via(thread_id, terminal_id), do: {:via, Registry, {@registry, {thread_id, terminal_id}}}

  @doc "How long a call to a terminal waits for its reply, in milliseconds."
  def call_timeout, do: @call_timeout

  # A terminal that just closed is not an error to a caller that raced it.
  defp call(pid, message) do
    GenServer.call(pid, message, @call_timeout)
  catch
    :exit, {:noproc, _} ->
      {:error, %{"_tag" => "TerminalSessionLookupError", "message" => "terminal closed"}}

    :exit, {:normal, _} ->
      {:ok, nil}
  end

  # A `providerInstanceId` runs the shell as that provider does: the instance's
  # variables over the client's env, and its home as CODEX_HOME or
  # CLAUDE_CONFIG_DIR. The snapshot never carries env, so secrets stay here. Settings
  # that could not be read refuse every instance: they cannot say what it sets.
  defp provider_env(%{"providerInstanceId" => id} = input) when is_binary(id) do
    if HalC2.Settings.unreadable?(),
      do: {:error, settings_unreadable_error(id)},
      else: provider_env(input, id)
  end

  defp provider_env(input), do: {:ok, input}

  defp provider_env(input, id) do
    settings = HalC2.Settings.settings()
    instance = get_in(settings, ["providerInstances", id])
    driver = (instance || %{})["driver"] || id

    if instance == nil and driver not in ~w(codex claudeAgent) and not HalC2.Acp.agent?(id) do
      {:error,
       %{
         "_tag" => "TerminalProviderInstanceNotFoundError",
         "providerInstanceId" => id,
         "message" => "Provider instance is not available: #{id}"
       }}
    else
      config =
        if instance,
          do: instance["config"] || %{},
          else: get_in(settings, ["providers", id]) || %{}

      env =
        (input["env"] || %{})
        |> Map.merge(HalC2.Settings.instance_env(id))
        |> Map.new(fn
          {key, value} when key in ~w(CODEX_HOME CLAUDE_CONFIG_DIR) -> {key, Path.expand(value)}
          pair -> pair
        end)
        |> put_home(driver, String.trim(config["homePath"] || ""))

      {:ok, input |> Map.delete("providerInstanceId") |> Map.put("env", env)}
    end
  end

  # A live shell needs nothing more from settings, so unreadable ones do not keep a
  # client from it. Without a `cwd` the attach starts nothing, even if the shell ended.
  defp running_attach_env(%{"providerInstanceId" => id} = input) when is_binary(id) do
    if HalC2.Settings.unreadable?(),
      do: {:ok, Map.drop(input, ["cwd", "providerInstanceId"])},
      else: provider_env(input)
  end

  defp running_attach_env(input), do: {:ok, input}

  defp settings_unreadable_error(id) do
    %{
      "_tag" => "TerminalProviderEnvironmentError",
      "providerInstanceId" => id,
      "cause" => "settings.json cannot be read",
      "reason" => "settings.json cannot be read",
      "message" =>
        "Could not prepare the terminal environment for provider instance: #{id}: " <>
          "settings.json cannot be read"
    }
  end

  defp put_home(env, _driver, ""), do: env
  defp put_home(env, "codex", home), do: Map.put(env, "CODEX_HOME", Path.expand(home))

  defp put_home(env, "claudeAgent", home),
    do: Map.put(env, "CLAUDE_CONFIG_DIR", Path.expand(home))

  defp put_home(env, _driver, _home), do: env

  defp check_cwd(cwd) do
    case File.stat(cwd) do
      {:ok, %{type: :directory}} ->
        :ok

      {:ok, _} ->
        {:error,
         %{
           "_tag" => "TerminalCwdNotDirectoryError",
           "cwd" => cwd,
           "message" => "Terminal cwd is not a directory: #{cwd}"
         }}

      {:error, :enoent} ->
        {:error,
         %{
           "_tag" => "TerminalCwdNotFoundError",
           "cwd" => cwd,
           "message" => "Terminal cwd does not exist: #{cwd}"
         }}

      {:error, reason} ->
        {:error,
         %{
           "_tag" => "TerminalCwdStatError",
           "cwd" => cwd,
           "message" => "Failed to access terminal cwd: #{cwd} (#{reason})"
         }}
    end
  end

  defp lookup_error(thread_id, terminal_id),
    do: %{
      "_tag" => "TerminalSessionLookupError",
      "threadId" => thread_id,
      "terminalId" => terminal_id,
      "message" => "Unknown terminal thread: #{thread_id}, terminal: #{terminal_id}"
    }

  defp not_running_error(state),
    do: %{
      "_tag" => "TerminalNotRunningError",
      "threadId" => state.thread_id,
      "terminalId" => state.terminal_id,
      "message" =>
        "Terminal is not running for thread: #{state.thread_id}, terminal: #{state.terminal_id}"
    }

  # --- session --------------------------------------------------------------------

  @impl true
  def init({thread_id, terminal_id}) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       thread_id: thread_id,
       terminal_id: terminal_id,
       cwd: nil,
       worktree_path: nil,
       env: nil,
       cols: @default_cols,
       rows: @default_rows,
       status: "starting",
       os_pid: nil,
       exit_code: nil,
       exit_signal: nil,
       history: History.new(read_history(thread_id, terminal_id)),
       carry: "",
       output: [],
       output_timer: nil,
       persist_timer: nil,
       subprocess: false,
       child_label: nil,
       seq: 0,
       updated_at: now(),
       subscribers: %{},
       # The pid of an attach in flight, told what the attach itself produces
       # as `:hal_c2_terminal_attach` (see `handle_call({:attach, …})`).
       attach_capture: nil,
       error: nil
     }}
  end

  @impl true
  def handle_call({:open, input}, _from, state) do
    state = open_session(state, input)
    {:reply, {:ok, snapshot(state)}, state}
  end

  def handle_call({:attach, input, subscriber}, _from, state) do
    # The snapshot holds the pending batch and whatever this attach starts, so a
    # subscriber attaching again is left out of the events they produce; others get them.
    # Those events are also told to the attaching pid as `:hal_c2_terminal_attach`:
    # a socket attaching for a new subscription fans them out to the subscriptions
    # it already holds to this terminal (its per-subscription floors keep the new
    # one from being told twice), which a plain re-send would break for a direct
    # subscriber reading snapshot-plus-events. Other direct subscribers ignore
    # the shape.
    {ref, others} = Map.pop(state.subscribers, subscriber)

    # `Map.put/3`, not a strict update: a terminal whose suspend timed out
    # in a hot reload never ran `code_change/3` and has no field yet.
    state = flush_output(%{state | subscribers: others} |> Map.put(:attach_capture, subscriber))

    open? =
      (state.cwd == nil and input["cwd"] != nil) or
        (state.os_pid == nil and input["cwd"] != nil and input["restartIfNotRunning"] == true)

    state =
      if open?,
        do: open_session(state, input),
        else: resize_to(state, input["cols"] || state.cols, input["rows"] || state.rows)

    state = Map.put(state, :attach_capture, nil)
    subscribers = Map.put(state.subscribers, subscriber, ref || Process.monitor(subscriber))

    # A shell that failed to start while attaching is explained to the attaching
    # client too; its snapshot alone only says "error".
    if open? and state.status == "error",
      do: send(subscriber, {:hal_c2_terminal, {state.thread_id, state.terminal_id}, state.error})

    {:reply, {:ok, snapshot(state)}, %{state | subscribers: subscribers}}
  end

  def handle_call({:attach_running, _input, _subscriber, refused}, _from, %{os_pid: nil} = state),
    do: {:reply, refused, state}

  def handle_call({:attach_running, input, subscriber, _refused}, from, state),
    do: handle_call({:attach, Map.delete(input, "cwd"), subscriber}, from, state)

  def handle_call({:write, _data}, _from, %{os_pid: nil} = state),
    do: {:reply, {:error, not_running_error(state)}, state}

  def handle_call({:write, data}, _from, state) do
    :ok = :exec.send(state.os_pid, data)
    {:reply, {:ok, nil}, state}
  end

  def handle_call({:resize, cols, rows}, _from, state),
    do: {:reply, {:ok, nil}, resize_to(state, cols, rows)}

  def handle_call(:clear, _from, state) do
    # Output printed before the clear must reach the clients before "cleared".
    state = flush_output(state)
    state = %{state | history: History.clear(state.history)} |> schedule_persist()
    {:reply, {:ok, nil}, emit(state, %{"type" => "cleared"})}
  end

  def handle_call({:restart, input}, _from, state) do
    # Stopped before the clear, so the old shell's last output is not in the new scrollback.
    state =
      state
      |> stop_shell()
      |> launch_context(input)
      |> Map.update!(:history, &History.clear/1)
      |> start_shell("restarted")

    {:reply, {:ok, snapshot(state)}, state}
  end

  def handle_call(:save, _from, state) do
    if state.persist_timer, do: Process.cancel_timer(state.persist_timer)
    persist(state)
    {:reply, :ok, %{state | persist_timer: nil}}
  end

  def handle_call({:close, delete_history}, _from, state) do
    {:stop, :normal, {:ok, nil}, state |> stop_shell() |> retire(delete_history)}
  end

  @impl true
  def handle_cast({:detach, subscriber}, state) do
    case Map.pop(state.subscribers, subscriber) do
      {nil, _} ->
        {:noreply, state}

      {ref, subscribers} ->
        Process.demonitor(ref, [:flush])
        {:noreply, %{state | subscribers: subscribers}}
    end
  end

  @impl true
  def handle_info({:stdout, os_pid, data}, %{os_pid: os_pid} = state),
    do: {:noreply, take_output(state, data)}

  def handle_info({:DOWN, os_pid, :process, _pid, reason}, %{os_pid: os_pid} = state) do
    {code, signal} =
      case reason do
        :normal ->
          {0, nil}

        {:exit_status, status} ->
          case :exec.status(status) do
            {:status, code} -> {code, nil}
            {:signal, signal, _core} -> {nil, signal_number(signal)}
          end

        _ ->
          {nil, nil}
      end

    state =
      %{
        flush_output(state)
        | status: "exited",
          os_pid: nil,
          exit_code: code,
          exit_signal: signal,
          subprocess: false,
          child_label: nil
      }
      |> emit(%{"type" => "exited", "exitCode" => code, "exitSignal" => signal})

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    case state.subscribers do
      %{^pid => ^ref} -> {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
      _ -> {:noreply, state}
    end
  end

  def handle_info(:output, state), do: {:noreply, flush_output(state)}

  # From `HalC2.Terminal.Hub`: too many terminals have ended. Started again since, this
  # one stays.
  def handle_info(:evict, %{os_pid: nil} = state), do: {:stop, :normal, retire(state, false)}

  # From a restarted `HalC2.Terminal.Hub`, which lost its list.
  # Who followed this terminal when its last process closed.
  def handle_info({:followers, pids}, state) do
    state = flush_output(state)
    key = {state.thread_id, state.terminal_id}
    event = %{"type" => "snapshot", "snapshot" => snapshot(state)}

    subscribers =
      Enum.reduce(pids, state.subscribers, fn pid, subscribers ->
        if is_map_key(subscribers, pid) do
          subscribers
        else
          send(pid, {:hal_c2_terminal, key, event})
          Map.put(subscribers, pid, Process.monitor(pid))
        end
      end)

    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info(:report, state) do
    Hub.upsert(summary(state), self())
    {:noreply, state}
  end

  def handle_info(:persist, state) do
    persist(state)
    {:noreply, %{state | persist_timer: nil}}
  end

  # From `HalC2.Terminal.Hub`: the command running in the shell changed.
  def handle_info({:activity, subprocess, label}, state) do
    if {subprocess, label} == {state.subprocess, state.child_label} or state.os_pid == nil do
      {:noreply, state}
    else
      state = %{state | subprocess: subprocess, child_label: label}

      {:noreply,
       emit(state, %{
         "type" => "activity",
         "hasRunningSubprocess" => subprocess,
         "label" => label(state)
       })}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # A terminal from before the attach capture has no field for it.
  @impl true
  def code_change(_old, state, _extra), do: {:ok, Map.put_new(state, :attach_capture, nil)}

  @impl true
  def terminate(_reason, state) do
    # Unregister here: the registry drops a dead process's key only afterwards, and
    # until then a lookup finds the terminal that is already closing.
    Registry.unregister(@registry, {state.thread_id, state.terminal_id})
    state = stop_shell(state)
    if state.persist_timer, do: persist(state)
    :ok
  end

  # The end of the process, its followers left with the hub for the next one.
  defp retire(state, delete_history) do
    state = emit(state, %{"type" => "closed"})
    Hub.closed(state.thread_id, state.terminal_id, Map.keys(state.subscribers))
    unless delete_history, do: persist(state)
    %{state | persist_timer: nil, cwd: nil}
  end

  # Starts the shell, or updates a running one, the way `terminal.open` does: a new
  # cwd, worktree, or env replaces the shell and its scrollback; an exited shell is
  # started again with empty scrollback.
  defp open_session(state, input) do
    worktree = Map.get(input, "worktreePath", state.worktree_path)
    ended? = state.status in ["exited", "error"]

    changed =
      state.cwd != nil and
        (state.cwd != input["cwd"] or state.env != env_input(input) or
           state.worktree_path != worktree)

    state =
      cond do
        changed or ended? ->
          state
          |> stop_shell()
          |> launch_context(input)
          |> Map.update!(:history, &History.clear/1)
          |> schedule_persist()

        state.cwd == nil ->
          launch_context(state, input)

        true ->
          state
      end

    if state.os_pid,
      do: resize_to(state, input["cols"] || state.cols, input["rows"] || state.rows),
      else:
        start_shell(
          %{state | cols: input["cols"] || state.cols, rows: input["rows"] || state.rows},
          if(ended?, do: "restarted", else: "started"),
          input["command"]
        )
  end

  defp launch_context(state, input),
    do: %{
      state
      | cwd: input["cwd"],
        worktree_path: Map.get(input, "worktreePath", state.worktree_path),
        env: env_input(input),
        cols: input["cols"] || state.cols,
        rows: input["rows"] || state.rows
    }

  defp env_input(input) do
    case input["env"] do
      env when is_map(env) and map_size(env) > 0 -> env
      _ -> nil
    end
  end

  defp start_shell(state, event, command \\ nil) do
    state = stop_shell(state)

    options = [
      :stdin,
      :stdout,
      # stderr on the pty too: bash is interactive only when fd 2 is a terminal;
      # otherwise it prints no prompt and Ctrl-C ends the shell itself.
      {:stderr, :stdout},
      :pty,
      # erlexec turns the pty's echo off by default, and readline follows it,
      # so nothing the user typed would show.
      :pty_echo,
      :monitor,
      {:winsz, {state.rows, state.cols}},
      {:cd, String.to_charlist(state.cwd)},
      {:env, [:clear | spawn_env(state.env)]},
      {:kill_timeout, 1}
    ]

    case Enum.find(shells(), &File.exists?(hd(&1))) do
      nil ->
        failed(state, "No shell found (tried #{Enum.map_join(shells(), ", ", &hd/1)})")

      shell ->
        argv = if command, do: shell ++ ["-ic", command], else: shell

        case :exec.run(argv, options) do
          {:ok, exec_pid, os_pid} ->
            # `:exec.run_link` would drop the DOWN message. Linked, the shell is killed
            # with the terminal even when `terminate/2` never runs (a killed terminal).
            Process.link(exec_pid)

            state = %{
              state
              | status: "running",
                os_pid: os_pid,
                exit_code: nil,
                exit_signal: nil,
                subprocess: false,
                child_label: nil,
                carry: ""
            }

            state = advance(state)
            event = %{"type" => event, "snapshot" => snapshot(state)}
            emit(state, event, advance: false)

          {:error, reason} ->
            failed(state, "Could not start #{hd(shell)}: #{inspect(reason)}")
        end
    end
  end

  defp failed(state, message) do
    Logger.warning("terminal #{state.terminal_id}: #{message}")

    state =
      emit(%{state | status: "error", os_pid: nil}, %{"type" => "error", "message" => message})

    %{
      state
      | error: %{
          "type" => "error",
          "message" => message,
          "threadId" => state.thread_id,
          "terminalId" => state.terminal_id,
          "sequence" => state.seq
        }
    }
  end

  defp stop_shell(%{os_pid: nil} = state), do: state

  # `:exec.stop` only signals the shell, and an interactive shell ignores its SIGTERM.
  # erlexec's own SIGKILL waits for its event loop to fall idle, which output from any
  # other process it runs can put off indefinitely, so the kill is sent from here. The
  # monitor's DOWN says the shell is gone, so a close or restart that returns has freed
  # the OS process.
  defp stop_shell(state) do
    state = if :exec.stop(state.os_pid) == :ok, do: kill_unless_gone(state), else: state
    %{flush_output(state) | os_pid: nil}
  end

  defp kill_unless_gone(state) do
    case await_down(state, @term_ms) do
      {:gone, state} ->
        state

      {:running, state} ->
        :exec.kill(state.os_pid, 9)
        {_, state} = await_down(state, @stop_ms)
        state
    end
  end

  # erlexec sends all of a shell's output before its DOWN; what arrives in between is
  # still the shell's and belongs in the scrollback a close saves. `ms` bounds the
  # whole wait, so a shell that keeps printing cannot renew it.
  defp await_down(state, ms),
    do: await_until(state, System.monotonic_time(:millisecond) + ms)

  defp await_until(%{os_pid: os_pid} = state, deadline) do
    receive do
      {:stdout, ^os_pid, data} -> await_until(take_output(state, data), deadline)
      {:DOWN, ^os_pid, :process, _pid, _reason} -> {:gone, state}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:running, state}
    end
  end

  # Output of the shell: into the scrollback and the batch sent after `@output_ms`.
  defp take_output(state, data) do
    {text, carry} = History.utf8(state.carry, data)

    state = %{
      state
      | carry: carry,
        history: History.append(state.history, text),
        output: [state.output, text]
    }

    state =
      if state.output_timer,
        do: state,
        else: %{state | output_timer: Process.send_after(self(), :output, @output_ms)}

    schedule_persist(state)
  end

  defp resize_to(state, cols, rows) do
    if state.os_pid && {cols, rows} != {state.cols, state.rows},
      do: :exec.winsz(state.os_pid, rows, cols)

    %{state | cols: cols, rows: rows}
  end

  defp flush_output(%{output: []} = state), do: state

  defp flush_output(state) do
    if state.output_timer, do: Process.cancel_timer(state.output_timer)
    data = IO.iodata_to_binary(state.output)
    state = %{state | output: [], output_timer: nil}
    if data == "", do: state, else: emit(state, %{"type" => "output", "data" => data})
  end

  # Sends an event to attached clients (the `started` snapshot goes out as
  # `snapshot`) and keeps the hub's summary current.
  defp emit(state, event, opts \\ []) do
    state = if Keyword.get(opts, :advance, true), do: advance(state), else: state

    event =
      Map.merge(event, %{
        "threadId" => state.thread_id,
        "terminalId" => state.terminal_id,
        "sequence" => state.seq
      })

    attach_event =
      if event["type"] == "started",
        do: %{"type" => "snapshot", "snapshot" => event["snapshot"]},
        else: event

    key = {state.thread_id, state.terminal_id}
    for {pid, _} <- state.subscribers, do: send(pid, {:hal_c2_terminal, key, attach_event})

    # An attach in flight left its pid out above; it is told as an attach event
    # instead (see `handle_call({:attach, …})`) — except an error, which the
    # attach handler sends the attacher itself, as the plain event, so the
    # attacher is told exactly once.
    if capture = Map.get(state, :attach_capture),
      do:
        unless(event["type"] == "error",
          do: send(capture, {:hal_c2_terminal_attach, key, attach_event})
        )

    if event["type"] in ~w(started restarted exited error activity),
      do: Hub.upsert(summary(state), self())

    state
  end

  defp advance(state), do: %{state | seq: state.seq + 1, updated_at: now()}

  defp snapshot(state) do
    state
    |> summary()
    |> Map.drop(["hasRunningSubprocess"])
    |> Map.merge(%{"history" => History.value(state.history), "sequence" => state.seq})
  end

  defp summary(state),
    do: %{
      "threadId" => state.thread_id,
      "terminalId" => state.terminal_id,
      "cwd" => state.cwd,
      "worktreePath" => state.worktree_path,
      "status" => state.status,
      "pid" => state.os_pid,
      "exitCode" => state.exit_code,
      "exitSignal" => state.exit_signal,
      "hasRunningSubprocess" => state.subprocess,
      "label" => label(state),
      "updatedAt" => state.updated_at
    }

  defp label(%{subprocess: true, child_label: label}) when is_binary(label) and label != "",
    do: String.slice(label, 0, 128)

  defp label(%{terminal_id: terminal_id}) do
    case Regex.run(~r/^term(?:inal)?-(\d+)$/i, terminal_id) do
      [_, n] -> "Terminal #{n}"
      nil -> String.slice(terminal_id, 0, 128)
    end
  end

  # --- shell and env --------------------------------------------------------------

  # The user's shell first, then common ones (`:terminal_shells` replaces the
  # common ones, for tests of a machine without them). zsh must not print its partial-line
  # marker into a fresh terminal.
  defp shells do
    requested = System.get_env("SHELL", "") |> String.split() |> List.first()

    [requested | Application.get_env(:hal_c2, :terminal_shells, @fallback_shells)]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.map(fn shell ->
      if Path.basename(shell) == "zsh", do: [shell, "-o", "nopromptsp"], else: [shell]
    end)
  end

  defp spawn_env(runtime_env) do
    base =
      for {key, value} <- System.get_env(),
          upper = String.upcase(key),
          upper not in @excluded_env,
          not String.starts_with?(upper, @excluded_env_prefixes),
          into: %{},
          do: {key, value}

    env =
      base
      |> without_appimage()
      |> Map.merge(runtime_env || %{})
      |> Map.put("TERM", "xterm-256color")
      |> Map.put_new("COLORTERM", "truecolor")

    for {key, value} <- env, value != "" or key == "COLORTERM", do: {key, value}
  end

  # Started from an AppImage, the MC's environment describes the AppImage: its markers,
  # and search paths into its temporary mount. A shell resolving tools there would run
  # the bundle's, so only the user's entries are left, and a search path with none goes,
  # for its consumers to use their defaults.
  defp without_appimage(env) when is_map_key(env, "APPIMAGE") or is_map_key(env, "APPDIR") do
    mount = env |> Map.get("APPDIR", "") |> String.trim_trailing("/")
    env = Map.drop(env, @appimage_env)

    if mount == "",
      do: env,
      else: Enum.reduce(@appimage_search_paths, env, &drop_mount(&2, &1, mount))
  end

  defp without_appimage(env), do: env

  defp drop_mount(env, key, mount) when is_map_key(env, key) do
    kept =
      env[key]
      |> String.split(":", trim: true)
      |> Enum.reject(&(&1 == mount or String.starts_with?(&1, mount <> "/")))

    if kept == [], do: Map.delete(env, key), else: Map.put(env, key, Enum.join(kept, ":"))
  end

  defp drop_mount(env, _key, _mount), do: env

  # --- history on disk ------------------------------------------------------------

  defp schedule_persist(%{persist_timer: nil} = state),
    do: %{state | persist_timer: Process.send_after(self(), :persist, @persist_ms)}

  defp schedule_persist(state), do: state

  defp persist(state) do
    write_history(state.thread_id, state.terminal_id, History.value(state.history))
  rescue
    error -> Logger.warning("terminal history not saved: #{Exception.message(error)}")
  end

  defp read_history(thread_id, terminal_id) do
    path = history_path(thread_id, terminal_id)
    max = %History{}.max_bytes

    case File.stat(path) do
      {:ok, %{size: size}} when size > max ->
        {:ok, file} = File.open(path, [:read, :binary])
        {:ok, data} = :file.pread(file, size - max, max)
        File.close(file)
        data

      {:ok, _} ->
        File.read!(path)

      {:error, _} ->
        if adopt_thread_log(thread_id, terminal_id, path),
          do: read_history(thread_id, terminal_id),
          else: ""
    end
  end

  # An older layout kept one log per thread, which is the default terminal's history.
  defp adopt_thread_log(thread_id, @default_terminal_id, path) do
    safe_thread_id = String.replace(thread_id, ~r/[^a-zA-Z0-9._-]/, "_")
    File.rename(Path.join(Path.dirname(path), "#{safe_thread_id}.log"), path) == :ok
  end

  defp adopt_thread_log(_thread_id, _terminal_id, _path), do: false

  @doc """
  A thread's saved scrollback as `[{terminal_id, text}]`, read from disk so it works
  whether or not its terminals are running. A thread file carries it.
  """
  def saved_scrollback(thread_id),
    do: for(id <- saved_ids(thread_id), do: {id, read_history(thread_id, id)})

  @doc "Saves scrollback for a thread's terminal, as a thread file brings it."
  def put_scrollback(thread_id, terminal_id, text),
    do: write_history(thread_id, terminal_id, text)

  defp write_history(thread_id, terminal_id, text) do
    path = history_path(thread_id, terminal_id)
    File.mkdir_p!(Path.dirname(path))
    if hashed_history?(path), do: File.write!(id_path(path), terminal_id)
    File.write!(path, text)
  end

  defp delete_history(thread_id, terminal_id) do
    path = history_path(thread_id, terminal_id)
    File.rm(path)
    if hashed_history?(path), do: File.rm(id_path(path))
  end

  # The ids of a thread's terminals with scrollback on disk.
  defp saved_ids(thread_id) do
    prefix = "terminal_#{encode_id(thread_id)}_"

    named =
      for path <- Path.wildcard(terminals_path(prefix <> "*.log")),
          name = Path.basename(path, ".log"),
          {:ok, id} <- [
            Base.url_decode64(String.replace_prefix(name, prefix, ""), padding: false)
          ],
          do: id

    hashed =
      for path <- Path.wildcard(terminals_path("#{@hashed_prefix}#{hash_id(thread_id)}_*.id")),
          {:ok, id} <- [File.read(path)],
          do: id

    named ++ hashed
  end

  # The ids are in the file name so that the name alone says whose scrollback it is.
  # Ids too long for that are hashed, with the terminal's id in a file beside it.
  defp history_path(thread_id, terminal_id) do
    name = "terminal_#{encode_id(thread_id)}_#{encode_id(terminal_id)}.log"

    if byte_size(name) <= @max_file_name,
      do: terminals_path(name),
      else: terminals_path("#{@hashed_prefix}#{hash_id(thread_id)}_#{hash_id(terminal_id)}.log")
  end

  defp hashed_history?(path), do: String.starts_with?(Path.basename(path), @hashed_prefix)
  defp id_path(path), do: Path.rootname(path, ".log") <> ".id"
  defp terminals_path(name), do: Path.join([HalC2.Paths.state_dir(), "terminals", name])
  defp encode_id(id), do: Base.url_encode64(id, padding: false)
  defp hash_id(id), do: encode_id(:crypto.hash(:sha256, id))

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  @signals %{sighup: 1, sigint: 2, sigquit: 3, sigkill: 9, sigsegv: 11, sigpipe: 13, sigterm: 15}
  defp signal_number(signal) when is_integer(signal), do: signal
  defp signal_number(signal), do: Map.get(@signals, signal)
end
