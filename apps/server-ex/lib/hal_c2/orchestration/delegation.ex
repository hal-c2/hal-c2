defmodule HalC2.Orchestration.Delegation do
  @moduledoc """
  Delegated tasks: child work a running thread hands to a subagent through MCP
  (`delegate_task`, `task_status`, `task_cancel`).

  A task is a new thread marked as a subagent of the caller, started with only the
  task prompt, on the caller's provider unless the task names another. The caller's
  thread records it as a `subagent` entity, node, and turn item, so the task shows
  in its timeline. When the child's run ends (`finished/3`), the entity takes the
  child's last answer, and the caller hears about it: an async task (`always`)
  sends the result as a message that runs once the caller is free, and a waiting
  one (`settled_only`) only when the caller's own run is already over.
  """

  require Logger

  alias HalC2.{Orchestration, StreamState}
  alias HalC2.Orchestration.Entities

  @active ~w(preparing starting running waiting)
  @terminal ~w(completed failed interrupted cancelled)
  @runtime_ranks %{
    "approval-required" => 0,
    "auto-accept-edits" => 1,
    "auto" => 2,
    "full-access" => 3
  }

  @doc "`delegate_task` for the caller thread `row` (a sidebar row) on provider `instance`."
  def delegate(row, instance, input) do
    parent = stream(row["id"])
    thread = StreamState.get(parent, "thread")[row["id"]]

    run =
      parent
      |> StreamState.list("run")
      |> Enum.filter(&(&1["status"] in @active))
      |> Enum.max_by(&(&1["ordinal"] || 0), fn -> nil end)

    with :ok <- task_given(input["task"]),
         :ok <- if(run && run["providerInstanceId"] == instance, do: :ok, else: not_active()),
         {:ok, selection} <- target(thread, input["target"]),
         {:ok, runtime} <- mode(thread["runtimeMode"], input["runtimeMode"], :runtime),
         {:ok, interaction} <-
           mode(thread["interactionMode"], input["interactionMode"], :interaction),
         {:ok, workspace} <- resolve_workspace(thread, input["workspace"]) do
      spec = %{
        "task" => input["task"],
        "workspace" => workspace,
        "title" => input["title"],
        "modelSelection" => selection,
        "runtimeMode" => runtime,
        "interactionMode" => interaction,
        "completionWake" => if(input["mode"] == "wait", do: "settled_only", else: "always"),
        "createdBy" => "agent",
        "creationSource" => "mcp"
      }

      case start(thread, run, spec) do
        {:ok, task_id} ->
          if input["mode"] == "wait",
            do: wait(thread["id"], task_id, wait_budget(input["timeoutMs"])),
            else: {:ok, status(thread["id"], task_id)}

        {:error, message} ->
          {:error, "task_not_started", message}
      end
    end
  end

  @doc """
  `delegated_task.request`: starts a task for the parent's active run as
  `delegate_task` does, for a client or the engine. Without `completionWake` the
  result only wakes the parent once its own run is over (`settled_only`).
  """
  def request(%{"parentThreadId" => parent_id, "parentRunId" => run_id} = command) do
    parent = stream(parent_id)
    thread = StreamState.get(parent, "thread")[parent_id]
    run = StreamState.get(parent, "run")[run_id]

    with %{} <- thread || {:error, "Thread #{parent_id} was not found."},
         :ok <- task_given(command["task"]),
         :ok <- if(run && run["status"] in @active, do: :ok, else: not_active()),
         {:ok, runtime} <- mode(thread["runtimeMode"], command["runtimeMode"], :runtime),
         {:ok, interaction} <-
           mode(thread["interactionMode"], command["interactionMode"], :interaction),
         {:ok, workspace} <- resolve_workspace(thread, command["workspace"]) do
      with {:ok, _task_id} <-
             start(thread, run, %{
               "task" => command["task"],
               "workspace" => workspace,
               "title" => command["title"],
               "modelSelection" => command["modelSelection"] || thread["modelSelection"],
               "runtimeMode" => runtime,
               "interactionMode" => interaction,
               "completionWake" => command["completionWake"] || "settled_only",
               "createdBy" => command["createdBy"] || "user",
               "creationSource" => command["creationSource"] || "web"
             }),
           do: :ok
    else
      {:error, _code, message} -> {:error, message}
      {:error, _} = error -> error
    end
  end

  @doc """
  `delegated_task.wake-policy`: whether the task's result wakes the parent while
  it is busy (`always`) or only once it is idle (`settled_only`). The policy is
  read when the child's run ends.
  """
  def wake_policy(%{"parentThreadId" => parent_id, "taskId" => task_id, "completionWake" => wake}) do
    case subagent(parent_id, task_id) do
      %{"origin" => "app_owned", "completionWake" => ^wake} ->
        {:error,
         "Delegated task #{task_id} already wakes the parent with completionWake #{wake}."}

      %{"origin" => "app_owned"} ->
        update(parent_id, task_id, %{"completionWake" => wake})

      _ ->
        not_app_owned(parent_id, task_id)
    end
  end

  @doc """
  `delegated_task.completion-delivery.acknowledge` / `.dispose`: the caller saw the
  task's result (naming the run that read it), or no longer wants it. Either way a
  result message still queued behind the caller's run is cancelled, so the result
  is not delivered again. Repeating either is a no-op.
  """
  def resolve_delivery(
        %{"type" => type, "parentThreadId" => parent_id, "taskId" => task_id} = command
      ) do
    state = if type =~ "acknowledge", do: "acknowledged", else: "disposed"

    case subagent(parent_id, task_id) do
      %{"origin" => "app_owned", "completionDelivery" => %{"state" => current}}
      when current == state or (current == "disposed" and state == "acknowledged") ->
        :ok

      %{"origin" => "app_owned"} ->
        observed = if state == "acknowledged", do: command["observedByRunId"]

        :ok =
          update(parent_id, task_id, %{
            "completionDelivery" => %{"state" => state, "observedByRunId" => observed}
          })

        cancel_delivery(parent_id, task_id)

      _ ->
        not_app_owned(parent_id, task_id)
    end
  end

  @doc """
  `notification.delivery.accept`: the provider took a delegated task result
  message into its turn. Recorded on the message (`delegatedCompletion.acceptedAt`),
  apart from the task's own delivery state, which says whether the agent read it.
  """
  def accept_delivery(%{"threadId" => thread_id, "messageId" => message_id}) do
    HalC2.Streams.transact(thread_id, :thread, fn state ->
      case StreamState.get(state, "message")[message_id] do
        %{"delegatedCompletion" => %{"acceptedAt" => nil}} ->
          at = Entities.now()

          {[
             Orchestration.upsert(state, "message", message_id, fn message ->
               message
               |> put_in(["delegatedCompletion", "acceptedAt"], at)
               |> Map.put("updatedAt", at)
             end)
           ], :ok}

        _ ->
          {[], :ok}
      end
    end)
  end

  @doc "How long a `mode: \"wait\"` call waits for `timeout_ms`: 1 ms to an hour, 10 minutes by default."
  def wait_budget(timeout_ms), do: min(max(number(timeout_ms, 600_000), 1), 3_600_000)

  @doc "`task_status`: a task of the caller thread `thread_id`."
  def task_status(thread_id, task_id) do
    case status(thread_id, task_id) do
      nil -> {:error, "task_not_found", "The task was not found for this thread."}
      task -> {:ok, task}
    end
  end

  @doc "`task_cancel`: interrupts a running task; its result, if any, stays."
  def cancel(thread_id, task_id) do
    with %{} = task <-
           subagent(thread_id, task_id) ||
             {:error, "task_not_found", "The task was not found for this thread."},
         # Settled before the child is interrupted, so the report of the interrupted run
         # finds the task ended and wakes nobody; a task that ended meanwhile is not
         # cancelled.
         {:settled, _, _} <-
           settle(thread_id, task, "cancelled", task["result"], "disposed", :once) do
      hook(:cancelling, task_id)

      _ =
        Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => task["childThreadId"]})

      {:ok, status(thread_id, task_id)}
    else
      :already -> {:error, "task_not_cancellable", "The task has already finished."}
      error -> error
    end
  end

  @doc "Called when a run of `thread_id` ends: settles a subagent's task once it is quiet (`settle_if_quiet/1`)."
  def finished(thread_id, _run_id, _status), do: settle_if_quiet(thread_id)

  @doc """
  Settles the task `thread_id` works on, once the child is quiet: no run active or
  queued, and no background work it still owes (`BackgroundWork.derive/1`, the
  sidebar's Waiting pill). Until then the task works on, however many turns the
  child takes. It ends as the child's last run that was not rolled back did, with
  the child's last answer in such a run, and wakes the caller once.

  Called at the end of each child run, when a task of the child's settles (it may
  have been all the child waited on), when background work ends on a provider that
  does not wake itself for it, and periodically for children with no live provider
  process (`HalC2.Orchestration.IdleSessions`). Background work ending is not a
  reason to check on providers that wake themselves: their wake run is queued only
  after the work's item ended, and the child is not quiet until that run has ended.
  """
  def settle_if_quiet(thread_id) do
    child = stream(thread_id)

    with %{"lineage" => %{"relationshipToParent" => "subagent", "parentThreadId" => parent_id}} <-
           StreamState.get(child, "thread")[thread_id],
         %{} = task <-
           Enum.find(
             StreamState.list(stream(parent_id), "subagent"),
             &(&1["childThreadId"] == thread_id)
           ),
         true <- task["status"] not in @terminal,
         # A child that has not started its first run yet has not begun the task.
         [_ | _] = runs <- StreamState.list(child, "run"),
         true <- quiet?(child),
         {status, run, ended_at} <- last_end(runs) do
      result = answer(child) || preparation_failure(child, run)

      # A child found quiet twice (two runs' ends, a provider replaying its turn's end
      # after a reconnect, the periodic check racing a report) settles and wakes once:
      # only the call that finds the task unsettled delivers it. Whether it is delivered
      # is decided with the task's end, so a wait that times out meanwhile (`wait/3`)
      # either hears of the end or leaves the task to wake the caller. The result
      # message is recorded in the same transaction, so a crash cannot leave a task
      # delivered without it.
      with {:settled, "delivered", {:ok, _} = sent} <-
             settle(parent_id, task, status, result, &delivery/2, :once, ended_at, true),
           do: Orchestration.dispatched(parent_id, wake(parent_id, task, status, result), sent)

      # The task may have been the last thing its caller, itself a subagent, waited on.
      settle_if_quiet(parent_id)
    end

    :ok
  end

  @doc """
  `finished/3` from the end of a child's run, tried again while a thread it reads is
  too busy to answer, or it fails: a report given up on leaves the task to the periodic
  check (`settle_if_quiet/1`) or the next boot (`reconcile/2`). Retries `attempts` times, waiting twice as long each time from `backoff` ms.
  """
  def report(thread_id, run_id, status, attempts \\ 6, backoff \\ 2_000) do
    hook(:reporting, thread_id)
    finished(thread_id, run_id, status)
  catch
    _kind, reason when attempts > 0 ->
      Logger.warning("delegated task report for #{thread_id} retried: #{inspect(reason)}")
      Process.sleep(backoff)
      report(thread_id, run_id, status, attempts - 1, backoff * 2)
  end

  @doc """
  Settles the tasks `parent_id` delegated whose child stopped working without its end
  reaching the caller (a report lost to a crash or a restart): how the child's latest
  run ended (`last_end/1`) is how the task ended, and when. The caller is not woken;
  its turn is long over. Recovery calls it before interrupting any run, so a child
  still working when the MC stopped is not taken for one that ended, and again once
  the runs it continues have started. With `boot?`, a task whose child was never
  launched (the MC stopped between recording it and launching) failed; later a child
  may be about to launch, so Recovery leaves those out.
  Returns how many it settled.
  """
  def reconcile(parent_id, boot? \\ true) do
    for %{"origin" => "app_owned", "childThreadId" => child_id, "status" => status} = task <-
          StreamState.list(stream(parent_id), "subagent"),
        status not in @terminal and is_binary(child_id),
        {ended, run, ended_at, child} <- [stopped(child_id, boot?)],
        settle(
          parent_id,
          task,
          ended,
          if(run, do: answer(child)),
          "disposed",
          :once,
          ended_at
        ) != :already,
        reduce: 0 do
      count -> count + 1
    end
  end

  # How a child ended and when, with its state; nil while it works or has not run yet.
  defp stopped(child_id, boot?) do
    child = stream(child_id)
    runs = StreamState.list(child, "run")

    cond do
      boot? and StreamState.get(child, "thread")[child_id] == nil -> {"failed", nil, nil, child}
      runs == [] or not quiet?(child) -> nil
      true -> with {ended, run, at} <- last_end(runs), do: {ended, run, at, child}
    end
  end

  # How a child's work ended: its latest run that was not rolled back, by the
  # same pick as everywhere else (`Shell.latest_run/1` — a held run cancelled
  # while held never started, so the run that passed it is how it ended), or,
  # when the user rolled back every one, cancelled when the last was. Nil for a
  # status no task takes.
  defp last_end(runs) do
    case runs
         |> Enum.reject(&(&1["status"] == "rolled_back"))
         |> HalC2.Projection.Shell.latest_run() do
      %{"status" => ended} = run when ended in @terminal -> {ended, run, end_of(run)}
      nil -> {"cancelled", nil, end_of(latest(runs))}
      _ -> nil
    end
  end

  # Quiet: no run active or queued, and no background work owed. Persistent monitors
  # never finish, so they are not owed (`BackgroundWork`).
  defp quiet?(child), do: not working?(StreamState.list(child, "run")) and owed(child) == []

  # The child's owed background work, as its sidebar row shows it, read from its stream.
  defp owed(child) do
    runs = StreamState.list(child, "run")

    HalC2.Projection.BackgroundWork.derive(
      latest_run: HalC2.Projection.Shell.latest_run(runs),
      provider_threads: StreamState.list(child, "provider-thread"),
      turn_items: StreamState.list(child, "turn-item"),
      active_provider_thread_id:
        (HalC2.Projection.Timeline.thread(child) || %{})["activeProviderThreadId"],
      runs: runs
    )
  end

  defp working?(runs), do: Enum.any?(runs, &(&1["status"] in @active or &1["status"] == "queued"))

  # Runs stored without an ordinal read 0, as in `Shell.latest_run/1`; a bare
  # `max_by` would let `nil` win outright (it sorts above integers).
  defp latest(runs), do: Enum.max_by(runs, &(&1["ordinal"] || 0), fn -> nil end)
  defp end_of(run), do: run["completedAt"] || run["updatedAt"]

  # --- tasks -------------------------------------------------------------------------

  # Records the task in the parent, then launches the child thread; returns its id, or
  # why the child did not start, the task failed. The record comes first: a child turn
  # that ends at once reports to it. A launch the MC stopped in the middle of is
  # settled at the next boot (`reconcile/2`).
  defp start(thread, run, spec) do
    child_id = HalC2.Environment.uuid4()
    task_id = "node:subagent:" <> HalC2.Environment.uuid4()
    selection = spec["modelSelection"]

    title =
      spec["title"] || spec["task"] |> String.split("\n") |> hd() |> String.slice(0, 80)

    workspace = spec["workspace"] || {"inherited", workspace(thread)}

    record(
      thread,
      run,
      task_id,
      child_id,
      selection,
      title,
      spec["task"],
      spec["completionWake"],
      elem(workspace, 0)
    )

    launched =
      Orchestration.launch_thread(%{
        "commandId" => "command:delegate:#{task_id}",
        "threadId" => child_id,
        "projectId" => thread["projectId"],
        "title" => title,
        "modelSelection" => selection,
        "runtimeMode" => spec["runtimeMode"],
        "interactionMode" => spec["interactionMode"],
        "createdBy" => spec["createdBy"],
        "creationSource" => spec["creationSource"],
        "workspaceStrategy" => elem(workspace, 1),
        "lineage" => %{
          "parentThreadId" => thread["id"],
          "relationshipToParent" => "subagent",
          "rootThreadId" => get_in(thread, ["lineage", "rootThreadId"]) || thread["id"]
        },
        "initialMessage" => %{
          "messageId" => "message:delegate:" <> HalC2.Environment.uuid4(),
          "senderThreadId" => thread["id"],
          "text" => spec["task"],
          "attachments" => []
        }
      })

    case launched do
      {:ok, _} ->
        {:ok, task_id}

      {:error, reason} ->
        message = if is_binary(reason), do: reason, else: inspect(reason)
        settle(thread["id"], %{"id" => task_id}, "failed", message, "disposed")
        {:error, message}
    end
  end

  defp update(parent_id, task_id, fields) do
    HalC2.Streams.transact(parent_id, :thread, fn state ->
      {[
         Orchestration.upsert(state, "subagent", task_id, fn task ->
           Map.merge(task, Map.put(fields, "updatedAt", Entities.now()))
         end)
       ], :ok}
    end)
  end

  # The task's result message, while it still waits behind the caller's run.
  defp cancel_delivery(parent_id, task_id) do
    message_id = result_message_id(task_id)

    case Enum.find(
           StreamState.list(stream(parent_id), "run"),
           &(&1["userMessageId"] == message_id and &1["status"] == "queued")
         ) do
      nil ->
        :ok

      run ->
        {:ok, _} =
          Orchestration.dispatch(%{
            "type" => "queued-run.cancel",
            "threadId" => parent_id,
            "runId" => run["id"]
          })

        :ok
    end
  end

  defp result_message_id(task_id), do: "message:delegate-result:" <> task_id

  defp not_app_owned(parent_id, task_id),
    do: {:error, "Delegated task #{task_id} is not an app-owned task of thread #{parent_id}."}

  defp record(thread, run, task_id, child_id, selection, title, prompt, wake, workspace) do
    at = Entities.now()
    instance = selection["instanceId"]
    driver = Orchestration.driver_for(instance)
    item_id = "turn-item:subagent:#{task_id}"

    task = %{
      "id" => task_id,
      "threadId" => thread["id"],
      "runId" => run["id"],
      "parentNodeId" => run["rootNodeId"],
      "origin" => "app_owned",
      "createdBy" => "agent",
      "driver" => driver,
      "providerInstanceId" => instance,
      "providerThreadId" => nil,
      "childThreadId" => child_id,
      "nativeTaskRef" => nil,
      "prompt" => prompt,
      "title" => title,
      "model" => selection["model"],
      "completionWake" => wake,
      "workspace" => workspace,
      "completionDelivery" => %{"state" => "pending", "observedByRunId" => nil},
      "status" => "running",
      "result" => nil,
      "startedAt" => at,
      "completedAt" => nil,
      "updatedAt" => at
    }

    node = %{
      "id" => task_id,
      "threadId" => thread["id"],
      "runId" => run["id"],
      "parentNodeId" => run["rootNodeId"],
      "rootNodeId" => run["rootNodeId"],
      "kind" => "subagent",
      "status" => "running",
      "providerThreadId" => nil,
      "providerTurnId" => nil,
      "nativeItemRef" => nil,
      "runtimeRequestId" => nil,
      "checkpointScopeId" => nil,
      "countsForRun" => false,
      "startedAt" => at,
      "completedAt" => nil
    }

    HalC2.Streams.transact(thread["id"], :thread, fn state ->
      item =
        Entities.turn_item(
          %{
            thread: thread["id"],
            run: run["id"],
            root_node: run["rootNodeId"],
            node: task_id,
            provider_thread: nil,
            driver: driver
          },
          item_id,
          "subagent",
          Orchestration.next_ordinal(state),
          "running",
          at,
          %{
            "nodeId" => task_id,
            "subagentId" => task_id,
            "origin" => "app_owned",
            "driver" => driver,
            "providerInstanceId" => instance,
            "childThreadId" => child_id,
            "prompt" => prompt,
            "result" => nil
          }
        )

      {[
         Orchestration.create("subagent", task_id, task),
         Orchestration.create("node", task_id, node),
         Orchestration.create("turn-item", item_id, item)
       ], :ok}
    end)
  end

  # Ends the task in its parent, at `at` or now, and returns `{:settled, delivery, sent}`.
  # `delivery` is a state, or a function of the task and the parent's state that
  # decides it inside the transaction. With `:once`, a task that already ended is left
  # as it is and `:already` is returned, decided in the same transaction. With `wake?`,
  # a delivered result's message is recorded with the end, and `sent` is what
  # `Orchestration.decide_dispatch/3` decided for it.
  defp settle(
         parent_id,
         task,
         status,
         result,
         delivery,
         how \\ :always,
         at \\ nil,
         wake? \\ false
       ) do
    at = at || Entities.now()
    status = if status in @terminal, do: status, else: "completed"
    item_id = "turn-item:subagent:#{task["id"]}"

    HalC2.Streams.transact(parent_id, :thread, fn state ->
      finish = &Map.merge(&1, %{"status" => status, "completedAt" => at})
      current = StreamState.get(state, "subagent")[task["id"]] || %{}
      delivery = if is_function(delivery), do: delivery.(current, state), else: delivery

      {message, sent} =
        if wake? and delivery == "delivered",
          do:
            Orchestration.decide_dispatch(state, parent_id, wake(parent_id, task, status, result)),
          else: {[], nil}

      changes =
        (message ++
           [
             Orchestration.upsert(state, "subagent", task["id"], fn entity ->
               Map.merge(entity, %{
                 "status" => status,
                 "result" => result,
                 "completedAt" => at,
                 "updatedAt" => at,
                 "completionDelivery" => %{"state" => delivery, "observedByRunId" => nil}
               })
             end),
             Orchestration.upsert(state, "node", task["id"], finish),
             StreamState.get(state, "turn-item")[item_id] &&
               Orchestration.upsert(state, "turn-item", item_id, fn item ->
                 Map.merge(item, %{
                   "status" => status,
                   "result" => result,
                   "completedAt" => at,
                   "updatedAt" => at
                 })
               end)
           ])
        |> Enum.reject(&(&1 in [nil, false]))

      if how == :once and current["status"] in @terminal,
        do: {[], :already},
        else: {changes, {:settled, delivery, sent}}
    end)
  end

  # Whether a finished task's result reaches the caller as a message: not once disposed,
  # when the task always wakes it, or when it is idle; else it is only acknowledged,
  # which is the caller's wait reading it (`wait/3`).
  defp delivery(task, parent_state) do
    cond do
      task["completionDelivery"]["state"] == "disposed" -> "disposed"
      task["completionWake"] == "always" or idle?(parent_state) -> "delivered"
      true -> "acknowledged"
    end
  end

  # The parent hears the result as a message that runs once it is free. The
  # message carries which task it delivers (`delegatedCompletion`), so the
  # provider's acceptance and a later dispose can find it, and what the user is
  # shown in place of its text (`notification`): that the task ended, and how.
  defp wake(parent_id, task, status, result) do
    {outcome, ended} =
      case status do
        "completed" -> {"completed", "finished"}
        "failed" -> {"failed", "failed"}
        _ -> {"cancelled", "stopped"}
      end

    label = String.trim(task["title"] || "")
    label = if label == "", do: "Delegated task", else: label

    answer = result || "(no answer)"
    child = task["childThreadId"]

    text = """
    <delegated_task_result taskId="#{attr(task["id"])}" title="#{attr(task["title"])}" status="#{attr(status)}" childThreadId="#{attr(child)}">
    #{cap_result(answer, child)}
    </delegated_task_result>
    """

    %{
      "type" => "message.dispatch",
      "commandId" => "command:delegate-result:#{task["id"]}",
      "threadId" => parent_id,
      "messageId" => result_message_id(task["id"]),
      "text" => String.trim(text),
      "attachments" => [],
      "createdBy" => "system",
      "creationSource" => "server",
      "dispatchMode" => %{"type" => "queue_after_active"},
      "notification" => %{
        "source" => %{"kind" => "delegated_task", "taskIds" => [task["id"]]},
        "outcome" => outcome,
        "summary" => "#{label} #{ended}",
        "workerThreadId" => child,
        "workerTitle" => label,
        "detail" => cap_result(answer, child)
      },
      "delegatedCompletion" => %{
        "parentRunId" => task["runId"],
        "taskIds" => [task["id"]],
        "acceptedAt" => nil
      }
    }
  end

  # How much of a worker's answer the provider prompt and the timeline notification
  # carry; the rest stays readable in the worker's own thread.
  @result_cap 8_192

  defp cap_result(text, child) when byte_size(text) > @result_cap do
    kept = text |> binary_part(0, @result_cap) |> trim_invalid()

    kept <>
      "\n\n[result truncated at #{@result_cap} bytes; read the rest with hal_c2_thread_read on thread #{child}]"
  end

  defp cap_result(text, _child), do: text

  # A byte cut can split a UTF-8 character; drop the broken tail.
  defp trim_invalid(text) do
    if String.valid?(text),
      do: text,
      else: trim_invalid(binary_part(text, 0, byte_size(text) - 1))
  end

  defp attr(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\n", "&#10;")
    |> String.replace("\r", "&#13;")
  end

  defp status(thread_id, task_id) do
    with %{} = task <- subagent(thread_id, task_id) do
      child = stream(task["childThreadId"])
      runs = StreamState.list(child, "run") |> Enum.sort_by(&(&1["ordinal"] || 0))
      # Live, not recorded with the task: the branch is renamed after the worktree exists.
      thread = StreamState.get(child, "thread")[task["childThreadId"]] || %{}
      pending = working?(runs)

      work_state =
        cond do
          task["status"] in @terminal -> "result_available"
          pending -> "working"
          owed(child) != [] -> "waiting_for_children"
          true -> "working"
        end

      %{
        "taskId" => task["id"],
        "childThreadId" => task["childThreadId"],
        "childRunId" => runs |> List.first(%{}) |> Map.get("id"),
        "title" => task["title"],
        "providerInstanceId" => task["providerInstanceId"],
        "model" => task["model"],
        "status" => task["status"],
        "workState" => work_state,
        "summary" => task["result"],
        "hasPendingChildRuns" => pending,
        "startedAt" => task["startedAt"],
        "completedAt" => task["completedAt"],
        "workspace" => task["workspace"],
        "worktreePath" => thread["worktreePath"],
        "branch" => thread["branch"]
      }
    end
  end

  defp subagent(thread_id, task_id), do: StreamState.get(stream(thread_id), "subagent")[task_id]

  @doc "Waits for the task to end; a timeout leaves it running and returns its state."
  def wait(thread_id, task_id, timeout) do
    :ok = HalC2.Streams.watch(thread_id, self())
    deadline = System.monotonic_time(:millisecond) + timeout

    try do
      wait_loop(thread_id, task_id, deadline)
    after
      HalC2.Streams.Server.unsubscribe(thread_id, self())
    end
  end

  defp wait_loop(thread_id, task_id, deadline) do
    task = status(thread_id, task_id)
    left = deadline - System.monotonic_time(:millisecond)

    cond do
      task["status"] in @terminal ->
        {:ok, task}

      left <= 0 ->
        hook(:expiring, task_id)

        case expire(thread_id, task_id) do
          :expired -> {:ok, Map.put(task, "waitTimedOut", true)}
          :ended -> {:ok, status(thread_id, task_id)}
        end

      true ->
        receive do
          {:hal_c2_stream, ^thread_id, _} -> wait_loop(thread_id, task_id, deadline)
        after
          min(left, 5_000) -> wait_loop(thread_id, task_id, deadline)
        end
    end
  end

  # The wait is over: a child that ends from now on wakes the caller. A task that ended
  # meanwhile was acknowledged to this wait, so it is answered with that end instead;
  # `finished/3` and this decide in transactions of the same thread, one after the other.
  defp expire(thread_id, task_id) do
    HalC2.Streams.transact(thread_id, :thread, fn state ->
      case StreamState.get(state, "subagent")[task_id] do
        %{"status" => status} when status in @terminal ->
          {[], :ended}

        _ ->
          change =
            Orchestration.upsert(state, "subagent", task_id, fn task ->
              Map.merge(task, %{"completionWake" => "always", "updatedAt" => Entities.now()})
            end)

          {[change], :expired}
      end
    end)
  end

  # The child's last answer in a run that was not rolled back: a turn that only handled
  # a monitor update or a background task's end without a word does not replace it.
  defp answer(child) do
    kept =
      for run <- StreamState.list(child, "run"),
          run["status"] != "rolled_back",
          into: MapSet.new(),
          do: run["id"]

    child
    |> StreamState.list("message")
    |> Enum.filter(
      &(&1["role"] == "assistant" and MapSet.member?(kept, &1["runId"]) and
          String.trim(&1["text"] || "") != "")
    )
    |> List.last(%{})
    |> Map.get("text")
  end

  # Why a child that never started ended: its worktree could not be prepared, or the
  # preparation was cancelled. Nil for any other run, a queued one cancelled included.
  defp preparation_failure(child, %{"id" => run_id}) do
    items = StreamState.get(child, "turn-item")

    case {items["turn-item:workspace-preparation-failure:#{run_id}"],
          items["turn-item:workspace-preparation:#{run_id}"]} do
      {%{"failure" => %{"message" => message}}, _} -> "Workspace preparation failed: #{message}"
      {_, %{"status" => "cancelled"}} -> "Workspace preparation was cancelled."
      _ -> nil
    end
  end

  defp preparation_failure(_child, _run), do: nil

  defp idle?(state), do: not Enum.any?(StreamState.list(state, "run"), &(&1["status"] in @active))

  defp target(thread, nil), do: {:ok, thread["modelSelection"]}

  defp target(thread, target) do
    instance = target["providerInstanceId"] || get_in(thread, ["modelSelection", "instanceId"])

    case Enum.find(HalC2.Environment.providers(), &(&1["instanceId"] == instance)) do
      nil ->
        {:error, "provider_unavailable", "Provider #{instance} is not available on this MC."}

      provider ->
        model =
          target["model"] ||
            if(instance == get_in(thread, ["modelSelection", "instanceId"]),
              do: get_in(thread, ["modelSelection", "model"]),
              else: provider["models"] |> Enum.find(%{}, & &1["isDefault"]) |> Map.get("slug")
            )

        options =
          case target["options"] do
            %{} = map -> for {id, value} <- map, do: %{"id" => id, "value" => value}
            list when is_list(list) -> list
            _ -> nil
          end

        {:ok,
         %{"instanceId" => instance, "model" => model}
         |> then(&if(options, do: Map.put(&1, "options", options), else: &1))}
    end
  end

  # Inheriting never escalates, and a parent without a mode leaves the child its default.
  defp mode(parent, requested, _kind) when requested in [nil, "inherit"], do: {:ok, parent}

  defp mode(parent, requested, :runtime) do
    if Map.get(@runtime_ranks, requested, 3) > Map.get(@runtime_ranks, parent, 3),
      do:
        {:error, "runtime_mode_escalation_denied",
         "Child runtime mode #{requested} is broader than parent mode #{parent}."},
      else: {:ok, requested}
  end

  defp mode(parent, requested, :interaction) do
    if parent == "plan" and requested != "plan",
      do:
        {:error, "interaction_mode_escalation_denied",
         "Child interaction mode #{requested} is broader than parent mode plan."},
      else: {:ok, requested}
  end

  # What `workspace` asks for, as `{kind, launch strategy}`. Omitted, the child works
  # where the caller does. Anything else makes or points at a checkout, so it needs
  # the caller `hal_c2_thread_launch` needs, and is refused here, before anything is
  # created: a task never falls back to the caller's checkout.
  defp resolve_workspace(thread, nil), do: {:ok, {"inherited", workspace(thread)}}
  defp resolve_workspace(thread, %{"type" => "inherit"}), do: resolve_workspace(thread, nil)

  defp resolve_workspace(thread, %{"type" => type} = asked) do
    root = project_root(thread)

    cond do
      type == "existing_worktree" and is_binary(asked["worktreePath"]) and
          asked["worktreePath"] == thread["worktreePath"] ->
        resolve_workspace(thread, nil)

      thread["runtimeMode"] != "full-access" or thread["interactionMode"] != "default" ->
        {:error, "workspace_escalation_denied",
         "A task's own workspace needs a full-access/default calling thread."}

      is_nil(root) ->
        invalid("The project is not on this MC.")

      type == "root" ->
        {:ok, {"root", %{"type" => "root"}}}

      type == "worktree" ->
        new_worktree(thread, root, asked)

      type == "existing_worktree" ->
        existing_worktree(root, asked)

      true ->
        invalid("Unknown workspace type #{inspect(type)}.")
    end
  end

  defp resolve_workspace(_thread, _asked), do: invalid("workspace needs a type.")

  defp invalid(message), do: {:error, "workspace_invalid", message}

  defp project_root(thread) do
    case HalC2.Shell.row(node(), thread["projectId"]) do
      {"project", %{"workspaceRoot" => root}} when is_binary(root) -> root
      _ -> nil
    end
  end

  # A new worktree from `baseRef` (default: where the caller is, so its local commits
  # are in it) on `branch`, which must not exist yet.
  defp new_worktree(thread, root, asked) do
    from_origin = asked["startFromOrigin"] == true
    base = asked["baseRef"] || caller_ref(thread, root)
    branch = asked["branch"]

    cond do
      not is_binary(base) or not ref?(root, base, from_origin) ->
        invalid("The base ref #{inspect(base)} does not exist.")

      is_binary(branch) and not valid_branch?(root, branch) ->
        invalid("#{inspect(branch)} is not a usable branch name.")

      is_binary(branch) and
          (ref?(root, "refs/heads/" <> branch, false) or
             HalC2.Git.branch_path_taken?(root, branch) or
             File.exists?(HalC2.Vcs.worktree_path(root, branch))) ->
        invalid("The branch #{branch} already exists.")

      true ->
        {:ok,
         {"worktree",
          %{
            "type" => "worktree",
            "baseRef" => base,
            "branch" => branch,
            "startFromOrigin" => from_origin
          }}}
    end
  end

  defp existing_worktree(root, %{"worktreePath" => path} = asked) do
    cond do
      not is_binary(path) or Path.type(path) != :absolute ->
        invalid("worktreePath must be an absolute path.")

      not File.dir?(path) or common_dir(path) == nil or common_dir(path) != common_dir(root) ->
        invalid("#{path} is not a checkout of this project.")

      true ->
        branch = asked["branch"] || HalC2.Git.current_branch(path)

        {:ok,
         {"existing_worktree",
          %{"type" => "existing_worktree", "worktreePath" => path, "branch" => branch}}}
    end
  end

  # The caller's branch, or its commit when detached.
  defp caller_ref(thread, root) do
    cwd = thread["worktreePath"] || root

    thread["branch"] || HalC2.Git.current_branch(cwd) ||
      with {:ok, sha} <- HalC2.Git.ok(cwd, ~w(rev-parse HEAD)), do: String.trim(sha)
  end

  defp ref?(root, ref, from_origin) do
    Enum.any?(if(from_origin, do: [ref, "origin/" <> ref], else: [ref]), fn candidate ->
      match?(
        {:ok, _},
        HalC2.Git.ok(root, ["rev-parse", "--verify", "--quiet", candidate <> "^{commit}"])
      )
    end)
  end

  defp valid_branch?(root, branch),
    do: match?({:ok, _}, HalC2.Git.ok(root, ["check-ref-format", "--branch", branch]))

  # Two checkouts of one repository share a common git dir.
  defp common_dir(cwd) do
    case HalC2.Git.ok(cwd, ["rev-parse", "--path-format=absolute", "--git-common-dir"]) do
      {:ok, dir} -> String.trim(dir)
      _ -> nil
    end
  end

  # The child works where the parent does.
  defp workspace(%{"worktreePath" => path, "branch" => branch}) when is_binary(path),
    do: %{"type" => "existing_worktree", "worktreePath" => path, "branch" => branch}

  defp workspace(_thread), do: %{"type" => "root"}

  # The task is the child's whole first message, so a call without one (an agent that
  # called it `prompt`, say) is refused where the agent can read why. Otherwise the child
  # starts on an empty message and answers that it came through empty.
  defp task_given(task) do
    if is_binary(task) and String.trim(task) != "",
      do: :ok,
      else:
        {:error, "invalid_task",
         "Delegated tasks need a `task`: the full prompt for the child, as a non-empty string."}
  end

  defp not_active,
    do:
      {:error, "parent_not_active",
       "Delegated tasks require an active run owned by this MCP provider session."}

  defp stream(thread_id), do: HalC2.Streams.state(thread_id)

  defp number(value, _default) when is_number(value), do: round(value)
  defp number(_value, default), do: default

  # Tests pause or break a task at a stage: `{module, function, args}`, called with the
  # stage and the thread or task id.
  defp hook(stage, id) do
    case Application.get_env(:hal_c2, :delegation_hook) do
      {m, f, a} -> apply(m, f, a ++ [stage, id])
      nil -> :ok
    end
  end
end
