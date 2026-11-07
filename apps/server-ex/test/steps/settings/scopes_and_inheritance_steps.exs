defmodule HalC2.Steps.Settings.ScopesAndInheritance do
  @moduledoc """
  How an MC stores its settings document (versioned `hal-c2.readSettings` /
  `hal-c2.writeSettings`, pushed to `config` subscribers) and how a project's
  overrides resolve over it (`HalC2.Settings.for_project/1`). The scenario's MC
  is the first environment the Background names.
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @environment_default %{"instanceId" => "claudeAgent", "model" => "claude-sonnet-4-6"}

  step "the user has environments {string} and {string}", %{args: [here, _other]} = context do
    Mc.ensure(HalC2.Settings)

    context
    |> Map.put(:environment_label, here)
    |> World.put_client(World.client(context))
  end

  step "the project {string} has a checkout on each environment", %{args: [title]} = context do
    World.create_project(context, title)
  end

  # --- versioned writes --------------------------------------------------------------

  step "a client has read the settings at their current version", context do
    read(context, "default")
  end

  step "the client writes a changed settings document at that version", context do
    write(context, "default", "24-hour")
  end

  step "the MC saves the document", context do
    assert HalC2.Settings.settings()["timestampFormat"] == "24-hour"
    context
  end

  step "the MC answers with the next version", context do
    assert {:ok, %{"version" => version}} = context.reply
    assert version == context.read["default"]["version"] + 1
    assert {_, ^version} = HalC2.Settings.get()
    context
  end

  step "two clients have read the settings at the same version", context do
    context = context |> read("first") |> read("second")
    assert context.read["first"]["version"] == context.read["second"]["version"]
    context
  end

  step "the first client has saved a change", context do
    context = write(context, "first", "24-hour")
    assert {:ok, _} = context.reply
    context
  end

  step "the second client writes its change at the old version", context do
    write(context, "second", "12-hour")
  end

  step "the MC refuses the write as stale settings", context do
    assert {:error, _, detail} = context.reply
    assert inspect(detail) =~ "StaleSettings"
    context
  end

  step "the first client's change is kept", context do
    assert HalC2.Settings.settings()["timestampFormat"] == "24-hour"
    context
  end

  step "a client is subscribed to this MC's settings", context do
    World.put_client(context, "subscriber", Mc.config(World.client(context, "subscriber")))
  end

  step "another client saves a settings change", context do
    context |> read("other") |> write("other", "24-hour")
  end

  step "the subscribed client receives the new settings document", context do
    {frame, client} =
      Mc.await(
        World.client(context, "subscriber"),
        &(&1["t"] == "config.settings" and &1["settings"]["timestampFormat"] == "24-hour")
      )

    assert frame["settings"] == HalC2.Settings.settings()
    World.put_client(context, "subscriber", client)
  end

  # --- project overrides ---------------------------------------------------------------

  step "the environment's default runtime mode is full access", context do
    World.update_settings(context, %{
      "defaultRuntimeMode" => "full-access",
      "timestampFormat" => "24-hour",
      "defaultThreadEnvMode" => "local"
    })
  end

  step "the project {string} overrides the default runtime mode to approval required",
       %{args: [project]} = context do
    override(context, project, %{"defaultRuntimeMode" => "approval-required"})
  end

  step "the MC resolves the settings for {string}", %{args: [project]} = context do
    Map.put(context, :resolved, HalC2.Settings.for_project(World.project(context, project).id))
  end

  step "the default runtime mode is approval required", context do
    assert context.resolved["defaultRuntimeMode"] == "approval-required"
    context
  end

  step "settings the project does not override keep the environment's values", context do
    environment = HalC2.Settings.settings()

    assert Map.delete(context.resolved, "defaultRuntimeMode") ==
             Map.delete(environment, "defaultRuntimeMode")

    assert environment["timestampFormat"] == "24-hour"
    context
  end

  # `timestampFormat` is not a `ProjectSettingsOverrides` key.
  step "the project {string} has an override for an environment-wide setting",
       %{args: [project]} = context do
    context
    |> World.update_settings(%{"timestampFormat" => "24-hour"})
    |> override(project, %{"timestampFormat" => "12-hour"})
  end

  step "that setting keeps the environment's value", context do
    assert context.resolved["timestampFormat"] == "24-hour"
    context
  end

  step "the project {string} overrides the default model with a model from {string}",
       %{args: [project, provider]} = context do
    assert provider == "Codex"

    context
    |> World.update_settings(%{"defaultModelSelection" => @environment_default})
    |> override(project, %{
      "defaultModelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"}
    })
  end

  step "the {string} provider is disabled on this environment", %{args: [provider]} = context do
    assert provider == "Codex"
    World.update_settings(context, %{"providers" => %{"codex" => %{"enabled" => false}}})
  end

  step "the default model is the environment's default model", context do
    assert context.resolved["defaultModelSelection"] == @environment_default
    context
  end

  # --- the settings file --------------------------------------------------------------

  step "the settings file holds a project override written by a newer MC", context do
    World.update_settings(context, %{})
    id = World.project(context, "hal-c2").id

    document =
      Map.put(HalC2.Settings.settings(), "projectSettingsOverrides", %{
        id => %{"defaultAutoPull" => false, "someFutureSetting" => "kept"}
      })

    File.write!(settings_path(), JSON.encode!(document))
    Map.put(context, :project_id, id)
  end

  step "an older MC loads it and the user edits that project", context do
    mc = Mc.restart(context.mc)
    context = %{context | mc: mc, clients: %{}}
    context = read(context, "default")
    %{"settings" => settings, "version" => version} = context.read["default"]

    edited =
      put_in(settings, ["projectSettingsOverrides", context.project_id, "defaultAutoPull"], true)

    {reply, context} =
      World.call(context, "hal-c2.writeSettings", %{"settings" => edited, "version" => version})

    assert {:ok, _} = reply
    context
  end

  step "the newer override is still in the settings file", context do
    entry = saved()["projectSettingsOverrides"][context.project_id]
    assert entry == %{"defaultAutoPull" => true, "someFutureSetting" => "kept"}
    context
  end

  step "a client is connected to the MC", context do
    Mc.ensure(HalC2.Settings)
    World.put_client(context, "subscriber", Mc.config(World.client(context, "subscriber")))
  end

  step "the user changes a setting in settings.json with a text editor", context do
    edit_file(%{"timestampFormat" => "24-hour"})
    check()
    context
  end

  step "the client receives the changed settings without the MC restarting", context do
    {frame, _client} =
      Mc.await(
        World.client(context, "subscriber"),
        &(&1["t"] == "config.settings" and &1["settings"]["timestampFormat"] == "24-hour")
      )

    assert frame["settings"]["timestampFormat"] == "24-hour"
    context
  end

  step "the MC is running with its settings", context do
    context = World.update_settings(context, %{"timestampFormat" => "24-hour"})
    :ok = HalC2.Settings.watch(self())
    context
  end

  step "the user saves a settings.json that is not valid JSON", context do
    File.write!(settings_path(), "{not json")
    check()
    context
  end

  step "the MC keeps using the settings it had", context do
    assert HalC2.Settings.settings()["timestampFormat"] == "24-hour"
    context
  end

  step "connected clients are not sent broken settings", context do
    refute_received {:hal_c2_settings, _, _}
    context
  end

  step "the user edited settings.json by hand a moment ago", context do
    context = World.update_settings(context, %{"timestampFormat" => "24-hour"})
    context = read(context, "default")

    File.write!(
      settings_path(),
      JSON.encode!(Map.put(saved(), "defaultThreadEnvMode", "worktree"))
    )

    context
  end

  step "a client saves a different setting before the MC has read the edit", context do
    write(context, "default", "12-hour")
  end

  step "settings.json holds both the hand edit and the client's change", context do
    assert {:ok, _} = context.reply
    assert %{"defaultThreadEnvMode" => "worktree", "timestampFormat" => "12-hour"} = saved()
    context
  end

  step "settings.json holds a hand edit that is not valid JSON", context do
    context = World.update_settings(context, %{"timestampFormat" => "24-hour"})
    context = read(context, "default")
    File.write!(settings_path(), "{not json")
    check()
    context
  end

  step "a client saves a setting", context do
    context = if context[:read], do: context, else: read(context, "default")
    write(context, "default", "12-hour")
  end

  step "the save is refused", context do
    assert {:error, _, %{"_tag" => "ServerSettingsError"}} = context.reply
    context
  end

  step "settings.json still holds the user's text for them to fix", context do
    assert File.read!(settings_path()) == "{not json"
    context
  end

  # The MC is stopped and started again by "the MC starts".
  step "settings.json is not valid JSON", context do
    context = World.update_settings(context, %{"timestampFormat" => "24-hour"})
    File.write!(settings_path(), "{not json")
    context
  end

  step "the MC runs with the default settings", context do
    assert HalC2.Settings.settings() == %{}
    context
  end

  step "settings.json is left on disk unchanged", context do
    assert File.read!(settings_path()) == "{not json"
    context
  end

  step "later settings changes do not overwrite it until it is repaired", context do
    assert {:error, _} = HalC2.Settings.update(&Map.put(&1, "timestampFormat", "24-hour"))
    assert File.read!(settings_path()) == "{not json"
    context
  end

  step "settings.json is readable only by the user the MC runs as", context do
    assert File.stat!(settings_path()).mode |> Bitwise.band(0o777) == 0o600
    context
  end

  step "it is replaced in one step so a crash never leaves half a file", context do
    # Written beside itself and renamed over: no temporary file is left behind.
    refute File.exists?(settings_path() <> ".tmp")
    assert {:ok, %{}} = JSON.decode(File.read!(settings_path()))
    context
  end

  defp settings_path, do: Path.join(HalC2.Paths.config_dir(), "settings.json")

  defp saved do
    case File.read(settings_path()) do
      {:ok, text} -> JSON.decode!(text)
      {:error, :enoent} -> %{}
    end
  end

  defp edit_file(changes),
    do: File.write!(settings_path(), JSON.encode!(Map.merge(saved(), changes)))

  # The file check, run now and waited for.
  defp check do
    send(HalC2.Settings, :check)
    :sys.get_state(HalC2.Settings)
    :ok
  end

  defp read(context, client) do
    {{:ok, read}, context} = World.call(context, "hal-c2.readSettings", %{}, client)
    Map.update(context, :read, %{client => read}, &Map.put(&1, client, read))
  end

  defp write(context, client, format) do
    %{"settings" => settings, "version" => version} = context.read[client]
    document = Map.put(settings, "timestampFormat", format)

    {reply, context} =
      World.call(
        context,
        "hal-c2.writeSettings",
        %{"settings" => document, "version" => version},
        client
      )

    Map.put(context, :reply, reply)
  end

  defp override(context, project, values) do
    id = World.project(context, project).id
    World.update_settings(context, %{"projectSettingsOverrides" => %{id => values}})
  end
end
