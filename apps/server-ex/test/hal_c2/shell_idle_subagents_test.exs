defmodule HalC2.ShellIdleSubagentsTest do
  use ExUnit.Case, async: true

  alias HalC2.Shell

  defp row(extra \\ %{}) do
    Map.merge(
      %{
        "id" => "child",
        "status" => "completed",
        "activeRunId" => nil,
        "activityRunStatus" => nil,
        "pendingRuntimeRequest" => nil,
        "pendingBackgroundTasks" => [],
        "lineage" => %{
          "parentThreadId" => "parent",
          "relationshipToParent" => "subagent",
          "rootThreadId" => "parent"
        }
      },
      extra
    )
  end

  test "an idle subagent leaf may be left out of a snapshot" do
    assert Shell.idle_subagent?(row(), MapSet.new())
    assert Shell.idle_subagent?(row(%{"status" => "idle"}), MapSet.new())
  end

  test "a subagent with work or a subagent of its own stays" do
    refute Shell.idle_subagent?(row(%{"status" => "running"}), MapSet.new())
    refute Shell.idle_subagent?(row(%{"status" => "queued"}), MapSet.new())
    refute Shell.idle_subagent?(row(%{"status" => "waiting"}), MapSet.new())
    refute Shell.idle_subagent?(row(%{"activeRunId" => "run-1"}), MapSet.new())
    refute Shell.idle_subagent?(row(%{"pendingRuntimeRequest" => %{"id" => "r"}}), MapSet.new())

    refute Shell.idle_subagent?(
             row(%{"pendingBackgroundTasks" => [%{"taskId" => "t"}]}),
             MapSet.new()
           )

    refute Shell.idle_subagent?(row(), MapSet.new(["child"]))
  end

  test "a top-level or fork thread is never an idle subagent" do
    fork = %{
      "parentThreadId" => "parent",
      "relationshipToParent" => "fork",
      "rootThreadId" => "parent"
    }

    refute Shell.idle_subagent?(row(%{"lineage" => fork}), MapSet.new())
    refute Shell.idle_subagent?(row(%{"lineage" => nil}), MapSet.new())
  end

  test "subagent parents are read from rows' lineage" do
    rows = [
      {{node(), "child"}, {"thread", row()}},
      {{node(), "parent"}, {"thread", %{"id" => "parent", "lineage" => nil}}},
      {{node(), "demo"}, {"project", %{"id" => "demo"}}}
    ]

    assert Shell.subagent_parents(rows) == MapSet.new(["parent"])
  end
end
