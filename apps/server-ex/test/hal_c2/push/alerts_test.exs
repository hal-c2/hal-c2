defmodule HalC2.Push.AlertsTest do
  use ExUnit.Case, async: true

  alias HalC2.Push.Alerts

  @t0 1_800_000_000_000

  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  defp row(id, fields \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "projectId" => "shop",
        "title" => "Thread #{id}",
        "latestRunId" => nil,
        "status" => "idle",
        "updatedAt" => iso(@t0)
      },
      fields
    )
  end

  defp completed(id, at, fields \\ %{}),
    do:
      row(
        id,
        Map.merge(
          %{
            "latestRunId" => "run-#{at}",
            "status" => "completed",
            "latestRunCompletedAt" => iso(at),
            "updatedAt" => iso(at)
          },
          fields
        )
      )

  defp thread(row), do: Alerts.thread("env", row, "shop")

  defp observe(seen, rows, started_at \\ @t0),
    do: Alerts.observe(seen, rows |> Enum.map(&thread/1) |> Enum.reject(&is_nil/1), started_at)

  describe "transitions" do
    test "a run that completes after the thread was seen alerts once" do
      {seen, []} = observe(%{}, [row("a")])
      {seen, [due]} = observe(seen, [completed("a", @t0 + 1)])
      assert %{kind: "completed", key: "env:a", title: "Thread a"} = due
      assert {_, []} = observe(seen, [completed("a", @t0 + 1)])
    end

    test "a later run completing alerts again with its own id" do
      {seen, []} = observe(%{}, [row("a")])
      {seen, [first]} = observe(seen, [completed("a", @t0 + 1)])
      {_, [second]} = observe(seen, [completed("a", @t0 + 2)])
      assert first.id != second.id
    end

    test "failure, approval and a question alert as their kinds" do
      {seen, []} = observe(%{}, [row("a")])

      failed = row("a", %{"latestRunId" => "r1", "status" => "failed"})
      assert {_, [%{kind: "failed"}]} = observe(seen, [failed])

      limited = Map.put(failed, "lastErrorClass", "usage_limit")
      assert {_, [%{kind: "failed"}]} = observe(seen, [limited])

      request = %{"id" => "rq", "kind" => "command", "createdAt" => iso(@t0 + 1)}
      approval = row("a", %{"pendingRuntimeRequest" => request})
      assert {_, [%{kind: "approval"}]} = observe(seen, [approval])

      question = row("a", %{"pendingRuntimeRequest" => %{request | "kind" => "user_input"}})
      assert {_, [%{kind: "input"}]} = observe(seen, [question])
    end

    test "archived, deleted and subagent threads do not alert" do
      {seen, []} = observe(%{}, [row("a"), row("b"), row("c")])

      rows = [
        completed("a", @t0 + 1, %{"archivedAt" => iso(@t0)}),
        completed("b", @t0 + 1, %{"deletedAt" => iso(@t0)}),
        completed("c", @t0 + 1, %{"lineage" => %{"relationshipToParent" => "subagent"}})
      ]

      assert Enum.map(rows, &thread/1) |> Enum.map(&(&1 && &1.archived)) == [true, nil, nil]
      assert {_, []} = observe(seen, rows)
    end
  end

  describe "startup (pingdotgg/t3code#13340)" do
    test "a thread first seen finished before the MC started is a baseline" do
      assert {seen, []} = observe(%{}, [completed("a", @t0 - :timer.hours(48))])
      # It does not alert later for the same run either.
      assert {_, []} = observe(seen, [completed("a", @t0 - :timer.hours(48))])
    end

    test "a thread first seen finished after the MC started alerts" do
      assert {_, [%{kind: "completed"}]} = observe(%{}, [completed("a", @t0 + 1)])
    end

    test "a request first seen alerts only when it was made after startup" do
      old = %{"id" => "rq", "kind" => "command", "createdAt" => iso(@t0 - 1)}
      assert {_, []} = observe(%{}, [row("a", %{"pendingRuntimeRequest" => old})])
      new = %{old | "createdAt" => iso(@t0 + 1)}

      assert {_, [%{kind: "approval"}]} =
               observe(%{}, [row("a", %{"pendingRuntimeRequest" => new})])
    end
  end

  describe "the alert" do
    test "one due alert is that thread's" do
      {seen, []} = observe(%{}, [row("a")])
      {_, due} = observe(seen, [completed("a", @t0 + 1)])

      assert %{
               "kind" => "completed",
               "title" => "Thread a",
               "body" => "Agent finished",
               "link" => "hal-c2://threads/env/a",
               "environmentId" => "env",
               "threadId" => "a"
             } = Alerts.alert(due)
    end

    test "several due alerts group, listing every thread, with a stable id" do
      ids = ~w(a b c d e)
      {seen, []} = observe(%{}, Enum.map(ids, &row/1))
      {_, due} = observe(seen, Enum.map(ids, &completed(&1, @t0 + 1)))
      alert = Alerts.alert(due)

      assert alert["kind"] == "grouped"
      assert alert["title"] == "5 agents finished"
      assert String.split(alert["body"], "\n") == Enum.map(ids, &"Thread #{&1}")
      assert alert["threadId"] == "a"
      assert Alerts.alert(due) == alert
    end

    test "a group's title says what it holds" do
      approval = %{kind: "approval", id: "1", title: "A", environment_id: "e", thread_id: "a"}
      input = %{approval | kind: "input", id: "2"}
      done = %{approval | kind: "completed", id: "3"}
      assert Alerts.alert([approval, input])["title"] == "2 agents need you"
      assert Alerts.alert([approval, done])["title"] == "2 agent updates"
    end

    test "a long title is clipped and a long group is shortened to fit" do
      long = String.duplicate("x", 300)
      assert String.length(thread(row("a", %{"title" => long})).title) == 120

      due =
        for i <- 1..60,
            do: %{
              kind: "completed",
              id: "#{i}",
              title: String.duplicate("t", 119) <> "#{rem(i, 10)}",
              environment_id: "e",
              thread_id: "t#{i}"
            }

      json = Alerts.message(Alerts.alert(due), nil, @t0)
      assert byte_size(json) < 3500
      %{"alert" => %{"body" => body}} = JSON.decode!(json)
      assert body =~ ~r/\nand \d+ more$/
    end
  end

  describe "the activity card" do
    test "orders attention, failed, working, then done, and counts all rows" do
      request = %{"id" => "rq", "kind" => "command", "createdAt" => iso(@t0)}

      threads =
        Enum.map(
          [
            completed("done", @t0),
            row("work", %{"latestRunId" => "r", "status" => "running"}),
            row("fail", %{"latestRunId" => "r", "status" => "failed"}),
            row("ask", %{"pendingRuntimeRequest" => request}),
            row("idle")
          ],
          &thread/1
        )

      card = Alerts.activity(threads, @t0 + 1)

      assert Enum.map(card["rows"], & &1["status"]) == ~w(Approval Failed Working Done)
      assert card["phase"] == "waiting_for_approval"
      assert card["active"]
      assert card["activeCount"] == 2
      assert card["attentionCount"] == 1
      assert card["expiresAt"] == @t0 + 1 + :timer.hours(2)
    end

    test "finished rows stay 15 minutes and the card then has none" do
      threads = [thread(completed("a", @t0))]
      card = Alerts.activity(threads, @t0 + 1)
      refute card["active"]
      assert card["expiresAt"] == @t0 + :timer.minutes(15)
      assert Alerts.next_expiry(threads, @t0 + 1) == @t0 + :timer.minutes(15)
      assert Alerts.activity(threads, @t0 + :timer.minutes(15)) == nil
    end
  end

  describe "quiet hours" do
    # 22:00 to 07:00, an hour east of UTC.
    @quiet %{"start" => 1320, "end" => 420, "allowApprovals" => false, "utcOffsetMinutes" => 60}

    defp at(hour, minute),
      do: @t0 - rem(@t0, :timer.hours(24)) + :timer.hours(hour) + :timer.minutes(minute)

    test "the window wraps past midnight in local time" do
      # 21:30 UTC is 22:30 local.
      assert Alerts.quiet?(@quiet, at(21, 30))
      assert Alerts.quiet?(@quiet, at(5, 59))
      refute Alerts.quiet?(@quiet, at(6, 0))
      refute Alerts.quiet?(@quiet, at(20, 59))
      refute Alerts.quiet?(nil, at(23, 0))
      refute Alerts.quiet?(%{@quiet | "end" => 1320}, at(21, 30))
    end

    test "the window ends at its end in local time" do
      assert Alerts.quiet_end(@quiet, at(22, 0)) == at(6, 0) + :timer.hours(24)
      assert Alerts.quiet_end(@quiet, at(2, 0)) == at(6, 0)
    end
  end
end
