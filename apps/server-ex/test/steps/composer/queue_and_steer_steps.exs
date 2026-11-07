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
  alias HalC2.Test.Mc.World

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
    File.write!(Path.join(context.mc.home, "reject-steer"), "")
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

  step("{string}, {string} and {string} are queued in that order", %{args: texts} = context,
    do: queue_all(context, texts)
  )

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

  step("the user promotes it to a steer", context, do: promote(context))

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

  step "{string} was queued when the MC restarted", %{args: [text]} = context do
    {{:ok, _}, context} = World.send_message(context, World.current(context), text)
    context
  end

  step "the MC comes back", context do
    %{context | mc: HalC2.Test.Mc.restart(context.mc), clients: %{}}
  end

  # The MC recovers before it takes requests; nothing starts the queue after that.
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

  step "{string}, {string} and {string} are queued while a turn runs", %{args: texts} = context do
    # The fake keeps the turn working through steers, as a long turn does.
    File.write!(Path.join(context.mc.home, "keep-turn"), "")
    queue_all(context, texts)
  end

  # Send now while a turn runs steers the message into it (`queued-message.promote-to-steer`).
  step "the user sends {string} now and then sends {string} now", %{args: texts} = context do
    title = World.current(context)

    Enum.reduce(texts, context, fn text, context ->
      context = context |> Map.put(:queued_run, queued_run(context, text)) |> promote()

      World.await_thread(context, title, fn state ->
        state
        |> StreamState.list("message")
        |> Enum.any?(&(&1["role"] == "assistant" and &1["text"] =~ "steered: #{text}"))
      end)

      context
    end)
  end

  step "{string} and {string} are each shown once in the conversation and no longer in the queue",
       %{args: texts} = context do
    for text <- texts do
      assert shown(context, text) == 1
      refute text in queue_texts(context)
    end

    context
  end

  step "{string} is still queued and not shown in the conversation", %{args: [text]} = context do
    assert text in queue_texts(context)
    assert shown(context, text) == 0
    context
  end

  # The MC restarts under the queue: the running turn is stopped and the queue held.
  step(
    "{string}, {string} and {string} are queued and held, and the turn is no longer running",
    %{args: texts} = context,
    do: held_queue(context, texts)
  )

  step(
    "{string} and {string} are queued and held, and the turn is no longer running",
    %{args: texts} = context,
    do: held_queue(context, texts)
  )

  step "the user sends {string} now", %{args: [text]} = context do
    queue_command(context, "queued-run.start", queued_run(context, text), %{})
  end

  step "a turn starts with {string}", %{args: [text]} = context do
    title = World.current(context)

    World.await_thread(context, title, fn _ ->
      match?(%{"status" => "completed"}, World.run_for(context, title, text))
    end)

    assert List.last(World.started_turns(context)) == text
    context
  end

  # Another client's message starts at once on the idle thread.
  step "another turn starts before the MC handles the user's request", context do
    title = World.current(context)

    {{:ok, _}, context} =
      World.send_message(context, title, "wait for me", %{
        "dispatchMode" => %{"type" => "start_immediately"}
      })

    World.await_thread(context, title, fn _ ->
      match?(%{"status" => "running"}, World.run_for(context, title, "wait for me"))
    end)

    context
  end

  step "the user's request to send {string} now arrives", %{args: [text]} = context do
    reply =
      HalC2.Orchestration.dispatch(%{
        "type" => "queued-run.start",
        "threadId" => World.thread_id(context, World.current(context)),
        "runId" => queued_run(context, text)["id"]
      })

    Map.put(context, :reply, reply)
  end

  step "{string} stays queued", %{args: [text]} = context do
    assert {:error, message} = context.reply
    assert message =~ "stays queued"
    assert text in queue_texts(context)
    context
  end

  step "no second turn is started", context do
    statuses = context |> World.runs(World.current(context)) |> Enum.map(& &1["status"])
    assert Enum.count(statuses, &(&1 == "running")) == 1
    assert List.last(World.started_turns(context)) == "wait for me"
    context
  end

  # Codex steers into the running turn on any of its models; another provider restarts it.
  step("a provider that steers live but cannot restart the turn", context, do: context)

  step "the user steers with one model or thinking level, then steers back to the running one",
       context do
    title = World.current(context)
    running = running_run(context)
    other = %{"instanceId" => "codex", "model" => "gpt-5.5", "options" => %{"effort" => "high"}}
    File.write!(Path.join(context.mc.home, "keep-turn"), "")

    context = steer(context, "use the other model", other)
    assert World.thread(context, title)["modelSelection"] == other

    # The fake's "say ..." steer ends the turn, so the next steer misses it.
    File.rm!(Path.join(context.mc.home, "keep-turn"))
    context = steer(context, "say done", running["modelSelection"])
    World.await_runs(context, title, ["completed"])

    Map.merge(context, %{working_run: running["id"], running_selection: running["modelSelection"]})
  end

  step "the saved next-turn selection is the newest choice", context do
    assert World.thread(context, World.current(context))["modelSelection"] ==
             context.running_selection

    context
  end

  step "a steer that misses the turn starts the follow-up on that choice", context do
    title = World.current(context)

    {{:ok, _}, context} =
      World.send_message(context, title, "one more thing", %{
        "deliveryIntent" => "steer",
        "dispatchMode" => %{"type" => "steer_active", "targetRunId" => context.working_run}
      })

    World.await_runs(context, title, ["completed", "completed"])
    follow_up = World.run_for(context, title, "one more thing")
    assert follow_up["modelSelection"] == context.running_selection
    assert List.last(World.started_turns(context)) == "one more thing"
    context
  end

  step "the user picked Claude and queued {string}", %{args: [text]} = context do
    claude = %{"instanceId" => "claudeAgent", "model" => "claude-haiku"}

    {{:ok, _}, context} =
      World.send_message(context, World.current(context), text, %{"modelSelection" => claude})

    context |> Map.put(:queued_run, queued_run(context, text)) |> Map.put(:claude, claude)
  end

  step "the user steers with the queued {string}", %{args: [text]} = context do
    context = promote(context)
    assert context.queued_run["userMessageId"]
    Map.put(context, :queued_text, text)
  end

  step "Claude answers {string}", %{args: [text]} = context do
    title = World.current(context)

    World.await_thread(context, title, fn _ ->
      match?(%{"status" => "completed"}, World.run_for(context, title, text))
    end)

    assert World.run_for(context, title, text)["modelSelection"]["instanceId"] == "claudeAgent"
    # Claude's first turn on the thread carries the Codex conversation before it.
    assert String.ends_with?(List.last(World.claude_prompts(context)), text)
    refute text in World.started_turns(context)
    context
  end

  step "the thread stays on Claude", context do
    thread = World.thread(context, World.current(context))
    assert thread["modelSelection"] == context.claude
    assert thread["providerInstanceId"] == "claudeAgent"
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

  defp queue_all(context, texts) do
    Enum.reduce(texts, context, fn text, context ->
      {{:ok, _}, context} = World.send_message(context, World.current(context), text)
      context
    end)
  end

  defp held_queue(context, texts) do
    context = queue_all(context, texts)
    context = %{context | mc: HalC2.Test.Mc.restart(context.mc), clients: %{}}
    held = List.duplicate("queued", length(texts))
    World.await_runs(context, World.current(context), ["interrupted" | held])
    assert Enum.all?(World.queued(context, World.current(context)), &elem(&1, 1)["queueHeld"])
    context
  end

  defp promote(context) do
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

  defp steer(context, text, selection) do
    {{:ok, _}, context} =
      World.send_message(context, World.current(context), text, %{
        "deliveryIntent" => "steer",
        "dispatchMode" => %{"type" => "steer_active"},
        "modelSelection" => selection
      })

    context
  end

  # How many times the conversation a client shows holds the user's message `text`.
  defp shown(context, text) do
    resolve = fn id -> HalC2.Streams.Server.state(HalC2.Streams.ensure(id)) end

    context
    |> World.stream(World.current(context))
    |> HalC2.Projection.Timeline.visible_items(resolve)
    |> Enum.count(&(&1["type"] == "user_message" and &1["text"] == text))
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
