defmodule HalC2.ScratchPropTest do
  @moduledoc """
  The law of `HalC2.Scratch.stale/4`, which decides what the sweep deletes: a folder goes
  exactly when no thread is running or was active recently enough to claim it.
  """

  use ExUnit.Case, async: false
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

  # `with_dir/2`'s promise: the folder is gone once its caller is, however the caller ends
  # (finishing, raising, or killed so that no `after` runs), and while the caller still runs
  # it exists.
  property "a folder of with_dir is gone however its caller ends",
    numtests: HalC2.Prop.numtests(100) do
    forall ends <- list(oneof([:finish, :raise, :kill])) do
      HalC2.Prop.scratch_home("scratch")
      test = self()

      Enum.all?(ends, fn how ->
        caller =
          spawn(fn ->
            Process.put(:scratch_notify, test)

            try do
              Scratch.with_dir("prop", fn dir ->
                send(test, {:dir, self(), dir})

                case how do
                  :finish -> :ok
                  :raise -> raise "boom"
                  :kill -> Process.sleep(:infinity)
                end
              end)
            rescue
              _ -> :ok
            end
          end)

        ref = Process.monitor(caller)

        receive do
          {:dir, ^caller, dir} ->
            existed = File.dir?(dir) or how != :kill
            if how == :kill, do: Process.exit(caller, :kill)

            receive do
              {:DOWN, ^ref, _, _, _} -> :ok
            end

            # A caller that ended by itself removed the folder before it exited.
            gone_at_exit = not File.exists?(dir)

            # The reaper always reports; for a killed caller it is the one that removed it.
            receive do
              {:scratch_removed, ^dir} ->
                existed and not File.exists?(dir) and (how == :kill or gone_at_exit)
            after
              5_000 -> false
            end
        end
      end)
    end
  end

  defp id, do: oneof(~w(a b c d e f))

  defp thread do
    let {id, days, running?} <- {id(), integer(0, 30), boolean()},
        do: {id, @now - days * @day_ms, running?}
  end
end
