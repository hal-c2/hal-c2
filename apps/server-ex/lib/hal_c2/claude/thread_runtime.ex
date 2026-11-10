defmodule HalC2.Claude.ThreadRuntime do
  @moduledoc """
  Runs one thread's Claude turns through the `claude` CLI (`HalC2.Claude.Session`) and
  writes them into the thread's log.

  One CLI process serves every turn of the thread: each message is another user
  message on its stream-json input. If the process has gone, or the turn is on
  another model or other model options, the next turn starts a new one with
  `--resume` on the recorded session id. Text and thinking stream from partial
  messages and are written as appends; tool calls become command, file-change,
  web-search, or generic tool items, finished by their tool results.

  Work Claude runs in the background outlives the turn that started it: a subagent
  (the `Agent` tool) is a provider-native subagent (`NativeSubagent`), and a
  background Bash call's command item stays running after its tool result, which
  only acknowledges the launch. Both end on the task's `task_notification`, and with
  the turn when it is interrupted or fails, or with the process. While they run, the
  thread lists them as background work (`HalC2.Projection.BackgroundWork`), which
  keeps the idle reaper from stopping the process.

  When background work ends between the MC's turns, Claude answers its notification
  with a turn of its own (a "wake"). Its messages wait for a run of their own, which
  the runtime asks the thread for (`wake/2`); that run replays them and follows the
  rest to Claude's `result`.
  """

  use GenServer, restart: :temporary

  require Logger

  import HalC2.Orchestration.TurnWriter

  alias HalC2.Claude.Budget
  alias HalC2.Claude.Provider
  alias HalC2.Subprocess.Durable
  alias HalC2.Claude.Session
  alias HalC2.Orchestration
  alias HalC2.Orchestration.{Entities, NativeSubagent}
  alias HalC2.StreamState

  @state_version 12

  # Claude 5's task tools (`task_tools/2`).
  @task_tools ["TaskCreate", "TaskUpdate", "TaskList"]

  # How to sign in, naming where when this instance runs under its own config
  # directory: the login has to land in the directory Claude will be pointed at.
  defp signed_out_message(turn) do
    where =
      case HalC2.Claude.Provider.home_path(Entities.instance(turn.ids)) do
        nil ->
          ""

        home ->
          " from #{JSON.encode!(Map.get(turn, :cwd) || "")}, with CLAUDE_CONFIG_DIR " <>
            "set to #{JSON.encode!(HalC2.Claude.Provider.expand_home(home))}"
      end

    "Claude could not authenticate. For subscription login, run `claude auth login` " <>
      "on this environment's machine#{where}, then start a new thread. For API-key " <>
      "authentication, check this instance's configured credentials."
  end

  # runtimeMode -> the CLI's permission mode; prompts it raises become approval
  # requests the user answers in the client. In auto, Claude Code's classifier
  # decides what it would otherwise ask.
  @permission_modes %{
    "full-access" => "bypassPermissions",
    "auto-accept-edits" => "acceptEdits",
    "auto" => "auto",
    "approval-required" => "default"
  }

  @file_tools ~w(Edit Write MultiEdit NotebookEdit)
  @web_tools ~w(WebSearch WebFetch)
  # Claude's subagent tool; "Task" before Claude Code 2.1.
  @agent_tools ~w(Agent Task)
  # The turn item types of `tool_kind/2`'s kinds.
  @item_types %{
    command: "command_execution",
    file: "file_change",
    web: "web_search",
    tool: "dynamic_tool"
  }
  # The messages a subagent sends under its tool call (`parent_tool_use_id`).
  @sidechain ~w(assistant user stream_event)
  @task_status %{"completed" => "completed", "failed" => "failed", "stopped" => "cancelled"}

  # Why Claude ended a turn, in the user's words, by the `terminal_reason` its
  # `result` carries. A known reason fails even a result Claude calls a success.
  @terminal_errors %{
    "api_error" => "Claude gave up after repeated API errors.",
    "malformed_tool_use_exhausted" => "Claude gave up after repeated malformed tool calls.",
    "budget_exhausted" => "Claude stopped: the turn's token budget was exhausted.",
    "structured_output_retry_exhausted" =>
      "Claude could not produce the requested structured output.",
    "tool_deferred_unavailable" =>
      "Claude could not resume a deferred tool call: the tool is no longer available.",
    "turn_setup_failed" => "Claude could not start the turn.",
    "blocking_limit" =>
      "Claude's context window is full. Run /compact or start a new thread to continue.",
    "rapid_refill_breaker" =>
      "Claude stopped: the context refilled too quickly after compaction.",
    "prompt_too_long" => "Claude stopped: the prompt exceeds the model's context window.",
    "image_error" => "Claude stopped: an image in the conversation could not be processed.",
    "model_error" => "Claude stopped: the model returned an error."
  }

  # The windows a usage-limit pause names, by Claude's `rateLimitType`.
  @limit_labels %{
    "five_hour" => "5-hour",
    "seven_day" => "7-day",
    "seven_day_opus" => "7-day Opus",
    "seven_day_sonnet" => "7-day Sonnet",
    "seven_day_overage_included" => "7-day model",
    "overage" => "overage"
  }

  # The subagent tool, taken from the CLI for a session kept to HAL-C2's workers
  # (`HalC2.Mcp.workers_only?/1`, read once into the launch's `:workers_only`). Part of
  # the launch, so a change restarts the CLI when the next turn starts.
  # So are the tools plugins turned off for the conversation (`HalC2.Orchestration.RunShape`),
  # the same on every turn of it.
  defp disallowed_tools(workers_only, turn) do
    workers = if workers_only, do: @agent_tools, else: []
    Enum.uniq(workers ++ Map.get(turn, :denied_tools, []))
  end

  # A sandboxed review's agent gets the report broker, never HAL-C2's MCP server, and
  # has no HAL-C2 workers to hand work to, so it keeps its own subagent tool.
  defp mcp(_state, %{sandbox: true} = turn), do: HalC2.OpenShell.Review.mcp(turn)
  defp mcp(state, turn), do: HalC2.Mcp.for_agent(state.thread_id, Entities.instance(turn.ids))

  defp workers_only?(%{sandbox: true}, _mcp), do: false
  defp workers_only?(_turn, mcp), do: HalC2.Mcp.workers_only?(mcp)

  def driver, do: "claudeAgent"

  @spec start_turn(String.t(), map) :: :ok
  def start_turn(thread_id, turn),
    do: thread_id |> ensure() |> GenServer.call({:start_turn, turn}, 60_000)

  @spec interrupt(String.t(), String.t() | nil) :: :ok | {:error, String.t()}
  def interrupt(thread_id, run_id) do
    case Registry.lookup(HalC2.Claude.Registry, thread_id) do
      [{pid, _}] -> GenServer.call(pid, {:interrupt, run_id}, 15_000)
      [] -> {:error, "no active Claude turn in this thread"}
    end
  end

  @doc """
  Adds a message (`%{text, attachments}`) to the running turn of `run_id`; Claude takes it at once.
  `:held` when the runtime did not answer in time and may still take it. Non-timeout
  exits propagate and must be treated as a refusal; see `HalC2.RuntimeSteer`.
  """
  @spec steer(String.t(), String.t(), map) :: :ok | :held | {:error, String.t()}
  def steer(thread_id, run_id, message) do
    case Registry.lookup(HalC2.Claude.Registry, thread_id) do
      [{pid, _}] -> steer_call(pid, run_id, message)
      [] -> {:error, "no running turn"}
    end
  end

  # The handler only notifies the session, so the explicit budget waits on mailbox
  # backlog alone; `HalC2.RuntimeSteer` owns which timeout means held.
  defp steer_call(pid, run_id, message) do
    timeout = Application.get_env(:hal_c2, :claude_steer_timeout_ms, 30_000)
    HalC2.RuntimeSteer.call(pid, run_id, message, timeout)
  end

  @doc """
  Whether `tool_use_id` (an MCP call's `_meta["claudecode/toolUseId"]`) is a tool call
  of one of the thread's running subagents rather than of Claude itself. A call the
  runtime has not seen yet counts as Claude's own.
  """
  @spec subagent_tool?(String.t(), String.t()) :: boolean
  def subagent_tool?(thread_id, tool_use_id) do
    case Registry.lookup(HalC2.Claude.Registry, thread_id) do
      [{pid, _}] -> GenServer.call(pid, {:subagent_tool?, tool_use_id}, 15_000)
      [] -> false
    end
  catch
    # A runtime that stopped has no subagents running.
    :exit, _ -> false
  end

  @doc """
  Marks (`awaited`) or clears the mark on background work Claude runs, named by the
  task ids Claude showed it (or its tool use ids): work it waits on holds the thread
  Working until it ends (`HalC2.Projection.BackgroundWork`). Answers the ids that
  name running background work; the others change nothing.
  """
  @spec await_background(String.t(), [String.t()], boolean) :: {:ok, [String.t()]}
  def await_background(thread_id, task_ids, awaited) do
    case Registry.lookup(HalC2.Claude.Registry, thread_id) do
      [{pid, _}] -> GenServer.call(pid, {:await_background, task_ids, awaited}, 15_000)
      [] -> {:ok, []}
    end
  catch
    # A runtime that stopped runs no background work.
    :exit, _ -> {:ok, []}
  end

  @doc """
  Answers a prompt: a permission's `%{"decision" => ProviderApprovalDecision}`,
  AskUserQuestion's `%{"answers" => answers}`, or `%{"dismissed" => true}`.
  """
  @spec respond(String.t(), String.t(), map) :: :ok | {:error, String.t()}
  def respond(thread_id, request_id, response) do
    case Registry.lookup(HalC2.Claude.Registry, thread_id) do
      [{pid, _}] -> HalC2.RuntimeRespond.call(pid, request_id, response)
      [] -> {:error, "no pending request"}
    end
  end

  @doc """
  Rewinds the conversation: drops the live session, so the next turn resumes the
  recorded session at the new head (`nativeConversationHeadRef`), or starts a new
  one when the rollback goes back to the thread's start.
  """
  @spec rollback(String.t(), map) :: {:ok, map} | {:error, String.t()}
  def rollback(thread_id, %{head: head}) do
    reply =
      case Registry.lookup(HalC2.Claude.Registry, thread_id) do
        # One that stops as it is asked is as gone as one not found.
        [{pid, _}] ->
          HalC2.Orchestration.session_call(fn -> GenServer.call(pid, :rollback, 30_000) end, :ok)

        [] ->
          :ok
      end

    with :ok <- reply do
      {:ok,
       if(head,
         do: %{"nativeConversationHeadRef" => Entities.provider_ref(head, "claudeAgent")},
         else: %{"nativeThreadRef" => nil, "nativeConversationHeadRef" => nil}
       )}
    end
  end

  def start_link(thread_id),
    do:
      GenServer.start_link(__MODULE__, thread_id,
        name: {:via, Registry, {HalC2.Claude.Registry, thread_id}}
      )

  defp ensure(thread_id) do
    # Under its provider plugin, so a crash there stays with this provider.
    case DynamicSupervisor.start_child(
           HalC2.Plugins.sessions("claudeAgent"),
           {__MODULE__, thread_id}
         ) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  @doc "Goes on with the program an earlier MC left running (`HalC2.Subprocess.Durable`)."
  def adopt(thread_id, survivor),
    do: GenServer.call(ensure(thread_id), {:adopt, survivor}, 30_000)

  # --- server ------------------------------------------------------------------

  @impl true
  def init(thread_id) do
    {:ok,
     %{
       v: @state_version,
       thread_id: thread_id,
       session: nil,
       session_id: nil,
       turn: nil,
       items: %{},
       buffer: %{},
       flush_timer: nil,
       # Streamed content blocks of the message in flight: index -> native item key.
       blocks: %{},
       message_id: nil,
       # The complete message in flight and how many of its blocks arrived (`placed/3`).
       placed: nil,
       interrupted: false,
       # Open prompts: request id -> `{:permission, control id, tool, suggested rules}`
       # (`:once` for rules when Claude forbids remembering the answer) or
       # `{:question, control id, input}`.
       requests: %{},
       # The session's permission mode, switched before a turn that needs another.
       permission_mode: nil,
       # How the session's CLI was started (`Provider.launch/3`); a turn on another model
       # or other model options restarts it.
       launch: nil,
       # A steer ends the turn's current part with an "aborted" result; that one
       # result is not the end of the turn.
       steered: false,
       # Subagents and background commands still running, by tool use id:
       # `%{sub: NativeSubagent handle | nil, item: command item | nil, background: bool}`.
       work: %{},
       # Claude's task ids -> the tool use id of their work, or nil for a task that is
       # not work (ambient, a foreground command) or has ended.
       tasks: %{},
       # Task ids that already ended, so late progress cannot reopen them.
       finished_tasks: MapSet.new(),
       # The notices of awaited commands that ended between turns, newest first, held
       # until Claude answers them (`hold_notice?/2`).
       notices: [],
       # The latest turn's ids, which work Claude starts between turns joins.
       last_ids: nil,
       # The run the latest turn ran as, also one that failed to start: the run a
       # client names to stop the work left running between turns.
       last_run: nil,
       # The instance the latest turn's quota is published under, resolved
       # against settings once when the turn starts (or its ids are recovered).
       usage_instance: nil,
       # A turn Claude runs by itself (`wake/2`) that no run follows yet:
       # `%{open: bool, buffer: [message] | nil}`, `open` until its `result`, `buffer` its
       # messages newest first, nil once the thread refused it a run.
       wake: nil,
       # Why the thread was last told Full access asks (`announce_bypass/2`), if it was.
       bypass_notice: nil,
       # The goal Claude works on (`goal/2`), as the provider thread shows it, and whether
       # Claude worked on it in the running turn.
       goal: nil,
       goal_checked: false,
       # Claude's task tools' list (`task_tools/2`): `{list id, [{task id, step}]}`, the
       # list id nil once Claude's own copy turned out unreadable; nil before any change
       # of this runtime's. And the task tool calls still to report back, by tool use id.
       task_list: nil,
       task_calls: %{},
       # What a sandboxed review's CLI spent (#1412), a `Budget`; nil outside a sandbox.
       sandbox_spent: nil
     }}
  end

  # A program an earlier MC left running: this runtime goes on from its checkpoint.
  @impl true
  def handle_call({:adopt, %{dir: dir, snapshot: snapshot}}, _from, state) do
    Process.flag(:trap_exit, true)

    with {:ok, session} <-
           Session.start_link(
             adopt: %{dir: dir, offset: snapshot.offset, channel: snapshot.channel},
             handler: self(),
             log: snapshot.state.thread_id
           ),
         :ok <- answering(session),
         {:ok, restored} <- code_change(nil, snapshot.state, nil) do
      # A stop that was out when the MC went keeps its deadline.
      if restored.turn != nil and restored.interrupted do
        settle = Application.get_env(:hal_c2, :claude_interrupt_timeout_ms, 10_000)
        Process.send_after(self(), {:settle_interrupt, restored.turn.ids.run}, settle)
      end

      # So does a hold on notices Claude has not answered yet.
      with [%{"task_id" => task_id} | _] <- Enum.reverse(restored.notices),
           do: hold_notices(task_id)

      {:reply, :ok, Durable.restored(restored, :session, session, snapshot)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # The run of a wake: nothing is sent to Claude. What it said so far is replayed into
  # the run, which then follows it to its `result`.
  @impl true
  def handle_call({:start_turn, %{wake: true} = turn}, _from, state) do
    ids = Map.put(turn.ids, :provider_turn, "provider-turn:claudeAgent:#{turn.ids.run}")

    launch =
      state.launch ||
        Provider.launch(turn.model, Map.get(turn, :options, %{}), Entities.instance(ids))

    turn = turn |> Map.put(:ids, ids) |> Map.put(:launch, launch)
    wake = state.wake || %{open: false, buffer: nil}
    buffer = Enum.reverse(wake.buffer || [])
    last_ids = state.last_ids

    state = %{
      state
      | turn: turn,
        items: %{},
        blocks: %{},
        interrupted: false,
        last_ids: ids,
        last_run: ids.run,
        usage_instance: resolved_instance(Entities.instance(ids)),
        wake: nil
    }

    case started(state) do
      :ok -> {:reply, :ok, replay_wake(state, wake, buffer)}
      # The run ended before it started: Claude stops the turn it began, and its
      # messages go on as between turns.
      :ended -> {:reply, :ok, drop_wake(state, wake, buffer, last_ids)}
    end
  end

  def handle_call({:start_turn, turn}, _from, state) do
    turn = HalC2.OpenShell.Review.in_sandbox(turn)
    # The user's run holds the thread working now.
    state = release_notices(state)
    ids = Map.put(turn.ids, :provider_turn, "provider-turn:claudeAgent:#{turn.ids.run}")
    # The CLI also takes its MCP server at launch: a credential renewed since (the old
    # one lapsed, or the project's agent access changed) needs a new process to reach it.
    # So does another instance of Claude, which runs with its own variables and home.
    launch =
      turn.model
      |> Provider.launch(Map.get(turn, :options, %{}), Entities.instance(ids))
      |> auto_compact(Entities.instance(ids))
      |> with_launch_args(turn, Entities.instance(ids))
      |> Map.put(:mcp, mcp(state, turn))
      |> then(&Map.put(&1, :workers_only, workers_only?(turn, &1.mcp)))
      |> then(&Map.put(&1, :disallowed_tools, disallowed_tools(&1.workers_only, turn)))
      |> Map.put(:instance, Entities.instance(ids))

    # Where the turn resumes the conversation, until Claude writes (`kept_head/3`).
    turn =
      turn
      |> Map.put(:ids, ids)
      |> Map.put(:launch, launch)
      |> Map.put(:resumed_at, Map.get(turn, :head))
      |> bypass_policy()

    last_ids = state.last_ids

    state = %{
      state
      | turn: turn,
        items: %{},
        blocks: %{},
        interrupted: false,
        last_ids: ids,
        last_run: ids.run,
        usage_instance: resolved_instance(Entities.instance(ids)),
        # A runtime started since the goal was set knows it from the provider thread.
        goal: state.goal || provider_goal(state, ids)
    }

    session = state.session

    # A model the installed CLI is too old for is refused here, naming the version,
    # as are launch arguments that cannot be read.
    opened =
      cond do
        # A fork point Claude cannot honour (`HalC2.Orchestration.Handoff.fork_boundary/3`).
        message = get_in(turn, [:fork, :error]) ->
          {:error, {:refused, message}}

        message = turn.launch[:launch_error] ->
          {:error, {:refused, message}}

        message = too_old(turn, Entities.instance(ids)) ->
          {:error, {:refused, message}}

        message = background_change(state, turn) ->
          {:error, {:refused, message}}

        true ->
          open_session(state, turn)
      end

    case opened do
      {:error, {:refused, message}} ->
        unsent(state, turn)
        finish(state, "failed", message)
        {:reply, :ok, %{state | turn: nil, last_ids: last_ids}}

      {:ok, state, turn} ->
        # A session Claude could not resume starts afresh with the whole thread, in a
        # conversation that holds no message of the old one: a turn stopped before
        # Claude writes leaves it to be resumed whole (`kept_head/3`).
        fresh? = Map.get(state, :fresh_start, false)

        turn =
          if fresh?,
            do: turn |> new_conversation() |> Map.delete(:resumed_at),
            else: turn

        {state, turn} = HalC2.Orchestration.Handoff.fresh_start(state, turn)
        state = %{state | turn: turn}

        # Claude's goal (`goal/2`) lived in the conversation it could not resume, and the
        # new one has none: shown as still active, any turn's end would read as meeting it.
        state = if fresh?, do: %{put_goal(state, nil) | goal_checked: false}, else: state

        # A run that ended while the session opened never reaches Claude.
        case started(state) do
          :ok ->
            {state, opts} = take_wake(state, session)
            # Fresh for every prompt: Claude finishes one whose uuid its transcript
            # already holds without running a turn for it (Upstream #16897).
            uuid = HalC2.Environment.uuid4()
            state = announce_bypass(state, turn)
            state = put_in(state.turn[:prompt], %{uuid: uuid, started: false})
            Session.send_message(state.session, claude_content(turn), [uuid: uuid] ++ opts)
            {:reply, :ok, state}

          :ended ->
            unsent(state, turn)
            {:reply, :ok, %{state | turn: nil, last_ids: last_ids}}
        end

      {:error, reason} ->
        Logger.warning("claude turn failed to start: #{inspect(reason)}")
        unsent(state, turn)
        finish(state, "failed", start_failure("Claude", reason))
        {:reply, :ok, %{state | turn: nil, last_ids: last_ids}}
    end
  end

  # IdleSessions' release: a runtime that took a turn since the thread looked idle keeps it.
  # It leaves the registry before it answers: the registry drops a dead runtime's key
  # only when it gets to its exit, so a lookup right after the release would find a pid
  # that is gone. `terminate/2` runs after that, with the key free: a turn may start a
  # new runtime meanwhile, so for a moment two run for the thread, and nothing in
  # `terminate/2` may count on having the thread to itself. What it ends there is
  # named by ids from this runtime's own state (its work, background commands and
  # subagents), which a replacement runtime never reuses, so its writes to the shared
  # thread stream cannot touch the new runtime's work.
  def handle_call(:release, _from, %{turn: nil} = state) do
    Registry.unregister(HalC2.Claude.Registry, state.thread_id)
    {:stop, {:shutdown, :released}, :ok, state}
  end

  def handle_call(:release, _from, state), do: {:reply, :busy, state}

  # Pinned to a run, the interrupt stops only that run's turn: a different
  # turn that began since the caller read the run is not the caller's to stop.
  def handle_call({:interrupt, run_id}, _from, %{turn: %{ids: %{run: other}}} = state)
      when is_binary(run_id) and run_id != other,
      do: {:reply, {:error, "no running turn"}, state}

  # Between turns a stop naming a run that started before the latest turn's (a
  # restart that read it as active) leaves the work that later run left, nor its session
  # (#474); one naming that run or a later one, on another provider, ends it.
  def handle_call({:interrupt, run_id}, from, %{turn: nil, last_run: last} = state)
      when is_binary(run_id) and is_binary(last) and run_id != last do
    if HalC2.Orchestration.earlier_run?(state.thread_id, run_id, last),
      do: {:reply, {:error, "no running turn"}, state},
      else: handle_call(:interrupt, from, state)
  end

  def handle_call({:interrupt, _run_id}, from, state), do: handle_call(:interrupt, from, state)

  def handle_call(:interrupt, _from, %{turn: turn, session: session} = state)
      when turn != nil and session != nil do
    {:reply, :ok, interrupt_now(state)}
  end

  # Between turns, stopping the thread stops the work it left running in the background,
  # with the process that runs it; the next turn resumes the conversation. A subagent ends
  # cancelled, as Claude reports a task it stopped; a command ends interrupted.
  def handle_call(:interrupt, _from, %{turn: nil, session: session} = state)
      when session != nil and state.work != %{} do
    state =
      state
      |> end_work(&match?(%{sub: %{}}, &1), "cancelled")
      |> end_work("interrupted")

    GenServer.stop(session)
    {:reply, :ok, %{state | session: nil, permission_mode: nil}}
  end

  def handle_call(:interrupt, _from, state), do: {:reply, {:error, "no running turn"}, state}

  # The message reads like the turn's own: its effort prefix, files and images.
  def handle_call({:steer, run_id, message}, _from, %{turn: %{ids: %{run: run_id}}} = state)
      when state.session != nil do
    content = claude_content(Map.put(message, :launch, state.turn.launch))
    # Its uuid is one the turn's result may name (`other_turn?/2`).
    uuid = HalC2.Environment.uuid4()
    Session.send_message(state.session, content, priority: "now", uuid: uuid)

    state =
      if state.turn[:prompt],
        do:
          update_in(
            state.turn.prompt,
            &Map.update(&1, :steers, [uuid], fn ids -> [uuid | ids] end)
          ),
        else: state

    {:reply, :ok, %{state | steered: true}}
  end

  def handle_call(:rollback, _from, %{turn: nil} = state) do
    state = end_work(state, "interrupted")
    if state.session, do: GenServer.stop(state.session)
    {:reply, :ok, %{state | session: nil, session_id: nil, permission_mode: nil, wake: nil}}
  end

  def handle_call(:rollback, _from, state),
    do: {:reply, {:error, "Interrupt the current turn before rewinding."}, state}

  def handle_call({:steer, _run_id, _message}, _from, state),
    do: {:reply, {:error, "no running turn"}, state}

  def handle_call({:subagent_tool?, tool_use_id}, _from, state) do
    reply =
      Enum.any?(state.work, fn
        {_, %{sub: %{} = sub}} -> is_map_key(Map.get(sub, :tools, %{}), tool_use_id)
        _ -> false
      end) or buffered_subagent_tool?(state.wake, tool_use_id)

    {:reply, reply, state}
  end

  # `hal_c2_background_wait`: the mark lives on the work's item, so it ends with the work.
  def handle_call({:await_background, task_ids, awaited}, _from, state) do
    matched =
      for id <- Enum.uniq(task_ids),
          tool = state.tasks[id] || id,
          match?(%{background: true}, state.work[tool]),
          do: {id, tool}

    items =
      for {_id, tool} <- matched,
          %{id: item_id} <- [state.work[tool].item || state.items[tool]],
          uniq: true,
          do: item_id

    state =
      Enum.reduce(matched, state, fn {_id, tool}, state ->
        put_in(state.work[tool], Map.put(state.work[tool], :awaited, awaited))
      end)

    if items != [] do
      commit(state, fn stream ->
        for item_id <- items do
          # Cleared as false: a patch only sets fields.
          Orchestration.upsert(stream, "turn-item", item_id, fn
            nil -> nil
            item -> Map.put(item, "awaited", awaited)
          end)
        end
      end)
    end

    {:reply, {:ok, Enum.map(matched, &elem(&1, 0))}, state}
  end

  def handle_call({:respond, request_id, response}, _from, state) do
    case Map.pop(state.requests, request_id) do
      {nil, _} ->
        {:reply, {:error, "no pending request #{request_id}"}, state}

      # The answers go back as the tool's input, keyed by question text.
      {{:question, control_id, input}, requests} ->
        {answer, status} =
          if response["dismissed"],
            do: {{:deny, "The user dismissed the question."}, "cancelled"},
            else:
              {{:allow, Map.put(input, "answers", claude_answers(response["answers"]))},
               "resolved"}

        Session.answer_permission(state.session, control_id, answer)
        state = resolve_request(%{state | requests: requests}, request_id, response, status)
        {:reply, :ok, state}

      # A dismissed dialog is cancelled, and Claude does what it does without an answer.
      {{:dialog, control_id, question}, requests} ->
        {answer, status} =
          if response["dismissed"],
            do: {:cancelled, "cancelled"},
            else:
              {{:completed, resume_choice(claude_answers(response["answers"])[question])},
               "resolved"}

        Session.answer_dialog(state.session, control_id, answer)
        state = resolve_request(%{state | requests: requests}, request_id, response, status)
        {:reply, :ok, state}

      # An MCP tool's elicitation: the answer is for this one request, and no
      # session or standing grant is written for the next one. A decision the card
      # does not offer ("acceptForSession") declines.
      {{:elicitation, control_id, params}, requests} ->
        decision =
          cond do
            response["dismissed"] -> "cancel"
            response["decision"] in ["accept", "decline", "cancel"] -> response["decision"]
            true -> "decline"
          end

        answer = HalC2.Codex.Elicitation.response(params, decision)
        Session.answer_elicitation(state.session, control_id, answer)

        state =
          resolve_request(
            %{state | requests: requests},
            request_id,
            decision,
            if(decision == "cancel", do: "cancelled", else: "resolved")
          )

        {:reply, :ok, state}

      {{:permission, control_id, tool, suggestions}, requests} ->
        # Claude forbade remembering this one (`suppressAlwaysAllowRule`): a session
        # grant the card did not offer declines.
        decision =
          case response["decision"] || "decline" do
            session
            when session in ["acceptForSession", "acceptAlways"] and suggestions == :once ->
              "decline"

            decision ->
              decision
          end

        cancelled? = decision == "cancel" or response["dismissed"] == true

        answer =
          case decision do
            _ when cancelled? ->
              :cancel

            "accept" ->
              :allow

            session when session in ["acceptForSession", "acceptAlways"] ->
              {:allow_session, session_rules(tool, suggestions)}

            _ ->
              {:deny, "The user declined."}
          end

        Session.answer_permission(state.session, control_id, answer)

        state =
          resolve_request(
            %{state | requests: requests},
            request_id,
            decision,
            if(cancelled?, do: "cancelled", else: "resolved")
          )

        # Cancelling an approval stops the turn instead of carrying on without
        # the tool.
        state = if cancelled?, do: interrupt_now(state), else: state
        {:reply, :ok, state}
    end
  end

  # A CLI that takes what the helper passes on and never answers (stopped, or wedged) would
  # hold its turn running for good: it is asked something any CLI answers, at once, and
  # an error is an answer too. One that stays quiet goes, for `Recovery` to kill.
  defp answering(session) do
    timeout = Application.get_env(:hal_c2, :claude_reattach_timeout_ms, 10_000)
    _reply = Session.control(session, "mcp_status", %{}, timeout)
    :ok
  catch
    :exit, _ ->
      Process.unlink(session)
      Process.exit(session, :kill)
      {:error, :no_answer}
  end

  # Claude gets ten seconds to end the turn itself after an interrupt; after that
  # the run is settled as interrupted here (`:settle_interrupt`).
  defp interrupt_now(%{turn: turn, session: session} = state)
       when turn != nil and session != nil do
    Session.control(session, "interrupt")
    settle = Application.get_env(:hal_c2, :claude_interrupt_timeout_ms, 10_000)
    Process.send_after(self(), {:settle_interrupt, turn.ids.run}, settle)
    %{state | interrupted: true}
  end

  # What a CLI stopped for another instance's (`ensure_session/2`), or one killed for
  # not answering on reattaching, had already sent belongs to no turn of this one, and
  # its checkpoints would save this state over its dir.
  @impl true
  def handle_info({:claude, session, _message}, %{session: current} = state)
      when session != current,
      do: {:noreply, state}

  def handle_info({:claude, _session, {:checkpoint, checkpoint}}, state),
    do: {:noreply, Durable.checkpoint(checkpoint, __MODULE__, state, &flush(&1, :timer))}

  def handle_info(:durable_save, state),
    do: {:noreply, Durable.save_due(state, &flush(&1, :timer))}

  def handle_info({:claude, _session, {:message, message}}, state) do
    message = result_meta(message)
    {:noreply, receive_message(message, budget(state, message))}
  end

  # The thread would not run the wake (`wake/2`): its messages go on as between turns.
  def handle_info(:wake_refused, %{turn: nil, wake: %{buffer: [_ | _] = buffer} = wake} = state) do
    state = %{state | wake: if(wake.open, do: %{wake | buffer: nil})}
    {:noreply, buffer |> Enum.reverse() |> Enum.reduce(state, &message/2)}
  end

  def handle_info(:wake_refused, state), do: {:noreply, state}

  def handle_info({:release_notices, task_id}, state) do
    if Enum.any?(state.notices, &(&1["task_id"] == task_id)),
      do: {:noreply, release_notices(state)},
      else: {:noreply, state}
  end

  def handle_info(
        {:claude, session, {:permission, id, _tool, _input, _context}},
        %{turn: nil} = state
      ) do
    Session.answer_permission(session, id, {:deny, "No turn is running."})
    {:noreply, state}
  end

  # Plan mode's plan: captured for the user, and Claude stops to wait for them.
  def handle_info({:claude, session, {:permission, id, "ExitPlanMode", input, _}}, state) do
    state =
      state
      |> flush()
      |> ensure_item("plan:#{id}", :plan)
      |> finish_plan("plan:#{id}", input["plan"] || "")

    Session.answer_permission(
      session,
      id,
      {:deny,
       "The client captured your proposed plan. Stop here and wait for the user's feedback or implementation request in a later turn."}
    )

    {:noreply, state}
  end

  def handle_info({:claude, _session, {:permission, id, "AskUserQuestion", input, _}}, state) do
    {state, request_id} = open_question(flush(state), id, claude_questions(input))
    request = {:question, id, input}
    {:noreply, %{state | requests: Map.put(state.requests, request_id, request)}}
  end

  def handle_info({:claude, _session, {:permission, id, tool, input, context}}, state) do
    kind =
      cond do
        tool in @file_tools -> "file-change"
        tool in ["Read", "Glob", "Grep", "LS"] -> "file-read"
        # Bash, the subagent and web tools, and any tool HAL-C2 does not know.
        true -> "command"
      end

    # The user approves what will actually run: a request carrying a command
    # shows that command, and Claude's description of it only stands in when
    # there is no command to show.
    prompt =
      context["title"] ||
        if(command?(input),
          do: summarize_tool(tool, input),
          else:
            context["description"] || context["decision_reason"] || summarize_tool(tool, input)
        )

    # When Claude forbids an always-allow rule, the approval offers only decline and
    # approve (Upstream #22546).
    once? = context["suppressAlwaysAllowRule"] == true

    options =
      if once?,
        do: [
          %{"decision" => "decline", "label" => "Decline"},
          %{"decision" => "accept", "label" => "Approve"}
        ]

    {state, request_id} =
      open_request(
        flush(state),
        id,
        kind,
        prompt,
        options,
        request_reason(state, prompt, context)
      )

    request =
      {:permission, id, tool, if(once?, do: :once, else: context["permission_suggestions"])}

    {:noreply, %{state | requests: Map.put(state.requests, request_id, request)}}
  end

  def handle_info({:claude, session, {:elicitation, id, _request}}, %{turn: nil} = state) do
    Session.answer_elicitation(session, id, %{"action" => "decline"})
    {:noreply, state}
  end

  # An MCP tool asks the user to confirm before it goes on: an approval naming
  # its server, offering only that one request's approve, decline or cancel.
  # A request the card cannot answer (a web sign-in, form values it cannot
  # fill, input it does not describe) is declined without asking.
  def handle_info({:claude, _session, {:elicitation, id, request}}, state) do
    params = %{
      "mode" => request["mode"],
      "message" => request["message"],
      "serverName" => request["mcp_server_name"],
      "requestedSchema" => request["requested_schema"]
    }

    answerable? =
      request["mode"] != "url" and is_map(request["requested_schema"]) and
        HalC2.Codex.Elicitation.response(params, "accept")["action"] == "accept"

    if answerable? do
      %{app: app, options: options} = HalC2.Codex.Elicitation.describe(params)
      options = Enum.filter(options, &(&1["decision"] in ["accept", "decline", "cancel"]))

      {state, request_id} =
        open_request(
          flush(state),
          "mcp-elicitation:#{id}",
          "mcp-elicitation",
          request["message"],
          options,
          %{"appName" => app}
        )

      request = {:elicitation, id, params}
      {:noreply, %{state | requests: Map.put(state.requests, request_id, request)}}
    else
      Session.answer_elicitation(state.session, id, %{"action" => "decline"})
      {:noreply, state}
    end
  end

  # Claude stopped waiting for an answer (it withdrew the request): the prompt
  # closes as cancelled. One the user already answered is no longer open, and
  # stays answered.
  def handle_info({:claude, _session, {:permission_cancelled, control_id}}, state) do
    case Enum.find(state.requests, fn {_id, request} -> elem(request, 1) == control_id end) do
      nil ->
        {:noreply, state}

      {request_id, request} ->
        state = %{state | requests: Map.delete(state.requests, request_id)}

        state =
          if state.turn,
            do: resolve_request(state, request_id, cancelled_decision(request), "cancelled"),
            else: state

        {:noreply, state}
    end
  end

  def handle_info({:claude, session, {:dialog, id, _kind, _payload}}, %{turn: nil} = state) do
    Session.answer_dialog(session, id, :cancelled)
    {:noreply, state}
  end

  # Claude asks before it continues a long, old conversation (`resume_return`).
  def handle_info({:claude, _session, {:dialog, id, "resume_return", payload}}, state) do
    question = resume_question(payload)
    {state, request_id} = open_question(flush(state), id, [question])
    request = {:dialog, id, question["id"]}
    {:noreply, %{state | requests: Map.put(state.requests, request_id, request)}}
  end

  # A turn Claude has not ended ten seconds after it was stopped is settled as
  # interrupted; its CLI is stopped, so the next turn resumes the conversation.
  def handle_info({:settle_interrupt, run_id}, state) do
    if state.turn && state.turn.ids.run == run_id && state.interrupted do
      state = end_turn(state, "interrupted", nil)
      if state.session, do: GenServer.stop(state.session)
      {:noreply, %{state | session: nil, interrupted: false}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:EXIT, session, _reason}, %{session: session} = state) do
    state =
      cond do
        state.turn && state.interrupted -> end_turn(state, "interrupted", nil)
        # The MC ending its CLI on the way down leaves the run and its work for the
        # next boot's recovery (`HalC2.Orchestration.Recovery.stopping?/0`).
        HalC2.Orchestration.Recovery.stopping?() -> state
        state.turn -> end_turn(state, "failed", "Claude exited")
        true -> end_work(state, "failed")
      end

    # A wake waiting for its run ends there, cut short.
    wake = if match?(%{buffer: [_ | _]}, state.wake), do: %{state.wake | open: false}
    {:noreply, %{state | session: nil, wake: wake}}
  end

  def handle_info(:flush, state),
    do: {:noreply, Durable.flushed(state, flush(%{state | flush_timer: nil}, :timer))}

  def handle_info(_other, state), do: {:noreply, state}

  # A turn the store fails to record fails, and stops (`HalC2.Orchestration.Unrecorded`).
  defoverridable handle_info: 2, handle_call: 3

  @impl true
  def handle_info(message, state),
    do:
      HalC2.Orchestration.Unrecorded.handle_info(__MODULE__, message, state, fn m, s ->
        super(m, s)
      end)

  @impl true
  def handle_call(request, from, state),
    do:
      HalC2.Orchestration.Unrecorded.handle_call(request, from, state, fn r, f, s ->
        super(r, f, s)
      end)

  defp cancelled_decision({:permission, _id, _tool, _suggestions}), do: "cancel"
  defp cancelled_decision({:elicitation, _id, _params}), do: "cancel"
  defp cancelled_decision(_request), do: %{"dismissed" => true}

  defp command?(input),
    do: Enum.any?(["command", "cmd", "script"], &(is_binary(input[&1]) and input[&1] != ""))

  # What an approval reads: the tool and what it would act on — its command or
  # its file, else its input — with the summary cut at 400 characters.
  defp summarize_tool(tool, input) do
    first = fn keys ->
      Enum.find_value(keys, fn key ->
        case input[key] do
          value when is_binary(value) and value != "" -> value
          _ -> nil
        end
      end)
    end

    cond do
      command = first.(["command", "cmd", "script"]) ->
        "#{tool}: #{String.slice(command, 0, 400)}"

      path = first.(["file_path", "path", "filename", "fileName"]) ->
        "#{tool}: #{String.slice(path, 0, 400)}"

      true ->
        serialized = JSON.encode!(input)

        if String.length(serialized) <= 400,
          do: "#{tool}: #{serialized}",
          else: "#{tool}: #{String.slice(serialized, 0, 397)}..."
    end
  end

  # The process runs the background work, so it ends with it: released when idle, or
  # stopped with its thread. Its writes may fail when the MC itself is stopping; the
  # next boot ends what is left (`HalC2.Orchestration.Recovery`).
  @impl true
  def terminate(_reason, state) do
    Durable.leaving(state, &flush(&1, :timer))
    unless HalC2.Orchestration.Recovery.stopping?(), do: end_work(state, "interrupted")
    :ok
  catch
    _, _ -> :ok
  end

  @impl true
  def code_change(_old, state, _extra),
    do:
      {:ok,
       state
       |> Map.put_new(:work, %{})
       |> Map.put_new(:tasks, %{})
       |> Map.put_new(:finished_tasks, MapSet.new())
       |> Map.put_new(:notices, [])
       |> Map.put_new(:last_ids, nil)
       |> Map.put_new_lazy(:last_run, fn -> state[:last_ids][:run] end)
       |> Map.put_new(:usage_instance, nil)
       |> Map.put_new(:wake, nil)
       |> Map.put_new(:permission_mode, nil)
       |> Map.put_new(:steered, false)
       |> Map.put_new(:launch, nil)
       |> Map.put_new(:placed, nil)
       |> Map.put_new(:bypass_notice, nil)
       |> Map.put_new(:goal, nil)
       |> Map.put_new(:goal_checked, false)
       |> Map.put_new(:task_list, nil)
       |> Map.put_new(:task_calls, %{})
       |> Map.put_new(:sandbox_spent, nil)
       |> Map.update!(:launch, &upgrade_launch(&1, state))
       |> Map.update!(:requests, &upgrade_requests/1)
       |> Map.put(:v, @state_version)}

  # A session started before launches recorded their MCP server has the thread's own.
  # One from before they recorded their instance cannot be told from the latest
  # turn's ids: a start that failed on another instance left those naming it while
  # this CLI still runs on the earlier one (restoring them now cannot repair a
  # state the old runtime already kept). Like Codex's `:unknown`, it is stamped
  # what no turn launches with, so the next turn starts its own CLI once.
  defp upgrade_launch(%{} = launch, %{last_ids: %{} = ids, thread_id: thread_id}) do
    launch
    |> Map.put_new_lazy(:mcp, fn -> HalC2.Mcp.for_agent(thread_id, Entities.instance(ids)) end)
    |> Map.put_new(:disallowed_tools, [])
    |> then(&Map.put_new(&1, :workers_only, kept_to_workers?(&1.disallowed_tools)))
    |> Map.put_new(:context_window, 200_000)
    |> Map.put_new(:instance, :unknown)
  end

  defp upgrade_launch(launch, _state), do: launch

  # A launch from before `:workers_only` was kept: such a session had the subagent tool
  # taken away.
  defp kept_to_workers?(disallowed), do: Enum.any?(@agent_tools, &(&1 in disallowed))

  # Allowing for the session keeps the CLI's own suggested rules, scoped to this
  # session, or allows the whole tool when it suggested none.
  defp session_rules(tool, suggestions) do
    case suggestions do
      [_ | _] ->
        Enum.map(suggestions, &Map.put(&1, "destination", "session"))

      _ ->
        [
          %{
            "type" => "addRules",
            "rules" => [%{"toolName" => tool}],
            "behavior" => "allow",
            "destination" => "session"
          }
        ]
    end
  end

  # Before session approvals, a pending permission held only its control id.
  defp upgrade_requests(requests),
    do:
      Map.new(requests, fn
        {id, control_id} when is_binary(control_id) -> {id, {:permission, control_id, nil, nil}}
        other -> other
      end)

  # AskUserQuestion's questions; each is keyed by its text, as Claude keys answers.
  defp claude_questions(input) do
    for {question, index} <- Enum.with_index(input["questions"] || [], 1),
        text = String.trim(question["question"] || ""),
        text != "" do
      %{
        "id" => text,
        "header" => non_empty(question["header"], "Question #{index}"),
        "question" => text,
        "options" =>
          for option <- question["options"] || [],
              label = String.trim(option["label"] || ""),
              label != "" do
            %{"label" => label, "description" => non_empty(option["description"], label)}
            |> with_preview(option["preview"])
          end,
        "multiSelect" => question["multiSelect"] == true
      }
    end
  end

  # An option's preview, kept verbatim (Upstream #21932); an option without one keeps its
  # shape.
  defp with_preview(option, preview) when is_binary(preview) and preview != "",
    do: Map.put(option, "preview", preview)

  defp with_preview(option, _preview), do: option

  @resume_compact "Compact and continue"
  @resume_never "Don't ask again"

  # The question of Claude's resume dialog: how old and how large the conversation is,
  # and what to do about it. Clients recognize the question and its "never" answer by
  # these words.
  defp resume_question(payload) do
    minutes = whole(payload["sessionAgeMinutes"])

    age =
      if minutes >= 60, do: "#{div(minutes, 60)}h #{rem(minutes, 60)}m", else: "#{minutes}m"

    tokens =
      payload["estimatedTokens"]
      |> whole()
      |> Integer.to_string()
      |> String.replace(~r/\B(?=(\d{3})+$)/, ",")

    text = "This session is #{age} old and uses #{tokens} tokens. Compact it before continuing?"

    %{
      "id" => text,
      "header" => "Resume session",
      "question" => text,
      "options" => [
        %{
          "label" => @resume_compact,
          "description" => "Resume with a summary and use fewer tokens."
        },
        %{
          "label" => "Keep full history",
          "description" => "Resume without changing the conversation."
        },
        %{
          "label" => @resume_never,
          "description" => "Keep full history and skip future resume prompts."
        }
      ],
      "multiSelect" => false
    }
  end

  defp whole(number) when is_number(number), do: max(0, trunc(number))
  defp whole(_other), do: 0

  # What Claude does with the answer: compacts first, continues as it is, or continues
  # and never asks again.
  defp resume_choice(@resume_compact), do: "compact"
  defp resume_choice(@resume_never), do: "never"
  defp resume_choice(_answer), do: "continue"

  defp claude_answers(answers) do
    for {question, value} <- answers || %{}, into: %{} do
      {question, if(is_list(value), do: Enum.join(value, ", "), else: to_string(value || ""))}
    end
  end

  defp non_empty(value, default) when is_binary(value),
    do: if(String.trim(value) == "", do: default, else: String.trim(value))

  defp non_empty(_value, default), do: default

  # The message, with where its files are; images go inline as content blocks. The
  # history a turn hands over (`HalC2.Orchestration.Handoff.ahead/2`) goes in front of
  # what the user wrote, and in a block of its own when that is a command: Claude runs
  # a slash command only from the last block (#1342). The user's text is read on its
  # own either way, so a `$skill` someone mentioned earlier in the thread does not run.
  defp claude_content(%{history: history} = turn) when is_binary(history) do
    said = String.replace_prefix(turn.text, history <> "\n\n", "")

    case claude_content(%{turn | history: nil, text: said}) do
      text when is_binary(text) ->
        if String.starts_with?(String.trim_leading(text), "/"),
          do: [
            %{"type" => "text", "text" => history <> "\n\n"},
            %{"type" => "text", "text" => text}
          ],
          else: history <> "\n\n" <> text

      blocks ->
        [%{"type" => "text", "text" => history <> "\n\n"} | blocks]
    end
  end

  defp claude_content(turn) do
    attachments = Map.get(turn, :attachments, [])
    images = HalC2.Attachments.native_images(attachments)

    image_blocks =
      for {mime, data} <- images,
          do: %{
            "type" => "image",
            "source" => %{"type" => "base64", "media_type" => mime, "data" => data}
          }

    # A `$skill` mention runs as Claude's own `/skill` command: the command is
    # the last block (where Claude expands it), after any leading text and the
    # message's images. Skills are re-read at each send, as they change
    # mid-session; one that may not run for the user stays plain text. A sandboxed
    # review's message (#1412) is sent as it is: this machine's skills, and their
    # paths, are not the sandbox's.
    skills =
      if Map.get(turn, :sandbox),
        do: %{},
        else:
          HalC2.Claude.Skills.user_invocable(
            turn.launch[:instance] || Entities.instance(turn[:ids] || %{}),
            Map.get(turn, :cwd)
          )

    case HalC2.Claude.Skills.dispatch(turn.text, skills) do
      nil ->
        text = Provider.prompt(turn.text, turn.launch.prompt_effort)

        cond do
          # Claude runs a command only from the last block, as typed: what came with
          # it (where its files are, its images) goes ahead of it.
          attachments != [] and String.starts_with?(String.trim_leading(text), "/") ->
            notes = HalC2.Attachments.prompt_text("", attachments)

            ([if(notes != "", do: %{"type" => "text", "text" => notes})] ++
               image_blocks ++ [%{"type" => "text", "text" => text}])
            |> Enum.reject(&is_nil/1)

          images == [] ->
            HalC2.Attachments.prompt_text(text, attachments)

          true ->
            [%{"type" => "text", "text" => HalC2.Attachments.prompt_text(text, attachments)}] ++
              image_blocks
        end

      {leading, command} ->
        leading =
          (leading || "")
          |> Provider.prompt(turn.launch.prompt_effort)
          |> HalC2.Attachments.prompt_text(attachments)

        Enum.reject(
          [
            if(leading != "", do: %{"type" => "text", "text" => leading})
          ] ++
            image_blocks ++ [%{"type" => "text", "text" => command}],
          &is_nil/1
        )
    end
  end

  # The instance's configured launch arguments reach the CLI, less the ones
  # HAL-C2 sets itself: a permission flag there wins over the thread's mode
  # instead of going to the CLI twice (below), `--settings` is merged under
  # HAL-C2's settings (HAL-C2's value wins where both set a key), and
  # `--append-system-prompt[-file]` follows HAL-C2's own instructions in the
  # one flag the CLI reads. A settings or instructions value that cannot be
  # read fails the turn before Claude starts, naming no value from it. Claude
  # is asked for summaries of its thinking unless thinking is off or the
  # launch arguments already say how thinking is shown.
  #
  # A sandboxed review's CLI (#1412) takes none of the instance's launch arguments:
  # they are this machine's, and may carry settings, keys, headers, MCP servers or
  # paths that must not reach the sandbox or the agent's argv.
  defp with_launch_args(launch, %{sandbox: true}, _instance),
    do: launch |> apply_launch_args({:ok, []}, nil) |> Map.put(:sandbox, true)

  defp with_launch_args(launch, turn, instance),
    do: apply_launch_args(launch, Provider.launch_args(instance), Map.get(turn, :cwd))

  defp apply_launch_args(launch, args, cwd) do
    case args do
      {:ok, args} ->
        {override, rest} = take_permission_flag(args)

        with {:ok, user_settings, rest} <- take_settings(rest, cwd),
             {:ok, appended, rest} <- take_appended(rest, cwd) do
          summaries? =
            launch.settings["alwaysThinkingEnabled"] != false and
              not Enum.any?(rest, &String.starts_with?(&1, "--thinking-display"))

          own =
            if summaries?,
              do: Map.put(launch.settings, "showThinkingSummaries", true),
              else: launch.settings

          launch
          |> Map.put(:settings, deep_merge(user_settings, own))
          |> Map.put(:extra_args, rest)
          |> Map.put(:appended, appended)
          |> Map.put(:permission_override, override)
          |> Map.put(:thinking_summaries, summaries?)
        else
          {:error, message} ->
            launch
            |> Map.put(:extra_args, [])
            |> Map.put(:appended, [])
            |> Map.put(:launch_error, message)
        end

      {:error, message} ->
        launch
        |> Map.put(:extra_args, [])
        |> Map.put(:appended, [])
        |> Map.put(:launch_error, "Claude could not start: #{message}")
    end
  end

  defp deep_merge(left, right) do
    Map.merge(left, right, fn _key, a, b ->
      if is_map(a) and is_map(b), do: deep_merge(a, b), else: b
    end)
  end

  # Every `--settings` value in `args`, read and merged in order: a value
  # starting with `{` is JSON, any other names a settings file (relative to
  # the thread's folder). The flags leave `args`; HAL-C2's own `--settings`
  # carries the merged result.
  defp take_settings(args, cwd), do: take_settings(args, cwd, %{}, [])

  defp take_settings([], _cwd, settings, kept), do: {:ok, settings, Enum.reverse(kept)}

  defp take_settings(["--settings", value | rest], cwd, settings, kept),
    do: merge_settings_value(value, rest, cwd, settings, kept)

  defp take_settings(["--settings=" <> value | rest], cwd, settings, kept),
    do: merge_settings_value(value, rest, cwd, settings, kept)

  defp take_settings(["--settings"], _cwd, _settings, _kept),
    do: {:error, settings_error()}

  defp take_settings([arg | rest], cwd, settings, kept),
    do: take_settings(rest, cwd, settings, [arg | kept])

  defp merge_settings_value(value, rest, cwd, settings, kept) do
    case read_settings_value(value, cwd) do
      {:ok, decoded} -> take_settings(rest, cwd, deep_merge(settings, decoded), kept)
      :error -> {:error, settings_error()}
    end
  end

  defp settings_error,
    do: "Claude could not start: its --settings launch argument could not be read."

  # A file the user's own launch arguments name, in the thread's folder: the
  # same file Claude itself would read for --settings.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_settings_value(value, cwd) do
    if String.starts_with?(String.trim(value), "{") do
      case JSON.decode(value) do
        {:ok, %{} = settings} -> {:ok, settings}
        _ -> :error
      end
    else
      with path when is_binary(path) <- cwd && Path.absname(value, cwd),
           {:ok, text} <- File.read(path),
           {:ok, %{} = settings} <- HalC2.Claude.Skills.decode_lenient(text) do
        {:ok, settings}
      else
        _ -> :error
      end
    end
  end

  # Every `--append-system-prompt[-file]` value in `args`, in order; a file is
  # read from the thread's folder, and one that cannot be read stops the turn
  # saying which.
  defp take_appended(args, cwd), do: take_appended(args, cwd, [], [])

  defp take_appended([], _cwd, appended, kept),
    do: {:ok, Enum.reverse(appended), Enum.reverse(kept)}

  defp take_appended(["--append-system-prompt", text | rest], cwd, appended, kept),
    do: take_appended(rest, cwd, [text | appended], kept)

  defp take_appended(["--append-system-prompt=" <> text | rest], cwd, appended, kept),
    do: take_appended(rest, cwd, [text | appended], kept)

  defp take_appended(["--append-system-prompt"], _cwd, _appended, _kept),
    do:
      {:error,
       "Claude could not start: its --append-system-prompt launch argument could not be read."}

  defp take_appended(["--append-system-prompt-file", path | rest], cwd, appended, kept),
    do: read_appended_file(path, rest, cwd, appended, kept)

  defp take_appended(["--append-system-prompt-file=" <> path | rest], cwd, appended, kept),
    do: read_appended_file(path, rest, cwd, appended, kept)

  defp take_appended(["--append-system-prompt-file"], _cwd, _appended, _kept),
    do:
      {:error,
       "Claude could not start: its --append-system-prompt-file launch argument could not be read."}

  defp take_appended([arg | rest], cwd, appended, kept),
    do: take_appended(rest, cwd, appended, [arg | kept])

  # As above: a file the user's launch arguments name, in the thread's folder.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_appended_file(path, rest, cwd, appended, kept) do
    with true <- is_binary(cwd),
         {:ok, text} <- File.read(Path.absname(path, cwd)) do
      take_appended(rest, cwd, [text | appended], kept)
    else
      _ -> {:error, ~s(Claude could not start: "#{path}" could not be read.)}
    end
  end

  defp take_permission_flag(args), do: take_permission_flag(args, nil, [])

  defp take_permission_flag([], override, rest), do: {override, Enum.reverse(rest)}

  defp take_permission_flag(["--permission-mode", mode | rest], _override, kept),
    do: take_permission_flag(rest, mode, kept)

  defp take_permission_flag(["--permission-mode=" <> mode | rest], _override, kept),
    do: take_permission_flag(rest, mode, kept)

  defp take_permission_flag(["--dangerously-skip-permissions" | rest], override, kept),
    do: take_permission_flag(rest, override || "bypassPermissions", kept)

  defp take_permission_flag(["--dangerously-skip-permissions=" <> value | rest], override, kept) do
    override = if value in ["true", ""], do: override || "bypassPermissions", else: override
    take_permission_flag(rest, override, kept)
  end

  defp take_permission_flag([arg | rest], override, kept),
    do: take_permission_flag(rest, override, [arg | kept])

  # A permission flag in the launch arguments, else plan mode, else a read-only
  # run's never-ask, else the thread's runtime mode: Full access asks as the default
  # mode does, or in Auto where that is allowed, when Claude's settings forbid
  # bypassing (`bypass_policy/1`).
  defp permission_mode(turn) do
    launch = Map.get(turn, :launch) || %{}

    cond do
      launch[:permission_override] -> launch[:permission_override]
      Map.get(turn, :interaction_mode) == "plan" -> "plan"
      Map.get(turn, :read_only) -> "dontAsk"
      Map.get(turn, :bypass_limited) == :auto -> "auto"
      Map.get(turn, :bypass_limited) -> "default"
      true -> Map.get(@permission_modes, turn.runtime_mode, "default")
    end
  end

  # Claude refuses bypass mode when its settings disable it, so a Full access turn
  # there runs in Auto (`:auto`), or in the default mode when they turn Auto off too
  # (`:disabled`), asking the user before the tools those settings guard. Settings
  # that cannot be read limit only this turn to the default mode: each turn reads
  # them again.
  #
  # Why the installed CLI cannot run `turn`'s model, or nil. A sandboxed review's CLI
  # is the review image's (#1412), not the one installed here, which it never needs.
  defp too_old(%{sandbox: true}, _instance), do: nil
  defp too_old(turn, instance), do: Provider.too_old(turn.model, instance)

  # A sandboxed review's CLI has a home of its own in the sandbox, so this machine's
  # Claude settings say nothing about it.
  defp bypass_policy(%{sandbox: true} = turn), do: turn

  defp bypass_policy(turn) do
    if permission_mode(turn) == "bypassPermissions" and turn.launch[:permission_override] == nil do
      instance = Entities.instance(turn.ids)
      config_dir = HalC2.Claude.Provider.config_dir(instance, turn.cwd)

      # The switches that turn bypass off are read from the `--settings` launch
      # argument too: it is merged into the settings the session runs with.
      bypass =
        if HalC2.Claude.Skills.bypass_disabled_in?(turn.launch.settings),
          do: :disabled,
          else: HalC2.Claude.Skills.bypass_permissions(config_dir, turn.cwd)

      case bypass do
        :allowed ->
          turn

        :disabled ->
          auto_off =
            HalC2.Claude.Skills.auto_disabled_in?(turn.launch.settings) or
              HalC2.Claude.Skills.auto_mode(config_dir, turn.cwd) != :allowed

          Map.put(turn, :bypass_limited, if(auto_off, do: :disabled, else: :auto))

        :unreadable ->
          Map.put(turn, :bypass_limited, :unreadable)
      end
    else
      turn
    end
  end

  @bypass_notices %{
    auto:
      "Claude's settings turn off bypassing permissions here, so this Full access thread runs in Auto mode and asks before the tools they guard run.",
    disabled:
      "Claude's settings turn off bypassing permissions here, so this Full access thread asks before the tools they guard run.",
    unreadable:
      "HAL-C2 could not read Claude's settings here, so this Full access turn asks before Claude's tools run."
  }

  # The thread says once why Full access asks, and again when the reason changes.
  defp announce_bypass(state, %{bypass_limited: limited} = turn)
       when limited != state.bypass_notice do
    text = @bypass_notices[limited]
    native = "bypass-limited:#{turn.ids.provider_turn}"

    state
    |> ensure_item(native, :notice, %{"title" => text, "message" => text})
    |> finish_item(native, "completed", & &1)
    |> Map.put(:bypass_notice, limited)
  end

  defp announce_bypass(state, %{bypass_limited: _}), do: state
  defp announce_bypass(state, _turn), do: %{state | bypass_notice: nil}

  # A session carried from another machine that this Claude cannot open (a newer
  # Claude Code wrote it, say) ends before it answers `initialize`. The turn then starts
  # a new session with the handoff instead, and the user is told.
  defp open_session(%{session: nil} = state, %{fork: %{carried: true} = fork} = turn) do
    case ensure_session(state, turn) do
      {:ok, state} ->
        if opened?(state.session),
          do: {:ok, state, turn},
          else: handed_over(%{state | session: nil}, turn, fork)

      {:error, _reason} ->
        handed_over(state, turn, fork)
    end
  end

  defp open_session(state, turn) do
    with {:ok, state} <- ensure_session(state, turn), do: {:ok, state, turn}
  end

  defp opened?(session) do
    receive do
      {:claude, ^session, {:initialized, _reply}} -> true
      {:EXIT, ^session, _reason} -> false
    after
      20_000 -> true
    end
  end

  defp handed_over(state, turn, fork) do
    turn = HalC2.Orchestration.Handoff.ahead(%{turn | fork: nil}, fork[:fallback])

    with {:ok, state} <- ensure_session(state, turn) do
      not_carried(state, turn, fork)
      {:ok, state, turn}
    end
  end

  defp not_carried(state, turn, fork) do
    at = Entities.now()
    id = "turn-item:claudeAgent:session-not-carried:#{turn.ids.run}"
    here = HalC2.ThreadArchive.label()
    mine = claude_version(turn)
    written = written_version(fork[:path])

    why =
      if mine && written && fork[:from] && Version.compare(mine, written) == :lt,
        do:
          ": Claude Code there (#{mine}) is older than on #{fork[:from]} (#{written}), which wrote it. It started a new session",
        else: ", so it started a new one"

    message =
      "Claude on #{here} could not continue its own session#{why} with a summary of the conversation."

    commit(state, fn stream ->
      [
        Orchestration.create(
          "turn-item",
          id,
          Entities.turn_item(
            turn.ids,
            id,
            "error",
            Orchestration.next_ordinal(stream),
            "completed",
            at,
            %{
              "title" => "Session not carried",
              "failure" => %{
                "class" => "provider_error",
                "message" => String.slice(message, 0, 4096),
                "code" => "session_not_carried",
                "retryable" => false
              }
            }
          )
        )
      ]
    end)
  end

  # The version `claude --version` reports here, as the turn would run it.
  defp claude_version(turn) do
    [command | args] = command(turn)
    env = Enum.to_list(HalC2.Settings.instance_env(Entities.instance(turn.ids)))

    case System.cmd(command, args ++ ["--version"], env: env, stderr_to_stdout: true) do
      {out, 0} -> out |> String.split() |> List.first() |> semver()
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # The newest Claude Code version that wrote an entry of the transcript at `path`.
  defp written_version(path) when is_binary(path) do
    path
    |> File.stream!()
    |> Stream.map(&JSON.decode/1)
    |> Stream.flat_map(fn
      {:ok, %{"version" => version}} when is_binary(version) -> List.wrap(semver(version))
      _ -> []
    end)
    |> Enum.max(Version, fn -> nil end)
  rescue
    _ -> nil
  end

  defp written_version(_path), do: nil

  defp semver(text) when is_binary(text) do
    case Version.parse(text) do
      {:ok, version} -> version
      :error -> nil
    end
  end

  defp semver(_text), do: nil

  # Fast mode left off launches as it does unset.
  defp same_launch?(launch, other), do: plain_launch(launch) == plain_launch(other)

  defp plain_launch(%{settings: %{"fastMode" => false} = settings} = launch),
    do: %{launch | settings: Map.delete(settings, "fastMode")}

  defp plain_launch(launch), do: launch

  # A new process would end the background work Claude runs, so a turn on another model
  # or other options waits until the user stops that work. Only what the user picks
  # counts: a turn that needs a new process for anything else still gets one.
  defp background_change(%{session: session} = state, turn) when session != nil do
    picked = &Map.take(plain_launch(&1), [:model, :effort, :settings, :context_window])

    if picked.(state.launch) != picked.(turn.launch) and
         Enum.any?(state.work, fn {_, work} -> work.background end),
       do:
         "Claude is still running background work, which a change of model or options would end. Stop it first, or send the message with the current selection."
  end

  defp background_change(_state, _turn), do: nil

  # The CLI takes its model, options and MCP server at launch, so a turn on others
  # resumes the conversation in a new process.
  defp ensure_session(%{session: session} = state, turn) when session != nil do
    if same_launch?(state.launch, turn.launch) do
      mode = permission_mode(turn)

      if state.permission_mode != mode do
        _ = Session.control(session, "set_permission_mode", %{"mode" => mode})
      end

      {:ok, %{state | permission_mode: mode}}
    else
      state = end_work(state, "interrupted")
      GenServer.stop(session)
      ensure_session(%{state | session: nil}, turn)
    end
  end

  # Claude cannot resume a session it never saved a message to, as when the MC sent
  # a prompt and Claude went down before writing it (Upstream #19637): it exits, and
  # every later turn would too. Such a session is replaced by a new one, handed the
  # whole thread (`HalC2.Orchestration.Handoff.fresh_start/2`). Its transcript tells,
  # where this instance keeps them. Any other session is opened, and replaced if
  # Claude ends before it answers: its transcript may not be found here, or hold no
  # message to resume at where the turn asks (a subagent's).
  defp ensure_session(state, turn) do
    Process.flag(:trap_exit, true)

    case saved_session(turn) do
      :new ->
        start_session(state, turn)

      :gone ->
        start_session(Map.put(state, :fresh_start, true), new_conversation(turn))

      :resume ->
        with {:ok, state} <- start_session(state, turn) do
          if opened?(state.session),
            do: {:ok, state},
            else:
              start_session(
                Map.put(%{state | session: nil}, :fresh_start, true),
                new_conversation(turn)
              )
        end
    end
  end

  # A fork names its own session, and a carried one is checked as it opens (`open_session/2`).
  # A sandboxed review's transcripts are in its sandbox, so nothing here is read for it.
  defp saved_session(%{fork: %{}}), do: :new
  defp saved_session(%{sandbox: true}), do: :new

  defp saved_session(%{native_thread_id: id} = turn) when is_binary(id) do
    instance = Entities.instance(turn.ids)

    case HalC2.PortableSessions.claude_transcript(instance, id, turn.cwd) do
      nil -> :resume
      path -> if saved_message?(path), do: :resume, else: :gone
    end
  end

  defp saved_session(_turn), do: :new

  defp saved_message?(path) do
    path
    |> File.stream!()
    |> Enum.any?(
      &match?({:ok, %{"type" => type}} when type in ["user", "assistant"], JSON.decode(&1))
    )
  rescue
    # A transcript that cannot be read is Claude's to judge.
    File.Error -> true
  end

  defp new_conversation(turn), do: %{turn | native_thread_id: nil} |> Map.delete(:head)

  defp start_session(state, turn) do
    opts = [
      handler: self(),
      model: turn.launch.model,
      effort: turn.launch.effort,
      settings: turn.launch.settings,
      permission_mode: permission_mode(turn),
      resume: fork_or(turn, :thread, turn.native_thread_id),
      resume_at: fork_or(turn, :turn, Map.get(turn, :head)),
      fork_session: Map.get(turn, :fork) != nil,
      partial_messages: true,
      thinking_display: Map.get(turn.launch, :thinking_summaries, false),
      tools: if(Map.get(turn, :read_only), do: ["Read", "Glob", "Grep"]),
      mcp: turn.launch.mcp,
      mcp_allowed:
        if(Map.get(turn, :read_only) and turn.launch.mcp,
          do: HalC2.Mcp.Tools.read_only_allowed()
        ),
      workers_only: Map.get(turn.launch, :workers_only, false),
      disallowed_tools: Map.get(turn.launch, :disallowed_tools, []),
      appended: Map.get(turn.launch, :appended, []),
      extra_args: Map.get(turn.launch, :extra_args, []),
      log: state.thread_id
    ]

    with {:ok, opts} <- in_sandbox(opts, turn, state),
         {:ok, session} <- Session.start_link(opts) do
      spent = if Map.get(turn, :sandbox) == true, do: Budget.new(opts[:resume] != nil)

      {:ok,
       %{
         state
         | session: session,
           permission_mode: permission_mode(turn),
           launch: turn.launch,
           sandbox_spent: spent
       }}
    end
  end

  # A sandboxed review's CLI runs in its sandbox (#1412) with the sandbox's environment
  # only: no instance command, variables or home of this machine's, no project
  # environment (none is even loaded), no attachments directory, and nothing durable,
  # since an exec stream ends with the MC.
  defp in_sandbox(opts, %{sandbox: true} = turn, _state) do
    env = %{
      "MCP_TOOL_TIMEOUT" => to_string(HalC2.Mcp.tool_timeout_ms()),
      # Its policy lets through the model's requests alone (`HalC2.OpenShell.Policy`).
      "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" => "1"
    }

    with {:ok, sandbox} <- HalC2.OpenShell.Review.for_turn(turn, env) do
      {:ok,
       Keyword.merge(opts,
         add_dirs: [],
         sandbox: sandbox,
         command: HalC2.OpenShell.Review.command("claudeAgent")
       )}
    end
  end

  defp in_sandbox(opts, turn, state) do
    {:ok,
     Keyword.merge(opts,
       cd: turn.cwd,
       # Claude can open a message's attached files where the MC saved them.
       add_dirs: [HalC2.Attachments.dir()],
       # The instance's variables in settings (such as CLAUDE_CONFIG_DIR) reach Claude,
       # over the project's environment when the project loads it.
       env: HalC2.ProjectEnvironment.for_turn(turn, session_env(turn), command(turn)),
       durable: state.thread_id,
       command: command(turn)
     )}
  end

  # The environment of the turn's `claude`. Its MCP client gives up on a tool after 60 s
  # unless told otherwise, which cuts HAL-C2's waiting tools short.
  @doc false
  def session_env(turn) do
    instance = Entities.instance(turn.ids)

    # An instance with its own Claude home runs under it. Only the config
    # directory is pointed there, never HOME: on macOS the saved login lives in
    # the keychain under HOME, and Claude would not find it signed in.
    home =
      case HalC2.Claude.Provider.home_path(instance) do
        nil -> []
        path -> [{"CLAUDE_CONFIG_DIR", HalC2.Claude.Provider.expand_home(path)}]
      end

    (Enum.to_list(HalC2.Settings.instance_env(instance)) ++
       home ++
       if(turn.launch.mcp,
         do: [{"MCP_TOOL_TIMEOUT", to_string(HalC2.Mcp.tool_timeout_ms())}],
         else: []
       ))
    |> then(&HalC2.Claude.Provider.spawn_env(instance, &1))
  end

  # The `claude` the turn's instance runs: its binary path in settings, else the one on PATH.
  # Session variables of a Claude session the MC was started from do not reach it.
  defp command(turn) do
    instance = Entities.instance(turn.ids)

    instance
    |> HalC2.Settings.instance_command(
      Application.get_env(:hal_c2, :claude_command) || ["claude"]
    )
    |> HalC2.Claude.Provider.resolve_command()
    |> HalC2.Claude.Provider.scrubbed_command(instance)
  end

  # A fork's first turn resumes the source session at the fork point, as a new session.
  defp fork_or(%{fork: %{} = fork}, key, _default), do: Map.fetch!(fork, key)
  defp fork_or(_turn, _key, default), do: default

  # --- messages ------------------------------------------------------------------

  # What a subagent says and does (a message under its tool call, `parent_tool_use_id`)
  # is its own (`sidechain/3`), never a wake. It keeps its place among a wake's messages
  # waiting for their run, where the call that started the subagent may be.
  defp receive_message(
         %{"type" => type, "parent_tool_use_id" => parent} = message,
         %{turn: nil, wake: %{buffer: buffer} = wake} = state
       )
       when type in @sidechain and is_binary(parent) and is_list(buffer),
       do: %{state | wake: %{wake | buffer: [message | buffer]}}

  defp receive_message(%{"type" => type, "parent_tool_use_id" => parent} = message, state)
       when type in @sidechain and is_binary(parent),
       do: message(message, state)

  # Claude runs one turn at a time and ends each with one `result`, so which turn a
  # result ends follows from the order: a wake Claude is running when a user's turn
  # starts ends first (`take_wake/2`), and between the MC's turns every result is a
  # wake's.
  defp receive_message(message, %{turn: nil, wake: %{buffer: buffer} = wake} = state)
       when is_list(buffer) do
    open = if result?(message), do: false, else: wake.open or wake?(message)
    %{state | wake: %{open: open, buffer: [message | buffer]}}
  end

  defp receive_message(message, %{turn: nil, wake: %{buffer: nil}} = state) do
    state = message(message, state)
    if result?(message), do: %{state | wake: nil}, else: state
  end

  defp receive_message(message, %{turn: nil, wake: nil} = state) do
    cond do
      hold_notice?(state, message) ->
        if state.notices == [], do: hold_notices(message["task_id"])
        %{state | notices: [message | state.notices]}

      wake?(message) or (result?(message) and state.notices != []) ->
        state = wake(state, message)
        %{state | wake: %{state.wake | buffer: [message | state.notices]}, notices: []}

      true ->
        message(message, state)
    end
  end

  # The result of the wake a user's turn took over; the user's own follows it. An
  # interrupt ends the user's turn with the first. A result naming the user's prompt
  # is Claude folding that prompt into the wake turn: the one result ends both, and
  # no other follows (Upstream #28010).
  defp receive_message(%{"type" => "result"} = result, %{wake: %{open: true}} = state)
       when not state.interrupted do
    state = %{state | wake: nil}

    case state.turn do
      %{prompt: %{} = prompt} ->
        if echoes_prompt?(result, prompt), do: message(result, state), else: state

      _ ->
        state
    end
  end

  # A result for a turn Claude ran by itself while the prompt waited (a resumed process
  # reporting work the last one left, a peer's message) does not end the user's turn:
  # it echoes other prompts' uuids, or comes after Claude queued the prompt and before
  # it started it. What that turn said joins this one, as a wake's does in `take_wake/2`.
  defp receive_message(%{"type" => "result"} = result, %{turn: %{prompt: %{} = prompt}} = state)
       when not state.interrupted do
    if other_turn?(result, prompt) do
      Logger.info("claude result for a turn of its own: #{inspect(result["origin"])}")
      state
    else
      message(result, state)
    end
  end

  defp receive_message(message, state), do: message(message, state)

  # Claude Code names the prompts a turn answered (`user_message_uuids`, from 2.1.252);
  # one that names none says when it queued and started the prompt instead.
  defp other_turn?(result, prompt) do
    case Enum.filter(
           List.wrap(result["user_message_uuids"]) ++ List.wrap(result["user_message_uuid"]),
           &is_binary/1
         ) do
      [] -> Map.get(prompt, :queued, false) and not prompt.started
      echoed -> not Enum.any?([prompt.uuid | Map.get(prompt, :steers, [])], &(&1 in echoed))
    end
  end

  defp result?(message), do: match?(%{"type" => "result"}, message)

  defp echoes_prompt?(result, prompt) do
    echoed = List.wrap(result["user_message_uuids"]) ++ List.wrap(result["user_message_uuid"])
    Enum.any?([prompt.uuid | Map.get(prompt, :steers, [])], &(&1 in echoed))
  end

  defp wake?(%{"type" => type}) when type in ~w(assistant user stream_event), do: true
  defp wake?(_message), do: false

  # A command the thread waits on (`hal_c2_background_wait`) that ends between turns
  # holds the thread working until Claude's turn answering it has a run: its notice
  # waits for that turn (`wake/2`), which ends the command when it replays it. Ended at
  # once, the command would leave the thread idle until the wake's run started.
  defp hold_notice?(state, %{"type" => "system", "subtype" => "task_notification"} = task) do
    tool = state.tasks[task["task_id"]] || task["tool_use_id"]
    match?(%{awaited: true, sub: nil}, state.work[tool])
  end

  defp hold_notice?(_state, _message), do: false

  # A Claude that answers a notice starts within seconds; one that never does must not
  # hold the thread working for good, so the first notice held releases them all
  # (`{:release_notices, task_id}`) unless they have gone first.
  defp hold_notices(task_id) do
    hold = Application.get_env(:hal_c2, :claude_notice_hold_ms, 30_000)
    Process.send_after(self(), {:release_notices, task_id}, hold)
  end

  # Held notices end their commands: the run that holds the thread working now is
  # another, or the work is ending anyway.
  defp release_notices(%{notices: []} = state), do: state

  defp release_notices(state),
    do: state.notices |> Enum.reverse() |> Enum.reduce(%{state | notices: []}, &message/2)

  # Claude started a turn by itself: the thread gets a message for it, from the agent,
  # whose run (`handle_call({:start_turn, %{wake: true}})`) queues behind any other.
  # Off this process, since starting the run calls back into it.
  defp wake(state, message) do
    runtime = self()

    HalC2.Orchestration.Wake.deliver(
      state.thread_id,
      %{
        "text" => "Background task completed.",
        # Its run replays what Claude already sent rather than sending this.
        "providerWake" => true,
        # What the timeline shows for it, in place of a message nobody sent
        # (apps/server ProviderContinuationService.ts).
        "notification" => %{
          "source" => %{"kind" => "background_task"},
          "outcome" => "updated",
          "summary" => "Background activity updated"
        }
      },
      instance: state.last_ids && Entities.instance(state.last_ids),
      on_dropped: fn -> send(runtime, :wake_refused) end
    )

    %{state | wake: %{open: not result?(message), buffer: [message]}}
  end

  # A wake's run started: the messages Claude sent meanwhile are its turn's.
  defp replay_wake(state, wake, buffer) do
    state = Enum.reduce(buffer, state, &receive_message/2)

    # Replayed to its end, or Claude is still at it; a wake a user's turn took over
    # (`take_wake/2`) leaves its run nothing to show.
    cond do
      state.turn == nil ->
        state

      state.session == nil and (wake.open or buffer != []) ->
        end_turn(state, "failed", "Claude exited")

      wake.open ->
        state

      true ->
        end_turn(state, "completed", nil)
    end
  end

  defp drop_wake(state, wake, buffer, last_ids) do
    if wake.open and state.session != nil, do: Session.control(state.session, "interrupt")

    state = %{
      state
      | turn: nil,
        last_ids: last_ids,
        wake: if(wake.open, do: %{wake | buffer: nil})
    }

    Enum.reduce(buffer, state, &message/2)
  end

  # A user's turn that starts while Claude runs a wake takes it over: what the wake said
  # so far joins the turn, and the message steers it, so the wake's `result` comes
  # before the turn's own instead of the two being one (`receive_message/2`). A new
  # process (`session` was another) ended the wake. A wake that already ended keeps
  # its messages for its own run.
  defp take_wake(%{wake: %{open: true} = wake} = state, session) do
    state =
      (wake.buffer || [])
      |> Enum.reverse()
      |> Enum.reject(&result?/1)
      |> Enum.reduce(%{state | wake: nil}, &message/2)

    if state.session == session,
      do: {%{state | wake: %{open: true, buffer: []}}, [priority: "now"]},
      else: {state, []}
  end

  defp take_wake(state, _session), do: {state, []}

  # Every message of Claude's the thread handles, between turns or in one: what it says
  # of the goal (`goal/2`), then the rest.
  defp message(message, state),
    do: claude_message(message, state |> goal(message) |> task_tools(message))

  defp claude_message(%{"type" => type, "parent_tool_use_id" => parent} = message, state)
       when type in @sidechain and is_binary(parent),
       do: sidechain(message, parent, state)

  # Claude says it started, or finished, the turn's prompt. One it finishes without
  # starting gets no turn and no result (Upstream #16897), so the turn fails.
  defp claude_message(
         %{"type" => "command_lifecycle", "command_uuid" => uuid, "state" => lifecycle},
         %{turn: %{prompt: %{uuid: uuid} = prompt}} = state
       ) do
    case lifecycle do
      "queued" ->
        put_in(state.turn.prompt, Map.put(prompt, :queued, true))

      # Claude took the prompt.
      "started" ->
        commit(state, &[confirmed(&1, state.turn.ids)])
        put_in(state.turn.prompt, %{prompt | started: true})

      # Claude ended the prompt without running it; a cancelled one is a stop, which
      # settles the turn itself.
      ended when ended in ["completed", "discarded", "refused"] and not prompt.started ->
        end_turn(
          state,
          "failed",
          "Claude acknowledged the message but never started a turn for it.",
          # The process and the work it runs in the background are untouched.
          keep_background: true
        )

      _ ->
        state
    end
  end

  defp claude_message(%{"type" => "command_lifecycle"}, state), do: state

  defp claude_message(%{"type" => "rate_limit_event", "rate_limit_info" => %{} = info}, state) do
    # `with_ids/1` recovers the latest turn's ids when this runtime has not
    # run one, so between-turns quota joins that turn's instance too.
    state = state |> with_ids() |> with_usage_instance()

    # A sandboxed review's quota is its sandbox key's (#1412), not this machine's account.
    if not sandboxed?(state),
      do: HalC2.ProviderUsageLimits.claude_event(usage_instance(state), info)

    rate_limit(info, state)
  end

  # Background work reports its progress and end after its turn is over. A task whose
  # start still waits with an ended wake for its run (`take_wake/2`) ends after that
  # start, when the run replays it, rather than before this runtime knows it
  # (Upstream #23561).
  defp claude_message(%{"type" => "system", "subtype" => "task_notification"} = task, state) do
    if buffered_task?(state.wake, task["task_id"]),
      do: put_in(state.wake.buffer, [task | state.wake.buffer]),
      else: task_notification(task, state)
  end

  # A task Claude started without telling this runtime (between turns, or before it
  # was upgraded to record them) is recorded on its first progress. Progress for a
  # task that already ended is late and does not reopen it.
  defp claude_message(%{"type" => "system", "subtype" => "task_progress"} = task, state) do
    if MapSet.member?(Map.get(state, :finished_tasks, MapSet.new()), task["task_id"]) do
      state
    else
      task_progress(task, state)
    end
  end

  defp claude_message(
         %{
           "type" => "system",
           "subtype" => "task_updated",
           "patch" => %{"is_backgrounded" => true}
         } =
           task,
         state
       ) do
    case state.work[state.tasks[task["task_id"]]] do
      nil -> state
      work -> put_in(state.work[state.tasks[task["task_id"]]], %{work | background: true})
    end
  end

  # Claude starts tasks between turns too: in the turn a task notification wakes it
  # for, or resuming a subagent (SendMessage).
  defp claude_message(%{"type" => "system", "subtype" => "task_started"} = task, state),
    do: task_started(state, task)

  # Between turns, a wake the thread would not run (`wake/2`) records only the work
  # Claude starts: its subagents and background commands, and their launches' results.
  defp claude_message(
         %{"type" => "assistant", "message" => %{"content" => content}},
         %{turn: nil} = state
       )
       when is_list(content) do
    case with_ids(state) do
      %{last_ids: nil} = state ->
        state

      state ->
        state = %{state | turn: %{ids: state.last_ids}}

        content
        |> Enum.filter(&background_launch?/1)
        |> Enum.reduce(state, &assistant_block(&1, nil, nil, &2))
        |> Map.put(:turn, nil)
    end
  end

  defp claude_message(
         %{"type" => "user", "message" => %{"content" => content}},
         %{turn: nil} = state
       )
       when is_list(content) do
    Enum.reduce(content, state, fn
      %{"type" => "tool_result", "tool_use_id" => tool_id} = result, state
      when is_map_key(state.work, tool_id) ->
        tool_result(state, tool_id, result)

      _, state ->
        state
    end)
  end

  defp claude_message(_message, %{turn: nil} = state), do: state

  defp claude_message(
         %{"type" => "system", "subtype" => "init", "session_id" => session_id},
         state
       ) do
    ids = state.turn.ids

    if session_id != state.session_id do
      commit(state, fn stream ->
        [
          Orchestration.upsert(
            stream,
            "provider-thread",
            ids.provider_thread,
            &Map.put(&1, "nativeThreadRef", Entities.provider_ref(session_id, "claudeAgent"))
          )
        ]
      end)
    end

    %{state | session_id: session_id}
  end

  defp claude_message(%{"type" => "stream_event", "event" => event}, state),
    do: stream_event(event, state)

  defp claude_message(
         %{"type" => "assistant", "message" => %{"id" => id, "content" => content}} = message,
         state
       ) do
    # The last assistant message is where a rollback to this turn resumes. Once Claude
    # writes, the turn no longer sits where it resumed the conversation (`kept_head/3`).
    state =
      if uuid = message["uuid"],
        do: update_in(state.turn, &(&1 |> Map.put(:head, uuid) |> Map.delete(:resumed_at))),
        else: state

    # The context meter reads the last request's usage, not the turn's total.
    state =
      with nil <- message["parent_tool_use_id"],
           %{} = usage <- get_in(message, ["message", "usage"]) do
        state = spent(state, id, usage)
        turn = Map.merge(state.turn, %{last_usage: usage, usage_message: id, compacted: false})
        %{state | turn: turn}
      else
        _ -> state
      end

    # A signed-out CLI answers with an auth error; the turn fails with how to sign in.
    state =
      if message["error"] == "authentication_failed" and message["parent_tool_use_id"] == nil and
           state.turn != nil,
         do: put_in(state.turn[:auth_failure], signed_out_message(state.turn)),
         else: state

    # An answer Claude could not give for a usage limit ends the turn as one.
    state =
      if message["error"] == "rate_limit" and message["parent_tool_use_id"] == nil and
           state.turn != nil,
         do: state |> put_in([:turn, :rate_limited], true) |> embedded_limit(message),
         else: state

    # An answer after a retry means the request went through.
    state = recover_retry(state)

    {blocks, placed} = placed(state.placed, id, with_presentation(content, message))

    Enum.reduce(blocks, flush(%{state | placed: placed}), fn {block, index}, state ->
      assistant_block(block, id, index, state)
    end)
    |> Map.put(:blocks, %{})
  end

  defp claude_message(%{"type" => "user", "message" => %{"content" => content}} = message, state)
       when is_list(content) do
    state =
      Enum.reduce(content, state, fn
        %{"type" => "tool_result", "tool_use_id" => tool_id} = result, state ->
          tool_result(state, tool_id, result)

        _, state ->
          state
      end)

    web_results(state, content, message["tool_use_result"])
  end

  # The part of a steered turn that the new message cut short; the turn goes on.
  # Claude compacted the conversation: the timeline says so, and the context meter
  # takes the size Claude reports for what is left.
  defp claude_message(
         %{"type" => "system", "subtype" => "compact_boundary"} = message,
         %{turn: turn} = state
       )
       when turn != nil do
    meta = message["compact_metadata"] || %{}
    native = message["uuid"] || "compaction:#{turn.ids.provider_turn}"
    count = fn key -> if is_number(meta[key]) and meta[key] > 0, do: round(meta[key]) end
    before = count.("pre_tokens")
    left = count.("post_tokens")

    fields =
      %{"driver" => "claudeAgent", "title" => "Context compacted"}
      |> then(&if(before, do: Map.put(&1, "beforeTokenCount", before), else: &1))
      |> then(&if(left, do: Map.put(&1, "afterTokenCount", left), else: &1))

    state =
      state
      |> flush()
      |> ensure_item(native, :compaction, fields)
      |> finish_item(native, "completed", & &1)

    if left do
      usage = %{"usedTokens" => left, "updatedAt" => Entities.now()}

      commit(state, fn stream ->
        [
          Orchestration.upsert(
            stream,
            "provider-turn",
            turn.ids.provider_turn,
            &Map.put(&1, "tokenUsage", usage)
          )
        ]
      end)
    end

    # The usage above stands until a post-compaction request reports its own.
    state = update_in(state.turn, &Map.merge(&1, %{last_usage: nil, usage_message: nil}))

    # The boundary is where this turn leaves the conversation: a turn Claude
    # only compacted in has no assistant message to resume at, so without this
    # a rollback to it has no recorded point and is refused.
    state =
      if is_binary(message["uuid"]),
        do:
          update_in(
            state.turn,
            &(&1 |> Map.put(:head, message["uuid"]) |> Map.delete(:resumed_at))
          ),
        else: state

    put_in(state.turn[:compacted], true)
  end

  defp claude_message(
         %{"type" => "result", "terminal_reason" => reason},
         %{steered: true} = state
       )
       when reason in ["aborted_streaming", "aborted_tools"] and not state.interrupted,
       do: %{state | steered: false}

  # Claude changed model rather than answer on the refused one: its own notice is
  # shown and the turn carries on.
  defp claude_message(
         %{"type" => "system", "subtype" => "model_refusal_fallback"} = message,
         %{turn: turn} = state
       )
       when turn != nil,
       do: notice(state, message, "model-fallback", "Claude switched models after a refusal.")

  # Claude's notices above info level, such as a hook's reason for blocking the prompt
  # (Upstream #21231). Info-level ones are for the transcript only.
  defp claude_message(
         %{"type" => "system", "subtype" => "informational", "level" => level, "content" => text} =
           message,
         %{turn: turn} = state
       )
       when turn != nil and level != "info" and is_binary(text) and text != "",
       do: notice(state, message, "notice", text)

  # Claude is retrying a failed API request: one work-log entry for the turn, which
  # every later attempt of that request updates.
  defp claude_message(
         %{"type" => "system", "subtype" => "api_retry"} = message,
         %{turn: turn} = state
       )
       when turn != nil,
       do: retry_item(state, message)

  defp claude_message(%{"type" => "result"} = result, state) do
    state = %{state | steered: false}
    reason = result["terminal_reason"]
    aborted = reason in ["aborted_streaming", "aborted_tools"]

    failed? =
      result["is_error"] == true or result["subtype"] != "success" or
        Map.has_key?(@terminal_errors, reason) or result["api_error_status"] in [429, 529]

    limit = if failed?, do: failure(result, state.turn)

    status =
      cond do
        # A limit that lands as the user stops the run still leaves the thread limited,
        # for the user to resume; `TurnWriter` keeps it from resuming on its own. A stop
        # that cut the run short is only a stop, whatever limit came before it.
        state.interrupted and limit["class"] == "usage_limit" -> "failed"
        state.interrupted or aborted -> "interrupted"
        failed? -> "failed"
        true -> "completed"
      end

    state = record_usage(state, result)

    # A turn Claude answered only in its result shows that as the answer.
    state = if status == "completed", do: result_answer(state, result), else: state

    failure =
      cond do
        status != "failed" ->
          nil

        # Claude labels a 403 an authentication failure too, but its reason is not a sign-in problem.
        state.turn[:auth_failure] && result["api_error_status"] in [nil, 401] ->
          auth_failure(state.turn[:auth_failure], result)

        true ->
          limit
      end

    state |> goal_met(status, reason) |> end_turn(status, failure)
  end

  defp claude_message(_message, state), do: state

  # --- the goal (`/goal`) ---------------------------------------------------------------
  # In SDK mode Claude reports its goal only in the transcript: a synthetic answer to
  # `/goal` names it ("Goal set: …", "Goal active: … (N turns)", "Goal cleared: …"), and
  # each check that found it unmet comes back as Stop hook feedback. The thread shows it
  # as the provider thread's `goal`: `%{"objective", "status", "checks", "lastCheck"}`
  # (Upstream #15592).

  @goal_active ~r/^Goal active: (.+?) \((?:not yet evaluated|(\d+) turns?)\)/s

  defp goal(state, %{"parent_tool_use_id" => parent}) when is_binary(parent), do: state

  defp goal(state, %{"type" => "assistant", "message" => %{"model" => "<synthetic>"} = said}) do
    case said["content"] |> result_text() |> String.trim() |> goal_said(state.goal) do
      :unchanged -> state
      goal -> put_goal(state, goal)
    end
  end

  # Claude worked on the goal in this turn, so the turn's end is its check.
  defp goal(%{goal: %{"status" => "active"}} = state, %{"type" => "assistant"}),
    do: %{state | goal_checked: true}

  defp goal(
         %{goal: %{"objective" => objective} = goal} = state,
         %{"type" => "user", "isSynthetic" => true, "message" => %{"content" => content}}
       ) do
    case result_text(content) do
      "Stop hook feedback:\n[" <> rest ->
        case String.split(rest, "]: ", parts: 2) do
          [^objective, reason] ->
            put_goal(
              state,
              %{
                goal
                | "status" => "active",
                  "checks" => (goal["checks"] || 0) + 1
              }
              |> Map.put("lastCheck", String.trim(reason))
            )

          _ ->
            state
        end

      _ ->
        state
    end
  end

  defp goal(state, _message), do: state

  # Claude 5 keeps its todos with task tools (TaskCreate, TaskUpdate and TaskList, in
  # place of TodoWrite), which edit one list per session across turns, its subagents'
  # calls included (Upstream #14964, #20985). The thread's task list is that list, one
  # per turn, updated in place. A call that failed or never ran changed nothing.
  defp task_tools(state, %{"type" => "assistant", "message" => %{"content" => content}})
       when is_list(content) do
    Enum.reduce(content, state, fn
      %{"type" => "tool_use", "id" => id, "name" => name} = block, state
      when name in @task_tools ->
        put_in(state.task_calls[id], {name, block["input"] || %{}})

      _block, state ->
        state
    end)
  end

  defp task_tools(state, %{"type" => "user", "message" => %{"content" => content}} = message)
       when is_list(content) do
    Enum.reduce(content, state, fn
      %{"type" => "tool_result", "tool_use_id" => id} = result, state
      when is_map_key(state.task_calls, id) ->
        {{name, input}, calls} = Map.pop(state.task_calls, id)
        state = %{state | task_calls: calls}

        if result_status(result) == "completed",
          do: task_changed(state, name, input, task_output(message, result)),
          else: state

      _block, state ->
        state
    end)
  end

  defp task_tools(state, _message), do: state

  # The call's structured result, or its text when there is none (a subagent's).
  defp task_output(%{"tool_use_result" => output}, _result) when is_map(output), do: output
  defp task_output(_message, result), do: result_text(result["content"])

  defp task_changed(%{turn: nil} = state, _name, _input, _output), do: state

  defp task_changed(state, name, input, output) do
    list_id = task_list_id(state)

    {known, tasks} =
      case state.task_list do
        {^list_id, tasks} -> {true, tasks}
        _ -> {false, []}
      end

    # A structured TaskList is the whole list. Any other change after a restart (or
    # by a subagent, whose TaskList is only text) starts from the list Claude keeps,
    # read once (Upstream #18398).
    stored =
      if not known and not (name == "TaskList" and is_list(task_field(output, "tasks"))),
        do: stored_tasks(state, list_id)

    case apply_task_tool(stored || tasks, name, input, output) || stored do
      nil ->
        %{state | task_list: {list_id, tasks}}

      tasks ->
        state = %{state | task_list: {list_id, tasks}}

        steps =
          for {id, step} <- tasks, do: Map.put(step, "id", "task-#{id}")

        write_todo(state, "tasks:#{state.turn.ids.run}", steps)
    end
  end

  # Claude names the list after the session, or CLAUDE_CODE_TASK_LIST_ID when set. A
  # sandboxed review's Claude has none of this machine's variables (#1412).
  defp task_list_id(%{turn: %{sandbox: true}} = state), do: state.session_id

  defp task_list_id(state) do
    instance = Entities.instance(state.turn.ids)

    custom =
      [HalC2.Settings.instance_env(instance)["CLAUDE_CODE_TASK_LIST_ID"]] ++
        [System.get_env("CLAUDE_CODE_TASK_LIST_ID")]

    Enum.find_value(custom, fn
      value when is_binary(value) -> if String.trim(value) != "", do: String.trim(value)
      _ -> nil
    end) || state.session_id
  end

  # The tasks Claude saved under `<config dir>/tasks/<list id>/<n>.json`, in order; nil
  # when they cannot be read. The format is Claude's own and undocumented, so this is
  # best effort, and Claude's internal tasks are not the user's.
  defp stored_tasks(_state, nil), do: nil
  # A sandboxed review's are in its sandbox.
  defp stored_tasks(%{turn: %{sandbox: true}}, _list_id), do: nil

  # Reads only `<n>.json` files in Claude's own tasks folder; the list id is reduced to
  # `[a-zA-Z0-9_-]` first, so it cannot leave that folder.
  # sobelow_skip ["Traversal.FileModule"]
  defp stored_tasks(state, list_id) do
    instance = Entities.instance(state.turn.ids)

    dir =
      Path.join([Provider.config_dir(instance, state.turn[:cwd]), "tasks", sanitized(list_id)])

    with {:ok, names} <- File.ls(dir) do
      names
      |> Enum.filter(&Regex.match?(~r/^\d+\.json$/, &1))
      |> Enum.sort_by(&String.to_integer(Path.rootname(&1)))
      |> Enum.flat_map(fn name ->
        with {:ok, text} <- File.read(Path.join(dir, name)),
             {:ok, %{"id" => id, "subject" => subject} = task} <- JSON.decode(text),
             false <- get_in(task, ["metadata", "_internal"]) not in [nil, false],
             id when id != "" <- task_text(id),
             text when text != "" <- task_text(subject),
             status when status != nil <- task_status(task["status"]) do
          [{id, %{"text" => text, "status" => status}}]
        else
          _ -> []
        end
      end)
    else
      _ -> nil
    end
  end

  defp sanitized(list_id), do: String.replace(list_id, ~r/[^a-zA-Z0-9_-]/, "-")

  # The list after a finished task call, or nil when it leaves the list as it was:
  # TaskList replaces it, TaskCreate adds the task under the id Claude gave it, and
  # TaskUpdate changes one it knows (a `deleted` status removes it).
  defp apply_task_tool(tasks, "TaskList", _input, output) do
    case task_field(output, "tasks") do
      listed when is_list(listed) ->
        listed =
          for task <- listed,
              id = task_text(task_field(task, "id")),
              text = task_text(task_field(task, "subject")),
              status = task_status(task_field(task, "status")),
              id != "" and text != "" and status != nil,
              do: {id, %{"text" => text, "status" => status}}

        if listed == [] and tasks == [], do: nil, else: listed

      _ ->
        nil
    end
  end

  defp apply_task_tool(tasks, "TaskCreate", input, output) do
    # A subagent's result is only the text "Task #3 created successfully: <subject>".
    {text_id, text_subject} =
      case is_binary(output) && Regex.run(~r/^Task #(\S+) created successfully: (.+)$/s, output) do
        [_, id, subject] -> {id, subject}
        _ -> {nil, nil}
      end

    created = task_field(output, "task")
    id = first_text([task_field(created, "id"), text_id])
    text = first_text([task_field(created, "subject"), text_subject, input["subject"]])

    if id && text,
      do: List.keystore(tasks, id, 0, {id, %{"text" => text, "status" => "pending"}})
  end

  defp apply_task_tool(tasks, "TaskUpdate", input, output) do
    failed? =
      task_field(output, "success") == false or
        (is_binary(output) and not String.starts_with?(output, "Updated task #"))

    id = first_text([input["taskId"], task_field(output, "taskId")])

    with false <- failed?,
         {^id, step} <- id && List.keyfind(tasks, id, 0) do
      if input["status"] == "deleted" do
        List.keydelete(tasks, id, 0)
      else
        next = %{
          "text" => first_text([input["subject"]]) || step["text"],
          "status" => task_status(input["status"]) || step["status"]
        }

        if next != step, do: List.keyreplace(tasks, id, 0, {id, next})
      end
    else
      _ -> nil
    end
  end

  defp task_field(value, key) when is_map(value), do: value[key]
  defp task_field(_value, _key), do: nil

  defp task_text(value) when is_binary(value), do: String.trim(value)
  defp task_text(value) when is_integer(value), do: Integer.to_string(value)
  defp task_text(_value), do: ""

  defp first_text(values),
    do: Enum.find_value(values, fn value -> if task_text(value) != "", do: task_text(value) end)

  defp task_status("pending"), do: "pending"
  defp task_status("in_progress"), do: "running"
  defp task_status("completed"), do: "completed"
  defp task_status(_status), do: nil

  defp goal_said("Goal set: " <> objective, _goal) do
    case String.trim(objective) do
      "" -> :unchanged
      objective -> %{"objective" => objective, "status" => "active", "checks" => 0}
    end
  end

  defp goal_said("Goal cleared: " <> _, _goal), do: nil
  defp goal_said("No goal set" <> _, _goal), do: nil

  defp goal_said(text, goal) do
    case Regex.run(@goal_active, text) do
      [_, objective | turns] ->
        checks = with [n] when n != "" <- turns, do: String.to_integer(n), else: (_ -> 0)
        kept = if goal && goal["objective"] == objective, do: goal, else: %{}
        Map.merge(kept, %{"objective" => objective, "status" => "active", "checks" => checks})

      nil ->
        :unchanged
    end
  end

  # Claude ends a turn by itself while a goal is set only once the goal's check passed,
  # so a turn that ended normally after Claude worked on the goal met it. Claude defers
  # the check while background work runs: with any left, the goal is still active
  # (Upstream #16598). A hook that stopped the turn gives another reason.
  defp goal_met(
         %{goal: %{"status" => "active"} = goal, goal_checked: true} = state,
         status,
         reason
       )
       when status == "completed" and reason in [nil, "completed"] do
    state = %{state | goal_checked: false}

    if Enum.any?(Map.values(state.work), & &1.background),
      do: state,
      else: put_goal(state, goal |> Map.put("status", "complete") |> Map.delete("lastCheck"))
  end

  defp goal_met(state, _status, _reason), do: %{state | goal_checked: false}

  defp provider_goal(state, ids) do
    HalC2.Streams.read(
      state.thread_id,
      &StreamState.get(&1, "provider-thread")[ids.provider_thread]
    )
    |> case do
      %{"goal" => %{} = goal} -> goal
      _ -> nil
    end
  end

  defp put_goal(%{goal: goal} = state, goal), do: state

  defp put_goal(state, goal) do
    if ids = (state.turn && state.turn.ids) || state.last_ids do
      commit(state, fn stream ->
        [
          Orchestration.upsert(
            stream,
            "provider-thread",
            ids.provider_thread,
            &Map.put(&1, "goal", goal)
          )
        ]
      end)
    end

    %{state | goal: goal}
  end

  defp task_progress(task, state) do
    state =
      if is_map_key(state.tasks, task["task_id"]), do: state, else: task_started(state, task)

    text = non_empty(task["summary"], non_empty(task["description"], ""))

    case state.tasks[task["task_id"]] do
      tool when is_map_key(state.work, tool) and text != "" ->
        case state.work[tool] do
          %{sub: %{} = sub} = work ->
            sub = NativeSubagent.progress(sub, text, thinking: true)
            put_in(state.work[tool], %{work | sub: sub})

          _ ->
            state
        end

      _ ->
        state
    end
  end

  # A web search's pages, from the structured `tool_use_result` Claude sends with
  # the result (falling back to the `Links:` list in its text), go on the search
  # step with their titles and addresses.
  defp web_results(state, content, extra) do
    block =
      Enum.find(content, fn
        %{"type" => "tool_result", "tool_use_id" => id} ->
          match?(%{kind: :web}, state.items[id])

        _ ->
          false
      end)

    results = web_result_pages(extra) || web_result_pages(block && block["content"])

    case {block, results} do
      {%{"tool_use_id" => tool_id}, [_ | _]} ->
        %{id: item_id} = state.items[tool_id]

        commit(state, fn stream ->
          [
            Orchestration.upsert(
              stream,
              "turn-item",
              item_id,
              &Map.put(&1, "results", results)
            )
          ]
        end)

        state

      _ ->
        state
    end
  end

  defp web_result_pages(%{"results" => results}) when is_list(results) do
    pages =
      Enum.flat_map(results, fn
        %{"content" => content} when is_list(content) -> content
        other -> [other]
      end)
      |> web_pages()

    if pages == [], do: nil, else: pages
  end

  defp web_result_pages(content) when is_list(content) do
    flat =
      Enum.flat_map(content, fn
        %{"content" => inner} when is_list(inner) -> inner
        other -> [other]
      end)

    nonempty(web_pages(flat)) ||
      Enum.find_value(flat, fn
        %{"text" => text} -> web_result_pages(text)
        text when is_binary(text) -> web_result_pages(text)
        _ -> nil
      end)
  end

  defp web_result_pages(text) when is_binary(text) do
    case Regex.run(~r/Links: (\[.+\])/s, text) do
      [_, json] ->
        case JSON.decode(json) do
          {:ok, pages} when is_list(pages) -> web_pages(pages) |> nonempty()
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp web_result_pages(_other), do: nil

  defp web_pages(list) do
    for %{"title" => title, "url" => url} <- list,
        is_binary(title) and is_binary(url),
        do: %{"title" => title, "url" => url}
  end

  defp nonempty([]), do: nil
  defp nonempty(list), do: list

  # The retry entry closes as recovered once Claude answers again.
  defp recover_retry(%{turn: turn} = state) when turn != nil do
    native = "terminal-failure:#{turn.ids.provider_turn}"

    if Map.has_key?(state.items, native) do
      state
      |> finish_item(native, "completed", &Map.put(&1, "title", "Provider recovered"))
      |> Map.update!(:items, &Map.delete(&1, native))
    else
      state
    end
  end

  defp recover_retry(state), do: state

  # The context meter: what the last request used is its input, cached and output
  # tokens, out of the model's context window (`Provider.launch/3`). The result's
  # own usage totals every request of the turn, so it only stands in when no
  # assistant message reported per-request usage — and never over the usage a
  # compaction in this turn already wrote.
  defp record_usage(state, result) do
    usage =
      state.turn[:last_usage] ||
        if state.turn[:compacted], do: nil, else: result["usage"]

    if is_map(usage), do: write_usage(state, usage, reported_window(state, result)), else: state
  end

  # A model neither Claude Code listed nor the manifest knows has no window of its
  # own in `launch`; the result's `modelUsage` reports the one Claude compacts
  # against (Upstream #30051).
  defp reported_window(%{turn: %{launch: launch} = turn}, %{"modelUsage" => %{} = models}) do
    entry = models[launch.model] || with([only] <- Map.values(models), do: only, else: (_ -> nil))

    with %{"contextWindow" => window} when is_integer(window) and window > 0 <- entry,
         false <- Provider.known?(Map.get(turn, :model), Entities.instance(turn.ids)) do
      window
    else
      _ -> nil
    end
  end

  defp reported_window(_state, _result), do: nil

  defp write_usage(state, usage, window) do
    count = fn key -> trunc(usage[key] || 0) end

    input =
      count.("input_tokens") + count.("cache_creation_input_tokens") +
        count.("cache_read_input_tokens")

    max = window || state.turn.launch.context_window

    token_usage =
      %{
        "usedTokens" => input + count.("output_tokens"),
        "maxTokens" => max,
        "autoCompactThreshold" => compacts_at(state.turn.launch.settings, max),
        "inputTokens" => input,
        "cachedInputTokens" => count.("cache_read_input_tokens"),
        "outputTokens" => count.("output_tokens"),
        "reasoningOutputTokens" => 0,
        "updatedAt" => Entities.now()
      }
      |> Map.reject(fn {_, value} -> value == nil end)

    commit(state, fn stream ->
      [
        Orchestration.upsert(
          stream,
          "provider-turn",
          state.turn.ids.provider_turn,
          &Map.put(&1, "tokenUsage", token_usage)
        )
      ]
    end)

    state
  end

  # The turn's notices are kept: Claude repeats one that ended the prompt as its result.
  defp notice(%{turn: turn} = state, message, kind, default) do
    text = non_empty(message["content"], default)
    native = message["uuid"] || "#{kind}:#{turn.ids.provider_turn}"

    %{state | turn: Map.update(turn, :notices, [text], &[text | &1])}
    |> flush()
    |> ensure_item(native, :notice, %{"title" => text, "message" => text})
    |> finish_item(native, "completed", & &1)
  end

  defp result_answer(state, result) do
    text = non_empty(result["result"], "")
    answered? = Enum.any?(state.items, fn {_, item} -> item.kind == :assistant end)

    if text == "" or answered? or text in Map.get(state.turn, :notices, []) do
      state
    else
      id = result["uuid"] || "result:#{state.turn.ids.provider_turn}"

      state
      |> flush()
      |> ensure_item(id, :assistant)
      |> finish_item(id, "completed", &Map.merge(&1, %{"text" => text, "streaming" => false}))
    end
  end

  defp auth_failure(message, result) do
    %{
      "class" => "provider_error",
      "message" => message,
      "code" =>
        if(result["api_error_status"],
          do: "api_error_#{result["api_error_status"]}",
          else: "authentication_failed"
        ),
      "retryable" => nil
    }
  end

  # The turn's retry entry, as Codex's runtime keeps its own: created on the first
  # attempt and updated in place, so the work log shows one entry per request.
  defp retry_item(state, retry) do
    native = "terminal-failure:#{state.turn.ids.provider_turn}"
    status = retry["error_status"]
    error = retry["error"]

    failure = %{
      "class" =>
        cond do
          status == 429 -> "usage_limit"
          status == nil -> "transport_error"
          true -> "provider_error"
        end,
      "message" =>
        if(is_binary(error) and error != "",
          do: "Claude API #{String.replace(error, "_", " ")}.",
          else: "Claude is retrying a failed API request."
        ),
      "code" => if(status, do: "api_error_#{status}", else: error),
      "retryable" => true
    }

    attempt = %{
      "attempt" => max(trunc(retry["attempt"] || 1), 1),
      "maxAttempts" => max(trunc(retry["max_retries"] || 1), 1),
      "retryDelayMs" => max(trunc(retry["retry_delay_ms"] || 0), 0)
    }

    state =
      state
      |> flush()
      |> ensure_item(native, :error, %{"title" => "Provider retry", "failure" => failure})

    %{id: item_id} = state.items[native]
    at = Entities.now()

    commit(state, fn stream ->
      [
        Orchestration.upsert(stream, "turn-item", item_id, fn item ->
          Map.merge(item, %{"failure" => failure, "retry" => attempt, "updatedAt" => at})
        end)
      ]
    end)

    state
  end

  # A rejected window pauses Claude inside the turn; the turn's end reports it as a
  # usage limit resetting at the latest window's reset.
  defp rate_limit(_info, %{turn: nil} = state), do: state

  defp rate_limit(info, state) do
    type = info["rateLimitType"] || "unknown"

    overage? =
      info["overageStatus"] in ["allowed", "allowed_warning"] or info["isUsingOverage"] == true or
        info["overageInUse"] == true

    limits = Map.get(state.turn, :limits, %{})

    blocked? = info["status"] == "rejected" and not overage?

    limits =
      cond do
        blocked? ->
          Map.put(limits, type, reset_at(info["resetsAt"]))

        info["status"] in ["allowed", "allowed_warning"] or overage? ->
          Map.delete(limits, type)

        true ->
          limits
      end

    state = put_in(state.turn[:limits], limits)
    if blocked?, do: announce_limit(state, type, info["resetsAt"]), else: state
  end

  # Claude does not repeat an unchanged `rate_limit_event`, so a quick retry learns its
  # window only from the refused answer's `api_error_params` (Upstream #18616). A window
  # an event already named keeps the event's reset.
  defp embedded_limit(state, message) do
    with %{"api_error_params" => %{"rate_limit_info" => %{"status" => "rejected"} = info}} <-
           message,
         false <- Map.has_key?(Map.get(state.turn, :limits, %{}), info["rateLimitType"]) do
      rate_limit(info, state)
    else
      _ -> state
    end
  end

  # A window that refused the turn pauses it: the thread says so once per window
  # and reset in the turn, with the wait when the reset can be trusted (a time
  # still ahead, within thirty days). Warnings never announce a pause.
  defp announce_limit(state, type, resets_at) do
    announced = Map.get(state.turn, :announced_limits, MapSet.new())
    key = "#{type}:#{resets_at || "unknown"}"

    if MapSet.member?(announced, key) do
      state
    else
      label = @limit_labels[type]
      wait = limit_wait(resets_at)

      text =
        cond do
          label && wait ->
            "Claude usage limit reached. This turn is paused until the #{label} " <>
              "limit resets in #{wait}."

          label ->
            "Claude usage limit reached. This turn is paused until the #{label} limit resets."

          wait ->
            "Claude usage limit reached. This turn is paused until the limit resets in #{wait}."

          true ->
            "Claude usage limit reached. This turn is paused until the limit resets."
        end

      native = "usage-limit:#{state.turn.ids.provider_turn}:#{key}"

      state
      |> flush()
      |> ensure_item(native, :notice, %{"title" => text, "message" => text})
      |> finish_item(native, "completed", & &1)
      |> put_in([:turn, :announced_limits], MapSet.put(announced, key))
    end
  end

  # The wait until an epoch-seconds reset, rounded up to minutes and shown as
  # `40m`, `3h` or `2h 5m`; nil for a reset that is missing, past, or over
  # thirty days away.
  defp limit_wait(seconds) when is_number(seconds) and seconds > 0 do
    left = trunc(seconds) - System.system_time(:second)

    if left > 0 and left <= 30 * 24 * 60 * 60 do
      minutes = ceil(left / 60)
      hours = div(minutes, 60)

      cond do
        hours == 0 -> "#{minutes}m"
        rem(minutes, 60) == 0 -> "#{hours}h"
        true -> "#{hours}h #{rem(minutes, 60)}m"
      end
    end
  end

  defp limit_wait(_seconds), do: nil

  defp reset_at(seconds) when is_number(seconds) and seconds > 0,
    do: HalC2.Projection.JS.iso(trunc(seconds * 1000))

  defp reset_at(_), do: nil

  # The instance quota is published under, resolved once when a turn starts
  # (or its ids are recovered): a turn's own instance when settings here
  # know it, or the driver when they do not. Resolving at capture pins a
  # turn's attribution: settings changing mid-turn do not move the rest of
  # it to another account.
  defp resolved_instance(instance),
    do:
      if(HalC2.Settings.known_instance?(instance, "claudeAgent"),
        do: instance,
        else: "claudeAgent"
      )

  defp usage_instance(state), do: Map.get(state, :usage_instance) || "claudeAgent"

  # Whether this runtime's Claude runs in a review sandbox (#1412), in a turn or after.
  defp sandboxed?(state),
    do: match?(%{sandbox: true}, state.turn) or match?(%{sandbox: true}, Map.get(state, :launch))

  # A state from before quota attribution was pinned at capture (upgraded
  # mid-turn) resolves it here, once, from the turn it is on: the running
  # turn's instance, else the latest turn's (work Claude starts between
  # turns joins it), else the driver.
  defp with_usage_instance(state) do
    case Map.get(state, :usage_instance) do
      instance when is_binary(instance) ->
        state

      _ ->
        ids = if state.turn, do: Map.get(state.turn, :ids), else: state.last_ids
        instance = if is_map(ids), do: Entities.instance(ids)
        Map.put(state, :usage_instance, resolved_instance(instance))
    end
  end

  # A failed turn's structured failure. A turn stopped by a usage limit reports the
  # latest window's reset, or none when any window's reset is unknown.
  defp failure(result, turn) do
    limits = Map.get(turn, :limits, %{})
    reason = result["terminal_reason"]
    api_status = result["api_error_status"]
    shown = user_facing_error(result)
    structured = @terminal_errors[reason]

    gateway_reset = gateway_reset(result, api_status)
    limits = if gateway_reset, do: %{gateway: gateway_reset}, else: limits

    # Claude ends a turn on a full context window as a `blocking_limit` too: that is a
    # usage limit only with rate-limit evidence (Upstream #19848).
    evidence? = api_status == 429 or limits != %{} or turn[:rate_limited] == true

    limited? =
      gateway_reset != nil or (reason == "blocking_limit" and evidence?) or
        (result["subtype"] == "success" and api_status == 429) or
        ((limits != %{} or turn[:rate_limited] == true) and
           (result["subtype"] != "success" or api_status in [nil, 429]) and
           reason in [nil, "api_error", "blocking_limit"])

    if limited? do
      resets = Map.values(limits)

      %{
        "class" => "usage_limit",
        "message" =>
          shown || if(reason != "blocking_limit", do: structured) ||
            api_status_message(api_status) ||
            "Claude usage limit reached. Send the message again once the limit resets.",
        "code" =>
          if(api_status, do: "api_error_#{api_status}", else: reason || result["subtype"]),
        "retryable" => if(api_status == 429, do: true),
        "resetAt" => if(resets != [] and nil not in resets, do: Enum.max(resets))
      }
    else
      %{
        "class" => "provider_error",
        "message" =>
          shown || api_error_text(result) || structured || api_status_message(api_status) ||
            result["result"] || joined_errors(result) || result["subtype"] ||
            "Claude reported an error.",
        "code" =>
          cond do
            api_status -> "api_error_#{api_status}"
            result["subtype"] == "success" -> reason || "sdk_result_error"
            true -> result["subtype"]
          end,
        "retryable" => if(api_status in [429, 529], do: true)
      }
    end
  end

  # A gateway (9router and the like) wraps Claude's 429 as a 503 `rate_limit_error` that
  # names its cooldown, "(reset after 1h 2m 3s)". The reset is that long from now; a cooldown of zero or one that cannot be
  # read is no usage limit.
  defp gateway_reset(result, 503) do
    text =
      Enum.join(
        [result["result"] | List.wrap(result["errors"])] |> Enum.filter(&is_binary/1),
        " "
      )

    with true <- text =~ "rate_limit_error",
         [_, cooldown] <- Regex.run(~r/\(reset after ((?:\d+[hms] ?)+)\)/, text),
         seconds when seconds > 0 <- cooldown_seconds(cooldown) do
      reset_at(System.system_time(:second) + seconds)
    else
      _ -> nil
    end
  end

  defp gateway_reset(_result, _status), do: nil

  defp cooldown_seconds(cooldown) do
    ~r/(\d+)([hms])/
    |> Regex.scan(cooldown)
    |> Enum.sum_by(fn [_, n, unit] ->
      String.to_integer(n) * %{"h" => 3600, "m" => 60, "s" => 1}[unit]
    end)
  end

  defp api_status_message(529), do: "Claude API is overloaded (529). Try again shortly."
  defp api_status_message(429), do: "Claude API rate limit reached. Try again later."
  defp api_status_message(_status), do: nil

  # The first of a result's errors meant for the user; Claude's own diagnostic
  # records (`[ede_diagnostic]…`) are not shown.
  defp user_facing_error(result) do
    Enum.find(List.wrap(result["errors"]), fn
      error when is_binary(error) -> not String.starts_with?(error, "[ede_diagnostic]")
      _ -> false
    end)
  end

  # Claude's own "API Error: ..." result says more than a generic line about repeated API
  # errors (Upstream #19136); a long one is cut to 500 characters.
  defp api_error_text(%{"result" => "API Error:" <> _ = text}), do: String.slice(text, 0, 500)
  defp api_error_text(_result), do: nil

  defp joined_errors(result) do
    case List.wrap(result["errors"]) |> Enum.filter(&is_binary/1) do
      [] -> nil
      errors -> Enum.join(errors, "\n")
    end
  end

  # What a sandboxed review's message cost counts against its budget (#1412), once per
  # message however often its counts are reported.
  defp spent(%{sandbox_spent: %Budget{} = budget} = state, message_id, usage)
       when is_binary(message_id),
       do: report(state, Budget.message(budget, message_id, usage))

  defp spent(state, _message_id, _usage), do: state

  # What else a sandboxed review's CLI spends (its subagents, its own count in each
  # result), whatever the thread then does with the message.
  defp budget(%{sandbox_spent: %Budget{} = budget} = state, message),
    do: report(state, Budget.observe(budget, message))

  defp budget(state, _message), do: state

  defp report(state, {budget, counts}) do
    for {key, tokens} <- counts, do: HalC2.OpenShell.Review.spent(state.thread_id, key, tokens)
    %{state | sandbox_spent: budget}
  end

  # Partial messages: text and thinking stream into their items as they arrive.
  defp stream_event(%{"type" => "message_start", "message" => %{"id" => id}}, state),
    do: %{state | message_id: id, blocks: %{}}

  defp stream_event(
         %{
           "type" => "content_block_start",
           "index" => index,
           "content_block" => %{"type" => type}
         },
         state
       )
       when type in ["text", "thinking"] do
    key = block_key(state.message_id, index)
    kind = if type == "text", do: :assistant, else: :reasoning
    state |> ensure_item(key, kind) |> put_in([:blocks, index], key)
  end

  defp stream_event(%{"type" => "content_block_delta", "index" => index, "delta" => delta}, state) do
    text = delta["text"] || delta["thinking"]

    case {state.blocks[index], text} do
      {nil, _} -> state
      {_, nil} -> state
      {key, text} -> buffer(state, key, "text", text)
    end
  end

  # A gateway may report a message's counts only as it ends (Upstream #19416). They
  # land on that message's usage, never on usage a compaction has since replaced.
  defp stream_event(%{"type" => "message_delta", "usage" => %{} = usage}, %{turn: turn} = state)
       when is_map(turn) do
    if turn[:last_usage] != nil and turn[:usage_message] == state.message_id do
      counts =
        for {key, value} <- usage, is_number(value) and value > 0, into: %{}, do: {key, value}

      turn = Map.update!(turn, :last_usage, &Map.merge(&1, counts))
      %{spent(state, state.message_id, turn.last_usage) | turn: turn}
    else
      state
    end
  end

  defp stream_event(_event, state), do: state

  # A complete assistant message: finishes streamed blocks with their final text,
  # and creates items for blocks that did not stream (tool calls, unstreamed text).
  defp assistant_block(%{"type" => "text", "text" => text}, id, index, state) do
    key = block_key(id, index)

    state
    |> ensure_item(key, :assistant)
    |> finish_item(key, "completed", &Map.merge(&1, %{"text" => text, "streaming" => false}))
  end

  defp assistant_block(%{"type" => "thinking", "thinking" => text}, id, index, state) do
    key = block_key(id, index)

    state
    |> ensure_item(key, :reasoning)
    |> finish_item(key, "completed", &Map.merge(&1, %{"text" => text, "streaming" => false}))
  end

  # Claude's todo list: one per run, updated in place.
  defp assistant_block(%{"type" => "tool_use", "name" => "TodoWrite"} = block, _id, _index, state) do
    steps =
      for {todo, index} <- Enum.with_index(get_in(block, ["input", "todos"]) || [], 1),
          text = non_empty(todo["content"], ""),
          text != "" do
        status =
          case todo["status"] do
            "completed" -> "completed"
            "in_progress" -> "running"
            _ -> "pending"
          end

        %{"id" => "step-#{index}", "text" => text, "status" => status}
      end

    write_todo(state, "todos:#{state.turn.ids.run}", steps)
  end

  # Shown as their question card and plan instead.
  defp assistant_block(%{"type" => "tool_use", "name" => name}, _id, _index, state)
       when name in ["AskUserQuestion", "ExitPlanMode"],
       do: state

  # A subagent; its task's messages end it (`task_started`, `task_notification`).
  defp assistant_block(
         %{"type" => "tool_use", "id" => tool_id, "name" => name} = block,
         _,
         _,
         state
       )
       when name in @agent_tools and not is_map_key(state.work, tool_id) do
    input = block["input"] || %{}
    state = flush(state)

    sub =
      NativeSubagent.start(work_ids(state), tool_id, %{
        "prompt" => input["prompt"],
        "title" => input["description"],
        "model" => input["model"]
      })

    put_in(state.work[tool_id], %{
      sub: sub,
      item: nil,
      background: input["run_in_background"] == true
    })
  end

  defp assistant_block(%{"type" => "tool_use", "name" => name}, _id, _index, state)
       when name in @agent_tools,
       do: state

  # SendMessage to a subagent Claude started earlier resumes it: the message is the
  # subagent's, shown in its own thread and not as a tool call of this one. The
  # subagent is found in the thread's record, so this holds after the MC restarted.
  defp assistant_block(
         %{"type" => "tool_use", "id" => tool_id, "name" => "SendMessage"} = block,
         _id,
         _index,
         state
       )
       when not is_map_key(state.items, tool_id) do
    input = block["input"] || %{}

    cond do
      is_map_key(state.work, tool_id) ->
        state

      entity = resumable(state, input["to"]) ->
        state = flush(state)
        sub = NativeSubagent.resume(work_ids(state), entity, input["message"])
        put_in(state.work[tool_id], %{sub: sub, item: nil, background: true})

      # An agent this thread has no record of, as when the MC missed its launch: the
      # call waits for its task (`task_started/2`), which makes it a subagent, or for
      # its result, which shows it as a tool call.
      is_binary(input["to"]) and is_map(state.turn) ->
        put_in(state.turn[:sends], Map.put(state.turn[:sends] || %{}, tool_id, block))

      true ->
        tool_block(block, state)
    end
  end

  # Claude put its own session in plan mode: the next turn sets the thread's mode back
  # (`ensure_session/2`), so Claude and the subagents it starts can edit again.
  defp assistant_block(%{"type" => "tool_use", "name" => "EnterPlanMode"} = block, _, _, state),
    do: tool_block(block, %{state | permission_mode: "plan"})

  defp assistant_block(%{"type" => "tool_use"} = block, _id, _index, state),
    do: tool_block(block, state)

  defp assistant_block(_block, _id, _index, state), do: state

  # The SendMessage call to an agent this thread had no record of, if it waits on `tool`.
  defp pending_send(%{turn: %{sends: %{} = sends} = turn} = state, tool)
       when is_map_key(sends, tool),
       do: {sends[tool], %{state | turn: %{turn | sends: Map.delete(sends, tool)}}}

  defp pending_send(state, _tool), do: {nil, state}

  # The subagent of this thread that Claude knows as the agent `to` (its task id).
  defp resumable(state, to) when is_binary(to) do
    HalC2.Streams.state(state.thread_id)
    |> StreamState.list("subagent")
    |> Enum.find(&(&1["origin"] == "provider_native" and &1["nativeTaskId"] == to))
  end

  defp resumable(_state, _to), do: nil

  # --- a subagent's own messages ----------------------------------------------------

  # A message of the subagent that tool call `parent` started (or resumed): what it says
  # and the tools it calls go to its child thread, never this thread's turn, so the
  # turn's text, rollback head, sign-in failure and end are its own. What it leaves
  # running in the background (a command, a monitor, a subagent of its own) runs in
  # this thread's Claude process, which must stay up for it, so that is this thread's
  # background work. Its partial messages are dropped: the complete message follows.
  # What it spends counts in `budget/2`.
  defp sidechain(%{"type" => "stream_event"}, _parent, state), do: state

  defp sidechain(
         %{"type" => "assistant", "message" => %{"content" => content}} = message,
         parent,
         state
       )
       when is_list(content) do
    state
    |> parent_work(Enum.filter(content, &parent_work?/1))
    |> to_subagent(parent, fn sub ->
      {blocks, placed} =
        placed(sub[:placed], message["message"]["id"], with_presentation(content, message))

      for {block, index} <- blocks,
          not parent_work?(block),
          reduce: Map.put(sub, :placed, placed) do
        sub -> subagent_block(sub, block, block_key(message["message"]["id"], index))
      end
    end)
  end

  # A result for the subagent's own launch call, in its own stream, is the note a
  # foreground fork opens with ("Fork started — that fork is you."): the launch's real
  # result arrives in the stream that made the call, so it is no result at all.
  defp sidechain(%{"type" => "user", "message" => %{"content" => content}}, parent, state)
       when is_list(content) do
    content =
      Enum.reject(content, &match?(%{"type" => "tool_result", "tool_use_id" => ^parent}, &1))

    {own, theirs} =
      Enum.split_with(content, fn
        %{"type" => "tool_result", "tool_use_id" => tool_id} ->
          is_map_key(state.work, tool_id) or is_map_key(state.items, tool_id)

        _ ->
          false
      end)

    state = Enum.reduce(own, state, &tool_result(&2, &1["tool_use_id"], &1))
    to_subagent(state, parent, fn sub -> Enum.reduce(theirs, sub, &subagent_result/2) end)
  end

  defp sidechain(_message, _parent, state), do: state

  defp parent_work?(%{"type" => "tool_use", "name" => "Monitor"}), do: true
  defp parent_work?(block), do: background_launch?(block)

  defp parent_work(state, []), do: state

  defp parent_work(%{turn: nil} = state, blocks) do
    case with_ids(state) do
      %{last_ids: nil} = state ->
        state

      state ->
        blocks
        |> Enum.reduce(
          %{state | turn: %{ids: state.last_ids}},
          &assistant_block(&1, nil, nil, &2)
        )
        |> Map.put(:turn, nil)
    end
  end

  defp parent_work(state, blocks),
    do: Enum.reduce(blocks, flush(state), &assistant_block(&1, nil, nil, &2))

  # Claude names a subagent's tool call before anything the subagent says, and this
  # runtime records the subagent then, so a message under a tool call it does not know
  # comes from a subagent that has ended, or that a runtime before this one started:
  # nothing will claim it later, and it is not this thread's.
  defp to_subagent(state, parent, fun) do
    case running_subagent(state, parent) do
      {tool, work} ->
        put_in(state.work[tool], %{work | sub: fun.(work.sub)})

      nil ->
        Logger.debug("claude #{state.thread_id}: dropped a message of subagent #{parent}")
        state
    end
  end

  # The work of the subagent tool call `parent` started, or of the call (SendMessage)
  # that resumed it.
  defp running_subagent(state, parent) do
    id = "node:subagent:#{driver()}:#{parent}"

    case state.work[parent] do
      %{sub: %{}} = work -> {parent, work}
      _ -> Enum.find(state.work, &match?({_, %{sub: %{id: ^id}}}, &1))
    end
  end

  # A subagent's message waiting with a wake for its run (`receive_message/2`) has not
  # recorded its tool calls yet.
  defp buffered_subagent_tool?(%{buffer: buffer}, tool_use_id) when is_list(buffer) do
    Enum.any?(buffer, fn
      %{"type" => "assistant", "parent_tool_use_id" => parent, "message" => %{"content" => c}}
      when is_binary(parent) and is_list(c) ->
        Enum.any?(c, &match?(%{"type" => "tool_use", "id" => ^tool_use_id}, &1))

      _ ->
        false
    end)
  end

  defp buffered_subagent_tool?(_wake, _tool_use_id), do: false

  defp subagent_block(sub, %{"type" => "text", "text" => text}, key),
    do: NativeSubagent.item(sub, key, "assistant_message", "completed", %{"text" => text})

  defp subagent_block(sub, %{"type" => "thinking", "thinking" => text}, key),
    do:
      NativeSubagent.item(sub, key, "reasoning", "completed", %{
        "text" => text,
        "streaming" => false
      })

  # Shown as their question card and plan, which reach the parent as prompts.
  defp subagent_block(sub, %{"type" => "tool_use", "name" => name}, _key)
       when name in ["AskUserQuestion", "ExitPlanMode"],
       do: sub

  defp subagent_block(sub, %{"type" => "tool_use", "id" => tool_id, "name" => name} = block, _key) do
    {kind, fields} = tool_kind(name, block["input"] || %{}, block["presentation"])
    sub = NativeSubagent.item(sub, tool_id, @item_types[kind], "running", fields)
    Map.put(sub, :tools, Map.put(Map.get(sub, :tools, %{}), tool_id, kind))
  end

  defp subagent_block(sub, _block, _key), do: sub

  defp subagent_result(%{"type" => "tool_result", "tool_use_id" => tool_id} = result, sub) do
    case Map.pop(Map.get(sub, :tools, %{}), tool_id) do
      {nil, _} ->
        sub

      {kind, tools} ->
        status = result_status(result)
        field = result_field(kind)
        fields = if field, do: %{field => result_text(result["content"])}, else: %{}

        sub
        |> NativeSubagent.item(tool_id, @item_types[kind], status, fields)
        |> Map.put(:tools, tools)
    end
  end

  defp subagent_result(_block, sub), do: sub

  defp tool_block(%{"id" => tool_id, "name" => name} = block, state) do
    input = block["input"] || %{}

    # A background command's tool result only says it started; its task ends it. A
    # monitor (the `Monitor` tool) always runs on: it is background work of its own
    # kind, never a command.
    state =
      if (name == "Bash" and input["run_in_background"] == true) or name == "Monitor",
        do: put_in(state.work[tool_id], %{sub: nil, item: nil, background: true}),
        else: state

    {kind, fields} = tool_kind(name, input, block["presentation"])
    ensure_item(state, tool_id, kind, Map.put(fields, :native_name, name))
  end

  # Claude Code names each MCP tool use on its assistant message, in `tool_use_meta`
  # (undeclared by the SDK): the tool's display name, its server's and the server's
  # icon. Each tool_use block carries its entry as `"presentation"`.
  defp with_presentation(content, message) do
    case message["tool_use_meta"] do
      [_ | _] = meta ->
        by_id = for %{"id" => id} = entry <- meta, is_binary(id), into: %{}, do: {id, entry}

        Enum.map(content, fn
          %{"type" => "tool_use", "id" => id} = block when is_map_key(by_id, id) ->
            Map.put(block, "presentation", by_id[id])

          block ->
            block
        end)

      _ ->
        content
    end
  end

  # How an MCP tool call reads: Claude's title for it and the integration it groups
  # under (`HalC2.Codex.ToolPresentation` gives Codex's the same fields), else a title
  # made from its `mcp__<server>__<tool>` name. HAL-C2's own tools are named by the
  # clients.
  defp presentation_fields(_name, %{"display_name" => title} = meta)
       when is_binary(title) and title != "" do
    fields = %{"title" => bounded(title, 160)}

    case meta["server_display_name"] do
      server when is_binary(server) and server != "" ->
        server = bounded(server, 160)

        source =
          %{"key" => "mcp:#{String.downcase(server)}", "name" => server, "kind" => "integration"}
          |> then(fn source ->
            case http_url(meta["icon_url"]) do
              nil -> source
              url -> Map.put(source, "icon", %{"_tag" => "themed-logo", "logoUrl" => url})
            end
          end)

        Map.put(fields, "toolSource", source)

      _ ->
        fields
    end
  end

  defp presentation_fields("mcp__" <> rest, _meta) do
    case String.split(rest, "__", parts: 2) do
      [server, tool] when server not in ["hal-c2", "hal_c2"] and tool != "" ->
        %{"title" => tool |> String.replace(["_", "-"], " ") |> String.capitalize()}

      _ ->
        %{}
    end
  end

  defp presentation_fields(_name, _meta), do: %{}

  # The approval item's account of why Claude asked: its reason when it says more
  # than the prompt, and in Full access which kind of check still asked
  # (`fullAccessOverride`): an ask rule in the user's permissions, or one of Claude's
  # own safety checks. Claude's other reasons (a hook, its classifier, ...) name none.
  defp request_reason(state, prompt, context) do
    reason =
      case context["decision_reason"] do
        reason when is_binary(reason) ->
          reason = reason |> String.replace(~r/\e\[[0-9;?]*[A-Za-z]/, "") |> String.trim()
          if reason != "" and reason != prompt, do: bounded(reason, 2000)

        _ ->
          nil
      end

    override =
      if state.permission_mode == "bypassPermissions" do
        case context["decision_reason_type"] do
          "rule" -> "ask_rule"
          "safetyCheck" -> "provider_check"
          _ -> nil
        end
      end

    Map.reject(%{"reason" => reason, "fullAccessOverride" => override}, fn {_, v} -> is_nil(v) end)
  end

  defp bounded(text, max), do: text |> String.trim() |> String.slice(0, max)

  defp http_url(url) when is_binary(url) and byte_size(url) <= 4096 do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}} when scheme in ["http", "https"] and host != nil ->
        url

      _ ->
        nil
    end
  end

  defp http_url(_url), do: nil

  # The item a tool call shows as: its kind (`TurnWriter.ensure_item/4`) and fields.
  defp tool_kind(name, input, presentation) do
    cond do
      name == "Bash" ->
        {:command, %{"input" => input["command"] || "", "output" => ""}}

      name in @file_tools ->
        {:file, %{"fileName" => input["file_path"] || input["notebook_path"] || name}}

      name in @web_tools ->
        {:web, %{"patterns" => Enum.filter([input["query"], input["url"]], &is_binary/1)}}

      # A skill call reads by the skill it ran; expanding it shows only its
      # arguments as plain text, and a call without arguments does not expand.
      name == "Skill" and is_binary(input["skill"]) and input["skill"] != "" ->
        {:tool,
         %{
           "toolName" => name,
           "title" => "Skill: #{bounded(input["skill"], 160)}",
           "input" => if(is_binary(input["args"]), do: input["args"], else: "")
         }}

      true ->
        {:tool,
         %{"toolName" => name, "input" => input}
         |> Map.merge(presentation_fields(name, presentation || %{}))
         |> then(fn fields ->
           case viewed_image_path(name, input) do
             nil -> fields
             path -> Map.put(fields, "viewedImagePath", path)
           end
         end)}
    end
  end

  @image_extensions ~w(.avif .gif .ico .jpeg .jpg .png .svg .webp)

  # An image Claude reads in the workspace is previewed from its tool call, by path.
  defp viewed_image_path(name, input) when name in ["Read", "Read file"] do
    path = String.trim(input["file_path"] || input["path"] || "")
    image? = String.downcase(Path.extname(path)) in @image_extensions

    if path != "" and String.length(path) <= 4096 and
         not String.contains?(path, ["\n", "\r"]) and image?,
       do: path
  end

  defp viewed_image_path(_name, _input), do: nil

  # Where a tool's result goes on its item.
  defp result_field(:command), do: "output"
  defp result_field(:file), do: "diffStr"
  defp result_field(:tool), do: "output"
  defp result_field(_kind), do: nil

  # Claude marks a tool call it did not run, one an explicit steer cut short say, in the
  # message's `tool_result_meta`; each result carries its mark, and a call Claude did not
  # run ends cancelled, not failed as a denied one does (Upstream #15892).
  defp result_meta(
         %{"tool_result_meta" => [_ | _] = meta, "message" => %{"content" => [_ | _]}} = message
       ) do
    kinds = Map.new(meta, &{&1["id"], &1["non_execution_kind"]})

    update_in(message, ["message", "content"], fn content ->
      Enum.map(content, fn
        %{"type" => "tool_result", "tool_use_id" => id} = block when is_map_key(kinds, id) ->
          Map.put(block, "non_execution_kind", kinds[id])

        block ->
          block
      end)
    end)
  end

  defp result_meta(message), do: message

  defp result_status(%{"non_execution_kind" => "cancelled"}), do: "cancelled"
  defp result_status(%{"is_error" => true}), do: "failed"
  defp result_status(_result), do: "completed"

  defp tool_result(state, tool_id, result) do
    state =
      case pending_send(state, tool_id) do
        {nil, state} -> state
        {block, state} -> tool_block(block, state)
      end

    case state.work[tool_id] do
      nil ->
        item_result(state, tool_id, result)

      work ->
        cond do
          result["is_error"] == true or not work.background ->
            work_result(state, tool_id, work, result)

          # A background subagent runs on; the call that started it (SendMessage's, say)
          # is done.
          work.sub ->
            item_result(state, tool_id, result)

          true ->
            launched(state, tool_id, work, result)
        end
    end
  end

  defp background_launch?(%{"type" => "tool_use", "name" => name}) when name in @agent_tools,
    do: true

  defp background_launch?(%{"type" => "tool_use", "name" => "Bash", "input" => input}),
    do: input["run_in_background"] == true

  defp background_launch?(_block), do: false

  # A background launch's acknowledgement: a command's item leaves the turn's items, so
  # the turn's end does not close it, and keeps running with the acknowledgement as its
  # output. A launch that failed ends the work.
  defp launched(state, tool_id, work, result) do
    case Map.pop(state.items, tool_id) do
      {nil, _} ->
        state

      {item, items} ->
        output = result_text(result["content"])

        commit(
          state,
          &[
            Orchestration.upsert(&1, "turn-item", item.id, fn e ->
              Map.put(e, "output", output)
            end)
          ]
        )

        %{state | items: items, work: %{state.work | tool_id => %{work | item: item}}}
    end
  end

  defp work_result(state, tool_id, work, result) do
    status = result_status(result)
    output = result_text(result["content"])
    state = if work.sub, do: end_work(state, tool_id, status, output), else: state
    state = %{state | work: Map.delete(state.work, tool_id)}
    item_result(state, tool_id, result)
  end

  defp item_result(state, tool_id, result) do
    case state.items[tool_id] do
      nil ->
        state

      %{kind: kind} ->
        status = result_status(result)
        output = result_text(result["content"])

        # A web call's result is not kept on the thread, which shows what it searched
        # for or fetched; plugins that hear turns hear it.
        finish_item(
          state,
          tool_id,
          status,
          fn entity ->
            if field = result_field(kind), do: Map.put(entity, field, output), else: entity
          end,
          if(kind == :web, do: %{"output" => output}, else: %{})
        )
    end
  end

  # A turn the user stopped before Claude wrote anything leaves the conversation where
  # the turn resumed it, so the head a rollback set, which the run's start cleared, goes
  # back: a later session resumes there again, not at the end of a transcript the
  # rollback cut (Upstream #25695). A turn Claude wrote in moved it on. A failed one
  # keeps it cleared: Claude may have failed on that very head ("No message found with
  # message.uuid"), and resuming the whole conversation is how the thread recovers.
  defp kept_head(%{resumed_at: head, ids: ids}, "interrupted", stream) when is_binary(head),
    do:
      Orchestration.upsert(
        stream,
        "provider-thread",
        ids.provider_thread,
        &Map.put(&1, "nativeConversationHeadRef", Entities.provider_ref(head, "claudeAgent"))
      )

  defp kept_head(_turn, _status, _stream), do: nil

  # A run whose prompt never reached Claude (refused, Claude did not start, or the run
  # ended while Claude started) leaves the provider thread as the run found it: what
  # other agents did since Claude last ran is still to be handed over, and a rollback's
  # head is still where Claude resumes (Upstream #25660). The run's start had moved both
  # on (`HalC2.Orchestration`).
  #
  # A start that outlived its caller's timeout can end after the next run started and
  # moved them on for itself. That run resumed Claude where it is now, so the head stays
  # its own; it counted what to hand over from this run, so what this one did not send
  # is still owed. What that run was handed is handed once more: a repeat costs less
  # than context Claude never sees.
  defp unsent(state, turn) do
    own = turn.run_ordinal

    commit(state, fn stream ->
      [
        Orchestration.upsert(stream, "provider-thread", turn.ids.provider_thread, fn
          %{"lastRunOrdinal" => ^own} = thread ->
            thread
            |> Map.put("lastRunOrdinal", turn[:seen_run_ordinal])
            # Nor did the history the run handed over: its mark goes, so the next run
            # resumes the conversation and hands that over again (`Handoff.plan/6`). A
            # mark the run found stands again: what it stands for is still unconfirmed.
            |> then(fn thread ->
              if thread["unconfirmedRunId"] == turn.ids.run,
                do:
                  thread
                  |> Map.drop(["unconfirmedRunId", "unconfirmedSince"])
                  |> Map.merge(Map.get(turn, :seen_mark, %{})),
                else: thread
            end)
            |> then(fn thread ->
              if head = turn[:head],
                do:
                  Map.put(
                    thread,
                    "nativeConversationHeadRef",
                    Entities.provider_ref(head, "claudeAgent")
                  ),
                else: thread
            end)

          %{"lastRunOrdinal" => later} = thread when is_integer(later) and later > own ->
            Map.put(thread, "lastRunOrdinal", turn[:seen_run_ordinal])

          _ ->
            nil
        end)
      ]
    end)
  end

  defp end_turn(state, status, failure, opts \\ []) do
    state = flush(state)

    # Items and prompts still open when the turn ends are closed with it; background
    # work goes on after a completed turn, or one Claude never started (`:keep_background`).
    state =
      if status == "completed" or opts[:keep_background],
        do: end_work(state, &(not &1.background), status),
        else: end_work(state, status)

    state = close_open_items(state, status)

    state =
      Enum.reduce(Map.keys(state.requests), state, &resolve_request(&2, &1, nil, "cancelled"))

    if head = state.turn[:head] do
      commit(state, fn stream ->
        [
          Orchestration.upsert(
            stream,
            "provider-turn",
            state.turn.ids.provider_turn,
            &Map.put(&1, "nativeTurnRef", Entities.provider_ref(head, "claudeAgent"))
          ),
          kept_head(state.turn, status, stream)
        ]
      end)
    end

    finish(state, status, failure)
    # Only a wake waiting for its own run outlives the turn.
    wake = if match?(%{buffer: [_ | _]}, state.wake), do: state.wake
    %{state | turn: nil, items: %{}, blocks: %{}, requests: %{}, wake: wake}
  end

  defp block_key(message_id, index), do: "#{message_id}:#{index}"

  # Claude sends a complete message one block per event, each under the message's id, so
  # a block's index in the message counts the blocks that came before it under that id
  # (`last`, `{id, count}`). Returns the blocks with their indexes, and the new `last`.
  defp placed(last, id, content) do
    from =
      case last do
        {^id, count} when is_binary(id) -> count
        _ -> 0
      end

    {Enum.with_index(content, from), {id, from + length(content)}}
  end

  # Claude says a task ended: its work ends with the task's summary.
  defp task_notification(task, state) do
    tool = state.tasks[task["task_id"]] || task["tool_use_id"]
    status = Map.get(@task_status, task["status"], "failed")

    state =
      if state.work[tool],
        do: end_work(state, tool, status, task["summary"], summary: true),
        else: state

    %{
      state
      | tasks: Map.delete(state.tasks, task["task_id"]),
        finished_tasks: MapSet.put(Map.get(state, :finished_tasks, MapSet.new()), task["task_id"])
    }
  end

  # The wake waiting for its run holds the task's start (`receive_message/2`).
  defp buffered_task?(%{buffer: buffer}, task_id) when is_list(buffer) do
    Enum.any?(
      buffer,
      &match?(%{"type" => "system", "subtype" => "task_started", "task_id" => ^task_id}, &1)
    )
  end

  defp buffered_task?(_wake, _task_id), do: false

  # Claude registered a task for a tool call: a subagent's or a command's, which says
  # whether it runs in the background. Other tasks (a workflow, say) show as subagents.
  # Ambient tasks, such as watchers, are not activity.
  defp task_started(state, %{"task_id" => task_id} = task) do
    state =
      Map.update(state, :finished_tasks, MapSet.new(), &MapSet.delete(&1, task_id))

    tool = task["tool_use_id"] || task_id
    background? = task["is_backgrounded"] == true

    cond do
      task["ambient"] == true or task["skip_transcript"] == true ->
        %{state | tasks: Map.put(state.tasks, task_id, nil)}

      work = state.work[tool] ->
        work = %{work | background: work.background or background?}
        # Claude's name for the subagent, which a later SendMessage addresses.
        if work.sub, do: name_subagent(state, work.sub, task_id)

        %{
          state
          | work: Map.put(state.work, tool, work),
            tasks: Map.put(state.tasks, task_id, tool)
        }

      background? and match?(%{kind: :command}, state.items[tool]) ->
        work = %{sub: nil, item: nil, background: true}

        %{
          state
          | work: Map.put(state.work, tool, work),
            tasks: Map.put(state.tasks, task_id, tool)
        }

      task["task_type"] == "local_bash" ->
        %{state | tasks: Map.put(state.tasks, task_id, nil)}

      true ->
        # A subagent the MC missed launching, resumed by a SendMessage: what it was sent
        # opens its thread.
        {send, state} = pending_send(state, tool)
        prompt = get_in(send || %{}, ["input", "message"])

        subagent_task(
          with_ids(state),
          tool,
          if(prompt, do: Map.put(task, "prompt", prompt), else: task)
        )
    end
  end

  defp name_subagent(state, sub, task_id) do
    commit(state, fn stream ->
      [
        Orchestration.upsert(stream, "subagent", sub.id, fn
          nil -> nil
          entity -> Map.put(entity, "nativeTaskId", task_id)
        end)
      ]
    end)
  end

  # No run to join: nothing is recorded.
  defp subagent_task(%{turn: nil, last_ids: nil} = state, _tool, _task), do: state

  defp subagent_task(state, tool, %{"task_id" => task_id} = task) do
    state = flush(state)

    sub =
      NativeSubagent.start(work_ids(state), tool, %{
        "prompt" => task["prompt"] || task["description"],
        "title" => task["description"]
      })

    name_subagent(state, sub, task_id)
    work = %{sub: sub, item: nil, background: task["is_backgrounded"] != false}

    %{
      state
      | work: Map.put(state.work, tool, work),
        tasks: Map.put(state.tasks, task_id, tool)
    }
  end

  # Ends the work `which` picks (all of it by default) with `status`. Held notices go
  # first, so a command Claude already reported ended keeps its own status and summary
  # when a stop, a rewind or the CLI's exit ends the rest.
  defp end_work(state, which \\ fn _ -> true end, status)

  defp end_work(state, which, status) when is_function(which) do
    state = release_notices(state)

    Enum.reduce(state.work, state, fn {tool, work}, state ->
      if which.(work), do: end_work(state, tool, status, nil), else: state
    end)
  end

  # Ends one piece of work: its subagent with the task's `result`, or its command item.
  defp end_work(state, tool, status, result, opts \\ []) do
    case state.work[tool] do
      %{sub: %{} = sub} ->
        NativeSubagent.finish(sub, status, result, opts)

      %{item: %{id: item_id, node: node_id}} ->
        end_item(state, item_id, node_id, status, fn item ->
          if result, do: Map.put(item, "output", result), else: item
        end)

      _ ->
        :ok
    end

    %{
      state
      | work: Map.delete(state.work, tool),
        tasks: Map.new(state.tasks, fn {task, t} -> {task, if(t != tool, do: t)} end)
    }
  end

  # Where Claude compacts on its own, for the meter: 33,000 tokens before an
  # `autoCompactWindow` smaller than the model's window (Upstream #22654). Unset, or
  # at least the window, Claude compacts where it would for the model.
  @compact_buffer 33_000
  defp compacts_at(%{"autoCompactWindow" => size}, max)
       when is_integer(size) and is_integer(max) and size < max,
       do: size - @compact_buffer

  defp compacts_at(_settings, _max), do: nil

  # The ids work joins: the running turn's, or between turns the latest one's.
  # The instance's `autoCompactWindow` (the tokens after which Claude compacts by
  # itself) goes to the CLI with its other settings; unset leaves Claude's default.
  defp auto_compact(launch, instance) do
    with window when is_binary(window) <-
           HalC2.Settings.instance_setting(instance, "autoCompactWindow"),
         {tokens, ""} when tokens >= 100_000 and tokens <= 1_000_000 <-
           Integer.parse(String.trim(window)) do
      %{launch | settings: Map.put(launch.settings, "autoCompactWindow", tokens)}
    else
      _ -> launch
    end
  end

  defp work_ids(%{turn: %{ids: ids}}), do: ids
  defp work_ids(state), do: state.last_ids

  # Fills in the latest turn's ids from the thread when this runtime has not run one
  # (it started, or was upgraded, after that turn): the latest run that began, not a
  # queued one, which has no attempt yet (a held one is numbered above the run that ran).
  defp with_ids(%{turn: nil, last_ids: nil} = state) do
    stream = HalC2.Streams.state(state.thread_id)

    case stream
         |> StreamState.list("run")
         |> Enum.reject(&(&1["status"] == "queued"))
         |> HalC2.Projection.Shell.latest_run() do
      nil ->
        state

      run ->
        ids = %{
          driver: driver(),
          instance: run["providerInstanceId"] || driver(),
          thread: state.thread_id,
          run: run["id"],
          attempt: run["activeAttemptId"],
          root_node: run["rootNodeId"],
          provider_thread: run["providerThreadId"]
        }

        state
        |> Map.put(:last_ids, ids)
        |> Map.put(:usage_instance, resolved_instance(Entities.instance(ids)))
    end
  end

  defp with_ids(state), do: state

  defp result_text(content) when is_binary(content), do: content

  defp result_text(content) when is_list(content),
    do: Enum.map_join(content, "", fn block -> block["text"] || "" end)

  defp result_text(_), do: ""
end
