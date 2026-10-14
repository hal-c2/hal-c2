defmodule HalC2.Muse.ThreadRuntime do
  @moduledoc """
  Runs one thread's turns on a Muse Code host (`muse serve`, `HalC2.Muse`) and
  writes them into the thread's log.

  One host serves the thread while its instance, access mode and checkout stay the
  same (the sandbox is fixed when the host starts). The thread's native
  conversation is a Muse session, whose id HAL-C2 mints: a new host resumes it
  (`session/resume`), and a session Muse no longer has is started again. A
  message is a `turn/start` (`/compact` is `session/compact`), whose id is the
  command id HAL-C2 sent; Muse's items stream into turn items by revision, and
  `turn/completed` ends the turn. Approvals and questions arrive as
  notifications and are answered with `approval/decide` and `userInput/answer`.
  Steering is `turn/steer`, interrupt `turn/interrupt`. Muse cannot rewind a
  session, so rollback is refused.
  """

  use GenServer, restart: :temporary

  require Logger

  import HalC2.Orchestration.TurnWriter

  alias HalC2.JsonRpc.Connection
  alias HalC2.Muse
  alias HalC2.Orchestration
  alias HalC2.Orchestration.Entities

  @state_version 3
  @registry HalC2.Muse.Registry
  # Muse's "overloaded" and "backpressured": the command may be sent again.
  @retryable [-32001, -32031]
  # Tools whose work shows elsewhere (the todo list, the question), unless they fail.
  @hidden_tools ~w(write_todos request_user_input workflow)
  # Muse's own bookkeeping, not part of the conversation shown.
  @skipped_items ~w(userMessage reminderChild)
  # Muse caps a question's free-text answer.
  @max_free_text 500

  @spec start_turn(String.t(), map) :: :ok
  def start_turn(thread_id, turn),
    do: thread_id |> ensure() |> GenServer.call({:start_turn, turn}, 120_000)

  @spec interrupt(String.t(), String.t() | nil) :: :ok | {:error, String.t()}
  def interrupt(thread_id, _run_id) do
    case lookup(thread_id) do
      nil -> {:error, "no active Muse turn in this thread"}
      pid -> GenServer.call(pid, :interrupt, 35_000)
    end
  end

  @doc "A `turn/steer` into the running turn, built from `%{text, attachments}` like a turn's."
  @spec steer(String.t(), String.t(), map) :: :ok | {:error, String.t()}
  def steer(thread_id, run_id, message) do
    case lookup(thread_id) do
      nil -> {:error, "no active Muse turn in this thread"}
      pid -> GenServer.call(pid, {:steer, run_id, message}, 35_000)
    end
  end

  @spec respond(String.t(), String.t(), map) :: :ok | {:error, String.t()}
  def respond(thread_id, request_id, response) do
    case lookup(thread_id) do
      nil -> {:error, "no pending request"}
      pid -> GenServer.call(pid, {:respond, request_id, response}, 35_000)
    end
  end

  @spec rollback(String.t(), map) :: {:error, String.t()}
  def rollback(_thread_id, _plan), do: {:error, "Muse Code cannot rewind its conversation."}

  def start_link(thread_id),
    do:
      GenServer.start_link(__MODULE__, thread_id, name: {:via, Registry, {@registry, thread_id}})

  defp lookup(thread_id) do
    with registry when registry != nil <- Process.whereis(@registry),
         [{pid, _}] <- Registry.lookup(@registry, thread_id) do
      pid
    else
      _ -> nil
    end
  end

  defp ensure(thread_id) do
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
       # What the host was started for: a change is a new host.
       host: nil,
       # Whether the host granted session MCP (HAL-C2's tools).
       mcp?: false,
       # Muse's session id, the thread's native conversation.
       session: nil,
       model: nil,
       turn: nil,
       # The Muse turn this run drives (its command id), and turns Muse started on its
       # own that this run shows too.
       native: nil,
       joined: MapSet.new(),
       # A `/compact`: the compaction item ends the turn instead of `turn/completed`.
       compact: false,
       items: %{},
       # Muse's items as last seen (itemId -> item), for revisions and deltas.
       muse: %{},
       buffer: %{},
       flush_timer: nil,
       interrupted: false,
       usage: %{},
       # Whether Muse has started this run's turn (turn/started); before then, context
       # usage is still the last turn's.
       started: false,
       # The provider turn of the run that ended last, for usage Muse reports after it.
       last_ids: nil,
       # Open prompts: request id -> {:approval, approval} | {:question, user input}.
       requests: %{}
     }}
  end

  @impl true
  def handle_call({:start_turn, turn}, _from, state) do
    ids = Map.put(turn.ids, :provider_turn, "provider-turn:#{turn.ids.driver}:#{turn.ids.run}")
    turn = %{turn | ids: ids, cwd: canonical(turn.cwd)}

    state = %{
      state
      | turn: turn,
        items: %{},
        muse: %{},
        native: Muse.command_id(),
        joined: MapSet.new(),
        compact: false,
        interrupted: false,
        usage: %{},
        started: false
    }

    with {:ok, state} <- ensure_session(state, turn),
         {:ok, state} <- select_model(state, turn.model) do
      # A run that ended while the session opened never reaches Muse.
      case started(state) do
        :ok -> {:reply, :ok, send_turn(state, turn)}
        :ended -> {:reply, :ok, %{state | turn: nil}}
      end
    else
      {:error, reason, state} ->
        Logger.warning("muse turn failed to start: #{inspect(reason)}")
        finish(state, "failed", start_failure("Muse Code", format(reason)))
        {:reply, :ok, %{state | turn: nil}}
    end
  end

  # IdleSessions' release: a runtime that took a turn since the thread looked idle keeps it.
  def handle_call(:release, _from, %{turn: nil} = state),
    do: {:stop, {:shutdown, :released}, :ok, state}

  def handle_call(:release, _from, state), do: {:reply, :busy, state}

  # Muse cannot stop a compaction; closing its host does.
  def handle_call(:interrupt, _from, %{turn: turn, compact: true} = state) when turn != nil do
    state = %{state | interrupted: true} |> end_turn("interrupted", nil) |> close_host()
    {:reply, :ok, state}
  end

  def handle_call(:interrupt, _from, %{turn: turn} = state) when turn != nil do
    # Muse runs a turn it joined first, so stopping the run stops it too.
    for joined <- state.joined, do: command(state, "turn/interrupt", %{"turnId" => joined})

    case command(state, "turn/interrupt", %{"turnId" => state.native}) do
      {:ok, _} -> {:reply, :ok, %{state | interrupted: true}}
      {:error, reason} -> {:reply, {:error, format(reason)}, state}
    end
  end

  def handle_call(:interrupt, _from, state), do: {:reply, {:error, "no running turn"}, state}

  def handle_call({:steer, run_id, message}, _from, %{turn: turn, compact: false} = state)
      when turn != nil and not state.interrupted and turn.ids.run == run_id do
    params = %{
      "expectedTurnId" => state.native,
      "input" => input(message.text, message.attachments)
    }

    case command(state, "turn/steer", params) do
      {:ok, %{"turnId" => turn_id}} when turn_id == state.native -> {:reply, :ok, state}
      {:ok, _} -> {:reply, {:error, "Muse steered a different turn."}, state}
      {:error, reason} -> {:reply, {:error, format(reason)}, state}
    end
  end

  def handle_call({:steer, _run_id, _message}, _from, state),
    do: {:reply, {:error, "Muse Code cannot be steered now"}, state}

  # An answer Muse accepts stays open until Muse settles it (approval/resolved,
  # userInput/settled): an approval can still gain a requirement (approval/updated).
  def handle_call({:respond, request_id, response}, _from, state) do
    case Map.fetch(state.requests, request_id) do
      :error ->
        {:reply, {:error, "no pending request #{request_id}"}, state}

      {:ok, {_kind, %{submitted: _}}} ->
        {:reply, :ok, state}

      {:ok, {:approval, approval}} ->
        decision = response["decision"] || "decline"

        with %{"choiceId" => choice} <- choices(approval)[decision] || {:error, :no_choice},
             {:ok, _} <-
               command(state, "approval/decide", %{
                 "approvalId" => approval["approvalId"],
                 "requirementId" => approval["currentRequirementId"],
                 "choiceId" => choice
               }) do
          {:reply, :ok, submitted(state, request_id, decision)}
        else
          {:error, :no_choice} -> {:reply, {:error, "Muse did not offer this decision."}, state}
          {:error, reason} -> {:reply, {:error, format(reason)}, state}
        end

      {:ok, {:question, input}} ->
        with {:ok, answers} <- question_answers(input["questions"], response),
             {:ok, _} <-
               command(state, "userInput/answer", %{
                 "userInputId" => input["userInputId"],
                 "answers" => answers
               }) do
          {:reply, :ok, submitted(state, request_id, response)}
        else
          {:error, reason} -> {:reply, {:error, format(reason)}, state}
        end
    end
  end

  @impl true
  # Muse's presentation receipts: the prompt itself arrives as a notification.
  def handle_info({:json_rpc, conn, {:request, id, method, _params}}, %{conn: conn} = state)
      when method in ["approval/request", "userInput/request"] do
    Connection.respond(conn, id, {:ok, %{}})
    {:noreply, state}
  end

  def handle_info({:json_rpc, conn, {:request, id, method, _params}}, %{conn: conn} = state) do
    Connection.respond(
      conn,
      id,
      {:error, %{"code" => -32601, "message" => "method not found: #{method}"}}
    )

    {:noreply, state}
  end

  def handle_info({:json_rpc, conn, {:notification, method, params}}, %{conn: conn} = state) do
    if is_map(params) and params["sessionId"] == state.session,
      do: {:noreply, notification(method, params, started(state, params))},
      else: {:noreply, state}
  end

  def handle_info({:EXIT, conn, _reason}, %{conn: conn} = state) do
    state =
      if state.turn, do: end_turn(state, "failed", "Muse Code exited unexpectedly"), else: state

    # The session and model were the dead host's; the next host resumes the session.
    {:noreply, %{state | conn: nil, host: nil, session: nil, model: nil}}
  end

  def handle_info(:flush, state), do: {:noreply, flush(%{state | flush_timer: nil}, :timer)}
  def handle_info(_other, state), do: {:noreply, state}

  # Anything Muse says about this run's turn means it has started it.
  defp started(%{native: native} = state, params) when native != nil do
    if native in [params["turnId"], get_in(params, ["item", "turnId"])],
      do: %{state | started: true},
      else: state
  end

  defp started(state, _params), do: state

  @impl true
  def terminate(_reason, state) do
    if state.conn, do: Connection.stop(state.conn)
    :ok
  end

  @impl true
  def code_change(_old, state, _extra), do: {:ok, migrate(state)}

  # Every older state shape migrates forward here.
  defp migrate(%{v: @state_version} = state), do: state

  # v3 knows whether Muse started the running turn; one running at the update has.
  defp migrate(%{v: 2} = state), do: state |> Map.merge(%{v: 3, started: true}) |> migrate()

  # v2 keeps the last turn's ids, not only its provider turn.
  defp migrate(%{v: 1} = state),
    do: state |> Map.delete(:last_turn) |> Map.merge(%{v: 2, last_ids: nil}) |> migrate()

  # --- session -------------------------------------------------------------------

  # Muse refuses a workspace root that is not canonical (macOS's /tmp, a symlinked
  # checkout) and names canonical paths in its approvals.
  defp canonical(cwd) when is_binary(cwd) do
    case HalC2.Paths.real(cwd) do
      {:ok, real} -> real
      {:error, _} -> cwd
    end
  end

  defp canonical(cwd), do: cwd

  defp ensure_session(state, turn) do
    instance = Entities.instance(turn.ids)
    host = {instance, turn.runtime_mode, turn.cwd}

    with {:ok, state} <- open_host(state, host, instance, turn),
         {:ok, state} <- open_session(state, turn) do
      if state.session != turn.native_thread_id, do: record_session(state)
      {:ok, state}
    end
  end

  defp open_host(%{conn: conn, host: host} = state, host, _instance, _turn) when conn != nil,
    do: {:ok, state}

  defp open_host(state, host, instance, turn) do
    state = close_host(state)

    case Muse.connect(instance, turn.cwd, runtime_mode: turn.runtime_mode, log: state.thread_id) do
      {:ok, conn, granted} ->
        {:ok, %{state | conn: conn, host: host, mcp?: "sessionMcp" in granted}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp close_host(%{conn: nil} = state), do: state

  defp close_host(state) do
    Connection.stop(state.conn)
    flush_exit(state.conn)
    %{state | conn: nil, host: nil, session: nil, model: nil}
  end

  defp flush_exit(conn) do
    receive do
      {:EXIT, ^conn, _} -> :ok
    after
      0 -> :ok
    end
  end

  # The host already has the thread's session loaded.
  defp open_session(%{session: session} = state, %{native_thread_id: session} = turn)
       when is_binary(session),
       do: set_mode(state, turn)

  defp open_session(state, %{native_thread_id: id} = turn) when is_binary(id) do
    params = Map.merge(%{"sessionId" => id, "excludeItems" => true}, config(state, turn))

    case command(state, "session/resume", params) do
      {:ok, %{"session" => %{"sessionId" => ^id} = session}} ->
        set_mode(%{state | session: id, model: session["modelId"]}, turn)

      # The host is out of step with the thread: it stops, and the next turn starts another.
      {:ok, _} ->
        {:error, "Muse resumed another session", close_host(state)}

      {:error, %{"data" => %{"kind" => kind}}} when kind in ["sessionNotFound", "notFound"] ->
        start_session(state, turn)

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp open_session(state, turn), do: start_session(state, turn)

  defp start_session(state, turn) do
    id = Muse.command_id()

    params =
      Map.merge(
        %{
          "sessionId" => id,
          "workspaceRoot" => turn.cwd,
          "providerId" => "meta",
          "approvalMode" => Muse.approval_mode(turn.runtime_mode)
        },
        config(state, turn)
      )
      |> then(&if(model?(turn.model), do: Map.put(&1, "modelId", turn.model), else: &1))

    case command(%{state | session: id}, "session/start", params) do
      {:ok, %{"session" => %{"sessionId" => ^id} = session}} ->
        {:ok, %{state | session: id, model: session["modelId"]}}

      {:ok, _} ->
        {:error, "Muse started a session under another id", close_host(state)}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # A resumed session keeps its last approval mode; the thread's may have changed.
  defp set_mode(state, turn) do
    case command(state, "session/setApprovalMode", %{
           "mode" => Muse.approval_mode(turn.runtime_mode)
         }) do
      {:ok, _} -> {:ok, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # HAL-C2's tools, optional: Muse fails a whole run when a required server is unreachable.
  defp config(%{mcp?: true} = state, _turn) do
    case HalC2.Mcp.for_agent(state.thread_id, Entities.instance(state.turn.ids)) do
      %{url: url, authorization: authorization} ->
        %{
          "config" => %{
            "mcpServers" => %{
              "hal-c2" => %{
                "transport" => "streamableHttp",
                "mode" => "optional",
                "url" => url,
                "headers" => %{"Authorization" => authorization}
              }
            }
          }
        }

      _ ->
        %{}
    end
  end

  defp config(_state, _turn), do: %{}

  defp model?(model), do: is_binary(model) and model not in ["", "default"]

  defp select_model(state, model) do
    if model?(model) and model != state.model do
      case command(state, "session/setModel", %{
             "model" => %{"modelId" => model, "providerId" => "meta"}
           }) do
        {:ok, _} -> {:ok, %{state | model: model}}
        {:error, reason} -> {:error, "could not select #{model}: #{format(reason)}", state}
      end
    else
      {:ok, state}
    end
  end

  defp record_session(state) do
    ids = state.turn.ids

    commit(state, fn stream ->
      [
        Orchestration.upsert(
          stream,
          "provider-thread",
          ids.provider_thread,
          &Map.put(&1, "nativeThreadRef", Entities.provider_ref(state.session, ids.driver))
        )
      ]
    end)
  end

  # A command: the session and a fresh command id go with every one, and Muse's
  # "overloaded" and "backpressured" are retried under the same id.
  defp command(state, method, params, attempt \\ 1) do
    id = params["commandId"] || Muse.command_id()
    params = Map.merge(%{"sessionId" => state.session, "commandId" => id}, params)

    case Connection.call(state.conn, method, params, 30_000) do
      {:error, %{"code" => code}} when code in @retryable and attempt < 3 ->
        Process.sleep(200 * attempt)
        command(state, method, params, attempt + 1)

      {:ok, result} when is_map(result) ->
        {:ok, result}

      {:ok, _} ->
        {:error, "Muse answered #{method} with something other than an object"}

      error ->
        error
    end
  catch
    # The request may still land, so the host is out of step with the MC: it stops,
    # and its exit ends the turn and drops the session like any host exit.
    :exit, _ ->
      close_conn(state.conn)
      {:error, "Muse Code did not answer #{method}"}
  end

  defp close_conn(conn) do
    Connection.stop(conn)
  catch
    :exit, _ -> :ok
  end

  defp send_turn(state, turn) do
    case Regex.run(~r/^\/compact(?:\s|$)/, String.trim(turn.text || "")) do
      [_] -> compact(state)
      nil -> start(state, turn)
    end
  end

  defp compact(state) do
    state = %{state | compact: true, started: true}

    case command(state, "session/compact", %{"commandId" => state.native}) do
      {:ok, %{"status" => "accepted"}} ->
        state

      {:ok, %{"status" => "noop"} = r} ->
        end_turn(state, "failed", r["reason"] || "Nothing to compact.")

      {:ok, other} ->
        end_turn(state, "failed", "Muse could not compact: #{inspect(other)}")

      {:error, reason} ->
        end_turn(state, "failed", format(reason))
    end
  end

  defp start(state, turn) do
    attachments = Map.get(turn, :attachments, [])
    effort = effort(state, turn)

    params =
      %{
        "commandId" => state.native,
        "input" => input(turn.text, attachments),
        "displayText" => if(turn.text in [nil, ""], do: "Image attachment", else: turn.text),
        # A resumed session keeps the root it started with; edits land in this checkout.
        "workspaceRoots" => [turn.cwd],
        "ifBusy" => "queue"
      }
      |> then(&if(effort, do: Map.put(&1, "reasoningEffort", effort), else: &1))

    case command(state, "turn/start", params) do
      {:ok, %{"turnId" => id}} when id == state.native ->
        state

      # A turn this run does not own may still be running there: the host stops.
      {:ok, _} ->
        state |> end_turn("failed", "Muse started the turn under another id") |> close_host()

      {:error, reason} ->
        end_turn(state, "failed", format(reason))
    end
  end

  # The text (with where each attachment is saved) and the images the model takes inline.
  defp input(text, attachments) do
    [%{"type" => "text", "text" => HalC2.Attachments.prompt_text(text, attachments)}] ++
      for {mime, data} <- HalC2.Attachments.native_images(attachments),
          do: %{"type" => "image", "mediaType" => mime, "base64Data" => data}
  end

  # The composer's options arrive as option id -> value (`Orchestration` turn fields).
  # The chosen effort, if the session's model offers it: a choice kept from another
  # model may not be one this model takes. Without the catalog, any effort Muse knows.
  defp effort(state, turn) do
    effort = option(turn, "reasoningEffort")
    model = if model?(turn.model), do: turn.model, else: state.model

    case HalC2.Acp.entry(Entities.instance(turn.ids)) do
      %{"models" => models} when is_list(models) ->
        case Enum.find(models, &(&1["slug"] == model)) do
          %{"capabilities" => %{} = capabilities} -> Muse.effort(effort, capabilities)
          _ -> if Muse.effort?(effort), do: effort
        end

      _ ->
        if Muse.effort?(effort), do: effort
    end
  end

  defp option(turn, id) do
    case (Map.get(turn, :options) || %{})[id] do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  # --- notifications ---------------------------------------------------------------

  # Muse lost events this client needs: the session's view cannot be trusted.
  defp notification("view/gap", _params, state) do
    state =
      if state.turn, do: end_turn(state, "failed", "Muse Code lost session events."), else: state

    close_host(state)
  end

  # Muse may report the context after `turn/completed`; it goes to the turn just ended.
  defp notification("session/contextUsage", %{"usedTokens" => used} = params, state)
       when is_integer(used) do
    usage = %{"usedTokens" => used}

    usage =
      if is_integer(params["windowTokens"]),
        do: Map.put(usage, "maxTokens", params["windowTokens"]),
        else: usage

    if state.turn != nil and not state.started,
      do: last_turn_usage(state, usage),
      else: token_usage(state, usage)
  end

  defp notification(_method, _params, %{turn: nil} = state), do: state

  # Muse starts a turn of its own when a workflow finishes; the running run shows it.
  defp notification("turn/started", %{"turnId" => id}, state)
       when id != state.native and not state.compact,
       do: %{state | joined: MapSet.put(state.joined, id)}

  defp notification(method, %{"item" => %{"itemId" => _} = item}, state)
       when method in ["item/started", "item/updated", "item/completed"] do
    previous = state.muse[item["itemId"]]

    cond do
      item["kind"] in @skipped_items ->
        state

      not owns?(state, item["turnId"]) and not (state.compact and item["kind"] == "compaction") ->
        state

      previous && (previous["revision"] || 0) >= (item["revision"] || 0) ->
        state

      true ->
        state |> Map.update!(:muse, &Map.put(&1, item["itemId"], item)) |> item(item)
    end
  end

  defp notification("item/delta", %{"itemId" => id, "delta" => delta} = params, state)
       when is_binary(delta) do
    case state.muse[id] do
      %{"status" => "inProgress"} = item -> delta(state, item, params["field"] || "text", delta)
      _ -> state
    end
  end

  defp notification("turn/completed", %{"turnId" => id} = params, %{compact: false} = state)
       when id == state.native do
    state = completed_usage(state, params["usage"])

    status =
      case params["terminal"] do
        "completed" -> "completed"
        "cancelled" when state.interrupted -> "interrupted"
        "cancelled" -> "cancelled"
        _ -> "failed"
      end

    failure =
      if status == "failed",
        do: get_in(params, ["error", "message"]) || params["reason"] || "Muse Code turn failed"

    end_turn(state, status, failure)
  end

  defp notification("session/tokenUsage", %{"turnId" => id, "usage" => usage}, state)
       when is_map(usage) do
    if owns?(state, id), do: completed_usage(state, usage), else: state
  end

  # Cancelled entries are no longer part of the plan.
  defp notification("session/todoListChanged", %{"items" => items}, state)
       when is_list(items) and state.turn != nil do
    items = Enum.reject(items, &(&1["status"] in ["cancelled", "canceled"]))

    steps =
      for {item, index} <- Enum.with_index(items, 1) do
        %{
          "id" => "step-#{index}",
          "text" => item["text"] || "Step #{index}",
          "status" =>
            case item["status"] do
              "completed" -> "completed"
              status when status in ["inProgress", "in_progress"] -> "running"
              _ -> "pending"
            end
        }
      end

    state |> flush() |> write_todo("todos:#{state.turn.ids.run}", steps)
  end

  defp notification("turn/retryScheduled", params, state) do
    if owns?(state, params["turnId"]), do: retry(state, params), else: state
  end

  defp notification(method, params, state)
       when method in ["approval/requested", "approval/updated"] do
    approval(state, method, params)
  end

  defp notification("userInput/requested", %{"userInputId" => id} = input, state) do
    if owns?(state, input["turnId"]) and not open?(state, id),
      do: question(state, input),
      else: state
  end

  # Settled after our answer (which it records), in Muse's own UI, or by the turn
  # ending (Muse's decision stands).
  defp notification(method, params, state)
       when method in ["approval/resolved", "userInput/settled"] do
    native = params["approvalId"] || params["userInputId"]

    case Enum.find(state.requests, fn {_id, {_, req}} ->
           (req["approvalId"] || req["userInputId"]) == native
         end) do
      {request_id, {_kind, req}} ->
        decision =
          case {req[:submitted], params["decision"]} do
            {nil, d} when is_binary(d) -> decision(%{"decision" => d, "scope" => "once"})
            {submitted, _} -> submitted
          end

        status = if match?(%{"dismissed" => true}, decision), do: "cancelled", else: "resolved"

        %{state | requests: Map.delete(state.requests, request_id)}
        |> resolve_request(request_id, decision, status)

      nil ->
        state
    end
  end

  defp notification(_method, _params, state), do: state

  defp owns?(_state, nil), do: true
  defp owns?(state, id), do: id == state.native or MapSet.member?(state.joined, id)

  # --- items -----------------------------------------------------------------------

  defp native(state, item), do: "#{state.turn.ids.run}:#{item["itemId"]}"

  defp item(state, %{"kind" => "agentMessage"} = item), do: text_item(state, item, :assistant)
  defp item(state, %{"kind" => "reasoning"} = item), do: text_item(state, item, :reasoning)

  defp item(state, %{"kind" => "compaction"} = item) do
    native = native(state, item)

    state =
      state
      |> flush()
      |> ensure_item(native, :compaction, %{
        "driver" => "muse",
        "title" => "Compacting context..."
      })

    case status(item) do
      "running" ->
        state

      status ->
        title =
          case status do
            "completed" -> "Context compacted"
            "cancelled" -> "Context compaction stopped"
            _ -> "Context compaction failed"
          end

        state = finish_item(state, native, status, &Map.put(&1, "title", title))

        if state.compact,
          do:
            end_turn(
              state,
              if(status == "cancelled" and state.interrupted, do: "interrupted", else: status),
              if(status == "failed", do: item["failureReason"] || item["reason"] || title)
            ),
          else: state
    end
  end

  defp item(state, item) do
    status = status(item)

    if item["kind"] == "toolCall" and item["tool"] in @hidden_tools and status != "failed" do
      state
    else
      {kind, fields} = tool(item, status)
      native = native(state, item)
      state = state |> flush() |> ensure_item(native, kind, fields)

      if status == "running",
        do: update_item(state, native, fields),
        else: finish_item(state, native, status, &Map.merge(&1, fields))
    end
  end

  # Text streams through deltas; the completed item's text is authoritative.
  defp text_item(state, item, kind) do
    native = native(state, item)
    state = ensure_item(state, native, kind)

    case status(item) do
      "running" ->
        state

      status ->
        text = text(item)

        state
        |> flush()
        |> finish_item(native, status, fn entity ->
          Map.merge(entity, %{"text" => text || entity["text"] || "", "streaming" => false})
        end)
    end
  end

  defp text(%{"text" => text}) when is_binary(text) and text != "", do: text
  defp text(%{"summary" => [_ | _] = summary}), do: Enum.join(summary, "\n")
  defp text(_item), do: nil

  defp delta(state, item, field, delta) do
    native = native(state, item)

    {item, write} =
      cond do
        field == "text" ->
          {Map.update(item, "text", delta, &((&1 || "") <> delta)), {"text", delta}}

        field in ["output", "visibleOutput"] ->
          {Map.update(item, "visibleOutput", delta, &((&1 || "") <> delta)), {"output", delta}}

        String.starts_with?(field, "summary.") ->
          # Reasoning summaries stream by paragraph into one text.
          summary = item["summary"] || []

          case Integer.parse(String.replace_prefix(field, "summary.", "")) do
            {n, ""} when n >= 0 and n < 100 ->
              summary = summary ++ List.duplicate("", max(0, n + 1 - length(summary)))
              joined = if n > 0 and Enum.at(summary, n) == "", do: "\n" <> delta, else: delta

              {Map.put(item, "summary", List.update_at(summary, n, &(&1 <> delta))),
               {"text", joined}}

            _ ->
              {item, nil}
          end

        true ->
          {item, nil}
      end

    state = %{state | muse: Map.put(state.muse, item["itemId"], item)}

    case {item["kind"], write} do
      {_, nil} ->
        state

      {kind, {field, text}} when kind in ["agentMessage", "reasoning"] and field == "text" ->
        kind = if kind == "agentMessage", do: :assistant, else: :reasoning
        state |> ensure_item(native, kind) |> buffer(native, "text", text)

      {_kind, {"output", text}} ->
        if Map.has_key?(state.items, native),
          do: buffer(state, native, "output", text),
          else: state

      _ ->
        state
    end
  end

  # A running item's fields as they change (arguments stream in).
  defp update_item(state, native, fields) do
    %{id: item_id} = state.items[native]
    at = Entities.now()
    # Streamed output is appended; a snapshot would race the buffer.
    fields = Map.delete(fields, "output")

    commit(state, fn stream ->
      [
        Orchestration.upsert(
          stream,
          "turn-item",
          item_id,
          &Map.merge(&1, Map.put(fields, "updatedAt", at))
        )
      ]
    end)

    state
  end

  @doc false
  # Unrecognized terminal states never show as successful work.
  def status(%{"status" => "inProgress"}), do: "running"
  def status(%{"status" => "cancelled"}), do: "cancelled"

  def status(%{"status" => "completed", "kind" => "compaction", "outcome" => outcome})
      when outcome not in [nil, "compacted"],
      do: "failed"

  def status(%{"status" => "completed"}), do: "completed"
  def status(_item), do: "failed"

  @doc false
  # A Muse tool, subagent or workflow as a turn item: `{kind, fields}`.
  def tool(item, status) do
    args = decode_args(item["args"])
    name = item["tool"] || item["kind"]

    title =
      case item["kind"] do
        "subagent" -> item["objective"] || item["role"] || "Muse agent"
        "workflow" -> item["entryId"] || "Workflow"
        _ -> name
      end

    detail =
      if status == "failed", do: item["failureReason"] || "Muse reported #{item["status"]}."

    text =
      item["visibleOutput"] || get_in(item, ["result", "summary"]) || item["text"] ||
        (is_list(item["summary"]) && Enum.join(item["summary"], "\n")) || item["finalSummary"] ||
        item["fallbackText"] || item["objective"] || ""

    output = [detail, text] |> Enum.filter(&(&1 not in [nil, ""])) |> Enum.join("\n")
    title = if detail, do: "#{title}: #{detail}", else: title
    string = fn keys -> Enum.find_value(keys, &(is_binary(args[&1]) && args[&1])) end

    cond do
      item["kind"] == "userShell" or
          (is_binary(item["tool"]) and item["tool"] =~ ~r/shell|bash|exec_command/i) ->
        {:command,
         %{
           "title" => title,
           "input" => item["commandText"] || string.(["command", "cmd"]) || item["args"] || "",
           "output" => output
         }
         |> put_present("exitCode", item["exitCode"])}

      item["kind"] == "toolCall" and name =~ ~r/write|edit|patch/i and
          is_binary(string.(["file_path", "path", "filePath"])) ->
        {:file,
         %{
           "title" => title,
           "fileName" => String.trim(string.(["file_path", "path", "filePath"]))
         }
         |> put_present("oldStr", string.(["old_string", "old_str", "oldStr", "oldText"]))
         |> put_present(
           "newStr",
           string.(["new_string", "new_str", "newStr", "newText", "content"])
         )
         |> put_present("diffStr", string.(["diff", "patch", "diffStr"]))}

      item["kind"] == "toolCall" and name =~ ~r/web|browse|fetch/i ->
        query = string.(["query", "url", "pattern"])

        {:web,
         %{"title" => title}
         |> put_present("patterns", query && [String.trim(query)])
         |> put_present(
           "results",
           web_results(item["tool"], detail, text, string.(["url"]), output)
         )}

      true ->
        {:tool,
         %{
           "title" => title,
           "toolName" => title,
           "input" => if(args == %{}, do: item["args"] || "", else: args),
           "output" => output
         }}
    end
  end

  # A search lists its hits; a page fetch (or a failure) shows its text under its link.
  defp web_results("web_search", nil, text, _url, _output) do
    case JSON.decode(text) do
      {:ok, %{"results" => results}} when is_list(results) ->
        for result <- results, is_map(result) do
          result
          |> Map.take(["url", "title", "snippet"])
          |> Map.reject(fn {_k, v} -> not is_binary(v) or String.trim(v) == "" end)
        end

      _ ->
        web_results(nil, nil, text, nil, text)
    end
  end

  defp web_results(_tool, _detail, _text, _url, ""), do: nil

  defp web_results(_tool, _detail, _text, url, output),
    do: [%{"snippet" => output} |> put_present("url", url && String.trim(url))]

  defp decode_args(args) when is_binary(args) do
    case JSON.decode(args) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  defp decode_args(_args), do: %{}

  # --- usage and retries -------------------------------------------------------------

  defp completed_usage(state, usage) when is_map(usage) do
    token_usage(state, %{
      "inputTokens" => usage["inputTokens"],
      "cachedInputTokens" => usage["cacheReadTokens"] || usage["cachedTokens"],
      "outputTokens" => usage["outputTokens"],
      "reasoningOutputTokens" => usage["reasoningTokens"]
    })
  end

  defp completed_usage(state, _usage), do: state

  # Muse reports a turn's context usage after it completes, and the next run may have
  # started meanwhile: the usage stays with the turn it followed.
  defp last_turn_usage(%{last_ids: nil} = state, _usage), do: state

  defp last_turn_usage(state, usage) do
    usage = Map.put(usage, "updatedAt", Entities.now())
    ids = state.last_ids

    commit(state, fn stream ->
      [
        Orchestration.upsert(
          stream,
          "provider-thread",
          ids.provider_thread,
          &Map.put(&1, "contextUsage", usage)
        ),
        Orchestration.upsert(
          stream,
          "provider-turn",
          ids.provider_turn,
          &Map.put(&1, "tokenUsage", Map.merge(&1["tokenUsage"] || %{}, usage))
        )
      ]
    end)

    state
  end

  # The meter needs Muse's context usage, which the provider thread keeps (the meter
  # reads it there) and the turn records; the turn's totals ride along with it.
  defp token_usage(state, usage) do
    usage = Map.merge(state.usage, Map.reject(usage, fn {_k, v} -> v == nil end))
    state = %{state | usage: usage}
    ids = if state.turn, do: state.turn.ids, else: state.last_ids

    if is_integer(usage["usedTokens"]) and ids do
      usage = Map.put(usage, "updatedAt", Entities.now())

      commit(state, fn stream ->
        [
          Orchestration.upsert(
            stream,
            "provider-thread",
            ids.provider_thread,
            &Map.put(&1, "contextUsage", usage)
          ),
          Orchestration.upsert(
            stream,
            "provider-turn",
            ids.provider_turn,
            &Map.put(&1, "tokenUsage", usage)
          )
        ]
      end)
    end

    state
  end

  # A provider retry is one item per turn, running until the turn goes on or ends.
  defp retry(state, params) do
    native = "terminal-failure:#{state.turn.ids.provider_turn}"
    attempt = max(1, params["nextAttempt"] || 1)

    fields = %{
      "title" => "Provider retry",
      "failure" => %{
        "class" => "provider_error",
        "message" => params["reason"] || "Muse is retrying the request.",
        "code" => nil,
        "retryable" => true
      },
      "retry" => %{
        "attempt" => attempt,
        "maxAttempts" => max(attempt, params["maxAttempts"] || attempt),
        "retryDelayMs" => max(0, round(params["retryDelayMs"] || 0))
      }
    }

    state = state |> flush() |> ensure_item(native, :error, fields)
    update_item(state, native, Map.put(fields, "status", "running"))
  end

  # --- approvals and questions -------------------------------------------------------

  defp open?(state, native),
    do:
      Enum.any?(state.requests, fn {_id, {_, req}} ->
        (req["approvalId"] || req["userInputId"]) == native
      end)

  defp approval(state, method, %{"approvalId" => id} = approval) do
    child? = approval["subagentOrigin"] != nil

    cond do
      # A newer requirement on an open prompt: the answer goes to it. One for a request
      # never stored (a workflow child's, accepted for it) is asked like a new one.
      method == "approval/updated" and open?(state, id) ->
        requests =
          Map.new(state.requests, fn
            {rid, {:approval, %{"approvalId" => ^id}}} -> {rid, {:approval, approval}}
            other -> other
          end)

        %{state | requests: requests}

      open?(state, id) ->
        state

      not child? and not owns?(state, approval["turnId"]) ->
        state

      # Muse does not give a workflow's children the session's allowAll mode. One Muse
      # will not take an accept for goes to the user instead.
      child? and elem(state.host, 1) == "full-access" and accepted?(state, approval) ->
        state

      true ->
        native = "#{state.turn.ids.run}:approval:#{id}"
        subject = approval["subject"] || %{}

        prompt =
          subject["command"] || subject["path"] || subject["host"] || subject["target"] ||
            approval["toolName"] || "Muse requests permission"

        {state, request_id} = open_request(flush(state), native, request_kind(subject), prompt)
        %{state | requests: Map.put(state.requests, request_id, {:approval, approval})}
    end
  end

  defp approval(state, _method, _params), do: state

  defp accepted?(state, approval) do
    case choices(approval)["accept"] do
      %{"choiceId" => choice} ->
        match?(
          {:ok, _},
          command(state, "approval/decide", %{
            "approvalId" => approval["approvalId"],
            "requirementId" => approval["currentRequirementId"],
            "choiceId" => choice
          })
        )

      nil ->
        false
    end
  end

  @doc false
  def request_kind(%{"kind" => "shell"}), do: "command"
  def request_kind(%{"kind" => "fileAccess", "access" => "read"}), do: "file-read"
  def request_kind(%{"kind" => "fileAccess"}), do: "file-change"
  def request_kind(_subject), do: "permission"

  @doc false
  # HAL-C2's decision for one of Muse's choices, or nil when it has none.
  def decision(%{"decision" => "approved"}), do: "accept"
  def decision(%{"decision" => "approvedForSession"}), do: "acceptForSession"

  def decision(%{"decision" => "approvedPolicyAmendment", "scope" => "session"}),
    do: "acceptForSession"

  def decision(%{"decision" => "approvedPolicyAmendment", "scope" => "localPersistent"}),
    do: "acceptAlways"

  def decision(%{"decision" => d}) when d in ["denied", "deniedPolicyAmendment"], do: "decline"
  def decision(%{"decision" => "abort"}), do: "cancel"
  def decision(_choice), do: nil

  @doc false
  # One native choice per decision, the narrowest scope first. Shell approvals offer
  # no `denied`, only `abort` ("Reject"), so declining falls back to it.
  def choices(approval) do
    rank = fn choice ->
      scope =
        case choice["scope"] do
          "once" -> 0
          "session" -> 2
          _ -> 4
        end

      scope + if(String.ends_with?(choice["decision"] || "", "PolicyAmendment"), do: 1, else: 0)
    end

    choices =
      (approval["availableChoices"] || [])
      |> Enum.filter(&decision/1)
      |> Enum.sort_by(rank)
      |> Enum.reduce(%{}, fn choice, acc -> Map.put_new(acc, decision(choice), choice) end)

    if choices["cancel"] && !choices["decline"],
      do: Map.put(choices, "decline", choices["cancel"]),
      else: choices
  end

  defp question(state, input) do
    native = "#{state.turn.ids.run}:question:#{input["userInputId"]}"

    questions =
      for question <- input["questions"] || [] do
        %{
          "id" => question["id"],
          "header" => non_empty(question["header"], "Question"),
          "question" => question["question"] || "",
          "options" =>
            for option <- question["options"] || [] do
              %{
                "label" => option["label"],
                "description" => non_empty(option["description"], option["label"])
              }
            end,
          "multiSelect" => get_in(question, ["selection", "mode"]) == "multiple"
        }
      end

    {state, request_id} = open_question(flush(state), native, questions)
    %{state | requests: Map.put(state.requests, request_id, {:question, input})}
  end

  # Muse cannot leave a question unanswered: a dismissed one tells it so, and the turn
  # goes on.
  defp question_answers(questions, %{"dismissed" => true}) when is_list(questions),
    do:
      {:ok,
       for(
         %{"id" => id} <- questions,
         do: %{"questionId" => id, "freeText" => "The user dismissed the question."}
       )}

  defp question_answers(questions, response), do: answers(questions, response["answers"])

  @doc false
  # The user's answers in Muse's shape: chosen labels, and anything else as free text.
  def answers(questions, answers) when is_list(questions) and is_map(answers) do
    Enum.reduce_while(questions, {:ok, []}, fn question, {:ok, acc} ->
      values =
        case answers[question["id"]] do
          value when is_binary(value) -> [value]
          values when is_list(values) -> values |> Enum.filter(&is_binary/1) |> Enum.uniq()
          _ -> []
        end

      labels = for %{"label" => label} <- question["options"] || [], do: label
      {selected, free} = Enum.split_with(values, &(&1 in labels))
      free = Enum.join(free, "\n")
      selection = question["selection"] || %{}
      single? = selection["mode"] != "multiple"

      cond do
        free == "" and selected == [] ->
          {:halt, {:error, "Muse needs an answer to every question."}}

        # Muse counts UTF-16 code units, as JavaScript does.
        HalC2.Acp.Auth.utf16_length(free) > @max_free_text ->
          {:halt, {:error, "Muse takes at most #{@max_free_text} characters of free text."}}

        (single? and length(selected) > 1) or
            (selected != [] and
               (length(selected) < (selection["minSelections"] || 0) or
                  length(selected) > (selection["maxSelections"] || length(selected)))) ->
          {:halt, {:error, "That is not a valid number of choices for this question."}}

        true ->
          answer =
            %{"questionId" => question["id"]}
            |> then(fn a ->
              cond do
                selected == [] -> a
                single? -> Map.put(a, "selectedLabel", hd(selected))
                true -> Map.put(a, "selectedLabels", selected)
              end
            end)
            |> then(fn a ->
              cond do
                free == "" -> a
                selected == [] -> Map.put(a, "freeText", free)
                true -> Map.put(a, "note", free)
              end
            end)

          {:cont, {:ok, acc ++ [answer]}}
      end
    end)
  end

  def answers(_questions, _answers), do: {:error, "Muse needs an answer to every question."}

  defp submitted(state, request_id, answer) do
    requests =
      Map.update!(state.requests, request_id, fn {kind, req} ->
        {kind, Map.put(req, :submitted, answer)}
      end)

    %{state | requests: requests}
  end

  defp cancel_requests(state) do
    Enum.reduce(state.requests, %{state | requests: %{}}, fn {request_id, _}, state ->
      resolve_request(state, request_id, nil, "cancelled")
    end)
  end

  # --- end of turn -------------------------------------------------------------------

  defp end_turn(state, status, failure) do
    state = state |> flush() |> close_open_items(status) |> cancel_requests()
    finish(state, status, failure)

    %{
      state
      | turn: nil,
        last_ids: state.turn.ids,
        items: %{},
        muse: %{},
        joined: MapSet.new(),
        compact: false
    }
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, []), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp non_empty(value, fallback) when is_binary(value),
    do: if(String.trim(value) == "", do: fallback, else: value)

  defp non_empty(_value, fallback), do: fallback

  defp format(reason) when is_binary(reason), do: reason
  defp format(%{"message" => message}) when is_binary(message), do: message
  defp format(:closed), do: "Muse Code stopped"
  defp format(reason), do: inspect(reason)
end
