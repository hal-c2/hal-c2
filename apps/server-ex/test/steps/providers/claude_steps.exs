defmodule HalC2.Steps.Providers.Claude do
  @moduledoc """
  Steps for `features/providers/claude.feature`. Claude runs on `fake_claude.py` (see
  `HalC2.Test.Mc.World.fake_providers/2`), which plays scripted turns from trigger
  words in the message and logs what it was sent.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.StreamState
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @thread "Claude work"

  # The composer's option ids, by the names the scenarios use.
  @options %{
    "reasoning" => "effort",
    "fast mode" => "fastMode",
    "thinking" => "thinking",
    "context window" => "contextWindow"
  }

  # --- install and updates -----------------------------------------------------------

  step "the claude command is installed on the MC", context do
    context = World.fake_providers(context)
    assert System.find_executable(hd(Application.get_env(:hal_c2, :claude_command)))
    context
  end

  step "the claude command is not installed on the MC", context do
    context = World.fake_providers(context)
    World.put_app_env(:claude_command, ["hal-c2-test-no-claude"])
    World.reset_provider_caches()
    context
  end

  step "Claude is listed as ready with its installed version", context do
    assert %{"status" => "ready", "installed" => true, "version" => "2.1.0"} =
             claude(context.providers)

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

    {providers, context} = World.provider_list(context)
    assert claude(providers)["version"] == "9.9.9"
    context
  end

  step "the user opens the update details for Claude", context do
    {providers, context} = World.provider_list(context)

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
    {providers, context} = World.provider_list(context)
    Map.put(context, :models, claude(providers)["models"])
  end

  step "the manifest's Claude models are offered in its order", context do
    offered = Enum.map(context.models, & &1["slug"])
    catalog = Enum.map(claude_manifest()["models"], & &1["slug"])
    assert offered != [] and offered == Enum.filter(catalog, &(&1 in offered))
    context
  end

  step "models the manifest marks as legacy are labelled legacy", context do
    legacy = for m <- claude_manifest()["models"], m["status"] == "legacy", do: m["slug"]
    assert Enum.any?(context.models, & &1["isLegacy"])

    for model <- context.models,
        do: assert(model["isLegacy"] == model["slug"] in legacy, model["slug"])

    context
  end

  step "the installed Claude is older than a model requires", context do
    {providers, context} = World.provider_list(context)
    version = claude(providers)["version"]

    gated =
      Enum.find(claude_manifest()["models"], fn m ->
        min = get_in(m, ["adapter", "claudeCode", "minVersion"])
        min && Version.compare(version, min) == :lt
      end)

    assert gated, "the fake Claude (#{version}) is new enough for every manifest model"
    Map.put(context, :gated, gated["slug"])
  end

  # The picker leaves the model out; a thread already on it (or a default naming it)
  # still picks it.
  step "the user picks that model", context do
    context =
      World.launch_on(context, @thread, "claudeAgent", "hello", %{"model" => context.gated})

    World.await_runs(context, @thread, ["failed"])
    context
  end

  step "the user is told which Claude version the model needs", context do
    model = Enum.find(claude_manifest()["models"], &(&1["slug"] == context.gated))
    min = get_in(model, ["adapter", "claudeCode", "minVersion"])

    assert [%{"lastError" => error}] =
             StreamState.list(World.stream(context, @thread), "provider-session")

    assert error ==
             "Claude Code v2.1.0 is too old for #{model["name"]}. Upgrade to v#{min} or newer to access it."

    # Claude was never started for the turn.
    refute Enum.any?(World.provider_log(context, "claude"), &Map.has_key?(&1, "in"))
    context
  end

  step "that model is not offered", context do
    refute Enum.any?(context.models, &(&1["slug"] == context.gated))
    context
  end

  step "the installed Claude can run every model in the manifest", context do
    World.fake_providers(context, claude_version: "999.0.0")
  end

  step ~r/^the user opens the options for a Claude model that supports (?<option>.+)$/,
       %{args: [option]} = context do
    {providers, context} = World.provider_list(context)
    id = @options[option]
    model = Enum.find(claude(providers)["models"], &descriptor(&1, id))
    assert model, "no Claude model offers #{option}"
    # Its choices are checked by the Codex steps' "the user can choose".
    Map.put(context, :option_descriptor, descriptor(model, id))
  end

  step ~r/^the user sends a message to Claude on a model with (?<option>.+) set to "(?<value>[^"]+)"$/,
       %{args: [option, value]} = context do
    id = @options[option]
    {providers, context} = World.provider_list(context)

    model =
      Enum.find(claude(providers)["models"], fn model ->
        case descriptor(model, id) do
          %{"type" => "boolean"} -> value in ["on", "off"]
          %{"options" => options} -> Enum.any?(options, &(&1["id"] == value))
          nil -> false
        end
      end)

    assert model, "no Claude model offers #{option} #{value}"
    value = Map.get(%{"on" => true, "off" => false}, value, value)

    selection = %{
      "instanceId" => "claudeAgent",
      "model" => model["slug"],
      "options" => [%{"id" => id, "value" => value}]
    }

    context =
      World.launch_on(context, @thread, "claudeAgent", "hello", %{"modelSelection" => selection})

    World.await_runs(context, @thread, ["completed"])
    assert [argv] = for(%{"argv" => argv} <- World.provider_log(context, "claude"), do: argv)
    Map.merge(context, %{argv: argv, model: model["slug"]})
  end

  step "Claude is started with the effort {string}", %{args: [effort]} = context do
    assert ["--effort", effort] in pairs(context.argv)
    context
  end

  step ~r/^Claude is started with the effort "(?<effort>[^"]+)" and the setting "(?<key>[^"]+)" on$/,
       %{args: [effort, key]} = context do
    assert ["--effort", effort] in pairs(context.argv)
    assert settings(context)[key] == true
    context
  end

  step "Claude is started with no effort, and the message asks it to ultrathink", context do
    refute "--effort" in context.argv

    assert ["Ultrathink:\nhello"] =
             for(
               %{"in" => %{"type" => "user", "message" => %{"content" => text}}} <-
                 World.provider_log(context, "claude"),
               do: text
             )

    context
  end

  step ~r/^Claude is started with the setting "(?<key>[^"]+)" (?<value>on|off)$/,
       %{args: [key, value]} = context do
    assert settings(context)[key] == (value == "on")
    context
  end

  step "Claude is started with a model id ending in {string}", %{args: [suffix]} = context do
    assert ["--model", context.model <> suffix] in pairs(context.argv)
    context
  end

  step "the Claude CLI is signed in with a subscription", context do
    # The fake reports me@example.com on a Max subscription when it starts.
    World.fake_providers(context)
  end

  step "Claude's usage has been checked", context do
    Mc.ensure(HalC2.ProviderUsageLimits)
    :ok = HalC2.ProviderUsageLimits.refresh(["claudeAgent"])
    # The account arrives as a cast the probe sent; this call lands after it.
    :sys.get_state(HalC2.ProviderUsageLimits)
    {providers, context} = World.provider_list(context)
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
      context |> World.fake_providers() |> World.launch_on(@thread, "claudeAgent", "hello")

    # A signed-out CLI fails the turn; the steps after this one say which it should be.
    World.await_value(context, @thread, fn state ->
      match?([%{"status" => s}] when s in ["completed", "failed"], StreamState.list(state, "run"))
    end)

    context
  end

  step "a Claude thread has answered on {string}", %{args: [model]} = context do
    # `providers/1` logs each start of the fake CLI (`claude_starts/1`).
    context =
      context
      |> World.providers()
      |> World.launch_on(@thread, "claudeAgent", "hello", %{"model" => model})

    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "the user sends the next message on {string}", %{args: [model]} = context do
    selection = %{"instanceId" => "claudeAgent", "model" => model}
    context = World.send_turn(context, @thread, "and now?", %{"modelSelection" => selection})
    World.await_runs(context, @thread, ["completed", "completed"])
    context
  end

  step "Claude answers it on {string}", %{args: [model]} = context do
    assert [_, argv] = World.claude_starts(context)
    # The model's default context window may add a suffix, such as "[1m]".
    assert Enum.any?(pairs(argv), &match?(["--model", ^model <> _], &1))
    Map.put(context, :argv, argv)
  end

  step "the conversation continues in the same Claude session", context do
    assert ["--resume", "fake-session-1"] in Enum.chunk_every(context.argv, 2, 1, :discard)
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
    Mc.ensure(HalC2.ProviderUsageLimits)
    :ok = HalC2.ProviderUsageLimits.refresh(["claudeAgent"])
    :sys.get_state(HalC2.ProviderUsageLimits)
    Map.put(context, :composer_instance, "claudeAgent")
  end

  step ~r/^the user types a slash in (?:the composer|a (?<provider>Codex) thread)$/,
       %{args: args} = context do
    instance = if args == ["Codex"], do: "codex", else: context.composer_instance
    {providers, context} = World.provider_list(World.fake_providers(context))

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

  step "the Claude CLI on the MC is not signed in", context do
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
      |> World.launch_on(@thread, "claudeAgent", "use #{tool}")

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
      |> World.launch_on(@thread, "claudeAgent", "wait for me")

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

  step "a Claude turn has finished", context do
    context =
      context |> World.fake_providers() |> World.launch_on(@thread, "claudeAgent", "hello")

    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "Claude answers a finished background task by itself", context do
    claude_says(context, %{
      "type" => "assistant",
      "message" => %{
        "id" => "m-wake",
        "content" => [%{"type" => "text", "text" => "The build passed"}]
      }
    })

    context
  end

  step "the thread shows a running run that Claude started, with Claude's answer", context do
    World.await_value(context, @thread, fn state ->
      runs = state |> StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])
      messages = StreamState.get(state, "message")

      match?([%{"status" => "completed"}, %{"status" => "running"}], runs) and
        messages[List.last(runs)["userMessageId"]]["creationSource"] == "provider" and
        Enum.any?(
          Map.values(messages),
          &(&1["runId"] == List.last(runs)["id"] and &1["text"] == "The build passed")
        )
    end)

    context
  end

  step "Claude finishes that work", context do
    claude_says(context, %{"type" => "result", "subtype" => "success"})
    context
  end

  step "that run completes and the user's run stays completed", context do
    World.await_runs(context, @thread, ["completed", "completed"])
    context
  end

  # The fake's "in the background" turn starts a subagent with the Agent tool (tool use
  # agent-1, task task-agent-1); the task then says what it does and ends.
  step "Claude starts a subagent", context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "claudeAgent", "survey in the background")

    World.await_runs(context, @thread, ["completed"])
    task = %{"type" => "system", "task_id" => "task-agent-1", "tool_use_id" => "agent-1"}

    claude_says(
      context,
      Map.merge(task, %{"subtype" => "task_progress", "summary" => "Reading lib"})
    )

    claude_says(
      context,
      Map.merge(task, %{
        "subtype" => "task_notification",
        "status" => "completed",
        "summary" => "lib has three modules"
      })
    )

    Map.merge(context, %{
      thread: @thread,
      subagent_prompt: "List what is in the repo",
      subagent_answer: "lib has three modules"
    })
  end

  step "Claude starts a monitor in the thread", context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "claudeAgent", "start a monitor")

    World.await_runs(context, @thread, ["completed"])
    Map.put(context, :thread, @thread)
  end

  step "the thread lists the monitor as background work", context do
    id = World.thread_id(context, @thread)

    World.await_row(
      id,
      &match?(
        [%{"taskId" => "mon-1", "taskType" => "dynamic_tool", "description" => "Monitor"}],
        &1["pendingBackgroundTasks"]
      )
    )

    context
  end

  step "the monitor is not shown as a command", context do
    items = World.entities(context, @thread, "turn-item")
    assert [] = Enum.filter(items, &(&1["type"] == "command_execution"))

    assert [%{"type" => "dynamic_tool", "toolName" => "Monitor", "status" => "running"}] =
             Enum.filter(items, &(get_in(&1, ["nativeItemRef", "nativeId"]) == "mon-1"))

    # It stops being background work when Claude reports it ended.
    claude_says(context, %{
      "type" => "system",
      "subtype" => "task_notification",
      "task_id" => "task-mon-1",
      "tool_use_id" => "mon-1",
      "status" => "completed",
      "summary" => "Monitor ended"
    })

    World.await_row(World.thread_id(context, @thread), &(&1["pendingBackgroundTasks"] == []))
    context
  end

  # --- routers ---------------------------------------------------------------------------

  @router_model "anthropic/claude-sonnet-router"

  # The Claude instance's variables in settings: its own config directory, and the
  # router Claude Code is pointed at (the token is a secret of the instance).
  step "a Claude instance with its own config directory and a router's endpoint and token in its environment",
       context do
    context = World.fake_providers(context)
    config = Mc.tmp_dir(context.mc, "claude-router")

    context =
      write_settings(context, fn settings ->
        put_in(settings, [Access.key("providerInstances", %{}), "claudeAgent"], %{
          "driver" => "claudeAgent",
          "enabled" => true,
          "environment" => [
            %{"name" => "CLAUDE_CONFIG_DIR", "value" => config, "sensitive" => false},
            %{
              "name" => "ANTHROPIC_BASE_URL",
              "value" => "https://openrouter.test/api",
              "sensitive" => false
            },
            %{"name" => "ANTHROPIC_AUTH_TOKEN", "value" => "sk-or-secret", "sensitive" => true}
          ]
        })
      end)

    Map.put(context, :router_config, config)
  end

  step "the router's model id is added as a custom model", context do
    context =
      write_settings(context, fn settings ->
        put_in(settings, ["providerInstances", "claudeAgent", "config"], %{
          "customModels" => [@router_model]
        })
      end)

    {providers, context} = World.provider_list(context)
    assert @router_model in Enum.map(claude(providers)["models"], & &1["slug"])
    context
  end

  step "the user sends a message with that model", context do
    context =
      World.launch_on(context, @thread, "claudeAgent", "hello", %{"model" => @router_model})

    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "the turn runs through the router with that model", context do
    assert [%{"argv" => argv, "env" => env}] =
             Enum.filter(World.provider_log(context, "claude"), &Map.has_key?(&1, "argv"))

    assert ["--model", @router_model] in pairs(argv)

    assert env == %{
             "CLAUDE_CONFIG_DIR" => context.router_config,
             "ANTHROPIC_BASE_URL" => "https://openrouter.test/api",
             "ANTHROPIC_AUTH_TOKEN" => "sk-or-secret"
           }

    # The token is kept as a secret: the settings a client reads do not carry it.
    {%{"settings" => settings}, context} = World.call!(context, "hal-c2.readSettings")
    refute inspect(settings, limit: :infinity) =~ "sk-or-secret"
    assert "Hello from claude" in World.replies(context, @thread)
    context
  end

  # Writes the settings as a client does.
  defp write_settings(context, fun) do
    {%{"settings" => settings, "version" => version}, context} =
      World.call!(context, "hal-c2.readSettings")

    {_, context} =
      World.call!(context, "hal-c2.writeSettings", %{
        "settings" => fun.(settings),
        "version" => version
      })

    context
  end

  step "the thread is in plan mode on Claude", context do
    context |> World.fake_providers() |> Map.put(:interaction_mode, "plan")
  end

  step "Claude finishes planning", context do
    context =
      World.launch_on(context, @thread, "claudeAgent", "make a plan", %{
        "interactionMode" => context.interaction_mode
      })

    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "Claude asks the user a question", context do
    context =
      World.launch_on(context, @thread, "claudeAgent", "question first", %{
        "interactionMode" => context.interaction_mode
      })

    Map.put(context, :request, World.await_request(context, @thread))
  end

  step "the question is shown", context do
    assert %{"kind" => "user_input"} = context.request

    assert [%{"status" => "waiting", "questions" => [question]}] =
             for(
               i <- StreamState.list(World.stream(context, @thread), "turn-item"),
               i["type"] == "user_input_request",
               do: i
             )

    Map.put(context, :question, question)
  end

  # Claude plans from the answer, so there is no plan while the question waits.
  step "the plan stays pending until the user answers", context do
    assert [%{"status" => "running"}] = World.runs(context, @thread)
    assert StreamState.list(World.stream(context, @thread), "plan") == []

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "runtime-request.respond",
        "threadId" => World.thread_id(context, @thread),
        "requestId" => context.request["id"],
        "answers" => %{context.question["id"] => "Red"}
      })

    state = World.await_runs(context, @thread, ["completed"])

    assert [%{"kind" => "proposed_plan", "status" => "active", "markdown" => markdown}] =
             StreamState.list(state, "plan")

    assert markdown =~ "paint it Red"
    context
  end

  step "Claude asks the user a multiple choice question", context do
    context =
      context |> World.fake_providers() |> World.launch_on(@thread, "claudeAgent", "ask me")

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
      HalC2.Orchestration.dispatch(%{
        "type" => "runtime-request.respond",
        "threadId" => World.thread_id(context, @thread),
        "requestId" => context.request["id"],
        "answers" => %{context.question["id"] => "Red"}
      })

    World.await_runs(context, @thread, ["completed"])
    assert ~s(answered {"Which color?": "Red"}) in World.replies(context, @thread)
    context
  end

  step "a Claude thread whose history is close to the context limit", context do
    context = context |> World.providers() |> World.launch_on(@thread, "claudeAgent", "hello")
    World.await_runs(context, @thread, ["completed"])
    # Its Claude process is gone, so the next message resumes the conversation, and the
    # fake Claude then finds a "long session" long and old enough to ask about.
    :ok = HalC2.Orchestration.release_session(World.thread_id(context, @thread))
    context
  end

  step "the user resumes the Claude thread", context do
    context = World.send_turn(context, @thread, "long session")
    Map.put(context, :request, World.await_request(context, @thread))
  end

  step "the user can compact and continue, keep the full history, or never be asked again",
       context do
    assert ["--resume", "fake-session-1"] in pairs(List.last(World.claude_starts(context)))
    assert %{"kind" => "user_input"} = context.request

    assert [%{"status" => "waiting", "questions" => [question]}] =
             for(
               i <- StreamState.list(World.stream(context, @thread), "turn-item"),
               i["type"] == "user_input_request",
               do: i
             )

    assert question["question"] ==
             "This session is 2h 15m old and uses 182,400 tokens. Compact it before continuing?"

    choices = [
      {"Compact and continue", "compact"},
      {"Keep full history", "continue"},
      {"Don't ask again", "never"}
    ]

    assert Enum.map(question["options"], & &1["label"]) == Enum.map(choices, &elem(&1, 0))

    # Claude is told each choice; the fake answers with what it was told.
    Enum.reduce(choices, {context.request, ["completed"]}, fn {label, result}, {request, runs} ->
      {:ok, _} =
        HalC2.Orchestration.dispatch(%{
          "type" => "runtime-request.respond",
          "threadId" => World.thread_id(context, @thread),
          "requestId" => request["id"],
          "answers" => %{question["id"] => label}
        })

      runs = runs ++ ["completed"]
      World.await_runs(context, @thread, runs)
      assert "resume #{result}" in World.replies(context, @thread)

      if result != "never" do
        World.send_turn(context, @thread, "long session")
        {World.await_request(context, @thread), runs}
      end
    end)

    context
  end

  step "the project allows the HAL-C2 tools", context do
    context = World.fake_providers(context)
    Mc.ensure(HalC2.Mcp)

    refute HalC2.Settings.for_project(World.project(context).id)["enableAgentBrowserAccess"] ==
             false

    context
  end

  step "a Claude turn starts", context do
    context = World.launch_on(context, @thread, "claudeAgent", "hello")
    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "Claude can call the HAL-C2 tools for this thread", context do
    %{"argv" => argv} = World.await_provider_log(context, "claude", &Map.has_key?(&1, "argv"))
    config = argv |> Enum.drop_while(&(&1 != "--mcp-config")) |> Enum.at(1) |> JSON.decode!()
    %{"url" => url, "headers" => %{"Authorization" => auth}} = config["mcpServers"]["hal-c2"]
    assert url =~ ~r{^http://127\.0\.0\.1:\d+/mcp$}

    body =
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "hal_c2_thread_list", "arguments" => %{}}
      })

    # The tools find the calling thread through its sidebar row.
    :ok = HalC2.Shell.subscribe(self())
    World.await_row(World.thread_id(context, @thread), & &1)
    assert {200, %{"result" => %{"structuredContent" => listed}}} = HalC2.Mcp.handle(auth, body)
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
    context = World.post_message(context, @thread, "where are we")

    World.await_runs(context, @thread, ["completed", "rolled_back", "rolled_back", "completed"])
    assert "resumed at uuid-1 fork False history False" in World.replies(context, @thread)
    context
  end

  step "a new thread continues Claude's session from the second turn", context do
    assert {:ok, _} = context.reply
    context = World.post_message(context, "fork", "where are we")

    World.await_value(context, "fork", fn state ->
      match?(
        [_, _, %{"status" => "completed"}],
        state |> StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])
      )
    end)

    assert "resumed at uuid-2 fork True history False" in World.replies(context, "fork")
    context
  end

  step "Claude is picked for text generation", context do
    context = World.text_writers(context, [:claude])

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
    Mc.ensure(HalC2.ProviderUsageLimits)
    context = World.launch_on(context, @thread, "claudeAgent", "rate limit")
    World.await_runs(context, @thread, ["completed"])
    :sys.get_state(HalC2.ProviderUsageLimits)
    context
  end

  step "the limits view shows the new usage for that window", context do
    {providers, context} = World.provider_list(context)
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
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "threadId" => World.thread_id(context, @thread)
      })

    # An interrupted turn leaves no checkpoint, so the next turn is the one to revert to.
    World.await_runs(context, @thread, ["interrupted"])
    context = World.post_message(context, @thread, "hello")
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
    {providers, context} = World.provider_list(context)
    assert claude(providers)["enabled"] == (offered == "offered again")
    context
  end

  defp descriptor(model, id),
    do: Enum.find(get_in(model, ["capabilities", "optionDescriptors"]) || [], &(&1["id"] == id))

  defp pairs(argv), do: Enum.chunk_every(argv, 2, 1, :discard)

  defp settings(context) do
    [_, json] = Enum.find(pairs(context.argv), &match?(["--settings", _], &1))
    JSON.decode!(json)
  end

  defp claude(providers), do: Enum.find(providers, &(&1["instanceId"] == "claudeAgent"))

  # The npm registry's latest release, as the MC last read it.
  defp latest(context, driver, version) do
    :persistent_term.put(
      {HalC2.ProviderUpdates, driver},
      {version, System.monotonic_time(:millisecond)}
    )

    context
  end

  defp claude_manifest do
    Path.expand("../../../priv/model-manifest.json", __DIR__)
    |> File.read!()
    |> JSON.decode!()
    |> get_in(["providers", "claudeAgent"])
  end

  defp claude_says(context, message) do
    [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, World.thread_id(context, @thread))
    send(pid, {:claude, :sys.get_state(pid).session, {:message, message}})
  end
end
