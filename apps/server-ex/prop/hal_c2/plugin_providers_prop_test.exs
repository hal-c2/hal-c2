defmodule HalC2.PluginProvidersPropTest do
  @moduledoc """
  The provider instances plugins add (`HalC2.Plugins.Host.provider_instances/3`, needing
  `providers:configure`) against a model of the plugins and the instances each holds.

  Commands install a package that asks for `providers:configure` or not (a new version
  each time, so an update that drops it is revoked and one that adds it waits for
  consent), remove it from disk, turn it on accepting what it asks for, turn it off, put
  and remove instances from its code (as a plugin that has not stopped yet would, too),
  list them, and delete one as the user does in Settings → Providers.

  After every step, once the host has heard the settings change:

  - the settings document's `plugin_*` instances are exactly the model's, each belonging
    to a plugin that is installed, on and granted `providers:configure`, and the user's
    own instance is as it was;
  - a plugin lists only its own instances, and is refused without the permission.
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
    numtests: HalC2.Prop.numtests(100),
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
  # instances: the `plugin_*` instances the settings document holds. version: the next
  # package version.
  def initial_state do
    %{
      plugins:
        Map.new(@ids, &{&1, %{installed: false, asks: false, enabled: false, granted: false}}),
      instances: %{},
      version: 1
    }
  end

  def command(state) do
    id = elements(@ids)
    name = elements(@names)

    frequency([
      {3, {:call, __MODULE__, :install, [id, boolean(), state.version]}},
      {1, {:call, __MODULE__, :uninstall, [id]}},
      {3, {:call, __MODULE__, :enable, [id]}},
      {2, {:call, __MODULE__, :disable, [id]}},
      {5, {:call, __MODULE__, :put, [id, name, elements(@labels)]}},
      {2, {:call, __MODULE__, :remove, [id, name]}},
      {2, {:call, __MODULE__, :list, [id]}}
      | for(
          instance_id <- [Map.keys(state.instances)],
          instance_id != [],
          do: {6, {:call, __MODULE__, :user_delete, [elements(instance_id)]}}
        )
    ])
  end

  def precondition(state, {:call, _, :user_delete, [instance_id]}),
    do: Map.has_key?(state.instances, instance_id)

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
    if state.plugins[id].granted,
      do: put_in(state.instances[instance_id(id, name)], instance(label)) |> settle(),
      else: state
  end

  def next_state(state, _result, {:call, _, :remove, [id, name]}) do
    if state.plugins[id].granted,
      do: %{state | instances: Map.delete(state.instances, instance_id(id, name))},
      else: state
  end

  def next_state(state, _result, {:call, _, :user_delete, [instance_id]}),
    do: %{state | instances: Map.delete(state.instances, instance_id)}

  def next_state(state, _result, {:call, _, :list, _}), do: state

  def postcondition(state, {:call, _, :put, [id, name, _label]} = call, result) do
    answered(state, id, result, &(&1 == {:ok, %{"instanceId" => instance_id(id, name)}})) and
      agrees(next_state(state, result, call))
  end

  def postcondition(state, {:call, _, :remove, [id, name]} = call, result) do
    removed = Map.has_key?(state.instances, instance_id(id, name))

    answered(state, id, result, &(&1 == {:ok, %{"removed" => removed}})) and
      agrees(next_state(state, result, call))
  end

  def postcondition(state, {:call, _, :list, [id]}, result) do
    own =
      for {instance_id, instance} <- Enum.sort(state.instances),
          {^id, name} <- [Host.instance_owner(instance_id)],
          do: %{"name" => name, "instanceId" => instance_id, "instance" => instance}

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

  def user_delete(instance_id) do
    HalC2.Settings.update(fn settings ->
      Map.update!(settings, "providerInstances", &Map.delete(&1, instance_id))
    end)

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
    {theirs, users} = Map.split_with(all, fn {id, _} -> Host.instance_owner(id) != nil end)

    cond do
      theirs != state.instances -> mismatch({:instances, theirs, state.instances})
      users != %{@user_id => @users} -> mismatch({:users, users})
      true -> true
    end
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

    instances =
      Map.filter(state.instances, fn {instance_id, _} ->
        elem(Host.instance_owner(instance_id), 0) in allowed
      end)

    %{state | instances: instances}
  end

  defp update_plugin(state, id, fun), do: update_in(state.plugins[id], fun)
  defp instance_id(id, name), do: "plugin_#{id}_#{name}"
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
