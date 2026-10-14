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
    assert {:error, "** (throw) :boom"} = HalC2.Settings.update(fn _ -> throw(:boom) end)
    assert {:error, "** (exit) :boom"} = HalC2.Settings.update(fn _ -> exit(:boom) end)

    assert Process.whereis(HalC2.Settings) == server
    assert HalC2.Settings.get() == {%{"a" => 1}, 1}
  end

  test "a file rewritten in place to the same size at once is still read" do
    {:ok, 1} = HalC2.Settings.update(&Map.put(&1, "a", 1))
    path = Path.join(HalC2.Paths.config_dir(), "settings.json")
    text = File.read!(path)

    # Written over, not renamed into place: the inode, size and second stay the same.
    File.write!(path, String.replace(text, "1", "2"))
    send(HalC2.Settings, :check)
    # Returns once the check before it has run.
    :sys.get_state(HalC2.Settings)

    assert {%{"a" => 2}, 2} = HalC2.Settings.get()
  end

  test "an added instance that changes driver forgets what the old driver read" do
    instance = &put_in(&1, [Access.key("providerInstances", %{}), "work"], %{"driver" => &2})
    {:ok, _} = HalC2.Settings.update(&instance.(&1, "opencode"))
    :persistent_term.put({HalC2.Acp, "work", :models}, [%{"slug" => "old"}])
    on_exit(fn -> HalC2.Acp.forget("work") end)

    {:ok, _} = HalC2.Settings.update(&instance.(&1, "muse"))

    assert :persistent_term.get({HalC2.Acp, "work", :models}, nil) == nil
  end
end
