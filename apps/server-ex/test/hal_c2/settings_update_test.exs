defmodule HalC2.SettingsUpdateTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    Application.put_env(:hal_c2, :settings_check_ms, nil)
    on_exit(fn -> Application.delete_env(:hal_c2, :settings_check_ms) end)
    start_supervised!(HalC2.Settings)
    :ok
  end

  test "an update function that raises is refused and the settings server lives on" do
    server = Process.whereis(HalC2.Settings)
    {:ok, 1} = HalC2.Settings.update(&Map.put(&1, "a", 1))

    assert {:error, "boom"} = HalC2.Settings.update(fn _ -> raise "boom" end)

    assert Process.whereis(HalC2.Settings) == server
    assert HalC2.Settings.get() == {%{"a" => 1}, 1}
  end
end
