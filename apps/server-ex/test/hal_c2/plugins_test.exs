defmodule HalC2.PluginsTest do
  use ExUnit.Case, async: false

  alias HalC2.Plugins

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @marker "••••••"

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

  test "followers of a topic, and what it last carried, outlive a restart of the host" do
    other = follower()
    assert {:ok, nil} = Plugins.subscribe_topic(self(), "alpha", "t")
    assert {:ok, nil} = Plugins.subscribe_topic(other, "alpha", "t")
    Plugins.publish("alpha", "t", 1)
    assert_receive {:hal_c2_plugin_topic, _, "alpha", "t", 1}

    :ok = Supervisor.terminate_child(HalC2.Plugins.Supervisor, Plugins)
    {:ok, _} = Supervisor.restart_child(HalC2.Plugins.Supervisor, Plugins)

    Plugins.publish("alpha", "t", 2)
    assert_receive {:hal_c2_plugin_topic, _, "alpha", "t", 2}
    assert {:ok, 2} = Plugins.subscribe_topic(follower(), "alpha", "t")

    # The new server watches them too: one that goes away is dropped.
    assert monitors() == 3
    ref = Process.monitor(other)
    Process.exit(other, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}
    assert monitors() == 2
  end

  test "a busy plugin host counts its plugins as running, a stopped one does not" do
    refute Plugins.running?("alpha")

    :ok = :sys.suspend(Plugins)
    assert Plugins.running?("alpha", 0)
    :ok = :sys.resume(Plugins)
    refute Plugins.running?("alpha")

    :ok = Supervisor.terminate_child(HalC2.Plugins.Supervisor, Plugins)
    refute Plugins.running?("alpha")
  end

  test "the secret marker is refused for a field that is not secret" do
    package("notes", "1")
    Plugins.handle("rescan", %{})

    assert {:error, %{"_tag" => "PluginSettingsInvalid", "message" => message}} =
             save("notes", %{"count" => @marker})

    assert message =~ "(count)"
    assert stored("notes") == %{}
  end

  test "the secret marker leaves a secret that was never set unset" do
    package("notes", "1")
    Plugins.handle("rescan", %{})

    assert {:ok, _} = save("notes", %{"token" => @marker, "count" => 2})
    assert stored("notes") == %{"count" => 2}
  end

  test "a package of UI parts only keeps serving the version that loaded when an update is refused" do
    package("notes", "1")
    Plugins.handle("rescan", %{})
    assert {:ok, _} = Plugins.handle("enable", %{"id" => "notes", "acceptPermissions" => []})
    assert {:ok, %{"content" => "notes 1"}} = main_page("notes")

    File.write!(Path.join(plugins_dir(), "notes/plugin.json"), "{not json")
    Plugins.handle("rescan", %{})

    assert %{"version" => "1", "enabled" => true, "reloadError" => error} = listed("notes")
    assert error =~ "JSON"
    assert {:ok, %{"content" => "notes 1"}} = main_page("notes")
  end

  test "a crash reported by a supervisor that is gone is not charged to the plugin" do
    package("notes", "1")
    Plugins.handle("rescan", %{})
    assert {:ok, _} = Plugins.handle("enable", %{"id" => "notes", "acceptPermissions" => []})
    %{sup: old} = plugin("notes")

    # A start that was cast just before the plugin stopped, whose worker died since.
    assert {:ok, _} = Plugins.handle("disable", %{"id" => "notes"})
    late_crash("notes", old)
    assert %{sup: nil, restarts: 0, last_error: nil} = plugin("notes")

    # The next start does not take the old supervisor's worker for its own.
    assert {:ok, _} = Plugins.handle("enable", %{"id" => "notes", "acceptPermissions" => []})
    assert %{sup: new} = plugin("notes")
    refute new == old
    late_crash("notes", old)
    assert %{restarts: 0, last_error: nil} = plugin("notes")

    late_crash("notes", new)
    assert %{restarts: 1, last_error: ":boom"} = plugin("notes")
  end

  defp save(id, settings),
    do: Plugins.handle("saveSettings", %{"id" => id, "settings" => settings})

  defp stored(id), do: get_in(HalC2.Settings.settings(), ["plugins", id, "settings"]) || %{}
  defp main_page(id), do: Plugins.handle("file", %{"id" => id, "path" => "ui/main.qml"})
  defp plugin(id), do: :sys.get_state(Plugins).plugins[id]

  # The host hears of a worker of supervisor `sup`, which then dies of `:boom`; the DOWN
  # has been handled by the time this returns.
  defp late_crash(id, sup) do
    worker = spawn(fn -> receive do: (:never -> :ok) end)
    ref = Process.monitor(worker)
    GenServer.cast(Plugins, {:worker, id, sup, worker})
    :sys.get_state(Plugins)
    Process.exit(worker, :boom)
    assert_receive {:DOWN, ^ref, _, _, :boom}
    :sys.get_state(Plugins)
    :sys.get_state(Plugins)
  end

  defp listed(id), do: Plugins |> GenServer.call(:list) |> Enum.find(&(&1["id"] == id))
  defp plugins_dir, do: Path.join(HalC2.Paths.data_dir(), "plugins")

  # A package of UI parts only, with a number and a secret among its settings.
  defp package(id, version) do
    dir = Path.join(plugins_dir(), id)
    File.mkdir_p!(Path.join(dir, "ui"))
    File.write!(Path.join(dir, "ui/main.qml"), "#{id} #{version}")

    File.write!(
      Path.join(dir, "plugin.json"),
      JSON.encode!(%{
        "id" => id,
        "name" => id,
        "version" => version,
        "description" => "A package of UI parts only.",
        "apiVersion" => 1,
        "settings" => [
          %{"key" => "count", "label" => "Count", "type" => "number", "default" => 1},
          %{"key" => "token", "label" => "Token", "type" => "secret"}
        ],
        "contributes" => %{
          "pages" => [%{"id" => "main", "title" => "Main", "qml" => "ui/main.qml"}]
        }
      })
    )
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
