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

  # --- too old for a model, compatibility, who updates it ----------------------------

  # The gated manifest model needing the lowest version above `version` (every gated
  # model when the version cannot be read): the one the upgrade message names.
  defp lowest_gated(version) do
    gated =
      for model <- claude_manifest()["models"],
          min = get_in(model, ["adapter", "claudeCode", "minVersion"]),
          is_binary(min),
          version == nil or Version.compare(version, min) == :lt,
          do: {min, model}

    gated
    |> Enum.sort_by(fn {min, _} -> Version.parse!(min) end, Version)
    |> List.first()
  end

  step ~r/^the installed Claude "(?<version>[^"]+)" is older than the version a model requires$/,
       %{args: [version]} = context do
    context = World.fake_providers(context, claude_version: version)
    assert {min, _model} = lowest_gated(version)
    Map.merge(context, %{gated_min: min, gated_from: version})
  end

  step "the installed Claude does not report its version", context do
    context = World.fake_providers(context, claude_version: "not-a-version")
    assert {min, _model} = lowest_gated(nil)
    Map.merge(context, %{gated_min: min, gated_from: nil})
  end

  step "Claude shows {string} that model", %{args: [prefix]} = context do
    {_min, model} = lowest_gated(context.gated_from)

    assert claude(context.providers)["message"] ==
             "#{prefix} #{model["name"]}. " <>
               "Upgrade to v#{context.gated_min} or newer to access it."

    context
  end

  step "Claude shows {string} the model needing the lowest version",
       %{args: [prefix]} = context do
    {_min, model} = lowest_gated(context.gated_from)
    assert claude(context.providers)["message"] =~ "#{prefix} #{model["name"]}."
    context
  end

  step "is told to upgrade to the version the model requires or newer", context do
    assert claude(context.providers)["message"] =~
             "Upgrade to v#{context.gated_min} or newer to access it."

    context
  end

  step "is told to upgrade to that version or newer", context do
    assert claude(context.providers)["message"] =~
             "Upgrade to v#{context.gated_min} or newer to access it."

    context
  end

  step "Claude Code version {string} is installed", %{args: [version]} = context do
    World.fake_providers(context, claude_version: version)
  end

  step "the MC checks Claude Code", context do
    {providers, context} = World.provider_list(context)
    Map.put(context, :providers, providers)
  end

  step "Claude Code is reported as {string} for this HAL-C2 release",
       %{args: [status]} = context do
    assert %{"status" => ^status} = claude(context.providers)["compatibilityAdvisory"]
    context
  end

  # A fake `claude` where an installer would put it, in a home of its own. It answers
  # `--version` and treats every other call (including `update`) as done.
  defp claude_at(context, home, relative) do
    path = Path.join(home, relative)
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    #!/bin/sh
    if [ "$1" = "--version" ]; then echo "2.1.0 (Claude Code)"; exit 0; fi
    if [ "$1" = "update" ]; then exit 0; fi
    exec python3 -u #{Path.expand("../../support/fake_claude.py", __DIR__)} "$@"
    """)

    File.chmod!(path, 0o755)
    World.put_os_env("HOME", home)
    World.put_app_env(:claude_command, [path])
    World.reset_provider_caches()
    Map.put(context, :claude_home, home)
  end

  step "the claude command lives in {string} of the user's home",
       %{args: [folder]} = context do
    context = World.fake_providers(context)
    home = Mc.tmp_dir(context.mc, "claude-home")
    claude_at(context, home, Path.join(folder, "claude"))
  end

  step "the claude command lives under {string} of the user's home",
       %{args: [folder]} = context do
    context = World.fake_providers(context)
    home = Mc.tmp_dir(context.mc, "claude-home")
    claude_at(context, home, Path.join([folder, "versions", "2.1.0", "claude"]))
  end

  step "the claude command lives in an npm global install", context do
    context = World.fake_providers(context)
    home = Mc.tmp_dir(context.mc, "claude-npm-home")
    prefix = Path.join(home, "npm")
    # npm itself is a fake in the prefix, so looking at the update runs nothing real.
    File.mkdir_p!(Path.join(prefix, "bin"))
    npm = Path.join([prefix, "bin", "npm"])
    File.write!(npm, "#!/bin/sh\nexit 0\n")
    File.chmod!(npm, 0o755)

    claude_at(
      context,
      home,
      Path.join(["npm", "lib", "node_modules", "@anthropic-ai", "claude-code", "cli.js"])
    )
  end

  # "the user opens Claude's update details" is the ProviderSetup steps'; it leaves
  # the entry at `context.claude`.
  step "the update command is Claude's own {string}", %{args: [command]} = context do
    assert context.claude["versionAdvisory"]["updateCommand"] =~ ~r{/claude update$}
    assert command == "claude update"
    context
  end

  step "the update command is npm installing {string}", %{args: [package]} = context do
    assert context.claude["versionAdvisory"]["updateCommand"] =~ "npm install -g --prefix"
    assert context.claude["versionAdvisory"]["updateCommand"] =~ package
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

  # Models as Claude Code 2.1.293 lists them at `initialize`: a `default` row naming the
  # model it resolves to, aliases with their canonical ids, a model the manifest does
  # not know (Sonnet 5.5), and one it gates on a newer Claude Code than the fake's 2.1.0
  # (Opus 5.5).
  @listed [
    %{
      "value" => "default",
      "resolvedModel" => "claude-opus-5-5",
      "displayName" => "Default (recommended)",
      "description" => "Opus 5.5 · Best for everyday, complex tasks",
      "supportsEffort" => true,
      "supportedEffortLevels" => ~w(low medium high xhigh max),
      "supportsAdaptiveThinking" => true,
      "supportsFastMode" => true,
      "supportsAutoMode" => true
    },
    %{
      "value" => "opus",
      "resolvedModel" => "claude-opus-5-5",
      "displayName" => "Opus 5.5",
      "description" => "For complex work and everyday tasks",
      "supportsEffort" => true,
      "supportedEffortLevels" => ~w(low medium high xhigh max),
      "supportsAdaptiveThinking" => true,
      "supportsFastMode" => true,
      "supportsAutoMode" => true
    },
    %{
      "value" => "sonnet",
      "resolvedModel" => "claude-sonnet-5-5",
      "displayName" => "Sonnet 5.5",
      "description" => "Most efficient for simpler tasks",
      "supportsEffort" => true,
      "supportedEffortLevels" => ~w(low medium high xhigh max),
      "supportsAdaptiveThinking" => true,
      "supportsAutoMode" => true
    },
    %{
      "value" => "claude-sonnet-4-6",
      "resolvedModel" => "claude-sonnet-4-6",
      "displayName" => "Sonnet 4.6",
      "description" => "Efficient for routine tasks",
      "supportsEffort" => true,
      "supportedEffortLevels" => ~w(low medium high max),
      "supportsAdaptiveThinking" => true,
      "supportsAutoMode" => true
    }
  ]

  step "the installed Claude lists its models", context do
    context = World.fake_providers(context)
    System.put_env("FAKE_CLAUDE_MODELS", JSON.encode!(@listed))
    context
  end

  step "the installed Claude does not list its models", context do
    # The fake answers `initialize` without models, as a Claude Code too old to list them.
    World.fake_providers(context)
  end

  step "the MC has read the Claude model list", context do
    :ok = HalC2.Claude.Provider.load()
    {providers, context} = World.provider_list(context)
    Map.put(context, :models, claude(providers)["models"])
  end

  step "Claude Code's models are offered in its order with its default marked", context do
    # The `default` row is the model it resolves to, marked as the default.
    assert [
             %{"slug" => "opus", "name" => "Opus 5.5", "isDefault" => true},
             %{"slug" => "sonnet", "name" => "Sonnet 5.5", "isDefault" => false},
             %{"slug" => "claude-sonnet-4-6", "name" => "Sonnet 4.6", "isDefault" => false}
           ] = context.models

    context
  end

  step "a thread saved on a model's full id shows the model that covers it", context do
    assert ["claude-opus-5-5", "default"] == listed_model(context, "opus")["aliases"]
    assert ["claude-sonnet-5-5"] == listed_model(context, "sonnet")["aliases"]
    context
  end

  step "a listed model the manifest knows offers Claude Code's reasoning levels and ultrathink",
       context do
    # Sonnet 4.6's manifest profile runs "max" as "high"; this Claude Code runs it itself.
    assert ~w(low medium high max ultrathink) ==
             choices(listed_model(context, "claude-sonnet-4-6"), "effort")

    assert ~w(low medium high xhigh max ultracode ultrathink) ==
             choices(listed_model(context, "opus"), "effort")

    assert descriptor(listed_model(context, "opus"), "fastMode")
    assert descriptor(listed_model(context, "opus"), "contextWindow")
    context
  end

  step "a listed model the manifest does not know offers only Claude Code's reasoning levels",
       context do
    model = listed_model(context, "sonnet")
    assert ~w(low medium high xhigh max) == choices(model, "effort")
    assert [%{"id" => "effort"}] = model["capabilities"]["optionDescriptors"]
    context
  end

  step "the installed Claude lists a model the manifest gates on a newer version", context do
    context = World.fake_providers(context)
    System.put_env("FAKE_CLAUDE_MODELS", JSON.encode!(@listed))
    min = Enum.find(claude_manifest()["models"], &(&1["slug"] == "claude-opus-5-5"))
    assert Version.compare("2.1.0", min["adapter"]["claudeCode"]["minVersion"]) == :lt
    :ok = HalC2.Claude.Provider.load()
    Map.put(context, :gated, "claude-opus-5-5")
  end

  step "the user sends a message to Claude on that model", context do
    context =
      World.launch_on(context, @thread, "claudeAgent", "hello", %{"model" => context.gated})

    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "Claude answers it on that model", context do
    # The turn's start, after the one that read the model list.
    argv = List.last(for %{"argv" => argv} <- World.provider_log(context, "claude"), do: argv)
    assert Enum.any?(pairs(argv), &match?(["--model", "claude-opus-5-5" <> _], &1))
    assert "--strict-mcp-config" not in argv
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
    fields =
      case context[:model_selection] do
        nil -> %{}
        selection -> %{"modelSelection" => selection}
      end

    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "claudeAgent", "hello", fields)

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

  step "the timeline shows that run began with Claude's background work, not a message someone sent",
       context do
    state = World.stream(context, @thread)
    run = state |> StreamState.list("run") |> Enum.max_by(& &1["ordinal"])
    run_id = run["id"]

    assert %{
             "type" => "notification",
             "runId" => ^run_id,
             "source" => %{"kind" => "background_task"},
             "outcome" => "updated",
             "summary" => "Background activity updated"
           } =
             item = StreamState.get(state, "turn-item")["turn-item:user:#{run["userMessageId"]}"]

    refute Map.has_key?(item, "text")

    assert [] ==
             for(
               %{"type" => "user_message", "createdBy" => "agent"} = item <-
                 StreamState.list(state, "turn-item"),
               do: item
             )

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

  step "the user sends another message and its turn is running", context do
    # The monitor is background work before the next message lands.
    World.await_row(
      World.thread_id(context, @thread),
      &match?(
        [%{"taskId" => "mon-1", "taskType" => "dynamic_tool", "description" => "Monitor"}],
        &1["pendingBackgroundTasks"]
      )
    )

    context = World.send_turn(context, @thread, "wait for me")
    World.await_running(context, @thread)
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

  # --- a resumed subagent ----------------------------------------------------------------

  # The subagent of the fake's "in the background" turn finished; then the runtime that
  # knew it is gone, as after a restart of the MC, and in the next turn Claude sends
  # the subagent (its task id) another message.
  step "Claude resumed a subagent after the MC restarted", context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "claudeAgent", "survey in the background")

    World.await_runs(context, @thread, ["completed"])
    task = %{"type" => "system", "task_id" => "task-agent-1", "tool_use_id" => "agent-1"}

    claude_says(
      context,
      Map.merge(task, %{
        "subtype" => "task_notification",
        "status" => "completed",
        "summary" => "lib has three modules"
      })
    )

    World.await_value(context, @thread, fn state ->
      Enum.any?(StreamState.list(state, "subagent"), &(&1["status"] == "completed"))
    end)

    [{runtime, _}] = Registry.lookup(HalC2.Claude.Registry, World.thread_id(context, @thread))
    ref = Process.monitor(runtime)
    Process.exit(runtime, :kill)
    assert_receive {:DOWN, ^ref, :process, _, _}, 5_000

    context = World.post_message(context, @thread, "wait and resume it")
    World.await_running(context, @thread)

    World.await_provider_log(
      context,
      "claude",
      &(get_in(&1, ["in", "message", "content"]) == "wait and resume it")
    )

    claude_says(context, %{
      "type" => "assistant",
      "message" => %{
        "id" => "m-send",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "send-1",
            "name" => "SendMessage",
            "input" => %{"to" => "task-agent-1", "message" => "Also check the tests"}
          }
        ]
      }
    })

    claude_says(context, %{
      "type" => "system",
      "subtype" => "task_started",
      "task_id" => "task-agent-1",
      "tool_use_id" => "send-1",
      "description" => "Survey the repo",
      "task_type" => "local_agent",
      "is_backgrounded" => true
    })

    claude_says(context, %{
      "type" => "user",
      "message" => %{
        "role" => "user",
        "content" => [
          %{"type" => "tool_result", "tool_use_id" => "send-1", "content" => "Message delivered"}
        ]
      }
    })

    claude_says(context, %{
      "type" => "system",
      "subtype" => "task_notification",
      "task_id" => "task-agent-1",
      "tool_use_id" => "send-1",
      "status" => "completed",
      "summary" => "The tests pass"
    })

    claude_says(context, %{"type" => "result", "subtype" => "success"})
    World.await_runs(context, @thread, ["completed", "completed"])
    context
  end

  step "the user opens the subagent's thread", context do
    state = World.stream(context, @thread)
    # Still the one subagent, and its one thread.
    assert [%{"status" => "completed", "result" => "The tests pass"} = subagent] =
             StreamState.list(state, "subagent")

    child = HalC2.Streams.Server.state(HalC2.Streams.ensure(subagent["childThreadId"]))

    messages =
      child
      |> StreamState.list("turn-item")
      |> Enum.filter(&(&1["type"] in ["user_message", "assistant_message"]))
      |> Enum.sort_by(& &1["ordinal"])
      |> Enum.map(&{&1["type"], &1["text"]})

    Map.put(context, :child_messages, messages)
  end

  step "the thread shows the message that resumed it", context do
    assert [
             {"user_message", "List what is in the repo"},
             {"assistant_message", "lib has three modules"},
             {"user_message", "Also check the tests"},
             {"assistant_message", "The tests pass"}
           ] = context.child_messages

    context
  end

  step "the parent thread does not", context do
    state = World.stream(context, @thread)

    refute Enum.any?(
             StreamState.list(state, "message"),
             &((&1["text"] || "") =~ "Also check the tests")
           )

    refute Enum.any?(
             StreamState.list(state, "turn-item"),
             &(inspect(&1, limit: :infinity) =~ "Also check the tests")
           )

    # The message is not a tool call of the parent's either.
    refute Enum.any?(StreamState.list(state, "turn-item"), &(&1["toolName"] == "SendMessage"))
    context
  end

  # --- several accounts ------------------------------------------------------------------

  @work "claude-work"

  # The built-in instance keeps the MC's own Claude config directory; the second
  # instance names another in its variables.
  step "the user adds a second Claude instance with its own config directory", context do
    context = World.fake_providers(context)
    personal = Mc.tmp_dir(context.mc, "claude-personal")
    work = Mc.tmp_dir(context.mc, "claude-work")
    World.put_os_env("CLAUDE_CONFIG_DIR", personal)
    World.put_os_env("FAKE_SESSIONS", "1")

    context =
      write_settings(context, fn settings ->
        put_in(settings, [Access.key("providerInstances", %{}), @work], %{
          "driver" => "claudeAgent",
          "enabled" => true,
          "displayName" => "Claude (work)",
          "environment" => [
            %{"name" => "CLAUDE_CONFIG_DIR", "value" => work, "sensitive" => false}
          ]
        })
      end)

    {providers, context} = World.provider_list(context)
    assert %{"driver" => "claudeAgent"} = Enum.find(providers, &(&1["instanceId"] == @work))
    assert claude(providers)
    Map.merge(context, %{claude_dirs: %{"claudeAgent" => personal, @work => work}})
  end

  # `claude auth login` with that directory leaves the login in it.
  step "the user signs in to the CLI with that config directory", context do
    File.write!(
      Path.join(context.claude_dirs[@work], ".claude.json"),
      JSON.encode!(%{"oauthAccount" => %{"emailAddress" => "work@example.com"}})
    )

    context
  end

  step "each instance uses its own account and history", context do
    context = World.launch_on(context, "Personal", "claudeAgent", "hello from home")
    World.await_runs(context, "Personal", ["completed"])
    context = World.launch_on(context, "Work", @work, "hello from work")
    World.await_runs(context, "Work", ["completed"])

    starts =
      for %{"argv" => _, "account" => account, "env" => env} <-
            World.provider_log(context, "claude"),
          do: {env["CLAUDE_CONFIG_DIR"], account}

    assert {context.claude_dirs["claudeAgent"], "me@example.com"} in starts
    assert {context.claude_dirs[@work], "work@example.com"} in starts

    # Each conversation is kept under its own instance's directory only.
    history = fn instance ->
      Path.join(context.claude_dirs[instance], "projects/*/*.jsonl")
      |> Path.wildcard()
      |> Enum.map_join(&File.read!/1)
    end

    assert history.("claudeAgent") =~ "hello from home"
    refute history.("claudeAgent") =~ "hello from work"
    assert history.(@work) =~ "hello from work"
    refute history.(@work) =~ "hello from home"
    context
  end

  # --- one quota per account -----------------------------------------------------------

  step "both Claude instances' usage has been checked", context do
    Mc.ensure(HalC2.ProviderUsageLimits)
    :ok = HalC2.ProviderUsageLimits.refresh(["claudeAgent", @work])
    # The account arrives as a cast the probe sent; this call lands after it.
    :sys.get_state(HalC2.ProviderUsageLimits)
    {providers, context} = World.provider_list(context)
    Map.put(context, :providers, providers)
  end

  step "a turn on the second Claude instance reports its usage", context do
    context = World.launch_on(context, "Work", @work, "rate limit")
    World.await_runs(context, "Work", ["completed"])
    # The turn's update is a cast; this call lands after it.
    :sys.get_state(HalC2.ProviderUsageLimits)
    context
  end

  step "each Claude account keeps its own usage limits", context do
    me = HalC2.ProviderUsageLimits.get("claudeAgent")
    work = HalC2.ProviderUsageLimits.get(@work)

    assert %{"usedPercent" => used} = Enum.find(me["windows"], &(&1["id"] == "five_hour"))
    assert round(used) == 30
    assert %{"usedPercent" => used} = Enum.find(work["windows"], &(&1["id"] == "five_hour"))
    assert round(used) == 91
    context
  end

  # --- the fetched manifest --------------------------------------------------------------

  @new_model "claude-nova-9"

  # The manifest the MC fetches (a file here, where it would be a URL) gains a model,
  # edited after this release was cut.
  step "the model manifest lists a new Claude model", context do
    context = World.fake_providers(context, claude_version: "999.0.0")
    bundled = HalC2.ModelManifest.bundled()
    catalog = bundled["providers"]["claudeAgent"]

    nova =
      hd(catalog["models"])
      |> Map.take(["profile"])
      |> Map.merge(%{"slug" => @new_model, "name" => "Claude Nova 9", "status" => "current"})

    published =
      bundled
      |> Map.put("updatedAt", "2099-01-01T00:00:00Z")
      |> put_in(["providers", "claudeAgent", "models"], catalog["models"] ++ [nova])
      |> update_in(["currentModels", "claudeAgent"], &((&1 || []) ++ [@new_model]))

    file = Path.join(context.mc.home, "published-models.json")
    File.write!(file, JSON.encode!(published))
    World.put_app_env(:model_manifest_url, file)
    HalC2.ModelManifest.forget()
    ExUnit.Callbacks.on_exit(&HalC2.ModelManifest.forget/0)

    # Until the MC refreshes, Claude's models are the release's own.
    {providers, context} = World.provider_list(context)
    refute @new_model in Enum.map(claude(providers)["models"], & &1["slug"])
    context
  end

  step "the new model is offered after the next refresh", context do
    {_, context} = World.call!(context, "server.refreshProviders", %{})
    {providers, context} = World.provider_list(context)
    models = claude(providers)["models"]

    assert %{"name" => "Claude Nova 9", "isCustom" => false} =
             Enum.find(models, &(&1["slug"] == @new_model))

    # It joins the release's models, which are all still offered.
    assert length(models) ==
             length(HalC2.ModelManifest.bundled()["providers"]["claudeAgent"]["models"]) + 1

    context
  end

  # --- compaction ------------------------------------------------------------------------

  defp compactions(context),
    do: Enum.filter(World.entities(context, @thread, "turn-item"), &(&1["type"] == "compaction"))

  # The newest usage any of the thread's provider turns reported: what the meter shows.
  defp context_usage(context) do
    World.entities(context, @thread, "provider-turn")
    |> Enum.filter(& &1["tokenUsage"])
    |> Enum.max_by(& &1["tokenUsage"]["updatedAt"], fn -> %{} end)
    |> Map.get("tokenUsage")
  end

  step "the Claude instance compacts after 200000 tokens", context do
    context
    |> World.fake_providers()
    |> World.put_settings(%{
      "providers" => %{"claudeAgent" => %{"autoCompactWindow" => "200000"}}
    })
  end

  step "the conversation grows past that size", context do
    context = World.launch_on(context, @thread, "claudeAgent", "grow the conversation")
    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "Claude compacts the conversation and the timeline says so", context do
    # Claude was told the size to compact at.
    assert [%{"argv" => argv}] =
             Enum.filter(World.provider_log(context, "claude"), &Map.has_key?(&1, "argv"))

    assert [settings] = for(["--settings", json] <- pairs(argv), do: JSON.decode!(json))
    assert settings["autoCompactWindow"] == 200_000

    assert [
             %{
               "title" => "Context compacted",
               "status" => "completed",
               "beforeTokenCount" => 205_000,
               "afterTokenCount" => 42_000
             }
           ] = compactions(context)

    context
  end

  step "Claude compacted the conversation of a thread", context do
    context =
      context
      |> World.fake_providers()
      |> World.put_settings(%{
        "providers" => %{"claudeAgent" => %{"autoCompactWindow" => "200000"}}
      })
      |> World.launch_on(@thread, "claudeAgent", "grow the conversation")

    World.await_runs(context, @thread, ["completed"])
    assert [_] = compactions(context)
    assert %{"usedTokens" => 42_000} = context_usage(context)
    context
  end

  step "the user sends the next message", context do
    context = World.post_message(context, @thread, "hello")

    World.await_value(context, @thread, fn state ->
      runs = StreamState.list(state, "run")
      length(runs) == 2 and Enum.all?(runs, &(&1["status"] in ["completed", "failed"]))
    end)

    context
  end

  # The same Claude session takes the message: nothing is started again, or resumed
  # from before the compaction.
  step "Claude continues from the compacted conversation", context do
    log = World.provider_log(context, "claude")
    assert [%{"argv" => argv}] = Enum.filter(log, &Map.has_key?(&1, "argv"))
    refute "--resume" in argv
    refute Enum.any?(argv, &String.starts_with?(&1, "--resume-session-at"))

    assert ["grow the conversation", "hello"] =
             for(
               %{"in" => %{"type" => "user", "message" => %{"content" => text}}} <- log,
               do: text
             )

    assert "Hello from claude" in World.replies(context, @thread)
    assert [_] = compactions(context)
    context
  end

  step "the context meter keeps the usage Claude reported after compaction", context do
    assert %{"usedTokens" => 42_000} = context_usage(context)
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
             "HOME" => System.user_home!(),
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

  step "the project turns the HAL-C2 tools off", context do
    context = World.fake_providers(context)
    Mc.ensure(HalC2.Mcp)
    id = World.project(context).id

    context =
      World.update_settings(context, %{
        "projectSettingsOverrides" => %{id => %{"enableAgentBrowserAccess" => false}}
      })

    assert HalC2.Settings.for_project(id)["enableAgentBrowserAccess"] == false
    context
  end

  step "Claude is started with no tools disallowed", context do
    %{"argv" => argv} = World.await_provider_log(context, "claude", &Map.has_key?(&1, "argv"))
    refute "--disallowedTools" in argv
    context
  end

  step "Claude is started with its {string} and {string} tools disallowed",
       %{args: [first, second]} = context do
    %{"argv" => argv} = World.await_provider_log(context, "claude", &Map.has_key?(&1, "argv"))

    assert ["--disallowedTools", "#{first},#{second}"] ==
             Enum.slice(argv, Enum.find_index(argv, &(&1 == "--disallowedTools")), 2)

    context
  end

  step "Claude is told to delegate with {string}", %{args: [tool]} = context do
    %{"argv" => argv} = World.await_provider_log(context, "claude", &Map.has_key?(&1, "argv"))
    prompt = Enum.at(argv, Enum.find_index(argv, &(&1 == "--append-system-prompt")) + 1)
    # The orchestration instructions and the workers-only note, with the
    # browser and runtime sections of `HalC2.Mcp.Instructions` between them.
    assert prompt =~ HalC2.Mcp.instructions()
    assert prompt =~ HalC2.Mcp.workers_only_note()
    assert prompt =~ "Delegate child work with `#{tool}`"
    context
  end

  # Created first, so the thread's sidebar row (which names its project) is in place
  # when the turn starts.
  step "a Claude turn starts in a thread that already exists", context do
    selection = %{"instanceId" => "claudeAgent", "model" => "sonnet"}
    context = World.create_thread(context, @thread, nil, %{"modelSelection" => selection})
    :ok = HalC2.Streams.subscribe(World.thread_id(context, @thread), self(), nil)
    {{:ok, _}, context} = World.send_message(context, @thread, "hello")
    World.await_runs(context, @thread, ["completed"])
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

  defp listed_model(context, slug), do: Enum.find(context.models, &(&1["slug"] == slug))

  defp choices(model, id), do: Enum.map(descriptor(model, id)["options"], & &1["id"])

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

  # --- a subagent's own messages ----------------------------------------------------------

  # The fake's "subagent works on: TASK" turn runs a subagent in the turn. Under its tool
  # call the subagent streams and says "Running the tests", runs `mix test`, writes a task
  # list, and answers "The tests pass".
  step "Claude's task list is shown in the thread", context do
    context =
      context |> World.fake_providers() |> World.launch_on(@thread, "claudeAgent", "todo")

    World.await_runs(context, @thread, ["completed"])

    assert [%{"steps" => [_, _]}] =
             plans = StreamState.list(World.stream(context, @thread), "plan")

    Map.put(context, :plans, plans)
  end

  step "a subagent writes a task list of its own", context do
    context = World.post_message(context, @thread, "subagent works on: Check the tests")
    World.await_runs(context, @thread, ["completed", "completed"])
    context
  end

  step "the thread's task list is unchanged", context do
    assert StreamState.list(World.stream(context, @thread), "plan") == context.plans
    context
  end

  step "Claude starts a subagent with the task {string}", %{args: [task]} = context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "claudeAgent", "subagent works on: #{task}")

    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "the subagent's thread starts with {string} as its first message",
       %{args: [task]} = context do
    assert [{"user_message", ^task} | _] = child_messages(context)
    context
  end

  step "the tools the subagent uses appear in the subagent's thread", context do
    items = context |> subagent_child() |> StreamState.list("turn-item")

    assert %{"type" => "command_execution", "status" => "completed"} =
             item = Enum.find(items, &(&1["input"] == "mix test"))

    assert item["output"] == "12 tests, 0 failures"
    assert Enum.any?(items, &(&1["type"] == "dynamic_tool" and &1["toolName"] == "TodoWrite"))

    assert [
             {"user_message", "Check the tests"},
             {"assistant_message", "Running the tests"},
             {"assistant_message", "The tests pass"}
           ] = child_messages(context)

    context
  end

  step "the subagent's own messages do not appear in the parent thread", context do
    state = World.stream(context, @thread)
    items = StreamState.list(state, "turn-item")

    assert ["The subagent says the tests pass"] =
             for(%{"type" => "assistant_message"} = item <- items, do: item["text"])

    assert [] = Enum.filter(items, &(&1["type"] in ["command_execution", "reasoning"]))
    assert [] = StreamState.list(state, "plan")

    assert [%{"status" => "completed", "result" => "The tests pass"}] =
             StreamState.list(state, "subagent")

    context
  end

  # The fake's "in the background" turn leaves its subagent (tool use agent-1, task
  # task-agent-1) running after the turn.
  step "Claude has a subagent running", context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "claudeAgent", "survey in the background")

    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "Claude reports the subagent's progress", context do
    claude_says(context, %{
      "type" => "system",
      "subtype" => "task_progress",
      "task_id" => "task-agent-1",
      "tool_use_id" => "agent-1",
      "summary" => "Reading lib"
    })

    context
  end

  step "the subagent's thread shows the progress as the subagent's thinking", context do
    World.await_value(context, @thread, fn state ->
      match?([%{"progress" => "Reading lib"}], StreamState.list(state, "subagent"))
    end)

    assert [%{"type" => "reasoning", "text" => "Reading lib", "status" => "running"}] =
             context
             |> subagent_child()
             |> StreamState.list("turn-item")
             |> Enum.filter(&(&1["type"] == "reasoning"))

    context
  end

  step "the subagent's result is shown as its answer when it finishes", context do
    claude_says(context, %{
      "type" => "system",
      "subtype" => "task_notification",
      "task_id" => "task-agent-1",
      "tool_use_id" => "agent-1",
      "status" => "completed",
      "summary" => "lib has three modules"
    })

    World.await_value(context, @thread, fn state ->
      match?([%{"status" => "completed"}], StreamState.list(state, "subagent"))
    end)

    assert {"assistant_message", "lib has three modules"} = List.last(child_messages(context))

    assert [%{"type" => "reasoning", "status" => "completed"}] =
             context
             |> subagent_child()
             |> StreamState.list("turn-item")
             |> Enum.filter(&(&1["type"] == "reasoning"))

    context
  end

  # The thread of the one subagent in the thread.
  defp subagent_child(context) do
    [subagent] = StreamState.list(World.stream(context, @thread), "subagent")
    HalC2.Streams.Server.state(HalC2.Streams.ensure(subagent["childThreadId"]))
  end

  defp child_messages(context) do
    context
    |> subagent_child()
    |> StreamState.list("turn-item")
    |> Enum.filter(&(&1["type"] in ["user_message", "assistant_message"]))
    |> Enum.sort_by(& &1["ordinal"])
    |> Enum.map(&{&1["type"], &1["text"]})
  end

  # --- turn endings --------------------------------------------------------------------

  # A turn the fake holds open ("wait"), which the steps then end by having Claude
  # say the `result` (or other frames) the scenario is about.
  defp running_turn(context) do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "claudeAgent", "wait for me")

    World.await_running(context, @thread)
    World.await_provider_log(context, "claude", &(get_in(&1, ["in", "type"]) == "user"))
    Map.put(context, :thread, @thread)
  end

  defp api_error_turn(context, status) do
    context = running_turn(context)
    text = "API Error: #{status} from the provider"

    message = %{
      "type" => "assistant",
      "message" => %{
        "id" => "m-api-error",
        "content" => [%{"type" => "text", "text" => text}]
      }
    }

    message =
      if status == 401, do: Map.put(message, "error", "authentication_failed"), else: message

    claude_says(context, message)

    claude_says(context, %{
      "type" => "result",
      "subtype" => "success",
      "is_error" => true,
      "api_error_status" => status,
      "terminal_reason" => "completed",
      "result" => text
    })

    Map.put(context, :error_text, text)
  end

  step ~r/^Claude ends a turn reporting the API error (?<status>\d+) as its result$/,
       %{args: [status]} = context do
    api_error_turn(context, String.to_integer(status))
  end

  step "the last Claude turn of a thread failed with an API error", context do
    context = api_error_turn(context, 529)
    World.await_runs(context, @thread, ["failed"])
    context
  end

  step "the run fails instead of completing", context do
    World.await_runs(context, @thread, ["failed"])
    context
  end

  step "the failure carries the code {string} and is a provider error",
       %{args: [code]} = context do
    items = StreamState.list(World.stream(context, @thread), "turn-item")

    assert %{"failure" => %{"class" => "provider_error", "code" => ^code}} =
             Enum.find(items, &(&1["type"] == "error"))

    context
  end

  step "the error text appears once in the thread", context do
    messages = StreamState.list(World.stream(context, @thread), "message")

    assert 1 ==
             Enum.count(
               messages,
               &(&1["role"] == "assistant" and (&1["text"] || "") =~ context.error_text)
             )

    context
  end

  step "Claude answers it in the same session", context do
    assert "Hello from claude" in World.replies(context, @thread)
    # The same CLI process took the message: it was started once.
    assert [_] = for(%{"argv" => argv} <- World.provider_log(context, "claude"), do: argv)
    context
  end

  step "the new run completes", context do
    assert ["failed", "completed"] =
             context |> World.runs(@thread) |> Enum.map(& &1["status"])

    context
  end

  @give_up %{
    "it kept getting API errors" => %{"terminal_reason" => "api_error"},
    "its tool calls kept coming out malformed" => %{
      "terminal_reason" => "malformed_tool_use_exhausted"
    },
    "the turn's token budget ran out" => %{"terminal_reason" => "budget_exhausted"},
    "it could not produce the structured output" => %{
      "terminal_reason" => "structured_output_retry_exhausted"
    },
    "a deferred tool is no longer available" => %{
      "terminal_reason" => "tool_deferred_unavailable"
    },
    "the turn could not be set up" => %{"terminal_reason" => "turn_setup_failed"},
    "a usage limit blocked the request" => %{"terminal_reason" => "blocking_limit"},
    "the context refilled straight after compaction" => %{
      "terminal_reason" => "rapid_refill_breaker"
    },
    "the prompt is larger than the context window" => %{"terminal_reason" => "prompt_too_long"},
    "an image could not be processed" => %{"terminal_reason" => "image_error"},
    "the model returned an error" => %{"terminal_reason" => "model_error"},
    "the API was overloaded" => %{"api_error_status" => 529},
    "the API rate limit was reached" => %{"api_error_status" => 429}
  }

  step ~r/^Claude ends a turn because (?<reason>.+)$/, %{args: [reason]} = context do
    context = running_turn(context)

    result =
      Map.merge(
        %{"type" => "result", "subtype" => "success", "is_error" => false},
        @give_up[reason]
      )

    claude_says(context, result)
    context
  end

  step "Claude ends a turn with an error and a diagnostic record of its own", context do
    context = running_turn(context)

    claude_says(context, %{
      "type" => "result",
      "subtype" => "error_during_execution",
      "is_error" => true,
      "errors" => ["[ede_diagnostic] heap=42 frames=17", "The model exploded"]
    })

    World.await_runs(context, @thread, ["failed"])
    context
  end

  step "the failure shows the error", context do
    items = StreamState.list(World.stream(context, @thread), "turn-item")

    assert %{"failure" => %{"message" => "The model exploded"}} =
             Enum.find(items, &(&1["type"] == "error"))

    context
  end

  step "the diagnostic record is not shown", context do
    state = World.stream(context, @thread)

    for kind <- ["turn-item", "message"] do
      refute inspect(StreamState.list(state, kind), limit: :infinity) =~ "ede_diagnostic"
    end

    context
  end

  step "Claude ends a turn with a result but without writing an answer", context do
    context = running_turn(context)

    claude_says(context, %{
      "type" => "result",
      "subtype" => "success",
      "is_error" => false,
      "result" => "The answer is 42"
    })

    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "the result's text is shown as Claude's answer", context do
    assert "The answer is 42" in World.replies(context, @thread)
    context
  end

  step "Claude says it fell back to another model after a refusal", context do
    claude_says(context, %{
      "type" => "system",
      "subtype" => "model_refusal_fallback",
      "uuid" => "fallback-1",
      "trigger" => "refusal",
      "direction" => "retry",
      "original_model" => "claude-fable-5",
      "fallback_model" => "claude-opus-4-8",
      "content" => "Safeguards flagged this message. Switched to Opus 4.8."
    })

    context
  end

  step "the thread shows Claude's notice", context do
    World.await_value(context, @thread, fn state ->
      Enum.any?(
        StreamState.list(state, "turn-item"),
        &(&1["type"] == "system_notice" and
            &1["message"] == "Safeguards flagged this message. Switched to Opus 4.8.")
      )
    end)

    context
  end

  step "the turn carries on", context do
    assert [%{"status" => "running"}] = World.runs(context, @thread)

    claude_says(context, %{
      "type" => "assistant",
      "message" => %{
        "id" => "m-after-fallback",
        "content" => [%{"type" => "text", "text" => "Carrying on"}]
      }
    })

    claude_says(context, %{"type" => "result", "subtype" => "success", "is_error" => false})
    World.await_runs(context, @thread, ["completed"])
    assert "Carrying on" in World.replies(context, @thread)
    context
  end

  step "Claude retries a failed API request", context do
    claude_says(context, %{
      "type" => "system",
      "subtype" => "api_retry",
      "uuid" => "retry-1",
      "attempt" => 1,
      "max_retries" => 5,
      "retry_delay_ms" => 2000,
      "error_status" => 529,
      "error" => "overloaded"
    })

    context
  end

  defp retry_items(state),
    do: for(%{"retry" => %{}} = item <- StreamState.list(state, "turn-item"), do: item)

  step "the turn's work log shows the retry with its attempt, the most attempts allowed and the wait before it",
       context do
    World.await_value(context, @thread, fn state ->
      match?(
        [
          %{
            "type" => "error",
            "title" => "Provider retry",
            "retry" => %{"attempt" => 1, "maxAttempts" => 5, "retryDelayMs" => 2000}
          }
        ],
        retry_items(state)
      )
    end)

    context
  end

  step "each later retry of that request updates the same entry", context do
    claude_says(context, %{
      "type" => "system",
      "subtype" => "api_retry",
      "uuid" => "retry-2",
      "attempt" => 2,
      "max_retries" => 5,
      "retry_delay_ms" => 4000,
      "error_status" => 529,
      "error" => "overloaded"
    })

    World.await_value(context, @thread, fn state ->
      match?([%{"retry" => %{"attempt" => 2, "retryDelayMs" => 4000}}], retry_items(state))
    end)

    assert length(retry_items(World.stream(context, @thread))) == 1

    claude_says(context, %{"type" => "result", "subtype" => "success", "is_error" => false})
    World.await_runs(context, @thread, ["completed"])
    context
  end

  # --- usage-limit pauses ------------------------------------------------------------------

  @windows %{
    "five hour" => "five_hour",
    "weekly" => "seven_day",
    "weekly Opus" => "seven_day_opus",
    "weekly Sonnet" => "seven_day_sonnet",
    "overage" => "overage"
  }

  defp refuse(context, type, resets_at) do
    info = %{"status" => "rejected", "rateLimitType" => type}
    info = if resets_at, do: Map.put(info, "resetsAt", resets_at), else: info
    claude_says(context, %{"type" => "rate_limit_event", "rate_limit_info" => info})
    context
  end

  defp wait_seconds(text) do
    parts = Regex.scan(~r/(\d+) (hours?|minutes?|seconds?)/, text)

    Enum.reduce(parts, 0, fn [_, n, unit], total ->
      factor =
        if(String.starts_with?(unit, "hour"),
          do: 3600,
          else: if(String.starts_with?(unit, "minute"), do: 60, else: 1)
        )

      total + String.to_integer(n) * factor
    end)
  end

  defp pause_notices(state) do
    for item <- StreamState.list(state, "turn-item"),
        item["type"] == "system_notice" and
          String.starts_with?(item["message"] || "", "Claude usage limit reached."),
        do: item
  end

  step ~r/^Claude is refused by its (?<window>.+) limit, which resets in (?<wait>.+)$/,
       %{args: [window, wait]} = context do
    refuse(context, @windows[window], System.system_time(:second) + wait_seconds(wait))
  end

  step ~r/^Claude is refused by its weekly limit, which (?<reset>has no reset time|should already have reset|resets more than 30 days from now)$/,
       %{args: [reset]} = context do
    resets_at =
      case reset do
        "has no reset time" -> nil
        "should already have reset" -> System.system_time(:second) - 3600
        "resets more than 30 days from now" -> System.system_time(:second) + 31 * 86_400
      end

    refuse(context, "seven_day", resets_at)
  end

  step "the thread says {string}", %{args: [text]} = context do
    World.await_value(context, @thread, fn state ->
      Enum.any?(pause_notices(state), &(&1["message"] == text))
    end)

    context
  end

  step "a Claude turn is paused on its five hour limit", context do
    context = running_turn(context)
    resets_at = System.system_time(:second) + 2400
    refuse(context, "five_hour", resets_at)

    World.await_value(context, @thread, fn state -> pause_notices(state) != [] end)
    Map.put(context, :five_hour_reset, resets_at)
  end

  step "Claude reports the same refusal again and a warning about its weekly limit",
       context do
    refuse(context, "five_hour", context.five_hour_reset)

    claude_says(context, %{
      "type" => "rate_limit_event",
      "rate_limit_info" => %{
        "status" => "allowed_warning",
        "rateLimitType" => "seven_day",
        "utilization" => 0.9
      }
    })

    # Both frames are in once the runtime has taken the next one.
    claude_says(context, %{"type" => "result", "subtype" => "success", "is_error" => false})
    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "the thread still shows one pause notice", context do
    assert length(pause_notices(World.stream(context, @thread))) == 1
    context
  end

  step "the warning adds no notice", context do
    assert [] ==
             for(
               item <- pause_notices(World.stream(context, @thread)),
               item["message"] =~ "7-day",
               do: item
             )

    context
  end

  # 14:00 and 18:00 on a fixed day, as the epochs Claude reports.
  defp at_o_clock(hour),
    do:
      DateTime.to_unix(%DateTime{
        year: 2026,
        month: 9,
        day: 24,
        hour: hour,
        minute: 0,
        second: 0,
        time_zone: "Etc/UTC",
        zone_abbr: "UTC",
        utc_offset: 0,
        std_offset: 0
      })

  step "Claude ends a turn refused by a limit that resets at 14:00 and another that resets at 18:00",
       context do
    context = running_turn(context)
    refuse(context, "five_hour", at_o_clock(14))
    refuse(context, "seven_day", at_o_clock(18))
    claude_says(context, %{"type" => "result", "subtype" => "success", "is_error" => true})
    context
  end

  step "Claude ends a turn refused by a limit that resets at 14:00 and another with no reset time",
       context do
    context = running_turn(context)
    refuse(context, "five_hour", at_o_clock(14))
    refuse(context, "seven_day", nil)
    claude_says(context, %{"type" => "result", "subtype" => "success", "is_error" => true})
    context
  end

  step "the thread's reset time is 18:00", context do
    World.await_row(
      World.thread_id(context, @thread),
      &(&1["usageLimitResetAt"] == "2026-09-24T18:00:00.000Z")
    )

    context
  end

  step "the thread is marked as limited without a reset time", context do
    World.await_runs(context, @thread, ["failed"])

    World.await_row(
      World.thread_id(context, @thread),
      &(&1["lastErrorClass"] == "usage_limit" and &1["usageLimitResetAt"] == nil)
    )

    context
  end

  # --- stopping a turn -----------------------------------------------------------------------

  defp stop_turn(context) do
    System.put_env("FAKE_CLAUDE_HOLD_INTERRUPT", "1")
    ExUnit.Callbacks.on_exit(fn -> System.delete_env("FAKE_CLAUDE_HOLD_INTERRUPT") end)
    context = running_turn(context)

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "threadId" => World.thread_id(context, @thread)
      })

    context
  end

  step "the user stopped a Claude turn while a tool was running", context do
    stop_turn(context)
  end

  step "Claude reports the turn as finished successfully but aborted", context do
    claude_says(context, %{
      "type" => "result",
      "subtype" => "success",
      "is_error" => false,
      "terminal_reason" => "aborted_tools"
    })

    context
  end

  step "the run is interrupted, not completed", context do
    World.await_runs(context, @thread, ["interrupted"])
    context
  end

  step "the user stopped a running Claude turn", context do
    World.put_app_env(:claude_interrupt_timeout_ms, 300)
    stop_turn(context)
  end

  step "Claude has not ended the turn after 10 seconds", context do
    # The settle deadline is shortened for the scenario; Claude never answers.
    assert [%{"status" => active}] = World.runs(context, @thread)
    assert active in ["running", "interrupted"]
    context
  end

  step "the run is interrupted anyway", context do
    World.await_runs(context, @thread, ["interrupted"], 10_000)
    context
  end

  step "Claude's process ends without reporting the turn", context do
    [{runtime, _}] = Registry.lookup(HalC2.Claude.Registry, World.thread_id(context, @thread))
    session = :sys.get_state(runtime).session
    ref = Process.monitor(session)
    Process.exit(session, :kill)
    assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
    context
  end

  step "it is not reported as a failed turn", context do
    state = World.stream(context, @thread)

    assert [] ==
             for(item <- StreamState.list(state, "turn-item"), item["type"] == "error", do: item)

    assert [%{"status" => "interrupted"}] = StreamState.list(state, "run")
    context
  end

  # --- approvals ------------------------------------------------------------------------

  # A permission request as the CLI sends it, straight to the runtime.
  defp claude_asks(context, id, tool, input) do
    [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, World.thread_id(context, @thread))
    send(pid, {:claude, :sys.get_state(pid).session, {:permission, id, tool, input, %{}}})
    context
  end

  defp flush_runtime(context) do
    [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, World.thread_id(context, @thread))
    :sys.get_state(pid)
    context
  end

  defp tool_input(tool) do
    cond do
      tool == "Bash" -> %{"command" => "npm test"}
      tool in ["Glob", "Grep"] -> %{"pattern" => "lib/**/*.ex"}
      tool == "LS" -> %{"path" => "lib"}
      true -> %{"file_path" => "lib/shop.ex"}
    end
  end

  step ~r/^Claude asks to use (?<tools>.+)$/, %{args: [tools]} = context do
    %{instance: instance, fields: fields} = context.pending_launch

    context =
      context
      |> Map.delete(:pending_launch)
      |> World.launch_on(@thread, instance, "wait for me", fields)

    World.await_running(context, @thread)
    World.await_provider_log(context, "claude", &(get_in(&1, ["in", "type"]) == "user"))

    tools =
      if tools == "a tool HAL-C2 does not know",
        do: ["Frobnicate"],
        else: tools |> String.split(~r/, | or /)

    context =
      tools
      |> Enum.with_index(1)
      |> Enum.reduce(context, fn {tool, i}, context ->
        claude_asks(context, "perm-kind-#{i}", tool, tool_input(tool))
      end)

    World.await_value(context, @thread, fn state ->
      length(StreamState.list(state, "runtime-request")) == length(tools)
    end)

    context
  end

  step ~r/^the user is asked for permission to (?<permission>.+)$/,
       %{args: [permission]} = context do
    kind =
      %{
        "run a command" => "command",
        "change files" => "file-change",
        "read files" => "file-read"
      }[
        permission
      ]

    requests = StreamState.list(World.stream(context, @thread), "runtime-request")
    assert requests != []
    assert Enum.all?(requests, &(&1["kind"] == kind)), inspect(requests)
    context
  end

  step "Claude asks to run the command {string}", %{args: [command]} = context do
    %{instance: instance, fields: fields} = context.pending_launch

    context =
      context
      |> Map.delete(:pending_launch)
      |> World.launch_on(@thread, instance, "wait for me", fields)

    World.await_running(context, @thread)
    World.await_provider_log(context, "claude", &(get_in(&1, ["in", "type"]) == "user"))
    claude_asks(context, "perm-name-1", "Bash", %{"command" => command})
    Map.put(context, :request, World.await_request(context, @thread))
  end

  defp approval_prompt(context, native) do
    World.stream(context, @thread)
    |> StreamState.list("turn-item")
    |> Enum.find(&(&1["id"] == "turn-item:approval:#{native}"))
    |> Kernel.||(%{})
    |> Map.get("prompt")
  end

  step "the approval reads {string}", %{args: [text]} = context do
    World.await_value(context, @thread, fn _state ->
      approval_prompt(context, "perm-name-1") == text
    end)

    context
  end

  step "a longer summary is cut at 400 characters", context do
    long = String.duplicate("x", 500)
    claude_asks(context, "perm-name-2", "Bash", %{"command" => long})

    World.await_value(context, @thread, fn _state ->
      approval_prompt(context, "perm-name-2") == "Bash: " <> String.duplicate("x", 400)
    end)

    context
  end

  # The waiting approval is the PermissionModes steps' Given, on their "Work" thread.
  @work_thread "Work"

  step "the user cancels the approval", context do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "runtime-request.respond",
        "threadId" => World.thread_id(context, @work_thread),
        "requestId" => context.request["id"],
        "decision" => "cancel"
      })

    context
  end

  step "Claude is told the user cancelled the tool", context do
    World.await_provider_log(context, "claude", fn entry ->
      get_in(entry, ["in", "response", "response", "message"]) ==
        "User cancelled tool execution." and
        get_in(entry, ["in", "response", "response", "interrupt"]) == true
    end)

    context
  end

  step "the turn is interrupted instead of carrying on without the tool", context do
    World.await_runs(context, @work_thread, ["interrupted"])
    refute "denied" in World.replies(context, @work_thread)
    context
  end

  # --- web search and read images -----------------------------------------------------------

  step "Claude searches the web for {string}", %{args: [query]} = context do
    context = running_turn(context)

    claude_says(context, %{
      "type" => "assistant",
      "message" => %{
        "id" => "m-web",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "web-1",
            "name" => "WebSearch",
            "input" => %{"query" => query}
          }
        ]
      }
    })

    claude_says(context, %{
      "type" => "user",
      "message" => %{
        "role" => "user",
        "content" => [
          %{
            "type" => "tool_result",
            "tool_use_id" => "web-1",
            "content" => "done",
            "is_error" => false
          }
        ]
      },
      "tool_use_result" => %{
        "query" => query,
        "durationSeconds" => 1.5,
        "results" => [
          %{
            "tool_use_id" => "srv-1",
            "content" => [
              %{"title" => "Tax rates explained", "url" => "https://example.com/tax"},
              %{"title" => "Rates for 2026", "url" => "https://example.com/2026"}
            ]
          }
        ]
      }
    })

    claude_says(context, %{"type" => "result", "subtype" => "success", "is_error" => false})
    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "the search step shows the query", context do
    item =
      World.stream(context, @thread)
      |> StreamState.list("turn-item")
      |> Enum.find(&(&1["type"] == "web_search"))

    assert item["patterns"] == ["tax rates 2026"]
    Map.put(context, :web_item, item)
  end

  step "it lists the titles and addresses of the pages found", context do
    assert context.web_item["results"] == [
             %{"title" => "Tax rates explained", "url" => "https://example.com/tax"},
             %{"title" => "Rates for 2026", "url" => "https://example.com/2026"}
           ]

    context
  end

  step "Claude reads the image {string} in the workspace", %{args: [path]} = context do
    context = running_turn(context)

    claude_says(context, %{
      "type" => "assistant",
      "message" => %{
        "id" => "m-read",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "read-1",
            "name" => "Read",
            "input" => %{"file_path" => path}
          }
        ]
      }
    })

    claude_says(context, %{
      "type" => "user",
      "message" => %{
        "role" => "user",
        "content" => [
          %{
            "type" => "tool_result",
            "tool_use_id" => "read-1",
            "content" => "image",
            "is_error" => false
          }
        ]
      }
    })

    claude_says(context, %{"type" => "result", "subtype" => "success", "is_error" => false})
    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "the tool call carries the image's path so the client can show it", context do
    item =
      World.stream(context, @thread)
      |> StreamState.list("turn-item")
      |> Enum.find(&(&1["toolName"] == "Read"))

    assert item["viewedImagePath"] == "docs/mock.png"
    context
  end

  # --- questions ------------------------------------------------------------------------------

  defp questions(context) do
    World.stream(context, @thread)
    |> StreamState.list("turn-item")
    |> Enum.find_value(& &1["questions"])
  end

  step "Claude asks two questions and the second has no heading", context do
    context =
      context |> World.fake_providers() |> World.launch_on(@thread, "claudeAgent", "ask two")

    Map.put(context, :request, World.await_request(context, @thread))
  end

  step "the second question is headed {string}", %{args: [header]} = context do
    assert [%{"header" => "Color"}, %{"header" => ^header}] = questions(context)
    context
  end

  step "Claude asked a question that allows several answers", context do
    context =
      context |> World.fake_providers() |> World.launch_on(@thread, "claudeAgent", "ask multi")

    context = Map.put(context, :request, World.await_request(context, @thread))
    assert [%{"multiSelect" => true} = question] = questions(context)
    Map.put(context, :question, question)
  end

  step "the user picks {string} and {string}", %{args: [first, second]} = context do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "runtime-request.respond",
        "threadId" => World.thread_id(context, @thread),
        "requestId" => context.request["id"],
        "answers" => %{context.question["id"] => [first, second]}
      })

    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "Claude receives {string} as the answer", %{args: [answer]} = context do
    assert ~s(answered {"What should we add?": "#{answer}"}) in World.replies(context, @thread)
    context
  end

  # --- task lists -------------------------------------------------------------------------------

  defp todo_plans(context) do
    World.stream(context, @thread)
    |> StreamState.list("plan")
    |> Enum.filter(&(&1["kind"] == "todo_list"))
    |> Enum.sort_by(& &1["id"])
  end

  step "Claude writes a task list with a finished step, a step in progress and a step not started",
       context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "claudeAgent", "todo three")

    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "Claude writes its task list twice in one turn", context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "claudeAgent", "todo twice")

    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "the thread shows one task list with the latest steps", context do
    assert [%{"status" => "active", "steps" => steps}] = todo_plans(context)
    assert Enum.map(steps, & &1["status"]) == ["completed", "completed", "running"]
    context
  end

  step "the task list shows the three steps as completed, running and pending", context do
    assert [%{"status" => "active", "steps" => steps}] = todo_plans(context)
    assert Enum.map(steps, & &1["status"]) == ["completed", "running", "pending"]
    context
  end

  step "the list is completed once every step is completed", context do
    context = World.post_message(context, @thread, "todo done")
    World.await_runs(context, @thread, ["completed", "completed"])

    assert Enum.any?(
             todo_plans(context),
             &(&1["status"] == "completed" and
                 Enum.all?(&1["steps"], fn step -> step["status"] == "completed" end))
           )

    context
  end

  step "Claude's task list still has unfinished steps", context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "claudeAgent", "todo done")

    World.await_runs(context, @thread, ["completed"])
    context = World.post_message(context, @thread, "todo")
    World.await_runs(context, @thread, ["completed", "completed"])
    assert Enum.any?(todo_plans(context), &(&1["status"] == "active"))
    context
  end

  step "Claude writes a new task list", context do
    context = World.post_message(context, @thread, "todo three")
    World.await_runs(context, @thread, ["completed", "completed", "completed"])
    context
  end

  step "the earlier list is marked superseded", context do
    assert Enum.any?(todo_plans(context), &(&1["status"] == "superseded"))
    context
  end

  step "a list that had already completed stays completed", context do
    assert Enum.any?(todo_plans(context), &(&1["status"] == "completed"))
    context
  end

  # --- background commands and subagents ----------------------------------------------------------

  step "Claude runs a long command as a background task", context do
    context = running_turn(context)

    claude_says(context, %{
      "type" => "assistant",
      "message" => %{
        "id" => "m-bash",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "bash-9",
            "name" => "Bash",
            "input" => %{"command" => "npm run build", "run_in_background" => true}
          }
        ]
      }
    })

    claude_says(context, %{
      "type" => "system",
      "subtype" => "task_started",
      "task_id" => "task-bash-9",
      "tool_use_id" => "bash-9",
      "task_type" => "local_bash",
      "is_backgrounded" => true,
      "description" => "Build"
    })

    claude_says(context, %{
      "type" => "user",
      "message" => %{
        "role" => "user",
        "content" => [
          %{
            "type" => "tool_result",
            "tool_use_id" => "bash-9",
            "content" => "Command running in background with ID: task-bash-9",
            "is_error" => false
          }
        ]
      }
    })

    claude_says(context, %{"type" => "result", "subtype" => "success", "is_error" => false})
    World.await_runs(context, @thread, ["completed"])

    claude_says(context, %{
      "type" => "system",
      "subtype" => "task_notification",
      "task_id" => "task-bash-9",
      "tool_use_id" => "bash-9",
      "status" => "completed",
      "summary" => "Build finished"
    })

    context
  end

  step "the thread shows the command and its output", context do
    World.await_value(context, @thread, fn state ->
      Enum.any?(
        StreamState.list(state, "turn-item"),
        &(&1["type"] == "command_execution" and &1["input"] == "npm run build" and
            &1["status"] == "completed" and &1["output"] == "Build finished")
      )
    end)

    context
  end

  step "no child thread or subagent is created for it", context do
    assert StreamState.list(World.stream(context, @thread), "subagent") == []
    context
  end

  defp subagent_notification(context, status, summary) do
    claude_says(context, %{
      "type" => "system",
      "subtype" => "task_notification",
      "task_id" => "task-agent-1",
      "tool_use_id" => "agent-1",
      "status" => status,
      "summary" => summary
    })

    context
  end

  step ~r/^Claude reports the subagent (?<reported>completed with a result|stopped|ended any other way)$/,
       %{args: [reported]} = context do
    case reported do
      "completed with a result" -> subagent_notification(context, "completed", "3 files")
      "stopped" -> subagent_notification(context, "stopped", "")
      "ended any other way" -> subagent_notification(context, "killed", "")
    end
  end

  step ~r/^the subagent is (?<status>completed|cancelled|failed)$/,
       %{args: [status]} = context do
    World.await_value(context, @thread, fn state ->
      match?([%{"status" => ^status}], StreamState.list(state, "subagent"))
    end)

    context
  end

  step "Claude launches a subagent in the background and the launch returns at once",
       context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "claudeAgent", "survey in the background")

    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "the subagent stays running until Claude reports it finished", context do
    assert [%{"status" => "running"}] =
             StreamState.list(World.stream(context, @thread), "subagent")

    subagent_notification(context, "completed", "3 files")

    World.await_value(context, @thread, fn state ->
      match?([%{"status" => "completed"}], StreamState.list(state, "subagent"))
    end)

    context
  end

  step "a Claude subagent completed with {string}", %{args: [result]} = context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "claudeAgent", "survey in the background")

    World.await_runs(context, @thread, ["completed"])
    subagent_notification(context, "completed", result)

    World.await_value(context, @thread, fn state ->
      match?(
        [%{"status" => "completed", "result" => ^result}],
        StreamState.list(state, "subagent")
      )
    end)

    context
  end

  step "Claude sends that subagent another message", context do
    context = World.post_message(context, @thread, "wait and resume it")
    World.await_running(context, @thread)

    World.await_provider_log(
      context,
      "claude",
      &(get_in(&1, ["in", "message", "content"]) == "wait and resume it")
    )

    claude_says(context, %{
      "type" => "assistant",
      "message" => %{
        "id" => "m-send",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "send-1",
            "name" => "SendMessage",
            "input" => %{"to" => "task-agent-1", "message" => "Also check the tests"}
          }
        ]
      }
    })

    context
  end

  step "the subagent is running again without its earlier result", context do
    state =
      World.await_value(context, @thread, fn state ->
        case StreamState.list(state, "subagent") do
          [%{"status" => "running"} = sub] -> sub
          _ -> false
        end
      end)

    assert state["result"] in [nil, ""]

    claude_says(context, %{
      "type" => "system",
      "subtype" => "task_notification",
      "task_id" => "task-agent-1",
      "tool_use_id" => "send-1",
      "status" => "completed",
      "summary" => "The tests pass"
    })

    claude_says(context, %{"type" => "result", "subtype" => "success", "is_error" => false})
    World.await_runs(context, @thread, ["completed", "completed"])
    context
  end

  step "a progress report for it arrives afterwards", context do
    claude_says(context, %{
      "type" => "system",
      "subtype" => "task_progress",
      "task_id" => "task-agent-1",
      "tool_use_id" => "agent-1",
      "summary" => "Still going"
    })

    flush_runtime(context)
  end

  step "the subagent stays completed with {string}", %{args: [result]} = context do
    assert [%{"status" => "completed", "result" => ^result}] =
             StreamState.list(World.stream(context, @thread), "subagent")

    context
  end

  # --- wakes --------------------------------------------------------------------------------------

  defp user_messages(context) do
    for %{"in" => %{"type" => "user"}} = entry <- World.provider_log(context, "claude"),
        do: entry
  end

  step "Claude answered a finished background task by itself after a turn ended", context do
    context =
      context |> World.fake_providers() |> World.launch_on(@thread, "claudeAgent", "hello")

    World.await_runs(context, @thread, ["completed"])

    claude_says(context, %{
      "type" => "assistant",
      "message" => %{
        "id" => "m-wake",
        "content" => [%{"type" => "text", "text" => "The build passed"}]
      }
    })

    context
  end

  step "the thread runs a turn for that work", context do
    World.await_value(context, @thread, fn state ->
      match?([_, %{"status" => "running"}], World.runs(context, @thread))
    end)

    claude_says(context, %{"type" => "result", "subtype" => "success", "is_error" => false})
    World.await_runs(context, @thread, ["completed", "completed"])
    context
  end

  step "the run shows what Claude already wrote", context do
    assert "The build passed" in World.replies(context, @thread)
    context
  end

  step "Claude is sent no new message for it", context do
    assert length(user_messages(context)) == 1
    context
  end

  step "the thread is asked to run a turn for work Claude did by itself", context do
    context =
      context |> World.fake_providers() |> World.launch_on(@thread, "claudeAgent", "hello")

    World.await_runs(context, @thread, ["completed"])
    [run] = World.runs(context, @thread)

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "commandId" => "command:claude-wake:#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, @thread),
        "messageId" => "message:wake-#{System.unique_integer([:positive])}",
        "text" => "Background task completed.",
        "attachments" => [],
        "modelSelection" => run["modelSelection"],
        "dispatchMode" => %{"type" => "queue_after_active"},
        "createdBy" => "agent",
        "creationSource" => "provider",
        "providerWake" => true,
        "notification" => %{
          "source" => %{"kind" => "background_task"},
          "outcome" => "updated",
          "summary" => "Background activity updated"
        }
      })

    context
  end

  step "Claude wrote nothing for it", context do
    context
  end

  step "the run completes without asking Claude anything", context do
    World.await_runs(context, @thread, ["completed", "completed"], 10_000)
    assert length(user_messages(context)) == 1
    context
  end

  # --- reverting to before the first turn ------------------------------------------------------------

  step "the user reverts to before the first turn and sends a message", context do
    context = World.rollback(context, @thread, 0, %{"restoreFiles" => false})
    assert {:ok, _} = context.reply
    World.post_message(context, @thread, "where are we")
  end

  step "Claude starts a new session that remembers none of the turns", context do
    World.await_value(context, @thread, fn state ->
      state
      |> StreamState.list("run")
      |> Enum.map(& &1["status"])
      |> Kernel.==(["rolled_back", "rolled_back", "rolled_back", "completed"])
    end)

    argv =
      World.provider_log(context, "claude")
      |> Enum.flat_map(fn
        %{"argv" => argv} -> [argv]
        _ -> []
      end)
      |> List.last()

    refute "--resume" in argv
    assert "resumed at None fork False history False" in World.replies(context, @thread)
    context
  end

  # --- launch, context meter, read-only runs -----------------------------------------

  defp last_argv(context) do
    context
    |> World.provider_log("claude")
    |> Enum.flat_map(fn
      %{"argv" => argv} -> [argv]
      _ -> []
    end)
    |> List.last()
  end

  defp flag_value(argv, flag) do
    case Enum.chunk_every(argv, 2, 1, :discard) |> Enum.find(&match?([^flag, _], &1)) do
      [_, value] -> value
      _ -> nil
    end
  end

  defp launch_args(context, text) do
    World.put_settings(context, %{"providers" => %{"claudeAgent" => %{"launchArgs" => text}}})
    World.reset_provider_caches()
    context
  end

  step ~r/^a Claude turn runs on (?<model>.+)$/, %{args: [model]} = context do
    {slug, options} =
      case model do
        "Opus 4.6" ->
          {"claude-opus-4-6", %{}}

        "Opus 4.7" ->
          {"claude-opus-4-7", %{}}

        "a model with the 1M context window set" ->
          {"claude-sonnet-4-6", [%{"id" => "contextWindow", "value" => "1m"}]}

        "any other model" ->
          {"claude-haiku-4-5-20251001", %{}}
      end

    selection = %{"instanceId" => "claudeAgent", "model" => slug, "options" => options}

    context =
      context
      |> World.fake_providers(claude_version: "999.0.0")
      |> World.launch_on(@thread, "claudeAgent", "wait for me", %{"modelSelection" => selection})

    World.await_running(context, @thread)

    # Two requests in one turn: the meter reads the last request's usage, not
    # the result's, which totals every request of the turn.
    for {id, usage} <- [
          {"usage-first",
           %{
             "input_tokens" => 9000,
             "cache_creation_input_tokens" => 0,
             "cache_read_input_tokens" => 80_000,
             "output_tokens" => 400
           }},
          {"usage-last",
           %{
             "input_tokens" => 1000,
             "cache_creation_input_tokens" => 200,
             "cache_read_input_tokens" => 300,
             "output_tokens" => 50
           }}
        ] do
      claude_says(context, %{
        "type" => "assistant",
        "message" => %{
          "id" => id,
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "working"}],
          "usage" => usage
        }
      })
    end

    claude_says(context, %{
      "type" => "result",
      "subtype" => "success",
      "is_error" => false,
      "usage" => %{
        "input_tokens" => 10_000,
        "cache_creation_input_tokens" => 200,
        "cache_read_input_tokens" => 80_300,
        "output_tokens" => 450
      }
    })

    World.await_runs(context, @thread, ["completed"])
    Map.put(context, :usage, context_usage(context))
  end

  step ~r/^the context meter is out of (?<size>[\d,]+) tokens$/, %{args: [size]} = context do
    assert context.usage["maxTokens"] == size |> String.replace(",", "") |> String.to_integer()
    context
  end

  step "what is used counts the input, cached and output tokens Claude reported", context do
    assert context.usage["usedTokens"] == 1000 + 200 + 300 + 50
    assert context.usage["inputTokens"] == 1500
    assert context.usage["cachedInputTokens"] == 300
    assert context.usage["outputTokens"] == 50
    context
  end

  step "a Claude instance with no launch arguments", context do
    World.fake_providers(context)
  end

  step "a model with thinking set to off", context do
    context = World.fake_providers(context)

    Map.put(context, :model_selection, %{
      "instanceId" => "claudeAgent",
      "model" => "claude-haiku-4-5-20251001",
      "options" => [%{"id" => "thinking", "value" => false}]
    })
  end

  step "a Claude instance with the launch argument {string}", %{args: [argument]} = context do
    context |> World.fake_providers() |> launch_args(argument)
  end

  step ~r/^Claude is (?<asked>asked|not asked) for summaries of its thinking$/,
       %{args: [asked]} = context do
    argv = last_argv(context)
    context = Map.put(context, :argv, argv)

    if asked == "asked" do
      assert flag_value(argv, "--thinking-display") == "summarized"
      assert settings(context)["showThinkingSummaries"] == true
    else
      refute flag_value(argv, "--thinking-display") == "summarized"

      case Enum.find(pairs(argv), &match?(["--settings", _], &1)) do
        nil -> :ok
        _ -> refute settings(context)["showThinkingSummaries"] == true
      end
    end

    assert Enum.count(argv, &(&1 == "--thinking-display")) <= 1
    context
  end

  step "the Claude instance has launch arguments configured", context do
    context
    |> World.fake_providers()
    |> launch_args(~s(--verbose --append-system-prompt "be brief"))
  end

  step "Claude is started with those arguments", context do
    argv = last_argv(context)
    assert "--verbose" in argv

    assert Enum.any?(
             Enum.chunk_every(argv, 2, 1, :discard),
             &match?(["--append-system-prompt", "be brief"], &1)
           )

    context
  end

  step "the Claude instance has the launch argument {string}", %{args: [argument]} = context do
    context |> World.fake_providers() |> launch_args(argument)
  end

  # A run confined to reading: a message dispatched with `readOnly`, the way an
  # internal sender asks for one (`Orchestration` carries it onto the turn).
  defp read_only_run(context) do
    # The fake setup does not start the MCP server the app always runs.
    Mc.ensure(HalC2.Mcp)

    context =
      context
      |> World.fake_providers()
      |> World.create_project("shop")
      |> World.create_thread(@thread)

    {{:ok, _}, context} =
      World.send_message(context, @thread, "survey the code", %{
        "modelSelection" => %{
          "instanceId" => "claudeAgent",
          "model" => "claude-haiku-4-5-20251001"
        },
        "readOnly" => true
      })

    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "a Claude run that may only read the workspace and never asks for approval", context do
    Map.put(context, :read_only_run, true)
  end

  step "a Claude run that may only read the workspace and has the HAL-C2 tools", context do
    Map.put(context, :read_only_run, true)
  end

  step "the run starts", context do
    read_only_run(context)
  end

  step "Claude can use only its tools for reading and searching files", context do
    argv = last_argv(context)
    assert flag_value(argv, "--tools") == "Read,Glob,Grep"
    assert flag_value(argv, "--permission-mode") == "dontAsk"
    context
  end

  # The session's start (later starts may be the usage probe's `claude -p`).
  defp session_argv(context) do
    context
    |> World.provider_log("claude")
    |> Enum.flat_map(fn
      %{"argv" => argv} -> [argv]
      _ -> []
    end)
    |> Enum.find(&("--output-format" in &1))
  end

  step "HAL-C2 tools that only read, such as listing threads, are allowed without asking",
       context do
    allowed = flag_value(session_argv(context), "--allowedTools")
    assert allowed =~ "mcp__hal-c2__hal_c2_thread_list"
    Map.put(context, :allowed_tools, allowed)
  end

  step "HAL-C2 tools that start threads or schedule tasks are not allowed", context do
    allowed = context.allowed_tools
    refute allowed == "mcp__hal-c2"
    refute allowed =~ "delegate_task"
    refute allowed =~ "schedule_task"
    refute allowed =~ "create_threads"
    context
  end

  step "the user sends Claude a message with an attached file", context do
    context =
      context
      |> World.fake_providers()
      |> World.create_project("shop")
      |> World.create_thread(@thread)

    bytes = "remember the milk\n"
    id = "pending-00000000-0000-4000-8000-000000000123"
    File.mkdir_p!(HalC2.Attachments.dir())
    File.write!(Path.join(HalC2.Attachments.dir(), id <> ".txt"), bytes)

    attachment = %{
      "type" => "file",
      "id" => id,
      "name" => "notes.txt",
      "mimeType" => "text/plain",
      "sizeBytes" => byte_size(bytes)
    }

    {{:ok, _}, context} =
      World.send_message(context, @thread, "read this", %{
        "modelSelection" => %{
          "instanceId" => "claudeAgent",
          "model" => "claude-haiku-4-5-20251001"
        },
        "attachments" => [attachment]
      })

    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "Claude is given access to the folder the MC saved the file in", context do
    argv = last_argv(context)
    assert flag_value(argv, "--add-dir") == HalC2.Attachments.dir()

    message =
      World.stream(context, @thread)
      |> StreamState.list("message")
      |> Enum.find(& &1["attachments"])

    assert [claimed] = message["attachments"]
    assert String.starts_with?(HalC2.Attachments.path(claimed), HalC2.Attachments.dir())
    context
  end

  # --- health, homes, sign-in ----------------------------------------------------------------

  # A `claude` of the scenario's own making, run in place of the fake's command.
  defp claude_script(context, name, body) do
    path = Path.join(Mc.tmp_dir(context.mc, "claude-script"), name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
    World.put_app_env(:claude_command, [path])
    World.reset_provider_caches()
    context
  end

  step "the claude command is not on the path", context do
    context =
      context
      |> World.fake_providers()
      |> write_settings(fn settings ->
        put_in(settings, [Access.key("providers", %{}), "claudeAgent"], %{
          "binaryPath" => "claude"
        })
      end)

    World.put_os_env("PATH", Mc.tmp_dir(context.mc, "empty-path"))
    World.reset_provider_caches()
    context
  end

  step "the claude command is found but cannot be run", context do
    context
    |> World.fake_providers()
    |> claude_script("claude", "#!/nonexistent/interpreter\necho never\n")
  end

  step "the claude version check exits with an error", context do
    context
    |> World.fake_providers()
    |> claude_script("claude", "#!/bin/sh\necho \"2.1.0 (Claude Code)\"\nexit 3\n")
  end

  step "the claude version check does not finish in time", context do
    World.put_app_env(:claude_health_timeout_ms, 300)

    context
    |> World.fake_providers()
    |> claude_script("claude", "#!/bin/sh\nsleep 5\n")
  end

  step "claude runs but does not report its sign-in", context do
    System.put_env("FAKE_CLAUDE_NO_ACCOUNT", "1")
    ExUnit.Callbacks.on_exit(fn -> System.delete_env("FAKE_CLAUDE_NO_ACCOUNT") end)
    context = World.fake_providers(context)
    # The check every MC runs at boot; it reads what `initialize` reports.
    :ok = HalC2.Claude.Provider.load()
    context
  end

  step "Claude is turned off in the provider settings", context do
    context
    |> World.fake_providers()
    |> write_settings(fn settings ->
      plugins =
        put_in(settings, [Access.key("providers", %{}), Access.key("claudeAgent", %{})], %{})

      put_in(plugins, ["providers", "claudeAgent", "enabled"], false)
    end)
  end

  step "the MC has not checked Claude yet since it started", context do
    World.put_app_env(:claude_health_timeout_ms, 10_000)

    context =
      context
      |> World.fake_providers()
      |> claude_script(
        "claude",
        "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then sleep 3; echo \"2.1.0 (Claude Code)\"; exit 0; fi\nexec python3 -u #{Path.expand("../../support/fake_claude.py", __DIR__)} \"$@\"\n"
      )

    task = Task.async(fn -> HalC2.Claude.Provider.entry() end)

    # Until the check it started lands, the entry is the pending one.
    Enum.reduce_while(1..200, nil, fn _, _ ->
      case :persistent_term.get({HalC2.Claude.Provider, :health}, %{}) do
        %{} = records when map_size(records) > 0 ->
          {:halt, :probing}

        _ ->
          Process.sleep(10)
          {:cont, nil}
      end
    end)

    Map.put(context, :health_task, task)
  end

  step "Claude is shown with the message {string}", %{args: [message]} = context do
    assert claude(context.providers)["message"] == message
    if task = context[:health_task], do: Task.await(task, 15_000)
    context
  end

  defp probe_starts(context) do
    Enum.count(World.provider_log(context, "claude"), fn
      %{"argv" => argv} -> "--strict-mcp-config" in argv
      _ -> false
    end)
  end

  step "the MC read a Claude instance's account, commands and agents for a project folder",
       context do
    context = World.fake_providers(context)
    :ok = HalC2.Claude.Provider.load()
    assert {:ok, %{"account" => _}} = HalC2.Claude.Provider.capabilities("claudeAgent")
    Map.put(context, :probe_starts, probe_starts(context))
  end

  step "it checks that instance again within five minutes", context do
    {providers, context} = World.provider_list(context)
    assert claude(providers)
    assert {:ok, _} = HalC2.Claude.Provider.capabilities("claudeAgent")
    context
  end

  step "Claude is not started again to read them", context do
    assert probe_starts(context) == context.probe_starts
    context
  end

  step "refreshing the provider by hand reads them afresh", context do
    {:ok, _} =
      HalC2.Environment.refresh_providers(%{
        "instanceId" => "claudeAgent",
        "refreshModels" => true
      })

    assert probe_starts(context) > context.probe_starts
    context
  end

  step "the MC runs on Windows and {string} on its path is npm's launcher script",
       %{args: [_name]} = context do
    World.put_app_env(:os_type, {:win32, :nt})
    context = World.fake_providers(context)
    root = Mc.tmp_dir(context.mc, "claude-npm-windows")
    bin = Path.join([root, "node_modules", "@anthropic-ai", "claude-code", "bin"])
    File.mkdir_p!(bin)

    exe = Path.join(bin, "claude.exe")

    File.write!(
      exe,
      "#!/bin/sh\nexec python3 -u #{Path.expand("../../support/fake_claude.py", __DIR__)} \"$@\"\n"
    )

    File.chmod!(exe, 0o755)

    launcher = Path.join(root, "claude.cmd")

    File.write!(
      launcher,
      "@echo off\r\n\"%~dp0\\node_modules\\@anthropic-ai\\claude-code\\bin\\claude.exe\" %*\r\n"
    )

    File.chmod!(launcher, 0o755)

    World.put_app_env(:claude_command, [launcher])
    World.reset_provider_caches()
    context |> Map.put(:windows_exe, exe) |> Map.put(:windows_launcher, launcher)
  end

  step "the MC starts the Claude program that script points to", context do
    # The launcher script itself cannot run here; a start happened, so the
    # program it points to is what ran.
    assert HalC2.Claude.Provider.resolve_command([context.windows_launcher]) ==
             [context.windows_exe]

    assert [%{"argv" => _}] =
             Enum.filter(World.provider_log(context, "claude"), &Map.has_key?(&1, "argv"))

    context
  end

  step "the turn runs", context do
    # Another file's scenario names its own thread in the context; Claude's
    # own scenarios run on @thread and expect Claude's answer.
    thread = context[:thread] || @thread
    World.await_latest_run(context, thread, "completed")

    if thread == @thread do
      assert "Hello from claude" in World.replies(context, @thread)
    end

    context
  end

  defp unquote_setting(value) do
    value |> String.trim() |> String.trim("\"")
  end

  step ~r/^the Claude instance's config directory is (?<setting>.+)$/,
       %{args: [setting]} = context do
    context = World.fake_providers(context)

    if setting == "empty" do
      context
    else
      write_settings(context, fn settings ->
        put_in(settings, [Access.key("providers", %{}), "claudeAgent"], %{
          "homePath" => unquote_setting(setting)
        })
      end)
    end
  end

  step ~r/^the MC's environment (?<inherited>sets another Claude config directory|sets the Claude config directory "[^"]+"|sets no Claude config directory)$/,
       %{args: [inherited]} = context do
    cond do
      inherited == "sets another Claude config directory" ->
        World.put_os_env("CLAUDE_CONFIG_DIR", "/other/claude")

      inherited =~ ~r/sets the Claude config directory "([^"]+)"/ ->
        [_, dir] = Regex.run(~r/"([^"]+)"/, inherited)
        World.put_os_env("CLAUDE_CONFIG_DIR", dir)

      true ->
        World.put_os_env("CLAUDE_CONFIG_DIR", nil)
    end

    context
  end

  step ~r/^Claude uses (?<directory>"[^"]+"(?: in the user's home)?)$/,
       %{args: [directory]} = context do
    env =
      World.provider_log(context, "claude")
      |> Enum.find_value(& &1["env"])

    if directory == "\".claude\" in the user's home" do
      refute Map.has_key?(env, "CLAUDE_CONFIG_DIR")
      assert HalC2.Claude.Provider.config_dir() == Path.join(System.user_home!(), ".claude")
    else
      assert env["CLAUDE_CONFIG_DIR"] == unquote_setting(directory)
    end

    context
  end

  @second_home "claude-second-home"

  step "one Claude instance has no config directory set and another is set to {string}",
       %{args: [home]} = context do
    home_dir = Mc.tmp_dir(context.mc, "user-home")
    World.put_os_env("HOME", home_dir)
    World.put_os_env("CLAUDE_CONFIG_DIR", nil)
    World.put_os_env("FAKE_SESSIONS", "1")
    context = World.fake_providers(context)

    context =
      write_settings(context, fn settings ->
        put_in(settings, [Access.key("providerInstances", %{}), @second_home], %{
          "driver" => "claudeAgent",
          "enabled" => true,
          "displayName" => "Claude (second home)",
          "config" => %{"homePath" => home}
        })
      end)

    context = World.launch_on(context, @thread, "claudeAgent", "hello")
    World.await_runs(context, @thread, ["completed"])
    Map.put(context, :user_home, home_dir)
  end

  step "a thread started on the first is moved to the second", context do
    context =
      World.send_turn(context, @thread, "where are we", %{
        "modelSelection" => %{"instanceId" => @second_home, "model" => "sonnet"}
      })

    World.await_runs(context, @thread, ["completed", "completed"])
    context
  end

  step "Claude continues the same conversation", context do
    starts = for %{"argv" => argv} <- World.provider_log(context, "claude"), do: argv

    native =
      World.stream(context, @thread)
      |> StreamState.list("provider-thread")
      |> Enum.find_value(&get_in(&1, ["nativeThreadRef", "nativeId"]))

    assert ["--resume", native] in pairs(List.last(starts))
    context
  end

  step "a thread that ran on Codex", context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "codex", "hello from codex")

    World.await_runs(context, @thread, ["completed"])

    assert World.stream(context, @thread)
           |> StreamState.list("provider-thread")
           |> Enum.any?(& &1["nativeThreadRef"])

    context
  end

  step "the user sends the next message to Claude", context do
    context =
      World.send_turn(context, @thread, "hello from claude", %{
        "modelSelection" => %{"instanceId" => "claudeAgent", "model" => "sonnet"}
      })

    World.await_runs(context, @thread, ["completed", "completed"])
    context
  end

  step "Claude starts a new conversation and the turn completes", context do
    starts = for %{"argv" => argv} <- World.provider_log(context, "claude"), do: argv
    assert starts != []
    refute "--resume" in List.last(starts)
    assert "Hello from claude" in World.replies(context, @thread)
    context
  end

  step "a Claude instance with its own config directory was signed in from a terminal",
       context do
    dir = Mc.tmp_dir(context.mc, "claude-mac-home")

    File.write!(
      Path.join(dir, ".claude.json"),
      JSON.encode!(%{"oauthAccount" => %{"emailAddress" => "mac@example.com"}})
    )

    context = World.fake_providers(context)

    context =
      write_settings(context, fn settings ->
        put_in(settings, [Access.key("providers", %{}), "claudeAgent"], %{"homePath" => dir})
      end)

    Map.put(context, :claude_home, dir)
  end

  step "the user sends a message to that instance", context do
    context = World.launch_on(context, @thread, "claudeAgent", "hello")

    World.await_value(context, @thread, fn state ->
      match?([%{"status" => s}] when s in ["completed", "failed"], StreamState.list(state, "run"))
    end)

    context
  end

  step "Claude runs signed in", context do
    start = Enum.find(World.provider_log(context, "claude"), &Map.has_key?(&1, "argv"))
    assert start["account"] == "mac@example.com"
    assert start["env"]["CLAUDE_CONFIG_DIR"] == context.claude_home
    # HOME is the user's own: Claude finds the login its keychain holds there.
    assert start["env"]["HOME"] == System.user_home!()
    assert "Hello from claude" in World.replies(context, @thread)
    context
  end

  step "a Claude instance with its own config directory is not signed in", context do
    System.put_env("FAKE_CLAUDE_SIGNED_OUT", "1")
    ExUnit.Callbacks.on_exit(fn -> System.delete_env("FAKE_CLAUDE_SIGNED_OUT") end)
    dir = Mc.tmp_dir(context.mc, "claude-signed-out-home")
    context = World.fake_providers(context)

    context =
      write_settings(context, fn settings ->
        put_in(settings, [Access.key("providers", %{}), "claudeAgent"], %{"homePath" => dir})
      end)

    Map.put(context, :claude_home, dir)
  end

  defp last_error(context, title \\ @thread) do
    state = World.await_runs(context, title, ["failed"])
    [session] = StreamState.list(state, "provider-session")
    session["lastError"]
  end

  step "the turn fails saying to run {string} on the MC's machine",
       %{args: [command]} = context do
    assert last_error(context) =~ "run `#{command}` on this environment's machine"
    context
  end

  step "the message names the folder to run it from and the config directory to set", context do
    project = World.project(context)

    assert last_error(context) =~
             ~s(from "#{project.root}", with CLAUDE_CONFIG_DIR set to "#{context.claude_home}")

    context
  end

  step "says to start a new thread afterwards, or to check the instance's credentials when it uses an API key",
       context do
    error = last_error(context)
    assert error =~ "then start a new thread"
    assert error =~ "check this instance's configured credentials"
    context
  end

  # --- skills --------------------------------------------------------------------------

  # Claude's own home for the scenario, so its skills and settings are the
  # scenario's, never this machine's.
  defp skills_home(context) do
    dir =
      context[:skills_home] ||
        (
          dir = Mc.tmp_dir(context.mc, "claude-skills-home")
          World.put_os_env("CLAUDE_CONFIG_DIR", dir)
          dir
        )

    {Map.put(context, :skills_home, dir), dir}
  end

  defp write_skill_file(base, name, body) do
    path = Path.join([base, name, "SKILL.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
  end

  defp project_skill(
         context,
         name,
         body \\ "---\ndescription: Does the review\n---\nReview it.\n"
       ) do
    {context, _home} = skills_home(context)
    root = context[:workspace] || World.project(context).root
    write_skill_file(Path.join([root, ".claude", "skills"]), name, body)
    context
  end

  defp open_skill_list(context, cwd \\ nil) do
    cwd = cwd || context[:workspace] || World.project(context).root

    {:ok, _} =
      HalC2.Environment.refresh_providers(%{"instanceId" => "claudeAgent", "cwd" => cwd})

    {providers, context} = World.provider_list(context)

    snapshot =
      Enum.find(
        claude(providers)["workspaceSnapshots"] || [],
        &(&1["cwd"] == cwd)
      )

    context
    |> Map.put(:providers, providers)
    |> Map.put(:skills, (snapshot && snapshot["skills"]) || [])
  end

  defp offered(context, name),
    do: Enum.find(context.skills, &(&1["name"] == name))

  step ~r/^a Claude skill "([^"]+)" in (.+)$/, %{args: [name, folder]} = context do
    {context, home} = skills_home(context)
    root = World.project(context).root

    {base, description} =
      case folder do
        "the skills folder of Claude's config directory" ->
          {Path.join(home, "skills"), "The user's own review"}

        "the project's .claude/skills" ->
          {Path.join([root, ".claude", "skills"]), "Reviews code"}

        "the project's .agents/skills" ->
          {Path.join([root, ".agents", "skills"]), "Reviews code"}
      end

    write_skill_file(base, name, "---\ndescription: #{description}\n---\nReview it.\n")
    context
  end

  step "the user opens the skill list in a Claude thread", context do
    context = World.fake_providers(context)
    open_skill_list(context)
  end

  step "the user opens the skill list in that thread", context do
    context = World.fake_providers(context)
    open_skill_list(context, context.workspace)
  end

  step ~r/^"([^"]+)" is (offered to Claude|not offered to Claude|shown as off)$/,
       %{args: [name, state]} = context do
    skill = offered(context, name)

    case state do
      "offered to Claude" -> assert skill && skill["enabled"] == true
      "not offered to Claude" -> assert skill == nil
      "shown as off" -> assert skill && skill["enabled"] == false
    end

    context
  end

  step "the project has the Claude skill {string}", %{args: [name]} = context do
    context = World.fake_providers(context)
    project_skill(context, name)
  end

  step "the project has the Claude skills {string} and {string}",
       %{args: [first, second]} = context do
    context = World.fake_providers(context)
    context |> project_skill(first) |> project_skill(second)
  end

  step "the project has the Claude skills {string} and {string}, and the header of {string} is malformed",
       %{args: [first, second, _broken]} = context do
    context = World.fake_providers(context)
    context = project_skill(context, first)
    project_skill(context, second, "---\nname: [unclosed\n---\nbody\n")
  end

  step ~r/^"([^"]+)" is offered and "([^"]+)" is not$/, %{args: [good, bad]} = context do
    assert offered(context, good)
    refute offered(context, bad)
    context
  end

  # Where each settings file of the layering lives, for this scenario.
  defp settings_file(context, which) do
    {_context, home} = skills_home(context)
    root = World.project(context).root
    workspace = context[:workspace] || root

    case which do
      "the user's Claude settings" ->
        Path.join(home, "settings.json")

      "the project's Claude settings" ->
        Path.join([workspace, ".claude", "settings.json"])

      "the project's local Claude settings" ->
        Path.join([workspace, ".claude", "settings.local.json"])

      "the repository root's local Claude settings" ->
        Path.join([context.repo_root, ".claude", "settings.local.json"])

      "the repository root's shared Claude settings" ->
        Path.join([context.repo_root, ".claude", "settings.json"])

      "the organisation's managed Claude settings" ->
        managed_file(context)
    end
  end

  defp managed_file(context) do
    case Application.get_env(:hal_c2, :claude_managed_settings_path) do
      nil ->
        path = Path.join(Mc.tmp_dir(context.mc, "claude-managed"), "managed-settings.json")
        World.put_app_env(:claude_managed_settings_path, path)
        path

      path ->
        path
    end
  end

  defp switch_skill(context, which, name, value) do
    {context, _home} = skills_home(context)
    path = settings_file(context, which)
    File.mkdir_p!(Path.dirname(path))

    settings =
      case File.read(path) do
        {:ok, text} -> JSON.decode!(text)
        _ -> %{}
      end

    overrides = Map.put(settings["skillOverrides"] || %{}, name, value)
    File.write!(path, JSON.encode!(Map.put(settings, "skillOverrides", overrides)))
    context
  end

  # A folder inside a git repository, for the layering rows that name its root:
  # the workspace the thread runs in, with the skill in it.
  defp in_repository(context) do
    if context[:repo_root] do
      context
    else
      repo = Mc.tmp_dir(context.mc, "skills-repo")
      File.mkdir_p!(Path.join(repo, ".git"))
      workspace = Path.join(repo, "shop")
      File.mkdir_p!(workspace)

      context
      |> Map.put(:repo_root, repo)
      |> Map.put(:workspace, workspace)
    end
  end

  step "the user's settings switch it off and the managed policy switches it on", context do
    context = switch_skill(context, "the user's Claude settings", "review", "off")
    switch_skill(context, "the organisation's managed Claude settings", "review", "on")
  end

  step "a settings file switches it off but holds a value Claude cannot read", context do
    {context, _home} = skills_home(context)
    path = settings_file(context, "the user's Claude settings")
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      JSON.encode!(%{"skillOverrides" => %{"review" => "off", "other" => "maybe"}})
    )

    context
  end

  step ~r/^(.+) switch(?:es)? "([^"]+)" (off|on)$/, %{args: [file, name, state]} = context do
    context =
      if file =~ "repository root", do: in_repository(context), else: context

    # The project of the layering rows is the workspace inside the repository.
    context = if context[:repo_root], do: project_skill(context, name), else: context
    switch_skill(context, file, name, state)
  end

  step "the project has a Claude skill in the folder {string} whose header names it {string}",
       %{args: [folder, header_name]} = context do
    context = World.fake_providers(context)

    project_skill(
      context,
      folder,
      "---\nname: #{header_name}\ndescription: Reviews code\n---\nReview it.\n"
    )
  end

  step "the skill is offered in the Claude thread as {string}", %{args: [name]} = context do
    assert offered(context, name)
    context
  end

  step "Claude's skill settings switch it on or off under {string}",
       %{args: [name]} = context do
    context = switch_skill(context, "the user's Claude settings", name, "off")
    context = open_skill_list(context)
    assert offered(context, name)["enabled"] == false
    context
  end

  step ~r/^another skill "([^"]+)" in the project's \.claude\/skills$/,
       %{args: [name]} = context do
    project_skill(context, name, "---\ndescription: The project's review\n---\nReview it.\n")
  end

  step ~r/^"([^"]+)" is listed once, with the description of the user's own skill$/,
       %{args: [name]} = context do
    matches = Enum.filter(context.skills, &(&1["name"] == name))
    assert [%{"description" => "The user's own review", "scope" => "user"}] = matches
    context
  end

  step "the project has a Claude skill {string} whose file has no header",
       %{args: [name]} = context do
    context = World.fake_providers(context)
    project_skill(context, name, "# Notes\n\nJust a body.\n")
  end

  step ~r/^"([^"]+)" is offered without a description$/, %{args: [name]} = context do
    skill = offered(context, name)
    assert skill
    refute Map.has_key?(skill, "description")
    context
  end

  step "its header says Claude must not start it by itself", context do
    rewrite_skill(context, "deploy", "---\ndisable-model-invocation: true\n---\nShip it.\n")
  end

  step "its header says so with {string} or {string} instead of {string}",
       %{args: [yes, on, _true]} = context do
    context =
      rewrite_skill(context, "deploy", "---\ndisable-model-invocation: #{yes}\n---\nShip it.\n")

    # The same reading for the other spelling, checked through the parser.
    assert {:ok, frontmatter} =
             HalC2.Claude.Skills.frontmatter("---\ndisable-model-invocation: #{on}\n---\n")

    assert frontmatter["disable-model-invocation"] in [true, on]
    context
  end

  step "Claude's skill settings set it to user-invocable-only", context do
    switch_skill(context, "the user's Claude settings", "deploy", "user-invocable-only")
  end

  defp rewrite_skill(context, name, body) do
    root = context[:workspace] || World.project(context).root
    write_skill_file(Path.join([root, ".claude", "skills"]), name, body)
    context
  end

  step ~r/^"([^"]+)" is offered and marked as started only by the user$/,
       %{args: [name]} = context do
    skill = offered(context, name)
    assert skill["enabled"] == true
    assert skill["userInvocationOnly"] == true
    context
  end

  step "a thread's workspace is a folder nested inside a git repository", context do
    context = context |> World.fake_providers() |> in_repository()
    project_skill(context, "review")
  end

  step "the repository root's shared Claude settings switch the skill {string} off",
       %{args: [name]} = context do
    switch_skill(context, "the repository root's shared Claude settings", name, "off")
  end

  step "Claude settings in folders above a workspace that is in no repository are not read either",
       context do
    parent = Mc.tmp_dir(context.mc, "skills-no-repo")
    child = Path.join(parent, "child")
    File.mkdir_p!(child)

    context =
      context
      |> Map.put(:workspace, child)
      |> project_skill("review")

    path = Path.join([parent, ".claude", "settings.local.json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(%{"skillOverrides" => %{"review" => "off"}}))

    context = open_skill_list(context, child)
    assert offered(context, "review")["enabled"] == true
    context
  end

  step ~r/^the managed Claude settings at (.+) switch the skill "([^"]+)" off$/,
       %{args: [place, name]} = context do
    context = context |> World.fake_providers() |> project_skill(name)
    os = Application.get_env(:hal_c2, :os_type, :os.type())

    file =
      if place =~ "program data" do
        # Windows names its place from PROGRAMDATA, which the scenario can write.
        World.put_os_env("PROGRAMDATA", Mc.tmp_dir(context.mc, "programdata"))
        HalC2.Claude.Skills.default_managed_path(os)
      else
        expected = place |> String.trim() |> String.trim("\"")
        assert HalC2.Claude.Skills.default_managed_path(os) == expected
        path = Path.join(Mc.tmp_dir(context.mc, "claude-managed"), "managed-settings.json")
        World.put_app_env(:claude_managed_settings_path, path)
        path
      end

    File.mkdir_p!(Path.dirname(file))
    File.write!(file, JSON.encode!(%{"skillOverrides" => %{name => "off"}}))
    context
  end

  step "the project's Claude settings hold comments and a trailing comma, and switch the skill {string} off",
       %{args: [name]} = context do
    context = context |> World.fake_providers() |> project_skill(name)
    root = World.project(context).root
    path = Path.join([root, ".claude", "settings.json"])
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    {
      // the team's switches
      "skillOverrides": {
        /* held back for now */
        "#{name}": "off",
      },
    }
    """)

    context
  end

  step "the MC's environment sets the Claude config directory to {string}",
       %{args: [dir]} = context do
    World.put_os_env("CLAUDE_CONFIG_DIR", dir)
    workspace = Mc.tmp_dir(context.mc, "shop")
    write_skill_file(Path.join([workspace, "claude-config", "skills"]), "review", "body\n")
    context |> World.fake_providers() |> Map.put(:workspace, workspace)
  end

  step "the Claude instance has no config directory of its own", context do
    context
  end

  step "the user opens the skill list in a thread whose folder is {string}",
       %{args: [_folder]} = context do
    open_skill_list(context, context.workspace)
  end

  step "skills are read from {string}", %{args: [path]} = context do
    skill = offered(context, "review")
    assert skill
    assert String.ends_with?(path, "claude-config/skills")

    assert skill["path"] ==
             Path.join([context.workspace, "claude-config", "skills", "review", "SKILL.md"])

    context
  end

  step "a config directory written with a leading {string} is not expanded to the user's home",
       %{args: [_tilde]} = context do
    World.put_os_env("CLAUDE_CONFIG_DIR", "~/claude-config")

    write_skill_file(
      Path.join([context.workspace, "~", "claude-config", "skills"]),
      "tilde",
      "body\n"
    )

    context = open_skill_list(context, context.workspace)
    assert offered(context, "tilde")
    context
  end

  step "the Claude instance is disabled", context do
    context = context |> World.fake_providers() |> project_skill("review")

    write_settings(context, fn settings ->
      plugins =
        put_in(settings, [Access.key("providers", %{}), Access.key("claudeAgent", %{})], %{})

      put_in(plugins, ["providers", "claudeAgent", "enabled"], false)
    end)
  end

  step "a client asks for the skills of a project folder", context do
    open_skill_list(context)
  end

  step "no skills are listed and no skill folder is read", context do
    assert context.skills == []
    context
  end

  # --- skill mentions -----------------------------------------------------------------------

  defp last_user_texts(context) do
    World.provider_log(context, "claude")
    |> Enum.filter(&(get_in(&1, ["in", "type"]) == "user"))
    |> List.last()
    |> get_in(["in", "message", "content"])
    |> case do
      text when is_binary(text) -> [text]
      blocks -> for %{"type" => "text", "text" => text} <- blocks, do: text
    end
  end

  step "the user sends {string} to Claude", %{args: [message]} = context do
    context = Map.put(context, :sent_message, message)

    if context[:thread_open] do
      context = World.post_message(context, @thread, message)
      World.await_runs(context, @thread, ["completed", "completed"])
      context
    else
      context = World.launch_on(context, @thread, "claudeAgent", message)
      World.await_runs(context, @thread, ["completed"])
      context
    end
  end

  step "Claude runs its {string} skill", %{args: [name]} = context do
    assert List.last(last_user_texts(context)) =~ ~r{^/#{name}(\s|$)}
    context
  end

  step "the rest of the message still reaches Claude", context do
    assert hd(last_user_texts(context)) == "Please"
    assert List.last(last_user_texts(context)) == "/review the diff"
    context
  end

  step "Claude receives the message exactly as typed", context do
    assert [text] = last_user_texts(context)
    assert text == context.sent_message
    context
  end

  step "Claude receives the message as plain text", context do
    assert ["Please $review the diff"] = last_user_texts(context)
    context
  end

  step "Claude runs the skill {string} with the rest of the message as its request",
       %{args: [name]} = context do
    assert List.last(last_user_texts(context)) == "/#{name} now"
    context
  end

  step "the earlier mention reaches Claude as {string}", %{args: [mention]} = context do
    assert hd(last_user_texts(context)) =~ mention
    context
  end

  step "Claude runs the skill {string}", %{args: [name]} = context do
    assert List.last(last_user_texts(context)) =~ ~r{^/#{name}(\s|$)}
    context
  end

  step ~r/^the project has the Claude skill "([^"]+)" and (.+)$/,
       %{args: [name, state]} = context do
    context = context |> World.fake_providers() |> project_skill(name)

    case state do
      "the skill is switched off" ->
        switch_skill(context, "the user's Claude settings", name, "off")

      "the skill is marked not user-invocable" ->
        rewrite_skill(context, name, "---\nuser-invocable: false\n---\nReview it.\n")

      "the skill was removed since the last message" ->
        context = World.launch_on(context, @thread, "claudeAgent", "Please $review the diff")
        World.await_runs(context, @thread, ["completed"])

        root = World.project(context).root
        File.rm_rf!(Path.join([root, ".claude", "skills", name]))
        Map.put(context, :thread_open, true)
    end
  end

  defp claude_says(context, message) do
    [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, World.thread_id(context, @thread))
    send(pid, {:claude, :sys.get_state(pid).session, {:message, message}})
  end
end
