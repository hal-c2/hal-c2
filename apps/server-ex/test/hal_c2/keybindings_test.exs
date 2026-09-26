defmodule HalC2.KeybindingsTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:hal_c2, :home)
    Application.put_env(:hal_c2, :home, dir)
    on_exit(fn -> Application.put_env(:hal_c2, :home, previous) end)
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

    {:ok, %{"rules" => []}} =
      HalC2.Keybindings.remove(%{"key" => "mod+shift+j", "command" => "terminal.toggle"})
  end

  test "entries that are not rules are skipped", %{path: path} do
    File.write!(path, ~s([{"key": "mod+k", "command": "commandPalette.toggle"}, 3, {"key": 1}]))

    assert HalC2.Keybindings.rules() == [
             %{"key" => "mod+k", "command" => "commandPalette.toggle"}
           ]
  end
end
