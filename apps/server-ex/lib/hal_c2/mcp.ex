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

  A thread a plugin started with `tools: :plugin` (`HalC2.Plugins.Host.launch_thread/4`,
  a code review's) gets a credential kept to that plugin's agent tools: it lists and
  calls nothing else, and its server is marked `report: true` so runtimes tell the
  agent nothing of orchestration. The plugin's tools are not HAL-C2's, so the access
  settings do not withhold them.

  Tool definitions (`priv/mcp_tools.json`, `priv/mcp_mc_tools.json`) and the instructions
  agents get (`priv/mcp_instructions.md`) are edited in place.
  """

  require Logger

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
    case :ets.match_object(@table, {:_, %{thread_id: thread_id, instance: instance}, :_}) do
      [{token, caller, _}] ->
        {capabilities, plugin} = carries(caller)
        served(token, capabilities, plugin)

      _ ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  # The server a credential is handed out as: kept to a plugin's tools, or HAL-C2's
  # while the user lets agents reach them.
  defp served(token, capabilities, plugin) do
    server = %{url: endpoint(), authorization: "Bearer " <> token}

    cond do
      is_binary(plugin) -> Map.put(server, :report, true)
      MapSet.member?(capabilities, "preview") -> server
      true -> nil
    end
  end

  @doc """
  Whether the live credential of `thread_id` on `instance` still matches
  what the user lets its agent reach, so a runtime can keep its session.
  No credential is prepared: a session opened without a server (this
  server was down, or the thread could not be read) has no token a flip
  could strand, and it gains one at its next ordinary relaunch. A session
  of a thread kept to a plugin's tools is the exception: it needs that
  server to do its work (a review's report tool), so once the thread can
  be read it relaunches to get it.
  """
  def prepared?(thread_id, instance) do
    case :ets.match_object(@table, {:_, %{thread_id: thread_id, instance: instance}, :_}) do
      [] -> unserved?(thread_id)
      # A thread that cannot be read keeps its session: its credential was scoped when
      # the thread could be read, or is refused until it can (`scoped/2`).
      [{_, caller, _} | _] -> current?(caller, wanted(thread_id))
    end
  rescue
    ArgumentError -> true
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
      settings = HalC2.Settings.for_project(project(thread_id))

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

  # The thread's project from its own stream, not its sidebar row: the row is put a
  # moment after the events (`@shell_debounce` in `HalC2.Streams.Server`), so a new
  # thread's first turn would read the environment's settings and its second turn
  # its project's, launching differently (#1452). Without streams (tools, some
  # tests) there is no thread to read, so the environment's settings apply; preparing
  # a session then gives no server at all (`wanted/1`).
  defp project(thread_id), do: thread(thread_id)["projectId"]

  defp thread(thread_id) do
    case read_thread(thread_id) do
      %{} = thread -> thread
      _ -> %{}
    end
  end

  # The thread as its stream holds it, nil when its stream holds no thread, or
  # `:unreadable` when no stream can answer: no streams to ask, or a stream that
  # fails to start (`HalC2.Streams.ensure/1` raises on a refused start), whose
  # supervisor or registry is gone, or whose call exits.
  defp read_thread(thread_id) do
    if Process.whereis(HalC2.Streams.Registry),
      do: HalC2.Streams.get(thread_id, "thread", thread_id),
      else: :unreadable
  rescue
    _ in [CaseClauseError, ArgumentError] -> :unreadable
  catch
    :exit, _ -> :unreadable
  end

  @doc """
  The plugin whose agent tools alone the agent of `thread_id` gets, or nil: the
  plugin that started it with `tools: :plugin`. A code review started before
  launches carried the `"tools"` mark is kept to its plugin's tools too, as every
  review now is.
  """
  def kept_to(thread_id), do: plugin_kept(thread(thread_id))

  defp plugin_kept(thread) do
    case thread["plugin"] do
      %{"id" => id, "tools" => "plugin"} when is_binary(id) -> id
      %{"id" => "code-review", "kind" => "review"} -> "code-review"
      _ -> nil
    end
  end

  # A credential this MC did not mint for the thread as it stands (an earlier MC's,
  # restored with a reattached program or kept over a release upgrade) is narrowed
  # to the thread's plugin's tools when the thread is kept to them. It is never
  # widened: one that reaches more than `wanted/1` says rotates at the next preparation.
  # `:unreadable` when the thread cannot be read to tell: the credential is then
  # neither scoped nor honoured until it can.
  defp kept(caller) do
    case read_thread(caller.thread_id) do
      :unreadable ->
        :unreadable

      thread ->
        case plugin_kept(thread || %{}) do
          nil -> {:ok, Map.put_new(caller, :plugin, nil)}
          plugin -> {:ok, %{caller | capabilities: MapSet.new()} |> Map.put(:plugin, plugin)}
        end
    end
  end

  # Whether a session with no credential may keep running without a server: all may
  # but one kept to a plugin's tools whose thread can now be read.
  defp unserved?(thread_id) do
    case read_thread(thread_id) do
      :unreadable -> true
      thread -> plugin_kept(thread || %{}) == nil
    end
  end

  defp current?(_caller, :unreadable), do: true
  defp current?(caller, wanted), do: carries(caller) == wanted

  # What a credential carries, as `wanted/1` says it: one an earlier MC minted, before
  # credentials named a plugin, reaches no plugin's tools alone.
  defp carries(caller), do: {caller.capabilities, Map.get(caller, :plugin)}

  # What the credential of `thread_id` should carry: `{capabilities, plugin}`. One kept
  # to a plugin's tools reaches nothing of HAL-C2's. `:unreadable` when the thread
  # cannot be read to tell whether it is kept: no credential is minted for it then.
  defp wanted(thread_id) do
    case read_thread(thread_id) do
      :unreadable ->
        :unreadable

      thread ->
        case plugin_kept(thread || %{}) do
          nil -> {agent_access(thread_id), nil}
          plugin -> {MapSet.new(), plugin}
        end
    end
  end

  @doc """
  The MCP server to give the agent of `thread_id`, or nil when the user keeps HAL-C2's
  tools from agents (`enableAgentBrowserAccess`, which gates the whole server). A
  thread kept to its plugin's tools (`kept_to/1`) gets a server of those alone, marked
  `report: true`. Nil too while the thread cannot be read to tell whether it is kept.
  """
  def for_agent(thread_id, instance) do
    # Preparing the session resolves (or rotates) its credential first, so a
    # flipped access setting takes effect with this run even when the server
    # itself ends up withheld. Call this only where a session is prepared;
    # a read mid-session goes through `current/2` and never rotates.
    with pid when is_pid(pid) <- Process.whereis(__MODULE__),
         {capabilities, plugin} <- wanted(thread_id) do
      token = GenServer.call(__MODULE__, {:prepare, thread_id, instance, capabilities, plugin})
      served(token, capabilities, plugin)
    else
      :unreadable ->
        Logger.warning(
          "withheld HAL-C2's MCP server from a session whose thread could not be read"
        )

        nil

      nil ->
        nil
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
  # A server kept to a plugin's tools has no workers to hand work to.
  def workers_only?(%{report: true}), do: false

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
  def instructions_for(caller, opts \\ [])

  def instructions_for(%{plugin: plugin}, _opts) when is_binary(plugin),
    do: "This server has only the tools of the HAL-C2 plugin that started this thread."

  def instructions_for(caller, opts) do
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
    with {:ok, token} <- mcp_bearer(authorization),
         [{_, caller, last_alive}] <- :ets.lookup(@table, token),
         :ok <- alive(token, caller, last_alive),
         {:ok, caller} <- scoped(token, caller) do
      case JSON.decode(body) do
        {:ok, %{"method" => method} = request} -> answer(request, method, caller, headers)
        _ -> {400, %{}, rpc_error(nil, -32700, "Parse error")}
      end
    else
      :unreadable ->
        Logger.warning("refused an MCP request whose thread could not be read to scope it")

        {503, %{"retry-after" => "1", "cache-control" => "no-store"},
         rpc_error(nil, -32603, "HAL-C2 cannot read this thread right now; try again.")}

      refused ->
        # Which part was wrong, never the credential itself (upstream #23782).
        reason = if is_binary(refused), do: refused, else: "unknown_or_expired_token"
        Logger.warning("rejected MCP request with an unusable credential: #{reason}")

        {401, %{"www-authenticate" => "Bearer", "cache-control" => "no-store"},
         %{
           "error" => "invalid_mcp_credential",
           "reason" => reason,
           "message" => "A valid provider-scoped MCP bearer credential is required."
         }}
    end
  end

  # A credential minted before credentials named a plugin, still live after a release
  # upgrade, takes its thread's scope (`kept/1`) at its first request here that can
  # read the thread. Until then it is refused, and stays unscoped so the next tries again.
  defp scoped(_token, caller) when is_map_key(caller, :plugin), do: {:ok, caller}

  defp scoped(token, caller) do
    with {:ok, caller} <- kept(caller) do
      :ets.update_element(@table, token, {2, caller})
      {:ok, caller}
    end
  end

  defp mcp_bearer(authorization) do
    case HalC2.Auth.credential(authorization) do
      :missing -> "missing_authorization_header"
      {"bearer", ""} -> "missing_bearer_token"
      {"bearer", token} -> {:ok, token}
      _ -> "unsupported_scheme"
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
  Ends one MCP session (an `initialize` answer's `mcp-session-id`) for the
  credential `authorization` carries, as a `DELETE /mcp` does. Only the
  credential that opened a session may end it; a session this MC no longer
  has is not an error.
  """
  def end_session(authorization, session_id) do
    with {:ok, token} <- mcp_bearer(authorization),
         [{_, caller, last_alive}] <- :ets.lookup(@table, token),
         :ok <- alive(token, caller, last_alive) do
      if :ets.whereis(@sessions) != :undefined do
        case :ets.lookup(@sessions, session_id) do
          [{_, %{thread_id: thread_id, instance: instance}}]
          when thread_id == caller.thread_id and instance == caller.instance ->
            :ets.delete(@sessions, session_id)
            :ok

          [] ->
            :ok

          _other ->
            :error
        end
      else
        :ok
      end
    else
      _ -> :error
    end
  rescue
    ArgumentError -> :error
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
        {200, %{}, result(id, %{"tools" => listed(caller)})}

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

  # A caller kept to its plugin's tools lists those alone.
  defp listed(%{plugin: plugin} = caller) when is_binary(plugin),
    do: HalC2.Plugins.tools_of(plugin, caller.thread_id)

  defp listed(caller), do: HalC2.Mcp.Tools.list() ++ plugin_tools(caller)

  # Tools of the enabled tool packs and extensions (`HalC2.Plugins`) for the caller's
  # thread; HAL-C2's own keep their names.
  defp plugin_tools(caller) do
    own = MapSet.new(HalC2.Mcp.Tools.list(), & &1["name"])
    Enum.reject(HalC2.Plugins.tools(caller.thread_id), &MapSet.member?(own, &1["name"]))
  end

  # A tool's answer as MCP content; a failure is an error result the agent can read.
  # `tool_use` is the provider's id for the call, which Claude sends.
  defp call(name, arguments, %{plugin: plugin} = caller, _tool_use) when is_binary(plugin) do
    answer =
      HalC2.Plugins.call_tool_of(plugin, name, arguments, caller.thread_id) ||
        {:error, "capability_denied",
         "This thread has only the tools of the plugin that started it, and #{name} is not one."}

    content(answer)
  end

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

    content(answer)
  end

  defp content(answer) do
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
        failure_result(code, message)

      {:error, code, message, extra} ->
        failure_result(code, message, extra)
    end
  end

  @doc """
  A failed tool call as an MCP result: an `OrchestratorMcpFailure` with `code` and
  `message`, and what `extra` adds (a plugin tool's `plugin` and `details`).
  """
  def failure_result(code, message, extra \\ %{}) do
    failure =
      Map.merge(extra, %{"_tag" => "OrchestratorMcpFailure", "code" => code, "message" => message})

    %{"content" => [%{"type" => "text", "text" => JSON.encode!(failure)}], "isError" => true}
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

  # A release upgrade loading code over this server migrates it here, never through
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
        [] -> mint(thread_id, instance, wanted(thread_id))
      end

    {:reply, token, state}
  end

  # `for_agent/2`, at session preparation: like `:credential`, except a
  # credential whose capabilities no longer match the settings rotates —
  # the old token is revoked as its replacement is minted, and the caller
  # hands the new one to the session it is about to open.
  # `{capabilities, plugin}` is what `wanted/1` read for the thread, in the caller.
  def handle_call({:prepare, thread_id, instance, capabilities, plugin}, _from, state) do
    wanted = {capabilities, plugin}

    token =
      case :ets.match_object(@table, {:_, %{thread_id: thread_id, instance: instance}, :_}) do
        [{token, caller, _} | _] ->
          if carries(caller) == wanted do
            token
          else
            :ets.delete(@table, token)
            drop_sessions(%{thread_id: thread_id, instance: instance})
            mint(thread_id, instance, wanted)
          end

        [] ->
          mint(thread_id, instance, wanted)
      end

    {:reply, token, state}
  end

  @doc """
  The thread's live credentials, for `restore/1`: a provider program that outlives the MC
  keeps the token it was started with, and this table does not outlive it.
  """
  def credentials(thread_id) do
    if :ets.whereis(@table) != :undefined,
      do: :ets.match_object(@table, {:_, %{thread_id: thread_id}, :_}),
      else: []
  end

  @doc """
  Honours credentials an earlier MC gave a program this one reattached to, each kept
  to its thread's plugin's tools when the thread is (`kept_to/1`), whatever it carried.
  """
  def restore(credentials) do
    if :ets.whereis(@table) != :undefined do
      now = System.monotonic_time(:millisecond)

      for {token, caller, _} <- credentials,
          do: :ets.insert(@table, {token, restored(caller), now})
    end

    :ok
  end

  # One whose thread cannot be read yet loses any plugin it named, so its first request
  # scopes it (`scoped/2`) instead of trusting what the earlier MC wrote.
  defp restored(caller) do
    case kept(caller) do
      {:ok, caller} -> caller
      :unreadable -> Map.delete(caller, :plugin)
    end
  end

  # While the thread cannot be read, a credential asked for outside preparation
  # (`server/2`) names no plugin: its first request that can read the thread scopes
  # it (`scoped/2`), and it is refused until then.
  defp mint(thread_id, instance, :unreadable),
    do: insert(thread_id, instance, %{capabilities: agent_access(thread_id)})

  defp mint(thread_id, instance, {capabilities, plugin}),
    # The plugin whose agent tools alone this credential reaches, or nil.
    do: insert(thread_id, instance, %{capabilities: capabilities, plugin: plugin})

  defp insert(thread_id, instance, scope) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    caller =
      Map.merge(
        %{thread_id: thread_id, instance: instance, environment_id: HalC2.Environment.id()},
        scope
      )

    :ets.insert(@table, {token, caller, System.monotonic_time(:millisecond)})
    token
  end
end
