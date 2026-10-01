defmodule HalC2.Steps.Orchestration.ProviderHandoff do
  @moduledoc "Steps for features/mc/orchestration/provider-handoff.feature."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

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
           ] = World.entities(context, context.thread, "context-handoff")

    assert run_id == run["id"]
    assert run["providerInstanceId"] == provider
    context
  end

  # --- helpers ----------------------------------------------------------------------

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

  # What the latest run's provider was sent.
  defp prompt(context) do
    case World.latest_run(context, context.thread)["providerInstanceId"] do
      "codex" -> hd(List.last(World.codex_requests(context, "turn/start"))["input"])["text"]
      "claudeAgent" -> List.last(World.claude_prompts(context))
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
