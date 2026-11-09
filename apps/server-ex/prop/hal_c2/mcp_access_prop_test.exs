defmodule HalC2.McpAccessPropTest do
  @moduledoc """
  `HalC2.Mcp.agent_access/1` and `for_agent/2` against a model of the settings: what a
  thread's agent may reach (the browser, which gates the whole server, and devices) is
  its project's override where it has one, else the environment's, read as the
  settings stand when the session is prepared, whatever was prepared before.

  No sidebar runs, so no thread has a row: that is how a new thread's first turn finds
  it, before the shell projects it. A thread its stream does not know yet follows the
  environment.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  @moduletag timeout: :infinity

  @projects %{"t-a" => "p-a", "t-b" => "p-b"}
  @keys %{"preview" => "enableAgentBrowserAccess", "device" => "enableAgentDeviceAccess"}

  property "a thread's agent reaches what its project allows",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("mcp-access")

        HalC2.Prop.start_services([
          {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
          HalC2.Streams,
          HalC2.Settings,
          HalC2.Mcp
        ])

        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- the real thing --------------------------------------------------------------

  def launch(thread) do
    {:ok, _} =
      HalC2.Streams.commit(thread, :thread, [
        {"thread", thread, %{"s" => %{"id" => thread, "projectId" => @projects[thread]}}}
      ])

    :ok
  end

  # `value` nil drops the key, so the default applies.
  def set(scope, capability, value) do
    {settings, version} = HalC2.Settings.get()
    path = if scope == :env, do: [@keys[capability]], else: [scope, @keys[capability]]
    overrides = settings["projectSettingsOverrides"] || %{}

    settings =
      case {scope, value} do
        {:env, nil} ->
          Map.delete(settings, @keys[capability])

        {:env, value} ->
          Map.put(settings, @keys[capability], value)

        {_, nil} ->
          put_in(settings["projectSettingsOverrides"], drop(overrides, path))

        {_, value} ->
          put_in(settings["projectSettingsOverrides"], deep_put(overrides, path, value))
      end

    {:ok, _} = HalC2.Settings.put(settings, version)
    :ok
  end

  defp drop(overrides, [project, key]),
    do: Map.update(overrides, project, %{}, &Map.delete(&1, key))

  defp deep_put(overrides, [project, key], value),
    do: Map.update(overrides, project, %{key => value}, &Map.put(&1, key, value))

  def access(thread), do: HalC2.Mcp.agent_access(thread)

  def prepare(thread, instance), do: HalC2.Mcp.for_agent(thread, instance) != nil

  # --- the model -------------------------------------------------------------------

  def initial_state, do: %{launched: MapSet.new(), env: %{}, projects: %{}}

  defp thread, do: oneof(Map.keys(@projects))
  defp scope, do: oneof([:env | Map.values(@projects)])
  defp value, do: oneof([nil, true, false])

  def command(_state) do
    frequency([
      {2, {:call, __MODULE__, :launch, [thread()]}},
      {4, {:call, __MODULE__, :set, [scope(), oneof(Map.keys(@keys)), value()]}},
      {3, {:call, __MODULE__, :access, [thread()]}},
      {3, {:call, __MODULE__, :prepare, [thread(), oneof(["codex", "claudeAgent"])]}}
    ])
  end

  def precondition(state, {:call, _, :launch, [thread]}),
    do: not MapSet.member?(state.launched, thread)

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :launch, [thread]}),
    do: %{state | launched: MapSet.put(state.launched, thread)}

  def next_state(state, _result, {:call, _, :set, [:env, capability, value]}),
    do: %{state | env: Map.put(state.env, capability, value)}

  def next_state(state, _result, {:call, _, :set, [project, capability, value]}),
    do: put_in(state.projects[{project, capability}], value)

  def next_state(state, _result, _call), do: state

  def postcondition(state, {:call, _, :access, [thread]}, result),
    do: result == expected(state, thread)

  def postcondition(state, {:call, _, :prepare, [thread, _]}, result),
    do: result == MapSet.member?(expected(state, thread), "preview")

  def postcondition(_state, _call, result), do: result == :ok

  defp expected(state, thread) do
    project = if MapSet.member?(state.launched, thread), do: @projects[thread]

    for capability <- Map.keys(@keys),
        allowed?(capability, setting(state, project, capability)),
        into: MapSet.new(),
        do: capability
  end

  defp setting(state, project, capability) do
    case state.projects[{project, capability}] do
      nil -> state.env[capability]
      value -> value
    end
  end

  # The browser is on unless turned off; devices are off unless turned on.
  defp allowed?("preview", value), do: value != false
  defp allowed?("device", value), do: value == true
end
