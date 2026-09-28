defmodule HalC2.Steps.Timeline.RunsAndQueue do
  @moduledoc """
  Steps for `features/timeline/runs-and-queue.feature`. "the user queues" and "the
  user resumes the queue" are shared with `features/composer/queue-and-steer.feature`.

  The agent is the fake Codex (`test/support/fake_codex.py`): a turn whose text says
  "wait" runs until it is interrupted or steered, any other turn finishes at once.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.StreamState
  alias HalC2.Test.Node.World

  step "the timeline marks the run as interrupted", context do
    run_id = context.interrupted_run

    state =
      World.await_thread(context, World.current(context), fn state ->
        Enum.any?(
          HalC2.Projection.Timeline.local_items(state),
          &(&1["type"] == "run_interrupt_result" and &1["runId"] == run_id)
        )
      end)

    types =
      for item <- HalC2.Projection.Timeline.local_items(state),
          item["runId"] == run_id,
          do: item["type"]

    assert "run_interrupt_request" in types
    assert StreamState.get(state, "run")[run_id]["status"] == "interrupted"
    context
  end

  step "the user queues {string}", %{args: [text]} = context do
    {{:ok, _}, context} = World.send_message(context, World.current(context), text)
    context
  end

  step "the message is queued at position {int}", %{args: [position]} = context do
    assert [{_, run}] = World.queued(context, World.current(context))
    assert run["userMessageId"] == context.last_message_id
    assert run["queuePosition"] == position
    context
  end

  # The running turn ends when the user stops it; the queued message starts then.
  step "it starts when the running turn ends", context do
    title = World.current(context)
    [running | _] = World.runs(context, title)
    assert World.queued(context, title) != []

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "threadId" => World.thread_id(context, title),
        "runId" => running["id"]
      })

    [_, next] = World.await_runs(context, title, ["interrupted", "completed"]) |> sorted_runs()
    assert next["userMessageId"] == context.last_message_id
    context
  end

  step "the agent is working on {word}", %{args: [provider]} = context do
    title = "#{provider} thread"
    context |> World.working_thread(title, provider) |> Map.put(:current, title)
  end

  step "the user steers with {string}", %{args: [text]} = context do
    title = World.current(context)
    [working] = World.runs(context, title)

    {{:ok, _}, context} =
      World.send_message(context, title, text, %{
        "deliveryIntent" => "steer",
        "dispatchMode" => %{"type" => "steer_active"}
      })

    context |> Map.put(:working_run, working["id"]) |> Map.put(:steer_text, text)
  end

  # Either a follow-up sent to `context.running` (plugins and providers
  # scenarios) or a steer of the current thread.
  step "the message joins the running turn", context do
    if World.fakes_feature?(context) do
      title = World.current_thread(context)

      World.await_value(context, title, fn state ->
        Enum.any?(
          HalC2.StreamState.list(state, "message"),
          &(&1["role"] == "assistant" and &1["text"] == "steered: one more thing")
        )
      end)

      # No second turn was queued for it.
      assert [_] = World.runs(context, title)
      context
    else
      case context[:running] do
        %{thread: thread_id, run: run_id} ->
          item =
            World.await_stream(thread_id, fn state ->
              Enum.find(
                HalC2.StreamState.list(state, "turn-item"),
                &(&1["messageId"] == context.follow_up)
              )
            end)

          assert %{"inputIntent" => "steer", "runId" => ^run_id} = item

          assert [%{"id" => ^run_id}] =
                   HalC2.StreamState.list(
                     HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id)),
                     "run"
                   )

        nil ->
          assert_joined(context, context.steer_text)
      end

      context
    end
  end

  # Grok cannot take a steer: as in the Node server, its turn is interrupted and
  # the message, queued first, runs as soon as it ends.
  step "the message is queued behind the running turn", context do
    title = World.current(context)
    runs = World.await_runs(context, title, ["interrupted", "completed"]) |> sorted_runs()
    assert [%{"id" => working}, %{"userMessageId" => message}] = runs
    assert working == context.working_run
    assert message == context.last_message_id
    context
  end

  step "the agent is working and one message is queued", context do
    context = World.working_thread(context, World.current(context))
    {{:ok, _}, context} = World.send_message(context, World.current(context), "then tidy up")
    Map.put(context, :queued_text, "then tidy up")
  end

  step "the user sends {string} as a restart", %{args: [text]} = context do
    {{:ok, _}, context} =
      World.send_message(context, World.current(context), text, %{"deliveryIntent" => "restart"})

    context
  end

  step "{string} runs before the queued message", %{args: [text]} = context do
    World.await_runs(context, World.current(context), ["interrupted", "completed", "completed"])
    assert_ran_in_order(context, [text, context.queued_text])
    context
  end

  step "the agent is working and {string} and {string} are queued", %{args: texts} = context do
    context = World.working_thread(context, World.current(context))

    Enum.reduce(texts, context, fn text, context ->
      {{:ok, _}, context} = World.send_message(context, World.current(context), text)
      context
    end)
  end

  step "the user moves {string} above {string}", %{args: [moved, before]} = context do
    queue_command(context, "queued-run.reorder", moved, %{
      "beforeRunId" => queued_run(context, before)["id"]
    })
  end

  step "the user removes {string} from the queue", %{args: [text]} = context do
    queue_command(context, "queued-run.cancel", text, %{})
  end

  step "the user edits {string} to read {string}", %{args: [text, new_text]} = context do
    queue_command(context, "queued-run.edit", text, %{"text" => new_text})
  end

  step "the queue holds {string} then {string}", %{args: texts} = context do
    assert queue_texts(context) == texts
    context
  end

  step "the queue holds {string}", %{args: [text]} = context do
    assert queue_texts(context) == [text]
    context
  end

  step "the agent is working on {word} and {string} is queued",
       %{args: [provider, text]} = context do
    title = "#{provider} thread"
    context = context |> World.working_thread(title, provider) |> Map.put(:current, title)
    {{:ok, _}, context} = World.send_message(context, title, text)
    context
  end

  step "the user sends {string} as a steer instead", %{args: [text]} = context do
    title = World.current(context)
    [working] = Enum.filter(World.runs(context, title), &(&1["status"] == "running"))

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "queued-message.promote-to-steer",
        "threadId" => World.thread_id(context, title),
        "queuedRunId" => queued_run(context, text)["id"],
        "targetRunId" => working["id"]
      })

    Map.put(context, :working_run, working["id"])
  end

  step "{string} joins the running turn", %{args: [text]} = context do
    assert_joined(context, text)
    context
  end

  step "the queue is empty", context do
    assert World.queued(context, World.current(context)) == []
    context
  end

  step "two messages were queued when the node restarted", context do
    title = World.current(context)
    context = World.working_thread(context, title)
    {{:ok, _}, context} = World.send_message(context, title, "first follow-up")
    {{:ok, _}, context} = World.send_message(context, title, "second follow-up")
    %{context | node: HalC2.Test.Node.restart(context.node), clients: %{}}
  end

  step "the queue is held and the messages are kept", context do
    title = World.current(context)
    queue = World.queued(context, title)
    assert Enum.map(queue, &elem(&1, 0)) == ["first follow-up", "second follow-up"]
    assert Enum.all?(queue, fn {_, run} -> run["queueHeld"] == true end)
    assert [%{"status" => "interrupted"} | _] = World.runs(context, title)
    context
  end

  step "the user resumes the queue", context do
    title = World.current(context)
    context = if context[:agents], do: context, else: World.agents(context)

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "queue.resume",
        "threadId" => World.thread_id(context, title)
      })

    context
  end

  step "the first queued message starts", context do
    title = World.current(context)
    World.await_runs(context, title, ["interrupted", "completed", "completed"])
    assert_ran_in_order(context, ["first follow-up", "second follow-up"])
    context
  end

  step "the agent was working when the node stopped", context do
    World.working_thread(context, World.current(context))
  end

  step "the turn is marked interrupted", context do
    assert [%{"status" => "interrupted"}] = World.runs(context, World.current(context))
    context
  end

  step "the thread is not shown as still working", context do
    row = World.thread(context, World.current(context))
    assert row["activeRunId"] == nil
    refute row["status"] in ~w(preparing queued starting running waiting)
    context
  end

  step "continuing threads after restarts is {word}", %{args: [setting]} = context do
    HalC2.Test.Node.ensure(HalC2.Settings)
    {_, version} = HalC2.Settings.get()

    {:ok, _} =
      HalC2.Settings.put(%{"continueThreadsAfterServerUpdate" => setting == "on"}, version)

    context
  end

  step "the agent is sent {string}", %{args: [text]} = context do
    title = World.current(context)
    World.await_runs(context, title, ["interrupted", "completed"])
    assert %{"userMessageId" => message_id} = World.run_for(context, title, text)
    message = StreamState.get(World.stream(context, title), "message")[message_id]
    assert message["createdBy"] == "agent"
    assert List.last(World.started_turns(context)) == text
    context
  end

  # The node settles and continues threads before it takes requests, so nothing
  # more happens once it is up.
  step "the thread waits for the user", context do
    assert [%{"status" => "interrupted"}] = World.runs(context, World.current(context))
    assert World.started_turns(context) == ["wait for it"]
    context
  end

  step "the provider exits before the turn starts", context do
    {{:ok, _}, context} =
      World.send_message(context, World.current(context), "exit before starting")

    context
  end

  step "the run fails with {string}", %{args: [message]} = context do
    title = World.current(context)
    World.await_runs(context, title, ["failed"])
    World.await_row(World.thread_id(context, title), &(&1["lastError"] == message))
    context
  end

  # --- helpers ---------------------------------------------------------------------

  defp sorted_runs(state),
    do: state |> StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])

  defp queue_texts(context),
    do: context |> World.queued(World.current(context)) |> Enum.map(&elem(&1, 0))

  defp queued_run(context, text) do
    {_, run} = context |> World.queued(World.current(context)) |> List.keyfind!(text, 0)
    run
  end

  defp queue_command(context, type, text, fields) do
    title = World.current(context)

    {:ok, _} =
      HalC2.Orchestration.dispatch(
        Map.merge(
          %{
            "type" => type,
            "threadId" => World.thread_id(context, title),
            "runId" => queued_run(context, text)["id"]
          },
          fields
        )
      )

    context
  end

  # The message became part of the running turn, which the agent answered.
  defp assert_joined(context, text) do
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
  end

  # The fake Codex started these turns in this order.
  defp assert_ran_in_order(context, texts) do
    started = World.started_turns(context)
    indexes = Enum.map(texts, fn text -> Enum.find_index(started, &(&1 == text)) end)
    assert Enum.all?(indexes, & &1), "turns started: #{inspect(started)}"
    assert indexes == Enum.sort(indexes), "turns started: #{inspect(started)}"
  end
end
