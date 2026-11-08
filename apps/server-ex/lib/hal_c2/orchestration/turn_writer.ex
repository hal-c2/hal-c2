defmodule HalC2.Orchestration.TurnWriter do
  @moduledoc """
  Writes a provider turn into its thread's log; shared by the provider runtimes.

  A runtime keeps a state map with `:thread_id`, `:turn` (holding the run's
  `ids`), `:items` (native item id to its turn item, node, and message),
  `:buffer`, and `:flush_timer`. Streamed text and output are buffered for
  `@flush_ms` and written as appends; the runtime forwards its `:flush` message to
  `flush/1`.
  """

  alias HalC2.Orchestration
  alias HalC2.Orchestration.{CommandOutput, CommandTail, Entities, TurnWatch, UserFacingErrors}
  alias HalC2.PullRequests.Opened
  alias HalC2.StreamState

  @flush_ms 50
  @active_runs ~w(preparing starting running waiting)
  @open ~w(pending running waiting)
  @text_ms 400

  @doc """
  Why a turn could not start, for its failed run: the provider (`label`) exited
  (`:closed`), or refused with `reason`.
  """
  def start_failure(_label, :closed), do: "The provider stopped while starting the turn."

  def start_failure(label, reason) when is_binary(reason),
    do: "#{label} could not start: #{reason}"

  def start_failure(label, reason), do: "#{label} could not start: #{inspect(reason)}"

  @doc "The turn item id for a provider's native item."
  def item_id(ids, native), do: "turn-item:#{Entities.driver(ids)}:#{native}"

  @doc """
  Creates the turn item (and its node) for a native item the first time it is seen.
  `kind` is `:assistant`, `:reasoning`, `:command`, `:file`, `:search`, `:web`, `:tool`,
  `:compaction`, `:notice` (a message the provider itself announced), or `:error`
  (a provider failure, such as a retry);
  `fields` are the item type's own fields.
  """
  def ensure_item(state, native, kind, fields \\ %{}) do
    if Map.has_key?(state.items, native) do
      state
    else
      # The provider's own name for the tool (`:native_name`), for plugins that hear
      # turns or read their history: `providerToolName` on the item.
      {native_name, fields} = Map.pop(fields, :native_name)

      fields =
        if is_binary(native_name),
          do: Map.put(fields, "providerToolName", native_name),
          else: fields

      ids = state.turn.ids
      driver = Entities.driver(ids)
      at = Entities.now()
      node_id = Entities.new_id("node")
      item_id = item_id(ids, native)
      message_id = if kind == :assistant, do: "message:#{driver}:#{native}"
      plan_id = if kind == :plan, do: "plan:#{driver}:#{native}"
      item_ids = Map.put(ids, :node, node_id)
      {node_kind, type, item_fields} = shape(kind, message_id, fields)
      item_fields = if plan_id, do: Map.put(item_fields, "planId", plan_id), else: item_fields

      commit(state, fn stream ->
        [
          Orchestration.create(
            "node",
            node_id,
            Entities.node(ids, node_id, node_kind, "running", at, %{
              "nativeItemRef" => Entities.provider_ref(native, driver)
            })
          ),
          Orchestration.create(
            "turn-item",
            item_id,
            Entities.turn_item(
              item_ids,
              item_id,
              type,
              Orchestration.next_ordinal(stream),
              "running",
              at,
              item_fields
            )
            |> Map.put("nativeItemRef", Entities.provider_ref(native, driver))
          ),
          message_id &&
            Orchestration.create(
              "message",
              message_id,
              Entities.message(item_ids, message_id, "assistant", "", true, at, %{
                "nodeId" => node_id
              })
            ),
          plan_id &&
            Orchestration.create(
              "plan",
              plan_id,
              plan(ids, plan_id, node_id, "proposed_plan", "draft", %{"markdown" => ""})
            )
        ]
      end)

      item = %{id: item_id, node: node_id, message: message_id, plan: plan_id, kind: kind}
      %{state | items: Map.put(state.items, native, item)}
    end
  end

  defp shape(:assistant, message_id, _),
    do:
      {"assistant_message", "assistant_message",
       %{"messageId" => message_id, "text" => "", "streaming" => true}}

  defp shape(:reasoning, _, _),
    do: {"reasoning", "reasoning", %{"text" => "", "streaming" => true}}

  defp shape(:command, _, fields), do: {"tool_call", "command_execution", fields}
  defp shape(:file, _, fields), do: {"tool_call", "file_change", fields}
  defp shape(:search, _, fields), do: {"tool_call", "file_search", fields}
  defp shape(:web, _, fields), do: {"tool_call", "web_search", fields}
  defp shape(:tool, _, fields), do: {"tool_call", "dynamic_tool", fields}
  defp shape(:subagent, _, fields), do: {"subagent", "subagent", fields}
  defp shape(:plan, _, _), do: {"plan", "proposed_plan", %{"markdown" => "", "streaming" => true}}
  defp shape(:compaction, _, fields), do: {"system", "compaction", fields}
  defp shape(:notice, _, fields), do: {"system", "system_notice", fields}
  defp shape(:error, _, fields), do: {"system", "error", fields}

  defp plan(ids, plan_id, node_id, kind, status, fields) do
    Map.merge(
      %{
        "id" => plan_id,
        "threadId" => ids.thread,
        "runId" => ids.run,
        "nodeId" => node_id,
        "kind" => kind,
        "status" => status
      },
      fields
    )
  end

  @doc """
  Completes a proposed plan (an item of kind `:plan`, whose text streamed into its
  turn item): the final `markdown` goes to the item and the plan, which becomes
  `active`, ready for the user to implement.
  """
  def finish_plan(state, native, markdown) do
    %{plan: plan_id} = Map.fetch!(state.items, native)

    state
    |> finish_item(native, "completed", fn entity ->
      Map.merge(entity, %{
        "markdown" => markdown || entity["markdown"] || "",
        "streaming" => false
      })
    end)
    |> tap(fn state ->
      commit(state, fn stream ->
        [
          Orchestration.upsert(stream, "plan", plan_id, fn plan ->
            Map.merge(plan, %{
              "status" => "active",
              "markdown" =>
                markdown ||
                  get_in(stream.entities, [
                    "turn-item",
                    item_id(state.turn.ids, native),
                    "markdown"
                  ]) || ""
            })
          end)
        ]
      end)
    end)
  end

  @doc """
  Writes a todo list (`OrchestrationV2PlanStep`s) as a plan with its turn item and
  node, creating them the first time and replacing the steps after that. The plan
  is complete once every step is.
  """
  def write_todo(state, native, steps, explanation \\ nil) do
    ids = state.turn.ids
    driver = Entities.driver(ids)
    at = Entities.now()
    plan_id = "plan:#{driver}:#{native}"
    item_id = item_id(ids, native)
    node_id = "node:todo:#{driver}:#{native}"
    # An empty list is a list whose items all went away (each one cancelled):
    # finished, not forever active.
    done = Enum.all?(steps, &(&1["status"] == "completed"))

    fields =
      %{"steps" => steps}
      |> then(&if(explanation, do: Map.put(&1, "explanation", explanation), else: &1))

    # The item is a snapshot of the list; the plan's status tracks its progress.
    item_status = "completed"

    commit(state, fn stream ->
      if stream.entities["plan"][plan_id] do
        [
          Orchestration.upsert(
            stream,
            "plan",
            plan_id,
            &Map.merge(&1, Map.put(fields, "status", if(done, do: "completed", else: "active")))
          ),
          Orchestration.upsert(
            stream,
            "turn-item",
            item_id,
            &Map.merge(&1, Map.merge(fields, %{"status" => item_status, "updatedAt" => at}))
          )
        ]
      else
        item_ids = Map.put(ids, :node, node_id)

        # A newer list replaces the thread's unfinished one; a completed list
        # stays completed.
        superseded =
          for {id, plan} <- stream.entities["plan"] || %{},
              plan["kind"] == "todo_list" and plan["status"] == "active",
              do: Orchestration.upsert(stream, "plan", id, &Map.put(&1, "status", "superseded"))

        superseded ++
          [
            Orchestration.create(
              "node",
              node_id,
              Entities.node(ids, node_id, "todo_list", "completed", at, %{
                "nativeItemRef" => Entities.provider_ref(native, driver)
              })
            ),
            Orchestration.create(
              "plan",
              plan_id,
              plan(
                ids,
                plan_id,
                node_id,
                "todo_list",
                if(done, do: "completed", else: "active"),
                fields
              )
            ),
            Orchestration.create(
              "turn-item",
              item_id,
              Entities.turn_item(
                item_ids,
                item_id,
                "todo_list",
                Orchestration.next_ordinal(stream),
                item_status,
                at,
                Map.put(fields, "planId", plan_id)
              )
            )
          ]
      end
    end)

    state
  end

  @doc """
  Finishes an item with `status`, applying `fun` to its turn item (and message). A
  command that printed the pull request it created links it to the thread
  (`HalC2.PullRequests.Opened`).
  """
  def finish_item(state, native, status, fun) do
    %{id: item_id, node: node_id, message: message_id} = item = Map.fetch!(state.items, native)
    at = Entities.now()
    tail = item[:kind] == :command && CommandTail.get(state.thread_id, item_id)
    fun = if item[:kind] == :command, do: &keep_output(fun.(&1), tail || ""), else: fun

    observing = HalC2.Plugins.observing?()

    {opened, current} =
      HalC2.Streams.transact(state.thread_id, :thread, fn stream ->
        changes = [
          Orchestration.upsert(
            stream,
            "turn-item",
            item_id,
            &(fun.(&1)
              |> Map.merge(%{"status" => status, "completedAt" => at, "updatedAt" => at})
              |> output_failure(item[:kind]))
          ),
          Orchestration.upsert(
            stream,
            "node",
            node_id,
            &Map.merge(&1, %{"status" => status, "completedAt" => at})
          ),
          message_id &&
            Orchestration.upsert(
              stream,
              "message",
              message_id,
              &(fun.(&1) |> Map.put("updatedAt", at))
            )
        ]

        opened =
          case item[:kind] == :command && StreamState.get(stream, "turn-item")[item_id] do
            %{} = current -> current |> fun.() |> then(&Opened.urls(&1["input"], &1["output"]))
            _ -> []
          end

        # What plugins that hear turns get of the item, as the thread now has it.
        current =
          case observing && StreamState.get(stream, "turn-item")[item_id] do
            %{} = current -> fun.(current)
            _ -> nil
          end

        {Enum.filter(changes, &is_tuple/1), {opened, current}}
      end)

    if opened != [], do: Opened.link(state.thread_id, opened)
    if item[:kind] == :command, do: CommandTail.delete(state.thread_id, item_id)
    if current, do: observe_item(state, status, current)
    state
  end

  # Plugins that hear turns hear each item that ended, as the thread has it.
  defp observe_item(state, status, current) do
    HalC2.Plugins.observe(
      current
      |> observed_item()
      |> Map.merge(%{
        "type" => "turn.item",
        "threadId" => state.thread_id,
        "runId" => state.turn.ids.run,
        "status" => status
      })
    )
  end

  @observed_chars 4_000

  @doc """
  What a plugin hears or reads of a turn item (`HalC2.Plugins.Extension`'s `observe/2`,
  `HalC2.Plugins.Host.history/2`): `"itemId", "itemType", "tool"` (the provider's own
  name for the tool, where it has one), `"title", "status", "input", "output",
  "exitCode"`, the input and output cut to their last #{@observed_chars} characters, a
  value that is not text as its JSON.
  """
  def observed_item(item) do
    %{
      "itemId" => item["id"],
      "itemType" => item["type"],
      "tool" => item["providerToolName"] || item["toolName"],
      "title" => item["title"],
      "status" => item["status"],
      "input" => observed(item["input"]),
      "output" => observed(item["output"]),
      "exitCode" => item["exitCode"]
    }
  end

  defp observed(nil), do: nil
  defp observed(text) when is_binary(text), do: cut_text(text)
  defp observed(value), do: value |> JSON.encode!() |> cut_text()

  defp cut_text(text) do
    if String.length(text) > @observed_chars,
      do: String.slice(text, -@observed_chars, @observed_chars),
      else: text
  end

  # What the thread keeps of a command's output: the provider's own account of it, or
  # what was printed while it ran, cut to the last `CommandTail.kept/0` bytes.
  defp keep_output(%{"output" => output} = item, tail) when is_binary(output) do
    output = if output == "", do: tail, else: output
    %{item | "output" => CommandTail.cut(output, CommandTail.kept())}
  end

  defp keep_output(item, _tail), do: item

  # A command the provider says completed whose output says otherwise.
  defp output_failure(%{"status" => "completed", "output" => output} = item, :command) do
    if CommandOutput.failed?(output),
      do: Map.put(item, "outputIndicatesFailure", true),
      else: item
  end

  defp output_failure(item, _kind), do: item

  @doc """
  Opens an approval prompt: a pending runtime request, the waiting approval item,
  and its node. `request_kind` is a `ProviderRequestKind` ("command", "file-change",
  "file-read", "permission"). Returns `{state, request_id}`; the runtime keeps what
  it needs to answer the provider under that id. `fields` go on the approval item
  as it is created, such as the provider's reason for asking.
  """
  def open_request(state, native, request_kind, prompt, options \\ nil, fields \\ %{}),
    do: open(state, native, {:approval, request_kind, prompt, options, fields})

  @doc """
  Opens questions for the user (`OrchestrationV2UserInputQuestion`s): a pending
  `user_input` request and its waiting `user_input_request` item. Answers arrive
  through `resolve_request/4` like approvals. Returns `{state, request_id}`.
  """
  def open_question(state, native, questions), do: open(state, native, {:questions, questions})

  @doc """
  Opens questions the provider asked without waiting (Codex's async questions): the
  request is answered with a user message (`responseCapability` `message`), so its
  node does not hold the run and it stays pending after the turn, the provider or
  the MC ends. Returns `{state, request_id}`.
  """
  def open_async_question(state, native, questions),
    do: open(state, native, {:async_questions, questions})

  @doc "Whether a runtime request is answered with a message rather than to a live provider."
  def message_request?(request), do: get_in(request, ["responseCapability", "type"]) == "message"

  defp open(state, native, what) do
    ids = state.turn.ids
    driver = Entities.driver(ids)
    at = Entities.now()
    request_id = "runtime-request:#{driver}:#{native}"
    node_id = "node:approval:#{native}"
    item_id = "turn-item:approval:#{native}"
    item_ids = Map.put(ids, :node, node_id)

    {node_kind, request_kind, item_fields} =
      case what do
        {:approval, kind, prompt, options, extra} ->
          fields = Map.merge(extra, %{"requestId" => request_id, "requestKind" => kind})

          fields =
            if(is_binary(prompt) and prompt != "",
              do: Map.put(fields, "prompt", prompt),
              else: fields
            )

          {"approval_request", kind,
           if(is_list(options), do: Map.put(fields, "options", options), else: fields)}

        {tag, questions} when tag in [:questions, :async_questions] ->
          {"user_input_request", "user_input",
           %{"requestId" => request_id, "questions" => questions}}
      end

    async? = match?({:async_questions, _}, what)

    commit(state, fn stream ->
      [
        Orchestration.create(
          "node",
          node_id,
          Entities.node(
            ids,
            node_id,
            node_kind,
            if(async?, do: "completed", else: "waiting"),
            at,
            %{
              "runtimeRequestId" => request_id
            }
          )
          |> then(&if(async?, do: Map.put(&1, "completedAt", at), else: &1))
        ),
        Orchestration.create("runtime-request", request_id, %{
          "id" => request_id,
          "nodeId" => node_id,
          "providerTurnId" => Map.get(ids, :provider_turn),
          "nativeRequestRef" => Entities.provider_ref(native, driver),
          "kind" => request_kind,
          "status" => "pending",
          "responseCapability" =>
            if(async?,
              do: %{"type" => "message"},
              else: %{
                "type" => "live",
                "providerSessionId" => session_id(stream, ids)
              }
            ),
          "createdAt" => at,
          "resolvedAt" => nil
        }),
        Orchestration.create(
          "turn-item",
          item_id,
          Entities.turn_item(
            item_ids,
            item_id,
            node_kind,
            Orchestration.next_ordinal(stream),
            "waiting",
            at,
            item_fields
          )
        )
      ]
    end)

    {state, request_id}
  end

  @doc "Records the decision on a prompt and closes its item and node."
  def resolve_request(state, request_id, decision, status \\ "resolved") do
    at = Entities.now()

    native =
      String.replace_prefix(request_id, "runtime-request:#{Entities.driver(state.turn.ids)}:", "")

    item_status = if status == "resolved", do: "completed", else: "cancelled"

    commit(state, fn stream ->
      [
        Orchestration.upsert(
          stream,
          "runtime-request",
          request_id,
          &(&1
            |> Map.merge(%{"status" => status, "resolvedAt" => at})
            |> Map.merge(response_fields(decision)))
        ),
        Orchestration.upsert(
          stream,
          "turn-item",
          "turn-item:approval:#{native}",
          &(&1
            |> Map.merge(%{"status" => item_status, "completedAt" => at, "updatedAt" => at})
            |> Map.merge(question_answer(decision)))
        ),
        Orchestration.upsert(
          stream,
          "node",
          "node:approval:#{native}",
          &Map.merge(&1, %{"status" => "completed", "completedAt" => at})
        )
      ]
    end)

    state
  end

  # What the user answered a question with, attachments included, for the question item.
  defp question_answer(%{"questionAnswer" => answer}), do: %{"questionAnswer" => answer}
  defp question_answer(_decision), do: %{}

  # A decision string, or a response's `decision`/`answers`.
  defp response_fields(nil), do: %{}
  defp response_fields(decision) when is_binary(decision), do: %{"decision" => decision}
  defp response_fields(%{} = response), do: Map.take(response, ["decision", "answers"])

  @doc "Closes this turn's items that are still running (their node too) with `status`."
  def close_open_items(state, status) do
    at = Entities.now()

    commit(state, fn stream ->
      for {_native, %{id: item_id, node: node_id} = item} <- state.items,
          stream.entities["turn-item"][item_id]["status"] == "running",
          change <- [
            Orchestration.upsert(
              stream,
              "turn-item",
              item_id,
              &(Map.merge(&1, %{
                  "status" => status,
                  "streaming" => false,
                  "completedAt" => at,
                  "updatedAt" => at
                })
                |> retry_title(status)
                |> stopped_output(item, state.thread_id))
            ),
            Orchestration.upsert(
              stream,
              "node",
              node_id,
              &Map.merge(&1, %{"status" => status, "completedAt" => at})
            ),
            # An assistant item's message stops streaming with it.
            item[:message] &&
              Orchestration.upsert(
                stream,
                "message",
                item.message,
                &Map.merge(&1, %{"streaming" => false, "updatedAt" => at})
              )
          ],
          change,
          do: change
    end)

    for {_native, %{kind: :command, id: item_id}} <- state.items,
        do: CommandTail.delete(state.thread_id, item_id)

    state
  end

  # A retry still open when its turn ends says how it ended; a usage-limit end is
  # retitled again by the failure item `finish/3` writes over it.
  defp retry_title(%{"retry" => %{}} = item, status) do
    title =
      case status do
        "completed" -> "Provider recovered"
        "failed" -> "Provider error"
        _ -> "Provider retry stopped"
      end

    Map.put(item, "title", title)
  end

  defp retry_title(item, _status), do: item

  # A command stopped mid-run keeps what it had printed.
  defp stopped_output(%{"output" => ""} = item, %{kind: :command, id: id}, thread_id) do
    case CommandTail.get(thread_id, id) do
      nil -> item
      tail -> %{item | "output" => tail}
    end
  end

  defp stopped_output(item, _meta, _thread_id), do: item

  @doc """
  Marks the turn as running: its provider turn (`ids.provider_turn`), attempt, run,
  root node, and provider thread, which becomes the thread's active one. The calling
  process drives the turn from here: if it crashes before `finish/3`, the turn ends
  as failed (`HalC2.Orchestration.TurnWatch`). Returns `:ended`, writing nothing, if
  the run ended while the turn started (the thread was deleted, or the start gave up
  waiting); the caller then has no turn to drive.
  """
  def started(state) do
    %{turn: turn} = state
    ids = turn.ids
    at = Entities.now()
    TurnWatch.claim(state.thread_id, ids.run)

    state
    |> commit_active(ids.run, fn stream ->
      [
        Orchestration.create(
          "provider-turn",
          ids.provider_turn,
          Entities.provider_turn(ids, nil, turn.run_ordinal, at)
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
          &Map.merge(&1, %{"status" => "active", "updatedAt" => at})
        ),
        Orchestration.upsert(
          stream,
          "thread",
          ids.thread,
          &Map.put(&1, "activeProviderThreadId", ids.provider_thread)
        )
      ]
    end)
    |> tap(&if(&1 == :ok, do: observe_started(state)))
  end

  # Plugins that hear turns (`HalC2.Plugins.observe/1`) hear this one start.
  defp observe_started(%{turn: turn} = state) do
    if HalC2.Plugins.observing?() do
      HalC2.Plugins.observe(%{
        "type" => "turn.started",
        "threadId" => state.thread_id,
        "runId" => turn.ids.run,
        "projectId" => Map.get(turn, :project_id),
        "instanceId" => Entities.instance(turn.ids),
        "provider" => Entities.driver(turn.ids),
        "model" => Map.get(turn, :model),
        "newConversation" => new_conversation?(turn)
      })
    end
  end

  @doc """
  Whether `turn` starts a new provider conversation, rather than resuming one, forking
  one or waking one the provider started by itself.
  """
  def new_conversation?(turn),
    do:
      Map.get(turn, :native_thread_id) == nil and Map.get(turn, :fork) == nil and
        Map.get(turn, :wake) != true

  @doc """
  Ends the run: provider turn, attempt, run, root node, and provider thread.
  `failure` is the provider's message, or a structured failure map that also becomes
  the run's error item. A completed run also captures its workspace checkpoint
  (`HalC2.Checkpoint`). The thread's next queued message then starts
  (`HalC2.Orchestration.start_next/1`), unless the thread was archived.
  """
  def finish(state, status, failure) do
    at = Entities.now()
    failure = UserFacingErrors.sanitize_failure(failure)

    # Ending a run is at-least-once (a restart can ask again): a run that has
    # already ended keeps the checkpoint its first ending captured, so the
    # repeat must not capture over it.
    run_id = state.turn && get_in(state.turn, [Access.key(:ids), Access.key(:run)])

    if run_id && not active?(HalC2.Streams.state(state.thread_id), run_id) do
      TurnWatch.release(run_id)
      :ok
    else
      finish_active(state, status, failure, at)
    end
  end

  defp finish_active(state, status, failure, at) do
    checkpoint =
      if status == "completed",
        do:
          HalC2.Traces.span("checkpoint.capture", trace_attributes(state), fn ->
            capture_checkpoint(state.turn, at)
          end)

    baselines = if checkpoint, do: baselines(state.turn, at), else: []

    # The turn may have pushed or changed its repository's pull requests; forgotten
    # before the run ends, so whoever sees it end reads them fresh.
    if cwd = state.turn.cwd, do: HalC2.PullRequests.turn_finished(cwd)

    ended =
      HalC2.Streams.transact(state.thread_id, :thread, fn stream ->
        if active?(stream, state.turn.ids.run) do
          changes =
            baseline_changes(stream, baselines) ++
              checkpoint_changes(stream, state.turn, checkpoint, at) ++
              ended(stream, state.turn.ids, status, failure, checkpoint, at)

          {Enum.filter(changes, &is_tuple/1), {:ended, queue_starts?(stream, state.thread_id)}}
        else
          {[], {:already, recorded?(stream, checkpoint)}}
        end
      end)

    case ended do
      {:ended, queue?} ->
        finished(state, status, failure, queue?)

      # Deleted, or abandoned, before the provider's turn ended: that end stands.
      {:already, recorded?} ->
        unless recorded?, do: drop_capture(state.turn.cwd, checkpoint)
        TurnWatch.release(state.turn.ids.run)
        :ok
    end
  end

  # Whether the thread recorded `checkpoint` (captured before a transaction that found
  # its run already ended): the run's ref is the end that won's, else nobody's.
  defp recorded?(_stream, nil), do: true

  defp recorded?(stream, checkpoint),
    do: StreamState.get(stream, "checkpoint")[checkpoint["id"]] != nil

  # A capture for a run another end settled without one: its ref would point at a
  # checkpoint the thread never recorded.
  defp drop_capture(cwd, %{"ref" => ref}) when is_binary(cwd),
    do: HalC2.Checkpoint.delete_ref(cwd, ref)

  defp drop_capture(_cwd, _checkpoint), do: :ok

  defp active?(stream, run_id),
    do: (StreamState.get(stream, "run")[run_id] || %{})["status"] in @active_runs

  # Whether the thread's queue starts once the run has ended, decided with the end: a
  # turn that ends while its thread is archived leaves the queue to the user, so an
  # unarchive that lands before the start does not start it either.
  defp queue_starts?(stream, thread_id),
    do: (StreamState.get(stream, "thread")[thread_id] || %{})["archivedAt"] == nil

  # The changes that end the run.
  defp ended(stream, ids, status, failure, checkpoint, at) do
    failure =
      stream
      |> queued_start_failure(ids, status, failure)
      |> kept_reset(stream, ids)
      |> retry_hint(stream, status)

    done = %{"status" => status, "completedAt" => at}
    run_done = if checkpoint, do: Map.put(done, "checkpointId", checkpoint["id"]), else: done

    # The run keeps its own failure text: the provider session's `lastError` outlives it.
    text = status == "failed" && failure_message(failure)

    run_done =
      if is_binary(text) and text != "",
        do: Map.put(run_done, "failure", text),
        else: run_done

    # A turn that failed while starting has not created all of these yet.
    settle = fn kind, id, changes ->
      StreamState.get(stream, kind)[id] &&
        Orchestration.upsert(stream, kind, id, &Map.merge(&1, changes))
    end

    [
      Map.has_key?(ids, :provider_turn) && settle.("provider-turn", ids.provider_turn, done),
      settle.("run-attempt", ids.attempt, done),
      settle.("run", ids.run, run_done),
      settle.("node", ids.root_node, done),
      settle.("provider-thread", ids.provider_thread, %{"status" => "idle", "updatedAt" => at}),
      status == "interrupted" && interrupt_result(stream, ids, at),
      failure && status == "failed" &&
        settle.(
          "provider-session",
          session_id(stream, ids),
          %{"lastError" => failure_message(failure), "updatedAt" => at}
        ),
      is_map(failure) && status == "failed" && failure_item(stream, ids, failure, at)
    ] ++ held_queue(stream, status, failure) ++ stopped_limit(stream, ids, status, failure)
  end

  # A limit that ended a run the user (or a parent agent) had asked to stop is not resumed
  # on its own: the stop leaves the choice to resume at the reset with the user.
  defp stopped_limit(stream, ids, "failed", %{"class" => "usage_limit"} = failure) do
    request = "turn-item:run:#{ids.run}:signal:interrupt-request"

    if StreamState.get(stream, "turn-item")[request] != nil and failure["resetAt"] != nil,
      do: [
        Orchestration.upsert(
          stream,
          "thread",
          ids.thread,
          &Map.put(&1, "limitRecovery", %{
            "runId" => ids.run,
            "resetAt" => failure["resetAt"],
            "autoResume" => false,
            "snooze" => false
          })
        )
      ],
      else: []
  end

  defp stopped_limit(_stream, _ids, _status, _failure), do: []

  # An automatic resume the provider rejects with a limit that names no reset leaves the
  # reset time of the stop it continued, so the thread still says when the limit lifts.
  # The resume's message names that stop, or, when the resume restarted a held queue, the
  # run it started does.
  defp kept_reset(%{"class" => "usage_limit", "resetAt" => nil} = failure, stream, ids) do
    run = StreamState.get(stream, "run")[ids.run] || %{}
    message = StreamState.get(stream, "message")[run["userMessageId"]] || %{}

    continued =
      StreamState.get(stream, "run")[
        run["usageLimitContinuationOfRunId"] || message["usageLimitContinuationOfRunId"]
      ]

    reset =
      continued &&
        HalC2.Projection.ThreadError.latest_root_provider_failure(
          continued,
          StreamState.list(stream, "turn-item")
        )

    if reset && reset["class"] == "usage_limit" && reset["resetAt"],
      do: Map.put(failure, "resetAt", reset["resetAt"]),
      else: failure
  end

  defp kept_reset(failure, _stream, _ids), do: failure

  # A run that left the queue and failed before its provider turn began (the runtime's
  # `start_failure/2`): the timeline says the queued message's provider could not start.
  defp queued_start_failure(stream, ids, "failed", failure) when is_binary(failure) do
    began = StreamState.get(stream, "provider-turn")[Map.get(ids, :provider_turn)] != nil
    message = Map.get(ids, :message)
    item = message && StreamState.get(stream, "turn-item")["turn-item:user:#{message}"]

    if not began and is_map(item) and item["inputIntent"] == "queued_turn",
      do: %{
        "class" => "provider_error",
        "code" => "queued_start_failed",
        "message" => failure,
        "retryable" => false
      },
      else: failure
  end

  defp queued_start_failure(_stream, _ids, _status, failure), do: failure

  # A worktree that could not be made again says how to retry: by sending again, or,
  # when the run holds messages queued behind it (`held_queue/3`), where a new message
  # would only wait too, by resuming the queue.
  defp retry_hint(%{"code" => "worktree_unavailable"} = failure, stream, "failed") do
    hint =
      if Enum.any?(StreamState.list(stream, "run"), &(&1["status"] == "queued")),
        do: "Resume the queue to retry.",
        else: "Send the message again to retry."

    Map.update!(failure, "message", &"#{&1} #{hint}")
  end

  defp retry_hint(failure, _stream, _status), do: failure

  # A run stopped by a usage limit, or by a worktree that could not be made again,
  # leaves the queue as it is: the messages behind it would only fail the same way, so
  # they wait, in order, until the user resumes the queue (`queue.resume`), as they do
  # after a restart.
  defp held_queue(stream, "failed", %{} = failure) do
    if failure["class"] == "usage_limit" or failure["code"] == "worktree_unavailable" do
      for %{"status" => "queued"} = run <- StreamState.list(stream, "run"),
          run["queueHeld"] != true,
          do: Orchestration.upsert(stream, "run", run["id"], &Map.put(&1, "queueHeld", true))
    else
      []
    end
  end

  defp held_queue(_stream, _status, _failure), do: []

  # What follows a run ending, once it has.
  defp finished(state, status, failure, queue?) do
    ids = state.turn.ids
    TurnWatch.release(ids.run)
    # A command the run left running has no more output to show.
    CommandTail.drop_thread(state.thread_id)

    # The turn may have changed the checkout; clients watching it see the result.
    if cwd = state.turn.cwd do
      HalC2.Vcs.Watch.turn_ended(cwd)
      HalC2.Workspace.invalidate(cwd)
    end

    # The thread is idle now: its next queued message can start. Off this process,
    # since starting a turn calls back into the runtime that is finishing this one.
    thread_id = state.thread_id

    HalC2.Traces.finished(
      "provider.turn",
      Map.put(trace_attributes(state), "turn.status", status),
      Map.get(state.turn, :started_ms, System.system_time(:millisecond)),
      if(status == "failed",
        do: %{"_tag" => "Failure", "cause" => failure_cause(failure)},
        else: %{"_tag" => "Success"}
      )
    )

    observe_finished(state, status)

    Task.start(fn ->
      if queue?, do: Orchestration.start_next(thread_id)
      # Notification channels hear about turns nobody was watching end.
      HalC2.Plugins.turn_finished(thread_id, status, failure)
    end)

    HalC2.Space.Presence.agent_done(thread_id)

    # A delegated task reports back to the thread that asked for it, apart from the
    # rest so their failures cannot lose the report.
    Task.start(fn -> HalC2.Orchestration.Delegation.report(thread_id, ids.run, status) end)
    # So does an agent asked from a page, to the page.
    Task.start(fn -> HalC2.Space.PageAgent.report(thread_id) end)

    :ok
  end

  # Plugins that hear turns hear this one end, from the process that drove it, after
  # its items. The usage is the provider's last report of the conversation's context:
  # the turn's own, or the provider thread's.
  defp observe_finished(state, status) do
    if HalC2.Plugins.observing?() do
      ids = state.turn.ids
      stream = HalC2.Streams.state(state.thread_id)
      provider_turn = StreamState.get(stream, "provider-turn")[ids[:provider_turn]] || %{}
      provider_thread = StreamState.get(stream, "provider-thread")[ids[:provider_thread]] || %{}

      HalC2.Plugins.observe(%{
        "type" => "turn.finished",
        "threadId" => state.thread_id,
        "runId" => ids.run,
        "status" => status,
        "tokenUsage" => provider_turn["tokenUsage"] || provider_thread["contextUsage"]
      })
    end
  end

  @doc """
  Ends run `run_id` of `thread_id` with `status` when nothing drives it any more: its
  runtime crashed, or stopped without ending it. What the run left open ends with it,
  from what the thread recorded, in the same transaction as the run, so of two
  callers racing (a crash and a stop) only the first ends it.
  """
  def abandon(thread_id, run_id, status, failure) do
    at = Entities.now()
    failure = UserFacingErrors.sanitize_failure(failure)
    {scope_id, checkpoint, cwd} = stopped_checkpoint(thread_id, run_id, status, at)

    abandoned =
      HalC2.Streams.transact(thread_id, :thread, fn stream ->
        case StreamState.get(stream, "run")[run_id] do
          %{"status" => active} = run when active in @active_runs ->
            state = abandoned_turn(stream, thread_id, run)
            turn = Map.put(state.turn, :scope_id, scope_id)
            baselines = if checkpoint, do: baselines(turn, at), else: []

            changes =
              baseline_changes(stream, baselines) ++
                checkpoint_changes(stream, turn, checkpoint, at) ++
                left_open(stream, run, status, at) ++
                ended(stream, state.turn.ids, status, failure, checkpoint, at)

            {Enum.filter(changes, &is_tuple/1), {state, queue_starts?(stream, thread_id)}}

          _ ->
            {[], {:already, recorded?(stream, checkpoint)}}
        end
      end)

    case abandoned do
      # Its checkpoint was captured before another end won the run.
      {:already, recorded?} ->
        unless recorded?, do: drop_capture(cwd, checkpoint)
        :ok

      {state, queue?} ->
        # A start still in flight for the run (its runtime stopped answering)
        # must not hold the thread's work behind it.
        HalC2.Orchestration.Effects.cancel_pending(thread_id, "provider-turn.start", run_id)
        finished(state, status, failure, queue?)
    end
  end

  @doc """
  Completes run `run_id` of `thread_id` with the checkpoint a capture replayed after a
  restart took (`args` are the capture's): the MC stopped after its provider turn ended
  and before the capture did, so the restart left the run to it.
  """
  def checkpointed(thread_id, run_id, args, checkpoint) do
    at = Entities.now()

    completed =
      HalC2.Streams.transact(thread_id, :thread, fn stream ->
        case StreamState.get(stream, "run")[run_id] do
          %{"status" => active} = run when active in @active_runs ->
            state = abandoned_turn(stream, thread_id, run)
            turn = Map.put(state.turn, :scope_id, args["scopeId"])
            baselines = if checkpoint, do: baselines(%{turn | cwd: args["cwd"]}, at), else: []

            changes =
              baseline_changes(stream, baselines) ++
                checkpoint_changes(stream, turn, checkpoint, at) ++
                left_open(stream, run, "completed", at) ++
                ended(stream, turn.ids, "completed", nil, checkpoint, at)

            {Enum.filter(changes, &is_tuple/1), {state, queue_starts?(stream, thread_id)}}

          _ ->
            {[], nil}
        end
      end)

    case completed do
      {state, queue?} -> finished(state, "completed", nil, queue?)
      nil -> :ok
    end
  end

  # A run the user stopped that nothing drove keeps what it changed: its checkpoint is
  # captured from the folder it worked in, as a completed run's is.
  defp stopped_checkpoint(thread_id, run_id, "interrupted", at) do
    stream = HalC2.Streams.state(thread_id)
    scope_id = HalC2.Checkpoint.scope_id(thread_id)

    case StreamState.get(stream, "run")[run_id] do
      %{"status" => active} = run when active in @active_runs ->
        turn = Map.put(abandoned_turn(stream, thread_id, run).turn, :scope_id, scope_id)
        checkpoint = if turn.cwd && File.dir?(turn.cwd), do: capture_checkpoint(turn, at)
        {scope_id, checkpoint, turn.cwd}

      _ ->
        {scope_id, nil, nil}
    end
  end

  defp stopped_checkpoint(thread_id, _run_id, _status, _at),
    do: {HalC2.Checkpoint.scope_id(thread_id), nil, nil}

  # The runtime state `finish/3` needs, rebuilt from the run.
  defp abandoned_turn(stream, thread_id, run) do
    instance = run["providerInstanceId"]
    driver = Orchestration.driver_for(instance)
    attempt = StreamState.get(stream, "run-attempt")[run["activeAttemptId"]] || %{}

    ids =
      %{
        thread: thread_id,
        run: run["id"],
        attempt: run["activeAttemptId"],
        root_node: run["rootNodeId"],
        provider_thread: run["providerThreadId"],
        driver: driver,
        instance: instance
      }
      |> then(
        &if(turn = attempt["providerTurnId"], do: Map.put(&1, :provider_turn, turn), else: &1)
      )

    cwd = (StreamState.get(stream, "provider-session")[session_id(stream, ids)] || %{})["cwd"]
    %{thread_id: thread_id, turn: %{ids: ids, cwd: cwd, run_ordinal: run["ordinal"]}}
  end

  # The session a run ran in, as its provider thread names it: one made before instances
  # had their own is under the driver's id.
  defp session_id(stream, ids) do
    (StreamState.get(stream, "provider-thread")[ids.provider_thread] || %{})["providerSessionId"] ||
      Entities.provider_session_id(Entities.instance(ids), ids.thread)
  end

  # The items, nodes, provider subagents and prompts a run left open, and its message
  # still streaming. Its root node ends with the run. A task it delegated runs on in its
  # own thread and settles when that ends (`Delegation.finished/3`).
  defp left_open(stream, %{"id" => run_id, "rootNodeId" => root}, status, at) do
    nodes =
      for {id, %{"runId" => ^run_id}} <- StreamState.get(stream, "node"),
          into: MapSet.new(),
          do: id

    delegated =
      for {id, %{"runId" => ^run_id, "origin" => "app_owned"}} <-
            StreamState.get(stream, "subagent"),
          into: MapSet.new(),
          do: id

    # Questions answered with a message outlive the run that asked them.
    asked =
      for {id, request} <- StreamState.get(stream, "runtime-request"),
          message_request?(request) and request["status"] == "pending",
          into: MapSet.new(),
          do: id

    for {kind, open?, changes} <- [
          {"turn-item",
           &(&1["runId"] == run_id and &1["nodeId"] not in delegated and &1["status"] in @open and
               &1["requestId"] not in asked),
           %{"status" => status, "streaming" => false, "completedAt" => at, "updatedAt" => at}},
          {"node",
           &(&1["runId"] == run_id and &1["id"] != root and &1["id"] not in delegated and
               &1["status"] in @open), %{"status" => status, "completedAt" => at}},
          {"subagent",
           &(&1["runId"] == run_id and &1["origin"] == "provider_native" and
               &1["status"] in @open),
           %{"status" => status, "completedAt" => at, "updatedAt" => at}},
          {"message", &(&1["runId"] == run_id and &1["streaming"] == true),
           %{"streaming" => false, "updatedAt" => at}},
          {"runtime-request",
           &(&1["nodeId"] in nodes and &1["status"] == "pending" and not message_request?(&1)),
           %{"status" => "cancelled", "resolvedAt" => at}}
        ],
        {id, entity} <- StreamState.get(stream, kind),
        open?.(entity),
        change = Orchestration.upsert(stream, kind, id, &Map.merge(&1, changes)),
        do: change
  end

  defp trace_attributes(state) do
    %{
      "thread.id" => state.thread_id,
      "run.id" => state.turn.ids.run,
      "provider.driver" => Entities.driver(state.turn.ids)
    }
  end

  defp failure_cause(%{"message" => message}) when is_binary(message), do: message
  defp failure_cause(failure) when is_binary(failure), do: failure
  defp failure_cause(failure), do: inspect(failure)

  defp failure_message(%{"message" => message}), do: message
  defp failure_message(message), do: message

  # A structured failure (`OrchestrationV2ProviderFailure`) is the run's error item,
  # which the thread's `lastErrorClass` and `usageLimitResetAt` are read from.
  defp failure_item(stream, ids, failure, at) do
    item_id = item_id(ids, "terminal-failure:#{Map.get(ids, :provider_turn, ids.run)}")

    Orchestration.create(
      "turn-item",
      item_id,
      Entities.turn_item(
        ids,
        item_id,
        "error",
        Orchestration.next_ordinal(stream),
        "failed",
        at,
        %{
          "title" =>
            cond do
              failure["class"] == "usage_limit" -> "Usage limit reached"
              failure["code"] == "queued_start_failed" -> "Queued provider could not start"
              failure["code"] == "provider_turned_off" -> "Provider turned off"
              failure["code"] == "compact_empty_thread" -> "Cannot compact an empty thread"
              failure["code"] == "worktree_unavailable" -> "Worktree could not be made"
              true -> "Provider error"
            end,
          "failure" => failure
        }
      )
    )
  end

  # "Run interrupted" in the transcript, under the stop's request when there was
  # one, saying who stopped it: the user, an agent (with its reason), or the
  # provider itself when nobody asked.
  defp interrupt_result(stream, ids, at) do
    item_id = "turn-item:run:#{ids.run}:signal:interrupt-result"

    request =
      StreamState.get(stream, "turn-item")["turn-item:run:#{ids.run}:signal:interrupt-request"]

    StreamState.get(stream, "turn-item")[item_id] == nil &&
      Orchestration.create(
        "turn-item",
        item_id,
        Entities.turn_item(
          ids,
          item_id,
          "run_interrupt_result",
          Orchestration.next_ordinal(stream),
          "interrupted",
          at,
          %{
            "title" => "Interrupted",
            "parentItemId" => "turn-item:run:#{ids.run}:signal:interrupt-request",
            "message" => stopped_by(request)
          }
        )
      )
  end

  defp stopped_by(nil), do: "Stopped by the provider"

  defp stopped_by(%{"stoppedBy" => "agent", "message" => reason})
       when is_binary(reason) and reason != "Interrupt requested",
       do: "Stopped by an agent: #{reason}"

  defp stopped_by(%{"stoppedBy" => "agent"}), do: "Stopped by an agent"
  defp stopped_by(_request), do: "Stopped by user"

  defp capture_checkpoint(%{scope_id: scope_id} = turn, at) do
    # Its own lane: a finish can run inside the turn's own start (a wake
    # replayed to its end), where the provider lane is the start itself.
    case HalC2.Orchestration.Effects.run_now(
           turn.ids.thread,
           "checkpoint.capture",
           %{
             "cwd" => turn.cwd,
             "scopeId" => scope_id,
             "runOrdinal" => turn.run_ordinal,
             "runId" => turn.ids.run,
             "rootNodeId" => turn.ids.root_node,
             "at" => at
           },
           :turn,
           "checkpoint"
         ) do
      {:ok, checkpoint} -> checkpoint
      _ -> nil
    end
  end

  defp capture_checkpoint(_turn, _at), do: nil

  defp baselines(turn, at) do
    HalC2.Checkpoint.baselines(
      turn.cwd,
      turn.scope_id,
      turn.run_ordinal,
      turn.ids.root_node,
      turn.ids.thread,
      at
    )
  end

  # Baselines not yet recorded as ready, which the previous run's own capture usually is.
  defp baseline_changes(stream, baselines) do
    Enum.flat_map(baselines, fn baseline ->
      case StreamState.get(stream, "checkpoint")[baseline["id"]] do
        nil ->
          [Orchestration.create("checkpoint", baseline["id"], baseline)]

        %{"status" => "ready"} ->
          []

        _ ->
          [Orchestration.upsert(stream, "checkpoint", baseline["id"], &Map.merge(&1, baseline))]
      end
    end)
  end

  # The checkpoint and the turn item that shows its changed files.
  defp checkpoint_changes(_stream, _turn, nil, _at), do: []

  defp checkpoint_changes(stream, turn, checkpoint, at) do
    item_id = item_id(turn.ids, "checkpoint:#{checkpoint["id"]}")

    [
      Orchestration.create("checkpoint", checkpoint["id"], checkpoint),
      Orchestration.create(
        "turn-item",
        item_id,
        Entities.turn_item(
          turn.ids,
          item_id,
          "checkpoint",
          Orchestration.next_ordinal(stream),
          "completed",
          at,
          %{
            "checkpointId" => checkpoint["id"],
            "scopeId" => checkpoint["scopeId"],
            "files" => checkpoint["files"]
          }
        )
      )
    ]
  end

  @doc "Buffers streamed `delta` for an item's `field`; written as an append on flush."
  def buffer(state, native, field, delta) do
    buffer = Map.update(state.buffer, {native, field}, delta, &(&1 <> delta))
    timer = state.flush_timer || Process.send_after(self(), :flush, @flush_ms)
    %{state | buffer: buffer, flush_timer: timer}
  end

  @doc """
  Writes buffered text. `:all` (item ends, prompts, the turn's end) writes
  everything; `:timer` holds assistant and reasoning text back by the project's
  `responseStreamingMode`: "paragraph" writes finished
  paragraphs and closed code blocks at most every 400 ms, "turn" writes nothing
  until a boundary. Tool output and plans stream as they come.
  """
  def flush(state, how \\ :all)

  def flush(%{buffer: buffer} = state, _how) when map_size(buffer) == 0, do: state

  def flush(state, how) do
    now = System.monotonic_time(:millisecond)
    mode = Map.get(state.turn || %{}, :streaming_mode, "paragraph")
    streamed = Map.get(state, :streamed, %{})

    {writes, held, streamed} =
      Enum.reduce(state.buffer, {[], %{}, streamed}, fn {key, pending},
                                                        {writes, held, streamed} ->
        {native, field} = key
        committed = streamed[key] || ""

        cond do
          how == :all or not prose?(state, native, field) ->
            {[{key, pending} | writes], held, Map.put(streamed, key, committed <> pending)}

          mode == "turn" or recent?(state, now) ->
            {writes, Map.put(held, key, pending), streamed}

          true ->
            {ready, _rest} = split_ready(committed <> pending)

            if byte_size(ready) > byte_size(committed) do
              out =
                binary_part(ready, byte_size(committed), byte_size(ready) - byte_size(committed))

              rest = binary_part(pending, byte_size(out), byte_size(pending) - byte_size(out))
              held = if rest == "", do: held, else: Map.put(held, key, rest)
              {[{key, out} | writes], held, Map.put(streamed, key, ready)}
            else
              {writes, Map.put(held, key, pending), streamed}
            end
        end
      end)

    changes =
      Enum.flat_map(writes, fn {{native, field}, text} ->
        %{id: item_id, message: message_id} = item = Map.fetch!(state.items, native)

        cond do
          # A command's output stays off the log: the item says how much there is.
          field == "output" and item.kind == :command and CommandTail.running?() ->
            size = CommandTail.append(state.thread_id, item_id, text)
            [{"turn-item", item_id, %{"s" => %{"outputSize" => size}}}]

          true ->
            append = %{"a" => %{field => text}}

            [{"turn-item", item_id, append}] ++
              if(message_id && field == "text", do: [{"message", message_id, append}], else: [])
        end
      end)

    if changes != [], do: {:ok, _} = HalC2.Streams.commit(state.thread_id, :thread, changes)
    if state.flush_timer, do: Process.cancel_timer(state.flush_timer)

    wrote_prose = Enum.any?(writes, fn {{native, field}, _} -> prose?(state, native, field) end)

    # Held paragraphs get another look once the throttle allows one.
    timer =
      if held != %{} and mode == "paragraph",
        do: Process.send_after(self(), :flush, @text_ms)

    state
    |> Map.merge(%{buffer: held, flush_timer: timer, streamed: streamed})
    |> then(&if(wrote_prose and how == :timer, do: Map.put(&1, :text_at, now), else: &1))
  end

  defp recent?(state, now) do
    case Map.get(state, :text_at) do
      nil -> false
      at -> now - at < @text_ms
    end
  end

  defp prose?(state, native, "text"),
    do: match?(%{kind: k} when k in [:assistant, :reasoning], state.items[native])

  defp prose?(_state, _native, _field), do: false

  @doc """
  Splits text at its last blank line or closing code fence outside an open
  fence: `{ready, rest}`, where `ready` will not change shape as more arrives.
  Only whole lines count, so a partial line is never delivered.
  """
  def split_ready(text) do
    {boundary, _fence, _offset} =
      text
      |> String.split("\n")
      # The last piece has no newline after it yet.
      |> Enum.drop(-1)
      |> Enum.reduce({0, nil, 0}, fn raw, {boundary, fence, offset} ->
        line = String.replace(raw, ~r/[ \t\r]+$/, "")
        next = offset + byte_size(raw) + 1

        case Regex.run(~r/^( *)(`{3,}|~{3,})/, line) do
          [_, indent, marker] when fence == nil ->
            {boundary, {marker, byte_size(indent)}, next}

          [_, indent, marker] ->
            {open, open_indent} = fence

            if String.first(marker) == String.first(open) and
                 byte_size(marker) >= byte_size(open) and
                 byte_size(indent) <= open_indent + 3 and
                 byte_size(line) == byte_size(indent) + byte_size(marker),
               do: {next, nil, next},
               else: {boundary, fence, next}

          nil ->
            if fence == nil and offset > 0 and Regex.match?(~r/^[ \t]*$/, line),
              do: {next, nil, next},
              else: {boundary, fence, next}
        end
      end)

    {binary_part(text, 0, boundary), binary_part(text, boundary, byte_size(text) - boundary)}
  end

  @doc "Commits the changes `fun` builds from the thread's current state; nils are skipped."
  def commit(state, fun) do
    HalC2.Streams.transact(state.thread_id, :thread, fn stream ->
      {fun.(stream) |> Enum.filter(&is_tuple/1), :ok}
    end)
  end

  @doc """
  As `commit/2`, if run `run_id` is still active; `:ended`, committing nothing, if it
  is not. The claim of a run that ended is released.
  """
  def commit_active(state, run_id, fun) do
    committed =
      HalC2.Streams.transact(state.thread_id, :thread, fn stream ->
        if active?(stream, run_id),
          do: {fun.(stream) |> Enum.filter(&is_tuple/1), :ok},
          else: {[], :ended}
      end)

    if committed == :ended, do: TurnWatch.release(run_id)
    committed
  end
end
