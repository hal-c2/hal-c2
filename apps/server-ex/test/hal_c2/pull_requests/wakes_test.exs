defmodule HalC2.PullRequests.WakesTest do
  @moduledoc """
  `HalC2.PullRequests.Wakes.changes/3` and `advance/3` for the merge queue: a
  removal the thread has not heard of is news, old history and a pull request
  that merged anyway are not.
  """

  use ExUnit.Case, async: true

  alias HalC2.PullRequests.Wakes

  @at "2030-01-01T00:00:10Z"
  @later "2030-01-01T00:00:20Z"

  defp snapshot(extra \\ %{}) do
    Map.merge(
      %{
        "state" => "open",
        "checksState" => "passing",
        "mergeability" => "mergeable",
        "mergeQueue" => nil,
        "mergeQueueRemoval" => %{"at" => @at, "reason" => "failed_checks"}
      },
      extra
    )
  end

  defp heard(extra \\ %{}),
    do:
      Map.merge(
        %{
          "state" => "open",
          "checksState" => "passing",
          "mergeability" => "mergeable",
          "checksFailed" => false,
          "mergeQueueRemovalAt" => nil
        },
        extra
      )

  test "a removal newer than what the thread heard is news, with its reason" do
    assert Wakes.changes(heard(), snapshot()) == [{:left_merge_queue, "failed_checks"}]
  end

  test "advance remembers the removal, so the same snapshot is not news again" do
    changes = Wakes.changes(heard(), snapshot())
    next = Wakes.advance(heard(), snapshot(), changes)
    assert next["mergeQueueRemovalAt"] == @at
    assert Wakes.changes(next, snapshot()) == []
  end

  test "a newer removal after one already heard is news again" do
    heard = heard(%{"mergeQueueRemovalAt" => @at})
    snapshot = snapshot(%{"mergeQueueRemoval" => %{"at" => @later, "reason" => "failed_checks"}})
    assert Wakes.changes(heard, snapshot) == [{:left_merge_queue, "failed_checks"}]
  end

  test "a link synced before snapshots carried removals is not woken for old history" do
    heard_without_marker = Map.delete(heard(), "mergeQueueRemovalAt")
    assert Wakes.changes(heard_without_marker, snapshot()) == []

    # But that snapshot becomes the baseline for any later removal.
    next = Wakes.advance(heard_without_marker, snapshot(), [])
    assert next["mergeQueueRemovalAt"] == @at
    later = snapshot(%{"mergeQueueRemoval" => %{"at" => @later, "reason" => "failed_checks"}})
    assert Wakes.changes(next, later) == [{:left_merge_queue, "failed_checks"}]
  end

  test "a first snapshot is a baseline: a removal already there is not news" do
    baseline = Wakes.baseline(snapshot())
    assert baseline["mergeQueueRemovalAt"] == @at
    assert Wakes.changes(baseline, snapshot()) == []
  end

  test "a snapshot with no removal carries the marker forward as nothing heard" do
    next = Wakes.advance(heard(), snapshot(%{"mergeQueueRemoval" => nil}), [])
    assert Map.has_key?(next, "mergeQueueRemovalAt")
    assert next["mergeQueueRemovalAt"] == nil
    assert Wakes.changes(next, snapshot(%{"mergeQueueRemoval" => nil})) == []
  end

  test "a snapshot that does not say keeps what was heard" do
    heard = heard(%{"mergeQueueRemovalAt" => @at})
    next = Wakes.advance(heard, Map.delete(snapshot(), "mergeQueueRemoval"), [])
    assert next["mergeQueueRemovalAt"] == @at
  end

  test "a removal whose pull request then merged does not wake as a failure" do
    changes = Wakes.changes(heard(), snapshot(%{"state" => "merged"}))
    assert changes == [:merged]
  end

  test "a removal whose pull request then closed is told as a close, not a queue failure" do
    assert Wakes.changes(heard(), snapshot(%{"state" => "closed"})) == [:closed]
  end

  test "entering the queue is not news" do
    snapshot =
      snapshot(%{
        "mergeQueue" => %{"state" => "queued", "position" => 1},
        "mergeQueueRemoval" => nil
      })

    assert Wakes.changes(heard(), snapshot) == []
  end

  test "the wake says why it left and how to see the queue's run, and counts as failed" do
    link = %{
      "host" => "github.com",
      "repository" => "acme/app",
      "number" => 12,
      "url" => "https://github.com/acme/app/pull/12",
      "snapshot" => %{"baseBranch" => "main"}
    }

    wake = Wakes.wake("t1", [{link, [{:left_merge_queue, "failed_checks"}]}])

    assert wake["text"] =~ "It left the merge queue: its checks failed there."
    assert wake["text"] =~ "gh run list --repo acme/app --event merge_group --limit 100"
    assert wake["text"] =~ ~s|startswith("gh-readonly-queue/main/pr-12-")|
    assert wake["notification"]["outcome"] == "failed"
    assert wake["notification"]["summary"] == "acme/app#12: left merge queue"
  end

  test "a removal for another reason reads sensibly and is not a failure" do
    link = %{
      "host" => "github.com",
      "repository" => "acme/app",
      "number" => 12,
      "url" => "https://github.com/acme/app/pull/12",
      "snapshot" => %{"baseBranch" => "main"}
    }

    wake = Wakes.wake("t1", [{link, [{:left_merge_queue, "dequeued_by_user"}]}])

    assert wake["text"] =~ "It left the merge queue (dequeued by user)."
    assert wake["notification"]["outcome"] == "updated"
  end
end
