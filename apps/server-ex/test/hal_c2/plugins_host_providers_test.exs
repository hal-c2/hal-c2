defmodule HalC2.PluginsHostProvidersTest do
  use ExUnit.Case, async: false

  alias HalC2.Plugins.Host

  @moduletag :tmp_dir
  @moduletag capture_log: true
  @fake_codex Path.expand("../support/fake_codex.py", __DIR__)
  @fake_claude Path.expand("../support/fake_claude.py", __DIR__)

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    Application.put_env(:hal_c2, :settings_check_ms, nil)
    Application.put_env(:hal_c2, :codex_command, ["python3", @fake_codex])
    Application.put_env(:hal_c2, :claude_command, ["python3", @fake_claude])

    Application.put_env(:hal_c2, :bundled_plugins, [
      HalC2.Plugins.Bundled.Codex,
      HalC2.Plugins.Bundled.Claude
    ])

    on_exit(fn ->
      for key <- [:codex_command, :claude_command, :bundled_plugins],
          do: Application.delete_env(:hal_c2, key)
    end)

    start_supervised!(HalC2.Settings)

    {:ok, _} =
      HalC2.Settings.update(fn settings ->
        Map.put(settings, "providerInstances", %{
          "claude-work" => %{
            "driver" => "claudeAgent",
            "displayName" => "Claude at work",
            "environment" => [
              %{"name" => "ANTHROPIC_API_KEY", "value" => "sk-ant-secret", "sensitive" => true}
            ]
          }
        })
      end)

    start_supervised!(HalC2.Plugins)
    # A call behind the host's first scan: the bundled plugins are running.
    _ = :sys.get_state(HalC2.Plugins)
    :ok
  end

  defp listed do
    {:ok, providers} = Host.providers("probe")
    Map.new(providers, &{&1["instanceId"], &1})
  end

  test "a user-named instance says which driver runs it, by the name the user gave it" do
    assert %{
             "codex" => %{"driverKind" => "codex"},
             "claudeAgent" => %{"driverKind" => "claudeAgent"},
             "claude-work" => %{"driverKind" => "claudeAgent", "name" => "Claude at work"}
           } = listed()
  end

  test "each instance carries its provider status in the snapshot's vocabulary" do
    for {_, entry} <- listed() do
      assert is_boolean(entry["enabled"])
      assert is_boolean(entry["installed"])
      assert entry["status"] in ~w(ready warning error disabled)
      assert entry["availability"] in ~w(available unavailable)
      assert entry["auth"]["status"] in ~w(authenticated unauthenticated unknown)
      assert Map.keys(entry["auth"]) == ["status"]
    end

    assert %{"enabled" => true, "installed" => true, "availability" => "available"} =
             listed()["claude-work"]
  end

  test "an instance's environment and settings are not shown" do
    entries = listed()
    encoded = JSON.encode!(entries)

    refute encoded =~ "sk-ant-secret"
    refute encoded =~ "ANTHROPIC_API_KEY"

    for {_, entry} <- entries do
      assert Map.keys(entry) --
               ~w(instanceId name driverKind enabled installed status availability auth models) ==
               []
    end
  end
end
