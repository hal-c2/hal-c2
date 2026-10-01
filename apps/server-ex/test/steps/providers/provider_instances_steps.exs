defmodule HalC2.Steps.Providers.ProviderInstances do
  @moduledoc """
  Steps for `features/providers/provider-instances.feature`: provider instances in
  the MC's settings, how their agents are started, and provider refreshes. Agents
  are the fakes of `HalC2.Test.AcpFixtures`; an absolute path in the feature (such as
  `/opt/grok/bin/grok`) is created under the scenario's home.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.AcpFixtures, as: Acp
  alias HalC2.Test.Mc

  @drivers %{"Grok" => "grok", "OpenCode" => "opencode"}
  # What the fake Codex and Claude at a custom binary path report as their version.
  @binary_version "7.7.7"

  # A feature's absolute path, inside the scenario's home.
  defp local(ctx, path), do: Path.join(ctx.mc.home, path)

  defp executable(ctx, "~" <> _ = path), do: Mc.Host.path(ctx, path)
  defp executable(ctx, path), do: local(ctx, path)

  defp thread_launches(ctx, name) do
    root = Enum.at(ctx.projects, 0) |> elem(1) |> Map.fetch!(:root)
    Enum.filter(Acp.launches(ctx, name), &(&1["cwd"] == root))
  end

  defp run_thread(ctx, instance) do
    ctx = Acp.launch(ctx, "on #{instance}", instance, "hello")
    Acp.await_runs(ctx.threads["on #{instance}"], 1)
    Map.put(ctx, :instance, instance)
  end

  # --- instance environment ------------------------------------------------------

  step "the user adds a Grok instance {string} with the variable {string}",
       %{args: [id, name]} = context do
    ctx = context |> Acp.ready() |> Acp.run_as(id, id)

    Acp.put_instance(id, %{
      "driver" => "grok",
      "enabled" => true,
      "environment" => [%{"name" => name, "value" => "secret-#{name}"}]
    })

    Map.put(ctx, :variable, name)
  end

  step "a thread runs on {string}", %{args: [id]} = context do
    run_thread(context, id)
  end

  step "Grok runs with that variable set", context do
    name = context.variable
    assert [launch | _] = thread_launches(context, context.instance)
    assert launch["env"][name] == "secret-#{name}"
    context
  end

  step "the instance {string} has the variable {string}", %{args: [id, name]} = context do
    ctx = context |> Acp.ready() |> Acp.run_as(id, id)

    Acp.put_instance(id, %{
      "driver" => "grok",
      "enabled" => true,
      "environment" => [%{"name" => name, "value" => "secret-#{name}"}]
    })

    ctx |> Map.put(:variable, name) |> Map.put(:instance, id)
  end

  step "the user removes that variable", context do
    id = context.instance

    Acp.write_settings(context, fn settings ->
      update_in(settings, ["providerInstances", id], &Map.put(&1, "environment", []))
    end)
  end

  step "Grok no longer runs with it", context do
    ctx = run_thread(context, context.instance)
    assert [launch | _] = thread_launches(ctx, ctx.instance)
    refute Map.has_key?(launch["env"], ctx.variable)
    ctx
  end

  # A Claude instance with `name` sealed in the MC's secrets.
  defp add_sensitive(context, name) do
    ctx =
      context
      |> Acp.ready()
      |> Acp.write_settings(fn settings ->
        Map.put_new(settings, "providerInstances", %{})
        |> put_in(["providerInstances", "claude_work"], %{
          "driver" => "claudeAgent",
          "enabled" => true,
          "environment" => [%{"name" => name, "value" => "secret-#{name}", "sensitive" => true}]
        })
      end)

    ctx |> Map.put(:variable, name) |> Map.put(:instance, "claude_work")
  end

  step "the user adds the sensitive variable {string} to a Claude instance",
       %{args: [name]} = context do
    add_sensitive(context, name)
  end

  step "the value is stored in the MC's secrets", context do
    assert HalC2.ProviderSecrets.value(context.instance, context.variable) ==
             "secret-#{context.variable}"

    context
  end

  step "clients only see that a value is set", context do
    {%{"settings" => settings}, ctx} = Mc.World.call!(context, "hal-c2.readSettings", %{})

    assert [variable] = get_in(settings, ["providerInstances", ctx.instance, "environment"])
    assert variable["name"] == ctx.variable
    assert variable["valueRedacted"] == true
    assert variable["value"] == ""
    refute inspect(settings) =~ "secret-#{ctx.variable}"
    ctx
  end

  step "the Claude instance keeps {string} as a stored secret", %{args: [name]} = context do
    ctx = add_sensitive(context, name)
    assert HalC2.ProviderSecrets.value(ctx.instance, name) == "secret-#{name}"
    ctx
  end

  step "a client saves it renamed to {string} without a new value", %{args: [name]} = context do
    id = context.instance

    context
    |> Acp.write_settings(fn settings ->
      update_in(settings, ["providerInstances", id, "environment"], fn [variable] ->
        [%{variable | "name" => name}]
      end)
    end)
    |> Map.put(:renamed, name)
  end

  step "clients see {string} with no value set", %{args: [name]} = context do
    {%{"settings" => settings}, ctx} = Mc.World.call!(context, "hal-c2.readSettings", %{})

    assert [variable] = get_in(settings, ["providerInstances", ctx.instance, "environment"])
    assert variable["name"] == name
    assert variable["value"] == ""
    refute Map.has_key?(variable, "valueRedacted")
    ctx
  end

  step "the secret of {string} is forgotten", %{args: [name]} = context do
    assert HalC2.ProviderSecrets.value(context.instance, name) == ""
    assert HalC2.ProviderSecrets.value(context.instance, context.renamed) == ""
    context
  end

  # --- text generation fallback ----------------------------------------------------

  step "Grok is picked for thread titles", context do
    ctx = context |> Acp.ready() |> Acp.run_as("grok", "grok")
    Acp.put_provider("grok", %{"enabled" => true})

    Acp.put_settings(
      &Map.put(&1, "textGenerationModelSelection", %{
        "instanceId" => "grok",
        "model" => "grok-build"
      })
    )

    {:ok, %{"title" => "grok title"}} =
      HalC2.TextGeneration.thread_title(Acp.dir(ctx), "Fix the login page")

    ctx
  end

  step "thread titles are written by the first usable provider with its default model",
       context do
    before = Acp.requests(context, "grok", "session/prompt") |> length()

    assert {:ok, %{"title" => "codex title"}} =
             HalC2.TextGeneration.thread_title(Acp.dir(context), "Fix the login page")

    assert [%{"argv" => argv} | _] =
             context
             |> Acp.dir()
             |> Path.join("text.log")
             |> File.read!()
             |> String.split("\n", trim: true)
             |> Enum.map(&JSON.decode!/1)
             |> Enum.reverse()

    assert ["exec" | _] = argv
    assert "gpt-6-luna" == Enum.at(argv, Enum.find_index(argv, &(&1 == "--model")) + 1)
    assert length(Acp.requests(context, "grok", "session/prompt")) == before
    context
  end

  # --- refreshes -----------------------------------------------------------------------

  step "each provider's account and usage are checked again", context do
    %{before: before, at: at} = context.refreshed

    for instance <- ["codex", "claudeAgent"] do
      now = HalC2.ProviderUsageLimits.get(instance)
      assert now["checkedAt"] >= at, "#{instance} was not probed again"
      assert now["checkedAt"] != before[instance]["checkedAt"]
    end

    context
  end

  step "the user refreshes provider models", context do
    ctx = context |> Acp.ready() |> Acp.run_as("grok", "grok")
    Acp.put_provider("grok", %{"enabled" => true})
    # Grok and Codex have been read once already.
    Acp.check("grok")
    HalC2.Codex.Provider.load()
    :persistent_term.erase({HalC2.Codex.Provider, :models})
    Acp.control(ctx, "grok", %{"models" => [["grok-4", "Grok 4"], ["grok-5", "Grok 5"]]})

    {_, ctx} =
      HalC2.Test.Mc.World.call!(ctx, "server.refreshProviders", %{"refreshModels" => true})

    ctx
  end

  step "Codex and every enabled ACP agent report their models again", context do
    assert [_ | _] = :persistent_term.get({HalC2.Codex.Provider, :models}, nil)
    assert length(Acp.requests(context, "grok", "session/new")) == 2

    assert ["grok-4", "grok-5"] --
             Enum.map(Acp.provider("grok")["models"], & &1["slug"]) == []

    context
  end

  step "the user refreshes the provider {string}", %{args: [id]} = context do
    ctx = context |> Acp.ready() |> Acp.run_as(id, id) |> Acp.run_as("grok", "grok")
    Mc.ensure(HalC2.ProviderUsageLimits)
    :ok = HalC2.ProviderUsageLimits.refresh([])
    Acp.put_provider("grok", %{"enabled" => true})
    Acp.put_instance(id, %{"driver" => "grok", "enabled" => true})
    Acp.check("grok")
    Acp.check(id)

    before = %{
      "codex" => HalC2.ProviderUsageLimits.get("codex"),
      "grok" => length(Acp.launches(ctx, "grok")),
      id => length(Acp.launches(ctx, id))
    }

    {_, ctx} = HalC2.Test.Mc.World.call!(ctx, "server.refreshProviders", %{"instanceId" => id})
    Map.put(ctx, :refreshed, %{before: before})
  end

  step "only {string} is checked again", %{args: [id]} = context do
    before = context.refreshed.before
    assert length(Acp.launches(context, id)) == before[id] + 1
    assert length(Acp.launches(context, "grok")) == before["grok"]
    assert HalC2.ProviderUsageLimits.get("codex") == before["codex"]
    context
  end

  # --- clients ---------------------------------------------------------------------------

  step "the user enables Grok on one client", context do
    ctx = context |> Acp.ready() |> Acp.run_as("grok", "grok")
    second = HalC2.Test.Mc.World.client(ctx, "second") |> Mc.config(7)
    ctx = HalC2.Test.Mc.World.put_client(ctx, "second", second)

    Acp.write_settings(
      ctx,
      &put_in(&1, [Access.key("providers", %{}), Access.key("grok", %{}), "enabled"], true),
      "first"
    )
  end

  step "the other client lists Grok as enabled", context do
    {frame, client} =
      Mc.await(
        HalC2.Test.Mc.World.client(context, "second"),
        fn frame ->
          frame["t"] == "config.providers" and
            Enum.any?(frame["providers"], &(&1["instanceId"] == "grok" and &1["enabled"]))
        end,
        5_000
      )

    assert %{"driver" => "grok"} = Enum.find(frame["providers"], &(&1["instanceId"] == "grok"))
    HalC2.Test.Mc.World.put_client(context, "second", client)
  end

  # --- background health checks -------------------------------------------------------

  defp tick do
    pid = Process.whereis(HalC2.ProviderUsageLimits)
    send(pid, :tick)
    # The tick is handled before this call returns.
    :sys.get_state(pid)
  end

  defp health_override(ctx, override) do
    Acp.write_settings(ctx, fn settings ->
      Map.put(
        settings,
        "backgroundActivity",
        if(override,
          do: %{
            "profile" => "custom",
            "baseProfile" => "balanced",
            "overrides" => %{"providerHealthRefreshInterval" => override}
          },
          else: %{"profile" => "balanced"}
        )
      )
    end)
  end

  step "the user sets the provider health check interval to {int}", %{args: [ms]} = context do
    ctx = Acp.ready(context)
    Mc.ensure(HalC2.ProviderUsageLimits)
    :ok = HalC2.ProviderUsageLimits.refresh([])
    health_override(ctx, ms)
  end

  step "providers are no longer checked in the background", context do
    assert HalC2.ProviderUsageLimits.interval() == :off
    before = HalC2.ProviderUsageLimits.get("codex")
    tick()
    assert HalC2.ProviderUsageLimits.get("codex") == before
    context
  end

  step "the user resets the interval", context do
    health_override(context, nil)
  end

  step "providers are checked on the default interval again", context do
    assert HalC2.ProviderUsageLimits.interval() ==
             HalC2.BackgroundPolicy.settings(%{})["providerHealthRefreshInterval"]

    before = HalC2.ProviderUsageLimits.get("codex")
    tick()
    assert HalC2.ProviderUsageLimits.get("codex")["checkedAt"] != before["checkedAt"]
    context
  end

  # --- binary paths ------------------------------------------------------------------------

  # A path under `~` is kept as written: the MC expands it against the scenario's `$HOME`.
  step ~r/^the (?<provider>Grok|OpenCode) instance has the binary path "(?<path>[^"]+)"$/,
       %{args: [provider, path]} = context do
    ctx = Acp.ready(context)
    driver = @drivers[provider]
    setting = if String.starts_with?(path, "~"), do: path, else: local(ctx, path)
    Acp.wrapper(ctx, executable(ctx, path), driver)

    Acp.put_instance(driver, %{
      "driver" => driver,
      "enabled" => true,
      "config" => %{"binaryPath" => setting}
    })

    Map.merge(ctx, %{instance: driver, binary_path: path})
  end

  # Codex and Claude: the commands the MC would find on the path are missing, and the
  # executable at `path` is a fake CLI that reports its own version and logs each start
  # the way the fake ACP agent does.
  step ~r/^the (?<provider>Codex|Claude) instance has the binary path "(?<path>[^"]+)"$/,
       %{args: [provider, path]} = context do
    ctx = Acp.ready(context)

    {driver, key, default, version, fake} =
      case provider do
        "Codex" ->
          {"codex", :codex_command, ["hal-c2-test-no-codex", "app-server"],
           "codex-cli #{@binary_version}", "fake_codex.py"}

        "Claude" ->
          {"claudeAgent", :claude_command, ["hal-c2-test-no-claude"],
           "#{@binary_version} (Claude Code)", "fake_claude.py"}
      end

    log = Path.join([ctx.mc.home, "agents", driver <> ".log"])
    binary = local(ctx, path)
    File.mkdir_p!(Path.dirname(binary))

    File.write!(binary, """
    #!/bin/sh
    if [ "$1" = "--version" ]; then echo "#{version}"; exit 0; fi
    printf '{"event":"launch","argv0":"%s","cwd":"%s"}\\n' "$0" "$(pwd -P)" >> #{log}
    exec python3 -u #{Path.expand("../../support/#{fake}", __DIR__)} "$@"
    """)

    File.chmod!(binary, 0o755)
    # Restored by `Acp.ready/1` when the scenario ends.
    Application.put_env(:hal_c2, key, default)
    Acp.put_provider(driver, %{"binaryPath" => binary})
    Map.merge(ctx, %{instance: driver, binary_path: path})
  end

  step "a thread runs on that instance", context do
    run_thread(context, context.instance)
  end

  step "the provider's version and update checks read {string}", %{args: [path]} = context do
    assert %{"version" => @binary_version, "versionAdvisory" => advisory} =
             Enum.find(HalC2.Environment.providers(), &(&1["instanceId"] == context.instance))

    assert advisory["currentVersion"] == @binary_version

    # Claude Code updates itself, so its updater is the executable the setting names.
    if context.instance == "claudeAgent",
      do: assert(advisory["updateCommand"] == local(context, path) <> " update")

    context
  end

  step "{string} is started for the thread", %{args: [path]} = context do
    assert [launch | _] = thread_launches(context, context.instance)
    assert launch["argv0"] == local(context, path)
    context
  end

  step "the executable in the user's home directory is started", context do
    assert [launch | _] = thread_launches(context, context.instance)
    assert launch["argv0"] == Mc.Host.path(context, context.binary_path)
    context
  end

  step "Grok's provider settings name the binary path {string}", %{args: [path]} = context do
    ctx = Acp.ready(context)
    Acp.wrapper(ctx, local(ctx, path), "grok_work")
    Acp.put_provider("grok", %{"binaryPath" => local(ctx, path)})
    ctx
  end

  step "the instance {string} names the binary path {string}", %{args: [id, path]} = context do
    Acp.wrapper(context, local(context, path), id)

    Acp.put_instance(id, %{
      "driver" => "grok",
      "enabled" => true,
      "config" => %{"binaryPath" => local(context, path)}
    })

    context
  end

  step "the Grok instance has an empty binary path", context do
    ctx = Acp.ready(context)
    bin = local(ctx, "bin")
    Acp.wrapper(ctx, Path.join(bin, "grok"), "grok")
    System.put_env("PATH", bin <> ":" <> System.get_env("PATH"))

    Acp.put_instance("grok", %{
      "driver" => "grok",
      "enabled" => true,
      "config" => %{"binaryPath" => ""}
    })

    Map.put(ctx, :instance, "grok")
  end

  step "the {string} executable found on the path is started", %{args: [name]} = context do
    assert [launch | _] = thread_launches(context, context.instance)
    assert launch["argv0"] == System.find_executable(name)
    assert launch["argv0"] == local(context, "bin/#{name}")
    context
  end

  # --- resetting a built-in provider ------------------------------------------------------

  # The MC stores the settings document and clients apply patches, so a reset is the
  # client writing back what `resetDefaultInstance` builds: no `providerInstances.codex`
  # and `providers.codex` at its defaults (which decode from an empty map).
  @codex_override %{"instanceId" => "codex", "model" => "gpt-5.5"}

  defp codex_override_applies?(ctx) do
    project_id = Mc.World.project(ctx).id
    HalC2.Settings.for_project(project_id)["textGenerationModelSelection"] == @codex_override
  end

  step "the user changed the settings of the built-in Codex", context do
    project_id = Mc.World.project(context).id

    ctx =
      Acp.ready(context)
      |> Acp.write_settings(fn settings ->
        settings
        |> put_in([Access.key("providers", %{}), "codex"], %{
          "enabled" => false,
          "binaryPath" => "/opt/codex/bin/codex"
        })
        |> put_in([Access.key("providerInstances", %{}), "codex"], %{
          "driver" => "codex",
          "enabled" => false
        })
        |> put_in([Access.key("projectSettingsOverrides", %{}), project_id], %{
          "textGenerationModelSelection" => @codex_override
        })
      end)

    # Codex is off, so the project's Codex model choice falls back to the environment's.
    refute codex_override_applies?(ctx)
    ctx
  end

  step "the user resets Codex to its defaults", context do
    Acp.write_settings(context, fn settings ->
      settings
      |> Map.update("providerInstances", %{}, &Map.delete(&1, "codex"))
      |> put_in(["providers", "codex"], %{})
    end)
  end

  step "Codex's settings are back to their defaults", context do
    settings = HalC2.Settings.settings()
    assert settings["providers"]["codex"] == %{}
    refute Map.has_key?(settings["providerInstances"], "codex")
    assert codex_override_applies?(context)
    context
  end
end
