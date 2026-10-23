defmodule HalC2.SettingsSharedTest do
  use ExUnit.Case, async: false

  alias HalC2.Settings
  alias HalC2.Settings.Shared

  @moduletag :tmp_dir

  defp record(at, by, value), do: %{"at" => at, "by" => by, "value" => value}

  describe "merge" do
    test "keeps the newer record per unit, and the same one whichever side it is on" do
      ours = %{
        "defaultRuntimeMode" => record(5, "a", "full-access"),
        "worktreeSubmodules" => record(9, "a", true)
      }

      theirs = %{
        "defaultRuntimeMode" => record(7, "b", "approval-required"),
        "worktreeSubmodules" => record(3, "b", false)
      }

      merged = Shared.merge(ours, theirs)
      assert merged["defaultRuntimeMode"]["value"] == "approval-required"
      assert merged["worktreeSubmodules"]["value"] == true
      assert merged == Shared.merge(theirs, ours)
      assert Shared.merge(merged, theirs) == merged
    end

    test "breaks a tie in time by writer, so both sides pick the same one" do
      a = %{"pullRequestMergeMethod" => record(5, "a", "squash")}
      b = %{"pullRequestMergeMethod" => record(5, "b", "rebase")}

      assert Shared.merge(a, b) == b
      assert Shared.merge(b, a) == b
    end

    test "a reset is a record like any other, so an older value does not come back" do
      reset = %{"responseStreamingMode" => %{"at" => 8, "by" => "a"}}
      older = %{"responseStreamingMode" => record(6, "b", "paragraph")}

      assert Shared.merge(reset, older) == reset
      assert Shared.apply(%{"responseStreamingMode" => "paragraph"}, reset) == %{}
    end
  end

  test "only the allowlist is shared, never a key whose secrets the MC seals" do
    for key <- Shared.sealed_keys(), do: refute(key in Shared.units())

    incoming = %{
      "defaultRuntimeMode" => record(1, "b", "full-access"),
      "providerInstances" => record(1, "b", %{"codex" => %{"binaryPath" => "/opt/codex"}}),
      "usageLimitSources" => record(1, "b", %{}),
      "plugins" => record(1, "b", %{}),
      "somethingNew" => record(1, "b", 1),
      "worktreeSubmodules" => %{"at" => -1, "by" => "b", "value" => true},
      "worktreeCleanup" => %{"at" => 1, "by" => :b},
      "sidebarAutoSettleOnMerge" => record(1, "b", {:not, :json}),
      "keybindings" => record(1, "b", [%{"key" => "mod+k", "command" => "x", "extra" => 1}])
    }

    assert Shared.sanitize(incoming) == %{"defaultRuntimeMode" => record(1, "b", "full-access")}
    assert Shared.sanitize(:garbage) == %{}
  end

  test "a local write is stamped after everything seen, and only where the value changed" do
    records = %{"defaultRuntimeMode" => record(100, "b", "full-access")}
    assert Shared.stamp(records, 50) == 101
    assert Shared.stamp(records, 500) == 500

    values = %{"defaultRuntimeMode" => "full-access", "providers" => %{}}
    assert Shared.local(records, values, Shared.document_keys(), 101, "a") == records

    assert Shared.local(records, %{}, Shared.document_keys(), 101, "a") ==
             %{"defaultRuntimeMode" => %{"at" => 101, "by" => "a"}}
  end

  describe "the settings server" do
    setup %{tmp_dir: dir} do
      Application.put_env(:hal_c2, :home, dir)
      Application.put_env(:hal_c2, :settings_check_ms, nil)
      on_exit(fn -> Application.delete_env(:hal_c2, :settings_check_ms) end)
      start_supervised!(Settings)

      %{
        path: Path.join(dir, "settings.json"),
        records: Path.join(dir, "settings-shared.json"),
        id: HalC2.Environment.id()
      }
    end

    test "stamps a change to a shared key, not to a machine's", %{records: records, id: id} do
      doc = %{
        "defaultRuntimeMode" => "full-access",
        "providers" => %{"codex" => %{"binaryPath" => "/x"}}
      }

      {:ok, 1} = Settings.put(doc, 0)

      assert %{"defaultRuntimeMode" => %{"by" => ^id, "value" => "full-access"}} =
               shared = Settings.shared_records()

      assert Map.keys(shared) == ["defaultRuntimeMode"]
      assert JSON.decode!(File.read!(records)) == shared
      assert Bitwise.band(File.stat!(records).mode, 0o777) == 0o600
    end

    test "a member's newer change is saved like a put; an older one changes nothing", %{
      path: path
    } do
      {:ok, 1} =
        Settings.put(%{"defaultRuntimeMode" => "full-access", "environmentIcon" => "laptop"}, 0)

      :ok = Settings.watch(self())
      %{"defaultRuntimeMode" => %{"at" => at}} = Settings.shared_records()

      Settings.merge_shared(%{
        "defaultRuntimeMode" => record(at + 1, "zz", "approval-required"),
        "environmentIcon" => record(at + 1, "zz", "desktop")
      })

      expected = %{"defaultRuntimeMode" => "approval-required", "environmentIcon" => "laptop"}
      assert_receive {:hal_c2_settings, _, ^expected}
      assert {^expected, 2} = Settings.get()
      assert JSON.decode!(File.read!(path)) == expected
      # A client that read version 1 has to read again.
      assert {:error, :stale} = Settings.put(%{}, 1)

      Settings.merge_shared(%{"defaultRuntimeMode" => record(at, "zz", "full-access")})
      assert {^expected, 2} = Settings.get()
      refute_received {:hal_c2_settings, _, _}
    end

    test "a reset from a member removes the key, and nothing older brings it back" do
      {:ok, 1} = Settings.put(%{"responseStreamingMode" => "paragraph"}, 0)
      %{"responseStreamingMode" => %{"at" => at}} = Settings.shared_records()

      Settings.merge_shared(%{"responseStreamingMode" => %{"at" => at + 10, "by" => "zz"}})
      Settings.merge_shared(%{"responseStreamingMode" => record(at + 5, "zz", "turn")})
      _ = :sys.get_state(Settings)

      assert {%{}, 2} = Settings.get()
    end

    test "keybindings travel as one unit", %{id: id} do
      :ok = Settings.watch(self())
      rules = [%{"key" => "mod+k", "command" => "commandPalette.toggle"}]
      {:ok, _} = HalC2.Keybindings.upsert(hd(rules))
      assert_receive {:hal_c2_keybindings, _, ^rules}
      _ = :sys.get_state(Settings)

      assert %{"keybindings" => %{"at" => at, "by" => ^id, "value" => ^rules}} =
               Settings.shared_records()

      theirs = [%{"key" => "mod+j", "command" => "terminal.toggle", "when" => "terminalFocus"}]
      Settings.merge_shared(%{"keybindings" => record(at + 1, "zz", theirs)})

      assert_receive {:hal_c2_keybindings, _, ^theirs}
      assert HalC2.Keybindings.rules() == theirs
      _ = :sys.get_state(Settings)
      assert %{"keybindings" => %{"by" => "zz"}} = Settings.shared_records()
    end

    test "an edit made while the MC was down is stamped at the file's time", %{path: path, id: id} do
      {:ok, 1} = Settings.put(%{"defaultRuntimeMode" => "full-access"}, 0)
      %{"defaultRuntimeMode" => %{"at" => at}} = Settings.shared_records()
      :ok = stop_supervised(Settings)

      # As an MC without stamps (or a person) would: the document only.
      File.write!(path, JSON.encode!(%{"defaultRuntimeMode" => "approval-required"}))
      later = div(at, 1000) + 3600
      File.touch!(path, later)
      start_supervised!(Settings)

      assert %{
               "defaultRuntimeMode" => %{
                 "at" => stamped,
                 "by" => ^id,
                 "value" => "approval-required"
               }
             } =
               Settings.shared_records()

      assert stamped == later * 1000
      # The document itself never carries a stamp.
      assert JSON.decode!(File.read!(path)) == %{"defaultRuntimeMode" => "approval-required"}
    end

    test "settings from before stamps keep every value and are stamped once", %{
      path: path,
      records: records
    } do
      :ok = stop_supervised(Settings)
      doc = %{"defaultRuntimeMode" => "full-access", "providers" => %{"codex" => %{}}}
      File.write!(path, JSON.encode!(doc))
      File.rm(records)
      start_supervised!(Settings)

      assert {^doc, 0} = Settings.get()
      shared = Settings.shared_records()
      assert Map.keys(shared) == ["defaultRuntimeMode"]

      :ok = stop_supervised(Settings)
      start_supervised!(Settings)
      assert Settings.shared_records() == shared
    end

    test "a document that cannot be read is not written over by a member", %{path: path} do
      :ok = stop_supervised(Settings)
      File.write!(path, "{not json")
      start_supervised!(Settings)

      Settings.merge_shared(%{"defaultRuntimeMode" => record(1, "zz", "full-access")})
      _ = :sys.get_state(Settings)

      assert File.read!(path) == "{not json"
      assert {%{}, 0} = Settings.get()
    end

    test "a deleted document is learned again from the members, not shared as a reset", %{
      path: path
    } do
      {:ok, 1} = Settings.put(%{"defaultRuntimeMode" => "full-access"}, 0)
      %{"defaultRuntimeMode" => %{"at" => at}} = Settings.shared_records()
      File.rm!(path)
      send(Settings, :check)
      _ = :sys.get_state(Settings)

      assert Settings.shared_records() == %{}

      Settings.merge_shared(%{"defaultRuntimeMode" => record(at - 1, "zz", "approval-required")})
      _ = :sys.get_state(Settings)
      assert {%{"defaultRuntimeMode" => "approval-required"}, _} = Settings.get()
    end

    test "sensitive provider variables never reach the shared records" do
      doc = %{
        "defaultRuntimeMode" => "full-access",
        "providerInstances" => %{
          "codex" => %{
            "driver" => "codex",
            "environment" => [
              %{"name" => "OPENAI_API_KEY", "value" => "sk-secret", "sensitive" => true}
            ]
          }
        }
      }

      {:ok, 1} = Settings.put(doc, 0)
      refute inspect(Settings.shared_records()) =~ "sk-secret"
      assert Map.keys(Settings.shared_records()) == ["defaultRuntimeMode"]
    end

    test "a settings server updated in place from before takes up the records", %{id: id} do
      {:ok, 1} = Settings.put(%{"worktreeSubmodules" => true}, 0)
      :sys.replace_state(Settings, &Map.drop(&1, [:id, :shared, :held]))

      :ok = :sys.suspend(Settings)
      :ok = :sys.change_code(Settings, Settings, nil, :hot)
      :ok = :sys.resume(Settings)

      assert %{id: ^id, held: false, shared: %{"worktreeSubmodules" => %{"value" => true}}} =
               :sys.get_state(Settings)
    end
  end
end
