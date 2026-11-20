defmodule HalC2.PluginProvidersPropTest do
  @moduledoc """
  The provider instances plugins add (`HalC2.Plugins.Host.provider_instances/3`, needing
  `providers:configure`) against a model of the plugins and the instances each holds.

  Commands install a package that asks for `providers:configure` or not (a new version
  each time, so an update that drops it is revoked and one that adds it waits for
  consent), remove it from disk, turn it on accepting what it asks for, turn it off, put
  and remove instances from its code (as a plugin that has not stopped yet would, too),
  list them, and add or delete one as the user does in Settings → Providers, the user's
  under the very ids the plugins use too (`plugin_alpha_claude`, `plugin_x_y`). The user
  also puts one of their own in place of a plugin's as a client does, from the document
  it read, in two saves before the host hears of either.

  After every step, once the host has heard the settings change:

  - the settings document's instances are exactly the model's: the plugins', each
    belonging to a plugin that is installed, on and granted `providers:configure`, and
    the user's, as the user left them;
  - a plugin lists only the instances it added, is refused a put under an id the user
    has, and is refused everything without the permission.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Plugins
  alias HalC2.Plugins.Host

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @ids ["alpha", "beta"]
  @names ["claude", "codex"]
  @labels ["Via the proxy", "Via the proxy, again"]
  @permission "providers:configure"
  @user_id "claude-work"
  @user_ids [@user_id, "plugin_x_y"] ++
              for(id <- @ids, name <- @names, do: "plugin_#{id}_#{name}")
  @users %{"driver" => "claudeAgent", "displayName" => "Claude at work", "enabled" => true}

  setup do
    saved =
      for key <- [:bundled_plugins, :settings_check_ms],
          do: {key, Application.fetch_env(:hal_c2, key)}

    on_exit(fn ->
      for {key, value} <- saved do
        case value do
          {:ok, value} -> Application.put_env(:hal_c2, key, value)
          :error -> Application.delete_env(:hal_c2, key)
        end
      end
    end)
  end

  property "a plugin's provider instances are its own, and leave with it",
    numtests: HalC2.Prop.numtests(500),
    max_size: 40 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        start()
        {history, state, result} = run_commands(__MODULE__, cmds)
        problems = Process.get({__MODULE__, :problems})
        HalC2.Prop.stop_services()

        (result == :ok)
        |> when_fail(
          IO.puts("""
          #{HalC2.Prop.report(cmds, history, state, result)}
          Mismatches:
          #{inspect(problems, pretty: true, limit: :infinity)}
          """)
        )
        |> aggregate(command_names(cmds))
      end
    end
  end

  defp start do
    Process.delete({__MODULE__, :problems})
    Application.put_env(:hal_c2, :settings_check_ms, nil)
    Application.put_env(:hal_c2, :bundled_plugins, [])
    HalC2.Prop.scratch_home("plugin-providers")
    File.mkdir_p!(plugins_dir())
    HalC2.Prop.start_services([HalC2.Settings, Plugins])
    sync()

    HalC2.Settings.update(&Map.put(&1, "providerInstances", %{@user_id => @users}))

    sync()
  end

  # --- model ------------------------------------------------------------------

  # plugins: per id `%{installed, asks, enabled, granted}` (`enabled` and `granted` are
  # its `plugins.<id>` of the settings document, which outlives the package on disk).
  # instances: the plugins' instances the settings document holds, by `{id, name}`.
  # users: the user's, by instance id. version: the next package version.
  def initial_state do
    %{
      plugins:
        Map.new(@ids, &{&1, %{installed: false, asks: false, enabled: false, granted: false}}),
      instances: %{},
      users: %{@user_id => @users},
      version: 1
    }
  end

  def command(state) do
    id = elements(@ids)
    name = elements(@names)

    theirs = Enum.map(Map.keys(state.instances), &instance_id/1)

    frequency(
      [
        {3, {:call, __MODULE__, :install, [id, boolean(), state.version]}},
        {1, {:call, __MODULE__, :uninstall, [id]}},
        {3, {:call, __MODULE__, :enable, [id]}},
        {2, {:call, __MODULE__, :disable, [id]}},
        {5, {:call, __MODULE__, :put, [id, name, elements(@labels)]}},
        {2, {:call, __MODULE__, :remove, [id, name]}},
        {2, {:call, __MODULE__, :list, [id]}},
        {2, {:call, __MODULE__, :user_add, [elements(@user_ids)]}}
      ] ++
        if(held(state) != [],
          do: [{6, {:call, __MODULE__, :user_delete, [elements(held(state))]}}],
          else: []
        ) ++
        if(theirs != [],
          do: [{20, {:call, __MODULE__, :user_replace, [elements(theirs)]}}],
          else: []
        )
    )
  end

  # The user adds an instance under an id nothing holds.
  def precondition(state, {:call, _, :user_add, [instance_id]}),
    do: instance_id not in held(state)

  def precondition(state, {:call, _, :user_delete, [instance_id]}),
    do: instance_id in held(state)

  def precondition(state, {:call, _, :user_replace, [instance_id]}),
    do: Enum.any?(Map.keys(state.instances), &(instance_id(&1) == instance_id))

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :install, [id, asks, version]}) do
    state
    |> update_plugin(id, fn plugin ->
      %{plugin | installed: true, asks: asks, granted: plugin.granted and asks}
    end)
    |> Map.put(:version, version + 1)
    |> settle()
  end

  def next_state(state, _result, {:call, _, :uninstall, [id]}),
    do: state |> update_plugin(id, &%{&1 | installed: false}) |> settle()

  def next_state(state, _result, {:call, _, :enable, [id]}) do
    if state.plugins[id].installed,
      do: state |> update_plugin(id, &%{&1 | enabled: true, granted: &1.asks}) |> settle(),
      else: state
  end

  def next_state(state, _result, {:call, _, :disable, [id]}) do
    if state.plugins[id].installed,
      do: state |> update_plugin(id, &%{&1 | enabled: false}) |> settle(),
      else: state
  end

  def next_state(state, _result, {:call, _, :put, [id, name, label]}) do
    if state.plugins[id].granted and not users?(state, id, name),
      do: put_in(state.instances[{id, name}], instance(label)) |> settle(),
      else: state
  end

  def next_state(state, _result, {:call, _, :remove, [id, name]}) do
    if state.plugins[id].granted,
      do: %{state | instances: Map.delete(state.instances, {id, name})},
      else: state
  end

  def next_state(state, _result, {:call, _, :user_add, [instance_id]}),
    do: put_in(state.users[instance_id], @users)

  def next_state(state, _result, {:call, _, :user_delete, [instance_id]}) do
    %{
      state
      | instances:
          Map.reject(state.instances, fn {key, _} -> instance_id(key) == instance_id end),
        users: Map.delete(state.users, instance_id)
    }
  end

  def next_state(state, result, {:call, _, :user_replace, [instance_id]}) do
    state
    |> next_state(result, {:call, __MODULE__, :user_delete, [instance_id]})
    |> next_state(result, {:call, __MODULE__, :user_add, [instance_id]})
  end

  def next_state(state, _result, {:call, _, :list, _}), do: state

  def postcondition(state, {:call, _, :put, [id, name, _label]} = call, result) do
    answer =
      if users?(state, id, name),
        do: &match?({:error, "plugin_" <> _}, &1),
        else: &(&1 == {:ok, %{"instanceId" => instance_id({id, name})}})

    answered(state, id, result, answer) and agrees(next_state(state, result, call))
  end

  def postcondition(state, {:call, _, :remove, [id, name]} = call, result) do
    removed = Map.has_key?(state.instances, {id, name})

    answered(state, id, result, &(&1 == {:ok, %{"removed" => removed}})) and
      agrees(next_state(state, result, call))
  end

  def postcondition(state, {:call, _, :list, [id]}, result) do
    own =
      for {{^id, name} = key, instance} <- Enum.sort(state.instances),
          do: %{"name" => name, "instanceId" => instance_id(key), "instance" => instance}

    answered(state, id, result, &(&1 == {:ok, %{"instances" => own}})) and agrees(state)
  end

  def postcondition(state, call, result), do: agrees(next_state(state, result, call))

  # --- commands ---------------------------------------------------------------

  def install(id, asks, version) do
    dir = Path.join(plugins_dir(), id)
    File.rm_rf!(dir)
    File.mkdir_p!(Path.join(dir, "mc"))
    permissions = if asks, do: [@permission, "threads:read"], else: ["threads:read"]

    File.write!(
      Path.join(dir, "plugin.json"),
      JSON.encode!(%{
        "id" => id,
        "name" => "Prop #{id}",
        "version" => "1.0.#{version}",
        "apiVersion" => 1,
        "description" => "A package the property installs.",
        "permissions" => for(p <- permissions, do: %{"id" => p, "reason" => "The property."})
      })
    )

    File.write!(Path.join(dir, "mc/prop.ex"), """
    defmodule HalC2PluginProp.Providers#{Macro.camelize(id)} do
      @behaviour HalC2.Plugins.Extension
      @impl true
      def call(_method, _input, _context), do: {:ok, %{}}
    end
    """)

    Plugins.rescan()
    sync()
  end

  def uninstall(id) do
    File.rm_rf!(Path.join(plugins_dir(), id))
    Plugins.rescan()
    sync()
  end

  def enable(id) do
    asked =
      case File.read(Path.join([plugins_dir(), id, "plugin.json"])) do
        {:ok, json} -> for %{"id" => p} <- JSON.decode!(json)["permissions"], do: p
        _ -> []
      end

    result = Plugins.handle("enable", %{"id" => id, "acceptPermissions" => asked})
    sync()
    result
  end

  def disable(id) do
    result = Plugins.handle("disable", %{"id" => id})
    sync()
    result
  end

  def put(id, name, label) do
    result = Host.provider_instances(id, "put", %{"name" => name, "instance" => instance(label)})
    sync()
    result
  end

  def remove(id, name) do
    result = Host.provider_instances(id, "remove", %{"name" => name})
    sync()
    result
  end

  def list(id), do: Host.provider_instances(id, "list", %{})

  def user_add(instance_id) do
    HalC2.Settings.update(
      &put_in(&1, [Access.key("providerInstances", %{}), instance_id], @users)
    )

    sync()
  end

  def user_delete(instance_id) do
    HalC2.Settings.update(fn settings ->
      Map.update!(settings, "providerInstances", &Map.delete(&1, instance_id))
    end)

    sync()
  end

  # As a client saves: the document it read, without the instance, then with one of the
  # user's in its place, the host's record still as read.
  def user_replace(instance_id) do
    {read, version} = HalC2.Settings.get()

    {:ok, version} =
      HalC2.Settings.put(
        Map.update!(read, "providerInstances", &Map.delete(&1, instance_id)),
        version
      )

    {:ok, _} =
      HalC2.Settings.put(put_in(read, ["providerInstances", instance_id], @users), version)

    sync()
  end

  # --- checks -----------------------------------------------------------------

  defp answered(state, id, result, ok?) do
    if state.plugins[id].granted,
      do: ok?.(result) or mismatch({:answer, id, result}),
      else:
        match?({:error, "was not granted" <> _}, refusal(id, result)) or
          mismatch({:answer, id, result})
  end

  defp agrees(state) do
    all = HalC2.Settings.settings()["providerInstances"] || %{}
    theirs = Map.new(state.instances, fn {key, instance} -> {instance_id(key), instance} end)

    if all == Map.merge(state.users, theirs),
      do: true,
      else: mismatch({:instances, all, theirs, state.users})
  end

  defp refusal(id, {:error, message}), do: {:error, String.replace_prefix(message, id <> " ", "")}
  defp refusal(_id, result), do: result

  defp mismatch(problem) do
    Process.put({__MODULE__, :problems}, [problem | Process.get({__MODULE__, :problems}, [])])
    false
  end

  # --- helpers ----------------------------------------------------------------

  # The host takes out the instances of every plugin not installed, on and granted.
  defp settle(state) do
    allowed = for {id, p} <- state.plugins, p.installed and p.enabled and p.granted, do: id

    %{state | instances: Map.filter(state.instances, fn {{id, _}, _} -> id in allowed end)}
  end

  defp held(state),
    do: Map.keys(state.users) ++ Enum.map(Map.keys(state.instances), &instance_id/1)

  defp users?(state, id, name), do: Map.has_key?(state.users, instance_id({id, name}))
  defp update_plugin(state, id, fun), do: update_in(state.plugins[id], fun)
  defp instance_id({id, name}), do: "plugin_#{id}_#{name}"
  defp instance(label), do: %{"driver" => "claudeAgent", "displayName" => label}
  defp plugins_dir, do: Path.join(HalC2.Paths.data_dir(), "plugins")

  # The host hears a settings change, and the change its own pruning makes.
  defp sync do
    :sys.get_state(HalC2.Settings)
    :sys.get_state(Plugins)
    :sys.get_state(HalC2.Settings)
    :sys.get_state(Plugins)
    :ok
  end
end
