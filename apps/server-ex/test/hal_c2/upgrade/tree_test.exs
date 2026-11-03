defmodule HalC2.Upgrade.TreeTest do
  use ExUnit.Case, async: true

  alias HalC2.Upgrade.Tree

  defp spec(child),
    do: Map.merge(%{restart: :permanent, type: :worker}, Supervisor.child_spec(child, []))

  defp agent(id, value), do: spec(Supervisor.child_spec({Agent, fn -> value end}, id: id))

  defp ids(sup), do: sup |> Supervisor.which_children() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

  test "children new in the release start, removed ones stop, changed ones restart" do
    # A boot task that ran and ended: a temporary child with nothing left to run.
    task = spec(%{id: :boot, start: {Function, :identity, [:ignore]}, restart: :temporary})
    old = [agent(:kept, 1), agent(:changed, 1), agent(:removed, 1), task]

    sup =
      start_supervised!(%{
        id: :tree,
        start: {Supervisor, :start_link, [old, [strategy: :one_for_one]]}
      })

    kept = pid(sup, :kept)

    new = [
      agent(:kept, 1),
      agent(:changed, 2),
      agent(:added, 3),
      spec(%{id: :boot, start: {Agent, :start_link, [fn -> :again end]}, restart: :temporary})
    ]

    changes = Tree.sync(sup, old, new)

    assert Enum.sort(changes) == [
             {:restarted, :changed},
             {:started, :added},
             {:stopped, :removed}
           ]

    assert ids(sup) == [:added, :changed, :kept]
    assert pid(sup, :kept) == kept
    assert Agent.get(pid(sup, :changed), & &1) == 2
  end

  test "a child that does not start is reported, not raised" do
    sup =
      start_supervised!(%{
        id: :tree,
        start: {Supervisor, :start_link, [[], [strategy: :one_for_one]]}
      })

    broken = spec(%{id: :broken, start: {Function, :identity, [{:error, :boom}]}})
    {result, _log} = ExUnit.CaptureLog.with_log(fn -> Tree.sync(sup, [], [broken]) end)
    assert result == [{:failed, :broken}]
  end

  defp pid(sup, id),
    do:
      Enum.find_value(Supervisor.which_children(sup), fn
        {^id, pid, _, _} -> pid
        _ -> nil
      end)
end
