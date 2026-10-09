defmodule HalC2.Plugins do
  @moduledoc """
  MC plugins: Elixir source files in `<home>/plugins/*.ex` whose modules implement
  plugin behaviours (`HalC2.Plugins.Kind`): provider adapters, MCP tool packs, git
  hosts, notification channels, text-generation backends and extensions. A module
  may implement several.

  Plugin packages (`HalC2.Plugins.Package`) are directories `<home>/plugins/<id>/`
  with a `plugin.json`: their `mc/` sources compile to at most one plugin module, a
  package without them is UI parts only, and the MC serves the package's files to
  clients (`plugins.file`). A running extension answers its UI parts
  (`plugins.call`) and pushes state to them by topic (`publish/3`).

  The directory is compiled at boot and on `plugins.rescan`; a file or package that
  changed is compiled again, and one whose new code does not load keeps the old
  code running with the failure reported. A file with no plugin module is skipped
  with a warning. A package's code is compiled only once the user let it run: one
  that is off or waits for consent is compiled when it is started.

  A plugin is off until the user enables it. What is enabled, and each plugin's
  settings, live in the MC's settings document under `plugins.<id>`
  (`%{"enabled", "settings"}`), so they survive restarts and reach every client
  with the settings push; secret fields sit in `<home>/secrets` with a marker in
  the document. An enabled plugin runs under its own supervisor: a crash restarts
  its process, and crashing more than `@max_restarts` times in `@max_seconds`
  stops it as failed with its last error until the user restarts it.

  Provider adapters (`HalC2.Plugins.ProviderAdapter`) are where turns run: the running
  ones are kept in the `HalC2.Plugins.Providers` table, which `provider/1` reads for
  every turn, and each has a sessions supervisor its thread processes run under
  (`sessions/1`), so a crash in one provider leaves the others' threads alone.
  Codex, Claude and the ACP agents are bundled (`HalC2.Plugins.Bundled`): on unless
  the user turns them off, and replaced by a plugin file with the same id.

  A plugin's manifest may ask for `permissions` (`[%{id, label}]`); enabling it
  grants them, recorded under `plugins.<id>.granted` and shown in the listing. A
  package is enabled only with every permission it asks for accepted
  (`acceptPermissions`), and waits as `awaitingConsent` when an update asks for
  more; `HalC2.Plugins.Host` refuses what was not granted.

  Watchers (`subscribe/1`) get `{:hal_c2_plugins, mc, list}` whenever the list
  changes, and topic watchers (`subscribe_topic/3`)
  `{:hal_c2_plugin_topic, mc, id, topic, value}` whenever a plugin publishes. Both,
  and what each topic last carried, live in a table that outlives a crash of this
  server (`HalC2.Heir`): clients are not told to follow again.
  """

  use GenServer
  require Logger

  alias HalC2.Plugins.Package

  # The plugin API this MC offers; a plugin's manifest names the one it was built for.
  @api_version 1
  @marker "••••••"
  @max_restarts 3
  @max_seconds 5

  @providers __MODULE__.Providers
  # `{{:list, pid}, ref}`, `{{:topic, id, topic, pid}, ref}` and `{{:last, id, topic}, value}`.
  @watchers __MODULE__.Watchers
  @heir __MODULE__.Heir

  @kinds %{
    HalC2.Plugins.ProviderAdapter => "providerAdapter",
    HalC2.Plugins.McpToolPack => "mcpToolPack",
    HalC2.Plugins.GitHost => "gitHost",
    HalC2.Plugins.NotificationChannel => "notificationChannel",
    HalC2.Plugins.TextGeneration => "textGeneration",
    HalC2.Plugins.Extension => "extension"
  }

  # The heir starts first, and a restart of it takes this server with it.
  def child_spec(_) do
    server = %{id: __MODULE__, start: {__MODULE__, :start_link, [nil]}}
    HalC2.Heir.supervise(@heir, server, HalC2.Plugins.Supervisor)
  end

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The plugin API version this MC offers."
  def api_version, do: @api_version

  # Enabling or rescanning can compile a package, which takes longer than a call does.
  @compiles 60_000

  @doc "Serves `plugins.<method>` (`HalC2.Rpc`)."
  def handle("list", _input), do: {:ok, %{"plugins" => GenServer.call(__MODULE__, :list)}}

  def handle("rescan", _input),
    do: {:ok, %{"plugins" => GenServer.call(__MODULE__, :rescan, @compiles)}}

  def handle("enable", %{"id" => id} = input) do
    case input["acceptPermissions"] || [] do
      accepted when is_list(accepted) ->
        if Enum.all?(accepted, &is_binary/1),
          do: GenServer.call(__MODULE__, {:set_enabled, id, true, accepted}, @compiles),
          else: {:error, "acceptPermissions is a list of permission ids."}

      _ ->
        {:error, "acceptPermissions is a list of permission ids."}
    end
  end

  def handle("disable", %{"id" => id}),
    do: GenServer.call(__MODULE__, {:set_enabled, id, false, []})

  def handle("restart", %{"id" => id}), do: GenServer.call(__MODULE__, {:restart, id})

  def handle("saveSettings", %{"id" => id, "settings" => %{} = settings}),
    do: GenServer.call(__MODULE__, {:save_settings, id, settings})

  # Plugin code runs in the caller, so a slow plugin holds up only its own request.
  def handle("call", %{"id" => id, "method" => method} = input) do
    with {:ok, module, context} <- GenServer.call(__MODULE__, {:context, id}) do
      case safely(fn ->
             with(
               {:ok, value} <- module.call(method, input["input"], context),
               do: {:ok, json(value)}
             )
           end) do
        {:ok, value} ->
          {:ok, value}

        {:error, message} ->
          {:error, %{"_tag" => "PluginCallFailed", "message" => "#{id}: #{text(message)}"}}

        other ->
          {:error,
           %{"_tag" => "PluginCallFailed", "message" => "#{id}: answered #{inspect(other)}"}}
      end
    end
  end

  def handle("file", %{"id" => id, "path" => path}) do
    with {:ok, dir, revision} <- GenServer.call(__MODULE__, {:file, id, path}) do
      case Package.file(dir, path, revision) do
        {:ok, file} -> {:ok, file}
        {:error, message} -> {:error, %{"_tag" => "PluginFileNotFound", "message" => message}}
      end
    end
  end

  def handle(method, _input), do: {:error, "plugins.#{method} is not served by this MC yet"}

  @doc "Sends `{:hal_c2_plugins, mc, list}` to `pid` on every change; returns the list."
  def subscribe(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})

  @doc "Stops what `subscribe/1` started."
  def unsubscribe(pid), do: GenServer.cast(__MODULE__, {:unsubscribe, pid})

  @doc """
  Sends `{:hal_c2_plugin_topic, mc, id, topic, value}` to `pid` whenever plugin `id`
  publishes on `topic`; answers `{:ok, value}` with what it last published, or nil.
  """
  def subscribe_topic(pid, id, topic),
    do: GenServer.call(__MODULE__, {:subscribe_topic, pid, id, topic})

  @doc "Stops what `subscribe_topic/3` started."
  def unsubscribe_topic(pid, id, topic),
    do: GenServer.cast(__MODULE__, {:unsubscribe_topic, pid, id, topic})

  @doc "Plugin `id` publishes `value` on `topic` (`HalC2.Plugins.Host.publish/3`)."
  def publish(id, topic, value),
    do: GenServer.cast(__MODULE__, {:publish, id, to_string(topic), json(value)})

  @doc "The permissions plugin `id` was granted."
  def granted(id), do: config(id)["granted"] || []

  @doc "Records that plugin `id` was refused a call needing `permission`."
  def denied(id, permission), do: GenServer.cast(__MODULE__, {:denied, id, permission})

  # --- contributions ------------------------------------------------------------------

  @doc """
  The tools of the running MCP tool packs, and of the running extensions granted
  `agentTools`, for an agent in `thread_id`, as MCP tool definitions.
  """
  def tools(thread_id \\ nil) do
    packs =
      for {_id, module, settings} <- running("mcpToolPack"), do: pack_tools(module, settings)

    extensions =
      for {_id, module, context} <- tool_extensions(thread_id),
          do: extension_tools(module, context)

    List.flatten(packs ++ extensions)
  end

  @doc """
  Calls a running tool pack's or extension's tool for an agent in `thread_id`:
  `{:ok, value}`, `{:error, code, message}`, or nil when no running plugin has it.
  """
  def call_tool(name, arguments, thread_id \\ nil) do
    pack =
      Enum.find_value(running("mcpToolPack"), fn {id, module, settings} ->
        if Enum.any?(pack_tools(module, settings), &(&1["name"] == name)),
          do: tool_answer(id, fn -> module.call_tool(name, arguments, settings) end)
      end)

    pack ||
      Enum.find_value(tool_extensions(thread_id), fn {id, module, context} ->
        if Enum.any?(extension_tools(module, context), &(&1["name"] == name)),
          do: tool_answer(id, fn -> module.call_agent_tool(name, arguments, context) end)
      end)
  end

  defp tool_answer(id, fun) do
    case safely(fun) do
      {:ok, value} -> {:ok, value}
      {:error, message} -> {:error, "plugin_failed", "#{id}: #{text(message)}"}
    end
  end

  # `{id, module, context}` of the running extensions that may offer agents tools.
  defp tool_extensions(thread_id) do
    for {id, module, settings} <- running("extension"),
        function_exported?(module, :agent_tools, 1),
        "agentTools" in granted(id),
        do: {id, module, %{id: id, settings: settings, thread_id: thread_id}}
  end

  defp extension_tools(module, context) do
    case safely(fn -> module.agent_tools(context) end) do
      tools when is_list(tools) -> Enum.map(tools, &json/1)
      _ -> []
    end
  end

  @doc """
  Whether plugin `id` is running on this MC. A host too busy to answer in `timeout`,
  say while it compiles a package, counts it as running, so what waits for a plugin to
  stop keeps waiting. A host that is not there has taken its plugins down with it.
  """
  def running?(id, timeout \\ 5_000) do
    GenServer.call(__MODULE__, {:running?, id}, timeout)
  catch
    :exit, {:timeout, _} -> true
    :exit, _ -> false
  end

  @doc "Whether `id` is a running text-generation backend."
  def text_backend?(id), do: Enum.any?(running("textGeneration"), &(elem(&1, 0) == id))

  @doc "A JSON object matching `schema` from the text-generation backend `id`."
  def generate(id, prompt, schema) do
    case List.keyfind(running("textGeneration"), id, 0) do
      {^id, module, settings} ->
        with {:ok, %{} = out} <- safely(fn -> module.generate(prompt, schema, settings) end),
             do: {:ok, json(out)}

      nil ->
        {:error, "The text generation plugin #{id} is not running."}
    end
  end

  @doc "The id of the running git host plugin that serves `host`, or nil."
  def git_host(host) do
    Enum.find_value(running("gitHost"), fn {id, module, settings} ->
      if safely(fn -> module.host?(host, settings) end) == true, do: id
    end)
  end

  @doc "A repository's pull requests from the git host plugin `id`."
  def pull_requests(id, repository) do
    case List.keyfind(running("gitHost"), id, 0) do
      {^id, module, settings} ->
        with {:ok, items} when is_list(items) <-
               safely(fn -> module.list_pull_requests(repository, settings) end),
             do: {:ok, Enum.map(items, &json/1)}

      nil ->
        {:error, "The git host plugin #{id} is not running."}
    end
  end

  # --- providers ----------------------------------------------------------------------

  @doc """
  The provider adapter behind a provider instance: `{:ok, driver, module}`,
  `{:missing, driver}` when no running plugin serves its driver, `:none` when no
  provider plugin runs at all, or nil when plugins are not running (the MC's
  built-in routing applies). ACP agents share the bundled "acp" adapter, and their
  driver is the instance's own id.
  """
  def provider(instance) do
    case rows() do
      nil ->
        nil

      [] ->
        :none

      rows ->
        acp = HalC2.Acp.agent?(instance)

        key =
          cond do
            acp ->
              "acp"

            driver = get_in(HalC2.Settings.settings(), ["providerInstances", instance, "driver"]) ->
              driver

            true ->
              instance
          end

        driver = if acp, do: instance, else: key

        case List.keyfind(rows, key, 0) do
          {_, adapter} -> {:ok, driver, adapter.module}
          nil -> {:missing, driver}
        end
    end
  end

  @doc """
  What the provider plugin serving `driver` declares (its manifest's `provider:`
  map), or nil for the bundled adapters, whose runtimes the core knows.
  """
  def declared(driver) do
    case rows() && List.keyfind(rows(), driver, 0) do
      {_, %{bundled: false, provider: provider}} -> provider
      _ -> nil
    end
  end

  @doc """
  The `ServerProvider` snapshots of the running provider plugins, and an
  unavailable one for each configured instance whose plugin is gone (its settings
  stay in the settings document); nil when plugins are not running.
  """
  def providers do
    case rows() do
      nil ->
        nil

      rows ->
        instances = HalC2.Settings.settings()["providerInstances"] || %{}

        running =
          rows
          |> Enum.sort_by(fn {key, adapter} -> {adapter.rank, key} end)
          |> Enum.flat_map(fn {key, adapter} -> adapter_providers(key, adapter, instances) end)

        missing =
          for {id, %{"driver" => _} = config} <- Enum.sort(instances),
              {:missing, driver} <- [provider(id)],
              do: unavailable(id, driver, config)

        running ++ missing
    end
  end

  @doc "The modules of the running provider plugins other than the bundled ones."
  def adapters, do: for({_, %{bundled: false, module: module}} <- rows() || [], do: module)

  @doc """
  The supervisor a provider's thread processes run under: the sessions supervisor
  of the plugin serving `driver`, or `HalC2.Codex.Supervisor` when there is none.
  """
  def sessions(driver) do
    with [_ | _] = rows <- rows(),
         {_, %{sup: sup}} <- List.keyfind(rows, driver, 0),
         {_, pid, _, _} when is_pid(pid) <- List.keyfind(children(sup), :sessions, 0) do
      pid
    else
      _ -> HalC2.Codex.Supervisor
    end
  end

  defp children(sup) do
    Supervisor.which_children(sup)
  catch
    :exit, _ -> []
  end

  defp rows do
    if :ets.whereis(@providers) != :undefined, do: :ets.tab2list(@providers)
  rescue
    ArgumentError -> nil
  end

  defp adapter_providers(key, adapter, instances) do
    if function_exported?(adapter.module, :providers, 1) do
      case safely(fn -> adapter.module.providers(adapter.settings) end) do
        list when is_list(list) -> Enum.map(list, &json/1)
        _ -> []
      end
    else
      configured =
        for {id, %{"driver" => ^key} = config} <- Enum.sort(instances), id != key do
          entry = HalC2.Plugins.ProviderAdapter.provider(adapter.provider, id, key)
          if name = config["displayName"], do: Map.put(entry, "displayName", name), else: entry
        end

      [HalC2.Plugins.ProviderAdapter.provider(adapter.provider, key, key) | configured]
    end
  end

  # As the TS server shows an instance whose driver this build lacks.
  defp unavailable(id, driver, config) do
    reason = "The provider plugin for \"#{driver}\" is not installed or not enabled on this MC."

    %{
      "instanceId" => id,
      "driver" => driver,
      "displayName" => config["displayName"] || driver,
      "enabled" => false,
      "installed" => false,
      "version" => nil,
      "status" => "error",
      "availability" => "unavailable",
      "unavailableReason" => reason,
      "message" => reason,
      "auth" => %{"status" => "unknown"},
      "checkedAt" => HalC2.Orchestration.Entities.now(),
      "models" => [],
      "slashCommands" => [],
      "skills" => []
    }
  end

  # --- notifications ------------------------------------------------------------------

  @doc """
  Tells the running notification channels that a turn in `thread_id` ended with
  `status`, unless a client has the thread in the foreground
  (`HalC2.BackgroundPolicy.watched?/1`).
  """
  def turn_finished(thread_id, status) do
    channels = running("notificationChannel")
    thread = fn -> thread(thread_id) end

    if channels != [] and not HalC2.BackgroundPolicy.watched?(thread_id) do
      notify(channels, %{
        "type" => "turn.finished",
        "threadId" => thread_id,
        "title" => thread.()["title"],
        "status" => status
      })
    end

    # The extension that started the thread hears of it too.
    with %{"plugin" => %{"id" => owner} = mark} <- thread.(),
         {^owner, module, settings} <- List.keyfind(running("extension"), owner, 0),
         true <- function_exported?(module, :handle_event, 2) do
      event = %{
        "type" => "turn.finished",
        "threadId" => thread_id,
        "status" => status,
        "plugin" => mark
      }

      context = %{id: owner, settings: settings, thread_id: thread_id}

      Task.start(fn ->
        with {:error, message} <- safely(fn -> module.handle_event(event, context) end),
             do:
               Logger.warning("plugin #{owner} failed handling a finished turn: #{text(message)}")
      end)
    end

    :ok
  end

  defp thread(thread_id) do
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))
    HalC2.StreamState.get(state, "thread")[thread_id] || %{}
  end

  defp notify(channels, notification) do
    for {id, module, settings} <- channels do
      case safely(fn -> module.notify(notification, settings) end) do
        {:error, message} ->
          Logger.warning("plugin #{id} did not deliver a notification: #{message}")

        _ ->
          :ok
      end
    end
  end

  # `{id, module, settings}` of the running plugins of a kind, secrets included.
  defp running(kind) do
    GenServer.call(__MODULE__, {:running, kind})
  catch
    :exit, _ -> []
  end

  defp pack_tools(module, settings) do
    case safely(fn -> module.tools(settings) end) do
      tools when is_list(tools) -> Enum.map(tools, &json/1)
      _ -> []
    end
  end

  # Plugin code runs in its caller; a plugin that raises answers an error instead.
  defp safely(fun) do
    fun.()
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, describe(reason)}
  end

  defp json(value), do: value |> JSON.encode!() |> JSON.decode!()

  defp text(message) when is_binary(message), do: message
  defp text(message), do: inspect(message)

  @doc false
  # The plugin's process, started by its supervisor (`self()`); the MC watches it for
  # crashes, and charges them only to the supervisor it is running or has just failed.
  def start_worker(id, module, settings) do
    with {:ok, pid} <- module.start_link(settings) do
      GenServer.cast(__MODULE__, {:worker, id, self(), pid})
      {:ok, pid}
    end
  end

  # --- server -------------------------------------------------------------------------

  @impl true
  def init(nil) do
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    :ets.new(@providers, [:named_table, :protected, :set, read_concurrency: true])
    :ok = HalC2.Settings.watch(self())
    dir = Path.join(HalC2.Paths.data_dir(), "plugins")

    # Watchers of the last run stay registered.
    if HalC2.Heir.claim(@heir, [@watchers]) == [],
      do: :ets.new(@watchers, [:named_table, :protected, :set] ++ HalC2.Heir.option(@heir))

    # A topic's last value has no watcher (`nil` filters it out) and stays as it was.
    for {key, _ref} <- :ets.tab2list(@watchers),
        pid = watcher(key),
        do: :ets.insert(@watchers, {key, Process.monitor(pid)})

    state = %{dir: dir, supervisor: supervisor, plugins: %{}, refs: %{}}

    {:ok, state, {:continue, :scan}}
  end

  @impl true
  # Watchers that outlived a crash are told what this run holds.
  def handle_continue(:scan, state), do: {:noreply, state |> scan() |> reconcile() |> push()}

  @impl true
  def handle_call(:list, _from, state), do: {:reply, list(state), state}

  def handle_call(:rescan, _from, state) do
    state = state |> scan() |> reconcile() |> push()
    {:reply, list(state), state}
  end

  def handle_call({:running, kind}, _from, state) do
    running =
      for {id, %{sup: sup} = plugin} <- state.plugins,
          sup != nil and kind in plugin.kinds,
          do: {id, plugin.module, settings(plugin)}

    {:reply, running, state}
  end

  def handle_call({:running?, id}, _from, state),
    do: {:reply, match?(%{sup: sup} when sup != nil, state.plugins[id]), state}

  def handle_call({:set_enabled, id, enabled, accepted}, _from, state) do
    case state.plugins[id] do
      nil ->
        {:reply, not_found(id), state}

      %{problem: {_, message}} when enabled ->
        {:reply, {:error, %{"_tag" => "PluginUnavailable", "message" => message}}, state}

      plugin ->
        requested = Enum.map(permissions(plugin), & &1["id"])
        # A package gets only what the user accepted; a plugin file what it asks for.
        missing = if plugin.package, do: requested -- (granted(id) ++ accepted), else: []

        if enabled and missing != [] do
          {:reply, {:error, consent_required(plugin, missing)}, state}
        else
          update_config(id, fn config ->
            config = Map.put(config, "enabled", enabled)
            if enabled, do: Map.put(config, "granted", requested), else: config
          end)

          plugin = %{
            plugin
            | failed: false,
              gave_up: nil,
              denied: if(enabled, do: [], else: plugin.denied)
          }

          state = put_in(state.plugins[id], plugin) |> reconcile() |> push()

          # A package compiles when it is first enabled, and may not.
          case state.plugins[id] do
            %{problem: {:load, message}} when enabled ->
              {:reply, {:error, %{"_tag" => "PluginUnavailable", "message" => message}}, state}

            plugin ->
              {:reply, {:ok, entry(plugin)}, state}
          end
        end
    end
  end

  def handle_call({:restart, id}, _from, state) do
    case state.plugins[id] do
      nil ->
        {:reply, not_found(id), state}

      plugin ->
        if runnable?(plugin) do
          state =
            state |> stop(id) |> update_in([:plugins, id], &%{&1 | failed: false, gave_up: nil})

          state = state |> reconcile() |> push()
          {:reply, {:ok, entry(state.plugins[id])}, state}
        else
          {:reply, {:error, "#{name(plugin)} is not enabled."}, state}
        end
    end
  end

  def handle_call({:save_settings, id, input}, _from, state) do
    case state.plugins[id] do
      %{module: module, package: package} = plugin when module != nil or package != nil ->
        fields = fields(plugin)
        input = Map.take(input, Enum.map(fields, & &1["key"]))
        current = config(id)["settings"] || %{}

        # The marker a secret field shows keeps what is stored for it, if anything.
        input =
          for %{"key" => key, "secret" => true} <- fields, input[key] == @marker, reduce: input do
            input -> Map.put(input, key, current[key])
          end

        # A value saved as null goes back to the field's default.
        next = current |> Map.merge(input) |> Map.reject(fn {_key, value} -> value == nil end)

        with :ok <- check_types(fields, input),
             :ok <- validate(module, Map.merge(defaults(fields), reveal(id, fields, next))) do
          update_config(id, &Map.put(&1, "settings", seal(id, fields, next)))
          # A running plugin starts again with what the user saved.
          state = if plugin.sup, do: state |> stop(id) |> reconcile(), else: state
          state = push(state)
          {:reply, {:ok, entry(state.plugins[id])}, state}
        else
          {:error, message} ->
            {:reply, {:error, %{"_tag" => "PluginSettingsInvalid", "message" => message}}, state}
        end

      _ ->
        {:reply, not_found(id), state}
    end
  end

  def handle_call({:subscribe, pid}, _from, state) do
    watch({:list, pid})
    {:reply, list(state), state}
  end

  def handle_call({:subscribe_topic, pid, id, topic}, _from, state) do
    watch({:topic, id, topic, pid})

    last =
      case :ets.lookup(@watchers, {:last, id, topic}) do
        [{_, value}] -> value
        [] -> nil
      end

    {:reply, {:ok, last}, state}
  end

  # What a plugin's MC part is called with, while it runs.
  def handle_call({:context, id}, _from, state) do
    reply =
      case state.plugins[id] do
        nil ->
          not_found(id)

        %{sup: nil} = plugin ->
          not_running(plugin)

        plugin ->
          if "extension" in plugin.kinds,
            do: {:ok, plugin.module, %{id: id, settings: settings(plugin), thread_id: nil}},
            else:
              {:error,
               %{"_tag" => "PluginCallFailed", "message" => "#{name(plugin)} answers no calls."}}
      end

    {:reply, reply, state}
  end

  # A package serves its files while it runs, and what the plugin list shows of it
  # (icon, screenshots, settings page) always.
  def handle_call({:file, id, path}, _from, state) do
    reply =
      case state.plugins[id] do
        nil ->
          not_found(id)

        %{package: nil} = plugin ->
          {:error,
           %{"_tag" => "PluginFileNotFound", "message" => "#{name(plugin)} has no files."}}

        plugin ->
          if plugin.sup != nil or path in shown_files(plugin),
            do: {:ok, plugin.files || plugin.package, revision(plugin)},
            else: not_running(plugin)
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_cast({:worker, id, sup, pid}, state) do
    if current?(state, id, sup),
      do: {:noreply, put_in(state.refs[Process.monitor(pid)], {:worker, id, sup})},
      else: {:noreply, state}
  end

  def handle_cast({:unsubscribe, pid}, state) do
    unwatch({:list, pid})
    {:noreply, state}
  end

  def handle_cast({:unsubscribe_topic, pid, id, topic}, state) do
    unwatch({:topic, id, topic, pid})
    {:noreply, state}
  end

  def handle_cast({:publish, id, topic, value}, state) do
    for [pid] <- :ets.match(@watchers, {{:topic, id, topic, :"$1"}, :_}),
        do: send(pid, {:hal_c2_plugin_topic, node(), id, topic, value})

    :ets.insert(@watchers, {{:last, id, topic}, value})
    {:noreply, state}
  end

  def handle_cast({:denied, id, permission}, state) do
    case state.plugins[id] do
      %{denied: denied} = plugin ->
        if permission in denied do
          {:noreply, state}
        else
          {:noreply,
           put_in(state.plugins[id], %{plugin | denied: denied ++ [permission]}) |> push()}
        end

      nil ->
        {:noreply, state}
    end
  end

  @impl true
  # A client may turn plugins on or off by writing the settings document itself.
  def handle_info({:hal_c2_settings, _mc, _settings}, state),
    do: {:noreply, state |> reconcile() |> push()}

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    {owner, refs} = Map.pop(state.refs, ref)
    state = %{state | refs: refs}

    case owner do
      {:worker, id, sup} when is_map_key(state.plugins, id) ->
        if not current?(state, id, sup) or reason in [:normal, :shutdown] or
             match?({:shutdown, _}, reason) do
          {:noreply, state}
        else
          state =
            update_in(
              state.plugins[id],
              # `:noproc` means the worker died before its monitor was set up
              # (its start cast lost the race), so its own reason is not known.
              &%{
                &1
                | restarts: &1.restarts + 1,
                  last_error:
                    if(reason == :noproc and &1.last_error,
                      do: &1.last_error,
                      else: describe(reason)
                    )
              }
            )

          {:noreply, push(state)}
        end

      # Only a supervisor that gave up stops without being asked.
      {:supervisor, id} when is_map_key(state.plugins, id) ->
        plugin = state.plugins[id]
        Logger.warning("plugin #{id} stopped after crashing repeatedly: #{plugin.last_error}")
        state = put_in(state.plugins[id], %{plugin | sup: nil, failed: true, gave_up: pid})
        {:noreply, state |> sync() |> push()}

      nil ->
        :ets.match_delete(@watchers, {{:list, pid}, :_})
        :ets.match_delete(@watchers, {{:topic, :_, :_, pid}, :_})
        {:noreply, state}

      _gone ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # One monitor per watched list or topic, so dropping one leaves the others.
  defp watch(key) do
    if :ets.lookup(@watchers, key) == [],
      do: :ets.insert(@watchers, {key, Process.monitor(watcher(key))})
  end

  defp unwatch(key) do
    for {_, ref} <- :ets.take(@watchers, key), do: Process.demonitor(ref, [:flush])
  end

  defp watcher({:list, pid}), do: pid
  defp watcher({:topic, _id, _topic, pid}), do: pid
  defp watcher({:last, _id, _topic}), do: nil

  # --- discovery ----------------------------------------------------------------------

  # Compiles new and changed files and packages, keeps unchanged ones, and stops
  # plugins whose file is gone or whose code was replaced.
  defp scan(state) do
    previous = Enum.group_by(Map.values(state.plugins), & &1.file)

    files =
      state.dir
      |> Path.join("*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(&load(&1, previous[&1] || []))

    # A bundled plugin stands in unless a file replaces it (an update), which then
    # counts as that bundled plugin: on by default, and run as the core knows it.
    bundled = Enum.map(HalC2.Plugins.Bundled.modules(), &bundled/1)
    ids = MapSet.new(bundled, & &1.id)

    packages =
      Enum.flat_map(Package.dirs(state.dir), &load_package(&1, previous[&1] || [], ids))

    loaded = files ++ packages
    loaded = Enum.map(loaded, &%{&1 | bundled: MapSet.member?(ids, &1.id)})
    loaded = loaded ++ Enum.reject(bundled, fn b -> Enum.any?(loaded, &(&1.id == b.id)) end)

    kept = MapSet.new(loaded, &{&1.id, &1.hash})

    state =
      Enum.reduce(state.plugins, state, fn {id, plugin}, state ->
        if MapSet.member?(kept, {id, plugin.hash}), do: state, else: stop(state, id)
      end)

    plugins =
      Map.new(loaded, fn plugin ->
        case state.plugins[plugin.id] do
          %{hash: hash} = old when hash == plugin.hash ->
            {plugin.id, %{old | reload_error: plugin.reload_error}}

          _ ->
            {plugin.id, plugin}
        end
      end)

    Enum.each(plugins, fn {id, plugin} -> revoke_dropped(id, plugin) end)
    drop_copies(plugins)
    %{state | plugins: plugins}
  end

  # A version that stops asking for a permission gives it up, so a later one that
  # asks again waits for the user like any new permission.
  defp revoke_dropped(_id, %{problem: {_, _}}), do: :ok

  defp revoke_dropped(id, plugin) do
    granted = granted(id)
    kept = Enum.filter(granted, &(&1 in Enum.map(permissions(plugin), fn p -> p["id"] end)))
    if kept != granted, do: update_config(id, &Map.put(&1, "granted", kept)), else: :ok
  end

  defp load(file, previous) do
    source = File.read!(file)
    hash = :crypto.hash(:sha256, source)

    case previous do
      [%{hash: ^hash} | _] ->
        Enum.map(previous, &%{&1 | reload_error: nil})

      _ ->
        case compile(file) do
          {:ok, modules} ->
            plugins =
              for {module, _} <- modules,
                  (kinds = kinds(module)) != [],
                  do: %{plugin(module, kinds, file, hash) | binaries: modules}

            if plugins == [],
              do:
                Logger.warning(
                  "#{Path.basename(file)} is not a plugin: none of its modules implements a plugin behaviour"
                )

            plugins

          {:error, message} ->
            failed(previous, message, fn -> blank(Path.basename(file, ".ex"), file, hash) end)
        end
    end
  end

  # A package's manifest, then its `mc/` sources, compiled in name order to at most
  # one plugin module; a package without sources is UI parts only. Compiling runs
  # the package's code, so a package compiles only once the user let it run: one
  # that is off or waits for consent compiles when it starts (`start/2`).
  defp load_package(dir, previous, bundled) do
    id = Path.basename(dir)

    case {Package.read(dir), previous} do
      {{:ok, _, _, hash}, [%{hash: hash} | _]} ->
        Enum.map(previous, &%{&1 | reload_error: nil})

      {{:error, _, hash}, [%{hash: hash} | _]} ->
        previous

      {{:ok, _, _, _}, _} ->
        copy = stage(id, dir)

        case Package.read(copy) do
          {:ok, manifest, sources, hash} ->
            plugin = %{
              blank(id, dir, hash)
              | manifest: manifest,
                sources: sources,
                package: dir,
                files: copy,
                bundled: MapSet.member?(bundled, id),
                problem: api_problem(manifest.api_version)
            }

            if runnable?(plugin), do: compile_package(plugin, previous), else: [plugin]

          {:error, message, hash} ->
            File.rm_rf(Path.dirname(copy))
            failed(previous, message, fn -> %{blank(id, dir, hash) | package: dir} end)
        end

      {{:error, message, hash}, _} ->
        failed(previous, message, fn -> %{blank(id, dir, hash) | package: dir} end)
    end
  end

  # The package compiled; when it does not, `failed/3` keeps the version that ran.
  defp compile_package(plugin, previous) do
    with {:ok, modules} <- compile_all(plugin.sources),
         {:ok, module, kinds} <- package_module(modules) |> unload_unless_ok(modules) do
      [%{plugin | module: module, kinds: kinds, binaries: modules, sources: []}]
    else
      {:error, message} -> failed(previous, message, fn -> %{plugin | sources: []} end)
    end
  end

  # A version of a package loads from a copy of its directory, which then serves its
  # files: clients get the version that runs, whatever the directory holds since.
  # Each copy sits in a directory named for the package, as the manifest's id must be.
  defp stage(id, dir) do
    copy = Path.join([copies_dir(), id, "#{System.unique_integer([:positive])}", id])
    :ok = Package.copy(dir, copy)
    copy
  end

  defp copies_dir, do: Path.join(HalC2.Paths.cache_dir(), "plugin-packages")

  # Removes the copies no loaded version serves.
  defp drop_copies(plugins) do
    kept = MapSet.new(for {_, %{files: files}} <- plugins, files != nil, do: Path.dirname(files))

    for copy <- Path.wildcard(Path.join(copies_dir(), "*/*")),
        not MapSet.member?(kept, copy),
        do: File.rm_rf(copy)
  end

  # A file or package that did not load: the version that loaded (its code, or a
  # package of UI parts only) keeps running, and the next scan tries again; without
  # one it is listed with the reason.
  defp failed(previous, message, blank) do
    case previous do
      [%{file: file} = old | _]
      when old.module != nil or (old.files != nil and old.sources == [] and old.problem == nil) ->
        Logger.warning("plugin #{Path.basename(file)} did not load: #{message}")
        restore(previous)
        Enum.map(previous, &%{&1 | reload_error: message})

      _ ->
        %{file: file} = plugin = blank.()
        Logger.warning("plugin #{Path.basename(file)} did not load: #{message}")
        [%{plugin | problem: {:load, message}}]
    end
  end

  defp compile_all(sources) do
    Enum.reduce_while(sources, {:ok, []}, fn source, {:ok, modules} ->
      case compile(source) do
        {:ok, compiled} ->
          {:cont, {:ok, modules ++ compiled}}

        {:error, message} ->
          unload(modules)
          {:halt, {:error, "mc/#{Path.basename(source)}: #{message}"}}
      end
    end)
  end

  # The modules a package compiled before one of its files failed: none of the new
  # version may run, so they are unloaded and `restore/1` loads the old ones again.
  defp unload(modules) do
    for {module, _} <- modules, :code.soft_purge(module), do: :code.delete(module)
  end

  defp unload_unless_ok({:error, _} = error, modules) do
    unload(modules)
    error
  end

  defp unload_unless_ok(ok, _modules), do: ok

  defp package_module(modules) do
    case for({module, _} <- modules, (kinds = kinds(module)) != [], do: {module, kinds}) do
      [] when modules == [] ->
        {:ok, nil, []}

      [] ->
        {:error,
         "mc/ has no module that implements a plugin behaviour, such as HalC2.Plugins.Extension."}

      [{module, kinds}] ->
        {:ok, module, kinds}

      many ->
        {:error,
         "mc/ has more than one plugin module (#{Enum.map_join(many, ", ", &inspect(elem(&1, 0)))}); a package has one."}
    end
  end

  # A module that fails to compile is unloaded, though its processes still run the
  # old code; the file's last good modules are loaded again.
  defp restore([%{file: file, binaries: binaries} | _]) do
    for {module, binary} <- binaries, :code.is_loaded(module) == false do
      :code.soft_purge(module)
      :code.load_binary(module, String.to_charlist(file), binary)
    end
  end

  defp compile(file) do
    {result, diagnostics} =
      Code.with_diagnostics([log: false], fn ->
        try do
          {:ok, Code.compile_file(file)}
        rescue
          e -> {:error, Exception.message(e)}
        end
      end)

    case {result, Enum.find(diagnostics, &(&1.severity == :error))} do
      {{:error, _}, %{message: message}} -> {:error, message}
      _ -> result
    end
  end

  defp kinds(module) do
    behaviours = Keyword.get_values(module.module_info(:attributes), :behaviour) |> List.flatten()
    for behaviour <- behaviours, kind = @kinds[behaviour], do: kind
  end

  defp plugin(module, kinds, file, hash) do
    case safely(fn -> module.manifest() end) do
      %{id: id} = manifest ->
        %{
          blank(to_string(id), file, hash)
          | module: module,
            kinds: kinds,
            manifest: manifest,
            problem: api_problem(manifest[:api_version])
        }

      other ->
        id = module |> Module.split() |> List.last() |> Macro.underscore()

        message =
          "#{inspect(module)}.manifest/0 must return a map with an id, got #{inspect(other)}"

        %{blank(id, file, hash) | kinds: kinds, problem: {:load, message}}
    end
  end

  defp api_problem(@api_version), do: nil

  defp api_problem(api) when is_integer(api) and api < @api_version,
    do:
      {:incompatible,
       "Built for plugin API #{api}, which this MC no longer offers (it offers #{@api_version})."}

  defp api_problem(api),
    do:
      {:incompatible,
       "Needs plugin API #{inspect(api)}. Update the MC first (it offers #{@api_version})."}

  defp bundled(module) do
    %{id: id} = manifest = module.manifest()

    %{
      blank(id, nil, :bundled)
      | module: module,
        kinds: ["providerAdapter"],
        manifest: manifest,
        bundled: true
    }
  end

  defp blank(id, file, hash) do
    %{
      id: id,
      file: file,
      hash: hash,
      module: nil,
      # The file's compiled modules, `{module, binary}`, to restore after a failed reload.
      binaries: [],
      kinds: [],
      manifest: %{},
      problem: nil,
      reload_error: nil,
      sup: nil,
      failed: false,
      gave_up: nil,
      restarts: 0,
      last_error: nil,
      bundled: false,
      # The package's directory, for a plugin package, and the copy of it this version
      # loaded from and serves files from.
      package: nil,
      files: nil,
      # The package's `mc/` sources while they wait to be compiled.
      sources: [],
      # The permissions host calls were refused for, since it was last enabled.
      denied: []
    }
  end

  # --- running ------------------------------------------------------------------------

  defp runnable?(plugin) do
    (plugin.module != nil or plugin.package != nil) and plugin.problem == nil and
      enabled?(plugin) and consented?(plugin)
  end

  # A package runs only with every permission it asks for granted, so an update
  # that asks for more waits for the user.
  defp consented?(%{package: nil}), do: true

  defp consented?(plugin),
    do: Enum.all?(permissions(plugin), &(&1["id"] in granted(plugin.id)))

  defp consent_required(plugin, missing) do
    labels = Enum.map_join(missing, "; ", &String.downcase(Package.permission_label(&1)))

    %{
      "_tag" => "PluginConsentRequired",
      "message" => "#{name(plugin)} needs your approval to: #{labels}.",
      "permissions" => missing
    }
  end

  defp not_running(plugin),
    do: {:error, %{"_tag" => "PluginNotRunning", "message" => "#{name(plugin)} is not running."}}

  # Bundled plugins are on until the user turns them off; others the other way round.
  defp enabled?(%{bundled: true, id: id}), do: config(id)["enabled"] != false
  defp enabled?(plugin), do: config(plugin.id)["enabled"] == true

  # Starts what is enabled and stopped (unless it failed), stops what is not enabled.
  defp reconcile(state) do
    state.plugins
    |> Enum.reduce(state, fn {id, plugin}, state ->
      cond do
        plugin.sup != nil and not runnable?(plugin) -> stop(state, id)
        plugin.sup == nil and not plugin.failed and runnable?(plugin) -> start(state, plugin)
        true -> state
      end
    end)
    |> sync()
  end

  # The running provider adapters, by the driver they serve, for `provider/1`.
  defp sync(state) do
    bundled = HalC2.Plugins.Bundled.modules()

    rows =
      for {id, %{sup: sup} = plugin} <- state.plugins,
          sup != nil and "providerAdapter" in plugin.kinds do
        provider = plugin.manifest[:provider] || %{}

        {to_string(provider[:driver] || id),
         %{
           id: id,
           module: plugin.module,
           sup: sup,
           provider: provider,
           bundled: plugin.bundled,
           settings: settings(plugin),
           rank: Enum.find_index(bundled, &(&1.manifest().id == id)) || length(bundled)
         }}
      end

    keys = MapSet.new(rows, &elem(&1, 0))
    for {key, _} <- :ets.tab2list(@providers), key not in keys, do: :ets.delete(@providers, key)
    :ets.insert(@providers, rows)
    state
  end

  defp start(state, %{sources: [_ | _]} = plugin) do
    case compile_package(plugin, []) do
      [%{problem: nil} = compiled] -> start(put_in(state.plugins[plugin.id], compiled), compiled)
      [failed] -> put_in(state.plugins[plugin.id], failed)
    end
  end

  defp start(state, plugin) do
    %{id: id, module: module} = plugin

    children =
      if module != nil and function_exported?(module, :start_link, 1),
        do: [%{id: module, start: {__MODULE__, :start_worker, [id, module, settings(plugin)]}}],
        else: []

    # A provider's thread processes (`sessions/1`).
    children =
      if "providerAdapter" in plugin.kinds,
        do: [
          %{
            id: :sessions,
            start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one]]},
            type: :supervisor
          }
          | children
        ],
        else: children

    spec = %{
      id: id,
      start:
        {Supervisor, :start_link,
         [
           children,
           [strategy: :one_for_one, max_restarts: @max_restarts, max_seconds: @max_seconds]
         ]},
      restart: :temporary,
      type: :supervisor
    }

    case DynamicSupervisor.start_child(state.supervisor, spec) do
      {:ok, sup} ->
        state = put_in(state.refs[Process.monitor(sup)], {:supervisor, id})
        put_in(state.plugins[id], %{plugin | sup: sup, failed: false, gave_up: nil})

      {:error, reason} ->
        put_in(state.plugins[id], %{plugin | failed: true, last_error: describe(reason)})
    end
  end

  # Whether `sup` is the supervisor the plugin runs, or the one that gave up and left it
  # failed (`gave_up`, until the plugin is enabled or started again); a crash reported by
  # an earlier supervisor is not this plugin's now.
  defp current?(state, id, sup) do
    case state.plugins[id] do
      %{sup: ^sup} -> true
      %{gave_up: ^sup} -> true
      _ -> false
    end
  end

  defp stop(state, id) do
    case state.plugins[id] do
      %{sup: sup} = plugin when sup != nil ->
        {refs, state} =
          Enum.split_with(state.refs, fn {_ref, owner} -> owner == {:supervisor, id} end)
          |> then(fn {mine, rest} -> {mine, %{state | refs: Map.new(rest)}} end)

        for {ref, _} <- refs, do: Process.demonitor(ref, [:flush])
        DynamicSupervisor.terminate_child(state.supervisor, sup)
        put_in(state.plugins[id], %{plugin | sup: nil})

      _ ->
        state
    end
  end

  defp describe({exception, _stack}) when is_exception(exception),
    do: Exception.message(exception)

  defp describe({:shutdown, {:failed_to_start_child, _, reason}}), do: describe(reason)
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  # --- settings -----------------------------------------------------------------------

  defp config(id), do: get_in(HalC2.Settings.settings(), ["plugins", id]) || %{}

  defp update_config(id, fun) do
    {settings, version} = HalC2.Settings.get()
    plugins = settings["plugins"] || %{}
    next = Map.put(settings, "plugins", Map.put(plugins, id, fun.(plugins[id] || %{})))

    case HalC2.Settings.put(next, version) do
      {:ok, _} -> :ok
      {:error, :stale} -> update_config(id, fun)
    end
  end

  defp fields(plugin) do
    for field <- plugin.manifest[:settings] || [] do
      %{
        "key" => to_string(field[:key]),
        "label" => field[:label] || to_string(field[:key]),
        "secret" => field[:secret] == true,
        "type" => field[:type] && to_string(field[:type]),
        "description" => field[:description],
        "default" => field[:default],
        "options" => field[:options] && json(field[:options])
      }
      |> Map.reject(fn {_key, value} -> value == nil end)
    end
  end

  defp defaults(fields),
    do: for(%{"key" => key, "default" => value} <- fields, into: %{}, do: {key, value})

  # A plugin's settings as it uses them: defaults, then what the user saved, with
  # secrets read back from the secret store.
  defp settings(plugin) do
    fields = fields(plugin)
    Map.merge(defaults(fields), reveal(plugin.id, fields, config(plugin.id)["settings"] || %{}))
  end

  # Values of the declared type; a field without one takes anything.
  defp check_types(fields, input) do
    Enum.find_value(fields, :ok, fn %{"key" => key} = field ->
      value = input[key]

      if value != nil and not Package.typed?(field, value),
        do: {:error, "#{field["label"]} (#{key}) must be #{expected(field)}."}
    end)
  end

  defp expected(%{"type" => "boolean"}), do: "on or off"
  defp expected(%{"type" => "number"}), do: "a number"
  defp expected(%{"type" => "list"}), do: "a list of text"
  defp expected(%{"type" => "choice"}), do: "one of the choices offered"
  defp expected(_field), do: "text"

  # A marker with nothing stored behind it (the document was written by hand, or came
  # from another machine) leaves the field at its default.
  defp reveal(id, fields, settings) do
    for %{"key" => key, "secret" => true} <- fields, settings[key] == @marker, reduce: settings do
      settings ->
        case File.read(secret_path(id, key)) do
          {:ok, value} -> Map.put(settings, key, value)
          {:error, _} -> Map.delete(settings, key)
        end
    end
  end

  # Secrets move to the secret store; the document keeps only that one is set.
  defp seal(id, fields, settings) do
    for %{"key" => key, "secret" => true} <- fields, reduce: settings do
      settings ->
        case settings[key] do
          @marker ->
            settings

          value when is_binary(value) and value != "" ->
            write_secret(secret_path(id, key), value)
            Map.put(settings, key, @marker)

          _ ->
            File.rm(secret_path(id, key))
            Map.delete(settings, key)
        end
    end
  end

  defp validate(module, settings) do
    if module != nil and function_exported?(module, :validate_settings, 1) do
      case safely(fn -> module.validate_settings(settings) end) do
        :ok -> :ok
        {:error, message} -> {:error, to_string(message)}
      end
    else
      :ok
    end
  end

  defp secret_path(id, key) do
    name = Base.url_encode64("#{id}/#{key}", padding: false)
    Path.join([HalC2.Paths.data_dir(), "secrets", "plugin-#{name}.bin"])
  end

  defp write_secret(path, value) do
    File.mkdir_p!(Path.dirname(path))
    File.chmod!(Path.dirname(path), 0o700)
    tmp = path <> ".tmp"
    File.write!(tmp, value)
    File.chmod!(tmp, 0o600)
    File.rename!(tmp, path)
  end

  # --- listing ------------------------------------------------------------------------

  defp list(state),
    do: state.plugins |> Map.values() |> Enum.sort_by(& &1.id) |> Enum.map(&entry/1)

  defp entry(plugin) do
    config = config(plugin.id)

    enabled = enabled?(plugin)
    package = plugin.manifest[:package] || %{}

    status =
      case plugin.problem do
        {:load, _} -> "error"
        {:incompatible, _} -> "incompatible"
        nil when plugin.sup != nil -> "running"
        nil when plugin.failed -> "failed"
        nil when enabled -> if consented?(plugin), do: "disabled", else: "awaitingConsent"
        nil -> "disabled"
      end

    %{
      "id" => plugin.id,
      "name" => name(plugin),
      "version" => plugin.manifest[:version],
      "kind" => List.first(plugin.kinds),
      "kinds" => plugin.kinds,
      "apiVersion" => plugin.manifest[:api_version],
      "file" => plugin.file && Path.basename(plugin.file),
      "source" =>
        cond do
          plugin.package -> "package"
          plugin.file -> "file"
          true -> "bundled"
        end,
      "description" => plugin.manifest[:description],
      "author" => package["author"],
      "homepage" => package["homepage"],
      "license" => package["license"],
      "icon" => package["icon"],
      "screenshots" => package["screenshots"] || [],
      "contributes" => package["contributes"] || %{},
      "runsCode" => (plugin.module != nil or plugin.sources != []) and not plugin.bundled,
      "denied" => plugin.denied,
      "revision" => revision(plugin),
      "enabled" => enabled,
      "status" => status,
      "error" => with({_, message} <- plugin.problem, do: message),
      "reloadError" => plugin.reload_error,
      "lastError" => plugin.last_error,
      "restarts" => plugin.restarts,
      "settingsSchema" => fields(plugin),
      "settings" => Map.merge(defaults(fields(plugin)), config["settings"] || %{}),
      "permissions" =>
        for(
          permission <- permissions(plugin),
          do: Map.put(permission, "granted", permission["id"] in (config["granted"] || []))
        )
    }
    |> Map.merge(provider_entry(plugin))
  end

  defp permissions(plugin) do
    for permission <- plugin.manifest[:permissions] || [] do
      %{
        "id" => to_string(permission[:id]),
        "label" => permission[:label] || to_string(permission[:id]),
        "reason" => permission[:reason]
      }
      |> Map.reject(fn {_key, value} -> value == nil end)
    end
  end

  # What the plugin list shows of a package, served even while it is off.
  defp shown_files(plugin) do
    package = plugin.manifest[:package] || %{}

    [
      package["icon"],
      get_in(package, ["contributes", "settingsPage"])
      | Enum.map(package["screenshots"] || [], & &1["path"])
    ]
    |> Enum.filter(&is_binary/1)
  end

  # Changes whenever the plugin's files change.
  defp revision(%{hash: hash}) when is_binary(hash),
    do: hash |> Base.encode16(case: :lower) |> binary_part(0, 16)

  defp revision(_plugin), do: nil

  # What a provider plugin declares for clients that have never heard of it.
  defp provider_entry(%{manifest: manifest} = plugin) do
    if "providerAdapter" in plugin.kinds do
      provider = manifest[:provider] || %{}

      %{
        "provider" => %{
          "driver" => to_string(provider[:driver] || plugin.id),
          "capabilities" => Enum.map(provider[:capabilities] || [], &to_string/1),
          "instanceSettings" =>
            for field <- provider[:instance_settings] || [] do
              %{
                "key" => to_string(field[:key]),
                "label" => field[:label] || to_string(field[:key]),
                "secret" => field[:secret] == true
              }
            end
        }
      }
    else
      %{}
    end
  end

  defp name(plugin), do: plugin.manifest[:name] || plugin.id

  defp not_found(id),
    do: {:error, %{"_tag" => "PluginNotFound", "message" => "No plugin #{id} is installed."}}

  defp push(state) do
    list = list(state)

    for [pid] <- :ets.match(@watchers, {{:list, :"$1"}, :_}),
        do: send(pid, {:hal_c2_plugins, node(), list})

    state
  end
end
