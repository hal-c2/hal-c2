defmodule HalC2.Steps.Plugins.Release do
  @moduledoc """
  An MC running from a release, for upgrade scenarios: a temporary `RELEASE_ROOT`
  with the running version's `upgrade.json`, and bundles of the next version in the
  MC's upgrade cache (`HalC2.Upgrade.Source.put/3`). A bundle carries one fixture
  module whose running version is loaded now; changing a plain module loads in
  place, changing a supervisor needs a restart.
  """

  alias HalC2.Test.Mc

  @manifest %{
    "otpRelease" => "29",
    "erts" => "17.0.5",
    "code" => ["hal_c2_fixture"],
    "config" => "c"
  }

  @doc "Makes the MC run from a release; returns the context with `:release`."
  def ensure(%{release: %{}} = context), do: context

  def ensure(context) do
    Mc.ensure(HalC2.Settings)
    Mc.ensure(HalC2.Upgrade)
    root = Mc.tmp_dir(context.mc, "release")
    current = HalC2.Upgrade.version()
    write_manifest(root, current)
    File.write!(Path.join([root, "releases", "start_erl.data"]), "17.0.5 #{current}\n")
    File.mkdir_p!(Path.join(root, "lib"))

    path = :code.get_path()
    env = for key <- ~w(RELEASE_ROOT HAL_C2_SERVICE), into: %{}, do: {key, System.get_env(key)}
    System.put_env("RELEASE_ROOT", root)
    # The bundles load several versions of the fixture modules.
    Code.put_compiler_option(:ignore_module_conflict, true)

    ExUnit.Callbacks.on_exit(fn ->
      # Loading in place moves code paths to the installed release.
      :code.set_path(path)

      for {key, value} <- env,
          do: if(value, do: System.put_env(key, value), else: System.delete_env(key))

      Code.put_compiler_option(:ignore_module_conflict, false)
      Application.delete_env(:hal_c2, :restart_exit)
      :persistent_term.erase({HalC2.Upgrade, :version})
      :persistent_term.erase({HalC2.Upgrade, :outcome})
    end)

    Map.put(context, :release, %{root: root, from: current})
  end

  @doc """
  Puts a bundle of `target` in the upgrade cache holding `source` (the new version
  of a fixture module) after loading `running` (the version the MC runs now).
  """
  def put_bundle(context, target, source, running) do
    bundle = Mc.tmp_dir(context.mc, "bundle")
    ebin = Path.join([bundle, "lib", "hal_c2_fixture-#{target}", "ebin"])
    File.mkdir_p!(ebin)
    write_manifest(bundle, target)

    for {mod, bin} <- Code.compile_string(source),
        do: File.write!(Path.join(ebin, "#{mod}.beam"), bin)

    Code.compile_string(running)

    archive = Path.join(Mc.tmp_dir(context.mc, "archive"), "bundle.tar.gz")

    files =
      for file <- Path.wildcard(Path.join(bundle, "**/*")),
          File.regular?(file),
          do: {to_charlist(Path.relative_to(file, bundle)), to_charlist(file)}

    :ok = :erl_tar.create(to_charlist(archive), files, [:compressed])
    :ok = HalC2.Upgrade.Source.put(target, HalC2.Upgrade.platform(), archive)
    context
  end

  defp write_manifest(root, version) do
    dir = Path.join([root, "releases", version])
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "upgrade.json"),
      JSON.encode!(
        Map.merge(@manifest, %{
          "version" => version,
          "applications" => %{"hal_c2_fixture" => version}
        })
      )
    )
  end
end

defmodule HalC2.Steps.Plugins.LogTap do
  @moduledoc "A `:logger` handler that sends the test process what the MC logs."

  def attach do
    id = :"hal_c2_log_tap_#{System.unique_integer([:positive])}"
    :ok = :logger.add_handler(id, __MODULE__, %{config: %{pid: self()}, level: :warning})
    ExUnit.Callbacks.on_exit(fn -> :logger.remove_handler(id) end)
  end

  @doc false
  def log(%{msg: msg, level: level}, %{config: %{pid: pid}}),
    do: send(pid, {:log, level, text(msg)})

  defp text({:string, chardata}), do: IO.chardata_to_string(chardata)
  defp text({:report, report}), do: inspect(report)
  defp text({format, args}), do: format |> :io_lib.format(args) |> IO.chardata_to_string()

  @doc "Waits for a logged line containing `fragment`."
  def await(fragment) do
    receive do
      {:log, _level, text} -> if text =~ fragment, do: text, else: await(fragment)
    after
      2_000 -> ExUnit.Assertions.flunk("the MC never logged #{inspect(fragment)}")
    end
  end
