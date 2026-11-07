defmodule HalC2.Steps.Orchestration.Runs do
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World
  alias HalC2.Steps.Plugins.Fixtures

  # Provider output is delivered to the thread's Codex runtime as if the (fake)
  # app-server sent it (`test/support/fake_codex.py` keeps a "wait" turn running).

  # --- threads -----------------------------------------------------------------------

  step "thread {string} exists in {string} with provider {string}",
       %{args: [thread, project, provider]} = context do
    context
    |> World.providers()
    |> World.named_thread(thread, project, %{
      "modelSelection" => %{"instanceId" => provider, "model" => "gpt-5.4"}
    })
  end

  step "thread {string} exists in {string} with provider instance {string}",
       %{args: [thread, project, instance]} = context do
    context
    |> World.named_thread(thread, project, %{
      "modelSelection" => %{"instanceId" => instance, "model" => "gpt-5.4"}
    })
    |> Map.put(:thread, thread)
  end

  step "the MC has no provider instance {string}", %{args: [instance]} = context do
    refute Map.has_key?(HalC2.Settings.settings()["providerInstances"] || %{}, instance)
    refute HalC2.Acp.agent?(instance)
    context
  end

  step "the provider instance is reported as unavailable", context do
    assert {:error, message, _} = context.reply
    assert message == "No provider instance bound to id 'removed_instance'"
    context
  end

  step "no turn starts on any other provider", context do
    assert World.entities(context, context.thread, "run") == []
    assert World.codex_requests(context, "turn/start") == []
    assert Registry.lookup(HalC2.Codex.Registry, World.thread_id(context, context.thread)) == []
    context
  end

  # --- starting a run ----------------------------------------------------------------

  step "{string} has a run with ordinal {int} that is starting",
       %{args: [thread, ordinal]} = context do
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    run = Enum.find(World.entities(context, thread, "run"), &(&1["ordinal"] == ordinal))
    assert run, "no run with ordinal #{ordinal}"
    # The run is created starting; the provider turn moves it on.
    assert %{"s" => %{"status" => "starting"}} = created(context, thread, "run", run["id"])
    Map.put(context, :run, run["id"])
  end

  step "the run has an attempt and a root turn node", context do
    run = run(context)
    attempt = World.state(context, context.thread).entities["run-attempt"][run["activeAttemptId"]]
    assert %{"runId" => run_id, "rootNodeId" => root} = attempt
    assert run_id == run["id"] and root == run["rootNodeId"]

    assert %{"kind" => "root_turn", "runId" => ^run_id} =
             World.state(context, context.thread).entities["node"][root]

    context
  end

  step "the user message {string} is recorded with a turn-start turn item",
       %{args: [text]} = context do
    run = run(context)
    message = World.state(context, context.thread).entities["message"][run["userMessageId"]]
    assert %{"role" => "user", "text" => ^text} = message

    assert %{"type" => "user_message", "inputIntent" => "turn_start", "text" => ^text} =
             World.state(context, context.thread).entities["turn-item"][
               "turn-item:user:#{message["id"]}"
             ]

    context
  end

  step "the dispatch answers with the thread's stream sequence", context do
    assert {:ok, %{"sequence" => sequence}} = context.reply
    # The sequence covers the run the message created.
    created_at = created_seq(context, context.thread, "run", context.run)
    assert is_integer(sequence) and sequence >= created_at
    assert sequence <= World.state(context, context.thread).seq
    context
  end

  step "{string} has completed one run", %{args: [thread]} = context do
    completed_run(context, thread, "Hi")
  end

  step "the user sends another message to {string}", %{args: [thread]} = context do
    context = World.dispatch_message(context, thread, "Again")
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    context
  end

  step "the new run has ordinal 2", context do
    assert %{"ordinal" => 2} = World.latest_run(context, context.thread)
    context
  end

  step "the user sends {string} to thread {string}", %{args: [text, thread]} = context do
    World.command(context, %{
      "type" => "message.dispatch",
      "threadId" => thread,
      "messageId" => "msg-#{System.unique_integer([:positive])}",
      "text" => text,
      "attachments" => []
    })
  end

  # --- provider session and thread ---------------------------------------------------

  step "{string} has a provider session for {string} that is ready",
       %{args: [thread, driver]} = context do
    session = session(context, thread, driver)
    assert %{"status" => "ready", "driver" => ^driver} = session
    context
  end

  step "{string} has a provider thread for {string} recording run ordinal {int}",
       %{args: [thread, driver, ordinal]} = context do
    id = "provider-thread:#{driver}:#{World.thread_id(context, thread)}"

    assert %{"driver" => ^driver, "lastRunOrdinal" => ^ordinal} =
             World.state(context, thread).entities["provider-thread"][id]

    context
  end

  step "{string} has one root checkpoint scope rooted at its working directory",
       %{args: [thread]} = context do
    assert [%{"kind" => "root_run", "parentScopeId" => nil} = scope] =
             World.entities(context, thread, "checkpoint-scope")

    assert scope["cwd"] == World.project(context, "demo").root
    context
  end

  step "the provider thread records run ordinal 2", context do
    id = "provider-thread:codex:#{World.thread_id(context, context.thread)}"

    assert World.state(context, context.thread).entities["provider-thread"][id][
             "lastRunOrdinal"
           ] == 2

    context
  end

  step "the root checkpoint scope follows the new run", context do
    run = World.latest_run(context, context.thread)
    assert [scope] = World.entities(context, context.thread, "checkpoint-scope")
    assert scope["runId"] == run["id"] and scope["nodeId"] == run["rootNodeId"]
    context
  end

  step "the provider session of {string} was stopped while idle",
       %{args: [thread]} = context do
    context |> completed_run(thread, "Hi") |> stop_session(thread) |> stopped()
  end

  step "the provider session of {string} is ready", %{args: [thread]} = context do
    World.await_state(context, thread, &(session_in(&1, context, thread)["status"] == "ready"))
    context
  end

  step "the provider resumes its earlier conversation", context do
    World.await_latest_run(context, context.thread, "completed")
    assert [%{"threadId" => "native-thread-1"}] = World.codex_requests(context, "thread/resume")
    context
  end

  # --- model and working directory ---------------------------------------------------

  step "{string} uses model {string}", %{args: [thread, model]} = context do
    World.patch_thread(context, thread, %{
      "modelSelection" => %{"instanceId" => "codex", "model" => model}
    })
  end

  step "the user sends {string} to {string} choosing model {string}",
       %{args: [text, thread, model]} = context do
    context
    |> Map.put(:thread, thread)
    |> World.dispatch_message(thread, text, %{
      "modelSelection" => %{"instanceId" => "codex", "model" => model}
    })
  end

  step "the run records model {string}", %{args: [model]} = context do
    assert {:ok, _} = context.reply
    assert World.latest_run(context, context.thread)["modelSelection"]["model"] == model
    World.await_latest_run(context, context.thread, "completed")
    assert [%{"model" => ^model}] = turn_starts(context)
    context
  end

  # The named worktree stands for a real directory under the scenario's home, since
  # the provider process starts in it.
  step "{string} is in worktree {string}", %{args: [thread, path]} = context do
    dir = Mc.tmp_dir(context.mc, "worktree-#{World.slug(path)}")

    context
    |> World.patch_thread(thread, %{"worktreePath" => dir})
    |> Map.update(:worktrees, %{path => dir}, &Map.put(&1, path, dir))
  end

  step "the turn runs in {string}", %{args: [path]} = context do
    assert turn_cwd(context) == context.worktrees[path]
    context
  end

  step "the turn runs in the root of {string}", %{args: [project]} = context do
    assert turn_cwd(context) == World.project(context, project).root
    context
  end

  step "a checkpoint for ordinal 0 exists before the turn starts", context do
    assert {:ok, _} = context.reply
    root = World.project(context, "demo").root
    ref = HalC2.Checkpoint.ref(HalC2.Checkpoint.scope_id(World.thread_id(context, "t1")), 0)
    # Captured while dispatching, before the turn wrote anything: it is the commit's tree.
    tree = World.git!(root, ["rev-parse", "#{ref}^{tree}"]) |> String.trim()
    assert tree == World.git!(root, ["rev-parse", "HEAD^{tree}"]) |> String.trim()
    context
  end

  # --- provider output ---------------------------------------------------------------

  step ~r/^the provider reports (?<output>assistant text|reasoning|a command it ran|a file it changed|a web search|a dynamic tool call|a proposed plan|a to-do list)$/,
       %{args: [output]} = context do
    report(context, output)
  end

  step "the run has a {string} turn item", %{args: [type]} = context do
    run = context.running

    World.await_state(context, context.thread, fn state ->
      Enum.any?(
        HalC2.StreamState.list(state, "turn-item"),
        &(&1["type"] == type and &1["runId"] == run)
      )
    end)

    context
  end

  step "the provider streams assistant text in several chunks", context do
    context = notify(context, "item/started", item("agentMessage", "msg-s"))

    Enum.reduce(["One.\n\n", "Two.\n\n"], Map.put(context, :written, ""), fn chunk, context ->
      written = context.written <> chunk
      context = notify(context, "item/agentMessage/delta", delta("msg-s", chunk))
      await_text(context, "msg-s", written)
      Map.put(context, :written, written)
    end)
  end

  step "one assistant message grows with each chunk", context do
    appends =
      for %{kind: "turn-item", entity: "turn-item:codex:msg-s", patch: %{"a" => %{"text" => t}}} <-
            World.events(context, context.thread),
          do: t

    assert appends == ["One.\n\n", "Two.\n\n"]

    assert [%{"id" => "message:codex:msg-s", "text" => "One.\n\nTwo.\n\n"}] =
             for(
               m <- World.entities(context, context.thread, "message"),
               m["role"] == "assistant",
               do: m
             )

    context
  end

  step "the message stops streaming when the provider finishes it", context do
    text = "One.\n\nTwo.\n\nThree."
    context = notify(context, "item/completed", item("agentMessage", "msg-s", %{"text" => text}))

    state =
      World.await_state(context, context.thread, fn state ->
        state.entities["turn-item"]["turn-item:codex:msg-s"]["status"] == "completed"
      end)

    assert %{"text" => ^text, "streaming" => false} =
             state.entities["turn-item"]["turn-item:codex:msg-s"]

    assert %{"text" => ^text, "streaming" => false} =
             state.entities["message"]["message:codex:msg-s"]

    context
  end

  step "project {string} streams responses by {string}", %{args: [project, mode]} = context do
    id = World.project(context, project).id
    context = World.providers(context)

    World.update_settings(context, %{
      "projectSettingsOverrides" => %{id => %{"responseStreamingMode" => mode}}
    })

    assert HalC2.Settings.for_project(id)["responseStreamingMode"] == mode
    context
  end

  step "project {string} has no response streaming setting", %{args: [project]} = context do
    id = World.project(context, project).id
    context = World.providers(context)
    {settings, _} = HalC2.Settings.get()

    refute Map.has_key?(
             get_in(settings, ["projectSettingsOverrides", id]) || %{},
             "responseStreamingMode"
           )

    assert HalC2.Settings.for_project(id)["responseStreamingMode"] in [nil, "paragraph"]
    context
  end

  step "the provider streams assistant text", context do
    stream_text(context)
  end

  step "a turn streams assistant text", context do
    context |> World.running_turn(context.thread) |> stream_text()
  end

  step ~r/^the text is written (?<cadence>.+)$/, %{args: [cadence]} = context do
    cond do
      String.starts_with?(cadence, "only at a boundary") ->
        # Nothing of the message is written while the command's output is.
        assert text(context, "msg-t") == ""
        finish_text(context)

      String.starts_with?(cadence, "a paragraph") ->
        # The finished paragraph is written; the partial one waits.
        assert text(context, "msg-t") == "One.\n\n"
        observed = System.monotonic_time(:millisecond)
        more = "o.\n\n```\ncode\n\n```\nThr"
        context = notify(context, "item/agentMessage/delta", delta("msg-t", more))
        await_text(context, "msg-t", "One.\n\nTwo.\n\n```\ncode\n\n```\n")

        # `observed` trails the first write by up to a poll, so the gap seen here is a
        # little under the 400 ms the writer waits; an unthrottled write takes a few ms.
        if String.contains?(cadence, "400 ms"),
          do: assert(System.monotonic_time(:millisecond) - observed >= 300)

        finish_text(context)
    end
  end

  # --- reasoning and held-back text stream by the same rules --------------------------

  step "the provider streams reasoning text", context do
    stream_witnessed(context, "reason-t", "item/reasoning/textDelta", "One.\n\nTw")
  end

  step "the reasoning is written a paragraph at a time, at most every 400 ms", context do
    assert text(context, "reason-t") == "One.\n\n"
    observed = System.monotonic_time(:millisecond)
    context = notify(context, "item/reasoning/textDelta", delta("reason-t", "o.\n\nThr"))
    await_text(context, "reason-t", "One.\n\nTwo.\n\n")
    assert System.monotonic_time(:millisecond) - observed >= 300
    context
  end

  step "by {string} it is written only when the reasoning is finished",
       %{args: [mode]} = context do
    # A fresh turn under the other mode: the mode is the turn's, taken at its start.
    context =
      notify(context, "turn/completed", %{
        "turn" => %{"id" => native_turn(context), "status" => "completed"}
      })

    await_status(context, context.running, "completed")
    id = World.project(context, "demo").id

    World.update_settings(context, %{
      "projectSettingsOverrides" => %{id => %{"responseStreamingMode" => mode}}
    })

    context = World.running_turn(context, context.thread)
    context = stream_witnessed(context, "reason-u", "item/reasoning/textDelta", "One.\n\nTw")
    assert text(context, "reason-u") == ""

    context = notify(context, "item/completed", item("reasoning", "reason-u"))
    await_text(context, "reason-u", "One.\n\nTw")
    context
  end

  # What each held-back shape streams, and what of it is written before the reply ends.
  @held_back %{
    "a paragraph and half of the next line" => {"One.\n\nTw", "One.\n\n"},
    "a paragraph and an opened code block with blank lines" =>
      {"One.\n\n```\ncode\n\nmore\n", "One.\n\n"},
    "a code block nested in a list item, then its close" =>
      {"- item\n\n  ```\n  code\n  ```\nAfter", "- item\n\n  ```\n  code\n  ```\n"},
    "a first paragraph with no blank line after it yet" => {"One.", ""}
  }

  step ~r/^the provider has streamed (?<so_far>.+)$/, %{args: [so_far]} = context do
    {streamed, _written} = Map.fetch!(@held_back, so_far)
    context = notify(context, "item/started", item("agentMessage", "msg-t"))

    context
    |> stream_witnessed("msg-t", "item/agentMessage/delta", streamed)
    |> Map.put(:held_back, so_far)
  end

  step ~r/^(only the paragraph is written|nothing inside the open code block is written|the text up to and including the close is written|nothing is written)$/,
       context do
    {_streamed, written} = Map.fetch!(@held_back, context.held_back)
    assert text(context, "msg-t") == written
    context
  end

  step "the provider streamed a reply that ends without a blank line", context do
    context = World.running_turn(context, context.thread)
    context = notify(context, "item/started", item("agentMessage", "msg-t"))

    context
    |> stream_witnessed("msg-t", "item/agentMessage/delta", "One.\n\nTwo")
    |> tap(fn context -> assert text(context, "msg-t") == "One.\n\n" end)
  end

  step "the provider finishes the reply", context do
    # No text of its own: what shows is what the finish flushed.
    notify(context, "item/completed", item("agentMessage", "msg-t"))
  end

  step "the whole reply is written at once, whatever was held back", context do
    await_text(context, "msg-t", "One.\n\nTwo")

    appends =
      for %{kind: "turn-item", entity: "turn-item:codex:msg-t", patch: %{"a" => %{"text" => t}}} <-
            World.events(context, context.thread),
          do: t

    assert appends == ["One.\n\n", "Two"]
    context
  end

  # --- a held-back reply cut off by a steer ------------------------------------------

  step "the agent's reply is partly held back", context do
    context = World.running_turn(context, context.thread)
    context = notify(context, "item/started", item("agentMessage", "msg-t"))

    context
    |> stream_witnessed("msg-t", "item/agentMessage/delta", "One.\n\nTw")
    |> tap(fn context -> assert text(context, "msg-t") == "One.\n\n" end)
  end

  step "the user steers the turn before the reply finishes", context do
    context =
      World.dispatch_message(context, context.thread, "Focus on the tests", %{
        "deliveryIntent" => "steer"
      })

    assert {:ok, _} = context.reply

    World.await_state(context, context.thread, fn state ->
      Enum.any?(
        HalC2.StreamState.list(state, "turn-item"),
        &(&1["type"] == "user_message" and &1["text"] == "Focus on the tests")
      )
    end)

    # What followed the steer: the provider's answer to it, under the same turn.
    World.await_state(context, context.thread, fn state ->
      Enum.any?(
        HalC2.StreamState.list(state, "turn-item"),
        &(&1["text"] == "steered: Focus on the tests")
      )
    end)

    context
  end

  step "the turn ends and the held-back reply is written", context do
    await_status(context, context.running, "completed")
    context
  end

  step "the reply appears before the steer and what followed it, where the agent said it",
       context do
    items =
      context
      |> World.entities(context.thread, "turn-item")
      |> Enum.sort_by(& &1["ordinal"])

    held = Enum.find(items, &(&1["id"] == "turn-item:codex:msg-t"))

    steer =
      Enum.find(items, &(&1["type"] == "user_message" and &1["text"] == "Focus on the tests"))

    after_steer = Enum.find(items, &(&1["text"] == "steered: Focus on the tests"))

    assert held["text"] == "One.\n\nTw"
    assert held["ordinal"] < steer["ordinal"]
    assert steer["ordinal"] < after_steer["ordinal"]
    context
  end

  # --- force stop is the user's alone -------------------------------------------------

  step "an agent looks for a way to force stop a thread through HAL-C2's tools", context do
    Map.put(context, :tool_names, Enum.map(HalC2.Mcp.Tools.list(), & &1["name"]))
  end

  step "none is offered", context do
    refute Enum.any?(context.tool_names, &String.contains?(&1, "force"))
    context
  end

  step "a command the agent runs prints output", context do
    context
    |> notify("item/started", item("commandExecution", "cmd-o", %{"command" => "make"}))
    |> notify("item/commandExecution/outputDelta", delta("cmd-o", "building"))
  end

  step "the output is written as it arrives", context do
    await_output(context, "building")
    context = notify(context, "item/commandExecution/outputDelta", delta("cmd-o", " still"))
    item = await_output(context, "building still")
    assert item["status"] == "running"
    context
  end

  # --- ending a run ------------------------------------------------------------------

  step "the provider completes the turn", context do
    # The provider's edit, which the run's checkpoint records.
    File.write!(Path.join(World.project(context, "demo").root, "done.txt"), "done\n")

    notify(context, "turn/completed", %{
      "turn" => %{"id" => native_turn(context), "status" => "completed"}
    })
  end

  step "the run is completed", context do
    await_status(context, context.running, "completed")
    context
  end

  step "a ready checkpoint for the run exists with the files it changed", context do
    run = World.state(context, context.thread).entities["run"][context.running]

    assert %{"status" => "ready", "runId" => run_id, "files" => files} =
             World.state(context, context.thread).entities["checkpoint"][run["checkpointId"]]

    assert run_id == run["id"]
    assert Enum.any?(files, &(&1["path"] == "done.txt"))
    context
  end

  step "the run has a checkpoint turn item", context do
    assert Enum.any?(
             World.entities(context, context.thread, "turn-item"),
             &(&1["type"] == "checkpoint" and &1["runId"] == context.running)
           )

    context
  end

  # Not a command: Codex's commands still running when a turn completes go on in the
  # background (recovery-and-idle-sessions.feature).
  step "{string} has a running turn with a web search still running",
       %{args: [thread]} = context do
    context = World.running_turn(context, thread)

    context =
      notify(
        context,
        "item/started",
        item("webSearch", "search-open", %{"query" => "elixir releases"})
      )

    World.await_state(context, thread, fn state ->
      state.entities["turn-item"]["turn-item:codex:search-open"]["status"] == "running"
    end)

    context
  end

  # Codex's spawnAgent call, still working on its task.
  step "{string} has a running turn with a subagent still running",
       %{args: [thread]} = context do
    context = World.running_turn(context, thread)
    {_, runtime} = World.codex_runtime(context, thread)

    context =
      notify(
        context,
        "item/started",
        item("collabAgentToolCall", "collab-1", %{
          "tool" => "spawnAgent",
          "prompt" => "List the modules in lib",
          "senderThreadId" => runtime.native_thread_id,
          "receiverThreadIds" => ["native-child-1"],
          "status" => "inProgress",
          "agentsStates" => %{"native-child-1" => %{"status" => "running"}}
        })
      )

    World.await_state(context, thread, fn state ->
      match?([%{"status" => "running"}], HalC2.StreamState.list(state, "subagent"))
    end)

    context
  end

  # The same spawn, with work of its own still running in the subagent's thread.
  step "{string} has a running turn with a provider subagent still at work",
       %{args: [thread]} = context do
    context = World.running_turn(context, thread)
    {_, runtime} = World.codex_runtime(context, thread)

    context =
      notify(
        context,
        "item/started",
        item("collabAgentToolCall", "collab-1", %{
          "tool" => "spawnAgent",
          "prompt" => "List the modules in lib",
          "senderThreadId" => runtime.native_thread_id,
          "receiverThreadIds" => ["native-child-1"],
          "status" => "inProgress",
          "agentsStates" => %{"native-child-1" => %{"status" => "running"}}
        })
      )

    state =
      World.await_state(context, thread, fn state ->
        match?([%{"status" => "running"}], HalC2.StreamState.list(state, "subagent"))
      end)

    [subagent] = HalC2.StreamState.list(state, "subagent")

    context =
      World.codex_notify(context, thread, "item/started", %{
        "threadId" => "native-child-1",
        "turnId" => "native-child-turn-1",
        "item" => %{
          "type" => "commandExecution",
          "id" => "cmd-sub",
          "command" => "mix test --listen",
          "status" => "inProgress"
        }
      })

    context =
      context
      |> put_in([:threads, "native-child"], subagent["childThreadId"])
      |> Map.put(:subagent_child, subagent["childThreadId"])

    await_child_item(context, "running")
    context
  end

  step ~r/^the turn is ended as (?<status>interrupted|failed|cancelled)$/,
       %{args: [status]} = context do
    context =
      case status do
        "interrupted" ->
          World.command(context, %{
            "type" => "run.interrupt",
            "threadId" => World.thread_id(context, context.thread),
            "runId" => context.running
          })

        "failed" ->
          notify(context, "turn/completed", %{
            "turn" => %{
              "id" => native_turn(context),
              "status" => "failed",
              "error" => %{"message" => "boom"}
            }
          })

        "cancelled" ->
          World.command(context, %{
            "type" => "thread.delete",
            "threadId" => World.thread_id(context, context.thread)
          })
      end

    await_status(context, context.running, status)
    Map.put(context, :ended_as, status)
  end

  step "the subagent, its item on the turn and the work in its own thread end as {word}",
       %{args: [status]} = context do
    state =
      World.await_state(context, context.thread, fn state ->
        match?(
          [%{"status" => ^status}],
          HalC2.StreamState.list(state, "subagent")
        ) and
          Enum.any?(
            HalC2.StreamState.list(state, "turn-item"),
            &(&1["type"] == "subagent" and &1["status"] == status)
          )
      end)

    assert Enum.any?(
             HalC2.StreamState.list(state, "turn-item"),
             &(&1["type"] == "subagent" and &1["status"] == status)
           )

    await_child_item(context, status)
    context
  end

  step "nothing of the subagent is left streaming", context do
    child = HalC2.Streams.Server.state(HalC2.Streams.ensure(context.subagent_child))

    items =
      Enum.filter(
        World.entities(context, context.thread, "turn-item"),
        &(&1["type"] == "subagent")
      ) ++
        HalC2.StreamState.list(child, "turn-item")

    for item <- items do
      assert item["streaming"] != true, inspect(item["id"])
      assert item["status"] != "running", inspect(item["id"])
    end

    for message <- HalC2.StreamState.list(child, "message"),
        do: assert(message["streaming"] != true, inspect(message["id"]))

    context
  end

  step "no turn item of the run is still running", context do
    await_status(context, context.running, "completed")

    items =
      for i <- World.entities(context, context.thread, "turn-item"),
          i["runId"] == context.running,
          do: i

    assert Enum.any?(items, &(&1["id"] == "turn-item:codex:search-open"))

    assert Enum.all?(items, &(&1["status"] != "running")),
           inspect(Enum.map(items, &{&1["id"], &1["status"]}))

    context
  end

  step "the provider fails the turn with {string}", %{args: [message]} = context do
    notify(context, "turn/completed", %{
      "turn" => %{
        "id" => native_turn(context),
        "status" => "failed",
        "error" => %{"message" => message}
      }
    })
  end

  step "the provider retries a failed request during a turn of {string}",
       %{args: [thread]} = context do
    context = World.running_turn(context, thread)

    for attempt <- 1..2 do
      notify(context, "error", %{
        "error" => %{
          "message" => "Reconnecting... #{attempt}/5",
          "codexErrorInfo" => %{"responseStreamDisconnected" => %{"httpStatusCode" => nil}},
          "additionalDetails" => "stream disconnected before completion"
        },
        "willRetry" => true,
        "turnId" => native_turn(context)
      })
    end

    context
  end

  step "the retry is recorded", context do
    state =
      World.await_state(context, context.thread, fn state ->
        Enum.any?(HalC2.StreamState.list(state, "turn-item"), &(&1["retry"]["attempt"] == 2))
      end)

    Map.put(
      context,
      :retries,
      for(%{"retry" => %{}} = item <- HalC2.StreamState.list(state, "turn-item"), do: item)
    )
  end

  step "the turn's work log shows a provider retry", context do
    # Both attempts are one item of the running run, which the retry did not fail.
    assert [
             %{
               "type" => "error",
               "status" => "running",
               "title" => "Provider retry",
               "runId" => run_id,
               "retry" => %{"attempt" => 2, "maxAttempts" => 5, "retryDelayMs" => nil},
               "failure" => %{
                 "class" => "transport_error",
                 "code" => "responseStreamDisconnected",
                 "message" => "stream disconnected before completion",
                 "retryable" => true
               }
             }
           ] = context.retries

    assert run_id == context.running
    assert [%{"status" => "running"}] = World.runs(context, context.thread)

    # The retry item ends with the turn, which completes.
    notify(context, "turn/completed", %{
      "turn" => %{"id" => native_turn(context), "status" => "completed"}
    })

    state =
      World.await_state(context, context.thread, fn state ->
        Enum.all?(HalC2.StreamState.list(state, "run"), &(&1["status"] == "completed"))
      end)

    assert [%{"status" => "completed"}] =
             for(%{"retry" => %{}} = item <- HalC2.StreamState.list(state, "turn-item"), do: item)

    context
  end

  step "no second user turn is created", context do
    state = World.state(context, context.thread)
    assert [%{"ordinal" => 1}] = HalC2.StreamState.list(state, "run")
    assert [%{"role" => "user"}] = HalC2.StreamState.list(state, "message")
    context
  end

  step "the provider is retrying a failed request during a turn of {string}",
       %{args: [thread]} = context do
    context = World.running_turn(context, thread)

    context =
      notify(context, "error", %{
        "error" => %{
          "message" => "Reconnecting... 1/5",
          "codexErrorInfo" => %{"responseStreamDisconnected" => %{"httpStatusCode" => nil}},
          "additionalDetails" => "stream disconnected before completion"
        },
        "willRetry" => true,
        "turnId" => native_turn(context)
      })

    World.await_state(context, thread, fn state ->
      Enum.any?(HalC2.StreamState.list(state, "turn-item"), &(&1["retry"]["attempt"] == 1))
    end)

    context
  end

  step "the retry succeeds", context do
    notify(context, "turn/completed", %{
      "turn" => %{"id" => native_turn(context), "status" => "completed"}
    })
  end

  step "the provider gives up", context do
    context
    |> notify("error", %{
      "error" => %{"message" => "stream disconnected before completion"},
      "willRetry" => false,
      "turnId" => native_turn(context)
    })
    |> notify("turn/completed", %{
      "turn" => %{
        "id" => native_turn(context),
        "status" => "failed",
        "error" => %{"message" => "stream disconnected before completion"}
      }
    })
  end

  step "the provider gives up on its usage limit", context do
    context
    |> notify("error", %{
      "error" => %{
        "message" => "You've hit your usage limit.",
        "codexErrorInfo" => %{"usageLimitExceeded" => nil}
      },
      "willRetry" => false,
      "turnId" => native_turn(context)
    })
    |> notify("turn/completed", %{
      "turn" => %{"id" => native_turn(context), "status" => "failed"}
    })
  end

  step "the user stops the turn while it is retrying", context do
    World.command(context, %{
      "type" => "run.interrupt",
      "threadId" => World.thread_id(context, context.thread),
      "runId" => context.running
    })
  end

  step "the retry's entry in the turn's work log reads {string}",
       %{args: [title]} = context do
    state =
      World.await_state(context, context.thread, fn state ->
        state.entities["run"][context.running]["status"] not in ~w(starting running)
      end)

    entries =
      for item <- HalC2.StreamState.list(state, "turn-item"),
          String.contains?(item["id"], "terminal-failure:"),
          do: item

    assert [%{"title" => ^title}] = entries
    Map.put(context, :retry_entries, entries)
  end

  step "the turn has only that one entry for the failure", context do
    assert length(context.retry_entries) == 1

    errors =
      for item <- World.entities(context, context.thread, "turn-item"),
          item["type"] == "error",
          do: item

    assert errors == context.retry_entries
    context
  end

  step "the provider session's last error is {string}", %{args: [message]} = context do
    assert session(context, context.thread, "codex")["lastError"] == message
    context
  end

  step "the provider process exits while {string} starts a turn", %{args: [thread]} = context do
    context = World.providers(context)
    fake = Application.get_env(:hal_c2, :codex_command)
    World.put_app_env(:codex_command, ["python3", "-c", "pass"])
    context = context |> Map.put(:thread, thread) |> World.dispatch_message(thread, "Hi")
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    # The fake Codex is back for the next message.
    Application.put_env(:hal_c2, :codex_command, fake)
    context
  end

  step "the provider process exits saying {string} while {string} starts a turn",
       %{args: [said, thread]} = context do
    context = World.providers(context)
    fake = Application.get_env(:hal_c2, :codex_command)
    dies = "import sys; sys.stderr.write(sys.argv[1] + '\\n'); sys.exit(1)"
    World.put_app_env(:codex_command, ["python3", "-c", dies, said])
    context = context |> Map.put(:thread, thread) |> World.dispatch_message(thread, "Hi")
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    Application.put_env(:hal_c2, :codex_command, fake)
    context
  end

  step "the run is failed, and its error ends with {string}", %{args: [ending]} = context do
    ending = String.replace(ending, "\\n", "\n")
    run = World.await_latest_run(context, context.thread, "failed")
    error = session(context, context.thread, "codex")["lastError"]
    assert String.ends_with?(error, ending), "the run failed with #{inspect(error)}"
    Map.put(context, :failed_run, run["id"])
  end

  step "the run is failed with {string}", %{args: [message]} = context do
    run = World.await_latest_run(context, context.thread, "failed")
    assert session(context, context.thread, "codex")["lastError"] == message
    Map.put(context, :failed_run, run["id"])
  end

  step "{string} can take its next message", %{args: [thread]} = context do
    context = World.dispatch_message(context, thread, "Next")
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    assert %{"ordinal" => 2} = World.await_latest_run(context, thread, "completed")
    context
  end

  step "the provider's session cannot be opened while {string} starts a turn",
       %{args: [thread]} = context do
    context = World.providers(context)
    sessions = HalC2.Plugins.sessions("codex")
    :sys.replace_state(sessions, &%{&1 | max_children: 0})
    context = context |> Map.put(:thread, thread) |> World.dispatch_message(thread, "Hi")
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    World.await_latest_run(context, thread, "failed")
    # Sessions open again for the next message.
    :sys.replace_state(sessions, &%{&1 | max_children: :infinity})
    context
  end

  # The delete reaches the thread's stream first, the end of the turn right behind it.
  step "the provider ends the turn while {string} is deleted", %{args: [thread]} = context do
    id = World.thread_id(context, thread)
    [{runtime, _}] = Registry.lookup(HalC2.Codex.Registry, id)
    stream = HalC2.Streams.ensure(id)
    test = self()

    :ok = :sys.suspend(stream)
    :erlang.trace(stream, true, [:receive])
    deleter = spawn(fn -> send(test, {:deleted, delete(id)}) end)
    await_call(stream, deleter)
    :ok = HalC2.Codex.ThreadRuntime.interrupt(id, context.running)
    await_call(stream, runtime)
    :erlang.trace(stream, false, [:receive])
    :ok = :sys.resume(stream)

    assert_receive {:deleted, {:ok, _}}, 5_000
    context
  end

  # The delete lands while the runtime waits to claim the run its turn started.
  step "{string} is deleted while its turn starts", %{args: [thread]} = context do
    context = World.providers(context)
    id = World.thread_id(context, thread)
    watch = suspend_watch()
    test = self()
    spawn(fn -> send(test, {:sent, HalC2.Orchestration.dispatch(start(id))}) end)
    await_claim(watch)

    spawn(fn -> send(test, {:deleted, delete(id)}) end)
    World.await_runs(context, thread, ["cancelled"])
    :ok = :sys.resume(watch)

    assert_receive {:deleted, {:ok, _}}, 5_000
    assert_receive {:sent, {:ok, _}}, 5_000
    Map.put(context, :thread, thread)
  end

  step "the run of {string} stays cancelled", %{args: [thread]} = context do
    World.await_runs(context, thread, ["cancelled"])
    context
  end

  # The first message's runtime waits to claim its run while the start gives up on it,
  # as begin_turn/2 does when its call to the runtime times out.
  step "the start of a turn in {string} gave up while a second message waits",
       %{args: [thread]} = context do
    context = World.providers(context)
    id = World.thread_id(context, thread)
    watch = suspend_watch()
    test = self()
    spawn(fn -> send(test, {:sent, HalC2.Orchestration.dispatch(start(id))}) end)
    runtime = await_claim(watch)
    assert {:ok, _} = HalC2.Orchestration.dispatch(start(id))
    state = World.await_runs(context, thread, ["starting", "queued"])
    [first, _] = state |> HalC2.StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])

    :erlang.trace(runtime, true, [:receive])
    failure = HalC2.Orchestration.TurnWriter.start_failure(nil, :closed)
    HalC2.Orchestration.TurnWriter.abandon(id, first["id"], "failed", failure)
    assert_receive {:trace, ^runtime, :receive, {:"$gen_call", _, {:start_turn, _}}}, 5_000
    :erlang.trace(runtime, false, [:receive])
    Map.merge(context, %{thread: thread, runtime: runtime, watch: watch})
  end

  step "the provider starts the first turn anyway", context do
    :ok = :sys.resume(context.watch)
    context
  end

  step "the first run of {string} stays failed and the second runs alone",
       %{args: [thread]} = context do
    World.await_runs(context, thread, ["failed", "running"])
    # The first turn's end, which Codex sends as the runtime lets go of it, is not the second's.
    :ok = GenServer.call(context.runtime, :settle)
    World.await_runs(context, thread, ["failed", "running"])
    context
  end

  step "{string} has a running turn and a queued message {string}",
       %{args: [thread, text]} = context do
    context
    |> World.running_turn(thread)
    |> World.queue_message(thread, text)
    |> World.queue_message(thread, "After that")
  end

  step "the remaining queued messages move up one place", context do
    [_, rest] = context.queued
    # A queued run that is still waiting moved from place 2 to place 1.
    events = World.events(context, context.thread)

    assert Enum.any?(
             events,
             &match?(%{kind: "run", entity: ^rest, patch: %{"s" => %{"queuePosition" => 2}}}, &1)
           )

    World.await_state(context, context.thread, fn state ->
      match?(%{"status" => "queued", "queuePosition" => 1}, state.entities["run"][rest]) or
        state.entities["run"][rest]["status"] != "queued"
    end)

    assert Enum.any?(
             World.events(context, context.thread),
             &(&1.kind == "run" and &1.entity == rest and
                 match?(%{"queuePosition" => 1}, &1.patch["s"] || &1.patch["m"] || %{}))
           )

    context
  end

  step "the user interrupts the run", context do
    World.command(context, %{
      "type" => "run.interrupt",
      "threadId" => World.thread_id(context, context.thread),
      "runId" => context.running
    })
  end

  step "{string} has a running turn after a run that ended", %{args: [thread]} = context do
    context = completed_run(context, thread, "Hi")
    context |> World.running_turn(thread) |> Map.put(:ended, context.run)
  end

  # A client that read the ended run as active, or a cleanup holding its run's id,
  # asks for that run after a newer turn took the session.
  step "the user interrupts the run that ended", context do
    World.command(context, %{
      "type" => "run.interrupt",
      "threadId" => World.thread_id(context, context.thread),
      "runId" => context.ended
    })
  end

  step "the running turn is still running", context do
    run =
      World.entities(context, context.thread, "run") |> Enum.find(&(&1["id"] == context.running))

    assert run["status"] == "running"
    context
  end

  step "the user interrupts the run of idle thread {string}", %{args: [thread]} = context do
    context
    |> World.providers()
    |> World.command(%{"type" => "run.interrupt", "threadId" => World.thread_id(context, thread)})
  end

  # --- stopping the session ----------------------------------------------------------

  step "{string} is idle with a provider session", %{args: [thread]} = context do
    context = completed_run(context, thread, "Hi")
    assert %{"status" => "ready"} = session(context, thread, "codex")
    assert [{pid, _}] = Registry.lookup(HalC2.Codex.Registry, World.thread_id(context, thread))
    Map.put(context, :runtime, {pid, Process.monitor(pid)})
  end

  step "the user stops the session of {string}", %{args: [thread]} = context do
    stop_session(context, thread)
  end

  step "the provider session is removed from {string}", %{args: [thread]} = context do
    assert {:ok, _} = context.reply
    assert World.entities(context, thread, "provider-session") == []
    context
  end

  step "the provider process for {string} stops", %{args: [thread]} = context do
    {pid, ref} = context.runtime
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    assert Registry.lookup(HalC2.Codex.Registry, World.thread_id(context, thread)) == []
    context
  end

  step "the user stopped the session of {string}", %{args: [thread]} = context do
    context |> completed_run(thread, "Hi") |> stop_session(thread) |> stopped()
  end

  step "a provider session is opened again and resumes the provider thread", context do
    World.await_latest_run(context, context.thread, "completed")
    assert %{"status" => "ready"} = session(context, context.thread, "codex")
    assert [%{"threadId" => "native-thread-1"}] = World.codex_requests(context, "thread/resume")
    context
  end

  # --- feedback ----------------------------------------------------------------------

  step "{string} has run a Codex turn", %{args: [thread]} = context do
    completed_run(context, thread, "Hi")
  end

  step "{string} has run a Claude turn", %{args: [thread]} = context do
    context = World.providers(context) |> Map.put(:thread, thread)

    context =
      World.dispatch_message(context, thread, "Hi", %{
        "modelSelection" => %{"instanceId" => "claudeAgent", "model" => "claude-haiku"}
      })

    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    World.await_latest_run(context, thread, "completed")
    context
  end

  step "the user uploads feedback for {string}", %{args: [thread]} = context do
    feedback(context, World.thread_id(context, thread))
  end

  step "the user uploads feedback for a thread with no runs", context do
    assert World.entities(context, "t1", "run") == []
    feedback(context, World.thread_id(context, "t1"))
  end

  step "the feedback is sent to Codex", context do
    assert {:ok, %{"feedbackId" => "feedback-for-native-thread-1"}} = context.reply

    assert [%{"threadId" => "native-thread-1", "reason" => "It went wrong"}] =
             World.codex_requests(context, "feedback/upload")

    context
  end

  # --- a removed worktree -------------------------------------------------------------

  # A real worktree of the project on its own branch, whose folder is then deleted the
  # way the storage sweep (or the user) removes one: git still lists it.
  step "{string} is in worktree {string} and that folder no longer exists",
       %{args: [thread, _path]} = context do
    Mc.ensure(
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Vcs.Registry},
        id: HalC2.Vcs.Registry
      )
    )

    root = World.project(context, "demo").root
    branch = "hal-c2/#{thread}"

    {:ok, %{"worktree" => %{"path" => path}}} =
      HalC2.Vcs.create_worktree(%{"cwd" => root, "refName" => "main", "newRefName" => branch})

    context = World.patch_thread(context, thread, %{"worktreePath" => path, "branch" => branch})
    File.rm_rf!(path)
    refute File.exists?(path)
    Map.put(context, :removed_worktree, %{path: path, branch: branch, root: root})
  end

  step "the worktree is recreated from the branch of {string}", %{args: [thread]} = context do
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    %{path: path, branch: branch} = context.removed_worktree
    assert File.dir?(path)
    assert World.git!(path, ~w(rev-parse --abbrev-ref HEAD)) == branch
    assert File.exists?(Path.join(path, "README.md"))
    assert %{"worktreePath" => ^path, "branch" => ^branch} = World.thread(context, thread)
    context
  end

  step "only then does the turn start", context do
    %{path: path, root: root} = context.removed_worktree
    World.await_latest_run(context, context.thread, "completed")
    # The provider was started in the recreated folder, and the baseline the engine
    # takes before starting a turn was captured from it.
    assert [%{"cwd" => ^path}] = turn_starts(context)
    ref = HalC2.Checkpoint.ref(HalC2.Checkpoint.scope_id(World.thread_id(context, "t1")), 0)
    assert World.git!(root, ["rev-parse", "--verify", "--quiet", ref]) != ""
    context
  end

  # --- a plugin's own retries ----------------------------------------------------------

  # A provider plugin that tries to open its session twice before giving up. Each
  # attempt tells the scenario and waits for it, so the run can be read in between.
  @flaky_plugin """
  defmodule HalC2PluginFixture.Flaky do
    @behaviour HalC2.Plugins.ProviderAdapter
    alias HalC2.Orchestration.TurnWriter

    @attempts 2

    def manifest do
      %{
        id: "flaky",
        name: "Flaky",
        version: "1.0.0",
        api_version: 1,
        settings: [],
        provider: %{
          driver: "flaky",
          name: "Flaky",
          capabilities: [],
          models: [%{slug: "flaky-1", name: "Flaky One"}]
        }
      }
    end

    def start_turn(thread_id, turn) do
      {:ok, _} =
        DynamicSupervisor.start_child(HalC2.Plugins.sessions("flaky"), %{
          id: :turn,
          start: {Task, :start_link, [fn -> run(thread_id, turn) end]},
          restart: :temporary
        })

      :ok
    end

    defp run(thread_id, turn) do
      state = %{thread_id: thread_id, turn: turn, items: %{}, buffer: %{}, flush_timer: nil}

      for attempt <- 1..@attempts do
        send(Process.whereis(:hal_c2_plugin_probe), {:opening_session, attempt, self()})

        receive do
          :refused -> :ok
        end
      end

      TurnWriter.finish(
        state,
        "failed",
        "Flaky could not open its session after \#{@attempts} attempts."
      )
    end
  end
  """

  step "a provider whose plugin retries opening its session", context do
    Fixtures.probe()

    context
    |> World.providers()
    |> Fixtures.install("flaky", @flaky_plugin)
    |> Fixtures.enable("flaky")
    |> World.patch_thread("t1", %{
      "modelSelection" => %{"instanceId" => "flaky", "model" => "flaky-1"},
      "providerInstanceId" => "flaky"
    })
  end

  # Every attempt the plugin makes is refused, as the scenario hears of it.
  step "opening the session fails the first time", context do
    assert Fixtures.entry("flaky")["status"] == "running"
    context
  end

  step "the plugin opens the session again", context do
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    assert_receive {:opening_session, 1, plugin}, 5_000
    # The first failure is the plugin's to handle: the run is still starting.
    assert %{"status" => "starting"} = World.latest_run(context, context.thread)
    send(plugin, :refused)
    assert_receive {:opening_session, 2, ^plugin}, 5_000
    Map.put(context, :plugin_turn, plugin)
  end

  step "the run fails only once the plugin gives up", context do
    # Still the one run, neither failed nor started again by the engine.
    assert [%{"status" => "starting", "ordinal" => 1}] = World.runs(context, context.thread)
    send(context.plugin_turn, :refused)
    run = World.await_latest_run(context, context.thread, "failed")
    assert [%{"id" => id}] = World.runs(context, context.thread)
    assert id == run["id"]
    refute_received {:opening_session, _, _}

    assert session(context, context.thread, "flaky")["lastError"] ==
             "Flaky could not open its session after 2 attempts."

    context
  end

  # --- a failed turn's output ----------------------------------------------------------

  step "the provider streamed part of its answer to {string} and then failed",
       %{args: [thread]} = context do
    context = World.running_turn(context, thread)

    context
    |> notify("item/started", item("agentMessage", "msg-partial"))
    |> notify("item/agentMessage/delta", delta("msg-partial", "Half an ans"))
    |> notify("turn/completed", %{
      "turn" => %{
        "id" => native_turn(context),
        "status" => "failed",
        "error" => %{"message" => "The model stopped responding."}
      }
    })
  end

  step "the failure is recorded", context do
    await_status(context, context.running, "failed")
    context
  end

  step "the partial answer stays in the failed run", context do
    state = World.state(context, context.thread)
    run = context.running

    assert %{"text" => "Half an ans", "streaming" => false, "runId" => ^run, "status" => status} =
             state.entities["turn-item"]["turn-item:codex:msg-partial"]

    assert status != "running"

    assert %{
             "text" => "Half an ans",
             "streaming" => false,
             "role" => "assistant",
             "runId" => ^run
           } =
             state.entities["message"]["message:codex:msg-partial"]

    # A client's transcript still shows it.
    {items, context} = World.timeline(context, context.thread)
    assert Enum.any?(items, &(&1["id"] == "turn-item:codex:msg-partial"))
    context
  end

  step "the run is marked failed", context do
    assert %{"status" => "failed", "completedAt" => at} =
             World.state(context, context.thread).entities["run"][context.running]

    assert is_binary(at)

    assert session(context, context.thread, "codex")["lastError"] ==
             "The model stopped responding."

    context
  end

  # --- a workspace that is gone ---------------------------------------------------------

  step "the workspace of {string} is not a worktree and its folder is gone",
       %{args: [thread]} = context do
    context = World.providers(context)
    root = World.project(context, "demo").root
    File.rm_rf!(root)
    refute File.exists?(root)
    Map.put(context, :thread, thread)
  end

  step "the run fails", context do
    World.await_latest_run(context, context.thread, "failed")
    context
  end

  step "no provider process is started for it", context do
    # The app-server never answered a request, and no connection to one is left.
    assert World.codex_requests(context, "initialize") == []
    assert World.codex_requests(context, "turn/start") == []

    for {pid, _} <-
          Registry.lookup(HalC2.Codex.Registry, World.thread_id(context, context.thread)),
        do: assert(:sys.get_state(pid).conn == nil)

    context
  end

  # --- an interrupt's record --------------------------------------------------------------

  step "the user interrupts the run giving the reason {string}",
       %{args: [reason]} = context do
    World.command(context, %{
      "type" => "run.interrupt",
      "threadId" => World.thread_id(context, context.thread),
      "runId" => context.running,
      "reason" => reason
    })
  end

  step "the user interrupts the run without a reason", context do
    World.command(context, %{
      "type" => "run.interrupt",
      "threadId" => World.thread_id(context, context.thread),
      "runId" => context.running
    })
  end

  step "the user presses Stop", context do
    World.command(context, %{
      "type" => "run.interrupt",
      "threadId" => World.thread_id(context, context.thread),
      "runId" => context.running,
      "stopDelegated" => true
    })
  end

  step "an agent stops it through HAL-C2's tools", context do
    agent_interrupt(context, %{})
  end

  step "an agent stops it through HAL-C2's tools with {string}",
       %{args: [reason]} = context do
    agent_interrupt(context, %{"reason" => reason})
  end

  # The run whose outcome is read is the delegated child's, cancelled by the
  # agent of "t1" (whose own turn is the scenario's running turn).
  step "an agent cancels its delegated task", context do
    assert {:ok, %{"taskId" => task_id}} =
             World.mcp_tool(context, context.thread, "delegate_task", %{
               "task" => "wait for it",
               "mode" => "async"
             })

    state =
      World.await_state(context, context.thread, fn state ->
        Enum.any?(HalC2.StreamState.list(state, "subagent"), &(&1["id"] == task_id))
      end)

    task = Enum.find(HalC2.StreamState.list(state, "subagent"), &(&1["id"] == task_id))

    context = put_in(context, [:threads, "delegated-child"], task["childThreadId"])

    child =
      World.await_state(context, "delegated-child", fn state ->
        Enum.any?(HalC2.StreamState.list(state, "run"), &(&1["status"] == "running"))
      end)

    run = Enum.find(HalC2.StreamState.list(child, "run"), &(&1["status"] == "running"))

    assert {:ok, %{"status" => "cancelled"}} =
             World.mcp_tool(context, context.thread, "task_cancel", %{"taskId" => task_id})

    context |> Map.put(:thread, "delegated-child") |> Map.put(:running, run["id"])
  end

  step "the provider ends the run with no stop asked for", context do
    notify(context, "turn/completed", %{
      "turn" => %{"id" => native_turn(context), "status" => "interrupted"}
    })
  end

  step "the run records an item titled {string} saying {string}",
       %{args: [title, message]} = context do
    assert {:ok, _} = context.reply
    assert interrupt_item(context, title, message)
    context
  end

  step "once the provider stops, an item titled {string} saying {string}",
       %{args: [title, message]} = context do
    await_interrupt_item(context, title, message)
  end

  step "once the provider stops, an item titled {string} says {string}",
       %{args: [title, message]} = context do
    await_interrupt_item(context, title, message)
  end

  # --- stopping a run nothing drives ------------------------------------------------------

  # The runtime stops without ending the turn, as one does when its provider vanishes
  # (a `:shutdown` is not a crash, which the run would be failed for).
  step "a run is still active because its provider vanished before reporting an end", context do
    context = World.providers(context) |> Map.put(:thread, "t1")
    context = World.dispatch_message(context, "t1", "approve the command")
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    World.await_request(context, "t1")
    run = World.latest_run(context, "t1")
    File.write!(Path.join(World.project(context, "demo").root, "partial.txt"), "half\n")

    {runtime, _} = World.codex_runtime(context, "t1")
    :ok = GenServer.stop(runtime, :shutdown)

    assert World.latest_run(context, "t1")["status"] in ~w(running waiting)
    Map.merge(context, %{running: run["id"], run: run["id"]}) |> Map.delete(:reply)
  end

  step "the user stops the thread", context do
    World.command(context, %{
      "type" => "run.interrupt",
      "threadId" => World.thread_id(context, context.thread)
    })
  end

  step "the run is settled as stopped with its partial output kept", context do
    assert {:ok, _} = context.reply, "stop failed: #{inspect(context.reply)}"
    state = await_status(context, context.running, "interrupted")

    items =
      for i <- HalC2.StreamState.list(state, "turn-item"), i["runId"] == context.running, do: i

    assert Enum.any?(items, &(&1["id"] == "turn-item:codex:cmd-1"))
    assert Enum.all?(items, &(&1["status"] != "running"))
    context
  end

  step "its pending requests are closed and its checkpoint is captured", context do
    state = World.state(context, context.thread)

    refute Enum.any?(
             HalC2.StreamState.list(state, "runtime-request"),
             &(&1["status"] in ~w(pending open))
           )

    run = state.entities["run"][context.running]

    assert %{"status" => "ready", "files" => files} =
             state.entities["checkpoint"][run["checkpointId"]]

    assert Enum.any?(files, &(&1["path"] == "partial.txt"))
    context
  end

  step "a late result from the provider cannot undo the stop or replace a newer attempt",
       context do
    id = World.thread_id(context, context.thread)
    :ok = HalC2.Orchestration.TurnWriter.abandon(id, context.running, "failed", "late")
    :ok = HalC2.Orchestration.TurnWriter.abandon(id, context.running, "completed", nil)

    assert %{"status" => "interrupted"} =
             World.state(context, context.thread).entities["run"][context.running]

    context
  end

  # --- stopping during a slow start --------------------------------------------------------

  # The runtime has its provider turn started and waits to claim the run, as it does
  # while a slow provider takes its time.
  step "a provider session is still starting", context do
    context = World.providers(context)
    id = World.thread_id(context, "t1")
    watch = suspend_watch()
    test = self()
    spawn(fn -> send(test, {:sent, HalC2.Orchestration.dispatch(start(id))}) end)
    runtime = await_claim(watch)
    Map.merge(context, %{thread: "t1", watch: watch, runtime: runtime})
  end

  step "the user stops the thread before the start completes", context do
    context =
      World.command(context, %{
        "type" => "run.interrupt",
        "threadId" => World.thread_id(context, context.thread)
      })

    :ok = :sys.resume(context.watch)
    assert_receive {:sent, {:ok, _}}, 5_000
    context
  end

  step "the half-started provider session is cleaned up", context do
    assert {:ok, _} = context.reply, "stop failed: #{inspect(context.reply)}"
    World.await_runs(context, context.thread, ["interrupted"])
    # The runtime let go of the turn its provider started, and told the provider so.
    :ok = GenServer.call(context.runtime, :settle)
    assert :sys.get_state(context.runtime).turn == nil
    assert [%{"turnId" => _}] = World.codex_requests(context, "turn/interrupt")
    World.await_runs(context, context.thread, ["interrupted"])
    context
  end

  # --- what a failure says -----------------------------------------------------------

  # What each provider message is, and what the thread records of it.
  @secrets %{
    "a URL with a user name, password and query" =>
      {"request to https://bob:hunter2@example.com/v1/chat?key=abc123 failed",
       "request to https://example.com/v1/chat failed"},
    "a bearer or basic authorization value" =>
      {"rejected Authorization: Bearer abc123def and Basic dXNlcjpwYXNz",
       "rejected Authorization: Bearer [REDACTED] and Basic [REDACTED]"},
    "an API key, token, password or secret" =>
      {"bad api_key=sk-12345 token: t0k3n password=hunter2 secret=s3cr3t",
       "bad api_key=[REDACTED] token: [REDACTED] password=[REDACTED] secret=[REDACTED]"},
    "a prefixed key, client secret or refresh token" =>
      {~s(bad OPENAI_API_KEY=sk-abc client_secret=c5 body {"refresh_token":"r7"}),
       ~s(bad OPENAI_API_KEY=[REDACTED] client_secret=[REDACTED] body {"refresh_token":"[REDACTED]"})},
    "a URL that cannot be read" =>
      {"could not reach http://[::1 broken", "could not reach [REDACTED_URL] broken"},
    # The compound-key outline names its provider text and what is shown outright.
    "client_secret=abc refresh_token=def" =>
      {"client_secret=abc refresh_token=def", "client_secret=[REDACTED] refresh_token=[REDACTED]"},
    ~s({"client_secret":"abc"}) =>
      {~s({"client_secret":"abc"}), ~s({"client_secret":"[REDACTED]"})},
    "clientSecret: abc" => {"clientSecret: abc", "clientSecret: [REDACTED]"},
    "max_tokens=4096 input_tokens: 12" =>
      {"max_tokens=4096 input_tokens: 12", "max_tokens=4096 input_tokens: 12"}
  }

  step ~r/^the provider fails a turn of "(?<thread>[^"]+)" with a message holding (?<secret>.+)$/,
       %{args: [thread, secret]} = context do
    {message, _} = Map.fetch!(@secrets, secret)
    context = World.running_turn(context, thread)

    context =
      notify(context, "turn/completed", %{
        "turn" => %{
          "id" => native_turn(context),
          "status" => "failed",
          "error" => %{"message" => message}
        }
      })

    await_status(context, context.running, "failed")
    Map.put(context, :secret, secret)
  end

  step ~r/^the failure the thread records shows (?<shown>.+)$/, %{args: [_shown]} = context do
    {message, expected} = Map.fetch!(@secrets, context.secret)
    recorded = session(context, context.thread, "codex")["lastError"]
    assert recorded == expected
    # A message with nothing to hide (token counts) is recorded as it came.
    if expected != message, do: refute(recorded == message)

    for %{"failure" => %{"message" => text}} <-
          World.entities(context, context.thread, "turn-item"),
        do: assert(text == expected)

    context
  end

  step "the provider fails a turn of {string} with a message longer than 4,096 characters",
       %{args: [thread]} = context do
    context = World.running_turn(context, thread)

    context =
      notify(context, "turn/completed", %{
        "turn" => %{
          "id" => native_turn(context),
          "status" => "failed",
          "error" => %{"message" => String.duplicate("long ", 1_000)}
        }
      })

    await_status(context, context.running, "failed")
    context
  end

  step "the failure the thread records is at most 4,096 characters and ends with {string}",
       %{args: [ending]} = context do
    recorded = session(context, context.thread, "codex")["lastError"]
    assert String.length(recorded) == 4_096
    assert String.ends_with?(recorded, ending)
    context
  end

  # --- a stream that ends without ending its turn --------------------------------------

  step "the provider's event stream ends without saying the turn ended", context do
    kill_app_server(context)
  end

  step "the run and its subagents are failed", context do
    await_status(context, context.running, "failed")

    World.await_state(context, context.thread, fn state ->
      match?(
        [%{"status" => "failed", "runId" => run}] when run == context.running,
        HalC2.StreamState.list(state, "subagent")
      )
    end)

    context
  end

  # The same end, with the MC itself going down: the runtime sees its connection end
  # (traced, so the scenario knows it did) and leaves the run as it was.
  step "a stream the MC ends because it is shutting down leaves the run for recovery",
       context do
    context = World.running_turn(context, context.thread)
    {runtime, state} = World.codex_runtime(context, context.thread)

    HalC2.Orchestration.Recovery.leaving(true)
    ExUnit.Callbacks.on_exit(fn -> HalC2.Orchestration.Recovery.leaving(false) end)
    :erlang.trace(runtime, true, [:receive])
    kill_app_server(context)
    conn = state.conn
    assert_receive {:trace, ^runtime, :receive, {:EXIT, ^conn, _}}, 5_000
    :erlang.trace(runtime, false, [:receive])
    :ok = GenServer.call(runtime, :settle)

    assert %{"status" => "running"} =
             World.state(context, context.thread).entities["run"][context.running]

    context
  end

  # --- helpers -----------------------------------------------------------------------

  defp run(context), do: World.state(context, context.thread).entities["run"][context.run]

  defp created(context, thread, kind, id) do
    Enum.find_value(World.events(context, thread), fn
      %{kind: ^kind, entity: ^id, patch: patch} -> patch
      _ -> nil
    end)
  end

  defp created_seq(context, thread, kind, id) do
    Enum.find_value(World.events(context, thread), fn
      %{kind: ^kind, entity: ^id, seq: seq} -> seq
      _ -> nil
    end)
  end

  defp completed_run(context, thread, text) do
    context = context |> World.providers() |> Map.put(:thread, thread)
    context = World.dispatch_message(context, thread, text)
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    run = World.await_latest_run(context, thread, "completed")
    context |> Map.delete(:reply) |> Map.put(:run, run["id"])
  end

  defp session(context, thread, driver) do
    World.state(context, thread).entities["provider-session"][
      "provider-session:#{driver}:#{World.thread_id(context, thread)}"
    ] || flunk("#{thread} has no #{driver} provider session")
  end

  defp session_in(state, context, thread),
    do:
      state.entities["provider-session"][
        "provider-session:codex:#{World.thread_id(context, thread)}"
      ] || %{}

  defp stop_session(context, thread) do
    id = World.thread_id(context, thread)

    context
    |> Map.put(:thread, thread)
    |> World.command(%{
      "type" => "provider-session.detach",
      "threadId" => id,
      "providerSessionId" => "provider-session:codex:#{id}"
    })
  end

  defp stopped(context) do
    assert {:ok, _} = context.reply, "provider-session.detach failed: #{inspect(context.reply)}"
    assert World.entities(context, context.thread, "provider-session") == []
    Map.delete(context, :reply)
  end

  defp feedback(context, thread_id) do
    {reply, context} =
      World.call(context, "provider.uploadFeedback", %{
        "threadId" => thread_id,
        "reason" => "It went wrong"
      })

    # The error's cause is the message a client shows.
    reply =
      case reply do
        {:error, _tag, %{"cause" => cause} = detail} -> {:error, cause, detail}
        reply -> reply
      end

    Map.put(context, :reply, reply)
  end

  defp await_interrupt_item(context, title, message) do
    World.await_state(context, context.thread, fn state ->
      Enum.any?(
        HalC2.StreamState.list(state, "turn-item"),
        &(&1["runId"] == context.running and &1["title"] == title and &1["message"] == message)
      )
    end)

    context
  end

  defp interrupt_item(context, title, message) do
    Enum.find(
      World.entities(context, context.thread, "turn-item"),
      &(&1["runId"] == context.running and &1["title"] == title and &1["message"] == message)
    )
  end

  defp kill_app_server(context) do
    {_, runtime} = World.codex_runtime(context, context.thread)
    os_pid = HalC2.Subprocess.os_pid(:sys.get_state(runtime.conn).sub)
    {_, 0} = System.cmd("kill", ["-9", Integer.to_string(os_pid)])
    context
  end

  defp turn_starts(context), do: World.codex_requests(context, "turn/start")

  defp turn_cwd(context) do
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    World.await_latest_run(context, context.thread, "completed")
    assert [%{"cwd" => cwd}] = turn_starts(context)
    cwd
  end

  defp native_turn(context),
    do: elem(World.codex_runtime(context, context.thread), 1).turn.native_turn_id

  # `hal_c2_thread_interrupt` from another thread of the project, as an agent's
  # own stop arrives. The caller needs a run of its own, as a calling agent has.
  defp agent_interrupt(context, extra) do
    target = context.thread
    running = context.running
    context = World.running_turn(context, "agent-caller")

    arguments = Map.merge(%{"threadId" => World.thread_id(context, target)}, extra)

    assert {:ok, %{"interrupted" => true}} =
             World.mcp_tool(context, "agent-caller", "hal_c2_thread_interrupt", arguments)

    context |> Map.put(:thread, target) |> Map.put(:running, running)
  end

  # The subagent's own command item, in its child thread ("native-child").
  defp await_child_item(context, status) do
    World.await_state(context, "native-child", fn state ->
      Enum.any?(
        HalC2.StreamState.list(state, "turn-item"),
        &(&1["status"] == status and String.ends_with?(&1["id"], "cmd-sub"))
      )
    end)
  end

  defp notify(context, method, params),
    do: World.codex_notify(context, context.thread, method, params)

  defp item(type, id, fields \\ %{}),
    do: %{"item" => Map.merge(%{"type" => type, "id" => id}, fields)}

  defp delta(id, text), do: %{"itemId" => id, "delta" => text}

  defp report(context, "assistant text") do
    context
    |> notify("item/started", item("agentMessage", "msg-r"))
    |> notify("item/agentMessage/delta", delta("msg-r", "Done."))
  end

  defp report(context, "reasoning"),
    do: notify(context, "item/reasoning/textDelta", delta("reason-r", "Thinking"))

  defp report(context, "a command it ran"),
    do: notify(context, "item/started", item("commandExecution", "cmd-r", %{"command" => "ls"}))

  defp report(context, "a file it changed") do
    notify(
      context,
      "item/completed",
      item("fileChange", "file-r", %{
        "status" => "completed",
        "changes" => [%{"path" => "a.txt", "diff" => "+a\n", "kind" => %{"type" => "add"}}]
      })
    )
  end

  defp report(context, "a web search"),
    do:
      notify(
        context,
        "item/started",
        item("webSearch", "web-r", %{
          "query" => "elixir",
          "action" => %{"type" => "search", "query" => "elixir"}
        })
      )

  defp report(context, "a dynamic tool call"),
    do:
      notify(
        context,
        "item/started",
        item("dynamicToolCall", "tool-r", %{"tool" => "lookup", "arguments" => %{"q" => 1}})
      )

  defp report(context, "a proposed plan"),
    do: notify(context, "item/started", item("plan", "plan-r", %{"text" => ""}))

  defp report(context, "a to-do list"),
    do:
      notify(context, "turn/plan/updated", %{
        "turnId" => native_turn(context),
        "plan" => [%{"step" => "Read", "status" => "inProgress"}]
      })

  # Streams `text` for `native` by `method`, then a command's output: both flush
  # together, so the output landing shows the prose write has had its chance.
  defp stream_witnessed(context, native, method, text) do
    cmd = "cmd-w#{System.unique_integer([:positive])}"

    context
    |> notify(method, delta(native, text))
    |> notify("item/started", item("commandExecution", cmd, %{"command" => "ls"}))
    |> notify("item/commandExecution/outputDelta", delta(cmd, "a.txt\n"))
    |> tap(fn context ->
      World.await_state(context, context.thread, fn state ->
        state.entities["turn-item"]["turn-item:codex:#{cmd}"]["outputSize"] == 6
      end)
    end)
  end

  # A paragraph and a half of assistant text, then a command's output: both are
  # flushed together, so the output being written shows what the text write held back.
  defp stream_text(context) do
    context
    |> notify("item/started", item("agentMessage", "msg-t"))
    |> notify("item/agentMessage/delta", delta("msg-t", "One.\n\nTw"))
    |> notify("item/started", item("commandExecution", "cmd-t", %{"command" => "ls"}))
    |> notify("item/commandExecution/outputDelta", delta("cmd-t", "a.txt\n"))
    |> tap(fn context ->
      World.await_state(context, context.thread, fn state ->
        state.entities["turn-item"]["turn-item:codex:cmd-t"]["outputSize"] == 6
      end)
    end)
  end

  defp finish_text(context) do
    text = "One.\n\nTwo.\n\nThree."
    context = notify(context, "item/completed", item("agentMessage", "msg-t", %{"text" => text}))

    World.await_state(context, context.thread, fn state ->
      state.entities["turn-item"]["turn-item:codex:msg-t"]["text"] == text
    end)

    context
  end

  defp text(context, native),
    do:
      World.state(context, context.thread).entities["turn-item"]["turn-item:codex:#{native}"][
        "text"
      ]

  defp await_text(context, native, text) do
    World.await_state(context, context.thread, fn state ->
      state.entities["turn-item"]["turn-item:codex:#{native}"]["text"] == text
    end)
  end

  # Output stays off the thread's stream: the item carries its size, the text is the
  # running command's tail.
  defp await_output(context, output) do
    state =
      World.await_state(context, context.thread, fn state ->
        state.entities["turn-item"]["turn-item:codex:cmd-o"]["outputSize"] == byte_size(output)
      end)

    assert HalC2.Orchestration.CommandTail.get(
             World.thread_id(context, context.thread),
             "turn-item:codex:cmd-o"
           ) == output

    state.entities["turn-item"]["turn-item:codex:cmd-o"]
  end

  defp await_status(context, run_id, status) do
    World.await_state(context, context.thread, &(&1.entities["run"][run_id]["status"] == status))
  end

  defp start(id),
    do: %{
      "type" => "message.dispatch",
      "threadId" => id,
      "messageId" => "msg-#{System.unique_integer([:positive])}",
      "text" => "wait",
      "attachments" => [],
      "dispatchMode" => %{"type" => "queue_after_active"}
    }

  defp delete(id),
    do: HalC2.Orchestration.dispatch(%{"type" => "thread.delete", "threadId" => id})

  defp await_call(stream, from),
    do: assert_receive({:trace, ^stream, :receive, {:"$gen_call", {^from, _}, _}}, 5_000)

  defp suspend_watch do
    watch = Process.whereis(HalC2.Orchestration.TurnWatch)
    :ok = :sys.suspend(watch)
    :erlang.trace(watch, true, [:receive])
    watch
  end

  # The runtime claiming a run from the suspended TurnWatch, once the turn started.
  defp await_claim(watch) do
    assert_receive {:trace, ^watch, :receive, {:"$gen_call", {runtime, _}, {:claim, _, _, _}}},
                   5_000

    :erlang.trace(watch, false, [:receive])
    runtime
  end
end
