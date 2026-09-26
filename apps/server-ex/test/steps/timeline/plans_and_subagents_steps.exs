defmodule T3.Steps.Timeline.PlansAndSubagents do
  @moduledoc """
  Steps for the `@node` scenarios of `features/timeline/plans-and-subagents.feature`.
  The working agent delegates through the node's MCP `delegate_task` tool, as a
  provider would. Outcome scenarios delegate "answer from gate", which the fake Codex
  answers with whatever the test puts in the gate file "answer".
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.StreamState
  alias T3.Test.Node.World

  step "the agent delegates {string} to a subagent", %{args: [task]} = context do
    title = World.current(context)
    before = World.stream(context, title)
    T3.Test.Node.ensure(T3.Mcp)
    result = delegate(context, %{"task" => task})

    # Every version of the parent's subagent item since the call, oldest first: the
    # fake child can finish before the next step looks.
    items =
      events(World.thread_id(context, title), before.seq, before)
      |> Enum.flat_map(&StreamState.list(&1, "turn-item"))
      |> Enum.filter(&(&1["type"] == "subagent"))

    Map.merge(context, %{
      task: task,
      delegated: result["structuredContent"],
      subagent_items: items
    })
  end

  step "a subagent thread starts with only that task", context do
    child_id = context.delegated["childThreadId"]
    parent_id = World.thread_id(context, World.current(context))

    child =
      await(
        child_id,
        &Enum.any?(StreamState.list(&1, "run"), fn run -> run["status"] == "completed" end)
      )

    assert %{"relationshipToParent" => "subagent", "parentThreadId" => ^parent_id} =
             StreamState.get(child, "thread")[child_id]["lineage"]

    assert [context.task] ==
             for(
               %{"role" => "user", "text" => text} <- StreamState.list(child, "message"),
               do: text
             )

    # The provider was given the task alone, with none of the parent's conversation.
    assert context.task in World.started_turns(context)
    context
  end

  step "the parent's timeline shows the subagent working", context do
    task_id = context.delegated["taskId"]

    assert [%{"status" => "running", "prompt" => prompt} | _] =
             Enum.filter(context.subagent_items, &(&1["subagentId"] == task_id))

    assert prompt == context.task
    context
  end

  step "the agent delegated a task and chose to carry on", context do
    context = World.working_thread(context, World.current(context))
    T3.Test.Node.ensure(T3.Mcp)
    result = delegate(context, %{"task" => "answer from gate"})
    Map.merge(context, %{delegated: result["structuredContent"], mode: :carry_on})
  end

  step "the agent delegated a task and chose to wait for it", context do
    title = World.current(context)
    context = World.working_thread(context, title)
    T3.Test.Node.ensure(T3.Mcp)

    waiting =
      Task.async(fn -> delegate(context, %{"task" => "answer from gate", "mode" => "wait"}) end)

    # The call blocks until the task ends, so the task is read from the parent.
    state = World.await_thread(context, title, &(StreamState.list(&1, "subagent") != []))
    [task] = StreamState.list(state, "subagent")
    assert task["completionWake"] == "settled_only"
    Map.merge(context, %{delegated: task, waiting: waiting, mode: :wait})
  end

  step "the subagent finishes with {string}", %{args: [answer]} = context do
    finish(context, answer)
  end

  step "the subagent finishes without an answer", context do
    finish(context, "")
  end

  step "the parent receives {string} once it is free", %{args: [text]} = context do
    title = World.current(context)
    # The result may already be queued behind the parent's run (ordinal 1).
    parent_run = Enum.min_by(World.runs(context, title), & &1["ordinal"])

    # The result waits behind the parent's run.
    state =
      World.await_thread(context, title, fn state ->
        Enum.any?(StreamState.list(state, "run"), &(&1["status"] == "queued"))
      end)

    assert [{result, _run}] = World.queued(context, title)
    assert result =~ "<delegated_task_result"
    assert result =~ text
    assert StreamState.get(state, "run")[parent_run["id"]]["status"] == "running"

    stop_run(context, parent_run)
    assert_result_runs(context, title, text)
  end

  step "the parent receives {string} once its own run is over", %{args: [text]} = context do
    title = World.current(context)

    assert %{"structuredContent" => %{"status" => "completed", "summary" => nil}} =
             Task.await(context.waiting, 5_000)

    assert_result_runs(context, title, text)
  end

  # Calls the node's MCP tool `delegate_task` as the current thread's provider. The
  # test process must have started `T3.Mcp` (`T3.Test.Node.ensure/1`).
  defp delegate(context, arguments) do
    parent_id = World.thread_id(context, World.current(context))
    %{authorization: auth} = T3.Mcp.server(parent_id, "codex")

    {200, %{"result" => result}} =
      T3.Mcp.handle(
        auth,
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "delegate_task", "arguments" => arguments}
        })
      )

    assert result["isError"] != true, inspect(result)
    result
  end

  # A waiting parent hears the result only when its own run is already over when the
  # child finishes (otherwise the blocking call hands it over), so its run ends first.
  defp finish(context, answer) do
    title = World.current(context)
    child_id = context.delegated["childThreadId"]

    if context.mode == :wait do
      [parent_run] = World.runs(context, title)
      stop_run(context, parent_run)
    end

    World.open_gate(context, "answer", answer)

    await(
      child_id,
      &Enum.any?(StreamState.list(&1, "run"), fn run -> run["status"] == "completed" end)
    )

    context
  end

  defp stop_run(context, run) do
    title = World.current(context)

    {:ok, _} =
      T3.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "threadId" => World.thread_id(context, title),
        "runId" => run["id"]
      })

    World.await_thread(
      context,
      title,
      &(StreamState.get(&1, "run")[run["id"]]["status"] == "interrupted")
    )
  end

  # The result message runs as the parent's next turn, and the agent is given it.
  defp assert_result_runs(context, title, text) do
    state =
      World.await_thread(context, title, fn state ->
        messages = StreamState.get(state, "message")

        Enum.any?(
          StreamState.list(state, "run"),
          &(&1["status"] == "completed" and messages[&1["userMessageId"]]["text"] =~ text)
        )
      end)

    assert [message] =
             Enum.filter(
               StreamState.list(state, "message"),
               &(&1["text"] =~ "<delegated_task_result")
             )

    assert message["text"] =~
             ~s(taskId="#{context.delegated["taskId"] || context.delegated["id"]}")

    assert Enum.any?(
             World.started_turns(context),
             &(&1 =~ "<delegated_task_result" and &1 =~ text)
           )

    context
  end

  defp await(id, fun) do
    :ok = T3.Streams.subscribe(id, self(), nil)
    state = T3.Streams.Server.state(T3.Streams.ensure(id))
    if fun.(state), do: state, else: await_next(id, fun)
  end

  defp await_next(id, fun) do
    receive do
      {:t3_stream, ^id, _} ->
        state = T3.Streams.Server.state(T3.Streams.ensure(id))
        if fun.(state), do: state, else: await_next(id, fun)
    after
      5_000 -> flunk("thread #{id} never reached the expected state")
    end
  end

  # The states a stream passed through after `seq`, from the commits already in the mailbox.
  defp events(id, seq, state) do
    receive do
      {:t3_stream, ^id, {:events, events}} ->
        next =
          Enum.reduce(
            Enum.filter(events, &(&1.seq > seq)),
            state,
            &StreamState.apply_event(&2, &1)
          )

        [next | events(id, max(seq, next.seq), next)]
    after
      0 -> []
    end
  end
end
