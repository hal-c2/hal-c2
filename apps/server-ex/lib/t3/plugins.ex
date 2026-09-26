defmodule T3.Plugins do
  @moduledoc """
  Node plugins: Elixir source files in `<home>/plugins/*.ex` whose modules implement
  one of the plugin behaviours (`T3.Plugins.Kind`): provider adapters, MCP tool
  packs, git hosts, notification channels and text-generation backends.

  The directory is compiled at boot and on `plugins.rescan`; a file that changed is
  compiled again, and a file whose new code does not load keeps the old code
  running with the failure reported. A file with no plugin module is skipped with a
  warning.

  A plugin is off until the user enables it. What is enabled, and each plugin's
  settings, live in the node's settings document under `plugins.<id>`
  (`%{"enabled", "settings"}`), so they survive restarts and reach every client
  with the settings push; secret fields sit in `<home>/secrets` with a marker in
  the document. An enabled plugin runs under its own supervisor: a crash restarts
  its process, and crashing more than `@max_restarts` times in `@max_seconds`
  stops it as failed with its last error until the user restarts it.

  Watchers (`subscribe/1`) get `{:t3_plugins, node, list}` whenever the list changes.
  """

  use GenServer
  require Logger

  # The plugin API this node offers; a plugin's manifest names the one it was built for.
  @api_version 1
  @marker "••••••"
  @max_restarts 3
  @max_seconds 5

  @kinds %{
    T3.Plugins.ProviderAdapter => "providerAdapter",
    T3.Plugins.McpToolPack => "mcpToolPack",
    T3.Plugins.GitHost => "gitHost",
    T3.Plugins.NotificationChannel => "notificationChannel",
    T3.Plugins.TextGeneration => "textGeneration"
  }

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The plugin API version this node offers."
  def api_version, do: @api_version

  @doc "Serves `plugins.<method>` (`T3.Rpc`)."
  def handle("list", _input), do: {:ok, %{"plugins" => GenServer.call(__MODULE__, :list)}}
  def handle("rescan", _input), do: {:ok, %{"plugins" => GenServer.call(__MODULE__, :rescan)}}
  def handle("enable", %{"id" => id}), do: GenServer.call(__MODULE__, {:set_enabled, id, true})
  def handle("disable", %{"id" => id}), do: GenServer.call(__MODULE__, {:set_enabled, id, false})
  def handle("restart", %{"id" => id}), do: GenServer.call(__MODULE__, {:restart, id})

  def handle("saveSettings", %{"id" => id, "settings" => %{} = settings}),
    do: GenServer.call(__MODULE__, {:save_settings, id, settings})

  def handle(method, _input), do: {:error, "plugins.#{method} is not served by this node yet"}

  @doc "Sends `{:t3_plugins, node, list}` to `pid` on every change; returns the list."
  def subscribe(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})

  # --- contributions ------------------------------------------------------------------

  @doc "The tools of the running MCP tool packs, as MCP tool definitions."
  def tools do
    for {_id, module, settings} <- running("mcpToolPack"),
        tool <- pack_tools(module, settings),
        do: tool
  end

  @doc """
  Calls a running tool pack's tool: `{:ok, value}`, `{:error, code, message}`, or
  nil when no running pack has it.
  """
  def call_tool(name, arguments) do
    Enum.find_value(running("mcpToolPack"), fn {id, module, settings} ->
      if Enum.any?(pack_tools(module, settings), &(&1["name"] == name)) do
        case safely(fn -> module.call_tool(name, arguments, settings) end) do
          {:ok, value} -> {:ok, value}
          {:error, message} -> {:error, "plugin_failed", "#{id}: #{message}"}
        end
      end
    end)
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

  # `{id, module, settings}` of the running plugins of a kind, secrets included.
  defp running(kind) do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, {:running, kind}), else: []
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

  @doc false
  # The plugin's process, started by its supervisor; the node watches it for crashes.
  def start_worker(id, module, settings) do
    with {:ok, pid} <- module.start_link(settings) do
      GenServer.cast(__MODULE__, {:worker, id, pid})
      {:ok, pid}
    end
  end

  # --- server -------------------------------------------------------------------------

  @impl true
  def init(nil) do
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    :ok = T3.Settings.watch(self())
    dir = Path.join(Application.fetch_env!(:t3, :home), "plugins")

    state = %{dir: dir, supervisor: supervisor, plugins: %{}, refs: %{}, watchers: %{}}
    {:ok, state, {:continue, :scan}}
  end

  @impl true
  def handle_continue(:scan, state), do: {:noreply, state |> scan() |> reconcile()}

  @impl true
  def handle_call(:list, _from, state), do: {:reply, list(state), state}

  def handle_call(:rescan, _from, state) do
    state = state |> scan() |> reconcile() |> push()
    {:reply, list(state), state}
  end

  def handle_call({:running, kind}, _from, state) do
    running =
      for {id, %{kind: ^kind, sup: sup} = plugin} <- state.plugins,
          sup != nil,
          do: {id, plugin.module, settings(plugin)}

    {:reply, running, state}
  end

  def handle_call({:set_enabled, id, enabled}, _from, state) do
    case state.plugins[id] do
      nil ->
        {:reply, not_found(id), state}

      %{problem: {_, message}} when enabled ->
        {:reply, {:error, %{"_tag" => "PluginUnavailable", "message" => message}}, state}

      plugin ->
        update_config(id, &Map.put(&1, "enabled", enabled))
        state = put_in(state.plugins[id], %{plugin | failed: false}) |> reconcile() |> push()
        {:reply, {:ok, entry(state.plugins[id])}, state}
    end
  end

  def handle_call({:restart, id}, _from, state) do
    case state.plugins[id] do
      nil ->
        {:reply, not_found(id), state}

      plugin ->
        if runnable?(plugin) do
          state = state |> stop(id) |> update_in([:plugins, id], &%{&1 | failed: false})
          state = state |> reconcile() |> push()
          {:reply, {:ok, entry(state.plugins[id])}, state}
        else
          {:reply, {:error, "#{name(plugin)} is not enabled."}, state}
        end
    end
  end

  def handle_call({:save_settings, id, input}, _from, state) do
    case state.plugins[id] do
      %{module: module} = plugin when module != nil ->
        fields = fields(plugin)
        current = config(id)["settings"] || %{}
        next = Map.merge(current, Map.take(input, Enum.map(fields, & &1["key"])))

        case validate(module, reveal(id, fields, next)) do
          :ok ->
            update_config(id, &Map.put(&1, "settings", seal(id, fields, next)))
            # A running plugin starts again with what the user saved.
            state = if plugin.sup, do: state |> stop(id) |> reconcile(), else: state
            state = push(state)
            {:reply, {:ok, entry(state.plugins[id])}, state}

          {:error, message} ->
            {:reply, {:error, %{"_tag" => "PluginSettingsInvalid", "message" => message}}, state}
        end

      _ ->
        {:reply, not_found(id), state}
    end
  end

  def handle_call({:subscribe, pid}, _from, state) do
    watchers = Map.put_new_lazy(state.watchers, pid, fn -> Process.monitor(pid) end)
    {:reply, list(state), %{state | watchers: watchers}}
  end

  @impl true
  def handle_cast({:worker, id, pid}, state) do
    {:noreply, put_in(state.refs[Process.monitor(pid)], {:worker, id})}
  end

  @impl true
  # A client may turn plugins on or off by writing the settings document itself.
  def handle_info({:t3_settings, _node, _settings}, state),
    do: {:noreply, state |> reconcile() |> push()}

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    {owner, refs} = Map.pop(state.refs, ref)
    state = %{state | refs: refs}

    case owner do
      {:worker, id} when is_map_key(state.plugins, id) ->
        if reason in [:normal, :shutdown] or match?({:shutdown, _}, reason) do
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
        state = put_in(state.plugins[id], %{plugin | sup: nil, failed: true})
        {:noreply, push(state)}

      nil ->
        {:noreply, %{state | watchers: Map.delete(state.watchers, pid)}}

      _gone ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- discovery ----------------------------------------------------------------------

  # Compiles new and changed files, keeps unchanged ones, and stops plugins whose
  # file is gone or whose code was replaced.
  defp scan(state) do
    previous = Enum.group_by(Map.values(state.plugins), & &1.file)

    loaded =
      state.dir
      |> Path.join("*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(&load(&1, previous[&1] || []))

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

    %{state | plugins: plugins}
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
                  kind = kind(module),
                  do: %{plugin(module, kind, file, hash) | binaries: modules}

            if plugins == [],
              do:
                Logger.warning(
                  "#{Path.basename(file)} is not a plugin: none of its modules implements a plugin behaviour"
                )

            plugins

          {:error, message} ->
            Logger.warning("plugin #{Path.basename(file)} did not load: #{message}")

            case previous do
              # The old code keeps running; the next scan tries the file again.
              [%{module: module} | _] when module != nil ->
                restore(previous)
                Enum.map(previous, &%{&1 | reload_error: message})

              _ ->
                id = Path.basename(file, ".ex")
                [%{blank(id, file, hash) | problem: {:load, message}}]
            end
        end
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

  defp kind(module) do
    behaviours = Keyword.get_values(module.module_info(:attributes), :behaviour) |> List.flatten()
    Enum.find_value(behaviours, &@kinds[&1])
  end

  defp plugin(module, kind, file, hash) do
    case safely(fn -> module.manifest() end) do
      %{id: id} = manifest ->
        api = manifest[:api_version]

        problem =
          cond do
            api == @api_version ->
              nil

            is_integer(api) and api < @api_version ->
              {:incompatible,
               "Built for plugin API #{api}, which this node no longer offers (it offers #{@api_version})."}

            true ->
              {:incompatible,
               "Needs plugin API #{inspect(api)}. Update the node first (it offers #{@api_version})."}
          end

        %{
          blank(to_string(id), file, hash)
          | module: module,
            kind: kind,
            manifest: manifest,
            problem: problem
        }

      other ->
        id = module |> Module.split() |> List.last() |> Macro.underscore()

        message =
          "#{inspect(module)}.manifest/0 must return a map with an id, got #{inspect(other)}"

        %{blank(id, file, hash) | kind: kind, problem: {:load, message}}
    end
  end

  defp blank(id, file, hash) do
    %{
      id: id,
      file: file,
      hash: hash,
      module: nil,
      # The file's compiled modules, `{module, binary}`, to restore after a failed reload.
      binaries: [],
      kind: nil,
      manifest: %{},
      problem: nil,
      reload_error: nil,
      sup: nil,
      failed: false,
      restarts: 0,
      last_error: nil
    }
  end

  # --- running ------------------------------------------------------------------------

  defp runnable?(plugin),
    do: plugin.module != nil and plugin.problem == nil and config(plugin.id)["enabled"] == true

  # Starts what is enabled and stopped (unless it failed), stops what is not enabled.
  defp reconcile(state) do
    Enum.reduce(state.plugins, state, fn {id, plugin}, state ->
      cond do
        plugin.sup != nil and not runnable?(plugin) -> stop(state, id)
        plugin.sup == nil and not plugin.failed and runnable?(plugin) -> start(state, plugin)
        true -> state
      end
    end)
  end

  defp start(state, plugin) do
    %{id: id, module: module} = plugin

    children =
      if function_exported?(module, :start_link, 1),
        do: [%{id: module, start: {__MODULE__, :start_worker, [id, module, settings(plugin)]}}],
        else: []

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
        put_in(state.plugins[id], %{plugin | sup: sup, failed: false})

      {:error, reason} ->
        put_in(state.plugins[id], %{plugin | failed: true, last_error: describe(reason)})
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

  defp config(id), do: get_in(T3.Settings.settings(), ["plugins", id]) || %{}

  defp update_config(id, fun) do
    {settings, version} = T3.Settings.get()
    plugins = settings["plugins"] || %{}
    next = Map.put(settings, "plugins", Map.put(plugins, id, fun.(plugins[id] || %{})))

    case T3.Settings.put(next, version) do
      {:ok, _} -> :ok
      {:error, :stale} -> update_config(id, fun)
    end
  end

  defp fields(plugin) do
    for field <- plugin.manifest[:settings] || [] do
      %{
        "key" => to_string(field[:key]),
        "label" => field[:label] || to_string(field[:key]),
        "secret" => field[:secret] == true
      }
    end
  end

  # A plugin's settings as it uses them: secrets read back from the secret store.
  defp settings(plugin),
    do: reveal(plugin.id, fields(plugin), config(plugin.id)["settings"] || %{})

  defp reveal(id, fields, settings) do
    for %{"key" => key, "secret" => true} <- fields, settings[key] == @marker, reduce: settings do
      settings -> Map.put(settings, key, File.read!(secret_path(id, key)))
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
    if function_exported?(module, :validate_settings, 1) do
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
    Path.join([Application.fetch_env!(:t3, :home), "secrets", "plugin-#{name}.bin"])
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

    status =
      case plugin.problem do
        {:load, _} -> "error"
        {:incompatible, _} -> "incompatible"
        nil when plugin.sup != nil -> "running"
        nil when plugin.failed -> "failed"
        nil -> "disabled"
      end

    %{
      "id" => plugin.id,
      "name" => name(plugin),
      "version" => plugin.manifest[:version],
      "kind" => plugin.kind,
      "apiVersion" => plugin.manifest[:api_version],
      "file" => Path.basename(plugin.file),
      "enabled" => config["enabled"] == true,
      "status" => status,
      "error" => with({_, message} <- plugin.problem, do: message),
      "reloadError" => plugin.reload_error,
      "lastError" => plugin.last_error,
      "restarts" => plugin.restarts,
      "settingsSchema" => fields(plugin),
      "settings" => config["settings"] || %{}
    }
  end

  defp name(plugin), do: plugin.manifest[:name] || plugin.id

  defp not_found(id),
    do: {:error, %{"_tag" => "PluginNotFound", "message" => "No plugin #{id} is installed."}}

  defp push(state) do
    list = list(state)
    for {pid, _} <- state.watchers, do: send(pid, {:t3_plugins, node(), list})
    state
  end
end
