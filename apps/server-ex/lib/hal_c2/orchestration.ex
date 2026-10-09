defmodule HalC2.Orchestration do
  @moduledoc """
  Client commands on this MC's threads: start a thread, send a message, answer
  an approval, and interrupt a run, for threads whose provider is Codex, Claude, or an
  ACP agent such as OpenCode;
  plus the diffs of their checkpoints.

  A message sent while a run is active steers it when its provider can take the
  message mid-turn (`steer/3`), or is queued: its run waits as `queued` with a queue
  position and starts when the thread is next idle (`start_next/1`). "restart"
  interrupts the running turn and puts the message first.

  Each command is decided inside the thread's stream process (`HalC2.Streams.transact/3`),
  so reading the thread and writing its new entities is atomic. Starting the provider
  turn happens after the commit, in the provider's runtime (`HalC2.Codex.ThreadRuntime`,
  `HalC2.Claude.ThreadRuntime`), which streams the turn back into the same log.
  """

  alias HalC2.Orchestration.Entities
  alias HalC2.{Patch, StreamState}
  alias HalC2.Projection.{JS, PullRequests}

  @active_statuses ~w(preparing starting running waiting)
  # The input of a prepared run's workspace preparation item, as the Node server names it.
  @preparing_workspace "Preparing workspace"

  @thread_updates ~w(thread.archive thread.unarchive thread.delete thread.settle thread.unsettle
                     thread.snooze thread.unsnooze thread.pin thread.unpin thread.pin.reorder
                     thread.active.reorder thread.visit thread.mark-unread thread.metadata.update
                     thread.runtime-mode.set thread.interaction-mode.set thread.model-selection.set
                     provider.switch thread.pull-request.link thread.pull-request.unlink
                     thread.title.regeneration.complete)
  # The longest order key a thread can hold; see `valid_order_key?/1`.
  @max_order_key 64
  # Commands that arrange a thread in the lists; an archived thread takes none of them.
  @organizing ~w(thread.settle thread.unsettle thread.snooze thread.unsnooze thread.pin
                 thread.unpin thread.pin.reorder thread.active.reorder)

  @doc "Handles one client RPC by method name; see `packages/contracts/src/orchestrationV2.ts`."
  @spec handle(String.t(), map) :: {:ok, term} | {:error, String.t()}
  def handle("orchestration.dispatchCommand", command) do
    HalC2.Traces.span("orchestration.dispatchCommand", %{"command.type" => command["type"]}, fn ->
      dispatch_once(command)
    end)
  end

  def handle("orchestration.launchThread", input), do: launch_thread(input)
  def handle("orchestration.searchThreads", input), do: HalC2.Search.threads(input)
  def handle("orchestration.getWorkflowScript", input), do: HalC2.WorkflowScripts.read(input)

  def handle("provider.uploadFeedback", %{"threadId" => thread_id} = input) do
    # The thread's latest provider thread says which provider ran it, as in the Node server.
    driver =
      case HalC2.Shell.row(node(), thread_id) do
        {"thread", _row} ->
          HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))
          |> StreamState.list("provider-thread")
          |> Enum.max_by(&(&1["lastRunOrdinal"] || 0), fn -> nil end)
          |> then(&(&1 && (&1["driver"] || driver_for(&1["providerInstanceId"] || "codex"))))

        _ ->
          nil
      end

    result =
      case driver do
        nil -> {:error, "No provider session has run in this thread yet."}
        "codex" -> HalC2.Codex.ThreadRuntime.upload_feedback(thread_id, input["reason"])
        driver -> {:error, "Provider '#{driver}' does not support feedback uploads."}
      end

    with {:error, message} <- result,
         do:
           {:error,
            %{
              "_tag" => "ProviderUploadFeedbackError",
              "threadId" => thread_id,
              "cause" => message
            }}
  end

  # This MC's archived threads, with the projects they belong to.
  def handle("orchestration.getArchivedShellSnapshot", _input) do
    rows = for {{mc, _id}, row} <- HalC2.Shell.rows(), mc == node(), do: row

    {:ok,
     %{
       "schemaVersion" => 1,
       "snapshotSequence" => 0,
       "projects" => for({"project", row} <- rows, row["deletedAt"] == nil, do: row),
       "threads" =>
         for(
           {"thread", row} <- rows,
           row["deletedAt"] == nil and row["archivedAt"] != nil,
           do: row
         )
     }}
  end

  def handle("orchestration.getTurnDiff", %{"threadId" => thread_id} = input),
    do: turn_diff(thread_id, input["fromTurnCount"], input["toTurnCount"], input)

  def handle("orchestration.getFullThreadDiff", %{"threadId" => thread_id} = input),
    do: turn_diff(thread_id, 0, input["toTurnCount"], input)

  def handle(method, _payload), do: {:error, "#{method} is not served by this MC yet"}

  defp turn_diff(thread_id, from, to, input) do
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))
    HalC2.Checkpoint.turn_diff(state, thread_id, from, to, input["ignoreWhitespace"] != false)
  end

  # A client's command id is answered once: repeating it, as a client retrying
  # after a reconnect does, returns the first outcome without deciding again (the
  # Node server's CommandReceiptStore). Receipts live in the store's meta table.
  # A receipt only answers for the thread the command acted on (its `threadId`, or the
  # `parentThreadId` a delegated task or created-thread record belongs to), so the same
  # id aimed at another thread is refused rather than answered with work done elsewhere.
  defp dispatch_once(%{"commandId" => id} = command) when is_binary(id) do
    key = "command-receipt:" <> id
    thread_id = command["threadId"] || command["parentThreadId"] || command["targetThreadId"]

    case HalC2.Store.meta(HalC2.Store.path(), key) do
      nil ->
        outcome = dispatch(command)

        case outcome do
          {:ok, %{} = result} ->
            HalC2.Store.put_meta(key, JSON.encode!(%{"ok" => result, "threadId" => thread_id}))

          {:error, message} when is_binary(message) ->
            HalC2.Store.put_meta(
              key,
              JSON.encode!(%{"error" => message, "threadId" => thread_id})
            )

          _ ->
            :ok
        end

        outcome

      receipt ->
        case JSON.decode!(receipt) do
          %{"threadId" => handled} when handled != thread_id ->
            {:error,
             "Command #{id} was already handled for thread #{handled} and cannot be replayed for #{thread_id}."}

          %{"error" => message} ->
            {:error, message}

          %{"ok" => result} ->
            {:ok, result}
        end
    end
  end

  defp dispatch_once(command), do: dispatch(command)

  @spec dispatch(map) :: {:ok, map} | {:error, String.t()}
  def dispatch(%{"type" => "message.dispatch", "threadId" => thread_id} = command) do
    # Uploads join the thread before the message names them.
    case HalC2.Attachments.claim(thread_id, command["attachments"] || []) do
      {:ok, attachments} ->
        with {:ok, _} = sent <- dispatch_message(thread_id, claimed(command, attachments)) do
          implemented_plan(thread_id, command["sourcePlanRef"])
          sent
        end

      {:error, _} = error ->
        error
    end
  end

  def dispatch(%{"type" => "thread.fork", "targetThreadId" => thread_id} = command) do
    with :ok <- HalC2.Orchestration.Fork.fork(command),
         do: {:ok, %{"sequence" => sequence(thread_id)}}
  end

  def dispatch(%{"type" => "thread.merge_back", "targetThreadId" => thread_id} = command) do
    with :ok <- HalC2.Orchestration.Fork.merge_back(command),
         do: {:ok, %{"sequence" => sequence(thread_id)}}
  end

  # An empty thread; launch_thread also sends a first message.
  def dispatch(%{"type" => "thread.create", "threadId" => thread_id} = command) do
    thread =
      command
      |> Entities.thread(Entities.now())
      |> Map.merge(Map.take(command, ~w(branch worktreePath)))

    created =
      HalC2.Streams.transact(thread_id, :thread, fn state ->
        if StreamState.get(state, "thread")[thread_id],
          do: {[], {:error, "Thread #{thread_id} already exists."}},
          else: {[create("thread", thread_id, thread)], :ok}
      end)

    with :ok <- created, do: {:ok, %{"sequence" => sequence(thread_id)}}
  end

  # A thread an agent created during a run shows in that run's transcript as a link.
  def dispatch(%{"type" => "thread.created.record", "parentThreadId" => parent_id} = command) do
    target_id = command["targetThreadId"]
    target_state = HalC2.Streams.Server.state(HalC2.Streams.ensure(target_id))
    target = StreamState.get(target_state, "thread")[target_id]
    target_run = command["targetRunId"]

    result =
      HalC2.Streams.transact(parent_id, :thread, fn state ->
        parent = StreamState.get(state, "thread")[parent_id]
        run = StreamState.get(state, "run")[command["parentRunId"]]
        node_id = command["parentNodeId"]

        cond do
          parent == nil ->
            {[], {:error, "unknown thread #{parent_id}"}}

          run == nil or run["rootNodeId"] != node_id ->
            {[],
             {:error, "Parent node #{node_id} is not the root of run #{command["parentRunId"]}."}}

          target == nil or target["projectId"] != parent["projectId"] ->
            {[], {:error, "Target thread #{target_id} belongs to another project."}}

          target_run != nil and StreamState.get(target_state, "run")[target_run] == nil ->
            {[], {:error, "Target run #{target_run} does not belong to thread #{target_id}."}}

          true ->
            at = Entities.now()
            item_id = "turn-item:thread-created:#{command["commandId"]}"

            ids = %{
              thread: parent_id,
              run: run["id"],
              root_node: node_id,
              provider_thread: run["providerThreadId"]
            }

            item =
              Entities.turn_item(
                ids,
                item_id,
                "thread_created",
                next_ordinal(state),
                "completed",
                at,
                %{
                  "title" => target["title"],
                  "targetThreadId" => target_id,
                  "targetRunId" => target_run,
                  "targetProviderInstanceId" => get_in(target, ["modelSelection", "instanceId"]),
                  "targetModel" => get_in(target, ["modelSelection", "model"])
                }
              )

            {[create("turn-item", item_id, item)], :ok}
        end
      end)

    with :ok <- result, do: {:ok, %{"sequence" => sequence(parent_id)}}
  end

  # Stops the thread's provider process ("Stop session"). The next run starts it
  # again and resumes the provider thread.
  def dispatch(%{"type" => "provider-session.detach", "threadId" => thread_id} = command) do
    session_id = command["providerSessionId"]

    detached =
      HalC2.Streams.transact(thread_id, :thread, fn state ->
        cond do
          Enum.any?(StreamState.list(state, "run"), &(&1["status"] in @active_statuses)) ->
            {[], {:error, "Interrupt the current turn before stopping the session."}}

          StreamState.get(state, "provider-session")[session_id] ->
            {[{"provider-session", session_id, Patch.delete()}], :ok}

          true ->
            {[], :ok}
        end
      end)

    with :ok <- detached do
      stop_session(thread_id)
      {:ok, %{"sequence" => sequence(thread_id)}}
    end
  end

  def dispatch(%{"type" => "checkpoint.rollback", "threadId" => thread_id} = command) do
    with :ok <- HalC2.Orchestration.Rollback.run(command),
         do: {:ok, %{"sequence" => sequence(thread_id)}}
  end

  # The user's stop shows in the transcript as a request, paired with the run's
  # "Run interrupted" result once the provider stops (`TurnWriter.finish/3`).
  def dispatch(%{"type" => "run.interrupt", "threadId" => thread_id} = command) do
    HalC2.Streams.transact(thread_id, :thread, &{interrupt_request(&1, command), :ok})

    with :ok <- interrupt_any(thread_id, command["runId"]),
         do: {:ok, %{"sequence" => sequence(thread_id)}}
  end

  def dispatch(%{"type" => "queued-run.cancel", "threadId" => thread_id, "runId" => run_id}) do
    queue_change(thread_id, fn state ->
      at = Entities.now()

      [
        upsert(
          state,
          "run",
          run_id,
          # A run that already started is not the queue's to cancel.
          &if(&1["status"] == "queued",
            do:
              Map.merge(&1, %{
                "status" => "cancelled",
                "queuePosition" => nil,
                "completedAt" => at
              }),
            else: &1
          )
        )
      ]
    end)
  end

  def dispatch(
        %{"type" => "queued-run.edit", "threadId" => thread_id, "runId" => run_id} = command
      ) do
    # Attachments, when given, replace the message's (uploads join the thread first);
    # context, when given, replaces its context records.
    with {:ok, command} <- edit_claims(thread_id, command) do
      edited =
        %{"text" => command["text"] || "", "updatedAt" => Entities.now()}
        |> Map.merge(Map.take(command, ["attachments"]))
        |> then(&if(command["context"], do: Map.put(&1, "context", command["context"]), else: &1))

      queue_change(thread_id, fn state ->
        case StreamState.get(state, "run")[run_id] do
          %{"status" => "queued", "userMessageId" => message_id} ->
            [upsert(state, "message", message_id, &Map.merge(&1, edited))]

          _ ->
            []
        end
      end)
    end
  end

  def dispatch(
        %{"type" => "queued-run.reorder", "threadId" => thread_id, "runId" => run_id} = command
      ) do
    queue_change(thread_id, fn state ->
      queued = queued_runs(state) |> Enum.map(& &1["id"])

      # A run that already started, or never existed, has no place in the queue.
      if run_id in queued do
        queued = List.delete(queued, run_id)

        order =
          case Enum.find_index(queued, &(&1 == command["beforeRunId"])) do
            nil -> queued ++ [run_id]
            index -> List.insert_at(queued, index, run_id)
          end

        for {id, position} <- Enum.with_index(order, 1),
            do: upsert(state, "run", id, &Map.put(&1, "queuePosition", position))
      else
        []
      end
    end)
  end

  # A link's host snapshot and native stack, from `HalC2.PullRequests.Sync`.
  def dispatch(%{"type" => "thread.pull-request-link.sync", "threadId" => thread_id} = command) do
    quiet_update(thread_id, fn thread ->
      links = PullRequests.of(thread)
      key = PullRequests.key(command)

      if Enum.any?(links, &(PullRequests.key(&1) == key)) do
        links
        |> Enum.map(fn link ->
          if PullRequests.key(link) == key,
            do: %{link | "snapshot" => command["snapshot"], "stack" => command["stack"]},
            else: link
        end)
        |> then(&pull_request_fields(thread, &1))
      else
        %{}
      end
    end)
  end

  # The branch's pull request, from `HalC2.PullRequests.Discovery`, refused when what it
  # was decided from (`expected`) no longer holds.
  def dispatch(%{"type" => "thread.pull-request.sync", "threadId" => thread_id} = command) do
    expected = command["expected"] || %{}

    project =
      case HalC2.Shell.row(node(), command["projectId"]) do
        {"project", row} -> if row["deletedAt"] == nil, do: row
        _ -> nil
      end

    quiet_update(thread_id, fn thread ->
      same? = fn field ->
        Map.take(JS.json(JS.get(thread, field)) || %{}, ~w(projectId repository number url)) ==
          Map.take(expected[field] || %{}, ~w(projectId repository number url))
      end

      cond do
        JS.get(thread, "archivedAt") != nil ->
          {:error, "Thread #{thread_id} is archived."}

        project == nil or project["workspaceRoot"] != expected["workspaceRoot"] or
          thread["projectId"] != command["projectId"] or
          JS.get(thread, "branch") != expected["branch"] or
          JS.get(thread, "worktreePath") != expected["worktreePath"] or
          not same?.("linkedPullRequest") or not same?.("branchPullRequest") ->
          {:error, "Thread #{thread_id} changed before pull request discovery."}

        Map.has_key?(command, "linkedPullRequest") ->
          thread
          |> replace_linked(command["linkedPullRequest"], Entities.now())
          |> Map.put("branchPullRequest", command["branchPullRequest"])

        true ->
          %{"branchPullRequest" => command["branchPullRequest"]}
      end
    end)
  end

  # Settles a thread `HalC2.Orchestration.Settlement` found idle or done, unless it was
  # touched after the row that was judged (`snapshotAt`) or settled or unsettled by hand.
  def dispatch(%{"type" => "thread.auto-settle", "threadId" => thread_id} = command) do
    snapshot_at = JS.epoch_ms(command["snapshotAt"])

    result =
      HalC2.Streams.transact(thread_id, :thread, fn state ->
        thread = StreamState.get(state, "thread")[thread_id]

        if thread == nil or JS.get(thread, "settledOverride") != nil or snapshot_at == nil or
             (state.updated_at || 0) > snapshot_at do
          {[], {:error, "Thread #{thread_id} changed before automatic settlement."}}
        else
          fields = thread_fields("thread.settle", command, thread, Entities.now())

          {Enum.reject([upsert(state, "thread", thread_id, &Map.merge(&1, fields))], &is_nil/1),
           :ok}
        end
      end)

    with :ok <- result, do: {:ok, %{"sequence" => sequence(thread_id)}}
  end

  # Commands that set fields on the thread itself.
  def dispatch(%{"type" => type, "threadId" => thread_id} = command)
      when type in @thread_updates do
    at = Entities.now()

    result =
      HalC2.Streams.transact(thread_id, :thread, fn state ->
        case StreamState.get(state, "thread")[thread_id] do
          nil ->
            {[], {:error, "unknown thread #{thread_id}"}}

          # A deleted thread is gone for good; deleting it again changes nothing.
          %{"deletedAt" => deleted} when deleted != nil and type == "thread.delete" ->
            {[], :ok}

          %{"deletedAt" => deleted} when deleted != nil ->
            {[], {:error, "Thread #{thread_id} is deleted."}}

          # Read-only while it moves: the destination takes the thread as the move found
          # it, and a change made here meanwhile would be lost. A visit only marks it read.
          %{"moving" => %{"label" => to}} = thread when type != "thread.visit" ->
            {[],
             {:error, "#{thread["title"]} is moving to #{to}. Try again once it has arrived."}}

          # The thread lives where it moved: a change to the record left here would be lost.
          # Deleting its project still deletes the record.
          %{"movedTo" => %{} = moved} = thread when type not in ~w(thread.visit thread.delete) ->
            {[], {:error, "#{thread["title"]} has moved to #{moved["label"]}."}}

          thread ->
            case refusal(type, command, thread, state) ||
                   with(
                     %{} = fields <- thread_fields(type, command, thread, at),
                     %{} = recovery <- limit_recovery(state, command, thread, at),
                     do: Map.merge(fields, recovery)
                   ) do
              {:error, _} = error ->
                {[], error}

              fields ->
                change =
                  state
                  |> upsert("thread", thread_id, &Map.merge(&1, fields))
                  |> quiet_read_state(type)

                # A deleted thread's sessions stop before the thread goes.
                changes =
                  deleted_thread(type, state, at) ++ [change | archived_queue(type, state, at)]

                {Enum.reject(changes, &is_nil/1), :ok}
            end
        end
      end)

    with :ok <- result do
      if type == "thread.metadata.update" and command["regenerateTitle"] == true,
        do: regenerate_title(thread_id)

      if type == "thread.delete", do: stop_runtimes(thread_id)

      {:ok, %{"sequence" => sequence(thread_id)}}
    end
  end

  # A queued message steers the running turn when its provider can take it; otherwise
  # it goes first and the run is interrupted, which starts it next.
  def dispatch(%{"type" => "queued-message.promote-to-steer", "threadId" => thread_id} = command) do
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))
    thread = StreamState.get(state, "thread")[thread_id]
    runs = StreamState.get(state, "run")
    queued = runs[command["queuedRunId"]]
    target = runs[command["targetRunId"]]
    message = queued && StreamState.get(state, "message")[queued["userMessageId"]]

    cond do
      thread == nil ->
        {:error, "unknown thread #{thread_id}"}

      thread["archivedAt"] != nil or thread["deletedAt"] != nil ->
        {:error, "Thread #{thread_id} is not active."}

      queued["status"] != "queued" ->
        {:error, "Queued run #{command["queuedRunId"]} is not queued."}

      message && target && target["status"] in @active_statuses && steerable?(target) &&
          runtime(target["providerInstanceId"]).steer(
            thread_id,
            target["id"],
            steer_input(message)
          ) == :ok ->
        promoted(thread_id, queued, target, message)

      true ->
        restart_promoted(thread_id, command)
    end
  end

  # After a restart the queue waits until the user resumes it.
  def dispatch(%{"type" => "queue.resume", "threadId" => thread_id}) do
    with {:ok, result} <-
           queue_change(thread_id, fn state ->
             for run <- queued_runs(state),
                 do: upsert(state, "run", run["id"], &Map.put(&1, "queueHeld", false))
           end) do
      start_next(thread_id)
      {:ok, result}
    end
  end

  # An approval's decision, or answers to questions (`answers`, by question id).
  def dispatch(%{"type" => "runtime-request.respond", "threadId" => thread_id} = command) do
    case message_request(thread_id, command["requestId"]) do
      nil ->
        with {:ok, response} <- response(thread_id, command),
             do: respond(thread_id, command["requestId"], response)

      request ->
        answer_with_message(thread_id, request, command)
    end
  end

  # Closing questions without answering them.
  def dispatch(%{"type" => "thread.user-input.dismiss", "threadId" => thread_id} = command) do
    case message_request(thread_id, command["requestId"]) do
      nil ->
        respond(thread_id, command["requestId"], %{"dismissed" => true})

      %{"status" => "pending"} = request ->
        HalC2.Streams.transact(thread_id, :thread, fn state ->
          {resolve_message_request(state, request, "cancelled", nil), :ok}
        end)

        {:ok, %{"sequence" => sequence(thread_id)}}

      _ ->
        {:error, "This question has already been answered."}
    end
  end

  # Delegated tasks (`HalC2.Orchestration.Delegation`).
  def dispatch(%{"type" => "delegated_task." <> _, "parentThreadId" => thread_id} = command) do
    result =
      case command["type"] do
        "delegated_task.request" ->
          HalC2.Orchestration.Delegation.request(command)

        "delegated_task.wake-policy" ->
          HalC2.Orchestration.Delegation.wake_policy(command)

        "delegated_task.completion-delivery." <> _ ->
          HalC2.Orchestration.Delegation.resolve_delivery(command)

        type ->
          {:error, "#{type} is not supported by this MC yet"}
      end

    with :ok <- result, do: {:ok, %{"sequence" => sequence(thread_id)}}
  end

  def dispatch(%{"type" => "notification.delivery.accept", "threadId" => thread_id} = command) do
    with :ok <- HalC2.Orchestration.Delegation.accept_delivery(command),
         do: {:ok, %{"sequence" => sequence(thread_id)}}
  end

  # Prepared runs: a workspace being made ready before the run's first turn.
  def dispatch(
        %{"type" => "prepared-run." <> action, "threadId" => thread_id, "runId" => run_id} =
          command
      ) do
    result =
      case action do
        "progress" ->
          progress_prepared(thread_id, run_id, command["phase"])

        "fail" ->
          fail_prepared(thread_id, run_id, "failed", command["failure"])

        "release" ->
          with {:error, _} <- release_prepared(thread_id, run_id),
               do: {:error, not_preparing(run_id)}

        _ ->
          {:error, "prepared-run.#{action} is not supported by this MC yet"}
      end

    with ok when ok in [:ok, {:ok, :ok}] <- result,
         do: {:ok, %{"sequence" => sequence(thread_id)}}
  end

  def dispatch(%{"type" => type}), do: {:error, "#{type} is not supported by this MC yet"}

  # A question the provider asked without waiting (Codex's async questions) has no
  # provider call to answer: its answer is a user message.
  # The provider took the promoted message into its running turn.
  defp promoted(thread_id, queued, target, message) do
    HalC2.Streams.transact(thread_id, :thread, fn state ->
      at = Entities.now()

      changes =
        [
          upsert(
            state,
            "run",
            queued["id"],
            &Map.merge(&1, %{
              "status" => "cancelled",
              "queuePosition" => nil,
              "completedAt" => at
            })
          ),
          upsert(state, "message", message["id"], &Map.put(&1, "runId", target["id"]))
        ] ++
          steer_changes(state, target, message["id"], message, "promoted_queued_to_steer", at)

      {Enum.reject(changes, &is_nil/1), :ok}
    end)

    HalC2.Streams.transact(thread_id, :thread, fn state -> {renumber(state), :ok} end)
    {:ok, %{"sequence" => sequence(thread_id)}}
  end

  defp message_request(thread_id, request_id) do
    request =
      HalC2.Streams.ensure(thread_id)
      |> HalC2.Streams.Server.state()
      |> StreamState.get("runtime-request")
      |> Map.get(request_id)

    if request && HalC2.Orchestration.TurnWriter.message_request?(request), do: request
  end

  # The answer resolves the request and goes to the provider as a message: into the
  # running turn when there is one to steer, else as the thread's next turn. Sending
  # the same answer again changes nothing.
  defp answer_with_message(thread_id, request, command) do
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))
    item = StreamState.get(state, "turn-item")[question_item(request)] || %{}
    answers = command["answers"] || %{}

    replies =
      for question <- item["questions"] || [] do
        case answers[question["id"]] do
          answer when is_binary(answer) ->
            if String.trim(answer) != "", do: question["question"] <> "
