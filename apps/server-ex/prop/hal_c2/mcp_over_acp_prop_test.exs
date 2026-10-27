defmodule HalC2.McpOverAcpPropTest do
  @moduledoc """
  `HalC2.Mcp.OverAcp` against a model of its promises: only the `"hal-c2"`
  server connects, at most 16 connections are open at once, a message or
  disconnect on a connection that is not open is refused, and disposing of
  the bridge closes every connection. The transport is a stub answering
  `ping` and `initialize`; a handle (an integer) names each connection the
  bridge opened, so a counterexample reads `ping(3)`.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  @moduletag timeout: :infinity

  property "connections keep their promises", numtests: HalC2.Prop.numtests(100), max_size: 50 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        {:ok, registry} = Agent.start_link(fn -> %{bridge: nil, ids: %{}, next: 1} end)
        Process.put(:over_acp_registry, registry)

        {:ok, bridge} =
          HalC2.Mcp.OverAcp.start_link(
            endpoint: "http://mc.invalid/mcp",
            authorization: "Bearer test",
            post: &post/4,
            delete: fn _endpoint, _headers -> {:ok, 200} end
          )

        Agent.update(registry, &%{&1 | bridge: bridge})
        {history, state, result} = run_commands(__MODULE__, cmds)
        if Process.alive?(bridge), do: GenServer.stop(bridge)
        Agent.stop(registry)

        result == :ok or
          (IO.inspect({history, state, result}, label: "over-acp counterexample") and false)
      end
    end
  end

  # --- the stub transport -------------------------------------------------------

  defp post(_endpoint, _headers, body, emit) do
    request = JSON.decode!(body)

    if request["id"] do
      result =
        if request["method"] == "initialize",
          do: %{"protocolVersion" => "2025-06-18"},
          else: %{}

      emit.(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
    end

    {:ok, 200, %{"mcp-session-id" => "s-#{System.unique_integer([:positive])}"}}
  end

  # --- wrappers the commands call ------------------------------------------------

  def connect(server) do
    registry = Process.get(:over_acp_registry)
    bridge = Agent.get(registry, & &1.bridge)

    case HalC2.Mcp.OverAcp.connect(bridge, server) do
      {:ok, connection_id} ->
        handle =
          Agent.get_and_update(registry, fn state ->
            {state.next,
             %{state | ids: Map.put(state.ids, state.next, connection_id), next: state.next + 1}}
          end)

        {:ok, handle}

      {:error, _message} = error ->
        error
    end
  end

  def disconnect(handle) do
    registry = Process.get(:over_acp_registry)
    %{bridge: bridge, ids: ids} = Agent.get(registry, & &1)
    HalC2.Mcp.OverAcp.disconnect(bridge, ids[handle] || "no-such-connection")
  end

  def ping(handle) do
    registry = Process.get(:over_acp_registry)
    %{bridge: bridge, ids: ids} = Agent.get(registry, & &1)
    HalC2.Mcp.OverAcp.message(bridge, ids[handle] || "no-such-connection", "ping")
  end

  def dispose do
    registry = Process.get(:over_acp_registry)
    bridge = Agent.get(registry, & &1.bridge)
    HalC2.Mcp.OverAcp.dispose(bridge)
  end

  # --- the model -------------------------------------------------------------------

  def initial_state, do: %{open: MapSet.new(), next: 1}

  def command(state) do
    handles = Enum.to_list(1..max(state.next, 1))

    frequency([
      {4, {:call, __MODULE__, :connect, [oneof(["hal-c2", "hal-c2", "other"])]}},
      {3, {:call, __MODULE__, :disconnect, [oneof(handles)]}},
      {3, {:call, __MODULE__, :ping, [oneof(handles)]}},
      {1, {:call, __MODULE__, :dispose, []}}
    ])
  end

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :connect, [server]}) do
    if server == "hal-c2" and MapSet.size(state.open) < 16 do
      %{state | open: MapSet.put(state.open, state.next), next: state.next + 1}
    else
      state
    end
  end

  def next_state(state, _result, {:call, _, :disconnect, [handle]}),
    do: %{state | open: MapSet.delete(state.open, handle)}

  def next_state(state, _result, {:call, _, :dispose, []}), do: %{state | open: MapSet.new()}
  def next_state(state, _result, _call), do: state

  def postcondition(state, {:call, _, :connect, [server]}, result) do
    if server == "hal-c2" and MapSet.size(state.open) < 16 do
      result == {:ok, state.next}
    else
      match?({:error, _}, result)
    end
  end

  def postcondition(state, {:call, _, :disconnect, [handle]}, result) do
    if MapSet.member?(state.open, handle), do: result == :ok, else: match?({:error, _}, result)
  end

  def postcondition(state, {:call, _, :ping, [handle]}, result) do
    if MapSet.member?(state.open, handle),
      do: result == {:ok, %{}},
      else: match?({:error, _}, result)
  end

  def postcondition(_state, {:call, _, :dispose, []}, result), do: result == :ok
end
