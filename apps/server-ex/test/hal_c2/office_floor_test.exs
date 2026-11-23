Code.require_file("../../../../plugins/office/mc/floor.ex", __DIR__)

defmodule HalC2.OfficeFloorTest do
  @moduledoc """
  How long the office keeps an idle thread (`HalC2Plugins.Office.Floor`, in
  `plugins/office/mc`): `idleHours` from when the thread became idle, however often its
  row changes after. And its talks: only current ones, and those of calls too long for a
  plugin to hear whole.
  The plugin process is covered by `features/plugins/office.feature`,
  the rest of the floor by `prop/hal_c2/office_prop_test.exs`.
  """
  use ExUnit.Case, async: true

  alias HalC2.Orchestration.TurnWriter
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

  defp worker(created) do
    Map.merge(row("working", nil, created), %{
      "id" => "worker",
      "createdAt" => Floor.iso(created),
      "lineage" => %{"relationshipToParent" => "subagent", "parentThreadId" => "lead"}
    })
  end

  defp in_office?(floor, now), do: Floor.view(floor, now)["people"] != []

  # A completed MCP call as plugins hear it.
  defp heard(tool, input, output) do
    %{
      "id" => "call-1",
      "type" => "dynamic_tool",
      "providerToolName" => "mcp__hal-c2__" <> tool,
      "status" => "completed",
      "input" => input,
      "output" => output
    }
    |> TurnWriter.observed_item()
    |> Map.merge(%{"type" => "turn.item", "threadId" => "lead"})
  end

  defp long, do: "First line\n" <> String.duplicate("more ", 1_000)

  # Claude gives a tool's result as text, Codex as a map.
  for {form, output} <- [text: quote(do: &JSON.encode!/1), map: quote(do: &Function.identity/1)] do
    test "a hand-off too long to hear whole says its worker's title (a #{form} result)" do
      title = ~s(Fix the "quoted" parser)
      input = %{"task" => long(), "title" => title}
      result = unquote(output).(%{"childThreadId" => "worker", "title" => title})

      # The call can be heard before the worker's row.
      floor = Floor.observe(floor(), heard("delegate_task", input, result), @start)

      assert [%{"kind" => "delegate", "to" => "worker", "text" => ^title}] =
               Floor.view(floor, @start)["talks"]
    end

    test "a message too long to hear whole is still a talk (a #{form} result)" do
      input = %{"threadId" => "reviewer", "message" => long()}
      result = unquote(output).(%{"threadId" => "reviewer", "status" => "sent"})

      floor = Floor.observe(floor(), heard("hal_c2_thread_send", input, result), @start)

      assert [%{"kind" => "message", "to" => "reviewer", "text" => "…"}] =
               Floor.view(floor, @start)["talks"]
    end
  end

  test "a hand-off nothing names shows as … and never an empty bubble" do
    result = %{"childThreadId" => "worker"}
    floor = Floor.observe(floor(), heard("delegate_task", %{"task" => long()}, result), @start)

    assert [%{"text" => "…"}] = Floor.view(floor, @start)["talks"]
  end

  test "a talk is in the office only while it is current, thirty seconds" do
    result = %{"childThreadId" => "worker"}
    floor = Floor.observe(floor(), heard("delegate_task", %{"task" => "Fix it"}, result), @start)

    assert [_] = Floor.view(floor, @start + 29_999)["talks"]
    assert Floor.next_change(floor, @start) == @start + 30_000
    assert Floor.view(floor, @start + 30_000)["talks"] == []
  end

  # A call that waits for its worker completes when the worker is done.
  test "a hand-off heard long after its worker was made is no talk" do
    floor = Floor.rows(floor(), [worker(@start)], @start)
    assert [%{"kind" => "delegate"}] = Floor.view(floor, @start)["talks"]

    later = @start + 5 * 60_000
    result = %{"childThreadId" => "worker"}
    floor = Floor.observe(floor, heard("delegate_task", %{"task" => "Fix it"}, result), later)

    assert Floor.view(floor, later)["talks"] == []
  end

  test "a worker's row that comes after its hand-off left the office is no second talk" do
    result = %{"childThreadId" => "worker"}
    floor = Floor.observe(floor(), heard("delegate_task", %{"task" => "Fix it"}, result), @start)
    later = @start + 60_000
    floor = Floor.rows(floor, [worker(@start)], later)

    assert Floor.view(floor, later)["talks"] == []
  end

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