" <> String.trim(answer)

          _ ->
            nil
        end
      end

    message_id = "async-answer:" <> request["id"]

    cond do
      request["status"] != "pending" ->
        if StreamState.get(state, "message")[message_id],
          do: {:ok, %{"sequence" => sequence(thread_id)}},
          else: {:error, "This question has already been answered."}

      replies == [] or Enum.any?(replies, &is_nil/1) ->
        {:error, "Answer each question before sending."}

      true ->
        answer = %{"requestId" => request["id"], "answers" => answers}

        HalC2.Streams.transact(thread_id, :thread, fn state ->
          {resolve_message_request(state, request, "resolved", answer), :ok}
        end)

        running =
          state
          |> StreamState.list("run")
          |> Enum.find(&(&1["status"] == "running"))

        dispatch(%{
          "type" => "message.dispatch",
          "commandId" => command["commandId"],
          "threadId" => thread_id,
          "messageId" => message_id,
          "text" => Enum.join(replies, "

"),
          "attachments" => [],
          "createdBy" => "user",
          "creationSource" => "server",
          "dispatchMode" =>
            if(running,
              do: %{"type" => "steer_active", "targetRunId" => running["id"]},
              else: %{"type" => "queue_after_active"}
            )
        })
    end
  end

  # A pending request a provider waits on. A question answered with a message holds
  # nothing up.
  defp blocking_request?(state) do
    Enum.any?(
      StreamState.list(state, "runtime-request"),
      &(&1["status"] == "pending" and not HalC2.Orchestration.TurnWriter.message_request?(&1))
    )
  end

  # A question's item is named after its node, whatever names them: this MC
  # (`node:approval:...`) or the Node server a thread was imported from
  # (`node:provider:...`).
  defp question_item(request),
    do: String.replace_prefix(request["nodeId"] || "", "node:", "turn-item:")

  defp resolve_message_request(state, request, status, answer) do
    at = Entities.now()
    item_status = if status == "resolved", do: "completed", else: "cancelled"

    [
      upsert(state, "runtime-request", request["id"], fn request ->
        request
        |> Map.merge(%{"status" => status, "resolvedAt" => at})
        |> then(&if(answer, do: Map.put(&1, "answers", answer["answers"]), else: &1))
      end),
      upsert(state, "turn-item", question_item(request), fn
        nil ->
          nil

        item ->
          item
          |> Map.merge(%{"status" => item_status, "completedAt" => at, "updatedAt" => at})
          |> then(&if(answer, do: Map.put(&1, "questionAnswer", answer), else: &1))
      end)
    ]
    |> Enum.filter(&is_tuple/1)
  end

  defp response(thread_id, %{"answers" => %{} = answers} = command) do
    by_question = command["attachmentsByQuestionId"] || %{}

    claimed =
      Enum.reduce_while(by_question, {:ok, %{}}, fn {question, attachments}, {:ok, acc} ->
        case HalC2.Attachments.claim(thread_id, attachments) do
          {:ok, claimed} -> {:cont, {:ok, Map.put(acc, question, claimed)}}
          {:error, message} -> {:halt, {:error, message <> " Attach it again."}}
        end
      end)

    with {:ok, claimed} <- claimed do
      answer = %{
        "requestId" => command["requestId"],
        "answers" => answers,
        "attachmentsByQuestionId" => claimed
      }

      {:ok, %{"answers" => with_attachment_paths(answers, claimed), "questionAnswer" => answer}}
    end
  end

  defp response(_thread_id, command), do: {:ok, %{"decision" => command["decision"] || "decline"}}

  # Answers keep their provider's shape; files are named by where they are saved,
  # as the Node server words it.
  defp with_attachment_paths(answers, claimed) do
    Enum.reduce(claimed, answers, fn
      {_question, []}, answers ->
        answers

      {question, attachments}, answers ->
        text =
          Enum.map_join(attachments, "\n", fn attachment ->
            "Attached #{attachment["type"] || "file"} #{JSON.encode!(attachment["name"])}: " <>
              JSON.encode!(HalC2.Attachments.path(attachment) || "")
          end)

        Map.put(
          answers,
          question,
          case answers[question] do
            list when is_list(list) -> list ++ [text]
            answer when is_binary(answer) and answer != "" -> answer <> "\n\n" <> text
            _ -> text
          end
        )
    end)
  end

  @doc """
  Stops an idle thread's provider processes and marks its sessions stopped; the
  next run starts them again and resumes the provider's thread. Refused while a
  run is active.
  """
  def release_session(thread_id) do
    released =
      HalC2.Streams.transact(thread_id, :thread, fn state ->
        if Enum.any?(StreamState.list(state, "run"), &(&1["status"] in @active_statuses)) do
          {[], :busy}
        else
          at = Entities.now()

          changes =
            for session <- StreamState.list(state, "provider-session"),
                session["status"] != "stopped",
                do:
                  upsert(
                    state,
                    "provider-session",
                    session["id"],
                    &Map.merge(&1, %{"status" => "stopped", "updatedAt" => at})
                  )

          {changes, :ok}
        end
      end)

    if released == :ok, do: stop_session(thread_id)
    released
  end

  # A runtime runs under its provider plugin's sessions supervisor (`HalC2.Plugins`).
  defp stop_runtimes(thread_id) do
    for registry <- [
          HalC2.Codex.Registry,
          HalC2.Claude.Registry,
          HalC2.Acp.Registry,
          HalC2.Pi.Registry
        ],
        Process.whereis(registry) != nil,
        {pid, _} <- Registry.lookup(registry, thread_id) do
      try do
        GenServer.stop(pid, :shutdown)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  # The stopped session's agent loses its HAL-C2 tools; the next session gets new ones.
  # A deleted thread only stops its runtimes: its agent's credential still reaches
  # the tools, which answer that the calling thread is gone.
  defp stop_session(thread_id) do
    stop_runtimes(thread_id)
    HalC2.Mcp.revoke(thread_id)
  end

  # The built-in runtimes, and the plugin adapters that can take a runtime call.
  defp runtimes(callback, arity) do
    builtin = [
      HalC2.Codex.ThreadRuntime,
      HalC2.Claude.ThreadRuntime,
      HalC2.Acp.ThreadRuntime,
      HalC2.Pi.ThreadRuntime
    ]

    builtin ++
      for(
        module <- HalC2.Plugins.adapters(),
        function_exported?(module, callback, arity),
        do: module
      )
  end

  defp respond(thread_id, request_id, response) do
    result =
      Enum.find_value(
        runtimes(:respond, 3),
        {:error, "no pending request"},
        fn runtime ->
          if runtime.respond(thread_id, request_id, response) == :ok, do: :ok
        end
      )

    with :ok <- result, do: {:ok, %{"sequence" => sequence(thread_id)}}
  end

  # The checkout is ready and its baseline taken before the runtime starts the turn.
  defp begin_turn(thread_id, turn) do
    restore_worktree(thread_id)
    :ok = HalC2.Checkpoint.baseline(turn.cwd, turn.scope_id, turn.run_ordinal - 1)
    start_turn(thread_id, turn)
  end

  # A worktree the storage sweep removed comes back at the same path from the
  # thread's branch before a turn runs in it, as the Node server's turn start does.
  defp restore_worktree(thread_id) do
    with {"thread", %{"worktreePath" => path, "branch" => branch} = row}
         when is_binary(path) and is_binary(branch) <- HalC2.Shell.row(node(), thread_id),
         false <- File.exists?(path),
         root when is_binary(root) <- project_root(row["projectId"]) do
      require Logger
      Logger.warning("recreating the missing worktree of #{thread_id} at #{path}")
      _ = HalC2.Git.run(root, ~w(worktree prune))

      with {:error, reason} <-
             HalC2.Vcs.create_worktree(%{"cwd" => root, "refName" => branch, "path" => path}),
           do:
             Logger.warning("could not recreate the worktree of #{thread_id}: #{inspect(reason)}")
    end

    :ok
  end

  # A runtime that dies while starting the turn must not leave the run "starting"
  # forever: the run fails and the thread can take the next message. Once the turn
  # was claimed, `HalC2.Orchestration.TurnWatch` may be ending it too; only the
  # first to abandon it does.
  defp start_turn(thread_id, turn) do
    :ok = runtime(turn.ids.instance).start_turn(thread_id, turn)
  catch
    :exit, reason ->
      require Logger
      Logger.warning("turn failed to start in #{thread_id}: #{inspect(reason)}")

      HalC2.Orchestration.TurnWriter.abandon(
        thread_id,
        turn.ids.run,
        "failed",
        HalC2.Orchestration.TurnWriter.start_failure(nil, :closed)
      )
  end

  @doc """
  Creates a thread, in the project root, an existing worktree, or a new worktree,
  and sends its first message when there is one (`orchestration.launchThread`). A
  new worktree is prepared first (`HalC2.WorktreeSetup`), with the message's run
  waiting as `preparing` until it is ready.

  `plugin:` marks the thread as one a plugin started (`HalC2.Plugins.Host`); clients
  cannot set it.
  """
  @spec launch_thread(map, keyword) :: {:ok, map} | {:error, String.t()}
  def launch_thread(input, opts \\ []) do
    thread_id = input["threadId"] || HalC2.Environment.uuid4()
    strategy = input["workspaceStrategy"] || %{"type" => "root"}
    at = Entities.now()

    message = input["initialMessage"]

    # A title asked for is in flight from the start, as a regeneration is.
    titling =
      if input["generateTitle"] == true and message != nil and
           ((message["text"] || "") != "" or (message["attachments"] || []) != []),
         do: %{"requestId" => input["commandId"] || thread_id, "startedAt" => at}

    thread =
      Entities.thread(Map.put(input, "threadId", thread_id), at)
      |> Map.merge(workspace_fields(strategy))
      # A delegated task's thread is a subagent of the thread that asked for it.
      |> Map.merge(Map.take(input, ["lineage"]))
      |> then(&if(mark = opts[:plugin], do: Map.put(&1, "plugin", mark), else: &1))
      |> then(&if(titling, do: Map.put(&1, "titleRegeneration", titling), else: &1))

    reuse? = input["reuseExistingThread"] == true

    transacted =
      HalC2.Streams.transact(thread_id, :thread, fn state ->
        case StreamState.get(state, "thread")[thread_id] do
          nil when reuse? ->
            {[], {:error, "Thread #{thread_id} does not exist."}}

          nil ->
            {[{"thread", thread_id, Patch.diff(nil, thread)}], {:ok, :created}}

          # A draft the client already created takes the launch's workspace, as
          # the Node server's `reuseExistingThread` does, but only while empty.
          existing when reuse? ->
            if reusable?(state, existing, input["projectId"]) do
              fields =
                workspace_fields(strategy)
                |> then(&if(titling, do: Map.put(&1, "titleRegeneration", titling), else: &1))

              {Enum.reject(
                 [upsert(state, "thread", thread_id, &Map.merge(&1, fields))],
                 &is_nil/1
               ), {:ok, :reused}}
            else
              {[],
               {:error,
                "Only an empty active thread in the target project can change workspace during launch."}}
            end

          _ when titling != nil ->
            change =
              upsert(state, "thread", thread_id, &Map.put(&1, "titleRegeneration", titling))

            {[change], {:ok, :resumed}}

          _ ->
            {[], {:ok, :resumed}}
        end
      end)

    with {:ok, created} <- transacted,
         do: launch_message(thread_id, thread, strategy, input, message, titling, created)
  end

  defp reusable?(state, thread, project_id) do
    thread["projectId"] == project_id and thread["archivedAt"] == nil and
      thread["deletedAt"] == nil and StreamState.get(state, "message") == %{} and
      StreamState.get(state, "run") == %{}
  end

  defp launch_message(thread_id, thread, strategy, input, message, titling, created) do
    result = %{"threadId" => thread_id, "resumed" => created == :resumed}

    case message do
      nil ->
        {:ok, result}

      message ->
        if titling,
          do: generate_title(thread_id, message["text"] || "", message["attachments"] || [])

        command =
          Map.merge(message, %{
            "type" => "message.dispatch",
            "commandId" => "#{input["commandId"]}:initial-message",
            "threadId" => thread_id,
            "createdBy" => input["createdBy"] || "user",
            "creationSource" => input["creationSource"] || "web",
            "modelSelection" => input["modelSelection"]
          })

        # The first message is a command of its own (`<commandId>:initial-message`),
        # answered once like any client command.
        launched =
          if strategy["type"] == "worktree" and created in [:created, :reused],
            do: launch_in_worktree(thread_id, thread, strategy, command),
            else: dispatch_once(command)

        with {:ok, _} <- launched, do: {:ok, result}
    end
  end

  defp workspace_fields(%{"type" => "existing_worktree"} = strategy),
    do: %{"worktreePath" => strategy["worktreePath"], "branch" => strategy["branch"]}

  defp workspace_fields(%{"type" => "root", "branch" => branch}) when is_binary(branch),
    do: %{"branch" => branch}

  defp workspace_fields(_strategy), do: %{"branch" => nil}

  defp launch_in_worktree(thread_id, thread, strategy, command) do
    project =
      case HalC2.Shell.row(node(), thread["projectId"]) do
        {"project", row} -> row
        _ -> nil
      end

    with %{"workspaceRoot" => _} <- project || {:error, "The project is not on this MC."},
         {:ok, attachments} <- HalC2.Attachments.claim(thread_id, command["attachments"] || []),
         command =
           command
           |> claimed(attachments)
           |> Map.put("dispatchMode", %{"type" => "defer_start"}),
         {:ok, {:prepared, run_id}} <-
           HalC2.Streams.transact(thread_id, :thread, &decide_message(&1, thread_id, command)) do
      :ok = HalC2.WorktreeSetup.start(thread_id, run_id, project, strategy, command["text"])
      {:ok, %{"sequence" => sequence(thread_id)}}
    else
      {:ok, :sent} -> {:ok, %{"sequence" => sequence(thread_id)}}
      refused -> refused
    end
  end

  # Titles a thread in the background, as the Node server does: from its first
  # message's `text` and `attachments` (tried three times), or, regenerating, from
  # its user and assistant messages and its `previous` title. The thread keeps its
  # title until a new one arrives; generation that fails or keeps the title clears
  # the thread's in-flight mark (`titleRegeneration`).
  defp generate_title(thread_id, text, attachments, previous \\ nil) do
    Task.start(fn ->
      root =
        case HalC2.Shell.row(node(), thread_id) do
          {"thread", row} -> row["worktreePath"] || project_root(row["projectId"])
          _ -> nil
        end

      opts = [attachments: attachments, previous_title: previous]
      attempts = if previous, do: 1, else: 3

      result =
        Enum.reduce_while(1..attempts, nil, fn attempt, _ ->
          case HalC2.TextGeneration.thread_title(root || System.tmp_dir!(), text, opts) do
            {:ok, _} = ok ->
              {:halt, ok}

            error ->
              if attempt < attempts,
                do:
                  Process.sleep(
                    Application.get_env(:hal_c2, :title_retry_ms, 2_000) * 2 ** (attempt - 1)
                  )

              {:cont, error}
          end
        end)

      case result do
        {:ok, %{"title" => title}} when title != "New thread" ->
          if previous != nil and String.trim(title) == String.trim(previous),
            do: title_settled(thread_id),
            else:
              dispatch(%{
                "type" => "thread.metadata.update",
                "threadId" => thread_id,
                "title" => title
              })

        failure ->
          require Logger

          unless match?({:ok, _}, failure),
            do: Logger.warning("thread title not generated: #{inspect(failure)}")

          title_settled(thread_id)
      end
    end)
  end

  defp title_settled(thread_id),
    do:
      dispatch(%{
        "type" => "thread.metadata.update",
        "threadId" => thread_id,
        "regenerateTitle" => false
      })

  defp regenerate_title(thread_id) do
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))
    previous = (StreamState.get(state, "thread")[thread_id] || %{})["title"] || ""

    messages =
      state
      |> StreamState.list("message")
      |> Enum.filter(&(&1["role"] in ["user", "assistant"] and &1["streaming"] != true))

    case HalC2.TextGeneration.Prompts.thread_context(messages) do
      {"", []} -> title_settled(thread_id)
      {text, attachments} -> generate_title(thread_id, text, attachments, previous)
    end
  end

  @doc """
  Starts the run a prepared workspace was waiting for (`prepared-run.release`),
  completing its preparation item.
  """
  def release_prepared(thread_id, run_id) do
    decide = fn state ->
      thread = StreamState.get(state, "thread")[thread_id]
      runs = StreamState.list(state, "run")

      with %{"status" => "preparing"} = run <- StreamState.get(state, "run")[run_id],
           %{} = message <- StreamState.get(state, "message")[run["userMessageId"]] do
        {changes, result} = new_run(state, thread, runs, message, run)

        done =
          preparation(state, run_id, %{
            "status" => "completed",
            "title" => "Workspace ready",
            "output" => "Workspace preparation completed.",
            "exitCode" => 0
          })

        {changes ++ Enum.reject([done], &is_nil/1), result}
      else
        _ -> {[], {:error, "the run is not waiting for its workspace"}}
      end
    end

    case HalC2.Streams.transact(thread_id, :thread, decide) do
      {:ok, turn} ->
        begin_turn(thread_id, turn)
        started(thread_id, run_id)

      {:error, _} = error ->
        error
    end
  end

  # An agent that cannot start fails its run before `start_turn` returns.
  defp started(thread_id, run_id) do
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))

    case StreamState.get(state, "run")[run_id] do
      %{"status" => "failed"} ->
        error =
          state
          |> StreamState.list("provider-session")
          |> Enum.find_value(& &1["lastError"])

        {:error, error || "the run failed"}

      _ ->
        :ok
    end
  end

  @doc """
  Shows which phase a prepared run's workspace is in (`prepared-run.progress`):
  `"worktree"` or `"setup"`.
  """
  def progress_prepared(thread_id, run_id, phase) do
    title = if phase == "worktree", do: "Preparing worktree", else: "Starting setup script"

    HalC2.Streams.transact(thread_id, :thread, fn state ->
      case StreamState.get(state, "run")[run_id] do
        %{"status" => "preparing"} ->
          {Enum.reject([preparation(state, run_id, %{"title" => title})], &is_nil/1), :ok}

        _ ->
          {[], {:error, not_preparing(run_id)}}
      end
    end)
  end

  @doc """
  Ends a run whose workspace could not be prepared (`failed` or `cancelled`). A
  failure (`OrchestrationV2ProviderFailure`) is shown on the preparation item and as
  an error item, as `prepared-run.fail` does.
  """
  def fail_prepared(thread_id, run_id, status, failure \\ nil) do
    result =
      HalC2.Streams.transact(thread_id, :thread, fn state ->
        case StreamState.get(state, "run")[run_id] do
          %{"status" => "preparing"} = run ->
            at = Entities.now()

            ended =
              upsert(state, "run", run_id, fn _ ->
                Map.merge(run, %{"status" => status, "completedAt" => at})
              end)

            item =
              case failure do
                %{"message" => message} ->
                  %{
                    "status" => "failed",
                    "title" => "Workspace preparation failed",
                    "output" => message,
                    "exitCode" => 1
                  }

                nil ->
                  %{"status" => status}
              end

            error =
              if failure do
                ids = %{
                  thread: thread_id,
                  run: run_id,
                  root_node: run["rootNodeId"],
                  provider_thread: run["providerThreadId"]
                }

                id = "turn-item:workspace-preparation-failure:#{run_id}"

                create(
                  "turn-item",
                  id,
                  Entities.turn_item(ids, id, "error", next_ordinal(state), "failed", at, %{
                    "title" => "Workspace preparation failed",
                    "failure" => failure
                  })
                )
              end

            {Enum.reject([ended, preparation(state, run_id, item), error], &is_nil/1), :ok}

          _ ->
            {[], {:error, not_preparing(run_id)}}
        end
      end)

    start_next(thread_id)
    result
  end

  defp not_preparing(run_id), do: "Run #{run_id} is not awaiting workspace preparation."

  # Updates a prepared run's "Preparing workspace" item, when it has one.
  defp preparation(state, run_id, fields) do
    id = preparation_item_id(run_id)
    at = Entities.now()

    if StreamState.get(state, "turn-item")[id] do
      ended =
        if fields["status"] in ~w(completed failed cancelled),
          do: %{"completedAt" => at},
          else: %{}

      upsert(
        state,
        "turn-item",
        id,
        &Map.merge(&1, Map.merge(fields, Map.put(ended, "updatedAt", at)))
      )
    end
  end

  # The provider driver for an instance: its own id for ACP agents.
  @doc "The driver behind a provider instance."
  # With plugins running, the provider plugin serving the instance decides both.
  def driver_for(instance) do
    case HalC2.Plugins.provider(instance) do
      {:ok, driver, _module} -> driver
      {:missing, driver} -> driver
      _ -> builtin_driver(instance)
    end
  end

  defp builtin_driver("claudeAgent"), do: "claudeAgent"

  # An instance the settings add for Claude runs on Claude, as the built-in one does.
  defp builtin_driver(instance) do
    cond do
      HalC2.Acp.agent?(instance) -> instance
      instance in HalC2.Settings.instances_of("claudeAgent") -> "claudeAgent"
      true -> "codex"
    end
  end

  @doc "The runtime (a `HalC2.Plugins.ProviderAdapter`) for a provider instance."
  def runtime(instance) do
    case is_binary(instance) && HalC2.Plugins.provider(instance) do
      # The bundled ACP plugin serves Pi too, but Pi runs in its own RPC mode.
      {:ok, _driver, HalC2.Plugins.Bundled.Acp} -> builtin_runtime(instance)
      {:ok, _driver, module} -> module
      _ -> builtin_runtime(instance)
    end
  end

  defp builtin_runtime("claudeAgent"), do: HalC2.Claude.ThreadRuntime

  defp builtin_runtime(instance) when is_binary(instance) and instance != "codex" do
    cond do
      HalC2.Acp.driver(instance) == "pi" -> HalC2.Pi.ThreadRuntime
      HalC2.Acp.agent?(instance) -> HalC2.Acp.ThreadRuntime
      instance in HalC2.Settings.instances_of("claudeAgent") -> HalC2.Claude.ThreadRuntime
      true -> HalC2.Codex.ThreadRuntime
    end
  end

  defp builtin_runtime(_codex), do: HalC2.Codex.ThreadRuntime

  # A thread has at most one running turn; interrupt whichever runtime holds it. A
  # started turn nothing drives any more (its runtime stopped without ending it) ends
  # here, and a provider plugin that cannot stop a turn says so.
  defp interrupt_any(thread_id, run_id) do
    Enum.find_value(runtimes(:interrupt, 2), fn runtime ->
      if interrupted?(runtime, thread_id, run_id), do: :ok
    end) || interrupt_undriven(thread_id, run_id)
  end

  # A runtime that dies as it is asked leaves its turn to `interrupt_undriven/2`.
  defp interrupted?(runtime, thread_id, run_id) do
    runtime.interrupt(thread_id, run_id) == :ok
  catch
    :exit, _ -> false
  end

  defp interrupt_undriven(thread_id, run_id) do
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))
    runs = StreamState.list(state, "run")

    run =
      Enum.find(runs, &(&1["id"] == run_id)) ||
        Enum.find(runs, &(&1["status"] in @active_statuses))

    if run != nil and run["status"] in ~w(running waiting) and
         not HalC2.Orchestration.TurnWatch.driven?(run["id"]),
       do: HalC2.Orchestration.TurnWriter.abandon(thread_id, run["id"], "interrupted", nil),
       else: interrupt_refusal(run)
  end

  defp interrupt_refusal(run) do
    instance = run && run["providerInstanceId"]

    with instance when is_binary(instance) <- instance,
         {:ok, driver, module} <- HalC2.Plugins.provider(instance),
         false <- function_exported?(module, :interrupt, 2) do
      {:error, "The provider \"#{driver}\" cannot stop a running turn."}
    else
      _ -> {:error, "no running turn"}
    end
  end

  defp dispatch_message(thread_id, command) do
    decide = fn state ->
      case decide_message(state, thread_id, command) do
        {[], {:ok, :sent}} = sent ->
          sent

        {changes, {:ok, _} = result} ->
          {Enum.reject([woken(state, thread_id) | changes], &is_nil/1), result}

        refused ->
          refused
      end
    end

    case HalC2.Streams.transact(thread_id, :thread, decide) do
      {:ok, status} when status in [:queued, :sent] ->
        {:ok, %{"sequence" => sequence(thread_id)}}

      {:ok, {:steer, run}} ->
        steer(thread_id, run, command)

      {:ok, {:restart, active_run_id}} ->
        # The queued message goes first; the interrupted run's end starts it.
        _ = interrupt_any(thread_id, active_run_id)
        {:ok, %{"sequence" => sequence(thread_id)}}

      {:ok, turn} ->
        begin_turn(thread_id, turn)
        {:ok, %{"sequence" => sequence(thread_id)}}

      {:error, _} = error ->
        error
    end
  end

  # A message brings a settled or snoozed thread back to the active list, as in the Node
  # server: it is neither settled nor held active by hand any more.
  defp woken(state, thread_id) do
    thread = StreamState.get(state, "thread")[thread_id]

    unsettled =
      case thread["settledOverride"] do
        nil ->
          %{}

        "settled" ->
          %{"settledOverride" => nil, "settledAt" => nil, "unsettledAt" => Entities.now()}

        _ ->
          %{"settledOverride" => nil, "settledAt" => nil}
      end

    unsnoozed =
      if thread["snoozedUntil"] != nil,
        do: %{"snoozedUntil" => nil, "snoozedAt" => nil},
        else: %{}

    upsert(state, "thread", thread_id, &(&1 |> Map.merge(unsettled) |> Map.merge(unsnoozed)))
  end

  defp sequence(thread_id), do: HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id)).seq

  defp interrupt_request(state, command) do
    runs = StreamState.get(state, "run")

    run =
      runs[command["runId"]] ||
        runs |> Map.values() |> Enum.find(&(&1["status"] in @active_statuses))

    item_id = run && "turn-item:run:#{run["id"]}:signal:interrupt-request"

    if run && StreamState.get(state, "turn-item")[item_id] == nil do
      at = Entities.now()

      ids = %{
        thread: run["threadId"],
        run: run["id"],
        root_node: run["rootNodeId"],
        provider_thread: run["providerThreadId"]
      }

      [
        create(
          "turn-item",
          item_id,
          Entities.turn_item(
            ids,
            item_id,
            "run_interrupt_request",
            next_ordinal(state),
            "completed",
            at,
            %{
              "title" => "Interrupt requested",
              "message" => command["reason"] || "Interrupt requested"
            }
          )
        )
      ]
    else
      []
    end
  end

  defp restart_promoted(thread_id, command) do
    queued_id = command["queuedRunId"]

    with {:ok, result} <-
           queue_change(thread_id, fn state ->
             order = [
               queued_id | queued_runs(state) |> Enum.map(& &1["id"]) |> List.delete(queued_id)
             ]

             for {id, position} <- Enum.with_index(order, 1),
                 do: upsert(state, "run", id, &Map.put(&1, "queuePosition", position))
           end) do
      _ = interrupt_any(thread_id, command["targetRunId"])
      {:ok, result}
    end
  end

  defp edit_claims(thread_id, %{"attachments" => attachments} = command)
       when is_list(attachments) do
    with {:ok, claimed} <- HalC2.Attachments.claim(thread_id, attachments),
         do: {:ok, claimed(command, claimed)}
  end

  defp edit_claims(_thread_id, command), do: {:ok, command}

  # What a message and its timeline item both carry: its composer context records
  # (`HalC2.ComposerContext`), the scheduled task that sent it, and the thread whose
  # agent sent it (MCP), so a client can name and open that thread.
  defp with_context(entity, source) do
    entity = Map.merge(entity, Map.take(source, ["scheduledTaskId", "senderThreadId"]))

    case source do
      %{"context" => %{} = context} -> Map.put(entity, "context", context)
      _ -> entity
    end
  end

  # A message's `with_context/2` fields and, for a delegated task's result, which task
  # it delivers (`HalC2.Orchestration.Delegation`).
  defp with_message_fields(message, command) do
    message
    |> with_context(command)
    |> Map.merge(Map.take(command, ["delegatedCompletion", "providerWake"]))
  end

  # Uploads claimed into the thread, with the context records that name them.
  defp claimed(command, attachments) do
    command
    |> Map.put("attachments", attachments)
    |> Map.put(
      "context",
      HalC2.ComposerContext.remap_attachments(
        command["context"],
        command["attachments"] || [],
        attachments
      )
    )
  end

  defp steerable?(run) do
    driver = driver_for(run["providerInstanceId"] || "codex")

    case HalC2.Plugins.declared(driver) do
      nil -> Entities.steers?(driver)
      provider -> :active_steering in (provider[:capabilities] || [])
    end
  end

  # The provider takes the message first; only then does it join the run. If the turn
  # ended meanwhile, the message is sent like any other (started, or queued behind a
  # newer run), as the Node server delivers a steer that lost the race with the turn's
  # end. A provider that refuses while its turn still runs is an error for the sender:
  # the message was not delivered, so it is neither shown in the turn nor queued.
  defp steer(thread_id, run, command) do
    instance = run["providerInstanceId"] || "codex"

    case runtime(instance).steer(thread_id, run["id"], steer_input(command)) do
      :ok ->
        HalC2.Streams.transact(thread_id, :thread, fn state ->
          at = Entities.now()
          message_id = command["messageId"] || Entities.new_id("message")
          ids = %{thread: thread_id, run: run["id"], root_node: run["rootNodeId"]}

          message =
            Entities.message(ids, message_id, "user", command["text"] || "", false, at)
            |> Map.merge(%{
              "attachments" => command["attachments"] || [],
              "createdBy" => command["createdBy"] || "user",
              "creationSource" => command["creationSource"] || "web"
            })
            |> with_message_fields(command)

          {[create("message", message_id, message)] ++
             steer_changes(state, run, message_id, message, "steer", at), :ok}
        end)

        {:ok, %{"sequence" => sequence(thread_id)}}

      {:error, reason} ->
        if run_active?(thread_id, run["id"]) do
          {:error,
           "#{HalC2.ThreadMove.provider_name(instance)} did not take the message into its running turn (#{reason}). Send it again, or stop the turn first."}
        else
          command
          |> Map.put("dispatchMode", %{"type" => "queue_after_active"})
          |> Map.delete("deliveryIntent")
          |> dispatch()
        end
    end
  end

  defp run_active?(thread_id, run_id) do
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))
    (StreamState.get(state, "run")[run_id] || %{})["status"] in @active_statuses
  end

  # What a runtime's `steer/3` is handed: the text the provider reads (with its composer
  # context) and the message's files, as a turn carries them.
  defp steer_input(message) do
    %{
      text: HalC2.ComposerContext.for_provider(message["text"] || "", message["context"]),
      attachments: provider_attachments(message["attachments"])
    }
  end

  # The files providers read, from this MC's attachment store.
  defp provider_attachments(attachments) do
    for attachment <- attachments || [],
        path = HalC2.Attachments.path(attachment),
        do: %{
          type: attachment["type"],
          name: attachment["name"],
          mime_type: attachment["mimeType"],
          path: path
        }
  end

  # The steered message's place in the transcript, inside the run it joined.
  defp steer_changes(state, run, message_id, message, intent, at) do
    item_id = "turn-item:user:#{message_id}"

    ids = %{
      thread: run["threadId"],
      run: run["id"],
      root_node: run["rootNodeId"],
      provider_thread: run["providerThreadId"]
    }

    [
      create(
        "turn-item",
        item_id,
        Entities.turn_item(ids, item_id, "user_message", next_ordinal(state), "completed", at, %{
          "createdBy" => message["createdBy"] || "user",
          "creationSource" => message["creationSource"] || "web",
          "messageId" => message_id,
          "inputIntent" => intent,
          "text" => message["text"] || "",
          "attachments" => message["attachments"] || []
        })
        |> with_context(message)
      )
    ]
  end

  # The thread fields a command sets, as the Node server's projector sets them.
  defp thread_fields("thread.archive", _, _, at), do: %{"archivedAt" => at}
  defp thread_fields("thread.unarchive", _, _, _), do: %{"archivedAt" => nil}
  defp thread_fields("thread.delete", _, _, at), do: %{"deletedAt" => at}

  # Settling is "I'm done with this": it parks the thread, clears its pinned and active
  # places and ends its snooze, as the Node server's settle does (thread.unsnoozed).
  # Settling a settled thread again keeps the time it was settled.
  defp thread_fields("thread.settle", command, thread, at) do
    kept =
      thread["settledOverride"] == "settled" and thread["pinnedAt"] == nil and
        thread["settledAt"]

    %{
      "settledOverride" => "settled",
      "settledAt" => kept || command["settledAt"] || at,
      "unsettledAt" => nil,
      "pinnedAt" => nil,
      "pinOrderKey" => nil,
      "activeOrderKey" => nil,
      "snoozedUntil" => nil,
      "snoozedAt" => nil
    }
  end

  defp thread_fields("thread.unsettle", _, thread, at) do
    unsettled_at = if thread["settledOverride"] == "active", do: thread["unsettledAt"], else: at
    %{"settledOverride" => "active", "settledAt" => nil, "unsettledAt" => unsettled_at}
  end

  # Snoozing again until the same time keeps when it was snoozed. A snooze the user
  # chose replaces the one a usage limit asked for.
  defp thread_fields("thread.snooze", command, thread, at) do
    until = command["snoozedUntil"]

    same? =
      thread["snoozedUntil"] != nil and JS.epoch_ms(thread["snoozedUntil"]) == JS.epoch_ms(until)

    fields = %{"snoozedUntil" => until, "snoozedAt" => (same? && thread["snoozedAt"]) || at}

    case thread["limitRecovery"] do
      %{} = recovery -> Map.put(fields, "limitRecovery", Map.put(recovery, "snooze", false))
      _ -> fields
    end
  end

  defp thread_fields("thread.unsnooze", _, _, _), do: %{"snoozedUntil" => nil, "snoozedAt" => nil}

  # Pinning is a promotion: a settled thread is active again and a snooze is spent. A
  # re-pin keeps its place, so a raced duplicate cannot move a thread the user placed.
  defp thread_fields("thread.pin", command, thread, at) do
    unsettled =
      if thread["settledOverride"] == "settled",
        do: %{"settledOverride" => "active", "settledAt" => nil},
        else: %{}

    placed =
      if thread["pinnedAt"] == nil and Map.has_key?(command, "orderKey"),
        do: %{"pinOrderKey" => command["orderKey"]},
        else: %{}

    %{"pinnedAt" => thread["pinnedAt"] || at, "snoozedUntil" => nil, "snoozedAt" => nil}
    |> Map.merge(unsettled)
    |> Map.merge(placed)
  end

  defp thread_fields("thread.unpin", _, _, _), do: %{"pinnedAt" => nil, "pinOrderKey" => nil}

  defp thread_fields("thread.pin.reorder", command, _, _),
    do: %{"pinOrderKey" => command["orderKey"]}

  defp thread_fields("thread.active.reorder", command, _, _),
    do: %{"activeOrderKey" => command["orderKey"]}

  # Visits only move forward, so a late or replayed visit changes nothing.
  defp thread_fields("thread.visit", command, thread, _) do
    visited = command["visitedAt"]

    if is_binary(thread["lastVisitedAt"]) and thread["lastVisitedAt"] >= visited,
      do: %{},
      else: %{"lastVisitedAt" => visited}
  end

  defp thread_fields("thread.mark-unread", _, _, _), do: %{"lastVisitedAt" => nil}

  defp thread_fields("thread.runtime-mode.set", command, _, at),
    do: %{"runtimeMode" => command["runtimeMode"], "updatedAt" => at}

  defp thread_fields("thread.interaction-mode.set", command, _, at),
    do: %{"interactionMode" => command["interactionMode"], "updatedAt" => at}

  # A thread's pull requests are keyed by host, repository and number. Linking again
  # changes nothing, except that a user or agent brings back a stack layer they unlinked.
  # A first manual link keeps the branch's pull request beside it.
  defp thread_fields("thread.pull-request.link", command, thread, at) do
    links = PullRequests.of(thread)
    key = PullRequests.key(command)
    existing = Enum.find(links, &(PullRequests.key(&1) == key))
    source = command["source"]

    if existing &&
         (existing["source"] != "stack-dismissed" or source in ["stack", "stack-dismissed"]) do
      %{}
    else
      link =
        if existing,
          do: %{existing | "source" => source, "url" => command["url"]},
          else: new_link(PullRequests.normalize(command), command["url"], source, at)

      branch = JS.json(JS.get(thread, "branchPullRequest"))
      branch_key = branch && PullRequests.legacy_key(branch)

      kept_branch =
        if source == "manual" and branch != nil and PullRequests.visible(links) == [] and
             PullRequests.key(branch_key) != key and
             not Enum.any?(links, &(PullRequests.key(&1) == PullRequests.key(branch_key))),
           do: [new_link(branch_key, branch["url"], "manual", at)],
           else: []

      pull_requests =
        kept_branch ++ Enum.reject(links, &(PullRequests.key(&1) == key)) ++ [link]

      Map.put(pull_request_fields(thread, pull_requests), "updatedAt", at)
    end
  end

  # A layer of a native stack stays as a tombstone, so the sync does not link it again.
  defp thread_fields("thread.pull-request.unlink", command, thread, at) do
    links = PullRequests.of(thread)
    key = PullRequests.normalize(command)
    existing = Enum.find(links, &(PullRequests.normalize(&1) == key))

    stacked? =
      existing != nil and
        (existing["source"] == "stack" or existing["stack"] != nil or
           Enum.any?(links, fn link ->
             Map.delete(PullRequests.normalize(link), "number") == Map.delete(key, "number") and
               Enum.any?((link["stack"] || %{})["layers"] || [], &(&1["number"] == key["number"]))
           end))

    cond do
      existing == nil ->
        %{}

      stacked? ->
        links
        |> Enum.map(&if(&1 == existing, do: %{&1 | "source" => "stack-dismissed"}, else: &1))
        |> then(&Map.put(pull_request_fields(thread, &1), "updatedAt", at))

      true ->
        links
        |> List.delete(existing)
        |> then(&Map.put(pull_request_fields(thread, &1), "updatedAt", at))
    end
  end

  # A legacy client's single link replaces the previous one among the thread's links.
  defp thread_fields(
         "thread.metadata.update",
         %{"linkedPullRequest" => linked} = command,
         thread,
         at
       ) do
    with %{} = fields <-
           thread_fields(
             "thread.metadata.update",
             Map.delete(command, "linkedPullRequest"),
             thread,
             at
           ),
         do: Map.merge(fields, replace_linked(thread, linked, at))
  end

  # The next run starts the new provider's thread with the conversation handed over.
  defp thread_fields("provider.switch", command, thread, at),
    do: thread_fields("thread.model-selection.set", command, thread, at)

  defp thread_fields("thread.model-selection.set", %{"modelSelection" => selection}, _, at),
    do: %{
      "modelSelection" => selection,
      "providerInstanceId" => selection["instanceId"],
      "updatedAt" => at
    }

  defp thread_fields("thread.metadata.update", command, thread, at) do
    cond do
      Map.has_key?(command, "expectedWorktreePath") and
          command["expectedWorktreePath"] != thread["worktreePath"] ->
        {:error, "the thread's worktree changed"}

      true ->
        command
        |> Map.take(~w(title branch worktreePath linkedPullRequest))
        |> Map.put("updatedAt", at)
        |> Map.merge(title_regeneration(command, at))
    end
  end

  # A regeneration finished elsewhere lands its title only while its request is still
  # the thread's in-flight one; a stale completion changes nothing.
  defp thread_fields("thread.title.regeneration.complete", command, thread, at) do
    if is_map(thread["titleRegeneration"]) and
         thread["titleRegeneration"]["requestId"] == command["requestId"],
       do:
         command
         |> Map.take(~w(title))
         |> Map.merge(%{"titleRegeneration" => nil, "updatedAt" => at}),
       else: %{}
  end

  # Choices about resuming a thread stopped on a usage limit (`HalC2.Orchestration.LimitRecovery`)
  # apply to the latest failed run and its reset only; snoozing to the reset sets the
  # thread's wake time, and turning it off clears a wake time it set.
  defp limit_recovery(
         state,
         %{"type" => "thread.metadata.update", "limitRecovery" => update} = command,
         thread,
         at
       ) do
    previous = thread["limitRecovery"]
    now = JS.epoch_ms(at)

    with :ok <- valid_limit_recovery(state, update, thread, now) do
      same? =
        previous != nil and update != nil and previous["runId"] == update["runId"] and
          previous["resetAt"] == update["resetAt"]

      recovery =
        update &&
          Map.merge(update, %{
            "autoResume" => choice(update, previous, same?, "autoResume"),
            "snooze" => choice(update, previous, same?, "snooze"),
            "requestId" => command["commandId"]
          })

      cond do
        recovery && recovery["snooze"] == true && JS.epoch_ms(recovery["resetAt"]) > now ->
          %{"snoozedUntil" => recovery["resetAt"], "snoozedAt" => at}

        previous["snooze"] == true and thread["snoozedUntil"] != nil and
            JS.epoch_ms(thread["snoozedUntil"]) == JS.epoch_ms(previous["resetAt"]) ->
          %{"snoozedUntil" => nil, "snoozedAt" => nil}

        true ->
          %{}
      end
      |> Map.put("limitRecovery", recovery)
    end
  end

  defp limit_recovery(_state, _command, _thread, _at), do: %{}

  # A choice the update leaves out keeps the one made for the same run and reset.
  defp choice(update, previous, same?, key) do
    case update[key] do
      nil -> same? and previous[key] == true
      value -> value
    end
  end

  defp valid_limit_recovery(_state, nil, _thread, _now), do: :ok

  defp valid_limit_recovery(state, update, thread, now) do
    runs = StreamState.list(state, "run")
    run = Enum.max_by(runs, & &1["ordinal"], fn -> nil end)

    failure =
      HalC2.Projection.ThreadError.latest_root_provider_failure(
        run,
        StreamState.list(state, "turn-item")
      )

    reset = JS.epoch_ms(update["resetAt"])

    cond do
      update["snooze"] == true and reset != nil and reset <= now ->
        {:error, "The reset time has passed. Retry the thread manually."}

      reset == nil or thread["archivedAt"] != nil or thread["settledOverride"] == "settled" or
        run == nil or run["id"] != update["runId"] or failure["class"] != "usage_limit" or
        failure["resetAt"] != update["resetAt"] or
        reset <= JS.epoch_ms(run["completedAt"] || run["requestedAt"]) or
        Enum.any?(StreamState.list(state, "runtime-request"), &(&1["status"] == "pending")) or
          Enum.any?(runs, &(&1["status"] == "queued")) ->
        {:error, "The provider limit changed before recovery could be configured."}

      true ->
        :ok
    end
  end

  # Commands the thread's state refuses, as the Node server guards them; nil to go ahead.
  defp refusal("thread.archive", command, %{"archivedAt" => archived}, _state)
       when archived != nil,
       do: {:error, "Thread #{command["threadId"]} is already archived."}

  defp refusal("thread.unarchive", command, thread, _state) do
    if thread["archivedAt"] == nil, do: {:error, "Thread #{command["threadId"]} is not archived."}
  end

  # An archived thread is out of the lists these arrange; unarchiving brings it back.
  defp refusal(type, command, %{"archivedAt" => archived}, _state)
       when type in @organizing and archived != nil,
       do: {:error, "Thread #{command["threadId"]} is archived."}

  # Only a pinned thread has a place among the pinned, so a reorder that races an unpin
  # cannot pin the thread again; only an active thread has a place in the active list.
  defp refusal("thread.pin.reorder", command, thread, _state) do
    if thread["pinnedAt"] == nil,
      do: {:error, "Thread #{command["threadId"]} is not pinned and cannot be reordered."},
      else: order_key_refusal(command)
  end

  defp refusal("thread.active.reorder", command, thread, _state) do
    if thread["pinnedAt"] != nil or thread["settledOverride"] == "settled",
      do: {:error, "Thread #{command["threadId"]} is not active and cannot be reordered."},
      else: order_key_refusal(command)
  end

  # A pin's order key is optional; one it does carry is checked like a reorder's.
  defp refusal("thread.pin", %{"orderKey" => key} = command, _thread, _state) when key != nil,
    do: order_key_refusal(command)

  # A thread settles once its work is done: nothing running or queued, and nothing
  # waiting on the user. A queued delegated-task result only wakes the agent, so it does
  # not count; settling cancels it (`archived_queue/3`).
  defp refusal("thread.settle", command, _thread, state) do
    busy? =
      Enum.any?(StreamState.list(state, "run"), fn run ->
        run["status"] in @active_statuses or
          (run["status"] == "queued" and not automatic?(state, run))
      end)

    if busy? or blocking_request?(state),
      do:
        {:error,
         "Thread #{command["threadId"]} has active or blocked work and cannot be settled."}
  end

  # A snoozed thread rests until its wake time, so it must be able to: nothing may be
  # waiting on the user and no queued run may be about to start.
  defp refusal("thread.snooze", command, _thread, state) do
    id = command["threadId"]
    until = command["snoozedUntil"]

    cond do
      not future?(until) ->
        {:error, "Thread #{id} snooze wake time #{until} is not in the future."}

      blocking_request?(state) ->
        {:error,
         "Thread #{id} has a pending approval or user-input request and cannot be snoozed."}

      Enum.any?(StreamState.list(state, "run"), &(&1["status"] == "queued")) ->
        {:error, "Thread #{id} has a queued run and cannot be snoozed."}

      true ->
        nil
    end
  end

  defp refusal(_type, _command, _thread, _state), do: nil

  defp order_key_refusal(command) do
    unless valid_order_key?(command["orderKey"]),
      do:
        {:error,
         "Thread #{command["threadId"]} order key is not 1 to #{@max_order_key} letters a-z ending in b-z."}
  end

  # An order key a client writes (`pinOrderKey`, `activeOrderKey`): base-26 letters that
  # sort as text, as `planPinnedReorder` in client-runtime's threadSort.ts and the
  # desktop's `sidebar::planReorder` make them; a last "a" leaves no key just before it.
  # The bound keeps every row small; a drag that would pass it re-keys its section.
  defp valid_order_key?(key) when is_binary(key) and byte_size(key) in 1..@max_order_key//1,
    do: key =~ ~r/\A[a-z]*[b-z]\z/

  defp valid_order_key?(_key), do: false

  defp future?(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _} -> DateTime.compare(at, DateTime.utc_now()) == :gt
      _ -> false
    end
  end

  defp future?(_), do: false

  # An archived thread's queued messages will not run.
  defp archived_queue("thread.archive", state, at) do
    for run <- queued_runs(state) do
      upsert(
        state,
        "run",
        run["id"],
        &Map.merge(&1, %{"status" => "cancelled", "queuePosition" => nil, "completedAt" => at})
      )
    end
  end

  # A deleted thread stops for good: its unfinished runs, their attempts and pending
  # requests are cancelled (`deleted_thread/3` stops its provider sessions).
  defp archived_queue("thread.delete", state, at) do
    active =
      for run <- StreamState.list(state, "run"),
          run["status"] in ["queued" | @active_statuses],
          do: run["id"]

    done = &Map.merge(&1, %{"status" => "cancelled", "completedAt" => at})

    runs =
      for id <- active,
          do: upsert(state, "run", id, &Map.merge(done.(&1), %{"queuePosition" => nil}))

    attempts =
      for attempt <- StreamState.list(state, "run-attempt"),
          attempt["runId"] in active and attempt["status"] in ~w(pending running),
          do: upsert(state, "run-attempt", attempt["id"], done)

    requests =
      for request <- StreamState.list(state, "runtime-request"),
          request["status"] == "pending",
          do:
            upsert(
              state,
              "runtime-request",
              request["id"],
              &Map.merge(&1, %{"status" => "cancelled", "resolvedAt" => at})
            )

    runs ++ attempts ++ requests
  end

  defp archived_queue("thread.settle", state, at) do
    for run <- queued_runs(state), automatic?(state, run) do
      upsert(
        state,
        "run",
        run["id"],
        &Map.merge(&1, %{"status" => "cancelled", "queuePosition" => nil, "completedAt" => at})
      )
    end
  end

  defp archived_queue(_type, _state, _at), do: []

  defp automatic?(state, run),
    do: StreamState.get(state, "message")[run["userMessageId"]]["delegatedCompletion"] != nil

  # A deleted thread's provider sessions stop in the commit that deletes it; the
  # dispatcher then stops their processes.
  defp deleted_thread("thread.delete", state, at) do
    for session <- StreamState.list(state, "provider-session"),
        session["status"] not in ["stopped", "error"],
        do:
          upsert(
            state,
            "provider-session",
            session["id"],
            &Map.merge(&1, %{"status" => "stopped", "updatedAt" => at})
          )
  end

  defp deleted_thread(_type, _state, _at), do: []

  # `regenerateTitle: true` marks a title in flight; a new title, or `false` when
  # generation failed, clears the mark.
  defp title_regeneration(%{"regenerateTitle" => true} = command, at),
    do: %{"titleRegeneration" => %{"requestId" => command["commandId"], "startedAt" => at}}

  defp title_regeneration(command, _at) do
    if command["regenerateTitle"] == false or Map.has_key?(command, "title"),
      do: %{"titleRegeneration" => nil},
      else: %{}
  end

  defp new_link(key, url, source, at),
    do:
      Map.merge(Map.take(key, ~w(host repository number)), %{
        "url" => url,
        "source" => source,
        "linkedAt" => at,
        "snapshot" => nil,
        "stack" => nil
      })

  # The legacy `linkedPullRequest` lasts only while a visible link still names it.
  defp pull_request_fields(thread, pull_requests) do
    linked = JS.json(JS.get(thread, "linkedPullRequest"))

    if linked == nil or
         Enum.any?(
           PullRequests.visible(pull_requests),
           &(PullRequests.key(&1) == PullRequests.key(PullRequests.legacy_key(linked)))
         ),
       do: %{"pullRequests" => pull_requests},
       else: %{"pullRequests" => pull_requests, "linkedPullRequest" => nil}
  end

  defp replace_linked(thread, linked, at) do
    replaced =
      for l <- [JS.json(JS.get(thread, "linkedPullRequest")), linked],
          l,
          do: PullRequests.key(PullRequests.legacy_key(l))

    kept = Enum.reject(PullRequests.of(thread), &(PullRequests.key(&1) in replaced))

    added =
      if linked,
        do: [new_link(PullRequests.legacy_key(linked), linked["url"], "manual", at)],
        else: []

    %{"linkedPullRequest" => linked, "pullRequests" => kept ++ added}
  end

  # Visits and mark-unread change read state only, and arranging the active list is not
  # activity either, as in the TS server: the thread's last activity time stays put.
  defp quiet_read_state({kind, id, patch}, type)
       when type in ["thread.visit", "thread.mark-unread", "thread.active.reorder"],
       do: {kind, id, Map.put(patch, "q", true)}

  defp quiet_read_state(change, _type), do: change

  # Host state and branch discovery are not activity: they leave `updatedAt` where it is.
  defp quiet_update(thread_id, decide) do
    result =
      HalC2.Streams.transact(thread_id, :thread, fn state ->
        case StreamState.get(state, "thread")[thread_id] do
          nil ->
            {[], {:error, "unknown thread #{thread_id}"}}

          thread ->
            case decide.(thread) do
              {:error, _} = error ->
                {[], error}

              fields ->
                case upsert(state, "thread", thread_id, &Map.merge(&1, fields)) do
                  nil -> {[], :ok}
                  {kind, id, patch} -> {[{kind, id, Map.put(patch, "q", true)}], :ok}
                end
            end
        end
      end)

    with :ok <- result, do: {:ok, %{"sequence" => sequence(thread_id)}}
  end

  # Changes to queued runs; positions are renumbered 1.. after each one. A thread
  # that does not exist, or was deleted, has no queue to change; one that is moving or
  # moved keeps its queue as the move took it, as thread updates do.
  defp queue_change(thread_id, fun) do
    changed =
      HalC2.Streams.transact(thread_id, :thread, fn state ->
        case StreamState.get(state, "thread")[thread_id] do
          nil ->
            {[], {:error, "unknown thread #{thread_id}"}}

          %{"deletedAt" => at} when at != nil ->
            {[], {:error, "Thread #{thread_id} is deleted."}}

          %{"moving" => %{"label" => to}} = thread ->
            {[],
             {:error, "#{thread["title"]} is moving to #{to}. Try again once it has arrived."}}

          %{"movedTo" => %{} = moved} = thread ->
            {[], {:error, "#{thread["title"]} has moved to #{moved["label"]}."}}

          _ ->
            {Enum.reject(fun.(state), &is_nil/1), :ok}
        end
      end)

    with :ok <- changed do
      HalC2.Streams.transact(thread_id, :thread, fn state -> {renumber(state), :ok} end)
      {:ok, %{"sequence" => sequence(thread_id)}}
    end
  end

  defp queued_runs(state) do
    state
    |> StreamState.list("run")
    |> Enum.filter(&(&1["status"] == "queued"))
    |> Enum.sort_by(&{&1["queuePosition"] || 0, &1["ordinal"]})
  end

  defp renumber(state) do
    for {run, position} <- Enum.with_index(queued_runs(state), 1),
        change = upsert(state, "run", run["id"], &Map.put(&1, "queuePosition", position)),
        do: change
  end

  @doc """
  Starts the thread's first queued message if nothing is running and the queue is
  not held. Runtimes call it (off their own process) when a run ends.
  """
  def start_next(thread_id) do
    case HalC2.Streams.transact(thread_id, :thread, &decide_next(&1, thread_id)) do
      {:ok, turn} ->
        begin_turn(thread_id, turn)

      _idle ->
        :ok
    end
  end

  defp decide_next(state, thread_id) do
    thread = StreamState.get(state, "thread")[thread_id]
    runs = StreamState.list(state, "run")

    # A deleted thread runs nothing more; an archived one nothing from its queue, as on
    # the Node server, until it is unarchived and the queue resumed or another turn ends.
    with true <- thread != nil and thread["deletedAt"] == nil and thread["archivedAt"] == nil,
         false <- Enum.any?(runs, &(&1["status"] in @active_statuses)),
         %{} = next <- Enum.find(queued_runs(state), &(&1["queueHeld"] != true)),
         %{} = message <- StreamState.get(state, "message")[next["userMessageId"]] do
      {changes, result} = new_run(state, thread, runs, message, next)
      # The started run leaves the queue; the rest move up.
      rest = queued_runs(state) |> Enum.reject(&(&1["id"] == next["id"]))

      positions =
        for {run, position} <- Enum.with_index(rest, 1),
            change = upsert(state, "run", run["id"], &Map.put(&1, "queuePosition", position)),
            do: change

      {changes ++ positions, result}
    else
      _ -> {[], :idle}
    end
  end

  # Records the user's message and a new run, and returns what the provider needs to
  # start the turn. Rejects a second run while one is active.
  defp decide_message(state, thread_id, command) do
    thread = StreamState.get(state, "thread")[thread_id]
    runs = StreamState.list(state, "run")

    cond do
      thread == nil ->
        {[], {:error, "unknown thread #{thread_id}"}}

      # A client retrying a send after a reconnect repeats its message id, possibly
      # while the first send is still in flight. A message the thread already has
      # (started, queued, prepared or steered) was sent: nothing more to decide.
      is_binary(command["messageId"]) and
          StreamState.get(state, "message")[command["messageId"]] != nil ->
        {[], {:ok, :sent}}

      thread["deletedAt"] != nil ->
        {[], {:error, "Thread #{thread_id} is deleted."}}

      # A thread that is moving is read-only until it arrives; one that moved lives on.
      moving = thread["moving"] ->
        {[],
         {:error,
          "#{thread["title"]} is moving to #{moving["label"]}. Send the message once it has arrived."}}

      moved = thread["movedTo"] ->
        {[], {:error, "#{thread["title"]} has moved to #{moved["label"]}."}}

      error = instance_refusal(thread, command) ->
        {[], {:error, error}}

      reason = model_locked(thread, command) ->
        {[], {:error, reason}}

      get_in(command, ["dispatchMode", "type"]) == "defer_start" ->
        prepare_run(state, thread, runs, command)

      active = Enum.find(runs, &(&1["status"] in @active_statuses)) ->
        intent = command["deliveryIntent"]
        mode = get_in(command, ["dispatchMode", "type"])
        steer = intent == "steer" or mode == "steer_active"

        # As the Node server resolves it: steer a running turn that can take it,
        # else queue; a restart (or a steer that cannot be) interrupts and goes first.
        auto_steer =
          intent in [nil, "auto"] and mode != "queue_after_active" and
            active["status"] in ["running", "waiting"]

        cond do
          intent == "restart" or mode == "restart_active" ->
            queue_run(state, thread, runs, command, active["id"])

          (steer or auto_steer) and steerable?(active) ->
            {[], {:ok, {:steer, active}}}

          steer ->
            queue_run(state, thread, runs, command, active["id"])

          true ->
            queue_run(state, thread, runs, command, nil)
        end

      true ->
        new_run(state, thread, runs, command)
    end
  end

  # Why a message cannot run on its thread's provider instance, or nil. No other
  # provider stands in for one this MC no longer has: an instance nothing binds
  # (not built in, not an ACP agent, not in settings) is unknown, one whose plugin
  # went away is unavailable.
  defp instance_refusal(thread, command) do
    selection = command["modelSelection"] || thread["modelSelection"]
    instance = selection["instanceId"] || thread["providerInstanceId"] || "codex"

    bound? =
      instance in ["codex", "claudeAgent"] or HalC2.Acp.agent?(instance) or
        Map.has_key?(HalC2.Settings.settings()["providerInstances"] || %{}, instance)

    missing =
      case HalC2.Plugins.provider(instance) do
        {:ok, _driver, _module} ->
          nil

        {:missing, _driver} ->
          instance

        :none ->
          :none

        nil ->
          driver = get_in(HalC2.Settings.settings(), ["providerInstances", instance, "driver"])

          unless instance in ["codex", "claudeAgent"] or driver in ["codex", "claudeAgent"] or
                   HalC2.Acp.agent?(instance),
                 do: instance
      end

    cond do
      missing == nil ->
        nil

      missing == :none ->
        "No provider is set up on this MC. Add a provider before starting a thread."

      not bound? ->
        "No provider instance bound to id '#{instance}'"

      true ->
        "The provider \"#{instance}\" is not available on this MC; its plugin may have been removed. Pick another provider for this thread."
    end
  end

  # A provider plugin that cannot switch models in a session keeps the thread's model
  # once its session exists; a new thread takes the other model (as the Node server
  # rejects the transition).
  defp model_locked(thread, command) do
    current = thread["modelSelection"] || %{}
    target = command["modelSelection"] || %{}
    instance = current["instanceId"]

    with true <- thread["activeProviderThreadId"] != nil,
         model when is_binary(model) <- target["model"],
         true <- model != current["model"] and target["instanceId"] in [nil, instance],
         %{} = provider <- HalC2.Plugins.declared(driver_for(instance || "codex")),
         false <- :model_switching in (provider[:capabilities] || []) do
      "#{provider[:name] || instance} cannot change the model of a running session. Start a new thread to use #{model}."
    else
      _ -> nil
    end
  end

  # A message whose run waits for its workspace (`release_prepared/2`). As the Node
  # server shows it: the user's message, then a "Preparing workspace" item that the
  # preparation's progress, release, or failure updates.
  defp prepare_run(state, thread, runs, command) do
    {changes, {:ok, :queued}} = queue_run(state, thread, runs, command, nil)

    [{"run", run_id, %{"s" => run}} | rest] = changes
    run = Map.merge(run, %{"status" => "preparing", "queuePosition" => nil})
    at = run["requestedAt"]
    message_id = run["userMessageId"]
    ordinal = next_ordinal(state)

    ids = %{
      thread: thread["id"],
      run: run_id,
      root_node: nil,
      provider_thread: run["providerThreadId"]
    }

    user_item =
      Entities.turn_item(
        ids,
        "turn-item:user:#{message_id}",
        "user_message",
        ordinal,
        "completed",
        at,
        %{
          "createdBy" => command["createdBy"] || "user",
          "creationSource" => command["creationSource"] || "web",
          "messageId" => message_id,
          "inputIntent" => "turn_start",
          "text" => command["text"] || "",
          "attachments" => command["attachments"] || []
        }
      )
      |> with_context(command)

    preparation =
      Entities.turn_item(
        ids,
        preparation_item_id(run_id),
        "command_execution",
        ordinal + 1,
        "running",
        at,
        %{
          "title" => @preparing_workspace,
          "input" => @preparing_workspace
        }
      )

    {[{"run", run_id, %{"s" => run}} | rest] ++
       [
         create("turn-item", user_item["id"], user_item),
         create("turn-item", preparation["id"], preparation)
       ], {:ok, {:prepared, run_id}}}
  end

  defp preparation_item_id(run_id), do: "turn-item:workspace-preparation:#{run_id}"

  # A message for later: its run waits in the queue, with the message itself. A
  # restart puts it first and asks for the active run to be interrupted.
  defp queue_run(state, thread, runs, command, restart_of) do
    at = Entities.now()
    selection = command["modelSelection"] || thread["modelSelection"]
    instance = selection["instanceId"] || thread["providerInstanceId"] || "codex"
    driver = driver_for(instance)
    message_id = command["messageId"] || Entities.new_id("message")

    ids = %{
      driver: driver,
      instance: instance,
      thread: thread["id"],
      run: Entities.new_id("run"),
      attempt: nil,
      root_node: nil,
      provider_thread: "provider-thread:#{driver}:#{thread["id"]}",
      message: message_id
    }

    queued = queued_runs(state)
    position = if restart_of, do: 0, else: length(queued) + 1

    run =
      Entities.run(ids, length(runs) + 1, selection, at)
      |> Map.merge(%{"status" => "queued", "queuePosition" => position})

    message =
      Entities.message(ids, message_id, "user", command["text"] || "", false, at)
      |> Map.merge(%{
        "attachments" => command["attachments"] || [],
        "createdBy" => command["createdBy"] || "user",
        "creationSource" => command["creationSource"] || "web"
      })
      |> with_message_fields(command)

    # A restart's message goes first; the others move down one.
    shifted =
      if restart_of,
        do:
          for(
            {queued_run, index} <- Enum.with_index(queued, 2),
            change = upsert(state, "run", queued_run["id"], &Map.put(&1, "queuePosition", index)),
            do: change
          ),
        else: []

    run = if restart_of, do: Map.put(run, "queuePosition", 1), else: run

    {[create("run", ids.run, run), create("message", message_id, message)] ++ shifted,
     {:ok, if(restart_of, do: {:restart, restart_of}, else: :queued)}}
  end

  # Starts a run for a message: a new one, or a queued run (with its stored message
  # as `command`), which keeps its ordinal and ids.
  defp new_run(state, thread, runs, command, queued \\ nil) do
    at = Entities.now()
    thread_id = thread["id"]
    ordinal = if queued, do: queued["ordinal"], else: length(runs) + 1

    selection =
      (queued && queued["modelSelection"]) || command["modelSelection"] ||
        thread["modelSelection"]

    instance = selection["instanceId"] || thread["providerInstanceId"] || "codex"
    driver = driver_for(instance)
    provider_thread_id = "provider-thread:#{driver}:#{thread_id}"
    session_id = "provider-session:#{driver}:#{thread_id}"
    cwd = thread["worktreePath"] || project_root(thread["projectId"]) || File.cwd!()

    message_id =
      (queued && queued["userMessageId"]) || command["messageId"] || Entities.new_id("message")

    ids = %{
      driver: driver,
      instance: instance,
      thread: thread_id,
      run: (queued && queued["id"]) || Entities.new_id("run"),
      attempt: Entities.new_id("run-attempt"),
      root_node: Entities.new_id("node"),
      provider_thread: provider_thread_id,
      message: message_id
    }

    provider_thread = StreamState.get(state, "provider-thread")[provider_thread_id]
    scope_id = HalC2.Checkpoint.scope_id(thread_id)

    # One root checkpoint scope per thread; it follows the latest run.
    scope_change =
      if StreamState.get(state, "checkpoint-scope")[scope_id] do
        upsert(
          state,
          "checkpoint-scope",
          scope_id,
          &Map.merge(&1, %{"runId" => ids.run, "nodeId" => ids.root_node, "cwd" => cwd})
        )
      else
        create(
          "checkpoint-scope",
          scope_id,
          HalC2.Checkpoint.scope(thread_id, ids.run, ids.root_node, provider_thread_id, cwd, at)
        )
      end

    # An imported thread has a provider thread (its native session) but no session yet.
    fresh_session =
      Entities.provider_session(session_id, cwd, selection["model"], at, driver, instance)

    # A session made by an older server takes on what this one can do.
    session_change =
      if StreamState.get(state, "provider-session")[session_id],
        do:
          upsert(
            state,
            "provider-session",
            session_id,
            # A session stopped while idle is ready again.
            &Map.merge(&1, %{
              "capabilities" => fresh_session["capabilities"],
              "status" => "ready",
              "cwd" => cwd
            })
          ),
        else: create("provider-session", session_id, fresh_session)

    provider_changes =
      if provider_thread do
        [
          session_change,
          upsert(
            state,
            "provider-thread",
            provider_thread_id,
            # A rolled-back head is where this run resumes the conversation.
            &Map.merge(&1, %{
              "lastRunOrdinal" => ordinal,
              "providerSessionId" => session_id,
              "nativeConversationHeadRef" => nil
            })
          )
        ]
      else
        [
          session_change,
          create(
            "provider-thread",
            provider_thread_id,
            Entities.provider_thread(
              provider_thread_id,
              thread_id,
              session_id,
              ordinal,
              at,
              driver,
              instance
            )
          )
        ]
      end

    text = command["text"] || ""

    changes =
      Enum.reject(provider_changes ++ [scope_change], &is_nil/1)
      |> Kernel.++(
        [
          if(queued,
            do:
              upsert(
                state,
                "run",
                ids.run,
                &Map.merge(
                  &1,
                  Map.drop(Entities.run(ids, ordinal, selection, at), ["requestedAt"])
                )
              ),
            else: create("run", ids.run, Entities.run(ids, ordinal, selection, at))
          ),
          create("run-attempt", ids.attempt, Entities.attempt(ids)),
          create(
            "node",
            ids.root_node,
            Entities.node(ids, ids.root_node, "root_turn", "pending", at, %{
              "checkpointScopeId" => scope_id
            })
          ),
          unless(queued,
            do:
              create(
                "message",
                message_id,
                Entities.message(ids, message_id, "user", text, false, at, %{
                  "attachments" => command["attachments"] || [],
                  "createdBy" => command["createdBy"] || "user",
                  "creationSource" => command["creationSource"] || "web"
                })
                |> with_message_fields(command)
              )
          ),
          create(
            "turn-item",
            "turn-item:user:#{message_id}",
            Entities.turn_item(
              ids,
              "turn-item:user:#{message_id}",
              "user_message",
              # A prepared run's message was shown while its workspace was prepared.
              (StreamState.get(state, "turn-item")["turn-item:user:#{message_id}"] || %{})[
                "ordinal"
              ] || next_ordinal(state),
              "completed",
              at,
              %{
                "createdBy" => command["createdBy"] || "user",
                "creationSource" => command["creationSource"] || "web",
                "messageId" => message_id,
                "inputIntent" =>
                  if(queued && queued["status"] == "queued",
                    do: "queued_turn",
                    else: "turn_start"
                  ),
                "text" => text,
                "attachments" => command["attachments"] || []
              }
            )
            |> with_context(command)
          )
        ]
        |> Enum.reject(&is_nil/1)
      )

    handoff =
      HalC2.Orchestration.Handoff.plan(state, provider_thread, driver, ids.run, ordinal, at)

    turn = %{
      ids: ids,
      run_ordinal: ordinal,
      started_ms: System.system_time(:millisecond),
      text:
        HalC2.Orchestration.Handoff.prompt(
          handoff.context,
          HalC2.ComposerContext.for_provider(text, command["context"])
        ),
      # A fork's first run continues the source's native thread from the fork point.
      fork: handoff.fork,
      cwd: cwd,
      scope_id: scope_id,
      model: selection["model"],
      # The model options picked in the composer: option id -> value.
      options:
        for(
          %{"id" => id, "value" => value} <- List.wrap((selection || %{})["options"]),
          into: %{},
          do: {id, value}
        ),
      runtime_mode: thread["runtimeMode"] || "full-access",
      # How assistant text is written as it streams (`TurnWriter.flush/2`).
      streaming_mode:
        HalC2.Settings.for_project(thread["projectId"])["responseStreamingMode"] || "paragraph",
      interaction_mode: thread["interactionMode"] || "default",
      attachments: provider_attachments(command["attachments"]),
      # A turn the provider started by itself, whose output its runtime already has
      # (a Claude wake, `HalC2.Claude.ThreadRuntime`): the message is not sent to it.
      wake: command["providerWake"] == true,
      native_thread_id: get_in(provider_thread || %{}, ["nativeThreadRef", "nativeId"]),
      head: get_in(provider_thread || %{}, ["nativeConversationHeadRef", "nativeId"])
    }

    {changes ++ handoff.changes, {:ok, turn}}
  end

  # A message that implements a proposed plan completes it, whether the plan is this
  # thread's or another thread's of the same project ("Implement in a new thread"),
  # and whether the message started, queued or steered a run.
  defp implemented_plan(thread_id, %{"threadId" => plan_thread, "planId" => plan_id})
       when is_binary(plan_thread) do
    project = fn state, id -> (StreamState.get(state, "thread")[id] || %{})["projectId"] end
    project_id = project.(HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id)), thread_id)

    HalC2.Streams.transact(plan_thread, :thread, fn state ->
      case StreamState.get(state, "plan")[plan_id] do
        %{"kind" => "proposed_plan"} ->
          if project.(state, plan_thread) == project_id,
            do:
              {Enum.reject(
                 [upsert(state, "plan", plan_id, &Map.put(&1, "status", "completed"))],
                 &is_nil/1
               ), :ok},
            else: {[], :ok}

        _ ->
          {[], :ok}
      end
    end)
  end

  defp implemented_plan(_thread_id, _ref), do: :ok

  @doc "The next free turn-item ordinal in a thread."
  def next_ordinal(state) do
    state
    |> StreamState.get("turn-item")
    |> Map.values()
    |> Enum.map(& &1["ordinal"])
    |> Enum.max(fn -> -1 end)
    |> Kernel.+(1)
  end

  @doc "A change creating `entity`."
  def create(kind, id, entity), do: {kind, id, Patch.diff(nil, entity)}

  @doc "A change updating an existing entity with `fun`, or `nil` when nothing changes."
  def upsert(state, kind, id, fun) do
    current = StreamState.get(state, kind)[id]

    # `fun` returning nil leaves the entity as it is, a missing one included.
    with %{} = next <- fun.(current),
         %{} = patch <- Patch.diff(current, next) do
      {kind, id, patch}
    else
      _ -> nil
    end
  end

  defp project_root(nil), do: nil

  defp project_root(project_id) do
    Enum.find_value(HalC2.Shell.rows(), fn
      {{mc, ^project_id}, {"project", row}} when mc == node() -> row["workspaceRoot"]
      _ -> nil
    end)
  end
end
