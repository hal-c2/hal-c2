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

  # The built-in runtimes' registries, in the order a release visits them. One
  # list for stopping, releasing and checking: a registry missed by the check
  # would have its live session's credential revoked on every release.
  @session_registries [
    HalC2.Codex.Registry,
    HalC2.Claude.Registry,
    HalC2.Acp.Registry,
    HalC2.Pi.Registry,
    HalC2.Muse.Registry
  ]
  # The input of a prepared run's workspace preparation item.
  @preparing_workspace "Preparing workspace"

  @thread_updates ~w(thread.archive thread.unarchive thread.delete thread.settle thread.unsettle
                     thread.snooze thread.unsnooze thread.pin thread.unpin thread.pin.reorder
                     thread.active.reorder thread.visit thread.mark-unread thread.metadata.update
                     thread.runtime-mode.set thread.interaction-mode.set thread.model-selection.set
                     provider.switch thread.pull-request.link thread.pull-request.unlink
                     thread.title.regeneration.complete)
  # Commands that arrange a thread in the lists; an archived thread takes none of them.
  @organizing ~w(thread.settle thread.unsettle thread.snooze thread.unsnooze thread.pin
                 thread.unpin thread.pin.reorder thread.active.reorder)

  @doc "Handles one client RPC by method name; see `packages/contracts/src/orchestrationV2.ts`."
  @spec handle(String.t(), map) :: {:ok, term} | {:error, String.t()}
  def handle("orchestration.dispatchCommand", command) do
    result =
      HalC2.Traces.span(
        "orchestration.dispatchCommand",
        %{"command.type" => command["type"]},
        fn ->
          try do
            dispatch_once(command)
          catch
            # A provider that fails inside the dispatch reaches the client with its
            # own reason, not the engine's wrapper around it.
            kind, reason ->
              require Logger
              Logger.error(Exception.format(kind, reason, __STACKTRACE__))

              cause =
                if is_exception(reason),
                  do: Exception.message(reason),
                  else: Exception.format(kind, reason)

              {:error,
               %{
                 "message" => "Failed to dispatch orchestration command",
                 "cause" => %{"message" => cause}
               }}
          end
        end
      )

    case result do
      {:error, error} -> {:error, HalC2.Orchestration.UserFacingErrors.message(error)}
      other -> other
    end
  end

  def handle("orchestration.launchThread", input), do: launch_thread(input)
  def handle("orchestration.searchThreads", input), do: HalC2.Search.threads(input)
  def handle("orchestration.getWorkflowScript", input), do: HalC2.WorkflowScripts.read(input)

  def handle("provider.uploadFeedback", %{"threadId" => thread_id} = input) do
    # The thread's latest provider thread says which provider ran it.
    driver =
      case HalC2.Shell.row(node(), thread_id) do
        {"thread", _row} ->
          HalC2.Streams.state(thread_id)
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
    state = HalC2.Streams.state(thread_id)
    HalC2.Checkpoint.turn_diff(state, thread_id, from, to, input["ignoreWhitespace"] != false)
  end

  # A client's command id is answered once: repeating it, as a client retrying
  # after a reconnect does, returns the first outcome without deciding again. Receipts live in the store's meta table.
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
    target_state = HalC2.Streams.state(target_id)
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
      HalC2.Orchestration.Effects.run_now(thread_id, "provider-session.detach", %{}, nil)
      {:ok, %{"sequence" => sequence(thread_id)}}
    end
  end

  def dispatch(%{"type" => "checkpoint.rollback", "threadId" => thread_id} = command) do
    with :ok <-
           HalC2.Orchestration.Effects.run_now(
             thread_id,
             "provider-thread.rollback",
             %{"command" => command},
             nil
           ),
         do: {:ok, %{"sequence" => sequence(thread_id)}}
  end

  # The user's stop shows in the transcript as a request, paired with the run's
  # "Run interrupted" result once the provider stops (`TurnWriter.finish/3`).
  def dispatch(%{"type" => "run.interrupt", "threadId" => thread_id} = command) do
    with :ok <- interrupt_policy(thread_id, command["runId"]) do
      HalC2.Streams.transact(thread_id, :thread, &{interrupt_request(&1, command), :ok})
      # Stopping a turn also stops its delegated tasks from waking it later.
      HalC2.Orchestration.Delegation.stop_wakes(thread_id, command["runId"])

      with :ok <- interrupt_any(thread_id, command["runId"]),
           do: {:ok, %{"sequence" => sequence(thread_id)}}
    end
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
    with :ok <- users_run(HalC2.Streams.state(thread_id), run_id),
         {:ok, command} <- edit_claims(thread_id, command) do
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

      if type == "thread.delete" do
        stop_runtimes(thread_id)
        # Work the thread still had waiting dies with it; cleaning up its
        # terminals and attached files is recorded work that outlives a
        # restart (`HalC2.Orchestration.Effects`).
        HalC2.Orchestration.Effects.cancel_thread(thread_id)
        HalC2.Orchestration.Effects.drop_thread(thread_id)
        HalC2.Orchestration.Effects.enqueue(thread_id, "terminal.cleanup", %{})
        HalC2.Orchestration.Effects.enqueue(thread_id, "attachment.cleanup", %{})
      end

      if type == "thread.runtime-mode.set",
        do: runtime_mode_changed(thread_id, command["runtimeMode"])

      # The archived threads are read from the sidebar rows, which a stream writes a
      # moment after its events: this one is in place before the reply, so a client
      # that lists them next sees the change.
      if type in ~w(thread.archive thread.unarchive thread.delete),
        do: HalC2.Streams.flush_shell(thread_id)

      {:ok, %{"sequence" => sequence(thread_id)}}
    end
  end

  # A queued message steers the running turn when its provider can take it; otherwise
  # it goes first and the run is interrupted, which starts it next.
  def dispatch(%{"type" => "queued-message.promote-to-steer", "threadId" => thread_id} = command) do
    state = HalC2.Streams.state(thread_id)
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

      agent_message?(message) ->
        users_run(state, queued["id"])

      message && target && target["status"] in @active_statuses &&
          steerable?(target, queued["providerInstanceId"]) ->
        promote(thread_id, queued, target, message, command)

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
  # The promoted message joins the running turn before the provider is asked to take
  # it, as a steer does (`reserve_steer/3`): a second promote finds its run no longer
  # queued, and the message sits ahead of the answer. A refusal puts it back in the
  # queue, first, and interrupts the turn, which starts it next (`unpromote/5`).
  defp promote(thread_id, queued, target, message, command) do
    promoted =
      HalC2.Streams.transact(thread_id, :thread, fn state ->
        runs = StreamState.get(state, "run")
        # As it is now: a queued message can be edited until it leaves the queue.
        message = StreamState.get(state, "message")[message["id"]]

        if message != nil and runs[queued["id"]]["status"] == "queued" and
             runs[target["id"]]["status"] in @active_statuses do
          at = Entities.now()

          changes =
            Enum.reject(
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
                steer_changes(
                  state,
                  target,
                  message["id"],
                  message,
                  "promoted_queued_to_steer",
                  at
                ),
              &is_nil/1
            )

          # The queue closes up in the same step: the ask that follows can take as
          # long as its timeout, and the runs behind keep their places meanwhile.
          positions = with_changes(state, changes) |> renumber()
          {changes ++ Enum.reject(positions, &is_nil/1), {:promoted, message}}
        else
          {[], runs[queued["id"]]["status"]}
        end
      end)

    case promoted do
      {:promoted, message} ->
        instance = target["providerInstanceId"] || "codex"

        case ask_steer(instance, thread_id, target["id"], steer_input(message)) do
          :ok ->
            {:ok, %{"sequence" => sequence(thread_id)}}

          {:error, reason} ->
            refused =
              "#{HalC2.ThreadMove.provider_name(instance)} did not take the message into its running turn (#{reason})"

            unpromote = &unpromote(&1, thread_id, queued["id"], message["id"], target["id"])

            case HalC2.Streams.transact(thread_id, :thread, unpromote) do
              :queued ->
                restart_target(thread_id, target["id"])
                # A turn that ended while it was out of the queue did not start it.
                start_next(thread_id)
                {:ok, %{"sequence" => sequence(thread_id)}}

              {:waits, why} ->
                {:error, "#{refused}, so it waits first in the queue. #{why}"}

              {:dropped, why} ->
                {:error, "#{refused}, and it was not queued again: #{why}"}
            end
        end

      "queued" ->
        restart_promoted(thread_id, command)

      _ ->
        {:error, "Queued run #{queued["id"]} is not queued."}
    end
  end

  # The refused message back on its own run, queued again and first, in one transaction:
  # the thread may have changed while the provider was asked. An archived or deleted
  # thread cancelled its queue meanwhile, and the run stays cancelled. A thread that is
  # moving got there after the turn ended (moves wait for a turn to end), and keeps the
  # message first in its queue without starting it. A thread that has moved keeps only
  # a forwarding record here, so nothing queued here runs: the run stays cancelled too,
  # and the sender is told to send it again on the destination.
  defp unpromote(state, thread_id, run_id, message_id, target_id) do
    thread = StreamState.get(state, "thread")[thread_id]
    message = StreamState.get(state, "message")[message_id]

    if message == nil or message["runId"] != target_id do
      {[], {:dropped, "it left the turn meanwhile."}}
    else
      released = [
        upsert(state, "message", message_id, &Map.put(&1, "runId", run_id)),
        {"turn-item", "turn-item:user:#{message_id}", Patch.delete()}
      ]

      cond do
        thread["deletedAt"] != nil ->
          {Enum.reject(released, &is_nil/1), {:dropped, "the thread was deleted."}}

        thread["archivedAt"] != nil ->
          {Enum.reject(released, &is_nil/1), {:dropped, "the thread was archived."}}

        is_map(thread["movedTo"]) ->
          {Enum.reject(released, &is_nil/1),
           {:dropped,
            "the thread has moved to #{thread["movedTo"]["label"]}; send it again there."}}

        true ->
          requeued =
            Enum.reject(
              [
                upsert(
                  state,
                  "run",
                  run_id,
                  &Map.merge(&1, %{"status" => "queued", "completedAt" => nil})
                )
                | released
              ],
              &is_nil/1
            )

          positions = with_changes(state, requeued) |> first_in_queue(run_id)
          {requeued ++ Enum.reject(positions, &is_nil/1), queue_waits(thread)}
      end
    end
  end

  defp queue_waits(%{"moving" => %{"label" => to}} = thread),
    do: {:waits, "#{thread["title"]} is moving to #{to}. Try again once it has arrived."}

  defp queue_waits(_thread), do: :queued

  defp message_request(thread_id, request_id) do
    request = HalC2.Streams.get(thread_id, "runtime-request", request_id)

    if request && HalC2.Orchestration.TurnWriter.message_request?(request), do: request
  end

  # The answer resolves the request and goes to the provider as a message: into the
  # running turn when there is one to steer, else as the thread's next turn. Sending
  # the same answer again changes nothing.
  defp answer_with_message(thread_id, request, command) do
    state = HalC2.Streams.state(thread_id)
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
  # (`node:approval:...`) or a thread imported from an earlier install
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

  # Answers keep their provider's shape; files are named by where they are saved.
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
  run is active, and by a runtime that took a turn since.
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

    if released == :ok, do: stop_session(thread_id), else: released
  end

  # A runtime runs under its provider plugin's sessions supervisor (`HalC2.Plugins`).
  defp stop_runtimes(thread_id) do
    for registry <- @session_registries,
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

  # Each runtime stops if it is idle. The thread was idle when its caller looked, but a
  # message may have started a turn since; that runtime keeps it (`:busy`).
  defp release_runtimes(thread_id) do
    kept =
      for registry <- @session_registries,
          Process.whereis(registry) != nil,
          {pid, _} <- Registry.lookup(registry, thread_id),
          release(pid) == :busy,
          do: pid

    if kept == [], do: :ok, else: :busy
  end

  # A runtime replies to its release before it stops: it is gone once this returns,
  # as it was when the release was a supervisor's stop. One that does not answer in
  # time is still there, and may be driving a turn: it is kept, like a busy one.
  defp release(pid) do
    ref = Process.monitor(pid)

    reply =
      try do
        GenServer.call(pid, :release, Application.get_env(:hal_c2, :release_timeout_ms, 15_000))
      catch
        :exit, {:timeout, _} -> :busy
        :exit, _ -> :gone
      end

    if reply == :ok do
      receive do
        {:DOWN, ^ref, _, _, _} -> :ok
      after
        15_000 -> :ok
      end
    end

    Process.demonitor(ref, [:flush])
    reply
  end

  # The stopped session's agent loses its HAL-C2 tools; the next session gets new ones.
  # A deleted thread only stops its runtimes: its agent's credential still reaches
  # the tools, which answer that the calling thread is gone.
  #
  # A released runtime leaves its registry before it stops, so a message in that
  # window starts a replacement whose first turn may already hold the thread's
  # credential (`HalC2.Mcp.server/2` reuses it by thread and instance). When a
  # runtime is again registered for the thread, the credential is the live
  # session's now and stays; revoking it would leave that session's tools
  # unauthenticated until it restarts. Two edges of that trade-off: the check
  # and the revoke are not atomic, so a replacement that registers and takes
  # the credential between them still loses it (a microseconds-wide window the
  # deterministic test cannot pin); and not revoking extends the dying
  # session's own use of the shared token until the next release, since the
  # token cannot tell the two sessions apart.
  defp stop_session(thread_id) do
    with :ok <- release_runtimes(thread_id) do
      if session_running?(thread_id), do: :ok, else: HalC2.Mcp.revoke(thread_id)
    end
  end

  # Whether any built-in runtime is live for the thread right now. A crashed
  # runtime never unregisters itself (only `:release` does), so its entry can
  # outlive it until the Registry handles its own DOWN: only a live pid counts,
  # or a dead session would keep its credential from being revoked above.
  defp session_running?(thread_id) do
    Enum.any?(@session_registries, fn registry ->
      Process.whereis(registry) != nil and
        Enum.any?(Registry.lookup(registry, thread_id), fn {pid, _} -> Process.alive?(pid) end)
    end)
  end

  # The built-in runtimes, and the plugin adapters that can take a runtime call.
  defp runtimes(callback, arity) do
    builtin = [
      HalC2.Codex.ThreadRuntime,
      HalC2.Claude.ThreadRuntime,
      HalC2.Acp.ThreadRuntime,
      HalC2.Pi.ThreadRuntime,
      HalC2.Muse.ThreadRuntime
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
      HalC2.Orchestration.Effects.run_now(
        thread_id,
        "runtime-request.respond",
        %{"requestId" => request_id},
        {thread_id, request_id, response}
      )

    with :ok <- result, do: {:ok, %{"sequence" => sequence(thread_id)}}
  end

  defp respond_now(thread_id, request_id, response) do
    Enum.find_value(
      runtimes(:respond, 3),
      {:error, "no pending request"},
      fn runtime ->
        if session_call(fn -> runtime.respond(thread_id, request_id, response) end, :gone) ==
             :ok,
           do: :ok
      end
    )
  end

  # The checkout is ready and its baseline taken before the runtime starts the turn.
  # A start that fails anywhere (the checkout, the runtime starting, or the runtime
  # dying while it starts the turn) must not leave the run "starting" forever: the
  # run fails and the thread can take the next message. Once the turn was claimed,
  # `HalC2.Orchestration.TurnWatch` may be ending it too; only the first to abandon
  # it does.
  # Starting a turn is the provider work an accepted message set going: it is
  # recorded and run as an effect (`HalC2.Orchestration.Effects`), so a stop
  # that arrives before it can cancel it and a restart knows it was in flight.
  defp begin_turn(thread_id, turn) do
    HalC2.Orchestration.Effects.run_now(
      thread_id,
      "provider-turn.start",
      %{"runId" => turn.ids.run},
      turn
    )

    :ok
  end

  defp begin_turn_now(thread_id, turn) do
    restore_worktree(thread_id)
    :ok = HalC2.Checkpoint.baseline(turn.cwd, turn.scope_id, turn.run_ordinal - 1)
    :ok = start_turn(thread_id, turn)
  catch
    kind, reason ->
      require Logger
      Logger.warning("turn failed to start in #{thread_id}: #{inspect({kind, reason})}")

      HalC2.Orchestration.TurnWriter.abandon(
        thread_id,
        turn.ids.run,
        "failed",
        HalC2.Orchestration.TurnWriter.start_failure(nil, :closed)
      )
  end

  # A runtime that released itself as idle just before this run began stops with the
  # call unanswered (or is gone by the call); a new one takes the turn.
  defp start_turn(thread_id, turn) do
    runtime(turn.ids.instance).start_turn(thread_id, turn)
  catch
    :exit, {reason, _} when reason in [{:shutdown, :released}, :noproc] ->
      runtime(turn.ids.instance).start_turn(thread_id, turn)
  end

  # A worktree the storage sweep removed comes back at the same path from the
  # thread's branch before a turn runs in it.
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

  @doc """
  Organizes a thread plugin `plugin_id` started, as `changes` asks: `"settled"`
  settles or unsettles it (a pinned thread, and one the user unsettled by hand,
  are left settled as they are) and `"listed"` shows or hides it in the thread
  list. Only the plugin's own threads; a change already so writes nothing.
  """
  @spec organize_plugin_thread(String.t(), String.t(), map) :: :ok | {:error, String.t()}
  def organize_plugin_thread(thread_id, plugin_id, changes) do
    at = Entities.now()

    HalC2.Streams.transact(thread_id, :thread, fn state ->
      case StreamState.get(state, "thread")[thread_id] do
        %{"plugin" => %{"id" => ^plugin_id}} = thread ->
          cond do
            thread["deletedAt"] != nil ->
              {[], {:error, "Thread #{thread_id} is deleted."}}

            thread["moving"] != nil or thread["movedTo"] != nil ->
              {[], {:error, "Thread #{thread_id} is moving or has moved."}}

            true ->
              fields = organize_fields(thread, changes, at)

              if Enum.any?(fields, fn {key, value} -> thread[key] != value end) do
                {[upsert(state, "thread", thread_id, &Map.merge(&1, fields))], :ok}
              else
                {[], :ok}
              end
          end

        %{} ->
          {[], {:error, "Thread #{thread_id} was not started by #{plugin_id}."}}

        nil ->
          {[], {:error, "unknown thread #{thread_id}"}}
      end
    end)
  end

  defp organize_fields(thread, changes, at) do
    settled =
      case changes["settled"] do
        true ->
          if thread["pinnedAt"] == nil and thread["settledOverride"] != "active",
            do: thread_fields("thread.settle", %{}, thread, at),
            else: %{}

        false ->
          # A plugin unsettling is not the user holding the thread active: the
          # override clears, as a wake clears it, so the thread can settle again.
          if thread["settledOverride"] == "settled",
            do: %{"settledOverride" => nil, "settledAt" => nil, "unsettledAt" => at},
            else: %{}

        _ ->
          %{}
      end

    if is_boolean(changes["listed"]),
      do: Map.put(settled, "plugin", Map.put(thread["plugin"], "listed", changes["listed"])),
      else: settled
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
    command = message && first_message(thread_id, input, message)

    # A new worktree's first message is recorded with the thread, as a run preparing
    # it, so a retry of the launch that finds the thread finds its message too.
    in_worktree =
      if command && strategy["type"] == "worktree",
        do: in_worktree(thread_id, thread, command)

    transacted =
      HalC2.Streams.transact(thread_id, :thread, fn state ->
        case StreamState.get(state, "thread")[thread_id] do
          nil when reuse? ->
            {[], {:error, "Thread #{thread_id} does not exist."}}

          nil ->
            change = {"thread", thread_id, Patch.diff(nil, thread)}
            with_first_run(state, thread_id, change, :created, in_worktree)

          # A draft the client already created takes the launch's workspace, but only while empty.
          existing when reuse? ->
            if reusable?(state, existing, input["projectId"]) do
              fields =
                workspace_fields(strategy)
                |> then(&if(titling, do: Map.put(&1, "titleRegeneration", titling), else: &1))

              change = upsert(state, "thread", thread_id, &Map.merge(&1, fields))
              with_first_run(state, thread_id, change, :reused, in_worktree)
            else
              {[],
               {:error,
                "Only an empty active thread in the target project can change workspace during launch."}}
            end

          _ when titling != nil ->
            change =
              upsert(state, "thread", thread_id, &Map.put(&1, "titleRegeneration", titling))

            {[change], {:ok, :resumed, nil}}

          _ ->
            {[], {:ok, :resumed, nil}}
        end
      end)

    with {:ok, created, first} <- transacted,
         do: launch_message(thread_id, strategy, command, titling, created, first)
  end

  # The thread's `change`, and with it the first message's run when the launch makes a
  # new worktree (`in_worktree`), decided as the thread will be once it is committed.
  defp with_first_run(_state, _thread_id, change, created, nil),
    do: {Enum.reject([change], &is_nil/1), {:ok, created, nil}}

  defp with_first_run(_state, _thread_id, _change, _created, {:error, _} = refused),
    do: {[], refused}

  defp with_first_run(state, thread_id, change, created, {:ok, project, command}) do
    {kind, id, patch} = change || {"thread", thread_id, %{}}

    launched =
      StreamState.apply_event(state, %{seq: state.seq, kind: kind, entity: id, patch: patch})

    {changes, decided} = decide_message(launched, thread_id, command)
    {Enum.reject([change], &is_nil/1) ++ changes, {:ok, created, {project, command, decided}}}
  end

  defp reusable?(state, thread, project_id) do
    thread["projectId"] == project_id and thread["archivedAt"] == nil and
      thread["deletedAt"] == nil and StreamState.get(state, "message") == %{} and
      StreamState.get(state, "run") == %{}
  end

  # The first message is a command of its own (`<commandId>:initial-message`),
  # answered once like any client command.
  defp first_message(thread_id, input, message) do
    Map.merge(message, %{
      "type" => "message.dispatch",
      "commandId" => "#{input["commandId"]}:initial-message",
      "threadId" => thread_id,
      "createdBy" => input["createdBy"] || "user",
      "creationSource" => input["creationSource"] || "web",
      "modelSelection" => input["modelSelection"]
    })
  end

  defp launch_message(thread_id, strategy, command, titling, created, first) do
    result = %{"threadId" => thread_id, "resumed" => created == :resumed}

    if titling,
      do: generate_title(thread_id, command["text"] || "", command["attachments"] || [])

    launched =
      case first do
        _ when command == nil ->
          {:ok, result}

        nil ->
          dispatch_once(command)

        {project, command, {:ok, {:prepared, run_id}}} ->
          :ok = HalC2.WorktreeSetup.start(thread_id, run_id, project, strategy, command["text"])
          {:ok, %{"sequence" => sequence(thread_id)}}

        {_, _, {:ok, :sent}} ->
          {:ok, %{"sequence" => sequence(thread_id)}}

        {_, _, refused} ->
          refused
      end

    with {:ok, _} <- launched, do: {:ok, result}
  end

  defp workspace_fields(%{"type" => "existing_worktree"} = strategy),
    do: %{"worktreePath" => strategy["worktreePath"], "branch" => strategy["branch"]}

  defp workspace_fields(%{"type" => "root", "branch" => branch}) when is_binary(branch),
    do: %{"branch" => branch}

  defp workspace_fields(_strategy), do: %{"branch" => nil}

  # The project a new worktree is made from, and the first message as it waits for
  # it: its attachments claimed and its run deferred.
  defp in_worktree(thread_id, thread, command) do
    project =
      case HalC2.Shell.row(node(), thread["projectId"]) do
        {"project", row} -> row
        _ -> nil
      end

    with %{"workspaceRoot" => _} <- project || {:error, "The project is not on this MC."},
         {:ok, attachments} <- HalC2.Attachments.claim(thread_id, command["attachments"] || []) do
      command =
        command
        |> claimed(attachments)
        |> Map.put("dispatchMode", %{"type" => "defer_start"})

      {:ok, project, command}
    end
  end

  # Titles a thread in the background: from its first message's `text` and
  # `attachments`, or, regenerating, from its user and assistant messages and
  # its `previous` title. The thread keeps its title until a new one arrives;
  # generation that fails or keeps the title clears the thread's in-flight
  # mark (`titleRegeneration`). It is an effect on its own lane, so it neither
  # waits for nor delays the thread's provider work; a first title that fails
  # is retried by the effect worker, a regeneration is tried once.
  defp generate_title(thread_id, text, attachments, previous \\ nil) do
    HalC2.Orchestration.Effects.enqueue(
      thread_id,
      "thread-title.generate",
      %{"text" => text, "attachments" => attachments, "previous" => previous},
      "title"
    )
  end

  defp title_effect(%{"threadId" => thread_id, "args" => args}, will_retry) do
    previous = args["previous"]

    root =
      case HalC2.Shell.row(node(), thread_id) do
        {"thread", row} -> row["worktreePath"] || project_root(row["projectId"])
        _ -> nil
      end

    opts = [attachments: args["attachments"] || [], previous_title: previous]

    case HalC2.TextGeneration.thread_title(root || System.tmp_dir!(), args["text"] || "", opts) do
      {:ok, %{"title" => title}} when title != "New thread" ->
        if previous != nil and String.trim(title) == String.trim(previous) do
          title_settled(thread_id)
        else
          dispatch(%{
            "type" => "thread.metadata.update",
            "threadId" => thread_id,
            "title" => title
          })
        end

        :ok

      {:ok, _} ->
        title_settled(thread_id)
        :ok

      failure ->
        message = "thread title not generated: #{inspect(failure)}"

        if will_retry and previous == nil do
          {:retry, message}
        else
          require Logger
          Logger.warning(message)
          title_settled(thread_id)
          {:error, message}
        end
    end
  end

  defp title_settled(thread_id),
    do:
      dispatch(%{
        "type" => "thread.metadata.update",
        "threadId" => thread_id,
        "regenerateTitle" => false
      })

  defp regenerate_title(thread_id) do
    state = HalC2.Streams.state(thread_id)
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
    state = HalC2.Streams.state(thread_id)

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

    # A child that never starts has no turn to report; a task waiting on it ends here.
    if result == :ok,
      do:
        Task.start(fn ->
          HalC2.Orchestration.Delegation.report(thread_id, run_id, status)
        end)

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
      HalC2.Settings.known_instance?(instance, "claudeAgent") -> "claudeAgent"
      true -> "codex"
    end
  end

  @doc "The runtime (a `HalC2.Plugins.ProviderAdapter`) for a provider instance."
  def runtime(instance) do
    case is_binary(instance) && HalC2.Plugins.provider(instance) do
      # The bundled ACP plugin serves Pi and Muse too, but each runs its own protocol.
      {:ok, _driver, HalC2.Plugins.Bundled.Acp} -> builtin_runtime(instance)
      {:ok, _driver, module} -> module
      _ -> builtin_runtime(instance)
    end
  end

  defp builtin_runtime("claudeAgent"), do: HalC2.Claude.ThreadRuntime

  defp builtin_runtime(instance) when is_binary(instance) and instance != "codex" do
    cond do
      HalC2.Acp.driver(instance) == "pi" -> HalC2.Pi.ThreadRuntime
      HalC2.Acp.driver(instance) == "muse" -> HalC2.Muse.ThreadRuntime
      HalC2.Acp.agent?(instance) -> HalC2.Acp.ThreadRuntime
      HalC2.Settings.known_instance?(instance, "claudeAgent") -> HalC2.Claude.ThreadRuntime
      true -> HalC2.Codex.ThreadRuntime
    end
  end

  defp builtin_runtime(_codex), do: HalC2.Codex.ThreadRuntime

  # A thread has at most one active run. A stop that reaches it, pinned to it or not
  # pinned, goes only to the runtime of that run's provider. So stopping or restarting a
  # turn leaves the background work any provider left, the way it does on one provider.
  # Between turns, work an earlier turn left can sit in any provider's runtime, so every
  # runtime is asked and each stops the work of its own that the pin covers (#474). A
  # started turn nothing drives any more (its runtime stopped without ending it) ends
  # here, and a provider plugin that cannot stop a turn says so.
  # A provider that cannot be interrupted refuses the stop in its name, before
  # anything is recorded. Between turns there is no provider to ask, and
  # `interrupt_undriven/2` decides.
  defp interrupt_policy(thread_id, run_id) do
    runs = StreamState.list(HalC2.Streams.state(thread_id), "run")

    run =
      Enum.find(runs, &(&1["id"] == run_id)) ||
        Enum.find(runs, &(&1["status"] in @active_statuses))

    instance =
      run && run["status"] in @active_statuses &&
        (run["providerInstanceId"] || get_in(run, ["modelSelection", "instanceId"]))

    if instance,
      do: HalC2.Orchestration.CommandPolicy.ensure(instance, :interrupt),
      else: :ok
  end

  # Asking a provider to stop is its own recorded effect. Work for the run
  # that has not reached the provider yet is cancelled with it.
  defp interrupt_any(thread_id, run_id) do
    pending =
      run_id ||
        thread_id
        |> HalC2.Streams.state()
        |> StreamState.list("run")
        |> Enum.find_value(&(&1["status"] in @active_statuses && &1["id"]))

    if pending,
      do: HalC2.Orchestration.Effects.cancel_pending(thread_id, "provider-turn.start", pending)

    case HalC2.Orchestration.Effects.run_now(
           thread_id,
           "provider-turn.interrupt",
           %{"runId" => run_id},
           {thread_id, run_id}
         ) do
      {:ok, :ok} -> :ok
      other -> other
    end
  end

  defp interrupt_provider(thread_id, run_id) do
    # A provider plugin that cannot stop a turn is not asked; `interrupt_undriven/2`
    # says so. A bundled provider's runtime is its plugin module, which `runtimes/2`
    # does not list.
    asked =
      case active_runtime(thread_id, run_id) do
        nil ->
          runtimes(:interrupt, 2)

        runtime ->
          if Code.ensure_loaded?(runtime) and function_exported?(runtime, :interrupt, 2),
            do: [runtime],
            else: []
      end

    stopped = Enum.filter(asked, &interrupted?(&1, thread_id, run_id))
    if stopped != [], do: :ok, else: interrupt_undriven(thread_id, run_id)
  end

  # The runtime of the pinned run if it is active, or of the active run for a stop
  # with no pin; nil between turns.
  defp active_runtime(thread_id, run_id) do
    runs = StreamState.list(HalC2.Streams.state(thread_id), "run")

    run =
      if run_id,
        do: Enum.find(runs, &(&1["id"] == run_id)),
        else: Enum.find(runs, &(&1["status"] in @active_statuses))

    instance = run && (run["providerInstanceId"] || run["modelSelection"]["instanceId"])
    if run["status"] in @active_statuses and is_binary(instance), do: runtime(instance)
  end

  # The thread's access changed. The next turn starts with it from the thread record; a
  # runtime that can change a running turn's access (`set_runtime_mode/2`, which must
  # not block) is told now, so the user's switch is not ignored until the turn ends.
  defp runtime_mode_changed(thread_id, mode) do
    runtime = active_runtime(thread_id, nil)

    if runtime && Code.ensure_loaded?(runtime) &&
         function_exported?(runtime, :set_runtime_mode, 2),
       do: runtime.set_runtime_mode(thread_id, mode)
  end

  @doc """
  Whether a stop pinned to `run_id` reaching a runtime between turns names a run
  that started before `latest`, the run of the runtime's latest turn, or one the
  thread does not have: the work `latest` left is not that stop's to end (#474). A
  stop naming `latest` or a later run (one on another provider) ends it.
  """
  def earlier_run?(thread_id, run_id, latest) do
    runs = StreamState.get(HalC2.Streams.state(thread_id), "run")

    case {runs[run_id], runs[latest]} do
      {%{"ordinal" => pinned}, %{"ordinal" => last}} -> pinned < last
      _ -> true
    end
  end

  @doc """
  Runs `call`, a runtime's call into a thread's session. A session that stopped after
  the runtime looked it up, however it stopped (released as idle, crashed), answers
  `gone`, as one the lookup did not find would; one that is only slow still exits the
  caller. Only the exit of a `GenServer.call` reads as a stopped session, which covers
  every built-in runtime; a runtime that exits any other way still exits the caller.

  "Stopped" is not an explicit refusal: a session that took the call's work (an
  answer sent to the provider) and then died before replying reads the same as one
  that died before taking it. Callers that retry on `gone` can therefore report an
  answer that landed as missing; for the built-in runtimes the provider connection
  dies with the runtime, so a taken-but-unacknowledged call is lost with it.

  A steer is not a caller either: `ask_steer/4` reads every exit as a refusal, since
  its message is already in the turn and only a refusal takes it back out.
  `start_turn/2` is deliberately not a caller: its retry re-dispatches the turn, so
  it retries only where the work provably never started (`{:shutdown, :released}`
  and `:noproc`); a runtime killed or crashing as a turn starts fails the run
  rather than risking the turn starting twice.
  """
  def session_call(call, gone) do
    call.()
  catch
    :exit, {why, {GenServer, :call, _}} when why != :timeout ->
      log_unexpected_stop(why)
      gone
  end

  # An exit outside the ways a session stops is some other server's failure read as
  # "gone" (a call a runtime adapter makes in the caller's process); say so, so the
  # misclassification stays diagnosable instead of dropping the reason. The
  # expected reasons can still be a nested call's, not the session's: most
  # built-in closures are single calls (respond, the Claude/ACP rollback inner
  # calls, Codex feedback), but the Codex/ACP/Pi rollback
  # closures run `ensure()` — a sessions-supervisor call — before the session
  # call, so a supervisor exit there is logged at debug as an expected stop.
  # A plugin adapter's closure need not be a single call either. They are
  # logged at debug rather than dropped silently.
  defp log_unexpected_stop(why) when why in [:noproc, :normal, :shutdown, :killed],
    do: log_stop_at_debug(why)

  defp log_unexpected_stop({:shutdown, _} = why), do: log_stop_at_debug(why)

  defp log_unexpected_stop(why) do
    require Logger
    Logger.warning("a session call read as stopped exited with #{inspect(why)}")
  end

  defp log_stop_at_debug(why) do
    require Logger
    Logger.debug("a session call read as stopped exited with #{inspect(why)}")
  end

  # A runtime that dies as it is asked leaves its turn to `interrupt_undriven/2`, and
  # one whose registry is not running (an MC started without it) holds nothing to stop.
  defp interrupted?(runtime, thread_id, run_id) do
    runtime.interrupt(thread_id, run_id) == :ok
  rescue
    # Any other error out of an adapter is a bug, and must not read as nothing to stop.
    error in ArgumentError ->
      if error.message =~ "unknown registry", do: false, else: reraise(error, __STACKTRACE__)
  catch
    :exit, _ -> false
  end

  defp interrupt_undriven(thread_id, run_id) do
    state = HalC2.Streams.state(thread_id)
    runs = StreamState.list(state, "run")

    run =
      Enum.find(runs, &(&1["id"] == run_id)) ||
        Enum.find(runs, &(&1["status"] in @active_statuses))

    latest = Enum.max_by(runs, &(&1["ordinal"] || 0), fn -> nil end)

    cond do
      # A turn still being handed to its provider, or one nothing drives any
      # more, is ended here: the provider never starts it, or has nothing to
      # stop. Pending work for it is cancelled first (`interrupt_any/2`).
      run != nil and run["status"] in ~w(starting running waiting) and
          not HalC2.Orchestration.TurnWatch.driven?(run["id"]) ->
        HalC2.Orchestration.TurnWriter.abandon(thread_id, run["id"], "interrupted", nil)

      # The turn ended as the stop arrived: the provider says it is not active,
      # and the stop counts as done rather than an error to retry. A run that
      # failed or was cancelled is a different answer: nothing was stopped.
      run != nil and latest != nil and run["id"] == latest["id"] and
          run["status"] == "completed" ->
        :ok

      true ->
        interrupt_refusal(run)
    end
  end

  defp interrupt_refusal(run) do
    instance = run && run["providerInstanceId"]

    cannot =
      with instance when is_binary(instance) <- instance,
           {:ok, _driver, module} <- HalC2.Plugins.provider(instance),
           false <- function_exported?(module, :interrupt, 2) do
        instance
      else
        _ ->
          if is_binary(instance) and
               not HalC2.Orchestration.CommandPolicy.instance_supports?(instance, :interrupt),
             do: instance
      end

    if cannot,
      do: {:error, HalC2.Orchestration.UserFacingErrors.capability_message(cannot, :interrupt)},
      else: {:error, "no running turn"}
  end

  defp dispatch_message(thread_id, command) do
    decide = fn state -> decide_dispatch(state, thread_id, command) end

    case HalC2.Streams.transact(thread_id, :thread, decide) do
      {:ok, _} = decided -> dispatched(thread_id, command, decided)
      {:error, _} = error -> error
    end
  end

  @doc false
  # One try of a recorded effect (`HalC2.Orchestration.Effects`); `payload` is
  # what only this process can carry (a decided turn), `args` what a replay
  # after a restart rebuilds from.
  def execute_effect(%{"type" => type} = effect, payload, will_retry) do
    thread_id = effect["threadId"]
    args = effect["args"] || %{}

    case type do
      "provider-turn.start" ->
        # Work cancelled (or settled by a restart) before it started never
        # reaches the provider.
        run = StreamState.get(HalC2.Streams.state(thread_id), "run")[args["runId"]]

        if payload != nil and run != nil and run["status"] in @active_statuses do
          begin_turn_now(thread_id, payload)
          :ok
        else
          :ok
        end

      "provider-turn.interrupt" ->
        {^thread_id, run_id} = payload || {thread_id, args["runId"]}
        interrupt_provider(thread_id, run_id)

      "provider-turn.restart" ->
        {^thread_id, run_id} = payload || {thread_id, args["runId"]}
        _ = interrupt_provider(thread_id, run_id)
        :ok

      "provider-turn.steer" ->
        {instance, ^thread_id, run_id, input} = payload
        ask_steer_now(instance, thread_id, run_id, input)

      "runtime-request.respond" ->
        {^thread_id, request_id, response} = payload
        respond_now(thread_id, request_id, response)

      "provider-session.detach" ->
        _ = stop_session(thread_id)
        :ok

      "provider-thread.rollback" ->
        HalC2.Orchestration.Rollback.run(args["command"])

      "provider-runtime.continue" ->
        case dispatch(args["command"]) do
          {:ok, _} -> :ok
          {:error, message} -> {:error, message}
        end

      "checkpoint.capture" ->
        {:ok,
         HalC2.Checkpoint.capture_run(
           args["cwd"],
           args["scopeId"],
           args["runOrdinal"],
           args["runId"],
           args["rootNodeId"],
           thread_id,
           args["at"]
         )}

      "terminal.cleanup" ->
        if Process.whereis(HalC2.Terminal.Registry),
          do: HalC2.Terminal.close(%{"threadId" => thread_id})

        :ok

      "attachment.cleanup" ->
        HalC2.Attachments.delete_thread(thread_id)

      "thread-title.generate" ->
        title_effect(effect, will_retry)

      other ->
        {:error, "unknown effect #{other}"}
    end
  end

  @doc """
  `message.dispatch` decided inside a transaction of the thread's stream, for a caller
  that records the message together with its own changes; `dispatched/3` finishes it
  once the transaction has committed.
  """
  def decide_dispatch(state, thread_id, command) do
    case decide_message(state, thread_id, command) do
      {[], {:ok, :sent}} = sent ->
        sent

      {changes, {:ok, _} = result} ->
        {Enum.reject([woken(state, thread_id) | changes], &is_nil/1), result}

      refused ->
        refused
    end
  end

  @doc "What follows a committed `decide_dispatch/3`: starting the turn, steering or interrupting."
  def dispatched(thread_id, command, {:ok, decided}) do
    case decided do
      status when status in [:queued, :sent] ->
        {:ok, %{"sequence" => sequence(thread_id)}}

      {:steer, run, message_id} ->
        steer(thread_id, run, message_id, command)

      {:restart, active_run_id} ->
        # The queued message goes first; the interrupted run's end starts it.
        _ =
          HalC2.Orchestration.Effects.run_now(
            thread_id,
            "provider-turn.restart",
            %{"runId" => active_run_id},
            {thread_id, active_run_id}
          )

        {:ok, %{"sequence" => sequence(thread_id)}}

      turn ->
        begin_turn(thread_id, turn)
        {:ok, %{"sequence" => sequence(thread_id)}}
    end
  end

  # A message brings a settled or snoozed thread back to the active list: it is neither settled nor held active by hand any more.
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

  defp sequence(thread_id), do: HalC2.Streams.sequence(thread_id)

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
    target_id = command["targetRunId"]

    with {:ok, result} <- queue_change(thread_id, &first_in_queue(&1, queued_id)) do
      restart_target(thread_id, target_id)
      {:ok, result}
    end
  end

  # Interrupts the promoted message's target, whose end starts the queue's head. A
  # target that has ended is left alone: the turn running now may be the promoted
  # message's own. The interrupt is pinned to the target, so one that ends and lets
  # the message's own turn start after the check is refused by the runtime (#403).
  defp restart_target(thread_id, target_id) do
    run = StreamState.get(HalC2.Streams.state(thread_id), "run")[target_id] || %{}

    if target_id == nil or run["status"] in @active_statuses,
      do: _ = interrupt_any(thread_id, target_id)

    :ok
  end

  # Queue positions with `run_id` first and the other queued runs after it, in order.
  # A run that is no longer queued keeps its place out of the queue.
  defp first_in_queue(state, run_id) do
    queued = queued_runs(state) |> Enum.map(& &1["id"])
    order = if run_id in queued, do: [run_id | List.delete(queued, run_id)], else: queued

    for {id, position} <- Enum.with_index(order, 1),
        do: upsert(state, "run", id, &Map.put(&1, "queuePosition", position))
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

  # A message's `with_context/2` fields and, for one the MC sends for the agent, what it
  # reports (`notification`, see `message_item/6`) and which delegated task it delivers
  # (`HalC2.Orchestration.Delegation`).
  defp with_message_fields(message, command) do
    message
    |> with_context(command)
    |> Map.merge(Map.take(command, ["delegatedCompletion", "providerWake", "notification"]))
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

  # A message for another provider cannot join the old provider's turn: it waits for
  # that turn, or interrupts it, and the provider it names takes the thread over.
  defp steerable?(run, instance),
    do: (run["providerInstanceId"] || "codex") == (instance || "codex") and steerable?(run)

  defp message_instance(thread, command) do
    (command["modelSelection"] || thread["modelSelection"] || %{})["instanceId"] ||
      thread["providerInstanceId"] || "codex"
  end

  defp steerable?(run) do
    driver = driver_for(run["providerInstanceId"] || "codex")

    case HalC2.Plugins.declared(driver) do
      nil -> Entities.steers?(driver)
      provider -> :active_steering in (provider[:capabilities] || [])
    end
  end

  # A steer is recorded in the running turn before the provider is asked to take it
  # (`steer/4`), in the transaction that decided it. A repeat of its message id then
  # finds it sent, so the provider is asked once, and the message sits in the
  # transcript ahead of whatever the provider answers it with. The repeat answers for
  # what the first send has done so far: if the provider then refuses the first, the
  # repeat has already heard it was sent, and the sender learns otherwise from the
  # first send's error and the message leaving the turn. An MC that stops between the
  # two leaves the message in the turn `HalC2.Orchestration.Recovery` ends as
  # interrupted, though the provider never read it. Its session ended with the MC, and
  # that loss is accepted.
  defp reserve_steer(state, run, command) do
    at = Entities.now()
    message_id = command["messageId"] || Entities.new_id("message")
    ids = %{thread: run["threadId"], run: run["id"], root_node: run["rootNodeId"]}

    message =
      Entities.message(ids, message_id, "user", command["text"] || "", false, at)
      |> Map.merge(%{
        "attachments" => command["attachments"] || [],
        "createdBy" => command["createdBy"] || "user",
        "creationSource" => command["creationSource"] || "web"
      })
      |> with_message_fields(command)

    {[create("message", message_id, message)] ++
       steer_changes(state, run, message_id, message, "steer", at),
     {:ok, {:steer, run, message_id}}}
  end

  # What a runtime's `:ok` means: the provider answers the message.
  # - Codex and Muse refuse a `turn/steer` whose turn is no longer the one running
  #   (`expectedTurnId`), and answer an accepted one in that turn.
  # - Claude takes a steer only while the run's turn is its current one. A turn it was
  #   already ending answers it in a turn of its own, which the MC records as a wake.
  # - OpenCode (ACP) and Pi take a steer as their loop ends and answer it in a new
  #   loop, which their runtimes do not record yet (#313).
  # - Other ACP agents (Cursor, Grok, Antigravity) cannot be steered: they refuse.
  # - Plugin providers answer for their own `steer/3`.
  #
  # A refusal takes the reserved message back out of the run. While the turn still
  # runs that is an error for the sender: the message was not delivered, so it is
  # neither shown in the turn nor queued. A turn that ended meanwhile is why it was
  # refused, so the message is sent like any other (started, or queued behind a
  # newer run).
  defp steer(thread_id, run, message_id, command) do
    instance = run["providerInstanceId"] || "codex"

    case ask_steer(instance, thread_id, run["id"], steer_input(command)) do
      :ok ->
        {:ok, %{"sequence" => sequence(thread_id)}}

      {:error, reason} ->
        resend =
          command
          |> Map.put("messageId", message_id)
          |> Map.put("dispatchMode", %{"type" => "queue_after_active"})
          |> Map.delete("deliveryIntent")

        case HalC2.Streams.transact(thread_id, :thread, &unsteer(&1, thread_id, run, resend)) do
          {:resent, decided} ->
            dispatched(thread_id, resend, decided)

          :refused ->
            {:error,
             "#{HalC2.ThreadMove.provider_name(instance)} did not take the message into its running turn (#{reason}). Send it again, or stop the turn first."}

          {:error, _} = refused ->
            refused
        end
    end
  end

  # The runtime's `steer/3`. The message is already in the turn (`reserve_steer/3`,
  # `promote/5`), and only a refusal takes it back out: a runtime that stops, raises,
  # throws, or answers something else counts as one. A runtime that does not answer
  # in time but still holds the request and hands it to the provider when it gets to
  # it answers `:ok` itself, where that is known (the bundled runtimes' `steer/3`
  # do): taking the message back out then would show the answer without it, and a
  # promoted message would also run again as its own turn. If that late ask is
  # refused after all, the turn shows a message the provider never read. A timeout
  # that reaches here instead came from a call nested inside a runtime this cannot
  # see into, where it need not mean the request reached the provider at all, so it
  # counts as a refusal like any other exit.
  defp ask_steer(instance, thread_id, run_id, input) do
    case HalC2.Orchestration.Effects.run_now(
           thread_id,
           "provider-turn.steer",
           %{"runId" => run_id},
           {instance, thread_id, run_id, input}
         ) do
      {:ok, :ok} -> :ok
      other -> other
    end
  end

  defp ask_steer_now(instance, thread_id, run_id, input) do
    case runtime(instance).steer(thread_id, run_id, input) do
      :ok -> :ok
      {:error, reason} when is_binary(reason) -> {:error, String.slice(reason, 0, 200)}
      other -> {:error, "its runtime answered #{inspect(other, limit: 3, printable_limit: 80)}"}
    end
  catch
    :exit, {:timeout, _} ->
      {:error, "its runtime did not answer in time"}

    :exit, _ ->
      {:error, "its session stopped"}

    kind, reason ->
      require Logger
      Logger.error(Exception.format(kind, reason, __STACKTRACE__))
      {:error, "its runtime failed"}
  end

  defp unsteer(state, thread_id, run, resend) do
    message_id = resend["messageId"]
    message = StreamState.get(state, "message")[message_id]
    status = (StreamState.get(state, "run")[run["id"]] || %{})["status"]

    released = [
      {"message", message_id, Patch.delete()},
      {"turn-item", "turn-item:user:#{message_id}", Patch.delete()}
    ]

    cond do
      message == nil or message["runId"] != run["id"] ->
        {[], :refused}

      # The send woke the thread (`woken/2`) and it stays awake: its turn still runs.
      status in @active_statuses ->
        {released, :refused}

      true ->
        case decide_dispatch(with_changes(state, released), thread_id, resend) do
          {changes, {:ok, _} = decided} -> {released ++ changes, {:resent, decided}}
          {_, refused} -> {released, refused}
        end
    end
  end

  # `state` as it is once `changes` are committed, for deciding more in the same
  # transaction.
  defp with_changes(state, changes) do
    Enum.reduce(changes, state, fn {kind, id, patch}, acc ->
      StreamState.apply_event(acc, %{seq: acc.seq, kind: kind, entity: id, patch: patch})
    end)
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
    ids = %{
      thread: run["threadId"],
      run: run["id"],
      root_node: run["rootNodeId"],
      provider_thread: run["providerThreadId"]
    }

    item = message_item(ids, message_id, next_ordinal(state), at, message, intent)
    [create("turn-item", item["id"], item)]
  end

  # A message's place in the transcript. One the MC sends for the agent (a delegated
  # task's result, a provider's wake) carries a `notification` and is shown as that:
  # what happened, not something the user said. The message keeps its text for the
  # provider.
  defp message_item(ids, message_id, ordinal, at, %{"notification" => %{} = notification}, _) do
    Entities.turn_item(
      ids,
      "turn-item:user:#{message_id}",
      "notification",
      ordinal,
      "completed",
      at,
      Map.take(notification, ~w(source outcome summary detail workerThreadId workerTitle))
    )
  end

  defp message_item(ids, message_id, ordinal, at, message, intent) do
    Entities.turn_item(
      ids,
      "turn-item:user:#{message_id}",
      "user_message",
      ordinal,
      "completed",
      at,
      %{
        "createdBy" => message["createdBy"] || "user",
        "creationSource" => message["creationSource"] || "web",
        "messageId" => message_id,
        "inputIntent" => intent,
        "text" => message["text"] || "",
        "attachments" => message["attachments"] || []
      }
    )
    |> with_context(message)
  end

  # The thread fields a command sets.
  defp thread_fields("thread.archive", _, _, at), do: %{"archivedAt" => at}
  defp thread_fields("thread.unarchive", _, _, _), do: %{"archivedAt" => nil}
  defp thread_fields("thread.delete", _, _, at), do: %{"deletedAt" => at}

  # Settling is "I'm done with this": it parks the thread, clears its pinned and active
  # places and ends its snooze (thread.unsnoozed).
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
  # changes nothing, except that a user or agent brings back a stack layer they unlinked;
  # a link the MC made on its own (`"automatic"`, `HalC2.PullRequests.Opened`) never does.
  # A first manual link keeps the branch's pull request beside it.
  defp thread_fields("thread.pull-request.link", command, thread, at) do
    links = PullRequests.of(thread)
    key = PullRequests.key(command)
    existing = Enum.find(links, &(PullRequests.key(&1) == key))
    source = command["source"]

    if existing &&
         (existing["source"] != "stack-dismissed" or source in ["stack", "stack-dismissed"] or
            command["automatic"] == true) do
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

  # A layer of a native stack, or a pull request the thread created, stays as a
  # tombstone, so the sync or discovery (`HalC2.PullRequests.Opened`) does not link it
  # again. It forgets what the thread heard of it, so a link back starts from a new
  # baseline.
  defp thread_fields("thread.pull-request.unlink", command, thread, at) do
    links = PullRequests.of(thread)
    key = PullRequests.normalize(command)
    existing = Enum.find(links, &(PullRequests.normalize(&1) == key))

    tombstone? =
      existing != nil and
        (existing["source"] in ["stack", "created"] or existing["stack"] != nil or
           Enum.any?(links, fn link ->
             Map.delete(PullRequests.normalize(link), "number") == Map.delete(key, "number") and
               Enum.any?((link["stack"] || %{})["layers"] || [], &(&1["number"] == key["number"]))
           end))

    cond do
      existing == nil or existing["source"] == "stack-dismissed" ->
        %{}

      tombstone? ->
        links
        |> Enum.map(fn link ->
          if link == existing,
            do: link |> Map.put("source", "stack-dismissed") |> Map.delete("heard"),
            else: link
        end)
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
  # thread's wake time, and turning it off clears a wake time it set. The messages the
  # stop held in the queue wait behind it and do not stand in the way; one queued since
  # (it would start on its own) does.
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
    run = HalC2.Projection.Shell.latest_run(runs)

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
          Enum.any?(runs, &(&1["status"] == "queued" and &1["queueHeld"] != true)) ->
        {:error, "The provider limit changed before recovery could be configured."}

      true ->
        :ok
    end
  end

  defp titled(%{"title" => title}, _command) when is_binary(title) and title != "", do: title
  defp titled(_thread, command), do: "Thread #{command["threadId"]}"

  # Commands the thread's state refuses; nil to go ahead.
  # These two reach the user as they are, so they name the thread by its title.
  defp refusal("thread.archive", command, %{"archivedAt" => archived} = thread, _state)
       when archived != nil,
       do: {:error, "#{titled(thread, command)} is already archived."}

  defp refusal("thread.unarchive", command, thread, _state) do
    if thread["archivedAt"] == nil, do: {:error, "#{titled(thread, command)} is not archived."}
  end

  # An archived thread is out of the lists these arrange; unarchiving brings it back.
  defp refusal(type, command, %{"archivedAt" => archived}, _state)
       when type in @organizing and archived != nil,
       do: {:error, "Thread #{command["threadId"]} is archived."}

  # Only a pinned thread has a place among the pinned, so a reorder that races an unpin
  # cannot pin the thread again; only an active thread has a place in the active list.
  defp refusal("thread.pin.reorder", command, thread, _state) do
    if thread["pinnedAt"] == nil,
      do: {:error, "Thread #{command["threadId"]} is not pinned and cannot be reordered."}
  end

  defp refusal("thread.active.reorder", command, thread, _state) do
    if thread["pinnedAt"] != nil or thread["settledOverride"] == "settled",
      do: {:error, "Thread #{command["threadId"]} is not active and cannot be reordered."}
  end

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

  # Switching a thread with a conversation to another provider hands the
  # conversation over as context; a provider that cannot receive one refuses
  # the switch in its name.
  defp refusal(type, command, thread, state)
       when type in ["provider.switch", "thread.model-selection.set"] do
    target = get_in(command, ["modelSelection", "instanceId"])
    current = thread["providerInstanceId"] || get_in(thread, ["modelSelection", "instanceId"])

    conversation? =
      thread["activeProviderThreadId"] != nil or
        StreamState.get(state, "provider-thread") != %{}

    if is_binary(target) and target != current and conversation? do
      case HalC2.Orchestration.CommandPolicy.ensure(target, :context_handoff) do
        :ok -> nil
        {:error, message} -> {:error, message}
      end
    end
  end

  defp refusal(_type, _command, _thread, _state), do: nil

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

  # A message the MC sent for the agent (`message_item/6`), also one stored before such
  # messages carried a `notification`.
  defp agent_message?(message),
    do: message["notification"] != nil or message["delegatedCompletion"] != nil

  # A queued message the MC sent for the agent is not the user's to rewrite or steer
  # with: it is what the agent is told, and when.
  defp users_run(state, run_id) do
    with %{"status" => "queued", "userMessageId" => message_id} <-
           StreamState.get(state, "run")[run_id],
         %{} = message <- StreamState.get(state, "message")[message_id],
         true <- agent_message?(message) do
      {:error, "Queued run #{run_id} is the agent's own message, not one to edit or steer with."}
    else
      _ -> :ok
    end
  end

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
  # activity either: the thread's last activity time stays put.
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
    |> Enum.sort_by(&{&1["queuePosition"] || 0, &1["ordinal"] || 0})
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

    # A deleted thread runs nothing more; an archived one nothing from its queue until it is
    # unarchived and the queue resumed or another turn ends. A moving or moved
    # thread starts nothing here either: this is the transaction that starts a
    # run, so the guard cannot be raced by a move marked after an earlier
    # caller's check (a refused promote's interrupt, say).
    with true <-
           thread != nil and thread["deletedAt"] == nil and thread["archivedAt"] == nil and
             thread["moving"] == nil and thread["movedTo"] == nil,
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

      reason = handoff_refusal(state, thread, command) ->
        {[], {:error, reason}}

      get_in(command, ["dispatchMode", "type"]) == "defer_start" ->
        prepare_run(state, thread, runs, command)

      # A steer or restart aimed at a run that is not the active one is a
      # delivery no provider can make as asked.
      untargeted = untargeted_delivery(runs, command) ->
        {[], {:error, untargeted}}

      active = Enum.find(runs, &(&1["status"] in @active_statuses)) ->
        intent = command["deliveryIntent"]
        mode = get_in(command, ["dispatchMode", "type"])
        steer = intent == "steer" or mode == "steer_active"
        instance = message_instance(thread, command)
        active_instance = active["providerInstanceId"] || instance

        # Steer a running turn that can take it,
        # else queue; a restart (or a steer that cannot be) interrupts and goes first.
        auto_steer =
          intent in [nil, "auto"] and mode != "queue_after_active" and
            active["status"] in ["running", "waiting"]

        cond do
          intent == "restart" or mode == "restart_active" ->
            case HalC2.Orchestration.CommandPolicy.decide_steering(active_instance, true) do
              {:ok, _} -> queue_run(state, thread, runs, command, active["id"])
              {:error, message} -> {[], {:error, message}}
            end

          (steer or auto_steer) and steerable?(active, instance) ->
            reserve_steer(state, active, command)

          steer ->
            case HalC2.Orchestration.CommandPolicy.decide_steering(active_instance, false) do
              {:ok, _} -> queue_run(state, thread, runs, command, active["id"])
              {:error, message} -> {[], {:error, message}}
            end

          true ->
            with :ok <-
                   HalC2.Orchestration.CommandPolicy.ensure(instance, :queued_messages),
                 :ok <-
                   HalC2.Orchestration.CommandPolicy.ensure(
                     instance,
                     :strong_terminal_status
                   ) do
              queue_run(state, thread, runs, command, nil)
            else
              {:error, message} -> {[], {:error, message}}
            end
        end

      true ->
        new_run(state, thread, runs, command)
    end
  end

  # A steer or restart naming a run other than the active one (or naming one
  # when nothing runs) cannot be delivered as asked, whatever the provider.
  defp untargeted_delivery(runs, command) do
    mode = get_in(command, ["dispatchMode", "type"])
    target = get_in(command, ["dispatchMode", "targetRunId"])
    active = Enum.find(runs, &(&1["status"] in @active_statuses))

    if mode in ["steer_active", "restart_active"] and is_binary(target) and
         (active == nil or active["id"] != target) do
      instance =
        get_in(command, ["modelSelection", "instanceId"]) ||
          (active && active["providerInstanceId"]) || "codex"

      HalC2.Orchestration.UserFacingErrors.unsupported_delivery_message(instance)
    end
  end

  # A message naming another provider instance hands the conversation over as
  # context at its turn; one that cannot receive a handoff refuses the message.
  defp handoff_refusal(state, thread, command) do
    target = get_in(command, ["modelSelection", "instanceId"])
    current = thread["providerInstanceId"] || get_in(thread, ["modelSelection", "instanceId"])

    if is_binary(target) and target != current and
         StreamState.get(state, "provider-thread") != %{} do
      case HalC2.Orchestration.CommandPolicy.ensure(target, :context_handoff) do
        :ok -> nil
        {:error, message} -> message
      end
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
  # once its session exists; a new thread takes the other model (the transition is
  # refused).
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

  # A message whose run waits for its workspace (`release_prepared/2`). The thread
  # shows the user's message, then a "Preparing workspace" item that the
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

    user_item = message_item(ids, message_id, ordinal, at, command, "turn_start")

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
      provider_thread: Entities.provider_thread_id(instance, thread["id"]),
      message: message_id
    }

    queued = queued_runs(state)
    position = if restart_of, do: 0, else: length(queued) + 1

    # Above every other run until it starts (`start_ordinal/3`).
    ordinal = Enum.max(Enum.map(runs, &(&1["ordinal"] || 0)), fn -> 0 end) + 1

    run =
      Entities.run(ids, ordinal, selection, at)
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

  # The changes that bring a thread from before each instance had its own provider
  # thread up to date. Then every instance of a driver kept its session under the
  # default instance's id (the driver's), and their runs named it. Each other instance
  # that ran there gets a provider thread of its own, which its runs (their attempts and
  # provider turns too) then name, so each resumes, forks and rewinds in its own home.
  # Their nodes, turn items and the checkpoint scope keep naming the old id on purpose:
  # nothing reads `providerThreadId` there (readers go through the run or provider turn),
  # and leaving them keeps the one-time rewrite small (`references/2`).
  # One whose own provider thread exists already keeps its runs where they were, as
  # runs of another instance's provider thread (`HalC2.Orchestration.Fork` gives them
  # the history). The default id is then the default instance's; its next run takes it
  # over (`new_run/5`). The provider thread is then marked `perInstance`, so later runs
  # skip the scan: from then on every run names its own instance's provider thread. One
  # this server made is `perInstance` from birth (`Entities.provider_thread/7`).
  defp relocated(state, driver, thread_id, at) do
    legacy_id = Entities.provider_thread_id(driver, thread_id)
    threads = StreamState.get(state, "provider-thread")
    legacy = threads[legacy_id]

    if legacy == nil or legacy["perInstance"] do
      []
    else
      owner = legacy["providerInstanceId"] || driver

      homeless =
        state
        |> StreamState.list("run")
        |> Enum.filter(&(&1["providerThreadId"] == legacy_id))
        |> Enum.group_by(&(&1["providerInstanceId"] || driver))
        |> Map.put_new(owner, [])
        |> Map.delete(driver)
        |> Map.reject(fn {instance, _} ->
          threads[Entities.provider_thread_id(instance, thread_id)]
        end)

      # Each takes its own provider session, made by its next run. The instance the
      # shared record was made for (`owner`, its `providerInstanceId`) takes the native
      # thread along: the old MC set that field only when it created the record, and a
      # later run on another instance either reused that instance's still-open session
      # or failed to resume, so for a thread this MC made the native thread stayed the
      # creator's. Do not derive the owner from the latest run instead; that would move
      # the native thread to an instance that never held it. Another instance starts a
      # new native thread, which the runs it had there are not in
      # (`nativeSinceRunOrdinal`).
      homes =
        for {instance, runs} <- homeless do
          id = Entities.provider_thread_id(instance, thread_id)
          session_id = Entities.provider_session_id(instance, thread_id)

          if instance == owner do
            create(
              "provider-thread",
              id,
              Map.merge(legacy, %{
                "id" => id,
                "providerSessionId" => session_id,
                "perInstance" => true
              })
            )
          else
            ran = for %{"activeAttemptId" => attempt} = run <- runs, attempt, do: run["ordinal"]
            last = Enum.max(ran, fn -> nil end)

            record =
              Entities.provider_thread(id, thread_id, session_id, last, at, driver, instance)
              |> Map.put("firstRunOrdinal", Enum.min(ran, fn -> nil end))
              |> Map.put("nativeSinceRunOrdinal", last && last + 1)

            create("provider-thread", id, record)
          end
        end

      runs =
        for {instance, runs} <- homeless,
            run <- runs,
            into: %{},
            do: {run["id"], Entities.provider_thread_id(instance, thread_id)}

      marked = upsert(state, "provider-thread", legacy_id, &Map.put(&1, "perInstance", true))
      homes ++ if(runs == %{}, do: [], else: references(state, runs)) ++ [marked]
    end
  end

  # Points the relocated runs, their attempts and their provider turns at their new
  # provider threads; nodes and turn items stay as they were (`relocated/4`).
  defp references(state, runs) do
    attempts =
      for {id, attempt} <- StreamState.get(state, "run-attempt"),
          to = runs[attempt["runId"]],
          into: %{},
          do: {id, to}

    turns =
      for {id, turn} <- StreamState.get(state, "provider-turn"),
          to = attempts[turn["runAttemptId"]],
          do: {id, to}

    for {kind, refs} <- [{"run", runs}, {"run-attempt", attempts}, {"provider-turn", turns}],
        {id, to} <- refs,
        change = upsert(state, kind, id, &Map.put(&1, "providerThreadId", to)),
        do: change
  end

  # `state` with `changes` made, for what is decided after them in the same commit.
  # Every change replays at `state.seq`: safe only while
  # `StreamState.apply_event/2` neither dedupes nor orders by seq and the
  # result's `created`/`changed` stamps go unread before commit.
  defp applied(state, changes) do
    Enum.reduce(changes, state, fn {kind, id, patch}, state ->
      StreamState.apply_event(state, %{seq: state.seq, kind: kind, entity: id, patch: patch})
    end)
  end

  # Starts a run for a message: a new one, or a queued run (with its stored message
  # as `command`), which keeps its ids and takes the next ordinal (`start_ordinal/3`).
  defp new_run(state, thread, runs, command, queued \\ nil) do
    at = Entities.now()
    thread_id = thread["id"]
    {ordinal, renumbered} = start_ordinal(state, runs, queued)

    selection =
      (queued && queued["modelSelection"]) || command["modelSelection"] ||
        thread["modelSelection"]

    instance = selection["instanceId"] || thread["providerInstanceId"] || "codex"
    driver = driver_for(instance)
    provider_thread_id = Entities.provider_thread_id(instance, thread_id)
    session_id = Entities.provider_session_id(instance, thread_id)
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

    # Everything below, the handoff's plan included, sees the thread brought up to date.
    legacy_changes = relocated(state, driver, thread_id, at)
    state = applied(state, legacy_changes)
    provider_thread = StreamState.get(state, "provider-thread")[provider_thread_id]

    # The default instance's id still holds another instance's session (see
    # `relocated/4`): the run takes it over and starts its own.
    foreign =
      provider_thread != nil and
        (provider_thread["providerInstanceId"] || driver) != instance

    provider_thread = if foreign, do: nil, else: provider_thread
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

    # A session made by an older server takes on what this one can do, and the
    # instance that now runs it. One another instance had under the default id is that
    # instance's (its model, its last error): the run taking the id over replaces it.
    session_change =
      cond do
        foreign ->
          upsert(state, "provider-session", session_id, fn _ -> fresh_session end)

        StreamState.get(state, "provider-session")[session_id] ->
          upsert(
            state,
            "provider-session",
            session_id,
            # A session stopped while idle is ready again.
            &Map.merge(&1, %{
              "capabilities" => fresh_session["capabilities"],
              "status" => "ready",
              "cwd" => cwd,
              "providerInstanceId" => instance
            })
          )

        true ->
          create("provider-session", session_id, fresh_session)
      end

    # Its earlier runs' native turns are in the native thread it no longer has
    # (`HalC2.Orchestration.Fork`).
    taken_over =
      if foreign,
        do: %{
          "providerInstanceId" => instance,
          "nativeThreadRef" => nil,
          "nativeSinceRunOrdinal" => ordinal
        },
        else: %{}

    provider_changes =
      if provider_thread || foreign do
        [
          session_change,
          upsert(
            state,
            "provider-thread",
            provider_thread_id,
            # A rolled-back head is where this run resumes the conversation.
            &(&1
              |> Map.merge(%{
                "lastRunOrdinal" => ordinal,
                "providerSessionId" => session_id,
                "nativeConversationHeadRef" => nil
              })
              |> Map.merge(taken_over)
              |> Map.drop(if(foreign, do: ["carriedSession"], else: [])))
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

    # A run on another provider takes the thread over, as `provider.switch` would: a
    # client's switch can be missing or stale when it sent behind sends still in flight.
    switch_change =
      if instance != message_instance(thread, %{}),
        do:
          upsert(
            state,
            "thread",
            thread_id,
            &Map.merge(
              &1,
              thread_fields("provider.switch", %{"modelSelection" => selection}, &1, at)
            )
          )

    text = command["text"] || ""

    changes =
      Enum.reject(legacy_changes ++ provider_changes ++ [scope_change, switch_change], &is_nil/1)
      |> Kernel.++(renumbered)
      |> Kernel.++(
        [
          if(queued,
            do:
              upsert(
                state,
                "run",
                ids.run,
                # Started, so no longer held, whatever path brought it here:
                # `Shell.held_never_started?/1` reads a started-then-cancelled
                # run's stale hold as never-started.
                &Map.merge(
                  &1,
                  Entities.run(ids, ordinal, selection, at)
                  |> Map.drop(["requestedAt"])
                  |> Map.put("queueHeld", false)
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
            message_item(
              ids,
              message_id,
              # A prepared run's message was shown while its workspace was prepared.
              (StreamState.get(state, "turn-item")["turn-item:user:#{message_id}"] || %{})[
                "ordinal"
              ] || next_ordinal(state),
              at,
              command,
              if(queued && queued["status"] == "queued", do: "queued_turn", else: "turn_start")
            )
          )
        ]
        |> Enum.reject(&is_nil/1)
      )

    handoff =
      HalC2.Orchestration.Handoff.plan(state, provider_thread, ids, ordinal, at)

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

  # Runs are numbered in the order they leave the queue, which is what checkpoints (ref
  # `ordinal - 1` is a run's baseline), handoff deltas and windows count by: a run
  # takes the ordinal after every run that left the queue, and the runs still waiting
  # (a held queue a newer message passed, say) move up behind it in queue order.
  # Without a hold nothing moves: the queue's first run already has the next ordinal.
  # A run cancelled while queued left it too, so it keeps its number, and the run after
  # it has no checkpoint at `ordinal - 1` to start from. Dense numbering is a
  # conscious cost: every pass over a waiting queue of N renumbers all N (each
  # shifted ordinal is a real diff, so the unchanged-diff filter does not help),
  # which is fine for realistic queue sizes; numbering waiting runs with
  # headroom would trade that for gaps in queued ordinals.
  defp start_ordinal(state, runs, run) do
    own = run && run["id"]

    {waiting, left} =
      runs |> Enum.reject(&(&1["id"] == own)) |> Enum.split_with(&(&1["status"] == "queued"))

    ordinal = Enum.max(Enum.map(left, &(&1["ordinal"] || 0)), fn -> 0 end) + 1

    renumbered =
      for {queued, next} <-
            waiting
            |> Enum.sort_by(&{&1["queuePosition"] || 0, &1["ordinal"] || 0})
            |> Enum.with_index(ordinal + 1),
          change = upsert(state, "run", queued["id"], &Map.put(&1, "ordinal", next)),
          do: change

    {ordinal, renumbered}
  end

  # A message that implements a proposed plan completes it, whether the plan is this
  # thread's or another thread's of the same project ("Implement in a new thread"),
  # and whether the message started, queued or steered a run.
  defp implemented_plan(thread_id, %{"threadId" => plan_thread, "planId" => plan_id})
       when is_binary(plan_thread) do
    project = fn state, id -> (StreamState.get(state, "thread")[id] || %{})["projectId"] end
    project_id = project.(HalC2.Streams.state(thread_id), thread_id)

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
