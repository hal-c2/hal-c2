for file <- ~w(triage issue_tracker),
    do: Code.require_file("../../../../plugins/issue-tracker/mc/#{file}.ex", __DIR__)

defmodule HalC2.IssueTrackerTest do
  @moduledoc """
  The issue tracker plugin's rules (`plugins/issue-tracker/mc`): what shape a
  triage agent's report must have, and what applying its proposal asks GitHub
  for. These are plain functions; the plugin process, its runs and GitHub are
  covered by `features/source-control/issue-tracker.feature`.
  """
  use ExUnit.Case, async: true

  alias HalC2Plugins.IssueTracker
  alias HalC2Plugins.IssueTracker.Triage

  test "the package reads, and its own defaults are settings it accepts" do
    dir = Path.expand("../../../../plugins/issue-tracker", __DIR__)
    assert {:ok, manifest, sources, _hash} = HalC2.Plugins.Package.read(dir)
    assert manifest.id == "issue-tracker"
    assert Enum.map(sources, &Path.basename/1) == ["issue_tracker.ex", "triage.ex"]

    defaults = Map.new(manifest.settings, &{&1.key, &1.default})
    assert :ok = IssueTracker.validate_settings(defaults)

    assert {:error, "repositories: give each as owner/name."} =
             IssueTracker.validate_settings(%{defaults | "repositories" => ["acme"]})

    assert {:error, "prioritising: name the agent that runs it."} =
             IssueTracker.validate_settings(%{defaults | "prioritising" => %{"provider" => ""}})

    assert {:error, "followUpPrompt: the prompt cannot be empty."} =
             IssueTracker.validate_settings(%{defaults | "followUpPrompt" => "  "})

    assert {:error, "pollMinutes: look at most once a minute."} =
             IssueTracker.validate_settings(%{defaults | "pollMinutes" => 0})
  end

  defp item(number, extra \\ %{}),
    do: Map.merge(%{"repository" => "acme/api", "number" => number}, extra)

  describe "a prioritising report" do
    test "keeps the agent's order, priorities and reasons" do
      assert {:ok, report} =
               Triage.report(
                 %{
                   "summary" => "  #9 blocks the release. ",
                   "items" => [
                     item(9, %{"priority" => "high", "reason" => "blocks Beta"}),
                     item(7, %{"priority" => "low"})
                   ]
                 },
                 "prioritise",
                 %{"repository" => "acme/api"}
               )

      assert report["summary"] == "#9 blocks the release."
      assert Enum.map(report["items"], & &1["number"]) == [9, 7]
      assert hd(report["items"])["priority"] == "high"
    end

    test "must rank something, in its own repository, each issue once" do
      target = %{"repository" => "acme/api"}

      assert {:error, "A prioritising report ranks at least one issue."} =
               Triage.report(%{"summary" => "None.", "items" => []}, "prioritise", target)

      assert {:error, "Rank only the issues of acme/api."} =
               Triage.report(
                 %{"summary" => "x", "items" => [%{"repository" => "acme/web", "number" => 1}]},
                 "prioritise",
                 target
               )

      assert {:error, "Each issue is reported once."} =
               Triage.report(
                 %{"summary" => "x", "items" => [item(9), item(9)]},
                 "prioritise",
                 target
               )
    end

    test "refuses priorities it does not know" do
      assert {:error, message} =
               Triage.report(
                 %{"summary" => "x", "items" => [item(9, %{"priority" => "urgent"})]},
                 "prioritise",
                 %{"repository" => "acme/api"}
               )

      assert message =~ "critical, high, medium, low"
    end
  end

  describe "a per-issue report" do
    test "is sent back when it names another issue" do
      assert {:error, "Report on acme/api#7 and nothing else."} =
               Triage.report(
                 %{"summary" => "x", "items" => [item(9, %{"comment" => "hi"})]},
                 "followUp",
                 %{"repository" => "acme/api", "number" => 7}
               )
    end

    test "a follow-up with no comment proposes nothing to apply" do
      assert {:ok, report} =
               Triage.report(
                 %{"summary" => "#7 is ready to work on.", "items" => [item(7)]},
                 "followUp",
                 %{"repository" => "acme/api", "number" => 7}
               )

      refute Triage.applicable?(report)
    end

    test "a summary names its duplicates, never itself" do
      assert {:ok, report} =
               Triage.report(
                 %{
                   "summary" => "Same as #11.",
                   "items" => [
                     item(7, %{"comment" => "The short of it.", "duplicates" => [11, 7, 11]})
                   ]
                 },
                 "summarise",
                 %{"repository" => "acme/api", "number" => 7}
               )

      assert hd(report["items"])["duplicates"] == [11]
      assert Triage.applicable?(report)
    end
  end

  describe "applying" do
    test "a priority replaces the old priority label and keeps the rest" do
      {:ok, report} =
        Triage.report(
          %{
            "summary" => "Ranked.",
            "items" => [
              item(9, %{"priority" => "high"}),
              item(7, %{"priority" => "low", "labels" => ["needs-design"]})
            ]
          },
          "prioritise",
          %{"repository" => "acme/api"}
        )

      current = %{"acme/api#9" => ["priority: low", "backend"], "acme/api#7" => []}

      assert Triage.operations(report, current) == [
               {:labels, "acme/api", 9, ["backend", "priority: high"]},
               {:labels, "acme/api", 7, ["needs-design", "priority: low"]}
             ]
    end

    test "a suggested priority label does not land beside the priority set" do
      # Found by prop/hal_c2/issue_tracker_prop_test.exs.
      {:ok, report} =
        Triage.report(
          %{
            "summary" => "Ranked.",
            "items" => [item(9, %{"priority" => "high", "labels" => ["priority: low", "bug"]})]
          },
          "prioritise",
          %{"repository" => "acme/api"}
        )

      assert Triage.operations(report, %{"acme/api#9" => ["priority: medium"]}) ==
               [{:labels, "acme/api", 9, ["bug", "priority: high"]}]
    end

    test "a comment is one operation on its issue" do
      {:ok, report} =
        Triage.report(
          %{"summary" => "Asked.", "items" => [item(7, %{"comment" => "Which limits?"})]},
          "followUp",
          %{"repository" => "acme/api", "number" => 7}
        )

      assert Triage.operations(report, %{}) == [{:comment, "acme/api", 7, "Which limits?"}]
    end
  end

  describe "for the page and the prompts" do
    test "slim leaves the body out and keys the issue" do
      issue = %{
        "repository" => "acme/api",
        "number" => 7,
        "title" => "Add limits",
        "body" => "long",
        "state" => "open",
        "url" => "https://github.com/acme/api/issues/7",
        "author" => "dana",
        "assignees" => [],
        "labels" => ["backend"],
        "milestone" => %{"title" => "Beta"},
        "blockedBy" => [%{"repository" => "acme/api", "number" => 5, "url" => "x"}],
        "subIssuesSummary" => %{"total" => 2, "completed" => 1}
      }

      slim = Triage.slim(issue)
      assert slim["key"] == "acme/api#7"
      refute Map.has_key?(slim, "body")
      assert slim["milestone"] == "Beta"
      assert slim["blockedBy"] == [%{"repository" => "acme/api", "number" => 5}]
      assert Triage.issue_line(slim) =~ "blocked by acme/api#5"
    end

    test "a branch that is taken gets the next free suffix" do
      assert Triage.free_branch("issue-7-add-limits", []) == "issue-7-add-limits"

      assert Triage.free_branch("issue-7-add-limits", ["issue-7-add-limits"]) ==
               "issue-7-add-limits-2"

      assert Triage.free_branch("issue-7-add-limits", [
               "issue-7-add-limits",
               "issue-7-add-limits-2"
             ]) ==
               "issue-7-add-limits-3"
    end

    test "fill leaves an unknown name as written, and branches are named for their issue" do
      assert Triage.fill("Do {{number}} of {{repository}}", %{"number" => "7"}) ==
               "Do 7 of {{repository}}"

      assert Triage.branch(7, "Add Limits, please!") == "issue-7-add-limits-please"
      assert Triage.branch(7, nil) == "issue-7"
    end
  end
end
