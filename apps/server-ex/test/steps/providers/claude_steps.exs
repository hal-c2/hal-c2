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

  # --- WinGet, release channels, and who really installed it --------------------------

  step "Claude was installed with WinGet", context do
    context = World.fake_providers(context)
    home = Mc.tmp_dir(context.mc, "claude-winget-home")

    context
    |> claude_at(
      home,
      Path.join([
        "AppData",
        "Local",
        "Microsoft",
        "WinGet",
        "Packages",
        "Anthropic.ClaudeCode",
        "claude"
      ])
    )
    |> latest("claudeAgent", "9.9.9")
  end

  step "a newer Claude is released", context do
    {providers, context} = World.provider_list(context)
    Map.put(context, :providers, providers)
  end

  step "Claude is reported out of date with the command to update it by hand", context do
    assert %{
             "status" => "behind_latest",
             "updateCommand" => "winget upgrade Anthropic.ClaudeCode"
           } =
             claude(context.providers)["versionAdvisory"]

    context
  end

  step "no Update action is offered", context do
    assert claude(context.providers)["versionAdvisory"]["canUpdate"] == false
    context
  end

  # The instance's Claude settings name the channel, in a config directory of
  # their own; the channel offers the installed 2.1.0.
  defp native_channel(context, channel) do
    context = World.fake_providers(context, claude_layout: :native)
    config = Mc.tmp_dir(context.mc, "claude-channel")

    File.write!(
      Path.join(config, "settings.json"),
      JSON.encode!(%{"autoUpdatesChannel" => channel})
    )

    World.put_os_env("CLAUDE_CONFIG_DIR", config)
    World.reset_provider_caches()
    channel_latest(context, channel, "2.1.0")
  end

  step "Claude was installed by its own native installer and follows the {string} channel",
       %{args: [channel]} = context do
    native_channel(context, channel)
  end

  step "Claude was installed by its own native installer", context do
    context |> World.fake_providers(claude_layout: :native) |> latest("claudeAgent", "9.9.9")
  end

  step "npm has published a newer Claude than the {string} channel offers",
       %{args: [_channel]} = context do
    # npm's last read is far ahead; it is not the native channel's to offer.
    :persistent_term.put(
      {HalC2.ProviderUpdates, "claudeAgent"},
      {"9.9.9", System.monotonic_time(:millisecond)}
    )

    context
  end

  step "the installed Claude is the newest the {string} channel offers",
       %{args: [_channel]} = context do
    {providers, context} = World.provider_list(context)
    Map.put(context, :providers, providers)
  end

  step "Claude is reported up to date", context do
    assert %{"status" => "current", "latestVersion" => "2.1.0"} =
             claude(context.providers)["versionAdvisory"]

    context
  end

  step "Claude's release channel does not answer or answers with something unreadable",
       context do
    # No channel read stands (the reset clears the seeded one), and test update
    # checks are off, so none arrives. npm's last read is still ahead.
    World.reset_provider_caches()

    :persistent_term.put(
      {HalC2.ProviderUpdates, "claudeAgent"},
      {"9.9.9", System.monotonic_time(:millisecond)}
    )

    context
  end

  step "the MC checks Claude for updates", context do
    {providers, context} = World.provider_list(context)
    Map.put(context, :providers, providers)
  end

  step "Claude's latest version is unknown", context do
    assert %{"status" => "unknown", "latestVersion" => nil} =
             claude(context.providers)["versionAdvisory"]

    context
  end

  step "Claude is not reported out of date against npm's releases", context do
    refute claude(context.providers)["versionAdvisory"]["status"] == "behind_latest"
    context
  end

  step "npm's global prefix is {string} of the user's home", %{args: [_prefix]} = context do
    context = World.fake_providers(context)
    Map.put(context, :npm_home, Mc.tmp_dir(context.mc, "claude-npm-local"))
  end

  step "the claude command in {string} links into npm's {string} package",
       %{args: [_bin, _package]} = context do
    home = context.npm_home

    real =
      Path.join([home, ".local", "lib", "node_modules", "@anthropic-ai", "claude-code", "cli.js"])

    File.mkdir_p!(Path.dirname(real))

    File.write!(real, """
    #!/bin/sh
    if [ "$1" = "--version" ]; then echo "2.1.0 (Claude Code)"; exit 0; fi
    exec python3 -u #{Path.expand("../../support/fake_claude.py", __DIR__)} "$@"
    """)

    File.chmod!(real, 0o755)
    link = Path.join([home, ".local", "bin", "claude"])
    File.mkdir_p!(Path.dirname(link))
    File.ln_s!(real, link)
    npm = Path.join([home, ".local", "bin", "npm"])
    File.write!(npm, "#!/bin/sh\nexit 0\n")
    File.chmod!(npm, 0o755)
    World.put_os_env("HOME", home)
    World.put_app_env(:claude_command, [link])
    World.reset_provider_caches()
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

  # The model's options as the thread's model picker offers them, and what it launches with.
  # The older models Claude Code lists next to `@listed`.
  @listed_older [
    %{
      "value" => "claude-opus-4-6",
      "resolvedModel" => "claude-opus-4-6",
      "displayName" => "Opus 4.6",
      "supportsEffort" => true,
      "supportedEffortLevels" => ~w(low medium high max)
    },
    %{
      "value" => "claude-opus-4-5",
      "resolvedModel" => "claude-opus-4-5",
      "displayName" => "Opus 4.5",
      "supportsEffort" => true,
      "supportedEffortLevels" => ~w(low medium high)
    },
    %{
      "value" => "claude-haiku-4-5",
      "resolvedModel" => "claude-haiku-4-5",
      "displayName" => "Haiku 4.5"
    }
  ]

  step ~r/^the user opens the options for (?<name>(?:Opus|Sonnet|Haiku) [\d.]+)$/,
       %{args: [name]} = context do
    context = World.fake_providers(context, claude_version: "999.0.0")
    System.put_env("FAKE_CLAUDE_MODELS", JSON.encode!(@listed ++ @listed_older))
    ExUnit.Callbacks.on_exit(fn -> System.delete_env("FAKE_CLAUDE_MODELS") end)
    :ok = HalC2.Claude.Provider.load()
    {providers, context} = World.provider_list(context)
    model = Enum.find(claude(providers)["models"], &(&1["name"] == name))
    assert model, "#{name} is not offered"

    Map.merge(context, %{
      window_model: model,
      window_launch: HalC2.Claude.Provider.launch(model["slug"], %{}),
      option_descriptor: descriptor(model, "contextWindow")
    })
  end

  step "there is no context window option and it runs {word}", %{args: [window]} = context do
    refute descriptor(context.window_model, "contextWindow")
    assert context.window_launch.context_window == window_tokens(window)
    # A fixed 1M window still launches with the CLI's 1M suffix.
    assert String.ends_with?(context.window_launch.model, "[1m]") == (window == "1M")
    context
  end

  defp window_tokens("1M"), do: 1_000_000
  defp window_tokens("200k"), do: 200_000

  step "a thread on Opus 5.5, picked as {string}, that saved a 200k context window",
       %{args: [picked]} = context do
    context = World.providers(context)
    System.put_env("FAKE_CLAUDE_MODELS", JSON.encode!(@listed))
    ExUnit.Callbacks.on_exit(fn -> System.delete_env("FAKE_CLAUDE_MODELS") end)
    :ok = HalC2.Claude.Provider.load()

    selection = %{
      "instanceId" => "claudeAgent",
      "model" => picked,
      "options" => [%{"id" => "contextWindow", "value" => "200k"}]
    }

    Map.put(context, :saved_selection, selection)
  end

  step "the user sends it a message", context do
    context
    |> World.launch_on(@thread, "claudeAgent", "report your usage", %{
      "modelSelection" => context.saved_selection
    })
    |> tap(&World.await_runs(&1, @thread, ["completed"]))
  end

  step "Claude is started as {string} and the context meter is out of 1,000,000 tokens",
       %{args: [started]} = context do
    # The first start is the CLI probe; the turn is the last.
    argv = List.last(World.claude_starts(context))
    assert ["--model", started] in pairs(argv)
    assert context_usage(context)["maxTokens"] == 1_000_000
    context
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
    # The CLI's `opus` alias resolves to Opus 5.5, whose 1M window is fixed.
    refute descriptor(listed_model(context, "opus"), "contextWindow")
    assert descriptor(listed_model(context, "claude-sonnet-4-6"), "contextWindow")
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

  step "a Claude thread uses a model that is not in HAL-C2's model list", context do
    context |> World.fake_providers() |> Map.put(:model, "claude-unlisted-9")
  end

  step "the user chooses {string} effort and sends a message", %{args: [effort]} = context do
    selection = %{
      "instanceId" => "claudeAgent",
      "model" => context.model,
      "options" => [%{"id" => "effort", "value" => effort}]
    }

    context =
      World.launch_on(context, @thread, "claudeAgent", "hello", %{"modelSelection" => selection})

    World.await_runs(context, @thread, ["completed"])
    assert [argv] = for(%{"argv" => argv} <- World.provider_log(context, "claude"), do: argv)
    Map.put(context, :argv, argv)
  end

  step "Claude runs the turn with {string} effort", %{args: [effort]} = context do
    assert ["--model", context.model] in pairs(context.argv)
    assert ["--effort", effort] in pairs(context.argv)
    context
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

  # --- plan names, sign-in state, custom endpoints ------------------------------------

  step "the Claude CLI is signed in with the {string} subscription",
       %{args: [subscription]} = context do
    World.put_os_env("FAKE_CLAUDE_SUBSCRIPTION", subscription)
    World.fake_providers(context)
  end

  step "Claude shows the plan as {string}", %{args: [plan]} = context do
    assert %{"label" => ^plan} = claude(context.providers)["auth"]
    context
  end

  # No key or token anywhere Claude would read one, and `claude auth status`
  # itself says nobody is signed in.
  defp signed_out(context) do
    World.put_os_env("ANTHROPIC_API_KEY", nil)
    World.put_os_env("ANTHROPIC_AUTH_TOKEN", nil)
    World.put_os_env("ANTHROPIC_BASE_URL", nil)
    World.put_os_env("FAKE_CLAUDE_AUTH_STATUS", ~s({"loggedIn":false,"authMethod":"none"}))
    World.reset_provider_caches()
    context
  end

  step "the Claude CLI on the MC reports no account, no API key and no token", context do
    context |> World.fake_providers() |> signed_out()
  end

  step "the Claude CLI is not signed in", context do
    context |> World.fake_providers() |> signed_out()
  end

  step "the Claude CLI on the MC uses an API key", context do
    World.put_os_env("ANTHROPIC_API_KEY", "sk-ant-test")
    context |> World.fake_providers() |> Map.put(:auth_checked, true)
  end

  step "the Claude CLI on the MC runs through Bedrock or Vertex", context do
    World.put_os_env("CLAUDE_CODE_USE_BEDROCK", "1")
    World.fake_providers(context)
  end

  step "the Claude CLI on the MC is too old to report its account", context do
    World.put_os_env("FAKE_CLAUDE_AUTH_STATUS", "unknown")
    World.fake_providers(context, claude_version: "1.0.44")
  end

  step "the user looks at Claude in the provider settings", context do
    {providers, context} = World.provider_list(context)
    Map.put(context, :providers, providers)
  end

  # The sign-in read lands in the background and re-announces the providers;
  # wait for the announcement that carries `status`, and keep its list.
  defp await_claude_auth(context, status) do
    if get_in(claude(context.providers || []), ["auth", "status"]) == status do
      context
    else
      id = System.unique_integer([:positive])
      # A connection of its own: the default one already holds a config
      # subscription, and a second on it gets no first frame.
      name = "claude-auth-#{id}"

      client =
        Mc.sub(World.client(context, name), id, %{
          "type" => "config",
          "mc" => Atom.to_string(node())
        })

      # The first frame is the whole config; re-announcements carry only the
      # providers (`config.providers`).
      providers_of = fn
        %{"t" => "config", "config" => %{"providers" => providers}} -> providers
        %{"t" => "config.providers", "providers" => providers} -> providers
        _ -> nil
      end

      settled = fn frame ->
        frame["id"] == id and
          get_in(claude(providers_of.(frame) || []), ["auth", "status"]) == status
      end

      {frame, client} = Mc.await(client, settled, 10_000)

      context
      |> World.put_client(name, client)
      |> Map.put(:providers, providers_of.(frame))
    end
  end

  step "Claude is shown as not signed in, with {string} as the fix",
       %{args: [fix]} = context do
    context = await_claude_auth(context, "unauthenticated")
    assert %{"status" => "unauthenticated"} = claude(context.providers)["auth"]
    assert claude(context.providers)["message"] =~ fix
    context
  end

  step "Claude is shown as signed in", context do
    context = await_claude_auth(context, "authenticated")
    assert %{"status" => "authenticated"} = claude(context.providers)["auth"]
    assert claude(context.providers)["status"] == "ready"
    context
  end

  step "the user signs in with Claude and refreshes the providers", context do
    World.put_os_env("FAKE_CLAUDE_AUTH_STATUS", ~s({"loggedIn":true,"authMethod":"claude.ai"}))

    {result, context} =
      World.call!(context, "server.refreshProviders", %{"instanceId" => "claudeAgent"})

    Map.put(context, :providers, result["providers"])
  end

  step "the user is told to update Claude Code to use that model", context do
    {providers, context} = World.provider_list(context)
    {min, model} = lowest_gated(claude(providers)["version"])
    assert claude(providers)["message"] =~ "is too old for #{model["name"]}"
    assert claude(providers)["message"] =~ "Upgrade to v#{min} or newer"
    Map.put(context, :providers, providers)
  end

  step "the sign-in hint is still shown", context do
    context = await_claude_auth(context, "unauthenticated")
    assert %{"status" => "unauthenticated"} = claude(context.providers)["auth"]
    assert claude(context.providers)["message"] =~ "claude auth login"
    context
  end

  # The built-in instance's own variables, as Settings > Providers writes them.
  defp instance_env(context, vars) do
    write_settings(context, fn settings ->
      put_in(settings, [Access.key("providerInstances", %{}), "claudeAgent"], %{
        "driver" => "claudeAgent",
        "enabled" => true,
        "environment" =>
          Enum.map(vars, fn {name, value} ->
            %{"name" => name, "value" => value, "sensitive" => true}
          end)
      })
    end)
  end

  step "a Claude instance whose environment sets a custom ANTHROPIC_BASE_URL and key",
       context do
    context
    |> World.fake_providers()
    |> instance_env(%{
      "ANTHROPIC_BASE_URL" => "https://router.test/api",
      "ANTHROPIC_API_KEY" => "[REDACTED]"
    })
  end

  # The provider entries the MC serves, read in-process: a check whose version
  # probe takes 15 seconds outlasts a socket frame's wait.
  step "the MC checks Claude", context do
    Map.put(context, :providers, HalC2.Environment.providers())
  end

  step "Claude is reported ready", context do
    assert %{"status" => "ready", "auth" => %{"status" => "authenticated"}} =
             claude(context.providers)

    context
  end

  step "the user is not asked to sign in", context do
    refute (claude(context.providers)["message"] || "") =~ "claude auth login"
    context
  end

  step "Claude's settings file sets ANTHROPIC_BASE_URL and ANTHROPIC_AUTH_TOKEN in its env",
       context do
    context = World.fake_providers(context)
    config = Mc.tmp_dir(context.mc, "claude-proxy")

    File.write!(
      Path.join(config, "settings.json"),
      JSON.encode!(%{
        "env" => %{
          "ANTHROPIC_BASE_URL" => "https://proxy.test",
          "ANTHROPIC_AUTH_TOKEN" => "[REDACTED]"
        }
      })
    )

    # The proxy login is what `initialize` reports: an auth token, no subscription.
    World.put_os_env("CLAUDE_CONFIG_DIR", config)
    World.put_os_env("FAKE_CLAUDE_TOKEN_SOURCE", "ANTHROPIC_AUTH_TOKEN")
    World.reset_provider_caches()
    Mc.ensure(HalC2.ProviderUsageLimits)
    :ok = HalC2.ProviderUsageLimits.refresh(["claudeAgent"])
    :sys.get_state(HalC2.ProviderUsageLimits)
    context
  end

  step "the MC's own environment sets neither", context do
    World.put_os_env("ANTHROPIC_BASE_URL", nil)
    World.put_os_env("ANTHROPIC_AUTH_TOKEN", nil)
    context
  end

  step "Claude is reported ready with {string}", %{args: [label]} = context do
    assert %{"status" => "ready", "auth" => %{"status" => "authenticated", "label" => ^label}} =
             claude(context.providers)

    context
  end

  step "the Claude account has a monthly spending limit, 40 percent used", context do
    World.put_os_env("FAKE_CLAUDE_MONTHLY", "40")
    World.fake_providers(context)
  end

  step "Claude shows a monthly window at 40 percent with its reset date", context do
    {providers, context} = World.provider_list(context)
    windows = claude(providers)["usageLimits"]["windows"]

    assert %{"kind" => "monthly", "usedPercent" => 40.0, "resetsAt" => resets} =
             Enum.find(windows, &(&1["kind"] == "monthly"))

    assert resets =~ "2026-10-01"
    context
  end

  # The first `--version` takes the 15 seconds; the deadline is what is under
  # test, so later probes of the same check answer at once.
  step "Claude takes 15 seconds to report its version", context do
    context = World.fake_providers(context)
    marker = Path.join(Mc.tmp_dir(context.mc, "slow-version"), "reported")

    claude_script(
      context,
      "claude",
      """
      #!/bin/sh
      if [ "$1" = "--version" ]; then
        if [ ! -e #{marker} ]; then touch #{marker}; sleep 15; fi
        echo "2.1.0 (Claude Code)"; exit 0
      fi
      exec python3 -u #{Path.expand("../../support/fake_claude.py", __DIR__)} "$@"
      """
    )
  end

  step "Claude is not reported as failing to run", context do
    assert %{"status" => "ready", "version" => "2.1.0"} = claude(context.providers)
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
    # The MC's services run from the start, as they do in the MC: one first started by
    # the next message (`World.send_turn/3`) would change that turn's launch, and the
    # new process would end the monitor.
    context =
      context
      |> World.fake_providers()
      |> World.providers()
      |> World.launch_on(@thread, "claudeAgent", "start a monitor")

    World.await_runs(context, @thread, ["completed"])
    Map.put(context, :thread, @thread)
  end

  # The sidebar row lists background work once the thread's runs have settled
  # (`HalC2.Projection.BackgroundWork`); while a later run is active, the clients' Agents
  # list shows the monitor from its own item, still live under the run that started it.
  step "the thread lists the monitor as background work", context do
    id = World.thread_id(context, @thread)
    state = World.stream(context, @thread)

    active =
      for %{"status" => s} = run <- StreamState.list(state, "run"),
          s in ~w(preparing starting running),
          do: run["id"]

    if active == [] do
      World.await_row(
        id,
        &match?(
          [%{"taskId" => "mon-1", "taskType" => "dynamic_tool", "description" => "Monitor"}],
          &1["runningBackgroundTasks"]
        )
      )
    else
      assert [monitor] =
               for(
                 %{"type" => "dynamic_tool", "toolName" => "Monitor"} = item <-
                   StreamState.list(state, "turn-item"),
                 do: item
               )

      assert monitor["status"] in ~w(pending running waiting)
      refute monitor["runId"] in active
    end

    context
  end

  step "the user sends another message and its turn is running", context do
    # The monitor is background work before the next message lands.
    World.await_row(
      World.thread_id(context, @thread),
      &match?(
        [%{"taskId" => "mon-1", "taskType" => "dynamic_tool", "description" => "Monitor"}],
        &1["runningBackgroundTasks"]
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

    World.await_row(World.thread_id(context, @thread), &(&1["runningBackgroundTasks"] == []))
    context
  end

  # --- a foreground fork --------------------------------------------------------------

  # Claude Code's frames for `Agent` with subagent_type "fork" in the foreground: the
  # fork's own stream opens with a placeholder result for its launch call.
  step "Claude starts a fork of itself in the foreground", context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "claudeAgent", "wait while you fork")

    World.await_running(context, @thread)

    claude_says(context, %{
      "type" => "assistant",
      "message" => %{
        "id" => "m-fork",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "fork-1",
            "name" => "Agent",
            "input" => %{
              "description" => "Fork to check the tests",
              "prompt" => "Check the tests",
              "subagent_type" => "fork",
              "run_in_background" => false
            }
          }
        ]
      }
    })

    claude_says(context, %{
      "type" => "system",
      "subtype" => "task_started",
      "task_id" => "task-fork-1",
      "tool_use_id" => "fork-1",
      "description" => "Fork to check the tests",
      "subagent_type" => "fork",
      "task_type" => "local_agent",
      "is_backgrounded" => false
    })

    claude_says(context, %{
      "type" => "user",
      "parent_tool_use_id" => "fork-1",
      "message" => %{
        "role" => "user",
        "content" => [
          %{
            "type" => "tool_result",
            "tool_use_id" => "fork-1",
            "content" => "Fork started — that fork is you."
          }
        ]
      }
    })

    flush_runtime(context)
  end

  step "the fork shows as working until it ends", context do
    assert [%{"status" => "running", "result" => nil}] =
             World.entities(context, @thread, "subagent")

    claude_says(context, %{
      "type" => "assistant",
      "parent_tool_use_id" => "fork-1",
      "message" => %{
        "id" => "m-fork-says",
        "content" => [%{"type" => "text", "text" => "FORK-DONE"}]
      }
    })

    claude_says(context, %{
      "type" => "system",
      "subtype" => "task_notification",
      "task_id" => "task-fork-1",
      "tool_use_id" => "fork-1",
      "status" => "completed",
      "summary" => "FORK-DONE"
    })

    claude_says(context, %{
      "type" => "user",
      "message" => %{
        "role" => "user",
        "content" => [
          %{
            "type" => "tool_result",
            "tool_use_id" => "fork-1",
            "content" => "[Subagent hand-back] FORK-DONE"
          }
        ]
      }
    })

    claude_says(context, %{"type" => "result", "subtype" => "success", "is_error" => false})
    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "its result is what the fork answers, not the note that it started", context do
    assert [%{"status" => "completed", "result" => result} = subagent] =
             World.entities(context, @thread, "subagent")

    assert result =~ "FORK-DONE"
    child = HalC2.Streams.Server.state(HalC2.Streams.ensure(subagent["childThreadId"]))

    refute Enum.any?(
             StreamState.list(child, "turn-item"),
             &(inspect(&1, limit: :infinity) =~ "Fork started")
           )

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

  # A turn the MC never saw start a subagent (Claude's own session started it, say,
  # before the thread came to the MC); the next turn sends that subagent a message.
  step "the MC missed the launch of a Claude subagent", context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "claudeAgent", "hello")

    World.await_runs(context, @thread, ["completed"])
    assert [] = World.entities(context, @thread, "subagent")
    context
  end

  step "Claude resumes that subagent", context do
    context = World.post_message(context, @thread, "wait and resume it")
    World.await_running(context, @thread)

    World.await_provider_log(
      context,
      "claude",
      &(inspect(get_in(&1, ["in", "message", "content"])) =~ "wait and resume it")
    )

    send_to_subagent(context, "send-1", "Also check the tests", "Check the tests")
    claude_says(context, %{"type" => "result", "subtype" => "success", "is_error" => false})
    World.await_runs(context, @thread, ["completed", "completed"])
    context
  end

  step "the subagent gets its own child thread", context do
    state = World.stream(context, @thread)
    assert [subagent] = StreamState.list(state, "subagent")
    assert %{"status" => "completed", "result" => "The tests pass"} = subagent
    assert subagent["nativeTaskId"] == "task-agent-7"
    child = HalC2.Streams.Server.state(HalC2.Streams.ensure(subagent["childThreadId"]))
    assert %{"title" => title} = StreamState.get(child, "thread")[subagent["childThreadId"]]
    assert title =~ "Check the tests"

    assert [{"user_message", "Also check the tests"}, {"assistant_message", "The tests pass"}] =
             child
             |> StreamState.list("turn-item")
             |> Enum.sort_by(& &1["ordinal"])
             |> Enum.filter(&(&1["type"] in ["user_message", "assistant_message"]))
             |> Enum.map(&{&1["type"], &1["text"]})

    # The message is the subagent's, not a tool call of the parent's.
    refute Enum.any?(StreamState.list(state, "turn-item"), &(&1["toolName"] == "SendMessage"))
    Map.put(context, :subagent, subagent)
  end

  # Resumed again, under another description: the child thread it has is kept as it is.
  step "an existing child thread keeps its title and model", context do
    child_id = context.subagent["childThreadId"]

    read = fn ->
      HalC2.Streams.Server.state(HalC2.Streams.ensure(child_id))
      |> StreamState.get("thread")
      |> Map.get(child_id)
    end

    before = read.()
    context = World.post_message(context, @thread, "wait and resume it again")
    World.await_running(context, @thread)

    World.await_provider_log(
      context,
      "claude",
      &(inspect(get_in(&1, ["in", "message", "content"])) =~ "wait and resume it again")
    )

    send_to_subagent(context, "send-2", "And the docs", "Something else entirely")
    claude_says(context, %{"type" => "result", "subtype" => "success", "is_error" => false})
    World.await_runs(context, @thread, ["completed", "completed", "completed"])

    assert [subagent] = World.entities(context, @thread, "subagent")
    assert subagent["childThreadId"] == child_id
    assert subagent["title"] == context.subagent["title"]
    assert subagent["model"] == context.subagent["model"]
    after_resume = read.()
    assert after_resume["title"] == before["title"]
    assert after_resume["modelSelection"] == before["modelSelection"]
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

  # The fake's "in the background" turn leaves its subagent (task task-agent-1) running;
  # the MC restarts under it.
  step "a Claude subagent was working when the MC restarted", context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "claudeAgent", "survey in the background")

    World.await_runs(context, @thread, ["completed"])

    World.await_value(context, @thread, fn state ->
      match?([%{"status" => "running"}], StreamState.list(state, "subagent"))
    end)

    # The runtimes go as the MC stops, which leaves their work to the next boot's recovery.
    HalC2.Orchestration.Recovery.leaving(true)

    try do
      %{
        context
        | mc: Mc.restart(context.mc, fn -> HalC2.Orchestration.Recovery.leaving(false) end),
          clients: %{}
      }
    after
      HalC2.Orchestration.Recovery.leaving(false)
    end
  end

  step "recovery marked it cancelled", context do
    state = World.stream(context, @thread)
    assert [%{"status" => "interrupted"} = subagent] = StreamState.list(state, "subagent")
    assert %{"status" => "interrupted"} = item = subagent_item(state, subagent)
    assert HalC2.Orchestration.Recovery.cut_off?(item)
    assert World.row(context, @thread)["pendingBackgroundTasks"] == []
    Map.put(context, :subagent, subagent)
  end

  step "the user's next message makes Claude resume the subagent", context do
    context = World.post_message(context, @thread, "wait and resume it")
    World.await_running(context, @thread)

    World.await_provider_log(
      context,
      "claude",
      &(inspect(get_in(&1, ["in", "message", "content"])) =~ "wait and resume it")
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

    flush_runtime(context)
  end

  step "the subagent's thread shows it running again, not cancelled", context do
    state = World.stream(context, @thread)

    assert [%{"status" => "running", "completedAt" => nil} = subagent] =
             StreamState.list(state, "subagent")

    assert subagent["childThreadId"] == context.subagent["childThreadId"]
    assert %{"status" => "running"} = item = subagent_item(state, subagent)
    refute HalC2.Orchestration.Recovery.cut_off?(item)
    assert %{"status" => "running"} = StreamState.get(state, "node")[subagent["id"]]
    context
  end

  # The parent's turn ends with the resumed subagent still at work in the background.
  step "its resume prompt, tool calls and final answer appear in its own thread", context do
    sidechain = &Map.put(&1, "parent_tool_use_id", "send-1")

    claude_says(
      context,
      sidechain.(%{
        "type" => "assistant",
        "message" => %{
          "id" => "m-sub-1",
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "sub-bash-1",
              "name" => "Bash",
              "input" => %{"command" => "mix test"}
            }
          ]
        }
      })
    )

    claude_says(
      context,
      sidechain.(%{
        "type" => "user",
        "message" => %{
          "role" => "user",
          "content" => [
            %{
              "type" => "tool_result",
              "tool_use_id" => "sub-bash-1",
              "content" => "12 tests, 0 failures"
            }
          ]
        }
      })
    )

    claude_says(
      context,
      sidechain.(%{
        "type" => "assistant",
        "message" => %{
          "id" => "m-sub-2",
          "content" => [%{"type" => "text", "text" => "The tests pass"}]
        }
      })
    )

    claude_says(context, %{"type" => "result", "subtype" => "success", "is_error" => false})
    World.await_runs(context, @thread, ["completed", "completed"])

    child = HalC2.Streams.Server.state(HalC2.Streams.ensure(context.subagent["childThreadId"]))
    items = Enum.sort_by(StreamState.list(child, "turn-item"), & &1["ordinal"])

    assert [
             {"user_message", "List what is in the repo"},
             {"user_message", "Also check the tests"},
             {"assistant_message", "The tests pass"}
           ] =
             for(
               %{"type" => type} = item <- items,
               type in ["user_message", "assistant_message"],
               do: {type, item["text"]}
             )

    assert %{"status" => "completed", "output" => "12 tests, 0 failures"} =
             Enum.find(items, &(&1["input"] == "mix test"))

    context
  end

  step "the subagent's thread and the parent's waiting list agree on its state", context do
    assert [%{"status" => "running"}] =
             StreamState.list(World.stream(context, @thread), "subagent")

    World.await_row(
      World.thread_id(context, @thread),
      &match?(
        [%{"taskType" => "subagent", "description" => "Survey the repo"}],
        &1["pendingBackgroundTasks"]
      )
    )

    claude_says(context, %{
      "type" => "system",
      "subtype" => "task_notification",
      "task_id" => "task-agent-1",
      "tool_use_id" => "send-1",
      "status" => "completed",
      "summary" => "The tests pass"
    })

    World.await_row(World.thread_id(context, @thread), &(&1["pendingBackgroundTasks"] == []))

    assert [%{"status" => "completed", "result" => "The tests pass"} = subagent] =
             StreamState.list(World.stream(context, @thread), "subagent")

    refute HalC2.Orchestration.Recovery.cut_off?(
             subagent_item(World.stream(context, @thread), subagent)
           )

    context
  end

  defp subagent_item(state, subagent),
    do: StreamState.get(state, "turn-item")["turn-item:subagent:#{subagent["id"]}"]

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
  step "the user added the custom Claude model {string}, which is not in the catalog",
       %{args: [model]} = context do
    context =
      context
      |> World.fake_providers()
      |> write_settings(fn settings ->
        put_in(
          settings,
          [Access.key("providerInstances", %{}), Access.key("claudeAgent", %{})],
          %{"driver" => "claudeAgent", "config" => %{"customModels" => [model]}}
        )
      end)

    refute HalC2.Claude.Provider.known?(model)
    Map.put(context, :model, model)
  end

  step ~r/^a Claude turn runs on it and Claude reports a context window of (?<size>[\d,]+) tokens$/,
       %{args: [size]} = context do
    World.put_os_env("FAKE_CLAUDE_CONTEXT_WINDOW", String.replace(size, ",", ""))

    context
    |> World.launch_on(@thread, "claudeAgent", "report your usage", %{
      "modelSelection" => %{"instanceId" => "claudeAgent", "model" => context.model}
    })
    |> tap(&World.await_runs(&1, @thread, ["completed"]))
  end

  step ~r/^the context meter is out of (?<size>[\d,]+) tokens before the turn settles$/,
       %{args: [size]} = context do
    # The usage is written with Claude's result, before the run completes.
    assert context_usage(context)["maxTokens"] ==
             size |> String.replace(",", "") |> String.to_integer()

    context
  end

  step "a model in the catalog keeps the catalog's window", context do
    assert HalC2.Claude.Provider.known?("sonnet")

    context =
      context
      |> World.launch_on("Catalog", "claudeAgent", "report your usage", %{
        "modelSelection" => %{"instanceId" => "claudeAgent", "model" => "sonnet"}
      })
      |> tap(&World.await_runs(&1, "Catalog", ["completed"]))

    assert [%{"tokenUsage" => %{"maxTokens" => window}}] =
             World.entities(context, "Catalog", "provider-turn")

    assert window == HalC2.Claude.Provider.launch("sonnet", %{}).context_window
    assert window != 204_800
    context
  end

  step "Claude runs through a gateway that reports zero tokens when a message starts", context do
    World.put_os_env("FAKE_CLAUDE_GATEWAY_USAGE", "1")
    World.fake_providers(context)
  end

  step "the gateway reports the real counts as the message ends", context do
    context = World.launch_on(context, @thread, "claudeAgent", "hello")
    World.await_runs(context, @thread, ["completed"])
    Map.put(context, :usage, context_usage(context))
  end

  step "the context meter shows those counts", context do
    assert %{
             "usedTokens" => 41_580,
             "inputTokens" => 41_500,
             "cachedInputTokens" => 40_000,
             "outputTokens" => 80
           } = context.usage

    context
  end

  step "a compaction is not undone by usage from before it", context do
    context = World.post_message(context, @thread, "compact, then")
    World.await_runs(context, @thread, ["completed", "completed"])
    assert %{"usedTokens" => 5000} = context_usage(context)
    context
  end

  defp context_usage(context) do
    World.entities(context, @thread, "provider-turn")
    |> Enum.filter(& &1["tokenUsage"])
    |> Enum.max_by(& &1["tokenUsage"]["updatedAt"], fn -> %{} end)
    |> Map.get("tokenUsage")
  end

  # Opus 5.5 always runs with a 1M window.
  step ~r/^Claude is set to compact the conversation at (?<size>[\d,]+) tokens on a model with a larger window$/,
       %{args: [size]} = context do
    context
    |> World.fake_providers(claude_version: "999.0.0")
    |> World.put_settings(%{
      "providers" => %{"claudeAgent" => %{"autoCompactWindow" => String.replace(size, ",", "")}}
    })
    |> Map.put(:model, "claude-opus-5-5")
  end

  step "the user looks at the context meter", context do
    context
    |> World.launch_on(@thread, "claudeAgent", "report your usage", %{
      "modelSelection" => %{"instanceId" => "claudeAgent", "model" => context.model}
    })
    |> tap(&World.await_runs(&1, @thread, ["completed"]))
  end

  step ~r/^it says the conversation compacts at about (?<size>[\d,]+) tokens$/,
       %{args: [size]} = context do
    assert %{"maxTokens" => 1_000_000, "autoCompactThreshold" => at} = context_usage(context)
    assert at == size |> String.replace(",", "") |> String.to_integer()
    context
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
    title = if context[:provider] == "pi", do: context.thread, else: @thread
    context = World.post_message(context, title, "hello")

    World.await_value(context, title, fn state ->
      runs = StreamState.list(state, "run")
      length(runs) == 2 and Enum.all?(runs, &(&1["status"] in ["completed", "failed"]))
    end)

    context
  end

  # After a revert to the compaction's end, the next message resumes the
  # conversation at the compaction itself.
  defp continues_after_compact_revert(context) do
    context = World.post_message(context, @thread, "where are we")
    World.await_latest_run(context, @thread, "completed")

    assert Enum.any?(
             World.replies(context, @thread),
             &String.starts_with?(&1, "resumed at compact-")
           ),
           inspect(World.replies(context, @thread))

    context
  end

  # The same Claude session takes the message: nothing is started again, or resumed
  # from before the compaction.
  step "Claude continues from the compacted conversation", context do
    if context[:compact_reverted] do
      continues_after_compact_revert(context)
    else
      continues_after_compaction(context)
    end
  end

  defp continues_after_compaction(context) do
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

  # The fake's "in the background" turn leaves a background task running when its
  # process goes; the process that resumes the session reports it stopped in a turn of
  # its own before the next message (FAKE_CLAUDE_ORPHANED).
  step "a resumed Claude thread whose previous process left a background task", context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "claudeAgent", "survey in the background")

    World.await_runs(context, @thread, ["completed"])
    release_claude(context)
    World.put_os_env("FAKE_CLAUDE_ORPHANED", "task-agent-1")
    context
  end

  step "the user compacts the thread", context do
    context = World.post_message(context, @thread, "/compact")

    World.await_value(context, @thread, fn state ->
      runs = StreamState.list(state, "run")

      length(runs) >= 2 and Enum.all?(runs, &(&1["status"] in ["completed", "failed"])) and
        Enum.any?(StreamState.list(state, "turn-item"), &(&1["type"] == "compaction"))
    end)

    context
  end

  step "the turn completes once, after the real compaction", context do
    assert [_, %{"status" => "completed"} = compact] = World.runs(context, @thread)

    assert [%{"beforeTokenCount" => 27_445, "afterTokenCount" => 1192} = compaction] =
             compactions(context)

    # The compaction is the /compact run's, which ended no earlier than it.
    assert compaction["runId"] == compact["id"]
    assert compact["completedAt"] >= compaction["completedAt"]
    context
  end

  step "no made-up \"Compacted context\" row is shown", context do
    titles = for item <- World.entities(context, @thread, "turn-item"), do: item["title"]
    refute "Compacted context" in titles
    assert Enum.count(titles, &(&1 == "Context compacted")) == 1
    context
  end

  step "the thread does not stay busy afterwards", context do
    assert Enum.all?(World.runs(context, @thread), &(&1["status"] == "completed"))
    assert World.latest_run(context, @thread)["status"] == "completed"
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
             "CLAUDE_CODE_ENTRYPOINT" => "hal-c2",
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

  # Plan mode wins over Full access: Claude runs in its plan mode, and every tool it
  # asks about there reaches the user instead of being approved for them.
  step "a Claude thread in plan mode with full access", context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "claudeAgent", "wait for me", %{
        "interactionMode" => "plan",
        "runtimeMode" => "full-access"
      })

    World.await_running(context, @thread)
    World.await_provider_log(context, "claude", &(get_in(&1, ["in", "type"]) == "user"))
    assert flag_value(last_argv(context), "--permission-mode") == "plan"
    refute "--dangerously-skip-permissions" in last_argv(context)
    context
  end

  step "Claude asks to write a file while planning", context do
    context = claude_asks(context, "perm-plan-write", "Write", tool_input("Write"))
    Map.put(context, :request, World.await_request(context, @thread))
  end

  step "the user is asked to approve the write", context do
    assert %{"kind" => "file-change", "status" => "pending"} = context.request
    assert [%{"status" => "running"}] = World.runs(context, @thread)
    context
  end

  step "the plan Claude proposed is still captured", context do
    claude_asks(context, "perm-plan-exit", "ExitPlanMode", %{"plan" => "# Plan\n- write it"})

    World.await_value(context, @thread, fn state ->
      Enum.any?(
        StreamState.list(state, "plan"),
        &(&1["kind"] == "proposed_plan" and &1["markdown"] =~ "write it")
      )
    end)

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

  step "Claude asked whether to compact a long conversation before resuming it", context do
    context = context |> World.providers() |> World.launch_on(@thread, "claudeAgent", "hello")
    World.await_runs(context, @thread, ["completed"])
    :ok = HalC2.Orchestration.release_session(World.thread_id(context, @thread))
    context = World.send_turn(context, @thread, "long session")
    Map.put(context, :request, World.await_request(context, @thread))
  end

  step "the user answers and the turn completes", context do
    [%{"questions" => [question]}] =
      for i <- StreamState.list(World.stream(context, @thread), "turn-item"),
          i["type"] == "user_input_request",
          do: i

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "runtime-request.respond",
        "threadId" => World.thread_id(context, @thread),
        "requestId" => context.request["id"],
        "answers" => %{question["id"] => "Compact and continue"}
      })

    World.await_runs(context, @thread, ["completed", "completed"])
    assert "resume compact" in World.replies(context, @thread)
    context
  end

  step "the turn's work shows no failed tool call for the question", context do
    items = StreamState.list(World.stream(context, @thread), "turn-item")
    assert [] = for(i <- items, i["status"] == "failed", do: {i["type"], i["toolName"]})
    assert [%{"status" => status}] = for(i <- items, i["type"] == "user_input_request", do: i)
    refute status == "waiting"
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

    # A turn that fails to start (a launch argument that could not be read)
    # still started, and failed.
    World.await_value(context, @thread, fn state ->
      match?(
        [%{"status" => status}] when status in ["completed", "failed"],
        StreamState.list(state, "run")
      )
    end)

    context
  end

  step "Claude's process arguments do not contain the credential for the HAL-C2 tools", context do
    %{"argv" => argv} = World.await_provider_log(context, "claude", &Map.has_key?(&1, "argv"))

    # The credential goes over stdin (`mcp_set_servers`), and no config file is named.
    token = hal_c2_token(context)
    assert byte_size(token) >= 16
    refute Enum.any?(argv, &String.contains?(&1, token))
    refute "--mcp-config" in argv
    context
  end

  # HAL-C2's tools reach the commands Claude runs only through Claude: with the
  # environment scrubbed for them, the tools must still work.
  step "a Claude thread has HAL-C2's tools", context do
    context = World.fake_providers(context)
    Mc.ensure(HalC2.Mcp)
    World.put_env("CLAUDE_CODE_SUBPROCESS_ENV_SCRUB", "1")
    context
  end

  # The fake runs `env` as a child, as Claude runs a shell command, a hook or a local
  # MCP server, and answers with what it printed.
  step "Claude runs a shell command, a hook or a local MCP server", context do
    context = World.launch_on(context, @thread, "claudeAgent", "run env")
    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "none of them can read the credential Claude uses to reach HAL-C2's tools", context do
    token = hal_c2_token(context)
    [printed] = World.replies(context, @thread)
    assert printed =~ "PATH="
    refute printed =~ token

    %{"argv" => argv} = World.await_provider_log(context, "claude", &Map.has_key?(&1, "argv"))
    refute Enum.any?(argv, &String.contains?(&1, token))

    # Nor any file the MC keeps, which the commands could read; the fakes' own logs
    # are this test's record of what Claude was sent.
    instruments = [
      Path.join(context.mc.home, "fakes") | Path.wildcard(Path.join(context.mc.home, "claude-*"))
    ]

    leaks =
      for path <- Path.wildcard(Path.join(context.mc.home, "**"), match_dot: true),
          not Enum.any?(instruments, &String.starts_with?(path, &1)),
          File.regular?(path),
          File.read!(path) =~ token,
          do: path

    assert leaks == []
    context
  end

  step "HAL-C2's tools still work when Claude scrubs its subprocess environment", context do
    assert System.get_env("CLAUDE_CODE_SUBPROCESS_ENV_SCRUB")
    call_hal_c2_tools(context)
  end

  step "Claude rejects the MCP servers HAL-C2 hands it", context do
    context = World.fake_providers(context)
    Mc.ensure(HalC2.Mcp)
    World.put_env("FAKE_CLAUDE_MCP_REFUSE", "1")
    World.capture_log(context)
  end

  step "the turn runs without HAL-C2's tools", context do
    assert [%{"hal-c2" => _}] = World.claude_mcp_servers(context)
    context = World.post_message(context, @thread, "which tools")
    World.await_runs(context, @thread, ["completed", "completed"])
    assert "tools: none" in World.replies(context, @thread)
    context
  end

  step "the log names the servers but none of the error text", context do
    log = World.logged(context)
    assert log =~ "MCP servers it refused: hal-c2"
    refute log =~ "Connection failed"
    refute log =~ hal_c2_token(context)
    context
  end

  # The credential Claude was last handed for HAL-C2's server, over stdin.
  defp hal_c2_server(context) do
    %{"hal-c2" => server} = List.last(World.claude_mcp_servers(context))
    server
  end

  defp hal_c2_token(context),
    do: hal_c2_server(context)["headers"]["Authorization"] |> String.split(" ") |> List.last()

  step "Claude can still call the HAL-C2 tools for this thread", context do
    call_hal_c2_tools(context)
  end

  step "Claude can call the HAL-C2 tools for this thread", context do
    call_hal_c2_tools(context)
  end

  defp call_hal_c2_tools(context) do
    %{"url" => url, "headers" => %{"Authorization" => auth}} = hal_c2_server(context)
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

    # With transcripts kept (`FAKE_SESSIONS`), the reply goes on to list them.
    assert Enum.any?(
             World.replies(context, "fork"),
             &String.starts_with?(&1, "resumed at uuid-2 fork True history False")
           )

    context
  end

  # The fake keeps transcripts in the config directory it runs with, so a fork resumed
  # from any other finds no conversation.
  step "a Claude instance {string} with its own home", %{args: [instance]} = context do
    context = World.fake_providers(context)
    own = Mc.tmp_dir(context.mc, "claude-mc-home")
    home = Mc.tmp_dir(context.mc, "claude-instance-home")
    World.put_os_env("CLAUDE_CONFIG_DIR", own)
    World.put_os_env("FAKE_SESSIONS", "1")

    context =
      write_settings(context, fn settings ->
        put_in(settings, [Access.key("providerInstances", %{}), instance], %{
          "driver" => "claudeAgent",
          "enabled" => true,
          "config" => %{"homePath" => home}
        })
      end)

    Map.put(context, :claude_homes, %{own: own, instance: home})
  end

  step "a thread on {string} with three turns", %{args: [instance]} = context do
    World.run_turns(context, @thread, instance, ["hello", "hello again", "one more"])
  end

  step "the MC's own Claude home is left as it was", context do
    assert File.ls!(context.claude_homes.own) == []

    # The source's session and the fork's, both in the instance's home.
    assert [_, _] = Path.wildcard(Path.join(context.claude_homes.instance, "projects/*/*.jsonl"))
    context
  end

  # --- forking a compacted thread -----------------------------------------------------------

  step "a Claude thread that was compacted three times", context do
    context =
      context
      |> World.fake_providers()
      |> World.run_turns(@thread, "claudeAgent", [
        "first",
        "/compact",
        "second",
        "/compact",
        "third",
        "/compact"
      ])

    assert length(compactions(context)) == 3
    Map.put(context, :thread, @thread)
  end

  step "the user forks from its latest turn and sends a message in the fork", context do
    context = World.fork(context, @thread, 6, "fork")
    assert {:ok, _} = context.reply
    context = World.post_message(context, "fork", "where are we")
    World.await_latest_run(context, "fork", "completed")
    context
  end

  step "the fork sends Claude the same compacted context as its source", context do
    replies = World.replies(context, "fork")
    latest = compactions(context) |> List.last() |> get_in(["nativeItemRef", "nativeId"])

    assert Enum.any?(replies, &String.starts_with?(&1, "resumed at #{latest} ")),
           inspect(replies)

    assert Enum.any?(replies, &(&1 =~ "fork True")), inspect(replies)
    context
  end

  step "every compaction in the fork points at messages the fork has", context do
    fork_items = World.entities(context, "fork", "turn-item")
    fork_runs = World.runs(context, "fork") |> Enum.map(& &1["id"]) |> MapSet.new()

    fork_native =
      for item <- fork_items,
          id = get_in(item, ["nativeItemRef", "nativeId"]),
          id,
          into: MapSet.new(),
          do: id

    source_native =
      for item <- World.entities(context, @thread, "turn-item"),
          id = get_in(item, ["nativeItemRef", "nativeId"]),
          id,
          into: MapSet.new(),
          do: id

    fork_compactions = Enum.filter(fork_items, &(&1["type"] == "compaction"))
    assert length(fork_compactions) == 3

    # Each compaction belongs to a run the fork has, carries the same native
    # boundary as in the source, and every native item the source had at the
    # fork point is among the fork's own items.
    assert Enum.all?(fork_compactions, &MapSet.member?(fork_runs, &1["runId"]))

    boundaries = fn items ->
      for item <- items,
          item["type"] == "compaction",
          do: get_in(item, ["nativeItemRef", "nativeId"])
    end

    assert MapSet.new(boundaries.(fork_items)) ==
             MapSet.new(boundaries.(World.entities(context, @thread, "turn-item")))

    assert MapSet.subset?(source_native, fork_native)
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

  # The npm registry's latest release, as the MC last read it. A native Claude
  # install follows its own release channel instead, so the channel's last read
  # is seeded with the same version.
  defp latest(context, driver, version) do
    read = {version, System.monotonic_time(:millisecond)}
    :persistent_term.put({HalC2.ProviderUpdates, driver}, read)

    if driver == "claudeAgent" do
      for channel <- ["latest", "stable"],
          do: :persistent_term.put({HalC2.ProviderUpdates, :claude_channel, channel}, read)
    end

    context
  end

  # The newest version Claude's own release channel offers, as the MC last read it.
  defp channel_latest(context, channel, version) do
    :persistent_term.put(
      {HalC2.ProviderUpdates, :claude_channel, channel},
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

  step ~r/^Claude ends a turn with the API error (?<status>\d+) "(?<reason>[^"]+)"$/,
       %{args: [status, reason]} = context do
    context = running_turn(context)
    text = "API Error: #{status} #{reason}"

    # Claude labels a 403 an authentication failure, as it does a 401.
    claude_says(context, %{
      "type" => "assistant",
      "error" => "authentication_failed",
      "message" => %{"id" => "m-403", "content" => [%{"type" => "text", "text" => text}]}
    })

    claude_says(context, %{
      "type" => "result",
      "subtype" => "success",
      "is_error" => true,
      "api_error_status" => String.to_integer(status),
      "terminal_reason" => "completed",
      "result" => text
    })

    Map.put(context, :error_text, text)
  end

  step "the turn fails showing {string}", %{args: [reason]} = context do
    World.await_runs(context, @thread, ["failed"])
    items = StreamState.list(World.stream(context, @thread), "turn-item")

    assert %{"failure" => %{"message" => message, "class" => "provider_error"}} =
             Enum.find(items, &(&1["type"] == "error"))

    assert message =~ reason
    context
  end

  step "it does not tell the user to run {string}", %{args: [command]} = context do
    items = StreamState.list(World.stream(context, @thread), "turn-item")

    for %{"type" => "error"} = item <- items,
        do: refute(inspect(item) =~ command)

    context
  end

  # Claude gave up on repeated API errors and said why in its result.
  step "Claude ends a turn on an API error with the result {string}",
       %{args: [text]} = context do
    context = running_turn(context)

    claude_says(context, %{
      "type" => "result",
      "subtype" => "success",
      "is_error" => true,
      "terminal_reason" => "api_error",
      "result" => text <> String.duplicate(".", 600)
    })

    World.await_runs(context, @thread, ["failed"])
    Map.put(context, :error_text, text)
  end

  # The failure is Claude's text, cut to 500 characters.
  step "the thread's failure reads {string}", %{args: [text]} = context do
    items = StreamState.list(World.stream(context, @thread), "turn-item")
    %{"failure" => %{"message" => message}} = Enum.find(items, &(&1["type"] == "error"))
    assert String.starts_with?(message, text)
    assert String.length(message) == 500
    context
  end

  step "not a generic message about repeated API errors", context do
    items = StreamState.list(World.stream(context, @thread), "turn-item")
    refute inspect(items) =~ "repeated API errors"
    context
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
    "a blocking limit came with no rate-limit evidence" => %{
      "terminal_reason" => "blocking_limit"
    },
    "the context refilled straight after compaction" => %{
      "terminal_reason" => "rapid_refill_breaker"
    },
    "the prompt is larger than the context window" => %{"terminal_reason" => "prompt_too_long"},
    # Claude ends a turn on a full context window as a blocking limit.
    "the prompt is too long for the context window" => %{
      "terminal_reason" => "blocking_limit",
      "is_error" => true,
      "result" => "Prompt is too long"
    },
    "an image could not be processed" => %{"terminal_reason" => "image_error"},
    "the model returned an error" => %{"terminal_reason" => "model_error"},
    "the API was overloaded" => %{"api_error_status" => 529},
    "the API rate limit was reached" => %{"api_error_status" => 429}
  }

  step ~r/^Claude ends a turn because (?<reason>.+)$/, %{args: [reason]} = context do
    context = if context[:turn_running], do: context, else: running_turn(context)

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

  # Upstream #21231. A UserPromptSubmit hook in the project's Claude settings, which the
  # fake CLI runs on each prompt: exit 2 drops the prompt with the hook's reason.
  step "a Claude hook blocks prompts that mention {string} with the reason {string}",
       %{args: [word, reason]} = context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "claudeAgent", "hello")

    World.await_runs(context, @thread, ["completed"])
    root = World.project(context).root
    hook = Path.join(Mc.tmp_dir(context.mc, "claude-hooks"), "block.sh")
    File.write!(hook, "#!/bin/sh\nif grep -q '#{word}'; then echo '#{reason}' >&2; exit 2; fi\n")
    File.chmod!(hook, 0o755)

    settings = %{
      "UserPromptSubmit" => [%{"hooks" => [%{"type" => "command", "command" => hook}]}]
    }

    File.mkdir_p!(Path.join(root, ".claude"))

    File.write!(
      Path.join([root, ".claude", "settings.json"]),
      JSON.encode!(%{"hooks" => settings})
    )

    Map.put(context, :current, @thread)
  end

  step "the thread shows Claude's notice {string}", %{args: [text]} = context do
    World.await_runs(context, @thread, ["completed", "completed"])

    assert [notice] =
             World.stream(context, @thread)
             |> StreamState.list("turn-item")
             |> Enum.filter(&(&1["type"] == "system_notice"))

    assert notice["message"] =~ text
    assert notice["status"] == "completed"
    Map.put(context, :notice, notice)
  end

  step "the notice is not shown a second time as Claude's answer", context do
    state = World.stream(context, @thread)
    [_, run] = World.runs(context, @thread)

    refute Enum.any?(
             StreamState.list(state, "turn-item"),
             &(&1["runId"] == run["id"] and &1["type"] == "assistant_message")
           )

    refute Enum.any?(World.replies(context, @thread), &(&1 == context.notice["message"]))
    context
  end

  step "the turn carries on", context do
    if context[:provider] == "pi" do
      # Pi already carried on past what the step before this did to the turn.
      World.await_runs(context, context.thread, ["completed"])
      assert World.replies(context, context.thread) != []
      context
    else
      turn_carries_on(context)
    end
  end

  defp turn_carries_on(context) do
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

    # The result names the prompt it answers, as Claude's do, so it ends the user's turn
    # even before Claude reported starting it.
    claude_says(context, %{
      "type" => "result",
      "subtype" => "success",
      "is_error" => false,
      "user_message_uuids" => [prompt_uuid(context)]
    })

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

  # Claude's refused answer repeats the window in its `api_error_params`; only the first
  # turn also sends the rate-limit event.
  defp refused_turn(context, event?) do
    context =
      if event? do
        running_turn(context)
      else
        context = World.send_turn(context, @thread, "wait again")

        World.await_provider_log(
          context,
          "claude",
          &(get_in(&1, ["in", "type"]) == "user" and inspect(&1) =~ "wait again")
        )

        context
      end

    info = %{"status" => "rejected", "rateLimitType" => "five_hour", "resetsAt" => at_o_clock(14)}

    if event?,
      do: claude_says(context, %{"type" => "rate_limit_event", "rate_limit_info" => info})

    claude_says(context, %{
      "type" => "assistant",
      "error" => "rate_limit",
      "api_error_params" => %{"rate_limit_info" => info},
      "message" => %{
        "id" => "m-limit-#{System.unique_integer([:positive])}",
        "content" => [%{"type" => "text", "text" => "You've hit your limit"}]
      }
    })

    claude_says(context, %{"type" => "result", "subtype" => "success", "is_error" => true})
    context
  end

  step "a Claude turn was refused by a limit that resets at 14:00", context do
    context = refused_turn(context, true)
    World.await_runs(context, @thread, ["failed"])
    context
  end

  step "the user retries at once and Claude refuses it with the same limit", context do
    context = refused_turn(context, false)
    World.await_runs(context, @thread, ["failed", "failed"])
    context
  end

  step "the thread's reset time is still 14:00", context do
    World.await_row(
      World.thread_id(context, @thread),
      &(&1["lastErrorClass"] == "usage_limit" and
          &1["usageLimitResetAt"] == "2026-09-24T14:00:00.000Z")
    )

    items = StreamState.list(World.stream(context, @thread), "turn-item")

    assert [_, _] =
             for(
               %{"type" => "error", "failure" => %{"resetAt" => "2026-09-24T14:00:00.000Z"}} <-
                 items,
               do: true
             )

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

  # --- a gateway's 503 --------------------------------------------------------------------

  # Claude reports a gateway's failure as an API error result; `body` is what the gateway said.
  defp gateway_503(context, body) do
    context = running_turn(context)
    text = "API Error: 503 " <> Jason.encode!(body)

    claude_says(context, %{
      "type" => "assistant",
      "message" => %{"id" => "m-503", "content" => [%{"type" => "text", "text" => text}]}
    })

    claude_says(context, %{
      "type" => "result",
      "subtype" => "success",
      "is_error" => true,
      "api_error_status" => 503,
      "terminal_reason" => "completed",
      "result" => text
    })

    context
  end

  defp rate_limit_body(message),
    do: %{"type" => "error", "error" => %{"type" => "rate_limit_error", "message" => message}}

  # The scenario's 13:00 is when the turn ends: the MC dates a cooldown from its own clock,
  # so the steps read reset times relative to the moment the turn was told to end.
  defp at_13_00(context), do: Map.put(context, :ended_from_s, System.system_time(:second))

  step ~r/^a Claude turn ends at 13:00 with a 503 rate_limit_error saying "\(reset after (?<cooldown>[^"]+)\)"$/,
       %{args: [cooldown]} = context do
    context
    |> at_13_00()
    |> gateway_503(rate_limit_body("All accounts rate limited (reset after #{cooldown})"))
    |> Map.put(:gateway_cooldown, cooldown)
  end

  step ~r/^the thread is marked as limited with a reset time of (?<reset>[\d:]+)$/,
       %{args: [reset]} = context do
    [hour, minute, second] = reset |> String.split(":") |> Enum.map(&String.to_integer/1)
    cooldown = (hour - 13) * 3600 + minute * 60 + second
    World.await_runs(context, @thread, ["failed"])

    row =
      World.await_row(
        World.thread_id(context, @thread),
        &(&1["lastErrorClass"] == "usage_limit" and is_binary(&1["usageLimitResetAt"]))
      )

    {:ok, reset_at, _} = DateTime.from_iso8601(row["usageLimitResetAt"])
    reset_s = DateTime.to_unix(reset_at)
    assert reset_s in (context.ended_from_s + cooldown)..(System.system_time(:second) + cooldown)

    context |> Map.put(:limit_reset_s, reset_s) |> Map.put(:limited_row, row)
  end

  step "it resumes on its own then if resuming after usage limits is on", context do
    # The recovery reads the thread's row, with the stop dated to when the turn ended.
    row = context.limited_row
    stopped = DateTime.to_iso8601(DateTime.from_unix!(context.ended_from_s), :extended)
    thread = Map.put(row, "latestRunCompletedAt", stopped)

    assert %{"type" => "message.dispatch"} =
             HalC2.Orchestration.LimitRecovery.command(
               Map.put(thread, "limitRecovery", %{
                 "runId" => row["latestRunId"],
                 "resetAt" => row["usageLimitResetAt"],
                 "autoResume" => true
               }),
               true,
               (context.limit_reset_s + 1) * 1000
             )

    context
  end

  step ~r/^a Claude turn ends with a 503 (?<error>that is not a rate_limit_error|rate_limit_error saying "\(reset after 0s\)"|rate_limit_error with a cooldown it cannot read)$/,
       %{args: [error]} = context do
    body =
      case error do
        "that is not a rate_limit_error" ->
          %{
            "type" => "error",
            "error" => %{"type" => "overloaded_error", "message" => "(reset after 5m)"}
          }

        ~s|rate_limit_error saying "(reset after 0s)"| ->
          rate_limit_body("All accounts rate limited (reset after 0s)")

        _ ->
          rate_limit_body("All accounts rate limited (reset after a while)")
      end

    context |> at_13_00() |> gateway_503(body)
  end

  step "Claude's latest rate-limit report allows requests", context do
    context = running_turn(context)

    claude_says(context, %{
      "type" => "rate_limit_event",
      "rate_limit_info" => %{"status" => "allowed", "rateLimitType" => "five_hour"}
    })

    Map.put(context, :turn_running, true)
  end

  step "the turn fails saying the context window is full and to run /compact or start a new thread",
       context do
    World.await_runs(context, @thread, ["failed"])
    items = StreamState.list(World.stream(context, @thread), "turn-item")

    assert %{"failure" => %{"class" => "provider_error", "message" => message}} =
             Enum.find(items, &(&1["type"] == "error"))

    assert message =~ "context window is full"
    assert message =~ "/compact"
    assert message =~ "new thread"
    context
  end

  step "the thread is not marked as limited", context do
    World.await_row(
      World.thread_id(context, @thread),
      &(&1["lastErrorClass"] == "provider_error" and &1["usageLimitResetAt"] == nil)
    )

    context
  end

  step "the run fails with a provider error and the thread is not marked as limited", context do
    World.await_runs(context, @thread, ["failed"])
    items = StreamState.list(World.stream(context, @thread), "turn-item")

    assert %{"failure" => %{"class" => "provider_error", "code" => "api_error_503"}} =
             Enum.find(items, &(&1["type"] == "error"))

    World.await_row(
      World.thread_id(context, @thread),
      &(&1["lastErrorClass"] != "usage_limit" and &1["usageLimitResetAt"] == nil)
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

  step "a Claude turn is running a command", context do
    # A stop is settled by the MC itself soon after, as Claude never answers it.
    World.put_app_env(:claude_interrupt_timeout_ms, 300)
    System.put_env("FAKE_CLAUDE_HOLD_INTERRUPT", "1")
    ExUnit.Callbacks.on_exit(fn -> System.delete_env("FAKE_CLAUDE_HOLD_INTERRUPT") end)
    context = running_turn(context)

    claude_says(context, %{
      "type" => "assistant",
      "message" => %{
        "id" => "m-cmd",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "cmd-1",
            "name" => "Bash",
            "input" => %{"command" => "sleep 60"}
          }
        ]
      }
    })

    World.await_value(context, @thread, fn state ->
      Enum.any?(StreamState.list(state, "turn-item"), &(&1["type"] == "command_execution"))
    end)

    context
  end

  defp command_items(context),
    do:
      context
      |> World.stream(@thread)
      |> StreamState.list("turn-item")
      |> Enum.filter(&(&1["type"] == "command_execution"))

  step "the command is recorded as interrupted, as Codex and Cursor record it", context do
    World.await_runs(context, @thread, ["interrupted"], 10_000)
    assert [%{"status" => "interrupted"}] = command_items(context)
    context
  end

  step "agents reading the thread are told it was interrupted, not that it failed", context do
    {:ok, result} =
      World.mcp_tool(
        context,
        @thread,
        "hal_c2_thread_read",
        %{"threadId" => World.thread_id(context, @thread)},
        "claudeAgent"
      )

    assert inspect(result) =~ "interrupted"
    refute Enum.any?(command_items(context), &(&1["status"] == "failed"))
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

  # --- background work and a change of selection ---------------------------------------
  # The fake's "in the background" turn ends with a subagent (agent-1) and a command
  # (bash-1) still running. The thread runs on Opus 4.6, whose fast mode it left unset.
  defp left_running(context) do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "claudeAgent", "survey in the background", %{
        "model" => "claude-opus-4-6"
      })

    World.await_runs(context, @thread, ["completed"])
    assert background_running?(context)
    [{runtime, _}] = Registry.lookup(HalC2.Claude.Registry, World.thread_id(context, @thread))
    Map.merge(context, %{runtime: runtime, first_session: :sys.get_state(runtime).session})
  end

  defp background_running?(context) do
    state = World.stream(context, @thread)

    match?([%{"status" => "running"}], StreamState.list(state, "subagent")) and
      Enum.any?(
        command_items(context),
        &(&1["nativeItemRef"]["nativeId"] == "bash-1" and &1["status"] == "running")
      )
  end

  defp send_on(context, options, statuses) do
    selection = %{
      "instanceId" => "claudeAgent",
      "model" => "claude-opus-4-6",
      "options" => options
    }

    context = World.post_message(context, @thread, "and now?", %{"modelSelection" => selection})
    World.await_runs(context, @thread, statuses)
    context
  end

  defp refused?(context) do
    [session] = StreamState.list(World.stream(context, @thread), "provider-session")
    String.starts_with?(session["lastError"] || "", "Claude is still running background work")
  end

  defp untouched?(context) do
    background_running?(context) and
      :sys.get_state(context.runtime).session == context.first_session and
      Process.alive?(context.first_session)
  end

  # Upstream #16287: the refused message never reached Claude, so the next turn on the
  # same session carries it.
  step "a Claude thread whose background subagent is still working", context do
    left_running(context)
  end

  step "Claude refuses the user's next turn because of that work", context do
    context = send_on(context, [%{"id" => "fastMode", "value" => true}], ["completed", "failed"])
    assert refused?(context)
    context
  end

  step "the user sends another message", context do
    selection = %{"instanceId" => "claudeAgent", "model" => "claude-opus-4-6", "options" => []}
    context = World.post_message(context, @thread, "what next?", %{"modelSelection" => selection})
    World.await_runs(context, @thread, ["completed", "failed", "completed"])
    context
  end

  step "Claude resumes the same session", context do
    assert :sys.get_state(context.runtime).session == context.first_session
    assert length(for(%{"argv" => _} <- World.provider_log(context, "claude"), do: 1)) == 1
    context
  end

  step "it reads the messages it missed before the new one", context do
    assert [sent] =
             for(
               %{"in" => %{"type" => "user"} = message} <- World.provider_log(context, "claude"),
               text = inspect(message["message"]["content"]),
               text =~ "what next?",
               do: text
             )

    assert [{missed, _}, {new, _}] =
             Enum.map(["and now?", "what next?"], &:binary.match(sent, &1))

    assert missed < new
    context
  end

  # The fake finishes "never start a turn" without a turn; "the turn fails with {string}"
  # (codex_steps.exs) reads the thread "Work".
  step "Claude ends a prompt as {word} without ever starting a turn for it",
       %{args: [ended]} = context do
    context
    |> World.fake_providers()
    |> World.launch_on("Work", "claudeAgent", "never start a turn (#{ended})")
  end

  step "the user sends a message Claude never starts a turn for", context do
    selection = %{"instanceId" => "claudeAgent", "model" => "claude-opus-4-6", "options" => []}

    context =
      World.post_message(context, @thread, "never start a turn", %{"modelSelection" => selection})

    World.await_runs(context, @thread, ["completed", "failed"])
    context
  end

  step "that message fails and the running background work is untouched", context do
    [session] = StreamState.list(World.stream(context, @thread), "provider-session")
    assert session["lastError"] =~ "never started a turn"
    assert untouched?(context)
    context
  end

  step "the next message the user sends starts a turn as usual", context do
    context = World.post_message(context, "Work", "hello")
    World.await_runs(context, "Work", ["failed", "completed"])
    assert "Hello from claude" in World.replies(context, "Work")
    context
  end

  step "Claude has a background agent or shell still running", context do
    left_running(context)
  end

  step "the user sends a message on a different model or option", context do
    send_on(context, [%{"id" => "fastMode", "value" => true}], ["completed", "failed"])
  end

  step "the send fails with a visible reason", context do
    assert refused?(context)
    # The message never reached Claude.
    refute Enum.any?(
             World.provider_log(context, "claude"),
             &(get_in(&1, ["in", "message", "content"]) == "and now?")
           )

    context
  end

  step "the running background work is untouched", context do
    assert untouched?(context)
    context
  end

  step "Stop still allows the change", context do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "threadId" => World.thread_id(context, @thread)
      })

    World.await_value(context, @thread, fn state ->
      match?(
        [%{"status" => status}] when status != "running",
        StreamState.list(state, "subagent")
      )
    end)

    context =
      send_on(
        context,
        [%{"id" => "fastMode", "value" => true}],
        ["completed", "failed", "completed"]
      )

    assert ["--settings", settings] =
             context
             |> World.provider_log("claude")
             |> Enum.filter(&Map.has_key?(&1, "argv"))
             |> List.last()
             |> Map.fetch!("argv")
             |> pairs()
             |> Enum.find(&match?(["--settings", _], &1))

    assert JSON.decode!(settings)["fastMode"] == true
    context
  end

  step "a Claude thread has a command running in the background", context do
    left_running(context)
  end

  step "a follow-up arrives with fast mode off where the first turn left it unset", context do
    send_on(context, [%{"id" => "fastMode", "value" => false}], ["completed", "completed"])
  end

  step "the follow-up is accepted and the background command keeps running", context do
    assert "Hello from claude" in World.replies(context, @thread)
    assert untouched?(context)
    context
  end

  step "a real model or settings change is still refused while that command runs", context do
    context =
      send_on(
        context,
        [%{"id" => "fastMode", "value" => true}],
        ["completed", "completed", "failed"]
      )

    assert refused?(context)
    assert untouched?(context)
    context
  end

  step "Claude calls EnterPlanMode during a turn on a thread whose mode is not plan", context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "claudeAgent", "enter plan mode yourself")

    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "the user sends the next turn", context do
    context = World.post_message(context, @thread, "which mode")
    World.await_runs(context, @thread, ["completed", "completed"])
    context
  end

  step "Claude can edit again and the subagents it starts do not inherit plan mode", context do
    # The session runs in the thread's own mode again, which its subagents start in.
    assert "mode bypassPermissions" in World.replies(context, @thread)
    refute "mode plan" in World.replies(context, @thread)
    context
  end

  step "ExitPlanMode still captures the plan as a proposed plan and denies the tool", context do
    context = World.post_message(context, @thread, "make a plan")
    state = World.await_runs(context, @thread, ["completed", "completed", "completed"])

    assert [%{"markdown" => "# Plan\n- do it"}] =
             Enum.filter(StreamState.list(state, "plan"), &(&1["kind"] == "proposed_plan"))

    refute Enum.any?(StreamState.list(state, "turn-item"), &(&1["toolName"] == "ExitPlanMode"))

    assert Enum.any?(
             World.provider_log(context, "claude"),
             &match?(
               %{"in" => %{"response" => %{"response" => %{"behavior" => "deny"}}}},
               &1
             )
           )

    context
  end

  step "the user stopped a running Claude turn", context do
    World.put_app_env(:claude_interrupt_timeout_ms, 300)
    stop_turn(context)
  end

  # The settle deadline is not under test: Claude records the turn well within it.
  step "the user stopped a running Claude turn, leaving Claude its 10 seconds to stop",
       context do
    stop_turn(context)
  end

  step "Claude has not ended the turn after 10 seconds", context do
    # The settle deadline is shortened for the scenario; Claude never answers.
    assert [%{"status" => active}] = World.runs(context, @thread)
    assert active in ["running", "interrupted"]
    context
  end

  step "Claude records the interrupted turn within three seconds", context do
    [{runtime, _}] = Registry.lookup(HalC2.Claude.Registry, World.thread_id(context, @thread))
    session = :sys.get_state(runtime).session

    claude_says(context, %{
      "type" => "result",
      "subtype" => "error_during_execution",
      "is_error" => true,
      "terminal_reason" => "aborted_streaming",
      "session_id" => "fake-session-1"
    })

    Map.merge(context, %{runtime: runtime, stopped_session: session})
  end

  step "the session closes only after that record", context do
    World.await_runs(context, @thread, ["interrupted"])
    # Claude's own record settled the run, so its session was never closed under it.
    assert Process.alive?(context.stopped_session)
    assert :sys.get_state(context.runtime).session == context.stopped_session
    context
  end

  step "the thread's next message continues the same conversation", context do
    context = World.post_message(context, @thread, "hello")
    World.await_runs(context, @thread, ["interrupted", "completed"], 10_000)
    assert "Hello from claude" in World.replies(context, @thread)
    # The same Claude process, and so the same conversation, answered it.
    assert :sys.get_state(context.runtime).session == context.stopped_session
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
  defp claude_asks(context, id, tool, input, request_context \\ %{}) do
    [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, World.thread_id(context, @thread))

    send(
      pid,
      {:claude, :sys.get_state(pid).session, {:permission, id, tool, input, request_context}}
    )

    context
  end

  # Claude sends the subagent it knows as task-agent-7 `message` with tool call `tool`,
  # registers the task under `description`, and the subagent answers.
  defp send_to_subagent(context, tool, message, description) do
    claude_says(context, %{
      "type" => "assistant",
      "message" => %{
        "id" => "m-#{tool}",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => tool,
            "name" => "SendMessage",
            "input" => %{"to" => "task-agent-7", "message" => message}
          }
        ]
      }
    })

    claude_says(context, %{
      "type" => "system",
      "subtype" => "task_started",
      "task_id" => "task-agent-7",
      "tool_use_id" => tool,
      "description" => description,
      "task_type" => "local_agent",
      "is_backgrounded" => true
    })

    claude_says(context, %{
      "type" => "user",
      "message" => %{
        "role" => "user",
        "content" => [
          %{"type" => "tool_result", "tool_use_id" => tool, "content" => "Message delivered"}
        ]
      }
    })

    claude_says(context, %{
      "type" => "assistant",
      "parent_tool_use_id" => tool,
      "message" => %{
        "id" => "m-sub-#{tool}",
        "content" => [%{"type" => "text", "text" => "The tests pass"}]
      }
    })

    claude_says(context, %{
      "type" => "system",
      "subtype" => "task_notification",
      "task_id" => "task-agent-7",
      "tool_use_id" => tool,
      "status" => "completed",
      "summary" => "The tests pass"
    })
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

  # --- notebook edits ------------------------------------------------------------------------

  # Claude's NotebookEdit names its file `notebook_path`, never `file_path`.
  step "Claude edits the notebook {string} with its NotebookEdit tool",
       %{args: [path]} = context do
    context = running_turn(context)

    claude_says(context, %{
      "type" => "assistant",
      "message" => %{
        "id" => "m-notebook",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "tool-notebook",
            "name" => "NotebookEdit",
            "input" => %{"notebook_path" => path, "cell_id" => "c1", "new_source" => "print(1)"}
          }
        ]
      }
    })

    claude_says(context, %{
      "type" => "user",
      "message" => %{
        "content" => [
          %{
            "type" => "tool_result",
            "tool_use_id" => "tool-notebook",
            "content" => "Updated cell c1"
          }
        ]
      }
    })

    claude_says(context, %{"type" => "result", "subtype" => "success", "is_error" => false})
    World.await_runs(context, @thread, ["completed"])
    context
  end

  defp file_changes(context) do
    for item <- StreamState.list(World.stream(context, @thread), "turn-item"),
        item["type"] == "file_change",
        do: item
  end

  step "the timeline shows a file change to {string}", %{args: [path]} = context do
    assert [%{"fileName" => ^path}] = file_changes(context)
    context
  end

  # A client's Open diff asks for the file the change names.
  step "opening its diff opens {string}", %{args: [path]} = context do
    refute Enum.any?(file_changes(context), &(inspect(&1) =~ "NotebookEdit result"))
    assert Enum.all?(file_changes(context), &(&1["fileName"] == path))
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

  step "Claude asks a question with a choice {string} that has a blank description",
       %{args: [label]} = context do
    context =
      context |> World.fake_providers() |> World.launch_on(@thread, "claudeAgent", "ask skip")

    context = Map.put(context, :request, World.await_request(context, @thread))
    [question] = questions(context)

    assert %{"label" => ^label, "description" => ^label} =
             Enum.find(question["options"], &(&1["label"] == label))

    Map.put(context, :question, question)
  end

  step "the user picks {string}", %{args: [label]} = context do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "runtime-request.respond",
        "threadId" => World.thread_id(context, @thread),
        "requestId" => context.request["id"],
        "answers" => %{context.question["id"] => label}
      })

    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "the run does not fail", context do
    assert ["completed"] = context |> World.runs(@thread) |> Enum.map(& &1["status"])
    context
  end

  step "Claude asks a question whose option {string} has a preview", %{args: [label]} = context do
    context =
      context |> World.fake_providers() |> World.launch_on(@thread, "claudeAgent", "ask preview")

    World.await_request(context, @thread)
    Map.put(context, :option, label)
  end

  # What a client subscribed to the thread renders the question from.
  step "the question the clients receive carries the preview of {string}",
       %{args: [label]} = context do
    [question] = questions(context)
    options = Map.new(question["options"], &{&1["label"], &1})
    assert options[label]["preview"] == "```sql\nCREATE TABLE orders (id serial);\n```"
    refute Map.has_key?(options["SQLite"], "preview")
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

  # --- Claude 5's task tools ---------------------------------------------------------------------

  # The built-in instance with its own Claude home, where Claude keeps its task lists, and
  # its own variables.
  defp task_instance(context, vars) do
    home = Mc.tmp_dir(context.mc, "claude-tasks-home")
    context = World.fake_providers(context)

    context =
      write_settings(context, fn settings ->
        put_in(settings, [Access.key("providerInstances", %{}), "claudeAgent"], %{
          "driver" => "claudeAgent",
          "enabled" => true,
          "config" => %{"homePath" => home},
          "environment" =>
            Enum.map(vars, fn {name, value} ->
              %{"name" => name, "value" => value, "sensitive" => false}
            end)
        })
      end)

    Map.put(context, :claude_home, home)
  end

  # Claude calls task tool `name` and reports `output`: a structured result, or the text
  # alone, as a subagent's call (under `opts[:parent]`) returns it.
  defp task_call(context, id, name, input, output, opts \\ []) do
    under = if parent = opts[:parent], do: %{"parent_tool_use_id" => parent}, else: %{}

    claude_says(
      context,
      Map.merge(under, %{
        "type" => "assistant",
        "message" => %{
          "id" => "m-#{id}",
          "content" => [%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}]
        }
      })
    )

    result = %{
      "type" => "tool_result",
      "tool_use_id" => id,
      "content" => if(is_binary(output), do: output, else: "Task tool finished."),
      "is_error" => opts[:error] == true
    }

    user =
      Map.merge(under, %{
        "type" => "user",
        "message" => %{"role" => "user", "content" => [result]}
      })

    claude_says(
      context,
      if(is_map(output), do: Map.put(user, "tool_use_result", output), else: user)
    )

    context
  end

  # Claude creates task `id` and saves it where it keeps the session's task list.
  defp task_created(context, id, subject) do
    [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, World.thread_id(context, @thread))
    dir = Path.join([context.claude_home, "tasks", :sys.get_state(pid).session_id])
    File.mkdir_p!(dir)

    task = %{"id" => id, "subject" => subject, "description" => "", "status" => "pending"}
    File.write!(Path.join(dir, "#{id}.json"), JSON.encode!(task))

    task_call(context, "task-create-#{id}", "TaskCreate", %{"subject" => subject}, %{
      "task" => %{"id" => id, "subject" => subject}
    })
  end

  # The steps of the thread's newest active task list, once the runtime has handled
  # what Claude said.
  defp task_steps(context) do
    [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, World.thread_id(context, @thread))
    _ = :sys.get_state(pid)

    for %{"status" => "active"} = plan <- todo_plans(context),
        step <- plan["steps"],
        do: {step["id"], step["text"], step["status"]}
  end

  defp claude_ends_turn(context) do
    claude_says(context, %{"type" => "result", "subtype" => "success", "is_error" => false})
    context
  end

  step "the Claude instance turns on Claude's task tools in its environment variables",
       context do
    task_instance(context, %{"CLAUDE_CODE_ENABLE_TODO_TOOLS" => "1"})
  end

  step "a Claude 5 model creates tasks, updates one to in progress and lists them", context do
    context =
      context
      |> running_turn()
      |> task_call("t1", "TaskCreate", %{"subject" => "Inspect the logs"}, %{
        "task" => %{"id" => "1", "subject" => "Inspect"}
      })
      |> task_call("t2", "TaskCreate", %{"subject" => "Fix the bug"}, %{
        "task" => %{"id" => "2", "subject" => "Fix the bug"}
      })
      |> task_call("t3", "TaskUpdate", %{"taskId" => "1", "status" => "in_progress"}, %{
        "success" => true,
        "taskId" => "1",
        "updatedFields" => ["status"]
      })

    assert task_steps(context) == [
             {"task-1", "Inspect", "running"},
             {"task-2", "Fix the bug", "pending"}
           ]

    context
    |> task_call("t4", "TaskList", %{}, %{
      "tasks" => [
        %{"id" => "1", "subject" => "Inspect", "status" => "in_progress", "blockedBy" => []},
        %{"id" => "2", "subject" => "Fix the bug", "status" => "completed", "blockedBy" => []}
      ]
    })
    |> claude_ends_turn()
    |> tap(&World.await_runs(&1, @thread, ["completed"]))
  end

  step "the thread's task list shows those tasks with their status", context do
    assert task_steps(context) == [
             {"task-1", "Inspect", "running"},
             {"task-2", "Fix the bug", "completed"}
           ]

    start = Enum.find(World.provider_log(context, "claude"), &Map.has_key?(&1, "argv"))
    assert start["env"]["CLAUDE_CODE_ENABLE_TODO_TOOLS"] == "1"
    context
  end

  step "Claude's task list has three tasks", context do
    context =
      context
      |> task_instance(%{})
      |> running_turn()
      |> task_created("1", "Inspect")
      |> task_created("2", "Fix")
      |> task_created("3", "Test")
      |> claude_ends_turn()

    World.await_runs(context, @thread, ["completed"])
    assert [{_, "Inspect", _}, {_, "Fix", _}, {_, "Test", _}] = task_steps(context)
    context
  end

  step "Claude adds a fourth task", context do
    context = World.post_message(context, @thread, "wait for the fourth task")
    World.await_running(context, @thread)

    World.await_provider_log(
      context,
      "claude",
      &(get_in(&1, ["in", "message", "content"]) == "wait for the fourth task")
    )

    context
    |> task_created("4", "Deploy")
    |> claude_ends_turn()
    |> tap(&World.await_runs(&1, @thread, ["completed", "completed"]))
  end

  step "the task list shows all four tasks", context do
    assert [
             {"task-1", "Inspect", "pending"},
             {"task-2", "Fix", "pending"},
             {"task-3", "Test", "pending"},
             {"task-4", "Deploy", "pending"}
           ] = task_steps(context)

    context
  end

  step "a Claude thread has a task list", context do
    context =
      context
      |> task_instance(%{})
      |> running_turn()
      |> task_created("1", "Inspect")
      |> task_created("2", "Fix")

    assert [{"task-1", "Inspect", "pending"}, {"task-2", "Fix", "pending"}] = task_steps(context)
    context
  end

  step "a Claude subagent adds a task and finishes another", context do
    claude_says(context, %{
      "type" => "assistant",
      "message" => %{
        "id" => "m-agent-tasks",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "agent-tasks",
            "name" => "Agent",
            "input" => %{"description" => "Helper", "prompt" => "Help with the tasks"}
          }
        ]
      }
    })

    claude_says(context, %{
      "type" => "system",
      "subtype" => "task_started",
      "task_id" => "task-agent-tasks",
      "tool_use_id" => "agent-tasks",
      "description" => "Helper",
      "task_type" => "local_agent"
    })

    context
    |> task_call(
      "sub-create",
      "TaskCreate",
      %{"subject" => "Write docs", "description" => "Document the fix"},
      "Task #3 created successfully: Write docs",
      parent: "agent-tasks"
    )
    |> task_call(
      "sub-update",
      "TaskUpdate",
      %{"taskId" => "1", "status" => "completed"},
      "Updated task #1 status",
      parent: "agent-tasks"
    )
  end

  step "the thread's task list shows the added task and the finished one", context do
    assert task_steps(context) == [
             {"task-1", "Inspect", "completed"},
             {"task-2", "Fix", "pending"},
             {"task-3", "Write docs", "pending"}
           ]

    context
  end

  step "a task change that failed leaves the list as it was", context do
    before = task_steps(context)
    update = %{"taskId" => "2", "status" => "completed"}

    context
    |> task_call("sub-failed", "TaskUpdate", update, "Task not found",
      parent: "agent-tasks",
      error: true
    )
    # A hook that blocks the call answers in text, without the error flag.
    |> task_call("sub-blocked", "TaskUpdate", update, "Blocked by a hook", parent: "agent-tasks")
    |> task_call("root-failed", "TaskUpdate", update, %{"success" => false, "taskId" => "2"})

    assert task_steps(context) == before
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

  # --- background work when Claude's process ends --------------------------------------

  # Its process lingers a second once its stdin closes, as Claude finishing its
  # background work does; a process reads that as it starts.
  step "Claude launched a subagent in the background", context do
    World.put_env("FAKE_CLAUDE_EXIT_DELAY", "1")
    background_subagent(context)
  end

  step "Claude launched a subagent in the background and the launching turn completed",
       context do
    background_subagent(context)
  end

  # Between turns the stop closes the thread's process, which lingers.
  step "the user stopped the turn", context do
    stop = Task.async(fn -> stop_thread(context) end)
    World.await_provider_log(context, "claude", &Map.has_key?(&1, "eof"))
    Map.put(context, :stop, stop)
  end

  step "the next turn starts a new Claude process before the old one has exited", context do
    [%{"pid" => old}] = claude_processes(context)
    assert alive?(old)
    context = World.post_message(context, @thread, "hello")
    Task.await(context.stop, 10_000)
    World.await_runs(context, @thread, ["completed", "completed"])
    assert [_, _] = claude_processes(context)
    Map.put(context, :old_process, old)
  end

  step "the old process exits", context do
    refute alive?(context.old_process)
    context
  end

  step "the thread can show that it is awaiting input", context do
    assert Enum.all?(World.runs(context, @thread), &(&1["status"] == "completed"))
    [{runtime, _}] = Registry.lookup(HalC2.Claude.Registry, World.thread_id(context, @thread))
    assert %{turn: nil, work: work} = :sys.get_state(runtime)
    assert work == %{}
    context
  end

  step ~r/^Claude's process (?<ends>exits unexpectedly|is stopped by the user) without reporting the subagent finished$/,
       %{args: [ends]} = context do
    case ends do
      "exits unexpectedly" ->
        [%{"pid" => pid}] = claude_processes(context)
        {_, 0} = System.cmd("kill", ["-9", to_string(pid)])

      "is stopped by the user" ->
        stop_thread(context)
    end

    context
  end

  defp stop_thread(context),
    do:
      {:ok, _} =
        HalC2.Orchestration.dispatch(%{
          "type" => "run.interrupt",
          "threadId" => World.thread_id(context, @thread)
        })

  defp background_subagent(context) do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "claudeAgent", "survey in the background")

    World.await_runs(context, @thread, ["completed"])

    assert [%{"status" => "running"}] =
             StreamState.list(World.stream(context, @thread), "subagent")

    context
  end

  # The fake Claude processes started in the scenario, oldest first: their OS pids.
  defp claude_processes(context),
    do: Enum.filter(World.provider_log(context, "claude"), &Map.has_key?(&1, "argv"))

  defp alive?(os_pid), do: File.exists?("/proc/#{os_pid}")

  # --- a nested subagent that finishes before its wake's run (Upstream #23561) ----------

  # Claude reacts to the survey by itself and the survey launches a subagent of its
  # own, all while the runtime is held: the wake ends, and the user's message is sent
  # before the runtime is let go, so the user's run comes first and the wake's run,
  # which replays the nested launch, queues behind it.
  step "a background Claude subagent launched a subagent of its own while the thread was idle",
       context do
    context = background_subagent(context)
    [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, World.thread_id(context, @thread))

    [survey] =
      for {tool, %{sub: %{}}} <- :sys.get_state(pid).work, do: tool

    :ok = :sys.suspend(pid)
    session = :sys.get_state(pid).session
    says = &send(pid, {:claude, session, {:message, &1}})

    says.(%{
      "type" => "assistant",
      "message" => %{
        "id" => "m-wake",
        "content" => [%{"type" => "text", "text" => "The survey is under way"}]
      }
    })

    says.(%{
      "type" => "assistant",
      "parent_tool_use_id" => survey,
      "message" => %{
        "id" => "s-nested",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "agent-nested",
            "name" => "Agent",
            "input" => %{
              "description" => "Count the files",
              "prompt" => "Count the files",
              "run_in_background" => true
            }
          }
        ]
      }
    })

    says.(%{
      "type" => "system",
      "subtype" => "task_started",
      "task_id" => "task-agent-nested",
      "tool_use_id" => "agent-nested",
      "description" => "Count the files",
      "task_type" => "local_agent",
      "is_backgrounded" => true
    })

    says.(%{"type" => "result", "subtype" => "success", "is_error" => false})
    Map.merge(context, %{runtime: pid, survey: survey})
  end

  step "the nested subagent finished during a later user turn", context do
    done = length(World.runs(context, @thread))
    send = Task.async(fn -> World.post_message(context, @thread, "wait for the survey") end)
    World.await_value(context, @thread, &(length(StreamState.list(&1, "run")) == done + 1))
    :ok = :sys.resume(context.runtime)
    Task.await(send, 10_000)
    assert %{turn: %{}, wake: %{open: false, buffer: [_ | _]}} = :sys.get_state(context.runtime)

    claude_says(context, %{
      "type" => "system",
      "subtype" => "task_notification",
      "task_id" => "task-agent-nested",
      "tool_use_id" => "agent-nested",
      "status" => "completed",
      "summary" => "There are 3 files"
    })

    claude_says(context, %{"type" => "result", "subtype" => "success", "is_error" => false})
    World.await_runs(context, @thread, ["completed", "completed", "completed"], 10_000)
    context
  end

  step "another subagent finishing wakes the thread", context do
    claude_says(context, %{
      "type" => "system",
      "subtype" => "task_notification",
      "task_id" => "task-#{context.survey}",
      "tool_use_id" => context.survey,
      "status" => "completed",
      "summary" => "The repo holds a server"
    })

    claude_says(context, %{
      "type" => "assistant",
      "message" => %{
        "id" => "m-survey-done",
        "content" => [%{"type" => "text", "text" => "The survey is done"}]
      }
    })

    claude_says(context, %{"type" => "result", "subtype" => "success", "is_error" => false})
    World.await_runs(context, @thread, List.duplicate("completed", 4), 10_000)
    context
  end

  step "the nested subagent is shown as completed", context do
    subagents = StreamState.list(World.stream(context, @thread), "subagent")
    assert %{"status" => "completed"} = Enum.find(subagents, &(&1["title"] == "Count the files"))
    assert Enum.all?(subagents, &(&1["status"] == "completed")), inspect(subagents)
    context
  end

  # --- notices wait for Claude's pending tools (Upstream #15892) -------------------------

  # The fake's turn calls Bash (tool-pending-1) and the call runs on.
  step "Claude has a tool call pending", context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "claudeAgent", "leave a tool pending")

    World.await_state(context, @thread, fn state ->
      Enum.any?(
        StreamState.list(state, "turn-item"),
        &(&1["type"] == "command_execution" and &1["status"] == "running")
      )
    end)

    [run] = World.runs(context, @thread)
    Map.merge(context, %{thread: @thread, active_run: run["id"]})
  end

  # Its delegated task's child (a Codex thread) is steered to its answer.
  step "a delegated task finishes while the run is active", context do
    input = %{
      "task" => "wait for it",
      "mode" => "async",
      "target" => %{"providerInstanceId" => "codex"}
    }

    # The tool finds its caller by the thread's sidebar row.
    World.await_row(World.thread_id(context, @thread), & &1)

    assert {:ok, %{"taskId" => task_id}} =
             World.mcp_tool(context, @thread, "delegate_task", input, "claudeAgent")

    task = fn state -> StreamState.get(state, "subagent")[task_id] end
    child = World.await_state(context, @thread, &task.(&1)) |> task.()
    context = put_in(context, [:threads, "delegated child"], child["childThreadId"])
    World.await_runs(context, "delegated child", ["running"])
    World.send_turn(context, "delegated child", "say Done")
    World.await_state(context, @thread, &(task.(&1)["status"] == "completed"))
    Map.put(context, :notice, &(get_in(&1, ["delegatedCompletion", "taskIds"]) == [task_id]))
  end

  # A schedule bound to the thread, run now as it would be when it comes due.
  step "a scheduled prompt comes due while the run is active", context do
    Mc.ensure(HalC2.ScheduledTasks)
    [run] = World.runs(context, @thread)

    {:ok, %{"task" => %{"id" => id}}} =
      HalC2.ScheduledTasks.upsert(%{
        "title" => "Check the build",
        "prompt" => "Check the build",
        "enabled" => false,
        "schedule" => %{"type" => "interval", "everyMs" => 3_600_000},
        "projectId" => World.project(context).id,
        "threadId" => World.thread_id(context, @thread),
        "workspaceStrategy" => %{"type" => "root"},
        "modelSelection" => run["modelSelection"],
        "runtimeMode" => "full-access",
        "interactionMode" => "default"
      })

    {:ok, _} = HalC2.ScheduledTasks.run_now(%{"id" => id})
    Map.put(context, :notice, &(&1["scheduledTaskId"] == id))
  end

  step "the notice is queued and delivered after the active run ends", context do
    notice = fn state -> Enum.find(StreamState.list(state, "message"), context.notice) end
    state = World.await_state(context, @thread, &(notice.(&1) != nil))
    message = notice.(state)

    assert [%{"id" => active, "status" => "running"}, %{"status" => "queued"} = queued] =
             World.runs(context, @thread)

    assert active == context.active_run
    assert queued["userMessageId"] == message["id"]

    claude_says(context, %{
      "type" => "user",
      "message" => %{
        "role" => "user",
        "content" => [
          %{"type" => "tool_result", "tool_use_id" => "tool-pending-1", "content" => "ok"}
        ]
      }
    })

    claude_says(context, %{"type" => "result", "subtype" => "success", "result" => "Tests pass"})

    World.await_state(context, @thread, fn state ->
      match?(
        [%{"status" => "completed"}, %{"status" => status}] when status != "queued",
        StreamState.list(state, "run") |> Enum.sort_by(& &1["ordinal"])
      )
    end)

    World.await_provider_log(context, "claude", fn entry ->
      get_in(entry, ["in", "type"]) == "user" and
        inspect(get_in(entry, ["in", "message", "content"])) =~
          String.slice(message["text"], 0, 20)
    end)

    context
  end

  step "the user steers the run", context do
    World.send_turn(context, @thread, "Look at this instead", %{
      "dispatchMode" => %{"type" => "steer_active", "targetRunId" => context.active_run}
    })
  end

  step "the steer goes in at once", context do
    World.await_provider_log(context, "claude", &(get_in(&1, ["in", "priority"]) == "now"))
    state = World.await_runs(context, @thread, ["completed"])

    assert Enum.any?(
             StreamState.list(state, "message"),
             &(&1["role"] == "assistant" and &1["text"] =~ "steered: Look at this instead")
           )

    context
  end

  step "the tool call Claude did not run shows as cancelled, not as denied permission",
       context do
    items = StreamState.list(World.stream(context, @thread), "turn-item")
    assert %{"status" => "cancelled"} = Enum.find(items, &(&1["type"] == "command_execution"))
    context
  end

  # --- a wake turn keeps the thread working (Upstream ClaudeAdapterV2 continuations) -----

  # The fake's first turn leaves a background command (task task-build-1) running, and
  # the thread waits on it as `hal_c2_background_wait` makes it.
  step "a Claude thread waiting on a background command", context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "claudeAgent", "background commands: build")

    World.await_runs(context, @thread, ["completed"])
    id = World.thread_id(context, @thread)

    assert {:ok, ["task-build-1"]} =
             HalC2.Claude.ThreadRuntime.await_background(id, ["task-build-1"], true)

    World.await_row(id, &match?([_], &1["pendingBackgroundTasks"]))
    context
  end

  # Claude says the command ended, then answers it in a turn of its own.
  step "the command finishes and Claude begins reacting", context do
    id = World.thread_id(context, @thread)
    flush_rows()

    claude_says(context, %{
      "type" => "system",
      "subtype" => "task_notification",
      "task_id" => "task-build-1",
      "tool_use_id" => "build-1",
      "status" => "completed",
      "summary" => "The build passed"
    })

    # Claude thinks before it answers: the sidebar row in the meantime.
    [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, id)
    _ = :sys.get_state(pid)
    :ok = HalC2.Streams.flush_shell(id)
    context = Map.put(context, :meantime, World.row(context, @thread))

    claude_says(context, %{
      "type" => "assistant",
      "message" => %{
        "id" => "m-build-done",
        "content" => [%{"type" => "text", "text" => "The build passed"}]
      }
    })

    claude_says(context, %{"type" => "result", "subtype" => "success", "is_error" => false})
    idle = first_idle_row(id)
    World.await_runs(context, @thread, ["completed", "completed"])
    Map.put(context, :idle, idle)
  end

  # The row while Claude thinks still holds the command; the stream may fold the rows
  # of quick commits into one, so the rest is checked on the first row that shows the
  # thread idle after the notice: by then the wake's run, the thread's last, has ended.
  step "the thread never leaves working in between", context do
    assert context.meantime["pendingBackgroundTasks"] != [], inspect(context.meantime)
    wake = List.last(World.runs(context, @thread))
    assert %{"latestRunId" => latest, "status" => "completed"} = context.idle
    assert latest == wake["id"], inspect(context.idle)

    assert Enum.any?(
             StreamState.list(World.stream(context, @thread), "turn-item"),
             &(&1["input"] == "run build" and &1["status"] == "completed")
           )

    context
  end

  # The hold on the notice runs out (`:claude_notice_hold_ms`) without Claude answering:
  # the deadline's message is sent at once.
  step "the command finishes and Claude does not answer it", context do
    id = World.thread_id(context, @thread)

    claude_says(context, %{
      "type" => "system",
      "subtype" => "task_notification",
      "task_id" => "task-build-1",
      "tool_use_id" => "build-1",
      "status" => "completed",
      "summary" => "The build passed"
    })

    [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, id)
    assert [_] = :sys.get_state(pid).notices
    send(pid, {:release_notices, "task-build-1"})
    context
  end

  # The notice is held for Claude's answer when the user stops the thread.
  step "the command finishes and the user stops the thread before Claude answers it",
       context do
    id = World.thread_id(context, @thread)

    claude_says(context, %{
      "type" => "system",
      "subtype" => "task_notification",
      "task_id" => "task-build-1",
      "tool_use_id" => "build-1",
      "status" => "completed",
      "summary" => "The build passed"
    })

    [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, id)
    assert [_] = :sys.get_state(pid).notices
    stop_thread(context)
    context
  end

  step "the command ends and the thread settles", context do
    World.await_row(
      World.thread_id(context, @thread),
      &(&1["activeRunId"] == nil and &1["pendingBackgroundTasks"] == [])
    )

    World.await_value(context, @thread, fn state ->
      Enum.any?(
        StreamState.list(state, "turn-item"),
        &(&1["input"] == "run build" and &1["status"] == "completed" and
            &1["output"] == "The build passed")
      )
    end)

    assert ["completed"] = Enum.map(World.runs(context, @thread), & &1["status"])
    context
  end

  defp flush_rows do
    receive do
      {:hal_c2_shell, {:rows, _, _}} -> flush_rows()
    after
      0 -> :ok
    end
  end

  # The first row the shell sends this process that shows the thread idle.
  defp first_idle_row(id) do
    receive do
      {:hal_c2_shell, {:rows, _, changed}} ->
        case List.keyfind(changed, id, 0) do
          {^id, {_kind, %{"activeRunId" => nil, "pendingBackgroundTasks" => []} = row}} -> row
          _ -> first_idle_row(id)
        end
    after
      10_000 -> flunk("the thread never settled")
    end
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
    World.await_value(context, @thread, fn _state ->
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

  # A wake whose subagent finished and that Claude never opened: the thread asks for its
  # run, which has nothing of Claude's to wait on and ends at once (rather than after
  # the two minutes upstream waits for Claude to begin).
  step "a Claude thread is woken by a background subagent finishing", context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "claudeAgent", "survey in the background")

    World.await_runs(context, @thread, ["completed"])

    claude_says(context, %{
      "type" => "system",
      "subtype" => "task_notification",
      "task_id" => "task-agent-1",
      "tool_use_id" => "agent-1",
      "status" => "completed",
      "summary" => "Survey done"
    })

    flush_runtime(context)
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

  step "Claude does not start a turn for the wake within two minutes", context do
    context
  end

  step "the wake run ends", context do
    World.await_runs(context, @thread, ["completed", "completed"])
    assert length(user_messages(context)) == 1
    context
  end

  step "the user's next message starts a turn as usual", context do
    World.post_message(context, @thread, "hello again")
    World.await_runs(context, @thread, ["completed", "completed", "completed"])
    assert length(user_messages(context)) == 2
    context
  end

  # Claude opens a wake while the runtime is held, and the user's message is sent
  # before it is let go: the wake's run then queues behind the user's, and the user's
  # turn starts while the wake is open, so it takes the wake over (a steer). Claude
  # folds the steer into the wake turn ("fold"): one result answers both.
  step "a background command finished and Claude opened a wake turn", context do
    context =
      context |> World.fake_providers() |> World.launch_on(@thread, "claudeAgent", "hello")

    World.await_runs(context, @thread, ["completed"])
    [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, World.thread_id(context, @thread))
    :ok = :sys.suspend(pid)

    claude_says(context, %{
      "type" => "system",
      "subtype" => "task_notification",
      "task_id" => "bash-1",
      "status" => "completed",
      "summary" => "Build finished"
    })

    claude_says(context, %{
      "type" => "assistant",
      "message" => %{
        "id" => "m-wake",
        "content" => [%{"type" => "text", "text" => "The build passed"}]
      }
    })

    Map.put(context, :held_runtime, pid)
  end

  step "the user's queued message started and Claude folded it into the wake turn", context do
    # The send starts its turn inline, on the held runtime: it goes in a task, and the
    # runtime is let go once the user's run is on the stream, ahead of the wake's.
    send_task = Task.async(fn -> World.post_message(context, @thread, "fold this in") end)
    World.await_value(context, @thread, fn _ -> length(World.runs(context, @thread)) == 2 end)
    :ok = :sys.resume(context.held_runtime)
    Task.await(send_task)
  end

  step "the queued wake run starts after the user turn ended", context do
    World.await_runs(context, @thread, ["completed", "completed", "completed"])
    context
  end

  step "the wake run ends without waiting for Claude", context do
    [_, user, wake] = World.runs(context, @thread)
    messages = World.stream(context, @thread) |> StreamState.get("message")
    assert messages[user["userMessageId"]]["text"] == "fold this in"
    assert messages[wake["userMessageId"]]["creationSource"] == "provider"
    assert "steered: fold this in" in World.replies(context, @thread)
    assert length(user_messages(context)) == 2
    context
  end

  step "the thread stops showing working", context do
    refute Enum.any?(World.runs(context, @thread), &(&1["status"] in ["running", "starting"]))
    [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, World.thread_id(context, @thread))
    assert %{turn: nil, wake: nil} = :sys.get_state(pid)
    context
  end

  # A wake Claude opens hits the usage limit; an empty task notice and its own empty
  # `result` follow it while its run waits to start.
  step "a Claude turn hits a usage limit", context do
    context =
      context |> World.fake_providers() |> World.launch_on(@thread, "claudeAgent", "hello")

    World.await_runs(context, @thread, ["completed"])
    resets = System.system_time(:second) + 3600

    claude_says(context, %{
      "type" => "stream_event",
      "event" => %{"type" => "message_start", "message" => %{"id" => "m-limit"}}
    })

    refuse(context, "five_hour", resets)

    claude_says(context, %{
      "type" => "assistant",
      "error" => "rate_limit",
      "message" => %{
        "id" => "m-limit",
        "content" => [%{"type" => "text", "text" => "You've hit your limit"}]
      }
    })

    claude_says(context, %{
      "type" => "result",
      "subtype" => "success",
      "is_error" => true,
      "result" => "You've hit your limit"
    })

    Map.put(context, :limit_reset_s, resets)
  end

  step "Claude then reports a background task notice with nothing in it", context do
    claude_says(context, %{"type" => "system", "subtype" => "task_notification"})

    claude_says(context, %{
      "type" => "result",
      "subtype" => "success",
      "is_error" => false,
      "result" => ""
    })

    context
  end

  step "the turn ends as stopped by the usage limit", context do
    World.await_runs(context, @thread, ["completed", "failed"])

    row =
      World.await_row(
        World.thread_id(context, @thread),
        &(&1["lastErrorClass"] == "usage_limit" and is_binary(&1["usageLimitResetAt"]))
      )

    Map.put(context, :limited_row, row)
  end

  step "it can be resumed when the limit resets", context do
    row = context.limited_row
    stopped = DateTime.to_iso8601(DateTime.utc_now(), :extended)

    assert %{"type" => "message.dispatch"} =
             HalC2.Orchestration.LimitRecovery.command(
               row
               |> Map.put("latestRunCompletedAt", stopped)
               |> Map.put("limitRecovery", %{
                 "runId" => row["latestRunId"],
                 "resetAt" => row["usageLimitResetAt"],
                 "autoResume" => true
               }),
               true,
               (context.limit_reset_s + 1) * 1000
             )

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

  # --- reverting to the turn after a compaction ---------------------------------------------

  step "a Claude thread with two turns, a {string} turn, and a turn that edited a file",
       %{args: [compact]} = context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "claudeAgent", "first question")

    World.await_runs(context, @thread, ["completed"])
    context = World.post_message(context, @thread, "second question")
    World.await_runs(context, @thread, ["completed", "completed"])
    context = World.post_message(context, @thread, compact)

    World.await_value(context, @thread, fn state ->
      length(StreamState.list(state, "run")) == 3 and compactions(context) != []
    end)

    context = World.post_message(context, @thread, "edit a file")

    World.await_value(context, @thread, fn state ->
      Enum.map(StreamState.list(state, "run"), & &1["status"]) ==
        ["completed", "completed", "completed", "completed"]
    end)

    context
  end

  step "the user reverts the thread to the end of the {string} turn",
       %{args: [_compact]} = context do
    context
    |> World.rollback(@thread, 3, %{"restoreFiles" => false})
    |> Map.put(:compact_reverted, true)
  end

  step "the revert succeeds", context do
    assert {:ok, _} = context.reply
    context
  end

  # --- reverting to a turn a subagent ended ------------------------------------------------

  # The fake's first turn ends with a background subagent's message; it cannot resume at
  # a subagent's message, as Claude Code cannot.
  step "a Claude turn whose last message came from one of its subagents", context do
    context = World.fake_providers(context)
    context = World.launch_on(context, @thread, "claudeAgent", "subagent has the last word")
    World.await_runs(context, @thread, ["completed"])
    context = World.post_message(context, @thread, "second question")
    World.await_runs(context, @thread, ["completed", "completed"])
    context
  end

  step "the user reverts the thread to that turn", context do
    context = World.rollback(context, @thread, 1, %{"restoreFiles" => false})
    assert {:ok, _} = context.reply
    context
  end

  step "sends a new message", context do
    context = World.post_message(context, @thread, "where are we")
    World.await_latest_run(context, @thread, "completed")
    context
  end

  step "Claude answers from the conversation as it stood at that turn", context do
    assert "resumed at uuid-1 fork False history False" in World.replies(context, @thread),
           inspect(World.replies(context, @thread))

    context
  end

  # --- a run stopped after a revert ---------------------------------------------------------

  step "the user reverted a Claude thread to an earlier turn", context do
    context = World.fake_providers(context)
    context = World.launch_on(context, @thread, "claudeAgent", "first question")
    World.await_runs(context, @thread, ["completed"])
    context = World.post_message(context, @thread, "second question")
    World.await_runs(context, @thread, ["completed", "completed"])
    context = World.rollback(context, @thread, 1, %{"restoreFiles" => false})
    assert {:ok, _} = context.reply
    context
  end

  step "a later run was stopped after Claude wrote part of its reply", context do
    context = World.post_message(context, @thread, "answer halfway")

    World.await_value(context, @thread, fn state ->
      Enum.any?(StreamState.list(state, "message"), &(&1["text"] =~ "Half an answer"))
    end)

    stop_and_release(context)
  end

  step "a later run was stopped before Claude wrote anything", context do
    context = World.post_message(context, @thread, "wait for me")
    World.await_running(context, @thread)

    World.await_provider_log(
      context,
      "claude",
      &(get_in(&1, ["in", "message", "content"]) == "wait for me")
    )

    stop_and_release(context)
  end

  step "the user sends a new message", context do
    context = World.post_message(context, @thread, "where are we")
    World.await_latest_run(context, @thread, "completed")
    context
  end

  # Resumed in full: Claude's transcript ends with the stopped run's partial answer.
  step "Claude answers with the stopped run's reply in its context", context do
    assert "resumed at None fork False history False" in World.replies(context, @thread),
           inspect(World.replies(context, @thread))

    assert "--resume" in last_argv(context)
    context
  end

  step "reverting again and sending still works", context do
    context = World.rollback(context, @thread, 1, %{"restoreFiles" => false})
    assert {:ok, _} = context.reply
    context = World.post_message(context, @thread, "where are we")
    World.await_latest_run(context, @thread, "completed")

    assert "resumed at uuid-1 fork False history False" in World.replies(context, @thread),
           inspect(World.replies(context, @thread))

    context
  end

  step "Claude continues from the turn the thread was reverted to", context do
    assert "resumed at uuid-1 fork False history False" in World.replies(context, @thread),
           inspect(World.replies(context, @thread))

    context
  end

  # --- a revert Claude cannot resume at -------------------------------------------------------

  # A head in a subagent's transcript, which the fake, like Claude Code, cannot resume
  # the conversation at: its process exits at startup. Set as a rollback sets one.
  step "the user reverted a Claude thread to a message Claude cannot resume at", context do
    context = World.fake_providers(context)
    context = World.launch_on(context, @thread, "claudeAgent", "first question")
    World.await_runs(context, @thread, ["completed"])
    thread_id = World.thread_id(context, @thread)
    {:ok, patch} = HalC2.Claude.ThreadRuntime.rollback(thread_id, %{head: "sub-uuid-1"})

    :ok =
      HalC2.Streams.transact(thread_id, :thread, fn stream ->
        [id] = Map.keys(stream.entities["provider-thread"])
        {[HalC2.Orchestration.upsert(stream, "provider-thread", id, &Map.merge(&1, patch))], :ok}
      end)

    context
  end

  step "Claude answers it in a new conversation handed the thread", context do
    argv = last_argv(context)
    refute "--resume" in argv, inspect(argv)
    prompt = last_prompt(context)
    assert prompt =~ "User: first question", prompt
    assert String.ends_with?(prompt, "where are we"), prompt
    context
  end

  # --- a turn that failed before its prompt was sent ------------------------------------------

  step "a Claude thread another agent worked on since Claude last ran", context do
    context = World.fake_providers(context)
    context = World.launch_on(context, @thread, "claudeAgent", "first question")
    World.await_runs(context, @thread, ["completed"])
    context = switch_provider(context, "codex", "gpt-5.4")
    context = World.post_message(context, @thread, "Carry on")
    World.await_runs(context, @thread, ["completed", "completed"])
    context = switch_provider(context, "claudeAgent", "claude-opus-4-6")
    Map.put(context, :claude_session, claude_session(context))
  end

  # Claude cannot be started, so neither prompt reaches it.
  step "two Claude turns failed before Claude got their prompts", context do
    release_claude(context)
    claude = Application.get_env(:hal_c2, :claude_command)
    Application.put_env(:hal_c2, :claude_command, [Path.join(context.mc.home, "no-claude")])

    for text <- ["try once", "try twice"] do
      World.post_message(context, @thread, text)
      World.await_latest_run(context, @thread, "failed")
    end

    Application.put_env(:hal_c2, :claude_command, claude)
    context
  end

  # The run ends while the thread's Claude is starting for it, as when the user stops it
  # during a slow start or the start gives up waiting: the runtime is held until then.
  step "a Claude turn ended while Claude started for it", context do
    abandon_starting(context, false)
    World.await_latest_run(context, @thread, "interrupted")
    context
  end

  # As above, and the next message's turn starts before the runtime gets to it, as after a
  # start that outlived its caller's timeout; Claude answers that one.
  step "a Claude turn ended while Claude started for it, after the next one started",
       context do
    abandon_starting(context, true)
    World.await_latest_run(context, @thread, "completed")
    context
  end

  step "a Claude turn ended while Claude started for it, and the next one was handed another agent's work",
       context do
    abandon_starting(context, :handed)
    World.await_latest_run(context, @thread, "completed")
    context
  end

  step "Claude's process is let go and the user sends a new message", context do
    release_claude(context)
    context = World.post_message(context, @thread, "where are we")
    World.await_latest_run(context, @thread, "completed")
    context
  end

  step "Claude answers from the whole conversation, the next turn's exchange included",
       context do
    replies = World.replies(context, @thread)
    # The next turn ran on the process started at the revert; a new one resumes it all.
    assert List.last(replies) == "resumed at None fork False history False", inspect(replies)
    context
  end

  # Holds the thread's Claude runtime while a message's run starts, ends that run, and
  # with `overtaken` starts the next message's run too, then lets the runtime go.
  defp abandon_starting(context, overtaken) do
    runtime =
      case DynamicSupervisor.start_child(
             HalC2.Plugins.sessions("claudeAgent"),
             {HalC2.Claude.ThreadRuntime, World.thread_id(context, @thread)}
           ) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    :ok = :sys.suspend(runtime)
    before = MapSet.new(World.runs(context, @thread), & &1["id"])

    # The message's dispatch starts the turn itself, so it waits on the runtime.
    sent = Task.async(fn -> World.post_message(context, @thread, "try again") end)

    next =
      try do
        held(runtime, 1)
        [run] = for %{"id" => id} <- World.runs(context, @thread), id not in before, do: id

        :ok =
          HalC2.Orchestration.TurnWriter.abandon(
            World.thread_id(context, @thread),
            run,
            "interrupted",
            nil
          )

        # Another agent works before the next message, so that turn is handed its work.
        if overtaken == :handed do
          context = switch_provider(context, "codex", "gpt-5.4")
          context = World.post_message(context, @thread, "Meanwhile")
          World.await_latest_run(context, @thread, "completed")
          switch_provider(context, "claudeAgent", "claude-opus-4-6")
        end

        if overtaken do
          next = Task.async(fn -> World.post_message(context, @thread, "and again") end)
          held(runtime, 2)
          next
        end
      after
        :sys.resume(runtime)
      end

    Task.await(sent)
    if next, do: Task.await(next)
    context
  end

  step "Claude resumes its original session", context do
    argv = last_argv(context)
    assert flag_value(argv, "--resume") == context.claude_session, inspect(argv)
    assert claude_session(context) == context.claude_session
    context
  end

  step "the context the failed turns did not send is sent with the new message", context do
    prompt = last_prompt(context)
    assert prompt =~ "User: Carry on", prompt
    assert String.ends_with?(prompt, "where are we"), prompt
    context
  end

  # Stops the running turn, then lets go of the thread's Claude as the idle sweep does
  # (`ThreadRuntime`'s `:release`), so the next message starts Claude again from the
  # recorded session instead of the process that ran the stopped turn.
  defp stop_and_release(context) do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "threadId" => World.thread_id(context, @thread)
      })

    World.await_latest_run(context, @thread, "interrupted")
    [{runtime, _}] = Registry.lookup(HalC2.Claude.Registry, World.thread_id(context, @thread))
    ref = Process.monitor(runtime)
    assert :ok = GenServer.call(runtime, :release)
    assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
    context
  end

  # --- auto on a model without it -----------------------------------------------------

  # The fake runs such a model in its default mode and refuses a switch to auto, as
  # Claude Code does when its auto gate is off for the model.
  step "a Claude thread in auto on a model that Claude runs without its auto mode", context do
    World.put_os_env("FAKE_CLAUDE_NO_AUTO", "1")

    context
    |> World.fake_providers()
    |> World.launch_on(@thread, "claudeAgent", "which mode", %{"runtimeMode" => "auto"})
  end

  step "Claude ran the first turn in its default mode", context do
    World.await_runs(context, @thread, ["completed"])
    assert flag_value(last_argv(context), "--permission-mode") == "auto"
    assert World.replies(context, @thread) == ["mode default"]
    context
  end

  step "the user sends a follow-up to that thread", context do
    World.post_message(context, @thread, "which mode")
  end

  step "the follow-up runs in the mode Claude reported for the first turn", context do
    World.await_runs(context, @thread, ["completed", "completed"])
    assert World.replies(context, @thread) == ["mode default", "mode default"]
    context
  end

  # Claude is not asked to switch to auto, and its process is not restarted to get it.
  step "it does not fail asking for auto again", context do
    log = World.provider_log(context, "claude")
    assert Enum.count(log, &Map.has_key?(&1, "argv")) == 1

    refute Enum.any?(
             log,
             &(get_in(&1, ["in", "request", "subtype"]) == "set_permission_mode")
           )

    assert Enum.all?(
             StreamState.list(World.stream(context, @thread), "provider-session"),
             &(&1["lastError"] == nil)
           )

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

  defp switch_provider(context, instance, model) do
    context =
      World.command(context, %{
        "type" => "provider.switch",
        "threadId" => World.thread_id(context, @thread),
        "modelSelection" => %{"instanceId" => instance, "model" => model}
      })

    assert {:ok, _} = context.reply
    context
  end

  # The native session of the thread's Claude provider thread.
  defp claude_session(context) do
    World.stream(context, @thread)
    |> StreamState.list("provider-thread")
    |> Enum.find_value(
      &(&1["providerInstanceId"] == "claudeAgent" and get_in(&1, ["nativeThreadRef", "nativeId"]))
    )
  end

  # The last user message Claude was sent.
  defp last_prompt(context) do
    for(
      %{"in" => %{"type" => "user", "message" => %{"content" => text}}} <-
        World.provider_log(context, "claude"),
      do: if(is_binary(text), do: text, else: Enum.map_join(text, &(&1["text"] || "")))
    )
    |> List.last()
  end

  # Until the held runtime has `count` turns to start. The calls are in its mailbox, not
  # on the stream, so there is nothing to wake on.
  defp held(pid, count, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    {:messages, messages} = Process.info(pid, :messages)

    cond do
      Enum.count(messages, &match?({:"$gen_call", _, {:start_turn, _}}, &1)) >= count ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("the turn never reached Claude's runtime")

      true ->
        receive do
        after
          10 -> held(pid, count, deadline)
        end
    end
  end

  # Lets go of the thread's Claude process, if it has one, as the idle sweep does.
  defp release_claude(context) do
    case Registry.lookup(HalC2.Claude.Registry, World.thread_id(context, @thread)) do
      [{runtime, _}] ->
        ref = Process.monitor(runtime)
        assert :ok = GenServer.call(runtime, :release)
        assert_receive {:DOWN, ^ref, :process, _, _}, 5_000

      [] ->
        :ok
    end
  end

  defp flag_value(argv, flag) do
    case Enum.chunk_every(argv, 2, 1, :discard) |> Enum.find(&match?([^flag, _], &1)) do
      [_, value] -> value
      _ -> nil
    end
  end

  defp launch_args(context, text) do
    # A `--settings <file>` launch argument names a file in the thread's
    # folder; the scenario's is written there (its `includeCoAuthoredBy` is
    # the user's, its `showThinkingSummaries` collides with HAL-C2's own).
    case Regex.run(~r/--settings[= ]([^\s'"]+\.json)/, text) do
      [_, file] ->
        path = Path.join(World.project(context).root, file)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, ~s({"includeCoAuthoredBy": false, "showThinkingSummaries": false}))

      _ ->
        :ok
    end

    World.put_settings(context, %{"providers" => %{"claudeAgent" => %{"launchArgs" => text}}})
    World.reset_provider_caches()
    context
  end

  step ~r/^a Claude turn runs on (?<model>(?!it ).+)$/, %{args: [model]} = context do
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
    # The user's appended instruction rides in HAL-C2's one appended prompt.
    assert Enum.count(argv, &(&1 == "--append-system-prompt")) == 1
    assert flag_value(argv, "--append-system-prompt") =~ "be brief"
    context
  end

  step "the Claude instance has the launch argument {string}", %{args: [argument]} = context do
    context |> World.fake_providers() |> launch_args(argument)
  end

  # --- launch arguments: --settings, appended instructions, --add-dir ------------------

  step "Claude runs with the user's settings and HAL-C2's settings together", context do
    merged = settings(Map.put(context, :argv, last_argv(context)))
    assert merged["includeCoAuthoredBy"] == false
    assert merged["showThinkingSummaries"] == true
    assert Enum.count(last_argv(context), &(&1 == "--settings")) == 1
    context
  end

  step "where both set the same key, HAL-C2's value is used", context do
    merged = settings(Map.put(context, :argv, last_argv(context)))
    assert merged["showThinkingSummaries"] == true
    context
  end

  # The outline's inline-JSON row: its quotes sit inside the Gherkin string.
  step ~r/^the Claude instance has the launch argument "--settings '(?<json>.+)'"$/,
       %{args: [json]} = context do
    context |> World.fake_providers() |> launch_args("--settings '#{json}'")
  end

  step "the Claude instance has the launch argument \"--settings\" with JSON that does not parse",
       context do
    context |> World.fake_providers() |> launch_args("--settings {broken-value")
  end

  step "the turn fails before Claude starts, saying its settings argument could not be read",
       context do
    assert last_error(context) =~ "--settings launch argument could not be read"
    assert World.claude_starts(context) == []
    context
  end

  step "the error and the logs name no value from those settings", context do
    refute last_error(context) =~ "broken-value"
    assert World.provider_log(context, "claude") == []
    context
  end

  step "the Claude instance's --settings launch argument turns off bypassing permissions",
       context do
    context
    |> World.fake_providers()
    |> launch_args(~s|--settings '{"permissions":{"disableBypassPermissionsMode":"disable"}}'|)
  end

  step "the thread says full access is not available and runs in the mode Claude allows",
       context do
    assert flag_value(last_argv(context), "--permission-mode") == "auto"
    assert [notice] = bypass_notices(context)
    assert notice =~ "turn off bypassing permissions"
    context
  end

  step "Claude's managed settings set \"permissions.disableBypassPermissionsMode\" to false",
       context do
    context = World.fake_providers(context)
    path = Path.join(Mc.tmp_dir(context.mc, "claude-managed"), "managed-settings.json")
    World.put_app_env(:claude_managed_settings_path, path)
    File.write!(path, ~s({"permissions": {"disableBypassPermissionsMode": false}}))
    context
  end

  step ~r/^the Claude instance has the launch argument --append-system-prompt "(?<text>[^"]+)"$/,
       %{args: [text]} = context do
    # HAL-C2's own instructions ride with its tools.
    Mc.ensure(HalC2.Mcp)
    context |> World.fake_providers() |> launch_args(~s(--append-system-prompt "#{text}"))
  end

  step ~r/^the Claude instance has the launch argument --append-system-prompt-file (?<path>.+)$/,
       %{args: [path]} = context do
    Mc.ensure(HalC2.Mcp)
    context = World.fake_providers(context)
    file = Path.join(World.project(context).root, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "Always answer in Icelandic.\n")

    context
    |> launch_args("--append-system-prompt-file #{path}")
    |> Map.put(:appended_file_text, "Always answer in Icelandic.")
  end

  defp appended_prompt(context) do
    argv = last_argv(context)
    assert Enum.count(argv, &(&1 == "--append-system-prompt")) == 1
    prompt = flag_value(argv, "--append-system-prompt")
    # HAL-C2's own instructions come first (they name its tools).
    assert prompt =~ "delegate_task"
    prompt
  end

  step "Claude receives HAL-C2's instructions followed by {string}",
       %{args: [added]} = context do
    assert String.ends_with?(appended_prompt(context), added)
    context
  end

  step "Claude receives HAL-C2's instructions followed by the contents of rules.md in the thread's folder",
       context do
    assert String.ends_with?(appended_prompt(context), context.appended_file_text)
    context
  end

  step "the turn fails saying {string} could not be read", %{args: [path]} = context do
    assert last_error(context) =~ ~s("#{path}" could not be read)
    assert World.claude_starts(context) == []
    context
  end

  # The folder a scenario names ("/work/tools"), as a real folder of its own.
  defp added_root(context, shown) do
    case get_in(context, [:dir_map, shown]) do
      nil ->
        root = Mc.tmp_dir(context.mc, "add-" <> String.replace(shown, ~r/[^A-Za-z0-9]+/, "-"))
        {root, Map.update(context, :dir_map, %{shown => root}, &Map.put(&1, shown, root))}

      root ->
        {root, context}
    end
  end

  defp actual_dir(context, shown), do: get_in(context, [:dir_map, shown]) || shown

  step "Claude's launch arguments add the folder {string}", %{args: [folder]} = context do
    context = World.fake_providers(context)
    {root, context} = added_root(context, folder)
    launch_args(context, "--add-dir #{root}")
  end

  step "{string} has the skill {string}", %{args: [folder, name]} = context do
    {context, _home} = skills_home(context)
    root = actual_dir(context, folder)

    write_skill_file(
      Path.join([root, ".claude", "skills"]),
      name,
      "---\ndescription: Demo\n---\nDo it.\n"
    )

    context
  end

  step "the user types \"$\" in a Claude thread's composer", context do
    open_skill_list(context)
  end

  step "a message mentioning \"$demo\" runs it as Claude's skill", context do
    context = World.launch_on(context, @thread, "claudeAgent", "Please $demo this")
    World.await_runs(context, @thread, ["completed"])
    assert List.last(last_user_texts(context)) =~ ~r{^/demo(\s|$)}
    context
  end

  step "Claude's launch arguments are {string}", %{args: [text]} = context do
    context = World.fake_providers(context)
    {context, _home} = skills_home(context)

    # The two folders the outline names, each with a skill of its own.
    {text, context} =
      Enum.reduce(["/work/apps", "/work/lib"], {text, context}, fn shown, {text, context} ->
        if String.contains?(text, shown) do
          {root, context} = added_root(context, shown)
          skill = if shown =~ "apps", do: "apps-skill", else: "lib-skill"

          write_skill_file(
            Path.join([root, ".claude", "skills"]),
            skill,
            "---\ndescription: From #{shown}\n---\nDo it.\n"
          )

          {String.replace(text, shown, root), context}
        else
          {text, context}
        end
      end)

    launch_args(context, text)
  end

  step "a Claude session starts", context do
    context = World.launch_on(context, @thread, "claudeAgent", "hello")
    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "Claude may work in {string} and {string} without asking",
       %{args: [first, second]} = context do
    dirs = HalC2.Claude.Provider.add_dirs(last_argv(context))
    assert actual_dir(context, first) in dirs
    assert actual_dir(context, second) in dirs
    context
  end

  step "Claude may work in {string} without asking", %{args: [folder]} = context do
    dirs = HalC2.Claude.Provider.add_dirs(last_argv(context))
    assert actual_dir(context, folder) in dirs
    context
  end

  step "skills under both folders are offered", context do
    context = open_skill_list(context)
    assert offered(context, "apps-skill")
    assert offered(context, "lib-skill")
    context
  end

  # --- who started Claude, and the session it must not join ----------------------------

  step "the MC was started from inside a Claude Code session", context do
    World.put_os_env("CLAUDECODE", "1")
    World.put_os_env("CLAUDE_CODE_ENTRYPOINT", "cli")
    World.put_os_env("CLAUDE_CODE_SESSION_ID", "the-session-that-started-the-mc")
    World.fake_providers(context)
  end

  step "the Claude instance's environment names {string} as the entrypoint",
       %{args: [name]} = context do
    context
    |> World.fake_providers()
    |> instance_env(%{"CLAUDE_CODE_ENTRYPOINT" => name})
  end

  step "Claude's settings file and the instance's environment both name one", context do
    context = World.fake_providers(context)
    {context, home} = skills_home(context)

    File.write!(
      Path.join(home, "settings.json"),
      JSON.encode!(%{"env" => %{"CLAUDE_CODE_ENTRYPOINT" => "settings-bot"}})
    )

    context
    |> instance_env(%{"CLAUDE_CODE_ENTRYPOINT" => "instance-bot"})
    |> Map.put(:settings_entrypoint, "settings-bot")
  end

  step "the MC starts Claude for a turn, a status check or a thread title", context do
    context = World.text_writers(context, [:claude])

    World.merge_settings(%{
      "textGenerationModelSelection" => %{"instanceId" => "claudeAgent", "model" => "haiku"}
    })

    :ok = HalC2.Claude.Provider.load()
    context = World.launch_on(context, @thread, "claudeAgent", "hello")
    World.await_runs(context, @thread, ["completed"])

    assert {:ok, %{"title" => _}} =
             HalC2.TextGeneration.thread_title(World.project(context).root, "Fix the login form")

    context
  end

  step "the MC starts Claude for a turn", context do
    context = World.launch_on(context, @thread, "claudeAgent", "hello")
    World.await_runs(context, @thread, ["completed"])
    context
  end

  defp start_envs(context) do
    for %{"argv" => _argv, "env" => env} <- World.provider_log(context, "claude"), do: env
  end

  step "Claude names HAL-C2 as the program that started it", context do
    for env <- start_envs(context), do: assert(env["CLAUDE_CODE_ENTRYPOINT"] == "hal-c2")
    for call <- World.text_calls(context), do: assert(call["entrypoint"] == "hal-c2")
    context
  end

  step "Claude names {string} as the program that started it", %{args: [name]} = context do
    for env <- start_envs(context), do: assert(env["CLAUDE_CODE_ENTRYPOINT"] == name)
    for call <- World.text_calls(context), do: assert(call["entrypoint"] == name)
    context
  end

  step "Claude names the one in Claude's settings file as the program that started it",
       context do
    for env <- start_envs(context),
        do: assert(env["CLAUDE_CODE_ENTRYPOINT"] == context.settings_entrypoint)

    for call <- World.text_calls(context),
        do: assert(call["entrypoint"] == context.settings_entrypoint)

    context
  end

  step "the Claude instance's environment sets \"CLAUDE_CODE_SHELL\"", context do
    context
    |> World.fake_providers()
    |> instance_env(%{"CLAUDE_CODE_SHELL" => "/bin/the-instance-shell"})
  end

  step "Claude is not part of the Claude Code session that started the MC", context do
    env = context |> start_envs() |> List.last()
    refute Map.has_key?(env, "CLAUDECODE")
    refute Map.has_key?(env, "CLAUDE_CODE_SESSION_ID")
    context
  end

  step "Claude gets the instance's \"CLAUDE_CODE_SHELL\"", context do
    env = context |> start_envs() |> List.last()
    assert env["CLAUDE_CODE_SHELL"] == "/bin/the-instance-shell"
    context
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

  # Codex's "a new Codex app-server is started" names the thread whose turn ran.
  step "the turn runs", context do
    case context[:turn_thread] do
      nil ->
        World.await_runs(context, @thread, ["completed"])
        assert "Hello from claude" in World.replies(context, @thread)

      title ->
        assert "Hello from codex" in World.replies(context, title)
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

  # The first turn's session is let go of, as when the MC restarts, and its transcript
  # is left as it is when Claude went down before saving the prompt: without it, or
  # never written at all.
  step ~r/^Claude went down before saving the prompt the MC sent it, leaving its transcript (?<transcript>without it|with only its metadata|nowhere at all)$/,
       %{args: [transcript]} = context do
    World.put_os_env("CLAUDE_CONFIG_DIR", Mc.tmp_dir(context.mc, "claude-unsaved"))
    World.put_os_env("FAKE_SESSIONS", "1")
    context = World.fake_providers(context) |> World.launch_on(@thread, "claudeAgent", "hello")
    World.await_runs(context, @thread, ["completed"])
    release_claude(context)
    [path] = Path.wildcard(Path.join(System.get_env("CLAUDE_CONFIG_DIR"), "projects/*/*.jsonl"))

    case transcript do
      "without it" ->
        kept = path |> File.stream!() |> Enum.reject(&(JSON.decode!(&1)["type"] == "user"))
        File.write!(path, kept)

      # What Claude writes before the message itself, as when the MC stopped in between.
      "with only its metadata" ->
        session = Path.basename(path, ".jsonl")

        File.write!(
          path,
          Enum.map_join(
            [
              %{"type" => "last-prompt", "lastPrompt" => "hello", "sessionId" => session},
              %{"type" => "atis-latch", "sessionId" => session},
              %{"type" => "cost-state", "sessionId" => session}
            ],
            &(JSON.encode!(&1) <> "\n")
          )
        )

      "nowhere at all" ->
        File.rm!(path)
    end

    Map.put(context, :unsaved, native_session(context))
  end

  step "the user sends the next message in the thread", context do
    context = World.post_message(context, @thread, "hello from claude")
    World.await_runs(context, @thread, ["completed", "completed"])
    context
  end

  step "Claude is handed the whole thread", context do
    prompts =
      for %{"in" => %{"type" => "user", "message" => %{"content" => content}}} <-
            World.provider_log(context, "claude"),
          do: inspect(content)

    assert List.last(prompts) =~ "<conversation_history>"
    assert List.last(prompts) =~ "hello"
    context
  end

  # The next session after the new one resumes it, not the one Claude never saved.
  step "later messages in the thread do not fail with {string}", %{args: [_]} = context do
    fresh = native_session(context)
    assert fresh != context.unsaved
    release_claude(context)
    context = World.post_message(context, @thread, "and again")
    World.await_runs(context, @thread, ["completed", "completed", "completed"])
    starts = for %{"argv" => argv} <- World.provider_log(context, "claude"), do: argv
    assert ["--resume", fresh] in pairs(List.last(starts))
    context
  end

  defp release_claude(context) do
    [{runtime, _}] = Registry.lookup(HalC2.Claude.Registry, World.thread_id(context, @thread))
    ref = Process.monitor(runtime)
    :ok = GenServer.call(runtime, :release)
    assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
  end

  defp native_session(context) do
    World.stream(context, @thread)
    |> StreamState.list("provider-thread")
    |> Enum.find_value(&get_in(&1, ["nativeThreadRef", "nativeId"]))
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
    |> Map.put(:slash_commands, (snapshot && snapshot["slashCommands"]) || [])
  end

  step ~r/^a project with commands under its "\.claude\/commands"$/, context do
    root = World.project(context).root
    dir = Path.join([root, ".claude", "commands"])
    File.mkdir_p!(Path.join(dir, "db"))

    File.write!(
      Path.join(dir, "deploy.md"),
      "---\ndescription: Ships the app\nargument-hint: [env]\n---\nDeploy to $ARGUMENTS.\n"
    )

    File.write!(Path.join([dir, "db", "migrate.md"]), "\nRuns the migrations\n")
    project_skill(context, "review")
  end

  step ~r/^a Claude skill whose frontmatter description contains an unquoted ": "$/, context do
    project_skill(
      context,
      "triage",
      "---\ndescription: Sorts issues: bugs first\ndisable-model-invocation: true\n---\nSort.\n"
    )

    project_skill(context, "broken", "---\ndescription: [never closed\n---\nBody.\n")
  end

  step "the skill picker is opened", context do
    context = World.fake_providers(context)
    open_skill_list(context)
  end

  step "the skill is listed with its invocation metadata", context do
    assert %{"description" => "Sorts issues: bugs first", "userInvocationOnly" => true} =
             offered(context, "triage")

    context
  end

  step "a skill with malformed structure is still left out", context do
    refute offered(context, "broken")
    context
  end

  step "the user opens the slash menu in a thread of that project", context do
    context = World.fake_providers(context)
    open_skill_list(context)
  end

  step "those commands are listed, not only the ones found in the MC's directory", context do
    commands = Map.new(context.slash_commands, &{&1["name"], &1})

    assert %{"description" => "Ships the app", "input" => %{"hint" => "[env]"}} =
             commands["deploy"]

    assert %{"description" => "Runs the migrations"} = commands["migrate"]
    assert commands["compact"]
    context
  end

  step "if command discovery fails the workspace's skills are still listed", context do
    dir = Path.join([World.project(context).root, ".claude", "commands"])
    File.chmod!(dir, 0o000)
    ExUnit.Callbacks.on_exit(fn -> File.chmod(dir, 0o755) end)
    context = open_skill_list(context)
    File.chmod!(dir, 0o755)

    assert Enum.map(context.slash_commands, & &1["name"]) == ["compact"]
    assert offered(context, "review")
    context
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

  # Claude's plugin registry and `enabledPlugins`, as `/plugin install` leaves them:
  # `acme` is on, `tidy` is installed but switched off.
  step "the Claude plugin {string} is installed and enabled and has the skill {string}",
       %{args: [plugin, skill]} = context do
    {context, home} = skills_home(context)

    install = fn name ->
      path = Path.join([home, "plugins", "cache", "market", name, "1.0.0"])

      write_skill_file(Path.join(path, "skills"), if(name == plugin, do: skill, else: "fmt"), """
      ---
      description: From #{name}
      ---
      Do it.
      """)

      {"#{name}@market", [%{"scope" => "user", "installPath" => path, "version" => "1.0.0"}]}
    end

    plugins = Map.new([install.(plugin), install.("tidy")])

    File.write!(
      Path.join([home, "plugins", "installed_plugins.json"]),
      JSON.encode!(%{"version" => 2, "plugins" => plugins})
    )

    settings = Path.join(home, "settings.json")

    File.write!(
      settings,
      JSON.encode!(%{"enabledPlugins" => %{"#{plugin}@market" => true, "tidy@market" => false}})
    )

    context
  end

  step ~r/^"(?<name>[a-z0-9_-]+:[a-z0-9_-]+)" is offered$/, %{args: [name]} = context do
    assert %{"scope" => "plugin", "enabled" => true} = offered(context, name)
    context
  end

  step "the skills of a disabled plugin are not", context do
    refute Enum.any?(context.skills, &(&1["name"] in ["tidy:fmt", "fmt"]))
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

  step "the project has the Claude skills {string} and {string}, which only the user may invoke",
       %{args: [first, second]} = context do
    context = World.fake_providers(context)
    body = "---\ndescription: Only on request\ndisable-model-invocation: true\n---\nDo it.\n"
    context |> project_skill(first, body) |> project_skill(second, body)
  end

  # Upstream #19485: the earlier skill is named with where its instructions are.
  step "Claude is told the user asked for {string} and where its instructions are",
       %{args: [name]} = context do
    root = World.project(context).root
    path = Path.join([root, ".claude", "skills", name, "SKILL.md"])

    assert hd(last_user_texts(context)) ==
             "/#{name} [The user invoked this skill. Follow the instructions at: #{path}] the diff, then"

    context
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

  step "the project's Claude settings hold a \"//\" comment ended by a lone carriage return",
       context do
    context = context |> World.fake_providers() |> project_skill("review")
    root = World.project(context).root
    path = Path.join([root, ".claude", "settings.json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{\n  // the team's switches" <> <<13>>)
    Map.put(context, :settings_path, path)
  end

  step "the line after it switches the skill {string} off", %{args: [name]} = context do
    File.write!(
      context.settings_path,
      "  \"skillOverrides\": {\"#{name}\": \"off\"}\n}\n",
      [:append]
    )

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

  # --- MCP tool presentation -------------------------------------------------------------

  # Claude Code names an MCP tool use in the assistant message's `tool_use_meta`; the
  # second call has no entry, as from a Claude Code that sends none.
  step "Claude calls an MCP tool", context do
    context = running_turn(context)

    claude_says(context, %{
      "type" => "assistant",
      "message" => %{
        "id" => "m-mcp",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "mcp-scrape",
            "name" => "mcp__claude_ai_Firecrawl__firecrawl_scrape",
            "input" => %{"url" => "https://example.com"}
          },
          %{
            "type" => "tool_use",
            "id" => "mcp-map",
            "name" => "mcp__claude_ai_Firecrawl__firecrawl_map",
            "input" => %{"url" => "https://example.com"}
          }
        ]
      },
      "tool_use_meta" => [
        %{
          "id" => "mcp-scrape",
          "display_name" => "Firecrawl scrape",
          "server_display_name" => "Firecrawl",
          "icon_url" => "https://www.google.com/s2/favicons?domain=firecrawl.dev&sz=64"
        }
      ]
    })

    claude_says(context, %{
      "type" => "user",
      "message" => %{
        "content" => [
          %{"type" => "tool_result", "tool_use_id" => "mcp-scrape", "content" => "scraped"},
          %{"type" => "tool_result", "tool_use_id" => "mcp-map", "content" => "mapped"}
        ]
      }
    })

    claude_says(context, %{"type" => "result", "subtype" => "success"})
    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "the item is titled with the tool's display name and server, with its icon", context do
    items = mcp_items(context)

    assert %{
             "type" => "dynamic_tool",
             "status" => "completed",
             "title" => "Firecrawl scrape",
             "toolSource" => %{
               "key" => "mcp:firecrawl",
               "name" => "Firecrawl",
               "kind" => "integration",
               "icon" => %{
                 "_tag" => "themed-logo",
                 "logoUrl" => "https://www.google.com/s2/favicons?domain=firecrawl.dev&sz=64"
               }
             }
           } = items["mcp-scrape"]

    context
  end

  step "the raw name like {string} is not shown", context do
    items = mcp_items(context)
    # Without Claude's own name for it, a title made from the tool's part of the name.
    assert %{"title" => "Firecrawl map"} = items["mcp-map"]
    refute Map.has_key?(items["mcp-map"], "toolSource")

    for {_id, item} <- items, do: refute(item["title"] =~ ~r/mcp__/i)
    context
  end

  defp mcp_items(context) do
    for item <- StreamState.list(World.stream(context, @thread), "turn-item"),
        item["toolName"] in [
          "mcp__claude_ai_Firecrawl__firecrawl_scrape",
          "mcp__claude_ai_Firecrawl__firecrawl_map"
        ],
        into: %{},
        do: {if(item["toolName"] =~ "scrape", do: "mcp-scrape", else: "mcp-map"), item}
  end

  # --- MCP elicitation -----------------------------------------------------------------

  # The fake's MCP tool elicits mid-turn ("mcp confirm" and friends); the tool
  # is told the answer's action and says "elicitation ACTION" before the turn ends.
  step "a Claude thread is running", context do
    context
    |> World.fake_providers()
    |> World.launch_on(@thread, "claudeAgent", "hello")
    |> Map.put(:thread, @thread)
    |> tap(&World.await_runs(&1, @thread, ["completed"]))
  end

  step "an MCP tool asks the user to confirm what it is about to do", context do
    context = World.post_message(context, @thread, "mcp confirm")
    Map.put(context, :request, World.await_request(context, @thread))
  end

  step "the user is asked to approve, decline or cancel", context do
    assert %{"kind" => "mcp-elicitation", "status" => "pending"} = context.request

    item =
      Enum.find(
        World.entities(context, @thread, "turn-item"),
        &(&1["requestId"] == context.request["id"])
      )

    assert %{"prompt" => "Delete the file?", "appName" => "demo", "options" => options} = item

    assert options ==
             [
               %{"decision" => "cancel", "label" => "Cancel"},
               %{"decision" => "decline", "label" => "Decline"},
               %{"decision" => "accept", "label" => "Approve"}
             ]

    context
  end

  step "the tool waits for the user's answer", context do
    assert [%{"status" => "completed"}, %{"status" => "running"}] =
             World.runs(context, @thread)

    refute Enum.any?(World.replies(context, @thread), &(&1 =~ "elicitation"))
    context
  end

  step "an MCP tool on Claude asked the user to confirm what it is about to do", context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "claudeAgent", "mcp confirm twice")
      |> Map.put(:thread, @thread)

    Map.put(context, :request, World.await_request(context, @thread))
  end

  step "the user approves", context do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "runtime-request.respond",
        "threadId" => World.thread_id(context, @thread),
        "requestId" => context.request["id"],
        "decision" => "accept"
      })

    context
  end

  step "the tool goes on with that request", context do
    # The tool was told accept: it asks its second question instead of ending denied.
    request = World.await_request(context, @thread)
    assert %{"kind" => "mcp-elicitation", "status" => "pending"} = request
    Map.put(context, :request2, request)
  end

  step "the next request from that tool asks the user again", context do
    assert context.request2["createdAt"] >= context.request["createdAt"]

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "runtime-request.respond",
        "threadId" => World.thread_id(context, @thread),
        "requestId" => context.request2["id"],
        "decision" => "accept"
      })

    World.await_runs(context, @thread, ["completed"])
    assert Enum.any?(World.replies(context, @thread), &(&1 == "elicitation accept"))
    context
  end

  step ~r/^an MCP tool on Claude asks the user for (?<request>.+)$/,
       %{args: [request]} = context do
    text =
      case request do
        "a sign-in at a web address" -> "mcp sign in"
        "values to fill in a form" -> "mcp form"
        "input it does not describe" -> "mcp undescribed"
      end

    context
    |> World.fake_providers()
    |> World.launch_on(@thread, "claudeAgent", text)
    |> Map.put(:thread, @thread)
  end

  step "Claude declines it without asking the user", context do
    World.await_runs(context, @thread, ["completed"])
    assert Enum.any?(World.replies(context, @thread), &(&1 == "elicitation decline"))
    assert World.entities(context, @thread, "runtime-request") == []
    context
  end

  step "an MCP tool on Claude is waiting for the user to confirm", context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "claudeAgent", "mcp confirm")
      |> Map.put(:thread, @thread)

    Map.put(context, :request, World.await_request(context, @thread))
  end

  step "the Claude session stops", context do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "threadId" => World.thread_id(context, @thread)
      })

    World.await_runs(context, @thread, ["interrupted"])
    context
  end

  step "the request is cancelled", context do
    assert [%{"status" => "cancelled"}] = World.entities(context, @thread, "runtime-request")
    context
  end

  step "answering it afterwards fails as no longer pending", context do
    assert {:error, _} =
             HalC2.Claude.ThreadRuntime.respond(
               World.thread_id(context, @thread),
               context.request["id"],
               %{"decision" => "accept"}
             )

    context
  end

  # --- Full access and Claude's own permission settings ------------------------------

  step "the project's or the managed Claude settings restrict bypassing permissions",
       context do
    {context, _home} = skills_home(context)
    path = settings_file(context, "the project's Claude settings")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, ~s({"permissions": {"disableBypassPermissionsMode": "disable"}}))
    context
  end

  step "a Claude thread in Full access wants to run a tool those settings guard", context do
    context = running_turn(context)
    claude_asks(context, "perm-guarded", "Bash", %{"command" => "rm -rf build"})
  end

  step "the user is asked for permission", context do
    # Those settings leave Auto allowed, so Full access falls back to it.
    assert flag_value(last_argv(context), "--permission-mode") == "auto"

    World.await_value(context, @thread, fn state ->
      match?([%{"status" => "pending"}], StreamState.list(state, "runtime-request"))
    end)

    context
  end

  step "the thread says Claude's settings limited Full access", context do
    assert [notice] = bypass_notices(context)
    assert notice =~ "Claude's settings turn off bypassing permissions"
    context
  end

  step "the project's Claude settings cannot be read", context do
    {context, _home} = skills_home(context)
    path = settings_file(context, "the project's Claude settings")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, ~s({"permissions": {"allow": [}))
    Map.put(context, :broken_settings, path)
  end

  step "a Claude thread in Full access runs a turn", context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "claudeAgent", "which mode")

    World.await_runs(context, @thread, ["completed"])
    Map.put(context, :thread, @thread)
  end

  step "that turn asks the user before Claude's tools run", context do
    assert flag_value(last_argv(context), "--permission-mode") == "default"
    assert World.replies(context, @thread) == ["mode default"]
    assert [notice] = bypass_notices(context)
    assert notice =~ "could not read Claude's settings"
    context
  end

  step "the next turn reads the settings again", context do
    File.write!(context.broken_settings, ~s({"permissions": {"allow": []}}))
    context = World.post_message(context, @thread, "which mode")
    World.await_runs(context, @thread, ["completed", "completed"])
    assert World.replies(context, @thread) == ["mode default", "mode bypassPermissions"]
    context
  end

  step ~r/^Claude has bypass turned off and (?<auto>Auto turned on|Auto turned off too)$/,
       %{args: [auto]} = context do
    {context, _home} = skills_home(context)
    path = settings_file(context, "the project's Claude settings")
    File.mkdir_p!(Path.dirname(path))

    settings =
      if auto == "Auto turned off too",
        do: %{"disableAutoMode" => "disable"},
        else: %{}

    settings = Map.put(settings, "permissions", %{"disableBypassPermissionsMode" => "disable"})
    File.write!(path, Jason.encode!(settings))
    context
  end

  step "a Claude thread runs in Full access", context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "claudeAgent", "which mode")

    World.await_runs(context, @thread, ["completed"])
    Map.put(context, :thread, @thread)
  end

  step ~r/^Claude runs in (?<mode>Auto|its default mode, with approvals)$/,
       %{args: [mode]} = context do
    expected = if mode == "Auto", do: "auto", else: "default"
    argv = last_argv(context)
    assert flag_value(argv, "--permission-mode") == expected
    refute Enum.any?(argv, &String.contains?(&1, "dangerously-skip-permissions"))
    assert World.replies(context, @thread) == ["mode #{expected}"]
    assert [notice] = bypass_notices(context)
    assert notice =~ "Claude's settings turn off bypassing permissions"
    assert notice =~ "Auto mode" == (mode == "Auto")
    context
  end

  defp bypass_notices(context) do
    title =
      if (context[:threads] || %{})[@thread],
        do: @thread,
        else: World.current_thread(context)

    for item <- StreamState.list(World.stream(context, title), "turn-item"),
        item["type"] == "system_notice",
        get_in(item, ["nativeItemRef", "nativeId"])
        |> to_string()
        |> String.starts_with?("bypass-"),
        do: item["message"]
  end

  # Why Claude asks in Full access, as its permission request says it.
  @full_access_causes %{
    "Claude's own safety check on a recursive delete" =>
      {"safetyCheck", "rm -rf on a path Claude could not verify always asks"},
    "an ask rule in the user's Claude permissions" =>
      {"rule", "Permission rule 'Bash(rm:*)' from user settings requires approval"},
    "a hook in the user's Claude settings" =>
      {"hook", "Hook PreToolUse:Bash asked for approval: deletes need a second look"}
  }

  step "a Claude thread in Full access", context do
    running_turn(context)
  end

  step ~r/^(?<cause>Claude's own safety check on a recursive delete|an ask rule in the user's Claude permissions|a hook in the user's Claude settings) makes Claude ask to run a command$/,
       %{args: [cause]} = context do
    {type, reason} = Map.fetch!(@full_access_causes, cause)
    [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, World.thread_id(context, @thread))

    send(
      pid,
      {:claude, :sys.get_state(pid).session,
       {:permission, "perm-why", "Bash", %{"command" => "rm -rf build"},
        %{
          "title" => "Claude wants to run rm -rf build",
          "decision_reason" => "\e[1m#{reason}\e[0m",
          "decision_reason_type" => type
        }}}
    )

    World.await_value(context, @thread, fn state ->
      Enum.any?(StreamState.list(state, "turn-item"), &(&1["type"] == "approval_request"))
    end)

    Map.put(context, :ask_reason, reason)
  end

  defp safety_check_asks(context, request_context) do
    [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, World.thread_id(context, @thread))
    {_type, reason} = @full_access_causes["Claude's own safety check on a recursive delete"]

    send(
      pid,
      {:claude, :sys.get_state(pid).session,
       {:permission, "perm-once", "Bash", %{"command" => "rm -rf build"},
        Map.merge(
          %{"decision_reason" => reason, "decision_reason_type" => "safetyCheck"},
          request_context
        )}}
    )

    item =
      World.await_value(context, @thread, fn state ->
        Enum.find(StreamState.list(state, "turn-item"), &(&1["type"] == "approval_request"))
      end)

    context |> Map.put(:ask_reason, reason) |> Map.put(:approval, item)
  end

  # The fake's safety check asks during the running turn, as the CLI does.
  step "Claude's safety check asks to run a command and forbids an always-allow rule", context do
    [%{"id" => run_id}] = World.runs(context, @thread)

    context =
      World.send_turn(context, @thread, "ask once", %{
        "dispatchMode" => %{"type" => "steer_active", "targetRunId" => run_id}
      })

    item =
      World.await_value(context, @thread, fn state ->
        Enum.find(StreamState.list(state, "turn-item"), &(&1["type"] == "approval_request"))
      end)

    Map.put(context, :approval, item)
  end

  step "the user can only decline or approve it", context do
    assert ["decline", "accept"] = Enum.map(context.approval["options"], & &1["decision"])
    context
  end

  # A client that still sends a session grant gets no rule written: the request is
  # declined.
  step "there is no way to always allow it for the session", context do
    request = World.await_request(context, @thread)

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "runtime-request.respond",
        "threadId" => World.thread_id(context, @thread),
        "requestId" => request["id"],
        "decision" => "acceptForSession"
      })

    entry =
      World.await_provider_log(
        context,
        "claude",
        &(get_in(&1, ["in", "type"]) == "control_response" and
            get_in(&1, ["in", "response", "request_id"]) == "perm-once")
      )

    answer = get_in(entry, ["in", "response", "response"])
    assert answer["behavior"] == "deny"
    refute Map.has_key?(answer, "updatedPermissions")
    context
  end

  step "a Claude thread in Full access is waiting on an approval Claude's safety check raised",
       context do
    context |> running_turn() |> safety_check_asks(%{})
  end

  step "an agent reads the thread", context do
    context = World.create_thread(context, "Reader", "shop")

    {:ok, read} =
      World.mcp_tool(context, "Reader", "hal_c2_thread_read", %{
        "threadId" => World.thread_id(context, @thread),
        "view" => "activity"
      })

    Map.put(context, :mcp_read, read)
  end

  step "the pending approval includes Claude's reason", context do
    assert %{"status" => "waiting", "reason" => reason, "text" => text} =
             Enum.find(context.mcp_read["items"], &(&1["type"] == "approval_request"))

    assert reason == context.ask_reason
    assert text =~ "rm -rf build"
    context
  end

  # --- skill calls --------------------------------------------------------------------------------

  defp skill_items(context) do
    for item <- StreamState.list(World.stream(context, @thread), "turn-item"),
        item["toolName"] == "Skill",
        do: item
  end

  step "Claude calls a skill", context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "claudeAgent", "call a skill")

    World.await_runs(context, @thread, ["completed"])
    context
  end

  step ~S(the row reads "Skill: <name>"), context do
    assert [%{"title" => "Skill: demo"}, %{"title" => "Skill: demo"}] = skill_items(context)
    context
  end

  step "expanding it shows only the arguments as plain text", context do
    assert [%{"input" => "with care"} | _] = skill_items(context)
    context
  end

  step "a call with no arguments does not expand", context do
    assert [_with_args, %{"input" => input}] = skill_items(context)
    assert input in [nil, ""]
    context
  end

  # --- what an approval reads -------------------------------------------------------------------

  step "Claude asks to run {string} and describes it as {string}",
       %{args: [command, description]} = context do
    %{instance: instance, fields: fields} = context.pending_launch

    context =
      context
      |> Map.delete(:pending_launch)
      |> World.launch_on(@thread, instance, "wait for me", fields)

    World.await_running(context, @thread)
    World.await_provider_log(context, "claude", &(get_in(&1, ["in", "type"]) == "user"))

    context
    |> claude_asks("perm-descr-1", "Bash", %{"command" => command}, %{
      "description" => description
    })
    |> Map.put(:described_as, description)
  end

  step "the approval shows the command {string} in full", %{args: [command]} = context do
    World.await_value(context, @thread, fn state ->
      Enum.any?(StreamState.list(state, "turn-item"), &(&1["type"] == "approval_request"))
    end)

    assert approval_prompt(context, "perm-descr-1") =~ command
    context
  end

  step "Claude's description is shown only for a request that carries no command", context do
    refute approval_prompt(context, "perm-descr-1") =~ context.described_as

    # A request with nothing to run shows the description instead.
    context =
      claude_asks(context, "perm-descr-2", "NotebookEdit", %{"notebook_path" => "notes.ipynb"}, %{
        "description" => context.described_as
      })

    World.await_value(context, @thread, fn state ->
      Enum.any?(
        StreamState.list(state, "turn-item"),
        &(&1["id"] == "turn-item:approval:perm-descr-2")
      )
    end)

    assert approval_prompt(context, "perm-descr-2") == context.described_as
    context
  end

  step "the approval shows Claude's reason", context do
    approval = approval_item(context)
    assert approval["prompt"] == "Claude wants to run rm -rf build"
    assert approval["reason"] == context.ask_reason

    # The session still holds the request, so the user's answer reaches Claude.
    [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, World.thread_id(context, @thread))

    assert Enum.any?(
             Map.values(:sys.get_state(pid).requests),
             &match?({:permission, "perm-why", _, _}, &1)
           )

    context
  end

  step ~r/^the user can find out why Full access still asks, explained as (?<explanation>.+)$/,
       %{args: [explanation]} = context do
    expected =
      Map.fetch!(
        %{"Claude's own safety check" => "provider_check", "the user's ask rule" => "ask_rule"},
        explanation
      )

    assert approval_item(context)["fullAccessOverride"] == expected
    context
  end

  # Only an ask rule and Claude's own safety checks are named; a hook is neither.
  step "the approval does not say which Full access check asked", context do
    refute Map.has_key?(approval_item(context), "fullAccessOverride")
    context
  end

  step "a Claude thread in Supervised mode", context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "claudeAgent", "wait for me", %{
        "runtimeMode" => "approval-required"
      })

    World.await_running(context, @thread)
    World.await_provider_log(context, "claude", &(get_in(&1, ["in", "type"]) == "user"))
    assert :sys.get_state(runtime(context)).permission_mode == "default"
    Map.put(context, :thread, @thread)
  end

  # Claude's ordinary ask outside Full access: a rule of its default mode.
  step ~r/^Claude asks to run "(?<command>[^"]+)"$/, %{args: [command]} = context do
    send(
      runtime(context),
      {:claude, :sys.get_state(runtime(context)).session,
       {:permission, "perm-plain", "Bash", %{"command" => command},
        %{
          "title" => "Claude wants to run #{command}",
          # An ask rule, which in Full access would explain why it still asked.
          "decision_reason" => "Bash(touch:*) is an ask rule",
          "decision_reason_type" => "rule"
        }}}
    )

    World.await_value(context, @thread, fn state ->
      Enum.any?(StreamState.list(state, "turn-item"), &(&1["type"] == "approval_request"))
    end)

    Map.put(context, :command, command)
  end

  step "the approval reads as an ordinary approval with no explanation of why Full access asked",
       context do
    approval = approval_item(context)
    assert approval["prompt"] == "Claude wants to run #{context.command}"
    refute Map.has_key?(approval, "fullAccessOverride")
    context
  end

  defp runtime(context) do
    [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, World.thread_id(context, @thread))
    pid
  end

  defp approval_item(context) do
    [approval] =
      for item <- StreamState.list(World.stream(context, @thread), "turn-item"),
          item["type"] == "approval_request",
          do: item

    approval
  end

  # --- rolling back a fork's first turn ---------------------------------------------------

  @source "Claude source"

  step "a Claude thread forked from another thread's second turn", context do
    context = World.fake_providers(context)
    {context, _home} = skills_home(context)
    World.put_os_env("FAKE_SESSIONS", "1")
    context = World.launch_on(context, @source, "claudeAgent", "first question")
    World.await_runs(context, @source, ["completed"])
    context = World.post_message(context, @source, "second question")
    World.await_runs(context, @source, ["completed", "completed"])
    context = World.fork(context, @source, 2, @thread)
    assert {:ok, _} = context.reply
    World.await_row(World.thread_id(context, @thread), & &1)
    Map.put(context, :thread, @thread)
  end

  step "the fork has run one turn of its own", context do
    done = length(World.runs(context, @thread))
    context = World.post_message(context, @thread, "the fork's own question")
    World.await_latest_run(context, @thread, "completed")
    assert length(World.runs(context, @thread)) == done + 1
    Map.put(context, :own_run, World.latest_run(context, @thread))
  end

  step "the user rolls that turn back and sends another message", context do
    context =
      World.rollback(context, @thread, context.own_run["ordinal"] - 1, %{"restoreFiles" => false})

    assert {:ok, _} = context.reply
    context = World.post_message(context, @thread, "where are we")

    World.await_value(context, @thread, fn state ->
      Enum.any?(StreamState.list(state, "message"), &(&1["text"] =~ "resumed at"))
    end)

    context
  end

  step "Claude still has the conversation the fork inherited", context do
    answer = Enum.find(World.replies(context, @thread), &(&1 =~ "resumed at"))
    # The fake keeps a resumed transcript whole; `resumed at` is where Claude cuts it.
    assert answer =~ "earlier [first question | second question", answer
    refute answer =~ "resumed at None", answer
    context
  end

  # --- the goal (`/goal`, Upstream #15592, #16598, #25426) --------------------------------

  # The fake's "/goal OBJECTIVE" says "Goal set", works, gets one unmet check back as
  # Stop hook feedback ("the tests still fail") and stays open; an objective "in the
  # background" starts a background subagent (agent-1, task task-agent-1) and ends the turn.
  defp goal(context) do
    World.stream(context, @thread)
    |> StreamState.list("provider-thread")
    |> Enum.find_value(& &1["goal"])
  end

  defp await_goal(context, fun) do
    World.await_value(context, @thread, fn state ->
      state |> StreamState.list("provider-thread") |> Enum.find_value(& &1["goal"]) |> fun.()
    end)
  end

  step "the user sends {string} with an objective in a Claude thread",
       %{args: ["/goal"]} = context do
    context
    |> World.fake_providers()
    |> World.launch_on(@thread, "claudeAgent", "/goal make the tests pass")
  end

  step "the goal's state and the number of checks show in the thread", context do
    await_goal(
      context,
      &(&1 == %{
          "objective" => "make the tests pass",
          "status" => "active",
          "checks" => 1,
          "lastCheck" => "the tests still fail"
        })
    )

    context
  end

  # A Stop hook of the user's ends the turn first: Claude never ran the goal's check.
  step "the goal shows complete only when Claude ends the turn normally", context do
    claude_says(context, %{
      "type" => "result",
      "subtype" => "success",
      "is_error" => false,
      "terminal_reason" => "stop_hook_prevented"
    })

    World.await_runs(context, @thread, ["completed"])
    assert %{"status" => "active", "checks" => 1} = goal(context)

    context = World.post_message(context, @thread, "keep going")
    World.await_runs(context, @thread, ["completed", "completed"])

    assert goal(context) == %{
             "objective" => "make the tests pass",
             "status" => "complete",
             "checks" => 1
           }

    context
  end

  step "a Claude thread is working on a {string} objective", %{args: ["/goal"]} = context do
    context
    |> World.fake_providers()
    |> World.launch_on(@thread, "claudeAgent", "/goal survey the repo in the background")
  end

  step "Claude has a subagent running in the background", context do
    World.await_value(context, @thread, fn state ->
      match?([%{"status" => "running"}], StreamState.list(state, "subagent"))
    end)

    context
  end

  step "the main turn ends normally", context do
    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "the goal is still shown as active", context do
    assert %{"objective" => "survey the repo in the background", "status" => "active"} =
             goal(context)

    context
  end

  # A turn of the user's ends while the subagent runs, then the subagent's end wakes Claude.
  step "it shows complete only after a later turn ends normally with no subagent running",
       context do
    context = World.post_message(context, @thread, "keep going")
    World.await_runs(context, @thread, ["completed", "completed"])
    assert %{"status" => "active"} = goal(context)

    subagent_notification(context, "completed", "lib has three modules")

    claude_says(context, %{
      "type" => "assistant",
      "message" => %{
        "id" => "m-goal-wake",
        "content" => [%{"type" => "text", "text" => "The survey is done"}]
      }
    })

    World.await_value(context, @thread, fn _state ->
      match?([_, _, %{"status" => "running"}], World.runs(context, @thread))
    end)

    claude_says(context, %{"type" => "result", "subtype" => "success", "is_error" => false})
    World.await_runs(context, @thread, ["completed", "completed", "completed"])
    await_goal(context, &match?(%{"status" => "complete"}, &1))
    context
  end

  step "the user sends {string} in a Claude thread", %{args: [command]} = context do
    context =
      context |> World.fake_providers() |> World.launch_on(@thread, "claudeAgent", "hello")

    World.await_runs(context, @thread, ["completed"])
    context = World.post_message(context, @thread, command)
    World.await_runs(context, @thread, ["completed", "failed"])
    Map.put(context, :goal_command, command)
  end

  step "the command is refused, saying Claude cannot pause or resume a goal", context do
    assert Enum.any?(
             StreamState.list(World.stream(context, @thread), "turn-item"),
             &(&1["type"] == "error" and &1["failure"]["code"] == "goal_unsupported" and
                 &1["failure"]["message"] ==
                   "Claude goals cannot be paused or resumed. Send /goal clear to remove the goal.")
           )

    # The command never reached Claude.
    refute Enum.any?(
             World.provider_log(context, "claude"),
             &(get_in(&1, ["in", "message", "content"]) == context.goal_command)
           )

    context
  end

  step "no goal named {string} is set", %{args: [_word]} = context do
    assert goal(context) == nil
    context
  end

  defp prompt_uuid(context) do
    [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, World.thread_id(context, @thread))
    :sys.get_state(pid).turn.prompt.uuid
  end

  defp claude_says(context, message) do
    [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, World.thread_id(context, @thread))
    send(pid, {:claude, :sys.get_state(pid).session, {:message, message}})
  end
end
