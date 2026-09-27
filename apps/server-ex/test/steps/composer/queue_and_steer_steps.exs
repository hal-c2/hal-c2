defmodule HalC2.Steps.Composer.QueueAndSteer do
  @moduledoc """
  Steps for `features/composer/queue-and-steer.feature`. "the user queues" and
  "the user resumes the queue" live with `features/timeline/runs-and-queue.feature`.

  The agents are the fakes in `test/support`: a turn whose text says "wait" runs
  until it is interrupted or steered, and a steer is answered "steered: <text>".
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.StreamState
  alias HalC2.Test.Node.World

  step "a thread whose agent is working on a turn", context do
    context
    |> World.create_project("shop")
    |> World.working_thread("Current thread")
    |> Map.put(:current, "Current thread")
  end

  step "{string} is queued behind the running turn", %{args: [text]} = context do
    title = World.current(context)
    assert [{^text, run}] = World.queued(context, title)
    assert run["queuePosition"] == 1
    assert [%{"status" => "running"} | _] = World.runs(context, title)
    context
  end

  # The running turn ends when the user stops it; the thread is idle, and the
  # queued message starts.
  step "it starts once the thread is idle", context do
    title = World.current(context)
    interrupt(context)
    World.await_runs(context, title, ["interrupted", "completed"])
    assert List.last(World.runs(context, title))["userMessageId"] == context.last_message_id
    context
  end

  # The Background's thread runs on Codex; another provider gets its own working thread.
  step "the thread runs on {word}", %{args: [provider]} = context do
    if World.instance(provider) == "codex" do
      context
    else
      title = "#{provider} thread"
      context |> World.working_thread(title, provider) |> Map.put(:current, title)
    end
  end

  step "the user steers the running turn with {string}", %{args: [text]} = context do
    title = World.current(context)
    working = running_run(context)

    {{:ok, _}, context} =
      World.send_message(context, title, text, %{
        "deliveryIntent" => "steer",
        "dispatchMode" => %{"type" => "steer_active"}
      })

    Map.put(context, :working_run, working["id"])
  end

  step "the running turn receives {string}", %{args: [text]} = context do
    title = World.current(context)

    state =
      World.await_thread(context, title, fn state ->
        state
        |> StreamState.list("message")
        |> Enum.any?(&(&1["role"] == "assistant" and &1["text"] =~ "steered: #{text}"))
      end)

    user =
      state
      |> StreamState.list("message")
      |> Enum.find(&(&1["role"] == "user" and &1["text"] == text))

    assert user["runId"] == context.working_run
    context
  end

  step "the running turn is interrupted and {string} runs next", %{args: [text]} = context do
    title = World.current(context)
    World.await_runs(context, title, ["interrupted", "completed"])
    [first | _] = World.runs(context, title)
    assert first["id"] == context.working_run
    assert %{"status" => "completed"} = World.run_for(context, title, text)
    context
  end

  step "the provider rejects the steer", context do
    File.write!(Path.join(context.node.home, "reject-steer"), "")
    context
  end

  step "the user tries to steer the running turn with {string}", %{args: [text]} = context do
    {reply, context} =
      World.send_message(context, World.current(context), text, %{
        "deliveryIntent" => "steer",
        "dispatchMode" => %{"type" => "steer_active"}
      })

    Map.put(context, :reply, reply)
  end

  step "the user is told the provider did not take the message", context do
    assert {:error, message} = context.reply
    assert message =~ "did not take the message into its running turn"
    context
  end

  step "{string} is neither queued nor part of the running turn", %{args: [text]} = context do
    title = World.current(context)
    assert World.queued(context, title) == []
    refute StreamState.get(World.stream(context, title), "message")[context.last_message_id]
    refute text in World.started_turns(context)
    context
  end

  step "the running turn keeps working", context do
    assert %{"status" => "running"} = running_run(context)
    context
  end

  step "{string} is queued", %{args: [text]} = context do
    {{:ok, _}, context} = World.send_message(context, World.current(context), text)
    context |> Map.put(:queued_text, text) |> Map.put(:queued_run, queued_run(context, text))
  end

  step "the user restarts the turn with {string}", %{args: [text]} = context do
    {{:ok, _}, context} =
      World.send_message(context, World.current(context), text, %{"deliveryIntent" => "restart"})

    context
  end

  step "{string} runs before {string}", %{args: [first, second]} = context do
    World.await_runs(context, World.current(context), ["interrupted", "completed", "completed"])
    started = World.started_turns(context)
    assert Enum.find_index(started, &(&1 == first)) < Enum.find_index(started, &(&1 == second))
    context
  end

  step "{string}, {string} and {string} are queued in that order", %{args: texts} = context do
    Enum.reduce(texts, context, fn text, context ->
      {{:ok, _}, context} = World.send_message(context, World.current(context), text)
      context
    end)
  end

  step "the user moves {string} before {string}", %{args: [moved, before]} = context do
    queue_command(context, "queued-run.reorder", queued_run(context, moved), %{
      "beforeRunId" => queued_run(context, before)["id"]
    })
  end

  step "the queue order is {string}, {string}, {string}", %{args: texts} = context do
    assert queue_texts(context) == texts
    context
  end

  step "the user edits it to {string}", %{args: [text]} = context do
    queue_command(context, "queued-run.edit", context.queued_run, %{"text" => text})
  end

  step "the queued message reads {string}", %{args: [text]} = context do
    assert queue_texts(context) == [text]
    context
  end

  step "it keeps its place in the queue", context do
    assert [{_, run}] = World.queued(context, World.current(context))
    assert run["id"] == context.queued_run["id"]
    assert run["queuePosition"] == context.queued_run["queuePosition"]
    context
  end

  step "the user promotes it to a steer", context do
    working = running_run(context)

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "queued-message.promote-to-steer",
        "threadId" => World.thread_id(context, World.current(context)),
        "queuedRunId" => context.queued_run["id"],
        "targetRunId" => working["id"]
      })

    Map.put(context, :working_run, working["id"])
  end

  step "{string} is no longer waiting in the queue", %{args: [text]} = context do
    refute text in queue_texts(context)
    context
  end

  step "the user removes it from the queue", context do
    queue_command(context, "queued-run.cancel", context.queued_run, %{})
  end

  # Once the running turn ends, the thread has nothing left to run.
  step "{string} never runs", %{args: [text]} = context do
    title = World.current(context)
    assert queue_texts(context) == []
    interrupt(context)
    World.await_runs(context, title, ["interrupted", "cancelled"])
    refute text in World.started_turns(context)
    context
  end

  step "{string} was queued when the node restarted", %{args: [text]} = context do
    {{:ok, _}, context} = World.send_message(context, World.current(context), text)
    context
  end

  step "the node comes back", context do
    %{context | node: HalC2.Test.Node.restart(context.node), clients: %{}}
  end

  # The node recovers before it takes requests; nothing starts the queue after that.
  step "the queue is held and {string} does not start on its own", %{args: [text]} = context do
    title = World.current(context)
    assert [{^text, %{"queueHeld" => true}}] = World.queued(context, title)
    assert [%{"status" => "interrupted"}, %{"status" => "queued"}] = World.runs(context, title)
    refute text in World.started_turns(context)
    context
  end

  step "{string} starts", %{args: [text]} = context do
    World.await_runs(context, World.current(context), ["interrupted", "completed"])
    assert List.last(World.started_turns(context)) == text
    context
  end

  # --- helpers ---------------------------------------------------------------------

  defp running_run(context) do
    run =
      context
      |> World.runs(World.current(context))
      |> Enum.find(&(&1["status"] == "running"))

    assert run, "no running turn"
    run
  end

  defp interrupt(context) do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "threadId" => World.thread_id(context, World.current(context)),
        "runId" => running_run(context)["id"]
      })
  end

  defp queue_texts(context),
    do: context |> World.queued(World.current(context)) |> Enum.map(&elem(&1, 0))

  defp queued_run(context, text) do
    {_, run} = context |> World.queued(World.current(context)) |> List.keyfind!(text, 0)
    run
  end

  defp queue_command(context, type, run, fields) do
    {:ok, _} =
      HalC2.Orchestration.dispatch(
        Map.merge(
          %{
            "type" => type,
            "threadId" => World.thread_id(context, World.current(context)),
            "runId" => run["id"]
          },
          fields
        )
      )

    context
  end
end
