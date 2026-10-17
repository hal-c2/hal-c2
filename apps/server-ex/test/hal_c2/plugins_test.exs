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

  # Loading the new version made the running one the module's old code; a process still
  # in it keeps that code from being purged, so the refused version stayed the current
  # code. The last good version is loaded again, and the process in it is stopped.
  test "a refused update leaves the old version's code loaded while a process runs in it" do
    code_package("busy", "1", [{"a.ex", busy_source("1")}])
    Plugins.handle("rescan", %{})
    assert {:ok, _} = Plugins.handle("enable", %{"id" => "busy", "acceptPermissions" => []})
    assert "1" = busy(:version, [])

    me = self()
    {waiter, ref} = spawn_monitor(fn -> busy(:wait, [me]) end)
    assert_receive {:parked, ^waiter}

    code_package("busy", "2", [
      {"a.ex", busy_source("2")},
      {"b.ex", "defmodule HalC2PluginsTest.Broken do\n  def broken(, do: :x\nend\n"}
    ])

    Plugins.handle("rescan", %{})
    assert %{"version" => "1", "reloadError" => error} = listed("busy")
    assert error =~ "b.ex"
    assert "1" = busy(:version, [])

    assert_receive {:DOWN, ^ref, :process, ^waiter, :killed}

    # The next update loads over it as usual.
    code_package("busy", "3", [{"a.ex", busy_source("3")}])
    Plugins.handle("rescan", %{})
    assert %{"version" => "3", "reloadError" => nil} = listed("busy")
    assert "3" = busy(:version, [])
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

  test "a host updated in place from before crashes were charged to supervisors still charges them" do
    package("notes", "1")
    Plugins.handle("rescan", %{})
    assert {:ok, _} = Plugins.handle("enable", %{"id" => "notes", "acceptPermissions" => []})
    %{sup: sup} = plugin("notes")
    worker = spawn(fn -> receive do: (:never -> :ok) end)
    GenServer.cast(Plugins, {:worker, "notes", sup, worker})

    # What the version before kept: no `gave_up`, and workers by plugin alone.
    :sys.replace_state(Plugins, fn state ->
      %{
        state
        | plugins: Map.new(state.plugins, fn {id, p} -> {id, Map.delete(p, :gave_up)} end),
          refs:
            Map.new(state.refs, fn
              {ref, {:worker, id, _sup}} -> {ref, {:worker, id}}
              entry -> entry
            end)
      }
    end)

    # What `HalC2.Hot` does for a process whose module changed.
    :ok = :sys.suspend(Plugins)
    :ok = :sys.change_code(Plugins, Plugins, nil, :hot)
    :ok = :sys.resume(Plugins)

    assert %{gave_up: nil} = plugin("notes")
    ref = Process.monitor(worker)
    Process.exit(worker, :boom)
    assert_receive {:DOWN, ^ref, _, _, :boom}
    assert %{restarts: 1, last_error: ":boom"} = plugin("notes")

    # A worker the version before announced, its cast queued behind the plugin stopping
    # and starting again: it is not the new supervisor's.
    assert {:ok, _} = Plugins.handle("disable", %{"id" => "notes"})
    assert {:ok, _} = Plugins.handle("enable", %{"id" => "notes", "acceptPermissions" => []})
    %{restarts: restarts} = plugin("notes")
    worker = spawn(fn -> receive do: (:never -> :ok) end)
    ref = Process.monitor(worker)
    GenServer.cast(Plugins, {:worker, "notes", worker})
    :sys.get_state(Plugins)
    Process.exit(worker, :boom)
    assert_receive {:DOWN, ^ref, _, _, :boom}
    assert %{restarts: ^restarts} = plugin("notes")
  end

  test "a worker announced before an update in place, its plugin since stopped, is not charged to it" do
    package("notes", "1")
    Plugins.handle("rescan", %{})
    assert {:ok, _} = Plugins.handle("enable", %{"id" => "notes", "acceptPermissions" => []})
    assert {:ok, _} = Plugins.handle("disable", %{"id" => "notes"})
    assert %{sup: nil, gave_up: nil} = plugin("notes")

    # Its cast from the version before, queued while the plugin stopped.
    worker = spawn(fn -> receive do: (:never -> :ok) end)
    ref = Process.monitor(worker)
    GenServer.cast(Plugins, {:worker, "notes", worker})
    :sys.get_state(Plugins)
    Process.exit(worker, :boom)
    assert_receive {:DOWN, ^ref, _, _, :boom}
    :sys.get_state(Plugins)

    assert %{restarts: 0, last_error: nil} = plugin("notes")
  end

  test "a Slack event waiting behind a slow handler is dropped when the plugin is turned off" do
    {first, waiting, _previous} = queued_behind_slow_handler()

    assert {:ok, _} = Plugins.handle("disable", %{"id" => "listener"})

    # Were the slow handler still running, its finishing would let the waiting one go on.
    send(first, :go)
    await_down(waiting)
    refute_received {:heard, "listener", %{"n" => 2}, _}
  end

  test "a Slack event waiting behind a slow handler does not reach the plugin turned off and on again" do
    {first, waiting, previous} = queued_behind_slow_handler()

    assert {:ok, _} = Plugins.handle("disable", %{"id" => "listener"})
    assert {:ok, _} = enable_listener()

    send(first, :go)
    await_down(waiting)
    refute_received {:heard, "listener", %{"n" => 2}, _}

    # The new run hears what comes after, in the same series.
    Plugins.slack_event(%{"type" => "slack.status", "n" => 3}, previous)
    assert_receive {:heard, "listener", %{"n" => 3}, _}
    refute_received {:heard, "listener", %{"n" => 2}, _}
  end

  test "a Slack event waiting behind a slow handler does not reach the restarted plugin" do
    {first, waiting, previous} = queued_behind_slow_handler()

    assert {:ok, _} = Plugins.handle("restart", %{"id" => "listener"})

    send(first, :go)
    await_down(waiting)
    refute_received {:heard, "listener", %{"n" => 2}, _}

    Plugins.slack_event(%{"type" => "slack.status", "n" => 3}, previous)
    assert_receive {:heard, "listener", %{"n" => 3}, _}
    refute_received {:heard, "listener", %{"n" => 2}, _}
  end

  # A run that stops ends its deliveries together, in no set order: the handler a waiting
  # delivery follows can be ended first. The run's task supervisor is held mid-way, as it
  # is while it ends them, and the waiting delivery is traced to see what it does next.
  test "a Slack event waiting behind a slow handler ended by a stopping run is dropped" do
    {first, waiting, _previous} = queued_behind_slow_handler()

    {:deliveries, tasks, _, _} =
      List.keyfind(Supervisor.which_children(plugin("listener").sup), :deliveries, 0)

    :ok = :sys.suspend(tasks)
    :erlang.trace(waiting, true, [:send])
    Process.exit(first, :shutdown)

    assert_receive {:trace, ^waiting, :send, _, ^tasks}
    assert {:ok, _} = Plugins.handle("disable", %{"id" => "listener"})
    await_down(waiting)
    refute_received {:heard, "listener", %{"n" => 2}, _}
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

  # A package with MC sources `[{name, source}]`, replacing what the directory held.
  defp code_package(id, version, sources) do
    dir = Path.join(plugins_dir(), id)
    File.rm_rf!(dir)
    File.mkdir_p!(Path.join(dir, "mc"))

    File.write!(
      Path.join(dir, "plugin.json"),
      JSON.encode!(%{
        "id" => id,
        "name" => id,
        "version" => version,
        "description" => "A package with code.",
        "apiVersion" => 1
      })
    )

    for {name, source} <- sources, do: File.write!(Path.join([dir, "mc", name]), source)
  end

  # Calls the package's module, which only exists once the test has loaded it.
  defp busy(function, args), do: apply(Module.concat(HalC2PluginsTest, Busy), function, args)

  # A plugin whose `wait/1` parks the caller in this version's own code.
  defp busy_source(version) do
    """
    defmodule HalC2PluginsTest.Busy do
      @behaviour HalC2.Plugins.Extension

      def version, do: #{inspect(version)}
      def wait(parent) do
        send(parent, {:parked, self()})

        receive do
          :go -> :ok
        end

        :ok
      end

      def call(method, _input, _context), do: {:error, "no method " <> method}
    end
    """
  end

  # The plugin "listener", granted `slack:read`, is in its handler of event 1 (`first`,
  # which returns once sent `:go`) while event 2 waits for it in `waiting`.
  defp queued_behind_slow_handler do
    listener("listener")
    previous = Plugins.slack_event(%{"type" => "slack.status", "n" => 1, "hold" => true})
    assert_receive {:heard, "listener", %{"n" => 1}, first}
    previous = Plugins.slack_event(%{"type" => "slack.status", "n" => 2}, previous)
    %{"listener" => waiting} = previous
    refute waiting == first
    {first, waiting, previous}
  end

  defp await_down(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
  end

  defp enable_listener,
    do: Plugins.handle("enable", %{"id" => "listener", "acceptPermissions" => ["slack:read"]})

  # A package granted `slack:read` whose `handle_event` tells the test process what it
  # heard, and holds an event marked `hold` until sent `:go`.
  defp listener(id) do
    Process.register(self(), :hal_c2_plugins_test)
    dir = Path.join(plugins_dir(), id)
    File.mkdir_p!(Path.join(dir, "mc"))

    File.write!(
      Path.join(dir, "plugin.json"),
      JSON.encode!(%{
        "id" => id,
        "name" => id,
        "version" => "1",
        "description" => "Hears Slack.",
        "apiVersion" => 1,
        "permissions" => [%{"id" => "slack:read", "reason" => "The test."}]
      })
    )

    File.write!(Path.join(dir, "mc/listener.ex"), """
    defmodule HalC2PluginsTest.Listener do
      @behaviour HalC2.Plugins.Extension

      @impl true
      def call(method, _input, _context), do: {:error, "no method " <> method}

      @impl true
      def handle_event(event, context) do
        send(:hal_c2_plugins_test, {:heard, context.id, event, self()})
        if event["hold"], do: receive(do: (:go -> :ok))
        :ok
      end
    end
    """)

    Plugins.handle("rescan", %{})
    assert {:ok, %{"status" => "running"}} = enable_listener()
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
