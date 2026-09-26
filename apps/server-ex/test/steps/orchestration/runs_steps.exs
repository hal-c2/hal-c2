defmodule T3.Steps.Orchestration.Runs do
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.Test.Node
  alias T3.Test.Node.World

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

  step "the node has no provider instance {string}", %{args: [instance]} = context do
    refute Map.has_key?(T3.Settings.settings()["providerInstances"] || %{}, instance)
    refute T3.Acp.agent?(instance)
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
    assert Registry.lookup(T3.Codex.Registry, World.thread_id(context, context.thread)) == []
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
    context = World.send_message(context, thread, "Again")
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
    World.await_run(context, context.thread, "completed")
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
    |> World.send_message(thread, text, %{
      "modelSelection" => %{"instanceId" => "codex", "model" => model}
    })
  end

  step "the run records model {string}", %{args: [model]} = context do
    assert {:ok, _} = context.reply
    assert World.latest_run(context, context.thread)["modelSelection"]["model"] == model
    World.await_run(context, context.thread, "completed")
    assert [%{"model" => ^model}] = turn_starts(context)
    context
  end

  # The named worktree stands for a real directory under the scenario's home, since
  # the provider process starts in it.
  step "{string} is in worktree {string}", %{args: [thread, path]} = context do
    dir = Node.tmp_dir(context.node, "worktree-#{World.slug(path)}")

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
    ref = T3.Checkpoint.ref(T3.Checkpoint.scope_id(World.thread_id(context, "t1")), 0)
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
        T3.StreamState.list(state, "turn-item"),
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

    World.write_settings(context, %{
      "projectSettingsOverrides" => %{id => %{"responseStreamingMode" => mode}}
    })

    assert T3.Settings.for_project(id)["responseStreamingMode"] == mode
    context
  end

  step "project {string} has no response streaming setting", %{args: [project]} = context do
    id = World.project(context, project).id
    context = World.providers(context)
    {settings, _} = T3.Settings.get()

    refute Map.has_key?(
             get_in(settings, ["projectSettingsOverrides", id]) || %{},
             "responseStreamingMode"
           )

    assert T3.Settings.for_project(id)["responseStreamingMode"] in [nil, "paragraph"]
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

        if String.contains?(cadence, "400 ms"),
          do: assert(System.monotonic_time(:millisecond) - observed >= 400)

        finish_text(context)
    end
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

  step "{string} has a running turn with a command still running",
       %{args: [thread]} = context do
    context = World.running_turn(context, thread)

    context =
      notify(
        context,
        "item/started",
        item("commandExecution", "cmd-open", %{"command" => "sleep"})
      )

    World.await_state(context, thread, fn state ->
      state.entities["turn-item"]["turn-item:codex:cmd-open"]["status"] == "running"
    end)

    context
  end

  step "no turn item of the run is still running", context do
    await_status(context, context.running, "completed")

    items =
      for i <- World.entities(context, context.thread, "turn-item"),
          i["runId"] == context.running,
          do: i

    assert Enum.any?(items, &(&1["id"] == "turn-item:codex:cmd-open"))

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

  step "the provider session's last error is {string}", %{args: [message]} = context do
    assert session(context, context.thread, "codex")["lastError"] == message
    context
  end

  step "the provider process exits while {string} starts a turn", %{args: [thread]} = context do
    context = World.providers(context)
    Application.put_env(:t3, :codex_command, ["python3", "-c", "pass"])
    context = context |> Map.put(:thread, thread) |> World.send_message(thread, "Hi")
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    # The fake Codex is back for the next message.
    World.providers(context)
  end

  step "the run is failed with {string}", %{args: [message]} = context do
    run = World.await_run(context, context.thread, "failed")
    assert session(context, context.thread, "codex")["lastError"] == message
    Map.put(context, :failed_run, run["id"])
  end

  step "{string} can take its next message", %{args: [thread]} = context do
    context = World.send_message(context, thread, "Next")
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    assert %{"ordinal" => 2} = World.await_run(context, thread, "completed")
    context
  end

  step "{string} has a running turn and a queued message {string}",
       %{args: [thread, text]} = context do
    context
    |> World.running_turn(thread)
    |> World.queue_message(thread, text)
    |> World.queue_message(thread, "After that")
  end

  step "a run for {string} starts", %{args: [text]} = context do
    [next | _] = context.queued

    state =
      World.await_state(context, context.thread, fn state ->
        state.entities["run"][next]["status"] in ~w(starting running waiting completed)
      end)

    run = state.entities["run"][next]
    assert state.entities["message"][run["userMessageId"]]["text"] == text
    assert run["queuePosition"] == nil
    context
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

  step "the user interrupts the run of idle thread {string}", %{args: [thread]} = context do
    context
    |> World.providers()
    |> World.command(%{"type" => "run.interrupt", "threadId" => World.thread_id(context, thread)})
  end

  # --- stopping the session ----------------------------------------------------------

  step "{string} is idle with a provider session", %{args: [thread]} = context do
    context = completed_run(context, thread, "Hi")
    assert %{"status" => "ready"} = session(context, thread, "codex")
    assert [{pid, _}] = Registry.lookup(T3.Codex.Registry, World.thread_id(context, thread))
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
    assert Registry.lookup(T3.Codex.Registry, World.thread_id(context, thread)) == []
    context
  end

  step "the user stopped the session of {string}", %{args: [thread]} = context do
    context |> completed_run(thread, "Hi") |> stop_session(thread) |> stopped()
  end

  step "a provider session is opened again and resumes the provider thread", context do
    World.await_run(context, context.thread, "completed")
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
      World.send_message(context, thread, "Hi", %{
        "modelSelection" => %{"instanceId" => "claudeAgent", "model" => "claude-haiku"}
      })

    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    World.await_run(context, thread, "completed")
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
    context = World.send_message(context, thread, text)
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    run = World.await_run(context, thread, "completed")
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

  defp turn_starts(context), do: World.codex_requests(context, "turn/start")

  defp turn_cwd(context) do
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    World.await_run(context, context.thread, "completed")
    assert [%{"cwd" => cwd}] = turn_starts(context)
    cwd
  end

  defp native_turn(context),
    do: elem(World.codex_runtime(context, context.thread), 1).turn.native_turn_id

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
        state.entities["turn-item"]["turn-item:codex:cmd-t"]["output"] == "a.txt\n"
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

  defp await_output(context, output) do
    World.await_state(context, context.thread, fn state ->
      state.entities["turn-item"]["turn-item:codex:cmd-o"]["output"] == output
    end).entities["turn-item"]["turn-item:codex:cmd-o"]
  end

  defp await_status(context, run_id, status) do
    World.await_state(context, context.thread, &(&1.entities["run"][run_id]["status"] == status))
  end
end
