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
  @noqueue "noqueue"
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

    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
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

  # --- what each provider can queue ---------------------------------------------------

  # A provider plugin that declares everything but queued messages; the thread runs on
  # it, or on Codex, which queues.
  step ~r/^"(?<thread>[^"]+)" has a running turn on a provider that (?<can>can|cannot) queue messages$/,
       %{args: [thread, can]} = context do
    capabilities = HalC2.Plugins.ProviderAdapter.capabilities() -- [:queued_messages]

    context =
      context
      |> World.providers()
      |> HalC2.Steps.Plugins.Fixtures.install(
        @noqueue,
        HalC2.Steps.Plugins.Fixtures.provider(@noqueue,
          name: @noqueue,
          capabilities: capabilities
        )
      )
      |> HalC2.Steps.Plugins.Fixtures.enable(@noqueue)

    context =
      if can == "can",
        do: provider_turn(context, thread, "codex"),
        else:
          context
          |> Map.put(:thread, thread)
          |> World.patch_thread(thread, %{
            "modelSelection" => queue_selection("cannot"),
            "providerInstanceId" => @noqueue
          })
          |> World.running_turn(thread)

    Map.put(context, :thread_model, World.thread(context, thread)["modelSelection"])
  end

  step ~r/^the user queues "(?<text>[^"]+)" for a provider that (?<can>can|cannot) queue messages$/,
       %{args: [text, can]} = context do
    context
    |> World.dispatch_message(context.thread, text, %{
      "dispatchMode" => %{"type" => "queue_after_active"},
      "modelSelection" => queue_selection(can)
    })
    |> Map.put(:sent, text)
  end

  step "the message waits in the queue", context do
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    assert %{"status" => "queued"} = run_for(context, context.sent)
    context
  end

  step "the message is refused saying queued messages are not supported", context do
    assert {:error, message, _} = context.reply
    assert message =~ "queue"

    assert Enum.all?(
             World.entities(context, context.thread, "message"),
             &(&1["text"] != context.sent)
           )

    context
  end

  step "{string} stays on the model of the running turn", %{args: [thread]} = context do
    assert World.thread(context, thread)["modelSelection"] == context.thread_model
    assert run(context, context.running)["status"] == "running"
    context
  end

  # --- a restart the provider does not let go of -----------------------------------------

  step "the user sends {string} to {string} to restart the active turn and the provider never ends the interrupted turn",
       %{args: [text, thread]} = context do
    File.write!(Path.join(context.mc.home, "ignore-interrupt"), "")
    World.put_app_env(:restart_end_ms, 300)

    context
    |> Map.put(:thread, thread)
    |> World.dispatch_message(thread, text, %{"dispatchMode" => %{"type" => "restart_active"}})
    |> Map.put(:sent, text)
  end

  step "the restart fails saying the provider turn did not end before the restart", context do
    assert {:error, message, _} = context.reply
    assert message =~ "did not end before the restart"
    assert %{"status" => "failed", "queuePosition" => nil} = run_for(context, context.sent)
    context
  end

  step "no second turn is started alongside the first", context do
    assert [_only] = World.codex_requests(context, "turn/start")
    assert run(context, context.running)["status"] == "running"
    assert queued(context) == []
    context
  end

  # --- a message queued behind a held queue ---------------------------------------------

  step "the user queues {string} on {string}", %{args: [text, thread]} = context do
    World.queue_message(Map.put(context, :thread, thread), thread, text)
  end

  step "{string} is held behind {string}", %{args: [b, a]} = context do
    assert %{"status" => "queued", "queueHeld" => true, "queuePosition" => 1} =
             run_for(context, a)

    assert %{"status" => "queued", "queueHeld" => true, "queuePosition" => 2} =
             run_for(context, b)

    context
  end

  step "no run starts until the user resumes the queue", context do
    :ok = HalC2.Orchestration.start_next(World.thread_id(context, context.thread))
    assert Enum.all?(context.queued, &(run(context, &1)["status"] == "queued"))
    assert World.codex_requests(context, "turn/start") == []

    context = queue_command(context, "queue.resume", %{})
    [first | _] = context.queued

    World.await_state(context, context.thread, fn state ->
      state.entities["run"][first]["status"] in @started
    end)

    context
  end

  # --- a queued run whose provider cannot start ------------------------------------------

  # The queued message is for Claude, whose CLI is missing.
  step "the running turn completes and the provider for {string} cannot be started",
       %{args: [text]} = context do
    World.put_app_env(:claude_command, [Path.join(context.mc.home, "no-such-claude")])

    context =
      World.put_entity(context, context.thread, "run", run_for(context, text)["id"], %{
        "s" => %{
          "modelSelection" => selection("claudeAgent"),
          "providerInstanceId" => "claudeAgent"
        }
      })

    {_pid, state} = World.codex_runtime(context, context.thread)

    context
    |> World.codex_notify(context.thread, "turn/completed", %{
      "turn" => %{"id" => state.turn.native_turn_id, "status" => "completed"}
    })
    |> Map.put(:sent, text)
  end

  step "the run for {string} fails", %{args: [text]} = context do
    id = run_for(context, text)["id"]
    World.await_state(context, context.thread, &(&1.entities["run"][id]["status"] == "failed"))
    context
  end

  step "the timeline shows an error titled {string} with the reason",
       %{args: [title]} = context do
    run_id = run_for(context, context.sent)["id"]

    IO.inspect(
      {run(context, run_id),
       World.entities(context, context.thread, "turn-item")
       |> Enum.map(&Map.take(&1, ~w(id runId type inputIntent title failure messageId)))},
      limit: :infinity
    )

    item =
      Enum.find(
        World.entities(context, context.thread, "turn-item"),
        &(&1["runId"] == run_id and &1["type"] == "error")
      ) || flunk("no error turn item for #{inspect(context.sent)}")

    assert item["title"] == title
    assert is_binary(item["failure"]["message"]) and item["failure"]["message"] != ""
    context
  end

  # --- steers and restarts aimed at the wrong turn ---------------------------------------

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

    Map.put(context, :completed, context.running)
  end

  step "a steer the user sent for that turn reaches the MC afterwards", context do
    context
    |> World.dispatch_message(context.thread, "Also", %{
      "deliveryIntent" => "steer",
      "dispatchMode" => %{"type" => "steer_active", "targetRunId" => context.completed}
    })
    |> Map.put(:sent, "Also")
  end

  step "the message is not lost", context do
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    assert message(context, context.sent)
    context
  end

  step "it starts a new turn of {string}", %{args: [thread]} = context do
    id = run_for(context, context.sent)["id"]
    assert id != context.completed

    World.await_state(context, thread, &(&1.entities["run"][id]["status"] in @started))
    assert length(World.codex_requests(context, "turn/start")) == 2
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
    assert run(context, context.running)["status"] == "running"
    assert World.codex_requests(context, "turn/interrupt") == []
    assert World.codex_requests(context, "turn/steer") == []
    assert [_only] = World.codex_requests(context, "turn/start")
    context
  end

  # --- compacting and signing out --------------------------------------------------------

  step "the user sends {string} by itself to {string} as a steer",
       %{args: [text, thread]} = context do
    World.dispatch_message(context, thread, text, %{"deliveryIntent" => "steer"})
  end

  # The run is only a record: what matters is the message that started it.
  step "{string} has a running turn started by {string} sent by itself",
       %{args: [thread, text]} = context do
    context
    |> World.providers()
    |> Map.put(:thread, thread)
    |> World.numbered_run(thread, 1, "running", %{"userMessageId" => "msg-alone"})
    |> World.put_entity(thread, "message", "msg-alone", %{
      "s" => %{
        "id" => "msg-alone",
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

  # --- editing and an archived thread's queue ---------------------------------------------

  step "{string} has a queued message {string} with no attachments",
       %{args: [thread, text]} = context do
    context = context |> World.running_turn(thread) |> World.queue_message(thread, text)
    assert queued_message(context)["attachments"] == []
    context
  end

  step "the user edits the queued message to empty text", context do
    World.command(context, %{
      "type" => "queued-run.edit",
      "threadId" => World.thread_id(context, context.thread),
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
    assert %{"status" => "queued"} = run(context, List.last(context.queued))
    assert queued_message(context)["text"] == text
    context
  end

  step "{string} has a queued message {string} and is archived",
       %{args: [thread, text]} = context do
    context = context |> World.running_turn(thread) |> World.queue_message(thread, text)
    id = World.thread_id(context, thread)
    {:ok, _} = HalC2.Orchestration.dispatch(%{"type" => "thread.archive", "threadId" => id})
    World.await_row(id, &(&1["archivedAt"] != nil))
    context
  end

  step "a client tries to promote {string} to a steer", %{args: [text]} = context do
    World.command(context, %{
      "type" => "queued-message.promote-to-steer",
      "threadId" => World.thread_id(context, context.thread),
      "queuedRunId" => run_for(context, text)["id"],
      "targetRunId" => context.running
    })
  end

  step "a client tries to resume the queue of {string}", %{args: [thread]} = context do
    World.command(context, %{
      "type" => "queue.resume",
      "threadId" => World.thread_id(context, thread)
    })
  end

  # --- helpers -----------------------------------------------------------------------

  defp selection(provider), do: %{"instanceId" => provider, "model" => @models[provider]}

  defp queue_selection("can"), do: selection("codex")
  defp queue_selection("cannot"), do: %{"instanceId" => @noqueue, "model" => "#{@noqueue}-1"}

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

  defp quoted(texts), do: for([_, text] <- Regex.scan(~r/"([^"]+)"/, texts), do: text)

  defp queue_command(context, type, fields) do
    World.command(
      context,
      Map.merge(%{"type" => type, "threadId" => World.thread_id(context, context.thread)}, fields)
    )
    |> tap(&assert({:ok, _} = &1.reply, "#{type} failed: #{inspect(&1.reply)}"))
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
