defmodule HalC2.Settings do
  @moduledoc """
  This node's `ServerSettings`, kept in `<home>/settings.json` (owner-only, since
  provider environments can hold secrets).

  The node stores the document; it does not interpret patches. A client applies a
  `server.updateSettings` patch with the shared `applyServerSettingsPatch` to the
  version it read and writes the whole result back with `put/2`, which refuses a
  stale version so concurrent editors retry instead of overwriting each other.
  Watchers (client sockets) get `{:hal_c2_settings, node, settings}` on every change,
  and `{:hal_c2_providers_changed, node}` when something else changes the node's
  provider list (`notify_providers/0`).

  Another process may edit the file too (`mix hal_c2.theme`), so it is checked every
  couple of seconds and a change is pushed to watchers like a `put/2`.

  Reads come from a table the server keeps current, not from a call: nearly every
  service reads settings, and a server slow to answer (a machine deep in swap) would
  otherwise time them all out at once and exhaust the node's restart budget.

  Hub management keys never stay in the document: `HalC2.UsageLimitSources.seal_keys/2`
  moves them to the secret store on every write, so nothing a client reads carries one.
  """

  use GenServer

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
  over the environment's values, as the Node server resolves them. A model
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

    for %{"name" => name, "value" => value} <- entry["environment"] || [],
        is_binary(name) and is_binary(value),
        into: %{},
        do: {name, value}
  end

  @doc "`{settings, version}`."
  def get do
    :ets.lookup_element(__MODULE__, :settings, 2)
  rescue
    # A node started without settings (tests, tools) has defaults.
    ArgumentError -> {%{}, 0}
  end

  @doc "Replaces the document if it is still at `version`; returns the new version."
  def put(settings, version), do: GenServer.call(__MODULE__, {:put, settings, version})

  def watch(pid) do
    GenServer.call(__MODULE__, {:watch, pid})
  catch
    :exit, {:noproc, _} -> :ok
  end

  def unwatch(pid), do: GenServer.cast(__MODULE__, {:unwatch, pid})

  @doc """
  Saves `fun.(settings)` as one step, whatever the version. Without a running
  settings server (a mix task beside a live node) it edits settings.json
  directly, keeping keys it does not know; the node's file check picks it up.
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

  @doc "Tells watchers this node now runs another version (`HalC2.Upgrade`)."
  def notify_upgraded(outcome), do: GenServer.cast(__MODULE__, {:upgraded, outcome})

  @doc "Tells watchers the published themes changed (`HalC2.EnvironmentThemes`)."
  def notify_themes(themes), do: GenServer.cast(__MODULE__, {:themes_changed, themes})

  @doc "Tells watchers the usage-limit source snapshots changed (`HalC2.UsageLimitSources`)."
  def notify_usage_limit_sources(sources),
    do: GenServer.cast(__MODULE__, {:usage_limit_sources_changed, sources})

  @doc "Tells watchers the keybinding rules changed (`HalC2.Keybindings`)."
  def notify_keybindings(rules), do: GenServer.cast(__MODULE__, {:keybindings_changed, rules})

  @impl true
  def init(nil) do
    path = path()

    settings =
      case read(path) do
        {:ok, settings} ->
          settings

        {:error, reason} ->
          Logger.warning("ignoring unreadable #{path}: #{inspect(reason)}")
          %{}
      end

    # A key written in plain text (by hand, or before keys were sealed) moves out now.
    {settings, changed} = HalC2.UsageLimitSources.seal_keys(settings, %{})
    if changed, do: write!(path, settings)
    schedule_check()

    :ets.new(__MODULE__, [:named_table, :protected, read_concurrency: true])
    publish(settings, 0)

    {:ok, %{path: path, settings: settings, version: 0, watchers: %{}, stamp: stamp(path)}}
  end

  @doc "The document as settings.json holds it, for tools running beside a node."
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

  # Writes rename a new file into place, so the inode changes with every save.
  defp stamp(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> {stat.inode, stat.size, stat.mtime}
      _ -> nil
    end
  end

  @impl true
  def handle_call({:put, settings, version}, _from, %{version: version} = state) do
    state = save(state, settings, true)
    {:reply, {:ok, state.version}, state}
  end

  def handle_call({:update, fun}, _from, state) do
    state = save(state, fun.(state.settings), true)
    {:reply, {:ok, state.version}, state}
  end

  def handle_call({:put, _settings, _version}, _from, state),
    do: {:reply, {:error, :stale}, state}

  def handle_call({:watch, pid}, _from, state) do
    watchers = Map.put_new_lazy(state.watchers, pid, fn -> Process.monitor(pid) end)
    {:reply, :ok, %{state | watchers: watchers}}
  end

  @impl true
  def handle_cast(:providers_changed, state) do
    for {pid, _} <- state.watchers, do: send(pid, {:hal_c2_providers_changed, node()})
    {:noreply, state}
  end

  def handle_cast({:keybindings_changed, rules}, state) do
    for {pid, _} <- state.watchers, do: send(pid, {:hal_c2_keybindings, node(), rules})
    {:noreply, state}
  end

  def handle_cast({:usage_limit_sources_changed, sources}, state) do
    for {pid, _} <- state.watchers, do: send(pid, {:hal_c2_usage_limit_sources, node(), sources})
    {:noreply, state}
  end

  def handle_cast({:upgraded, outcome}, state) do
    for {pid, _} <- state.watchers, do: send(pid, {:hal_c2_upgraded, node(), outcome})
    {:noreply, state}
  end

  def handle_cast({:themes_changed, themes}, state) do
    for {pid, _} <- state.watchers, do: send(pid, {:hal_c2_themes, node(), themes})
    {:noreply, state}
  end

  def handle_cast({:unwatch, pid}, state) do
    {ref, watchers} = Map.pop(state.watchers, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:noreply, %{state | watchers: watchers}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, %{state | watchers: Map.delete(state.watchers, pid)}}

  # The file changed under the node: adopt it unless it is unreadable.
  def handle_info(:check, state) do
    schedule_check()
    stamp = stamp(state.path)

    with true <- stamp != state.stamp,
         {:ok, settings} when settings != state.settings <- read(state.path) do
      {:noreply, save(state, settings, false)}
    else
      _ -> {:noreply, %{state | stamp: stamp}}
    end
  end

  defp save(state, settings, write?) do
    {settings, keys_changed} = HalC2.UsageLimitSources.seal_keys(settings, state.settings)
    if write? or keys_changed, do: write!(state.path, settings)

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

    publish(settings, state.version + 1)
    for {pid, _} <- state.watchers, do: send(pid, {:hal_c2_settings, node(), settings})

    %{
      state
      | settings: settings,
        version: state.version + 1,
        stamp: stamp(state.path)
    }
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
