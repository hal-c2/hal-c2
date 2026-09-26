defmodule HalC2.Steps.Providers.Capabilities do
  @moduledoc """
  Steps for `features/providers/capabilities.feature`: the same conversation moves
  across the fake providers (`HalC2.Test.Node.World.fake_providers/2`) and each one's
  log shows what it was handed.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.StreamState
  alias HalC2.Test.Node.World

  @thread "Work"
  @instances %{
    "Codex" => "codex",
    "Claude" => "claudeAgent",
    "Grok" => "grok",
    "OpenCode" => "opencode",
    "Cursor" => "cursor",
    "Pi" => "pi"
  }

  # --- steering --------------------------------------------------------------------------

  step ~r/^a (?<provider>Codex|Claude|Grok|OpenCode|Cursor|Pi) thread with a running turn$/,
       %{args: [provider]} = context do
    context =
      context
      |> World.fake_providers()
      |> fake_pi(provider)
      |> World.launch_on(@thread, @instances[provider], "wait for me")

    World.await_running(context, @thread)
    context
  end

  # Pi runs in its own RPC mode, so its fake is the scripted Pi rather than the ACP agent.
  defp fake_pi(context, "Pi") do
    wait = %{"match" => "wait for me", "steps" => [%{"waitAbort" => true}]}

    HalC2.Test.FakeAcp.install_pi(context, %{},
      enabled: true,
      turns: [wait | HalC2.Test.FakeAcp.pi_turns()]
    )
  end

  defp fake_pi(context, _provider), do: context

  step "the message waits until the running turn ends", context do
    World.await_runs(context, @thread, ["running", "queued"])

    assert [%{"text" => "one more thing"}] =
             for(
               m <- StreamState.list(World.stream(context, @thread), "message"),
               m["role"] == "user" and m["text"] == "one more thing",
               do: m
             )

    context
  end

  step "a Codex thread whose turn is finishing", context do
    context =
      context |> World.fake_providers() |> World.launch_on(@thread, "codex", "finishing up")

    World.await_running(context, @thread)
    context
  end

  step "the user's steer reaches the node after the turn ended", context do
    # Codex refuses the steer (its turn is over) and ends the turn.
    World.post_message(context, @thread, "one more thing", %{"dispatchMode" => nil})
  end

  step "the message starts the next turn", context do
    World.await_runs(context, @thread, ["completed", "completed"])

    start =
      context
      |> World.provider_log("codex")
      |> Enum.filter(&(get_in(&1, ["in", "method"]) == "turn/start"))
      |> List.last()

    assert [%{"text" => "one more thing"} | _] = get_in(start, ["in", "params", "input"])
    assert "Hello from codex" in World.replies(context, @thread)
    context
  end

  # --- forks, switches and merges -------------------------------------------------------------

  step ~r/^a (?<provider>Grok|OpenCode) thread with three turns$/,
       %{args: [provider]} = context do
    context
    |> World.fake_providers()
    |> World.run_turns(@thread, @instances[provider], ["hello", "hello again", "one more"])
  end

  step "the user forks the thread after the second turn", context do
    context = World.fork(context, World.current_thread(context), 2, "fork")
    assert {:ok, _} = context.reply
    context |> World.post_message("fork", "where are we") |> await_fork_turn()
  end

  step "the fork's first turn continues a copy of Codex's own thread cut after turn 2", context do
    fork =
      World.await_provider_log(context, "codex", &(get_in(&1, ["in", "method"]) == "thread/fork"))

    assert get_in(fork, ["in", "params", "lastTurnId"]) == "native-turn-2"

    assert "on forked-native-thread-1-at-native-turn-2 history False merged False" in World.replies(
             context,
             "fork"
           )

    context
  end

  step "the fork's first turn resumes Claude's session at turn 2 as a new session", context do
    assert "resumed at uuid-2 fork True history False" in World.replies(context, "fork")
    context
  end

  step "the fork's first turn starts with a transcript of the first two turns", context do
    prompt =
      context
      |> World.provider_log("acp")
      |> Enum.filter(&(get_in(&1, ["in", "method"]) == "session/prompt"))
      |> List.last()
      |> get_in(["in", "params", "prompt"])
      |> Enum.map_join(& &1["text"])

    assert prompt =~ "<conversation_history>"
    assert prompt =~ "User: hello\n\nAssistant: Hello from acp\n\nUser: hello again"
    refute prompt =~ "one more"
    assert String.ends_with?(prompt, "where are we")
    context
  end

  step "a Codex thread with history", context do
    context |> World.fake_providers() |> World.run_turns(@thread, "codex", ["hello"])
  end

  step "a thread whose history is longer than a provider's handover limit", context do
    # Codex repeats a "repeat" message as its answer, so each turn is twice its size.
    old = "repeat old-marker " <> String.duplicate("a", 20_000)
    new = "repeat new-marker " <> String.duplicate("b", 20_000)
    context |> World.fake_providers() |> World.run_turns(@thread, "codex", [old, new])
  end

  step "the thread moves to another provider", context do
    switch_to_claude(context, "where are we")
  end

  step "the transcript keeps the newest history and drops the oldest", context do
    text = claude_prompt(context, "where are we")
    assert text =~ "[earlier messages omitted]"
    assert text =~ "new-marker"
    refute text =~ "old-marker"
    context
  end

  step "a fork with two turns the parent has not seen", context do
    context |> parent_and_fork() |> fork_turns(["fork one", "fork two"])
  end

  step "the user merges the fork back", context do
    merge_back(context)
  end

  step "the parent's next turn receives the fork's new work as a transcript", context do
    text = parent_turn(context)
    assert text =~ "<merged_work>"
    assert text =~ "User: fork one"
    assert text =~ "User: fork two"
    # The history both share is not repeated.
    refute text =~ "User: hello"
    context
  end

  step "a merge from a fork that the parent has not used yet", context do
    context |> parent_and_fork() |> fork_turns(["fork one"]) |> merge_back()
  end

  step "the user merges the same fork back again", context do
    context |> fork_turns(["fork two"]) |> merge_back()
  end

  step "only the newer merge reaches the parent", context do
    text = parent_turn(context)
    transfers = StreamState.list(World.stream(context, @thread), "context-transfer")
    assert ["consumed", "superseded"] = transfers |> Enum.map(& &1["status"]) |> Enum.sort()

    assert length(String.split(text, "<merged_work>")) == 2
    assert length(String.split(text, "User: fork one")) == 2
    assert text =~ "User: fork two"
    context
  end

  step "the user merges back a thread that was not forked from the parent", context do
    context =
      context
      |> World.fake_providers()
      |> World.run_turns("Other", "codex", ["hello"])
      |> World.run_turns(@thread, "codex", ["hello"])

    [run] = World.runs(context, "Other")

    reply =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.merge_back",
        "commandId" => "cmd-merge-#{System.unique_integer([:positive])}",
        "sourceThreadId" => World.thread_id(context, "Other"),
        "targetThreadId" => World.thread_id(context, @thread),
        "sourcePoint" => %{"type" => "run", "runId" => run["id"]}
      })

    Map.put(context, :reply, reply)
  end

  step "the user is told the thread is not a fork of the parent", context do
    assert {:error, message} = context.reply
    assert message =~ "is not a fork of #{World.thread_id(context, @thread)}"
    context
  end

  # --- rewinds ------------------------------------------------------------------------------

  step "the user rewinds to the first turn", context do
    World.rollback(context, World.current_thread(context), 1, %{"restoreFiles" => false})
  end

  step "the next turn starts a new Grok session without the old conversation", context do
    assert {:ok, _} = context.reply
    context = World.post_message(context, @thread, "where are we")
    World.await_runs(context, @thread, ["completed", "rolled_back", "rolled_back", "completed"])

    methods = for entry <- World.provider_log(context, "acp"), do: get_in(entry, ["in", "method"])
    prompts = for {"session/prompt", i} <- Enum.with_index(methods), do: i
    sessions = for {"session/new", i} <- Enum.with_index(methods), do: i
    # The turn after the rewind opened a session of its own.
    assert Enum.at(prompts, 2) < List.last(sessions)
    assert List.last(sessions) < List.last(prompts)

    last =
      for(
        entry <- World.provider_log(context, "acp"),
        get_in(entry, ["in", "method"]) == "session/prompt",
        do: entry["in"]["params"]
      )
      |> List.last()

    text = Enum.map_join(last["prompt"], & &1["text"])
    # Only the turn it was rewound to comes along, as a transcript.
    assert text =~ "User: hello\n"
    refute text =~ "hello again"
    refute text =~ "one more"
    context
  end

  step "the user rewinds the thread", context do
    World.rollback(context, World.current_thread(context), 0, %{"restoreFiles" => false})
  end

  # --- text generation ----------------------------------------------------------------------

  step ~r/^the text-generation model is on (?<provider>Codex|Claude|Grok|OpenCode|Cursor)$/,
       %{args: [provider]} = context do
    instance = @instances[provider]

    context =
      case instance do
        "codex" ->
          World.text_writers(context, [:codex])

        "claudeAgent" ->
          World.text_writers(context, [:claude])

        # Built-in ACP agents are off until the user turns them on.
        _ ->
          World.merge_settings(%{"providers" => %{instance => %{"enabled" => true}}})
          context = context |> World.fake_providers() |> World.text_writers([])
          # Without a text log the fake ACP agent asks to run a tool before it answers.
          World.put_os_env("FAKE_TEXT_LOG", nil)
          context
      end

    model = %{"codex" => "gpt-5.4-mini", "claudeAgent" => "haiku"}[instance] || "fake/one"

    World.merge_settings(%{
      "textGenerationModelSelection" => %{"instanceId" => instance, "model" => model}
    })

    context
  end

  step "Codex writes it in a read-only run", context do
    assert {:ok, %{"title" => title}} = context.title_result
    assert title =~ "codex"
    assert [%{"argv" => ["exec" | _] = argv}] = World.text_calls(context)
    assert ["-s", "read-only"] in Enum.chunk_every(argv, 2, 1)
    context
  end

  step "Claude writes it in a one-shot run", context do
    assert {:ok, %{"title" => title}} = context.title_result
    assert title =~ "claude"
    assert [%{"argv" => ["-p" | _]}] = World.text_calls(context)
    context
  end

  # --- helpers ------------------------------------------------------------------------------

  defp await_fork_turn(context) do
    World.await_value(context, "fork", fn state ->
      match?(
        [_, _, %{"status" => "completed"}],
        state |> StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])
      )
    end)

    context
  end

  defp switch_to_claude(context, text) do
    title = World.current_thread(context)
    count = length(World.runs(context, title))

    context =
      World.post_message(context, title, text, %{
        "modelSelection" => %{"instanceId" => "claudeAgent", "model" => "sonnet"}
      })

    World.await_value(context, title, &(length(StreamState.list(&1, "run")) > count))
    World.await_idle(context, title)
    context
  end

  # The user message Claude was sent that ends with `text`.
  defp claude_prompt(context, text) do
    context
    |> World.provider_log("claude")
    |> Enum.map(&get_in(&1, ["in", "message", "content"]))
    |> Enum.map(fn
      content when is_binary(content) -> content
      content when is_list(content) -> Enum.map_join(content, &(&1["text"] || ""))
      _ -> ""
    end)
    |> Enum.find(&String.ends_with?(&1, text))
    |> Kernel.||(flunk("Claude was never sent #{inspect(text)}"))
  end

  defp parent_and_fork(context) do
    context =
      context
      |> World.fake_providers()
      |> World.run_turns(@thread, "codex", ["hello", "hello again"])
      |> World.fork(@thread, 2, "fork")

    assert {:ok, _} = context.reply
    Map.put(context, :current_thread, @thread)
  end

  defp fork_turns(context, texts) do
    Enum.reduce(texts, context, fn text, context ->
      count = length(World.runs(context, "fork"))
      context = World.post_message(context, "fork", text)
      World.await_value(context, "fork", &(length(StreamState.list(&1, "run")) > count))
      World.await_idle(context, "fork")
      context
    end)
  end

  defp merge_back(context) do
    run = context |> World.runs("fork") |> List.last()

    assert :ok =
             HalC2.Orchestration.dispatch(%{
               "type" => "thread.merge_back",
               "commandId" => "cmd-merge-#{System.unique_integer([:positive])}",
               "sourceThreadId" => World.thread_id(context, "fork"),
               "targetThreadId" => World.thread_id(context, @thread),
               "sourcePoint" => %{"type" => "run", "runId" => run["id"]}
             })
             |> then(fn
               {:ok, _} -> :ok
               other -> other
             end)

    context
  end

  # Sends the parent its next turn and returns the text Codex got for it.
  defp parent_turn(context) do
    count = length(World.runs(context, @thread))
    context = World.post_message(context, @thread, "where are we")
    World.await_value(context, @thread, &(length(StreamState.list(&1, "run")) > count))
    World.await_idle(context, @thread)

    assert Enum.any?(World.replies(context, @thread), &(&1 =~ "merged True"))

    context
    |> World.provider_log("codex")
    |> Enum.filter(&(get_in(&1, ["in", "method"]) == "turn/start"))
    |> Enum.map(
      &Enum.map_join(get_in(&1, ["in", "params", "input"]), fn i -> i["text"] || "" end)
    )
    |> Enum.filter(&String.ends_with?(&1, "where are we"))
    |> List.last()
  end
end
