defmodule HalC2.Mcp do
  @moduledoc """
  The `hal-c2` MCP server that agents get in their provider sessions, so an agent
  can work with HAL-C2 itself: read and message threads, launch new ones, and manage
  the queue, projects, and schedule (`HalC2.Mcp.Tools`).

  It is served at `POST /mcp` on the MC, as JSON-RPC over HTTP (MCP's
  streamable HTTP transport, answered with plain JSON). Each thread has its own
  bearer credential (`server/2`), given to that thread's agent, so every tool call
  acts as the thread that made it. A credential lapses after a day without MCP
  traffic while its thread has no run in progress (`:mcp_liveness_ms`), and is
  revoked when the thread's provider session stops (`revoke/1`) or its thread
  is archived.

  A credential also carries what the user lets agents reach: the `"preview"`
  capability when agent browser access is on for the thread's project, the
  `"device"` capability when agent device access is. Settings that cannot be
  read grant neither. Preparing a session (`for_agent/2`) whose capabilities
  no longer match its thread's credential rotates it, so a flipped setting
  never survives through reuse, while a detach that changes nothing (a
  workspace move) keeps the credential it started with.

  A project can turn the server off for its threads (`enableAgentBrowserAccess`
  in its settings overrides): no server is attached to its agents then, and a
  credential minted anyway carries no browser capability, so the choice holds
  everywhere the token is honoured.

  Tool definitions (`priv/mcp_tools.json`, `priv/mcp_mc_tools.json`) and the instructions
  agents get (`priv/mcp_instructions.md`) are edited in place.
  """

  use GenServer

  @workers_only "\n\nThe user keeps agents to HAL-C2's workers: do not use this provider's built-in subagents. Delegate child work with `delegate_task`, so the user can see it.\n"

  @table __MODULE__.Credentials
  @sessions __MODULE__.Sessions
  @protocol "2025-06-18"
  @liveness_ms 24 * 60 * 60 * 1_000

  # Why `delegate_task` refuses a native subagent: a task's result comes back as a
  # message to its owner's thread, which wakes that thread's agent, never a subagent.
  @subagent_delegation "A native subagent can't own HAL-C2 workers: nothing can wake it " <>
                         "when they finish. Work that fans out must itself be started " <>
                         "with delegate_task."

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  The MCP server for the agent of `thread_id` running on `instance`:
  `%{url: url, authorization: "Bearer ..."}`.
  """
  def server(thread_id, instance) do
    token = GenServer.call(__MODULE__, {:credential, thread_id, instance})
    %{url: endpoint(), authorization: "Bearer " <> token}
  end

  @doc """
  The server a live session of `thread_id` on `instance` was given, or nil:
  a read, never a mint or a rotation. Per-turn and per-prompt readers use
  this, so an access setting flipped mid-session cannot revoke the token
  the running agent still carries; rotation belongs to preparing a session
  (`for_agent/2`), and runtimes relaunch when `prepared?/2` goes false.
  """
  def current(thread_id, instance) do
    with [[token, capabilities]] <-
           :ets.match(
             @table,
             {:"$1", %{thread_id: thread_id, instance: instance, capabilities: :"$2"}, :_}
           ),
         true <- MapSet.member?(capabilities, "preview") do
      %{url: endpoint(), authorization: "Bearer " <> token}
    else
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Whether the live credential of `thread_id` on `instance` still matches
  what the user lets its agent reach, so a runtime can keep its session.
  No credential is prepared: a session opened without a server (this
  server was down, or access was withheld) has no token a flip could
  strand, and it gains one at its next ordinary relaunch.
  """
  def prepared?(thread_id, instance) do
    case capabilities(thread_id, instance) do
      nil -> true
      capabilities -> capabilities == agent_access(thread_id)
    end
  end

  @doc "The MCP endpoint agents reach this MC at."
  def endpoint do
    port = Application.get_env(:hal_c2, :port, 3780)
    "http://127.0.0.1:#{port}/mcp"
  end

  @doc "Revokes every credential of `thread_id`, as its provider session stops."
  def revoke(thread_id) do
    if :ets.whereis(@table) != :undefined do
      :ets.match_delete(@table, {:_, %{thread_id: thread_id, instance: :_}, :_})
      drop_sessions(%{thread_id: thread_id})
    end

    :ok
  end

  @doc """
  Revokes the credential of `thread_id` on one provider `instance` only, as
  when the session it was minted for failed to open: a replacement session on
  another instance keeps its own.
  """
  def revoke(thread_id, instance) do
    if :ets.whereis(@table) != :undefined do
      :ets.match_delete(@table, {:_, %{thread_id: thread_id, instance: instance}, :_})
      drop_sessions(%{thread_id: thread_id, instance: instance})
    end

    :ok
  end

  # Sessions outlive nothing: a revoked (or lapsed) credential's are dropped
  # with it, so the table holds only sessions a live credential opened.
  defp drop_sessions(caller_match) do
    if :ets.whereis(@sessions) != :undefined,
      do: :ets.match_delete(@sessions, {:_, caller_match})
  end

  @doc "The capabilities the live credential of `thread_id` on `instance` carries, or nil."
  def capabilities(thread_id, instance) do
    case :ets.match(
           @table,
           {:_, %{thread_id: thread_id, instance: instance, capabilities: :"$1"}, :_}
         ) do
      [[capabilities] | _] -> capabilities
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  What the user lets the agent of `thread_id` reach, as capabilities:
  `"preview"` for the browser, `"device"` for simulators and emulators.
  Settings that cannot be read grant neither — an explicit "off" silently
  becoming "on" would break the user's stated choice, whereas the reverse
  costs an agent one toolset and is visible at once.
  """
  def agent_access(thread_id) do
    # No settings service to read (down, or not started yet): withhold both,
    # like any other unreadable settings.
    if Process.whereis(HalC2.Settings) == nil do
      MapSet.new()
    else
      project =
        case HalC2.Shell.row(node(), thread_id) do
          {"thread", row} -> row["projectId"]
          _ -> nil
        end

      settings = HalC2.Settings.for_project(project)

      MapSet.new(
        Enum.reject(
          [
            if(settings["enableAgentBrowserAccess"] != false, do: "preview"),
            if(settings["enableAgentDeviceAccess"] == true, do: "device")
          ],
          &is_nil/1
        )
      )
    end
  rescue
    # The settings table is gone or unreadable: withhold both.
    _ -> MapSet.new()
  catch
    :exit, _ -> MapSet.new()
  end

  @doc """
  The MCP server to give the agent of `thread_id`, or nil when the user keeps HAL-C2's
  tools from agents (`enableAgentBrowserAccess`, which gates the whole server).
  """
  def for_agent(thread_id, instance) do
    # Preparing the session resolves (or rotates) its credential first, so a
    # flipped access setting takes effect with this run even when the server
    # itself ends up withheld. Call this only where a session is prepared;
    # a read mid-session goes through `current/2` and never rotates.
    if Process.whereis(__MODULE__) do
      token = GenServer.call(__MODULE__, {:prepare, thread_id, instance})
      server = %{url: endpoint(), authorization: "Bearer " <> token}
      if MapSet.member?(agent_access(thread_id), "preview"), do: server
    end
  end

  @doc """
  How long a provider's MCP client waits on one tool call, in milliseconds: past the
  longest wait an HAL-C2 tool accepts (an hour), so a wait ends with its own result
  instead of the client's 60-second default.
  """
  def tool_timeout_ms, do: 3_900_000

  @doc """
  The longest a waiting tool (`hal_c2_thread_wait`, `delegate_task` in wait mode) may
  block for a caller on provider `instance`. Claude and Codex are given `tool_timeout_ms/0`;
  the other providers take their MCP servers over ACP, which has no field for a tool
  timeout, so they keep their client's 60 s default and a wait is clamped under it
  (`:acp_max_wait_ms`, which tests shorten).
  """
  def max_wait_ms(instance) do
    driver =
      Enum.find_value(
        HalC2.Environment.providers(),
        &(&1["instanceId"] == instance && &1["driver"])
      )

    if driver in ["claudeAgent", "codex"],
      do: 3_600_000,
      else: Application.get_env(:hal_c2, :acp_max_wait_ms, 55_000)
  end

  @doc """
  Whether an agent session given `mcp` (`for_agent/2`) is kept to HAL-C2's workers: the
  user chose so (`nativeSubagents`) and the agent has the tools to delegate with. An
  adapter reads it once per session, for both the provider tool it takes away and
  `instructions/1`, so the two cannot disagree.
  """
  def workers_only?(nil), do: false

  def workers_only?(_mcp),
    do: Process.whereis(HalC2.Settings) != nil and HalC2.Settings.hal_c2_subagents?()

  @doc """
  What agents are told about the tools, for their system or developer prompt. For a
  session kept to HAL-C2's workers (`workers_only?/1`) it ends by saying so.
  """
  def instructions(workers_only \\ false)
  def instructions(true), do: instructions(false) <> @workers_only
  def instructions(false), do: HalC2.Mcp.Instructions.orchestration()

  @doc "The note a session kept to HAL-C2's workers ends its instructions with."
  def workers_only_note, do: @workers_only

  @doc """
  The instructions for one caller: the orchestration text, with the browser
  section only when its credential carries the preview capability, so an
  agent is never promised tools every call would refuse.
  """
  def instructions_for(caller, opts \\ []) do
    capabilities = Map.get(caller, :capabilities, MapSet.new(["preview"]))

    HalC2.Mcp.Instructions.for_session([capabilities: capabilities] ++ opts) <>
      if(Keyword.get(opts, :workers_only, false), do: @workers_only, else: "")
  end

  @doc """
  Answers one MCP request: `{status, body}` where `body` is JSON or nil. `authorization`
  is the request's Authorization header.
  """
  def handle(authorization, body) do
    {status, _headers, reply} = handle_request(authorization, %{}, body)
    {status, reply}
  end

  @doc """
  `handle/2` with the request's headers in and the answer's out:
  `{status, headers, body}`. An `initialize` answer carries the new
  `mcp-session-id`; a refused credential asks for a Bearer [REDACTED] and
  forbids storing the answer.
  """
  def handle_request(authorization, headers, body) do
    with "Bearer " <> token <- authorization || :missing,
         [{_, caller, last_alive}] <- :ets.lookup(@table, token),
         :ok <- alive(token, caller, last_alive) do
      case JSON.decode(body) do
        {:ok, %{"method" => method} = request} -> answer(request, method, caller, headers)
        _ -> {400, %{}, rpc_error(nil, -32700, "Parse error")}
      end
    else
      _ ->
        {401, %{"www-authenticate" => "Bearer", "cache-control" => "no-store"},
         %{
           "error" => "invalid_mcp_credential",
           "message" => "A valid provider-scoped MCP bearer credential is required."
         }}
    end
  end

  # A credential stays alive while its agent calls in or its thread has a run in
  # progress; an idle one lapses.
  defp alive(token, caller, last_alive) do
    now = System.monotonic_time(:millisecond)

    if now - last_alive <= Application.get_env(:hal_c2, :mcp_liveness_ms, @liveness_ms) or
         running?(caller.thread_id) do
      :ets.update_element(@table, token, {3, now})
      :ok
    else
      :ets.delete(@table, token)
      drop_sessions(%{thread_id: caller.thread_id, instance: caller.instance})
      :expired
    end
  end

  defp running?(thread_id) do
    HalC2.Streams.state(thread_id)
    |> HalC2.StreamState.list("run")
    |> Enum.any?(&(&1["status"] in ~w(preparing starting running waiting)))
  end

  @doc """
  Ends one MCP session (an `initialize` answer's `mcp-session-id`), as a
  `DELETE /mcp` or a closed MCP-over-ACP connection does. A session this MC
  no longer has is not an error.
  """
  def end_session(session_id) do
    if :ets.whereis(@sessions) != :undefined, do: :ets.delete(@sessions, session_id)
    :ok
  end

  @doc "Whether `session_id` is a live MCP session of this MC."
  def session?(session_id) do
    :ets.whereis(@sessions) != :undefined and :ets.member(@sessions, session_id)
  rescue
    ArgumentError -> false
  end

  # Notifications have no id and get no answer.
  defp answer(request, _method, _caller, _headers) when not is_map_key(request, "id"),
    do: {202, %{}, nil}

  defp answer(%{"id" => id} = request, method, caller, _headers) do
    case method do
      "initialize" ->
        session_id = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
        # Session bookkeeping never answers the handshake: a table this server
        # has not made (new code loaded over one started before sessions were
        # kept) must not turn every agent's connect into a 500.
        if :ets.whereis(@sessions) != :undefined,
          do: :ets.insert(@sessions, {session_id, caller})

        {200, %{"mcp-session-id" => session_id},
         result(id, %{
           "protocolVersion" => get_in(request, ["params", "protocolVersion"]) || @protocol,
           "capabilities" => %{"tools" => %{"listChanged" => false}},
           "serverInfo" => %{"name" => "hal-c2", "version" => "0.1.0"},
           "instructions" => instructions_for(caller)
         })}

      "ping" ->
        {200, %{}, result(id, %{})}

      "tools/list" ->
        {200, %{}, result(id, %{"tools" => HalC2.Mcp.Tools.list() ++ plugin_tools(caller)})}

      "tools/call" ->
        %{"name" => name} = params = request["params"] || %{}
        tool_use = get_in(params, ["_meta", "claudecode/toolUseId"])
        {200, %{}, result(id, call(name, params["arguments"] || %{}, caller, tool_use))}

      _ ->
        {200, %{}, rpc_error(id, -32601, "Method not found: #{method}")}
    end
  end

  # A call outside its tool's advertised input schema never reaches the tool:
  # refused as an `invalid_request` tool failure, as the Node server's
  # toolkits refused it before their handlers ran. Tools this MC does not
  # advertise (a plugin's, an unknown name) keep their own answers.
  defp validate(name, arguments) do
    case Enum.find(HalC2.Mcp.Tools.list(), &(&1["name"] == name)) do
      %{"inputSchema" => schema} -> HalC2.Mcp.Schema.validate(schema, arguments)
      _ -> :ok
    end
  end

  # Tools of the enabled tool packs and extensions (`HalC2.Plugins`) for the caller's
  # thread; HAL-C2's own keep their names.
  defp plugin_tools(caller) do
    own = MapSet.new(HalC2.Mcp.Tools.list(), & &1["name"])
    Enum.reject(HalC2.Plugins.tools(caller.thread_id), &MapSet.member?(own, &1["name"]))
  end

  # A tool's answer as MCP content; a failure is an error result the agent can read.
  # `tool_use` is the provider's id for the call, which Claude sends.
  defp call(name, arguments, caller, tool_use) do
    valid = validate(name, arguments)

    answer =
      cond do
        match?({:error, _}, valid) ->
          {:error, "invalid_request", elem(valid, 1)}

        name == "delegate_task" and native_subagent?(caller, tool_use) ->
          {:error, "capability_denied", @subagent_delegation}

        Enum.any?(HalC2.Mcp.Tools.list(), &(&1["name"] == name)) ->
          HalC2.Mcp.Tools.call(name, arguments, caller)

        true ->
          HalC2.Plugins.call_tool(name, arguments, caller.thread_id) ||
            HalC2.Mcp.Tools.call(name, arguments, caller)
      end

    case answer do
      {:ok, value} ->
        %{
          "content" => [%{"type" => "text", "text" => JSON.encode!(value)}],
          "structuredContent" => value
        }

      # A tool whose answer is more than JSON, such as a screenshot.
      {:ok, value, content} ->
        %{"content" => content, "structuredContent" => value}

      {:error, code, message} ->
        failure = %{"_tag" => "OrchestratorMcpFailure", "code" => code, "message" => message}
        %{"content" => [%{"type" => "text", "text" => JSON.encode!(failure)}], "isError" => true}
    end
  end

  # A Claude subagent shares its thread's credential, so its calls arrive as the
  # thread's; Claude names the tool call, which the runtime knows as the subagent's.
  defp native_subagent?(_caller, nil), do: false

  defp native_subagent?(%{thread_id: thread_id}, tool_use),
    do: HalC2.Claude.ThreadRuntime.subagent_tool?(thread_id, tool_use)

  defp result(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp rpc_error(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  # --- server ------------------------------------------------------------------

  @impl true
  def init(nil) do
    ensure_tables()
    {:ok, nil}
  end

  # Code loaded over this server (`HalC2.Hot`) migrates it here, never through
  # init: a table a newer module keeps is made now, in this process, so the
  # requests the new code answers find it there.
  @impl true
  def code_change(_old, state, _extra) do
    ensure_tables()
    {:ok, state}
  end

  defp ensure_tables do
    for name <- [@table, @sessions], :ets.whereis(name) == :undefined do
      :ets.new(name, [:named_table, :public, read_concurrency: true])
    end

    :ok
  end

  # Resolves the thread's credential on `instance`: a still-valid one whose
  # capabilities still match what the user lets agents reach is reused (a
  # thread that left its session and came back keeps it); a mismatch rotates,
  # revoking the old token as the new one is minted.
  @impl true
  # `server/2`: the thread's credential, minted on first ask and then
  # reused as it stands — a live session's token is never rotated under it.
  def handle_call({:credential, thread_id, instance}, _from, state) do
    token =
      case :ets.match(@table, {:"$1", %{thread_id: thread_id, instance: instance}, :_}) do
        [[token] | _] -> token
        [] -> mint(thread_id, instance, agent_access(thread_id))
      end

    {:reply, token, state}
  end

  # `for_agent/2`, at session preparation: like `:credential`, except a
  # credential whose capabilities no longer match the settings rotates —
  # the old token is revoked as its replacement is minted, and the caller
  # hands the new one to the session it is about to open.
  def handle_call({:prepare, thread_id, instance}, _from, state) do
    capabilities = agent_access(thread_id)

    token =
      case :ets.match(
             @table,
             {:"$1", %{thread_id: thread_id, instance: instance, capabilities: :"$2"}, :_}
           ) do
        [[token, ^capabilities] | _] ->
          token

        [[old, _stale] | _] ->
          :ets.delete(@table, old)
          drop_sessions(%{thread_id: thread_id, instance: instance})
          mint(thread_id, instance, capabilities)

        [] ->
          mint(thread_id, instance, capabilities)
      end

    {:reply, token, state}
  end

  defp mint(thread_id, instance, capabilities) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    caller = %{
      thread_id: thread_id,
      instance: instance,
      capabilities: capabilities,
      environment_id: HalC2.Environment.id()
    }

    :ets.insert(@table, {token, caller, System.monotonic_time(:millisecond)})
    token
  end
end
