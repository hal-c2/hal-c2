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

  # The code-review settings warn when the picked agent's reviews would fail closed.
  test "an instance says whether its agent can review in a sandbox" do
    assert %{
             "codex" => %{"sandboxable" => true},
             "claude-work" => %{"sandboxable" => true}
           } = listed()
  end

  # Settings → Code review says before a review fails when a sandbox has no way to the
  # agent's model. With the CLIProxyAPI plugin's instance there it is named instead (the
  # plugin runs in the code-review feature's scenario of it).
  test "an instance says why a sandboxed review on it would fail for want of a key" do
    keys = for key <- ~w(ANTHROPIC_API_KEY OPENAI_API_KEY), do: {key, System.get_env(key)}
    for {key, _} <- keys, do: System.delete_env(key)

    on_exit(fn ->
      for {key, value} <- keys, value != nil, do: System.put_env(key, value)
    end)

    assert %{
             "claude-work" => %{"sandboxRefusal" => nil},
             "claudeAgent" => %{"sandboxRefusal" => bare}
           } =
             listed()

    assert bare =~ "needs ANTHROPIC_API_KEY for Claude"
    assert bare =~ "which the CLIProxyAPI plugin adds"

    assert listed()["codex"]["sandboxRefusal"] =~ "needs OPENAI_API_KEY for Codex"
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
    # A sandbox's refusal names the variable a key goes in, never the instance's own.
    refute JSON.encode!(
             Map.new(entries, fn {id, entry} -> {id, Map.delete(entry, "sandboxRefusal")} end)
           ) =~
             "ANTHROPIC_API_KEY"

    for {_, entry} <- entries do
      assert Map.keys(entry) --
               ~w(instanceId name driverKind enabled installed status availability auth sandboxable sandboxRefusal models) ==
               []
    end
  end
end
