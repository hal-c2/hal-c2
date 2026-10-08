defmodule HalC2.Steps.Orchestration.Delegation do
  @moduledoc """
  Steps for `features/mc/orchestration/delegation.feature`.

  The caller is the parent thread's agent on the fake Codex CLI; its `delegate_task`,
  `task_status` and `task_cancel` calls go through the MCP server
  (`HalC2.Test.Mc.World.mcp_tool/5`). A task's child thread is named "subagent" in
  the scenario. Children run on the fake CLIs too: a task "wait for it" keeps
  working until the scenario steers it with "say <answer>", which ends its turn
  with that answer.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.StreamState
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  # --- the caller ----------------------------------------------------------------

  step "thread {string} has a running turn on {string} in worktree {string}",
       %{args: [thread, "codex", path]} = context do
    context = World.providers(context)
    root = World.project(context).root
    dir = Mc.tmp_dir(context.mc, "worktree")
    World.git!(root, ["worktree", "add", "-q", "-b", "work", dir])

    context =
      World.launch_titled(context, thread, nil, "wait for it", %{
        "workspaceStrategy" => %{
          "type" => "existing_worktree",
          "worktreePath" => dir,
          "branch" => "work"
        }
      })

    World.await_runs(context, thread, ["running"])
    Map.put(context, :worktrees, %{path => dir})
  end

  step "{string} has no active run on the calling provider", %{args: [thread]} = context do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "threadId" => World.thread_id(context, thread)
      })

    World.await_runs(context, thread, ["interrupted"])
    context
  end

  step "the task names a provider this MC does not have", context do
    Map.put(context, :delegate_input, %{"target" => %{"providerInstanceId" => "nowhere"}})
  end

  step "the task asks for full access while {string} is approval-required",
       %{args: [thread]} = context do
    World.patch_thread(context, thread, %{"runtimeMode" => "approval-required"})
    Map.put(context, :delegate_input, %{"runtimeMode" => "full-access"})
  end

  step "the task asks for default mode while {string} is in plan mode",
       %{args: [thread]} = context do
    World.patch_thread(context, thread, %{"interactionMode" => "plan"})
    Map.put(context, :delegate_input, %{"interactionMode" => "default"})
  end

  step "the turn of {string} fails", %{args: [thread]} = context do
    World.await_runs(context, thread, ["failed"])
    context
  end

  step "the task, its node and its turn item are {string}", %{args: [status]} = context do
    state = World.state(context, context.task_parent)
    assert task(context)["status"] == status
    assert StreamState.get(state, "node")[context.task_id]["status"] == status

    assert StreamState.get(state, "turn-item")["turn-item:subagent:#{context.task_id}"]["status"] ==
             status

    context
  end

  step "the turn of {string} ended", %{args: [thread]} = context do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "threadId" => World.thread_id(context, thread)
      })

    World.await_runs(context, thread, ["interrupted"])
    context
  end

  # --- delegating ----------------------------------------------------------------

  step "the agent in {string} delegates {string}", %{args: [caller, task]} = context do
    delegate(context, caller, %{"task" => String.replace(task, "\\n", "\n")})
  end

  step "the agent in {string} delegates a task whose first line is {int} characters long",
       %{args: [caller, length]} = context do
    line = String.duplicate("a", length)
    context |> delegate(caller, %{"task" => line <> "\nwait for it"}) |> Map.put(:line, line)
  end

  step "the agent in {string} delegates a task", %{args: [caller]} = context do
    delegate(context, caller, %{})
  end

  step "the agent in {string} delegates a task without naming a provider",
       %{args: [caller]} = context do
    delegate(context, caller, %{})
  end

  step "the agent in {string} delegates a task to {string} without a model",
       %{args: [caller, instance]} = context do
    delegate(context, caller, %{"target" => %{"providerInstanceId" => instance}})
  end

  step "the agent in {string} delegates a task and waits", %{args: [caller]} = context do
    delegate(context, caller, %{"mode" => "wait"})
  end

  step "the agent in {string} delegates a task and waits {int} second(s)",
       %{args: [caller, seconds]} = context do
    delegate(context, caller, %{"mode" => "wait", "timeoutMs" => seconds * 1_000})
  end

  step ~r/^the agent in "(?<caller>[^"]+)" delegates a task and waits (?<asked>\S+) ms$/,
       %{args: [caller, asked]} = context do
    input =
      case asked do
        "none" -> %{"mode" => "wait"}
        ms -> %{"mode" => "wait", "timeoutMs" => number(ms)}
      end

    context |> delegate(caller, input) |> Map.put(:asked, input["timeoutMs"])
  end

  step "the agent in {string} delegated a task without waiting", %{args: [caller]} = context do
    delegate(context, caller, %{"mode" => "async"})
  end

  step "the agent in {string} delegated a task", %{args: [caller]} = context do
    delegate(context, caller, %{"mode" => "async"})
  end

  step "the agent in {string} delegated a task that is still working",
       %{args: [caller]} = context do
    context = delegate(context, caller, %{"mode" => "async"})
    World.await_runs(context, "subagent", ["running"])
    context
  end

  step "the agent in {string} delegated a task that completed", %{args: [caller]} = context do
    context = delegate(context, caller, %{"mode" => "async", "task" => "say Done"})
    await_task(context, &(&1["status"] == "completed"))
    context
  end

  step "the agent in {string} delegated a task and is waiting", %{args: [caller]} = context do
    delegate(context, caller, %{"mode" => "wait"})
  end

  step "the agent in {string} delegated a task and waited until it timed out",
       %{args: [caller]} = context do
    context = delegate(context, caller, %{"mode" => "wait", "timeoutMs" => 1})
    assert {:ok, %{"waitTimedOut" => true}} = Task.await(context.wait)
    context
  end

  # Each task's child thread goes by the task's name. A result message quotes the
  # task's title, and the fake Codex plays the caller's wake turn from it: "where
  # are we" answers and ends the turn.
  step "the agent in {string} delegated tasks {string}, {string} and {string} without waiting",
       %{args: [caller | names]} = context do
    Enum.reduce(names, context, fn name, context ->
      context =
        delegate(context, caller, %{"mode" => "async", "title" => "where are we with #{name}"})

      context
      |> put_in([:threads, name], context.threads["subagent"])
      |> put_in([Access.key(:named_tasks, %{}), name], context.task_id)
    end)
  end

  step "{string} was woken for the completion of {string}", %{args: [parent, name]} = context do
    context = complete_named(context, name)
    # The caller's own turn ends, and the result runs as its next turn.
    World.send_turn(context, parent, "say Carrying on")
    [wake] = await_wakes(context, parent, [name])
    Map.put(context, :first_wake, wake)
  end

  step "{string} and {string} complete afterwards", %{args: [first, second]} = context do
    context |> complete_named(first) |> complete_named(second) |> Map.put(:later, [first, second])
  end

  step "{string} is woken again for them", %{args: [parent]} = context do
    wakes = await_wakes(context, parent, context.later)
    assert Enum.all?(wakes, &(&1["ordinal"] > context.first_wake["ordinal"]))
    Map.put(context, :later_wakes, wakes)
  end

  # Each result is delivered once; two that land together may ride one turn.
  step "completions that arrive together may share one wake turn", context do
    assert length(Enum.uniq_by(context.later_wakes, & &1["id"])) in 1..2

    for name <- context.later do
      assert [_] =
               Enum.filter(
                 messages(context, "parent"),
                 &(&1["text"] =~ ~s(taskId="#{context.named_tasks[name]}"))
               )
    end

    context
  end

  # --- the subagent ----------------------------------------------------------------

  step "the subagent completes with {string}", %{args: [answer]} = context do
    complete(context, answer)
  end

  step "the subagent completes", context do
    complete(context, "Done")
  end

  # The child's run end is reported again, as a provider replaying the end of its turn
  # after it reconnects does: twice at once, so the reports race each other too.
  step "the same completion is delivered again after a reconnect", context do
    child = World.thread_id(context, "subagent")
    [%{"id" => run_id, "status" => "completed"}] = World.runs(context, "subagent")
    message = await_result_message(context, context.task_parent)

    repeats =
      for _ <- 1..2 do
        Task.async(fn -> HalC2.Orchestration.Delegation.finished(child, run_id, "completed") end)
      end
      |> Task.await_many()

    Map.merge(context, %{repeats: repeats, result_message: message, settled: task(context)})
  end

  step "{string} receives one wake turn", %{args: [parent]} = context do
    wakes =
      Enum.filter(messages(context, parent), &(&1["delegatedCompletion"]["taskIds"] != nil))

    assert [%{"id" => id, "runId" => run_id}] = wakes
    assert id == context.result_message["id"]
    assert [^run_id] = for(m <- wakes, do: m["runId"])

    # The caller's own turn, and the one run that carries the result behind it.
    assert [%{"status" => "running"}, %{"id" => ^run_id, "status" => "queued"}] =
             World.runs(context, parent)

    context
  end

  step "the repeat is acknowledged without another wake", context do
    assert context.repeats == [:ok, :ok]
    # The task is as the first report left it: same result, same delivery, same time.
    assert task(context) == context.settled
    assert %{"completionDelivery" => %{"state" => "delivered"}} = task(context)

    assert [_one] =
             Enum.filter(
               World.events(context, context.task_parent),
               &(&1.kind == "message" and &1.entity == context.result_message["id"])
             )

    context
  end

  step "the subagent is still working after {int} second(s)", %{args: [_seconds]} = context do
    result = Task.await(context.wait)
    assert [%{"status" => "running"}] = World.runs(context, "subagent")
    Map.put(context, :wait_result, result)
  end

  step "the subagent's turn ends with two assistant messages", context do
    context = delegate(context, "parent", %{"mode" => "async", "task" => "say First | Second"})
    await_task(context, &(&1["status"] == "completed"))
    context
  end

  step "the subagent fails without an assistant message", context do
    context = delegate(context, "parent", %{"mode" => "async", "task" => "fail now"})
    await_task(context, &(&1["status"] == "failed"))
    context
  end

  # --- what the caller sees --------------------------------------------------------

  step "a new thread marked as a subagent of {string} exists", %{args: [parent]} = context do
    child = World.thread(context, "subagent")

    assert %{"parentThreadId" => parent_id, "relationshipToParent" => "subagent"} =
             child["lineage"]

    assert parent_id == World.thread_id(context, parent)
    context
  end

  step "it was created by an agent through MCP", context do
    [message | _] = messages(context, "subagent")
    assert %{"createdBy" => "agent", "creationSource" => "mcp"} = message
    context
  end

  step "its first message is the task prompt", context do
    [message | _] = messages(context, "subagent")
    assert message["text"] == context.task
    context
  end

  # The thread the scenario just made: a batch-created one, else the subagent.
  step "its title is {string}", %{args: [title]} = context do
    case context[:titled] do
      nil -> assert World.thread(context, "subagent")["title"] == title
      id -> World.await_row(id, &(&1["title"] == title))
    end

    context
  end

  step "the subagent thread's title is the first 80 characters", context do
    assert World.thread(context, "subagent")["title"] == String.slice(context.line, 0, 80)
    context
  end

  step "the subagent thread works in worktree {string}", %{args: [path]} = context do
    assert World.thread(context, "subagent")["worktreePath"] == context.worktrees[path]
    context
  end

  step "the subagent runs on {string} with the caller's model", %{args: [instance]} = context do
    selection = World.thread(context, "subagent")["modelSelection"]
    assert selection["instanceId"] == instance
    assert selection["model"] == World.thread(context, "parent")["modelSelection"]["model"]
    context
  end

  step "the subagent runs on {string} with that provider's default model",
       %{args: [instance]} = context do
    default =
      HalC2.Environment.providers()
      |> Enum.find(&(&1["instanceId"] == instance))
      |> Map.fetch!("models")
      |> Enum.find(& &1["isDefault"])

    assert World.thread(context, "subagent")["modelSelection"] == %{
             "instanceId" => instance,
             "model" => default["slug"]
           }

    context
  end

  step "{string} has a subagent task owned by the app with a node and a turn item",
       %{args: [parent]} = context do
    state = World.state(context, parent)
    task = task(context)
    assert task["origin"] == "app_owned"
    assert StreamState.get(state, "node")[task["id"]]["kind"] == "subagent"

    assert Enum.any?(
             StreamState.list(state, "turn-item"),
             &(&1["type"] == "subagent" and &1["subagentId"] == task["id"])
           )

    context
  end

  step "the task id starts with {string}", %{args: [prefix]} = context do
    assert String.starts_with?(context.task_id, prefix)
    context
  end

  step "the tool fails with code {string}", %{args: [code]} = context do
    assert {:error, ^code, _} = context.mcp_result
    context
  end

  step "the wait returns status completed with summary {string}", %{args: [summary]} = context do
    assert {:ok, %{"status" => "completed", "summary" => ^summary} = result} =
             Task.await(context.wait)

    refute result["waitTimedOut"]
    context
  end

  step "the wait returns the task as working and says the wait timed out", context do
    assert {:ok, %{"workState" => "working", "waitTimedOut" => true}} = context.wait_result
    context
  end

  # A child that keeps working holds the wait for its whole budget: short budgets are
  # waited out, the long ones (which the scenario cannot sit through) are read from
  # the budget the call used.
  step ~r/^the wait lasts at most (?<used>\S+) ms$/, %{args: [used]} = context do
    used = number(used)

    if used <= 5_000 do
      assert {:ok, %{"waitTimedOut" => true}} = Task.await(context.wait, used + 5_000)
      assert System.monotonic_time(:millisecond) - context.wait_started < used + 1_000
    else
      assert Task.yield(context.wait, 0) == nil
      assert HalC2.Orchestration.Delegation.wait_budget(context.asked) == used
    end

    context
  end

  step "{string} receives a system message carrying the delegated task result {string}",
       %{args: [parent, result]} = context do
    message = await_result_message(context, parent)
    assert message["createdBy"] == "system"
    assert message["text"] =~ ~s(taskId="#{context.task_id}")
    assert message["text"] =~ "\n#{result}\n"
    Map.put(context, :result_message, message)
  end

  step "{string} receives the delegated task result as a message",
       %{args: [parent]} = context do
    message = await_result_message(context, parent)
    assert message["text"] =~ ~s(taskId="#{context.task_id}")
    context
  end

  step "the message runs after the caller's active turn", context do
    assert [%{"status" => "running"}, %{"status" => "queued"} = queued] =
             World.runs(context, "parent")

    assert queued["id"] == context.result_message["runId"]
    context
  end

  step "the task delivery is {string}", %{args: [delivery]} = context do
    await_task(context, &(&1["completionDelivery"]["state"] == delivery))
    context
  end

  step "no result message is queued into {string}", %{args: [parent]} = context do
    assert {:ok, %{"status" => "completed"}} = Task.await(context.wait)
    assert [%{"status" => "running"}] = World.runs(context, parent)
    refute Enum.any?(messages(context, parent), &(&1["text"] =~ "<delegated_task_result"))
    context
  end

  step "the task summary is the last one", context do
    assert {:ok, %{"summary" => "Second"}} =
             World.mcp_tool(context, "parent", "task_status", %{"taskId" => context.task_id})

    context
  end

  step "the user rolled back the task's turn in its thread", context do
    roll_back(context)
    context
  end

  step "the subagent completes while its caller is too busy to hear it", context do
    complete_unheard(context, fn -> :ok end)
  end

  step "the subagent completes, and the user rolls back its turn before the caller hears it",
       context do
    complete_unheard(context, fn -> roll_back(context) end)
  end

  step "the subagent completes, and the user rolls back its turn and asks again before the caller hears it",
       context do
    complete_unheard(context, fn ->
      roll_back(context)
      World.send_turn(context, "subagent", "wait for it")
      World.await_runs(context, "subagent", ["rolled_back", "running"])
      cancel_queued_turn(context)
    end)
  end

  step "{string} is told the task was cancelled without an answer",
       %{args: [parent]} = context do
    message = await_result_message(context, parent)
    assert message["text"] =~ ~s(status="cancelled")
    assert message["text"] =~ "\n(no answer)\n"
    context
  end

  step "the task ended when its child's turn did", context do
    task = task(context)
    child = World.await_stream(task["childThreadId"], & &1)
    run = child |> HalC2.StreamState.list("run") |> Enum.max_by(& &1["ordinal"])
    assert task["completedAt"] == run["completedAt"]
    context
  end

  step "the task summary is {string}", %{args: [summary]} = context do
    assert task(context)["result"] == summary
    context
  end

  # The task as its caller had it before the child's end reached it.
  # Ends the caller's turns first, including the one the result woke.
  step "the caller was never told the task ended", context do
    open = %{"status" => "running", "completedAt" => nil}
    parent = World.thread_id(context, context.task_parent)
    quiet(parent, 10)

    {:ok, _} =
      HalC2.Streams.commit(parent, :thread, [
        {"subagent", context.task_id,
         %{
           "s" =>
             Map.merge(open, %{
               "result" => nil,
               "completionDelivery" => %{"state" => "pending", "observedByRunId" => nil}
             })
         }},
        {"node", context.task_id, %{"s" => open}},
        {"turn-item", "turn-item:subagent:#{context.task_id}", %{"s" => open}}
      ])

    context
  end

  step "the delivered result says there was no answer", context do
    message = await_result_message(context, "parent")
    assert message["text"] =~ ~s(status="failed")
    assert message["text"] =~ "\n(no answer)\n"
    context
  end

  step "the agent asks for the task's status", context do
    Map.put(context, :mcp_result, status(context))
  end

  step "it sees the child thread, provider, model, status and whether child runs are pending",
       context do
    assert {:ok, status} = context.mcp_result
    assert status["childThreadId"] == World.thread_id(context, "subagent")
    assert status["providerInstanceId"] == "codex"
    assert status["model"] == "gpt-5.4"
    assert status["status"] == "running"
    assert status["hasPendingChildRuns"] == true
    context
  end

  step "the work state is {string} until the task ends and {string} after",
       %{args: [working, done]} = context do
    assert {:ok, %{"workState" => ^working}} = context.mcp_result
    complete(context, "Done")
    assert {:ok, %{"workState" => ^done, "hasPendingChildRuns" => false}} = status(context)
    context
  end

  step "the agent in {string} asks for the status of task {string}",
       %{args: [caller, task_id]} = context do
    result = World.mcp_tool(context, caller, "task_status", %{"taskId" => task_id})
    Map.put(context, :mcp_result, result)
  end

  step "the agent cancels the task", context do
    result = World.mcp_tool(context, "parent", "task_cancel", %{"taskId" => context.task_id})
    Map.put(context, :mcp_result, result)
  end

  step "the subagent's turn is interrupted", context do
    assert {:ok, _} = context.mcp_result
    World.await_runs(context, "subagent", ["interrupted"])
    context
  end

  step "the task is cancelled and its delivery disposed", context do
    task = task(context)
    assert task["status"] == "cancelled"
    assert task["completionDelivery"]["state"] == "disposed"
    context
  end

  # --- delivery commands ---------------------------------------------------------------

  step "the wake policy is changed to always", context do
    {reply, context} = World.dispatch(context, wake_command(context, "always"))
    assert {:ok, _} = reply
    await_task(context, &(&1["completionWake"] == "always"))
    context
  end

  step "the result is delivered as a message when the task ends", context do
    complete(context, "Done")
    await_task(context, &(&1["completionDelivery"]["state"] == "delivered"))
    assert await_result_message(context, "parent")["text"] =~ "\nDone\n"
    assert {:ok, %{"status" => "completed"}} = Task.await(context.wait)
    context
  end

  step "a delegated task of {string} finished with a delivered result",
       %{args: [parent]} = context do
    context = delegate(context, parent, %{"mode" => "async"})
    complete(context, "Done")
    await_task(context, &(&1["completionDelivery"]["state"] == "delivered"))
    message = await_result_message(context, parent)
    assert Enum.any?(World.runs(context, parent), &(&1["userMessageId"] == message["id"]))
    Map.put(context, :result_message, message)
  end

  step "the caller acknowledges the delivery naming the run that saw it", context do
    [seen | _] = World.runs(context, "parent")

    {reply, context} =
      World.dispatch(context, delivery_command(context, "acknowledge", seen["id"]))

    assert {:ok, _} = reply
    Map.put(context, :seen_run, seen["id"])
  end

  step "the task records which run observed its result", context do
    assert task(context)["completionDelivery"] == %{
             "state" => "acknowledged",
             "observedByRunId" => context.seen_run
           }

    # The agent has the result, so its queued result message is not run.
    World.await_state(context, "parent", fn state ->
      Enum.any?(
        StreamState.list(state, "run"),
        &(&1["userMessageId"] == context.result_message["id"] and &1["status"] == "cancelled")
      )
    end)

    context
  end

  step "disposing a delivery stops it from being delivered again", context do
    {reply, context} = World.dispatch(context, delivery_command(context, "dispose"))
    assert {:ok, _} = reply

    assert %{"state" => "disposed", "observedByRunId" => nil} =
             task(context)["completionDelivery"]

    # Acknowledging a disposed delivery leaves it disposed.
    {reply, context} = World.dispatch(context, delivery_command(context, "acknowledge", nil))
    assert {:ok, _} = reply
    assert task(context)["completionDelivery"]["state"] == "disposed"

    # A task disposed while it works sends no result when it ends.
    context = delegate(context, "parent", %{"mode" => "async"})
    {reply, context} = World.dispatch(context, delivery_command(context, "dispose"))
    assert {:ok, _} = reply
    complete(context, "Late")
    assert task(context)["completionDelivery"]["state"] == "disposed"
    refute Enum.any?(messages(context, "parent"), &(&1["text"] =~ context.task_id))
    context
  end

  step "a delegated task result was delivered into {string} as a message",
       %{args: [parent]} = context do
    context = delegate(context, parent, %{"mode" => "async"})
    complete(context, "Done")
    message = await_result_message(context, parent)
    assert message["delegatedCompletion"]["taskIds"] == [context.task_id]
    assert message["delegatedCompletion"]["acceptedAt"] == nil
    Map.put(context, :result_message, message)
  end

  step "the provider accepts the delivery", context do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "notification.delivery.accept",
        "commandId" => "command:mailbox-accepted:#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, "parent"),
        "messageId" => context.result_message["id"]
      })

    context
  end

  step "the message is recorded as accepted, separately from the agent reading it", context do
    message =
      StreamState.get(World.state(context, "parent"), "message")[context.result_message["id"]]

    assert is_binary(message["delegatedCompletion"]["acceptedAt"])

    assert task(context)["completionDelivery"] == %{
             "state" => "delivered",
             "observedByRunId" => nil
           }

    context
  end

  step "a client requests a delegated task for the active run of {string}",
       %{args: [parent]} = context do
    [run] = World.runs(context, parent)
    thread = World.thread(context, parent)

    {reply, context} =
      World.dispatch(context, %{
        "type" => "delegated_task.request",
        "parentThreadId" => thread["id"],
        "parentRunId" => run["id"],
        "parentNodeId" => run["rootNodeId"],
        "task" => "wait for it",
        "modelSelection" => thread["modelSelection"],
        "runtimeMode" => thread["runtimeMode"],
        "interactionMode" => thread["interactionMode"]
      })

    assert {:ok, _} = reply
    context |> Map.put(:task, "wait for it") |> await_child(parent)
  end

  step "a subagent thread starts as if the agent had delegated it", context do
    child = World.thread(context, "subagent")
    parent_id = World.thread_id(context, "parent")

    assert %{"parentThreadId" => ^parent_id, "relationshipToParent" => "subagent"} =
             child["lineage"]

    World.await_runs(context, "subagent", ["running"])
    assert [%{"text" => "wait for it"} | _] = messages(context, "subagent")

    assert %{"origin" => "app_owned", "status" => "running", "childThreadId" => child_id} =
             task(context)

    assert child_id == child["id"]
    assert {:ok, %{"workState" => "working"}} = status(context)
    context
  end

  # --- helpers -----------------------------------------------------------------------

  # Calls delegate_task; a waiting call runs in a task (`context.wait`) until the step
  # that ends it. Once the child exists it is the scenario's "subagent" thread.
  defp delegate(context, caller, input) do
    input =
      %{"task" => "wait for it"}
      |> Map.merge(context[:delegate_input] || %{})
      |> Map.merge(input)

    context = Map.put(context, :task, input["task"])

    if input["mode"] == "wait" do
      started = System.monotonic_time(:millisecond)
      wait = Task.async(fn -> World.mcp_tool(context, caller, "delegate_task", input) end)
      await_child(Map.merge(context, %{wait: wait, wait_started: started}), caller)
    else
      case World.mcp_tool(context, caller, "delegate_task", input) do
        {:ok, %{"taskId" => _}} = result ->
          context |> Map.put(:mcp_result, result) |> await_child(caller)

        result ->
          Map.put(context, :mcp_result, result)
      end
    end
  end

  # The caller's newest task; an earlier one keeps its place under `:tasks`.
  defp await_child(context, caller) do
    known = Map.values(context[:tasks] || %{})
    fresh = fn state -> Enum.reject(StreamState.list(state, "subagent"), &(&1["id"] in known)) end
    state = World.await_state(context, caller, &(fresh.(&1) != []))
    [task] = fresh.(state)
    World.await_row(task["childThreadId"], & &1)
    context = put_in(context, [Access.key(:tasks, %{}), task["id"]], task["id"])

    context
    |> put_in([:threads, "subagent"], task["childThreadId"])
    |> Map.merge(%{task_id: task["id"], task_parent: caller})
  end

  defp task(context),
    do: StreamState.get(World.state(context, context.task_parent), "subagent")[context.task_id]

  defp await_task(context, fun) do
    World.await_state(context, context.task_parent, fn state ->
      task = StreamState.get(state, "subagent")[context.task_id]
      task != nil and fun.(task)
    end)
  end

  defp status(context),
    do:
      World.mcp_tool(context, context.task_parent, "task_status", %{"taskId" => context.task_id})

  # Steers the working child with an answer, which ends its turn.
  defp complete(context, answer) do
    World.await_runs(context, "subagent", ["running"])
    World.send_turn(context, "subagent", "say " <> answer)
    await_task(context, &(&1["status"] == "completed"))
    context
  end

  # Steers the working child of the task called `name` to its answer.
  defp complete_named(context, name) do
    task_id = context.named_tasks[name]
    World.await_runs(context, name, ["running"])
    World.send_turn(context, name, "say #{name} done")

    World.await_state(context, context.task_parent, fn state ->
      StreamState.get(state, "subagent")[task_id]["status"] == "completed"
    end)

    context
  end

  # The parent's finished runs that delivered the results of the tasks `names`, in that order.
  defp await_wakes(context, parent, names) do
    wakes = fn state ->
      messages = StreamState.get(state, "message")

      for name <- names do
        Enum.find(StreamState.list(state, "run"), fn run ->
          run["status"] == "completed" and
            (get_in(messages, [run["userMessageId"], "text"]) || "") =~
              ~s(taskId="#{context.named_tasks[name]}")
        end)
      end
    end

    context |> World.await_state(parent, &Enum.all?(wakes.(&1))) |> wakes.()
  end

  defp messages(context, thread) do
    context
    |> World.state(thread)
    |> StreamState.list("message")
    |> Enum.sort_by(& &1["createdAt"])
  end

  defp await_result_message(context, parent) do
    state =
      World.await_state(context, parent, fn state ->
        Enum.any?(StreamState.list(state, "message"), &(&1["text"] =~ "<delegated_task_result"))
      end)

    Enum.find(StreamState.list(state, "message"), &(&1["text"] =~ "<delegated_task_result"))
  end

  defp wake_command(context, wake) do
    %{
      "type" => "delegated_task.wake-policy",
      "parentThreadId" => World.thread_id(context, context.task_parent),
      "taskId" => context.task_id,
      "completionWake" => wake
    }
  end

  defp delivery_command(context, action, observed \\ nil) do
    %{
      "type" => "delegated_task.completion-delivery.#{action}",
      "parentThreadId" => World.thread_id(context, context.task_parent),
      "taskId" => context.task_id
    }
    |> then(&if(action == "acknowledge", do: Map.put(&1, "observedByRunId", observed), else: &1))
  end

  defp number(text), do: text |> String.replace(",", "") |> String.to_integer()

  # Completes the task's child with its caller's stream held, so the report of its
  # end times out, and holds that report at its retry; `meanwhile` runs before it.
  # The caller has no result until the retry.
  defp complete_unheard(context, meanwhile) do
    parent_id = World.thread_id(context, context.task_parent)
    parent = HalC2.Streams.ensure(parent_id)
    World.await_runs(context, "subagent", ["running"])
    gate = :"delegation_retry_gate_#{System.unique_integer([:positive])}"
    :ok = :logger.add_handler(gate, __MODULE__.RetryGate, %{config: self()})
    :sys.suspend(parent)

    # A failing step leaves neither the gate nor a held stream to the next scenario.
    ExUnit.Callbacks.on_exit(fn ->
      :logger.remove_handler(gate)
      catch_exit(:sys.resume(parent))
    end)

    World.send_turn(context, "subagent", "say Done")
    assert_receive {:retrying, reporter}, 15_000
    :logger.remove_handler(gate)
    :sys.resume(parent)

    refute Enum.any?(
             StreamState.list(World.state(context, context.task_parent), "message"),
             &(&1["text"] =~ "<delegated_task_result")
           )

    assert task(context)["status"] == "running"
    meanwhile.()
    ref = Process.monitor(reporter)
    send(reporter, :retry)
    assert_receive {:DOWN, ^ref, _, _, _}, 15_000

    result =
      context
      |> World.state(context.task_parent)
      |> StreamState.list("message")
      |> Enum.find(&(&1["text"] =~ "<delegated_task_result"))

    Map.put(context, :result_message, result)
  end

  # A turn the user queued in the child behind the running one, then cancelled: the
  # child's newest run, and an ended one.
  defp cancel_queued_turn(context) do
    child = task(context)["childThreadId"]
    ordinal = child |> World.await_stream(& &1) |> StreamState.list("run") |> length()
    at = HalC2.Orchestration.Entities.now()

    {:ok, _} =
      HalC2.Streams.commit(child, :thread, [
        {"run", "run:cancelled",
         %{
           "s" => %{
             "id" => "run:cancelled",
             "threadId" => child,
             "ordinal" => ordinal + 1,
             "status" => "cancelled",
             "completedAt" => at,
             "updatedAt" => at
           }
         }}
      ])
  end

  defp roll_back(context) do
    child = task(context)["childThreadId"]
    runs = child |> World.await_stream(& &1) |> StreamState.list("run")

    {:ok, _} =
      HalC2.Streams.commit(
        child,
        :thread,
        for(run <- runs, do: {"run", run["id"], %{"s" => %{"status" => "rolled_back"}}})
      )
  end

  defp quiet(thread_id, attempts) do
    HalC2.Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})

    World.await_stream(
      thread_id,
      fn state ->
        runs = HalC2.StreamState.list(state, "run")
        if Enum.all?(runs, &(&1["status"] not in ~w(running queued))), do: state
      end,
      500
    )
  rescue
    error ->
      if attempts > 1, do: quiet(thread_id, attempts - 1), else: reraise(error, __STACKTRACE__)
  end
end

defmodule HalC2.Steps.Orchestration.Delegation.RetryGate do
  @moduledoc "A logger handler that holds a delegated task report at its retry."
  def log(%{msg: msg}, %{config: test}) do
    text = msg |> elem(1) |> IO.chardata_to_string()

    if text =~ "delegated task report" do
      # Released by the scenario, or by its end if it failed first.
      ref = Process.monitor(test)
      send(test, {:retrying, self()})

      receive do
        :retry -> :ok
        {:DOWN, ^ref, _, _, _} -> :ok
      end

      Process.demonitor(ref, [:flush])
    end
  rescue
    _ -> :ok
  end
end
