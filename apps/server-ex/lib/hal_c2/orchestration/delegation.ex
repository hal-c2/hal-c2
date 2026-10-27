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
         :new <- repeated(parent, thread, instance, input),
         {:ok, selection} <- target(thread, input["target"]),
         {:ok, runtime} <- mode(thread["runtimeMode"], input["runtimeMode"], :runtime),
         {:ok, interaction} <-
           mode(thread["interactionMode"], input["interactionMode"], :interaction),
         {:ok, workspace} <- resolve_workspace(thread, input["workspace"]) do
      spec = %{
        "task" => input["task"],
        "prompt" => framed(input),
        "taskId" => request_task_id(thread["id"], input["clientRequestId"]),
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
            do:
              wait(
                thread["id"],
                task_id,
                min(wait_budget(input["timeoutMs"]), HalC2.Mcp.max_wait_ms(instance))
              ),
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
         :ok <-
           if(run && run["status"] in @active,
             do: :ok,
             else: {:error, "parent_not_active", "Parent run #{run_id} is not active."}
           ),
         :ok <- parent_node(parent, run, command["parentNodeId"]),
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

      %{"origin" => "app_owned"} = task ->
        :ok = update(parent_id, task_id, %{"completionWake" => wake})

        # A task that already ended was decided under its old policy: switching it
        # to always wake a caller that is still working delivers its result now.
        # A caller that has since gone idle already heard it (or can read it from
        # the task's status), so no second wake is sent then.
        if wake == "always" and task["status"] in @terminal and
             get_in(task, ["completionDelivery", "state"]) not in ["delivered", "disposed"] and
             not idle?(stream(parent_id)) do
          deliver_now(parent_id, Map.put(task, "completionWake", "always"))
        else
          :ok
        end

      _ ->
        not_app_owned(parent_id, task_id)
    end
  end

  # The node a `delegated_task.request` hangs the task on must be part of the run.
  defp parent_node(_parent, _run, nil), do: :ok

  defp parent_node(parent, run, node_id) do
    if (StreamState.get(parent, "node")[node_id] || %{})["runId"] == run["id"],
      do: :ok,
      else: {:error, "Parent node #{node_id} is not part of active run #{run["id"]}."}
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
         :ok <- cancellable(task),
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
  def finished(thread_id, _run_id, _status) do
    settle_if_quiet(thread_id)
    flush_pending(thread_id)
  end

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
    hook(:settling, thread_id)
    child = stream(thread_id)

    with %{"lineage" => %{"relationshipToParent" => "subagent", "parentThreadId" => parent_id}} <-
           StreamState.get(child, "thread")[thread_id],
         %{} = task <-
           Enum.find(
             StreamState.list(stream(parent_id), "subagent"),
             &(&1["childThreadId"] == thread_id)
           ),
         true <- task["status"] in @terminal or settle_quiet(child, parent_id, task) do
      # The task may have been the last thing its caller, itself a subagent, waited on.
      # Checked whenever the task has ended, not only by the call that ended it, so a
      # report retried after this check failed (`report/5`) checks again.
      settle_if_quiet(parent_id)
    end

    :ok
  end

  # Settles `task` if its child is quiet; true once the task has ended.
  defp settle_quiet(child, parent_id, task) do
    # A child that has not started its first run yet has not begun the task.
    with [_ | _] = runs <- StreamState.list(child, "run"),
         true <- quiet?(child),
         {status, run, ended_at} <- last_end(runs) do
      result = result_for(child, run, status)

      # A child found quiet twice (two runs' ends, a provider replaying its turn's end
      # after a reconnect, the periodic check racing a report) settles and wakes once:
      # only the call that finds the task unsettled delivers it. Whether it is delivered
      # is decided with the task's end, so a wait that times out meanwhile (`wait/3`)
      # either hears of the end or leaves the task to wake the caller. The result
      # message is recorded in the same transaction, so a crash cannot leave a task
      # delivered without it.
      with {:settled, "delivered", {{:ok, _} = sent, command}} <-
             settle(parent_id, task, status, result, nil, :once, ended_at, true),
           do: Orchestration.dispatched(parent_id, command, sent)

      true
    else
      _ -> false
    end
  end

  @doc """
  `finished/3` from the end of a child's run (or of background work no provider wakes
  itself for), tried again while a thread it reads is too busy to answer, or it fails:
  a report given up on leaves the task to the periodic check (`settle_if_quiet/1`) or the next boot (`reconcile/2`). Retries `attempts` times, waiting twice as long each time from `backoff` ms.
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
          if(run, do: result_for(child, run, ended)),
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
  # A task of its own whose result is still to reach it (a `pending` delivery) is
  # owed too: the child is not done until the wake about it has run.
  defp owed(child) do
    runs = StreamState.list(child, "run")

    pending =
      for task <- StreamState.list(child, "subagent"),
          task["origin"] == "app_owned" and task["status"] in @terminal and
            get_in(task, ["completionDelivery", "state"]) == "pending",
          do: task["id"]

    pending ++
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
    task_id = spec["taskId"] || "node:subagent:" <> HalC2.Environment.uuid4()
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
          "text" => preamble(thread) <> (spec["prompt"] || spec["task"]),
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

  # What a delegated child is told before its task: who it works for and that its last
  # message is the report, so it finishes its own background work and workers first.
  @doc false
  def preamble(thread) do
    title = thread["title"] |> to_string() |> String.replace(~r/\s+/, " ") |> String.trim()
    parent = if title == "", do: thread["id"], else: inspect(title)

    """
    You are a HAL-C2 worker delegated by the thread #{parent}. Your final message is your report to it: lead with the outcome, then evidence (files, commands, test results), then anything left undone. Finish your own work, including waiting on your background work and your own workers, before you end your last turn.

    Task:
    """
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

  # Takes the task out of a wake that still waits behind the caller's run: the
  # wake goes on naming the tasks that are left, or is cancelled when none are.
  defp cancel_delivery(parent_id, task_id) do
    state = stream(parent_id)
    messages = StreamState.get(state, "message")

    queued =
      Enum.find_value(StreamState.list(state, "run"), fn run ->
        message = messages[run["userMessageId"]]

        if (run["status"] == "queued" and message) &&
             task_id in (get_in(message, ["delegatedCompletion", "taskIds"]) || []),
           do: {run, message}
      end)

    case queued do
      nil ->
        :ok

      {run, message} ->
        remaining =
          (get_in(message, ["delegatedCompletion", "taskIds"]) || []) -- [task_id]

        if remaining == [] do
          {:ok, _} =
            Orchestration.dispatch(%{
              "type" => "queued-run.cancel",
              "threadId" => parent_id,
              "runId" => run["id"]
            })

          :ok
        else
          HalC2.Streams.transact(parent_id, :thread, fn fresh ->
            tasks = cohort_tasks(fresh, remaining, nil)

            {[
               Orchestration.upsert(fresh, "message", message["id"], fn current ->
                 current
                 |> Map.put("text", wake_text(tasks))
                 |> Map.put("notification", notification(tasks))
                 |> put_in(["delegatedCompletion", "taskIds"], remaining)
                 |> Map.put("updatedAt", Entities.now())
               end)
             ]
             |> Enum.filter(&is_tuple/1), :ok}
          end)
        end
    end
  end

  @doc """
  Stops the wakes of the run `run_id` of `thread_id` (the thread's active run
  when none is named), as stopping that turn does: a wake still queued for it
  is cancelled, and its tasks, whenever they finish, no longer wake the caller.
  Their results stay readable from their status.
  """
  def stop_wakes(thread_id, run_id \\ nil) do
    state = stream(thread_id)
    messages = StreamState.get(state, "message")
    runs = StreamState.list(state, "run")

    stopped =
      case run_id do
        nil ->
          runs |> Enum.filter(&(&1["status"] in @active)) |> Enum.map(& &1["id"])

        id ->
          [id]
      end

    # Interrupting a wake run itself stops the cohort it was waking for.
    cohorts =
      Enum.flat_map(stopped, fn id ->
        case Enum.find(runs, &(&1["id"] == id)) do
          %{"userMessageId" => message_id} ->
            [id, get_in(messages, [message_id, "delegatedCompletion", "parentRunId"])]

          _ ->
            [id]
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if cohorts != [] do
      HalC2.Streams.transact(thread_id, :thread, fn fresh ->
        {for task <- StreamState.list(fresh, "subagent"),
             task["origin"] == "app_owned" and task["runId"] in cohorts and
               get_in(task, ["completionDelivery", "state"]) in ["pending", "delivered"] do
           Orchestration.upsert(fresh, "subagent", task["id"], fn entity ->
             Map.merge(entity, %{
               "completionDelivery" => %{"state" => "disposed", "observedByRunId" => nil},
               "updatedAt" => Entities.now()
             })
           end)
         end
         |> Enum.filter(&is_tuple/1), :ok}
      end)

      for run <- runs,
          run["status"] == "queued",
          get_in(messages, [run["userMessageId"], "delegatedCompletion", "parentRunId"]) in cohorts do
        _ =
          Orchestration.dispatch(%{
            "type" => "queued-run.cancel",
            "threadId" => thread_id,
            "runId" => run["id"]
          })
      end
    end

    :ok
  end

  @doc """
  Acknowledges the delivery of every finished task of `parent_id` whose child
  is `child_id`, as reading the child's answer in full does: the caller has the
  result, so it is not woken for it again. Returns whether one was acknowledged.
  """
  def acknowledge_child_read(parent_id, child_id, observed_by_run_id) do
    tasks =
      parent_id
      |> stream()
      |> StreamState.list("subagent")
      |> Enum.filter(
        &(&1["origin"] == "app_owned" and &1["childThreadId"] == child_id and
            &1["status"] in @terminal and
            get_in(&1, ["completionDelivery", "state"]) in ["pending", "delivered"])
      )

    for task <- tasks do
      resolve_delivery(%{
        "type" => "delegated_task.completion-delivery.acknowledge",
        "parentThreadId" => parent_id,
        "taskId" => task["id"],
        "observedByRunId" => observed_by_run_id
      })
    end

    tasks != []
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

      {delivery, message, sent} =
        if wake? do
          plan_wake(state, parent_id, current, status, result)
        else
          delivery = if is_function(delivery), do: delivery.(current, state), else: delivery
          {delivery, [], {nil, nil}}
        end

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

  # Whether and how a finished task's result reaches the caller, decided with its
  # end inside the caller's transaction. Returns the delivery state, the wake's
  # changes and `{sent, command}` for `Orchestration.dispatched/3`.
  #
  # A disposed task, and one whose caller is archived or deleted, wakes nobody. A
  # task that wakes only an idle caller (`settled_only`) ending while the caller
  # works is only acknowledged, which is the caller's wait reading it (`wait/3`).
  # Otherwise the result joins a wake still queued for the run that started it, or
  # starts one, at most two wakes per such run: later results stay readable from
  # the task's status instead of waking the caller again and again.
  defp plan_wake(state, parent_id, task, status, result) do
    thread = StreamState.get(state, "thread")[parent_id] || %{}
    task = Map.merge(task, %{"status" => status, "result" => result})

    cond do
      get_in(task, ["completionDelivery", "state"]) == "disposed" ->
        {"disposed", [], {nil, nil}}

      thread["archivedAt"] != nil or thread["deletedAt"] != nil ->
        {"disposed", [], {nil, nil}}

      (task["completionWake"] || "settled_only") != "always" and not idle?(state) ->
        {"acknowledged", [], {nil, nil}}

      queued = queued_wake(state, task["runId"]) ->
        join_wake(state, queued, task)

      # A wake for this run is already with the caller: this result rides the
      # one follow-up wake that runs when it ends (`flush_pending/1`).
      wake_in_flight?(state, task["runId"]) ->
        {"pending", [], {nil, nil}}

      settled_wake_count(state, task["runId"]) >= 2 ->
        {"acknowledged", [], {nil, nil}}

      true ->
        command = wake_command(state, parent_id, thread, [task])
        {changes, sent} = Orchestration.decide_dispatch(state, parent_id, command)
        {"delivered", changes, {sent, command}}
    end
  end

  # Plans a wake for a task that already ended, as `wake_policy/1` asks when a
  # finished task is switched to always wake a caller that is still working.
  defp deliver_now(parent_id, task) do
    decided =
      HalC2.Streams.transact(parent_id, :thread, fn state ->
        current = StreamState.get(state, "subagent")[task["id"]] || task
        thread = StreamState.get(state, "thread")[parent_id] || %{}

        cond do
          get_in(current, ["completionDelivery", "state"]) == "disposed" ->
            {[], nil}

          queued = queued_wake(state, current["runId"]) ->
            {_delivery, changes, sent} = join_wake(state, queued, current)
            {changes ++ delivered_change(state, current), sent}

          settled_wake_count(state, current["runId"]) >= 2 and
              not wake_in_flight?(state, current["runId"]) ->
            {[], nil}

          true ->
            command = wake_command(state, parent_id, thread, [current])
            {changes, sent} = Orchestration.decide_dispatch(state, parent_id, command)
            {changes ++ delivered_change(state, current), {sent, command}}
        end
      end)

    case decided do
      {{:ok, _} = sent, command} -> Orchestration.dispatched(parent_id, command, sent)
      _ -> :ok
    end

    :ok
  end

  defp delivered_change(state, task) do
    [
      Orchestration.upsert(state, "subagent", task["id"], fn entity ->
        Map.merge(entity, %{
          "completionDelivery" => %{"state" => "delivered", "observedByRunId" => nil},
          "updatedAt" => Entities.now()
        })
      end)
    ]
    |> Enum.filter(&is_tuple/1)
  end

  # A result that lands while its run's wake still waits joins that wake: one
  # message naming every task it carries, its notification re-summed over them.
  defp join_wake(state, {_run, message}, task) do
    ids =
      ((get_in(message, ["delegatedCompletion", "taskIds"]) || []) ++ [task["id"]])
      |> Enum.uniq()

    tasks = cohort_tasks(state, ids, task)

    changes =
      [
        Orchestration.upsert(state, "message", message["id"], fn current ->
          current
          |> Map.put("text", wake_text(tasks))
          |> Map.put("notification", notification(tasks))
          |> put_in(["delegatedCompletion", "taskIds"], ids)
          |> Map.put("updatedAt", Entities.now())
        end)
      ]
      |> Enum.filter(&is_tuple/1)

    {"delivered", changes, {{:ok, :sent}, nil}}
  end

  defp cohort_tasks(state, ids, fresh) do
    stored = StreamState.get(state, "subagent")

    Enum.flat_map(ids, fn id ->
      cond do
        fresh && id == fresh["id"] -> [fresh]
        stored[id] -> [stored[id]]
        true -> []
      end
    end)
  end

  # The queued run and message waking `parent_run_id`, if one still waits.
  defp queued_wake(state, parent_run_id) when is_binary(parent_run_id) do
    messages = StreamState.get(state, "message")

    Enum.find_value(StreamState.list(state, "run"), fn run ->
      message = messages[run["userMessageId"]]

      if (run["status"] == "queued" and message) &&
           get_in(message, ["delegatedCompletion", "parentRunId"]) == parent_run_id,
         do: {run, message}
    end)
  end

  defp queued_wake(_state, _parent_run_id), do: nil

  # Wakes for a run that have run their course, and whether one is with the
  # caller now. Cancelled wakes never woke it, so they count for neither.
  defp settled_wake_count(state, parent_run_id) when is_binary(parent_run_id) do
    runs = StreamState.get(state, "run")

    Enum.count(StreamState.list(state, "message"), fn message ->
      get_in(message, ["delegatedCompletion", "parentRunId"]) == parent_run_id and
        (runs[message["runId"]] || %{})["status"] in @terminal
    end)
  end

  defp settled_wake_count(_state, _parent_run_id), do: 0

  defp wake_in_flight?(state, parent_run_id) when is_binary(parent_run_id) do
    runs = StreamState.get(state, "run")

    Enum.any?(StreamState.list(state, "message"), fn message ->
      get_in(message, ["delegatedCompletion", "parentRunId"]) == parent_run_id and
        (runs[message["runId"]] || %{})["status"] in @active
    end)
  end

  defp wake_in_flight?(_state, _parent_run_id), do: false

  @doc """
  Wakes `parent_id` once for each run whose tasks ended while that run's wake
  was already with the caller (`plan_wake/5` left them `pending`): one follow-up
  wake carrying them all. Called as runs of the thread end, when a wake that
  kept them waiting may have settled.
  """
  def flush_pending(parent_id) do
    state = stream(parent_id)
    thread = StreamState.get(state, "thread")[parent_id] || %{}

    pending =
      state
      |> StreamState.list("subagent")
      |> Enum.filter(
        &(&1["origin"] == "app_owned" and &1["status"] in @terminal and
            get_in(&1, ["completionDelivery", "state"]) == "pending")
      )
      |> Enum.group_by(& &1["runId"])

    for {_run_id, tasks} <- pending do
      if thread["archivedAt"] != nil or thread["deletedAt"] != nil do
        for task <- tasks,
            do:
              update(parent_id, task["id"], %{
                "completionDelivery" => %{"state" => "disposed", "observedByRunId" => nil}
              })
      else
        decided =
          HalC2.Streams.transact(parent_id, :thread, fn fresh ->
            still =
              Enum.filter(tasks, fn task ->
                current = StreamState.get(fresh, "subagent")[task["id"]] || %{}
                get_in(current, ["completionDelivery", "state"]) == "pending"
              end)

            if still == [] or wake_in_flight?(fresh, hd(still)["runId"]) do
              {[], nil}
            else
              case queued_wake(fresh, hd(still)["runId"]) do
                {_run, message} ->
                  ids =
                    ((get_in(message, ["delegatedCompletion", "taskIds"]) || []) ++
                       Enum.map(still, & &1["id"]))
                    |> Enum.uniq()

                  tasks = cohort_tasks(fresh, ids, nil)

                  changes =
                    [
                      Orchestration.upsert(fresh, "message", message["id"], fn current ->
                        current
                        |> Map.put("text", wake_text(tasks))
                        |> Map.put("notification", notification(tasks))
                        |> put_in(["delegatedCompletion", "taskIds"], ids)
                        |> Map.put("updatedAt", Entities.now())
                      end)
                    ]
                    |> Enum.filter(&is_tuple/1)

                  {changes ++ Enum.flat_map(still, &delivered_change(fresh, &1)),
                   {{:ok, :sent}, nil}}

                nil ->
                  stored = cohort_tasks(fresh, Enum.map(still, & &1["id"]), nil)
                  command = wake_command(fresh, parent_id, thread, stored)
                  {changes, sent} = Orchestration.decide_dispatch(fresh, parent_id, command)

                  {changes ++ Enum.flat_map(stored, &delivered_change(fresh, &1)),
                   {sent, command}}
              end
            end
          end)

        case decided do
          {{:ok, _} = sent, command} -> Orchestration.dispatched(parent_id, command, sent)
          _ -> :ok
        end
      end
    end

    :ok
  end

  # The parent hears the results as one message. It carries which tasks it
  # delivers (`delegatedCompletion`), so the provider's acceptance and a later
  # dispose can find it, and what the user is shown in place of its text
  # (`notification`): that the tasks ended, and how. On a provider that takes a
  # message mid-turn as its next prompt (Claude, OpenCode, Pi, Muse) an
  # always-wake joins the running turn; elsewhere it waits behind it. A wake
  # never interrupts or restarts the turn it wakes.
  defp wake_command(state, parent_id, thread, tasks) do
    first = hd(tasks)
    active = Enum.find(StreamState.list(state, "run"), &(&1["status"] in @active))

    mode =
      if active && Enum.all?(tasks, &(&1["completionWake"] == "always")) &&
           mailbox_steers?(active, thread) do
        %{"type" => "steer_active", "targetRunId" => active["id"]}
      else
        %{"type" => "queue_after_active"}
      end

    %{
      "type" => "message.dispatch",
      "commandId" => "command:delegate-result:#{first["id"]}",
      "threadId" => parent_id,
      "messageId" => result_message_id(first["id"]),
      "text" => wake_text(tasks),
      "attachments" => [],
      "createdBy" => "system",
      "creationSource" => "server",
      "dispatchMode" => mode,
      "notification" => notification(tasks),
      "delegatedCompletion" => %{
        "parentRunId" => first["runId"],
        "taskIds" => Enum.map(tasks, & &1["id"]),
        "acceptedAt" => nil
      }
    }
  end

  defp mailbox_steers?(run, thread) do
    instance = run["providerInstanceId"] || "codex"
    driver = Orchestration.driver_for(instance)

    run["status"] in ["running", "waiting"] and instance == thread_instance(thread) and
      (driver == "claudeAgent" or
         (HalC2.Acp.driver(driver) || driver) in ["opencode", "pi", "muse"])
  end

  defp thread_instance(thread) do
    get_in(thread, ["modelSelection", "instanceId"]) || thread["providerInstanceId"] || "codex"
  end

  defp wake_text(tasks), do: tasks |> Enum.map(&envelope/1) |> Enum.join("\n")

  defp envelope(task) do
    answer = task["result"] || "(no answer)"

    """
    <delegated_task_result taskId="#{attr(task["id"])}" title="#{attr(task["title"])}" status="#{attr(task["status"])}" childThreadId="#{attr(task["childThreadId"])}">
    #{close_tag_safe(answer)}
    </delegated_task_result>
    """
    |> String.trim()
  end

  # What the caller's timeline shows for a wake: one task by its title, several
  # counted, the outcome the worst of theirs (upstream `Notification.ts`).
  defp notification(tasks) do
    outcome =
      cond do
        Enum.any?(tasks, &(&1["status"] == "failed")) -> "failed"
        Enum.any?(tasks, &(&1["status"] in ["cancelled", "interrupted"])) -> "cancelled"
        true -> "completed"
      end

    label =
      case tasks do
        [task] ->
          case String.trim(task["title"] || "") do
            "" -> "Delegated task"
            title -> title
          end

        _ ->
          "#{length(tasks)} delegated tasks"
      end

    ended = %{"failed" => "failed", "cancelled" => "stopped", "completed" => "finished"}[outcome]
    first = hd(tasks)

    %{
      "source" => %{"kind" => "delegated_task", "taskIds" => Enum.map(tasks, & &1["id"])},
      "outcome" => outcome,
      "summary" => "#{label} #{ended}",
      "workerThreadId" => first["childThreadId"],
      "workerTitle" => label,
      "detail" => cap_result(Enum.map_join(tasks, "\n\n", &(&1["result"] || "(no answer)")))
    }
  end

  # The agent reads the whole answer; a closing tag quoted inside it (a previous result,
  # say) must not end the envelope early.
  defp close_tag_safe(text),
    do: Regex.replace(~r{</(?=delegated_task_result)}i, text, "&lt;/")

  # How much of a worker's answer the timeline notification carries, so clients don't
  # render megabytes; the rest stays readable in the worker's own thread.
  @result_cap 8_192

  defp cap_result(text) when byte_size(text) > @result_cap do
    kept = text |> binary_part(0, @result_cap) |> trim_invalid()
    kept <> "\n\n[result truncated at #{@result_cap} bytes; the rest is in the worker's thread]"
  end

  defp cap_result(text), do: text

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

  # What a task's result is, however its end reaches the caller.
  defp result_for(child, run, status) do
    preparation_failure(child, run) || failure_text(child, run, status) || answer(child) ||
      no_answer_text(status)
  end

  # A failed run's own word on why: its latest error item, which outranks any
  # answer it gave before failing (upstream `subagentResultForRun`).
  defp failure_text(_child, _run, status) when status != "failed", do: nil

  defp failure_text(child, %{"id" => run_id}, "failed") do
    child
    |> StreamState.list("turn-item")
    |> Enum.filter(&(&1["type"] == "error" and &1["runId"] == run_id))
    |> Enum.sort_by(&(&1["ordinal"] || 0))
    |> List.last(%{})
    |> Map.get("failure")
    |> case do
      %{"message" => message} when is_binary(message) and message != "" -> message
      message when is_binary(message) and message != "" -> message
      _ -> nil
    end
  end

  defp failure_text(_child, _run, _status), do: nil

  # What the result says when the child left no answer and no failure of its own.
  # A failed or cancelled child keeps no result: its wake says "(no answer)".
  defp no_answer_text("completed"), do: "Child task completed without an assistant result."
  defp no_answer_text("interrupted"), do: "Child task ended with status interrupted."
  defp no_answer_text(_status), do: nil

  # A task can be cancelled only while its child has work to interrupt: a run
  # going, or background work it still owes.
  defp cancellable(task) do
    child = stream(task["childThreadId"])

    if working?(StreamState.list(child, "run")) or owed(child) != [] do
      :ok
    else
      {:error, "task_not_cancellable",
       "Delegated task #{task["id"]} has no interruptible child run."}
    end
  end

  defp idle?(state), do: not Enum.any?(StreamState.list(state, "run"), &(&1["status"] in @active))

  # A role frames the child's prompt; "general" and no role leave the task as given.
  defp framed(%{"task" => task, "role" => role}) when role not in [nil, "general"],
    do: "Act as the #{role} sub-agent for this task.\n\n#{task}"

  defp framed(%{"task" => task}), do: task

  # The task id a request key names, so repeating a delegation with the same
  # `clientRequestId` finds the task it started instead of starting another.
  defp request_task_id(_parent_id, key) when not is_binary(key) or key == "", do: nil

  defp request_task_id(parent_id, key) do
    digest =
      :crypto.hash(:sha256, "delegate_task\0#{parent_id}\0#{key}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)

    "node:subagent:" <>
      Enum.join(
        [
          binary_part(digest, 0, 8),
          binary_part(digest, 8, 4),
          binary_part(digest, 12, 4),
          binary_part(digest, 16, 4),
          binary_part(digest, 20, 12)
        ],
        "-"
      )
  end

  defp repeated(parent, thread, instance, input) do
    case request_task_id(thread["id"], input["clientRequestId"]) do
      nil ->
        :new

      task_id ->
        if StreamState.get(parent, "subagent")[task_id] do
          if input["mode"] == "wait",
            do:
              wait(
                thread["id"],
                task_id,
                min(wait_budget(input["timeoutMs"]), HalC2.Mcp.max_wait_ms(instance))
              ),
            else: {:ok, status(thread["id"], task_id)}
        else
          :new
        end
    end
  end

  defp target(thread, nil), do: {:ok, thread["modelSelection"]}

  defp target(thread, target) do
    providers = HalC2.Environment.providers()
    inherited = thread["modelSelection"] || %{}
    driver = target["driverKind"]

    with {:ok, instance} <-
           resolve_instance(providers, inherited, target["providerInstanceId"], driver),
         %{} = provider <-
           Enum.find(providers, &(&1["instanceId"] == instance)) ||
             {:error, "provider_unavailable", "Provider instance #{instance} is not registered."},
         :ok <- driver_matches(provider, instance, driver),
         :ok <- runnable(provider, instance) do
      models = provider["models"] || []

      model =
        target["model"] ||
          if(instance == inherited["instanceId"],
            do: inherited["model"],
            else: Enum.find(models, %{}, & &1["isDefault"])["slug"]
          )

      options =
        case target["options"] do
          %{} = map -> for {id, value} <- map, do: %{"id" => id, "value" => value}
          list when is_list(list) -> list
          _ -> nil
        end

      with :ok <- model_advertised(models, instance, target["model"]),
           :ok <- options_valid(models, instance, model, options) do
        {:ok,
         %{"instanceId" => instance, "model" => model}
         |> then(&if(options, do: Map.put(&1, "options", options), else: &1))}
      end
    end
  end

  # An instance named outright, else one of the named kind: the caller's own when it
  # can run, else another healthy one of that kind.
  defp resolve_instance(_providers, _inherited, instance, _driver) when is_binary(instance),
    do: {:ok, instance}

  defp resolve_instance(providers, inherited, _instance, driver) when is_binary(driver) do
    healthy =
      providers
      |> Enum.filter(&(&1["driver"] == driver))
      |> Enum.filter(&healthy?/1)

    case Enum.find(healthy, &(&1["instanceId"] == inherited["instanceId"])) || List.first(healthy) do
      %{"instanceId" => instance} ->
        {:ok, instance}

      nil ->
        {:error, "provider_unavailable",
         "No available V2 provider instance for driver #{driver}."}
    end
  end

  defp resolve_instance(_providers, inherited, _instance, _driver),
    do: {:ok, inherited["instanceId"]}

  defp driver_matches(provider, instance, driver) when is_binary(driver) do
    if provider["driver"] == driver,
      do: :ok,
      else:
        {:error, "invalid_request",
         "Provider instance #{instance} uses driver #{provider["driver"]}, not #{driver}."}
  end

  defp driver_matches(_provider, _instance, _driver), do: :ok

  defp healthy?(provider) do
    provider["enabled"] != false and provider["installed"] != false and
      provider["status"] not in ["error", "disabled"] and
      get_in(provider, ["auth", "status"]) != "unauthenticated"
  end

  defp runnable(provider, instance) do
    problems =
      [
        provider["enabled"] == false && "Provider instance is disabled.",
        provider["installed"] == false && "Provider executable is not installed.",
        provider["status"] in ["error", "disabled"] &&
          (provider["message"] || "Provider status is #{provider["status"]}."),
        get_in(provider, ["auth", "status"]) == "unauthenticated" &&
          "Provider is not authenticated."
      ]
      |> Enum.filter(&is_binary/1)

    if problems == [],
      do: :ok,
      else:
        {:error, "provider_unavailable",
         "Provider #{instance} cannot run a child task: #{Enum.join(problems, " ")}"}
  end

  defp model_advertised(models, instance, requested) when is_binary(requested) do
    if models == [] or Enum.any?(models, &(&1["slug"] == requested)),
      do: :ok,
      else:
        {:error, "model_unavailable",
         "Model #{requested} is not advertised by provider #{instance}."}
  end

  defp model_advertised(_models, _instance, _requested), do: :ok

  # The requested options against the model's descriptors (upstream
  # `invalidOptionSelections`): duplicates always fail; without descriptors the
  # rest is the provider's to judge.
  defp options_valid(_models, _instance, _model, nil), do: :ok

  defp options_valid(models, instance, model, options) do
    descriptors =
      models
      |> Enum.find(&(&1["slug"] == model))
      |> get_in([Access.key("capabilities", %{}), "optionDescriptors"])

    problems =
      options
      |> Enum.reduce({MapSet.new(), []}, fn
        %{"id" => id} = option, {seen, problems} ->
          cond do
            MapSet.member?(seen, id) ->
              {seen, problems ++ ["Option #{id} was specified more than once."]}

            descriptors == nil ->
              {MapSet.put(seen, id), problems}

            true ->
              {MapSet.put(seen, id), problems ++ option_problem(descriptors, option)}
          end

        _other, acc ->
          acc
      end)
      |> elem(1)

    if problems == [],
      do: :ok,
      else:
        {:error, "invalid_request",
         "Model #{model} on provider #{instance} rejected options: #{Enum.join(problems, " ")}"}
  end

  defp option_problem(descriptors, %{"id" => id, "value" => value}) do
    case Enum.find(descriptors, &(&1["id"] == id)) do
      nil ->
        known = descriptors |> Enum.map(& &1["id"]) |> Enum.join(", ")
        ["Unknown option #{id}; supported options: #{if known == "", do: "none", else: known}."]

      %{"type" => "boolean"} when not is_boolean(value) ->
        ["Option #{id} expects a boolean value."]

      %{"type" => "select", "options" => choices} ->
        if Enum.any?(choices, &(&1["id"] == value)),
          do: [],
          else: [
            "Option #{id} must be one of: #{choices |> Enum.map(& &1["id"]) |> Enum.join(", ")}."
          ]

      _ ->
        []
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

      # A caller already in the project root is asking for its own checkout.
      type == "root" and is_nil(thread["worktreePath"]) ->
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
