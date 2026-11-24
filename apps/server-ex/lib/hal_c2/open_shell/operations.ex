defmodule HalC2.OpenShell.Operations do
  @moduledoc """
  The OpenShell lifecycle commands a client's Settings runs on this MC
  (`server.runOpenShellOperation`): install (also update and repair), check,
  rotate and uninstall, each `HalC2.OpenShell.Command.run/2`, the code the CLI
  runs. One runs at a time: another asked for while it runs is answered `busy` at
  once, and a CLI command holding the lifecycle lock fails the operation with
  `[busy]` (`HalC2.OpenShell.Install`).

  Its state, `OpenShellOperationState`, is what the `openShell` shape shows each
  subscriber, again on every change: the operation running or last run, its number
  (`run`), its steps so far, and the outcome once it ended, worded for Settings
  (`HalC2.OpenShell.Command.settings_error/1`). A client tells its own run's frames
  from older ones by the number its reply carries: each run's is larger than the
  last's, across restarts of this server (its last number outlives it) and of the
  MC (it starts from the clock in microseconds). Until this server runs one, there
  is no operation and the number is when it started, larger than any run before
  it: a client still waiting on a run that sees that knows the server restarted
  and the run's outcome went with it. An operation runs
  in a process of its own, unlinked, so a restart of this server never stops one
  halfway; the lock keeps a second from starting under it. A server started while
  one still runs takes it back (`HalC2.OpenShell.Operations`'s own name only): it
  shows it running, under its number, and its later steps and its outcome, so a
  client reconnecting after the restart sees it go on and end. The steps from
  before the restart are not kept.

  Nothing a client sends names a path, an archive or a URL: the input is the
  operation, `drain` (the names of the sandboxes its user agreed to delete, from
  the `sandboxes-running` outcome that asked) and `force`, and any other key is
  refused. What is installed is the pinned manifest's.

  The detail of an outcome (its message, which can name the gateway's address and
  paths on this machine, and the names a drain sends back) is for sessions that
  may run operations: `viewed/2` is what the others see.
  """
  use GenServer

  require Logger

  alias HalC2.OpenShell.Command

  @operations ~w(install check rotate uninstall)
  @flags ~w(drain force)
  @step_limit 20

  @doc "The scopes a session needs to run an operation (`HalC2.Rpc.required_scopes/2`)."
  def scopes, do: ["access:write", "terminal:operate"]

  @doc """
  Whether a session holding `scopes` (`:all` for the MC's own token) may run one,
  as the `canManage` and `manageReason` a client's Settings disables its actions by.
  """
  def manage(scopes) do
    missing = if scopes == :all, do: [], else: Enum.reject(scopes(), &(&1 in scopes))

    %{
      "canManage" => missing == [],
      "manageReason" =>
        if(missing != [],
          do:
            "Installing and managing OpenShell needs a session that can manage this machine and use its terminal (#{Enum.join(missing, ", ")}). Pair this device with a link that grants them."
        )
    }
  end

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  Starts the operation `input` names (`%{"operation" => ..., "drain"?, "force"?}`)
  and answers `{:ok, state}` with it running, or `{:error, %{"_tag" =>
  "ServerOpenShellOperationError", "reason" => "invalid" | "busy", "message" => ...}}`.
  """
  def run(input, server \\ __MODULE__) do
    with {:ok, operation, opts} <- parse(input),
         do: GenServer.call(server, {:run, operation, opts})
  end

  @doc "The state now."
  def state(server \\ __MODULE__), do: GenServer.call(server, :state)

  def subscribe(pid, ref \\ nil, server \\ __MODULE__),
    do: GenServer.call(server, {:subscribe, pid, ref})

  def unsubscribe(pid, ref \\ nil, server \\ __MODULE__),
    do: GenServer.cast(server, {:unsubscribe, pid, ref})

  # --- input ------------------------------------------------------------------------

  defp parse(%{"operation" => operation} = input) when operation in @operations do
    extra = input |> Map.keys() |> Enum.reject(&(&1 in ["operation" | @flags]))
    flags = Map.take(input, @flags)

    cond do
      extra != [] ->
        invalid("Unknown arguments: #{Enum.join(Enum.sort(extra), ", ")}.")

      not names?(Map.get(flags, "drain", [])) ->
        invalid("drain is the names of the sandboxes to delete.")

      not is_boolean(Map.get(flags, "force", false)) ->
        invalid("force is true or false.")

      operation == "check" and flags != %{} ->
        invalid("check takes neither drain nor force.")

      true ->
        {:ok, operation,
         Enum.flat_map(flags, fn
           {"drain", names} -> [drain: names]
           {"force", true} -> [force: true]
           {"force", false} -> []
         end)}
    end
  end

  defp parse(_input),
    do: invalid("The operation is one of #{Enum.join(@operations, ", ")}.")

  defp names?(names),
    do: is_list(names) and Enum.all?(names, &(is_binary(&1) and &1 != ""))

  defp invalid(message), do: refusal("invalid", message)

  defp refusal(reason, message),
    do:
      {:error,
       %{"_tag" => "ServerOpenShellOperationError", "reason" => reason, "message" => message}}

  # --- server -----------------------------------------------------------------------

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    state = %{
      name: name,
      runner: Keyword.get(opts, :runner),
      # The wall clock in microseconds, but for a test's.
      clock: Keyword.get(opts, :clock),
      job: nil,
      # When this server started: above every run before it, so a client waiting
      # on a run sees the restart.
      run: number(Keyword.get(opts, :clock)),
      operation: nil,
      steps: [],
      result: nil,
      watchers: %{}
    }

    {:ok, adopt(state, running(name))}
  end

  # The run an earlier server under this name left running, taken back. One whose
  # process has gone since ended without this server seeing how.
  defp adopt(state, %{token: token, pid: pid, operation: operation, run: run}) do
    state = %{state | run: run, operation: operation}

    if Process.alive?(pid) do
      %{state | job: {token, {pid, Process.monitor(pid)}}}
    else
      note_running(state, nil)
      %{state | result: lost(operation, :gone)}
    end
  end

  defp adopt(state, nil), do: state

  # Where a run is noted while it runs, for a server started under the same name to
  # take back: only a named server's, as only it is found again.
  defp running(nil), do: nil
  defp running(name), do: :persistent_term.get({__MODULE__, :running, name}, nil)

  defp note_running(%{name: nil}, _job), do: :ok

  defp note_running(%{name: name}, job),
    do: :persistent_term.put({__MODULE__, :running, name}, job)

  @impl true
  def handle_call({:run, operation, _opts}, _from, %{job: {_, _}} = state) do
    {:reply,
     refusal(
       "busy",
       "OpenShell's #{state.operation} is already running on this MC. Try #{operation} again once it finishes."
     ), state}
  end

  def handle_call({:run, operation, opts}, _from, state) do
    # The job tells the server by its name, so one started after a restart hears
    # the rest of it.
    server = state.name || self()
    token = make_ref()

    runner =
      state.runner || Application.get_env(:hal_c2, :openshell_operation_runner, &Command.run/2)

    progress = fn step -> tell(server, {:step, token, step}) end

    {pid, monitor} =
      spawn_monitor(fn ->
        tell(server, {:done, token, attempt(runner, operation, opts ++ [progress: progress])})
      end)

    state = %{
      state
      | job: {token, {pid, monitor}},
        run: number(Map.get(state, :clock)),
        operation: operation,
        steps: [],
        result: nil
    }

    note_running(state, %{token: token, pid: pid, operation: operation, run: state.run})
    changed(state)
    {:reply, {:ok, snapshot(state)}, state}
  end

  def handle_call(:state, _from, state), do: {:reply, {:ok, snapshot(state)}, state}

  def handle_call({:subscribe, pid, ref}, _from, state) do
    state = %{state | watchers: HalC2.Watchers.add(state.watchers, pid, ref)}
    {:reply, {:ok, snapshot(state)}, state}
  end

  @impl true
  def handle_cast({:unsubscribe, pid, ref}, state),
    do: {:noreply, %{state | watchers: HalC2.Watchers.remove(state.watchers, pid, ref)}}

  @impl true
  def handle_info({:step, token, step}, %{job: {token, _}} = state) do
    state = %{state | steps: Enum.take(state.steps ++ [step], -@step_limit)}
    changed(state)
    {:noreply, state}
  end

  def handle_info({:done, token, result}, %{job: {token, {_pid, monitor}}} = state) do
    Process.demonitor(monitor, [:flush])
    finish(state, outcome(result))
  end

  # Its process went without an answer: killed, since `attempt/3` catches the rest.
  def handle_info({:DOWN, monitor, :process, _pid, reason}, %{job: {_, {_, monitor}}} = state) do
    finish(state, lost(state.operation, reason))
  end

  def handle_info({:DOWN, monitor, :process, pid, _}, state),
    do: {:noreply, %{state | watchers: HalC2.Watchers.down(state.watchers, monitor, pid)}}

  def handle_info(_other, state), do: {:noreply, state}

  defp lost(operation, reason) do
    Logger.error("OpenShell's #{operation} stopped without an outcome: #{inspect(reason)}")

    %{
      "ok" => false,
      "code" => nil,
      "message" =>
        "OpenShell's #{operation} stopped before it finished. The MC's log says why; Refresh shows what is installed now.",
      "sandboxes" => nil,
      "drain" => nil
    }
  end

  defp finish(state, result) do
    note_running(state, nil)
    state = %{state | job: nil, result: result}
    changed(state)
    {:noreply, state}
  end

  # The runner's answer, or its failure as one: whatever it raises goes to the log.
  defp attempt(runner, operation, opts) do
    runner.(String.to_existing_atom(operation), opts)
  catch
    kind, reason ->
      Logger.error(
        "OpenShell's #{operation} failed: " <> Exception.format(kind, reason, __STACKTRACE__)
      )

      {:error, "OpenShell's #{operation} failed. The MC's log says why."}
  end

  defp outcome({:ok, text}),
    do: %{"ok" => true, "code" => nil, "message" => text, "sandboxes" => nil, "drain" => nil}

  defp outcome({:error, message}) when is_binary(message),
    do: Map.put(Command.settings_error(message), "ok", false)

  defp outcome(other) do
    Logger.error("OpenShell's operation answered #{inspect(other)}")
    outcome({:error, "The operation gave no outcome the MC understands."})
  end

  @doc """
  What a session holding `scopes` is shown of `snapshot`: all of it when it may run
  operations (`scopes/0`); otherwise the operation, its steps, and how it ended
  as ok or not, its problem's code and how many reviews it would stop, but not its
  message or the sandboxes' names.
  """
  def viewed(snapshot, scopes) do
    case {manage(scopes), snapshot["result"]} do
      {%{"canManage" => true}, _} ->
        snapshot

      {_, nil} ->
        snapshot

      {_, result} ->
        %{
          snapshot
          | "result" => %{result | "message" => viewed_message(snapshot, result), "drain" => nil}
        }
    end
  end

  defp viewed_message(%{"operation" => operation}, %{"ok" => true}),
    do: "OpenShell's #{operation} finished."

  defp viewed_message(%{"operation" => operation}, %{"code" => code}),
    do:
      "OpenShell's #{operation} failed#{if code, do: " (#{code})"}. A session that can manage this machine sees why."

  # A step or the outcome, for the server under `server` now, if there is one.
  defp tell(server, message) when is_pid(server), do: send(server, message)

  defp tell(server, message) do
    case Process.whereis(server) do
      nil -> :ok
      pid -> send(pid, message)
    end
  end

  defp snapshot(state) do
    %{
      "operation" => state.operation,
      "run" => state.run,
      "running" => state.job != nil,
      "steps" => state.steps,
      "result" => state.result
    }
  end

  # The last number handed out, kept where a restart of this server (not of the MC)
  # leaves it.
  @numbered {__MODULE__, :run}

  # A number above every one before it: above the last this MC handed out, and from
  # the clock so above every one before the MC started too. A clock stepped back
  # across an MC restart can give one below an earlier run's; a client waiting on a
  # run tells that from its frames, whose number goes below the last one's
  # (SandboxSettingsController.cpp, apps/tui's sandboxes.ts).
  defp number(clock) do
    run = max(:persistent_term.get(@numbered, 0) + 1, now(clock))
    :persistent_term.put(@numbered, run)
    run
  end

  defp now(nil), do: System.os_time(:microsecond)
  defp now(clock), do: clock.()

  defp changed(state),
    do: HalC2.Watchers.notify(state.watchers, {:hal_c2_openshell, node(), snapshot(state)})
end
