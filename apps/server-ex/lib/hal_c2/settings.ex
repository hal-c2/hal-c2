defmodule HalC2.Settings do
  @moduledoc """
  This MC's `ServerSettings`, kept in `<home>/settings.json` (owner-only, since
  provider environments can hold secrets).

  The MC stores the document; it does not interpret patches. A client applies a
  `server.updateSettings` patch with the shared `applyServerSettingsPatch` to the
  version it read and writes the whole result back with `put/2`, which refuses a
  stale version so concurrent editors retry instead of overwriting each other.
  Watchers (client sockets) get `{:hal_c2_settings, mc, settings}` on every change,
  and `{:hal_c2_providers_changed, mc}` when something else changes the MC's
  provider list (`notify_providers/0`).

  Another process may edit the file too (`mix hal_c2.theme`), so it is checked every
  couple of seconds and a change is pushed to watchers like a `put/2`.

  Reads come from a table the server keeps current, not from a call: nearly every
  service reads settings, and a server slow to answer (a machine deep in swap) would
  otherwise time them all out at once and exhaust the MC's restart budget.

  Hub management keys and sensitive provider variables never stay in the document:
  `HalC2.UsageLimitSources.seal_keys/2` and `HalC2.ProviderSecrets.seal/2` move them to
  the secret store on every write, so nothing a client reads carries one.

  The settings that belong to the person rather than the machine
  (`HalC2.Settings.Shared`) follow them across their cluster. Each carries a stamp in
  `<home>/settings-shared.json`, written after settings.json so an MC that knows
  nothing of it reads and writes the document as before. A change made here, by a
  client or in the file, is stamped when it is saved, and one made while the MC was
  down (or ran a version without stamps) when it starts, at the file's time. Members
  send their stamps through `HalC2.Cluster`, and a newer one is saved here like a
  `put/2`: watchers hear of it and the version moves on, so a client writing what it
  read before it is refused as stale.
  """

  use GenServer

  alias HalC2.Settings.Shared

  require Logger

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The settings document (`%{}` when never written; clients fill in defaults)."
  def settings, do: elem(get(), 0)

  # The keys a project may override (`ProjectSettingsOverrides`).
  @project_scoped ~w(worktreeCleanup defaultModelSelection defaultRuntimeMode defaultThreadEnvMode
                     newWorktreesStartFromOrigin worktreeSubmodules defaultAutoPull
                     defaultProjectScripts enableAgentBrowserAccess enableAgentDeviceAccess
                     textGenerationModelSelection sourceControlWriterModelSelection
                     sourceControlWritingStyle pullRequestMergeMethod sidebarAutoSettleOnMerge
                     sidebarAutoSettleAfterDays continueThreadsAfterServerUpdate
                     responseStreamingMode)

  @doc """
  The settings as they apply to one project: its `projectSettingsOverrides` entry
  over the environment's values. A model
  override on a disabled provider falls back to the environment's.
  """
  def for_project(project_id), do: resolve(settings(), project_id)

  @doc false
  def resolve(settings, project_id) do
    overrides = get_in(settings, ["projectSettingsOverrides", project_id]) || %{}

    Enum.reduce(overrides, settings, fn {key, value}, acc ->
      cond do
        key not in @project_scoped ->
          acc

        key in ~w(textGenerationModelSelection defaultModelSelection) and is_map(value) and
            not provider_enabled?(settings, value["instanceId"]) ->
          acc

        true ->
          Map.put(acc, key, value)
      end
    end)
  end

  defp provider_enabled?(settings, instance) do
    case get_in(settings, ["providerInstances", instance]) do
      %{} = config -> config["enabled"] != false
      nil -> get_in(settings, ["providers", instance, "enabled"]) != false
    end
  end

  @doc "The variables set on provider instance `instance` in settings, as a map."
  def instance_env(instance) do
    entry = (settings()["providerInstances"] || %{})[instance] || %{}
    Map.new(HalC2.ProviderSecrets.environment(instance, entry))
  end

  @doc """
  A driver setting of provider instance `instance`, such as Codex's `launchArgs`: its
  own `config` value, else its driver's in `providers.<driver>`. A blank string counts
  as unset.
  """
  def instance_setting(instance, key) do
    settings = settings()
    entry = get_in(settings, ["providerInstances", instance]) || %{}

    Enum.find(
      [
        get_in(entry, ["config", key]),
        get_in(settings, ["providers", entry["driver"] || instance, key])
      ],
      &(is_binary(&1) and String.trim(&1) != "")
    )
  end

  @doc """
  The command that runs provider instance `instance`: `default`, with the instance's
  `binaryPath` setting in place of its executable when it has one. A path the user wrote
  as `~/bin/codex` names their home directory, as a shell would.
  """
  def instance_command(instance, [_executable | args] = default) do
    case instance_setting(instance, "binaryPath") do
      nil ->
        default

      path ->
        case String.trim(path) do
          "~" -> [HalC2.Paths.user_home() | args]
          "~/" <> rest -> [Path.join(HalC2.Paths.user_home(), rest) | args]
          path -> [path | args]
        end
    end
  end

  def instance_command(_instance, default), do: default

  @doc "Whether `instance` is `driver`'s built-in instance or one settings add for it."
  def known_instance?(instance, driver),
    do:
      instance == driver or
        match?(%{"driver" => ^driver}, (settings()["providerInstances"] || %{})[instance])

  @doc "The ids of the instances settings add for `driver`, besides its built-in one."
  def instances_of(driver) do
    for {id, %{"driver" => ^driver}} <- Enum.sort(settings()["providerInstances"] || %{}),
        id != driver,
        do: id
  end

  @doc """
  Whether instance `instance` of `driver` is on: its own `enabled`, and for the
  built-in instance the driver's in `providers.<driver>`.
  """
  def instance_enabled?(instance, driver) do
    settings = settings()

    if instance == driver,
      do: get_in(settings, ["providers", driver, "enabled"]) != false,
      else: get_in(settings, ["providerInstances", instance, "enabled"]) != false
  end

  @doc """
  The provider entry of an instance whose `binaryPath` setting names nothing that
  runs, or nil when it has no such setting: a provider that is simply not on this
  machine is not listed, one the user pointed somewhere is, so the path can be fixed.
  """
  def not_installed_entry(instance, driver, name) do
    if path = instance_setting(instance, "binaryPath") do
      %{
        "instanceId" => instance,
        "driver" => driver,
        "enabled" => instance_enabled?(instance, driver),
        "installed" => false,
        "version" => nil,
        "status" => "error",
        "availability" => "available",
        "message" => "#{name} was not found at #{String.trim(path)}.",
        "auth" => %{"status" => "unknown"},
        "checkedAt" => HalC2.Orchestration.Entities.now(),
        "models" => [],
        "slashCommands" => [],
        "skills" => []
      }
    end
  end

  @doc """
  What makes `settings` unusable, as a `ServerSettingsError`, or `:ok`. The MC keeps
  the document as clients write it, except for a provider variable no process could
  be given: its name has to be one a shell accepts (`ProviderInstanceEnvironmentVariableName`).
  """
  def validate(settings) do
    invalid =
      for {id, %{"environment" => variables}} when is_list(variables) <-
            Enum.sort(settings["providerInstances"] || %{}),
          %{"name" => name} when is_binary(name) <- variables,
          String.trim(name) != "",
          not (name =~ ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/) or String.length(name) > 128,
          do: {id, name}

    case invalid do
      [] ->
        :ok

      [{id, name} | _] ->
        {:error,
         %{
           "_tag" => "ServerSettingsError",
           "settingsPath" => path(),
           "operation" => "normalize",
           "providerInstanceId" => id,
           "environmentVariable" => name,
           "message" =>
             "\"#{name}\" is not a valid environment variable name: use letters, digits and " <>
               "underscores, not starting with a digit."
         }}
    end
  end

  @doc "`{settings, version}`."
  def get do
    :ets.lookup_element(__MODULE__, :settings, 2)
  rescue
    # An MC started without settings (tests, tools) has defaults.
    ArgumentError -> {%{}, 0}
  end

  @doc "Replaces the document if it is still at `version`; returns the new version."
  def put(settings, version), do: GenServer.call(__MODULE__, {:put, settings, version})

  def watch(pid, ref \\ nil) do
    GenServer.call(__MODULE__, {:watch, pid, ref})
  catch
    :exit, {:noproc, _} -> :ok
  end

  def unwatch(pid, ref \\ nil), do: GenServer.cast(__MODULE__, {:unwatch, pid, ref})

  @doc """
  Saves `fun.(settings)` as one step, whatever the version. Without a running
  settings server (a mix task beside a live MC) it edits settings.json
  directly, keeping keys it does not know; the MC's file check picks it up.
  """
  def update(fun) do
    GenServer.call(__MODULE__, {:update, fun})
  catch
    :exit, {:noproc, _} ->
      path = path()

      case read(path) do
        {:ok, settings} ->
          write!(path, fun.(settings))
          :ok

        {:error, reason} ->
          {:error,
           "Could not read #{path} (#{inspect(reason)}). Fix or remove it, then run this again."}
      end
  end

  @doc "Tells watchers to read the provider list again, such as after a model probe."
  def notify_providers, do: GenServer.cast(__MODULE__, :providers_changed)

  @doc "Tells watchers this MC now runs another version (`HalC2.Upgrade`)."
  def notify_upgraded(outcome), do: GenServer.cast(__MODULE__, {:upgraded, outcome})

  @doc "Tells watchers the published themes changed (`HalC2.EnvironmentThemes`)."
  def notify_themes(themes), do: GenServer.cast(__MODULE__, {:themes_changed, themes})

  @doc "Tells watchers the usage-limit source snapshots changed (`HalC2.UsageLimitSources`)."
  def notify_usage_limit_sources(sources),
    do: GenServer.cast(__MODULE__, {:usage_limit_sources_changed, sources})

  @doc "Tells watchers the keybinding rules changed (`HalC2.Keybindings`)."
  def notify_keybindings(rules), do: GenServer.cast(__MODULE__, {:keybindings_changed, rules})

  @doc "The stamped records of the shared settings (`HalC2.Settings.Shared`), for members."
  def shared_records do
    :ets.lookup_element(__MODULE__, :shared, 2)
  rescue
    ArgumentError -> %{}
  end

  @doc """
  Takes up the shared-settings records a member sent (`HalC2.Cluster`): each newer than
  this MC's is saved here, and any change is passed on to the members.
  """
  def merge_shared(records), do: GenServer.cast(__MODULE__, {:merge_shared, records})

  @impl true
  def init(nil) do
    path = path()

    {settings, held} =
      case read(path) do
        {:ok, settings} ->
          {settings, false}

        {:error, reason} ->
          Logger.warning("ignoring unreadable #{path}: #{inspect(reason)}")
          {%{}, true}
      end

    # A key written in plain text (by hand, or before keys were sealed) moves out now.
    {settings, changed} = HalC2.UsageLimitSources.seal_keys(settings, %{})
    {settings, secrets_changed} = HalC2.ProviderSecrets.seal(settings, settings)
    if changed or secrets_changed, do: write!(path, settings)
    schedule_check()

    :ets.new(__MODULE__, [:named_table, :protected, read_concurrency: true])
    publish(settings, 0)

    state = %{
      path: path,
      settings: settings,
      version: 0,
      watchers: %{},
      stamp: stamp(path),
      id: HalC2.Environment.id(),
      shared: read_shared(),
      held: held
    }

    {:ok, start_shared(state)}
  end

  # The records of what changed while this MC was not running, stamped at the time
  # their file changed. A document that cannot be read holds nothing to compare, and
  # until it can be (`held`) nothing a member sends is saved over it. A missing file is
  # a machine starting over, not a reset to tell the members: it forgets its records
  # and learns the shared settings from them.
  defp start_shared(state) do
    shared =
      cond do
        state.held ->
          state.shared

        not File.exists?(state.path) ->
          Map.drop(state.shared, Shared.document_keys())

        true ->
          local_shared(state.shared, state.settings, Shared.document_keys(), state, state.path)
      end

    file = HalC2.Keybindings.path()

    shared =
      if File.exists?(file),
        do:
          local_shared(
            shared,
            keybindings(HalC2.Keybindings.rules()),
            ["keybindings"],
            state,
            file
          ),
        else: Map.delete(shared, "keybindings")

    if shared != state.shared, do: write!(shared_path(), shared)
    :ets.insert(__MODULE__, {:shared, shared})
    %{state | shared: shared}
  end

  # `records` with a local write for each of `units` whose value in `values` is not the
  # one its record holds, stamped now, or at `file`'s time when given.
  defp local_shared(records, values, units, state, file \\ nil) do
    at =
      case file && File.stat(file, time: :posix) do
        {:ok, %{mtime: seconds}} -> seconds * 1000
        _ -> System.os_time(:millisecond)
      end

    Shared.local(records, values, units, Shared.stamp(records, at), state.id)
  end

  defp keybindings([]), do: %{}
  defp keybindings(rules), do: %{"keybindings" => rules}

  defp shared_path, do: Path.join(HalC2.Paths.config_dir(), "settings-shared.json")

  defp read_shared do
    with {:ok, text} <- File.read(shared_path()),
         {:ok, records} <- JSON.decode(text) do
      Shared.sanitize(records)
    else
      _ -> %{}
    end
  end

  # Saves, publishes and tells the members the records, after whatever they stamp has
  # been written: a crash in between then reads as a local edit of the new value.
  defp put_shared(state, shared) when shared == state.shared, do: state

  defp put_shared(state, shared) do
    write!(shared_path(), shared)
    :ets.insert(__MODULE__, {:shared, shared})
    HalC2.Cluster.share_settings()
    %{state | shared: shared}
  end

  @doc "The document as settings.json holds it, for tools running beside an MC."
  def saved, do: read(path())

  defp path, do: Path.join(HalC2.Paths.config_dir(), "settings.json")

  defp read(path) do
    with {:ok, text} <- File.read(path),
         {:ok, %{} = settings} <- JSON.decode(text) do
      {:ok, settings}
    else
      {:error, :enoent} -> {:ok, %{}}
      {:ok, _not_an_object} -> {:error, :not_an_object}
      {:error, reason} -> {:error, reason}
    end
  end

  defp schedule_check do
    case Application.get_env(:hal_c2, :settings_check_ms, 2_000) do
      nil -> :ok
      ms -> Process.send_after(self(), :check, ms)
    end
  end

  # The file's contents, hashed. Its inode, size and mtime (in whole seconds) miss an
  # editor that rewrites it in place to the same size within the second.
  defp stamp(path) do
    case File.read(path) do
      {:ok, text} -> :erlang.md5(text)
      _ -> nil
    end
  end

  @impl true
  def handle_call({:put, settings, version}, _from, %{version: version} = state),
    do: save_reply(state, fn -> settings end)

  # `fun` is a caller's: a crash in it must not take the table every service reads with it.
  def handle_call({:update, fun}, _from, state),
    do: save_reply(state, fn -> fun.(state.settings) end)

  def handle_call({:put, _settings, _version}, _from, state),
    do: {:reply, {:error, :stale}, state}

  def handle_call({:watch, pid, ref}, _from, state) do
    watchers = HalC2.Watchers.add(state.watchers, pid, ref)
    {:reply, :ok, %{state | watchers: watchers}}
  end

  @impl true
  def handle_cast(:providers_changed, state) do
    HalC2.Watchers.notify(state.watchers, {:hal_c2_providers_changed, node()})
    {:noreply, state}
  end

  def handle_cast({:keybindings_changed, rules}, state) do
    HalC2.Watchers.notify(state.watchers, {:hal_c2_keybindings, node(), rules})

    {:noreply,
     put_shared(state, local_shared(state.shared, keybindings(rules), ["keybindings"], state))}
  end

  def handle_cast({:merge_shared, _records}, %{held: true} = state), do: {:noreply, state}

  def handle_cast({:merge_shared, records}, state) do
    merged = Shared.merge(state.shared, Shared.sanitize(records))

    if merged == state.shared do
      {:noreply, state}
    else
      # The rules file is written before the record that stamps it, like settings.json.
      if merged["keybindings"] != state.shared["keybindings"] do
        rules = merged["keybindings"]["value"] || []
        if rules != HalC2.Keybindings.rules(), do: HalC2.Keybindings.replace(rules)
      end

      settings = Shared.apply(state.settings, merged)

      if settings == state.settings,
        do: {:noreply, put_shared(state, merged)},
        else: {:noreply, save(state, settings, true, merged)}
    end
  end

  def handle_cast({:usage_limit_sources_changed, sources}, state) do
    HalC2.Watchers.notify(state.watchers, {:hal_c2_usage_limit_sources, node(), sources})
    {:noreply, state}
  end

  def handle_cast({:upgraded, outcome}, state) do
    HalC2.Watchers.notify(state.watchers, {:hal_c2_upgraded, node(), outcome})
    {:noreply, state}
  end

  def handle_cast({:themes_changed, themes}, state) do
    HalC2.Watchers.notify(state.watchers, {:hal_c2_themes, node(), themes})
    {:noreply, state}
  end

  def handle_cast({:unwatch, pid, ref}, state) do
    watchers = HalC2.Watchers.remove(state.watchers, pid, ref)
    {:noreply, %{state | watchers: watchers}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, %{state | watchers: Map.delete(state.watchers, pid)}}

  # The file changed under the MC: adopt it unless it is unreadable.
  def handle_info(:check, state) do
    schedule_check()
    stamp = stamp(state.path)

    with true <- stamp != state.stamp,
         {:ok, settings} when settings != state.settings or state.held <- read(state.path) do
      # A deleted file is a machine starting over, as at start (`start_shared/1`).
      shared =
        if stamp == nil,
          do: Map.drop(state.shared, Shared.document_keys()),
          else: state.shared

      {:noreply, save(state, settings, false, shared)}
    else
      _ -> {:noreply, %{state | stamp: stamp}}
    end
  end

  # Saves what `settings.()` returns and replies with the new version. A document that
  # cannot be built or written is refused with the reason and nothing changes.
  defp save_reply(state, settings) do
    state = save(state, settings.(), true)
    {:reply, {:ok, state.version}, state}
  rescue
    exception -> {:reply, {:error, Exception.message(exception)}, state}
  catch
    kind, reason -> {:reply, {:error, Exception.format_banner(kind, reason)}, state}
  end

  # `shared` is what the records are before this document's shared keys are compared
  # with them: a member's newer records, saved together with the keys they change.
  defp save(state, settings, write?, shared \\ nil) do
    {settings, keys_changed} = HalC2.UsageLimitSources.seal_keys(settings, state.settings)
    {settings, secrets_changed} = HalC2.ProviderSecrets.seal(settings, state.settings)
    if write? or keys_changed or secrets_changed, do: write!(state.path, settings)

    state =
      put_shared(
        state,
        local_shared(shared || state.shared, settings, Shared.document_keys(), state)
      )

    # Published before anything below reacts, so what it reads is the new settings.
    publish(settings, state.version + 1)

    if keys_changed or settings["usageLimitSources"] != state.settings["usageLimitSources"],
      do: HalC2.UsageLimitSources.refresh_async()

    # OpenCode read from another server (or from none) is a different inventory.
    server =
      &((get_in(&1, ["providers", "opencode"]) || %{})
        |> Map.take(["serverUrl", "serverPassword"]))

    if server.(settings) != server.(state.settings), do: HalC2.Acp.forget("opencode")

    # Pi run from another binary or with other launch arguments is read again.
    pi = &((get_in(&1, ["providers", "pi"]) || %{}) |> Map.take(["binaryPath", "launchArgs"]))
    if pi.(settings) != pi.(state.settings), do: HalC2.Acp.forget("pi")

    muse = &get_in(&1, ["providers", "muse", "binaryPath"])
    if muse.(settings) != muse.(state.settings), do: HalC2.Acp.forget("muse")

    # So is an added instance whose driver, or own or driver's binaryPath, changed
    # (HalC2.Acp.binary_path/1).
    binaries = fn settings ->
      for {id, %{} = entry} <- settings["providerInstances"] || %{}, into: %{} do
        {id,
         {entry["driver"], get_in(entry, ["config", "binaryPath"]),
          get_in(settings, ["providers", entry["driver"] || id, "binaryPath"])}}
      end
    end

    {old, new} = {binaries.(state.settings), binaries.(settings)}

    for id <- Enum.uniq(Map.keys(old) ++ Map.keys(new)),
        old[id] != new[id],
        do: HalC2.Acp.forget(id)

    HalC2.Watchers.notify(state.watchers, {:hal_c2_settings, node(), settings})

    %{
      state
      | settings: settings,
        version: state.version + 1,
        stamp: stamp(state.path),
        held: false
    }
  end

  # A settings process updated in place (`HalC2.Hot`) does not run `init/1` again, so one
  # from before shared settings takes up their records here.
  @impl true
  def code_change(_old, %{shared: _} = state, _extra), do: {:ok, state}

  def code_change(_old, state, _extra) do
    state = Map.merge(state, %{id: HalC2.Environment.id(), shared: read_shared(), held: false})
    {:ok, start_shared(state)}
  end

  defp publish(settings, version), do: :ets.insert(__MODULE__, {:settings, {settings, version}})

  # Written to a temporary file and renamed, so a crash never leaves half a file.
  defp write!(path, settings) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    File.write!(tmp, JSON.encode_to_iodata!(settings))
    File.chmod!(tmp, 0o600)
    File.rename!(tmp, path)
  end
end
