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
      |> Enum.max_by(& &1["ordinal"], fn -> nil end)

    with :ok <- if(run && run["providerInstanceId"] == instance, do: :ok, else: not_active()),
         {:ok, selection} <- target(thread, input["target"]),
         {:ok, runtime} <- mode(thread["runtimeMode"], input["runtimeMode"], :runtime),
         {:ok, interaction} <-
           mode(thread["interactionMode"], input["interactionMode"], :interaction) do
      task_id =
        start(thread, run, %{
          "task" => input["task"],
          "title" => input["title"],
          "modelSelection" => selection,
          "runtimeMode" => runtime,
          "interactionMode" => interaction,
          "completionWake" => if(input["mode"] == "wait", do: "settled_only", else: "always"),
          "createdBy" => "agent",
          "creationSource" => "mcp"
        })

      if input["mode"] == "wait" do
        wait(thread["id"], task_id, wait_budget(input["timeoutMs"]))
      else
        {:ok, status(thread["id"], task_id)}
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
         :ok <- if(run && run["status"] in @active, do: :ok, else: not_active()),
         {:ok, runtime} <- mode(thread["runtimeMode"], command["runtimeMode"], :runtime),
         {:ok, interaction} <-
           mode(thread["interactionMode"], command["interactionMode"], :interaction) do
      start(thread, run, %{
        "task" => command["task"],
        "title" => command["title"],
        "modelSelection" => command["modelSelection"] || thread["modelSelection"],
        "runtimeMode" => runtime,
        "interactionMode" => interaction,
        "completionWake" => command["completionWake"] || "settled_only",
        "createdBy" => command["createdBy"] || "user",
        "creationSource" => command["creationSource"] || "web"
      })

      :ok
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
         true <-
           task["status"] not in @terminal ||
             {:error, "task_not_cancellable", "The task has already finished."} do
      _ =
        Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => task["childThreadId"]})

      settle(thread_id, task, "cancelled", task["result"], "disposed")
      {:ok, status(thread_id, task_id)}
    end
  end

  @doc "Called when a run of `thread_id` ends: reports a subagent's result to its parent."
  def finished(thread_id, run_id, status) do
    child = stream(thread_id)

    with %{"lineage" => %{"relationshipToParent" => "subagent", "parentThreadId" => parent_id}} <-
           StreamState.get(child, "thread")[thread_id],
         %{} = task <-
           Enum.find(
             StreamState.list(stream(parent_id), "subagent"),
             &(&1["childThreadId"] == thread_id)
           ),
         true <- task["status"] not in @terminal,
         # A report that comes late (retried) finds the run as it is now: one the
         # user rolled back meanwhile ends the task as its other runs say.
         {status, run, ended_at} <- reported(child, run_id, status) do
      result = run && answer(child, run["id"])

      delivery =
        cond do
          task["completionDelivery"]["state"] == "disposed" -> "disposed"
          task["completionWake"] == "always" or idle?(parent_id) -> "delivered"
          true -> "acknowledged"
        end

      # A completion reported twice (a provider replaying its turn's end after a
      # reconnect, or two reports racing) settles and wakes once: only the report
      # that finds the task unsettled delivers it.
      with :ok <- settle(parent_id, task, status, result, delivery, :once, ended_at),
           true <- delivery == "delivered",
           do: wake(parent_id, task, status, result)
    end

    :ok
  end

  @doc """
  `finished/3` from the end of a child's run, tried again while a thread it reads is
  too busy to answer: a report given up on leaves the task running in its caller for
  good. Retries `attempts` times, waiting twice as long each time from `backoff` ms.
  """
  def report(thread_id, run_id, status, attempts \\ 6, backoff \\ 2_000) do
    finished(thread_id, run_id, status)
  catch
    :exit, reason when attempts > 0 ->
      Logger.warning("delegated task report for #{thread_id} retried: #{inspect(reason)}")
      Process.sleep(backoff)
      report(thread_id, run_id, status, attempts - 1, backoff * 2)
  end

  @doc """
  Settles the tasks `parent_id` delegated whose child stopped working without its end
  reaching the caller (a report lost to a crash or a restart): how the child's latest
  run ended (`last_end/1`) is how the task ended, and when. The caller is not woken;
  its turn is long over. Recovery calls it before interrupting any run, so a child
  still working when the MC stopped is not taken for one that ended.
  Returns how many it settled.
  """
  def reconcile(parent_id) do
    for %{"origin" => "app_owned", "childThreadId" => child_id, "status" => status} = task <-
          StreamState.list(stream(parent_id), "subagent"),
        status not in @terminal and is_binary(child_id),
        child = stream(child_id),
        runs = StreamState.list(child, "run"),
        runs != [],
        not Enum.any?(runs, &(&1["status"] in @active or &1["status"] == "queued")),
        {ended, run, ended_at} <- [last_end(runs)],
        settle(
          parent_id,
          task,
          ended,
          run && answer(child, run["id"]),
          "disposed",
          :once,
          ended_at
        ) ==
          :ok,
        reduce: 0 do
      count -> count + 1
    end
  end

  # How a child's work ended: its latest run that was not rolled back, or, when the
  # user rolled back every one, cancelled when the last was. Nil for a status no
  # task takes.
  defp last_end(runs) do
    case runs |> Enum.reject(&(&1["status"] == "rolled_back")) |> latest() do
      %{"status" => ended} = run when ended in @terminal -> {ended, run, end_of(run)}
      nil -> {"cancelled", nil, end_of(latest(runs))}
      _ -> nil
    end
  end

  # How the reported run ended and when, not when its report got through; nil when
  # it was rolled back and the child is working again, whose next run reports.
  defp reported(child, run_id, status) do
    case StreamState.get(child, "run")[run_id] do
      %{"status" => "rolled_back"} -> last_end(StreamState.list(child, "run"))
      run -> {status, run || %{"id" => run_id}, run && run["completedAt"]}
    end
  end

  defp latest(runs), do: Enum.max_by(runs, & &1["ordinal"], fn -> nil end)
  defp end_of(run), do: run["completedAt"] || run["updatedAt"]

  # --- tasks -------------------------------------------------------------------------

  # Records the task in the parent, then launches the child thread; returns its id.
  # The record comes first: a child turn that ends at once reports to it.
  defp start(thread, run, spec) do
    child_id = HalC2.Environment.uuid4()
    task_id = "node:subagent:" <> HalC2.Environment.uuid4()
    selection = spec["modelSelection"]

    title =
      spec["title"] || spec["task"] |> String.split("\n") |> hd() |> String.slice(0, 80)

    record(thread, run, task_id, child_id, selection, title, spec["task"], spec["completionWake"])

    {:ok, _} =
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
        "workspaceStrategy" => workspace(thread),
        "lineage" => %{
          "parentThreadId" => thread["id"],
          "relationshipToParent" => "subagent",
          "rootThreadId" => get_in(thread, ["lineage", "rootThreadId"]) || thread["id"]
        },
        "initialMessage" => %{
          "messageId" => "message:delegate:" <> HalC2.Environment.uuid4(),
          "text" => spec["task"],
          "attachments" => []
        }
      })

    task_id
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

  defp record(thread, run, task_id, child_id, selection, title, prompt, wake) do
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

  # Ends the task in its parent, at `at` or now. With `:once`, a task that already
  # ended is left as it is and `:already` is returned, decided inside the parent's
  # transaction.
  defp settle(parent_id, task, status, result, delivery, how \\ :always, at \\ nil) do
    at = at || Entities.now()
    status = if status in @terminal, do: status, else: "completed"
    item_id = "turn-item:subagent:#{task["id"]}"

    HalC2.Streams.transact(parent_id, :thread, fn state ->
      finish = &Map.merge(&1, %{"status" => status, "completedAt" => at})
      current = StreamState.get(state, "subagent")[task["id"]] || %{}

      changes =
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
        ]
        |> Enum.reject(&(&1 in [nil, false]))

      if how == :once and current["status"] in @terminal,
        do: {[], :already},
        else: {changes, :ok}
    end)
  end

  # The parent hears the result as a message that runs once it is free. The
  # message carries which task it delivers (`delegatedCompletion`), so the
  # provider's acceptance and a later dispose can find it.
  defp wake(parent_id, task, status, result) do
    text = """
    <delegated_task_result taskId="#{task["id"]}" title="#{task["title"]}" status="#{status}" childThreadId="#{task["childThreadId"]}">
    #{result || "(no answer)"}
    </delegated_task_result>
    """

    Orchestration.dispatch(%{
      "type" => "message.dispatch",
      "commandId" => "command:delegate-result:#{task["id"]}",
      "threadId" => parent_id,
      "messageId" => result_message_id(task["id"]),
      "text" => String.trim(text),
      "attachments" => [],
      "createdBy" => "system",
      "creationSource" => "server",
      "dispatchMode" => %{"type" => "queue_after_active"},
      "delegatedCompletion" => %{
        "parentRunId" => task["runId"],
        "taskIds" => [task["id"]],
        "acceptedAt" => nil
      }
    })
  end

  defp status(thread_id, task_id) do
    with %{} = task <- subagent(thread_id, task_id) do
      child = stream(task["childThreadId"])
      runs = StreamState.list(child, "run") |> Enum.sort_by(& &1["ordinal"])
      terminal = task["status"] in @terminal

      %{
        "taskId" => task["id"],
        "childThreadId" => task["childThreadId"],
        "childRunId" => runs |> List.first(%{}) |> Map.get("id"),
        "title" => task["title"],
        "providerInstanceId" => task["providerInstanceId"],
        "model" => task["model"],
        "status" => task["status"],
        "workState" => if(terminal, do: "result_available", else: "working"),
        "summary" => task["result"],
        "hasPendingChildRuns" =>
          Enum.any?(runs, &(&1["status"] in @active or &1["status"] == "queued")),
        "startedAt" => task["startedAt"],
        "completedAt" => task["completedAt"]
      }
    end
  end

  defp subagent(thread_id, task_id), do: StreamState.get(stream(thread_id), "subagent")[task_id]

  # Waits for the task to end; a timeout leaves it running and returns its state.
  defp wait(thread_id, task_id, timeout) do
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

      # A child that ends after the caller stopped waiting still wakes it.
      left <= 0 ->
        if task["status"] not in @terminal,
          do: update(thread_id, task_id, %{"completionWake" => "always"})

        {:ok, Map.put(task, "waitTimedOut", true)}

      true ->
        receive do
          {:hal_c2_stream, ^thread_id, _} -> wait_loop(thread_id, task_id, deadline)
        after
          min(left, 5_000) -> wait_loop(thread_id, task_id, deadline)
        end
    end
  end

  # The child's last answer in the run that ended.
  defp answer(child, run_id) do
    child
    |> StreamState.list("message")
    |> Enum.filter(&(&1["runId"] == run_id and &1["role"] == "assistant"))
    |> List.last(%{})
    |> Map.get("text")
  end

  defp idle?(thread_id),
    do: not Enum.any?(StreamState.list(stream(thread_id), "run"), &(&1["status"] in @active))

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

  defp mode(parent, requested, kind) when requested in [nil, "inherit"],
    do: mode(parent, parent, kind)

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

  # The child works where the parent does.
  defp workspace(%{"worktreePath" => path, "branch" => branch}) when is_binary(path),
    do: %{"type" => "existing_worktree", "worktreePath" => path, "branch" => branch}

  defp workspace(_thread), do: %{"type" => "root"}

  defp not_active,
    do:
      {:error, "parent_not_active",
       "Delegated tasks require an active run owned by this MCP provider session."}

  defp stream(thread_id), do: HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))

  defp number(value, _default) when is_number(value), do: round(value)
  defp number(_value, default), do: default
end
