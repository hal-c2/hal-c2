defmodule HalC2.Steps.Orchestration.QueueAndSteering do
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.StreamState
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  # Turns run on the scripted fakes (`World.providers/1`): a message containing "wait"
  # keeps its turn running until it is completed or interrupted. Messages are found by
  # their text; a queued message's run is the one its `runId` names.

  @models %{
    "codex" => "gpt-5.4",
    "claudeAgent" => "claude-haiku",
    "opencode" => "fake/one",
    "grok" => "fake/one"
  }
  @started ~w(starting running waiting completed failed interrupted)

  # --- active turns --------------------------------------------------------------------

  step ~r/^"(?<thread>[^"]+)" has a (?<status>running|waiting) turn on "(?<provider>[^"]+)"$/,
       %{args: [thread, status, provider]} = context do
    context = provider_turn(context, thread, provider)

    if status == "waiting",
      do:
        World.put_entity(context, thread, "run", context.running, %{
          "s" => %{"status" => "waiting"}
        }),
      else: context
  end

  step ~r/^"(?<thread>[^"]+)" has a running turn on "(?<provider>[^"]+)" and (?:a queued message|queued messages) (?<texts>".+")$/,
       %{args: [thread, provider, texts]} = context do
    context = provider_turn(context, thread, provider)
    Enum.reduce(quoted(texts), context, &World.queue_message(&2, thread, &1))
  end

  step ~r/^"(?<thread>[^"]+)" has (?:a running turn and )?queued messages (?<texts>".+")$/,
       %{args: [thread, texts]} = context do
    context = World.running_turn(context, thread)
    Enum.reduce(quoted(texts), context, &World.queue_message(&2, thread, &1))
  end

  step "{string} has a running turn on {string} and a message {string} queued for {string}",
       %{args: [thread, provider, text, other]} = context do
    context =
      context
      |> provider_turn(thread, provider)
      |> World.dispatch_message(thread, text, %{
        "dispatchMode" => %{"type" => "queue_after_active"},
        "modelSelection" => selection(other)
      })

    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    Map.delete(context, :reply)
  end

  step "{string} has a queued message {string}", %{args: [thread, text]} = context do
    context |> World.running_turn(thread) |> World.queue_message(thread, text)
  end

  step "{string} has a turn that is starting on {string}",
       %{args: [thread, provider]} = context do
    context
    |> World.providers()
    |> World.numbered_run(thread, 1, "starting", %{
      "providerInstanceId" => provider,
      "modelSelection" => selection(provider)
    })
    |> Map.put(:running, "run-1")
  end

  step "{string} has a run for {string} that is running", %{args: [thread, text]} = context do
    context
    |> World.numbered_run(thread, 1, "running", %{"userMessageId" => "msg-started"})
    |> World.put_entity(thread, "message", "msg-started", %{
      "s" => %{
        "id" => "msg-started",
        "threadId" => World.thread_id(context, thread),
        "runId" => "run-1",
        "role" => "user",
        "text" => text,
        "attachments" => [],
        "streaming" => false
      }
    })
    |> Map.put(:running, "run-1")
  end

  step "{string} has a running turn and a queued message {string} with ordinal {int}",
       %{args: [thread, text, ordinal]} = context do
    # Earlier runs take the ordinals before it.
    context = World.numbered_run(context, thread, ordinal - 2, "completed")
    context = context |> World.running_turn(thread) |> World.queue_message(thread, text)
    assert run_for(context, text)["ordinal"] == ordinal
    context
  end

  # --- sending while a turn is active -------------------------------------------------

  step ~r/^the user sends "(?<text>[^"]+)" to "(?<thread>[^"]+)" (?<how>with automatic delivery|with restart delivery|to restart the active turn|to queue after the active turn|as a steer)$/,
       %{args: [text, thread, how]} = context do
    delivery =
      case how do
        "with automatic delivery" -> %{"deliveryIntent" => "auto"}
        "with restart delivery" -> %{"deliveryIntent" => "restart"}
        "to restart the active turn" -> %{"dispatchMode" => %{"type" => "restart_active"}}
        "to queue after the active turn" -> %{"dispatchMode" => %{"type" => "queue_after_active"}}
        "as a steer" -> %{"deliveryIntent" => "steer"}
      end

    context =
      context |> Map.put(:thread, thread) |> World.dispatch_message(thread, text, delivery)

    # A steer may be refused; the refusal steps read the reply.
    if how != "as a steer",
      do: assert({:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}")

    Map.put(context, :sent, text)
  end

  step ~r/^the user (?:sends|sent) "(?<text>[^"]+)" for "(?<provider>[^"]+)" to "(?<thread>[^"]+)" (?<how>with automatic delivery|as a steer)$/,
       %{args: [text, provider, thread, how]} = context do
    intent = if how == "as a steer", do: "steer", else: "auto"

    context =
      World.dispatch_message(context, thread, text, %{
        "deliveryIntent" => intent,
        "modelSelection" => selection(provider)
      })

    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    Map.put(context, :sent, text)
  end

  step "{string} runs on {string}", %{args: [text, provider]} = context do
    assert %{"providerInstanceId" => ^provider} = run_for(context, text)
    context
  end

  step "thread {string} is on {string}", %{args: [thread, provider]} = context do
    assert %{"providerInstanceId" => ^provider, "modelSelection" => %{"instanceId" => ^provider}} =
             World.thread(context, thread)

    context
  end

  step "the message joins the active run as a steer", context do
    assert message(context, context.sent)["runId"] == context.running
    # No run of its own: the active run is still the thread's only one.
    assert [%{"id" => id}] = World.entities(context, context.thread, "run")
    assert id == context.running
    context
  end

  step "the run has a user message turn item marked as a steer", context do
    assert %{"runId" => run_id} = user_item(context, context.sent, "steer")
    assert run_id == context.running
    context
  end

  step "{string} waits in the queue at position {int}", %{args: [text, position]} = context do
    assert %{"status" => "queued", "queuePosition" => ^position} = run_for(context, text)
    context
  end

  step "{string} waits in the queue", %{args: [text]} = context do
    assert %{"status" => "queued", "queuePosition" => position} = run_for(context, text)
    assert is_integer(position)
    context
  end

  step "{string} waits at the end of the queue", %{args: [text]} = context do
    assert %{"status" => "queued", "queuePosition" => position} = run_for(context, text)
    assert position == length(queued(context))
    context
  end

  step "{string} is first in the queue and {string} moves to position 2",
       %{args: [first, second]} = context do
    first_in_queue(context, first)
    assert Enum.any?(positions(context, run_for(context, second)["id"]), &(&1 == 2))
    context
  end

  step "{string} is first in the queue", %{args: [text]} = context do
    first_in_queue(context, text)
    context
  end

  step "a run for {string} starts when the interrupted run ends", %{args: [text]} = context do
    id = run_for(context, text)["id"]

    state =
      World.await_state(context, context.thread, fn state ->
        state.entities["run"][id]["startedAt"] != nil
      end)

    run = state.entities["run"][id]
    interrupted = state.entities["run"][context.running]
    assert interrupted["status"] == "interrupted"
    assert run["startedAt"] >= interrupted["completedAt"]
    assert run["queuePosition"] == nil
    context
  end

  step "the provider refuses the steer", context do
    # The MC names a turn the app-server does not have; the fake refuses a steer for it
    # while its own turn keeps running.
    {pid, _} = World.codex_runtime(context, context.thread)
    :sys.replace_state(pid, &put_in(&1.turn.native_turn_id, "turn-elsewhere"))
    context
  end

  step "the turn carrying the task result starts when the interrupted run ends", context do
    id = context.delegated_run

    state =
      World.await_state(context, context.thread, &(&1.entities["run"][id]["startedAt"] != nil))

    assert state.entities["run"][context.running]["status"] == "interrupted"
    context
  end

  step "{string} and {string} wait behind it in that order", %{args: [first, second]} = context do
    assert %{"status" => "queued", "queuePosition" => 1} = run_for(context, first)
    assert %{"status" => "queued", "queuePosition" => 2} = run_for(context, second)
    context
  end

  step "the user tries to send {string} to {string} as a steer",
       %{args: [text, thread]} = context do
    context
    |> Map.put(:thread, thread)
    |> World.dispatch_message(thread, text, %{"deliveryIntent" => "steer"})
    |> Map.put(:sent, text)
  end

  step "the send fails saying Codex did not take the message into its running turn", context do
    assert {:error, message, _} = context.reply
    assert message =~ "Codex did not take the message into its running turn"
    assert message =~ "turn moved on"
    context
  end

  # The real runtime unregisters and a stand-in takes its place, dying as the
  # steer call reaches it: the session stops after it was found, mid-call.
  step "the session of {string} stops as it is asked to steer",
       %{args: [thread]} = context do
    thread_id = World.thread_id(context, thread)
    registry = HalC2.Codex.Registry

    case Registry.lookup(registry, thread_id) do
      [{real, _}] ->
        :sys.replace_state(real, fn state ->
          :ok = Registry.unregister(registry, thread_id)
          state
        end)

      [] ->
        :ok
    end

    test = self()

    spawn(fn ->
      {:ok, _} = Registry.register(registry, thread_id, nil)
      send(test, :stand_in_registered)

      receive do
        {:"$gen_call", _from, request}
        when request == :steer or (is_tuple(request) and elem(request, 0) == :steer) ->
          exit({:shutdown, :released})
      end
    end)

    assert_receive :stand_in_registered
    context
  end

  step "the send fails saying its session stopped", context do
    assert {:error, message, _} = context.reply
    assert message =~ "did not take the message into its running turn (its session stopped)"
    context
  end

  step "{string} was not queued and the turn of {string} is still running",
       %{args: [text, thread]} = context do
    refute Enum.any?(World.entities(context, thread, "message"), &(&1["text"] == text))
    assert [%{"id" => id, "status" => "running"}] = World.entities(context, thread, "run")
    assert id == context.running
    context
  end

  step "{string} is neither queued nor added to the running turn", %{args: [text]} = context do
    assert [%{"expectedTurnId" => "turn-elsewhere"}] = World.codex_requests(context, "turn/steer")
    refute Enum.any?(World.entities(context, context.thread, "message"), &(&1["text"] == text))
    assert [%{"id" => id, "status" => "running"}] = World.entities(context, context.thread, "run")
    assert id == context.running
    context
  end

  # Both carry the message's id, as a client retrying while the first is on its way. The
  # repeat is sent while Codex still holds the first: the message is in the turn, and
  # Codex has not answered.
  step "the user's client sends the steer {string} to {string} twice at once",
       %{args: [text, thread]} = context do
    message_id = "msg-#{System.unique_integer([:positive])}"

    command = %{
      "type" => "message.dispatch",
      "threadId" => World.thread_id(context, thread),
      "messageId" => message_id,
      "text" => text,
      "attachments" => [],
      "deliveryIntent" => "steer"
    }

    hold = Path.join(context.mc.home, "hold-steer")
    File.touch!(hold)
    first = Task.async(fn -> HalC2.Orchestration.dispatch(command) end)

    World.await_state(context, thread, fn state ->
      StreamState.get(state, "turn-item")["turn-item:user:#{message_id}"] != nil
    end)

    second = HalC2.Orchestration.dispatch(command)
    File.rm!(hold)
    replies = [Task.await(first, 15_000), second]

    context
    |> Map.put(:thread, thread)
    |> Map.put(:replies, replies)
    |> Map.put(:repeat_command, command)
    |> Map.put(:sent, text)
  end

  # The first send is not linked to the test: an MC restart ends it, as it ends a real one.
  step "the provider is holding the steer {string} sent to {string}",
       %{args: [text, thread]} = context do
    message_id = "msg-#{System.unique_integer([:positive])}"

    command = %{
      "type" => "message.dispatch",
      "threadId" => World.thread_id(context, thread),
      "messageId" => message_id,
      "text" => text,
      "attachments" => [],
      "deliveryIntent" => "steer"
    }

    hold = Path.join(context.mc.home, "hold-steer")
    File.touch!(hold)
    spawn(fn -> HalC2.Orchestration.dispatch(command) end)

    World.await_state(context, thread, fn state ->
      StreamState.get(state, "turn-item")["turn-item:user:#{message_id}"] != nil
    end)

    # The restart kills the runtime stuck holding the steer. Were the run still watched,
    # that could end it before the stream stops, and recovery would skip the thread (#704).
    HalC2.Orchestration.TurnWatch.release(context.running)
    false = HalC2.Orchestration.TurnWatch.driven?(context.running)

    context |> Map.put(:thread, thread) |> Map.put(:repeat_command, command)
  end

  # As a real stop goes: `Recovery.stopping?/0` holds, and the runtime, which cannot read
  # its shutdown while it waits on the provider, is killed at the limit. The next boot's
  # `Recovery.run/0` ends the stop.
  step "the MC restarts while its runtime for {string} is stuck on the provider",
       %{args: [thread]} = context do
    HalC2.Orchestration.Recovery.leaving(true)
    ExUnit.Callbacks.on_exit(fn -> HalC2.Orchestration.Recovery.leaving(false) end)

    [{runtime, _}] = Registry.lookup(HalC2.Codex.Registry, World.thread_id(context, thread))
    gone = Process.monitor(runtime)
    Process.exit(runtime, :kill)
    assert_receive {:DOWN, ^gone, :process, _, _}, 5_000
    _ = :sys.get_state(HalC2.Orchestration.TurnWatch)

    %{context | mc: Mc.restart(context.mc), clients: %{}}
  end

  step "the running turn of {string} ends", %{args: [thread]} = context do
    thread_id = World.thread_id(context, thread)

    :ok =
      HalC2.Streams.transact(thread_id, :thread, fn state ->
        ended =
          HalC2.Orchestration.upsert(state, "run", context.running, fn run ->
            Map.put(run, "status", "completed")
          end)

        {[ended], :ok}
      end)

    context
  end

  step "the user's client sends the steer {string} again", context do
    Map.put(context, :replies, [nil, HalC2.Orchestration.dispatch(context.repeat_command)])
  end

  step "the first send succeeds", context do
    assert [{:ok, _}, _] = context.replies
    context
  end

  step "the first send fails saying Codex did not take the message into its running turn",
       context do
    assert [{:error, message}, _] = context.replies
    assert message =~ "Codex did not take the message into its running turn"
    context
  end

  step "the repeat is told {string} is still being sent", context do
    assert [_, {:error, %{"message" => message}}] = context.replies
    assert message =~ "still being sent"
    context
  end

  step "sending {string} again now succeeds", context do
    assert {:ok, _} = HalC2.Orchestration.dispatch(context.repeat_command)
    context
  end

  step "Codex is asked to take {string} once", %{args: [text]} = context do
    steers = World.codex_requests(context, "turn/steer")
    assert [_] = Enum.filter(steers, &match?(%{"input" => [%{"text" => ^text} | _]}, &1))
    context
  end

  step "{string} is in the running turn once", %{args: [text]} = context do
    assert [%{"runId" => run_id}] =
             Enum.filter(
               World.entities(context, context.thread, "message"),
               &(&1["text"] == text)
             )

    assert run_id == context.running
    assert %{"runId" => ^run_id} = user_item(context, text, "steer")
    context
  end

  # The fake Codex answers the steer and ends its turn before it replies that it took it.
  step "{string} has a running turn on {string} that ends as it takes a steer",
       %{args: [thread, provider]} = context do
    provider_turn(context, thread, provider, "wait, closing soon")
  end

  step "{string} is in the turn ahead of the answer to it", %{args: [text]} = context do
    state = World.await_runs(context, context.thread, ["completed"])
    items = StreamState.list(state, "turn-item")
    steer = user_item(context, text, "steer")
    answer = Enum.find(items, &(&1["text"] == "steered: " <> text))

    assert answer, "no answer to #{inspect(text)}"
    assert steer["runId"] == context.running and answer["runId"] == context.running
    assert steer["ordinal"] < answer["ordinal"]
    context
  end

  step "the user steers {string} with {string} and an attached screenshot",
       %{args: [thread, text]} = context do
    context =
      context
      |> Map.put(:thread, thread)
      |> World.dispatch_message(thread, text, %{
        "deliveryIntent" => "steer",
        "attachments" => [upload("screenshot.png")]
      })

    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    Map.put(context, :sent, text)
  end

  step "the running turn answers {string} having seen the screenshot",
       %{args: [text]} = context do
    # The fakes answer a steer with its text (which names where the file is saved) and
    # how many images came inline.
    World.await_state(context, context.thread, fn state ->
      Enum.any?(StreamState.list(state, "message"), &steered_with_screenshot?(&1, text))
    end)

    assert %{"runId" => run_id} = user_item(context, text, "steer")
    assert run_id == context.running
    context
  end

  # --- queued runs starting -----------------------------------------------------------

  step "the running turn completes", context do
    {_pid, state} = World.codex_runtime(context, context.thread)

    World.codex_notify(context, context.thread, "turn/completed", %{
      "turn" => %{"id" => state.turn.native_turn_id, "status" => "completed"}
    })
  end

  step "the run for {string} starts with ordinal {int}", %{args: [text, ordinal]} = context do
    id = run_for(context, text)["id"]

    state =
      World.await_state(context, context.thread, fn state ->
        state.entities["run"][id]["status"] in @started
      end)

    assert %{"ordinal" => ^ordinal, "queuePosition" => nil} = state.entities["run"][id]
    Map.put(context, :sent, text)
  end

  step "the run for {string} has ordinal {int}", %{args: [text, ordinal]} = context do
    assert %{"ordinal" => ^ordinal} = run_for(context, text)
    context
  end

  step "the thread's latest run is the run for {string}", %{args: [text]} = context do
    id = run_for(context, text)["id"]
    World.await_row(World.thread_id(context, context.thread), &(&1["latestRunId"] == id))
    context
  end

  step "its user message turn item is marked as a queued turn", context do
    assert %{"runId" => run_id} = user_item(context, context.sent, "queued_turn")
    assert run_id == run_for(context, context.sent)["id"]
    context
  end

  # --- a usage limit -------------------------------------------------------------------

  # As the Codex app-server reports it: the error naming the limit, then the failed turn.
  step "the provider stops {string} because its usage limit was reached",
       %{args: [thread]} = context do
    {_pid, state} = World.codex_runtime(context, thread)
    turn = %{"threadId" => state.native_thread_id, "turnId" => state.turn.native_turn_id}
    error = %{"message" => "You've hit your usage limit."}

    context
    |> World.codex_notify(
      thread,
      "error",
      Map.merge(turn, %{
        "willRetry" => false,
        "error" => Map.put(error, "codexErrorInfo", "usageLimitExceeded")
      })
    )
    |> World.codex_notify(thread, "turn/completed", %{
      "turn" => %{"id" => state.turn.native_turn_id, "status" => "failed", "error" => error}
    })
    |> tap(fn context ->
      World.await_state(
        context,
        thread,
        &(&1.entities["run"][context.running]["status"] == "failed")
      )
    end)
  end

  step "{string} and {string} stay queued in their original order",
       %{args: [first, second]} = context do
    # The run failed as a usage limit, which is what holds the queue.
    assert Enum.any?(
             World.entities(context, context.thread, "turn-item"),
             &(&1["runId"] == context.running and &1["failure"]["class"] == "usage_limit")
           )

    assert %{"status" => "queued", "queuePosition" => 1, "queueHeld" => true} =
             run_for(context, first)

    assert %{"status" => "queued", "queuePosition" => 2, "queueHeld" => true} =
             run_for(context, second)

    assert Enum.map(queued(context), & &1["id"]) == context.queued
    context
  end

  step "neither is discarded or sent early", context do
    # What follows a run's end (starting the next queued message) has run its course:
    # the thread is idle, with both messages still waiting and only one turn ever sent.
    HalC2.Orchestration.start_next(World.thread_id(context, context.thread))
    runs = World.entities(context, context.thread, "run")
    assert Enum.map(runs, & &1["status"]) |> Enum.sort() == ~w(failed queued queued)
    assert [_only] = World.codex_requests(context, "turn/start")

    for id <- context.queued do
      run = run(context, id)
      assert run["startedAt"] == nil and run["completedAt"] == nil
      message = World.state(context, context.thread).entities["message"][run["userMessageId"]]
      assert message["text"] in ["one", "two"]
    end

    # The way out: resuming the queue sends them, first one first.
    context = queue_command(context, "queue.resume", %{})
    assert {:ok, _} = context.reply
    [first, _second] = context.queued

    World.await_state(context, context.thread, fn state ->
      state.entities["run"][first]["status"] in @started
    end)

    context
  end

  # --- cancelling, editing and reordering --------------------------------------------

  step "the user cancels queued message {string}", %{args: [text]} = context do
    queue_command(context, "queued-run.cancel", %{"runId" => run_for(context, text)["id"]})
  end

  step "{string} is cancelled", %{args: [text]} = context do
    assert %{"status" => "cancelled", "queuePosition" => nil} = run_for(context, text)
    context
  end

  step "{string} and {string} are at positions {int} and {int}",
       %{args: [a, b, pa, pb]} = context do
    assert %{"status" => "queued", "queuePosition" => ^pa} = run_for(context, a)
    assert %{"status" => "queued", "queuePosition" => ^pb} = run_for(context, b)
    context
  end

  step "the user cancels the running turn as if it were queued", context do
    context = Map.put(context, :before, run(context, context.running))
    queue_command(context, "queued-run.cancel", %{"runId" => context.running})
  end

  step "the running turn is unchanged", context do
    assert run(context, context.running) == context.before
    assert context.before["status"] == "running"
    context
  end

  step "the user edits the queued message to {string}", %{args: [text]} = context do
    queue_command(context, "queued-run.edit", %{
      "runId" => List.last(context.queued),
      "text" => text
    })
  end

  step "the user edits that message as if it were queued", context do
    queue_command(context, "queued-run.edit", %{"runId" => context.running, "text" => "Changed"})
  end

  step "the message still reads {string}", %{args: [text]} = context do
    run = run(context, context.running)
    assert run["status"] == "running"

    assert World.state(context, context.thread).entities["message"][run["userMessageId"]]["text"] ==
             text

    context
  end

  step "{string} has a queued message with an attached screenshot", %{args: [thread]} = context do
    context = World.running_turn(context, thread)
    screenshot = upload("screenshot.png")

    context =
      World.dispatch_message(context, thread, "Look at this", %{
        "dispatchMode" => %{"type" => "queue_after_active"},
        "attachments" => [screenshot],
        "context" => %{
          "version" => 1,
          "records" => [
            %{"contextId" => "shot", "kind" => "image", "attachmentId" => screenshot["id"]}
          ]
        }
      })

    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    run = run_for(context, "Look at this")
    context = Map.put(context, :queued, [run["id"]])
    assert [%{"name" => "screenshot.png"}] = queued_message(context)["attachments"]
    context
  end

  step "the user edits the queued message removing the screenshot and adding a file reference",
       context do
    queue_command(context, "queued-run.edit", %{
      "runId" => List.last(context.queued),
      "text" => "Look at [README.md](hal-c2-context://v1/mention/readme)",
      "attachments" => [],
      "context" => %{
        "version" => 1,
        "records" => [%{"contextId" => "readme", "kind" => "mention", "path" => "README.md"}]
      }
    })
  end

  step "the queued message carries only the file reference", context do
    message = queued_message(context)
    assert message["attachments"] == []
    assert [%{"kind" => "mention", "path" => "README.md"}] = message["context"]["records"]
    assert run(context, List.last(context.queued))["status"] == "queued"
    context
  end

  step "the user moves {string} before a message that is not queued", %{args: [text]} = context do
    queue_command(context, "queued-run.reorder", %{
      "runId" => run_for(context, text)["id"],
      "beforeRunId" => context.running
    })
  end

  # --- promoting to a steer ------------------------------------------------------------

  step "the user promotes {string} to a steer", %{args: [text]} = context do
    # The fake keeps the turn working through a steer, so it is still running when checked.
    File.write!(Path.join(context.mc.home, "keep-turn"), "")

    queue_command(context, "queued-message.promote-to-steer", %{
      "queuedRunId" => run_for(context, text)["id"],
      "targetRunId" => context.running
    })
  end

  step "the queued run for {string} is cancelled and leaves the queue",
       %{args: [text]} = context do
    [id | _] = context.queued
    assert %{"status" => "cancelled", "queuePosition" => nil} = run(context, id)
    assert queued(context) == []
    assert message(context, text)["runId"] == context.running
    context
  end

  step "{string} joins the running turn as a promoted steer", %{args: [text]} = context do
    assert %{"runId" => run_id} = user_item(context, text, "promoted_queued_to_steer")
    assert run_id == context.running
    assert run(context, context.running)["status"] == "running"
    context
  end

  # --- a held queue ------------------------------------------------------------------

  step "{string} had a queued message when the MC restarted", %{args: [thread]} = context do
    held_queue(context, thread, ["Later"])
  end

  step "{string} has held queued messages {string} and {string}",
       %{args: [thread, a, b]} = context do
    held_queue(context, thread, [a, b])
  end

  step "{string} has a held queued message {string}", %{args: [thread, text]} = context do
    held_queue(context, thread, [text])
  end

  step "the queued message is held", context do
    [id] = context.queued
    assert %{"status" => "queued", "queueHeld" => true} = run(context, id)
    context
  end

  step "no run starts for it", context do
    [id] = context.queued
    # What a run's end asks for; a held queue does not start.
    :ok = HalC2.Orchestration.start_next(World.thread_id(context, context.thread))
    assert %{"status" => "queued", "startedAt" => nil} = run(context, id)
    assert World.codex_requests(context, "turn/start") == []
    context
  end

  step "the user resumes the queue of {string}", %{args: [thread]} = context do
    queue_command(Map.put(context, :thread, thread), "queue.resume", %{})
  end

  step "no queued message is held", context do
    assert Enum.all?(World.entities(context, context.thread, "run"), &(&1["queueHeld"] != true))
    context
  end

  step "another run of {string} ends", %{args: [thread]} = context do
    context = World.dispatch_message(context, thread, "Something else")
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    # Its own run, the latest: the held one waits behind it with a higher ordinal.
    World.await_latest_run(context, thread, "completed")

    # Its end asks for the next queued message, as the runtime does.
    :ok = HalC2.Orchestration.start_next(World.thread_id(context, thread))
    context
  end

  step "{string} is still queued", %{args: [text]} = context do
    assert %{"status" => "queued", "queueHeld" => true} = run_for(context, text)
    assert [_] = World.codex_requests(context, "turn/start")
    context
  end

  step "{string} is still held", %{args: [text]} = context do
    # What a run's end asks for; a held queue does not start.
    :ok = HalC2.Orchestration.start_next(World.thread_id(context, context.thread))
    assert %{"status" => "queued", "queueHeld" => true} = run_for(context, text)
    context
  end

  step "{string} is held", %{args: [text]} = context do
    assert %{"status" => "queued", "queueHeld" => true} = run_for(context, text)
    context
  end

  step "another agent's message reaches {string} and its run ends",
       %{args: [thread]} = context do
    sent_and_ended(context, thread, "From another agent", %{
      "createdBy" => "agent",
      "creationSource" => "mcp"
    })
  end

  step "the user sends {string} to {string} and its run ends",
       %{args: [text, thread]} = context do
    sent_and_ended(context, thread, text, %{})
  end

  step ~r/^(?<what>a steer the user sent|the prompt of a scheduled task the user created|the MC continuing the thread after a usage limit|the MC continuing the thread after it restarted) reaches "(?<thread>[^"]+)"$/,
       %{args: [what, thread]} = context do
    fields =
      case what do
        "a steer the user sent" ->
          %{"deliveryIntent" => "steer"}

        "the prompt of a scheduled task the user created" ->
          %{"scheduledTaskId" => "task-1", "dispatchMode" => %{"type" => "queue_after_active"}}

        # As `HalC2.Orchestration.LimitRecovery` and `HalC2.Orchestration.Recovery` send them.
        "the MC continuing the thread after a usage limit" ->
          %{"createdBy" => "user", "creationSource" => "server"}

        "the MC continuing the thread after it restarted" ->
          %{"createdBy" => "agent", "creationSource" => "server"}
      end

    sent_and_ended(context, thread, "Continue where you left off.", fields)
  end

  # --- a turn being stopped ----------------------------------------------------------

  # The fake acknowledges the stop and goes on with the turn, past Codex's own
  # deadline for it (`:codex_interrupt_deadline_ms`).
  step "the user stopped the running turn of {string} and the provider is still stopping it",
       %{args: [thread]} = context do
    File.touch!(Path.join(context.mc.home, "ignore-interrupt"))
    World.put_app_env(:codex_interrupt_deadline_ms, 600_000)

    context =
      queue_command(Map.put(context, :thread, thread), "run.interrupt", %{
        "runId" => context.running
      })

    assert World.state(context, thread).entities["turn-item"][
             "turn-item:run:#{context.running}:signal:interrupt-request"
           ]

    assert run(context, context.running)["status"] == "running"
    context
  end

  step "no run starts for it until the user resumes the queue or sends a message", context do
    [id | _] = context.queued

    World.await_state(
      context,
      context.thread,
      &(&1.entities["run"][context.running]["status"] == "interrupted")
    )

    :ok = HalC2.Orchestration.start_next(World.thread_id(context, context.thread))

    assert Enum.all?(
             context.queued,
             &match?(%{"status" => "queued", "queueHeld" => true}, run(context, &1))
           )

    assert [_running] = World.codex_requests(context, "turn/start")

    # The ways out: the user sends a message, or resumes the queue.
    context = World.dispatch_message(context, context.thread, "Back again")
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    World.await_state(context, context.thread, &(&1.entities["run"][id]["status"] in @started))
    context
  end

  step "the user tries to promote {string} to a steer", %{args: [text]} = context do
    try_queue_command(context, %{
      "type" => "queued-message.promote-to-steer",
      "queuedRunId" => run_for(context, text)["id"],
      "targetRunId" => context.running
    })
  end

  step "the user tries to send {string} to {string} with restart",
       %{args: [text, thread]} = context do
    World.dispatch_message(context, thread, text, %{"deliveryIntent" => "restart"})
  end

  step "{string} is still queued and held", %{args: [text]} = context do
    assert %{"status" => "queued", "queueHeld" => true} = run_for(context, text)
    # Nothing went into the turn being stopped.
    assert run(context, context.running)["status"] == "running"
    refute "turn/steer" in World.codex_methods(context)
    assert [_running] = World.codex_requests(context, "turn/start")
    context
  end

  step "{string} is queued after {string} without steering the stopping turn",
       %{args: [later, earlier]} = context do
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    assert %{"status" => "queued", "queuePosition" => 2} = later_run = run_for(context, later)
    assert %{"status" => "queued", "queuePosition" => 1} = earlier_run = run_for(context, earlier)
    # The user sending resumed the queue Stop held.
    assert later_run["queueHeld"] != true and earlier_run["queueHeld"] != true
    refute "turn/steer" in World.codex_methods(context)
    context
  end

  # A turn of its own on the record (no provider runs it), so the hal-c2 tools take its calls.
  step "an agent is working in thread {string} in {string}",
       %{args: [thread, project]} = context do
    context
    |> World.named_thread(thread, project)
    |> World.numbered_run(thread, 1, "running")
  end

  step "the agent of {string} interrupts {string} and lets its queue run",
       %{args: [caller, thread]} = context do
    arguments = %{"threadId" => World.thread_id(context, thread), "holdQueue" => false}

    assert {:ok, %{"status" => "interrupt_requested"}} =
             World.mcp_tool(context, caller, "hal_c2_thread_interrupt", arguments)

    context
  end

  step "{string} starts once the turn has stopped", %{args: [text]} = context do
    # The provider ends the stopped turn, unless it already has.
    case World.codex_runtime(context, context.thread) do
      {_pid, %{turn: %{native_turn_id: turn}}} ->
        World.codex_notify(context, context.thread, "turn/completed", %{
          "turn" => %{"id" => turn, "status" => "interrupted"}
        })

      _ ->
        :ok
    end

    id = run_for(context, text)["id"]
    World.await_state(context, context.thread, &(&1.entities["run"][id]["status"] in @started))
    context
  end

  # --- a worktree that could not be made ---------------------------------------------

  # The thread's first message waited for a worktree of its own (as a launch in a new
  # worktree sends it), with "text" queued behind it, and making the worktree failed.
  step "{string} has a held queued message {string} because its worktree could not be set up",
       %{args: [thread, text]} = context do
    context =
      context
      |> World.providers()
      |> Map.put(:thread, thread)
      |> World.numbered_run(thread, 1, "preparing", %{
        "workspacePreparation" => %{"type" => "worktree"}
      })

    prepared = "run-1"
    context = World.queue_message(context, thread, text)

    context =
      try_queue_command(context, %{
        "type" => "prepared-run.fail",
        "runId" => prepared,
        "failure" => %{"class" => "provider_error", "message" => "git worktree add failed"}
      })

    assert {:ok, _} = context.reply, "prepared-run.fail failed: #{inspect(context.reply)}"
    assert %{"status" => "queued", "queueHeld" => true} = run_for(context, text)
    Map.delete(context, :reply)
  end

  step "{string} is still held until {string} has a worktree",
       %{args: [text, thread]} = context do
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"

    sent =
      World.entities(context, thread, "run")
      |> Enum.reject(&(&1["status"] == "queued"))
      |> Enum.max_by(& &1["ordinal"])

    World.await_state(context, thread, &(&1.entities["run"][sent["id"]]["status"] == "completed"))
    :ok = HalC2.Orchestration.start_next(World.thread_id(context, thread))
    assert %{"status" => "queued", "queueHeld" => true} = run_for(context, text)

    # Once it has one, the user sending again resumes the queue.
    worktree = Mc.tmp_dir(context.mc, "worktree")

    context =
      queue_command(context, "thread.metadata.update", %{"worktreePath" => worktree})

    context = World.dispatch_message(context, thread, "Now in the worktree")
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    id = run_for(context, text)["id"]
    World.await_state(context, thread, &(&1.entities["run"][id]["status"] in @started))
    context
  end

  # --- the user's message resumes a held queue ---------------------------------------

  # Its turn stays running, so what comes after waits behind it.
  step "the user sends {string} to {string} and its turn stays running",
       %{args: [text, thread]} = context do
    hold = Path.join(context.mc.home, "hold-turn")
    File.touch!(hold)
    context = World.dispatch_message(Map.put(context, :thread, thread), thread, text)
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    id = message(context, text)["runId"]
    World.await_state(context, thread, &(&1.entities["run"][id]["status"] == "running"))
    File.rm!(hold)
    Map.merge(context, %{running: id, sent: text})
  end

  step "a delegated task result queued behind {string} is not held", %{args: [_text]} = context do
    context = delegated_result(context, context.thread, ["task-one"])
    assert run(context, context.delegated_run)["queueHeld"] != true
    context
  end

  step "{string} starts after the run for {string} ends", %{args: [text, sent]} = context do
    id = run_for(context, text)["id"]
    assert run(context, id)["status"] == "queued"
    assert run_for(context, sent)["status"] == "running"
    context = step_complete(context)

    # The task result goes first, and its turn stays open until it is completed.
    delegated = context.delegated_run

    World.await_state(
      context,
      context.thread,
      &(&1.entities["run"][delegated]["status"] == "running")
    )

    assert run(context, id)["status"] == "queued"
    context = step_complete(context)
    World.await_state(context, context.thread, &(&1.entities["run"][id]["status"] in @started))
    context
  end

  # --- which provider can queue ------------------------------------------------------

  # Two provider plugins, one declaring everything but a queue; the thread runs on the
  # one the scenario names.
  step ~r/^"(?<thread>[^"]+)" has a running turn on a provider that (?<can>can|cannot) queue messages$/,
       %{args: [thread, can]} = context do
    context =
      context
      |> World.providers()
      |> queue_plugin("queues", [])
      |> queue_plugin("noqueue", [:queued_messages])

    instance = if can == "can", do: "queues", else: "noqueue"

    context =
      World.create_thread(context, thread, "demo", %{
        "modelSelection" => %{"instanceId" => instance, "model" => "#{instance}-1"}
      })

    context = World.dispatch_message(context, thread, "wait")
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    run = World.await_latest_run(context, thread, "running")

    context
    |> Map.delete(:reply)
    |> Map.merge(%{thread: thread, running: run["id"], running_instance: instance})
  end

  step ~r/^the user queues "(?<text>[^"]+)" for a provider that (?<can>can|cannot) queue messages$/,
       %{args: [text, can]} = context do
    instance = if can == "can", do: "queues", else: "noqueue"

    World.dispatch_message(context, context.thread, text, %{
      "dispatchMode" => %{"type" => "queue_after_active"},
      "modelSelection" => %{"instanceId" => instance, "model" => "#{instance}-1"}
    })
  end

  step "the message waits in the queue", context do
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    assert %{"status" => "queued", "providerInstanceId" => "queues"} = run_for(context, "Next")
    context
  end

  step "the message is refused saying queued messages are not supported", context do
    assert {:error, message, _} = context.reply
    assert message =~ "cannot queue messages"
    refute Enum.any?(World.entities(context, context.thread, "message"), &(&1["text"] == "Next"))
    context
  end

  step "{string} stays on the model of the running turn", %{args: [thread]} = context do
    instance = context.running_instance
    assert %{"modelSelection" => %{"instanceId" => ^instance}} = World.thread(context, thread)
    assert run(context, context.running)["status"] == "running"
    context
  end

  # --- a restart the provider never finishes -------------------------------------------

  # The fake acknowledges the stop and goes on with the turn. Codex's own deadline for a
  # stop (`:codex_interrupt_deadline_ms`) is put past the restart's.
  step "the user sends {string} to {string} to restart the active turn and the provider never ends the interrupted turn",
       %{args: [text, thread]} = context do
    File.touch!(Path.join(context.mc.home, "ignore-interrupt"))
    World.put_app_env(:codex_interrupt_deadline_ms, 600_000)
    World.put_app_env(:restart_end_ms, 200)

    context =
      World.dispatch_message(context, thread, text, %{
        "dispatchMode" => %{"type" => "restart_active", "targetRunId" => context.running}
      })

    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    Map.put(context, :sent, text)
  end

  step "the restart fails saying the provider turn did not end before the restart", context do
    id = message(context, context.sent)["runId"]

    state =
      World.await_state(context, context.thread, &(&1.entities["run"][id]["status"] == "failed"))

    assert state.entities["run"][id]["queuePosition"] == nil

    assert Enum.any?(StreamState.list(state, "turn-item"), fn item ->
             item["runId"] == id and item["type"] == "error" and
               item["failure"]["message"] =~ "did not end before the restart"
           end)

    context
  end

  step "no second turn is started alongside the first", context do
    assert [%{"id" => id}] =
             Enum.filter(
               World.entities(context, context.thread, "run"),
               &(&1["status"] == "running")
             )

    assert id == context.running
    assert [_only] = World.codex_requests(context, "turn/start")
    context
  end

  # --- delegated task results ----------------------------------------------------------

  step "a delegated task of {string} finished, so its result is queued after {string}",
       %{args: [thread, _text]} = context do
    delegated_result(context, thread, ["task-one"])
  end

  step "{string} has a running turn and a queued delegated task result",
       %{args: [thread]} = context do
    context |> World.running_turn(thread) |> delegated_result(thread, ["task-one"])
  end

  step "{string} has a queued delegated task result and a queued message {string}",
       %{args: [thread, text]} = context do
    context
    |> World.running_turn(thread)
    |> delegated_result(thread, ["task-one"])
    |> World.queue_message(thread, text)
  end

  step "{string} has a running turn and a queued result for delegated tasks {string} and {string}",
       %{args: [thread, a, b]} = context do
    context |> World.running_turn(thread) |> delegated_result(thread, [a, b])
  end

  step "the turn carrying the task result starts first", context do
    id = context.delegated_run

    state =
      World.await_state(context, context.thread, &(&1.entities["run"][id]["status"] in @started))

    assert state.entities["run"][run_for(context, "Next")["id"]]["status"] == "queued"
    context
  end

  # Once the turn carrying the result ends.
  step "{string} starts after it", %{args: [text]} = context do
    delegated = context.delegated_run

    World.await_state(
      context,
      context.thread,
      &(&1.entities["run"][delegated]["status"] == "running")
    )

    {_pid, runtime} = World.codex_runtime(context, context.thread)

    World.codex_notify(context, context.thread, "turn/completed", %{
      "turn" => %{"id" => runtime.turn.native_turn_id, "status" => "completed"}
    })

    id = run_for(context, text)["id"]

    state =
      World.await_state(context, context.thread, &(&1.entities["run"][id]["status"] in @started))

    assert state.entities["run"][delegated]["status"] == "completed"
    assert state.entities["run"][id]["ordinal"] > state.entities["run"][delegated]["ordinal"]
    context
  end

  step ~r/^the user tries to (?<action>promote it to a steer|move it in the queue|edit) the queued result$/,
       %{args: [action]} = context do
    id = context.delegated_run

    command =
      case action do
        "promote it to a steer" ->
          %{
            "type" => "queued-message.promote-to-steer",
            "queuedRunId" => id,
            "targetRunId" => context.running
          }

        "move it in the queue" ->
          %{"type" => "queued-run.reorder", "runId" => id, "beforeRunId" => nil}

        "edit" ->
          %{"type" => "queued-run.edit", "runId" => id, "text" => "something else"}
      end

    try_queue_command(context, command)
  end

  step "the user moves {string} before the queued result", %{args: [text]} = context do
    try_queue_command(context, %{
      "type" => "queued-run.reorder",
      "runId" => run_for(context, text)["id"],
      "beforeRunId" => context.delegated_run
    })
  end

  step "the user cancels the queued result", context do
    queue_command(context, "queued-run.cancel", %{"runId" => context.delegated_run})
  end

  step "it leaves the queue", context do
    assert %{"status" => "cancelled", "queuePosition" => nil} =
             run(context, context.delegated_run)

    assert queued(context) == []
    context
  end

  # The running turn ends, which is when a result left waiting would wake the agent.
  step "the agent of {string} is not woken again for {string} or {string}",
       %{args: [thread, a, b]} = context do
    tasks = World.state(context, thread).entities["subagent"]
    assert tasks[a]["completionDelivery"]["state"] == "disposed"
    assert tasks[b]["completionDelivery"]["state"] == "disposed"

    {_pid, runtime} = World.codex_runtime(context, thread)

    World.codex_notify(context, thread, "turn/completed", %{
      "turn" => %{"id" => runtime.turn.native_turn_id, "status" => "completed"}
    })

    World.await_state(
      context,
      thread,
      &(&1.entities["run"][context.running]["status"] == "completed")
    )

    thread_id = World.thread_id(context, thread)
    :ok = HalC2.Orchestration.Delegation.flush_pending(thread_id)
    :ok = HalC2.Orchestration.start_next(thread_id)

    assert World.entities(context, thread, "run") |> Enum.map(& &1["status"]) |> Enum.sort() ==
             ~w(cancelled completed)

    context
  end

  step "their results can still be read from each task's status", context do
    thread_id = World.thread_id(context, context.thread)

    for id <- context.delegated_tasks do
      assert {:ok, %{"status" => "completed", "summary" => summary}} =
               HalC2.Orchestration.Delegation.task_status(thread_id, id)

      assert summary == "#{id} is done"
    end

    context
  end

  # --- a held queue takes new messages ------------------------------------------------

  # Each as its sender queues it after the active turn, of which there is none:
  # `HalC2.Orchestration.Delegation`, Codex's background wake, and `hal_c2_thread_send`.
  step ~r/^(?<what>a delegated task result|a background command's end|another agent's message) reaches "(?<thread>[^"]+)" while no turn is running$/,
       %{args: [what, thread]} = context do
    message_id = "message:wake-#{System.unique_integer([:positive])}"
    queued = %{"messageId" => message_id, "dispatchMode" => %{"type" => "queue_after_active"}}

    fields =
      case what do
        "a delegated task result" ->
          %{
            "createdBy" => "system",
            "creationSource" => "server",
            "notification" => %{"kind" => "delegated_tasks", "summary" => "Tasks finished"},
            "delegatedCompletion" => %{
              "parentRunId" => "run-1",
              "taskIds" => ["task-one"],
              "acceptedAt" => nil
            }
          }

        "a background command's end" ->
          %{"createdBy" => "agent", "creationSource" => "provider"}

        "another agent's message" ->
          %{"createdBy" => "agent", "creationSource" => "mcp"}
      end

    context = World.dispatch_message(context, thread, what, Map.merge(queued, fields))
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    run_id = World.state(context, thread).entities["message"][message_id]["runId"]
    Map.put(context, :woken_run, run_id)
  end

  # Queued behind the running turn, on the provider the thread is on now (#1048).
  step ~r/^(?:a delegated task result|a background wake from "(?<provider>[^"]+)") for "(?<thread>[^"]+)" (?<where>waits in the queue|arrives while no turn is running)$/,
       %{args: [provider, thread, where]} = context do
    provider = if provider == "", do: nil, else: provider

    message_id = "message:wake-#{System.unique_integer([:positive])}"

    fields =
      if provider,
        do: %{
          "createdBy" => "agent",
          "creationSource" => "provider",
          "providerWake" => true,
          "modelSelection" => selection(provider),
          "notification" => %{"kind" => "background_task", "summary" => "Background activity"}
        },
        else: %{
          "createdBy" => "system",
          "creationSource" => "server",
          "notification" => %{"kind" => "delegated_tasks", "summary" => "Tasks finished"},
          "delegatedCompletion" => %{
            "parentRunId" => context.running,
            "taskIds" => ["task-one"],
            "acceptedAt" => nil
          }
        }

    context =
      World.dispatch_message(
        context,
        thread,
        "Woken",
        Map.merge(
          %{"messageId" => message_id, "dispatchMode" => %{"type" => "queue_after_active"}},
          fields
        )
      )

    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    run_id = World.state(context, thread).entities["message"][message_id]["runId"]
    if where == "waits in the queue", do: assert(run(context, run_id)["status"] == "queued")
    Map.put(context, :woken_run, run_id)
  end

  step "the agent of {string} switches it to {string}", %{args: [thread, provider]} = context do
    context =
      context
      |> World.log_claude_prompts()
      |> World.command(%{
        "type" => "provider.switch",
        "threadId" => World.thread_id(context, thread),
        "modelSelection" => selection(provider)
      })

    assert {:ok, _} = context.reply, "provider.switch failed: #{inspect(context.reply)}"
    context
  end

  step "the turn for the woken agent runs on {string}", %{args: [provider]} = context do
    id = context.woken_run
    World.await_state(context, context.thread, &(&1.entities["run"][id]["status"] in @started))

    assert %{"providerInstanceId" => ^provider, "modelSelection" => %{"instanceId" => ^provider}} =
             run(context, id)

    context
  end

  step "the woken turn completes", context do
    id = context.woken_run
    World.await_state(context, context.thread, &(&1.entities["run"][id]["status"] == "completed"))
    context
  end

  # The handoff to the provider switched to carries the turn the old provider ran
  # after the switch (#1048).
  step "Claude receives the woken turn as earlier conversation before {string}",
       %{args: [text]} = context do
    World.await_latest_run(context, context.thread, "completed")
    prompt = List.last(World.claude_prompts(context))
    assert [_, rest] = String.split(prompt, "<conversation_history>", parts: 2)
    assert [history, message] = String.split(rest, "</conversation_history>", parts: 2)
    assert history =~ "User: Woken"
    assert String.trim(message) == text
    context
  end

  step "a turn for it starts", context do
    id = context.woken_run
    World.await_state(context, context.thread, &(&1.entities["run"][id]["status"] in @started))
    assert run(context, id)["queueHeld"] != true
    context
  end

  step "the user queues {string} on {string}", %{args: [text, thread]} = context do
    World.queue_message(context, thread, text)
  end

  step "{string} is held behind {string}", %{args: [later, earlier]} = context do
    assert %{"status" => "queued", "queueHeld" => true, "queuePosition" => 2} =
             run_for(context, later)

    assert %{"status" => "queued", "queueHeld" => true, "queuePosition" => 1} =
             run_for(context, earlier)

    context
  end

  step "no run starts until the user resumes the queue", context do
    thread_id = World.thread_id(context, context.thread)
    :ok = HalC2.Orchestration.start_next(thread_id)
    assert World.codex_requests(context, "turn/start") == []
    assert Enum.all?(context.queued, &(run(context, &1)["status"] == "queued"))

    # The way out: resuming sends them in order.
    context = queue_command(context, "queue.resume", %{})
    [first | _] = context.queued

    World.await_state(context, context.thread, &(&1.entities["run"][first]["status"] in @started))
    context
  end

  # --- a queued message whose provider cannot start ----------------------------------

  # "Next" was queued for Claude, whose command is not there to start.
  step "the running turn completes and the provider for {string} cannot be started",
       %{args: [text]} = context do
    World.put_app_env(:claude_command, [Path.join(context.mc.home, "no-such-claude")])

    context =
      World.put_entity(context, context.thread, "run", run_for(context, text)["id"], %{
        "s" => %{
          "providerInstanceId" => "claudeAgent",
          "modelSelection" => selection("claudeAgent")
        }
      })

    {_pid, state} = World.codex_runtime(context, context.thread)

    World.codex_notify(context, context.thread, "turn/completed", %{
      "turn" => %{"id" => state.turn.native_turn_id, "status" => "completed"}
    })
  end

  step "the run for {string} fails", %{args: [text]} = context do
    id = run_for(context, text)["id"]
    World.await_state(context, context.thread, &(&1.entities["run"][id]["status"] == "failed"))
    Map.put(context, :failed_run, id)
  end

  step "the timeline shows an error titled {string} with the reason",
       %{args: [title]} = context do
    assert %{"failure" => %{"message" => reason}} =
             Enum.find(
               World.entities(context, context.thread, "turn-item"),
               &(&1["runId"] == context.failed_run and &1["type"] == "error" and
                   &1["title"] == title)
             ) || flunk("no #{inspect(title)} error for #{context.failed_run}")

    assert reason =~ "could not start"
    context
  end

  # --- steers that name a turn --------------------------------------------------------

  step "{string} had a running turn that completed", %{args: [thread]} = context do
    context = World.running_turn(context, thread)
    {_pid, state} = World.codex_runtime(context, thread)

    World.codex_notify(context, thread, "turn/completed", %{
      "turn" => %{"id" => state.turn.native_turn_id, "status" => "completed"}
    })

    World.await_state(
      context,
      thread,
      &(&1.entities["run"][context.running]["status"] == "completed")
    )

    context
  end

  step "a steer the user sent for that turn reaches the MC afterwards", context do
    context =
      World.dispatch_message(context, context.thread, "Also this", %{
        "deliveryIntent" => "steer",
        "dispatchMode" => %{"type" => "steer_active", "targetRunId" => context.running}
      })

    Map.put(context, :sent, "Also this")
  end

  step "the message is not lost", context do
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    assert message(context, context.sent)
    context
  end

  step "it starts a new turn of {string}", %{args: [thread]} = context do
    id = message(context, context.sent)["runId"]
    assert id != context.running

    state =
      World.await_state(context, thread, &(&1.entities["run"][id]["status"] in @started))

    assert state.entities["run"][id]["ordinal"] >
             state.entities["run"][context.running]["ordinal"]

    context
  end

  step ~r/^"(?<thread>[^"]+)" has a running turn and an older turn that (?<state>completed|was interrupted)$/,
       %{args: [thread, state]} = context do
    status = if state == "completed", do: "completed", else: "interrupted"

    context
    |> World.providers()
    |> World.numbered_run(thread, 1, status)
    |> World.running_turn(thread)
    |> Map.put(:older, "run-1")
  end

  step ~r/^the user sends "(?<text>[^"]+)" to "(?<thread>[^"]+)" as a (?<delivery>steer|restart) of the older turn$/,
       %{args: [text, thread, delivery]} = context do
    World.dispatch_message(context, thread, text, %{
      "dispatchMode" => %{"type" => "#{delivery}_active", "targetRunId" => context.older}
    })
  end

  step "the running turn is not disturbed", context do
    assert [%{"id" => id}] =
             Enum.filter(
               World.entities(context, context.thread, "run"),
               &(&1["status"] == "running")
             )

    assert id == context.running
    refute Enum.any?(World.entities(context, context.thread, "message"), &(&1["text"] == "Now"))
    assert World.codex_requests(context, "turn/interrupt") == []
    assert World.codex_requests(context, "turn/steer") == []
    context
  end

  # --- /compact and /logout -----------------------------------------------------------

  step "the user sends {string} by itself to {string} as a steer",
       %{args: [text, thread]} = context do
    World.dispatch_message(context, thread, text, %{"deliveryIntent" => "steer"})
  end

  # The running turn's message is the command alone, as a client sends it.
  step "{string} has a running turn started by {string} sent by itself",
       %{args: [thread, text]} = context do
    context = World.running_turn(context, thread)
    message_id = run(context, context.running)["userMessageId"]
    World.put_entity(context, thread, "message", message_id, %{"s" => %{"text" => text}})
  end

  # --- editing and archived queues ------------------------------------------------------

  step "{string} has a queued message {string} with no attachments",
       %{args: [thread, text]} = context do
    context = context |> World.running_turn(thread) |> World.queue_message(thread, text)
    assert queued_message(context)["attachments"] == []
    context
  end

  step "the user edits the queued message to empty text", context do
    try_queue_command(context, %{
      "type" => "queued-run.edit",
      "runId" => List.last(context.queued),
      "text" => "  "
    })
  end

  step "the command fails saying the queued run cannot be edited to an empty message", context do
    assert {:error, message, _} = context.reply
    assert message =~ "cannot be edited to an empty message"
    context
  end

  step "the queued message still reads {string}", %{args: [text]} = context do
    assert queued_message(context)["text"] == text
    assert run(context, List.last(context.queued))["status"] == "queued"
    context
  end

  step "{string} has a queued message {string} and is archived",
       %{args: [thread, text]} = context do
    context = context |> World.running_turn(thread) |> World.queue_message(thread, text)
    World.patch_thread(context, thread, %{"archivedAt" => World.iso_from_now(0)})
  end

  step "a client tries to promote {string} to a steer", %{args: [text]} = context do
    try_queue_command(context, %{
      "type" => "queued-message.promote-to-steer",
      "queuedRunId" => run_for(context, text)["id"],
      "targetRunId" => context.running
    })
  end

  step "a client tries to resume the queue of {string}", %{args: [thread]} = context do
    try_queue_command(context, %{
      "type" => "queue.resume",
      "threadId" => World.thread_id(context, thread)
    })
  end

  # --- helpers -----------------------------------------------------------------------

  defp selection(provider), do: %{"instanceId" => provider, "model" => @models[provider]}

  # A turn that keeps running on `provider`, which the thread is set to.
  defp provider_turn(context, thread, provider, text \\ "wait for it") do
    context =
      context
      |> World.providers()
      |> Map.put(:thread, thread)
      |> World.patch_thread(thread, %{
        "modelSelection" => selection(provider),
        "providerInstanceId" => provider
      })

    World.running_turn(context, thread, text)
  end

  # Queued runs arranged before a restart: the active run is only a record (the
  # provider process died with the MC), and the restart holds the queue.
  defp held_queue(context, thread, texts) do
    context =
      context
      |> World.providers()
      |> Map.put(:thread, thread)
      |> World.numbered_run(thread, 1, "running")

    context = Enum.reduce(texts, context, &World.queue_message(&2, thread, &1))
    context = %{context | mc: Mc.restart(context.mc), clients: %{}}
    assert run(context, "run-1")["status"] == "interrupted"
    context
  end

  defp steered_with_screenshot?(message, text) do
    reply = message["text"] || ""

    message["role"] == "assistant" and String.starts_with?(reply, "steered: " <> text) and
      reply =~ ~s("screenshot.png" is saved at) and String.ends_with?(reply, "(+1 image)")
  end

  # A message `fields` describe, sent to `thread`, whose run ends; its end asks for the
  # next queued message, as the runtime does.
  defp sent_and_ended(context, thread, text, fields) do
    context = Map.put(context, :thread, thread)
    message_id = "msg-ended-#{System.unique_integer([:positive])}"

    context =
      World.dispatch_message(context, thread, text, Map.put(fields, "messageId", message_id))

    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    id = World.state(context, thread).entities["message"][message_id]["runId"]

    World.await_state(
      context,
      thread,
      &(&1.entities["run"][id]["status"] in ~w(completed failed interrupted))
    )

    :ok = HalC2.Orchestration.start_next(World.thread_id(context, thread))
    context
  end

  defp step_complete(context) do
    {_pid, state} = World.codex_runtime(context, context.thread)

    World.codex_notify(context, context.thread, "turn/completed", %{
      "turn" => %{"id" => state.turn.native_turn_id, "status" => "completed"}
    })
  end

  defp quoted(texts), do: for([_, text] <- Regex.scan(~r/"([^"]+)"/, texts), do: text)

  defp queue_command(context, type, fields) do
    World.command(
      context,
      Map.merge(%{"type" => type, "threadId" => World.thread_id(context, context.thread)}, fields)
    )
    |> tap(&assert({:ok, _} = &1.reply, "#{type} failed: #{inspect(&1.reply)}"))
  end

  # A command the scenario expects may be refused: its reply is `context.reply`.
  defp try_queue_command(context, fields) do
    World.command(
      context,
      Map.put_new(fields, "threadId", World.thread_id(context, context.thread))
    )
  end

  # Delegated tasks of the running turn that finished, and the message that wakes the
  # agent for them waiting in the queue (as `HalC2.Orchestration.Delegation` queues it).
  defp delegated_result(context, thread, task_ids) do
    thread_id = World.thread_id(context, thread)
    at = World.iso_from_now(0)

    context =
      Enum.reduce(task_ids, context, fn id, context ->
        World.put_entity(context, thread, "subagent", id, %{
          "s" => %{
            "id" => id,
            "threadId" => thread_id,
            "runId" => context.running,
            "origin" => "app_owned",
            "childThreadId" => "th-child-#{id}-#{System.unique_integer([:positive])}",
            "title" => id,
            "completionWake" => "settled_only",
            "completionDelivery" => %{"state" => "delivered", "observedByRunId" => nil},
            "status" => "completed",
            "result" => "#{id} is done",
            "startedAt" => at,
            "completedAt" => at,
            "updatedAt" => at
          }
        })
      end)

    message_id = "message:delegate-result:#{hd(task_ids)}"

    context =
      World.dispatch_message(context, thread, "The delegated tasks finished.", %{
        "messageId" => message_id,
        "createdBy" => "system",
        "creationSource" => "server",
        "dispatchMode" => %{"type" => "queue_after_active"},
        "notification" => %{"kind" => "delegated_tasks", "summary" => "Tasks finished"},
        "delegatedCompletion" => %{
          "parentRunId" => context.running,
          "taskIds" => task_ids,
          "acceptedAt" => nil
        }
      })

    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    run_id = World.state(context, thread).entities["message"][message_id]["runId"]
    assert %{"status" => "queued", "queuePosition" => 1} = run(context, run_id)

    context
    |> Map.delete(:reply)
    |> Map.merge(%{delegated_run: run_id, delegated_tasks: task_ids})
  end

  defp queue_plugin(context, id, missing) do
    context
    |> HalC2.Steps.Plugins.Fixtures.install(
      id,
      HalC2.Steps.Plugins.Fixtures.provider(id,
        name: id,
        capabilities: HalC2.Plugins.ProviderAdapter.capabilities() -- missing
      )
    )
    |> HalC2.Steps.Plugins.Fixtures.enable(id)
  end

  defp run(context, id), do: World.state(context, context.thread).entities["run"][id]

  defp message(context, text) do
    Enum.find(
      World.entities(context, context.thread, "message"),
      &(&1["role"] == "user" and &1["text"] == text)
    ) ||
      flunk("no message #{inspect(text)}")
  end

  defp run_for(context, text), do: run(context, message(context, text)["runId"])

  defp queued(context) do
    World.entities(context, context.thread, "run")
    |> Enum.filter(&(&1["status"] == "queued"))
    |> Enum.sort_by(& &1["queuePosition"])
  end

  defp queued_message(context) do
    run = run(context, List.last(context.queued))
    World.state(context, context.thread).entities["message"][run["userMessageId"]]
  end

  defp user_item(context, text, intent) do
    id = message(context, text)["id"]

    Enum.find(World.entities(context, context.thread, "turn-item"), fn item ->
      item["type"] == "user_message" and item["messageId"] == id and item["inputIntent"] == intent
    end) || flunk("no #{intent} turn item for #{inspect(text)}")
  end

  # The queue positions a run was given, oldest first.
  defp positions(context, id) do
    for %{kind: "run", entity: ^id, patch: patch} <- World.events(context, context.thread),
        position = (patch["s"] || patch["m"] || %{})["queuePosition"],
        is_integer(position),
        do: position
  end

  # The message went to the front: its run was put at position 1 while the runs queued
  # before it moved behind it. (It may have started since, once the active run ended.)
  defp first_in_queue(context, text) do
    run = run_for(context, text)
    assert 1 in positions(context, run["id"])

    for id <- context[:queued] || [], id != run["id"] do
      assert Enum.any?(positions(context, id), &(&1 >= 2)), "#{id} never moved behind #{text}"
    end
  end

  defp upload(name) do
    {:ok, %{"attachmentId" => id, "relativeUrl" => "/api/attachments/upload/" <> token}} =
      HalC2.Attachments.create_upload_url(%{
        "type" => "image",
        "name" => name,
        "mimeType" => "image/png",
        "sizeBytes" => 4
      })

    :ok = HalC2.Attachments.store(token, "png!")
    %{"type" => "image", "id" => id, "name" => name, "mimeType" => "image/png", "sizeBytes" => 4}
  end
end
