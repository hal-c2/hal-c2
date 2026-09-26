defmodule T3.Pi.ThreadRuntime do
  @moduledoc """
  Runs one thread's turns on Pi's RPC mode (`pi --mode rpc`, `T3.Pi`), as the
  Node server's `PiAdapterV2` does, and writes them into the thread's log.

  One Pi process serves the thread while its access mode stays the same (T3's Pi
  extension reads the mode when Pi starts). The thread's native conversation is
  Pi's session file: a new process `switch_session`s to it, a rewind `fork`s it
  before the first dropped turn, and a forked thread starts from a copy made with
  `pi --fork`. A message is a `prompt` (T3's `$skill`s become Pi's `/skill:`
  commands, `/compact` is Pi's `compact`); Pi's events stream text, thinking,
  tools, retries and compactions into items, and `agent_settled` ends the turn
  with the session's entries (the turn's native ref, the conversation head) and
  its context usage. Extension dialogs are approvals (`confirm`) and questions
  (`select`, `input`, `editor`). Interrupt is `abort`.
  """

  use GenServer, restart: :temporary

  require Logger

  import T3.Orchestration.TurnWriter

  alias T3.JsonRpc.Connection
  alias T3.Orchestration
  alias T3.Orchestration.Entities

  @state_version 1
  @registry T3.Pi.Registry

  @spec start_turn(String.t(), map) :: :ok
  def start_turn(thread_id, turn),
    do: thread_id |> ensure() |> GenServer.call({:start_turn, turn}, 120_000)

  @spec interrupt(String.t(), String.t() | nil) :: :ok | {:error, String.t()}
  def interrupt(thread_id, _run_id) do
    case lookup(thread_id) do
      nil -> {:error, "no active Pi turn in this thread"}
      pid -> GenServer.call(pid, :interrupt, 15_000)
    end
  end

  @doc "Pi's RPC mode takes no input while a prompt runs."
  def steer(_thread_id, _run_id, _text), do: {:error, "Pi cannot be steered"}

  @spec respond(String.t(), String.t(), map) :: :ok | {:error, String.t()}
  def respond(thread_id, request_id, response) do
    case lookup(thread_id) do
      nil -> {:error, "no pending request"}
      pid -> GenServer.call(pid, {:respond, request_id, response})
    end
  end

  @doc """
  Rewinds Pi's session: Pi forks it before the first dropped turn's user message,
  and the thread continues in the new session file.
  """
  @spec rollback(String.t(), map) :: {:ok, map} | {:error, String.t()}
  def rollback(thread_id, plan),
    do: thread_id |> ensure() |> GenServer.call({:rollback, plan}, 120_000)

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
    case DynamicSupervisor.start_child(T3.Plugins.sessions("acp"), {__MODULE__, thread_id}) do
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
       instance: nil,
       mode: nil,
       # Pi's session file, the thread's native conversation.
       session: nil,
       model: nil,
       thinking: nil,
       context_window: nil,
       # The session's last entry when the turn started: `get_entries` since it.
       leaf: nil,
       skills: [],
       turn: nil,
       # A `/compact` runs as a call rather than a prompt.
       compact: nil,
       items: %{},
       buffer: %{},
       flush_timer: nil,
       interrupted: false,
       failure: nil,
       message: 0,
       compactions: 0,
       retry: nil,
       live_tokens: nil,
       # Open dialogs: request id -> {:confirm, ui id, key} | {:question, ui id, native}.
       requests: %{},
       # Confirmations the user allowed for the session.
       allowed: MapSet.new()
     }}
  end

  @impl true
  def handle_call({:start_turn, turn}, _from, state) do
    ids = Map.put(turn.ids, :provider_turn, "provider-turn:#{turn.ids.driver}:#{turn.ids.run}")
    turn = %{turn | ids: ids}

    state = %{
      state
      | turn: turn,
        items: %{},
        interrupted: false,
        failure: nil,
        message: 0,
        compactions: 0,
        retry: nil,
        live_tokens: nil
    }

    with {:ok, state} <- ensure_session(state, turn),
         {:ok, state} <- select_model(state, turn.model),
         {:ok, state} <- select_thinking(state, option(turn, "thinking")) do
      started(state)
      {:reply, :ok, send_prompt(state, turn)}
    else
      {:error, reason, state} ->
        Logger.warning("pi turn failed to start: #{inspect(reason)}")
        finish(state, "failed", "Pi could not start: #{format(reason)}")
        {:reply, :ok, %{state | turn: nil}}
    end
  end

  def handle_call(:interrupt, _from, %{turn: turn} = state) when turn != nil do
    Connection.notify(state.conn, "abort", %{})
    {:reply, :ok, %{cancel_requests(state) | interrupted: true}}
  end

  def handle_call(:interrupt, _from, state), do: {:reply, {:error, "no running turn"}, state}

  def handle_call({:rollback, _plan}, _from, %{turn: turn} = state) when turn != nil,
    do: {:reply, {:error, "Interrupt the current turn before rewinding."}, state}

  def handle_call({:rollback, plan}, _from, state) do
    entry = plan.first_dropped

    session = %{
      instance: plan.instance,
      runtime_mode: state.mode || "approval-required",
      cwd: plan.cwd,
      native_thread_id: plan.native_thread_id,
      thread_id: plan.thread_id
    }

    with true <- is_binary(entry) || {:error, "Pi has no native turn to rewind to.", state},
         {:ok, state} <- open(state, session),
         {:ok, _} <- call(state, "fork", %{"entryId" => entry}),
         {:ok, pi} <- call(state, "get_state", %{}),
         {:ok, entries} <- call(state, "get_entries", %{}) do
      file = pi["sessionFile"]
      head = entries["leafId"]
      state = %{state | session: file, leaf: head}

      {:reply,
       {:ok,
        %{
          "nativeThreadRef" => Entities.provider_ref(file, plan.driver),
          "nativeConversationHeadRef" => head && Entities.provider_ref(head, plan.driver)
        }}, state}
    else
      {:error, reason, state} -> {:reply, {:error, format(reason)}, state}
      {:error, reason} -> {:reply, {:error, format(reason)}, state}
    end
  end

  def handle_call({:respond, request_id, response}, _from, state) do
    case Map.pop(state.requests, request_id) do
      {nil, _} ->
        {:reply, {:error, "no pending request #{request_id}"}, state}

      {{:confirm, ui_id, key}, requests} ->
        decision = response["decision"] || "decline"

        reply =
          case decision do
            d when d in ["accept", "acceptForSession", "acceptAlways"] -> %{"confirmed" => true}
            "decline" -> %{"confirmed" => false}
            _ -> %{"cancelled" => true}
          end

        ui_reply(state, ui_id, reply)

        allowed =
          if decision in ["acceptForSession", "acceptAlways"],
            do: MapSet.put(state.allowed, key),
            else: state.allowed

        state = %{state | requests: requests, allowed: allowed}
        {:reply, :ok, resolve_request(state, request_id, decision)}

      {{:question, ui_id, native}, requests} ->
        value = if is_map(response["answers"]), do: answer(response["answers"][native])

        {reply, status} =
          if response["dismissed"] || value == nil,
            do: {%{"cancelled" => true}, "cancelled"},
            else: {%{"value" => value}, "resolved"}

        ui_reply(state, ui_id, reply)
        state = %{state | requests: requests}
        {:reply, :ok, resolve_request(state, request_id, response, status)}
    end
  end

  @impl true
  def handle_info({:json_rpc, conn, {:notification, type, event}}, %{conn: conn} = state) do
    if state.turn, do: {:noreply, event(type, event, state)}, else: {:noreply, state}
  end

  # A `/compact` came back.
  def handle_info({ref, result}, %{compact: ref} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | compact: nil}

    state =
      case result do
        {:error, reason} when not state.interrupted -> %{state | failure: format(reason)}
        _ -> state
      end

    {:noreply, settle(state)}
  end

  def handle_info({:EXIT, conn, _reason}, %{conn: conn} = state) do
    state = if state.turn, do: end_turn(state, "failed", "Pi exited unexpectedly"), else: state
    {:noreply, %{state | conn: nil, compact: nil}}
  end

  def handle_info(:flush, state), do: {:noreply, flush(%{state | flush_timer: nil}, :timer)}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.conn, do: Connection.stop(state.conn)
    :ok
  end

  @impl true
  def code_change(_old, state, _extra), do: {:ok, migrate(state)}

  # Every older state shape migrates forward here.
  defp migrate(%{v: @state_version} = state), do: state

  # --- session -------------------------------------------------------------------

  defp ensure_session(state, turn) do
    turn = Map.merge(turn, %{instance: Entities.instance(turn.ids), thread_id: state.thread_id})

    with {:ok, forked} <- fork_first(state, turn),
         {:ok, state} <- open(state, forked) do
      if state.session != turn.native_thread_id, do: record_session(state, state.session)
      {:ok, state}
    end
  end

  # A forked thread's first turn starts from a copy of the source's session, cut
  # before the turn after the fork point, made by a short-lived Pi of its own.
  defp fork_first(state, %{fork: %{thread: source} = fork} = turn) when is_binary(source) do
    with {:ok, argv, env} <-
           T3.Pi.launch(turn.instance, bare: true, extra: ["--fork", source])
           |> launch_error(state),
         {:ok, conn} <- connect(argv, env, turn.cwd, state) do
      try do
        with {:ok, _} <- cut(conn, fork[:before]),
             {:ok, %{"sessionFile" => file}} when is_binary(file) and file != source <-
               Connection.call(conn, "get_state", %{}) do
          {:ok, %{turn | native_thread_id: file}}
        else
          {:error, reason} -> {:error, reason, state}
          _ -> {:error, "Pi could not fork the session", state}
        end
      after
        Connection.stop(conn)
      end
    end
  end

  defp fork_first(_state, turn), do: {:ok, turn}

  defp cut(_conn, nil), do: {:ok, nil}
  defp cut(conn, entry), do: Connection.call(conn, "fork", %{"entryId" => entry}, 60_000)

  # T3's extension reads the access mode when Pi starts, so a new mode is a new Pi.
  defp open(%{conn: conn, instance: instance, mode: mode} = state, turn)
       when conn != nil and instance == turn.instance and mode == turn.runtime_mode do
    switch(state, turn.native_thread_id)
  end

  defp open(state, turn) do
    if state.conn, do: Connection.stop(state.conn)
    state = %{state | conn: nil, session: nil, model: nil, thinking: nil}
    mcp = T3.Mcp.for_agent(turn.thread_id, turn.instance)

    with {:ok, argv, env} <-
           T3.Pi.launch(turn.instance, runtime_mode: turn.runtime_mode, mcp: mcp)
           |> launch_error(state),
         {:ok, conn} <- connect(argv, env, turn.cwd, state) do
      state = %{state | conn: conn, instance: turn.instance, mode: turn.runtime_mode}

      skills =
        case Connection.call(conn, "get_commands", %{}) do
          {:ok, data} -> data |> T3.Pi.parse_commands() |> elem(1) |> Enum.map(& &1["name"])
          {:error, _} -> []
        end

      switch(%{state | skills: skills}, turn.native_thread_id)
    end
  end

  defp launch_error({:error, message}, state), do: {:error, message, state}
  defp launch_error(ok, _state), do: ok

  defp connect(argv, env, cwd, state) do
    case Connection.start_link(cmd: argv, handler: self(), cd: cwd, env: env, dialect: :pi) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # Continues the thread's session file, or the new session Pi started with.
  defp switch(%{session: file} = state, file) when is_binary(file), do: {:ok, state}

  defp switch(state, file) do
    with {:ok, _} <-
           if(is_binary(file),
             do: call(state, "switch_session", %{"sessionPath" => file}),
             else: {:ok, nil}
           ),
         {:ok, pi} <- call(state, "get_state", %{}),
         {:ok, entries} <- call(state, "get_entries", %{}) do
      {:ok,
       remember_model(
         %{
           state
           | session: pi["sessionFile"],
             leaf: entries["leafId"],
             thinking: pi["thinkingLevel"]
         },
         pi["model"]
       )}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp remember_model(state, %{"provider" => provider, "id" => id} = model),
    do: %{state | model: "#{provider}/#{id}", context_window: positive(model["contextWindow"])}

  defp remember_model(state, _model), do: state

  defp call(state, type, params), do: Connection.call(state.conn, type, params, 60_000)

  # "Pi default" leaves the model to the user's own Pi settings.
  defp select_model(state, model)
       when is_binary(model) and model not in ["", "default"] and model != state.model do
    with [provider, id] <- String.split(model, "/", parts: 2),
         {:ok, _} <- call(state, "set_model", %{"provider" => provider, "modelId" => id}),
         {:ok, pi} <- call(state, "get_state", %{}) do
      {:ok, remember_model(%{state | model: model}, pi["model"])}
    else
      {:error, reason} -> {:error, "could not select #{model}: #{format(reason)}", state}
      _ -> {:error, "unknown Pi model #{model}", state}
    end
  end

  defp select_model(state, _model), do: {:ok, state}

  defp select_thinking(state, level) when is_binary(level) and level != state.thinking do
    case call(state, "set_thinking_level", %{"level" => level}) do
      {:ok, _} -> {:ok, %{state | thinking: level}}
      {:error, reason} -> {:error, "could not set thinking to #{level}: #{format(reason)}", state}
    end
  end

  defp select_thinking(state, _level), do: {:ok, state}

  # The composer's options arrive as option id -> value (`Orchestration` turn fields).
  defp option(turn, id) do
    case (Map.get(turn, :options) || %{})[id] do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp send_prompt(state, turn) do
    case Regex.run(~r/^\/compact(?:\s+(.*))?$/s, String.trim(turn.text)) do
      [_ | instructions] ->
        params =
          case instructions do
            [text] when text != "" -> %{"customInstructions" => text}
            _ -> %{}
          end

        conn = state.conn
        task = Task.async(fn -> Connection.call(conn, "compact", params, :infinity) end)
        %{state | compact: task.ref}

      nil ->
        message =
          turn.text
          |> T3.Pi.expand_skills(state.skills)
          |> T3.Attachments.prompt_text(Map.get(turn, :attachments, []))

        Connection.notify(state.conn, "prompt", %{"message" => message})
        state
    end
  end

  defp record_session(state, file) do
    ids = state.turn.ids

    commit(state, fn stream ->
      [
        Orchestration.upsert(
          stream,
          "provider-thread",
          ids.provider_thread,
          &Map.put(&1, "nativeThreadRef", Entities.provider_ref(file, ids.driver))
        )
      ]
    end)
  end

  # --- events --------------------------------------------------------------------

  # The prompt's acknowledgement: a refused prompt ends the turn.
  defp event("response", %{"command" => "prompt", "success" => false} = event, state),
    do: end_turn(state, "failed", event["error"] || "Pi refused the prompt")

  defp event("message_start", %{"message" => %{"role" => "assistant"}}, state),
    do: %{state | message: state.message + 1}

  defp event("message_update", event, state) do
    state = live_usage(state, event["usage"] || get_in(event, ["message", "usage"]))

    case event["assistantMessageEvent"] do
      %{"type" => "text_delta", "delta" => delta} when is_binary(delta) ->
        native = "#{state.turn.ids.run}:message:#{state.message}"
        state |> ensure_item(native, :assistant) |> buffer(native, "text", delta)

      %{"type" => "thinking_delta", "delta" => delta} when is_binary(delta) ->
        native = "#{state.turn.ids.run}:thinking:#{state.message}"
        state |> ensure_item(native, :reasoning) |> buffer(native, "text", delta)

      _ ->
        state
    end
  end

  defp event("message_end", %{"message" => %{"stopReason" => "error"} = message}, state),
    do: %{state | failure: message["errorMessage"] || "Pi request failed"}

  defp event("tool_execution_start", %{"toolCallId" => id} = event, state) do
    {kind, fields} = tool_shape(event["toolName"], event["args"] || %{})
    state |> flush() |> ensure_item(tool_native(state, id), kind, fields)
  end

  defp event("tool_execution_end", %{"toolCallId" => id} = event, state) do
    native = tool_native(state, id)

    state =
      if Map.has_key?(state.items, native),
        do: state,
        else: event("tool_execution_start", event, state)

    %{kind: kind} = state.items[native]
    output = result_text(event["result"])
    status = if event["isError"] == true, do: "failed", else: "completed"

    finish_item(state, native, status, fn entity ->
      case kind do
        :command ->
          exit_code = get_in(event, ["result", "details", "exitCode"])

          entity
          |> Map.put("output", output)
          |> then(&if(is_integer(exit_code), do: Map.put(&1, "exitCode", exit_code), else: &1))

        :file ->
          Map.put(entity, "diffStr", output)

        _ ->
          Map.put(entity, "output", output)
      end
    end)
  end

  defp event("compaction_start", _event, state) do
    n = state.compactions + 1
    native = "compaction:#{state.turn.ids.provider_turn}:#{n}"

    state
    |> flush()
    |> Map.put(:compactions, n)
    |> ensure_item(native, :compaction, %{"driver" => "pi", "title" => "Compacting context..."})
  end

  defp event("compaction_end", event, state) do
    native = "compaction:#{state.turn.ids.provider_turn}:#{state.compactions}"

    if Map.has_key?(state.items, native) do
      result = event["result"] || %{}

      {status, title} =
        cond do
          event["aborted"] == true -> {"cancelled", "Context compaction stopped"}
          is_binary(event["errorMessage"]) -> {"failed", "Context compaction failed"}
          true -> {"completed", "Context compacted"}
        end

      finish_item(state, native, status, fn entity ->
        entity
        |> Map.put("title", title)
        |> put_present("summary", result["summary"])
        |> put_present("beforeTokenCount", result["tokensBefore"])
        |> put_present("afterTokenCount", result["estimatedTokensAfter"])
      end)
    else
      state
    end
  end

  defp event("auto_retry_start", event, state) do
    attempt = max(1, event["attempt"] || 1)

    retry = %{
      "attempt" => attempt,
      "maxAttempts" => max(attempt, event["maxAttempts"] || attempt),
      "retryDelayMs" => max(0, event["delayMs"] || 0)
    }

    failure = provider_failure(event["errorMessage"] || "Pi provider request failed.", true)
    retry_item(state, "running", "Provider retry", failure, retry)
  end

  defp event("auto_retry_end", %{"success" => true} = event, state) do
    state = %{state | failure: nil}

    case state.retry do
      nil ->
        state

      %{failure: failure, retry: retry} ->
        retry = Map.put(retry, "attempt", event["attempt"] || retry["attempt"])
        retry_item(state, "completed", "Provider recovered", failure, retry)
    end
  end

  defp event("auto_retry_end", event, state) do
    message = event["finalError"] || "Pi auto-retry failed."
    attempt = max(1, event["attempt"] || 1)
    previous = (state.retry && state.retry.retry) || %{}

    retry = %{
      "attempt" => attempt,
      "maxAttempts" => previous["maxAttempts"] || attempt,
      "retryDelayMs" => previous["retryDelayMs"]
    }

    state = retry_item(state, "failed", "Provider error", provider_failure(message, false), retry)
    %{state | failure: message}
  end

  defp event("extension_ui_request", %{"id" => ui_id, "method" => method} = request, state) do
    dialog(method, ui_id, request, state)
  end

  defp event("agent_settled", _event, %{compact: nil} = state), do: settle(state)

  defp event(_type, _event, state), do: state

  defp tool_native(state, id), do: "#{state.turn.ids.run}:tool:#{id}"

  defp tool_shape("bash", args),
    do: {:command, %{"input" => args["command"] || "", "output" => ""}}

  defp tool_shape(name, args) when name in ["edit", "write"] do
    case args["path"] || args["file_path"] do
      path when is_binary(path) -> {:file, %{"fileName" => path}}
      _ -> {:tool, %{"toolName" => name, "input" => args}}
    end
  end

  defp tool_shape(name, args), do: {:tool, %{"toolName" => name || "tool", "input" => args}}

  defp result_text(%{"content" => content}) when is_list(content) do
    for(%{"type" => "text", "text" => text} <- content, do: text) |> Enum.join("\n")
  end

  defp result_text(_result), do: ""

  defp provider_failure(message, retryable),
    do: %{
      "class" => "provider_error",
      "message" => message,
      "code" => nil,
      "retryable" => retryable
    }

  # A provider retry is one item per turn (`terminal-failure:<provider turn>`).
  defp retry_item(state, status, title, failure, retry) do
    native = "terminal-failure:#{state.turn.ids.provider_turn}"
    fields = %{"title" => title, "failure" => failure, "retry" => retry}
    state = state |> flush() |> ensure_item(native, :error, fields)
    state = %{state | retry: %{failure: failure, retry: retry}}

    if status == "running" do
      %{id: item_id} = state.items[native]
      at = Entities.now()

      commit(state, fn stream ->
        [
          Orchestration.upsert(
            stream,
            "turn-item",
            item_id,
            &Map.merge(&1, Map.merge(fields, %{"status" => "running", "updatedAt" => at}))
          )
        ]
      end)

      state
    else
      finish_item(state, native, status, &Map.merge(&1, fields))
    end
  end

  # Pi attaches the message's usage to streaming updates; the meter moves when it changes.
  defp live_usage(%{context_window: window} = state, %{"totalTokens" => used} = usage)
       when is_integer(window) and window > 0 and is_integer(used) and used > 0 do
    if used == state.live_tokens do
      state
    else
      token_usage(state, %{
        "usedTokens" => used,
        "maxTokens" => window,
        "inputTokens" => usage["input"],
        "cachedInputTokens" => usage["cacheRead"],
        "outputTokens" => usage["output"]
      })
      |> Map.put(:live_tokens, used)
    end
  end

  defp live_usage(state, _usage), do: state

  defp token_usage(state, usage) do
    usage =
      usage
      |> Enum.reject(fn {_k, v} -> v == nil end)
      |> Map.new()
      |> Map.put("updatedAt", Entities.now())

    commit(state, fn stream ->
      [
        Orchestration.upsert(
          stream,
          "provider-turn",
          state.turn.ids.provider_turn,
          &Map.put(&1, "tokenUsage", usage)
        )
      ]
    end)

    state
  end

  # --- extension dialogs ---------------------------------------------------------

  defp dialog("notify", ui_id, request, state) do
    native = "#{state.turn.ids.run}:ui:#{ui_id}"
    message = request["message"] || request["title"] || ""

    state
    |> flush()
    |> ensure_item(native, :tool, %{"toolName" => "notify", "input" => %{"message" => message}})
    |> finish_item(native, "completed", &Map.put(&1, "output", message))
  end

  # T3's extension asks before a tool the access mode does not allow.
  defp dialog("confirm", ui_id, request, state) do
    title = request["title"] || ""
    message = request["message"]
    key = "#{String.length(title)}:#{title}#{message}"

    if MapSet.member?(state.allowed, key) do
      ui_reply(state, ui_id, %{"confirmed" => true})
      state
    else
      kind = if title =~ ~r/^Allow (edit|write)\?$/, do: "file-change", else: "command"
      prompt = if message in [nil, ""], do: title, else: message
      native = "#{state.turn.ids.run}:ui:#{ui_id}"
      {state, request_id} = open_request(flush(state), native, kind, prompt)
      %{state | requests: Map.put(state.requests, request_id, {:confirm, ui_id, key})}
    end
  end

  defp dialog(method, ui_id, request, state) when method in ["select", "input", "editor"] do
    native = "#{state.turn.ids.run}:ui:#{ui_id}"
    title = request["title"] || "Pi"

    options =
      case method do
        "select" ->
          for option <- request["options"] || [],
              do: %{
                "label" => if(option in [nil, ""], do: "Empty value", else: option),
                "description" => option,
                "value" => option
              }

        _ ->
          [
            %{
              "label" => "Submit empty value",
              "description" => "Submit empty value",
              "value" => ""
            }
          ]
      end

    question = %{
      "id" => native,
      "header" => title,
      "question" => request["message"] || request["placeholder"] || title,
      "options" => options
    }

    {state, request_id} = open_question(flush(state), native, [question])
    %{state | requests: Map.put(state.requests, request_id, {:question, ui_id, native})}
  end

  defp dialog(_method, _ui_id, _request, state), do: state

  defp ui_reply(state, ui_id, reply),
    do: Connection.notify(state.conn, "extension_ui_response", Map.put(reply, "id", ui_id))

  defp answer([value | _]), do: answer(value)
  defp answer(value) when is_binary(value), do: value
  defp answer(_value), do: nil

  defp cancel_requests(state) do
    Enum.reduce(state.requests, %{state | requests: %{}}, fn {request_id, request}, state ->
      ui_id = elem(request, 1)
      ui_reply(state, ui_id, %{"cancelled" => true})
      resolve_request(state, request_id, nil, "cancelled")
    end)
  end

  # --- end of turn -----------------------------------------------------------------

  # The session's entries since the turn started name the turn (its user message)
  # and the conversation's new head; the session's stats give its context usage.
  defp settle(state) do
    ids = state.turn.ids
    driver = ids.driver

    state =
      case call(state, "get_entries", %{"since" => state.leaf}) do
        {:ok, %{"entries" => entries} = data} ->
          user =
            Enum.find(entries || [], &(get_in(&1, ["message", "role"]) == "user"))

          head = data["leafId"]

          commit(state, fn stream ->
            [
              user &&
                Orchestration.upsert(
                  stream,
                  "provider-turn",
                  ids.provider_turn,
                  &Map.put(&1, "nativeTurnRef", Entities.provider_ref(user["id"], driver))
                ),
              head &&
                Orchestration.upsert(
                  stream,
                  "provider-thread",
                  ids.provider_thread,
                  &Map.put(&1, "nativeConversationHeadRef", Entities.provider_ref(head, driver))
                )
            ]
          end)

          %{state | leaf: head || state.leaf}

        _ ->
          state
      end

    state =
      case Connection.call(state.conn, "get_session_stats", %{}, 2_000) do
        {:ok, %{"contextUsage" => %{"tokens" => used, "contextWindow" => window}} = stats}
        when is_integer(used) and is_integer(window) and window > 0 ->
          totals = stats["tokens"] || %{}

          token_usage(state, %{
            "usedTokens" => used,
            "maxTokens" => window,
            "inputTokens" => totals["input"],
            "cachedInputTokens" => totals["cacheRead"],
            "outputTokens" => totals["output"]
          })

        _ ->
          state
      end

    cond do
      state.interrupted -> end_turn(state, "interrupted", nil)
      state.failure -> end_turn(state, "failed", state.failure)
      true -> end_turn(state, "completed", nil)
    end
  catch
    :exit, _ -> end_turn(state, "failed", "Pi exited unexpectedly")
  end

  defp end_turn(state, status, failure) do
    state = state |> flush() |> close_open_items(status) |> cancel_requests()
    finish(state, status, failure)
    %{state | turn: nil, items: %{}}
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp positive(n) when is_integer(n) and n > 0, do: n
  defp positive(_n), do: nil

  defp format(reason) when is_binary(reason), do: reason
  defp format(%{"message" => message}), do: message
  defp format(reason), do: inspect(reason)
end
