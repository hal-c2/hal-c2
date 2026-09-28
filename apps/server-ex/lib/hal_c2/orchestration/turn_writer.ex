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
  alias HalC2.Orchestration.{Entities, TurnWatch}
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
  `kind` is `:assistant`, `:reasoning`, `:command`, `:file`, `:web`, `:tool`,
  `:compaction`, or `:error` (a provider failure, such as a retry);
  `fields` are the item type's own fields.
  """
  def ensure_item(state, native, kind, fields \\ %{}) do
    if Map.has_key?(state.items, native) do
      state
    else
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
  defp shape(:web, _, fields), do: {"tool_call", "web_search", fields}
  defp shape(:tool, _, fields), do: {"tool_call", "dynamic_tool", fields}
  defp shape(:subagent, _, fields), do: {"subagent", "subagent", fields}
  defp shape(:plan, _, _), do: {"plan", "proposed_plan", %{"markdown" => "", "streaming" => true}}
  defp shape(:compaction, _, fields), do: {"system", "compaction", fields}
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
    done = steps != [] and Enum.all?(steps, &(&1["status"] == "completed"))

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

  @doc "Finishes an item with `status`, applying `fun` to its turn item (and message)."
  def finish_item(state, native, status, fun) do
    %{id: item_id, node: node_id, message: message_id} = Map.fetch!(state.items, native)
    at = Entities.now()

    commit(state, fn stream ->
      [
        Orchestration.upsert(
          stream,
          "turn-item",
          item_id,
          &(fun.(&1) |> Map.merge(%{"status" => status, "completedAt" => at, "updatedAt" => at}))
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
    end)

    state
  end

  @doc """
  Opens an approval prompt: a pending runtime request, the waiting approval item,
  and its node. `request_kind` is a `ProviderRequestKind` ("command", "file-change",
  "file-read", "permission"). Returns `{state, request_id}`; the runtime keeps what
  it needs to answer the provider under that id.
  """
  def open_request(state, native, request_kind, prompt),
    do: open(state, native, {:approval, request_kind, prompt})

  @doc """
  Opens questions for the user (`OrchestrationV2UserInputQuestion`s): a pending
  `user_input` request and its waiting `user_input_request` item. Answers arrive
  through `resolve_request/4` like approvals. Returns `{state, request_id}`.
  """
  def open_question(state, native, questions), do: open(state, native, {:questions, questions})

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
        {:approval, kind, prompt} ->
          fields = %{"requestId" => request_id, "requestKind" => kind}

          {"approval_request", kind,
           if(is_binary(prompt) and prompt != "",
             do: Map.put(fields, "prompt", prompt),
             else: fields
           )}

        {:questions, questions} ->
          {"user_input_request", "user_input",
           %{"requestId" => request_id, "questions" => questions}}
      end

    commit(state, fn stream ->
      [
        Orchestration.create(
          "node",
          node_id,
          Entities.node(ids, node_id, node_kind, "waiting", at, %{
            "runtimeRequestId" => request_id
          })
        ),
        Orchestration.create("runtime-request", request_id, %{
          "id" => request_id,
          "nodeId" => node_id,
          "providerTurnId" => Map.get(ids, :provider_turn),
          "nativeRequestRef" => Entities.provider_ref(native, driver),
          "kind" => request_kind,
          "status" => "pending",
          "responseCapability" => %{
            "type" => "live",
            "providerSessionId" => "provider-session:#{driver}:#{ids.thread}"
          },
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
              &Map.merge(&1, %{
                "status" => status,
                "streaming" => false,
                "completedAt" => at,
                "updatedAt" => at
              })
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

    state
  end

  @doc """
  Marks the turn as running: its provider turn (`ids.provider_turn`), attempt, run,
  root node, and provider thread, which becomes the thread's active one. The calling
  process drives the turn from here: if it crashes before `finish/3`, the turn ends
  as failed (`HalC2.Orchestration.TurnWatch`).
  """
  def started(state) do
    %{turn: turn} = state
    ids = turn.ids
    at = Entities.now()
    TurnWatch.claim(state.thread_id, ids.run)

    commit(state, fn stream ->
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
  end

  @doc """
  Ends the run: provider turn, attempt, run, root node, and provider thread.
  `failure` is the provider's message, or a structured failure map that also becomes
  the run's error item. A completed run also captures its workspace checkpoint
  (`HalC2.Checkpoint`). The thread's next queued message then starts
  (`HalC2.Orchestration.start_next/1`).
  """
  def finish(state, status, failure) do
    at = Entities.now()

    checkpoint =
      if status == "completed",
        do:
          HalC2.Traces.span("checkpoint.capture", trace_attributes(state), fn ->
            capture_checkpoint(state.turn, at)
          end)

    baselines = if checkpoint, do: baselines(state.turn, at), else: []

    commit(state, fn stream ->
      baseline_changes(stream, baselines) ++
        checkpoint_changes(stream, state.turn, checkpoint, at) ++
        ended(stream, state.turn.ids, status, failure, checkpoint, at)
    end)

    finished(state, status, failure)
  end

  # The changes that end the run.
  defp ended(stream, ids, status, failure, checkpoint, at) do
    done = %{"status" => status, "completedAt" => at}
    run_done = if checkpoint, do: Map.put(done, "checkpointId", checkpoint["id"]), else: done

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
          "provider-session:#{Entities.driver(ids)}:#{ids.thread}",
          %{"lastError" => failure_message(failure), "updatedAt" => at}
        ),
      is_map(failure) && status == "failed" && failure_item(stream, ids, failure, at)
    ]
  end

  # What follows a run ending, once it has.
  defp finished(state, status, failure) do
    ids = state.turn.ids
    TurnWatch.release(ids.run)

    # The turn may have changed the checkout; clients watching it see the result.
    if cwd = state.turn.cwd do
      HalC2.Vcs.Watch.refresh(cwd)
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

    Task.start(fn ->
      Orchestration.start_next(thread_id)
      # A delegated task reports back to the thread that asked for it.
      HalC2.Orchestration.Delegation.finished(thread_id, ids.run, status)
      # Notification channels hear about turns nobody was watching end.
      HalC2.Plugins.turn_finished(thread_id, status)
    end)

    :ok
  end

  @doc """
  Ends run `run_id` of `thread_id` with `status` when nothing drives it any more: its
  runtime crashed, or stopped without ending it. What the run left open ends with it,
  from what the thread recorded, in the same transaction as the run, so of two
  callers racing (a crash and a stop) only the first ends it.
  """
  def abandon(thread_id, run_id, status, failure) do
    at = Entities.now()

    abandoned =
      HalC2.Streams.transact(thread_id, :thread, fn stream ->
        case StreamState.get(stream, "run")[run_id] do
          %{"status" => active} = run when active in @active_runs ->
            state = abandoned_turn(stream, thread_id, run)

            changes =
              left_open(stream, run, status, at) ++
                ended(stream, state.turn.ids, status, failure, nil, at)

            {Enum.filter(changes, &is_tuple/1), state}

          _ ->
            {[], nil}
        end
      end)

    if abandoned, do: finished(abandoned, status, failure), else: :ok
  end

  # The runtime state `finish/3` needs, rebuilt from the run.
  defp abandoned_turn(stream, thread_id, run) do
    instance = run["providerInstanceId"]
    driver = Orchestration.driver_for(instance)
    attempt = StreamState.get(stream, "run-attempt")[run["activeAttemptId"]] || %{}
    session_id = "provider-session:#{driver}:#{thread_id}"

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

    cwd = (StreamState.get(stream, "provider-session")[session_id] || %{})["cwd"]
    %{thread_id: thread_id, turn: %{ids: ids, cwd: cwd, run_ordinal: run["ordinal"]}}
  end

  # The items, nodes and prompts a run left open, and its message still streaming. Its
  # root node ends with the run.
  defp left_open(stream, %{"id" => run_id, "rootNodeId" => root}, status, at) do
    nodes =
      for {id, %{"runId" => ^run_id}} <- StreamState.get(stream, "node"),
          into: MapSet.new(),
          do: id

    for {kind, open?, changes} <- [
          {"turn-item", &(&1["runId"] == run_id and &1["status"] in @open),
           %{"status" => status, "streaming" => false, "completedAt" => at, "updatedAt" => at}},
          {"node", &(&1["runId"] == run_id and &1["id"] != root and &1["status"] in @open),
           %{"status" => status, "completedAt" => at}},
          {"message", &(&1["runId"] == run_id and &1["streaming"] == true),
           %{"streaming" => false, "updatedAt" => at}},
          {"runtime-request", &(&1["nodeId"] in nodes and &1["status"] == "pending"),
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
            if(failure["class"] == "usage_limit",
              do: "Usage limit reached",
              else: "Provider error"
            ),
          "failure" => failure
        }
      )
    )
  end

  # "Run interrupted" in the transcript, under the user's request when there was one.
  defp interrupt_result(stream, ids, at) do
    item_id = "turn-item:run:#{ids.run}:signal:interrupt-result"

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
            "message" => "Run interrupted by user"
          }
        )
      )
  end

  defp capture_checkpoint(%{scope_id: scope_id} = turn, at) do
    HalC2.Checkpoint.capture_run(
      turn.cwd,
      scope_id,
      turn.run_ordinal,
      turn.ids.run,
      turn.ids.root_node,
      turn.ids.thread,
      at
    )
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
  `responseStreamingMode`, as the Node server does: "paragraph" writes finished
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
        %{id: item_id, message: message_id} = Map.fetch!(state.items, native)
        append = %{"a" => %{field => text}}

        [{"turn-item", item_id, append}] ++
          if(message_id && field == "text", do: [{"message", message_id, append}], else: [])
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
end
