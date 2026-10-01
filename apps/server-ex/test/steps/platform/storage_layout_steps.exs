defmodule HalC2.Steps.Platform.StorageLayout do
  @moduledoc """
  Steps for features/mc/platform/storage-layout.feature, and the storage
  steps mc-startup.feature and storage-migration.feature share.

  Linux and macOS users start a real MC (`HalC2.Test.Storage`) with the
  scenario's `/home/sam` as their home. A Windows user is resolved with
  `HalC2.Paths.app_dirs/4` under Windows path rules, since the MC cannot start
  as one here.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Paths
  alias HalC2.Test.{Mc, Storage}
  alias HalC2.Test.Mc.World

  # --- the user ------------------------------------------------------------------------

  step ~r/^an? (?<platform>Linux|macOS|Windows) user with no XDG variables and no HAL-C2 home configured$/,
       %{args: [platform]} = context do
    Storage.user(context, platform)
  end

  step ~r/^an? (?<platform>Linux|macOS|Windows) user with (?<var>XDG_[A-Z_]+) set to "(?<value>[^"]*)"$/,
       %{args: [platform, var, value]} = context do
    context |> Storage.user(platform) |> set_xdg(var, value)
  end

  step ~r/^(?<var>XDG_[A-Z_]+) is set to "(?<value>[^"]*)"$/, %{args: [var, value]} = context do
    context |> Storage.user() |> set_xdg(var, value)
  end

  step ~r/^a Linux user whose (?<kind>config|data|state|cache|runtime) directory does not exist yet$/,
       %{args: [kind]} = context do
    context = Storage.user(context)
    refute File.exists?(dir(kind))
    context
  end

  step "no HAL-C2 home is configured", context do
    Storage.user(context)
  end

  step "HAL_C2_HOME is {string}", %{args: [home]} = context do
    context = Storage.user(context)
    World.put_os_env("HAL_C2_HOME", Storage.path(context, home))
    put_in(context, [:mc, :spec], Storage.release_spec())
  end

  step "HAL_C2_HOME is {string} in the developer's shell", %{args: [home]} = context do
    context = Storage.user(context)
    World.put_os_env("HAL_C2_HOME", Storage.path(context, home))
    context
  end

  step "HAL_C2_MC_HOME is {string}", %{args: [home]} = context do
    context = Storage.user(context)
    World.put_os_env("HAL_C2_MC_HOME", Storage.path(context, home))
    put_in(context, [:mc, :spec], Storage.release_spec())
  end

  step "HAL_C2_MC_HOME is {string} and HAL_C2_HOME is {string}",
       %{args: [mc_home, home]} = context do
    context = Storage.user(context)
    World.put_os_env("HAL_C2_MC_HOME", Storage.path(context, mc_home))
    World.put_os_env("HAL_C2_HOME", Storage.path(context, home))
    put_in(context, [:mc, :spec], Storage.release_spec())
  end

  # --- starting ------------------------------------------------------------------------

  step "HAL-C2 starts", context do
    context = Storage.user(context)

    if context.storage_user.platform == "Windows" do
      env =
        Map.merge(
          %{
            "APPDATA" => Storage.path(context, "%APPDATA%"),
            "LOCALAPPDATA" => Storage.path(context, "%LOCALAPPDATA%")
          },
          context[:windows_env] || %{}
        )

      Map.put(context, :resolved, Paths.app_dirs(nil, env, "C:\\Users\\sam", :windows))
    else
      Storage.start(context)
    end
  end

  step "HAL-C2 starts and saves its settings", context do
    context = Storage.start(context)
    :ok = World.merge_settings(%{"providers" => %{"grok" => %{"enabled" => false}}})
    context
  end

  step "HAL-C2 stores a secret for the first time", context do
    context = Storage.start(context)
    :ok = HalC2.Connect.Secrets.put("relay-token", "s3cret")
    context
  end

  step ~r/^a developer starts HAL-C2 from a linked git worktree$/, context do
    Storage.start_checkout(context, :worktree)
  end

  step "the server is started from a linked worktree", context do
    context |> Storage.user() |> Map.put(:checkout_kind, :worktree)
  end

  step "a developer starts a development server from a linked git worktree", context do
    Storage.start_checkout(context, :worktree)
  end

  step "the installed app's {string} is not touched", %{args: [dir]} = context do
    Storage.assert_untouched(context, Storage.path(context, dir))
    context
  end

  step "a developer starts a development server", context do
    Storage.start_checkout(context, context[:checkout_kind] || :worktree)
  end

  # --- where things are ----------------------------------------------------------------

  step ~r/^its (?<kind>config|data|state|cache|runtime) directory is (?<path>.+)$/,
       %{args: [kind, path]} = context do
    expected = expected_path(context, path)

    case context[:resolved] do
      %{} = resolved ->
        assert Map.fetch!(resolved, String.to_atom(kind)) == expected

      nil ->
        assert dir(kind) == expected

        # The MC keeps nothing in the runtime directory, so it only resolves it; its
        # own files are under an `elixir` level in each of the other kinds.
        if kind != "runtime" do
          assert File.dir?(expected), "#{expected} was not created"
          assert Map.fetch!(Paths.dirs(), String.to_atom(kind)) == Path.join(expected, "elixir")
        end
    end

    context
  end

  step "nothing is written under {string}", %{args: [path]} = context do
    real = Storage.path(context, path)
    Storage.assert_untouched(context, real)
    context
  end

  step ~r/^HAL-C2 creates its (?<kind>config|data|state|cache|runtime) directory readable only by the user$/,
       %{args: [kind]} = context do
    assert private?(dir(kind)), "#{dir(kind)} is not private"

    if kind != "runtime" do
      mc_dir = Map.fetch!(Paths.dirs(), String.to_atom(kind))
      assert private?(mc_dir), "#{mc_dir} is not private"
    end

    context
  end

  step "its {string} directory in the data directory is readable only by the user",
       %{args: [name]} = context do
    dir = Path.join(Paths.data_dir(), name)
    assert private?(dir)
    assert File.regular?(Path.join(dir, "relay-token.bin"))
    assert mode(Path.join(dir, "relay-token.bin")) == 0o600
    context
  end

  step "every kind lives under the worktree's {string} directory", %{args: [name]} = context do
    root = Path.join(context.checkout, name)

    for kind <- [:config, :data, :state, :cache] do
      dir = Map.fetch!(Paths.dirs(), kind)
      assert dir == Path.join([root, Atom.to_string(kind), "elixir"])
      assert File.dir?(dir)
    end

    assert HalC2.Store.home_path() == Path.join(root, "data/elixir/hal-c2.sqlite")
    context
  end

  step "there is no {string} or {string} level inside it", %{args: names} = context do
    data = Storage.app_dirs().data

    for name <- names,
        do: refute(File.exists?(Path.join(data, name)), "#{data} has a #{name} level")

    context
  end

  # --- the MC's files ----------------------------------------------------------------

  step(~r/^the MC keeps (?<what>.+) at "(?<path>[^"]+)"$/, context, do: keeps(context))

  step "its database is {string}", %{args: [path]} = context do
    expected = Storage.path(context, path)
    assert HalC2.Store.home_path() == expected
    assert File.regular?(expected)
    context
  end

  step "the MC has threads, settings, provider sign-ins and secrets", context do
    context = context |> Storage.start() |> World.create_thread("Kept")
    :ok = World.merge_settings(%{"providers" => %{"grok" => %{"enabled" => false}}})
    credentials = HalC2.Acp.cursor_credentials("cursor")
    File.mkdir_p!(Path.dirname(credentials))
    File.write!(credentials, ~s({"accessToken":"cursor-sign-in"}))
    :ok = HalC2.Connect.Secrets.put("relay-token", "s3cret")

    # A downloaded tool: the registry agent "acme", installed into the cache.
    context = context |> HalC2.Test.AcpFixtures.publish() |> prepare_acme()
    assert File.dir?(Path.join([Paths.cache_dir(), "tools", "acme"]))
    Map.put(context, :archive_fetches, archive_fetches(context))
  end

  step "the user deletes {string} and restarts the MC", %{args: [path]} = context do
    File.rm_rf!(Storage.path(context, path))
    :persistent_term.erase({HalC2.Acp.Catalog, :index})
    Storage.restart(context)
  end

  step "the threads, settings, provider sign-ins and secrets are all still there", context do
    assert World.thread(context, "Kept")["title"] == "Kept"
    assert get_in(HalC2.Settings.settings(), ["providers", "grok", "enabled"]) == false
    assert File.read!(HalC2.Acp.cursor_credentials("cursor")) =~ "cursor-sign-in"
    assert HalC2.Connect.Secrets.get("relay-token") == "s3cret"
    context
  end

  step "downloaded tools are fetched again when they are next needed", context do
    refute File.exists?(Path.join([Paths.cache_dir(), "tools", "acme"]))
    context = prepare_acme(context)
    assert {:ok, _} = context.reply
    assert File.dir?(Path.join([Paths.cache_dir(), "tools", "acme"]))
    assert archive_fetches(context) == context.archive_fetches + 1
    context
  end

  # --- helpers -------------------------------------------------------------------------

  defp set_xdg(context, var, value) do
    if context.storage_user.platform == "Windows" do
      Map.update(context, :windows_env, %{var => value}, &Map.put(&1, var, value))
    else
      # Relative values stay as they are: the MC must ignore them.
      value = if String.starts_with?(value, "/"), do: Storage.path(context, value), else: value
      World.put_os_env(var, value)
      context
    end
  end

  # HAL-C2's own directory for `kind` (runtime included) as the running MC resolves it.
  defp dir(kind), do: Map.fetch!(Storage.app_dirs(), String.to_atom(kind))

  defp expected_path(context, ~s(the worktree's ") <> rest),
    do: Path.join(context.checkout, String.trim_trailing(rest, "\""))

  defp expected_path(context, ~s(") <> rest),
    do: Storage.path(context, String.trim_trailing(rest, "\""))

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)
  defp private?(dir), do: File.dir?(dir) and mode(dir) == 0o700

  defp keeps(%{args: [what, path]} = context) do
    expected = Storage.path(context, path)
    under = &String.starts_with?(&1, expected <> "/")

    case what do
      "its settings" ->
        :ok = World.merge_settings(%{"providers" => %{"grok" => %{"enabled" => false}}})
        assert File.regular?(expected)

      "its keybindings" ->
        assert HalC2.Environment.server_config()["keybindingsConfigPath"] == expected

      "its themes" ->
        Mc.ensure(HalC2.EnvironmentThemes)
        assert File.dir?(expected)

      "its database" ->
        assert HalC2.Store.home_path() == expected
        assert File.regular?(expected)

      "its environment id" ->
        assert File.read!(expected) == context.mc.environment

      "its access token" ->
        assert File.regular?(expected)

      "attachments" ->
        assert HalC2.Attachments.dir() == expected

      "browser captures" ->
        assert HalC2.Mcp.Preview.artifacts_dir() == expected

      "the worktrees it creates" ->
        assert under.(HalC2.Vcs.worktree_path("/code/app", "feature/login"))

      "installed plugins" ->
        Mc.ensure(HalC2.Settings)
        Mc.ensure(HalC2.Plugins)
        assert :sys.get_state(HalC2.Plugins).dir == expected

      "secrets" ->
        :ok = HalC2.Connect.Secrets.put("relay-token", "s3cret")
        assert File.regular?(Path.join(expected, "relay-token.bin"))

      "provider sign-ins" ->
        assert under.(HalC2.Acp.cursor_credentials("cursor"))

      "provider data" ->
        assert under.(HalC2.Acp.Antigravity.profile("antigravity"))

      "cluster membership" ->
        # The MC makes its cluster certificate when `HalC2.Cluster` starts.
        Mc.ensure(HalC2.Cluster)
        assert HalC2.Cluster.dir(Paths.data_dir()) == expected
        assert File.regular?(Path.join(expected, "mc.pem"))

      "staged upgrades" ->
        assert under.(HalC2.Upgrade.Source.cache_dir("9.9.9"))

      "scheduled tasks" ->
        Mc.ensure(HalC2.ScheduledTasks)
        assert :sys.get_state(HalC2.ScheduledTasks).path == expected

      "device hub state" ->
        assert under.(HalC2.Devices.agent_state_dir())

      logs when logs in ["server, trace and provider logs", "its logs"] ->
        assert HalC2.Environment.server_config()["observability"]["logsDirectoryPath"] == expected
        assert under.(HalC2.Traces.path())
        assert under.(HalC2.ProviderLog.path("thread-1"))

      "downloaded tools" ->
        assert under.(HalC2.Acp.Antigravity.managed_dir())

      "the ACP registry" ->
        assert Path.dirname(HalC2.Acp.Catalog.cache_path()) == expected

      "the Pi cache" ->
        assert under.(HalC2.Pi.extension_path())

      "the usage scan cache" ->
        assert HalC2.Usage.cache_path() == expected

      "model rates for usage" ->
        assert HalC2.Usage.Pricing.snapshot_path() == expected
    end

    context
  end

  defp prepare_acme(context) do
    context =
      if Map.has_key?(context.clients, "ops"),
        do: context,
        else: World.put_client(context, "ops", Mc.connect(context.mc))

    {reply, context} =
      World.call(context, "server.prepareAcpRegistryAgent", %{"agentId" => "acme"}, "ops")

    Map.put(context, :reply, reply)
  end

  defp archive_fetches(context),
    do:
      context
      |> HalC2.Test.AcpFixtures.registry_requests()
      |> Enum.count(&(&1 != "registry.json"))
end
