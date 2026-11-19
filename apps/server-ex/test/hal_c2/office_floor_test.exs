Code.require_file("../../../../plugins/office/mc/floor.ex", __DIR__)

defmodule HalC2.OfficeFloorTest do
  @moduledoc """
  How long the office keeps an idle thread (`HalC2Plugins.Office.Floor`, in
  `plugins/office/mc`): `idleHours` from when the thread became idle, however often its
  row changes after. The plugin process is covered by `features/plugins/office.feature`,
  the rest of the floor by `prop/hal_c2/office_prop_test.exs`.
  """
  use ExUnit.Case, async: true

  alias HalC2Plugins.Office.Floor

  @hour 3_600_000
  @start 1_800_000_000_000

  defp floor, do: Floor.new(%{"idleHours" => 1})

  defp row(state, ended, updated) do
    %{
      "id" => "t1",
      "title" => "Fix the parser",
      "createdAt" => Floor.iso(@start - 10 * @hour),
      "updatedAt" => Floor.iso(updated),
      "status" => if(state == "working", do: "running", else: "completed"),
      "latestRunCompletedAt" => ended && Floor.iso(ended),
      "pendingBackgroundTasks" =>
        if(state == "waiting", do: [%{"taskId" => "w", "taskType" => "subagent"}], else: [])
    }
  end

  defp in_office?(floor, now), do: Floor.view(floor, now)["people"] != []

  test "a thread read idle leaves idleHours after its run ended, its row touched since" do
    # Its run ended 50 minutes ago; its provider session was stopped 20 minutes later.
    floor = Floor.load(floor(), [row("idle", @start - 50 * 60_000, @start - 30 * 60_000)], @start)
    floor = Floor.rows(floor, [row("idle", @start - 50 * 60_000, @start)], @start)

    assert Floor.next_change(floor, @start) == @start + 10 * 60_000
    assert in_office?(floor, @start + 10 * 60_000 - 1)
    refute in_office?(floor, @start + 10 * 60_000)
  end

  test "a thread seen going idle leaves idleHours after, however often its row changes" do
    floor = Floor.load(floor(), [row("working", nil, @start)], @start)
    floor = Floor.rows(floor, [row("idle", @start, @start)], @start)

    floor =
      Enum.reduce(1..5, floor, fn i, floor ->
        Floor.rows(
          floor,
          [row("idle", @start, @start + i * 10 * 60_000)],
          @start + i * 10 * 60_000
        )
      end)

    assert Floor.next_change(floor, @start + 50 * 60_000) == @start + @hour
    refute in_office?(floor, @start + @hour)
  end

  test "a thread done waiting on background work is idle from then, not from its run" do
    floor = Floor.load(floor(), [row("waiting", @start - 2 * @hour, @start)], @start)
    floor = Floor.rows(floor, [row("idle", @start - 2 * @hour, @start)], @start)

    assert in_office?(floor, @start + @hour - 1)
    refute in_office?(floor, @start + @hour)
  end

  test "a row first seen already idle is idle from its run, not from when it came" do
    # Moved here from another machine, say: its row is new to the office.
    floor = Floor.rows(floor(), [row("idle", @start - 2 * @hour, @start)], @start)

    refute in_office?(floor, @start)
    assert Floor.next_change(floor, @start) == nil
  end

  test "an idle thread whose latest run ended later than the office saw ran in between" do
    floor = Floor.load(floor(), [row("idle", @start - 2 * @hour, @start - 2 * @hour)], @start)
    refute in_office?(floor, @start)

    # A short run the shell's batching folded into one change: idle before and after.
    floor = Floor.rows(floor, [row("idle", @start, @start)], @start)

    assert in_office?(floor, @start)
    assert Floor.next_change(floor, @start) == @start + @hour
  end

  for {put_away, back} <- [
        {%{"archivedAt" => "2026-01-01T00:00:00.000Z"}, %{"archivedAt" => nil}},
        {%{"settledOverride" => "settled"}, %{"settledOverride" => "active"}}
      ] do
    test "a long-idle thread brought back (#{inspect(Map.keys(put_away))}) stays idleHours more" do
      ended = @start - 2 * @hour

      floor =
        Floor.load(
          floor(),
          [Map.merge(row("idle", ended, ended), unquote(Macro.escape(put_away)))],
          @start
        )

      refute in_office?(floor, @start)

      floor =
        Floor.rows(
          floor,
          [Map.merge(row("idle", ended, @start), unquote(Macro.escape(back)))],
          @start
        )

      assert in_office?(floor, @start + @hour - 1)
      assert Floor.next_change(floor, @start) == @start + @hour
      refute in_office?(floor, @start + @hour)
    end
  end
end
