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
  halfway; the lock keeps a second from starting under it.

  Nothing a client sends names a path, an archive or a URL: the input is the
  operation and its `drain` and `force` flags, and any other key is refused. What
  is installed is the pinned manifest's.
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

      Enum.any?(flags, fn {_, value} -> not is_boolean(value) end) ->
        invalid("drain and force are true or false.")

      operation == "check" and flags != %{} ->
        invalid("check takes neither drain nor force.")

      true ->
        {:ok, operation, for({key, true} <- flags, do: {String.to_existing_atom(key), true})}
    end
  end

  defp parse(_input),
    do: invalid("The operation is one of #{Enum.join(@operations, ", ")}.")

  defp invalid(message), do: refusal("invalid", message)

  defp refusal(reason, message),
    do:
      {:error,
       %{"_tag" => "ServerOpenShellOperationError", "reason" => reason, "message" => message}}

  # --- server -----------------------------------------------------------------------

  @impl true
  def init(opts) do
    {:ok,
     %{
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
     }}
  end

  @impl true
  def handle_call({:run, operation, _opts}, _from, %{job: {_, _}} = state) do
    {:reply,
     refusal(
       "busy",
       "OpenShell's #{state.operation} is already running on this MC. Try #{operation} again once it finishes."
     ), state}
  end

  def handle_call({:run, operation, opts}, _from, state) do
    server = self()
    token = make_ref()

    runner =
      state.runner || Application.get_env(:hal_c2, :openshell_operation_runner, &Command.run/2)

    progress = fn step -> send(server, {:step, token, step}) end

    {pid, monitor} =
      spawn_monitor(fn ->
        send(server, {:done, token, attempt(runner, operation, opts ++ [progress: progress])})
      end)

    state = %{
      state
      | job: {token, {pid, monitor}},
        run: number(Map.get(state, :clock)),
        operation: operation,
        steps: [],
        result: nil
    }

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
    Logger.error("OpenShell's #{state.operation} stopped without an outcome: #{inspect(reason)}")

    finish(state, %{
      "ok" => false,
      "code" => nil,
      "message" =>
        "OpenShell's #{state.operation} stopped before it finished. The MC's log says why; Refresh shows what is installed now.",
      "sandboxes" => nil
    })
  end

  def handle_info({:DOWN, monitor, :process, pid, _}, state),
    do: {:noreply, %{state | watchers: HalC2.Watchers.down(state.watchers, monitor, pid)}}

  def handle_info(_other, state), do: {:noreply, state}

  defp finish(state, result) do
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
    do: %{"ok" => true, "code" => nil, "message" => text, "sandboxes" => nil}

  defp outcome({:error, message}) when is_binary(message),
    do: Map.put(Command.settings_error(message), "ok", false)

  defp outcome(other) do
    Logger.error("OpenShell's operation answered #{inspect(other)}")
    outcome({:error, "The operation gave no outcome the MC understands."})
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
