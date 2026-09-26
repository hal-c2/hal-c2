defmodule T3.Steps.Orchestration.QueueAndSteering do
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.Test.Node
  alias T3.Test.Node.World

  # Turns run on the scripted fakes (`World.providers/1`): a message containing "wait"
  # keeps its turn running until it is completed or interrupted. Messages are found by
  # their text; a queued message's run is the one its `runId` names.

  @models %{"codex" => "gpt-5.4", "claudeAgent" => "claude-haiku", "opencode" => "fake/one"}
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

    context = context |> Map.put(:thread, thread) |> World.send_message(thread, text, delivery)
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    Map.put(context, :sent, text)
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

  step "the provider refuses the steer because the turn just ended", context do
    # The app-server's turn moved on: the fake refuses a steer for any other turn.
    {pid, _} = World.codex_runtime(context, context.thread)
    :sys.replace_state(pid, &put_in(&1.turn.native_turn_id, "turn-that-ended"))
    context
  end

  step "{string} is sent as a queued message instead", %{args: [text]} = context do
    assert [%{"expectedTurnId" => "turn-that-ended"}] =
             World.codex_requests(context, "turn/steer")

    assert %{"status" => "queued", "queuePosition" => 1} = run_for(context, text)

    refute Enum.any?(
             World.entities(context, context.thread, "turn-item"),
             &(&1["inputIntent"] == "steer")
           )

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

  step "its user message turn item is marked as a queued turn", context do
    assert %{"runId" => run_id} = user_item(context, context.sent, "queued_turn")
    assert run_id == run_for(context, context.sent)["id"]
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

  step "the queued message reads {string}", %{args: [text]} = context do
    assert queued_message(context)["text"] == text
    context
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
      World.send_message(context, thread, "Look at this", %{
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
      "text" => "Look at [README.md](t3-context://v1/mention/readme)",
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

  step "the user moves {string} before {string}", %{args: [text, before]} = context do
    queue_command(context, "queued-run.reorder", %{
      "runId" => run_for(context, text)["id"],
      "beforeRunId" => run_for(context, before)["id"]
    })
  end

  step "the user moves {string} before a message that is not queued", %{args: [text]} = context do
    queue_command(context, "queued-run.reorder", %{
      "runId" => run_for(context, text)["id"],
      "beforeRunId" => context.running
    })
  end

  step ~r/^the queue order is (?<texts>".+")$/, %{args: [texts]} = context do
    assert Enum.map(queued(context), &text_of(context, &1)) == quoted(texts)
    context
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

  step "{string} had a queued message when the node restarted", %{args: [thread]} = context do
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
    :ok = T3.Orchestration.start_next(World.thread_id(context, context.thread))
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
    context = World.send_message(context, thread, "Something else")
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    World.await_run(context, thread, "completed")
    # Its end asks for the next queued message, as the runtime does.
    :ok = T3.Orchestration.start_next(World.thread_id(context, thread))
    context
  end

  step "{string} is still queued", %{args: [text]} = context do
    assert %{"status" => "queued", "queueHeld" => true} = run_for(context, text)
    assert [_] = World.codex_requests(context, "turn/start")
    context
  end

  # --- helpers -----------------------------------------------------------------------

  defp selection(provider), do: %{"instanceId" => provider, "model" => @models[provider]}

  # A turn that keeps running on `provider`, which the thread is set to.
  defp provider_turn(context, thread, provider) do
    context =
      context
      |> World.providers()
      |> Map.put(:thread, thread)
      |> World.patch_thread(thread, %{"modelSelection" => selection(provider)})

    World.running_turn(context, thread)
  end

  # Queued runs arranged before a restart: the active run is only a record (the
  # provider process died with the node), and the restart holds the queue.
  defp held_queue(context, thread, texts) do
    context =
      context
      |> World.providers()
      |> Map.put(:thread, thread)
      |> World.numbered_run(thread, 1, "running")

    context = Enum.reduce(texts, context, &World.queue_message(&2, thread, &1))
    context = %{context | node: Node.restart(context.node), clients: %{}}
    assert run(context, "run-1")["status"] == "interrupted"
    context
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

  defp text_of(context, run),
    do: World.state(context, context.thread).entities["message"][run["userMessageId"]]["text"]

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
      T3.Attachments.create_upload_url(%{
        "type" => "image",
        "name" => name,
        "mimeType" => "image/png",
        "sizeBytes" => 4
      })

    :ok = T3.Attachments.store(token, "png!")
    %{"type" => "image", "id" => id, "name" => name, "mimeType" => "image/png", "sizeBytes" => 4}
  end
end
