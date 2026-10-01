defmodule HalC2.SettingsTest do
  use ExUnit.Case, async: false

  alias HalC2.Settings

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    start_supervised!(Settings)
    %{path: Path.join(dir, "settings.json")}
  end

  test "writes need the version they read; the document survives a restart", %{path: path} do
    assert {%{}, 0} = Settings.get()
    :ok = Settings.watch(self())

    doc = %{"enableAssistantStreaming" => false}
    assert {:ok, 1} = Settings.put(doc, 0)
    assert_receive {:hal_c2_settings, _, ^doc}

    # Another client's write from the same starting point is refused.
    assert {:error, :stale} = Settings.put(%{"other" => true}, 0)
    assert {^doc, 1} = Settings.get()

    assert %{mode: mode} = File.stat!(path)
    assert Bitwise.band(mode, 0o777) == 0o600

    :ok = stop_supervised(Settings)
    start_supervised!(Settings)
    assert {^doc, 0} = Settings.get()
  end

  test "settings stay readable while the settings server cannot answer" do
    doc = %{"enableAssistantStreaming" => false}
    assert {:ok, 1} = Settings.put(doc, 0)

    :ok = :sys.suspend(Settings)
    assert {^doc, 1} = Settings.get()
    :ok = :sys.resume(Settings)
  end

  test "the usage-limit sources refresh a write asks for reads the written sources" do
    test = self()

    # Stands in for `HalC2.UsageLimitSources`: reads the settings as the refresh
    # arrives, as the real one does when it handles it.
    start_supervised!(
      {Task,
       fn ->
         Process.register(self(), HalC2.UsageLimitSources)
         send(test, :registered)

         receive do
           {:"$gen_cast", :refresh} -> send(test, {:read, Settings.settings()})
         end
       end}
    )

    assert_receive :registered
    sources = %{"hub" => %{"kind" => "cliproxy", "url" => "http://hub"}}
    assert {:ok, 1} = Settings.put(%{"usageLimitSources" => sources}, 0)
    assert_receive {:read, %{"usageLimitSources" => ^sources}}
  end

  test "a project's overrides apply over the environment's, except models on disabled providers" do
    settings = %{
      "enableAgentBrowserAccess" => true,
      "worktreeSubmodules" => "recursive",
      "textGenerationModelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
      "providerInstances" => %{"claudeAgent" => %{"enabled" => false}},
      "projectSettingsOverrides" => %{
        "p1" => %{
          "enableAgentBrowserAccess" => false,
          "worktreeSubmodules" => "none",
          "textGenerationModelSelection" => %{"instanceId" => "claudeAgent", "model" => "haiku"},
          "notScoped" => 1
        }
      }
    }

    resolved = HalC2.Settings.resolve(settings, "p1")
    assert resolved["enableAgentBrowserAccess"] == false
    assert resolved["worktreeSubmodules"] == "none"
    assert resolved["textGenerationModelSelection"]["instanceId"] == "codex"
    refute Map.has_key?(resolved, "notScoped")
    assert HalC2.Settings.resolve(settings, "p2") == settings
    assert HalC2.Settings.resolve(settings, nil) == settings
  end

  test "an instance's driver setting is its own, else its driver's, and blank is unset" do
    assert {:ok, 1} =
             Settings.put(
               %{
                 "providers" => %{"codex" => %{"launchArgs" => "--strict-config"}},
                 "providerInstances" => %{
                   "codex_work" => %{"driver" => "codex", "config" => %{"launchArgs" => "-c a=1"}},
                   "codex_home" => %{"driver" => "codex", "config" => %{"launchArgs" => "  "}}
                 }
               },
               0
             )

    assert Settings.instance_setting("codex_work", "launchArgs") == "-c a=1"
    assert Settings.instance_setting("codex_home", "launchArgs") == "--strict-config"
    assert Settings.instance_setting("codex", "launchArgs") == "--strict-config"
    assert Settings.instance_setting("claudeAgent", "launchArgs") == nil
    assert Settings.instance_setting(nil, "launchArgs") == nil
  end

  test "an instance's binary path replaces the executable of its command" do
    assert {:ok, 1} =
             Settings.put(
               %{
                 "providers" => %{"codex" => %{"binaryPath" => " /opt/codex/bin/codex "}},
                 "providerInstances" => %{
                   "codex_work" => %{
                     "driver" => "codex",
                     "config" => %{"binaryPath" => "~/bin/codex"}
                   }
                 }
               },
               0
             )

    assert Settings.instance_command("codex", ["codex", "app-server"]) ==
             ["/opt/codex/bin/codex", "app-server"]

    assert Settings.instance_command("codex_work", ["codex", "app-server"]) ==
             [Path.join(HalC2.Paths.user_home(), "bin/codex"), "app-server"]

    assert Settings.instance_command("claudeAgent", ["claude"]) == ["claude"]
  end

  describe "sensitive provider variables" do
    defp instance(variables),
      do: %{
        "providerInstances" => %{
          "claudeAgent_work" => %{"driver" => "claudeAgent", "environment" => variables}
        }
      }

    defp variables,
      do: Settings.settings()["providerInstances"]["claudeAgent_work"]["environment"]

    test "are sealed on write, kept by a redacted write-back and read for the agent", %{
      path: path
    } do
      token = %{"name" => "ANTHROPIC_AUTH_TOKEN", "value" => "sk-1", "sensitive" => true}
      plain = %{"name" => "BASE", "value" => "https://x", "sensitive" => false}
      assert {:ok, 1} = Settings.put(instance([token, plain]), 0)

      assert [%{"name" => "ANTHROPIC_AUTH_TOKEN", "value" => "", "valueRedacted" => true}, ^plain] =
               variables()

      refute File.read!(path) =~ "sk-1"

      assert Settings.instance_env("claudeAgent_work") == %{
               "ANTHROPIC_AUTH_TOKEN" => "sk-1",
               "BASE" => "https://x"
             }

      # A client sends back what it read: the stored value stays.
      assert {:ok, 2} = Settings.put(Settings.settings(), 1)
      assert Settings.instance_env("claudeAgent_work")["ANTHROPIC_AUTH_TOKEN"] == "sk-1"

      # A new value replaces it.
      assert {:ok, 3} = Settings.put(instance([%{token | "value" => "sk-2"}]), 2)
      assert Settings.instance_env("claudeAgent_work") == %{"ANTHROPIC_AUTH_TOKEN" => "sk-2"}
    end

    test "a removed or plain variable forgets its secret", %{tmp_dir: dir} do
      token = %{"name" => "TOKEN", "value" => "sk-1", "sensitive" => true}
      assert {:ok, 1} = Settings.put(instance([token]), 0)
      assert [_] = Path.wildcard(Path.join(dir, "**/secrets/provider-env-*.bin"))

      assert {:ok, 2} = Settings.put(instance([]), 1)
      assert [] = Path.wildcard(Path.join(dir, "**/secrets/provider-env-*.bin"))
      assert Settings.instance_env("claudeAgent_work") == %{}
    end

    test "a redacted variable with nothing stored under its name is saved as unset", %{
      tmp_dir: dir
    } do
      token = %{"name" => "API_KEY", "value" => "sk-1", "sensitive" => true}
      assert {:ok, 1} = Settings.put(instance([token]), 0)

      # A client renamed the stored row without a new value.
      renamed = %{
        "name" => "OPENAI_KEY",
        "value" => "",
        "sensitive" => true,
        "valueRedacted" => true
      }

      assert {:ok, 2} = Settings.put(instance([renamed]), 1)

      assert [%{"name" => "OPENAI_KEY", "value" => "", "sensitive" => true} = variable] =
               variables()

      refute Map.has_key?(variable, "valueRedacted")
      assert [] = Path.wildcard(Path.join(dir, "**/secrets/provider-env-*.bin"))
      assert Settings.instance_env("claudeAgent_work") == %{"OPENAI_KEY" => ""}
    end

    test "a plain-text secret already on disk is sealed at start", %{path: path} do
      :ok = stop_supervised(Settings)
      token = %{"name" => "TOKEN", "value" => "sk-1", "sensitive" => true}
      File.write!(path, JSON.encode!(instance([token])))
      start_supervised!(Settings)

      assert [%{"valueRedacted" => true, "value" => ""}] = variables()
      refute File.read!(path) =~ "sk-1"
      assert Settings.instance_env("claudeAgent_work") == %{"TOKEN" => "sk-1"}
    end
  end
end
