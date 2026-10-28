defmodule HalC2.Codex.ThreadRuntime do
  @moduledoc """
  Runs one thread's Codex turns through `codex app-server` and writes them into the
  thread's log.

  The process owns the app-server connection for its thread. A turn starts with
  `thread/start` (or `thread/resume` for a thread Codex already knows) and
  `turn/start`; the app-server's notifications then become entity patches.
  Streamed text and command output are written as appends (`HalC2.Orchestration.TurnWriter`),
  so a long answer costs its new bytes, not its whole length, per update.

  A command Codex leaves running in a background terminal (unified exec) when its turn
  completes keeps its item running after the turn: the thread lists it as background
  work (`HalC2.Projection.BackgroundWork`), which keeps the idle reaper from stopping
  the app-server that runs it. Codex's late `item/completed` for it ends the item. An
  interrupted turn, or a stop between turns, terminates those terminals
  (`thread/backgroundTerminals/terminate`) along with the turn's own commands, which
  Codex leaves running when it interrupts; the app-server exiting or being released
  ends them too.
  """

  use GenServer, restart: :temporary

  require Logger

  import HalC2.Orchestration.TurnWriter

  alias HalC2.Orchestration
  alias HalC2.Orchestration.{Entities, TurnWatch}
  alias HalC2.JsonRpc.Connection

  @state_version 3

  # The steer's two budgets, one source so their ordering cannot drift: the
  # handler's nested `turn/steer` call (`steer_call_timeout/0`, passed
  # explicitly rather than left to `Connection.call`'s default) and the outer
  # steer call's default above it. See `steer_call/3`.
  @steer_call_timeout_ms 30_000
  @steer_timeout_ms @steer_call_timeout_ms + 5_000

  # runtimeMode -> {approvalPolicy, approvalsReviewer, sandboxPolicy type}. Auto lets Codex's own reviewer answer what it would ask the user.
  @runtime_policies %{
    "approval-required" => {"untrusted", "user", "readOnly"},
    "auto-accept-edits" => {"on-request", "user", "workspaceWrite"},
    "auto" => {"on-request", "auto_review", "workspaceWrite"},
    "full-access" => {"never", "user", "dangerFullAccess"}
  }

  def driver, do: "codex"

  @spec start_turn(String.t(), map) :: :ok
  def start_turn(thread_id, turn),
    do: thread_id |> ensure() |> GenServer.call({:start_turn, turn}, 60_000)

  @queued_stop "Codex did not start the queued turn within 10 seconds; Stop could not be delivered."

  @spec interrupt(String.t(), String.t() | nil) :: :ok | {:error, String.t()}
  def interrupt(thread_id, run_id) do
    case Registry.lookup(HalC2.Codex.Registry, thread_id) do
      [{pid, _}] ->
        # A turn Codex has not started yet keeps this call queued in the runtime
        # behind its start: it is delivered as soon as the turn starts, and a turn
        # that never starts fails the stop rather than holding it forever. The
        # queued call carries an id the runtime checks, so a timed-out stop is
        # not delivered late after all.
        id = System.unique_integer([:positive])
        budget = Application.get_env(:hal_c2, :codex_interrupt_timeout_ms, 10_000)

        try do
          GenServer.call(pid, {:interrupt, run_id, id}, budget)
        catch
          :exit, {:timeout, _} ->
            now = System.monotonic_time(:millisecond)

            cancelled =
              :persistent_term.get({__MODULE__, :cancelled_stops}, %{})
              |> Enum.filter(fn {_id, at} -> is_integer(at) and now - at < 60_000 end)
              |> Map.new()
              |> Map.put(id, now)

            :persistent_term.put({__MODULE__, :cancelled_stops}, cancelled)
            {:error, @queued_stop}

          :exit, _ ->
            {:error, "no active Codex turn in this thread"}
        end

      [] ->
        {:error, "no active Codex turn in this thread"}
    end
  end

  @doc """
  Adds a message (`%{text, attachments}`) to the running turn of `run_id` (`turn/steer`).

  When Codex refuses, whatever it said before refusing (a `turn/completed`, say) is
  applied before this returns, so the caller sees whether the turn is still running.
  Non-timeout exits (the runtime stopping mid-call, its nested provider call
  timing out) propagate: the caller must treat them as a refusal. See
  `HalC2.RuntimeSteer`.
  """
  @spec steer(String.t(), String.t(), map) :: :ok | {:error, String.t()}
  def steer(thread_id, run_id, message) do
    case Registry.lookup(HalC2.Codex.Registry, thread_id) do
      [{pid, _}] -> steer_call(pid, run_id, message)
      [] -> {:error, "no running turn"}
    end
  end

  @doc false
  # The outer steer call's budget. Its default is derived above
  # `steer_call_timeout/0` (see the module attributes), so the two stay
  # ordered; an env override below the inner budget reorders them on purpose
  # (tests timeout a steer quickly that way).
  def steer_timeout,
    do: Application.get_env(:hal_c2, :codex_steer_timeout_ms, @steer_timeout_ms)

  @doc false
  # The handler's nested `turn/steer` budget, passed explicitly at the call.
  def steer_call_timeout, do: @steer_call_timeout_ms

  # `HalC2.RuntimeSteer` owns which timeout means held. The handler blocks in
  # a nested `Connection.call` on the inner budget, so the outer defaults
  # above it: with equal budgets the outer deadline — started strictly before
  # the handler starts the inner call — would always win, and a provider that
  # never answers `turn/steer` would be reported as a delivery. Ordered this
  # way, a promptly started handler whose provider hangs is decided by the
  # inner exit (a refusal), while a steer stuck behind mailbox backlog past
  # the outer budget still falls through to `:ok`. A refusal is always the
  # refusal: settling the runtime so the caller sees whether the turn still
  # runs is best-effort, and a settle that itself times out or finds the
  # runtime gone must not turn it into a delivery. The two budgets stack: a
  # wedged runtime blocks the dispatching process for the steer budget plus
  # the settle budget (35s + 30s by default) before the sender hears the
  # refusal, so tune them together, not one in isolation.
  defp steer_call(pid, run_id, message) do
    timeout = steer_timeout()

    with {:error, _} = error <- HalC2.RuntimeSteer.call(pid, run_id, message, timeout) do
      # Notifications that preceded the refusal sit in the runtime's mailbox ahead
      # of this call.
      settle(pid)
      error
    end
  end

  defp settle(pid) do
    timeout = Application.get_env(:hal_c2, :codex_steer_settle_timeout_ms, 30_000)
    GenServer.call(pid, :settle, timeout)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Answers a prompt: an approval's `%{"decision" => ProviderApprovalDecision}`,
  questions' `%{"answers" => answers}`, or `%{"dismissed" => true}`.
  """
  @spec respond(String.t(), String.t(), map) :: :ok | {:error, String.t()}
  def respond(thread_id, request_id, response) do
    case Registry.lookup(HalC2.Codex.Registry, thread_id) do
      [{pid, _}] -> GenServer.call(pid, {:respond, request_id, response})
      [] -> {:error, "no pending request"}
    end
  end

  @doc "Drops the last `drop` turns of the thread's Codex conversation (`thread/rollback`)."
  @spec rollback(String.t(), map) :: {:ok, map} | {:error, String.t()}
  def rollback(thread_id, plan),
    do: thread_id |> ensure() |> GenServer.call({:rollback, plan}, 60_000)

  @doc """
  `provider.uploadFeedback`: sends Codex a bug report with its logs for this
  thread's provider thread. Needs the thread's session to be running.
  """
  def upload_feedback(thread_id, reason) do
    gone = {:error, "The provider session is no longer running. Send a message first."}

    case Registry.lookup(HalC2.Codex.Registry, thread_id) do
      # A session that stopped after the lookup, however it stopped, is as gone as one
      # the lookup did not find. One that is only slow still exits the caller.
      [{pid, _}] ->
        Orchestration.session_call(
          fn -> GenServer.call(pid, {:upload_feedback, reason}, 60_000) end,
          gone
        )

      [] ->
        gone
    end
  end

  def start_link(thread_id),
    do:
      GenServer.start_link(__MODULE__, thread_id,
        name: {:via, Registry, {HalC2.Codex.Registry, thread_id}}
      )

  defp ensure(thread_id) do
    # Under its provider plugin, so a crash there stays with this provider.
    case DynamicSupervisor.start_child(HalC2.Plugins.sessions("codex"), {__MODULE__, thread_id}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  # --- server ------------------------------------------------------------------

  @impl true
  def init(thread_id) do
    # The app-server exiting ends the turn it was running (`{:EXIT, conn, _}`).
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       v: @state_version,
       thread_id: thread_id,
       conn: nil,
       # The provider instance the app-server was started for: nil until the first
       # `connect/2`; `:unknown` after a hot update of a runtime that predates the field.
       # Apart from `instance`, which is the resolved one a turn's quota belongs to.
       conn_instance: nil,
       native_thread_id: nil,
       # Whether the native thread was started kept to HAL-C2's workers
       # (`HalC2.Mcp.workers_only?/1`): its features and every turn's instructions follow it.
       workers_only: false,
       turn: nil,
       # The instance the latest turn runs as: a turn's quota belongs to it.
       instance: nil,
       items: %{},
       buffer: %{},
       flush_timer: nil,
       failure: nil,
       # Open approval prompts: request id -> the app-server request to answer.
       requests: %{},
       # The turn's commands still running: native item id -> Codex's process id (nil
       # outside unified exec).
       running: %{},
       # Commands an earlier turn left running in the background: native item id ->
       # `%{item: turn item, process: process id | nil}`.
       background: %{},
       # The run the latest turn ran as, also one that failed to start: the run a
       # client names to stop the commands left running between turns.
       last_run: nil,
       # Native threads Codex runs to consolidate its memories: their work is not
       # this thread's, and none of it is shown.
       memory_threads: %{},
       # The turn's final-answer items, the ones Codex tags `final_answer`
       # (`finals`: their native ids, `final_first`: the first one's,
       # `final_texts`: what they said, `suppressed`: later ones held back until
       # they finish, `commentary`: items Codex tagged as commentary). A message
       # with no phase is neither: it streams as any message does.
       final_first: nil,
       finals: %{},
       final_texts: %{},
       suppressed: %{},
       commentary: %{},
       # Dynamic tool calls Codex marked persistent: native id -> turn item handle.
       # They stay running after a completed turn, like background commands.
       persistent: %{},
       # The native turn a stop was delivered for, and whether a stop settled the
       # last turn (a subagent starting under it is interrupted at once).
       interrupting: nil,
       stopped: false,
       # A usage-limit failure whose reset Codex had not named when the turn
       # stopped: `%{item: failure item id}` while its reset is still unknown.
       usage_failure: nil
     }}
  end

  @impl true
  def handle_call({:start_turn, turn}, _from, state) do
    # A thread saved under an older model name runs on the model it names today.
    turn = %{turn | model: HalC2.Codex.Provider.current_slug(turn.model)}

    # The instance is resolved once, here: settings changing mid-turn (the
    # instance removed, say) do not re-attribute the rest of the turn.
    instance =
      case turn[:ids] do
        %{} = ids -> Entities.instance(ids)
        _ -> nil
      end

    state = %{
      state
      | turn: turn,
        instance: resolved_instance(instance),
        items: %{},
        failure: nil,
        running: %{},
        last_run: turn[:ids][:run]
    }

    # The threads this turn's subagents run in (`spawnAgent`): native thread id ->
    # `%{sub: NativeSubagent handle, done: bool}`.
    state =
      Map.merge(state, %{
        subagents: %{},
        final_first: nil,
        finals: %{},
        final_texts: %{},
        suppressed: %{},
        commentary: %{},
        interrupting: nil,
        stopped: false,
        usage_failure: nil
      })

    case begin_turn(state, turn) do
      {:ok, state} ->
        {:reply, :ok, state}

      {:error, %{"message" => "Codex App Server process exited" <> _}, state} ->
        Logger.warning("codex turn failed to start: the app-server exited")
        finish(state, "failed", "The provider stopped while starting the turn.")
        {:reply, :ok, %{state | turn: nil}}

      # The app-server exited before the turn began.
      {:error, :closed, state} ->
        Logger.warning("codex turn failed to start: the app-server exited")
        finish(state, "failed", "The provider stopped while starting the turn.")
        {:reply, :ok, %{state | turn: nil}}

      {:error, reason, state} ->
        Logger.warning("codex turn failed to start: #{inspect(reason)}")
        finish(state, "failed", start_failure("Codex", reason))
        {:reply, :ok, %{state | turn: nil}}
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
    Registry.unregister(HalC2.Codex.Registry, state.thread_id)
    {:stop, {:shutdown, :released}, :ok, state}
  end

  def handle_call(:release, _from, state), do: {:reply, :busy, state}

  # Pinned to a run, the interrupt stops only that run's turn: a different
  # turn that began since the caller read the run is not the caller's to stop.
  def handle_call({:interrupt, run_id}, _from, %{turn: %{ids: %{run: other}}} = state)
      when is_binary(run_id) and run_id != other,
      do: {:reply, {:error, "no running turn"}, state}

  # Between turns a stop naming a run that started before the latest turn's (a
  # restart that read it as active) leaves the commands that later run left
  # (#474); one naming that run or a later one, on another provider, ends it.
  def handle_call({:interrupt, run_id}, from, %{turn: nil, last_run: last} = state)
      when is_binary(run_id) and is_binary(last) and run_id != last do
    if HalC2.Orchestration.earlier_run?(state.thread_id, run_id, last),
      do: {:reply, {:error, "no running turn"}, state},
      else: handle_call(:interrupt, from, state)
  end

  def handle_call({:interrupt, _run_id}, from, state), do: handle_call(:interrupt, from, state)

  # A stop whose caller already timed out (`interrupt/2`) is not delivered late.
  def handle_call({:interrupt, run_id, id}, from, state) do
    cancelled = :persistent_term.get({__MODULE__, :cancelled_stops}, %{})

    if cancelled[id] do
      :persistent_term.put({__MODULE__, :cancelled_stops}, Map.delete(cancelled, id))
      {:reply, {:error, @queued_stop}, state}
    else
      handle_call({:interrupt, run_id}, from, state)
    end
  end

  def handle_call(:interrupt, _from, %{turn: %{native_turn_id: turn_id}} = state)
      when is_binary(turn_id) do
    Connection.call(state.conn, "turn/interrupt", %{
      "threadId" => state.native_thread_id,
      "turnId" => turn_id
    })

    # The turn's subagents stop with it, each on its own native thread.
    for {thread, entry} <- Map.get(state, :subagents, %{}),
        entry[:turn_id] != nil do
      Connection.call(state.conn, "turn/interrupt", %{
        "threadId" => thread,
        "turnId" => entry.turn_id
      })
    end

    # A turn Codex does not end within the deadline is settled as interrupted
    # here; what it sends for the turn afterwards is not the thread's.
    deadline = Application.get_env(:hal_c2, :codex_interrupt_deadline_ms, 10_000)
    Process.send_after(self(), {:interrupt_deadline, turn_id}, deadline)
    {:reply, :ok, %{state | interrupting: turn_id, stopped: true}}
  end

  # Between turns, stopping the thread stops the commands it left running.
  def handle_call(:interrupt, _from, %{turn: nil} = state) when state.background != %{},
    do: {:reply, :ok, end_background(state, "interrupted")}

  def handle_call(:interrupt, _from, state), do: {:reply, {:error, "no running turn"}, state}

  # Codex refuses the steer if its turn has moved on, so a late steer fails cleanly.
  def handle_call(
        {:steer, run_id, message},
        _from,
        %{turn: %{ids: %{run: run_id}, native_turn_id: turn_id}} = state
      ) do
    params = %{
      "threadId" => state.native_thread_id,
      "expectedTurnId" => turn_id,
      "input" => codex_input(message)
    }

    case Connection.call(state.conn, "turn/steer", params, steer_call_timeout()) do
      {:ok, _} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, rpc_message(reason)}, state}
    end
  end

  def handle_call({:rollback, _plan}, _from, %{turn: turn} = state) when turn != nil,
    do: {:reply, {:error, "Interrupt the current turn before rewinding."}, state}

  def handle_call({:rollback, plan}, _from, state) do
    state = end_background(state, "interrupted")

    # A session carried from another machine is forked from its copy before rewinding.
    turn = %{
      cwd: plan.cwd,
      model: plan.model,
      native_thread_id: plan.native_thread_id,
      ids: %{thread: plan.thread_id, instance: plan.instance},
      fork: plan[:fork]
    }

    with {:ok, state} <- connect(state, turn),
         {:ok, state} <- ensure_native_thread(state, turn),
         {:ok, %{"thread" => %{"id" => id}}} <- rewind(state, plan) do
      {:reply, {:ok, %{"nativeThreadRef" => Entities.provider_ref(id)}},
       %{state | native_thread_id: id}}
    else
      {:error, reason, state} -> {:reply, {:error, rpc_message(reason)}, state}
      {:error, reason} -> {:reply, {:error, rpc_message(reason)}, state}
    end
  end

  def handle_call({:upload_feedback, reason}, _from, state) do
    params =
      %{"classification" => "bug", "includeLogs" => true, "threadId" => state.native_thread_id}
      |> then(&if(is_binary(reason), do: Map.put(&1, "reason", reason), else: &1))

    reply =
      with conn when conn != nil <- state.conn,
           true <- is_binary(state.native_thread_id),
           {:ok, %{"threadId" => id}} <- Connection.call(conn, "feedback/upload", params) do
        {:ok, %{"feedbackId" => id}}
      else
        {:error, reason} -> {:error, rpc_message(reason)}
        _ -> {:error, "The provider session is no longer running. Send a message first."}
      end

    {:reply, reply, state}
  end

  def handle_call({:steer, _run_id, _message}, _from, state),
    do: {:reply, {:error, "no running turn"}, state}

  def handle_call(:settle, _from, state), do: {:reply, :ok, state}

  def handle_call({:respond, request_id, response}, _from, state) do
    case Map.pop(state.requests, request_id) do
      {nil, _} ->
        {:reply, {:error, "no pending request #{request_id}"}, state}

      {{:question, rpc_id, question_ids}, requests} ->
        answers = if response["dismissed"], do: %{}, else: response["answers"] || %{}

        Connection.respond(
          state.conn,
          rpc_id,
          {:ok, %{"answers" => codex_answers(answers, question_ids)}}
        )

        status = if response["dismissed"], do: "cancelled", else: "resolved"
        state = resolve_request(%{state | requests: requests}, request_id, response, status)
        {:reply, :ok, state}

      {{:elicitation, rpc_id, params}, requests} ->
        decision = response["decision"] || "decline"
        answer = HalC2.Codex.Elicitation.response(params, decision)
        Connection.respond(state.conn, rpc_id, {:ok, answer})
        state = resolve_request(%{state | requests: requests}, request_id, decision)
        {:reply, :ok, state}

      {{:legacy, rpc_id}, requests} ->
        decision = response["decision"] || "decline"

        legacy =
          case decision do
            "accept" -> "approved"
            "acceptForSession" -> "approved_for_session"
            "acceptAlways" -> "approved_for_session"
            "cancel" -> "abort"
            _ -> "denied"
          end

        Connection.respond(state.conn, rpc_id, {:ok, %{"decision" => legacy}})
        state = resolve_request(%{state | requests: requests}, request_id, decision)
        {:reply, :ok, state}

      {rpc_id, requests} ->
        decision = response["decision"] || "decline"
        # Codex has no "always"; the closest is for the rest of the session.
        codex_decision = if decision == "acceptAlways", do: "acceptForSession", else: decision
        Connection.respond(state.conn, rpc_id, {:ok, %{"decision" => codex_decision}})
        state = resolve_request(%{state | requests: requests}, request_id, decision)
        {:reply, :ok, state}
    end
  end

  # What an app-server stopped for another instance's (`connect/2`) had already sent
  # belongs to no turn of this one.
  @impl true
  def handle_info({:json_rpc, conn, _message}, %{conn: current} = state) when conn != current,
    do: {:noreply, state}

  def handle_info({:json_rpc, _conn, {:notification, method, params}}, state),
    do: {:noreply, notification(method, params || %{}, state)}

  # Codex may not pile up requests on the user: with 32 already waiting, another
  # is refused at once and the waiting ones are unaffected.
  def handle_info({:json_rpc, conn, {:request, id, method, _params}}, state)
      when method in [
             "item/commandExecution/requestApproval",
             "item/fileChange/requestApproval",
             "item/permissions/requestApproval",
             "execCommandApproval",
             "applyPatchApproval",
             "item/tool/requestUserInput",
             "mcpServer/elicitation/request"
           ] and map_size(state.requests) >= 32 do
    Connection.respond(
      conn,
      id,
      {:error, %{"code" => -32001, "message" => "Too many Codex requests are already active."}}
    )

    {:noreply, state}
  end

  def handle_info({:json_rpc, _conn, {:request, id, method, params}}, %{turn: turn} = state)
      when turn != nil and
             method in [
               "item/commandExecution/requestApproval",
               "item/fileChange/requestApproval",
               "item/permissions/requestApproval",
               "execCommandApproval",
               "applyPatchApproval"
             ] do
    {kind, prompt} =
      case method do
        "item/commandExecution/requestApproval" ->
          {"command", reason_or(params, params["command"])}

        "item/fileChange/requestApproval" ->
          {"file-change", file_change_prompt(params)}

        # An older Codex's approvals: its command is a list of words, and its patch
        # lists the files the way `file_change_prompt/1` reads them.
        "execCommandApproval" ->
          command =
            case params["command"] do
              words when is_list(words) -> Enum.join(words, " ")
              command -> command
            end

          {"command", reason_or(params, command)}

        "applyPatchApproval" ->
          {"file-change", file_change_prompt(params)}

        _ ->
          {permissions_kind(params["permissions"]), params["reason"]}
      end

    native =
      params["approvalId"] || params["itemId"] || params["callId"] || "request-#{id}"

    {state, request_id} = open_request(flush(state), native, kind, prompt)

    answer =
      if method in ["execCommandApproval", "applyPatchApproval"], do: {:legacy, id}, else: id

    {:noreply, %{state | requests: Map.put(state.requests, request_id, answer)}}
  end

  def handle_info(
        {:json_rpc, _conn, {:request, id, "item/tool/requestUserInput", params}},
        %{turn: turn} = state
      )
      when turn != nil do
    questions =
      (params["questions"] || [])
      |> Enum.with_index(1)
      |> Enum.map(fn {question, index} ->
        %{
          "id" => text(question["id"], "question-#{index}"),
          "header" => text(question["header"], "Question"),
          "question" => text(question["question"], "Choose an answer."),
          "options" =>
            for {option, n} <- Enum.with_index(question["options"] || [], 1) do
              label = text(option["label"], "Option #{n}")
              %{"label" => label, "description" => text(option["description"], label)}
            end
        }
      end)

    native = params["itemId"] || "request-#{id}"
    {state, request_id} = open_question(flush(state), native, questions)
    ids = Enum.map(questions, & &1["id"])
    {:noreply, %{state | requests: Map.put(state.requests, request_id, {:question, id, ids})}}
  end

  # A tool asking for access to another app: an approval naming the app, with the
  # scopes the request offers. One the user's decision could not answer is declined.
  def handle_info(
        {:json_rpc, conn, {:request, id, "mcpServer/elicitation/request", params}},
        %{turn: turn} = state
      ) do
    if turn == nil or HalC2.Codex.Elicitation.response(params, "accept")["action"] != "accept" do
      Connection.respond(conn, id, {:ok, %{"action" => "decline"}})
      {:noreply, state}
    else
      native =
        if params["mode"] == "url",
          do: params["elicitationId"] || "request-#{id}",
          else: "mcp-elicitation:#{params["serverName"]}"

      %{app: app, options: options} = HalC2.Codex.Elicitation.describe(params)

      {state, request_id} =
        open_request(flush(state), native, "mcp-elicitation", params["message"])

      commit(state, fn stream ->
        [
          Orchestration.upsert(
            stream,
            "turn-item",
            "turn-item:approval:#{native}",
            &Map.merge(&1, %{"appName" => app, "options" => options})
          )
        ]
      end)

      request = {:elicitation, id, params}
      {:noreply, %{state | requests: Map.put(state.requests, request_id, request)}}
    end
  end

  # Other requests are not wired up yet; refuse rather than hang the turn.
  def handle_info({:json_rpc, conn, {:request, id, method, _params}}, state) do
    Connection.respond(
      conn,
      id,
      {:error, %{"code" => -32601, "message" => "Method not found: #{method}"}}
    )

    {:noreply, state}
  end

  def handle_info({:EXIT, conn, _reason}, %{conn: conn} = state) do
    state = %{state | conn: nil}
    state = if state.turn, do: end_turn(state, "failed", "Codex exited unexpectedly"), else: state
    # Its terminals went with it.
    state = end_background(state, "failed")
    # The native thread was loaded in that app-server; the next one resumes it.
    {:noreply, %{state | conn: nil, native_thread_id: nil}}
  end

  def handle_info({:interrupt_deadline, turn_id}, %{turn: %{native_turn_id: turn_id}} = state) do
    {:noreply, end_turn(state, "interrupted", nil)}
  end

  def handle_info({:interrupt_deadline, _turn_id}, state), do: {:noreply, state}

  # Output that is not a protocol message at all ends the session: the turn fails
  # rather than waits on a connection HAL-C2 can no longer read. A message that
  # decodes but is not one HAL-C2 knows is `{:invalid, decoded}` and is skipped.
  def handle_info({:json_rpc, conn, {:invalid, line}}, %{conn: conn} = state)
      when is_binary(line) do
    Process.unlink(conn)
    stop_conn(conn)
    state = %{state | conn: nil, native_thread_id: nil}

    state =
      if state.turn,
        do: end_turn(state, "failed", "Codex sent output that is not a protocol message"),
        else: state

    {:noreply, end_background(state, "failed")}
  end

  def handle_info(:flush, state), do: {:noreply, flush(%{state | flush_timer: nil}, :timer)}
  def handle_info(_other, state), do: {:noreply, state}

  # The app-server, and the terminals it runs, stop with this process: released when
  # idle, or stopped with its thread. Its writes may fail when the MC itself is
  # stopping; the next boot ends what is left (`HalC2.Orchestration.Recovery`).
  @impl true
  def terminate(_reason, state) do
    unless HalC2.Orchestration.Recovery.stopping?(),
      do: end_background(%{state | conn: nil}, "interrupted")

    :ok
  catch
    _, _ -> :ok
  end

  @impl true
  def code_change(_old, state, _extra) do
    # A runtime upgraded mid-turn derives the turn's instance, so the rest of
    # that turn's quota still belongs to it; between turns there is none yet
    # (the next quota update recovers the latest turn's from the thread —
    # `with_instance/1`, not here: the streams may be mid-upgrade too).
    # What is captured is resolved against settings once, as at turn start.
    instance =
      case state do
        %{instance: instance} when is_binary(instance) -> resolved_instance(instance)
        %{turn: %{ids: ids}} when is_map(ids) -> resolved_instance(Entities.instance(ids))
        _ -> nil
      end

    {:ok,
     state
     |> Map.put_new(:running, %{})
     |> Map.put_new(:background, %{})
     |> Map.put_new(:last_run, nil)
     |> Map.put_new(:workers_only, false)
     |> Map.put_new(:memory_threads, %{})
     |> Map.put_new(:final_first, nil)
     |> Map.put_new(:finals, %{})
     |> Map.put_new(:final_texts, %{})
     |> Map.put_new(:suppressed, %{})
     |> Map.put_new(:commentary, %{})
     |> Map.put_new(:persistent, %{})
     |> Map.put_new(:interrupting, nil)
     |> Map.put_new(:stopped, false)
     |> Map.put_new(:usage_failure, nil)
     |> Map.put(:instance, instance)
     |> Map.put_new(:conn_instance, :unknown)
     |> Map.put(:v, @state_version)}
  end

  # The message, with where its files are, and its images inline.
  defp codex_input(turn) do
    attachments = Map.get(turn, :attachments, [])
    text = HalC2.Attachments.prompt_text(turn.text, attachments)

    if(text == "", do: [], else: [%{"type" => "text", "text" => text}]) ++
      for {mime, data} <- HalC2.Attachments.native_images(attachments),
          do: %{"type" => "image", "url" => "data:#{mime};base64,#{data}"}
  end

  # A permissions request: file writes are a file change,
  # file reads a file read; anything else stays a plain permission.
  defp permissions_kind(%{"fileSystem" => %{} = fs}) do
    cond do
      (fs["write"] || []) != [] -> "file-change"
      (fs["read"] || []) != [] -> "file-read"
      true -> "permission"
    end
  end

  defp permissions_kind(_permissions), do: "permission"

  defp non_empty(value, default) when is_binary(value),
    do: if(String.trim(value) == "", do: default, else: String.trim(value))

  defp non_empty(_value, default), do: default

  # Codex takes each answered question's choices as strings.
  defp codex_answers(answers, question_ids) do
    for {id, value} <- answers, id in question_ids, into: %{} do
      values = if is_list(value), do: value, else: [value]
      {id, %{"answers" => for(v <- values, v != nil, do: to_string(v))}}
    end
  end

  defp text(value, default) when is_binary(value) do
    if String.trim(value) == "", do: default, else: String.trim(value)
  end

  defp text(_value, default), do: default

  # --- turn lifecycle -------------------------------------------------------------

  defp begin_turn(state, turn) do
    state = restart_session(state, turn)

    with {:ok, state} <- connect(state, turn),
         {:ok, state, turn} <- open_thread(state, turn),
         {:ok, state, turn} <- inject_history(state, turn),
         {:ok, native_turn} <- start_native_turn(state, turn) do
      at = Entities.now()
      ids = Map.put(turn.ids, :provider_turn, "provider-turn:codex:#{native_turn}")
      turn = %{turn | ids: ids} |> Map.put(:native_turn_id, native_turn)
      # As `started/1` does, with Codex's native turn and thread.
      TurnWatch.claim(state.thread_id, ids.run)

      commit_active(state, ids.run, fn stream ->
        [
          Orchestration.create(
            "provider-turn",
            ids.provider_turn,
            Entities.provider_turn(ids, native_turn, turn.run_ordinal, at)
          ),
          Orchestration.upsert(
            stream,
            "run-attempt",
            ids.attempt,
            &Map.merge(&1, %{
              "status" => "running",
              "providerTurnId" => ids.provider_turn,
              "startedAt" => at
            })
          ),
          Orchestration.upsert(
            stream,
            "run",
            ids.run,
            &Map.merge(&1, %{"status" => "running", "startedAt" => at})
          ),
          Orchestration.upsert(
            stream,
            "node",
            ids.root_node,
            &Map.merge(&1, %{"status" => "running", "providerTurnId" => ids.provider_turn})
          ),
          Orchestration.upsert(
            stream,
            "provider-thread",
            ids.provider_thread,
            &Map.merge(&1, %{
              "status" => "active",
              "nativeThreadRef" => Entities.provider_ref(state.native_thread_id),
              "updatedAt" => at
            })
          ),
          Orchestration.upsert(
            stream,
            "thread",
            ids.thread,
            &Map.put(&1, "activeProviderThreadId", ids.provider_thread)
          )
        ]
      end)
      |> case do
        :ok ->
          {:ok, %{state | turn: turn}}

        # The run ended while Codex started its turn: nothing wants the turn now.
        :ended ->
          Connection.call(state.conn, "turn/interrupt", %{
            "threadId" => state.native_thread_id,
            "turnId" => native_turn
          })

          {:ok, %{state | turn: nil}}
      end
    end
  end

  # Paginated threads (current Codex) cut history before a turn; legacy threads
  # only take a count of turns to drop.
  defp rewind(state, plan) do
    thread = state.native_thread_id

    with {:error, _} <-
           if(plan.first_dropped,
             do:
               Connection.call(state.conn, "thread/revert", %{
                 "threadId" => thread,
                 "beforeTurnId" => plan.first_dropped
               }),
             else: {:error, :no_turn_id}
           ),
         do:
           Connection.call(state.conn, "thread/rollback", %{
             "threadId" => thread,
             "numTurns" => plan.drop
           })
  end

  # An approval's reason when Codex gave one, else what it wants to do.
  defp reason_or(params, fallback) do
    case params["reason"] do
      reason when is_binary(reason) -> if String.trim(reason) == "", do: fallback, else: reason
      _ -> fallback
    end
  end

  # What a file-change approval is for when Codex gives no reason: each file with
  # what would be done to it (the first 20, the rest counted), or the folder it
  # wants to write under (`codexFileChangeApprovalPrompt`).
  defp file_change_prompt(params) do
    case reason_or(params, nil) do
      reason when is_binary(reason) ->
        reason

      _ ->
        entries =
          (params["fileChanges"] || %{})
          |> Enum.sort_by(fn {path, _change} -> path end)

        cond do
          entries != [] ->
            described =
              for {path, change} <- Enum.take(entries, 20) do
                move = if change["type"] == "update", do: change["move_path"]

                if move,
                  do: "#{change["type"]} #{path} -> #{move}",
                  else: "#{change["type"]} #{path}"
              end

            remaining = length(entries) - length(described)
            lines = Enum.join(described, "\n")
            if remaining > 0, do: "#{lines}\n+#{remaining} more", else: lines

          is_binary(params["grantRoot"]) and String.trim(params["grantRoot"]) != "" ->
            String.trim(params["grantRoot"])

          true ->
            nil
        end
    end
  end

  # The text of a Codex user message item, from its content parts.
  defp user_message_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      _ -> ""
    end)
    |> Enum.join("")
  end

  defp user_message_text(_content), do: ""

  # Codex's `spawnAgent` tool: each thread it starts is a subagent of this turn.

  # A persistent tool call that ends after its turn: its item, kept running since,
  # finishes with what the call came back with.
  defp persistent_done(state, native, item) do
    {handle, persistent} = Map.pop(state.persistent, native)
    fields = tool_fields(item)
    status = if item["status"] == "failed", do: "failed", else: "completed"

    state = %{state | persistent: persistent, items: Map.put(state.items, native, handle)}
    state = finish_item(state, native, status, &Map.merge(&1, fields))
    %{state | items: Map.delete(state.items, native)}
  end

  # Codex's fuller explanation when it gives one, else its short message.
  defp error_text(error) do
    case String.trim(error["additionalDetails"] || "") do
      "" -> error["message"] || "Codex reported an error"
      details -> details
    end
  end

  # A change the session cannot take in place (runtime mode, workspace, or
  # another account of the same home) restarts the app-server and resumes
  # the same native conversation on it; a model or options change and an
  # interaction-mode change are turn-scoped and keep the process
  # (`HalC2.Orchestration.SessionTransition`).
  defp restart_session(state, turn) do
    snapshot = session_snapshot(turn)

    # Another instance's app-server is `connect/2`'s to replace: it settles
    # what the old one left before it stops.
    restart? =
      HalC2.Orchestration.SessionTransition.decide(
        state[:session_snapshot],
        snapshot,
        true
      ) == :restart_and_resume and
        get_in(state[:session_snapshot] || %{}, [:selection, "instanceId"]) ==
          snapshot.selection["instanceId"]

    state = Map.put(state, :session_snapshot, snapshot)

    if restart? and state.conn != nil do
      Process.unlink(state.conn)
      stop_conn(state.conn)
      %{state | conn: nil, conn_instance: nil, native_thread_id: nil}
    else
      state
    end
  end

  defp session_snapshot(turn) do
    instance = Entities.instance(turn.ids)

    %{
      driver: "codex",
      continuation: HalC2.Orchestration.SessionTransition.continuation("codex", instance),
      selection: %{
        "instanceId" => instance,
        "model" => turn.model,
        "options" =>
          Enum.map(turn.options || %{}, fn {id, value} -> %{"id" => id, "value" => value} end)
      },
      runtime_mode: turn.runtime_mode,
      workspace: turn.cwd
    }
  end

  # Codex takes a handed-over conversation as history of its own thread
  # (`thread/inject_items`), so the message it receives holds only what the
  # user wrote. A Codex too old for that says so before changing anything
  # (-32601), and the history rides in front of the message instead, as it
  # was already put there. Any other failure may or may not have landed:
  # the delivery stays pending, the turn fails, and the next run starts a
  # new conversation rather than risk sending the history twice or never.
  defp inject_history(state, turn) do
    if turn[:history], do: do_inject_history(state, turn), else: {:ok, state, turn}
  end

  defp do_inject_history(state, turn) do
    items =
      [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => turn.history.context}]
        }
      ] ++
        Enum.map(turn.history.messages, fn message ->
          %{
            "type" => "message",
            "role" => message["role"],
            "content" => [
              %{
                "type" => if(message["role"] == "user", do: "input_text", else: "output_text"),
                "text" => HalC2.Orchestration.Handoff.render_historical(message)
              }
            ]
          }
        end)

    settle_delivery(state, turn, "pending")

    case Connection.call(state.conn, "thread/inject_items", %{
           "threadId" => state.native_thread_id,
           "items" => items
         }) do
      {:ok, _} ->
        settle_delivery(state, turn, "injected")
        {:ok, state, %{turn | text: turn.user_text}}

      {:error, %{"code" => -32601}} ->
        settle_delivery(state, turn, "inline")
        {:ok, state, turn}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # The delivery is settled before the injection is attempted and after it
  # lands, so one the MC cannot account for stays visibly pending.
  defp settle_delivery(state, turn, status) do
    at = Entities.now()
    handoff_id = turn.history.handoff_id

    commit(state, fn stream ->
      [
        Orchestration.upsert(stream, "context-handoff", handoff_id, fn entity ->
          if entity do
            Map.merge(entity, %{
              "updatedAt" => at,
              "delivery" => %{
                "nativeThreadId" => state.native_thread_id,
                "status" => status,
                "itemIds" => Enum.map(turn.history.messages, & &1["itemId"])
              }
            })
          end
        end)
      ]
      |> Enum.reject(&is_nil/1)
    end)

    :ok
  end

  # The end of a turn let go of before it started (`begin_turn/2`).

  defp rpc_message(%{"message" => message}) when is_binary(message), do: message
  defp rpc_message(reason), do: inspect(reason)

  defp connect(%{conn: nil} = state, %{ids: ids} = turn) do
    instance = Entities.instance(ids)

    cmd =
      HalC2.Settings.instance_command(
        instance,
        Application.get_env(:hal_c2, :codex_command, ["codex", "app-server"])
      )

    # The instance's variables in settings (such as CODEX_HOME) reach Codex, over the
    # home its settings name (`HalC2.Codex.Home`).
    env = Enum.to_list(HalC2.Settings.instance_env(instance))

    with {:ok, args} <- launch_args(instance),
         {:ok, home} <- home_env(instance),
         env = home ++ env,
         {:ok, conn} <-
           Connection.start_link(
             cmd: cmd ++ args,
             handler: self(),
             cd: turn.cwd,
             env: env,
             log: turn.ids.thread,
             program: "Codex App Server"
           ),
         {:ok, _} <-
           Connection.call(conn, "initialize", %{
             "clientInfo" => %{
               "name" => "hal_c2_desktop",
               "title" => "HAL-C2 Desktop",
               "version" => "0.1.0"
             },
             "capabilities" => %{
               "experimentalApi" => true,
               "optOutNotificationMethods" => ["turn/diff/updated"]
             }
           }) do
      Connection.notify(conn, "initialized", nil)
      {:ok, %{state | conn: conn, conn_instance: instance}}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # The app-server runs with its instance's command, variables and home, so a turn on
  # another instance of Codex needs its own: the open one, and the commands it left
  # running, stop, and the turn opens the thread it has there. One whose instance is
  # not known (started before a hot update) may run as another account, so it is
  # replaced too.
  defp connect(state, %{ids: ids} = turn) do
    if state.conn_instance == Entities.instance(ids) do
      {:ok, state}
    else
      # Pending requests are a turn's: every request handler needs a running
      # turn and `end_turn/3` cancels and clears them, so none is live here.
      # Settle any that somehow remain anyway — their rpc ids belong to the
      # app-server being stopped, never to the new instance's.
      state =
        Enum.reduce(Map.keys(state.requests), state, &resolve_request(&2, &1, nil, "cancelled"))

      state = end_background(%{state | requests: %{}}, "interrupted")
      Process.unlink(state.conn)
      stop_conn(state.conn)
      connect(%{state | conn: nil, native_thread_id: nil}, turn)
    end
  end

  # An app-server that has just exited (its `:EXIT` not handled yet) is already stopped.
  defp stop_conn(conn) do
    Connection.stop(conn)
  catch
    :exit, _ -> :ok
  end

  # The instance's launch arguments follow `app-server`.
  defp launch_args(instance), do: HalC2.Codex.Provider.launch_args(instance)

  # A shadow home that cannot be made fails the turn before Codex starts: running
  # against the shared home instead would sign the turn in as another account.
  defp home_env(instance) do
    case HalC2.Codex.Home.env(instance) do
      {:ok, env} ->
        {:ok, env}

      {:error, reason} ->
        Logger.warning("codex shadow home not prepared: #{reason}")
        {:error, "Failed to materialize the Codex shadow home."}
    end
  end

  # A session carried from another machine that this Codex cannot open (a newer
  # Codex wrote it, say) starts a new thread with the handoff instead, and the user
  # is told.
  defp open_thread(state, %{fork: %{carried: true} = fork} = turn) do
    case ensure_native_thread(state, turn) do
      {:ok, state} ->
        {:ok, state, turn}

      {:error, reason, state} ->
        turn = %{
          turn
          | fork: nil,
            text: HalC2.Orchestration.Handoff.prompt(fork[:fallback], turn.text)
        }

        with {:ok, state} <- ensure_native_thread(state, turn) do
          not_carried(state, turn, rpc_message(reason))
          {:ok, state, turn}
        end
    end
  end

  defp open_thread(state, turn) do
    with {:ok, state} <- ensure_native_thread(state, turn), do: {:ok, state, turn}
  end

  defp not_carried(state, turn, reason) do
    at = Entities.now()
    id = "turn-item:codex:session-not-carried:#{turn.ids.run}"

    message =
      "Codex on #{HalC2.ThreadArchive.label()} could not continue its own session (#{reason}), so it started a new one with a summary of the conversation."

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

  # A live native thread keeps its session while its MCP credential still
  # matches the access settings; a flip resumes it with fresh config below,
  # so its tool calls never carry a rotated-away token.
  defp ensure_native_thread(%{native_thread_id: id} = state, turn) when is_binary(id) do
    if HalC2.Mcp.prepared?(state.thread_id, Entities.instance(turn.ids)) do
      {:ok, state}
    else
      ensure_native_thread(%{state | native_thread_id: nil}, turn)
    end
  end

  # A fork's first turn starts from a copy of the source thread, cut after its turn;
  # a session carried from another machine is forked whole from its rollout's path.
  defp ensure_native_thread(state, %{fork: %{thread: source, turn: last} = fork} = turn) do
    state = workers_only(state, turn)

    params =
      thread_params(state, turn)
      |> Map.put("threadId", source)
      |> then(&if(last, do: Map.put(&1, "lastTurnId", last), else: &1))
      |> then(&if(fork[:path], do: Map.put(&1, "path", fork[:path]), else: &1))

    case Connection.call(state.conn, "thread/fork", params) do
      {:ok, %{"thread" => %{"id" => id}}} -> {:ok, %{state | native_thread_id: id}}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp ensure_native_thread(state, turn) do
    state = workers_only(state, turn)
    params = thread_params(state, turn)

    result =
      if turn.native_thread_id,
        do:
          Connection.call(
            state.conn,
            "thread/resume",
            Map.merge(params, %{"threadId" => turn.native_thread_id, "excludeTurns" => true})
          ),
        else: Connection.call(state.conn, "thread/start", params)

    case result do
      {:ok, %{"thread" => %{"id" => id}}} ->
        {:ok, %{state | native_thread_id: id}}

      # A conversation Codex can no longer find (its rollout was cleaned up, say)
      # starts fresh: HAL-C2 keeps the thread's history, Codex a new conversation.
      {:error, reason} when turn.native_thread_id != nil ->
        if recoverable_resume?(reason) do
          case Connection.call(state.conn, "thread/start", params) do
            {:ok, %{"thread" => %{"id" => id}}} -> {:ok, %{state | native_thread_id: id}}
            {:error, reason} -> {:error, reason, state}
          end
        else
          {:error, reason, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # The wordings with which Codex says a thread is gone (`CodexSessionRuntime.ts`
  # `isRecoverableThreadResumeError`).
  @recoverable_resume [
    "not found",
    "missing thread",
    "no such thread",
    "unknown thread",
    "does not exist",
    "no rollout found"
  ]
  defp recoverable_resume?(reason) do
    message = reason |> rpc_message() |> String.downcase()
    Enum.any?(@recoverable_resume, &String.contains?(message, &1))
  end

  # The thread's settings, with HAL-C2's own MCP server for the agent when allowed.
  defp thread_params(state, turn) do
    params = %{"cwd" => turn.cwd, "model" => turn.model}

    case config(state, turn) do
      config when config == %{} -> params
      config -> Map.put(params, "config", config)
    end
  end

  # Codex's own config for the thread: HAL-C2's MCP server when allowed, and its
  # subagent tools off when the user keeps agents to HAL-C2's workers (`nativeSubagents`).
  defp config(state, turn) do
    mcp =
      case mcp(state, turn) do
        nil ->
          %{}

        mcp ->
          %{
            "mcp_servers" => %{
              "hal-c2" => %{
                "url" => mcp.url,
                "tool_timeout_sec" => div(HalC2.Mcp.tool_timeout_ms(), 1000),
                "http_headers" => %{"Authorization" => mcp.authorization}
              }
            }
          }
      end

    if state.workers_only,
      do: Map.put(mcp, "features", %{"multi_agent" => false, "multi_agent_v2" => false}),
      else: mcp
  end

  # Codex takes `features` only when a native thread starts, so the choice is read then
  # and kept for the thread's turns.
  defp workers_only(state, turn),
    do: %{state | workers_only: HalC2.Mcp.workers_only?(mcp(state, turn))}

  defp mcp(state, turn), do: HalC2.Mcp.for_agent(state.thread_id, Entities.instance(turn.ids))

  defp start_native_turn(state, turn) do
    {approval, reviewer, sandbox} =
      Map.get(@runtime_policies, turn.runtime_mode, @runtime_policies["full-access"])

    params = %{
      "threadId" => state.native_thread_id,
      "input" => codex_input(turn),
      "cwd" => turn.cwd,
      "model" => turn.model,
      "approvalPolicy" => approval,
      "approvalsReviewer" => reviewer,
      "sandboxPolicy" => %{"type" => sandbox},
      "summary" => "detailed",
      # Always explicit: Codex keeps the last collaboration mode on a resumed thread.
      "collaborationMode" => %{
        "mode" => if(Map.get(turn, :interaction_mode) == "plan", do: "plan", else: "default"),
        # A read, never a preparation: rotating here would strand the
        # header this thread's config already carries. HAL-C2's orchestration
        # instructions steer the agent to work, so a plan turn — which must not
        # do the work — does not get them.
        "settings" =>
          if(
            HalC2.Mcp.current(state.thread_id, Entities.instance(turn.ids)) &&
              Map.get(turn, :interaction_mode) != "plan",
            do: %{
              "model" => turn.model,
              "developer_instructions" =>
                HalC2.Mcp.Instructions.for_session(
                  # The sections follow what this thread's credential may
                  # reach, as an ACP session's do, never tools it lacks.
                  capabilities:
                    HalC2.Mcp.capabilities(state.thread_id, Entities.instance(turn.ids)) ||
                      HalC2.Mcp.agent_access(state.thread_id),
                  runtime: %{
                    harness: "Codex",
                    model: turn.model,
                    effort: Map.get(turn, :options, %{})["reasoningEffort"]
                  }
                ) <> if(state.workers_only, do: HalC2.Mcp.workers_only_note(), else: "")
            },
            else: %{"model" => turn.model}
          )
      }
    }

    params = Map.merge(params, selected_options(Map.get(turn, :options, %{})))

    case Connection.call(state.conn, "turn/start", params) do
      {:ok, %{"turn" => %{"id" => id}}} -> {:ok, id}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # --- notifications ----------------------------------------------------------

  # Quota comes alongside token usage, mostly unchanged; it merges onto the turn's own
  # instance entry, so one account never overwrites another's quota.
  # The merged snapshot is kept to name the used-up window when a turn stops on it.
  defp notification("account/rateLimits/updated", %{"rateLimits" => snapshot}, state) do
    state = with_instance(state)

    HalC2.ProviderUsageLimits.update(
      state.instance,
      HalC2.ProviderUsageLimits.Codex.windows(snapshot)
    )

    state =
      if snapshot["limitId"] in [nil, "codex"],
        do:
          Map.put(state, :rate_limits, Map.merge(Map.get(state, :rate_limits) || %{}, snapshot)),
        else: state

    # A turn that stopped on a limit before Codex named its reset learns it from
    # this report; a reset already named does not move.
    case Map.get(state, :usage_failure) do
      %{item: item_id} ->
        snapshot = Map.get(state, :rate_limits) || snapshot
        at = DateTime.utc_now()

        case usage_limit_reset(snapshot, at) do
          nil ->
            state

          reset ->
            message = usage_limit_message(snapshot, at)

            commit(state, fn stream ->
              [
                Orchestration.upsert(stream, "turn-item", item_id, fn item ->
                  failure =
                    Map.merge(item["failure"] || %{}, %{
                      "message" => message,
                      "resetAt" => reset
                    })

                  Map.put(item, "failure", failure)
                end)
              ]
            end)

            Map.put(state, :usage_failure, nil)
        end

      _ ->
        state
    end
  end

  # A background command ended, between turns or during a later one. Its output
  # meanwhile is not streamed: the end carries it whole.
  defp notification("item/completed", %{"item" => %{"id" => native} = item}, state)
       when is_map_key(state.background, native),
       do: background_done(state, native, item)

  defp notification("item/commandExecution/outputDelta", %{"itemId" => native}, state)
       when is_map_key(state.background, native),
       do: state

  # A persistent tool call ending after its turn: its item ends with it.
  defp notification("item/completed", %{"item" => %{"id" => native} = item}, state)
       when is_map_key(state.persistent, native) and not is_map_key(state.items, native),
       do: persistent_done(state, native, item)

  # Codex consolidating its memories runs a thread of its own in the background:
  # none of its work is this thread's, and none of it is shown.
  defp notification("thread/started", %{"thread" => thread}, state) do
    source = thread["source"] || %{}

    if thread["threadSource"] == "memory_consolidation" or
         source["subAgent"] == "memory_consolidation" do
      %{state | memory_threads: Map.put(state.memory_threads, thread["id"], true)}
    else
      state
    end
  end

  defp notification("thread/closed", %{"threadId" => thread}, state)
       when is_map_key(state.memory_threads, thread) do
    %{state | memory_threads: Map.delete(state.memory_threads, thread)}
  end

  defp notification(_method, %{"threadId" => thread}, state)
       when is_map_key(state.memory_threads, thread),
       do: state

  # A subagent starting work under a turn the user stopped is interrupted at once.
  defp notification(
         "turn/started",
         %{"threadId" => thread, "turn" => %{"id" => turn_id}},
         %{turn: nil, stopped: true, subagents: subagents} = state
       )
       when is_map_key(subagents, thread) do
    Connection.call(state.conn, "turn/interrupt", %{"threadId" => thread, "turnId" => turn_id})
    entry = subagents[thread]

    sub = HalC2.Orchestration.NativeSubagent.finish(entry.sub, "interrupted", entry[:final])
    entry = %{entry | sub: sub, done: true}

    %{state | subagents: Map.put(subagents, thread, entry)}
  end

  defp notification(_method, _params, %{turn: nil} = state), do: state

  # A subagent's own thread reports under its thread id: its answer goes to its child
  # thread, and nothing it says (its `turn/completed` least of all) is this turn's.
  defp notification(method, %{"threadId" => thread} = params, %{subagents: subagents} = state)
       when is_map_key(subagents, thread) do
    entry =
      subagents[thread]
      |> Map.put_new(:final, nil)
      |> Map.put(
        :turn_id,
        params["turnId"] || get_in(params, ["turn", "id"]) || subagents[thread][:turn_id]
      )

    entry =
      case {method, params} do
        {"item/agentMessage/delta", %{"delta" => delta}} when is_binary(delta) ->
          %{entry | sub: HalC2.Orchestration.NativeSubagent.append(entry.sub, delta)}

        # A message Codex sends a subagent that finished its first task: the
        # subagent runs again, with the message in its thread from its parent.
        {"item/completed", %{"item" => %{"type" => "userMessage"} = item}} when entry.done ->
          text = user_message_text(item["content"])

          entity =
            HalC2.StreamState.get(HalC2.Streams.state(state.thread_id), "subagent")[entry.sub.id]

          if text != "" and entity do
            sub = HalC2.Orchestration.NativeSubagent.resume(state.turn.ids, entity, text)
            %{entry | sub: sub, done: false, final: nil}
          else
            entry
          end

        {"item/completed", %{"item" => %{"type" => "agentMessage", "text" => text} = item}}
        when is_binary(text) ->
          entry =
            if item["phase"] == "commentary", do: entry, else: %{entry | final: text}

          if entry.sub.text == "" do
            %{entry | sub: HalC2.Orchestration.NativeSubagent.append(entry.sub, text)}
          else
            entry
          end

        _ ->
          entry
      end

    %{state | subagents: Map.put(subagents, thread, entry)}
  end

  defp notification(
         "item/" <> event,
         %{"item" => %{"type" => "collabAgentToolCall"} = item},
         state
       )
       when event in ["started", "completed"] do
    state |> flush() |> spawned(item) |> subagent_states(item)
  end

  # Another turn's item that is not running any more (a command stopped with its
  # turn, say) is not this turn's.
  defp notification(
         "item/" <> _,
         %{"threadId" => thread, "turnId" => turn_id},
         %{native_thread_id: thread, turn: %{native_turn_id: current}} = state
       )
       when turn_id != current,
       do: state

  # A turn's first final answer streams as it comes; a later one is held back
  # until it finishes, when a repeat of an earlier answer (or an empty one) is
  # dropped instead of shown twice.
  defp notification(
         "item/started",
         %{"item" => %{"type" => "agentMessage", "id" => native} = item},
         state
       ) do
    case item["phase"] do
      "commentary" ->
        state
        |> Map.put(:commentary, Map.put(state.commentary, native, true))
        |> ensure_item(native, :assistant)

      "final_answer" ->
        state = Map.put(state, :finals, Map.put(state.finals, native, true))

        if state.final_first in [nil, native] do
          state |> Map.put(:final_first, native) |> ensure_item(native, :assistant)
        else
          Map.put(state, :suppressed, Map.put(state.suppressed, native, true))
        end

      _ ->
        ensure_item(state, native, :assistant)
    end
  end

  defp notification("item/started", %{"item" => %{"type" => "commandExecution"} = item}, state) do
    state
    |> ensure_item(item["id"], :command, %{"input" => item["command"] || "", "output" => ""})
    |> then(&%{&1 | running: Map.put(&1.running, item["id"], item["processId"])})
  end

  # Plan mode's proposed plan streams as its own item.
  defp notification("item/started", %{"item" => %{"type" => "plan", "id" => native}}, state),
    do: ensure_item(state, native, :plan)

  defp notification(
         "item/started",
         %{"item" => %{"type" => "webSearch", "id" => native} = item},
         state
       ),
       do: ensure_item(state, native, :web, %{"patterns" => web_patterns(item)})

  defp notification("item/started", %{"item" => %{"type" => type, "id" => native} = item}, state)
       when type in ["mcpToolCall", "dynamicToolCall"] do
    state = ensure_item(state, native, :tool, tool_fields(item))

    if type == "dynamicToolCall" and get_in(item, ["arguments", "persistent"]) == true do
      Map.put(state, :persistent, Map.put(state.persistent, native, state.items[native]))
    else
      state
    end
  end

  defp notification("item/plan/delta", %{"itemId" => native, "delta" => delta}, state),
    do: state |> ensure_item(native, :plan) |> buffer(native, "markdown", delta)

  # The agent's own todo list for the turn.
  defp notification("turn/plan/updated", %{"plan" => plan} = params, state) when is_list(plan) do
    steps =
      for {step, index} <- Enum.with_index(plan, 1) do
        %{
          "id" => "step-#{index}",
          "text" => non_empty(step["step"], "Step #{index}"),
          "status" =>
            case step["status"] do
              "completed" -> "completed"
              "inProgress" -> "running"
              _ -> "pending"
            end
        }
      end

    explanation =
      if is_binary(params["explanation"]) and params["explanation"] != "",
        do: params["explanation"]

    write_todo(state, "turn-plan:#{params["turnId"]}", steps, explanation)
  end

  defp notification(
         "item/agentMessage/delta",
         %{"itemId" => native, "delta" => delta},
         state
       ) do
    if state.suppressed[native],
      do: state,
      else: state |> ensure_item(native, :assistant) |> buffer(native, "text", delta)
  end

  defp notification("item/reasoning/" <> _, %{"itemId" => native, "delta" => delta}, state),
    do: state |> ensure_item(native, :reasoning) |> buffer(native, "text", delta)

  defp notification(
         "item/commandExecution/outputDelta",
         %{"itemId" => native, "delta" => delta},
         state
       ),
       do:
         state
         |> ensure_item(native, :command, %{"input" => "", "output" => ""})
         |> buffer(native, "output", delta)

  # A question Codex asks without waiting for the answer (`delivery: "async"`): there
  # is no call to answer, so the user's answer goes back as a message
  # (`HalC2.Orchestration`'s `runtime-request.respond`).
  defp notification(
         "item/completed",
         %{
           "item" =>
             %{"type" => "agentMessage", "delivery" => "async", "questions" => [_ | _] = asked} =
               item
         },
         state
       ) do
    questions =
      for {question, index} <- Enum.with_index(asked) do
        %{
          "id" => Integer.to_string(index),
          "header" => "Question",
          "question" => text(question["title"], "Choose an answer."),
          "options" =>
            for(
              label <- question["options"] || [],
              is_binary(label),
              do: %{"label" => label, "description" => ""}
            )
        }
      end

    {state, _request_id} = open_async_question(flush(state), "async:#{item["id"]}", questions)
    state
  end

  defp notification("item/completed", %{"item" => item}, state),
    do: complete_item(flush(state), item)

  # How full the conversation's context is, for the context meter. It belongs to the
  # provider thread, so it outlives the run, and a model change, until Codex says more.
  defp notification(
         "thread/tokenUsage/updated",
         %{"tokenUsage" => %{"last" => %{"totalTokens" => used} = last} = usage},
         state
       )
       when is_integer(used) do
    counts =
      for {key, field} <- [
            {"inputTokens", "inputTokens"},
            {"cachedInputTokens", "cachedInputTokens"},
            {"outputTokens", "outputTokens"},
            {"reasoningOutputTokens", "reasoningOutputTokens"}
          ],
          is_integer(last[field]),
          into: %{"usedTokens" => max(used, 0)},
          do: {key, max(last[field], 0)}

    window = usage["modelContextWindow"]

    snapshot =
      if is_integer(window) and window > 0, do: Map.put(counts, "maxTokens", window), else: counts

    commit(state, fn stream ->
      [
        Orchestration.upsert(
          stream,
          "provider-thread",
          state.turn.ids.provider_thread,
          &Map.put(&1, "contextUsage", snapshot)
        )
      ]
    end)

    state
  end

  defp notification("error", %{"error" => error} = params, state) do
    cond do
      params["willRetry"] == true ->
        retry_item(state, error)

      # A structured `usage_limit` failure, as Claude's: the thread reads its error class
      # and reset from it, and its queue waits (`TurnWriter.finish/3`).
      error_code(error["codexErrorInfo"]) in ["usageLimitExceeded", "rateLimitExceeded"] ->
        snapshot = Map.get(state, :rate_limits)
        at = DateTime.utc_now()

        failure = %{
          "class" => "usage_limit",
          "message" => usage_limit_message(snapshot, at),
          "code" => error_code(error["codexErrorInfo"]),
          "retryable" => nil,
          "resetAt" => usage_limit_reset(snapshot, at)
        }

        %{state | failure: failure}

      true ->
        %{state | failure: error_text(error)}
    end
  end

  defp notification(
         "turn/completed",
         %{"turn" => %{"id" => id}},
         %{turn: %{native_turn_id: own}} = state
       )
       when is_binary(own) and id != own,
       do: state

  defp notification("turn/completed", %{"turn" => turn}, state) do
    status =
      if turn["status"] in ["completed", "interrupted", "failed"],
        do: turn["status"],
        else: "failed"

    # A turn that finishes while it is being stopped was stopped: Codex reporting
    # it completed a moment before it acknowledges the stop does not unstop it.
    status =
      if status == "completed" and Map.get(state, :interrupting) == turn["id"],
        do: "interrupted",
        else: status

    end_turn(
      state,
      status,
      state.failure || if(turn["error"], do: error_text(turn["error"]))
    )
  end

  defp notification(_method, _params, state), do: state

  # The instance quota is published under, resolved once: a turn's own
  # instance when settings here know it, or the driver when they do not (a
  # thread carried from another machine, say — such a turn physically ran
  # under the built-in configuration).
  defp resolved_instance(instance),
    do: if(HalC2.Settings.known_instance?(instance, "codex"), do: instance, else: "codex")

  # Fills in the latest turn's instance from the thread when this runtime
  # has captured none (it started, or was upgraded, between turns), so a
  # late update from the still-connected app-server joins that turn's
  # instance. Resolved once, here, and kept from then on.
  defp with_instance(state) do
    case Map.get(state, :instance) do
      instance when is_binary(instance) ->
        state

      _ ->
        Map.put(state, :instance, resolved_instance(latest_run_instance(state)))
    end
  end

  defp latest_run_instance(state) do
    case Map.get(state, :thread_id) do
      thread_id when is_binary(thread_id) ->
        run =
          thread_id
          |> HalC2.Streams.state()
          |> HalC2.StreamState.list("run")
          |> Enum.max_by(& &1["ordinal"], fn -> nil end)

        if run, do: run["providerInstanceId"]

      _ ->
        nil
    end
  end

  # Codex retries a failed request itself and reports each attempt: one work-log item
  # per turn (`terminal-failure:<provider turn>`), updated by every attempt and closed
  # with the turn. The attempt comes from Codex's own "2/5" when the message has one.
  defp retry_item(state, error) do
    native = "terminal-failure:#{state.turn.ids.provider_turn}"
    message = error["message"] || "Codex is retrying a failed request"
    code = error_code(error["codexErrorInfo"])

    failure = %{
      "class" =>
        cond do
          code in ["usageLimitExceeded", "rateLimitExceeded"] -> "usage_limit"
          String.starts_with?(code || "", ["http", "responseStream"]) -> "transport_error"
          true -> "provider_error"
        end,
      "message" =>
        case String.trim(error["additionalDetails"] || "") do
          "" -> message
          details -> details
        end,
      "code" => code,
      "retryable" => true
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
          previous = item["retry"] || %{}

          retry =
            case Regex.run(~r/\b([1-9]\d*)\s*\/\s*([1-9]\d*)\b/, message) do
              [_, attempt, max] ->
                %{
                  "attempt" => String.to_integer(attempt),
                  "maxAttempts" => String.to_integer(max)
                }

              nil ->
                %{
                  "attempt" => (previous["attempt"] || 0) + 1,
                  "maxAttempts" => previous["maxAttempts"]
                }
            end

          Map.merge(item, %{
            "failure" => failure,
            "retry" => Map.put(retry, "retryDelayMs", nil),
            "updatedAt" => at
          })
        end)
      ]
    end)

    state
  end

  defp end_turn(state, status, failure) do
    state = flush(state)

    state =
      Enum.reduce(Map.keys(state.requests), state, &resolve_request(&2, &1, nil, "cancelled"))

    # A completed turn's commands still running go on in the background; an
    # interrupted or failed turn stops them, and an interrupt everything else too.
    # Other items the provider left running end with the turn, as with Claude and ACP.
    state =
      case status do
        "completed" ->
          state |> to_background() |> to_persistent()

        _ ->
          for {_native, process} <- state.running, do: terminate_terminal(state, process)

          state = %{
            state
            | running: %{},
              persistent: Map.drop(Map.get(state, :persistent, %{}), Map.keys(state.items))
          }

          if status == "interrupted", do: end_background(state, status), else: state
      end

    # The turn's subagents end with an interrupted or failed turn; a completed
    # turn's were settled by Codex's own reports of them.
    state =
      if status in ["interrupted", "failed"] do
        subagents =
          for {thread, entry} <- Map.get(state, :subagents, %{}), into: %{} do
            if entry.done do
              {thread, entry}
            else
              sub = HalC2.Orchestration.NativeSubagent.finish(entry.sub, status, entry[:final])
              {thread, %{entry | sub: sub, done: true}}
            end
          end

        Map.put(state, :subagents, subagents)
      else
        state
      end

    # A usage-limit stop whose reset Codex had not named learns it from a later
    # report (`notification("account/rateLimits/updated", ...)`).
    state =
      case failure do
        %{"class" => "usage_limit", "resetAt" => nil} ->
          item =
            HalC2.Orchestration.TurnWriter.item_id(
              state.turn.ids,
              "terminal-failure:#{Map.get(state.turn.ids, :provider_turn, state.turn.ids.run)}"
            )

          Map.put(state, :usage_failure, %{item: item})

        _ ->
          state
      end

    state = close_open_items(state, status)
    finish(state, status, failure)
    %{state | turn: nil, items: %{}, requests: %{}, interrupting: nil}
  end

  # Tool calls Codex marked persistent outlive a completed turn: they leave its
  # items, so its end does not close them, and their own end finishes them later.
  defp to_persistent(state) do
    persistent = Map.get(state, :persistent, %{})
    %{state | items: Map.drop(state.items, Map.keys(persistent))}
  end

  # The model options the user picked: reasoning effort and service tier.
  defp selected_options(options) do
    tier =
      options["serviceTier"] || if(options["fastMode"] == true, do: "fast")

    %{}
    |> then(
      &if is_binary(options["reasoningEffort"]),
        do: Map.put(&1, "effort", options["reasoningEffort"]),
        else: &1
    )
    |> then(&if is_binary(tier), do: Map.put(&1, "serviceTier", tier), else: &1)
  end

  defp error_code(code) when is_binary(code), do: code
  defp error_code(%{} = info) when map_size(info) > 0, do: info |> Map.keys() |> hd()
  defp error_code(_), do: nil

  # Instead of Codex's own sentence (which on a workspace blames credits for a window
  # that simply ran out): the used-up window resetting last, and what to do next.
  defp usage_limit_message(snapshot, at) do
    reset =
      case used_up_window(snapshot, at) do
        {wait, kind, _resets} -> " The #{kind} limit resets in #{wait_text(wait)}."
        nil -> ""
      end

    next =
      case (snapshot || %{})["rateLimitReachedType"] do
        type
        when type in ["workspace_owner_credits_depleted", "workspace_member_credits_depleted"] ->
          " The workspace has no credits to continue sooner: ask your workspace owner to add " <>
            "credits, or send the message again once the limit resets."

        type
        when type in [
               "workspace_owner_usage_limit_reached",
               "workspace_member_usage_limit_reached"
             ] ->
          " The workspace spend limit is reached: ask your workspace owner to raise it, or " <>
            "send the message again once the limit resets."

        _ ->
          " Send the message again once the limit resets."
      end

    "Codex usage limit reached." <> reset <> next
  end

  # When the used-up window resetting last resets (ISO), or nil when Codex did not say.
  defp usage_limit_reset(snapshot, at) do
    case used_up_window(snapshot, at) do
      {_wait, _kind, resets} -> resets
      nil -> nil
    end
  end

  # The used-up window that resets last: `{ms to wait, kind, resetsAt}`.
  defp used_up_window(snapshot, at) do
    (snapshot || %{})
    |> HalC2.ProviderUsageLimits.Codex.windows()
    |> Enum.flat_map(fn window ->
      with true <- window["usedPercent"] >= 100,
           {:ok, resets, _} <- DateTime.from_iso8601(window["resetsAt"] || ""),
           wait when wait > 0 <- DateTime.diff(resets, at, :millisecond),
           do: [{wait, window["kind"], window["resetsAt"]}],
           else: (_ -> [])
    end)
    |> Enum.max_by(&elem(&1, 0), fn -> nil end)
  end

  # Coarse remaining wait, as the usage rows read: `5d 5h`, `3h 20m`, `12m`.
  defp wait_text(ms) do
    total = div(ms + 59_999, 60_000)
    {days, hours, minutes} = {div(total, 1440), div(rem(total, 1440), 60), rem(total, 60)}

    cond do
      days > 0 and hours == 0 -> "#{days}d"
      days > 0 -> "#{days}d #{hours}h"
      hours == 0 -> "#{total}m"
      minutes == 0 -> "#{hours}h"
      true -> "#{hours}h #{minutes}m"
    end
  end

  defp command_status(%{"status" => "failed"}), do: "failed"
  defp command_status(%{"status" => "declined"}), do: "cancelled"
  defp command_status(_item), do: "completed"

  defp command_result(entity, item) do
    entity
    |> Map.put("output", item["aggregatedOutput"] || entity["output"] || "")
    |> then(
      &if(is_integer(item["exitCode"]), do: Map.put(&1, "exitCode", item["exitCode"]), else: &1)
    )
  end

  # --- background commands ---------------------------------------------------------

  # The completed turn's commands still running move out of its items, so the turn's
  # end does not close them.
  defp to_background(state) do
    background =
      for {native, process} <- state.running,
          item = state.items[native],
          into: state.background,
          do: {native, %{item: item, process: process}}

    %{
      state
      | background: background,
        items: Map.drop(state.items, Map.keys(state.running)),
        running: %{}
    }
  end

  defp background_done(state, native, item) do
    {%{item: %{id: item_id, node: node_id}}, background} = Map.pop(state.background, native)
    end_command(state, item_id, node_id, command_status(item), &command_result(&1, item))
    state = %{state | background: background}
    # Between turns Codex does not hear of it by itself: the thread tells it.
    if state.turn == nil, do: wake(state.thread_id, item)
    state
  end

  # A turn telling Codex that a command it left in the background ended, queued like
  # any message. Off this process, since starting the run calls back into it. An
  # archived or deleted thread is left alone.
  defp wake(thread_id, item) do
    Task.start(fn ->
      stream = HalC2.Streams.state(thread_id)
      thread = HalC2.StreamState.get(stream, "thread")[thread_id] || %{}

      # Not a held queue's run, which waits with a higher ordinal behind the one that ran.
      latest = HalC2.Projection.Shell.latest_run(HalC2.StreamState.list(stream, "run")) || %{}

      message_id = Entities.new_id("message")

      ended =
        case item["exitCode"] do
          code when is_integer(code) -> "exited with code #{code}"
          _ -> "ended (#{command_status(item)})"
        end

      if thread["archivedAt"] == nil and thread["deletedAt"] == nil do
        with {:error, reason} <-
               Orchestration.dispatch(%{
                 "type" => "message.dispatch",
                 "commandId" => "command:codex-background:#{message_id}",
                 "threadId" => thread_id,
                 "messageId" => message_id,
                 "text" => "The background command `#{item["command"]}` #{ended}.",
                 "attachments" => [],
                 "modelSelection" => latest["modelSelection"],
                 "dispatchMode" => %{"type" => "queue_after_active"},
                 "createdBy" => "agent",
                 "creationSource" => "provider"
               }) do
          Logger.warning("codex background wake in #{thread_id} has no run: #{inspect(reason)}")
        end
      end
    end)
  end

  # Stops every background command, and ends its item as `status`.
  defp end_background(state, status) do
    for {_native, %{item: item, process: process}} <- state.background do
      terminate_terminal(state, process)
      end_command(state, item.id, item.node, status, & &1)
    end

    %{state | background: %{}}
  end

  defp end_command(state, item_id, node_id, status, fun) do
    at = Entities.now()
    done = %{"status" => status, "completedAt" => at}

    commit(state, fn stream ->
      [
        Orchestration.upsert(
          stream,
          "turn-item",
          item_id,
          &(fun.(&1) |> Map.merge(Map.put(done, "updatedAt", at)))
        ),
        Orchestration.upsert(stream, "node", node_id, &Map.merge(&1, done))
      ]
    end)
  end

  # Codex keeps a unified exec process running when its turn is interrupted; this
  # stops it. Without the app-server there is nothing to ask (its terminals went with
  # it), and a command outside unified exec has no process to name.
  defp terminate_terminal(%{conn: conn} = state, process)
       when conn != nil and process != nil do
    params = %{"threadId" => state.native_thread_id, "processId" => process}

    case Connection.call(conn, "thread/backgroundTerminals/terminate", params, 10_000) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("codex terminal #{process} not terminated: #{inspect(reason)}")
    end
  catch
    :exit, reason ->
      Logger.warning("codex terminal #{process} not terminated: #{inspect(reason)}")
  end

  defp terminate_terminal(_state, _process), do: :ok

  defp complete_item(state, %{"type" => "agentMessage", "id" => native} = item) do
    text = item["text"] || ""
    final? = Map.get(state, :finals, %{})[native] == true

    cond do
      # A held-back final answer that repeats an earlier one, or says nothing,
      # adds nothing to the thread; a different one is shown now that it is whole.
      state.suppressed[native] ->
        state = Map.put(state, :suppressed, Map.delete(state.suppressed, native))

        if text == "" or state.final_texts[text] do
          state
        else
          state
          |> Map.put(:final_texts, Map.put(state.final_texts, text, true))
          |> ensure_item(native, :assistant)
          |> finish_item(native, "completed", fn entity ->
            Map.merge(entity, %{"text" => text, "streaming" => false})
          end)
        end

      true ->
        state =
          if final?,
            do: Map.put(state, :final_texts, Map.put(state.final_texts, text, true)),
            else: state

        finish_item(state, native, "completed", fn entity ->
          Map.merge(entity, %{"text" => item["text"] || entity["text"], "streaming" => false})
        end)
    end
  end

  # The completed plan item is authoritative over its streamed deltas.
  defp complete_item(state, %{"type" => "plan", "id" => native} = item) do
    text = if is_binary(item["text"]) and item["text"] != "", do: item["text"]
    state |> ensure_item(native, :plan) |> finish_plan(native, text)
  end

  defp complete_item(state, %{"type" => "reasoning", "id" => native}) do
    if Map.has_key?(state.items, native),
      do: finish_item(state, native, "completed", &Map.put(&1, "streaming", false)),
      else: state
  end

  defp complete_item(state, %{"type" => "commandExecution", "id" => native} = item) do
    %{state | running: Map.delete(state.running, native)}
    |> ensure_item(native, :command, %{"input" => item["command"] || "", "output" => ""})
    |> finish_item(native, command_status(item), &command_result(&1, item))
  end

  defp complete_item(state, %{"type" => "fileChange", "id" => native, "changes" => [change | _]}) do
    ids = state.turn.ids
    at = Entities.now()
    item_id = item_id(ids, native)

    commit(state, fn stream ->
      [
        Orchestration.create(
          "turn-item",
          item_id,
          Entities.turn_item(
            ids,
            item_id,
            "file_change",
            Orchestration.next_ordinal(stream),
            "completed",
            at,
            %{
              "fileName" => change["path"] || "file",
              "diffStr" => change["diff"] || ""
            }
          )
        )
      ]
    end)

    state
  end

  defp complete_item(state, %{"type" => "webSearch", "id" => native} = item) do
    fields = %{"patterns" => web_patterns(item)}

    state
    |> ensure_item(native, :web, fields)
    |> finish_item(native, "completed", &Map.merge(&1, fields))
  end

  defp complete_item(state, %{"type" => type, "id" => native} = item)
       when type in ["mcpToolCall", "dynamicToolCall"] do
    fields = tool_fields(item)
    status = if item["status"] == "failed", do: "failed", else: "completed"

    state
    |> ensure_item(native, :tool, fields)
    |> finish_item(native, status, &Map.merge(&1, fields))
  end

  defp complete_item(state, _item), do: state

  defp spawned(state, %{"tool" => "spawnAgent", "id" => id} = item) do
    known = Map.get(state, :subagents, %{})

    subagents =
      for thread <- item["receiverThreadIds"] || [],
          is_binary(thread) and not is_map_key(known, thread),
          into: known do
        sub =
          HalC2.Orchestration.NativeSubagent.start(state.turn.ids, "#{id}:#{thread}", %{
            "prompt" => item["prompt"] || "",
            "title" => nil,
            "model" => if(item["model"] in [nil, ""], do: nil, else: item["model"])
          })

        {thread, %{sub: sub, done: false}}
      end

    Map.put(state, :subagents, subagents)
  end

  defp spawned(state, _item), do: Map.put_new(state, :subagents, %{})

  @agent_status %{
    "pendingInit" => "pending",
    "running" => "running",
    "interrupted" => "interrupted",
    "completed" => "completed",
    "errored" => "failed",
    "shutdown" => "cancelled",
    "notFound" => "failed"
  }

  # Where each agent of a collab tool call stands; one that ended ends its subagent
  # with what it said last, and a late older report does not reopen it.
  defp subagent_states(state, item) do
    subagents =
      for {thread, agent} <- item["agentsStates"] || %{}, reduce: state.subagents do
        subagents ->
          with %{done: false, sub: sub} = entry <- subagents[thread],
               status when is_binary(status) <- @agent_status[agent["status"]] do
            if status in ["pending", "running"] do
              sub = HalC2.Orchestration.NativeSubagent.show(sub, status)
              Map.put(subagents, thread, %{entry | sub: sub})
            else
              sub =
                HalC2.Orchestration.NativeSubagent.finish(
                  sub,
                  status,
                  agent["message"] || entry[:final]
                )

              Map.put(subagents, thread, %{entry | sub: sub, done: true})
            end
          else
            _ -> subagents
          end
      end

    %{state | subagents: subagents}
  end

  # What a web search looked for.
  defp web_patterns(item) do
    action = item["action"] || %{}

    candidates =
      case action["type"] do
        "search" -> (action["queries"] || []) ++ [action["query"], item["query"]]
        "openPage" -> [action["url"], item["query"]]
        "findInPage" -> [action["pattern"], action["url"], item["query"]]
        _ -> [item["query"]]
      end

    candidates
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
  end

  # An MCP or dynamic tool call's name, arguments, and result.
  defp tool_fields(%{"type" => "mcpToolCall"} = item) do
    result = item["result"] || %{}
    output = result["structuredContent"] || result["content"]

    output =
      case item["error"] do
        %{"message" => message} when output == nil -> %{"error" => message}
        %{"message" => message} -> %{"error" => message, "result" => output}
        _ -> output
      end

    tool_fields("#{item["server"]}.#{item["tool"]}", item["arguments"], output)
    |> Map.merge(HalC2.Codex.ToolPresentation.fields(item))
  end

  defp tool_fields(item) do
    name = Enum.filter([item["namespace"], item["tool"]], &(is_binary(&1) and &1 != ""))

    output =
      cond do
        item["contentItems"] != nil -> item["contentItems"]
        item["success"] == false -> %{"success" => false}
        true -> nil
      end

    tool_fields(Enum.join(name, "."), item["arguments"], output)
  end

  defp tool_fields(name, input, nil), do: %{"toolName" => name, "input" => input}

  defp tool_fields(name, input, output),
    do: %{"toolName" => name, "input" => input, "output" => output}
end
