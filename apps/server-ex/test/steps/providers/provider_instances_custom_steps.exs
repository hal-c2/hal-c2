defmodule HalC2.Steps.Providers.ProviderInstancesCustom do
  @moduledoc """
  More steps for `features/providers/provider-instances.feature`: instances the user
  adds beside a built-in provider (their name, colour, removal and binary path),
  instances of a driver this MC lacks, variable names, and what a view-only client
  may do. Claude and Codex run on `HalC2.Test.Mc.World.fake_providers/2`.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.StreamState
  alias HalC2.Test.AcpFixtures, as: Acp
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  # The green of the accent picker (`ProviderAccentColorPicker`).
  @green "#22c55e"
  @thread "Work"

  # A second Claude instance, as the "add provider" dialog saves one.
  defp custom_claude(context, id, fields \\ %{}) do
    context = World.fake_providers(context)

    Acp.put_instance(
      id,
      Map.merge(
        %{"driver" => "claudeAgent", "enabled" => true, "displayName" => "Claude Work"},
        fields
      )
    )

    Map.put(context, :instance, id)
  end

  defp listed(context, id) do
    {providers, context} = World.provider_list(context)
    {Enum.find(providers, &(&1["instanceId"] == id)), context}
  end

  defp edit_instance(context, fun) do
    id = context.instance
    Acp.write_settings(context, &update_in(&1, ["providerInstances", id], fun))
  end

  # --- name and accent colour ---------------------------------------------------------

  step "the instance {string}", %{args: [id]} = context do
    context = custom_claude(context, id)
    {entry, context} = listed(context, id)
    assert %{"driver" => "claudeAgent", "displayName" => "Claude Work"} = entry
    refute Map.has_key?(entry, "accentColor")
    context
  end

  step "the instance {string} has a green accent", %{args: [id]} = context do
    context = custom_claude(context, id, %{"accentColor" => @green})
    {entry, context} = listed(context, id)
    assert entry["accentColor"] == @green
    context
  end

  step "the user renames it to {string} and picks a green accent", %{args: [name]} = context do
    edit_instance(context, &Map.merge(&1, %{"displayName" => name, "accentColor" => @green}))
  end

  # The picker lists an instance by the name and colour of its provider entry, with
  # the models it can run.
  step "the model picker shows {string} in green", %{args: [name]} = context do
    {entry, context} = listed(context, context.instance)

    assert %{"displayName" => ^name, "accentColor" => @green, "enabled" => true} = entry
    assert [_ | _] = entry["models"]
    context
  end

  step "the user clears the accent colour", context do
    edit_instance(context, &Map.delete(&1, "accentColor"))
  end

  step "the instance uses the default colour", context do
    {entry, context} = listed(context, context.instance)
    assert %{"displayName" => "Claude Work"} = entry
    refute Map.has_key?(entry, "accentColor")
    context
  end

  # --- deleting an instance -------------------------------------------------------------

  step "the custom instance {string}", %{args: [id]} = context do
    context = custom_claude(context, id)
    context = World.run_turns(context, @thread, id, ["hello"])
    # The instance's own Claude ran the turn.
    assert [_ | _] = World.provider_log(context, "claude")

    assert [%{"status" => "completed", "providerInstanceId" => ^id}] =
             World.runs(context, @thread)

    context
  end

  step "the user deletes it", context do
    id = context.instance

    Acp.write_settings(
      context,
      &update_in(&1, ["providerInstances"], fn all -> Map.delete(all, id) end)
    )
  end

  step "it is no longer listed", context do
    {entry, context} = listed(context, context.instance)
    assert entry == nil
    refute Map.has_key?(HalC2.Settings.settings()["providerInstances"] || %{}, context.instance)
    context
  end

  step "threads that ran on it keep their history", context do
    {rows, context} =
      World.call!(context, "hal-c2.threadRows", %{"threadId" => World.thread_id(context, @thread)})

    messages =
      for ["message", _id, message] <- rows["rows"], do: {message["role"], message["text"]}

    assert {"user", "hello"} in messages
    assert Enum.any?(messages, &match?({"assistant", text} when text != "", &1))
    context
  end

  # --- a driver this MC does not have -------------------------------------------------

  @acme %{
    "driver" => "acme",
    "enabled" => true,
    "displayName" => "Acme at work",
    "config" => %{"endpoint" => "https://acme.example.com"}
  }

  # Provider plugins decide which drivers an MC has, as on a running MC.
  step "the settings contain the instance {string} for a driver this MC does not have",
       %{args: [id]} = context do
    context = World.fake_providers(context)
    Mc.ensure(HalC2.Plugins)
    Acp.put_instance(id, @acme)
    Map.put(context, :instance, id)
  end

  step "{string} is listed as unavailable with its configuration preserved",
       %{args: [id]} = context do
    entry = Enum.find(context.providers, &(&1["instanceId"] == id))

    assert %{
             "driver" => "acme",
             "availability" => "unavailable",
             "displayName" => "Acme at work",
             "enabled" => false,
             "models" => []
           } = entry

    assert entry["unavailableReason"] =~ ~s(provider plugin for "acme")

    {%{"settings" => settings}, context} = World.call!(context, "hal-c2.readSettings", %{})
    assert settings["providerInstances"][id] == @acme
    context
  end

  step "sending a message on {string} is refused with a clear error", %{args: [id]} = context do
    context =
      World.create_thread(context, "On #{id}", nil, %{
        "modelSelection" => %{"instanceId" => id, "model" => "acme-1"}
      })

    thread_id = World.thread_id(context, "On #{id}")

    {reply, context} =
      World.dispatch(context, %{
        "type" => "message.dispatch",
        "threadId" => thread_id,
        "messageId" => "m1",
        "text" => "hello",
        "attachments" => [],
        "dispatchMode" => %{"type" => "start_immediately"}
      })

    assert {:error, message, _} = reply
    assert message =~ ~s(The provider "#{id}" is not available on this MC)

    # No other provider ran the turn in its place.
    state = World.stream(context, "On #{id}")
    assert StreamState.list(state, "run") == []
    assert World.provider_log(context, "codex") == []
    context
  end

  # --- variable names --------------------------------------------------------------------

  defp save_variable(context, name) do
    {%{"settings" => settings, "version" => version}, context} =
      World.call!(context, "hal-c2.readSettings", %{})

    settings =
      put_in(settings, ["providerInstances", context.instance, "environment"], [
        %{"name" => name, "value" => "1", "sensitive" => false}
      ])

    World.call(context, "hal-c2.writeSettings", %{"settings" => settings, "version" => version})
  end

  step "the user adds the variable {string} to an instance", %{args: [name]} = context do
    context = Acp.ready(context)
    Acp.put_instance("grok_work", %{"driver" => "grok", "enabled" => true})
    context = Map.merge(context, %{instance: "grok_work", variable: name})
    {reply, context} = save_variable(context, name)
    Map.put(context, :reply, reply)
  end

  step "the variables are not saved until the name is fixed", context do
    assert {:error, message, detail} = context.reply
    assert message =~ ~s("#{context.variable}" is not a valid environment variable name)

    assert %{
             "_tag" => "ServerSettingsError",
             "providerInstanceId" => "grok_work",
             "environmentVariable" => "1BAD"
           } = detail

    instance = fn -> HalC2.Settings.settings()["providerInstances"]["grok_work"] end
    refute Map.has_key?(instance.(), "environment")
    assert HalC2.Settings.instance_env("grok_work") == %{}

    {reply, context} = save_variable(context, "GOOD_NAME")
    assert {:ok, _} = reply
    assert [%{"name" => "GOOD_NAME"}] = instance.()["environment"]
    assert HalC2.Settings.instance_env("grok_work") == %{"GOOD_NAME" => "1"}
    context
  end

  # --- a client that may only view -------------------------------------------------------

  step "the client has view-only access to the environment", context do
    context = World.fake_providers(context)

    {:ok, %{"credential" => credential}} =
      HalC2.Auth.create_pairing_link(%{"scopes" => ["orchestration:read"]})

    {:ok, access, _expires, scopes} = HalC2.Auth.exchange(credential, %{label: "Viewer"})
    viewer = Mc.connect_as(context.mc, access)
    context |> World.put_client("viewer", viewer) |> Map.put(:viewer_scopes, scopes)
  end

  step "the user opens provider settings", context do
    id = System.unique_integer([:positive])

    client =
      Mc.sub(World.client(context, "viewer"), id, %{
        "type" => "config",
        "mc" => Atom.to_string(node())
      })

    {frame, client} = Mc.await(client, &(&1["t"] == "config" and &1["id"] == id), 10_000)
    context = World.put_client(context, "viewer", client)

    {%{"settings" => settings, "version" => version}, context} =
      World.call!(context, "hal-c2.readSettings", %{}, "viewer")

    Map.merge(context, %{
      providers: frame["config"]["providers"],
      viewed: {settings, version}
    })
  end

  step "the providers are shown but every change is unavailable", context do
    assert [_ | _] = context.providers
    assert Enum.any?(context.providers, &(&1["instanceId"] == "codex"))
    {settings, version} = context.viewed

    changes = [
      {"hal-c2.writeSettings",
       %{
         "settings" =>
           put_in(settings, [Access.key("providers", %{}), "codex"], %{"enabled" => false}),
         "version" => version
       }},
      {"server.refreshProviders", %{}},
      {"server.updateProvider", %{"provider" => "codex"}},
      {"provider.auth.start", %{"instanceId" => "grok"}},
      {"provider.auth.logout", %{"instanceId" => "grok"}}
    ]

    {refusals, context} =
      Enum.map_reduce(changes, context, fn {method, payload}, context ->
        {reply, context} = World.call(context, method, payload, "viewer")
        assert {:error, _message, %{"_tag" => "EnvironmentScopeRequiredError"}} = reply
        {reply, context}
      end)

    # Nothing changed.
    assert HalC2.Settings.get() == {settings, version}
    Map.put(context, :refusals, refusals)
  end

  # The client words it; the MC gives it the two facts: what this session holds, and
  # what a change needs.
  step "the user is told this session can only view them", context do
    assert context.viewer_scopes == ["orchestration:read"]

    for {:error, message, detail} <- context.refusals do
      assert detail["requiredScope"] == "orchestration:operate"
      assert message == "orchestration:operate is required"
    end

    context
  end

  # --- a binary path with nothing at it --------------------------------------------------

  @drivers %{"Codex" => "codex", "Claude" => "claudeAgent"}

  step ~r/^the (?<provider>Codex|Claude) instance has a binary path where nothing is installed$/,
       %{args: [provider]} = context do
    context = World.fake_providers(context)
    driver = @drivers[provider]
    path = Path.join(context.mc.home, "opt/#{driver}/bin/missing")
    refute File.exists?(path)
    Acp.put_provider(driver, %{"binaryPath" => path})
    Map.merge(context, %{instance: driver, binary_path: path})
  end

  step "a client lists the providers", context do
    {providers, context} = World.provider_list(context)
    Map.put(context, :providers, providers)
  end

  step ~r/^(?<provider>Codex|Claude) is listed as not installed$/,
       %{args: [provider]} = context do
    entry = Enum.find(context.providers, &(&1["instanceId"] == @drivers[provider]))

    assert %{"installed" => false, "status" => "error", "version" => nil, "models" => []} = entry
    assert entry["message"] == "#{provider} was not found at #{context.binary_path}."
    context
  end

  step "its configured binary path is kept", context do
    {%{"settings" => settings}, context} = World.call!(context, "hal-c2.readSettings", %{})
    assert settings["providers"][context.instance]["binaryPath"] == context.binary_path
    context
  end

  # --- a second instance's own executable ---------------------------------------------

  @second %{
    "Codex" => %{
      driver: "codex",
      key: :codex_command,
      args: ["app-server"],
      fake: "fake_codex.py",
      version: "codex-cli %s",
      package: "@openai/codex"
    },
    "Claude" => %{
      driver: "claudeAgent",
      key: :claude_command,
      args: [],
      fake: "fake_claude.py",
      version: "%s (Claude Code)",
      package: "@anthropic-ai/claude-code"
    }
  }

  # A CLI that logs each start to `log`, answers `--version`, and is the fake otherwise.
  defp logging_cli(path, log, fake, version_line) do
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    #!/bin/sh
    printf '%s\\n' "$0 $*" >> #{log}
    if [ "$1" = "--version" ]; then echo "#{version_line}"; exit 0; fi
    exec python3 -u #{Path.expand("../../support/#{fake}", __DIR__)} "$@"
    """)

    File.chmod!(path, 0o755)
  end

  defp starts(log) do
    case File.read(log) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  # The built-in instance runs one executable; the second instance names another, which
  # npm installed under its own prefix (so npm is what updates it). Both log their starts.
  step ~r/^a second (?<provider>Codex|Claude) instance "(?<id>[^"]+)" with the binary path "(?<path>[^"]+)"$/,
       %{args: [provider, id, path]} = context do
    context = Acp.ready(context)

    %{driver: driver, key: key, args: args, fake: fake, version: version, package: package} =
      @second[provider]

    home = context.mc.home
    logs = %{default: Path.join(home, "default-cli.log"), own: Path.join(home, "own-cli.log")}

    default = Path.join(home, "default/bin/#{Path.basename(path)}")
    logging_cli(default, logs.default, fake, String.replace(version, "%s", "1.1.1"))
    Application.put_env(:hal_c2, key, [default | args])

    binary = Path.join(home, path)
    prefix = binary |> Path.dirname() |> Path.dirname()
    real = Path.join([prefix, "lib/node_modules", package, "bin/cli.js"])
    logging_cli(real, logs.own, fake, String.replace(version, "%s", "7.7.7"))
    File.mkdir_p!(Path.dirname(binary))
    File.ln_s!(real, binary)

    npm = Path.join(prefix, "bin/npm")
    File.write!(npm, "#!/bin/sh\necho \"$0 $*\" >> #{Path.join(home, "npm.log")}\n")
    File.chmod!(npm, 0o755)

    Acp.put_instance(id, %{
      "driver" => driver,
      "enabled" => true,
      "config" => %{"binaryPath" => binary}
    })

    # A newer release is out, so there is an update to check for.
    :persistent_term.put(
      {HalC2.ProviderUpdates, driver},
      {"9.0.0", System.monotonic_time(:millisecond)}
    )

    Map.merge(context, %{
      instance: id,
      driver: driver,
      binary: binary,
      prefix: prefix,
      package: package,
      cli_logs: logs
    })
  end

  step "the MC checks the version, update and usage of {string}", %{args: [id]} = context do
    # The MC is up: it has listed its providers and read their usage once.
    Mc.ensure(HalC2.ProviderUsageLimits)
    :ok = HalC2.ProviderUsageLimits.refresh([])
    assert %{"version" => "1.1.1"} = Acp.provider(context.driver)
    usage_before = HalC2.ProviderUsageLimits.get(context.driver)

    # Now the instance alone is checked again: nothing asked so far counts, and its
    # version is read afresh.
    for module <- [HalC2.Codex.Provider, HalC2.Claude.Provider] do
      versions = :persistent_term.get({module, :version}, %{})
      :persistent_term.put({module, :version}, Map.delete(versions, context.binary))
    end

    for {_, log} <- context.cli_logs, do: File.rm(log)
    context = Map.put(context, :usage_before, usage_before)

    entry = Acp.provider(id)
    :ok = HalC2.ProviderUsageLimits.refresh([id])
    :sys.get_state(HalC2.ProviderUsageLimits)

    {reply, context} =
      World.call(context, "server.updateProvider", %{
        "provider" => context.driver,
        "instanceId" => id
      })

    Map.merge(context, %{checked: entry, reply: reply})
  end

  step "each check runs {string}", %{args: [_path]} = context do
    %{binary: binary, instance: id} = context
    own = starts(context.cli_logs.own)

    # The version: read from the instance's executable.
    assert "#{binary} --version" in own
    assert %{"version" => "7.7.7", "versionAdvisory" => advisory} = context.checked
    assert %{"currentVersion" => "7.7.7", "status" => "behind_latest"} = advisory

    # The update: offered and run through the npm that installed that executable.
    command =
      "#{context.prefix}/bin/npm install -g --prefix #{context.prefix} #{context.package}@latest"

    assert advisory["updateCommand"] == command
    assert {:ok, %{"providers" => providers}} = context.reply
    assert starts(Path.join(context.mc.home, "npm.log")) == [command]

    assert %{"updateState" => %{"status" => "unchanged"}} =
             Enum.find(providers, &(&1["instanceId"] == id))

    # The usage: read from a session of the instance's executable.
    assert Enum.any?(
             own,
             &(&1 != "#{binary} --version" and String.starts_with?(&1, binary <> " "))
           )

    assert %{"checkedAt" => at} = HalC2.ProviderUsageLimits.get(id)
    assert is_binary(at)
    context
  end

  step "none runs the default instance's executable", context do
    assert starts(context.cli_logs.default) == []

    default = Acp.provider(context.driver)
    assert default["version"] == "1.1.1"
    refute Map.has_key?(default, "updateState")
    assert HalC2.ProviderUsageLimits.get(context.driver) == context.usage_before
    context
  end
end
