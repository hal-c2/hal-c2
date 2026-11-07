defmodule HalC2.ServerPasswordPropTest do
  @moduledoc """
  OpenCode server passwords (`providers.opencode.serverPassword` and an OpenCode
  instance's `config.serverPassword`) against a model of the secret store: what each
  scope holds, if anything. Clients save the document as they read it, so an untouched
  password comes back as the marker; they also type a new one, clear it, drop the key
  or the instance, and an older MC leaves one in plain text in settings.json while this
  one is stopped. Whatever happens, the document never holds a password, shows the
  marker exactly where one is stored, and reads back the stored one.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.ProviderSecrets
  alias HalC2.Settings

  @moduletag timeout: :infinity

  @marker "••••••"
  @instance "opencode-work"
  @scopes [{:provider, "opencode"}, {:instance, @instance}]

  property "server passwords live in the secret store and read back",
    numtests: HalC2.Prop.numtests(100),
    max_size: 30 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        HalC2.Prop.scratch_home("server-password")
        HalC2.Prop.start_services([Settings])
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ------------------------------------------------------------------

  # stored: each scope's password in the secret store, or nil. instance: whether the
  # OpenCode instance exists.
  def initial_state, do: %{stored: %{}, instance: false}

  def command(_state) do
    frequency([
      {6, {:call, __MODULE__, :save, [edit(), edit()]}},
      {2, {:call, __MODULE__, :drop_instance, []}},
      {2, {:call, __MODULE__, :restart_plain, [oneof(@scopes), password()]}},
      {1, {:call, __MODULE__, :restart, []}}
    ])
  end

  # What a client does to one scope's field: leaves it as read, types one, clears it,
  # or drops the key.
  defp edit, do: oneof([:as_read, {:plain, password()}, :blank, :absent])
  defp password, do: oneof(["p1", "p2", "pass word"])

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :save, [provider, instance]}) do
    state
    |> edited({:provider, "opencode"}, provider)
    |> Map.put(:instance, true)
    |> edited({:instance, @instance}, instance)
  end

  def next_state(state, _result, {:call, _, :drop_instance, []}),
    do: %{state | instance: false, stored: Map.delete(state.stored, {:instance, @instance})}

  def next_state(state, _result, {:call, _, :restart_plain, [scope, password]}),
    do: %{state | stored: Map.put(state.stored, scope, password)} |> placed(scope)

  def next_state(state, _result, {:call, _, :restart, []}), do: state

  defp edited(state, _scope, :as_read), do: state

  defp edited(state, scope, {:plain, password}),
    do: %{state | stored: Map.put(state.stored, scope, password)}

  defp edited(state, scope, _cleared), do: %{state | stored: Map.delete(state.stored, scope)}

  # A plain password for the instance brings the instance back with it.
  defp placed(state, {:instance, _}), do: %{state | instance: true}
  defp placed(state, _scope), do: state

  def postcondition(state, call, _result) do
    state = next_state(state, nil, call)
    {settings, _version} = Settings.get()

    file =
      case File.read(settings_path()) do
        {:ok, text} -> text
        _ -> ""
      end

    Enum.all?(@scopes, fn scope ->
      value = get_in(settings, keys(scope))
      stored = state.stored[scope]

      ProviderSecrets.server_password(scope, value) == stored and
        value == @marker == (stored != nil) and
        (stored == nil or not String.contains?(file, stored))
    end) and Map.has_key?(settings["providerInstances"] || %{}, @instance) == state.instance
  end

  # --- commands ---------------------------------------------------------------

  # A client's save: the document it read, with each field edited.
  def save(provider, instance) do
    {settings, version} = Settings.get()

    settings =
      settings
      |> Map.put_new("providers", %{})
      |> update_in(["providers"], &Map.put_new(&1, "opencode", %{}))
      |> Map.put_new("providerInstances", %{})
      |> update_in(
        ["providerInstances"],
        &Map.put_new(&1, @instance, %{"driver" => "opencode", "config" => %{}})
      )
      |> edit(keys({:provider, "opencode"}), provider)
      |> edit(keys({:instance, @instance}), instance)

    {:ok, _} = Settings.put(settings, version)
    :ok
  end

  def drop_instance do
    {settings, version} = Settings.get()
    instances = Map.delete(settings["providerInstances"] || %{}, @instance)
    {:ok, _} = Settings.put(Map.put(settings, "providerInstances", instances), version)
    :ok
  end

  # An older MC wrote `password` in plain text while this one was stopped.
  def restart_plain(scope, password) do
    sup = Process.get({HalC2.Prop, :services})
    :ok = Supervisor.terminate_child(sup, Settings)

    settings =
      case File.read(settings_path()) do
        {:ok, text} -> JSON.decode!(text)
        _ -> %{}
      end

    settings =
      case scope do
        {:provider, driver} ->
          settings
          |> Map.put_new("providers", %{})
          |> update_in(["providers"], &Map.put_new(&1, driver, %{}))

        {:instance, id} ->
          settings
          |> Map.put_new("providerInstances", %{})
          |> update_in(
            ["providerInstances"],
            &Map.put_new(&1, id, %{"driver" => "opencode", "config" => %{}})
          )
      end
      |> put_in(keys(scope), password)

    File.mkdir_p!(Path.dirname(settings_path()))
    File.write!(settings_path(), JSON.encode!(settings))
    {:ok, _} = Supervisor.restart_child(sup, Settings)
    :ok
  end

  def restart do
    HalC2.Prop.restart_service(Settings)
    :ok
  end

  defp edit(settings, _keys, :as_read), do: settings
  defp edit(settings, keys, {:plain, password}), do: put_in(settings, keys, password)
  defp edit(settings, keys, :blank), do: put_in(settings, keys, "")

  defp edit(settings, keys, :absent) do
    {parent, [key]} = Enum.split(keys, -1)
    update_in(settings, parent, &Map.delete(&1, key))
  end

  defp keys({:provider, driver}), do: ["providers", driver, "serverPassword"]
  defp keys({:instance, id}), do: ["providerInstances", id, "config", "serverPassword"]

  defp settings_path, do: Path.join(HalC2.Paths.config_dir(), "settings.json")
end
