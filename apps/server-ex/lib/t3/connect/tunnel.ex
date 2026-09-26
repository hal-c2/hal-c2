defmodule T3.Connect.Tunnel do
  @moduledoc """
  The managed tunnel's connector (`ManagedEndpointRuntime.ts`): the relay client
  (`T3.Connect.RelayClient`) running `tunnel run` with the relay's connector token,
  restarted when it exits.

  `apply/1` sets the tunnel the relay handed out (`RelayManagedEndpointRuntimeConfig`,
  or nil for none) and answers a `CloudManagedEndpointRuntimeStatus`. The same
  config while its connector runs keeps that connector, so a relink or a hot
  upgrade never drops the tunnel. At start the stored config is applied again.

  The state is versioned so a hot upgrade can migrate it in `code_change/3`.
  """

  use GenServer
  require Logger

  @state_version 1
  @stable_uptime 30_000
  @backoff_base 1_000
  @backoff_max 60_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Runs the tunnel `config` names (nil stops it); the resulting status."
  def apply(config), do: GenServer.call(__MODULE__, {:apply, config}, 15_000)

  @doc "The current `CloudManagedEndpointRuntimeStatus`."
  def status do
    case GenServer.whereis(__MODULE__) do
      nil -> %{"status" => "disabled"}
      pid -> GenServer.call(pid, :status)
    end
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{v: @state_version, config: nil, active: nil, delay: 0}, {:continue, :stored}}
  end

  @impl true
  def handle_continue(:stored, state) do
    config =
      with json when is_binary(json) <- T3.Connect.Secrets.get("cloud-endpoint-runtime-config"),
           {:ok, %{} = config} <- JSON.decode(json),
           do: config,
           else: (_ -> nil)

    {_status, state} = reconcile(%{state | config: config})
    {:noreply, state}
  end

  @impl true
  def handle_call({:apply, config}, _from, state) do
    {status, state} = reconcile(%{state | config: config, delay: 0})
    {:reply, status, state}
  end

  def handle_call(:status, _from, state), do: {:reply, current(state), state}

  @impl true
  def handle_info(
        {:DOWN, os_pid, :process, _pid, reason},
        %{active: %{os_pid: os_pid} = active} = state
      ) do
    uptime = System.monotonic_time(:millisecond) - active.started

    # The first crash restarts at once; further crashes inside the stable window
    # double the wait, so a client that fails instantly cannot spin.
    {wait, delay} =
      cond do
        uptime >= @stable_uptime -> {0, 0}
        state.delay == 0 -> {0, @backoff_base}
        true -> {state.delay, min(state.delay * 2, @backoff_max)}
      end

    Logger.warning("Relay client exited (#{inspect(reason)}); restarting in #{wait} ms")
    Process.send_after(self(), {:restart, key(state.config)}, wait)
    {:noreply, %{state | active: nil, delay: delay}}
  end

  def handle_info({:restart, key}, state) do
    if state.active == nil and key(state.config) == key do
      {_status, state} = reconcile(state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: stop(state.active)

  @impl true
  def code_change(_old_vsn, state, _extra), do: {:ok, migrate(state)}

  defp migrate(%{v: @state_version} = state), do: state
  defp migrate(state), do: Map.put(state, :v, @state_version)

  defp reconcile(%{config: %{"providerKind" => "cloudflare_tunnel"} = config} = state) do
    active = state.active

    if active && active.key == key(config) && running?(active) do
      {current(state), state}
    else
      stop(active)
      state = %{state | active: nil}

      case T3.Connect.RelayClient.resolve() do
        %{"status" => "available", "executablePath" => exe} -> spawn_connector(exe, config, state)
        resolved -> {failed(config, not_available(resolved)), state}
      end
    end
  end

  defp reconcile(%{config: config} = state) do
    stop(state.active)
    state = %{state | active: nil}

    if config,
      do: {%{"status" => "unsupported", "providerKind" => config["providerKind"]}, state},
      else: {%{"status" => "disabled"}, state}
  end

  defp spawn_connector(exe, config, state) do
    options = [
      :monitor,
      {:env, [{"TUNNEL_TOKEN", config["connectorToken"]}]},
      {:stdout, :null},
      {:stderr, :null},
      {:kill_timeout, 2}
    ]

    case :exec.run([exe, "tunnel", "run"], options) do
      {:ok, pid, os_pid} ->
        Logger.info("Relay client process started (pid #{os_pid})")

        active = %{
          pid: pid,
          os_pid: os_pid,
          key: key(config),
          started: System.monotonic_time(:millisecond)
        }

        state = %{state | active: active}
        {current(state), state}

      {:error, reason} ->
        Logger.warning("Failed to start relay client: #{inspect(reason)}")
        {failed(config, "Relay client did not start."), state}
    end
  end

  defp current(%{config: nil}), do: %{"status" => "disabled"}

  defp current(%{config: %{"providerKind" => "cloudflare_tunnel"} = config, active: active}) do
    if active && running?(active),
      do: tunnel(config, %{"status" => "running", "pid" => active.os_pid}),
      else: failed(config, "Relay client did not start.")
  end

  defp current(%{config: config}),
    do: %{"status" => "unsupported", "providerKind" => config["providerKind"]}

  defp failed(config, reason), do: tunnel(config, %{"status" => "failed", "reason" => reason})

  defp tunnel(config, status) do
    status
    |> Map.put("providerKind", "cloudflare_tunnel")
    |> Map.merge(Map.take(config, ["tunnelId", "tunnelName"]))
  end

  defp not_available(%{"status" => "unsupported", "platform" => platform, "arch" => arch}),
    do: "Relay client is unsupported on #{platform}-#{arch}."

  defp not_available(_), do: "The relay client is not installed."

  defp running?(%{pid: pid}), do: Process.alive?(pid)

  defp stop(nil), do: :ok

  defp stop(%{os_pid: os_pid}) do
    :exec.stop(os_pid)

    receive do
      {:DOWN, ^os_pid, :process, _, _} -> :ok
    after
      5_000 -> :ok
    end
  end

  defp key(nil), do: nil
  defp key(config), do: Map.take(config, ~w(providerKind connectorToken tunnelId tunnelName))
end
