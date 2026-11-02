defmodule HalC2.McpPropTest do
  @moduledoc """
  `HalC2.Mcp` against a model of its promises: a thread's credential answers
  until it is revoked or the server restarts; `initialize` always answers 200
  for a live credential and opens a session; a session lives until it ends,
  its credential is revoked, or the server restarts. Code loaded over the
  running server (`reload`, a `code_change` as `HalC2.Hot` runs) and a server
  whose sessions table was never made (`lose_sessions_table`, as one started
  before sessions were kept) must not break the handshake: sessions are lost,
  never the connect.

  A caller is a `{thread, instance}` from a small pool; a handle (an integer)
  names each session, so a counterexample reads `initialize({"t-a", "codex"})`.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  @moduletag timeout: :infinity

  @threads ["t-a", "t-b"]
  @instances ["codex", "claudeAgent"]

  property "credentials and sessions keep their promises",
    numtests: HalC2.Prop.numtests(100),
    max_size: 50 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("mcp")

        HalC2.Prop.start_services([
          {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
          HalC2.Streams,
          HalC2.Mcp
        ])

        {:ok, registry} =
          Agent.start_link(fn -> %{auth: %{}, sessions: %{}, next: 1} end)

        Process.put(:mcp_registry, registry)
        {history, state, result} = run_commands(__MODULE__, cmds)
        Agent.stop(registry)
        HalC2.Prop.stop_services()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- wrappers the commands call ------------------------------------------------

  defp registry, do: Process.get(:mcp_registry)

  defp auth(caller),
    do: Agent.get(registry(), & &1.auth[caller]) || "Bearer [REDACTED]"

  defp request(caller, method, params \\ %{}) do
    body =
      JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})

    HalC2.Mcp.handle_request(auth(caller), %{}, body)
  end

  def mint({thread, instance} = caller) do
    %{authorization: authorization} = HalC2.Mcp.server(thread, instance)
    Agent.update(registry(), &%{&1 | auth: Map.put(&1.auth, caller, authorization)})
    :ok
  end

  def initialize(caller) do
    case request(caller, "initialize", %{"protocolVersion" => "2025-06-18"}) do
      {200, %{"mcp-session-id" => session_id}, _} ->
        handle =
          Agent.get_and_update(registry(), fn state ->
            {state.next,
             %{
               state
               | sessions: Map.put(state.sessions, state.next, session_id),
                 next: state.next + 1
             }}
          end)

        {:ok, handle}

      {status, _, _} ->
        {:error, status}
    end
  end

  def ping_as(caller) do
    {status, _, _} = request(caller, "ping")
    status
  end

  def session_live(handle) do
    session_id = Agent.get(registry(), & &1.sessions[handle]) || "no-such-session"
    HalC2.Mcp.session?(session_id)
  end

  def end_session(handle) do
    session_id = Agent.get(registry(), & &1.sessions[handle]) || "no-such-session"
    HalC2.Mcp.end_session(session_id)
  end

  def revoke(thread), do: HalC2.Mcp.revoke(thread)

  # A server started before sessions were kept: the table its newer code
  # answers initialize with was never made.
  def lose_sessions_table do
    if :ets.whereis(HalC2.Mcp.Sessions) != :undefined, do: :ets.delete(HalC2.Mcp.Sessions)
    :ok
  end

  # Code loaded over the running server, as `HalC2.Hot.reload/1` migrates it.
  def reload do
    pid = Process.whereis(HalC2.Mcp)
    :sys.suspend(pid)
    :ok = :sys.change_code(pid, HalC2.Mcp, nil, :hot)
    :sys.resume(pid)
    :ok
  end

  def restart, do: HalC2.Prop.restart_service(HalC2.Mcp)

  # --- the model -------------------------------------------------------------------

  def initial_state,
    do: %{creds: MapSet.new(), sessions: %{}, next: 1, kept: true}

  defp caller, do: {oneof(@threads), oneof(@instances)}

  def command(state) do
    handles = Enum.to_list(1..max(state.next, 1))

    frequency([
      {4, {:call, __MODULE__, :mint, [caller()]}},
      {4, {:call, __MODULE__, :initialize, [caller()]}},
      {3, {:call, __MODULE__, :ping_as, [caller()]}},
      {3, {:call, __MODULE__, :session_live, [oneof(handles)]}},
      {2, {:call, __MODULE__, :end_session, [oneof(handles)]}},
      {2, {:call, __MODULE__, :revoke, [oneof(@threads)]}},
      {1, {:call, __MODULE__, :lose_sessions_table, []}},
      {1, {:call, __MODULE__, :reload, []}},
      {1, {:call, __MODULE__, :restart, []}}
    ])
  end

  def precondition(state, {:call, _, :initialize, [caller]}),
    do: MapSet.member?(state.creds, caller)

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :mint, [caller]}),
    do: %{state | creds: MapSet.put(state.creds, caller)}

  def next_state(state, _result, {:call, _, :initialize, [caller]}) do
    sessions =
      if state.kept, do: Map.put(state.sessions, state.next, caller), else: state.sessions

    %{state | sessions: sessions, next: state.next + 1}
  end

  def next_state(state, _result, {:call, _, :end_session, [handle]}),
    do: %{state | sessions: Map.delete(state.sessions, handle)}

  def next_state(state, _result, {:call, _, :revoke, [thread]}) do
    %{
      state
      | creds: MapSet.reject(state.creds, &(elem(&1, 0) == thread)),
        sessions: Map.reject(state.sessions, fn {_, {t, _}} -> t == thread end)
    }
  end

  def next_state(state, _result, {:call, _, :lose_sessions_table, []}),
    do: %{state | sessions: %{}, kept: false}

  def next_state(state, _result, {:call, _, :reload, []}), do: %{state | kept: true}

  def next_state(state, _result, {:call, _, :restart, []}),
    do: %{state | creds: MapSet.new(), sessions: %{}, kept: true}

  def next_state(state, _result, _call), do: state

  def postcondition(state, {:call, _, :initialize, [_caller]}, result),
    do: result == {:ok, state.next}

  def postcondition(state, {:call, _, :ping_as, [caller]}, result),
    do: result == if(MapSet.member?(state.creds, caller), do: 200, else: 401)

  def postcondition(state, {:call, _, :session_live, [handle]}, result),
    do: result == Map.has_key?(state.sessions, handle)

  def postcondition(_state, _call, result), do: result == :ok
end
