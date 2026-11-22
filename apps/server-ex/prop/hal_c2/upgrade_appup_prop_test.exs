defmodule HalC2.UpgradeAppupPropTest do
  @moduledoc """
  `HalC2.Upgrade.Appup.instructions/3` over any two versions of an application's
  modules, plain, process and supervisor modules alike.

  The model: each module the new version adds is added, each it drops is deleted, and
  each whose code changed moves once, naming as dependencies only the other modules
  that move and that it calls. A changed supervisor re-reads its specs (`:update`), or
  with `supervisors: :load` only has its code loaded, so its `init/1` does not run
  again; how every other module moves does not depend on that option.
  """

  use ExUnit.Case, async: true
  use PropCheck

  alias HalC2.Upgrade.Appup

  @mods [:m1, :m2, :m3, :m4, :m5, :m6]
  @kinds %{plain: [], process: [GenServer], supervisor: [Supervisor]}

  property "every module moves as its kind and the supervisor option say",
    numtests: HalC2.Prop.numtests(200) do
    forall {old, new, supervisors} <- {modules(), modules(), oneof([:update, :load])} do
      old = Map.new(old, fn {mod, beam} -> {mod, %{md5: beam.md5}} end)
      got = Appup.instructions(old, new, supervisors: supervisors)
      expected = expected(old, new, supervisors)

      other = if supervisors == :load, do: :update, else: :load
      not_supervisors = &Enum.reject(&1, fn i -> supervisor?(new, elem(i, 1)) end)

      (got == expected and
         not_supervisors.(got) ==
           not_supervisors.(Appup.instructions(old, new, supervisors: other)))
      |> when_fail(IO.inspect(%{old: old, new: new, got: got, expected: expected}))
    end
  end

  defp expected(old, new, supervisors) do
    added = Enum.filter(@mods, &(Map.has_key?(new, &1) and not Map.has_key?(old, &1)))
    removed = Enum.filter(@mods, &(Map.has_key?(old, &1) and not Map.has_key?(new, &1)))
    updated = Enum.filter(@mods, &(old[&1] && new[&1] && old[&1].md5 != new[&1].md5))
    moving = added ++ updated

    moves =
      for mod <- updated do
        deps = Enum.filter(@mods, &(&1 != mod and &1 in moving and &1 in new[mod].imports))

        case {kind(new[mod]), supervisors} do
          {:supervisor, :update} ->
            {:update, mod, :static, :default, {:advanced, []}, :soft_purge, :soft_purge, deps}

          {:process, _} ->
            {:update, mod, {:advanced, []}, :soft_purge, :soft_purge, deps}

          _ ->
            {:load_module, mod, :soft_purge, :soft_purge, deps}
        end
      end

    Enum.map(added, &{:add_module, &1}) ++ moves ++ Enum.map(removed, &{:delete_module, &1})
  end

  defp supervisor?(new, mod), do: new[mod] != nil and kind(new[mod]) == :supervisor

  defp kind(beam), do: Enum.find(Map.keys(@kinds), &(@kinds[&1] == beam.behaviours))

  # Some of the modules, each with one of three builds, a kind and what it calls.
  defp modules do
    entry = {oneof(@mods), range(1, 3), oneof(Map.keys(@kinds)), resize(4, list(oneof(@mods)))}

    let entries <- resize(10, list(entry)) do
      Map.new(entries, fn {mod, md5, kind, imports} ->
        {mod,
         %{
           md5: <<md5>>,
           behaviours: @kinds[kind],
           imports: Enum.uniq(imports),
           nif?: false,
           frozen?: false
         }}
      end)
    end
  end
end
