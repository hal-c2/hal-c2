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

  # The session of the subagent the fake Grok spawns in the background (`fake_acp.py`).
  @grok_child_session "0f8e2a4c-5b6d-4e7f-8a9b-1c2d3e4f5a6b"

  @grok_models %{
    "id" => "model",
    "name" => "Model",
    "type" => "select",
    "currentValue" => "grok-code-fast-1",
    "options" => [%{"value" => "grok-code-fast-1", "name" => "Grok Code Fast"}]
  }

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
    assert_status(context, status)
  end

  # The task's own status and its node's and timeline item's agree.
  defp assert_status(context, status) do
    state = World.state(context, context.task_parent)
    assert task(context)["status"] == status
    assert StreamState.get(state, "node")[context.task_id]["status"] == status

    assert StreamState.get(state, "turn-item")["turn-item:subagent:#{context.task_id}"]["status"] ==
             status

    context
  end

  step "the task, its node and its turn item end {string}", %{args: [status]} = context do
    await_task(context, &(&1["status"] == status))
    assert_status(context, status)
  end

  # The agent finishes its turn (a steer it answers), as distinct from the user
  # stopping it: only the stop keeps its tasks from waking it later.
  step "the turn of {string} ended", %{args: [thread]} = context do
    World.send_turn(context, thread, "say Carrying on")
    World.await_runs(context, thread, ["completed"])
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

  step "the agent in {string} delegates with its prompt under another name",
       %{args: [caller]} = context do
    input = %{"prompt" => "Write the migration", "title" => "Migration"}
    Map.put(context, :mcp_result, World.mcp_tool(context, caller, "delegate_task", input))
  end

  # --- a Claude subagent's calls ------------------------------------------------------

  # Claude's turn in `thread` stays open ("wait for it"); in it Claude starts a subagent
  # (tool use agent-1), which calls `delegate_task` (tool use sub-call-1).
  step "thread {string} on {string} has a subagent running",
       %{args: [thread, "claudeAgent"]} = context do
    selection = %{"instanceId" => "claudeAgent", "model" => "claude-sonnet-4-6"}

    context =
      World.launch_titled(context, thread, nil, "wait for it", %{"modelSelection" => selection})

    World.await_runs(context, thread, ["running"])

    claude_says(context, thread, [
      claude_tool_use(nil, "agent-1", "Agent", %{"prompt" => "Fan out"}),
      %{
        "type" => "system",
        "subtype" => "task_started",
        "task_id" => "task-agent-1",
        "tool_use_id" => "agent-1",
        "prompt" => "Fan out",
        "task_type" => "local_agent"
      },
      claude_tool_use("agent-1", "sub-call-1", "mcp__hal-c2__delegate_task", %{
        "task" => "wait for it"
      })
    ])

    context
  end

  step "the subagent in {string} delegates a task", %{args: [thread]} = context do
    Map.put(context, :mcp_result, claude_delegates(context, thread, "sub-call-1"))
  end

  step "Claude in {string} delegates a task itself", %{args: [thread]} = context do
    claude_says(context, thread, [
      claude_tool_use(nil, "own-call-1", "mcp__hal-c2__delegate_task", %{"task" => "wait for it"})
    ])

    Map.put(context, :mcp_result, claude_delegates(context, thread, "own-call-1"))
  end

  step "the refusal says a native subagent can't own HAL-C2 workers and to start such work with delegate_task",
       context do
    assert {:error, _, message} = context.mcp_result
    assert message =~ "A native subagent can't own HAL-C2 workers"
    assert message =~ "nothing can wake it"
    assert message =~ "must itself be started with delegate_task"
    context
  end

  step "{string} has no delegated task", %{args: [caller]} = context do
    assert [%{"origin" => "provider_native"}] =
             StreamState.list(World.stream(context, caller), "subagent")

    context
  end

  step "{string} has a delegated task", %{args: [caller]} = context do
    assert {:ok, %{"taskId" => task}} = context.mcp_result

    assert task in Enum.map(
             StreamState.list(World.stream(context, caller), "subagent"),
             & &1["id"]
           )

    context
  end

  step "{string} has no subagent task", %{args: [caller]} = context do
    assert StreamState.list(World.stream(context, caller), "subagent") == []
    context
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

  # A caller on another provider than the background's Codex parent; the wait is
  # synchronous, so a wait the caller's cap does not cut short holds the scenario.
  step "the agent in {string} on {string} delegates a task to {string} and waits 2 hours",
       %{args: [caller, instance, target]} = context do
    input = %{
      "task" => "wait for it",
      "mode" => "wait",
      "timeoutMs" => 2 * 60 * 60 * 1_000,
      "target" => %{"providerInstanceId" => target}
    }

    result = World.mcp_tool(context, caller, "delegate_task", input, instance)
    Map.put(context, :wait_result, result)
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

  step "the agent in {string} delegated tasks {string}, {string}, {string} and {string} without waiting",
       %{args: [caller | names]} = context do
    named_tasks(context, caller, names)
  end

  step "{string} was woken for the completion of {string}", %{args: [parent, name]} = context do
    context = complete_named(context, name)
    # The caller's own turn ends, and the result runs as its next turn.
    World.send_turn(context, parent, "say Carrying on")
    [wake] = await_wakes(context, parent, [name])
    Map.put(context, :last_wake, wake)
  end

  # The caller's busy turn holds the wake for `first` in its queue, so `second` joins
  # it whatever the timing. Were the caller idle, that wake could run and end before
  # `second` lands, and `second` would get a wake of its own (#634).
  step "{string} and {string} complete afterwards, while {string} works on another turn",
       %{args: [first, second, parent]} = context do
    ended = Enum.map(World.runs(context, parent), & &1["status"])
    World.send_turn(context, parent, "wait for it")
    World.await_runs(context, parent, ended ++ ["running"])
    context = context |> complete_named(first) |> complete_named(second)
    World.send_turn(context, parent, "say Carrying on")
    Map.put(context, :later, [first, second])
  end

  step "{string} is woken again for them", %{args: [parent]} = context do
    wakes = await_wakes(context, parent, context.later)
    assert Enum.all?(wakes, &(&1["ordinal"] > context.last_wake["ordinal"]))
    Map.put(context, :later_wakes, wakes)
  end

  step "{string} finishes after the wake for them ended", %{args: [name]} = context do
    await_wakes(context, context.task_parent, context.later)
    context = complete_named(context, name)
    await_wakes(context, context.task_parent, [name])
    context
  end

  # Every task's result is in one wake of the caller that ran, and in no other message.
  step "each task's result reached {string} in exactly one wake turn",
       %{args: [parent]} = context do
    runs = Map.new(World.runs(context, parent), &{&1["id"], &1})

    for {_name, task_id} <- context.named_tasks do
      assert [message] =
               Enum.filter(messages(context, parent), &(&1["text"] =~ ~s(taskId="#{task_id}")))

      assert task_id in message["delegatedCompletion"]["taskIds"]
      assert runs[message["runId"]]["status"] == "completed"
    end

    context
  end

  step "every task's delivery is {string}", %{args: [delivery]} = context do
    tasks = StreamState.get(World.state(context, context.task_parent), "subagent")

    for {_name, task_id} <- context.named_tasks,
        do: assert(tasks[task_id]["completionDelivery"]["state"] == delivery)

    context
  end

  # Each result is delivered once, and two that land together ride one turn.
  step "completions that arrive together share one wake turn", context do
    assert [_] = Enum.uniq_by(context.later_wakes, & &1["id"])

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

  step "its first message ends with the task prompt", context do
    [message | _] = messages(context, "subagent")
    assert String.ends_with?(message["text"], context.task)
    context
  end

  step "the subagent's first message names {string} as the thread that delegated it",
       %{args: [parent]} = context do
    [message | _] = messages(context, "subagent")
    assert message["text"] =~ ~s(delegated by the thread "#{parent}")
    context
  end

  step "it says the final message is the report to that thread", context do
    [message | _] = messages(context, "subagent")
    assert message["text"] =~ "final message is your report"
    context
  end

  step "it says to finish its own work, including its own workers, before the last turn",
       context do
    [message | _] = messages(context, "subagent")

    assert message["text"] =~
             "Finish your own work, including waiting on your background work and your own workers"

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

  # --- workspaces -----------------------------------------------------------------

  step "the agent in {string} delegates a task with workspace {string}",
       %{args: [caller, json]} = context do
    context
    |> World.worktree_setup()
    |> delegate(caller, %{"mode" => "async", "workspace" => workspace_input(context, json)})
  end

  step "the agent in {string} delegated a task with workspace {string}",
       %{args: [caller, json]} = context do
    context
    |> World.worktree_setup()
    |> delegate(caller, %{"mode" => "async", "workspace" => workspace_input(context, json)})
  end

  step "the task asks for the workspace {string}", %{args: [json]} = context do
    context = World.worktree_setup(context)
    input = Map.put(context[:delegate_input] || %{}, "workspace", workspace_input(context, json))
    Map.put(context, :delegate_input, input)
  end

  step "the task's caller {string} works in the project root", %{args: [thread]} = context do
    World.patch_thread(context, thread, %{"worktreePath" => nil})
    context
  end

  step "the subagent thread works in the project root", context do
    assert World.thread(context, "subagent")["worktreePath"] == nil
    context
  end

  step "the task's caller {string} is approval-required", %{args: [thread]} = context do
    World.patch_thread(context, thread, %{"runtimeMode" => "approval-required"})
    context
  end

  step "{string} has a commit that is not on any other branch", %{args: [thread]} = context do
    path = World.thread(context, thread)["worktreePath"]
    File.write!(Path.join(path, "local.txt"), "local\n")
    World.git!(path, ["add", "local.txt"])
    World.git!(path, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "local"])
    Map.put(context, :local_commit, World.git!(path, ["rev-parse", "HEAD"]))
  end

  step "the project has another worktree {string} on branch {string}",
       %{args: [path, branch]} = context do
    dir = Mc.tmp_dir(context.mc, "other")
    World.git!(World.project(context).root, ["worktree", "add", "-q", "-b", branch, dir])
    Map.update(context, :worktrees, %{path => dir}, &Map.put(&1, path, dir))
  end

  step "the subagent thread works in a new worktree other than {string}",
       %{args: [path]} = context do
    child = World.await_row(World.thread_id(context, "subagent"), & &1["worktreePath"])
    assert child["worktreePath"] != context.worktrees[path]
    assert File.dir?(child["worktreePath"])
    context
  end

  step "that worktree has the caller's commit", context do
    path = World.thread(context, "subagent")["worktreePath"]
    assert World.git!(path, ["rev-parse", "HEAD"]) == context.local_commit
    context
  end

  step "the task's status reports that worktreePath and branch", context do
    child = World.thread(context, "subagent")
    assert {:ok, status} = status(context)
    assert status["worktreePath"] == child["worktreePath"]
    assert status["branch"] == child["branch"]
    assert status["workspace"] == "worktree"
    refute status["worktreePath"] == World.thread(context, "parent")["worktreePath"]
    context
  end

  step "the subagent's first turn starts in it, after it was prepared", context do
    World.await_runs(context, "subagent", ["running"])
    child = World.thread(context, "subagent")
    assert child["worktreePath"]
    [turn] = StreamState.list(World.state(context, "subagent"), "provider-turn")
    assert turn
    context
  end

  step "the subagent thread works in a new worktree on branch {string}",
       %{args: [branch]} = context do
    child = World.await_row(World.thread_id(context, "subagent"), & &1["worktreePath"])
    assert child["branch"] == branch
    assert File.dir?(child["worktreePath"])
    context
  end

  step "the subagent thread works in worktree {string} on branch {string}",
       %{args: [path, branch]} = context do
    child = World.thread(context, "subagent")
    assert child["worktreePath"] == context.worktrees[path]
    assert child["branch"] == branch
    context
  end

  step "the project has no worktree besides {string}", %{args: [path]} = context do
    listed =
      context
      |> World.project()
      |> Map.fetch!(:root)
      |> World.git!(["worktree", "list", "--porcelain"])
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "worktree "))
      |> Enum.map(&String.replace_prefix(&1, "worktree ", ""))

    assert Enum.sort(listed) == Enum.sort([World.project(context).root, context.worktrees[path]])
    context
  end

  # The project's post-checkout hook fails, so `git worktree add` fails.
  step "adding the next worktree fails", context do
    context = World.worktree_setup(context)
    hook = Path.join([World.project(context).root, ".git", "hooks", "post-checkout"])
    File.mkdir_p!(Path.dirname(hook))
    File.write!(hook, "#!/bin/sh\nexit 1\n")
    File.chmod!(hook, 0o755)
    context
  end

  # The hook waits for the gate file, which opens when the scenario ends.
  step "the next worktree is held while it is prepared", context do
    context = World.worktree_setup(context)
    dir = Mc.tmp_dir(context.mc, "gate")
    gate = Path.join(dir, "open")
    hook = Path.join([World.project(context).root, ".git", "hooks", "post-checkout"])
    File.mkdir_p!(Path.dirname(hook))

    File.write!(hook, """
    #!/bin/sh
    i=0
    while [ ! -f '#{gate}' ] && [ -d '#{dir}' ] && [ $i -lt 1500 ]; do sleep 0.02; i=$((i+1)); done
    """)

    File.chmod!(hook, 0o755)
    ExUnit.Callbacks.on_exit(fn -> File.write(gate, "") end)
    context
  end

  # Cancelled once the checkout is under way, held at the hook.
  step "the worktree setup is cancelled", context do
    child = World.thread_id(context, "subagent")

    checking_out? = fn snapshot ->
      snapshot &&
        Enum.any?(snapshot["stages"], &(&1["id"] == "checkout" and &1["status"] == "running"))
    end

    snapshot = HalC2.WorktreeSetup.subscribe(child, self())

    unless checking_out?.(snapshot) do
      receive_setup = fn receive_setup ->
        receive do
          {:hal_c2_worktree_setup, ^child, snapshot} ->
            if checking_out?.(snapshot), do: :ok, else: receive_setup.(receive_setup)
        after
          10_000 -> flunk("the worktree setup never got to the checkout")
        end
      end

      receive_setup.(receive_setup)
    end

    {reply, context} = World.call(context, "worktreeSetup.cancel", %{"threadId" => child})
    assert {:ok, %{"cancelled" => true}} = reply
    context
  end

  step "the task ends {string} with the result {string}",
       %{args: [status, text]} = context do
    await_task(context, &(&1["status"] == status))
    task = task(context)

    assert task["result"] =~ text
    assert task["completionDelivery"]["state"] == "delivered"
    context
  end

  # Its caller has heard the task failed, and may have given the work to another agent.
  step "retrying the subagent's setup is refused", context do
    child = World.thread_id(context, "subagent")
    {reply, context} = World.call(context, "worktreeSetup.retry", %{"threadId" => child})
    assert {:ok, %{"retried" => false}} = reply

    assert %{"stages" => stages} = HalC2.WorktreeSetup.subscribe(child, self())
    assert Enum.find(stages, &(&1["id"] == "agent"))["status"] == "skipped"
    context
  end

  step "the subagent never ran", context do
    state = World.state(context, "subagent")
    assert StreamState.list(state, "provider-turn") == []
    refute Enum.any?(StreamState.list(state, "run"), &(&1["status"] in ~w(running completed)))
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
  step "thread {string} runs on Codex", %{args: [thread]} = context do
    assert World.thread(context, thread)["modelSelection"]["instanceId"] == "codex"
    context
  end

  step "the agent in {string} delegates a task and waits {int} minutes",
       %{args: [caller, minutes]} = context do
    input = %{"mode" => "wait", "timeoutMs" => minutes * 60_000}
    context |> delegate(caller, input) |> Map.put(:asked, input["timeoutMs"])
  end

  # Ten minutes are not waited out: what would cut the wait at ten minutes is Codex's
  # tool limit (the `tool_timeout_sec` its session is given) or the MC's own cap, and
  # both are past the wait asked for.
  step "the subagent is still working after {int} minutes", %{args: [minutes]} = context do
    World.await_runs(context, "subagent", ["running"])

    budget =
      min(
        HalC2.Orchestration.Delegation.wait_budget(context.asked),
        HalC2.Mcp.max_wait_ms("codex")
      )

    assert budget == context.asked and budget > minutes * 60_000
    assert HalC2.Mcp.tool_timeout_ms() > budget
    context
  end

  step "the wait is still open", context do
    assert Task.yield(context.wait, 0) == nil
    assert task(context)["status"] == "running"
    context
  end

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

  step "the subagent completes and the first report of its end fails", context do
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

  step "a message is queued behind the subagent's turn", context do
    {{:ok, _}, context} = World.send_message(context, "subagent", "and another thing")
    context
  end

  step "the subagent's turn is interrupted and the message behind it cancelled", context do
    assert {:ok, _} = context.mcp_result
    World.await_runs(context, "subagent", ["interrupted", "cancelled"])
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
    assert [%{"text" => text} | _] = messages(context, "subagent")
    assert String.ends_with?(text, "wait for it")

    assert %{"origin" => "app_owned", "status" => "running", "childThreadId" => child_id} =
             task(context)

    assert child_id == child["id"]
    assert {:ok, %{"workState" => "working"}} = status(context)
    context
  end

  # --- work the subagent owes (hal-c2/hal-c2#508) ------------------------------------

  step "the agent in {string} delegated a task whose subagent left a command running in the background",
       %{args: [caller]} = context do
    context = delegate(context, caller, %{"mode" => "async"})
    World.await_runs(context, "subagent", ["running"])
    leave_background(context, "The dev server is running.")
  end

  step "the subagent's turn ended while a command it started is still running in the background",
       context do
    World.await_runs(context, "subagent", ["running"])
    leave_background(context, "The dev server is running.")
  end

  # The subagent's own task answers at once, and its result waits behind the subagent's
  # turn. The task is titled so the subagent's turn about it holds (the fake Codex keeps
  # a turn whose text says "wait" open).
  step "the subagent's turn ended while a task it delegated finished but that result has not reached it",
       context do
    context = delegate_own(context, %{"task" => "say Found it", "title" => "wait here"})
    World.await_state(context, "subagent", &own_settled?(&1, context))
    World.send_turn(context, "subagent", "say Waiting on my task.")
    World.await_runs(context, "subagent", ["completed", "running"])
    context
  end

  # Its turn about its own task answers with where it is ("where are we").
  step "the subagent's turn ended while a task it delegated itself is still working", context do
    context = delegate_own(context, %{"task" => "wait for it", "title" => "where are we"})

    World.await_stream(context.own_child, fn state ->
      Enum.map(StreamState.list(state, "run"), & &1["status"]) == ["running"]
    end)

    World.send_turn(context, "subagent", "say Waiting on my task.")
    World.await_row(World.thread_id(context, "subagent"), &(&1["pendingBackgroundTasks"] != []))
    context
  end

  step "the subagent's own task is done and the subagent's turn about it ends", context do
    own = Map.update!(context, :threads, &Map.put(&1, "own", context.own_child))
    World.send_turn(own, "own", "say Found it")
    await_task(context, &(&1["status"] == "completed"))
    context
  end

  step "the task summary is the answer of the subagent's turn about its own task", context do
    assert task(context)["result"] =~ ~r/^on native-thread-\d+ history /
    context
  end

  step "the agent in {string} asks for the task's status", %{args: [_caller]} = context do
    Map.put(context, :mcp_result, status(context))
  end

  step "the work state is {string}", %{args: [state]} = context do
    if state == "result_available", do: await_task(context, &(&1["status"] == "completed"))
    assert {:ok, %{"workState" => ^state}} = status(context)
    context
  end

  step "the task is still running and the work state is {string}", %{args: [state]} = context do
    assert {:ok, %{"status" => "running", "workState" => ^state}} = status(context)
    context
  end

  # Codex reports the command's exit; between turns the MC wakes Codex with a turn of
  # its own about it, which the fake answers "Hello from codex".
  step "the command ends and the subagent's turn about it ends", context do
    {_pid, runtime} = World.codex_runtime(context, "subagent")
    ordinal = length(World.runs(context, "subagent")) + 1

    World.codex_notify(context, "subagent", "item/completed", %{
      "threadId" => runtime.native_thread_id,
      "turnId" => "native-turn-1",
      "item" => %{
        "type" => "commandExecution",
        "id" => "cmd-bg",
        "command" => "npm run dev",
        "status" => "completed",
        "aggregatedOutput" => "bye",
        "exitCode" => 0
      }
    })

    World.await_state(context, "subagent", fn state ->
      Enum.any?(
        StreamState.list(state, "run"),
        &(&1["ordinal"] == ordinal and &1["status"] == "completed")
      )
    end)

    await_task(context, &(&1["status"] == "completed"))
    context
  end

  step "{string} receives one result message, with the answer of the subagent's turn about the command",
       %{args: [parent]} = context do
    await_result_message(context, parent)
    assert [message] = result_messages(context, parent)
    assert message["text"] =~ "\nHello from codex\n"
    context
  end

  step "no result message to {string} says {string}", %{args: [parent, text]} = context do
    refute Enum.any?(result_messages(context, parent), &(&1["text"] =~ text))
    context
  end

  step "the task summary is the answer of the subagent's turn about the command", context do
    assert task(context)["result"] == "Hello from codex"
    context
  end

  step "the subagent answered {string} with a turn to handle an update from a monitor queued behind it",
       %{args: [answer]} = context do
    World.await_runs(context, "subagent", ["running"])
    queue(context, "rate limit")
    end_turn(context, answer)
    context
  end

  step "that turn ends without a word", context do
    await_task(context, &(&1["status"] == "completed"))
    context
  end

  step "the subagent answered {string} and then {string}, with a third turn still working",
       %{args: [first, second]} = context do
    World.await_runs(context, "subagent", ["running"])
    queue(context, "say " <> second)
    queue(context, "wait for it")
    end_turn(context, first)
    World.await_runs(context, "subagent", ["completed", "completed", "running"])
    context
  end

  step "the subagent's second turn was rolled back before the task settled", context do
    [_, second, _] = World.runs(context, "subagent")
    child = World.thread_id(context, "subagent")

    {:ok, _} =
      HalC2.Streams.commit(child, :thread, [
        {"run", second["id"], %{"s" => %{"status" => "rolled_back"}}}
      ])

    assert task(context)["status"] == "running"
    context
  end

  step "the third turn ends without a word", context do
    {_pid, runtime} = World.codex_runtime(context, "subagent")

    World.codex_notify(context, "subagent", "turn/completed", %{
      "threadId" => runtime.native_thread_id,
      "turn" => %{"id" => runtime.turn.native_turn_id, "status" => "completed"}
    })

    await_task(context, &(&1["status"] == "completed"))
    context
  end

  # --- options on the caller's model ------------------------------------------------

  step "{string} runs with fast mode on", %{args: [thread]} = context do
    selection = World.thread(context, thread)["modelSelection"]

    World.patch_thread(context, thread, %{
      "modelSelection" => Map.put(selection, "options", [%{"id" => "fastMode", "value" => true}])
    })

    context
  end

  step "{string} delegates a task that sets the reasoning effort to {string}",
       %{args: [caller, effort]} = context do
    instance = World.thread(context, caller)["modelSelection"]["instanceId"]

    delegate(context, caller, %{
      "target" => %{
        "providerInstanceId" => instance,
        "options" => [%{"id" => "reasoningEffort", "value" => effort}]
      }
    })
  end

  step "{string} delegates a task on another model", %{args: [caller]} = context do
    %{"instanceId" => instance, "model" => model} =
      World.thread(context, caller)["modelSelection"]

    other =
      Enum.find_value(HalC2.Environment.providers(), fn provider ->
        provider["instanceId"] == instance &&
          Enum.find_value(provider["models"] || [], &(&1["slug"] != model && &1["slug"]))
      end) || flunk("#{instance} advertises no model besides #{model}")

    delegate(context, caller, %{
      "target" => %{"providerInstanceId" => instance, "model" => other}
    })
  end

  step "the subagent runs with effort {string} and fast mode on", %{args: [effort]} = context do
    assert {:ok, %{"taskId" => _}} = context.mcp_result
    options = subagent_options(context)
    assert options["reasoningEffort"] == effort
    assert options["fastMode"] == true
    context
  end

  step "the subagent runs without fast mode", context do
    assert {:ok, %{"taskId" => _}} = context.mcp_result
    refute Map.has_key?(subagent_options(context), "fastMode")
    context
  end

  defp subagent_options(context) do
    selection = World.thread(context, "subagent")["modelSelection"]
    Map.new(selection["options"] || [], &{&1["id"], &1["value"]})
  end

  # --- messages steered into a subagent -------------------------------------------

  step "a subagent is running a turn that no task is waiting on", context do
    context = delegate(context, "parent", %{"mode" => "async", "task" => "say Done"})
    await_task(context, &(&1["status"] == "completed"))
    World.send_turn(context, "subagent", "wait")
    World.await_runs(context, "subagent", ["completed", "running"])
    context
  end

  step "the parent sends it a message that steers the running turn", context do
    result =
      World.mcp_tool(context, "parent", "hal_c2_thread_send", %{
        "threadId" => World.thread_id(context, "subagent"),
        "message" => "Check the docs too"
      })

    Map.put(context, :mcp_result, result)
  end

  step "the parent is told the message was steered", context do
    assert {:ok, %{"delivery" => "steer_active"}} = context.mcp_result
    context
  end

  step "no task is opened for it", context do
    assert [%{"status" => "completed"}] =
             StreamState.list(World.state(context, "parent"), "subagent")

    context
  end

  step "the parent is not shown waiting on the subagent", context do
    parent = World.state(context, "parent")

    refute Enum.any?(
             StreamState.list(parent, "subagent"),
             &(&1["status"] in ~w(preparing starting running waiting))
           )

    refute HalC2.Orchestration.Delegation.working_task?(
             World.thread_id(context, "parent"),
             World.thread_id(context, "subagent")
           )

    context
  end

  # --- review rounds ----------------------------------------------------------------

  step "a delegated review task has finished", context do
    context
    |> delegate("parent", %{"task" => "Review the change"})
    |> complete("Looks good")
  end

  step "the parent wants the child to review again", context do
    Map.put(context, :instructions, HalC2.Mcp.instructions(false))
  end

  step "the instructions tell it to start a new delegated task with the full context and a new request id",
       context do
    assert context.instructions =~
             "start a new `delegate_task` with the full context and a new `clientRequestId`"

    context
  end

  step "cancelling the finished task leaves later runs of the child thread alone", context do
    World.send_turn(context, "subagent", "wait")
    World.await_runs(context, "subagent", ["completed", "running"])

    assert {:error, "task_not_cancellable", _} =
             World.mcp_tool(context, "parent", "task_cancel", %{"taskId" => context.task_id})

    assert ["completed", "running"] = Enum.map(World.runs(context, "subagent"), & &1["status"])
    assert task(context)["status"] == "completed"
    context
  end

  # --- access modes per provider ---------------------------------------------------

  step ~r/^"(?<thread>[^"]+)" is in (?<mode>full access|auto-accept edits)$/,
       %{args: [thread, mode]} = context do
    World.patch_thread(context, thread, %{"runtimeMode" => access_mode(mode)})
    context
  end

  step "the agent in {string} delegates a task to Muse Code asking for auto-accept edits",
       %{args: [caller]} = context do
    context
    |> with_muse()
    |> delegate(caller, %{
      "target" => %{"providerInstanceId" => "muse"},
      "runtimeMode" => "auto-accept-edits"
    })
  end

  step "the agent in {string} delegates a task to Muse Code without naming an access mode",
       %{args: [caller]} = context do
    context |> with_muse() |> delegate(caller, %{"target" => %{"providerInstanceId" => "muse"}})
  end

  step "the tool fails and lists the access modes Muse Code offers", context do
    assert {:error, "runtime_mode_unsupported", message} = context.mcp_result

    assert message =~ "approval-required, full-access"
    assert World.state(context, "parent") |> StreamState.list("subagent") == []
    context
  end

  # Muse offers approval-required and full access; auto-accept edits sits between them.
  step "the subagent runs in the broadest mode Muse Code offers that does not exceed {string}'s",
       context do
    assert {:ok, %{"taskId" => _}} = context.mcp_result
    assert World.thread(context, "subagent")["runtimeMode"] == "approval-required"
    context
  end

  step "an agent asks for the orchestrator's capabilities", context do
    context = with_muse(context)

    Map.put(
      context,
      :mcp_result,
      World.mcp_tool(context, "parent", "orchestrator_capabilities")
    )
  end

  step "each provider lists the access modes it offers", context do
    assert {:ok, %{"providers" => providers}} = context.mcp_result
    modes = Map.new(providers, &{&1["providerInstanceId"], &1["runtimeModes"]})
    assert modes["muse"] == ~w(approval-required full-access)
    assert modes["codex"] == ~w(approval-required auto-accept-edits auto full-access)
    context
  end

  defp access_mode("full access"), do: "full-access"
  defp access_mode("auto-accept edits"), do: "auto-accept-edits"

  # An enabled Muse Code with a model, so a task can name it.
  defp with_muse(context) do
    HalC2.Test.FakeAcp.services()
    context = HalC2.Test.FakeAcp.install_muse(context, %{}, enabled: true)

    {_, context} =
      HalC2.Test.FakeAcp.await_providers(
        context,
        &match?(%{"models" => [_ | _]}, HalC2.Test.FakeAcp.find(&1, "muse"))
      )

    context
  end

  step "the agent in {string} delegated a task to Grok whose subagent left work running in the background",
       %{args: [caller]} = context do
    grok_background(context, caller)
  end

  step "the agent in {string} delegated a task whose subagent's run ended with other work still going",
       %{args: [caller]} = context do
    context = grok_background(context, caller)
    World.await_runs(context, "subagent", ["completed"])
    context
  end

  step "the subagent's work is stopped", context do
    assert {:ok, %{"status" => "cancelled"}} = context.mcp_result
    World.await_row(World.thread_id(context, "subagent"), &(&1["pendingBackgroundTasks"] == []))
    context
  end

  step "the task is {string}", %{args: [status]} = context do
    assert task(context)["status"] == status
    context
  end

  # A Grok subagent whose turn ended with a shell and a subagent of its own still running.
  defp grok_background(context, caller) do
    context =
      HalC2.Test.FakeAcp.install(context, "grok", %{"configOptions" => [@grok_models]},
        enabled: true
      )

    {_, context} =
      HalC2.Test.FakeAcp.await_providers(
        context,
        &match?(%{"models" => [_ | _]}, HalC2.Test.FakeAcp.find(&1, "grok"))
      )

    context =
      delegate(context, caller, %{
        "mode" => "async",
        "task" => "Start the dev server in the background",
        "target" => %{"providerInstanceId" => "grok"}
      })

    World.await_row(World.thread_id(context, "subagent"), &(&1["pendingBackgroundTasks"] != []))
    assert task(context)["status"] == "running"
    context
  end

  # The fake Grok's background turn left a shell (task-sh) and a subagent (its session)
  # running; Grok reports both ended.
  step "Grok reports the subagent's background work ended", context do
    [{pid, _}] = Registry.lookup(HalC2.Acp.Registry, World.thread_id(context, "subagent"))
    runtime = :sys.get_state(pid)

    for task <- ["task-sh", @grok_child_session] do
      send(
        pid,
        {:json_rpc, runtime.conn,
         {:notification, "x.ai/task_completed",
          %{
            "sessionId" => runtime.session_id,
            "update" => %{
              "sessionUpdate" => "task_completed",
              "task_snapshot" => %{"task_id" => task}
            }
          }}}
      )
    end

    context
  end

  # The report is held at its retry, as one given up on would never come.
  step "the subagent completed with {string}, and the report of its end was lost",
       %{args: [answer]} = context do
    lost_report(context, answer)
  end

  defp lost_report(context, answer) do
    reporter = report_held(context, answer)
    assert task(context)["status"] == "running"
    Map.put(context, :reporter, reporter)
  end

  # Completes the task's child with `answer`, fails the first report of its end, as a
  # thread it reads that restarts under it would, and holds the report at its retry.
  # Returns the reporter, which goes on when sent `:retry`.
  defp report_held(context, answer) do
    World.await_runs(context, "subagent", ["running"])
    failed = :atomics.new(1, [])
    child = World.thread_id(context, "subagent")
    World.put_app_env(:delegation_hook, {__MODULE__, :fail_first_report, [failed, child]})
    gate = :"delegation_retry_gate_#{System.unique_integer([:positive])}"
    :ok = :logger.add_handler(gate, __MODULE__.RetryGate, %{config: self()})
    # A failing step leaves no gate to the next scenario.
    ExUnit.Callbacks.on_exit(fn -> :logger.remove_handler(gate) end)

    World.send_turn(context, "subagent", "say " <> answer)
    assert_receive {:retrying, reporter}, 15_000
    :logger.remove_handler(gate)
    reporter
  end

  # The `:delegation_hook` of `report_held/2`.
  def fail_first_report(failed, child, :reporting, child) do
    if :atomics.exchange(failed, 1, 1) == 0, do: exit(:restarting)
  end

  def fail_first_report(_failed, _child, _stage, _id), do: :ok

  step "the subagent's session is released and the MC's periodic check runs", context do
    child = World.thread_id(context, "subagent")
    World.await_row(child, &(&1["activeRunId"] == nil))
    assert :ok = HalC2.Orchestration.release_session(child)
    Mc.ensure(HalC2.Orchestration.IdleSessions)
    HalC2.Orchestration.IdleSessions.check()
    context
  end

  step "the lost report, arriving after all, does not deliver it again", context do
    ref = Process.monitor(context.reporter)
    send(context.reporter, :retry)
    assert_receive {:DOWN, ^ref, _, _, _}, 15_000
    assert [_one] = result_messages(context, context.task_parent)
    context
  end

  step "the subagent's command is stopped", context do
    World.await_row(World.thread_id(context, "subagent"), &(&1["pendingBackgroundTasks"] == []))
    context
  end

  # --- backlog: roles, targets, request keys ------------------------------------------

  step "the agent in {string} delegates the task {string} with role {string}",
       %{args: [caller, task, role]} = context do
    delegate(context, caller, %{"task" => task, "role" => role})
  end

  step "the agent in {string} delegates the task {string} with no role",
       %{args: [caller, task]} = context do
    delegate(context, caller, %{"task" => task})
  end

  step "the subagent's first message is {string} and then the task",
       %{args: [prefix]} = context do
    [message | _] = messages(context, "subagent")
    assert String.ends_with?(message["text"], "#{prefix}\n\n#{context.task}")
    context
  end

  step "the subagent's first message is the task unchanged", context do
    [message | _] = messages(context, "subagent")
    assert String.ends_with?(message["text"], context.task)
    refute message["text"] =~ "Act as the"
    context
  end

  step "{string} runs on a {string} instance that is healthy",
       %{args: [thread, driver]} = context do
    assert World.thread(context, thread)["modelSelection"]["instanceId"] == driver

    assert %{"enabled" => true} =
             Enum.find(HalC2.Environment.providers(), &(&1["instanceId"] == driver))

    context
  end

  step "{string} runs on a {string} instance that is disabled",
       %{args: [thread, driver]} = context do
    context = World.update_settings(context, %{"providers" => %{driver => %{"enabled" => false}}})
    assert World.thread(context, thread)["modelSelection"]["instanceId"] == driver
    context
  end

  step "another healthy {string} instance exists", %{args: [driver]} = context do
    context =
      World.update_settings(context, %{
        "providerInstances" => %{"codex2" => %{"driver" => driver}}
      })

    assert %{"enabled" => true, "driver" => ^driver} =
             Enum.find(HalC2.Environment.providers(), &(&1["instanceId"] == "codex2"))

    Map.put(context, :other_instance, "codex2")
  end

  step "the agent in {string} delegates a task naming the provider kind {string}",
       %{args: [caller, driver]} = context do
    delegate(context, caller, %{"target" => %{"driverKind" => driver}})
  end

  step "the subagent runs on the instance {string} runs on", %{args: [parent]} = context do
    assert World.thread(context, "subagent")["modelSelection"]["instanceId"] ==
             World.thread(context, parent)["modelSelection"]["instanceId"]

    context
  end

  step "the subagent runs on the other healthy instance", context do
    assert World.thread(context, "subagent")["modelSelection"]["instanceId"] ==
             context.other_instance

    context
  end

  step "the agent in {string} delegates a task and names the provider kind {string} but none is healthy",
       %{args: [caller, driver]} = context do
    context = World.update_settings(context, %{"providers" => %{driver => %{"enabled" => false}}})
    delegate(context, caller, %{"target" => %{"driverKind" => driver}})
  end

  step "the agent in {string} delegates a task and names an instance that is not registered",
       %{args: [caller]} = context do
    delegate(context, caller, %{"target" => %{"providerInstanceId" => "ghost"}})
  end

  step "the agent in {string} delegates a task and names an instance of a different kind than the kind given",
       %{args: [caller]} = context do
    context =
      World.update_settings(context, %{
        "providerInstances" => %{"claude" => %{"driver" => "claudeAgent"}}
      })

    delegate(context, caller, %{
      "target" => %{"providerInstanceId" => "claude", "driverKind" => "codex"}
    })
  end

  step "the agent in {string} delegates a task and names a model the provider does not advertise",
       %{args: [caller]} = context do
    delegate(context, caller, %{"target" => %{"providerInstanceId" => "codex", "model" => "nope"}})
  end

  # A provider, model and descriptor of `type` from what this MC advertises, so the
  # option checks run against a model that really has the option.
  defp find_descriptor(type) do
    found =
      for provider <- HalC2.Environment.providers(),
          model <- provider["models"] || [],
          descriptor <- get_in(model, ["capabilities", "optionDescriptors"]) || [],
          descriptor["type"] == type or type == :any do
        {provider["instanceId"], model["slug"], descriptor}
      end

    List.first(found) || flunk("no advertised model has a #{type} option")
  end

  defp option_case(context, caller, type, options_for) do
    {instance, model, descriptor} = find_descriptor(type)

    context =
      Map.put(context, :option_case, %{
        instance: instance,
        model: model,
        descriptor: descriptor
      })

    delegate(context, caller, %{
      "target" => %{
        "providerInstanceId" => instance,
        "model" => model,
        "options" => options_for.(descriptor)
      }
    })
  end

  step "the agent in {string} delegates a task with the same option given twice",
       %{args: [caller]} = context do
    option_case(context, caller, :any, fn %{"id" => id} = descriptor ->
      value = if descriptor["type"] == "boolean", do: true, else: hd(descriptor["options"])["id"]
      [%{"id" => id, "value" => value}, %{"id" => id, "value" => value}]
    end)
  end

  step "the agent in {string} delegates a task with an option the model does not have",
       %{args: [caller]} = context do
    option_case(context, caller, :any, fn _descriptor ->
      [%{"id" => "noSuchOption", "value" => "x"}]
    end)
  end

  step "the agent in {string} delegates a task with a true or false option given a word",
       %{args: [caller]} = context do
    option_case(context, caller, "boolean", fn %{"id" => id} ->
      [%{"id" => id, "value" => "yes"}]
    end)
  end

  step "the agent in {string} delegates a task with a choice option given a value outside its choices",
       %{args: [caller]} = context do
    option_case(context, caller, "select", fn %{"id" => id} ->
      [%{"id" => id, "value" => "no-such-choice"}]
    end)
  end

  step ~r/^the message names the model and the provider and says (?<problem>.+)$/,
       %{args: [problem]} = context do
    assert {:error, _code, message} = context.mcp_result
    %{instance: instance, model: model, descriptor: descriptor} = context.option_case
    assert message =~ "Model #{model} on provider #{instance} rejected options:"

    cond do
      problem =~ "more than once" ->
        assert message =~ "Option #{descriptor["id"]} was specified more than once."

      problem =~ "unknown" ->
        assert message =~ "Unknown option noSuchOption; supported options:"
        assert message =~ descriptor["id"]

      problem =~ "boolean" ->
        assert message =~ "Option #{descriptor["id"]} expects a boolean value."

      problem =~ "one of the choices" ->
        assert message =~ "Option #{descriptor["id"]} must be one of:"
    end

    context
  end

  step "the agent in {string} delegated a task with request key {string}",
       %{args: [caller, key]} = context do
    context = delegate(context, caller, %{"mode" => "async", "clientRequestId" => key})
    Map.merge(context, %{request_key: key, first_task_id: context.task_id})
  end

  step "no second subagent thread is started", context do
    assert [_one] = StreamState.list(World.state(context, context.task_parent), "subagent")
    context
  end

  step "it receives the same task id", context do
    assert {:ok, %{"taskId" => task_id}} = context.mcp_result
    assert task_id == context.first_task_id
    context
  end

  step "a delegated task of {string} finished with an answer that fits one read",
       %{args: [parent]} = context do
    context = delegate(context, parent, %{"mode" => "async"})
    complete(context, "Done")
  end

  step "a delegated task of {string} finished", %{args: [parent]} = context do
    context = delegate(context, parent, %{"mode" => "async"})
    complete(context, "Done")
  end

  step "the agent in {string} reads the subagent's thread from the start",
       %{args: [caller]} = context do
    result =
      World.mcp_tool(context, caller, "hal_c2_thread_read", %{
        "threadId" => World.thread_id(context, "subagent")
      })

    assert {:ok, %{"items" => items}} = result
    assert Enum.any?(items, &(&1["text"] =~ "Done"))
    Map.put(context, :mcp_result, result)
  end

  step "the task's delivery is {string} and {string} is not woken for it",
       %{args: [delivery, parent]} = context do
    await_task(context, &(&1["completionDelivery"]["state"] == delivery))

    refute Enum.any?(
             World.runs(context, parent),
             &(&1["status"] in ["queued"] and wake_run?(context, parent, &1))
           )

    context
  end

  # The child says one thing while working and its answer last, then its turn ends.
  step "a delegated task of {string} finished after a progress message",
       %{args: [parent]} = context do
    context = delegate(context, parent, %{"mode" => "async"})
    World.await_runs(context, "subagent", ["running"])
    {_pid, runtime} = World.codex_runtime(context, "subagent")
    at = %{"threadId" => runtime.native_thread_id, "turnId" => runtime.turn.native_turn_id}

    for {id, text} <- [{"msg-progress", "Working on it"}, {"msg-answer", "Done"}] do
      message = %{"type" => "agentMessage", "id" => id, "text" => text}

      World.codex_notify(
        context,
        "subagent",
        "item/started",
        Map.put(at, "item", %{message | "text" => ""})
      )

      World.codex_notify(context, "subagent", "item/completed", Map.put(at, "item", message))
    end

    World.codex_notify(context, "subagent", "turn/completed", %{
      "threadId" => runtime.native_thread_id,
      "turn" => %{"id" => runtime.turn.native_turn_id, "status" => "completed"}
    })

    await_task(
      context,
      &(&1["status"] == "completed" and &1["completionDelivery"]["state"] == "delivered")
    )

    progress =
      context
      |> World.state("subagent")
      |> StreamState.list("turn-item")
      |> Enum.find(&(&1["type"] == "assistant_message"))

    Map.put(context, :progress_item_id, progress["id"])
  end

  step "the agent in {string} reads just the progress message of the subagent's thread",
       %{args: [caller]} = context do
    result =
      World.mcp_tool(context, caller, "hal_c2_thread_read", %{
        "threadId" => World.thread_id(context, "subagent"),
        "itemId" => context.progress_item_id
      })

    assert {:ok, %{"items" => [%{"text" => "Working on it"}]}} = result
    Map.put(context, :mcp_result, result)
  end

  step "the agent in {string} waits on the subagent's thread", %{args: [caller]} = context do
    result =
      World.mcp_tool(context, caller, "hal_c2_thread_wait", %{
        "threadId" => World.thread_id(context, "subagent"),
        "timeoutMs" => 5_000
      })

    Map.put(context, :mcp_result, result)
  end

  step "the wait reports only the status", context do
    assert {:ok, %{"status" => "completed", "timedOut" => false}} = context.mcp_result
    context
  end

  step "the task's delivery is still pending", context do
    state = task(context)["completionDelivery"]["state"]
    assert state in ["pending", "delivered"]
    # The wake that carries it still waits for the caller.
    assert Enum.any?(World.runs(context, context.task_parent), &(&1["status"] == "queued"))
    context
  end

  step "the agent in {string} delegated a task that is not finished and whose subagent has nothing running or in the background",
       %{args: [caller]} = context do
    context = delegate(context, caller, %{"mode" => "async"})
    context = lost_report(context, "Done")
    assert [%{"status" => "completed"}] = World.runs(context, "subagent")
    assert task(context)["status"] == "running"
    context
  end

  step "the tool reports the task {string}", %{args: [status]} = context do
    assert {:ok, %{"status" => ^status}} = context.mcp_result
    context
  end

  # --- backlog: later wakes and left-behind work --------------------------------------------

  step "the subagent answered {string} and left a command running in the background",
       %{args: [answer]} = context do
    World.await_runs(context, "subagent", ["running"])
    leave_background(context, answer)
  end

  # Codex reports the command's exit, and the MC wakes Codex for it. The command's output
  # holds that turn open (the fake Codex keeps a turn whose text says "wait"), and Codex
  # ends it with `answer`.
  step "the command ends and the subagent's provider wakes it to finish with {string}",
       %{args: [answer]} = context do
    {_pid, runtime} = World.codex_runtime(context, "subagent")

    World.codex_notify(context, "subagent", "item/completed", %{
      "threadId" => runtime.native_thread_id,
      "turnId" => "native-turn-1",
      "item" => %{
        "type" => "commandExecution",
        "id" => "cmd-bg",
        "command" => "npm run dev",
        "status" => "completed",
        "aggregatedOutput" => "wait for it",
        "exitCode" => 0
      }
    })

    World.await_runs(context, "subagent", ["completed", "running"])
    assert task(context)["status"] == "running"
    end_turn(context, answer)
    await_task(context, &(&1["status"] == "completed"))
    context
  end

  step "the subagent answered {string} while a command it started was running in the background",
       %{args: [answer]} = context do
    World.await_runs(context, "subagent", ["running"])
    context = leave_background(context, answer)
    Map.put(context, :left_behind, :command)
  end

  # Its own task's wake holds its turn open (titled "wait"), so that turn ends when the
  # test ends it.
  step "the subagent answered {string} while a task it delegated itself was still running",
       %{args: [answer]} = context do
    context = delegate_own(context, %{"task" => "wait for it", "title" => "wait here"})

    World.await_stream(context.own_child, fn state ->
      Enum.map(StreamState.list(state, "run"), & &1["status"]) == ["running"]
    end)

    end_turn(context, answer)
    World.await_row(World.thread_id(context, "subagent"), &(&1["pendingBackgroundTasks"] != []))
    assert task(context)["status"] == "running"
    Map.put(context, :left_behind, :task)
  end

  # The work ends, and the subagent's turn about it ends without a word, so its answer
  # stays the task's result.
  step "that work settles", context do
    case context.left_behind do
      :command ->
        {_pid, runtime} = World.codex_runtime(context, "subagent")

        World.codex_notify(context, "subagent", "item/completed", %{
          "threadId" => runtime.native_thread_id,
          "turnId" => "native-turn-1",
          "item" => %{
            "type" => "commandExecution",
            "id" => "cmd-bg",
            "command" => "npm run dev",
            "status" => "completed",
            "aggregatedOutput" => "wait for it",
            "exitCode" => 0
          }
        })

      :task ->
        own = Map.update!(context, :threads, &Map.put(&1, "own", context.own_child))
        World.send_turn(own, "own", "say Found it")
    end

    World.await_runs(context, "subagent", ["completed", "running"])
    assert task(context)["status"] == "running"
    {_pid, runtime} = World.codex_runtime(context, "subagent")

    World.codex_notify(context, "subagent", "turn/completed", %{
      "threadId" => runtime.native_thread_id,
      "turn" => %{"id" => runtime.turn.native_turn_id, "status" => "completed"}
    })

    context
  end

  step "the task finishes with {string}", %{args: [answer]} = context do
    await_task(context, &(&1["status"] == "completed"))
    assert task(context)["result"] == answer
    Map.put(context, :answer, answer)
  end

  step "{string} is woken once with that result", %{args: [parent]} = context do
    await_result_message(context, parent)
    assert [message] = result_messages(context, parent)
    assert message["text"] =~ "\n#{context.answer}\n"
    context
  end

  # --- backlog: deliveries and the caller's settled run -------------------------------------

  # The caller's turn settles, and its delivery is answered with the run read before.
  step ~r/^the caller's run (?<settled>failed in the provider|completed its checkpoint) just before the caller (?<command>acknowledges|disposes) the delivery$/,
       %{args: [settled, command]} = context do
    parent = context.task_parent
    [seen | _] = World.runs(context, parent)

    case settled do
      "failed in the provider" ->
        {_pid, runtime} = World.codex_runtime(context, parent)

        World.codex_notify(context, parent, "turn/completed", %{
          "threadId" => runtime.native_thread_id,
          "turn" => %{
            "id" => runtime.turn.native_turn_id,
            "status" => "failed",
            "error" => %{"message" => "the turn failed"}
          }
        })

      "completed its checkpoint" ->
        World.send_turn(context, parent, "say Carrying on")
    end

    ended = if settled == "failed in the provider", do: "failed", else: "completed"

    World.await_state(context, parent, fn state ->
      run = StreamState.get(state, "run")[seen["id"]]
      run["status"] == ended and (ended == "failed" or run["checkpointId"] != nil)
    end)

    action = if command == "acknowledges", do: "acknowledge", else: "dispose"
    {reply, context} = World.dispatch(context, delivery_command(context, action, seen["id"]))
    assert {:ok, _} = reply
    Map.put(context, :seen_run, seen["id"])
  end

  step "the run stays {word}", %{args: [ended]} = context do
    run = StreamState.get(World.state(context, context.task_parent), "run")[context.seen_run]
    assert run["status"] == ended
    if ended == "completed", do: assert(run["checkpointId"] != nil)
    context
  end

  # The wake for the result runs next, unless answering the delivery cancelled it; then a
  # message of the user's does.
  step "the next run of {string} can start", %{args: [parent]} = context do
    later = fn ->
      Enum.filter(World.runs(context, parent), &(&1["id"] != context.seen_run))
    end

    unless Enum.any?(later.(), &(&1["status"] in ["queued", "running", "completed"])),
      do: World.send_turn(context, parent, "say Next")

    World.await_state(context, parent, fn state ->
      Enum.any?(
        StreamState.list(state, "run"),
        &(&1["id"] != context.seen_run and &1["status"] in ["running", "completed"])
      )
    end)

    run = StreamState.get(World.state(context, parent), "run")[context.seen_run]
    assert run["status"] in ["failed", "completed"]
    context
  end

  # The caller's turn has ended in its provider, and its checkpoint is held while it is
  # being taken.
  step "the run of {string} is finishing and taking its checkpoint",
       %{args: [parent]} = context do
    context = delegate(context, parent, %{"mode" => "async"})
    World.await_runs(context, "subagent", ["running"])
    parent_id = World.thread_id(context, parent)

    Application.put_env(
      :hal_c2,
      :effects_hook,
      {__MODULE__, :hold_checkpoint, [self(), parent_id]}
    )

    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :effects_hook) end)
    [seen | _] = World.runs(context, parent)
    World.send_turn(context, parent, "say Carrying on")
    assert_receive {:checkpoint_held, effect, holder}, 5_000
    assert World.runs(context, parent) |> hd() |> Map.fetch!("status") == "running"
    Map.merge(context, %{held_checkpoint: {effect, holder}, seen_run: seen["id"]})
  end

  step "the subagent of {string} finishes at that moment", %{args: [_parent]} = context do
    complete(context, "Done")
    {effect, holder} = context.held_checkpoint
    Application.delete_env(:hal_c2, :effects_hook)
    send(holder, {:release_checkpoint, effect})
    context
  end

  step "the run of {string} stays completed with its checkpoint", %{args: [parent]} = context do
    World.await_state(context, parent, fn state ->
      run = StreamState.get(state, "run")[context.seen_run]
      run["status"] == "completed" and run["checkpointId"] != nil
    end)

    context
  end

  step "the subagent's result is delivered to {string}", %{args: [parent]} = context do
    message = await_result_message(context, parent)
    assert message["text"] =~ "\nDone\n"

    World.await_state(context, parent, fn state ->
      Enum.any?(
        StreamState.list(state, "run"),
        &(&1["userMessageId"] == message["id"] and &1["status"] in ["running", "completed"])
      )
    end)

    run = StreamState.get(World.state(context, parent), "run")[context.seen_run]
    assert run["status"] == "completed" and run["checkpointId"] != nil
    context
  end

  # The `:effects_hook` of the step above: holds the caller's checkpoint capture.
  def hold_checkpoint(
        test,
        thread_id,
        :execute,
        %{"type" => "checkpoint.capture", "threadId" => thread_id, "id" => id}
      ) do
    send(test, {:checkpoint_held, id, self()})

    receive do
      {:release_checkpoint, ^id} -> :ok
    end
  end

  def hold_checkpoint(_test, _thread_id, _stage, _record), do: :ok

  # --- backlog: the hint to end the turn ----------------------------------------------------

  # Each is delegated with a request key, so waiting on it again is the same call.
  step "the agent in {string} delegated a task that is still running",
       %{args: [caller]} = context do
    context = delegate(context, caller, %{"mode" => "async", "clientRequestId" => "hinted"})
    World.await_runs(context, "subagent", ["running"])
    context
  end

  step "the agent in {string} delegated a task that is finished", %{args: [caller]} = context do
    context =
      delegate(context, caller, %{
        "mode" => "async",
        "task" => "say Done",
        "clientRequestId" => "hinted"
      })

    await_task(context, &(&1["status"] == "completed"))
    context
  end

  step "the agent in {string} delegated a task that is blocked on a question for the user",
       %{args: [caller]} = context do
    context = delegate(context, caller, %{"mode" => "async", "clientRequestId" => "hinted"})
    child_question(context)
  end

  step "the agent in {string} delegated a task that is blocked on an approval",
       %{args: [caller]} = context do
    context = delegate(context, caller, %{"mode" => "async", "clientRequestId" => "hinted"})
    child_approval(context)
  end

  step "the agent in {string} asks for the status of the task", %{args: [caller]} = context do
    result = World.mcp_tool(context, caller, "task_status", %{"taskId" => context.task_id})
    Map.put(context, :mcp_result, result)
  end

  step "the agent in {string} waits 1 second on the task", %{args: [caller]} = context do
    result =
      World.mcp_tool(context, caller, "delegate_task", %{
        "task" => context.task,
        "mode" => "wait",
        "timeoutMs" => 1_000,
        "clientRequestId" => "hinted"
      })

    Map.put(context, :mcp_result, result)
  end

  step "the agent in {string} waits on {string}'s run of the task",
       %{args: [caller, _parent]} = context do
    result =
      World.mcp_tool(context, caller, "hal_c2_thread_wait", %{
        "threadId" => World.thread_id(context, "subagent"),
        "timeoutMs" => 1
      })

    Map.put(context, :mcp_result, result)
  end

  step "the result says that the completion wakes {string}, so it should end its turn and not poll",
       %{args: [_parent]} = context do
    assert {:ok, %{"next" => next}} = context.mcp_result
    assert next =~ "Completion wakes this thread, so end your turn"
    assert next =~ "Do not wait on it or poll it"
    context
  end

  step "the result does not say that the completion wakes {string}, so it should end its turn and not poll",
       %{args: [_parent]} = context do
    assert {:ok, result} = context.mcp_result
    refute Map.has_key?(result, "next")
    context
  end

  step "the subagent's run stops on an approval", context do
    child_approval(context)
  end

  step "the wait returns the task as working with the approval's request, kind and run",
       context do
    result = Task.await(context.wait)
    [%{"id" => run_id}] = World.runs(context, "subagent")

    assert {:ok,
            %{
              "status" => "running",
              "workState" => "working",
              "pendingRequest" => %{"requestId" => request, "kind" => kind, "runId" => ^run_id}
            } = status} = result

    assert request == context.child_request
    assert is_binary(kind) and kind != "user_input"
    refute status["waitTimedOut"]
    Map.put(context, :wait_result, result)
  end

  step "the subagent keeps running once the approval is answered", context do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "runtime-request.respond",
        "commandId" => "command:respond:#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, "subagent"),
        "requestId" => context.child_request,
        "decision" => "accept"
      })

    World.await_state(context, "subagent", fn state ->
      get_in(StreamState.get(state, "runtime-request"), [context.child_request, "status"]) ==
        "resolved"
    end)

    assert [%{"status" => "running"}] = World.runs(context, "subagent")
    assert task(context)["status"] == "running"
    context
  end

  step "the task's later result still wakes {string}", %{args: [parent]} = context do
    complete(context, "Done")
    assert await_result_message(context, parent)["text"] =~ "Done"
    context
  end

  step "the subagent asks the user a question and stops until it is answered", context do
    child_question(context)
  end

  step "the wait returns the task as working with a pending question, not timed out",
       context do
    assert {:ok,
            %{
              "status" => "running",
              "pendingRequest" => %{"requestId" => request, "kind" => "user_input"}
            } = result} = Task.await(context.wait)

    assert request == context.child_request
    refute result["waitTimedOut"]
    Map.put(context, :wait_result, result)
  end

  step "the result tells the agent how to read and answer the question on the subagent's thread",
       context do
    {:ok, %{"pendingRequest" => %{"next" => next}}} = context.wait_result
    assert next =~ "hal_c2_pending_request_read"
    assert next =~ "hal_c2_pending_request_respond"
    assert next =~ World.thread_id(context, "subagent")
    assert next =~ context.child_request
    context
  end

  # A fresh wait on a fresh task: its subagent asks without stopping (Codex's async
  # question), and the wait still ends only with the task's answer.
  step "a question the subagent asks while it keeps working does not end the wait",
       context do
    context =
      context |> delegate(context.task_parent, %{"mode" => "wait"}) |> child_async_question()

    World.send_turn(context, "subagent", "say Done again")

    assert {:ok, %{"status" => "completed", "summary" => "Done again"} = result} =
             Task.await(context.wait)

    refute result["pendingRequest"]
    context
  end

  step "the agent in {string} delegated a task whose subagent asked a question and kept working",
       %{args: [caller]} = context do
    context |> delegate(caller, %{"mode" => "async"}) |> child_async_question()
  end

  step ~r/^the task ends (?<ending>cancelled|interrupted|completed)$/,
       %{args: [ending]} = context do
    case ending do
      "cancelled" ->
        assert {:ok, _} =
                 World.mcp_tool(context, "parent", "task_cancel", %{"taskId" => context.task_id})

      "interrupted" ->
        assert {:ok, _} =
                 HalC2.Orchestration.dispatch(%{
                   "type" => "run.interrupt",
                   "threadId" => World.thread_id(context, "subagent")
                 })

      "completed" ->
        World.send_turn(context, "subagent", "say Done")
    end

    await_task(context, &(&1["status"] == ending))
    context
  end

  step ~r/^the question is (?<state>dismissed|still open to be answered)$/,
       %{args: [state]} = context do
    status = if state == "dismissed", do: "cancelled", else: "pending"

    World.await_state(context, "subagent", fn child ->
      get_in(StreamState.get(child, "runtime-request"), [context.child_request, "status"]) ==
        status
    end)

    context
  end

  # The child's Codex asks a question without stopping its turn (an async question,
  # answered by a message).
  defp child_async_question(context) do
    World.await_runs(context, "subagent", ["running"])
    {_, runtime} = World.codex_runtime(context, "subagent")

    World.codex_notify(context, "subagent", "item/completed", %{
      "threadId" => runtime.native_thread_id,
      "turnId" => runtime.turn.native_turn_id,
      "item" => %{
        "type" => "agentMessage",
        "id" => "msg-async",
        "delivery" => "async",
        "text" => "",
        "questions" => [%{"title" => "Which color?", "options" => ["Red", "Blue"]}]
      }
    })

    assert %{"responseCapability" => %{"type" => "message"}} =
             request = World.await_request(context, "subagent")

    Map.put(context, :child_request, request["id"])
  end

  # The child's provider asks for an answer, and its turn stops until it has one.
  defp child_request(context, method, params) do
    World.await_runs(context, "subagent", ["running"])
    {pid, runtime} = World.codex_runtime(context, "subagent")
    rpc = System.unique_integer([:positive])
    item = "item-#{rpc}"
    send(pid, {:json_rpc, runtime.conn, {:request, rpc, method, Map.put(params, "itemId", item)}})
    request = "runtime-request:codex:#{item}"

    World.await_state(context, "subagent", fn state ->
      get_in(StreamState.get(state, "runtime-request"), [request, "status"]) == "pending"
    end)

    Map.merge(context, %{child_request: request, child_rpc: rpc})
  end

  defp child_approval(context),
    do:
      child_request(context, "item/commandExecution/requestApproval", %{
        "command" => "ls",
        "reason" => "list it"
      })

  defp child_question(context),
    do:
      child_request(context, "item/tool/requestUserInput", %{
        "questions" => [
          %{
            "id" => "q1",
            "header" => "Question",
            "question" => "Which database?",
            "options" => [%{"label" => "Postgres"}, %{"label" => "SQLite"}]
          }
        ]
      })

  # --- backlog: stopping ------------------------------------------------------------------

  # The caller's turn is over and its task is recorded as running, with a child thread
  # that never started a run for it: nothing will ever end that task by itself.
  step "{string} is idle and lists a delegated task as running", %{args: [parent]} = context do
    World.send_turn(context, parent, "say Carrying on")
    World.await_runs(context, parent, ["completed"])
    [%{"id" => run_id}] = World.runs(context, parent)
    parent_id = World.thread_id(context, parent)
    child_id = HalC2.Environment.uuid4()
    task_id = "node:subagent:" <> HalC2.Environment.uuid4()
    at = HalC2.Orchestration.Entities.now()

    {:ok, _} =
      HalC2.Streams.commit(child_id, :thread, [
        {"thread", child_id,
         %{
           "s" => %{
             "id" => child_id,
             "title" => "stuck",
             "projectId" => World.thread(context, parent)["projectId"],
             "lineage" => %{
               "relationshipToParent" => "subagent",
               "parentThreadId" => parent_id,
               "rootThreadId" => parent_id
             },
             "createdAt" => at,
             "updatedAt" => at
           }
         }}
      ])

    {:ok, _} =
      HalC2.Streams.commit(parent_id, :thread, [
        {"subagent", task_id,
         %{
           "s" => %{
             "id" => task_id,
             "origin" => "app_owned",
             "childThreadId" => child_id,
             "title" => "stuck",
             "completionWake" => "always",
             "completionDelivery" => %{"state" => "pending", "observedByRunId" => nil},
             "status" => "running",
             "runId" => run_id,
             "startedAt" => at
           }
         }},
        {"node", task_id,
         %{"s" => %{"id" => task_id, "kind" => "subagent", "status" => "running"}}},
        {"turn-item", "turn-item:subagent:#{task_id}",
         %{
           "s" => %{
             "id" => "turn-item:subagent:#{task_id}",
             "nodeId" => task_id,
             "runId" => run_id,
             "ordinal" => 1_000,
             "type" => "subagent",
             "status" => "running"
           }
         }}
      ])

    context
    |> put_in([:threads, "subagent"], child_id)
    |> Map.merge(%{task_id: task_id, task_parent: parent})
  end

  step "no run of the subagent was ever bound to that task", context do
    assert World.runs(context, "subagent") == []
    context
  end

  step "the agent in {string} delegated a task whose subagent is running its turn",
       %{args: [caller]} = context do
    context = delegate(context, caller, %{"mode" => "async"})
    World.await_runs(context, "subagent", ["running"])
    context
  end

  step "the task settles from that turn's outcome and {string} is woken once",
       %{args: [parent]} = context do
    assert {:ok, _} = context.stop_result
    await_task(context, &(&1["status"] == "interrupted"))
    await_result_message(context, parent)
    assert [message] = result_messages(context, parent)
    assert message["text"] =~ ~s(status="interrupted")
    context
  end

  step "the user stops the subagent", context do
    result =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "threadId" => World.thread_id(context, "subagent")
      })

    Map.put(context, :stop_result, result)
  end

  step "{string} is not woken with a result", %{args: [parent]} = context do
    assert get_in(task(context), ["completionDelivery", "state"]) == "disposed"
    assert wake_messages(context, parent) == []
    assert result_messages(context, parent) == []
    assert Enum.all?(World.runs(context, parent), &(&1["status"] == "completed"))
    context
  end

  # The task's subagent works on after the caller's turn that delegated it, and the
  # caller is in a later turn.
  step "the agent in {string} delegated task {string} in an earlier turn",
       %{args: [caller, name]} = context do
    context = named_tasks(context, caller, [name])
    World.send_turn(context, caller, "say Carrying on")
    World.await_runs(context, caller, ["completed"])
    World.send_turn(context, caller, "wait for it")
    World.await_runs(context, caller, ["completed", "running"])
    context
  end

  step "the subagent of {string} is still working", %{args: [name]} = context do
    World.await_runs(context, name, ["running"])
    assert named_task(context, name)["status"] == "running"
    context
  end

  # The caller's turn ended as stopped in its provider, which stops nothing it delegated.
  step "{string} is stopped but the subagent of its task {string} is still working",
       %{args: [parent, name]} = context do
    context = named_tasks(context, parent, [name])
    {_pid, runtime} = World.codex_runtime(context, parent)

    World.codex_notify(context, parent, "turn/completed", %{
      "threadId" => runtime.native_thread_id,
      "turn" => %{"id" => runtime.turn.native_turn_id, "status" => "interrupted"}
    })

    World.await_runs(context, parent, ["interrupted"])
    World.await_runs(context, name, ["running"])
    assert named_task(context, name)["status"] == "running"
    context
  end

  step "the user presses Stop on {string}", %{args: [parent]} = context do
    press_stop(context, parent)
  end

  step "the user presses Stop on {string} again", %{args: [parent]} = context do
    press_stop(context, parent)
  end

  step "the subagent of {string} is stopped", %{args: [name]} = context do
    World.await_runs(context, name, ["interrupted"])
    context
  end

  step "the task {string} is cancelled", %{args: [name]} = context do
    task_id = context.named_tasks[name]

    state =
      World.await_state(context, context.task_parent, fn state ->
        StreamState.get(state, "subagent")[task_id]["status"] == "cancelled"
      end)

    assert StreamState.get(state, "node")[task_id]["status"] == "cancelled"
    context
  end

  defp press_stop(context, parent) do
    HalC2.Orchestration.dispatch(%{
      "type" => "run.interrupt",
      "threadId" => World.thread_id(context, parent)
    })

    context
  end

  # --- what the agent is told -------------------------------------------------------

  step "an agent reads the description of delegate_task", context do
    tool = Enum.find(HalC2.Mcp.Tools.list(), &(&1["name"] == "delegate_task"))
    Map.put(context, :read_tool, tool)
  end

  step "it says to leave the access mode inherited unless the user asks for a supervised subagent",
       context do
    assert runtime_mode_text(context) =~
             ~r/Leave it inherited unless the user asks for a supervised subagent/

    context
  end

  step "that a supervised subagent waits for a person on each action that needs approval",
       context do
    assert runtime_mode_text(context) =~
             ~r/supervised subagent .* waits for a person on each action that needs approval/

    context
  end

  step "that a narrower mode is not a read-only switch, so a limit belongs in the task itself",
       context do
    assert runtime_mode_text(context) =~ ~r/not a read-only switch: .* in the task itself/
    context
  end

  defp runtime_mode_text(context),
    do: context.read_tool["inputSchema"]["properties"]["runtimeMode"]["description"]

  # Upstream #25359: what an agent reads before it delegates, the instructions and every
  # tool it is given.
  step "the user asks an agent for 20 workers on the same model", context do
    texts =
      [HalC2.Mcp.instructions(false), HalC2.Mcp.instructions(true)] ++
        Enum.map(HalC2.Mcp.Tools.list(), &JSON.encode!/1)

    Map.put(context, :agent_reads, texts)
  end

  step "nothing in the instructions given to the agent limits it to one delegated task per model",
       context do
    limit = ~r/\bone (child|task|worker|subagent|delegat\w*)\b[^.]*\bper (named )?model\b/i
    for text <- context.agent_reads, do: refute(text =~ limit)
    context
  end

  # --- a finished task's answer (upstream #19759) -----------------------------------

  step "the agent in {string} delegated a task that finished with its answer",
       %{args: [caller]} = context do
    context = delegate(context, caller, %{"mode" => "async", "task" => "say Found 3 bugs"})
    await_task(context, &(&1["status"] == "completed"))
    context
  end

  step "the answer is given once, not again as the latest answer", context do
    assert {:ok, %{"summary" => "Found 3 bugs"} = status} = context.mcp_result
    refute Map.has_key?(status, "latestAnswer")
    context
  end

  step "a later answer that differs from the result is still given", context do
    World.send_turn(context, "subagent", "say Fixed them")
    World.await_runs(context, "subagent", ["completed", "completed"])

    assert {:ok, %{"summary" => "Found 3 bugs", "latestAnswer" => "Fixed them"}} =
             status(context)

    context
  end

  # Whether `run` of `parent` is a delegated-result wake.
  defp wake_run?(context, parent, run) do
    message = StreamState.get(World.state(context, parent), "message")[run["userMessageId"]]
    message != nil and get_in(message, ["delegatedCompletion", "taskIds"]) != nil
  end

  # --- backlog: wakes ------------------------------------------------------------------

  # Delegates one task per name; each child thread and task is kept under its name.
  defp named_tasks(context, caller, names, input \\ %{}) do
    Enum.reduce(names, context, fn name, context ->
      title = input["title"] || "where are we with #{name}"

      context =
        delegate(
          context,
          caller,
          Map.merge(%{"mode" => "async", "title" => title}, Map.delete(input, "title"))
        )

      context
      |> put_in([:threads, name], context.threads["subagent"])
      |> put_in([Access.key(:named_tasks, %{}), name], context.task_id)
    end)
  end

  defp named_task(context, name) do
    StreamState.get(World.state(context, context.task_parent), "subagent")[
      context.named_tasks[name]
    ]
  end

  defp wake_messages(context, parent) do
    Enum.filter(
      messages(context, parent),
      &(get_in(&1, ["delegatedCompletion", "taskIds"]) != nil)
    )
  end

  defp await_wake(context, parent, fun) do
    World.await_state(context, parent, fn state ->
      Enum.any?(
        StreamState.list(state, "message"),
        &(get_in(&1, ["delegatedCompletion", "taskIds"]) != nil and fun.(&1))
      )
    end)

    Enum.find(wake_messages(context, parent), fun)
  end

  # Ends the named task's child the way its ending says, and waits for the task.
  defp end_named(context, name, ending) do
    task_id = context.named_tasks[name]

    case ending do
      "complete" ->
        complete_named(context, name)

      "fail" ->
        World.await_runs(context, name, ["running"])
        {_pid, runtime} = World.codex_runtime(context, name)

        World.codex_notify(context, name, "turn/completed", %{
          "threadId" => runtime.native_thread_id,
          "turn" => %{
            "id" => runtime.turn.native_turn_id,
            "status" => "failed",
            "error" => %{"message" => "the turn failed"}
          }
        })

        World.await_state(context, context.task_parent, fn state ->
          StreamState.get(state, "subagent")[task_id]["status"] == "failed"
        end)

        context

      "stop" ->
        {:ok, _} =
          HalC2.Orchestration.dispatch(%{
            "type" => "run.interrupt",
            "threadId" => World.thread_id(context, name)
          })

        World.await_state(context, context.task_parent, fn state ->
          StreamState.get(state, "subagent")[task_id]["status"] in ["interrupted", "cancelled"]
        end)

        context
    end
  end

  step "the turn of {string} ended while a task titled {string} were still working",
       %{args: [parent, title]} = context do
    context = named_tasks(context, parent, ["one"], %{"title" => title})
    World.send_turn(context, parent, "say Carrying on")
    World.await_runs(context, parent, ["completed"])
    context
  end

  step "the turn of {string} ended while a task with no title were still working",
       %{args: [parent]} = context do
    context = named_tasks(context, parent, ["one"], %{"title" => ""})
    World.send_turn(context, parent, "say Carrying on")
    World.await_runs(context, parent, ["completed"])
    context
  end

  step "the turn of {string} ended while three tasks were still working",
       %{args: [parent]} = context do
    context = named_tasks(context, parent, ["one", "two", "three"])
    World.send_turn(context, parent, "say Carrying on")
    World.await_runs(context, parent, ["completed"])
    context
  end

  # The parent is busy with a held turn while the tasks end, so their results
  # gather in one queued wake; ending that turn wakes it for them together.
  defp finish_and_wake(context, parent, endings) do
    context = World.send_turn(context, parent, "wait for it")
    World.await_runs(context, parent, ["completed", "running"])

    context =
      Enum.reduce(endings, context, fn {name, ending}, context ->
        end_named(context, name, ending)
      end)

    World.send_turn(context, parent, "say Carrying on")
    context
  end

  step "the task completes and {string} is woken for it", %{args: [parent]} = context do
    finish_and_wake(context, parent, [{"one", "complete"}])
  end

  step "the task fails and {string} is woken for it", %{args: [parent]} = context do
    finish_and_wake(context, parent, [{"one", "fail"}])
  end

  step "the task is cancelled or interrupted and {string} is woken for it",
       %{args: [parent]} = context do
    finish_and_wake(context, parent, [{"one", "stop"}])
  end

  step "all three complete and {string} is woken for it", %{args: [parent]} = context do
    finish_and_wake(context, parent, [
      {"one", "complete"},
      {"two", "complete"},
      {"three", "complete"}
    ])
  end

  step "two complete and one is cancelled and {string} is woken for it",
       %{args: [parent]} = context do
    finish_and_wake(context, parent, [{"one", "complete"}, {"two", "complete"}, {"three", "stop"}])
  end

  step "one fails and one is cancelled and {string} is woken for it",
       %{args: [parent]} = context do
    finish_and_wake(context, parent, [{"one", "fail"}, {"two", "stop"}, {"three", "complete"}])
  end

  step "the timeline of {string} shows a delegated task notification reading {string}",
       %{args: [parent, summary]} = context do
    message = await_wake(context, parent, &(get_in(&1, ["notification", "summary"]) == summary))
    assert message["notification"]["summary"] == summary
    Map.put(context, :wake_message, message)
  end

  step "the notification's outcome is {string}", %{args: [outcome]} = context do
    assert context.wake_message["notification"]["outcome"] == outcome
    context
  end

  # A task started by command, as a client starts one, with the given wake policy.
  defp request_delegated(context, parent, fields) do
    [run] = World.runs(context, parent)
    thread = World.thread(context, parent)

    {reply, context} =
      World.dispatch(
        context,
        Map.merge(
          %{
            "type" => "delegated_task.request",
            "parentThreadId" => thread["id"],
            "parentRunId" => run["id"],
            "parentNodeId" => run["rootNodeId"],
            "task" => "wait for it",
            "modelSelection" => thread["modelSelection"],
            "runtimeMode" => thread["runtimeMode"],
            "interactionMode" => thread["interactionMode"]
          },
          fields
        )
      )

    assert {:ok, _} = reply
    context |> Map.put(:task, "wait for it") |> await_child(parent)
  end

  step "the agent in {string} delegated a task that wakes it only once it is idle",
       %{args: [caller]} = context do
    request_delegated(context, caller, %{"completionWake" => "settled_only"})
  end

  step "the subagent completes while the turn of {string} is still running",
       %{args: [parent]} = context do
    assert Enum.any?(World.runs(context, parent), &(&1["status"] == "running"))
    context = Map.put(context, :parent_runs_before, World.runs(context, parent))
    complete(context, "Done")
  end

  step "{string} is not woken and nothing is queued for it", %{args: [parent]} = context do
    assert [%{"status" => "running"}] = World.runs(context, parent)
    assert wake_messages(context, parent) == []
    context
  end

  step "the result can be read from the task's status", context do
    assert {:ok, %{"summary" => summary}} = status(context)
    assert summary in ["Done", "three done"]
    context
  end

  step "{string} runs on a provider that can take messages mid-turn",
       %{args: [parent]} = context do
    selection = %{"instanceId" => "claudeAgent", "model" => "claude-sonnet-4-6"}

    context =
      World.launch_titled(context, parent, nil, "wait for it", %{"modelSelection" => selection})

    World.await_runs(context, parent, ["running"])
    [run] = World.runs(context, parent)
    Map.put(context, :parent_run, run["id"])
  end

  step "{string} runs on a provider that cannot take messages mid-turn",
       %{args: [parent]} = context do
    # The background's Codex parent: its delegated results queue behind the turn.
    [run] = World.runs(context, parent)
    Map.put(context, :parent_run, run["id"])
  end

  step "the agent in {string} delegated a task that always wakes it",
       %{args: [caller]} = context do
    delegate(context, caller, %{
      "mode" => "async",
      "target" => %{"providerInstanceId" => "codex"}
    })
  end

  step "the wake message joins the running turn", context do
    parent = context.task_parent
    message = await_wake(context, parent, &(&1["runId"] == context.parent_run))
    assert message["runId"] == context.parent_run
    assert length(World.runs(context, parent)) == 1
    context
  end

  step "the wake message waits in the queue behind the running turn", context do
    parent = context.task_parent
    message = await_wake(context, parent, fn _ -> true end)

    assert [%{"id" => running, "status" => "running"}, %{"status" => "queued"} = queued] =
             World.runs(context, parent)

    assert running == context.parent_run
    assert queued["userMessageId"] == message["id"]
    context
  end

  step "the running turn is never interrupted or restarted for it", context do
    run =
      Enum.find(World.runs(context, context.task_parent), &(&1["id"] == context.parent_run))

    assert run["status"] == "running"
    context
  end

  step "a wake for the finished task {string} of {string} is queued behind a running turn",
       %{args: [name, parent]} = context do
    context = named_tasks(context, parent, ["one", "two"])
    context = complete_named(context, name)
    assert {_run, _message} = queued_wake!(context, parent)
    context
  end

  defp queued_wake!(context, parent) do
    state =
      World.await_state(context, parent, fn state ->
        messages = StreamState.get(state, "message")

        Enum.any?(StreamState.list(state, "run"), fn run ->
          run["status"] == "queued" and
            get_in(messages, [run["userMessageId"], "delegatedCompletion", "taskIds"]) != nil
        end)
      end)

    messages = StreamState.get(state, "message")

    Enum.find_value(StreamState.list(state, "run"), fn run ->
      message = messages[run["userMessageId"]]

      if (run["status"] == "queued" and message) &&
           get_in(message, ["delegatedCompletion", "taskIds"]) != nil,
         do: {run, message}
    end)
  end

  step "task {string} of the same turn finishes", %{args: [name]} = context do
    complete_named(context, name)
  end

  step "no second wake is queued", context do
    assert length(wake_messages(context, context.task_parent)) == 1
    context
  end

  step "the queued wake now names {string} and {string}", %{args: [one, two]} = context do
    {_run, message} = queued_wake!(context, context.task_parent)

    assert MapSet.new(message["delegatedCompletion"]["taskIds"]) ==
             MapSet.new([context.named_tasks[one], context.named_tasks[two]])

    context
  end

  step "{string} is running the turn that woke it for task {string}",
       %{args: [parent, name]} = context do
    # Titled with "wait", which the fake Codex holds the wake turn on.
    context = named_tasks(context, parent, ["one", "two", "three"], %{"title" => "wait a while"})

    context = complete_named(context, name)
    World.send_turn(context, parent, "say Carrying on")

    World.await_state(context, parent, fn state ->
      messages = StreamState.get(state, "message")

      Enum.any?(StreamState.list(state, "run"), fn run ->
        run["status"] == "running" and
          get_in(messages, [run["userMessageId"], "delegatedCompletion", "taskIds"]) != nil
      end)
    end)

    context
  end

  step "tasks {string} and {string} of the same original turn finish",
       %{args: [one, two]} = context do
    context |> complete_named(one) |> complete_named(two)
  end

  step "they are not added to the running wake", context do
    [message] = wake_messages(context, context.task_parent)
    assert message["delegatedCompletion"]["taskIds"] == [context.named_tasks["one"]]
    Map.put(context, :first_wake_id, message["id"])
  end

  step "when that turn ends {string} is woken once more, for {string} and {string} together",
       %{args: [parent, one, two]} = context do
    World.send_turn(context, parent, "say Carrying on")

    message =
      await_wake(
        context,
        parent,
        &(&1["id"] != context.first_wake_id and
            MapSet.new(&1["delegatedCompletion"]["taskIds"]) ==
              MapSet.new([context.named_tasks[one], context.named_tasks[two]]))
      )

    assert message
    assert length(wake_messages(context, parent)) == 2
    context
  end

  # Four tasks; "one" and "two" each woke the caller, the second once the first wake
  # had ended, and the caller is idle again.
  step "the tasks of one turn of {string} already woke it twice", %{args: [parent]} = context do
    context = named_tasks(context, parent, ["one", "two", "three", "four"])
    context = complete_named(context, "one")
    World.send_turn(context, parent, "say Carrying on")
    await_wakes(context, parent, ["one"])
    context = complete_named(context, "two")
    [wake] = await_wakes(context, parent, ["two"])
    assert length(wake_messages(context, parent)) == 2
    Map.put(context, :last_wake, wake)
  end

  # Each lands with the caller idle, once the wake before it has ended.
  step "{string} and then {string} finish, each after the wake before it ended",
       %{args: names} = context do
    Enum.reduce(names, context, fn name, context ->
      context = complete_named(context, name)
      await_wakes(context, context.task_parent, [name])
      context
    end)
  end

  step "{string} is woken four times, once for each task", %{args: [parent]} = context do
    wakes = wake_messages(context, parent)
    assert length(wakes) == 4

    assert Enum.map(wakes, & &1["delegatedCompletion"]["taskIds"]) ==
             Enum.map(~w(one two three four), &[context.named_tasks[&1]])

    context
  end

  step "a wake for task {string} is queued", %{args: [name]} = context do
    {_run, message} = queued_wake!(context, context.task_parent)
    assert message["delegatedCompletion"]["taskIds"] == [context.named_tasks[name]]
    context
  end

  step "{string} was archived while the task was still working", %{args: [parent]} = context do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.archive",
        "threadId" => World.thread_id(context, parent)
      })

    context
  end

  step "{string} was deleted while the task was still working", %{args: [parent]} = context do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.delete",
        "threadId" => World.thread_id(context, parent)
      })

    context
  end

  step "{string} is not woken and no message is added to it", %{args: [parent]} = context do
    assert wake_messages(context, parent) == []
    assert result_messages(context, parent) == []
    context
  end

  step "the task's delivery is {string}", %{args: [delivery]} = context do
    await_task(context, &(&1["completionDelivery"]["state"] == delivery))
    context
  end

  step "the result can still be read from the task's status", context do
    assert {:ok, %{"summary" => "Done", "status" => "completed"}} = status(context)
    context
  end

  # One of the two has already finished, so a wake for it is queued when the user
  # stops the turn; the other is still working.
  step "the agent in {string} delegated tasks {string} and {string} without waiting",
       %{args: [caller, one, two]} = context do
    context = named_tasks(context, caller, [one, two])
    context = complete_named(context, one)
    assert {_run, _message} = queued_wake!(context, caller)
    context
  end

  step "the user interrupts the turn of {string}", %{args: [parent]} = context do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "threadId" => World.thread_id(context, parent)
      })

    context
  end

  step "{string} and {string} finish afterwards", %{args: [one, two]} = context do
    context =
      Enum.reduce([one, two], context, fn name, context ->
        if named_task(context, name)["status"] == "running",
          do: complete_named(context, name),
          else: context
      end)

    context
  end

  step "{string} is not woken for either", %{args: [parent]} = context do
    refute Enum.any?(
             World.runs(context, parent),
             &(&1["status"] in ["queued", "running", "completed"] and
                 wake_run?(context, parent, &1))
           )

    context
  end

  step "a wake already queued for that turn is cancelled", context do
    parent = context.task_parent
    [message] = wake_messages(context, parent)
    run = Enum.find(World.runs(context, parent), &(&1["userMessageId"] == message["id"]))
    assert run["status"] == "cancelled"
    context
  end

  step "a wake for the finished tasks {string} and {string} of {string} is queued",
       %{args: [one, two, parent]} = context do
    context = named_tasks(context, parent, [one, two])
    context = context |> complete_named(one) |> complete_named(two)
    {_run, message} = queued_wake!(context, parent)

    assert MapSet.new(message["delegatedCompletion"]["taskIds"]) ==
             MapSet.new([context.named_tasks[one], context.named_tasks[two]])

    context
  end

  defp delivery_for(context, task_id, action) do
    [run | _] = World.runs(context, context.task_parent)

    command = %{
      "type" => "delegated_task.completion-delivery.#{action}",
      "parentThreadId" => World.thread_id(context, context.task_parent),
      "taskId" => task_id
    }

    command =
      if action == "acknowledge",
        do: Map.put(command, "observedByRunId", run["id"]),
        else: command

    {reply, context} = World.dispatch(context, command)
    assert {:ok, _} = reply
    context
  end

  step "the agent acknowledges the result of {string}", %{args: [name]} = context do
    delivery_for(context, context.named_tasks[name], "acknowledge")
  end

  step "the agent acknowledges the results of both tasks", context do
    context
    |> delivery_for(context.named_tasks["one"], "acknowledge")
    |> delivery_for(context.named_tasks["two"], "acknowledge")
  end

  step "the agent disposes the delivery of both tasks", context do
    context
    |> delivery_for(context.named_tasks["one"], "dispose")
    |> delivery_for(context.named_tasks["two"], "dispose")
  end

  step "the queued wake names only {string}", %{args: [name]} = context do
    {_run, message} = queued_wake!(context, context.task_parent)
    assert message["delegatedCompletion"]["taskIds"] == [context.named_tasks[name]]
    context
  end

  step "the queued wake is cancelled and never runs", context do
    parent = context.task_parent
    [message] = wake_messages(context, parent)

    World.await_state(context, parent, fn state ->
      Enum.any?(
        StreamState.list(state, "run"),
        &(&1["userMessageId"] == message["id"] and &1["status"] == "cancelled")
      )
    end)

    context
  end

  # --- backlog: delivery commands, wake policy, results, native subagents ----------------

  # A "parent" thread on Claude with its turn running, for provider-started work.
  defp claude_parent(context, fields \\ %{}) do
    selection = %{"instanceId" => "claudeAgent", "model" => "claude-sonnet-4-6"}

    context =
      World.launch_titled(
        context,
        "parent",
        nil,
        "wait for it",
        Map.merge(%{"modelSelection" => selection}, fields)
      )

    World.await_runs(context, "parent", ["running"])
    context
  end

  # Claude starts a subagent of its own in "parent" (an Agent tool call and its
  # task_started), as the existing Claude steps drive it. Keeps the newest
  # provider-native subagent and its child thread in the context.
  defp start_native(context, suffix, input, started) do
    before =
      context
      |> World.state("parent")
      |> StreamState.list("subagent")
      |> Enum.map(& &1["id"])

    claude_says(context, "parent", [
      claude_tool_use(nil, "agent-#{suffix}", "Agent", input),
      Map.merge(
        %{
          "type" => "system",
          "subtype" => "task_started",
          "task_id" => "task-agent-#{suffix}",
          "tool_use_id" => "agent-#{suffix}",
          "task_type" => "local_agent"
        },
        started
      )
    ])

    state =
      World.await_state(context, "parent", fn state ->
        Enum.any?(
          StreamState.list(state, "subagent"),
          &(&1["origin"] == "provider_native" and &1["id"] not in before)
        )
      end)

    native =
      state
      |> StreamState.list("subagent")
      |> Enum.filter(&(&1["origin"] == "provider_native" and &1["id"] not in before))
      |> List.last()

    context
    |> Map.put(:native, native)
    |> put_in([:threads, "native-child"], native["childThreadId"])
  end

  step "a subagent that the provider of {string} started by itself",
       %{args: [_parent]} = context do
    context = claude_parent(context)
    start_native(context, "own", %{"prompt" => "Fan out"}, %{"prompt" => "Fan out"})
  end

  defp try_delivery_command(context, command) do
    {reply, context} = World.dispatch(context, command)
    context |> Map.put(:command_reply, reply) |> Map.put(:reply, reply)
  end

  step "a client tries to acknowledge its completion delivery for that subagent", context do
    try_delivery_command(context, %{
      "type" => "delegated_task.completion-delivery.acknowledge",
      "parentThreadId" => World.thread_id(context, "parent"),
      "taskId" => context.native["id"],
      "observedByRunId" => nil
    })
  end

  step "a client tries to dispose its completion delivery for that subagent", context do
    try_delivery_command(context, %{
      "type" => "delegated_task.completion-delivery.dispose",
      "parentThreadId" => World.thread_id(context, "parent"),
      "taskId" => context.native["id"]
    })
  end

  step "a client tries to change its wake policy for that subagent", context do
    try_delivery_command(context, %{
      "type" => "delegated_task.wake-policy",
      "parentThreadId" => World.thread_id(context, "parent"),
      "taskId" => context.native["id"],
      "completionWake" => "always"
    })
  end

  step "the agent in {string} delegated task {string} that always wakes it",
       %{args: [caller, name]} = context do
    named_tasks(context, caller, [name])
  end

  step "the wake policy of {string} is set to always again", %{args: [name]} = context do
    context =
      try_delivery_command(context, %{
        "type" => "delegated_task.wake-policy",
        "parentThreadId" => World.thread_id(context, context.task_parent),
        "taskId" => context.named_tasks[name],
        "completionWake" => "always"
      })

    Map.update!(context, :reply, &rename_reply(&1, context.named_tasks[name], name))
  end

  # The refusal's ids in the names the scenario gives them, for the common
  # "the command fails with {string}" step (which reads `context.reply`).
  defp rename_reply(value, id, name) when is_binary(value),
    do: String.replace(value, id, name)

  defp rename_reply(value, id, name) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&rename_reply(&1, id, name)) |> List.to_tuple()

  defp rename_reply(value, id, name) when is_list(value),
    do: Enum.map(value, &rename_reply(&1, id, name))

  defp rename_reply(value, id, name) when is_map(value),
    do: Map.new(value, fn {k, v} -> {k, rename_reply(v, id, name)} end)

  defp rename_reply(value, _id, _name), do: value

  step "a task of {string} that wakes it only once idle finished while its turn was running",
       %{args: [parent]} = context do
    context = request_delegated(context, parent, %{"completionWake" => "settled_only"})
    context = complete(context, "Done")
    assert task(context)["completionDelivery"]["state"] == "acknowledged"
    context
  end

  step "the turn of {string} is still running", %{args: [parent]} = context do
    assert Enum.any?(World.runs(context, parent), &(&1["status"] == "running"))
    context
  end

  step "the turn of {string} has ended", %{args: [parent]} = context do
    World.send_turn(context, parent, "say Carrying on")
    World.await_runs(context, parent, ["completed"])
    context
  end

  step "the task's wake policy is changed to always", context do
    {reply, context} = World.dispatch(context, wake_command(context, "always"))
    assert {:ok, _} = reply
    context
  end

  step "the result is delivered to {string} now", %{args: [parent]} = context do
    await_task(context, &(&1["completionDelivery"]["state"] == "delivered"))
    assert await_wake(context, parent, fn _ -> true end)["text"] =~ "\nDone\n"
    context
  end

  step "no wake is sent and the result stays readable from the task's status", context do
    assert wake_messages(context, context.task_parent) == []
    assert {:ok, %{"summary" => "Done"}} = status(context)
    context
  end

  defp request_command(context, parent, run) do
    thread = World.thread(context, parent)

    %{
      "type" => "delegated_task.request",
      "parentThreadId" => thread["id"],
      "parentRunId" => run["id"],
      "parentNodeId" => run["rootNodeId"],
      "task" => "wait for it",
      "modelSelection" => thread["modelSelection"],
      "runtimeMode" => thread["runtimeMode"],
      "interactionMode" => thread["interactionMode"]
    }
  end

  step "a client requests a delegated task for a run that already ended of {string}",
       %{args: [parent]} = context do
    [run] = World.runs(context, parent)
    World.send_turn(context, parent, "say Carrying on")
    World.await_runs(context, parent, ["completed"])
    try_delivery_command(context, request_command(context, parent, run))
  end

  step "a client requests a delegated task for the active run and a node that is not part of it of {string}",
       %{args: [parent]} = context do
    [run] = World.runs(context, parent)

    try_delivery_command(
      context,
      Map.put(request_command(context, parent, run), "parentNodeId", "node:not-in-run")
    )
  end

  step ~r/^the command fails saying (?<reason>the parent run is not active|the parent node is not part of the active run|it is not an app-owned task of thread ".+")$/,
       %{args: [reason]} = context do
    assert {:error, _, _} = context.command_reply
    text = inspect(context.command_reply)

    cond do
      reason =~ "app-owned" ->
        assert text =~ "is not an app-owned task of thread"

      reason =~ "node" ->
        assert text =~ "is not part of active run"

      true ->
        assert text =~ "is not active"
    end

    context
  end

  # Ends the subagent's running Codex turn the way `ending` says, with no answer
  # of its own unless the ending gives one first.
  defp end_child(context, ending) do
    context = delegate(context, "parent", %{"mode" => "async"})
    World.await_runs(context, "subagent", ["running"])
    {_pid, runtime} = World.codex_runtime(context, "subagent")
    at = %{"threadId" => runtime.native_thread_id, "turnId" => runtime.turn.native_turn_id}

    case ending do
      "completed" ->
        World.codex_notify(context, "subagent", "turn/completed", %{
          "threadId" => runtime.native_thread_id,
          "turn" => %{"id" => runtime.turn.native_turn_id, "status" => "completed"}
        })

        await_task(context, &(&1["status"] == "completed"))

      "interrupted" ->
        {:ok, _} =
          HalC2.Orchestration.dispatch(%{
            "type" => "run.interrupt",
            "threadId" => World.thread_id(context, "subagent")
          })

        await_task(context, &(&1["status"] == "interrupted"))

      "failed" ->
        message = %{"type" => "agentMessage", "id" => "msg-before-failure", "text" => "Answered"}

        World.codex_notify(
          context,
          "subagent",
          "item/started",
          Map.put(at, "item", %{message | "text" => ""})
        )

        World.codex_notify(
          context,
          "subagent",
          "item/completed",
          Map.put(at, "item", message)
        )

        World.codex_notify(context, "subagent", "error", %{
          "threadId" => runtime.native_thread_id,
          "turnId" => runtime.turn.native_turn_id,
          "willRetry" => true,
          "error" => %{"message" => "Rate limit reached"}
        })

        World.codex_notify(context, "subagent", "turn/completed", %{
          "threadId" => runtime.native_thread_id,
          "turn" => %{
            "id" => runtime.turn.native_turn_id,
            "status" => "failed",
            "error" => %{"message" => "Rate limit reached"}
          }
        })

        await_task(context, &(&1["status"] == "failed"))
    end

    context
  end

  step "the subagent's turn completes without an assistant message", context do
    end_child(context, "completed")
  end

  step "the subagent's turn is interrupted without an assistant message", context do
    end_child(context, "interrupted")
  end

  step "the subagent's turn fails with {string} after it already answered",
       %{args: [_message]} = context do
    end_child(context, "failed")
  end

  step "the task's result reads {string}", %{args: [result]} = context do
    assert task(context)["result"] == result
    context
  end

  step "{string} is titled {string}", %{args: [_thread, title]} = context do
    claude_parent(context, %{"title" => title})
  end

  step "the provider of {string} starts its second subagent with neither a title nor a prompt",
       %{args: [_parent]} = context do
    context =
      start_native(context, "first", %{"prompt" => "First task"}, %{"prompt" => "First task"})

    start_native(context, "second", %{}, %{})
  end

  step "the subagent's thread is titled {string}", %{args: [title]} = context do
    row = World.await_row(context.native["childThreadId"], & &1)
    assert row["title"] == title
    context
  end

  step "the provider of {string} starts a subagent with no title and a prompt of 100 characters",
       %{args: [_parent]} = context do
    prompt = String.duplicate("a", 100)
    context = claude_parent(context)
    context = start_native(context, "long", %{"prompt" => prompt}, %{"prompt" => prompt})
    Map.put(context, :long_prompt, prompt)
  end

  step "the subagent's thread is titled with the prompt's first 69 characters followed by {string}",
       %{args: [suffix]} = context do
    row = World.await_row(context.native["childThreadId"], & &1)
    assert row["title"] == String.slice(context.long_prompt, 0, 69) <> suffix
    context
  end

  step "thread {string} is snoozed", %{args: [parent]} = context do
    context = claude_parent(context)

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.snooze",
        "threadId" => World.thread_id(context, parent),
        "snoozedUntil" => World.iso_from_now(World.days(1))
      })

    context
  end

  step "the provider of {string} starts a subagent", %{args: [_parent]} = context do
    start_native(context, "fresh", %{"prompt" => "Check something"}, %{
      "prompt" => "Check something"
    })
  end

  step "the subagent's thread is not snoozed, settled or archived", context do
    child =
      context.native["childThreadId"]
      |> World.await_stream(& &1)
      |> StreamState.get("thread")
      |> Map.fetch!(context.native["childThreadId"])

    assert child["snoozedUntil"] == nil
    assert child["settledOverride"] == nil
    assert child["settledAt"] == nil
    assert child["archivedAt"] == nil
    Map.put(context, :native_child_thread, child)
  end

  step "it has never been visited", context do
    assert context.native_child_thread["lastVisitedAt"] == nil
    context
  end

  step "the provider of {string} starts a subagent with the prompt {string}",
       %{args: [_parent, prompt]} = context do
    context = claude_parent(context)
    start_native(context, "prompted", %{"prompt" => prompt}, %{"prompt" => prompt})
  end

  step "the subagent's thread opens with the message {string} written by the agent",
       %{args: [text]} = context do
    [message | _] = messages(context, "native-child")
    assert message["text"] == text
    assert message["role"] == "user"
    assert message["createdBy"] == "agent"
    Map.put(context, :native_first_message, message)
  end

  step "the message names {string} as the thread that sent it", %{args: [parent]} = context do
    assert context.native_first_message["senderThreadId"] == World.thread_id(context, parent)
    context
  end

  # --- helpers -----------------------------------------------------------------------

  # `delegate_task` as Claude calls it for its tool use `tool_use`.
  defp claude_delegates(context, thread, tool_use) do
    params = %{
      "name" => "delegate_task",
      "arguments" => %{"task" => "wait for it"},
      "_meta" => %{"claudecode/toolUseId" => tool_use}
    }

    case World.mcp(context, thread, "tools/call", params, "claudeAgent") do
      {200, %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}}} ->
        %{"code" => code, "message" => message} = JSON.decode!(text)
        {:error, code, message}

      {200, %{"result" => %{"structuredContent" => result}}} ->
        {:ok, result}
    end
  end

  # Claude's messages to the runtime of `thread`, handled once this returns.
  defp claude_says(context, thread, messages) do
    [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, World.thread_id(context, thread))
    session = :sys.get_state(pid).session
    for message <- messages, do: send(pid, {:claude, session, {:message, message}})
    :sys.get_state(pid)
  end

  # A tool call of Claude's (`parent` nil) or of its subagent under the tool call `parent`.
  defp claude_tool_use(parent, id, name, input) do
    %{
      "type" => "assistant",
      "parent_tool_use_id" => parent,
      "message" => %{
        "id" => "m-#{id}",
        "content" => [%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}]
      }
    }
  end

  # Calls delegate_task; a waiting call runs in a task (`context.wait`) until the step
  # that ends it. Once the child exists it is the scenario's "subagent" thread.
  defp delegate(context, caller, input) do
    input =
      %{"task" => "wait for it"}
      |> Map.merge(context[:delegate_input] || %{})
      |> Map.merge(input)

    context = Map.put(context, :task, input["task"])

    instance =
      get_in(World.thread(context, caller) || %{}, ["modelSelection", "instanceId"]) || "codex"

    if input["mode"] == "wait" do
      started = System.monotonic_time(:millisecond)

      wait =
        Task.async(fn -> World.mcp_tool(context, caller, "delegate_task", input, instance) end)

      await_child(Map.merge(context, %{wait: wait, wait_started: started}), caller)
    else
      case World.mcp_tool(context, caller, "delegate_task", input, instance) do
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

  # A scenario's worktree names stand for the directories it made.
  defp workspace_input(context, json) do
    json =
      json
      |> String.replace("'", ~s("))
      |> then(
        &Enum.reduce(context[:worktrees] || %{}, &1, fn {name, dir}, json ->
          String.replace(json, ~s("#{name}"), JSON.encode!(dir))
        end)
      )

    JSON.decode!(json)
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

  # Ends the subagent's running turn the way Codex ends one that started a dev server
  # and left it running: the command's item is still in progress at the turn's end.
  defp leave_background(context, answer) do
    {_pid, runtime} = World.codex_runtime(context, "subagent")
    at = %{"threadId" => runtime.native_thread_id, "turnId" => runtime.turn.native_turn_id}

    World.codex_notify(
      context,
      "subagent",
      "item/started",
      Map.put(at, "item", %{
        "type" => "commandExecution",
        "id" => "cmd-bg",
        "command" => "npm run dev",
        "processId" => "4275",
        "source" => "unifiedExecStartup",
        "status" => "inProgress"
      })
    )

    end_turn(context, answer)
    World.await_row(World.thread_id(context, "subagent"), &(&1["pendingBackgroundTasks"] != []))
    context
  end

  # Ends the subagent's running turn with `answer`, as Codex reports it.
  defp end_turn(context, answer) do
    {_pid, runtime} = World.codex_runtime(context, "subagent")
    at = %{"threadId" => runtime.native_thread_id, "turnId" => runtime.turn.native_turn_id}
    message = %{"type" => "agentMessage", "id" => "msg-end", "text" => answer}

    World.codex_notify(
      context,
      "subagent",
      "item/started",
      Map.put(at, "item", %{message | "text" => ""})
    )

    World.codex_notify(context, "subagent", "item/completed", Map.put(at, "item", message))

    World.codex_notify(context, "subagent", "turn/completed", %{
      "threadId" => runtime.native_thread_id,
      "turn" => %{"id" => runtime.turn.native_turn_id, "status" => "completed"}
    })
  end

  # A message queued behind the subagent's running turn.
  defp queue(context, text) do
    count = length(World.runs(context, "subagent"))

    World.send_turn(context, "subagent", text, %{
      "dispatchMode" => %{"type" => "queue_after_active"}
    })

    World.await_state(context, "subagent", &(length(StreamState.list(&1, "run")) > count))
  end

  # The subagent delegates a task of its own, without waiting.
  defp delegate_own(context, input) do
    World.await_runs(context, "subagent", ["running"])

    assert {:ok, %{"taskId" => task_id, "childThreadId" => child}} =
             World.mcp_tool(context, "subagent", "delegate_task", Map.put(input, "mode", "async"))

    World.await_row(child, & &1)
    Map.merge(context, %{own_task: task_id, own_child: child})
  end

  defp own_settled?(state, context) do
    case StreamState.get(state, "subagent")[context.own_task] do
      %{"status" => "completed"} -> true
      _ -> false
    end
  end

  defp result_messages(context, thread),
    do: Enum.filter(messages(context, thread), &(&1["text"] =~ "<delegated_task_result"))

  defp number(text), do: text |> String.replace(",", "") |> String.to_integer()

  # Completes the task's child with the first report of its end failed, and holds that
  # report at its retry; `meanwhile` runs before it. The caller has no result until
  # the retry.
  defp complete_unheard(context, meanwhile) do
    reporter = report_held(context, "Done")

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
