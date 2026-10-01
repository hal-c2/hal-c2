defmodule HalC2.Acp.ThreadRuntime do
  @moduledoc """
  Runs one thread's turns on an Agent Client Protocol agent (OpenCode's
  `opencode acp`, a registry agent, or any other instance in `HalC2.Acp.instances/0`) and writes them into
  the thread's log.

  One agent process serves the thread: `initialize`, then `session/new`, or
  `session/resume` (else `session/load`) on the recorded session id when the
  thread already has one. Each message is a `session/prompt`, run off the process
  since it lasts the whole turn; its `session/update` notifications stream thoughts,
  answers, and tool calls into items. Permission requests become approvals, which
  full-access threads grant at once. Interrupt is `session/cancel`.

  OpenCode also serves its HTTP API (`HalC2.Acp.OpenCode`): each turn records the
  OpenCode message it began with, where a rewind or a fork cuts the session.

  Grok's background work outlives its turn: subagents it spawns in the background,
  and shells and monitors it starts as tasks (`BackgroundTaskStarted` and `Monitor`
  tool results, or a running tool `x.ai/task_backgrounded` names). They stay running,
  so the thread lists them as background work and the idle reaper keeps the process
  that runs them, until Grok reports them ended (`x.ai/task_completed`, a
  `kill_command_or_subagent` result, or its "Background subagent ... completed"
  notice). Stopping the thread, an interrupted or failed turn, or a rewind ends them
  and the agent process with them, since only that stops them; its exit or release
  ends them too. The other ACP agents finish their tools and subagents inside the turn.
  """

  use GenServer, restart: :temporary

  require Logger

  import HalC2.Orchestration.TurnWriter

  alias HalC2.JsonRpc.Connection
  alias HalC2.Orchestration
  alias HalC2.Orchestration.{Entities, NativeSubagent}
  alias HalC2.Acp.Antigravity.Session, as: Antigravity
  alias HalC2.Acp.OpenCode

  @state_version 9
  @registry HalC2.Acp.Registry

  # Grok's background task notifications.
  @xai_backgrounded ["x.ai/task_backgrounded", "_x.ai/task_backgrounded"]
  @xai_completed ["x.ai/task_completed", "_x.ai/task_completed"]

  # Grok's own requests (`x.ai/...`), bare or wrapped in `{method, params}`.
  @xai_questions ["x.ai/ask_user_question", "_x.ai/ask_user_question"]
  @xai_plan ["x.ai/exit_plan_mode", "_x.ai/exit_plan_mode"]
  @empty_plan "# No plan written yet\n\n(The agent exited plan mode without writing a plan.)"
  @plan_captured "The client captured your proposed plan. Stop here and wait for the user's feedback or implementation request in a later turn."

  # Agents that ask HAL-C2 about every tool: HAL-C2 applies the access mode for them.
  @gated ~w(opencode pi)

  @spec start_turn(String.t(), map) :: :ok
  def start_turn(thread_id, turn),
    do: thread_id |> ensure() |> GenServer.call({:start_turn, turn}, 120_000)

  @spec interrupt(String.t(), String.t() | nil) :: :ok | {:error, String.t()}
  def interrupt(thread_id, _run_id) do
    case lookup(thread_id) do
      nil -> {:error, "no active ACP turn in this thread"}
      pid -> GenServer.call(pid, :interrupt, 15_000)
    end
  end

  @doc """
  ACP has no way to add to a running prompt, but OpenCode's running loop takes a
  second `session/prompt` (`%{text, attachments}`, built like a turn's) into the
  turn; both answer when the turn ends.
  """
  @spec steer(String.t(), String.t(), map) :: :ok | {:error, String.t()}
  def steer(thread_id, run_id, message) do
    case lookup(thread_id) do
      nil -> {:error, "no active ACP turn in this thread"}
      pid -> GenServer.call(pid, {:steer, run_id, message})
    end
  end

  @spec respond(String.t(), String.t(), map) :: :ok | {:error, String.t()}
  def respond(thread_id, request_id, response) do
    case lookup(thread_id) do
      nil -> {:error, "no pending request"}
      pid -> GenServer.call(pid, {:respond, request_id, response})
    end
  end

  @doc """
  ACP has no conversation truncation: a rollback starts the next turn in a new
  session, without any of the old conversation. OpenCode forks its session before
  the first dropped turn's message, and the thread continues in the fork.
  """
  @spec rollback(String.t(), map) :: {:ok, map} | {:error, String.t()}
  def rollback(thread_id, %{native_thread_id: native, first_dropped: before} = plan)
      when is_binary(native) and is_binary(before) do
    if HalC2.Acp.driver(plan.instance) == "opencode",
      do: thread_id |> ensure() |> GenServer.call({:rollback, plan}, 120_000),
      else: rollback(thread_id, Map.delete(plan, :first_dropped))
  end

  def rollback(thread_id, _plan) do
    reply =
      case Registry.lookup(@registry, thread_id) do
        [{pid, _}] -> GenServer.call(pid, :rollback)
        [] -> :ok
      end

    with :ok <- reply, do: {:ok, %{"nativeThreadRef" => nil}}
  end

  def start_link(thread_id),
    do:
      GenServer.start_link(__MODULE__, thread_id, name: {:via, Registry, {@registry, thread_id}})

  defp lookup(thread_id) do
    case Registry.lookup(@registry, thread_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp ensure(thread_id) do
    # Under its provider plugin, so a crash there stays with this provider.
    case DynamicSupervisor.start_child(HalC2.Plugins.sessions("acp"), {__MODULE__, thread_id}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  # --- server ------------------------------------------------------------------

  @impl true
  def init(thread_id) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       v: @state_version,
       thread_id: thread_id,
       conn: nil,
       agent: nil,
       mode: nil,
       capabilities: %{},
       session_id: nil,
       model: nil,
       # The models the session's `model` option lists.
       options: [],
       turn: nil,
       prompt: nil,
       items: %{},
       buffer: %{},
       flush_timer: nil,
       interrupted: false,
       # Updates `session/load` replays are history, not this turn.
       replaying: false,
       # Open prompts: request id -> {:permission, rpc id, options, {kind, prompt}}
       # or {:question, rpc id, params} ({rpc id, options} before v4).
       requests: %{},
       # Tools the user allowed for the session: {request kind, prompt}.
       allowed: MapSet.new(),
       # ACP has no system prompt: a session given HAL-C2's tools hears about them in
       # its first prompt.
       announce: false,
       # Subagents the agent started this turn, or in the background before it (Grok's
       # `task` tool): tool call id -> %{sub: NativeSubagent handle, session: child
       # session id, done: bool, background: bool}.
       subagents: %{},
       # Grok's background tasks: task id -> the tool call's id while its turn runs,
       # then its turn item (`%{id, node}`).
       tasks: %{},
       # Child-session updates that arrived before their subagent named its session.
       orphans: %{},
       # The session's config options (`configId` -> current value).
       config: %{},
       # The agent's own planning modes (`configId` -> the choice that plans), and what
       # those options held before HAL-C2's plan mode took them over.
       plan_modes: %{},
       build_modes: %{},
       # OpenCode's HTTP server (`HalC2.Acp.OpenCode`), and its session's newest
       # message when the turn began: `{:ok, id | nil}`, or `:unknown`.
       server: nil,
       leaf: :unknown
     }}
  end

  @impl true
  def handle_call({:start_turn, turn}, _from, state) do
    driver = turn.ids.driver
    ids = Map.put(turn.ids, :provider_turn, "provider-turn:#{driver}:#{turn.ids.run}")
    turn = %{turn | ids: ids}
    # Subagents still working in the background carry over; the rest were this turn's.
    subagents = Map.filter(state.subagents, fn {_, e} -> background?(e) and not e.done end)

    state = %{
      state
      | turn: turn,
        items: %{},
        interrupted: false,
        subagents: subagents,
        orphans: %{}
    }

    with :ok <- Antigravity.check_turn(turn),
         {:ok, state} <- ensure_session(state, turn),
         {:ok, state} <- check_model(state, driver, turn.model),
         {:ok, state} <- select_model(state, turn.model),
         state = set_options(state, turn) do
      started(state)
      state = %{state | leaf: leaf(state)}
      conn = state.conn
      session_id = state.session_id
      prompt = acp_prompt(turn, state.capabilities, state.announce)
      state = %{state | announce: false}

      task =
        Task.async(fn ->
          Connection.call(
            conn,
            "session/prompt",
            %{"sessionId" => session_id, "prompt" => prompt},
            :infinity
          )
        end)

      {:reply, :ok, %{state | prompt: task.ref}}
    else
      :logout ->
        {:reply, :ok, sign_out(state)}

      {:error, message} when is_binary(message) ->
        finish(state, "failed", message)
        {:reply, :ok, %{state | turn: nil}}

      {:error, reason, state} ->
        reason = Antigravity.failure(driver, reason)
        Logger.warning("#{driver} turn failed to start: #{inspect(reason)}")
        failure = if reason == :closed, do: reason, else: format(reason)
        finish(state, "failed", start_failure(HalC2.Acp.label(driver), failure))
        {:reply, :ok, %{state | turn: nil}}
    end
  end

  def handle_call(:interrupt, _from, %{prompt: ref} = state) when ref != nil do
    Connection.notify(state.conn, "session/cancel", %{"sessionId" => state.session_id})
    state = cancel_requests(state)
    {:reply, :ok, %{state | interrupted: true}}
  end

  # Between turns, stopping the thread stops its background work.
  def handle_call(:interrupt, _from, state) do
    if work?(state),
      do: {:reply, :ok, stop_work(state, "interrupted")},
      else: {:reply, {:error, "no running turn"}, state}
  end

  def handle_call({:steer, run_id, message}, _from, %{agent: "opencode", prompt: ref} = state)
      when ref != nil and not state.interrupted and state.turn.ids.run == run_id do
    conn = state.conn
    prompt = acp_prompt(Map.put(message, :ids, state.turn.ids), state.capabilities, false)
    params = %{"sessionId" => state.session_id, "prompt" => prompt}
    # Its answer is the turn's, which the first prompt's already ends.
    Task.start(fn -> Connection.call(conn, "session/prompt", params, :infinity) end)
    {:reply, :ok, state}
  end

  def handle_call({:steer, _run_id, _message}, _from, state),
    do: {:reply, {:error, "this agent cannot be steered now"}, state}

  # The instance's sessions stop (sign-out, a new sign-in method): a running turn
  # ends, and the thread's next message starts the agent again.
  def handle_call(:close, _from, state) do
    state = if state.turn, do: end_turn(%{state | prompt: nil}, "interrupted", nil), else: state
    state = end_work(state, "interrupted")
    if state.conn, do: Connection.stop(state.conn)
    {:reply, :ok, released(%{state | conn: nil, session_id: nil, prompt: nil, server: nil})}
  end

  def handle_call(:rollback, _from, %{turn: nil} = state),
    do: {:reply, :ok, %{stop_work(state, "interrupted") | session_id: nil}}

  def handle_call(:rollback, _from, state),
    do: {:reply, {:error, "Interrupt the current turn before rewinding."}, state}

  def handle_call({:rollback, _plan}, _from, %{turn: turn} = state) when turn != nil,
    do: {:reply, {:error, "Interrupt the current turn before rewinding."}, state}

  # The fork keeps the thread's earlier turns under new message ids, so their refs
  # move to the copies (`nativeTurnRefs`, which the rewind settles with the rest).
  # The next turn opens the fork.
  def handle_call({:rollback, plan}, _from, state) do
    with {:ok, state} <- serve(state, plan),
         {:ok, fork, copies} <-
           OpenCode.fork(state.server, plan.native_thread_id, plan.first_dropped) do
      {:reply,
       {:ok,
        %{
          "nativeThreadRef" => Entities.provider_ref(fork, plan.driver),
          "nativeTurnRefs" => copies
        }}, %{state | session_id: nil}}
    else
      {:error, reason, state} -> {:reply, {:error, format(reason)}, state}
      {:error, reason} -> {:reply, {:error, format(reason)}, state}
    end
  end

  # A decision string is how a runtime before v4 was asked.
  def handle_call({:respond, request_id, decision}, from, state) when is_binary(decision),
    do: handle_call({:respond, request_id, %{"decision" => decision}}, from, state)

  def handle_call({:respond, request_id, response}, _from, state) do
    case Map.pop(state.requests, request_id) do
      {nil, _} ->
        {:reply, {:error, "no pending request #{request_id}"}, state}

      {{:question, rpc_id, params}, requests} ->
        {answer, status} =
          if response["dismissed"] || !is_map(response["answers"]),
            do: {%{"outcome" => "cancelled"}, "cancelled"},
            else: {xai_answers(params, response["answers"]), "resolved"}

        Connection.respond(state.conn, rpc_id, {:ok, answer})

        {:reply, :ok,
         resolve_request(%{state | requests: requests}, request_id, response, status)}

      {{:permission, rpc_id, options, tool}, requests} ->
        decision = response["decision"] || "decline"
        Connection.respond(state.conn, rpc_id, {:ok, %{"outcome" => outcome(options, decision)}})
        state = %{state | requests: requests} |> remember_allowed(tool, decision)
        {:reply, :ok, resolve_request(state, request_id, decision)}

      {{rpc_id, options}, requests} ->
        decision = response["decision"] || "decline"
        Connection.respond(state.conn, rpc_id, {:ok, %{"outcome" => outcome(options, decision)}})
        {:reply, :ok, resolve_request(%{state | requests: requests}, request_id, decision)}
    end
  end

  @impl true
  def handle_info(
        {:json_rpc, _conn, {:notification, "session/update", %{"update" => update} = params}},
        state
      ) do
    cond do
      state.replaying -> {:noreply, state}
      child_session?(params["sessionId"], state) -> {:noreply, child_update(params, state)}
      subagent_ended?(update) -> {:noreply, subagent_ended(state, update)}
      state.turn == nil -> {:noreply, state}
      true -> {:noreply, update(update, state)}
    end
  end

  # Grok's background tasks: one it moved to the background, one that ended.
  def handle_info({:json_rpc, _conn, {:notification, method, params}}, state)
      when method in @xai_backgrounded do
    update = xai_params(params)["update"] || %{}
    tool = update["tool_call_id"]

    if is_binary(update["task_id"]) and is_map_key(state.items, tool),
      do: {:noreply, %{state | tasks: Map.put(state.tasks, update["task_id"], tool)}},
      else: {:noreply, state}
  end

  def handle_info({:json_rpc, _conn, {:notification, method, params}}, state)
      when method in @xai_completed do
    update = xai_params(params)["update"] || %{}
    task = get_in(update, ["task_snapshot", "task_id"]) || update["task_id"]
    {:noreply, if(is_binary(task), do: end_task(state, task, "completed"), else: state)}
  end

  def handle_info({:json_rpc, conn, {:request, id, "session/request_permission", params}}, state) do
    {:noreply, permission(conn, id, params, state)}
  end

  # Answered off this process: the user may take minutes to open the page.
  def handle_info(
        {:json_rpc, conn, {:request, id, "elicitation/create", %{"mode" => "url"} = params}},
        state
      ) do
    instance = state.agent

    Task.start(fn ->
      Connection.respond(conn, id, {:ok, HalC2.Acp.UrlAuth.request(instance, params)})
    end)

    {:noreply, state}
  end

  # Grok's questions for the user.
  def handle_info({:json_rpc, _conn, {:request, id, method, params}}, %{turn: turn} = state)
      when method in @xai_questions and turn != nil do
    params = xai_params(params)
    native = "xai-question:#{params["toolCallId"] || id}"
    {state, request_id} = open_question(flush(state), native, xai_questions(params))
    {:noreply, %{state | requests: Map.put(state.requests, request_id, {:question, id, params})}}
  end

  # Grok's plan becomes a proposed plan; its own approval gate is abandoned so the
  # turn ends, and the user implements the plan from HAL-C2 in a later turn.
  def handle_info({:json_rpc, conn, {:request, id, method, params}}, %{turn: turn} = state)
      when method in @xai_plan and turn != nil do
    params = xai_params(params)
    native = "plan:#{params["toolCallId"] || id}"

    markdown =
      case String.trim(params["planContent"] || "") do
        "" -> @empty_plan
        text -> text
      end

    state = state |> flush() |> ensure_item(native, :plan) |> finish_plan(native, markdown)
    Connection.respond(conn, id, {:ok, %{"outcome" => "abandoned", "feedback" => @plan_captured}})
    {:noreply, state}
  end

  # This client offers no file system or terminal; say so rather than hang.
  def handle_info({:json_rpc, conn, {:request, id, method, _params}}, state) do
    Connection.respond(
      conn,
      id,
      {:error, %{"code" => -32601, "message" => "#{method} is not supported"}}
    )

    {:noreply, state}
  end

  def handle_info({ref, result}, %{prompt: ref} = state) do
    Process.demonitor(ref, [:flush])

    {status, failure} =
      case result do
        _ when state.interrupted -> {"interrupted", nil}
        {:ok, %{"stopReason" => "cancelled"}} -> {"interrupted", nil}
        {:ok, %{"stopReason" => _}} -> {"completed", nil}
        # xAI's rate limit.
        {:error, %{"code" => -32003}} -> {"failed", "Grok usage limit reached. Try again later."}
        {:error, %{"message" => message}} -> {"failed", message}
        # The agent's process went away before it answered.
        {:error, :closed} -> {"failed", "#{HalC2.Acp.label(state.agent)} exited unexpectedly"}
        {:error, reason} -> {"failed", format(reason)}
      end

    state = record_turn(%{state | prompt: nil})
    state = end_turn(state, status, failure)
    # A turn that did not complete takes its background work, and earlier turns', down.
    {:noreply, if(status == "completed", do: state, else: stop_work(state, status))}
  end

  def handle_info({:EXIT, conn, _reason}, %{conn: conn} = state) do
    state =
      if state.turn,
        do: end_turn(state, "failed", "#{HalC2.Acp.label(state.agent)} exited unexpectedly"),
        else: state

    state = end_work(state, "failed")

    {:noreply, released(%{state | conn: nil, session_id: nil, prompt: nil, server: nil})}
  end

  def handle_info(:flush, state), do: {:noreply, flush(%{state | flush_timer: nil}, :timer)}
  def handle_info(_other, state), do: {:noreply, state}

  # The runtime or its provider plugin's supervisor crashed (not a stop): the turn
  # it was running ends, with what was buffered, so the thread shows the session is gone.
  # The agent's subagents ran in its process and end with it.
  # Background work stops with the agent process either way (released when idle, or
  # stopped with its thread); when the node itself stops, its next boot ends what is
  # left (`HalC2.Orchestration.Recovery`).
  @impl true
  def terminate(reason, %{turn: turn} = state) when turn != nil do
    unless reason in [:normal, :shutdown] or match?({:shutdown, _}, reason) do
      for {_, %{done: false, sub: sub}} <- state.subagents,
          do: NativeSubagent.finish(sub, "failed", nil)

      end_turn(state, "failed", "#{HalC2.Acp.label(state.agent)}'s session ended unexpectedly.")
    end

    :ok
  end

  def terminate(_reason, state) do
    end_work(state, "interrupted")
    :ok
  catch
    _, _ -> :ok
  end

  @impl true
  def code_change(_old, state, _extra), do: {:ok, migrate(state)}

  # Every older state shape migrates forward here; v2 added the agent's mode.
  defp migrate(%{v: @state_version} = state), do: state

  defp migrate(%{v: 1} = state),
    do: state |> Map.put_new(:mode, nil) |> Map.put(:v, 2) |> migrate()

  defp migrate(%{v: 2} = state),
    do: state |> Map.put_new(:announce, false) |> Map.put(:v, 3) |> migrate()

  defp migrate(%{v: 3} = state),
    do: state |> Map.put_new(:allowed, MapSet.new()) |> Map.put(:v, 4) |> migrate()

  defp migrate(%{v: 4} = state),
    do: state |> Map.put_new(:options, []) |> Map.put(:v, 5) |> migrate()

  defp migrate(%{v: 5} = state),
    do:
      state
      |> Map.merge(%{subagents: %{}, orphans: %{}, config: %{}})
      |> Map.put(:v, 6)
      |> migrate()

  # An agent started before v7 runs no OpenCode server; its turns go unrecorded.
  defp migrate(%{v: 6} = state),
    do: state |> Map.merge(%{server: nil, leaf: :unknown}) |> Map.put(:v, 7) |> migrate()

  defp migrate(%{v: 7} = state),
    do: state |> Map.put_new(:tasks, %{}) |> Map.put(:v, 8) |> migrate()

  # Planning modes are read from the session's next config options.
  defp migrate(%{v: 8} = state),
    do: state |> Map.merge(%{plan_modes: %{}, build_modes: %{}}) |> Map.put(:v, 9)

  # --- session -------------------------------------------------------------------

  # The agent's permission mode is set when it starts, so a new mode means a new process.
  defp ensure_session(%{conn: conn, session_id: sid, agent: agent, mode: mode} = state, turn)
       when conn != nil and sid != nil and agent == turn.ids.driver and mode == turn.runtime_mode,
       do: {:ok, state}

  defp ensure_session(state, turn) do
    driver = turn.ids.driver

    with {:ok, state} <- launch(state, driver, turn.runtime_mode, turn.cwd) do
      with :ok <- Antigravity.authenticate(state.conn, driver),
           {:ok, forked} <- fork_first(state, turn),
           {:ok, session_id, state} <- open_session(state, forked) do
        if session_id != turn.native_thread_id, do: record_session(state, session_id)
        Antigravity.opened(state.conn, session_id, driver, turn.runtime_mode, state.options)
        {:ok, %{state | session_id: session_id, announce: mcp_servers(state, turn) != []}}
      else
        {:error, reason} -> {:error, reason, state}
        {:error, reason, state} -> {:error, reason, state}
      end
    end
  end

  # A new agent process for `instance`, initialized; OpenCode's serves its HTTP API.
  defp launch(state, instance, mode, cwd) do
    if state.conn, do: Connection.stop(state.conn)
    state = %{state | conn: nil, session_id: nil, server: nil}

    with {:ok, command, env} <- HalC2.Acp.command(instance, mode),
         {command, env, server} = serve_opencode(instance, command, env),
         {:ok, conn} <-
           Connection.start_link(
             cmd: command,
             handler: self(),
             cd: cwd,
             env: env,
             dialect: :v2,
             log: state.thread_id
           ),
         {:ok, init} <-
           Connection.call(conn, "initialize", %{
             "protocolVersion" => 1,
             "clientCapabilities" => %{
               "fs" => %{"readTextFile" => false, "writeTextFile" => false},
               "terminal" => false,
               # A sign-in page the agent asks for shows on the provider (`HalC2.Acp.UrlAuth`).
               "elicitation" => %{"url" => %{}}
             },
             "clientInfo" => %{"name" => "hal-c2", "version" => "0.1.0"}
           }) do
      {:ok,
       %{
         state
         | conn: conn,
           agent: instance,
           mode: mode,
           server: server,
           capabilities: init["agentCapabilities"] || %{}
       }}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp serve_opencode(instance, command, env) do
    if HalC2.Acp.driver(instance) == "opencode",
      do: OpenCode.serve(command, env),
      else: {command, env, nil}
  end

  # OpenCode's server for a rewind: the thread's own, else one started for it.
  defp serve(%{conn: conn, server: server, agent: agent} = state, plan)
       when conn != nil and server != nil and agent == plan.instance,
       do: {:ok, state}

  defp serve(state, plan),
    do: launch(state, plan.instance, state.mode || "approval-required", plan.cwd)

  # A forked OpenCode thread's first turn opens a fork of the source's session, cut
  # before the source's turn after the fork point.
  defp fork_first(%{server: server} = state, %{fork: %{thread: source} = fork} = turn)
       when server != nil and is_binary(source) do
    case OpenCode.fork(server, source, fork[:before]) do
      {:ok, id, _copies} -> {:ok, %{turn | native_thread_id: id}}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp fork_first(_state, turn), do: {:ok, turn}

  # Continue the recorded session when the agent can; otherwise start a new one.
  defp open_session(state, %{native_thread_id: native} = turn) when is_binary(native) do
    params = %{"sessionId" => native, "cwd" => turn.cwd, "mcpServers" => mcp_servers(state, turn)}
    caps = state.capabilities

    cond do
      is_map(get_in(caps, ["sessionCapabilities", "resume"])) ->
        case Connection.call(state.conn, "session/resume", params, 60_000) do
          {:ok, result} -> {:ok, native, remember_model(state, result)}
          {:error, _} -> new_session(state, turn)
        end

      caps["loadSession"] == true ->
        state = %{state | replaying: true}
        result = Connection.call(state.conn, "session/load", params, 120_000)
        state = %{state | replaying: false}

        case result do
          {:ok, result} -> {:ok, native, remember_model(state, result || %{})}
          {:error, _} -> new_session(state, turn)
        end

      true ->
        new_session(state, turn)
    end
  end

  defp open_session(state, turn), do: new_session(state, turn)

  defp new_session(state, turn) do
    case Connection.call(
           state.conn,
           "session/new",
           %{"cwd" => turn.cwd, "mcpServers" => mcp_servers(state, turn)},
           60_000
         ) do
      {:ok, %{"sessionId" => id} = result} -> {:ok, id, remember_model(state, result)}
      {:ok, other} -> {:error, {:unexpected, other}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # HAL-C2's own MCP server, for agents that take servers over HTTP.
  defp mcp_servers(state, turn) do
    with true <- get_in(state.capabilities, ["mcpCapabilities", "http"]) == true,
         %{url: url, authorization: authorization} <-
           HalC2.Mcp.for_agent(state.thread_id, Entities.instance(turn.ids)) do
      [
        %{
          "type" => "http",
          "name" => "hal-c2",
          "url" => url,
          "headers" => [%{"name" => "Authorization", "value" => authorization}]
        }
      ]
    else
      _ -> []
    end
  end

  defp remember_model(state, result) do
    state =
      case HalC2.Acp.session_models(result) do
        [] -> state
        models -> Map.put(state, :options, models)
      end

    state = remember_config(state, result)

    case Enum.find(result["configOptions"] || [], &(&1["id"] == "model")) do
      %{"currentValue" => model} -> %{state | model: model}
      _ -> state
    end
  end

  defp check_model(state, driver, model) do
    case Antigravity.check_model(driver, model, state.options) do
      :ok -> {:ok, state}
      {:error, message} -> {:error, message, state}
    end
  end

  defp remember_config(state, %{"configOptions" => [_ | _] = options}) do
    %{
      state
      | config: Map.new(options, &{&1["id"], &1["currentValue"]}),
        plan_modes:
          for(
            %{"id" => id, "category" => category} = option <- options,
            category in ["mode", "collaboration_mode"],
            choice = plan_choice(option),
            into: %{},
            do: {id, choice}
          )
    }
  end

  defp remember_config(state, _result), do: state

  # OpenCode's agent and reasoning variant (`OpenCodeAdapterV2`): the thread's `agent`
  # option, else its plan agent in plan mode (back to build after), and `variant`.
  defp set_options(%{agent: "opencode"} = state, turn) do
    options = Map.get(turn, :options) || %{}

    value = fn id ->
      case options[id] do
        value when is_binary(value) -> value
        _ -> nil
      end
    end

    agent =
      value.("agent") ||
        cond do
          turn.interaction_mode == "plan" -> "plan"
          state.config["mode"] == "plan" -> "build"
          true -> nil
        end

    state |> set_config("mode", agent) |> set_config("effort", value.("variant"))
  end

  # Any other agent with a mode of its own for planning (a mode option offering `plan`
  # or `architect`) runs in it while the thread is in plan mode. HAL-C2 owns only that
  # override: the next turn out of plan mode puts back what the options held before.
  defp set_options(%{plan_modes: plan_modes} = state, %{interaction_mode: "plan"}) do
    Enum.reduce(plan_modes, state, fn {id, plan}, state ->
      if state.config[id] == plan do
        state
      else
        build_modes = Map.put_new(state.build_modes, id, state.config[id])
        set_config(%{state | build_modes: build_modes}, id, plan)
      end
    end)
  end

  defp set_options(%{build_modes: build_modes} = state, _turn),
    do:
      Enum.reduce(
        build_modes,
        %{state | build_modes: %{}},
        &set_config(&2, elem(&1, 0), elem(&1, 1))
      )

  # The choice of a select option (flat or grouped) that plans, if it has one.
  defp plan_choice(option) do
    option["options"]
    |> List.wrap()
    |> Enum.flat_map(&(&1["options"] || [&1]))
    |> Enum.find_value(&(&1["value"] in ["plan", "architect"] && &1["value"]))
  end

  defp set_config(state, id, value)
       when is_binary(value) and is_map_key(state.config, id) do
    if state.config[id] == value do
      state
    else
      case Connection.call(state.conn, "session/set_config_option", %{
             "sessionId" => state.session_id,
             "configId" => id,
             "value" => value
           }) do
        {:ok, result} ->
          state = remember_config(state, result || %{})
          %{state | config: Map.put(state.config, id, value)}

        {:error, reason} ->
          Logger.warning("could not set #{id} to #{value}: #{inspect(reason)}")
          state
      end
    end
  end

  defp set_config(state, _id, _value), do: state

  # A model OpenCode no longer offers fails the turn, as OpenCode's own prompt does, so
  # the user can pick another; other agents keep their session's model.
  defp select_model(%{agent: "opencode"} = state, model)
       when is_binary(model) and model != "" and model != state.model do
    case Connection.call(state.conn, "session/set_config_option", %{
           "sessionId" => state.session_id,
           "configId" => "model",
           "value" => model
         }) do
      {:ok, result} ->
        {:ok, remember_config(%{state | model: model}, result || %{})}

      {:error, reason} ->
        {:error,
         "the model #{model} is no longer offered (#{format(reason)}). Pick another model and try again.",
         state}
    end
  end

  defp select_model(state, model), do: {:ok, set_model(state, model)}

  # "Pi default" leaves the model to the user's own Pi settings.
  defp set_model(%{agent: agent} = state, "default") when agent != nil do
    if HalC2.Acp.driver(agent) == "pi", do: state, else: set_model_now(state, "default")
  end

  defp set_model(state, model), do: set_model_now(state, model)

  defp set_model_now(state, model)
       when is_binary(model) and model != "" and model != state.model do
    case Connection.call(state.conn, "session/set_config_option", %{
           "sessionId" => state.session_id,
           "configId" => "model",
           "value" => model
         }) do
      {:ok, result} ->
        remember_config(%{state | model: model}, result || %{})

      {:error, reason} ->
        Logger.warning("could not select #{model}: #{inspect(reason)}")
        state
    end
  end

  defp set_model_now(state, _model), do: state

  defp record_session(state, session_id) do
    ids = state.turn.ids

    commit(state, fn stream ->
      [
        Orchestration.upsert(
          stream,
          "provider-thread",
          ids.provider_thread,
          &Map.put(&1, "nativeThreadRef", Entities.provider_ref(session_id, ids.driver))
        )
      ]
    end)
  end

  # Where an OpenCode session stood when the turn began.
  defp leaf(%{server: nil}), do: :unknown

  defp leaf(state) do
    case OpenCode.leaf(state.server, state.session_id) do
      {:ok, leaf} ->
        {:ok, leaf}

      {:error, reason} ->
        Logger.warning("could not read the OpenCode session: #{reason}")
        :unknown
    end
  end

  # The OpenCode message that began the turn names it, so a rewind or a fork can cut
  # the session there.
  defp record_turn(%{server: server, leaf: {:ok, leaf}, turn: turn} = state)
       when server != nil and turn != nil do
    with message when is_binary(message) <-
           OpenCode.turn_message(server, state.session_id, leaf) do
      ids = turn.ids

      commit(state, fn stream ->
        [
          Orchestration.upsert(
            stream,
            "provider-turn",
            ids.provider_turn,
            &Map.put(&1, "nativeTurnRef", Entities.provider_ref(message, ids.driver))
          )
        ]
      end)
    end

    state
  end

  defp record_turn(state), do: state

  # --- updates -------------------------------------------------------------------

  defp update(%{"sessionUpdate" => "agent_message_chunk"} = u, state),
    do: chunk(state, u, :assistant)

  defp update(%{"sessionUpdate" => "agent_thought_chunk"} = u, state),
    do: chunk(state, u, :reasoning)

  # The protocol lets an agent send any JSON as a tool's raw input. Only a map names a
  # command, a pattern or an address, so anything else is left out.
  defp update(%{"sessionUpdate" => s, "rawInput" => input} = call, state)
       when s in ["tool_call", "tool_call_update"] and not is_map(input),
       do: update(Map.delete(call, "rawInput"), state)

  defp update(%{"sessionUpdate" => s, "toolCallId" => id} = call, state)
       when s in ["tool_call", "tool_call_update"] and is_map_key(state.subagents, id),
       do: subagent_call(state, id, call)

  defp update(%{"sessionUpdate" => "tool_call", "toolCallId" => id} = call, state) do
    if subagent_call?(call, state),
      do: subagent_call(state, id, call),
      else: tool(state, id, call)
  end

  defp update(%{"sessionUpdate" => "tool_call_update", "toolCallId" => id} = call, state) do
    cond do
      Map.has_key?(state.items, id) -> tool_update(state, id, call)
      subagent_call?(call, state) -> subagent_call(state, id, call)
      true -> tool_update(state, id, call)
    end
  end

  # The agent's task list for the turn (ACP `plan`), replaced whole on each update.
  defp update(%{"sessionUpdate" => "plan", "entries" => entries}, state)
       when is_list(entries) and entries != [] do
    steps =
      for {entry, index} <- Enum.with_index(entries, 1) do
        %{
          "id" => "step-#{index}",
          "text" => non_empty(entry["content"], "Step #{index}"),
          "status" =>
            case entry["status"] do
              "completed" -> "completed"
              "in_progress" -> "running"
              _ -> "pending"
            end
        }
      end

    state |> flush() |> write_todo("acp-plan:#{state.turn.ids.run}", steps)
  end

  # Models the agent adds or drops mid-session reach the picker without a provider refresh.
  defp update(%{"sessionUpdate" => "config_option_update", "configOptions" => options}, state)
       when is_list(options) do
    HalC2.Acp.put_models(state.agent, options)
    remember_model(state, %{"configOptions" => options})
  end

  # How full the session's context is, for the context meter.
  defp update(%{"sessionUpdate" => "usage_update", "used" => used} = u, state)
       when is_integer(used) do
    usage =
      if is_integer(u["size"]) and u["size"] > 0,
        do: %{"usedTokens" => used, "maxTokens" => u["size"]},
        else: %{"usedTokens" => used}

    ids = state.turn.ids

    commit(state, fn stream ->
      [
        Orchestration.upsert(
          stream,
          "provider-thread",
          ids.provider_thread,
          &Map.put(&1, "contextUsage", usage)
        )
      ]
    end)

    state
  end

  defp update(_update, state), do: state

  defp tool(state, id, call) do
    {kind, fields} = tool_shape(call)
    state = state |> flush() |> ensure_item(id, kind, fields) |> note_kill(id, call)

    cond do
      task = started_task(call) ->
        start_task(state, id, task, call)

      call["status"] in ["completed", "failed"] ->
        state |> killed(id, call) |> finish_tool(id, call)

      true ->
        state
    end
  end

  defp tool_update(state, id, call) do
    state =
      if Map.has_key?(state.items, id),
        do: state,
        else:
          (fn {kind, fields} -> ensure_item(flush(state), id, kind, fields) end).(
            tool_shape(call)
          )

    state = note_kill(state, id, call)

    cond do
      task = started_task(call) ->
        start_task(state, id, task, call)

      # A background task's tool call ends with its task, not its acknowledgement.
      id in Map.values(state.tasks) ->
        running_command(state, id, call)

      call["status"] in ["completed", "failed"] ->
        state |> killed(id, call) |> finish_tool(id, call)

      true ->
        state |> running_command(id, call) |> running_search(id, call)
    end
  end

  # OpenCode names a command only once it runs (`rawInput` on an in-progress update)
  # and sends its output so far with each update.
  defp running_command(state, id, call) do
    with %{kind: :command, id: item_id} = item <- state.items[id],
         fields =
           %{
             "input" => command_text(call["rawInput"] || %{}, nil),
             "output" => content_text(call["content"])
           }
           |> Map.reject(fn {key, value} -> value in [nil, ""] or item[key] == value end),
         true <- fields != %{} do
      commit(state, fn stream ->
        [Orchestration.upsert(stream, "turn-item", item_id, &Map.merge(&1, fields))]
      end)

      %{state | items: Map.put(state.items, id, Map.merge(item, fields))}
    else
      _ -> state
    end
  end

  # A read or search announced before its input says what it looked for once it runs.
  defp running_search(state, id, call) do
    with %{kind: :search, id: item_id} = item <- state.items[id],
         fields = Map.drop(search_fields(call), Map.keys(item)),
         true <- fields != %{} do
      commit(state, fn stream ->
        [Orchestration.upsert(stream, "turn-item", item_id, &Map.merge(fields, &1))]
      end)

      %{state | items: Map.put(state.items, id, Map.merge(item, fields))}
    else
      _ -> state
    end
  end

  # --- provider subagents -----------------------------------------------------------

  @uuid "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
  @child_session [
    ~r/(?:^|\n)\s*Agent ID:\s*(#{@uuid})\b/i,
    ~r/(?:^|\n)\s*subagent_id:\s*(#{@uuid})\b/i,
    ~r/===\s*Task\s+(#{@uuid})\s*===/i
  ]

  # Grok's Task / spawn_subagent tool (XAiAcpExtension.ts `isXAiSpawnOrTaskTool`).
  defp subagent_call?(call, %{turn: %{ids: %{driver: "grok"}}}) do
    title = String.downcase(call["title"] || "")
    input = call["rawInput"] || %{}
    variant = String.downcase(to_string(input["variant"] || ""))

    title in ["task", "spawn_subagent"] or String.contains?(title, "spawn subagent") or
      variant in ["task", "cursortask", "spawn_subagent"] or
      Enum.any?([input["subagent_type"], input["subagentType"]], &(is_binary(&1) and &1 != ""))
  end

  defp subagent_call?(_call, _state), do: false

  # The subagent's own session streams under another session id: its answer goes to
  # its child thread. Updates for a session no subagent has named yet wait for it.
  defp child_session?(session, state),
    do:
      is_binary(session) and state.subagents != %{} and state.session_id != nil and
        session != state.session_id

  defp child_update(%{"sessionId" => session, "update" => update}, state) do
    case Enum.find(state.subagents, fn {_id, entry} -> entry.session == session end) do
      {id, %{sub: sub} = entry} ->
        sub =
          case update do
            %{"sessionUpdate" => "agent_message_chunk", "content" => %{"text" => text}}
            when is_binary(text) ->
              NativeSubagent.append(sub, text)

            _ ->
              sub
          end

        %{state | subagents: Map.put(state.subagents, id, %{entry | sub: sub})}

      nil ->
        %{state | orphans: Map.update(state.orphans, session, [update], &(&1 ++ [update]))}
    end
  end

  defp subagent_call(state, id, call) do
    state = flush(state)
    output = content_text(call["content"]) || raw_output(call["rawOutput"])
    input = call["rawInput"] || %{}

    entry =
      state.subagents[id] ||
        %{
          sub:
            NativeSubagent.start(state.turn.ids, id, %{
              "prompt" => input["prompt"],
              "title" => input["description"],
              "model" => input["model"]
            }),
          session: nil,
          done: false
        }

    fresh = entry.session == nil && child_session(output)
    entry = if fresh, do: %{entry | session: fresh}, else: entry

    {waiting, orphans} =
      if fresh, do: Map.pop(state.orphans, fresh, []), else: {[], state.orphans}

    state = %{state | subagents: Map.put(state.subagents, id, entry), orphans: orphans}

    state =
      Enum.reduce(waiting, state, fn update, state ->
        child_update(%{"sessionId" => fresh, "update" => update}, state)
      end)

    entry = state.subagents[id]

    # A background spawn's acknowledgement ends the tool call, not the subagent.
    cond do
      call["status"] in ["completed", "failed"] and spawn_ack?(output) ->
        %{state | subagents: Map.put(state.subagents, id, Map.put(entry, :background, true))}

      call["status"] in ["completed", "failed"] and not entry.done ->
        status = if call["status"] == "failed", do: "failed", else: "completed"
        sub = NativeSubagent.finish(entry.sub, status, subagent_result(output))
        %{state | subagents: Map.put(state.subagents, id, %{entry | sub: sub, done: true})}

      true ->
        state
    end
  end

  defp background?(entry), do: Map.get(entry, :background, false)

  # --- Grok's background work -------------------------------------------------------

  # The task a tool result started in the background: a shell, or a monitor.
  defp started_task(%{"rawOutput" => %{"type" => type} = output})
       when type in ["BackgroundTaskStarted", "Monitor"] do
    case output["task_id"] || output["taskId"] do
      task when is_binary(task) and task != "" -> task
      _ -> nil
    end
  end

  defp started_task(_call), do: nil

  # The task's tool call stays running with what it said so far; a persistent
  # monitor, which never ends, says so on its input (`HalC2.Projection.BackgroundWork`).
  defp start_task(state, id, task, call) do
    state = %{state | tasks: Map.put(state.tasks, task, id)}
    %{id: item_id} = state.items[id]
    output = content_text(call["content"])
    persistent = call["rawOutput"]["persistent"] == true

    commit(state, fn stream ->
      [
        Orchestration.upsert(stream, "turn-item", item_id, fn item ->
          item
          |> then(&if(output, do: Map.put(&1, "output", output), else: &1))
          |> then(
            &if(persistent and is_map(&1["input"]),
              do: put_in(&1, ["input", "persistent"], true),
              else: &1
            )
          )
        end)
      ]
    end)

    state
  end

  # `kill_command_or_subagent` is the only end Grok reports for what it killed. Its
  # targets are on the tool call, which its updates need not repeat, so they are kept
  # on the item until it completes.
  defp note_kill(state, id, call) do
    title = String.downcase(call["title"] || "")
    input = call["rawInput"] || %{}

    with true <- String.contains?(title, "kill_command_or_subagent") or input["variant"] == "kill",
         ids = List.wrap(input["task_ids"]) ++ [input["task_id"], input["taskId"]],
         [_ | _] = ids <- Enum.filter(ids, &is_binary/1),
         %{} = item <- state.items[id] do
      %{state | items: Map.put(state.items, id, Map.put(item, :kills, ids))}
    else
      _ -> state
    end
  end

  defp killed(state, id, %{"status" => "completed"}) do
    ids = get_in(state.items, [id, :kills]) || []
    Enum.reduce(ids, state, &end_task(&2, &1, "cancelled"))
  end

  defp killed(state, _id, _call), do: state

  # Grok's reminder in the root session that a background subagent ended.
  defp subagent_ended?(%{"sessionUpdate" => "user_message_chunk", "content" => %{"text" => text}})
       when is_binary(text),
       do: text =~ ~r/Background subagent\s+["']?#{@uuid}/i

  defp subagent_ended?(_update), do: false

  defp subagent_ended(state, %{"content" => %{"text" => text}}) do
    [_, session, rest] = Regex.run(~r/Background subagent\s+["']?(#{@uuid})["']?(.*)/is, text)
    status = if rest =~ ~r/\bfail/i, do: "failed", else: "completed"
    end_task(state, session, status)
  end

  # Ends the background task or subagent Grok knows as `task`: a subagent by its
  # tool call or its session id.
  defp end_task(state, task, status) do
    subagent =
      Enum.find(state.subagents, fn {id, e} ->
        not e.done and (id == task or e.session == task)
      end)

    cond do
      Map.has_key?(state.tasks, task) -> end_tool_task(state, task, status)
      subagent -> end_subagent(state, elem(subagent, 0), status)
      true -> state
    end
  end

  defp end_subagent(state, id, status) do
    entry = state.subagents[id]
    sub = NativeSubagent.finish(entry.sub, status, nil)
    %{state | subagents: Map.put(state.subagents, id, %{entry | sub: sub, done: true})}
  end

  # While its turn runs the tool call is one of the turn's items; after, its own.
  defp end_tool_task(state, task, status) do
    {ref, tasks} = Map.pop(state.tasks, task)
    state = %{state | tasks: tasks}

    case ref do
      id when is_binary(id) and is_map_key(state.items, id) ->
        finish_item(state, id, status, & &1)

      %{id: item_id, node: node_id} ->
        at = Entities.now()
        done = %{"status" => status, "completedAt" => at}

        commit(state, fn stream ->
          [
            Orchestration.upsert(
              stream,
              "turn-item",
              item_id,
              &Map.merge(&1, Map.put(done, "updatedAt", at))
            ),
            Orchestration.upsert(stream, "node", node_id, &Map.merge(&1, done))
          ]
        end)

        state

      _ ->
        state
    end
  end

  defp work?(state),
    do:
      state.tasks != %{} or
        Enum.any?(state.subagents, fn {_, e} -> background?(e) and not e.done end)

  # Ends all background work, running subagents with it, as `status`.
  defp end_work(state, status) do
    state = Enum.reduce(Map.keys(state.tasks), state, &end_tool_task(&2, &1, status))

    Enum.reduce(state.subagents, state, fn {id, e}, state ->
      if e.done, do: state, else: end_subagent(state, id, status)
    end)
  end

  # Grok keeps background work through a cancel; only stopping its process ends it.
  # The next turn starts it again on the same session.
  defp stop_work(state, status) do
    if work?(state) do
      state = end_work(state, status)
      if state.conn, do: Connection.stop(state.conn)
      released(%{state | conn: nil, session_id: nil, prompt: nil, server: nil})
    else
      state
    end
  end

  defp child_session(nil), do: nil

  defp child_session(output) do
    Enum.find_value(@child_session, fn regex ->
      case Regex.run(regex, output) do
        [_, id] -> id
        _ -> nil
      end
    end)
  end

  defp spawn_ack?(nil), do: false

  defp spawn_ack?(output) do
    output =~ ~r/subagent started in background/i or
      (output =~ ~r/subagent_id:\s*#{@uuid}/i and output =~ ~r/get_command_or_subagent_output/i)
  end

  defp subagent_result(nil), do: nil

  defp subagent_result(output) do
    output
    |> String.replace(~r/(?:^|\n)\s*(?:Agent ID|subagent_id):\s*#{@uuid}[^\n]*(?:\n|$)/i, "\n")
    |> String.trim()
    |> then(&if(&1 == "", do: nil, else: &1))
  end

  defp non_empty(text, fallback) when is_binary(text) do
    case String.trim(text) do
      "" -> fallback
      text -> text
    end
  end

  defp non_empty(_, fallback), do: fallback

  defp chunk(state, %{"content" => %{"type" => "text", "text" => text}} = u, kind) do
    # Message ids are optional and need only be unique within a turn, so each turn
    # gets its own messages rather than overwriting an earlier turn's.
    key = "#{kind}:#{state.turn.ids.run}:#{u["messageId"] || "current"}"
    state |> ensure_item(key, kind) |> buffer(key, "text", text)
  end

  # Content the client cannot render is shown as a placeholder, never its data.
  defp chunk(state, %{"content" => %{"type" => type} = content} = u, kind)
       when type in ["image", "audio", "resource", "resource_link"] do
    chunk(state, %{u | "content" => %{"type" => "text", "text" => placeholder(content)}}, kind)
  end

  defp chunk(state, _u, _kind), do: state

  defp placeholder(%{"type" => "image"} = content),
    do: "[ACP image (#{meta(content["mimeType"], "unknown type")})#{uri(content["uri"])}]"

  defp placeholder(%{"type" => "audio"} = content),
    do: "[ACP audio (#{meta(content["mimeType"], "unknown type")})]"

  defp placeholder(%{"type" => "resource", "resource" => %{"text" => text}}) when is_binary(text),
    do: text

  defp placeholder(%{"type" => "resource", "resource" => resource}) when is_map(resource) do
    mime = meta(resource["mimeType"], nil)
    "[ACP binary resource#{if mime, do: " (#{mime})"}#{uri(resource["uri"])}]"
  end

  defp placeholder(%{"type" => "resource_link"} = content) do
    label = meta(content["title"], nil) || meta(content["name"], nil) || "resource"
    description = meta(content["description"], nil)
    label = if description, do: "#{label}: #{description}", else: label

    case uri(content["uri"]) do
      "" -> label
      ": " <> uri -> label <> "\n" <> uri
    end
  end

  defp placeholder(_), do: "[Unsupported ACP content]"

  defp meta(value, fallback) when is_binary(value) do
    case value |> String.trim() |> String.slice(0, 256) do
      "" -> fallback
      value -> value
    end
  end

  defp meta(_, fallback), do: fallback

  # A data URI would carry the content itself; only real addresses are shown.
  defp uri(value) do
    uri = meta(value, "")

    if uri == "" or String.starts_with?(String.downcase(uri), "data:"),
      do: "",
      else: ": " <> uri
  end

  defp tool_shape(call) do
    if HalC2.Acp.Antigravity.subagent?(call), do: subagent_shape(call), else: tool_kind(call)
  end

  # Antigravity's `start_subagent` tool starts a batch of subagents.
  defp subagent_shape(call) do
    prompt = content_text(call["content"]) || call["title"] || "Antigravity subagent batch"

    {:subagent,
     %{
       "subagentId" => call["toolCallId"],
       "origin" => "provider_native",
       "title" => "Antigravity subagent batch",
       "prompt" => prompt,
       "result" => nil
     }}
  end

  defp tool_kind(call) do
    input = call["rawInput"] || %{}
    path = get_in(call, ["locations", Access.at(0), "path"])

    case call["kind"] do
      "execute" ->
        {:command, %{"input" => command_text(input, call["title"]), "output" => ""}}

      kind when kind in ["edit", "delete", "move"] ->
        {:file, %{"fileName" => path || call["title"] || "file"}}

      # A read names its file; a search names what it looked for. Their output stays
      # out of the timeline: a file's whole text is too much to send to every client.
      "read" ->
        {:search, file_search(path, path)}

      "search" ->
        {:search, search_fields(call)}

      "fetch" ->
        {:web, %{"patterns" => Enum.filter([input["url"], input["query"]], &is_binary/1)}}

      _ ->
        {:tool, %{"toolName" => call["title"] || call["kind"] || "tool", "input" => input}}
    end
  end

  # What a search or read looked for, from whatever the call says so far.
  defp search_fields(call) do
    input = call["rawInput"] || %{}
    path = get_in(call, ["locations", Access.at(0), "path"])
    file_search(input["pattern"] || input["query"] || path, path)
  end

  defp file_search(pattern, path) do
    Map.reject(
      %{"pattern" => pattern, "results" => path && [%{"fileName" => path}]},
      fn {_key, value} -> not (is_binary(value) or is_list(value)) end
    )
  end

  defp command_text(%{"command" => command}, _title) when is_binary(command), do: command
  defp command_text(%{"command" => [_ | _] = argv}, _title), do: Enum.join(argv, " ")
  defp command_text(_input, title), do: title || ""

  defp finish_tool(state, id, call) do
    %{kind: kind} = state.items[id]
    status = if call["status"] == "failed", do: "failed", else: "completed"
    output = content_text(call["content"]) || raw_output(call["rawOutput"])

    finish_item(state, id, status, fn entity ->
      case kind do
        :command ->
          entity
          |> Map.put("output", output || "")
          |> then(
            &if(call["rawInput"],
              do: Map.put(&1, "input", command_text(call["rawInput"], entity["input"])),
              else: &1
            )
          )

        :file ->
          Map.put(entity, "diffStr", output || "")

        :tool ->
          entity
          |> Map.put("output", output || "")
          |> then(&if(call["rawInput"], do: Map.put(&1, "input", call["rawInput"]), else: &1))

        # What the call named when it was announced stays; the end fills in the rest.
        :search ->
          Map.merge(search_fields(call), entity)

        _ ->
          entity
      end
    end)
  end

  # Tool content: text blocks, and diffs as a small before/after.
  defp content_text([_ | _] = content) do
    content
    |> Enum.map(fn
      %{"type" => "content", "content" => %{"type" => "text", "text" => text}} ->
        text

      %{"type" => "diff", "path" => path, "newText" => new} = diff ->
        "#{path}\n--- before\n#{diff["oldText"] || ""}\n+++ after\n#{new}"

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "\n")
    end
  end

  defp content_text(_), do: nil

  defp raw_output(%{"output" => output}) when is_binary(output), do: output
  defp raw_output(_), do: nil

  # --- permissions ---------------------------------------------------------------

  # Full-access threads allow without asking; others ask the user.
  defp permission(conn, id, params, %{turn: nil} = state) do
    Connection.respond(conn, id, {:ok, %{"outcome" => %{"outcome" => "cancelled"}}})
    _ = params
    state
  end

  defp permission(conn, id, params, state) do
    options = params["options"] || []
    call = params["toolCall"] || %{}

    kind =
      case call["kind"] do
        "execute" -> "command"
        k when k in ["edit", "delete", "move"] -> "file-change"
        k when k in ["read", "search"] -> "file-read"
        _ -> "permission"
      end

    prompt = command_text(call["rawInput"] || %{}, call["title"])

    if allowed?(state, kind, call, prompt) do
      Connection.respond(conn, id, {:ok, %{"outcome" => outcome(options, "accept")}})
      state
    else
      {state, request_id} = open_request(flush(state), "#{id}", kind, prompt)
      request = {:permission, id, options, {kind, prompt}}
      %{state | requests: Map.put(state.requests, request_id, request)}
    end
  end

  # Full access allows everything. OpenCode and Pi ask about every tool, so HAL-C2
  # applies the mode for them: reads go ahead (OpenCode keeps asking about .env
  # files), edits go ahead in auto-accept-edits, and what the user allowed for the
  # session goes ahead again. Pi has no auto; its old auto threads ask as approval
  # required does.
  defp allowed?(%{turn: %{runtime_mode: "full-access"}}, _kind, _call, _prompt), do: true

  defp allowed?(state, kind, call, prompt) do
    driver = HalC2.Acp.driver(state.agent)
    mode = state.turn.runtime_mode

    cond do
      MapSet.member?(state.allowed, {kind, prompt}) -> true
      driver not in @gated -> false
      kind == "file-read" -> not (driver == "opencode" and env_file?(call))
      kind == "file-change" -> mode == "auto-accept-edits"
      true -> false
    end
  end

  # `.env` and `.env.local`, not `.env.example` or `.env.sample`.
  defp env_file?(call) do
    paths =
      [get_in(call, ["rawInput", "path"]), get_in(call, ["rawInput", "filePath"])] ++
        for(%{"path" => path} <- call["locations"] || [], do: path)

    Enum.any?(paths, fn
      path when is_binary(path) ->
        base = Path.basename(path)

        base == ".env" or
          (String.starts_with?(base, ".env.") and
             base not in [".env.example", ".env.sample", ".env.template"])

      _ ->
        false
    end)
  end

  defp remember_allowed(state, tool, decision)
       when decision in ["acceptForSession", "acceptAlways"],
       do: %{state | allowed: MapSet.put(state.allowed, tool)}

  defp remember_allowed(state, _tool, _decision), do: state

  # The agent's option for a `ProviderApprovalDecision`, or a cancellation.
  defp outcome(options, decision) do
    wanted =
      case decision do
        "accept" -> ["allow_once", "allow_always"]
        d when d in ["acceptForSession", "acceptAlways"] -> ["allow_always", "allow_once"]
        "decline" -> ["reject_once", "reject_always"]
        _ -> []
      end

    case Enum.find_value(wanted, fn kind -> Enum.find(options, &(&1["kind"] == kind)) end) do
      %{"optionId" => option} -> %{"outcome" => "selected", "optionId" => option}
      nil -> %{"outcome" => "cancelled"}
    end
  end

  defp cancel_requests(state) do
    Enum.reduce(state.requests, %{state | requests: %{}}, fn {request_id, request}, state ->
      answer =
        case request do
          {:question, rpc_id, _params} ->
            {rpc_id, %{"outcome" => "cancelled"}}

          {:permission, rpc_id, _options, _tool} ->
            {rpc_id, %{"outcome" => %{"outcome" => "cancelled"}}}

          {rpc_id, _options} ->
            {rpc_id, %{"outcome" => %{"outcome" => "cancelled"}}}
        end

      {rpc_id, result} = answer
      Connection.respond(state.conn, rpc_id, {:ok, result})
      resolve_request(state, request_id, nil, "cancelled")
    end)
  end

  defp end_turn(state, status, failure) do
    state = flush(state)

    # A completed turn's background tasks go on without it.
    state =
      if status == "completed" do
        {tasks, items} =
          Enum.reduce(state.tasks, {state.tasks, state.items}, fn
            {task, id}, {tasks, items} when is_binary(id) and is_map_key(items, id) ->
              {Map.put(tasks, task, Map.take(items[id], [:id, :node])), Map.delete(items, id)}

            _, acc ->
              acc
          end)

        %{state | tasks: tasks, items: items}
      else
        state
      end

    state = state |> close_open_items(status) |> cancel_requests()
    finish(state, status, failure)
    %{state | turn: nil, items: %{}}
  end

  # The message, with where its files are; images inline when the agent takes them.
  defp acp_prompt(turn, capabilities, announce) do
    attachments = Map.get(turn, :attachments, [])
    message = HalC2.Attachments.prompt_text(turn.text, attachments)

    message =
      if announce,
        do:
          "<hal_c2_orchestration_instructions>#{HalC2.Mcp.instructions()}</hal_c2_orchestration_instructions>\n\n<user_request>\n#{message}\n</user_request>",
        else: message

    text = [%{"type" => "text", "text" => message}]

    cond do
      Antigravity.antigravity?(turn.ids.driver) ->
        text ++ HalC2.Acp.Antigravity.attachment_blocks(attachments)

      get_in(capabilities || %{}, ["promptCapabilities", "image"]) == true ->
        text ++
          for(
            {mime, data} <- HalC2.Attachments.native_images(attachments),
            do: %{"type" => "image", "mimeType" => mime, "data" => data}
          )

      true ->
        text
    end
  end

  # The thread no longer holds an agent session (`HalC2.Acp.Antigravity.sessions/1`).
  defp released(state) do
    Registry.update_value(@registry, state.thread_id, fn _ -> nil end)
    state
  end

  # `/logout` alone in an Antigravity thread signs its instance out.
  defp sign_out(state) do
    instance = state.turn.ids.driver
    if state.conn, do: Connection.stop(state.conn)
    state = released(%{state | conn: nil, session_id: nil, prompt: nil})
    started(state)

    case HalC2.ProviderAuth.logout_from(instance, self()) do
      {:ok, _} ->
        state
        |> ensure_item("logout", :command, %{"input" => "/logout", "output" => ""})
        |> finish_item("logout", "completed", &Map.put(&1, "output", "Provider signed out"))
        |> end_turn("completed", nil)

      {:error, %{"detail" => detail}} ->
        end_turn(state, "failed", detail)
    end
  end

  # --- Grok's own requests --------------------------------------------------------

  defp xai_params(%{"params" => %{} = params}), do: params
  defp xai_params(params), do: params || %{}

  # Keyed by question text, as Grok keys its answers; a question with no choices
  # gets an OK.
  defp xai_questions(params) do
    for question <- params["questions"] || [], is_binary(question["question"]) do
      %{
        "id" => question["id"] || question["question"],
        "header" => "Question",
        "question" => question["question"],
        "multiSelect" => question["multiSelect"] == true,
        "options" =>
          case question["options"] || [] do
            [] ->
              [%{"label" => "OK", "description" => "Continue"}]

            options ->
              for option <- options,
                  do: %{
                    "label" => option["label"],
                    "description" => option["description"] || option["label"]
                  }
          end
      }
    end
  end

  # The labels chosen for each question, by question text; free text is "Other"
  # with the text as a note.
  defp xai_answers(params, answers) do
    answered =
      for question <- params["questions"] || [],
          values =
            answer_values(
              answers[question["id"] || question["question"]] || answers[question["question"]]
            ),
          values != [] do
        labels = for option <- question["options"] || [], do: option["label"]
        {chosen, notes} = Enum.split_with(values, &(&1 in labels))
        {question["question"], if(chosen == [], do: ["Other"], else: chosen), notes}
      end

    annotations =
      for {text, _chosen, [_ | _] = notes} <- answered,
          into: %{},
          do: {text, %{"notes" => Enum.join(notes, "\n")}}

    %{
      "outcome" => "accepted",
      "answers" => Map.new(answered, fn {text, chosen, _} -> {text, chosen} end)
    }
    |> then(&if(annotations == %{}, do: &1, else: Map.put(&1, "annotations", annotations)))
  end

  defp answer_values(values) when is_list(values),
    do: for(value <- values, is_binary(value), value = String.trim(value), value != "", do: value)

  defp answer_values(value) when is_binary(value), do: answer_values([value])
  defp answer_values(_value), do: []

  defp format(reason) when is_binary(reason), do: reason
  defp format(%{"message" => message}), do: message
  defp format(reason), do: inspect(reason)
end
