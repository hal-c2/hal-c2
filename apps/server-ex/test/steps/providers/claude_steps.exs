defmodule T3.Steps.Providers.Claude do
  @moduledoc """
  Steps for `features/providers/claude.feature`. Claude runs on `fake_claude.py` (see
  `T3.Test.Node.World.fake_providers/2`), which plays scripted turns from trigger
  words in the message and logs what it was sent.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.StreamState
  alias T3.Test.Node
  alias T3.Test.Node.World

  @thread "Claude work"

  # --- install and updates -----------------------------------------------------------

  step "the claude command is installed on the node", context do
    context = World.fake_providers(context)
    assert System.find_executable(hd(Application.get_env(:t3, :claude_command)))
    context
  end

  step "the claude command is not installed on the node", context do
    context = World.fake_providers(context)
    Application.put_env(:t3, :claude_command, ["t3-test-no-claude"])
    World.reset_provider_caches()
    context
  end

  step "Claude is listed as ready with its installed version", context do
    assert %{"status" => "ready", "installed" => true, "version" => "2.1.0"} =
             claude(context.providers)

    context
  end

  step "Claude is not offered as a provider", context do
    refute claude(context.providers)
    context
  end

  step "the installed Claude is older than the latest published version", context do
    context |> World.fake_providers(claude_layout: :native) |> latest("claudeAgent", "9.9.9")
  end

  step "Claude shows that an update is available and how it will be installed", context do
    assert %{
             "status" => "behind_latest",
             "currentVersion" => "2.1.0",
             "latestVersion" => "9.9.9",
             "canUpdate" => true,
             "updateCommand" => command
           } = claude(context.providers)["versionAdvisory"]

    # Claude's own installer updates it.
    assert command =~ ~r{/bin/claude update$}
    context
  end

  step "Claude was installed by its own native installer and is outdated", context do
    context |> World.fake_providers(claude_layout: :native) |> latest("claudeAgent", "9.9.9")
  end

  step "the user updates Claude", context do
    {reply, context} =
      World.call(context, "server.updateProvider", %{"provider" => "claudeAgent"})

    Map.put(context, :reply, reply)
  end

  step "Claude updates itself and the new version is shown", context do
    assert {:ok, %{"providers" => providers}} = context.reply

    assert %{"version" => "9.9.9", "versionAdvisory" => %{"status" => "current"}} =
             claude(providers)

    {providers, context} = World.providers(context)
    assert claude(providers)["version"] == "9.9.9"
    context
  end

  step "the user opens the update details for Claude", context do
    {providers, context} = World.providers(context)

    {reply, context} =
      World.call(context, "server.updateProvider", %{"provider" => "claudeAgent"})

    context |> Map.put(:providers, providers) |> Map.put(:reply, reply)
  end

  step "the user is told to update Claude by hand", context do
    assert %{"canUpdate" => false, "updateCommand" => nil, "status" => "behind_latest"} =
             claude(context.providers)["versionAdvisory"]

    assert {:error, message, _} = context.reply
    assert message =~ "This installation cannot be updated from here."
    context
  end

  # --- models and account ------------------------------------------------------------

  step "the user opens the model picker for Claude", context do
    {providers, context} = World.providers(context)
    Map.put(context, :models, claude(providers)["models"])
  end

  step "Sonnet, Opus and Haiku are offered", context do
    assert ["Claude Sonnet", "Claude Opus", "Claude Haiku"] ==
             Enum.map(context.models, & &1["name"])

    context
  end

  step "Sonnet is the default", context do
    assert [%{"slug" => "sonnet"}] = Enum.filter(context.models, & &1["isDefault"])
    context
  end

  step "the Claude CLI is signed in with a subscription", context do
    # The fake reports me@example.com on a Max subscription when it starts.
    World.fake_providers(context)
  end

  step "Claude's usage has been checked", context do
    Node.ensure(T3.ProviderUsageLimits)
    :ok = T3.ProviderUsageLimits.refresh(["claudeAgent"])
    # The account arrives as a cast the probe sent; this call lands after it.
    :sys.get_state(T3.ProviderUsageLimits)
    {providers, context} = World.providers(context)
    Map.put(context, :providers, providers)
  end

  step "Claude shows the account's email and plan", context do
    assert %{"email" => "me@example.com", "type" => "max", "label" => label} =
             claude(context.providers)["auth"]

    assert label =~ "Max"
    context
  end

  # --- turns ---------------------------------------------------------------------------

  step "the user sends a message to Claude", context do
    context =
      context |> World.fake_providers() |> World.launch_thread(@thread, "claudeAgent", "hello")

    # A signed-out CLI fails the turn; the steps after this one say which it should be.
    World.await_stream(context, @thread, fn state ->
      match?([%{"status" => s}] when s in ["completed", "failed"], StreamState.list(state, "run"))
    end)

    context
  end

  # --- composer ------------------------------------------------------------------------

  step "Claude reports the skill {string} and the command {string}",
       %{args: [skill, command]} = context do
    context = World.fake_providers(context)
    # Claude Code lists skills among the slash commands its initialize reply names.
    System.put_env(
      "FAKE_CLAUDE_COMMANDS",
      JSON.encode!([skill, String.trim_leading(command, "/")])
    )

    ExUnit.Callbacks.on_exit(fn -> System.delete_env("FAKE_CLAUDE_COMMANDS") end)
    Node.ensure(T3.ProviderUsageLimits)
    :ok = T3.ProviderUsageLimits.refresh(["claudeAgent"])
    :sys.get_state(T3.ProviderUsageLimits)
    Map.put(context, :composer_instance, "claudeAgent")
  end

  step ~r/^the user types a slash in (?:the composer|a (?<provider>Codex) thread)$/,
       %{args: args} = context do
    instance = if args == ["Codex"], do: "codex", else: context.composer_instance
    {providers, context} = World.providers(World.fake_providers(context))

    Map.put(
      context,
      :slash_commands,
      Enum.find(providers, &(&1["instanceId"] == instance))["slashCommands"]
    )
  end

  step ~r/^"(?<a>[^"]+)" and "(?<b>[^"]+)" are offered$/, %{args: names} = context do
    offered = Enum.map(context.slash_commands, & &1["name"])
    for name <- names, do: assert(String.trim_leading(name, "/") in offered)
    context
  end

  step "the Claude CLI on the node is not signed in", context do
    System.put_env("FAKE_CLAUDE_SIGNED_OUT", "1")
    ExUnit.Callbacks.on_exit(fn -> System.delete_env("FAKE_CLAUDE_SIGNED_OUT") end)
    context
  end

  step "the turn fails saying to run the Claude sign-in command on that machine", context do
    state = World.await_runs(context, @thread, ["failed"])
    [session] = StreamState.list(state, "provider-session")
    assert session["lastError"] =~ "run `claude auth login` on this environment's machine"
    context
  end

  step "the answer appears as it is written", context do
    message =
      Enum.find(
        StreamState.list(World.stream(context, @thread), "message"),
        &(&1["role"] == "assistant")
      )

    assert %{"text" => "Hello from claude", "streaming" => false} = message

    # The message is shown streaming, empty, before any of its text is written.
    patches =
      for e <- World.stream_events(context, @thread), e.entity == message["id"], do: e.patch

    assert [created | later] = patches
    assert %{"s" => %{"streaming" => true, "text" => ""}} = created
    assert Enum.any?(later, &match?(%{"a" => %{"text" => _}}, &1))
    context
  end

  step "Claude's thinking is shown separately", context do
    items = StreamState.list(World.stream(context, @thread), "turn-item")
    assert Enum.any?(items, &(&1["type"] == "reasoning" and &1["text"] == "Let me look."))
    refute Enum.any?(items, &(&1["type"] == "assistant_message" and &1["text"] =~ "Let me look."))
    context
  end

  step ~r/^Claude uses the (?<tool>\w+) tool$/, %{args: [tool]} = context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_thread(@thread, "claudeAgent", "use #{tool}")

    World.await_runs(context, @thread, ["completed"])
    context
  end

  step ~r/^the timeline shows a (?<kind>file change|command|web) step$/,
       %{args: [kind]} = context do
    type =
      %{"file change" => "file_change", "command" => "command_execution", "web" => "web_search"}[
        kind
      ]

    items = StreamState.list(World.stream(context, @thread), "turn-item")
    assert Enum.any?(items, &(&1["type"] == type and &1["status"] == "completed")), inspect(items)
    context
  end

  step "a Claude turn is running", context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_thread(@thread, "claudeAgent", "wait for me")

    World.await_running(context, @thread)
    World.await_provider_log(context, "claude", &(get_in(&1, ["in", "type"]) == "user"))
    context
  end

  step "Claude receives the message during the running turn", context do
    World.await_provider_log(context, "claude", &(get_in(&1, ["in", "priority"]) == "now"))
    state = World.await_runs(context, @thread, ["completed"])

    assert Enum.any?(
             StreamState.list(state, "message"),
             &(&1["role"] == "assistant" and &1["text"] =~ "steered: ")
           )

    context
  end

  step "the thread is in plan mode on Claude", context do
    context |> World.fake_providers() |> Map.put(:interaction_mode, "plan")
  end

  step "Claude finishes planning", context do
    context =
      World.launch_thread(context, @thread, "claudeAgent", "make a plan", %{
        "interactionMode" => context.interaction_mode
      })

    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "Claude asks the user a multiple choice question", context do
    context =
      context |> World.fake_providers() |> World.launch_thread(@thread, "claudeAgent", "ask me")

    Map.put(context, :request, World.await_request(context, @thread))
  end

  step "the question is shown with its choices", context do
    assert %{"kind" => "user_input"} = context.request

    assert [%{"status" => "waiting", "questions" => [question]}] =
             for(
               i <-
                 StreamState.list(
                   World.stream(context, World.current_thread(context)),
                   "turn-item"
                 ),
               i["type"] == "user_input_request",
               do: i
             )

    labels = Enum.map(question["options"], & &1["label"])
    assert "Red" in labels and Enum.all?(labels, &is_binary/1)
    Map.put(context, :question, question)
  end

  step "the user's answer is sent back to Claude", context do
    {:ok, _} =
      T3.Orchestration.dispatch(%{
        "type" => "runtime-request.respond",
        "threadId" => World.thread_id(context, @thread),
        "requestId" => context.request["id"],
        "answers" => %{context.question["id"] => "Red"}
      })

    World.await_runs(context, @thread, ["completed"])
    assert ~s(answered {"Which color?": "Red"}) in World.replies(context, @thread)
    context
  end

  step "the project allows the T3 Code tools", context do
    context = World.fake_providers(context)
    Node.ensure(T3.Mcp)
    refute T3.Settings.for_project(World.project(context).id)["enableAgentBrowserAccess"] == false
    context
  end

  step "a Claude turn starts", context do
    context = World.launch_thread(context, @thread, "claudeAgent", "hello")
    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "Claude can call the T3 Code tools for this thread", context do
    %{"argv" => argv} = World.await_provider_log(context, "claude", &Map.has_key?(&1, "argv"))
    config = argv |> Enum.drop_while(&(&1 != "--mcp-config")) |> Enum.at(1) |> JSON.decode!()
    %{"url" => url, "headers" => %{"Authorization" => auth}} = config["mcpServers"]["t3-code"]
    assert url =~ ~r{^http://127\.0\.0\.1:\d+/mcp$}

    body =
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "t3_thread_list", "arguments" => %{}}
      })

    # The tools find the calling thread through its sidebar row.
    :ok = T3.Shell.subscribe(self())
    World.await_row(World.thread_id(context, @thread), & &1)
    assert {200, %{"result" => %{"structuredContent" => listed}}} = T3.Mcp.handle(auth, body)
    assert listed["currentThreadId"] == World.thread_id(context, @thread)
    context
  end

  step "a Claude thread with three turns", context do
    context
    |> World.fake_providers()
    |> World.run_turns(@thread, "claudeAgent", ["hello", "hello again", "one more"])
  end

  step "Claude continues from the first turn as if the later turns never happened", context do
    assert {:ok, _} = context.reply
    context = World.send_message(context, @thread, "where are we")

    World.await_runs(context, @thread, ["completed", "rolled_back", "rolled_back", "completed"])
    assert "resumed at uuid-1 fork False history False" in World.replies(context, @thread)
    context
  end

  step "a new thread continues Claude's session from the second turn", context do
    assert {:ok, _} = context.reply
    context = World.send_message(context, "fork", "where are we")

    World.await_stream(context, "fork", fn state ->
      match?(
        [_, _, %{"status" => "completed"}],
        state |> StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])
      )
    end)

    assert "resumed at uuid-2 fork True history False" in World.replies(context, "fork")
    context
  end

  step "Claude is picked for text generation", context do
    context = World.fake_text(context, [:claude])

    World.merge_settings(%{
      "textGenerationModelSelection" => %{"instanceId" => "claudeAgent", "model" => "haiku"}
    })

    context
  end

  step "Claude writes the title without using any tools", context do
    assert {:ok, %{"title" => title}} = context.title_result
    assert title =~ "claude"
    assert [%{"argv" => argv}] = World.text_calls(context)
    assert ["-p" | _] = argv
    # No tool is available to it, and it asks for nothing.
    assert ["--tools", ""] in Enum.chunk_every(argv, 2, 1)
    assert ["--permission-mode", "dontAsk"] in Enum.chunk_every(argv, 2, 1)
    context
  end

  step "Claude reports that a usage window is nearly used up during a turn", context do
    context = World.fake_providers(context)
    Node.ensure(T3.ProviderUsageLimits)
    context = World.launch_thread(context, @thread, "claudeAgent", "rate limit")
    World.await_runs(context, @thread, ["completed"])
    :sys.get_state(T3.ProviderUsageLimits)
    context
  end

  step "the limits view shows the new usage for that window", context do
    {providers, context} = World.providers(context)
    windows = claude(providers)["usageLimits"]["windows"]

    assert %{"kind" => "session", "usedPercent" => used} =
             Enum.find(windows, &(&1["id"] == "five_hour"))

    assert round(used) == 91
    context
  end

  step "Claude shows its session and weekly windows and a weekly window for the limited model",
       context do
    windows = claude(context.providers)["usageLimits"]["windows"]

    assert [
             %{"kind" => "session", "label" => "Session"},
             %{"kind" => "weekly", "label" => "Weekly"},
             %{"kind" => "weekly", "label" => "Weekly · Fable 1"}
           ] = Enum.sort_by(windows, &{&1["kind"], &1["label"]})

    context
  end

  step "Claude is signed in with a subscription", context do
    World.fake_providers(context)
  end

  step "the user tries to revert to an earlier turn", context do
    World.rollback(context, @thread, 1, %{"restoreFiles" => false})
  end

  step "the revert is refused until the turn ends", context do
    assert {:error, "Interrupt the current turn before rewinding."} = context.reply

    {:ok, _} =
      T3.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "threadId" => World.thread_id(context, @thread)
      })

    # An interrupted turn leaves no checkpoint, so the next turn is the one to revert to.
    World.await_runs(context, @thread, ["interrupted"])
    context = World.send_message(context, @thread, "hello")
    World.await_runs(context, @thread, ["interrupted", "completed"])
    context = World.rollback(context, @thread, 2, %{"restoreFiles" => false})
    assert {:ok, _} = context.reply
    context
  end

  step ~r/^the user (?<action>disables|enables) Claude$/, %{args: [action]} = context do
    World.merge_settings(%{
      "providers" => %{"claudeAgent" => %{"enabled" => action == "enables"}}
    })

    context
  end

  step ~r/^Claude is (?<offered>not offered in the model picker|offered again)$/,
       %{args: [offered]} = context do
    {providers, context} = World.providers(context)
    assert claude(providers)["enabled"] == (offered == "offered again")
    context
  end

  defp claude(providers), do: Enum.find(providers, &(&1["instanceId"] == "claudeAgent"))

  # The npm registry's latest release, as the node last read it.
  defp latest(context, driver, version) do
    :persistent_term.put(
      {T3.ProviderUpdates, driver},
      {version, System.monotonic_time(:millisecond)}
    )

    context
  end
end