end

defmodule HalC2.Steps.Plugins.NodePlugins do
  @moduledoc "Steps for `features/plugins/mc-plugins.feature`."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.Plugins.{Fixtures, LogTap, Release, Turns}
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @plain "HalC2.Steps.Plugins.NodePlugins.Plain"
  @tree "HalC2.Steps.Plugins.NodePlugins.Tree"

  step "an MC with a plugins directory", context do
    File.mkdir_p!(Path.join(context.mc.home, "plugins"))
    context
  end

  # --- upgrades --------------------------------------------------------------------------

  step "a thread has a running provider session", context do
    context = context |> World.create_project("shop") |> Turns.providers()
    {thread_id, context} = Turns.send_first(context, "codex", "wait for it")
    [run] = Turns.await_runs(thread_id, ["running"])
    [{session, _}] = Registry.lookup(HalC2.Codex.Registry, thread_id)
    Map.put(context, :running, %{thread: thread_id, run: run["id"], session: session})
  end

  step "the MC installs a version whose changes need no restart", context do
    context = Release.ensure(context)
    target = context.release.from <> "-hot"

    context =
      Release.put_bundle(
        context,
        target,
        "defmodule #{@plain} do def v, do: 2 end",
        "defmodule #{@plain} do def v, do: 1 end"
      )

    {reply, context} = World.call(context, "server.updateServer", %{"targetVersion" => target})
    Map.merge(context, %{reply: reply, target: target})
  end

  step "the new code is loaded in place", context do
    assert {:ok, %{"method" => "hot-upgrade", "targetVersion" => target}} = context.reply
    assert target == context.target
    assert HalC2.Upgrade.version() == target
    assert apply(Module.concat([@plain]), :v, []) == 2
    context
  end

  step "the provider session and client connections stay up", context do
    %{thread: thread_id, run: run_id, session: session} = context.running
    assert Process.alive?(session)
    assert [{^session, _}] = Registry.lookup(HalC2.Codex.Registry, thread_id)

    assert [%{"id" => ^run_id, "status" => "running"}] =
             Turns.runs(HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id)))

    # The socket that asked for the update is still served.
    {{:ok, _}, context} = World.call(context, "server.getSettings")
    context
  end

  step "the MC installs a version that changes a supervisor", context do
    test = self()
    Application.put_env(:hal_c2, :restart_exit, &send(test, {:restart_exit, &1}))
    System.put_env("HAL_C2_SERVICE", "1")
    context = Release.ensure(context)
    target = context.release.from <> "-tree"

    tree = fn children ->
      "defmodule #{@tree} do use Supervisor; def init(_), do: Supervisor.init(#{children}, strategy: :one_for_one) end"
    end

    context = Release.put_bundle(context, target, tree.("[{Task, fn -> :ok end}]"), tree.("[]"))
    {reply, context} = World.call(context, "server.updateServer", %{"targetVersion" => target})
    assert {:ok, %{"targetVersion" => ^target}} = reply
    Map.put(context, :target, target)
  end

  step "the MC restarts on the new version", context do
    # The MC exits for bin/hal-c2-service, whose next boot runs what start_erl.data names.
    assert_receive {:restart_exit, 75}, 2_000
    start = File.read!(Path.join([context.release.root, "releases", "start_erl.data"]))
    assert [_erts, booted] = String.split(start)
    assert booted == context.target

    :persistent_term.put({HalC2.Upgrade, :version}, booted)
    :ok = ExUnit.Callbacks.stop_supervised(HalC2.Upgrade)
    mc = Mc.restart(context.mc)
    Mc.ensure(HalC2.Upgrade)
    %{context | mc: mc, clients: %{}}
  end

  step "the outcome of the update is reported when it is ready again", context do
    client =
      Mc.sub(Mc.connect(context.mc), 1, %{
        "type" => "config",
        "mc" => Atom.to_string(node())
      })

    {frame, client} = Mc.await(client, &(&1["t"] == "config" and &1["id"] == 1))

    assert %{"status" => "committed", "targetVersion" => target, "fromVersion" => from} =
             frame["updateOutcome"]

    assert target == context.target
    assert from == context.release.from
    World.put_client(context, client)
  end

  # --- discovery -------------------------------------------------------------------------

  step ~r/^the plugins directory contains a (?<kind>.+) plugin named "(?<id>[^"]+)"$/,
       %{args: [_kind, id]} = context do
    Fixtures.install(context, id)
  end

  step ~r/^"(?<id>[^"]+)" is listed as an installed (?<kind>.+) plugin$/,
       %{args: [id, kind]} = context do
    {%{"plugins" => plugins}, context} = World.call!(context, "plugins.list")
    expected = Fixtures.kind(kind)

    assert %{"kind" => ^expected, "version" => "1.0.0", "apiVersion" => 1} =
             Enum.find(plugins, &(&1["id"] == id))

    context
  end

  step "the plugins directory contains a module that implements no plugin behaviour", context do
    LogTap.attach()

    File.write!(
      Fixtures.path(context, "notes"),
      "defmodule HalC2PluginFixture.Notes do\n  def hello, do: :world\nend\n"
    )

    Fixtures.ensure(context)
  end

  step "the MC logs that the module is not a plugin", context do
    LogTap.await("notes.ex is not a plugin")
    context
  end

  step "it is not listed as a plugin", context do
    {%{"plugins" => plugins}, context} = World.call!(context, "plugins.list")
    refute Enum.any?(plugins, &(&1["file"] == "notes.ex"))
    context
  end

  step ~r/^the plugins directory contains "(?<id>[^"]+)" whose code does not load$/,
       %{args: [id]} = context do
    File.write!(Fixtures.path(context, id), unloadable(id, "1.0.0"))
    Fixtures.ensure(context)
  end

  step "the MC is ready", context do
    {_, context} = World.call!(context, "server.getSettings")
    assert Process.alive?(Process.whereis(HalC2.Plugins))
    context
  end

  step ~r/^"(?<id>[^"]+)" is listed with its load error$/, %{args: [id]} = context do
    {%{"plugins" => plugins}, context} = World.call!(context, "plugins.list")
    assert %{"status" => "error", "error" => error} = Enum.find(plugins, &(&1["id"] == id))
    assert error =~ "undefined function"
    context
  end

  step "the plugins directory gains the plugin {string}", %{args: [id]} = context do
    context = Fixtures.ensure(context)
    File.write!(Fixtures.path(context, id), Fixtures.source(id))
    context
  end

  step "the MC rescans its plugins", context do
    {_, context} = World.call!(context, "plugins.rescan")
    context
  end

  step ~r/^"(?<id>[^"]+)" is listed as disabled$/, %{args: [id]} = context do
    assert %{"status" => "disabled", "enabled" => false} = Fixtures.entry(id)
    assert Process.whereis(Fixtures.module(id)) == nil
    context
  end

  # --- enabling --------------------------------------------------------------------------

  step ~r/^the (?:plugin|notification channel|MCP tool pack|text-generation backend) "(?<id>[^"]+)" is enabled$/,
       %{args: [id]} = context do
    context |> Fixtures.install(id) |> configure(id) |> Fixtures.enable(id)
  end

  step "its tools are no longer offered to agents in new turns", context do
    names = context |> agent_turn() |> tool_names()
    assert Enum.all?(HalC2.Mcp.Tools.list(), &(&1["name"] in names))
    refute "jira_search" in names
    context
  end

  step "its settings are kept for when it is enabled again", context do
    assert %{"enabled" => false, "settings" => %{"siteUrl" => "https://acme.atlassian.net"}} =
             Fixtures.entry("jira-tools")

    context
  end

  step "the user disabled {string} after setting its site URL", %{args: [id]} = context do
    context =
      context
      |> Fixtures.install(id)
      |> configure(id, %{"siteUrl" => "https://shop.atlassian.net"})

    context = Fixtures.enable(context, id)
    {_, context} = World.call!(context, "plugins.disable", %{"id" => id})
    context
  end

  step "its tools are offered again with the same site URL", context do
    context = agent_turn(context)
    tool = Enum.find(mcp(context, "tools/list")["tools"], &(&1["name"] == "jira_search"))
    assert tool["description"] =~ "https://shop.atlassian.net"

    assert %{"structuredContent" => %{"site" => "https://shop.atlassian.net"}} =
             mcp(context, "tools/call", %{
               "name" => "jira_search",
               "arguments" => %{"query" => "checkout"}
             })

    context
  end

  step "the user enabled {string} and disabled {string}", %{args: [on, off]} = context do
    context = context |> Fixtures.install(on) |> Fixtures.install(off)
    context = context |> Fixtures.enable(on) |> Fixtures.enable(off)
    {_, context} = World.call!(context, "plugins.disable", %{"id" => off})
    context
  end

  step "{string} is enabled and {string} is disabled", %{args: [on, off]} = context do
    {%{"plugins" => plugins}, context} = World.call!(context, "plugins.list")
    assert %{"enabled" => true, "status" => "running"} = Enum.find(plugins, &(&1["id"] == on))
    assert %{"enabled" => false, "status" => "disabled"} = Enum.find(plugins, &(&1["id"] == off))
    assert Process.whereis(Fixtures.module(off)) == nil
    context
  end

  # --- plugin API versions ---------------------------------------------------------------

  step "the plugin {string} declares that it needs an older plugin API",
       %{args: [id]} = context do
    # Enabled before this MC stopped offering the API it was built for.
    context = Fixtures.ensure(context)
    {settings, version} = HalC2.Settings.get()
    plugins = Map.put(settings["plugins"] || %{}, id, %{"enabled" => true})
    {:ok, _} = HalC2.Settings.put(Map.put(settings, "plugins", plugins), version)
    File.write!(Fixtures.path(context, id), Fixtures.source(id))
    Map.put(context, :plugin, id)
  end

  step ~r/^"(?<id>[^"]+)" is listed as incompatible with the version it needs$/,
       %{args: [id]} = context do
    {%{"plugins" => plugins}, context} = World.call!(context, "plugins.list")

    assert %{"status" => "incompatible", "apiVersion" => 0, "error" => error} =
             Enum.find(plugins, &(&1["id"] == id))

    assert error =~ "plugin API 0"
    context
  end

  step "it is not started", context do
    assert Process.whereis(Fixtures.module(context.plugin)) == nil
    assert HalC2.Plugins.git_host("git.example.com") == nil
    context
  end

  step "the plugin {string} needs a newer plugin API than the MC offers",
       %{args: [id]} = context do
    Fixtures.install(context, id)
  end

  step "the user tries to enable {string}", %{args: [id]} = context do
    {reply, context} = World.call(context, "plugins.enable", %{"id" => id})
    Map.merge(context, %{reply: reply, plugin: id})
  end

  step "the user is told to update the MC first", context do
    assert {:error, message, %{"_tag" => "PluginUnavailable"}} = context.reply
    assert message =~ "Update the MC first"
    assert %{"status" => "incompatible", "enabled" => false} = Fixtures.entry(context.plugin)
    context
  end

  # --- supervision -----------------------------------------------------------------------

  step ~r/^"(?<id>[^"]+)" crashes$/, %{args: [id]} = context do
    # A thread and another plugin run alongside, to show they are left alone.
    context = context |> bystander(id) |> running_thread()
    Fixtures.probe()
    HalC2.Plugins.subscribe(self())
    pid = crash(id)
    Map.put(context, :crashed, pid)
  end

  step "its supervisor restarts it", context do
    id = context.plugin
    assert_receive {:plugin_started, ^id, pid}, 2_000
    assert pid != context.crashed
    entry = await_plugin(id, &(&1["restarts"] == 1))
    assert %{"status" => "running", "lastError" => "ntfy lost its connection"} = entry
    context
  end

  step "running threads and other plugins are unaffected", context do
    {other, pid} = context.bystander
    assert Process.whereis(Fixtures.module(other)) == pid
    assert %{"status" => "running", "restarts" => 0} = Fixtures.entry(other)

    %{thread: thread_id, run: run_id, session: session} = context.running
    assert Process.alive?(session)

    assert [%{"id" => ^run_id, "status" => "running"}] =
             Turns.runs(HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id)))

    context
  end

  step ~r/^"(?<id>[^"]+)" crashes repeatedly within a short time$/, %{args: [id]} = context do
    crash_repeatedly(context, id)
  end

  step "its restart limit is reached", context do
    await_plugin(context.plugin, &(&1["status"] == "failed"))
    context
  end

  step ~r/^"(?<id>[^"]+)" is stopped and listed as failed with its last error$/,
       %{args: [id]} = context do
    assert Process.whereis(Fixtures.module(id)) == nil

    assert %{"status" => "failed", "enabled" => true, "lastError" => "ntfy lost its connection"} =
             Fixtures.entry(id)

    context
  end

  step "the MC keeps running", context do
    assert Process.whereis(HalC2.Plugins) == context.plugins_pid
    {_, context} = World.call!(context, "server.getSettings")
    context
  end

  step ~r/^"(?<id>[^"]+)" is listed as failed$/, %{args: [id]} = context do
    context = crash_repeatedly(context, id)
    await_plugin(id, &(&1["status"] == "failed"))
    context
  end

  step "the user restarts {string}", %{args: [id]} = context do
    {_, context} = World.call!(context, "plugins.restart", %{"id" => id})
    context
  end

  step ~r/^"(?<id>[^"]+)" runs again$/, %{args: [id]} = context do
    assert_receive {:plugin_started, ^id, pid}, 2_000
    assert Process.whereis(Fixtures.module(id)) == pid
    assert %{"status" => "running"} = Fixtures.entry(id)
    context
  end

  # --- settings --------------------------------------------------------------------------

  step "the git host {string} asks for a base URL and a token", %{args: [id]} = context do
    context = context |> Fixtures.install(id) |> configure(id)

    assert [%{"key" => "baseUrl", "secret" => false}, %{"key" => "token", "secret" => true}] =
             Fixtures.entry(id)["settingsSchema"]

    Map.put(context, :plugin, id)
  end

  step "the user saves a base URL that is not a URL", context do
    {reply, context} =
      World.call(context, "plugins.saveSettings", %{
        "id" => context.plugin,
        "settings" => %{"baseUrl" => "git example com"}
      })

    Map.put(context, :reply, reply)
  end

  step "the save is refused with the plugin's message", context do
    assert {:error, "The base URL must be an http(s) address, like https://git.example.com.",
            %{"_tag" => "PluginSettingsInvalid"}} = context.reply

    context
  end

  step "the previous settings are kept", context do
    before = context[:settings_before] || %{"baseUrl" => "https://git.example.com"}
    assert Fixtures.entry(context.plugin)["settings"] == before
    context
  end

  step "the user saves a token for {string}", %{args: [id]} = context do
    context = Fixtures.install(context, id)

    {_, context} =
      World.call!(context, "plugins.saveSettings", %{
        "id" => id,
        "settings" => %{"baseUrl" => "https://git.example.com", "token" => "gt-secret-123"}
      })

    Map.put(context, :plugin, id)
  end

  step "the token is stored in the MC's secrets", context do
    [secret] = Path.wildcard(Path.join([context.mc.home, "secrets", "plugin-*.bin"]))
    assert File.read!(secret) == "gt-secret-123"
    assert File.stat!(secret).mode |> Bitwise.band(0o777) == 0o600
    refute File.read!(Path.join(context.mc.home, "settings.json")) =~ "gt-secret-123"
    context
  end

  step "clients only see that a token is set", context do
    {listing, context} = World.call!(context, "plugins.list")
    {settings, context} = World.call!(context, "server.getSettings")

    assert %{"token" => "••••••", "baseUrl" => "https://git.example.com"} =
             Enum.find(listing["plugins"], &(&1["id"] == context.plugin))["settings"]

    assert get_in(settings, ["plugins", context.plugin, "settings", "token"]) == "••••••"
    refute inspect({listing, settings}) =~ "gt-secret-123"
    context
  end

  step "the user changes a setting of {string} on the first client", %{args: [id]} = context do
    context = Fixtures.install(context, id)

    second =
      Mc.sub(World.client(context, "second"), 1, %{
        "type" => "config",
        "mc" => Atom.to_string(node())
      })

    {_, second} = Mc.await(second, &(&1["t"] == "config" and &1["id"] == 1))
    context = World.put_client(context, "second", second)

    {_, context} =
      World.call!(
        context,
        "plugins.saveSettings",
        %{"id" => id, "settings" => %{"baseUrl" => "https://git.acme.dev"}},
        "first"
      )

    Map.put(context, :plugin, id)
  end

  step "the second client shows the new setting", context do
    {_, second} =
      Mc.await(
        World.client(context, "second"),
        &(&1["t"] == "config.settings" and
            get_in(&1, ["settings", "plugins", context.plugin, "settings", "baseUrl"]) ==
              "https://git.acme.dev")
      )

    World.put_client(context, "second", second)
  end

  # --- reloading -------------------------------------------------------------------------

  step ~r/^a new version of "(?<id>[^"]+)" is placed in the plugins directory and the MC reloads$/,
       %{args: [id]} = context do
    context = bystander(context, id)
    File.write!(Fixtures.path(context, id), Fixtures.source(id, "2.0.0"))
    {_, context} = World.call!(context, "plugins.rescan")
    Map.merge(context, %{plugin: id, plugins_pid: Process.whereis(HalC2.Plugins)})
  end

  step ~r/^"(?<id>[^"]+)" runs the new version without an MC restart$/,
       %{args: [id]} = context do
    assert %{"status" => "running", "version" => "2.0.0"} = Fixtures.entry(id)
    assert GenServer.call(Fixtures.module(id), :version) == "2.0.0"
    assert Process.whereis(HalC2.Plugins) == context.plugins_pid
    context
  end

  step "plugins that did not change keep running untouched", context do
    {other, pid} = context.bystander
    assert Process.whereis(Fixtures.module(other)) == pid
    assert %{"status" => "running", "version" => "1.0.0"} = Fixtures.entry(other)
    context
  end

  step ~r/^a new version of "(?<id>[^"]+)" that fails to load is placed in the plugins directory$/,
       %{args: [id]} = context do
    running = Process.whereis(Fixtures.module(id))
    File.write!(Fixtures.path(context, id), unloadable(id, "2.0.0"))
    {_, context} = World.call!(context, "plugins.rescan")
    Map.merge(context, %{plugin: id, running_pid: running})
  end

  step ~r/^the MC keeps running the old version of "(?<id>[^"]+)"$/, %{args: [id]} = context do
    assert Process.whereis(Fixtures.module(id)) == context.running_pid
    assert GenServer.call(Fixtures.module(id), :version) == "1.0.0"
    assert %{"status" => "running", "version" => "1.0.0"} = Fixtures.entry(id)
    context
  end

  step "the failed reload is reported", context do
    assert Fixtures.entry(context.plugin)["reloadError"] =~ "undefined function"
    context
  end

  step ~r/^"(?<id>[^"]+)" is removed from the plugins directory and the MC rescans$/,
       %{args: [id]} = context do
    running = Process.whereis(Fixtures.module(id))
    File.rm!(Fixtures.path(context, id))
    {_, context} = World.call!(context, "plugins.rescan")
    Map.put(context, :running_pid, running)
  end

  step ~r/^"(?<id>[^"]+)" is stopped and no longer listed$/, %{args: [id]} = context do
    refute Process.alive?(context.running_pid)
    {%{"plugins" => plugins}, context} = World.call!(context, "plugins.list")
    refute Enum.any?(plugins, &(&1["id"] == id))
    context
  end

  # --- contributions ---------------------------------------------------------------------

  step "the git host plugin {string} is enabled with a base URL", %{args: [id]} = context do
    context |> Fixtures.install(id) |> configure(id) |> Fixtures.enable(id)
  end

  step "a project whose remote is on that host", context do
    context = World.create_project(context, "shop")

    World.git!(
      context.projects["shop"].root,
      ~w(remote add origin https://git.example.com/acme/shop.git)
    )

    context
  end

  step "the user opens the pull requests for the project", context do
    {reply, context} =
      World.call(context, "pullRequests.list", %{"projectId" => context.projects["shop"].id})

    Map.put(context, :reply, reply)
  end

  step "the pull requests come from {string}", %{args: [id]} = context do
    assert {:ok, %{"entries" => [entry], "errors" => [], "providers" => providers}} =
             context.reply

    assert %{
             "provider" => ^id,
             "number" => 7,
             "repository" => "acme/shop",
             "host" => "git.example.com"
           } =
             entry

    assert entry["url"] == "https://git.example.com/acme/shop/pulls/7"
    assert Enum.any?(providers, &(&1["host"] == "git.example.com" and &1["kind"] == id))
    context
  end

  step "the user picks {string} for text generation", %{args: [id]} = context do
    {%{"settings" => settings, "version" => version}, context} =
      World.call!(context, "hal-c2.readSettings")

    selection = %{"instanceId" => id, "model" => "llama-3"}

    {_, context} =
      World.call!(context, "hal-c2.writeSettings", %{
        "settings" => Map.put(settings, "textGenerationModelSelection", selection),
        "version" => version
      })

    context
  end

  step "a thread needs a title", context do
    context = context |> Turns.providers() |> World.create_project("shop")
    thread_id = "th-title-#{System.unique_integer([:positive])}"

    {_, context} =
      World.call!(context, "orchestration.launchThread", %{
        "commandId" => "cmd-#{thread_id}",
        "threadId" => thread_id,
        "projectId" => context.projects["shop"].id,
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "generateTitle" => true,
        "initialMessage" => %{
          "messageId" => "m1",
          "text" => "fix the checkout",
          "attachments" => []
        }
      })

    Map.put(context, :thread, thread_id)
  end

  step "{string} writes the title", %{args: [id]} = context do
    World.await_row(context.thread, &(&1["title"] == "Written by #{id}"))
    context
  end

  step ~r/^an agent starts a turn in (?:a project that allows MCP|that project)$/, context do
    agent_turn(context)
  end

  step ~r/^the agent can call the "(?<id>[^"]+)" tools$/, %{args: [_id]} = context do
    names = tool_names(context)
    assert "jira_search" in names
    assert Enum.all?(HalC2.Mcp.Tools.list(), &(&1["name"] in names))

    assert %{"structuredContent" => %{"site" => "https://acme.atlassian.net", "issues" => [_]}} =
             mcp(context, "tools/call", %{
               "name" => "jira_search",
               "arguments" => %{"query" => "checkout"}
             })

    context
  end

  step "the project has MCP turned off", context do
    context = World.create_project(context, "shop")
    project = context.projects["shop"].id
    {settings, version} = HalC2.Settings.get()

    overrides =
      Map.put(settings["projectSettingsOverrides"] || %{}, project, %{
        "enableAgentBrowserAccess" => false
      })

    {:ok, _} =
      HalC2.Settings.put(Map.put(settings, "projectSettingsOverrides", overrides), version)

    context
  end

  step ~r/^no "(?<id>[^"]+)" tools are offered$/, %{args: [_id]} = context do
    # The whole hal-c2 MCP server, tool packs included, is kept from the agent.
    assert context.mcp == nil
    assert HalC2.Plugins.tools() != []
    context
  end

  # A new turn's agent in "shop": the MCP server its runtime would hand it (`HalC2.Mcp.for_agent/2`).
  defp agent_turn(context) do
    Mc.ensure(HalC2.Mcp)

    context =
      if context[:projects]["shop"], do: context, else: World.create_project(context, "shop")

    context = World.create_thread(context, "Agent #{System.unique_integer([:positive])}", "shop")
    thread_id = context.threads |> Map.values() |> List.last()
    Map.put(context, :mcp, HalC2.Mcp.for_agent(thread_id, "codex"))
  end

  defp tool_names(context), do: Enum.map(mcp(context, "tools/list")["tools"], & &1["name"])

  defp mcp(context, method, params \\ %{}) do
    %{authorization: "Bearer " <> token} = context.mcp
    body = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

    {200, %{"result" => result}} =
      Mc.http(context.mc, :post, "/mcp", bearer: token, json: body)

    result
  end

  # --- environments --------------------------------------------------------------------

  step "two environments each have the plugin {string} installed", %{args: [id]} = context do
    context |> Fixtures.install(id) |> Fixtures.install_on_peer(id)
  end

  step "the user enables {string} on the first environment", %{args: [id]} = context do
    {_, context} = World.call!(context, "plugins.enable", %{"id" => id})
    context
  end

  step "{string} runs on the first environment", %{args: [id]} = context do
    assert %{"status" => "running", "enabled" => true} = Fixtures.entry(id)
    assert is_pid(Process.whereis(Fixtures.module(id)))
    context
  end

  step "{string} stays disabled on the second environment", %{args: [id]} = context do
    {plugins, context} = Fixtures.list(context, context.peer_environment)
    assert %{"status" => "disabled", "enabled" => false} = Enum.find(plugins, &(&1["id"] == id))
    assert :erpc.call(context.peer, Process, :whereis, [Fixtures.module(id)]) == nil
    context
  end

  step "two MCs are connected in a cluster", context do
    context = Fixtures.peer(context)
    assert context.peer in :erlang.nodes()
    context
  end

  step "only the second MC has the plugin {string}", %{args: [id]} = context do
    context |> Fixtures.install_on_peer(id) |> Map.put(:plugin, id)
  end

  step "the user lists plugins for each environment", context do
    {local, context} = Fixtures.list(context, context.mc.environment)
    {remote, context} = Fixtures.list(context, context.peer_environment)
    Map.put(context, :listings, %{first: local, second: remote})
  end

  step "{string} is listed for the second environment only", %{args: [id]} = context do
    refute Enum.any?(context.listings.first, &(&1["id"] == id))
    assert %{"status" => "disabled"} = Enum.find(context.listings.second, &(&1["id"] == id))
    context
  end

  # --- notifications ---------------------------------------------------------------------

  step "a turn finishes while no client is focused on the thread", context do
    Fixtures.probe()
    context = context |> World.create_project("shop") |> Turns.providers()
    {thread_id, context} = Turns.send_first(context, "codex", "hello")
    Turns.await_runs(thread_id, ["completed"])
    refute HalC2.BackgroundPolicy.watched?(thread_id)
    Map.put(context, :thread_id, thread_id)
  end

  step "{string} delivers the notification", %{args: [id]} = context do
    thread_id = context.thread_id

    assert_receive {:notified, ^id,
                    %{
                      "type" => "turn.finished",
                      "threadId" => ^thread_id,
                      "status" => "completed"
                    }, _settings},
                   2_000

    context
  end

  # --- helpers ---------------------------------------------------------------------------

  defp configure(context, id, settings \\ nil) do
    settings =
      settings ||
        case id do
          "jira-tools" -> %{"siteUrl" => "https://acme.atlassian.net"}
          "gitea" -> %{"baseUrl" => "https://git.example.com"}
          _ -> nil
        end

    if settings do
      {_, context} =
        World.call!(context, "plugins.saveSettings", %{"id" => id, "settings" => settings})

      context
    else
      context
    end
  end

  # Another enabled plugin, kept in the context as `:bystander` (`{id, pid}`).
  defp bystander(context, id) do
    other = if id == "gitea", do: "local-llama", else: "gitea"
    context = context |> Fixtures.install(other) |> configure(other) |> Fixtures.enable(other)
    Map.merge(context, %{bystander: {other, Process.whereis(Fixtures.module(other))}, plugin: id})
  end

  defp running_thread(context) do
    context = context |> World.create_project("shop") |> Turns.providers()
    {thread_id, context} = Turns.send_first(context, "codex", "wait for it")
    [run] = Turns.await_runs(thread_id, ["running"])
    [{session, _}] = Registry.lookup(HalC2.Codex.Registry, thread_id)
    Map.put(context, :running, %{thread: thread_id, run: run["id"], session: session})
  end

  # Crashes the plugin's process; returns the pid that crashed.
  defp crash(id) do
    pid = Process.whereis(Fixtures.module(id))
    GenServer.cast(pid, :crash)
    pid
  end

  # One crash more than the plugin's supervisor restarts in its window.
  defp crash_repeatedly(context, id) do
    context = context |> Fixtures.install(id) |> Fixtures.enable(id)
    Fixtures.probe()
    HalC2.Plugins.subscribe(self())

    for _ <- 1..3 do
      crash(id)
      assert_receive {:plugin_started, ^id, _}, 2_000
    end

    crash(id)
    Map.merge(context, %{plugin: id, plugins_pid: Process.whereis(HalC2.Plugins)})
  end

  # The listing of `id` once it satisfies `fun`, from `HalC2.Plugins` pushes.
  defp await_plugin(id, fun) do
    entry = Fixtures.entry(id)

    if fun.(entry) do
      entry
    else
      receive do
        {:hal_c2_plugins, _mc, list} ->
          entry = Enum.find(list, &(&1["id"] == id))
          if fun.(entry), do: entry, else: await_plugin(id, fun)
      after
        2_000 -> flunk("#{id} never became as expected: #{inspect(entry)}")
      end
    end
  end

  # Plugin `id` at `version` with a call that does not compile.
  defp unloadable(id, version) do
    String.replace(
      Fixtures.source(id, version),
      "  def start_link(settings)",
      "  def broken, do: not_defined_anywhere()\n\n  def start_link(settings)"
    )
  end
end
