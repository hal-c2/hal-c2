defmodule HalC2.ProviderInstallWatchPropTest do
  @moduledoc """
  `HalC2.ProviderInstall.watch/3`, what a client socket calls on the MC an instance is
  on to follow its install progress. The installer is picked by that MC's own
  settings: an instance it knows as Codex reaches the Codex installer, anything else
  is refused by the Antigravity one, as instances come and go in its settings.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{ProviderInstall, Settings}

  @moduletag timeout: :infinity

  @pool ["codex-work", "codex-lab", "other"]

  property "an instance reaches the installer its own MC's settings say",
    numtests: HalC2.Prop.numtests(200),
    max_size: 20 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("provider-install-watch")
        HalC2.Prop.put_env(:codex_command, ["codex", "app-server"])

        HalC2.Prop.start_services([
          Settings,
          {Registry, keys: :unique, name: HalC2.Codex.Registry},
          HalC2.Codex.Installation,
          HalC2.Acp.Antigravity.Installation
        ])

        _ = home
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()
        HalC2.Prop.restore_env()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model: the instances settings know as Codex ----------------------------------

  def initial_state, do: %{codex: MapSet.new(), watched: MapSet.new()}

  def command(_state) do
    id = elements(@pool)

    frequency([
      {2, {:call, __MODULE__, :add, [id]}},
      {2, {:call, __MODULE__, :remove, [id]}},
      {4, {:call, __MODULE__, :watch, [id, elements([:ref1, :ref2])]}},
      {3, {:call, __MODULE__, :unwatch, [id, elements([:ref1, :ref2])]}}
    ])
  end

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :add, [id]}),
    do: %{state | codex: MapSet.put(state.codex, id)}

  def next_state(state, _result, {:call, _, :remove, [id]}),
    do: %{state | codex: MapSet.delete(state.codex, id)}

  def next_state(state, _result, {:call, _, :watch, [id, ref]}) do
    if MapSet.member?(state.codex, id),
      do: %{state | watched: MapSet.put(state.watched, {id, ref})},
      else: state
  end

  def next_state(state, _result, {:call, _, :unwatch, [id, ref]}),
    do: %{state | watched: MapSet.delete(state.watched, {id, ref})}

  def next_state(state, _result, _call), do: state

  # Known as Codex: followed (the Codex installer answers its state). Else refused.
  def postcondition(state, {:call, _, :watch, [id, _]}, result) do
    if MapSet.member?(state.codex, id),
      do: match?({:ok, _}, result),
      else: match?({:error, %{"operation" => "observe-install"}}, result)
  end

  # Whatever became of the instance since, `unwatch/3` lets go of what `watch/3` held:
  # the Codex installer is left with the refs the model still has.
  def postcondition(state, {:call, _, :unwatch, [id, _]} = call, held) do
    after_call = next_state(state, nil, call)
    held == for({^id, ref} <- after_call.watched, into: MapSet.new(), do: ref)
  end

  def postcondition(_state, _call, _result), do: true

  # --- what the commands do ------------------------------------------------------------

  def add(id), do: put(&Map.put(&1, id, %{"driver" => "codex"}))
  def remove(id), do: put(&Map.delete(&1, id))

  def watch(id, ref) do
    ProviderInstall.watch(id, self(), ref)
  end

  # The refs the Codex installer still holds for this process on `id`.
  def unwatch(id, ref) do
    ProviderInstall.unwatch(id, self(), ref)
    # A call behind the cast: the installer has handled it.
    watchers = :sys.get_state(HalC2.Codex.Installation).watchers

    case Map.get(watchers, {self(), id}) do
      {_monitor, refs} -> refs
      nil -> MapSet.new()
    end
  end

  defp put(fun) do
    {settings, version} = Settings.get()
    instances = fun.(settings["providerInstances"] || %{})
    {:ok, _} = Settings.put(%{"providerInstances" => instances}, version)
    :ok
  end
end
