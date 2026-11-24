defmodule HalC2.PluginsTest do
  use ExUnit.Case, async: false

  alias HalC2.Plugins
  alias HalC2.Plugins.Host

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
    running("alpha")
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

    # The new server watches them too (and the plugin it started): one that goes away
    # is dropped.
    assert monitors() == 3 + 1
    ref = Process.monitor(other)
    Process.exit(other, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}
    assert monitors() == 2 + 1
  end

  test "what a plugin published is forgotten once it is turned off, and it publishes nothing then" do
    package("notes", "1")
    Plugins.handle("rescan", %{})
    assert {:ok, _} = Plugins.handle("enable", %{"id" => "notes", "acceptPermissions" => []})
    Plugins.publish("notes", "t", 1)
    assert {:ok, 1} = Plugins.subscribe_topic(self(), "notes", "t")

    assert {:ok, _} = Plugins.handle("disable", %{"id" => "notes"})
    assert {:ok, nil} = Plugins.subscribe_topic(follower(), "notes", "t")

    # As it stopped: not said to those following, nor kept.
    Plugins.publish("notes", "t", 2)
    assert {:ok, nil} = Plugins.subscribe_topic(follower(), "notes", "t")
    refute_received {:hal_c2_plugin_topic, _, "notes", "t", _}
  end

  # Found by the plugin host's property: the model forgot nothing while an update held it.
  test "what a plugin published is forgotten once an update holds it for permissions" do
    running("notes")
    Plugins.publish("notes", "t", 1)
    assert {:ok, 1} = Plugins.subscribe_topic(self(), "notes", "t")

    # The same version, asking for a permission it was not granted: held, not running.
    package("notes", "1", ["slack:read"])
    Plugins.handle("rescan", %{})
    assert {:ok, nil} = Plugins.subscribe_topic(follower(), "notes", "t")

    # Accepted, it runs again with nothing published.
    assert {:ok, _} =
             Plugins.handle("enable", %{"id" => "notes", "acceptPermissions" => ["slack:read"]})

    assert {:ok, nil} = Plugins.subscribe_topic(follower(), "notes", "t")
  end

  test "a plugin that was removed publishes nothing, and what it published is forgotten" do
    running("notes")
    Plugins.publish("notes", "t", 1)
    assert {:ok, 1} = Plugins.subscribe_topic(self(), "notes", "t")

    File.rm_rf!(Path.join(plugins_dir(), "notes"))
    Plugins.handle("rescan", %{})
    assert {:ok, nil} = Plugins.subscribe_topic(follower(), "notes", "t")

    # As it was removed: not said to those following, nor kept.
    Plugins.publish("notes", "t", 2)
    assert {:ok, nil} = Plugins.subscribe_topic(follower(), "notes", "t")
    refute_received {:hal_c2_plugin_topic, _, "notes", "t", _}
  end

  test "what a plugin removed while the host was down published is forgotten as it starts" do
    running("notes")
    Plugins.publish("notes", "t", 1)
    assert {:ok, 1} = Plugins.subscribe_topic(self(), "notes", "t")

    :ok = Supervisor.terminate_child(HalC2.Plugins.Supervisor, Plugins)
    File.rm_rf!(Path.join(plugins_dir(), "notes"))
    {:ok, _} = Supervisor.restart_child(HalC2.Plugins.Supervisor, Plugins)

    assert {:ok, nil} = Plugins.subscribe_topic(follower(), "notes", "t")
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

  test "the instances of a plugin that is gone are released once settings.json takes the save" do
    Application.put_env(:hal_c2, :plugin_release_retry_ms, 10)
    on_exit(fn -> Application.delete_env(:hal_c2, :plugin_release_retry_ms) end)
    stop_supervised!(Plugins)
    id = "plugin_gone_work"

    {:ok, _} =
      HalC2.Settings.update(fn _ ->
        %{
          "providerInstances" => %{id => %{"driver" => "codex"}},
          "plugins" => %{"gone" => %{"providerInstances" => [id]}}
        }
      end)

    # The file check is off: only the host trying again notices the file is fixed.
    File.write!(settings_file(), "{ not json")
    start_supervised!(Plugins)
    _ = :sys.get_state(Plugins)
    :ok = HalC2.Settings.watch(self())
    File.rm!(settings_file())

    assert_receive {:hal_c2_settings, _, settings}, 5_000
    assert settings["providerInstances"] == %{}

    assert settings["plugins"]["gone"] == %{
             "providerInstances" => [],
             "releasedInstances" => [id]
           }
  end

  test "a host updated in place from before instances were released retries a refused release" do
    # The first try's retry is not what the test waits on.
    Application.put_env(:hal_c2, :plugin_release_retry_ms, 60_000)
    on_exit(fn -> Application.delete_env(:hal_c2, :plugin_release_retry_ms) end)
    stop_supervised!(Plugins)
    id = "plugin_gone_work"

    {:ok, _} =
      HalC2.Settings.update(fn _ ->
        %{
          "providerInstances" => %{id => %{"driver" => "codex"}},
          "plugins" => %{"gone" => %{"providerInstances" => [id]}}
        }
      end)

    File.write!(settings_file(), "{ not json")
    start_supervised!(Plugins)
    host = Process.whereis(Plugins)

    # What the version before kept: no retry of a release, as it released nothing.
    :ok = :sys.suspend(Plugins)
    _ = :sys.replace_state(Plugins, &Map.delete(&1, :release_retry))
    :ok = :sys.change_code(Plugins, Plugins, nil, :hot)
    :ok = :sys.resume(Plugins)

    Application.put_env(:hal_c2, :plugin_release_retry_ms, 10)
    :ok = HalC2.Settings.watch(self())
    send(Plugins, :release_instances)
    _ = :sys.get_state(Plugins)
    File.rm!(settings_file())

    assert_receive {:hal_c2_settings, _, settings}, 5_000
    assert settings["providerInstances"] == %{}
    assert settings["plugins"]["gone"]["releasedInstances"] == [id]
    assert Process.whereis(Plugins) == host
  end

  test "a toggle or save that settings.json refuses is answered with why, and the host stays" do
    package("notes", "1")
    Plugins.handle("rescan", %{})
    host = Process.whereis(Plugins)
    File.write!(settings_file(), "{ not json")

    for request <- [
          fn -> Plugins.handle("enable", %{"id" => "notes"}) end,
          fn -> Plugins.handle("disable", %{"id" => "notes"}) end,
          fn -> save("notes", %{"count" => 3, "token" => "s3cret"}) end
        ] do
      assert {:error, %{"_tag" => "ServerSettingsError", "message" => message}} = request.()
      assert message =~ "Could not read"
    end

    assert Process.whereis(Plugins) == host
    refute listed("notes")["enabled"]
    assert stored("notes") == %{}
    # A secret is kept only with a document that says it is set.
    assert File.ls(Path.join(HalC2.Paths.data_dir(), "secrets")) in [{:ok, []}, {:error, :enoent}]

    # Removed, the file is the MC's document again, and saves go through.
    File.rm!(settings_file())
    assert {:ok, %{"enabled" => true}} = Plugins.handle("enable", %{"id" => "notes"})
  end

  @operator ~w(orchestration:read orchestration:operate)

  test "a save without the shell's scope cannot change a setting the manifest marks exec" do
    exec_package("runner")
    assert {:ok, _} = save("runner", %{"program" => "/opt/runner", "key" => "k1"})

    for change <- [
          %{"program" => "/elsewhere"},
          %{"program" => nil},
          %{"key" => "k2"},
          %{"key" => nil},
          %{"count" => 2, "program" => "/elsewhere"}
        ] do
      assert {:error,
              %{
                "_tag" => "EnvironmentScopeRequiredError",
                "requiredScope" => "terminal:operate",
                "message" => message
              }} = save("runner", change, @operator),
             inspect(change)

      assert message =~ "terminal:operate"
    end

    assert stored("runner") == %{"program" => "/opt/runner", "key" => @marker}

    # What leaves every marked value as the plugin uses it is an operate save: the same
    # program, the secret's marker, and plain settings.
    assert {:ok, _} =
             save(
               "runner",
               %{"program" => "/opt/runner", "key" => @marker, "count" => 3},
               @operator
             )

    assert stored("runner") == %{"program" => "/opt/runner", "key" => @marker, "count" => 3}

    # A saved null is the default; one already at it changes nothing.
    exec_package("defaults")
    assert {:ok, _} = save("defaults", %{"program" => nil, "key" => nil}, @operator)

    assert {:ok, _} =
             save("runner", %{"program" => "/elsewhere"}, @operator ++ ["terminal:operate"])

    assert stored("runner")["program"] == "/elsewhere"
  end

  # The shape the release before this one sent, which an upgrade can find in the mailbox.
  test "a save queued before an upgrade is answered as one without the shell's scope" do
    exec_package("runner")
    assert {:ok, _} = save("runner", %{"program" => "/opt/runner"})

    assert {:error, %{"_tag" => "EnvironmentScopeRequiredError"}} =
             GenServer.call(Plugins, {:save_settings, "runner", %{"program" => "/elsewhere"}})

    assert {:ok, _} = GenServer.call(Plugins, {:save_settings, "runner", %{"count" => 4}})
    assert stored("runner") == %{"program" => "/opt/runner", "count" => 4}
  end

  test "the settings list says which settings are marked exec" do
    exec_package("runner")

    assert [
             %{"key" => "program", "exec" => true},
             %{"key" => "key", "exec" => true},
             %{"key" => "count"} = count
           ] = listed("runner")["settingsSchema"]

    refute Map.has_key?(count, "exec")
  end

  test "a call the manifest marks exec needs the shell's scope" do
    exec_package("runner")
    Plugins.handle("rescan", %{})
    assert {:ok, _} = Plugins.handle("enable", %{"id" => "runner", "acceptPermissions" => []})

    assert {:error,
            %{"_tag" => "EnvironmentScopeRequiredError", "requiredScope" => "terminal:operate"}} =
             call("runner", "swap", @operator)

    assert {:ok, "status"} = call("runner", "status", @operator)
    assert {:ok, "swap"} = call("runner", "swap", @operator ++ ["terminal:operate"])
    assert {:ok, "swap"} = call("runner", "swap", :all)
  end

  test "a client's settings write cannot change whether a plugin is on, what it was granted or its settings" do
    package("notes", "1", ["slack:read"])
    Plugins.handle("rescan", %{})

    assert {:ok, _} =
             Plugins.handle("enable", %{"id" => "notes", "acceptPermissions" => ["slack:read"]})

    assert {:ok, _} = save("notes", %{"count" => 2})
    held = HalC2.Settings.settings()["plugins"]

    # A change is refused, and says where plugins change instead.
    for edit <- [
          &put_in(&1, ["plugins", "notes", "enabled"], false),
          &put_in(&1, ["plugins", "notes", "granted"], ["slack:read", "slack:write"]),
          &put_in(&1, ["plugins", "notes", "settings", "count"], 9),
          &put_in(&1, ["plugins", "other"], %{"enabled" => true, "granted" => ["slack:write"]}),
          &Map.put(&1, "plugins", %{})
        ] do
      {:ok, %{"settings" => settings, "version" => version}} =
        HalC2.Rpc.handle("hal-c2.readSettings", %{})

      assert {:error, %{"_tag" => "ServerSettingsError", "message" => message}} =
               HalC2.Rpc.handle("hal-c2.writeSettings", %{
                 "settings" => edit.(Map.put(settings, "enableAssistantStreaming", true)),
                 "version" => version
               })

      assert message =~ "plugins.enable"
      assert HalC2.Settings.settings()["plugins"] == held
      refute HalC2.Settings.settings()["enableAssistantStreaming"]
    end

    # A document without the key keeps the MC's copy.
    {:ok, %{"settings" => settings, "version" => version}} =
      HalC2.Rpc.handle("hal-c2.readSettings", %{})

    assert {:ok, _} =
             HalC2.Rpc.handle("hal-c2.writeSettings", %{
               "settings" => Map.delete(settings, "plugins"),
               "version" => version
             })

    assert HalC2.Settings.settings()["plugins"] == held

    # The rest of the document is the client's.
    {:ok, %{"settings" => settings, "version" => version}} =
      HalC2.Rpc.handle("hal-c2.readSettings", %{})

    assert {:ok, _} =
             HalC2.Rpc.handle("hal-c2.writeSettings", %{
               "settings" => Map.put(settings, "enableAssistantStreaming", true),
               "version" => version
             })

    assert HalC2.Settings.settings()["enableAssistantStreaming"] == true

    # Turning it off goes through the host.
    assert {:ok, %{"enabled" => false}} = Plugins.handle("disable", %{"id" => "notes"})
    assert HalC2.Settings.settings()["plugins"]["notes"]["enabled"] == false
  end

  test "a plugin that takes settings live keeps its process, and work in it, through a save" do
    pid = enable_worker("live", :live)

    assert {:ok, _} = save("live", %{"token" => "s3cret"})

    # As `start_link/1` takes them: the defaults filled in and the secret revealed.
    assert_receive {:changed, ^pid, %{"count" => 1, "token" => "s3cret"}, %{"count" => 1}}
    assert GenServer.call(pid, :settings) == %{"count" => 1, "token" => "s3cret"}
    assert Process.alive?(pid)
    refute_received {:started, _, _}
  end

  test "a plugin without live settings is restarted with the ones saved" do
    old = enable_worker("restarting", :restart)
    ref = Process.monitor(old)

    assert {:ok, _} = save("restarting", %{"count" => 5})

    assert_receive {:DOWN, ^ref, _, _, _}
    assert_receive {:started, new, %{"count" => 5}}
    assert GenServer.call(new, :settings) == %{"count" => 5}
  end

  test "a plugin that refuses settings live is restarted with them" do
    old = enable_worker("refusing", :refuse)
    ref = Process.monitor(old)

    assert {:ok, _} = save("refusing", %{"count" => 5})

    assert_receive {:changed, ^old, %{"count" => 5}, _}
    assert_receive {:DOWN, ^ref, _, _, _}
    assert_receive {:started, _new, %{"count" => 5}}
  end

  test "a save the plugin refuses leaves the running plugin as it was" do
    pid = enable_worker("live", :live)
    assert {:ok, _} = save("live", %{"count" => 5})
    assert_receive {:changed, ^pid, _, _}

    assert {:error, %{"_tag" => "PluginSettingsInvalid", "message" => "count: too many"}} =
             save("live", %{"count" => 500})

    assert stored("live") == %{"count" => 5}
    assert GenServer.call(pid, :settings) == %{"count" => 5}
    refute_received {:changed, _, _, _}
    refute_received {:started, _, _}
  end

  test "a plugin restarted after a crash runs with the settings saved last" do
    pid = enable_worker("live", :live)
    assert {:ok, _} = save("live", %{"count" => 7})

    Process.exit(pid, :kill)

    assert_receive {:started, new, %{"count" => 7}}, 1_000
    refute new == pid
  end

  test "a plugin without a process of its own keeps running through a save" do
    package("notes", "1")
    Plugins.handle("rescan", %{})
    assert {:ok, _} = Plugins.handle("enable", %{"id" => "notes", "acceptPermissions" => []})
    %{sup: sup} = plugin("notes")

    assert {:ok, _} = save("notes", %{"count" => 3})

    assert %{sup: ^sup} = plugin("notes")
    assert Process.alive?(sup)
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

  # The version that still runs declares `threadsStay`; the update that failed to load
  # does not, and its manifest is what the disk says. The declaration of the version
  # loaded is read from a table, so a host too busy to answer (suspended here) cannot
  # make it read false and let the plugin's threads leave.
  test "the declaration of the version loaded is read without waiting on the host" do
    code_package("busy", "1", [{"a.ex", busy_source("1")}])
    manifest = Path.join(plugins_dir(), "busy/plugin.json")

    File.write!(
      manifest,
      manifest |> File.read!() |> JSON.decode!() |> declare() |> JSON.encode!()
    )

    Plugins.handle("rescan", %{})
    assert {:ok, _} = Plugins.handle("enable", %{"id" => "busy", "acceptPermissions" => []})
    assert Plugins.threads_stay?("busy")

    code_package("busy", "2", [
      {"a.ex", busy_source("2")},
      {"b.ex", "defmodule HalC2PluginsTest.Broken do\n  def broken(, do: :x\nend\n"}
    ])

    Plugins.handle("rescan", %{})
    assert %{"version" => "1", "reloadError" => error} = listed("busy")
    assert error =~ "b.ex"
    refute HalC2.Plugins.Package.threads_stay?("busy")
    assert Plugins.threads_stay?("busy")

    :ok = :sys.suspend(Plugins)
    assert Plugins.threads_stay?("busy")
    refute Plugins.threads_stay?("other")
    :ok = :sys.resume(Plugins)

    # The host starting again loses the version that ran, and the table with it: the
    # disk answers, and the table fills as the plugins load.
    :ok = Supervisor.terminate_child(HalC2.Plugins.Supervisor, Plugins)
    {:ok, _} = Supervisor.restart_child(HalC2.Plugins.Supervisor, Plugins)
    refute Plugins.threads_stay?("busy")

    code_package("busy", "3", [{"a.ex", busy_source("3")}])

    manifest
    |> File.read!()
    |> JSON.decode!()
    |> declare()
    |> JSON.encode!()
    |> then(&File.write!(manifest, &1))

    Plugins.handle("rescan", %{})
    assert Plugins.threads_stay?("busy")

    # Uninstalling frees the threads.
    File.rm_rf!(Path.join(plugins_dir(), "busy"))
    Plugins.handle("rescan", %{})
    refute Plugins.threads_stay?("busy")
  end

  # A manifest that fails its validation might be one that meant to declare it.
  test "a threadsStay that is no boolean keeps the threads on their machine" do
    code_package("odd", "1", [{"a.ex", busy_source("1")}])
    manifest = Path.join(plugins_dir(), "odd/plugin.json")
    refute HalC2.Plugins.Package.threads_stay?("odd")

    for value <- ["yes", nil, 1, %{}] do
      manifest
      |> File.read!()
      |> JSON.decode!()
      |> Map.put("threadsStay", value)
      |> JSON.encode!()
      |> then(&File.write!(manifest, &1))

      assert HalC2.Plugins.Package.threads_stay?("odd"), inspect(value)
    end
  end

  # A release upgrade updates the host in place: `init/1` does not run again, so a host
  # from before `threadsStay` has no table of declarations. `code_change/3` makes it and
  # fills it from the versions loaded, and the scans after it keep working.
  test "a host updated in place by a release upgrade reads and keeps the declarations" do
    code_package("busy", "1", [{"a.ex", busy_source("1")}])
    manifest = Path.join(plugins_dir(), "busy/plugin.json")

    File.write!(
      manifest,
      manifest |> File.read!() |> JSON.decode!() |> declare() |> JSON.encode!()
    )

    Plugins.handle("rescan", %{})
    pid = Process.whereis(Plugins)

    # The host as a release from before the table left it.
    :sys.replace_state(Plugins, fn state ->
      :ets.delete(HalC2.Plugins.Stays)
      state
    end)

    :ok = :sys.suspend(Plugins)
    :ok = :sys.change_code(Plugins, Plugins, "before", [])
    :ok = :sys.resume(Plugins)

    assert :ets.member(HalC2.Plugins.Stays, "busy")
    Plugins.handle("rescan", %{})
    assert Process.whereis(Plugins) == pid
    assert Plugins.threads_stay?("busy")
  end

  # A file of a package that cannot be read, as one an install removes under a scan, is
  # a package that does not load this time, not a host that crashes: the version that
  # ran keeps running, and a rescan once the file is back loads the new one.
  test "a package file that cannot be read fails the load and leaves the host running" do
    code_package("busy", "1", [{"a.ex", busy_source("1")}])
    Plugins.handle("rescan", %{})
    assert {:ok, _} = Plugins.handle("enable", %{"id" => "busy", "acceptPermissions" => []})
    pid = Process.whereis(Plugins)

    code_package("busy", "2", [{"a.ex", busy_source("2")}])
    source = Path.join(plugins_dir(), "busy/mc/a.ex")
    File.chmod!(source, 0o000)

    try do
      Plugins.handle("rescan", %{})
      assert Process.whereis(Plugins) == pid
      assert %{"version" => "1", "reloadError" => error} = listed("busy")
      assert error =~ "a.ex"
    after
      File.chmod!(source, 0o644)
    end

    Plugins.handle("rescan", %{})
    assert %{"version" => "2", "reloadError" => nil} = listed("busy")
  end

  # A copy the cache cannot take, as when it is briefly full or unwritable, fails that
  # load only: once the cache takes copies again, a rescan of the unchanged package loads it.
  test "a package whose copy failed loads on a rescan once the cache takes copies" do
    code_package("busy", "1", [{"a.ex", busy_source("1")}])
    copies = Path.join(HalC2.Paths.cache_dir(), "plugin-packages")
    File.mkdir_p!(copies)
    File.chmod!(copies, 0o500)

    try do
      Plugins.handle("rescan", %{})
      assert %{"status" => "error"} = listed("busy")
    after
      File.chmod!(copies, 0o755)
    end

    Plugins.handle("rescan", %{})
    assert %{"status" => "disabled"} = listed("busy")
    assert {:ok, _} = Plugins.handle("enable", %{"id" => "busy", "acceptPermissions" => []})
    assert %{"status" => "running", "version" => "1"} = listed("busy")
  end

  defp declare(manifest), do: Map.put(manifest, "threadsStay", true)

  # What a peer answers for a plugin: only a function the running version has, so a
  # machine on an older version or without the plugin says so rather than failing.
  test "a peer answers for a function its plugin has, and says none for what it lacks" do
    code_package("busy", "1", [{"a.ex", busy_source("1")}])
    Plugins.handle("rescan", %{})
    assert {:ok, _} = Plugins.handle("enable", %{"id" => "busy", "acceptPermissions" => []})

    label = HalC2.Environment.label()
    assert {:ok, %{"machine" => ^label, "result" => "1"}} = Host.peer("busy", :version, [])

    assert {:ok, %{"machine" => ^label, "result" => :none}} =
             Host.peer("busy", :claims, [["acme/api#1"]])

    assert {:ok, %{"result" => :none}} = Host.peer("missing", :version, [])
    # Not distributed: no other machine to ask.
    assert [] = Host.peers("busy", :version, [])
  end

  test "a check of a package whose code has a syntax error says where, and enables nothing" do
    code_package("typo", "1", [
      {"a.ex",
       String.replace(busy_source("1"), "HalC2PluginsTest.Busy", "HalC2PluginsTest.Typo")},
      {"b.ex", "defmodule HalC2PluginsTest.Broken do\n  def broken(, do: :x\nend\n"}
    ])

    Plugins.handle("rescan", %{})

    assert {:ok,
            %{"ok" => false, "error" => "mc/b.ex:2: " <> _, "diagnostics" => diagnostics} =
              check} = compile("typo")

    assert [%{"file" => "mc/b.ex", "line" => 2, "severity" => "error"}] = diagnostics

    assert %{"status" => "disabled", "enabled" => false, "compileCheck" => ^check} =
             listed("typo")

    refute :code.is_loaded(HalC2PluginsTest.Typo)
    assert plugin("typo").sup == nil
  end

  test "code that throws or exits as it compiles fails the check, where it did" do
    code_package("thrown", "1", [
      {"a.ex", "defmodule HalC2PluginsTest.Thrown do\n  throw(:not_today)\nend\n"}
    ])

    code_package("exited", "1", [
      {"a.ex",
       "defmodule HalC2PluginsTest.Exited do\n  def x, do: 1\n  exit({:timeout, :no})\nend\n"}
    ])

    Plugins.handle("rescan", %{})

    assert {:ok, %{"ok" => false, "error" => "mc/a.ex:2: ** (throw) :not_today"}} =
             compile("thrown")

    assert %{"compileCheck" => %{"ok" => false}} = listed("thrown")

    assert {:ok, %{"ok" => false, "error" => "mc/a.ex:3: ** (exit) " <> _}} = compile("exited")
  end

  test "what a package's code does to the VM as it compiles stays in the check" do
    code_package("eager", "1", [
      {"a.ex",
       """
       defmodule HalC2PluginsTest.Eager do
         @behaviour HalC2.Plugins.Extension
         :persistent_term.put(:hal_c2_plugins_test_eager, :compiled)
         Process.register(spawn(fn -> Process.sleep(:infinity) end), :hal_c2_plugins_test_eager)
         :ets.new(:hal_c2_plugins_test_eager, [:named_table, :public])
         def call(method, _input, _context), do: {:error, "no method " <> method}
       end
       """}
    ])

    Plugins.handle("rescan", %{})

    assert {:ok, %{"ok" => true, "error" => nil, "diagnostics" => []}} = compile("eager")
    assert :persistent_term.get(:hal_c2_plugins_test_eager, nil) == nil
    assert Process.whereis(:hal_c2_plugins_test_eager) == nil
    assert :ets.whereis(:hal_c2_plugins_test_eager) == :undefined
    refute :code.is_loaded(HalC2PluginsTest.Eager)
    assert Path.wildcard(Path.join(HalC2.Paths.data_dir(), "**/*.beam")) == []
    assert Path.wildcard(Path.join(HalC2.Paths.cache_dir(), "**/*.beam")) == []
  end

  test "a check of a package with a running plugin's module leaves the running code, and work in it" do
    code_package("busy", "1", [{"a.ex", busy_source("1")}])
    Plugins.handle("rescan", %{})
    assert {:ok, _} = Plugins.handle("enable", %{"id" => "busy", "acceptPermissions" => []})

    me = self()
    {waiter, ref} = spawn_monitor(fn -> busy(:wait, [me]) end)
    assert_receive {:parked, ^waiter}

    code_package("fork", "1", [{"a.ex", busy_source("2")}])
    Plugins.handle("rescan", %{})
    assert {:ok, %{"ok" => true}} = compile("fork")

    assert "1" = busy(:version, [])
    assert Process.alive?(waiter)
    send(waiter, :go)
    assert_receive {:DOWN, ^ref, :process, ^waiter, :normal}
    assert %{"status" => "running"} = listed("busy")
  end

  test "a new version or enabling the package drops what a check found" do
    code_package("later", "1", [
      {"a.ex", "defmodule HalC2PluginsTest.Later do\n  def x(, do: 1\nend\n"}
    ])

    Plugins.handle("rescan", %{})
    assert {:ok, %{"ok" => false}} = compile("later")

    # Rescanning the same version keeps it.
    Plugins.handle("rescan", %{})
    assert %{"compileCheck" => %{"ok" => false}} = listed("later")

    code_package("later", "2", [{"a.ex", busy_source("2")}])
    Plugins.handle("rescan", %{})
    assert %{"compileCheck" => nil} = listed("later")

    assert {:ok, %{"ok" => true}} = compile("later")
    assert %{"compileCheck" => %{"ok" => true}} = listed("later")

    assert {:ok, %{"compileCheck" => nil}} =
             Plugins.handle("enable", %{"id" => "later", "acceptPermissions" => []})
  end

  test "a package with two plugin modules fails the check as enabling it would" do
    code_package("two", "1", [
      {"a.ex", busy_source("1")},
      {"b.ex",
       String.replace(busy_source("1"), "HalC2PluginsTest.Busy", "HalC2PluginsTest.Other")}
    ])

    Plugins.handle("rescan", %{})

    assert {:ok, %{"ok" => false, "error" => "mc/ has more than one plugin module" <> _}} =
             compile("two")
  end

  test "only installed plugin packages are checked" do
    assert {:error, %{"_tag" => "PluginNotFound"}} = compile("nothing")

    File.mkdir_p!(plugins_dir())

    File.write!(
      Path.join(plugins_dir(), "broken/plugin.json") |> tap(&File.mkdir_p!(Path.dirname(&1))),
      "{not json"
    )

    Plugins.handle("rescan", %{})

    assert {:error, %{"_tag" => "PluginUnavailable", "message" => message}} = compile("broken")
    assert message =~ "JSON"
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

    # What a release upgrade (`{update, M, {advanced, []}}`) does for a process whose module changed.
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

  defp save(id, settings, scopes \\ :all),
    do: Plugins.handle("saveSettings", %{"id" => id, "settings" => settings}, scopes)

  defp call(id, method, scopes),
    do: Plugins.handle("call", %{"id" => id, "method" => method, "input" => %{}}, scopes)

  defp stored(id), do: get_in(HalC2.Settings.settings(), ["plugins", id, "settings"]) || %{}
  defp compile(id), do: Plugins.handle("compile", %{"id" => id})
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
  defp settings_file, do: Path.join(HalC2.Paths.config_dir(), "settings.json")
  defp plugins_dir, do: Path.join(HalC2.Paths.data_dir(), "plugins")

  # A package of UI parts only (`package/2`), installed and turned on.
  defp running(id) do
    package(id, "1")
    Plugins.handle("rescan", %{})
    assert {:ok, _} = Plugins.handle("enable", %{"id" => id, "acceptPermissions" => []})
  end

  # A package of UI parts only, with a number and a secret among its settings, asking
  # for `permissions`.
  defp package(id, version, permissions \\ []) do
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
        "permissions" => for(p <- permissions, do: %{"id" => p, "reason" => "The test."}),
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

  # A package whose manifest marks a program, a secret key and the call `swap` exec, and
  # leaves a count and the call `status` plain. Its MC part answers each call's name.
  defp exec_package(id) do
    dir = Path.join(plugins_dir(), id)
    File.rm_rf!(dir)
    File.mkdir_p!(Path.join(dir, "mc"))

    File.write!(
      Path.join(dir, "plugin.json"),
      JSON.encode!(%{
        "id" => id,
        "name" => id,
        "version" => "1",
        "description" => "A package that runs a program.",
        "apiVersion" => 1,
        "execCalls" => ["swap"],
        "settings" => [
          %{"key" => "program", "label" => "Program", "type" => "text", "exec" => true},
          %{"key" => "key", "label" => "Key", "type" => "secret", "exec" => true},
          %{"key" => "count", "label" => "Count", "type" => "number", "default" => 1}
        ]
      })
    )

    File.write!(Path.join([dir, "mc", "runner.ex"]), """
    defmodule HalC2PluginsTest.Exec#{Macro.camelize(id)} do
      @behaviour HalC2.Plugins.Extension
      def call(method, _input, _context), do: {:ok, method}
    end
    """)

    Plugins.handle("rescan", %{})
  end

  # A package with MC sources `[{name, source}]`, replacing what the directory held.
  defp code_package(id, version, sources, settings \\ []) do
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
        "apiVersion" => 1,
        "settings" => settings
      })
    )

    for {name, source} <- sources, do: File.write!(Path.join([dir, "mc", name]), source)
  end

  # Enables the plugin `id`, whose process tells the test when it starts and, `live`,
  # when it takes settings (`:live`), or refuses them (`:refuse`), or cannot (`:restart`).
  defp enable_worker(id, live) do
    Process.register(self(), :plugins_test)

    code_package("#{id}", "1", [{"worker.ex", worker_source(id, live)}], [
      %{"key" => "count", "label" => "Count", "type" => "number", "default" => 1},
      %{"key" => "token", "label" => "Token", "type" => "secret"}
    ])

    Plugins.handle("rescan", %{})
    assert {:ok, _} = Plugins.handle("enable", %{"id" => id, "acceptPermissions" => []})
    assert_receive {:started, pid, %{"count" => 1}}
    pid
  end

  defp worker_source(id, live) do
    module = "HalC2PluginsTest.Worker#{Macro.camelize(id)}"

    changed =
      case live do
        :restart ->
          ""

        :live ->
          "def settings_changed(pid, settings, old), do: GenServer.call(pid, {:set, settings, old})"

        :refuse ->
          "def settings_changed(pid, settings, old), do: GenServer.call(pid, {:refuse, settings, old})"
      end

    """
    defmodule #{module} do
      @behaviour HalC2.Plugins.Extension
      use GenServer

      def start_link(settings), do: GenServer.start_link(__MODULE__, settings)
      def validate_settings(%{"count" => count}) when count > 100, do: {:error, "count: too many"}
      def validate_settings(_settings), do: :ok
      #{changed}
      def call(method, _input, _context), do: {:error, "no method " <> method}

      def init(settings) do
        send(:plugins_test, {:started, self(), settings})
        {:ok, settings}
      end

      def handle_call(:settings, _from, settings), do: {:reply, settings, settings}

      def handle_call({:set, settings, old}, _from, _settings) do
        send(:plugins_test, {:changed, self(), settings, old})
        {:reply, :ok, settings}
      end

      def handle_call({:refuse, settings, old}, _from, state) do
        send(:plugins_test, {:changed, self(), settings, old})
        {:reply, {:error, "not now"}, state}
      end
    end
    """
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
