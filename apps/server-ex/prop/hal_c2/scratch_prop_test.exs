defmodule HalC2.ScratchPropTest do
  @moduledoc """
  The law of `HalC2.Scratch.stale/3`, which decides what the sweep deletes: a folder goes
  exactly when no thread is running or was active recently enough to claim it.
  """

  use ExUnit.Case, async: true
  use PropCheck

  alias HalC2.Scratch

  @day_ms 86_400_000
  @now 1000 * @day_ms

  property "a folder goes exactly when no running or recent thread claims it",
    numtests: HalC2.Prop.numtests(200) do
    forall {threads, strangers, days} <- {list(thread()), list(id()), oneof([nil, 1, 7, 30])} do
      key = &Path.basename(Scratch.thread_dir(&1))
      ids = Enum.map(threads, &elem(&1, 0)) ++ strangers
      keys = ids |> Enum.map(key) |> Enum.uniq()
      stale = Scratch.stale(keys, threads, days, @now)

      claimed =
        for {id, at, running?} <- threads,
            running? or days == nil or @now - at <= days * @day_ms,
            into: MapSet.new(),
            do: key.(id)

      MapSet.new(stale) == MapSet.difference(MapSet.new(keys), claimed) and
        Enum.all?(stale, &(&1 in keys))
    end
  end

  defp id, do: oneof(~w(a b c d e f))

  defp thread do
    let {id, days, running?} <- {id(), integer(0, 30), boolean()},
        do: {id, @now - days * @day_ms, running?}
  end
end
