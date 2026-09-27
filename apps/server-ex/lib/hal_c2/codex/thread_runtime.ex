defmodule HalC2.Codex.ThreadRuntime do
  @moduledoc """
  Runs one thread's Codex turns through `codex app-server` and writes them into the
  thread's log.

  The process owns the app-server connection for its thread. A turn starts with
  `thread/start` (or `thread/resume` for a thread Codex already knows) and
  `turn/start`; the app-server's notifications then become entity patches.
  Streamed text and command output are written as appends (`HalC2.Orchestration.TurnWriter`),
  so a long answer costs its new bytes, not its whole length, per update.
  """

  use GenServer, restart: :temporary

  require Logger

  import HalC2.Orchestration.TurnWriter

  alias HalC2.Orchestration
  alias HalC2.Orchestration.Entities
  alias HalC2.JsonRpc.Connection

  @state_version 1

  # runtimeMode -> {approvalPolicy, approvalsReviewer, sandboxPolicy type}, as the Node
  # adapter maps it. Auto lets Codex's own reviewer answer what it would ask the user.
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

  @spec interrupt(String.t(), String.t() | nil) :: :ok | {:error, String.t()}
  def interrupt(thread_id, _run_id) do
    case Registry.lookup(HalC2.Codex.Registry, thread_id) do
      [{pid, _}] -> GenServer.call(pid, :interrupt, 15_000)
      [] -> {:error, "no active Codex turn in this thread"}
    end
  end

  @doc """
  Adds a message (`%{text, attachments}`) to the running turn of `run_id` (`turn/steer`).

  When Codex refuses, whatever it said before refusing (a `turn/completed`, say) is
  applied before this returns, so the caller sees whether the turn is still running.
  """
  @spec steer(String.t(), String.t(), map) :: :ok | {:error, String.t()}
  def steer(thread_id, run_id, message) do
    case Registry.lookup(HalC2.Codex.Registry, thread_id) do
      [{pid, _}] ->
        with {:error, _} = error <- GenServer.call(pid, {:steer, run_id, message}, 30_000) do
          # Notifications that preceded the refusal sit in the runtime's mailbox ahead
          # of this call.
          GenServer.call(pid, :settle, 30_000)
          error
        end

      [] ->
        {:error, "no running turn"}
    end
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
    case Registry.lookup(HalC2.Codex.Registry, thread_id) do
      [{pid, _}] -> GenServer.call(pid, {:upload_feedback, reason}, 60_000)
      [] -> {:error, "The provider session is no longer running. Send a message first."}
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
    {:ok,
     %{
       v: @state_version,
       thread_id: thread_id,
       conn: nil,
       native_thread_id: nil,
       turn: nil,
       items: %{},
       buffer: %{},
       flush_timer: nil,
       failure: nil,
       # Open approval prompts: request id -> the app-server request to answer.
       requests: %{}
     }}
  end

  @impl true
  def handle_call({:start_turn, turn}, _from, state) do
    state = %{state | turn: turn, items: %{}, failure: nil}

    case begin_turn(state, turn) do
      {:ok, state} ->
        {:reply, :ok, state}

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

  def handle_call(:interrupt, _from, %{turn: %{native_turn_id: turn_id}} = state)
      when is_binary(turn_id) do
    Connection.call(state.conn, "turn/interrupt", %{
      "threadId" => state.native_thread_id,
      "turnId" => turn_id
    })

    {:reply, :ok, state}
  end

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

    case Connection.call(state.conn, "turn/steer", params) do
      {:ok, _} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, rpc_message(reason)}, state}
    end
  end

  def handle_call({:rollback, _plan}, _from, %{turn: turn} = state) when turn != nil,
    do: {:reply, {:error, "Interrupt the current turn before rewinding."}, state}

  def handle_call({:rollback, plan}, _from, state) do
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

      {rpc_id, requests} ->
        decision = response["decision"] || "decline"
        # Codex has no "always"; the closest is for the rest of the session.
        codex_decision = if decision == "acceptAlways", do: "acceptForSession", else: decision
        Connection.respond(state.conn, rpc_id, {:ok, %{"decision" => codex_decision}})
        state = resolve_request(%{state | requests: requests}, request_id, decision)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:json_rpc, _conn, {:notification, method, params}}, state),
    do: {:noreply, notification(method, params || %{}, state)}

  def handle_info({:json_rpc, _conn, {:request, id, method, params}}, %{turn: turn} = state)
      when turn != nil and
             method in [
               "item/commandExecution/requestApproval",
               "item/fileChange/requestApproval",
               "item/permissions/requestApproval"
             ] do
    {kind, prompt} =
      case method do
        "item/commandExecution/requestApproval" ->
          {"command", params["reason"] || params["command"]}

        "item/fileChange/requestApproval" ->
          {"file-change", params["reason"]}

        _ ->
          {permissions_kind(params["permissions"]), params["reason"]}
      end

    native = params["approvalId"] || params["itemId"] || "request-#{id}"
    {state, request_id} = open_request(flush(state), native, kind, prompt)
    {:noreply, %{state | requests: Map.put(state.requests, request_id, id)}}
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

  # Other requests are not wired up yet; refuse rather than hang the turn.
  def handle_info({:json_rpc, conn, {:request, id, method, _params}}, state) do
    Connection.respond(
      conn,
      id,
      {:error, %{"code" => -32601, "message" => "#{method} is not supported"}}
    )

    {:noreply, state}
  end

  def handle_info(:flush, state), do: {:noreply, flush(%{state | flush_timer: nil}, :timer)}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def code_change(_old, state, _extra), do: {:ok, %{state | v: @state_version}}

  # The message, with where its files are, and its images inline.
  defp codex_input(turn) do
    attachments = Map.get(turn, :attachments, [])
    text = HalC2.Attachments.prompt_text(turn.text, attachments)

    if(text == "", do: [], else: [%{"type" => "text", "text" => text}]) ++
      for {mime, data} <- HalC2.Attachments.native_images(attachments),
          do: %{"type" => "image", "url" => "data:#{mime};base64,#{data}"}
  end

  # As the Node server reads a permissions request: file writes are a file change,
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
    with {:ok, state} <- connect(state, turn),
         {:ok, state, turn} <- open_thread(state, turn),
         {:ok, native_turn} <- start_native_turn(state, turn) do
      at = Entities.now()
      ids = Map.put(turn.ids, :provider_turn, "provider-turn:codex:#{native_turn}")
      turn = %{turn | ids: ids} |> Map.put(:native_turn_id, native_turn)

      commit(state, fn stream ->
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

      {:ok, %{state | turn: turn}}
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

  defp rpc_message(%{"message" => message}) when is_binary(message), do: message
  defp rpc_message(reason), do: inspect(reason)

  defp connect(%{conn: nil} = state, turn) do
    cmd = Application.get_env(:hal_c2, :codex_command, ["codex", "app-server"])

    # The instance's variables in settings (such as CODEX_HOME) reach Codex.
    env =
      if ids = turn[:ids],
        do: Enum.to_list(HalC2.Settings.instance_env(Entities.instance(ids))),
        else: []

    with {:ok, conn} <-
           Connection.start_link(
             cmd: cmd,
             handler: self(),
             cd: turn.cwd,
             env: env,
             log: turn.ids.thread
           ),
         {:ok, _} <-
           Connection.call(conn, "initialize", %{
             "clientInfo" => %{
               "name" => "hal_c2_elixir",
               "title" => "HAL-C2",
               "version" => "0.1.0"
             },
             "capabilities" => %{
               "experimentalApi" => true,
               "optOutNotificationMethods" => ["turn/diff/updated"]
             }
           }) do
      Connection.notify(conn, "initialized", nil)
      {:ok, %{state | conn: conn}}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp connect(state, _turn), do: {:ok, state}

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

  defp ensure_native_thread(%{native_thread_id: id} = state, _turn) when is_binary(id),
    do: {:ok, state}

  # A fork's first turn starts from a copy of the source thread, cut after its turn;
  # a session carried from another machine is forked whole from its rollout's path.
  defp ensure_native_thread(state, %{fork: %{thread: source, turn: last} = fork} = turn) do
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
      {:ok, %{"thread" => %{"id" => id}}} -> {:ok, %{state | native_thread_id: id}}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # The thread's settings, with HAL-C2's own MCP server for the agent when allowed.
  defp thread_params(state, turn) do
    params = %{"cwd" => turn.cwd, "model" => turn.model}

    case mcp(state, turn) do
      nil ->
        params

      mcp ->
        Map.put(params, "config", %{
          "mcp_servers" => %{
            "hal-c2" => %{
              "url" => mcp.url,
              "http_headers" => %{"Authorization" => mcp.authorization}
            }
          }
        })
    end
  end

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
        "settings" =>
          if(mcp(state, turn),
            do: %{"model" => turn.model, "developer_instructions" => HalC2.Mcp.instructions()},
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

  # Quota comes alongside token usage, mostly unchanged; it merges onto the provider entry.
  # The merged snapshot is kept to name the used-up window when a turn stops on it.
  defp notification("account/rateLimits/updated", %{"rateLimits" => snapshot}, state) do
    HalC2.ProviderUsageLimits.update("codex", HalC2.ProviderUsageLimits.Codex.windows(snapshot))

    if snapshot["limitId"] in [nil, "codex"],
      do: Map.put(state, :rate_limits, Map.merge(Map.get(state, :rate_limits) || %{}, snapshot)),
      else: state
  end

  defp notification(_method, _params, %{turn: nil} = state), do: state

  defp notification(
         "item/started",
         %{"item" => %{"type" => "agentMessage", "id" => native}},
         state
       ),
       do: ensure_item(state, native, :assistant)

  defp notification("item/started", %{"item" => %{"type" => "commandExecution"} = item}, state) do
    state
    |> ensure_item(item["id"], :command, %{"input" => item["command"] || "", "output" => ""})
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
       when type in ["mcpToolCall", "dynamicToolCall"],
       do: ensure_item(state, native, :tool, tool_fields(item))

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

  defp notification("item/agentMessage/delta", %{"itemId" => native, "delta" => delta}, state),
    do: state |> ensure_item(native, :assistant) |> buffer(native, "text", delta)

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

  defp notification("item/completed", %{"item" => item}, state),
    do: complete_item(flush(state), item)

  defp notification("error", %{"error" => error} = params, state) do
    cond do
      params["willRetry"] == true ->
        state

      error_code(error["codexErrorInfo"]) in ["usageLimitExceeded", "rateLimitExceeded"] ->
        %{state | failure: usage_limit_message(Map.get(state, :rate_limits), DateTime.utc_now())}

      true ->
        %{state | failure: error["message"] || "Codex reported an error"}
    end
  end

  defp notification("turn/completed", %{"turn" => turn}, state) do
    state = flush(state)

    status =
      if turn["status"] in ["completed", "interrupted", "failed"],
        do: turn["status"],
        else: "failed"

    state =
      Enum.reduce(Map.keys(state.requests), state, &resolve_request(&2, &1, nil, "cancelled"))

    # Items the provider left running end with the turn, as with Claude and ACP.
    state = close_open_items(state, status)
    finish(state, status, state.failure || get_in(turn, ["error", "message"]))
    %{state | turn: nil, items: %{}, requests: %{}}
  end

  defp notification(_method, _params, state), do: state

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
      (snapshot || %{})
      |> HalC2.ProviderUsageLimits.Codex.windows()
      |> Enum.flat_map(fn window ->
        with true <- window["usedPercent"] >= 100,
             {:ok, resets, _} <- DateTime.from_iso8601(window["resetsAt"] || ""),
             wait when wait > 0 <- DateTime.diff(resets, at, :millisecond),
             do: [{wait, window["kind"]}],
             else: (_ -> [])
      end)
      |> Enum.max_by(&elem(&1, 0), fn -> nil end)

    reset =
      case reset do
        {wait, kind} -> " The #{kind} limit resets in #{wait_text(wait)}."
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

  defp complete_item(state, %{"type" => "agentMessage", "id" => native} = item) do
    finish_item(state, native, "completed", fn entity ->
      Map.merge(entity, %{"text" => item["text"] || entity["text"], "streaming" => false})
    end)
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
    status =
      case item["status"] do
        "failed" -> "failed"
        "declined" -> "cancelled"
        _ -> "completed"
      end

    state
    |> ensure_item(native, :command, %{"input" => item["command"] || "", "output" => ""})
    |> finish_item(native, status, fn entity ->
      entity
      |> Map.put("output", item["aggregatedOutput"] || entity["output"] || "")
      |> then(
        &if(is_integer(item["exitCode"]), do: Map.put(&1, "exitCode", item["exitCode"]), else: &1)
      )
    end)
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

  # What a web search looked for, as the Node server lists it.
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
