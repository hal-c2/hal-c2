defmodule HalC2.PluginsTest do
  use ExUnit.Case, async: false

  alias HalC2.Plugins

  @moduletag :tmp_dir
  @moduletag capture_log: true

  setup %{tmp_dir: dir} do
    bundled = Application.fetch_env(:hal_c2, :bundled_plugins)

    on_exit(fn ->
      case bundled do
        {:ok, value} -> Application.put_env(:hal_c2, :bundled_plugins, value)
        :error -> Application.delete_env(:hal_c2, :bundled_plugins)
      end
    end)

    Application.put_env(:hal_c2, :home, dir)
    Application.put_env(:hal_c2, :settings_check_ms, nil)
    Application.put_env(:hal_c2, :bundled_plugins, [])
    start_supervised!(HalC2.Settings)
    start_supervised!(Plugins)
    :ok
  end

  test "a second client following a topic adds one monitor, not two" do
    [a, b] = for _ <- 1..2, do: follower()

    assert {:ok, nil} = Plugins.subscribe_topic(a, "alpha", "t")
    assert {:ok, nil} = Plugins.subscribe_topic(b, "alpha", "t")

    assert monitors() == 2
  end

  defp monitors do
    :sys.get_state(Plugins)
    {:monitors, monitors} = Process.info(Process.whereis(Plugins), :monitors)
    length(monitors)
  end

  # A process that follows topics, as a client socket does, until the test ends.
  defp follower do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end
end
