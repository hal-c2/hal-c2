defmodule HalC2.Steps.Orchestration.ProviderHandoff do
  @moduledoc "Steps for features/mc/orchestration/provider-handoff.feature."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Orchestration.Entities
  alias HalC2.Test.Mc.World

  @models %{"codex" => "gpt-5.4", "claudeAgent" => "claude-haiku"}
  @history_start "<conversation_history>\nThis conversation started in another agent session. Continue from it.\n\n"
  @history_end "\n</conversation_history>"

  # --- arranging --------------------------------------------------------------------

  step "thread {string} has completed runs on {string} with model {string}",
       %{args: [thread, provider, model]} = context do
    context =
      context
      |> World.providers()
      |> World.log_claude_prompts()
      |> World.named_thread(thread, nil, %{
        "modelSelection" => %{"instanceId" => provider, "model" => model}
      })

    # The fake answers "repeat ..." with the same text, one assistant line per run.
    Enum.reduce(["repeat one", "repeat two"], context, &run(&2, thread, &1))
  end

  step "the user switched {string} to {string}", %{args: [thread, provider]} = context do
    # Switching to the provider the thread already runs on only hands the
    # conversation over once it has been somewhere else first.
    context =
      if World.thread(context, thread)["providerInstanceId"] == provider do
        other = if provider == "codex", do: "claudeAgent", else: "codex"
        context = switch(context, thread, other, @models[other])
        run(context, thread, "Carry on")
      else
        context
      end

    context = switch(context, thread, provider, @models[provider])
    assert {:ok, _} = context.reply
    context
  end

  step "{string} has two completed runs and one failed run", %{args: [thread]} = context do
    assert [1, 2] = finished(context, thread) |> Enum.map(& &1["ordinal"])

    context = World.add_run(context, thread, "failed", nil, %{"ordinal" => 3})
    run = World.latest_run(context, thread)

    context
    |> World.add_message(thread, "user", "Try three", nil, %{"runId" => run["id"]})
    |> World.add_message(thread, "assistant", "It failed halfway", nil, %{"runId" => run["id"]})
  end

  step "the conversation of {string} is longer than 60,000 characters",
       %{args: [thread]} = context do
    filler = String.duplicate("x", 35_000)

    # Two long answers that cannot both be handed over.
    for {ordinal, ask, answer} <- [
          {3, "Try three", "oldest-start " <> filler},
          {4, "Try four", filler <> " newest-end"}
        ],
        reduce: context do
      context ->
        context = World.add_run(context, thread, "completed", nil, %{"ordinal" => ordinal})
        run = %{"runId" => World.latest_run(context, thread)["id"]}

        context
        |> World.add_message(thread, "user", ask, nil, run)
        |> World.add_message(thread, "assistant", answer, nil, run)
    end
  end

  step "the provider thread of {string} has no native conversation any more",
       %{args: [thread]} = context do
    # The provider process is gone and its conversation with it.
    {pid, _} = World.codex_runtime(context, thread)
    ref = Process.monitor(pid)
    :ok = DynamicSupervisor.terminate_child(HalC2.Codex.Supervisor, pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    [provider_thread] = World.entities(context, thread, "provider-thread")

    World.put_entity(context, thread, "provider-thread", provider_thread["id"], %{
      "s" => %{"nativeThreadRef" => nil}
    })
  end

  step "{string} moved from {string} to {string} and ran once there",
       %{args: [thread, from, to]} = context do
    assert World.latest_run(context, thread)["providerInstanceId"] == from
    context = switch(context, thread, to, @models[to])
    run(context, thread, "Carry on")
  end

  step "{string} moved from {string} to {string} and back to {string}",
       %{args: [thread, from, to, back]} = context do
    assert World.latest_run(context, thread)["providerInstanceId"] == from
    context = switch(context, thread, to, @models[to])
    context = run(context, thread, "Carry on")
    context = switch(context, thread, back, @models[back])
    assert {:ok, _} = context.reply
    context
  end

  # Its fake Codex names its threads and turns after it and cannot resume another
  # instance's thread (`FAKE_CODEX_INSTANCE`), as a Codex in another home cannot.
  step ~r/^an?(?:other| second) Codex instance "(?<instance>[^"]+)" with its own home$/,
       %{args: [instance]} = context do
    variable = %{"name" => "FAKE_CODEX_INSTANCE", "value" => instance}

    World.merge_settings(%{
      "providerInstances" => %{
        instance => %{"driver" => "codex", "enabled" => true, "environment" => [variable]}
      }
    })

    context
  end

  # Before each instance had its own provider thread, a thread kept the session of the
  # instance of the driver it ran on under the driver's id.
  step "{string} last ran on {string} when instances shared a provider thread",
       %{args: [thread, instance]} = context do
    ref = Entities.provider_ref("#{instance}-thread-1", "codex")
    shared(context, thread, %{"providerInstanceId" => instance, "nativeThreadRef" => ref})
  end

  # Its runs named the shared provider thread too: the run, its attempt and its provider
  # turn become that instance's, and the instance the last to run there.
  step ~r/^the (?<nth>first|latest) run of "(?<thread>[^"]+)" ran on "(?<instance>[^"]+)" when instances shared a provider thread$/,
       %{args: [nth, thread, instance]} = context do
    id = World.thread_id(context, thread)

    run =
      if nth == "first",
        do: Enum.find(World.entities(context, thread, "run"), &(&1["ordinal"] == 1)),
        else: World.latest_run(context, thread)

    attempt = run["activeAttemptId"]

    turn =
      context
      |> World.entities(thread, "provider-turn")
      |> Enum.find(&(&1["runAttemptId"] == attempt))

    turn_ref = Entities.provider_ref("#{instance}-turn-#{run["ordinal"]}", "codex")
    moved = %{"s" => %{"providerInstanceId" => instance}}

    {:ok, _} =
      HalC2.Streams.commit(id, :thread, [
        {"run", run["id"], moved},
        {"run-attempt", attempt, moved},
        {"provider-turn", turn["id"], %{"s" => %{"nativeTurnRef" => turn_ref}}}
      ])

    thread_ref = Entities.provider_ref("#{instance}-thread-1", "codex")
    shared(context, thread, %{"providerInstanceId" => instance, "nativeThreadRef" => thread_ref})
  end

  # A move brought that instance's session along, not yet continued here.
  step "{string} last ran on {string} when instances shared a provider thread and moved here with its session",
       %{args: [thread, instance]} = context do
    session = %{"driver" => "codex", "nativeId" => "#{instance}-carried", "from" => "laptop"}

    shared(context, thread, %{
      "providerInstanceId" => instance,
      "nativeThreadRef" => nil,
      "carriedSession" => session
    })
  end

  # A runtime started before it recorded its instance, then updated in place as
  # `HalC2.Hot.reload/2` does.
  step "the Codex runtime of {string} was started before it recorded its instance",
       %{args: [thread]} = context do
    {pid, _} = World.codex_runtime(context, thread)
    :ok = :sys.suspend(pid)
    :sys.replace_state(pid, &(&1 |> Map.delete(:instance) |> Map.put(:v, 2)))
    :ok = :sys.change_code(pid, HalC2.Codex.ThreadRuntime, 2, nil)
    :ok = :sys.resume(pid)
    context
  end

  # --- context occupancy --------------------------------------------------------------

  # Codex reports its token usage during a turn; the turn then ends.
  step "{string} has used 80 percent of its provider context", %{args: [thread]} = context do
    context = context |> World.running_turn(thread) |> report_usage(160_000)
    usage = await_usage(context, thread, 160_000)
    assert %{"usedTokens" => 160_000, "maxTokens" => 200_000} = usage
    context |> end_turn(thread) |> Map.put(:usage_before, usage)
  end

  step "the user changes {string} to another model on the same provider",
       %{args: [thread]} = context do
    context =
      World.command(context, %{
        "type" => "thread.model-selection.set",
        "threadId" => World.thread_id(context, thread),
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-b"}
      })

    assert {:ok, _} = context.reply
    context
  end

  step "the next run reports the context occupancy from before the change", context do
    thread = context.thread
    context = World.running_turn(context, thread)
    run = World.state(context, thread).entities["run"][context.running]
    assert run["modelSelection"]["model"] == "gpt-b"
    assert %{"model" => "gpt-b"} = List.last(World.codex_requests(context, "turn/start"))
    # The run is on the same provider thread, which still carries the earlier usage.
    assert context.usage_before == provider_thread(context, thread, run)["contextUsage"]
    context
  end

  step "the meter does not reset to zero until the provider reports new usage", context do
    thread = context.thread
    run = World.state(context, thread).entities["run"][context.running]

    # Nothing in the model change or the new run's start touched it...
    refute Enum.any?(World.events(context, thread), fn event ->
             event.kind == "provider-thread" and
               match?(
                 %{"contextUsage" => usage} when usage != context.usage_before,
                 event.patch["s"]
               )
           end)

    # ...and it moves when Codex reports usage on the new model.
    context = report_usage(context, 1_000)
    assert %{"usedTokens" => 1_000, "maxTokens" => 200_000} = await_usage(context, thread, 1_000)
    context = end_turn(context, thread)
    assert %{"usedTokens" => 1_000} = provider_thread(context, thread, run)["contextUsage"]
    context
  end

  # --- a failed turn -------------------------------------------------------------------

  # A real Codex turn that ran a command, began its answer and then failed; Codex's
  # own conversation is still there (its native thread).
  step "{string} has a failed turn whose provider context is still usable",
       %{args: [thread]} = context do
    context = World.running_turn(context, thread, "Run the migration, finishing the schema")
    {_pid, runtime} = World.codex_runtime(context, thread)

    command = %{
      "type" => "commandExecution",
      "id" => "cmd-failed",
      "command" => "mix ecto.migrate"
    }

    context
    |> World.codex_notify(thread, "item/started", %{"item" => command})
    |> World.codex_notify(thread, "item/completed", %{
      "item" =>
        Map.merge(command, %{
          "status" => "failed",
          "aggregatedOutput" => "connection refused",
          "exitCode" => 1
        })
    })
    |> World.codex_notify(thread, "item/started", %{
      "item" => %{"type" => "agentMessage", "id" => "msg-failed"}
    })
    |> World.codex_notify(thread, "item/agentMessage/delta", %{
      "itemId" => "msg-failed",
      "delta" => "The database is not"
    })
    |> World.codex_notify(thread, "turn/completed", %{
      "turn" => %{
        "id" => runtime.turn.native_turn_id,
        "status" => "failed",
        "error" => %{"message" => "The model stopped responding."}
      }
    })

    World.await_state(
      context,
      thread,
      &(&1.entities["run"][context.running]["status"] == "failed")
    )

    [provider_thread] = World.entities(context, thread, "provider-thread")
    assert %{"nativeId" => "native-thread-1"} = provider_thread["nativeThreadRef"]
    context |> Map.delete(:reply) |> Map.put(:failed_run, context.running)
  end

  step "the user switches {string} to {string} and sends a message",
       %{args: [thread, provider]} = context do
    context = switch(context, thread, provider, @models[provider])
    assert {:ok, _} = context.reply
    context = run(context, thread, "Carry on")
    Map.put(context, :prompt, List.last(World.claude_prompts(context)))
  end

  step "the provider receives the context of the failed turn", context do
    transcript = transcript(context.prompt)

    assert transcript =~
             "User: Run the migration, finishing the schema\n\n" <>
               "Command: mix ecto.migrate\nExit code: 1\nconnection refused\n\n" <>
               "Assistant: The database is not"

    assert String.ends_with?(context.prompt, @history_end <> "\n\nCarry on")
    context
  end

  step "the failed turn stays in the history of {string}", %{args: [thread]} = context do
    state = World.state(context, thread)
    assert %{"status" => "failed", "ordinal" => 3} = state.entities["run"][context.failed_run]
    {items, context} = World.timeline(context, thread)
    shown = for item <- items, item["runId"] == context.failed_run, do: item["id"]
    assert "turn-item:codex:cmd-failed" in shown
    assert "turn-item:codex:msg-failed" in shown
    # The run on the new provider came after it, as run 4.
    assert %{"ordinal" => 4, "providerInstanceId" => "claudeAgent"} =
             World.latest_run(context, thread)

    context
  end

  # --- acting -----------------------------------------------------------------------

  step "the user sets the model of {string} to {string} on {string}",
       %{args: [thread, model, provider]} = context do
    World.command(context, %{
      "type" => "thread.model-selection.set",
      "threadId" => World.thread_id(context, thread),
      "modelSelection" => %{"instanceId" => provider, "model" => model}
    })
  end

  step "the user switches {string} to {string} with model {string}",
       %{args: [thread, provider, model]} = context do
    switch(context, thread, provider, model)
  end

  step "a run starts a new provider thread for {string}", %{args: [thread]} = context do
    context = switch(context, thread, "claudeAgent", @models["claudeAgent"])
    context = run(context, thread, "Carry on")
    Map.put(context, :prompt, List.last(World.claude_prompts(context)))
  end

  step "the user switches {string} back to {string} and sends a message",
       %{args: [thread, provider]} = context do
    context = switch(context, thread, provider, @models[provider])
    run(context, thread, "where are we")
  end

  step "the next run starts on {string}", %{args: [provider]} = context do
    context = run(context, context.thread, "where are we")
    assert World.latest_run(context, context.thread)["providerInstanceId"] == provider
    context
  end

  step "the user switches thread {string} to {string}", %{args: [thread, provider]} = context do
    World.command(context, %{
      "type" => "provider.switch",
      "threadId" => thread,
      "modelSelection" => %{"instanceId" => provider, "model" => @models[provider]}
    })
  end

  # --- outcomes ---------------------------------------------------------------------

  step "thread {string} uses model {string} on provider instance {string}",
       %{args: [thread, model, instance]} = context do
    assert {:ok, _} = context.reply

    assert %{"providerInstanceId" => ^instance, "modelSelection" => %{"model" => ^model}} =
             World.thread(context, thread)

    context
  end

  step "a thread-model-selection-updated event is recorded", context do
    selection = World.thread(context, context.thread)["modelSelection"]
    id = World.thread_id(context, context.thread)

    patch =
      context
      |> World.events(context.thread)
      |> Enum.filter(&(&1.kind == "thread" and &1.entity == id))
      |> List.last()
      |> Map.fetch!(:patch)

    assert %{"s" => %{"modelSelection" => ^selection, "updatedAt" => _}} = patch
    context
  end

  step "the next run continues the same provider conversation", context do
    model = World.thread(context, context.thread)["modelSelection"]["model"]
    context = run(context, context.thread, "where are we")

    # The same native thread, no transcript, on the new model.
    assert answer(context, context.thread) == "on native-thread-1 history False merged False"
    assert [_] = World.codex_requests(context, "thread/start")

    assert %{"threadId" => "native-thread-1", "model" => ^model} =
             List.last(World.codex_requests(context, "turn/start"))

    context
  end

  step "the run answers on the Codex thread {string}", %{args: [native]} = context do
    assert answer(context, context.thread) =~ ~r/^on #{Regex.escape(native)} history /
    context
  end

  step "the run resumes the provider thread {string} had", %{args: [instance]} = context do
    run = World.latest_run(context, context.thread)
    threads = World.entities(context, context.thread, "provider-thread")
    thread = Enum.find(threads, &(&1["id"] == run["providerThreadId"]))

    assert %{"providerInstanceId" => ^instance, "nativeThreadRef" => %{"nativeId" => native}} =
             thread

    assert %{"threadId" => ^native} = List.last(World.codex_requests(context, "thread/resume"))
    assert answer(context, context.thread) =~ ~r/^on #{Regex.escape(native)} history /
    context
  end

  step "the user forks {string} after its {word} run and sends on {string}",
       %{args: [thread, nth, instance]} = context do
    context = World.fork(context, thread, %{"first" => 1, "second" => 2}[nth], "fork")
    assert {:ok, _} = context.reply
    context = switch(context, "fork", instance, @models["codex"])
    run(context, "fork", "where are we")
  end

  step "the fork's first turn forks the Codex thread {string} after {string}",
       %{args: [native, turn]} = context do
    assert %{"threadId" => ^native, "lastTurnId" => ^turn} =
             List.last(World.codex_requests(context, "thread/fork"))

    assert World.latest_run(context, "fork")["status"] == "completed"
    context
  end

  step "the fork's first turn starts a new Codex thread with the conversation", context do
    World.await_latest_run(context, "fork", "completed")
    assert World.codex_requests(context, "thread/fork") == []
    assert_history_before(Map.put(context, :thread, "fork"), "where are we")
  end

  step "the provider thread of {string} on {string} names that instance's session",
       %{args: [thread, instance]} = context do
    id = World.thread_id(context, thread)

    assert %{"providerSessionId" => session} =
             World.state(context, thread).entities["provider-thread"][
               Entities.provider_thread_id(instance, id)
             ]

    assert session == Entities.provider_session_id(instance, id)
    context
  end

  step "the session {string} runs {string} in is its own",
       %{args: [instance, thread]} = context do
    id = World.thread_id(context, thread)

    assert %{"providerInstanceId" => ^instance, "model" => "gpt-5.4", "lastError" => nil} =
             World.state(context, thread).entities["provider-session"][
               Entities.provider_session_id(instance, id)
             ]

    context
  end

  step "the run continues the carried Codex session {string}", %{args: [native]} = context do
    run = World.await_latest_run(context, context.thread, "completed")
    assert %{"threadId" => ^native} = List.last(World.codex_requests(context, "thread/fork"))

    thread =
      context
      |> World.entities(context.thread, "provider-thread")
      |> Enum.find(&(&1["id"] == run["providerThreadId"]))

    refute Map.has_key?(thread, "carriedSession")
    context
  end

  step "a new provider thread is started for {string}", %{args: [instance]} = context do
    run = World.await_latest_run(context, context.thread, "completed")
    threads = World.entities(context, context.thread, "provider-thread")
    assert [_, _] = threads
    new = Enum.find(threads, &(&1["id"] == run["providerThreadId"]))
    assert %{"providerInstanceId" => ^instance} = new
    context
  end

  step "the provider receives the earlier conversation before {string}",
       %{args: [text]} = context do
    World.await_latest_run(context, context.thread, "completed")
    assert_history_before(context, text)
  end

  step "the provider receives the earlier conversation before the message", context do
    World.await_latest_run(context, context.thread, "completed")
    assert_history_before(context, "Where were we?")
  end

  step "the transcript has a user line and an assistant line for each finished run",
       context do
    transcript = transcript(context.prompt)

    for {user, assistant} <- [
          {"repeat one", "repeat one"},
          {"repeat two", "repeat two"},
          {"Try three", "It failed halfway"}
        ] do
      assert transcript =~ "User: #{user}\n\nAssistant: #{assistant}"
    end

    # Three finished runs before this one, one line each way.
    assert length(Regex.scan(~r/^User: /m, transcript)) == 3
    assert length(Regex.scan(~r/^Assistant: /m, transcript)) == 3
    context
  end

  step "it is wrapped as conversation history ahead of the message", context do
    assert String.starts_with?(context.prompt, @history_start)
    assert String.ends_with?(context.prompt, @history_end <> "\n\nCarry on")
    context
  end

  # The note that earlier messages were omitted comes on top of the history kept.
  step "the transcript keeps at most 60,000 characters of history", context do
    transcript = transcript(context.prompt)
    history = String.replace_prefix(transcript, "[earlier messages omitted]\n\n", "")
    assert String.length(history) <= 60_000
    assert transcript =~ "newest-end"
    refute transcript =~ "oldest-start"
    # The requests around the answer left out are still there, the first one too.
    for request <- ["repeat one", "Try three", "Try four"],
        do: assert(transcript =~ "User: #{request}\n")

    context
  end

  step "it notes that earlier messages were omitted", context do
    assert String.starts_with?(transcript(context.prompt), "[earlier messages omitted]")
    context
  end

  step ~r/^the "(?<provider>[^"]+)" provider thread is resumed$/,
       %{args: [provider]} = context do
    [first | _] = runs = finished(context, context.thread)
    latest = List.last(runs)
    assert first["providerInstanceId"] == provider
    assert latest["providerInstanceId"] == provider
    assert latest["providerThreadId"] == first["providerThreadId"]

    # Its own native conversation, told only what happened elsewhere meanwhile.
    assert answer(context, context.thread) == "on native-thread-1 history True merged False"
    assert [_] = World.codex_requests(context, "thread/start")
    context
  end

  step "the provider history of {string} lists both instances", %{args: [thread]} = context do
    # The sidebar row catches up after the run.
    World.await_row(World.thread_id(context, thread), fn row ->
      Enum.sort(row["providerInstanceHistory"]) == ["claudeAgent", "codex"]
    end)

    context
  end

  step "the handoff carries only the turns since {string} last saw the thread",
       %{args: [provider]} = context do
    transcript = transcript(prompt(context))
    # The fake Claude runs `ls` in its turn, as the fake Codex does.
    assert transcript == "User: Carry on\n\nCommand: ls\na.txt\n\nAssistant: Hello from claude"

    run = World.latest_run(context, context.thread)

    assert [
             %{
               "strategy" => "delta_since_target_last_seen",
               "targetRunId" => run_id,
               "coveredRunOrdinals" => %{"from" => 3, "to" => 3},
               "summaryText" => ^transcript
             }
           ] =
             context
             |> World.entities(context.thread, "context-handoff")
             |> Enum.filter(&(&1["strategy"] == "delta_since_target_last_seen"))

    assert run_id == run["id"]
    assert run["providerInstanceId"] == provider
    context
  end

  # --- attribution, budget and delivery ---------------------------------------------

  step "each item of the handoff is marked as historical, with its role, kind and status and the thread and run it came from",
       context do
    [handoff] =
      context
      |> World.entities(context.thread, "context-handoff")
      |> Enum.filter(&(&1["strategy"] == "full_thread_summary"))

    messages = handoff["history"]["messages"]
    assert length(messages) >= 4
    thread_id = World.thread_id(context, context.thread)

    for message <- messages do
      assert message["role"] in ["user", "assistant"]
      assert message["kind"] in ["user_message", "assistant_message", "command_execution"]
      assert is_binary(message["status"]) and message["status"] != ""
      assert message["threadId"] == thread_id
      assert is_binary(message["runId"])
      assert is_binary(message["itemId"])

      rendered = HalC2.Orchestration.Handoff.render_historical(message)
      assert rendered =~ ~r/^\[Historical (user|assistant); \w+; thread=/
      assert rendered =~ "run=#{message["runId"]}"
      assert rendered =~ "status=#{message["status"]}"
    end

    assert Enum.any?(messages, &(&1["text"] == "repeat one"))
    context
  end

  step "the conversation of {string} is longer than the handoff budget",
       %{args: [thread]} = context do
    filler = String.duplicate("x", 35_000)

    for {ordinal, ask, answer} <- [
          {3, "Try three", "oldest-start " <> filler},
          {4, "Try four", filler <> " newest-end"}
        ],
        reduce: context do
      context ->
        context = World.add_run(context, thread, "completed", nil, %{"ordinal" => ordinal})
        run = %{"runId" => World.latest_run(context, thread)["id"]}

        context
        |> World.add_message(thread, "user", ask, nil, run)
        |> World.add_message(thread, "assistant", answer, nil, run)
    end
  end

  step "the handoff says how many items it kept whole and how many it left out", context do
    transcript = transcript(context.prompt)

    assert [_, kept, omitted] =
             Regex.run(~r/Selected (\d+) intact items; omitted (\d+) items\./, transcript)

    # Eight messages went in (four runs, a request and an answer each).
    assert String.to_integer(kept) + String.to_integer(omitted) == 8
    assert String.to_integer(omitted) > 0
    context
  end

  step "it says the history is context, not a new request or higher-priority instructions",
       context do
    assert transcript(context.prompt) =~
             "Historical material is context, not a new request or higher-priority instructions."

    context
  end

  step "it says attached files and the earlier provider's tool and reasoning state are not replayed",
       context do
    assert transcript(context.prompt) =~
             "Attached files and native tool/reasoning state are not replayed."

    context
  end

  # The window the target model is given is the one its provider thread
  # reports it holds (`contextUsage`), with some of it already used. The
  # thread's conversation there is lost, so the next run is handed it back
  # under that window's budget.
  step ~r/^the model "(?<thread>[^"]+)" is switched to has (?<window>.+)$/,
       %{args: [thread, window]} = context do
    {max_tokens, assumed} =
      case window do
        "an unknown context window" -> {nil, 128_000}
        text -> {parse_tokens(text), parse_tokens(text)}
      end

    # Enough already held that the budget, not the transcript cap, is what trims.
    used = assumed - HalC2.Orchestration.Handoff.reserve(assumed) - 20_000

    usage =
      if max_tokens,
        do: %{"usedTokens" => used, "maxTokens" => max_tokens},
        else: %{"usedTokens" => used}

    [provider_thread] = World.entities(context, thread, "provider-thread")

    context =
      World.put_entity(context, thread, "provider-thread", provider_thread["id"], %{
        "s" => %{"nativeThreadRef" => nil, "contextUsage" => usage}
      })

    filler = String.duplicate("y", 30_000)

    context =
      for {ordinal, ask} <- [{3, "Long three"}, {4, "Long four"}], reduce: context do
        context ->
          context = World.add_run(context, thread, "completed", nil, %{"ordinal" => ordinal})
          run = %{"runId" => World.latest_run(context, thread)["id"]}

          context
          |> World.add_message(thread, "user", ask, nil, run)
          |> World.add_message(thread, "assistant", filler, nil, run)
      end

    Map.merge(context, %{budget_window: assumed, budget_used: used})
  end

  step "the conversation is handed over with a new message", context do
    context = run(context, context.thread, "Carry on now")
    Map.put(context, :budget_message, "Carry on now")
  end

  step ~r/^the history is trimmed so that (?<reserve>.+) stay free after the message and what the provider already holds$/,
       %{args: [reserve]} = context do
    reserve = parse_tokens(reserve)
    assert reserve == HalC2.Orchestration.Handoff.reserve(context.budget_window)

    [handoff] =
      context
      |> World.entities(context.thread, "context-handoff")
      |> Enum.filter(&(&1["strategy"] == "full_thread_summary"))

    handed = String.length(handoff["summaryText"])
    message = String.length(context.budget_message)

    assert handed > 0
    assert handed + context.budget_used + message + reserve <= context.budget_window
    # And the trimming actually happened: the whole conversation is longer.
    assert handed < 60_000
    context
  end

  step "the user sends a message with two images and one other file", context do
    thread_id = World.thread_id(context, context.thread)

    {:ok, %{"attachments" => stored}} =
      HalC2.Attachments.persist(%{
        "threadId" => thread_id,
        "attachments" =>
          for name <- ["one.png", "two.png"] do
            %{
              "name" => name,
              "mimeType" => "image/png",
              "dataUrl" => "data:image/png;base64,#{Base.encode64("bytes of " <> name)}"
            }
          end
      })

    attachments =
      stored ++
        [
          %{
            "type" => "file",
            "id" => "notes-1",
            "name" => "notes.txt",
            "mimeType" => "text/plain"
          }
        ]

    # Hand it over against a window small enough for the allowance to move
    # the budget: the target provider thread reports a 64,000 window and has
    # no native conversation yet.
    provider_thread_id = Entities.provider_thread_id("claudeAgent", thread_id)
    session_id = Entities.provider_session_id("claudeAgent", thread_id)

    record =
      Entities.provider_thread(
        provider_thread_id,
        thread_id,
        session_id,
        3,
        Entities.now(),
        "claudeAgent",
        "claudeAgent"
      )
      |> Map.put("contextUsage", %{"usedTokens" => 0, "maxTokens" => 64_000})

    context =
      World.put_entity(context, context.thread, "provider-thread", provider_thread_id, %{
        "s" => record
      })

    filler = String.duplicate("z", 30_000)

    context =
      for {ordinal, ask} <- [{3, "Long three"}, {4, "Long four"}], reduce: context do
        context ->
          context =
            World.add_run(context, context.thread, "completed", nil, %{"ordinal" => ordinal})

          run = %{"runId" => World.latest_run(context, context.thread)["id"]}

          context
          |> World.add_message(context.thread, "user", ask, nil, run)
          |> World.add_message(context.thread, "assistant", filler, nil, run)
      end

    done = length(finished(context, context.thread))

    context =
      World.dispatch_message(context, context.thread, "With files", %{
        "attachments" => attachments
      })

    assert {:ok, _} = context.reply

    World.await_state(context, context.thread, fn state ->
      state
      |> HalC2.StreamState.list("run")
      |> Enum.count(&(&1["status"] in ~w(completed failed interrupted)))
      |> Kernel.>(done)
    end)

    context |> Map.delete(:reply) |> Map.put(:attachments, attachments)
  end

  step "the handoff budget is smaller by 8,192 tokens for each image and 4,096 tokens for the file",
       context do
    allowance = HalC2.Orchestration.Handoff.attachment_allowance(context.attachments)
    assert allowance == 2 * 8_192 + 4_096

    thread = %{"contextUsage" => %{"usedTokens" => 0, "maxTokens" => 64_000}}

    assert HalC2.Orchestration.Handoff.budget(nil, thread, text: "With files") -
             HalC2.Orchestration.Handoff.budget(nil, thread,
               text: "With files",
               attachments: context.attachments
             ) == allowance

    [handoff] =
      context
      |> World.entities(context.thread, "context-handoff")
      |> Enum.filter(&(&1["strategy"] == "full_thread_summary"))
      |> Enum.sort_by(& &1["createdAt"])
      |> Enum.take(-1)

    budget =
      HalC2.Orchestration.Handoff.budget(nil, thread,
        text: "With files",
        attachments: context.attachments
      )

    assert String.length(handoff["summaryText"]) <= budget
    context
  end

  step "{string} switched provider and also has a merge-back from a fork waiting",
       %{args: [thread]} = context do
    filler = String.duplicate("f", 25_000)

    # A fork with two long runs of its own, merged back and waiting.
    context = World.fork(context, thread, 2, "fork")
    assert {:ok, _} = context.reply

    context =
      for ask <- ["Fork one", "Fork two"], reduce: context do
        context ->
          ordinal = length(World.runs(context, "fork")) + 1
          context = World.add_run(context, "fork", "completed", nil, %{"ordinal" => ordinal})
          run = %{"runId" => World.latest_run(context, "fork")["id"]}

          context
          |> World.add_message("fork", "user", ask, nil, run)
          |> World.add_message("fork", "assistant", filler, nil, run)
      end

    {reply, context} =
      World.dispatch(context, %{
        "type" => "thread.merge_back",
        "createdBy" => "user",
        "sourceThreadId" => World.thread_id(context, "fork"),
        "targetThreadId" => World.thread_id(context, thread),
        "sourcePoint" => %{"type" => "latest_stable"}
      })

    assert {:ok, _} = reply

    # And the thread's own history is long, and it is switched.
    context =
      for {ordinal, ask} <- [{3, "Long three"}, {4, "Long four"}], reduce: context do
        context ->
          context = World.add_run(context, thread, "completed", nil, %{"ordinal" => ordinal})
          run = %{"runId" => World.latest_run(context, thread)["id"]}

          context
          |> World.add_message(thread, "user", ask, nil, run)
          |> World.add_message(thread, "assistant", filler, nil, run)
      end

    context = switch(context, thread, "claudeAgent", @models["claudeAgent"])
    assert {:ok, _} = context.reply
    Map.delete(context, :reply)
  end

  step "both handoffs reach the provider within the one handoff budget", context do
    World.await_latest_run(context, context.thread, "completed")
    prompt = List.last(World.claude_prompts(context))
    assert prompt =~ "<conversation_history>"
    assert prompt =~ "<merged_work>"

    [_, history] = String.split(prompt, "<conversation_history>", parts: 2)
    [history, _] = String.split(history, "</conversation_history>", parts: 2)
    [_, merged] = String.split(prompt, "<merged_work>", parts: 2)
    [merged, _] = String.split(merged, "</merged_work>", parts: 2)

    assert String.length(history) + String.length(merged) <= 60_000 + 300
    assert merged =~ "Fork two"
    context
  end

  step "the MC could not confirm that the handed-over history of {string} reached {string}",
       %{args: [thread, provider]} = context do
    context = switch(context, thread, provider, @models[provider])
    assert {:ok, _} = context.reply
    context = run(context, thread, "Carry on")

    [handoff] =
      context
      |> World.entities(thread, "context-handoff")
      |> Enum.filter(&(&1["strategy"] == "full_thread_summary"))

    [provider_thread] =
      context
      |> World.entities(thread, "provider-thread")
      |> Enum.filter(&(&1["providerInstanceId"] == provider))

    context =
      World.put_entity(context, thread, "context-handoff", handoff["id"], %{
        "s" => %{
          "delivery" => %{
            "nativeThreadId" =>
              get_in(provider_thread, ["nativeThreadRef", "nativeId"]) || "unknown",
            "status" => "pending",
            "itemIds" => []
          }
        }
      })

    Map.merge(context, %{
      uncertain_handoff: handoff["id"],
      uncertain_native: get_in(provider_thread, ["nativeThreadRef", "nativeId"])
    })
  end

  step "the user sends the next message to {string}", %{args: [thread]} = context do
    run(context, thread, "And now")
  end

  step "the turn starts on a new provider conversation", context do
    handoffs = World.entities(context, context.thread, "context-handoff")
    old = Enum.find(handoffs, &(&1["id"] == context.uncertain_handoff))
    assert old["status"] == "superseded"

    run = World.latest_run(context, context.thread)
    thread = provider_thread(context, context.thread, run)
    # The run opened a fresh native conversation rather than resuming the
    # one whose delivery was uncertain.
    assert thread["nativeThreadRef"]["nativeId"] != context.uncertain_native or
             context.uncertain_native == nil

    assert [%{}] =
             Enum.filter(
               handoffs,
               &(&1["strategy"] == "full_thread_summary" and &1["id"] != context.uncertain_handoff)
             )

    context
  end

  step "the provider receives a summary of the whole thread before the message", context do
    prompt = List.last(World.claude_prompts(context))
    transcript = transcript(prompt)
    assert transcript =~ "User: repeat one"
    assert transcript =~ "User: Carry on"
    assert String.ends_with?(prompt, @history_end <> "\n\nAnd now")
    context
  end

  # --- Codex history, compaction deferral -------------------------------------------

  step "Codex is given the earlier conversation as history of its own thread", context do
    World.await_latest_run(context, context.thread, "completed")
    assert injected_before_last_turn?(context)

    items =
      context |> World.codex_requests("thread/inject_items") |> List.last() |> Map.fetch!("items")

    texts = Enum.map(items, &hd(&1["content"])["text"])
    assert Enum.any?(texts, &(&1 =~ "Provider context handoff."))
    assert Enum.any?(texts, &(&1 =~ "[Historical user; user_message;"))
    # The part of the conversation Codex had not seen (the turn on Claude).
    assert Enum.any?(texts, &String.ends_with?(&1, "Carry on"))
    context
  end

  step "the message Codex receives holds only what the user wrote", context do
    text = hd(List.last(World.codex_requests(context, "turn/start"))["input"])["text"]
    # The shared send-a-message step's words, and nothing handed over in front.
    assert text == "carry on"
    context
  end

  step "the user switched {string} to a Codex that does not know how to take history",
       %{args: [thread]} = context do
    variable = %{"name" => "FAKE_CODEX_NO_INJECT", "value" => "1"}
    instance = %{"name" => "FAKE_CODEX_INSTANCE", "value" => "codex-old"}

    World.merge_settings(%{
      "providerInstances" => %{
        "codex-old" => %{
          "driver" => "codex",
          "enabled" => true,
          "environment" => [variable, instance]
        }
      }
    })

    context = switch(context, thread, "codex-old", @models["codex"])
    assert {:ok, _} = context.reply
    Map.delete(context, :reply)
  end

  step "Codex receives the earlier conversation in front of the message", context do
    World.await_latest_run(context, context.thread, "completed")
    text = hd(List.last(World.codex_requests(context, "turn/start"))["input"])["text"]
    assert text =~ "<conversation_history>"
    assert text =~ "User: repeat one"
    context
  end

  step "the conversation is not handed over with that message", context do
    World.await_latest_run(context, context.thread, "completed")
    prompt = List.last(World.claude_prompts(context))
    refute prompt =~ "<conversation_history>"

    [provider_thread] =
      context
      |> World.entities(context.thread, "provider-thread")
      |> Enum.filter(&(&1["providerInstanceId"] == "claudeAgent"))

    assert provider_thread["handoffDeferred"] == true
    context
  end

  step "it is handed over with the next ordinary message", context do
    context = run(context, context.thread, "Carry on")
    prompt = List.last(World.claude_prompts(context))
    assert transcript(prompt) =~ "User: repeat one"

    [provider_thread] =
      context
      |> World.entities(context.thread, "provider-thread")
      |> Enum.filter(&(&1["providerInstanceId"] == "claudeAgent"))

    refute provider_thread["handoffDeferred"]
    context
  end

  # --- queued provider switches -------------------------------------------------------

  step "{string} has a running turn on {string} and two more {string} messages queued",
       %{args: [thread, provider, _same_provider]} = context do
    context = World.running_turn(context, thread)

    Enum.reduce(["repeat three", "repeat four"], context, fn text, context ->
      queue_for(context, thread, text, provider, @models[provider])
    end)
  end

  step "the user queues {string} for {string}", %{args: [text, provider]} = context do
    queue_for(context, context.thread, text, provider, @models[provider])
  end

  step "the three {string} turns finish and the queue reaches {string}",
       %{args: [_provider, _text]} = context do
    context = end_turn(context, context.thread)

    World.await_state(context, context.thread, fn state ->
      state
      |> HalC2.StreamState.list("run")
      |> Enum.all?(&(&1["status"] in ~w(completed failed interrupted)))
    end)

    context
  end

  step "the earlier turns ran on {string} with no handoff", %{args: [provider]} = context do
    runs = finished(context, context.thread)
    codex_runs = Enum.filter(runs, &(&1["providerInstanceId"] == provider))
    assert length(codex_runs) >= 3

    handoffs = World.entities(context, context.thread, "context-handoff")
    run_ids = MapSet.new(codex_runs, & &1["id"])
    refute Enum.any?(handoffs, &MapSet.member?(run_ids, &1["targetRunId"]))
    context
  end

  step "a handoff appears in the timeline just before {string}", %{args: [text]} = context do
    {items, context} = World.timeline(context, context.thread)
    index = Enum.find_index(items, &(&1["type"] == "user_message" and &1["text"] == text))
    assert index != nil and index > 0
    assert Enum.at(items, index - 1)["type"] == "handoff"
    context
  end

  step "the handoff carries the results of all three {string} turns",
       %{args: [_provider]} = context do
    prompt = List.last(World.claude_prompts(context))
    transcript = transcript(prompt)
    assert transcript =~ "User: wait for it"
    assert transcript =~ "User: repeat three\n\nAssistant: repeat three"
    assert transcript =~ "User: repeat four\n\nAssistant: repeat four"
    context
  end

  # A provider plugin that declares everything except taking handoffs.
  step "the user queues {string} for a provider that cannot take handoff summaries",
       %{args: [text]} = context do
    context = no_handoff_provider(context, "nohandoff")
    context = queue_for(context, context.thread, text, "nohandoff", "nohandoff-1")
    Map.put(context, :unsupported_text, text)
  end

  step "the run for {string} fails with the code {string}",
       %{args: [text, code]} = context do
    context = await_all_finished(context)

    message =
      context
      |> World.entities(context.thread, "message")
      |> Enum.find(&(&1["text"] == text))

    run =
      context
      |> World.entities(context.thread, "run")
      |> Enum.find(&(&1["userMessageId"] == message["id"]))

    assert run["status"] == "failed"

    assert [%{"failure" => %{"code" => ^code}}] =
             context
             |> World.entities(context.thread, "turn-item")
             |> Enum.filter(&(&1["runId"] == run["id"] and &1["type"] == "error"))

    context
  end

  step "the run for {string} starts on {string} with the conversation intact",
       %{args: [text, provider]} = context do
    message =
      context
      |> World.entities(context.thread, "message")
      |> Enum.find(&(&1["text"] == text))

    run =
      context
      |> World.entities(context.thread, "run")
      |> Enum.find(&(&1["userMessageId"] == message["id"]))

    assert run["status"] == "completed"
    assert run["providerInstanceId"] == provider
    # The same native conversation the thread's Codex turns ran in.
    first = hd(finished(context, context.thread))
    assert run["providerThreadId"] == first["providerThreadId"]
    context
  end

  step "{string} has a running turn on the {string} instance",
       %{args: [thread, _provider]} = context do
    World.running_turn(context, thread)
  end

  # Another account on the same Codex home: its sessions are the home's, so
  # it continues the conversation itself and never needs a handoff (which is
  # what makes its not taking handoff summaries moot).
  step "another instance of {string} cannot take handoff summaries",
       %{args: [_provider]} = context do
    home = Path.join(HalC2.Paths.user_home(), ".codex")

    World.merge_settings(%{
      "providerInstances" => %{
        "codex-home2" => %{
          "driver" => "codex",
          "enabled" => true,
          "config" => %{
            "homePath" => home,
            "shadowHomePath" => Path.join(context.mc.home, "codex-shadow")
          }
        }
      }
    })

    Map.put(context, :other_instance, "codex-home2")
  end

  step "the user queues {string} for that other instance and the running turn completes",
       %{args: [text]} = context do
    context =
      queue_for(context, context.thread, text, context.other_instance, @models["codex"])

    context = end_turn(context, context.thread)

    World.await_state(context, context.thread, fn state ->
      state
      |> HalC2.StreamState.list("run")
      |> Enum.all?(&(&1["status"] in ~w(completed failed interrupted)))
    end)

    Map.put(context, :queued_text, text)
  end

  step "{string} resumes the same provider conversation on that instance",
       %{args: [text]} = context do
    message =
      context
      |> World.entities(context.thread, "message")
      |> Enum.find(&(&1["text"] == text))

    run =
      context
      |> World.entities(context.thread, "run")
      |> Enum.find(&(&1["userMessageId"] == message["id"]))

    assert run["status"] == "completed"
    assert run["providerInstanceId"] == context.other_instance
    thread = provider_thread(context, context.thread, run)
    assert thread["nativeThreadRef"]["nativeId"] == "native-thread-1"

    assert %{"threadId" => "native-thread-1"} =
             List.last(World.codex_requests(context, "thread/resume"))

    context
  end

  step "no handoff is created", context do
    assert World.entities(context, context.thread, "context-handoff") == []
    context
  end

  # --- refusals ---------------------------------------------------------------------

  step "provider instance {string} is disabled", %{args: [instance]} = context do
    World.merge_settings(%{"providers" => %{instance => %{"enabled" => false}}})
    context
  end

  step "the user switches {string} to {string}", %{args: [thread, provider]} = context do
    switch(context, thread, provider, @models[provider])
  end

  step "{string} runs on an ACP agent whose session does not offer switching models",
       %{args: [thread]} = context do
    context = no_models_acp(context, "acme", "Acme")
    context = switch(context, thread, "acme", "fake/one")
    assert {:ok, _} = context.reply
    context = run(context, thread, "hello acme")
    assert World.latest_run(context, thread)["providerInstanceId"] == "acme"
    refute HalC2.Acp.ThreadRuntime.model_switchable?(World.thread_id(context, thread))
    context
  end

  step "the user sets another model for {string}", %{args: [thread]} = context do
    World.command(context, %{
      "type" => "thread.model-selection.set",
      "threadId" => World.thread_id(context, thread),
      "modelSelection" => %{"instanceId" => "acme", "model" => "fake/two"}
    })
  end

  # --- session transitions ------------------------------------------------------------

  step "{string} has a live provider process", %{args: [thread]} = context do
    {pid, runtime} = World.codex_runtime(context, thread)
    assert Process.alive?(pid) and runtime.conn != nil
    Map.merge(context, %{thread: thread, conn_before: runtime.conn, runtime_before: pid})
  end

  step "{string} has a live provider process on {string}",
       %{args: [thread, _provider]} = context do
    {pid, runtime} = World.codex_runtime(context, thread)
    assert Process.alive?(pid) and runtime.conn != nil
    Map.merge(context, %{thread: thread, conn_before: runtime.conn, runtime_before: pid})
  end

  step ~r/^the user changes (?<what>.+) of "(?<thread>[^"]+)" and sends a message$/,
       %{args: [what, thread]} = context do
    context = change_session(context, thread, what)
    run(context, thread, "where are we")
  end

  step "the provider process of {string} is restarted", %{args: [thread]} = context do
    {_pid, runtime} = World.codex_runtime(context, thread)
    assert runtime.conn != nil and runtime.conn != context.conn_before
    context
  end

  step "the provider conversation is resumed without a handoff", context do
    assert %{"threadId" => "native-thread-1"} =
             List.last(World.codex_requests(context, "thread/resume"))

    assert answer(context, context.thread) == "on native-thread-1 history False merged False"
    context
  end

  step "the same provider process takes the turn", context do
    {pid, runtime} = World.codex_runtime(context, context.thread)
    assert pid == context.runtime_before
    assert runtime.conn == context.conn_before
    context
  end

  step "the {string} process of {string} stops", %{args: [_provider, thread]} = context do
    refute Process.alive?(context.runtime_before)
    assert Registry.lookup(HalC2.Codex.Registry, World.thread_id(context, thread)) == []
    context
  end

  step "the next run does not report the occupancy {string} had",
       %{args: [_provider]} = context do
    run = World.latest_run(context, context.thread)
    usage = provider_thread(context, context.thread, run)["contextUsage"]
    assert usage != context.usage_before
    assert usage == nil or usage["usedTokens"] != 160_000
    context
  end

  # --- compact summaries, spreading, degradation --------------------------------------

  step "a finished turn of {string} has a very long tool output",
       %{args: [thread]} = context do
    context = World.running_turn(context, thread, "wait and run the long thing")
    {_pid, runtime} = World.codex_runtime(context, thread)
    output = String.duplicate("output line ", 400)

    command = %{"type" => "commandExecution", "id" => "cmd-long", "command" => "mix test"}

    context
    |> World.codex_notify(thread, "item/started", %{"item" => command})
    |> World.codex_notify(thread, "item/completed", %{
      "item" =>
        Map.merge(command, %{
          "status" => "completed",
          "aggregatedOutput" => output,
          "exitCode" => 0
        })
    })
    |> World.codex_notify(thread, "item/started", %{
      "item" => %{"type" => "agentMessage", "id" => "msg-long"}
    })
    |> World.codex_notify(thread, "item/agentMessage/delta", %{
      "itemId" => "msg-long",
      "delta" => String.duplicate("It printed a lot. ", 100)
    })
    |> World.codex_notify(thread, "turn/completed", %{
      "turn" => %{"id" => runtime.turn.native_turn_id, "status" => "completed"}
    })
    |> then(fn context ->
      World.await_state(
        context,
        thread,
        &(&1.entities["run"][context.running]["status"] == "completed")
      )

      Map.delete(context, :reply)
    end)
  end

  step "each compacted entry of the handoff is at most 240 characters", context do
    [item] =
      context
      |> World.entities(context.thread, "turn-item")
      |> Enum.filter(&(&1["type"] == "handoff"))

    lines = String.split(item["summary"], "\n")
    assert Enum.any?(lines, &String.ends_with?(&1, "..."))

    for line <- lines do
      assert String.length(String.replace(line, ~r/^- \w+: /, "")) <= 240
    end

    context
  end

  step "two instances of {string} with different accounts", %{args: [_provider]} = context do
    variable = %{"name" => "FAKE_CODEX_INSTANCE", "value" => "codex-work"}

    World.merge_settings(%{
      "providerInstances" => %{
        "codex-work" => %{"driver" => "codex", "enabled" => true, "environment" => [variable]}
      }
    })

    context
  end

  step "the first is at its usage limit", context do
    case GenServer.whereis(HalC2.ProviderUsageLimits) do
      nil -> {:ok, _} = HalC2.ProviderUsageLimits.start_link(nil)
      _ -> :ok
    end

    HalC2.ProviderUsageLimits.update("codex", [%{"id" => "primary", "usedPercent" => 100}])
    _ = :sys.get_state(HalC2.ProviderUsageLimits)

    assert Enum.any?(
             HalC2.ProviderUsageLimits.get("codex")["windows"],
             &(&1["id"] == "primary" and &1["usedPercent"] == 100)
           )

    ExUnit.Callbacks.on_exit(fn ->
      HalC2.ProviderUsageLimits.update("codex", [%{"id" => "primary", "usedPercent" => 0}])
    end)

    context
  end

  step "new runs start on the second instance", context do
    context =
      World.named_thread(context, "fresh", nil, %{
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-a"}
      })

    context = run(context, "fresh", "hello")
    assert World.latest_run(context, "fresh")["providerInstanceId"] == "codex-work"
    context
  end

  step ~r/^the provider of "(?<thread>[^"]+)" cannot (?<capability>.+)$/,
       %{args: [thread, capability]} = context do
    context =
      case capability do
        "nest checkpoints" ->
          caps = HalC2.Orchestration.Entities.capabilities("codex")
          refute caps["checkpointing"]["supportsNestedCheckpointScopes"]
          context

        "rewind natively" ->
          # An Antigravity provider thread: its driver cannot roll its
          # conversation back (as the commands steps arrange one).
          World.merge_settings(%{
            "providerInstances" => %{
              "codexRewind" => %{"driver" => "antigravity", "displayName" => "Codex"}
            }
          })

          thread_id = World.thread_id(context, thread)
          at = Entities.now()
          provider_thread_id = "provider-thread:codexRewind:#{thread_id}"

          context =
            World.put_entity(context, thread, "provider-thread", provider_thread_id, %{
              "s" => %{
                "id" => provider_thread_id,
                "threadId" => thread_id,
                "providerInstanceId" => "codexRewind",
                "driver" => "antigravity",
                "nativeThreadRef" => %{
                  "driver" => "antigravity",
                  "nativeId" => "native-1",
                  "strength" => "strong"
                },
                "status" => "idle",
                "createdAt" => at,
                "updatedAt" => at
              }
            })

          current = World.thread(context, thread)

          World.put_entity(context, thread, "thread", thread_id, %{
            "s" => Map.put(current, "activeProviderThreadId", provider_thread_id)
          })
      end

    Map.put(context, :capability, capability)
  end

  step "a command needs it", context do
    case context.capability do
      "nest checkpoints" ->
        run(context, context.thread, "spawn a subagent")

      "rewind natively" ->
        id = World.thread_id(context, context.thread)
        scope = HalC2.Checkpoint.scope_id(id)

        World.command(context, %{
          "type" => "checkpoint.rollback",
          "threadId" => id,
          "scopeId" => scope,
          "checkpointId" => HalC2.Checkpoint.checkpoint_id(scope, 1),
          "restoreFiles" => false
        })
    end
  end

  step "the engine captures subagent work in the parent's root scope", context do
    scopes = World.entities(context, context.thread, "checkpoint-scope")
    assert scopes != []
    assert Enum.all?(scopes, &(&1["parentScopeId"] == nil))

    root = HalC2.Checkpoint.scope_id(World.thread_id(context, context.thread))
    assert Enum.any?(scopes, &(&1["id"] == root))

    assert [%{"status" => "completed"}] =
             context
             |> World.entities(context.thread, "turn-item")
             |> Enum.filter(&(&1["type"] == "subagent"))

    context
  end

  step "the engine refuses the rewind and explains the provider cannot roll back", context do
    assert {:error, message, _} = context.reply
    assert message =~ "cannot rewind its conversation"
    context
  end

  # --- helpers ----------------------------------------------------------------------

  # Codex's `thread/tokenUsage/updated` for the running turn: `used` of 200,000 tokens.
  defp report_usage(context, used) do
    {_pid, runtime} = World.codex_runtime(context, context.thread)

    World.codex_notify(context, context.thread, "thread/tokenUsage/updated", %{
      "threadId" => runtime.native_thread_id,
      "turnId" => runtime.turn.native_turn_id,
      "tokenUsage" => %{
        "last" => %{
          "totalTokens" => used,
          "inputTokens" => used - 100,
          "cachedInputTokens" => 0,
          "outputTokens" => 100,
          "reasoningOutputTokens" => 0
        },
        "total" => %{"totalTokens" => used},
        "modelContextWindow" => 200_000
      }
    })
  end

  defp await_usage(context, thread, used) do
    state =
      World.await_state(context, thread, fn state ->
        Enum.any?(
          HalC2.StreamState.list(state, "provider-thread"),
          &(&1["contextUsage"]["usedTokens"] == used)
        )
      end)

    state |> HalC2.StreamState.list("provider-thread") |> hd() |> Map.fetch!("contextUsage")
  end

  defp end_turn(context, thread) do
    {_pid, runtime} = World.codex_runtime(context, thread)

    context =
      World.codex_notify(context, thread, "turn/completed", %{
        "turn" => %{"id" => runtime.turn.native_turn_id, "status" => "completed"}
      })

    World.await_state(
      context,
      thread,
      &(&1.entities["run"][context.running]["status"] == "completed")
    )

    Map.delete(context, :reply)
  end

  defp provider_thread(context, thread, run),
    do: World.state(context, thread).entities["provider-thread"][run["providerThreadId"]]

  # "50,000 tokens" and friends, as the outline tables write them.
  defp parse_tokens(text) do
    [_, digits] = Regex.run(~r/([\d,]+)/, text)
    digits |> String.replace(",", "") |> String.to_integer()
  end

  # Queues `text` behind the thread's active run, for `provider`.
  defp queue_for(context, thread, text, provider, model) do
    before = MapSet.new(World.entities(context, thread, "run"), & &1["id"])

    context =
      World.dispatch_message(context, thread, text, %{
        "dispatchMode" => %{"type" => "queue_after_active"},
        "modelSelection" => %{"instanceId" => provider, "model" => model}
      })

    assert {:ok, _} = context.reply

    [queued] =
      for run <- World.entities(context, thread, "run"),
          not MapSet.member?(before, run["id"]),
          do: run

    assert queued["status"] == "queued"
    context |> Map.delete(:reply) |> Map.put(:thread, thread)
  end

  defp await_all_finished(context) do
    World.await_state(context, context.thread, fn state ->
      state
      |> HalC2.StreamState.list("run")
      |> Enum.all?(&(&1["status"] in ~w(completed failed interrupted)))
    end)

    context
  end

  # A provider plugin declaring everything except `missing`
  # (`HalC2.Steps.Orchestration.Commands`' policy plugins).
  defp no_handoff_provider(context, id, missing \\ [:context_handoff]) do
    capabilities = HalC2.Plugins.ProviderAdapter.capabilities() -- missing

    context
    |> World.providers()
    |> HalC2.Steps.Plugins.Fixtures.install(
      id,
      HalC2.Steps.Plugins.Fixtures.provider(id, name: id, capabilities: capabilities)
    )
    |> HalC2.Steps.Plugins.Fixtures.enable(id)
  end

  # An ACP registry agent whose sessions offer no models to switch between.
  defp no_models_acp(context, id, name) do
    context = World.acp_registry_agent(context, id, name)
    commands = Application.get_env(:hal_c2, :acp_commands, %{})

    Application.put_env(
      :hal_c2,
      :acp_commands,
      Map.put(commands, id, ["env", "FAKE_ACP_NO_MODELS=1" | List.wrap(commands[id])])
    )

    context
  end

  # The session change an outline row names, as the commands a client sends.
  defp change_session(context, thread, what) do
    id = World.thread_id(context, thread)

    case what do
      "the runtime mode" ->
        World.command(context, %{
          "type" => "thread.runtime-mode.set",
          "threadId" => id,
          "runtimeMode" => "approval-required"
        })

      "the interaction mode" ->
        World.command(context, %{
          "type" => "thread.interaction-mode.set",
          "threadId" => id,
          "interactionMode" => "plan"
        })

      "the model's options" ->
        World.command(context, %{
          "type" => "thread.model-selection.set",
          "threadId" => id,
          "modelSelection" => %{
            "instanceId" => "codex",
            "model" => "gpt-a",
            "options" => [%{"id" => "effort", "value" => "high"}]
          }
        })

      "the workspace" ->
        [session] = World.entities(context, thread, "provider-session")
        workspace = Path.join(session["cwd"], "subws")
        File.mkdir_p!(workspace)

        World.command(context, %{
          "type" => "thread.metadata.update",
          "threadId" => id,
          "worktreePath" => workspace
        })

      "the instance, to another of the same provider that can continue the conversation" ->
        home = Path.join(HalC2.Paths.user_home(), ".codex")

        World.merge_settings(%{
          "providerInstances" => %{
            "codex-home2" => %{
              "driver" => "codex",
              "enabled" => true,
              "config" => %{
                "homePath" => home,
                "shadowHomePath" => Path.join(context.mc.home, "codex-shadow")
              }
            }
          }
        })

        switch(context, thread, "codex-home2", @models["codex"])
    end
    |> tap(fn context -> assert {:ok, _} = context.reply end)
    |> Map.delete(:reply)
  end

  defp switch(context, thread, provider, model) do
    context
    |> Map.put(:thread, thread)
    |> World.command(%{
      "type" => "provider.switch",
      "threadId" => World.thread_id(context, thread),
      "modelSelection" => %{"instanceId" => provider, "model" => model}
    })
  end

  # Sends `text` and waits for its run to finish.
  defp run(context, thread, text) do
    done = length(finished(context, thread))
    context = World.dispatch_message(context, thread, text)
    assert {:ok, _} = context.reply

    World.await_state(context, thread, fn state ->
      state
      |> HalC2.StreamState.list("run")
      |> Enum.count(&(&1["status"] in ~w(completed failed interrupted)))
      |> Kernel.>(done)
    end)

    context |> Map.delete(:reply) |> Map.put(:thread, thread)
  end

  defp finished(context, thread) do
    context
    |> World.entities(thread, "run")
    |> Enum.filter(&(&1["status"] in ~w(completed failed interrupted)))
    |> Enum.sort_by(& &1["ordinal"])
  end

  # The latest run's last assistant message.
  defp answer(context, thread) do
    run = World.latest_run(context, thread)

    context
    |> World.entities(thread, "message")
    |> Enum.filter(&(&1["runId"] == run["id"] and &1["role"] == "assistant"))
    |> List.last()
    |> Map.fetch!("text")
  end

  # Fields of the provider thread every instance of Codex shared, under Codex's id, from
  # before the MC brought it up to date (`perInstance`). The session there was the
  # instance's too, its model and last error included.
  defp shared(context, thread, fields) do
    id = World.thread_id(context, thread)
    instance = fields["providerInstanceId"]

    session = %{
      "providerInstanceId" => instance,
      "model" => "#{instance}-model",
      "lastError" => "#{instance} is out of credits"
    }

    {:ok, _} =
      HalC2.Streams.commit(id, :thread, [
        {"provider-thread", Entities.provider_thread_id("codex", id),
         %{"s" => fields, "u" => ["perInstance"]}},
        {"provider-session", Entities.provider_session_id("codex", id), %{"s" => session}}
      ])

    context
  end

  # What the latest run's provider was sent. Codex takes handed-over history
  # as its own (`thread/inject_items`) ahead of the message, so what it was
  # sent is the injected history rendered as the transcript, then the text.
  defp prompt(context) do
    case World.latest_run(context, context.thread)["providerInstanceId"] do
      "claudeAgent" ->
        List.last(World.claude_prompts(context))

      _codex ->
        text = hd(List.last(World.codex_requests(context, "turn/start"))["input"])["text"]

        if injected_before_last_turn?(context) do
          items =
            context
            |> World.codex_requests("thread/inject_items")
            |> List.last()
            |> Map.fetch!("items")
            |> tl()

          transcript =
            Enum.map_join(items, "\n\n", fn item ->
              [header, raw] =
                String.split(hd(item["content"])["text"], "\n", parts: 2)

              [_historical_role, kind | _] = String.split(header, "; ")

              case String.trim(kind) do
                "user_message" -> "User: #{raw}"
                "assistant_message" -> "Assistant: #{raw}"
                _command -> raw
              end
            end)

          @history_start <> transcript <> @history_end <> "\n\n" <> text
        else
          text
        end
    end
  end

  # Whether the last Codex turn was given history of its own before it started.
  defp injected_before_last_turn?(context) do
    methods = World.codex_methods(context)

    starts =
      methods
      |> Enum.with_index()
      |> Enum.filter(fn {method, _} -> method == "turn/start" end)
      |> Enum.map(&elem(&1, 1))

    case starts do
      [] ->
        false

      _ ->
        last = List.last(starts)
        previous = Enum.at(starts, -2, -1)

        methods
        |> Enum.slice(previous + 1, last - previous - 1)
        |> Enum.member?("thread/inject_items")
    end
  end

  defp transcript(prompt) do
    assert [_, rest] = String.split(prompt, @history_start, parts: 2)
    assert [transcript, _] = String.split(rest, @history_end, parts: 2)
    transcript
  end

  defp assert_history_before(context, text) do
    prompt = prompt(context)
    transcript = transcript(prompt)
    assert transcript =~ "User: repeat one\n\nAssistant: repeat one"
    assert String.ends_with?(prompt, @history_end <> "\n\n" <> text)
    context
  end
end
