defmodule HalC2.KeybindingsTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:hal_c2, :home)
    Application.put_env(:hal_c2, :home, dir)
    on_exit(fn -> Application.put_env(:hal_c2, :home, previous) end)
    # Edits are made by the settings server, in turn with a member's rules.
    start_supervised!(HalC2.Settings)
    %{path: Path.join(dir, "keybindings.json")}
  end

  test "rules are added, replaced, and removed in the user's file", %{path: path} do
    assert HalC2.Keybindings.rules() == []

    {:ok, _} = HalC2.Keybindings.upsert(%{"key" => "mod+j", "command" => "terminal.toggle"})

    {:ok, %{"rules" => rules}} =
      HalC2.Keybindings.upsert(%{
        "key" => "mod+shift+j",
        "command" => "terminal.toggle",
        "replace" => %{"key" => "mod+j", "command" => "terminal.toggle"}
      })

    assert rules == [%{"key" => "mod+shift+j", "command" => "terminal.toggle"}]
    assert JSON.decode!(File.read!(path)) == rules
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600

    {:ok, %{"rules" => []}} =
      HalC2.Keybindings.remove(%{"key" => "mod+shift+j", "command" => "terminal.toggle"})
  end

  test "a rules file that cannot be written fails the edit, and the settings server stays up",
       %{path: path} do
    {_, version} = HalC2.Settings.get()
    server = Process.whereis(HalC2.Settings)
    :ok = HalC2.Settings.watch(self())
    # The rules are written to `<path>.tmp` first; a directory there refuses them.
    File.mkdir_p!(path <> ".tmp")

    assert {:error, message} =
             HalC2.Keybindings.upsert(%{"key" => "mod+j", "command" => "terminal.toggle"})

    assert message =~ "keybindings.json.tmp"
    assert Process.whereis(HalC2.Settings) == server
    assert {_, ^version} = HalC2.Settings.get()
    assert HalC2.Keybindings.rules() == []
    refute_received {:hal_c2_keybindings, _, _}

    File.rmdir!(path <> ".tmp")
    rule = %{"key" => "mod+j", "command" => "terminal.toggle"}
    assert {:ok, %{"rules" => [^rule]}} = HalC2.Keybindings.upsert(rule)
    # The watch survived the failed edit.
    assert_received {:hal_c2_keybindings, _, [^rule]}
  end

  test "an edit whose record cannot be saved stands and is stamped, and the next one saves it",
       %{path: path} do
    rule = %{"key" => "mod+j", "command" => "terminal.toggle"}
    other = %{"key" => "mod+k", "command" => "commandPalette.toggle"}
    server = Process.whereis(HalC2.Settings)
    # The records are written to `settings-shared.json.tmp` first.
    tmp = Path.join(HalC2.Paths.config_dir(), "settings-shared.json.tmp")
    File.mkdir_p!(tmp)

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:ok, %{"rules" => [^rule]}} = HalC2.Keybindings.upsert(rule)
    end)

    assert JSON.decode!(File.read!(path)) == [rule]
    assert Process.whereis(HalC2.Settings) == server
    assert %{"keybindings" => %{"value" => [^rule]}} = HalC2.Settings.shared_records()
    refute File.exists?(Path.join(HalC2.Paths.config_dir(), "settings-shared.json"))

    File.rmdir!(tmp)
    {:ok, _} = HalC2.Keybindings.upsert(other)
    assert %{"keybindings" => %{"value" => [^rule, ^other]}} = HalC2.Settings.shared_records()

    assert %{"keybindings" => %{"value" => [^rule, ^other]}} =
             JSON.decode!(File.read!(Path.join(HalC2.Paths.config_dir(), "settings-shared.json")))
  end

  test "entries that are not rules are skipped", %{path: path} do
    File.write!(path, ~s([{"key": "mod+k", "command": "commandPalette.toggle"}, 3, {"key": 1}]))

    assert HalC2.Keybindings.rules() == [
             %{"key" => "mod+k", "command" => "commandPalette.toggle"}
           ]
  end
end
