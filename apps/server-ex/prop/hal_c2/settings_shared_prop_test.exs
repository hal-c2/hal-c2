defmodule HalC2.SettingsSharedPropTest do
  @moduledoc """
  The laws of `HalC2.Settings.Shared`: merging records is commutative, associative and
  idempotent per unit, so it never matters in what order or how often members hear of
  each other. Then the protocol over it: members with skewed clocks write and hear of
  each other's records in any order, and once every member has heard every other they
  all hold, per unit, the last write by `{at, by}`, and none holds anything it would
  have to take back.
  """

  use ExUnit.Case, async: true
  use PropCheck

  alias HalC2.Settings.Shared

  @units ["keybindings", "defaultRuntimeMode", "worktreeSubmodules"]
  @members ["mc-a", "mc-b", "mc-c"]

  # Times from a small range, so records tie on `at` and the writer decides.
  defp record do
    let {at, by, value} <- {range(0, 4), oneof(@members), oneof([:unset, "x", "y", true])} do
      case value do
        :unset -> %{"at" => at, "by" => by}
        value -> %{"at" => at, "by" => by, "value" => value}
      end
    end
  end

  defp records, do: let(pairs <- list({oneof(@units), record()}), do: Map.new(pairs))

  property "merging is commutative", numtests: HalC2.Prop.numtests(300) do
    forall {a, b} <- {records(), records()} do
      Shared.merge(a, b) == Shared.merge(b, a)
    end
  end

  property "merging is associative", numtests: HalC2.Prop.numtests(300) do
    forall {a, b, c} <- {records(), records(), records()} do
      Shared.merge(Shared.merge(a, b), c) == Shared.merge(a, Shared.merge(b, c))
    end
  end

  property "merging is idempotent, and what was merged in is never lost",
    numtests: HalC2.Prop.numtests(300) do
    forall {a, b} <- {records(), records()} do
      merged = Shared.merge(a, b)

      Shared.merge(a, a) == a and Shared.merge(merged, b) == merged and
        Shared.merge(merged, a) == merged
    end
  end

  # --- members gossiping ----------------------------------------------------------

  # Each member's clock is off by a skew of up to a minute either way. A write sets or
  # resets a unit; a delivery is one member's records, as they are then, reaching
  # another. A delivery not made is a message lost or a member away. Crashes lose
  # nothing here, since records are written before they are sent; the Maude model
  # (`proof/models/settings_shared.maude`) has them.
  defp event do
    frequency([
      {3, {:write, oneof(@members), oneof(@units), oneof([:unset, "x", "y", "z"])}},
      {3, {:deliver, oneof(@members), oneof(@members)}},
      {1, {:tick, range(1, 5)}}
    ])
  end

  defp skews, do: vector(length(@members), range(-60_000, 60_000))

  property "members that hear of each other in any order converge on the last write",
    numtests: HalC2.Prop.numtests(300),
    max_size: 60 do
    forall {skews, events, order} <- {skews(), list(event()), list(range(0, 2))} do
      skew = Map.new(Enum.zip(@members, skews))
      start = %{now: 1_000_000_000, members: Map.new(@members, &{&1, %{}}), writes: [], ok: true}

      final = Enum.reduce(events, start, &step(&1, &2, skew))

      # Everyone hears from everyone, in an order the case picks, twice over.
      pairs = for from <- @members, to <- @members, from != to, do: {from, to}
      pairs = rotate(pairs, order)
      final = Enum.reduce(pairs ++ pairs, final, fn {from, to}, acc -> deliver(acc, from, to) end)

      last =
        for {unit, record} <- Enum.reverse(final.writes), reduce: %{} do
          acc -> Map.update(acc, unit, record, &later(&1, record))
        end

      held = Enum.uniq(Map.values(final.members))

      (final.ok and length(held) == 1 and hd(held) == last)
      |> when_fail(
        IO.puts("""
        members: #{inspect(final.members, pretty: true)}
        last writes: #{inspect(last, pretty: true)}
        stamped after what it had seen: #{final.ok}
        """)
      )
      |> aggregate(Enum.map(events, &elem(&1, 0)))
    end
  end

  defp step({:tick, n}, state, _skew), do: %{state | now: state.now + n}

  defp step({:write, member, unit, value}, state, skew) do
    before = state.members[member]
    at = Shared.stamp(before, state.now + skew[member])

    values =
      cond do
        value == :unset -> %{}
        unit == "keybindings" -> %{unit => [%{"key" => "mod+" <> value, "command" => "c"}]}
        true -> %{unit => value}
      end

    records = Shared.local(before, values, [unit], at, member)

    # Writing the value it already holds stamps nothing.
    if records == before do
      state
    else
      record = records[unit]

      %{
        state
        | members: Map.put(state.members, member, records),
          writes: [{unit, record} | state.writes],
          # Stamped after everything its writer had seen, so it wins there.
          ok: state.ok and record["at"] > Shared.newest(before),
          now: state.now + 1
      }
    end
  end

  defp step({:deliver, from, to}, state, _skew), do: deliver(state, from, to)

  defp deliver(state, from, to) do
    merged = Shared.merge(state.members[to], Shared.sanitize(state.members[from]))
    %{state | members: Map.put(state.members, to, merged)}
  end

  defp later(a, b), do: if({b["at"], b["by"], b} > {a["at"], a["by"], a}, do: b, else: a)

  defp rotate(list, []), do: list

  defp rotate(list, [n | rest]) do
    {front, back} = Enum.split(list, rem(n, max(length(list), 1)))
    rotate(back ++ front, rest)
  end
end
