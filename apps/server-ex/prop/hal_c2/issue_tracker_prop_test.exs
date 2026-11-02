for file <- ~w(triage issue_tracker),
    do: Code.require_file("../../../../plugins/issue-tracker/mc/#{file}.ex", __DIR__)

defmodule HalC2.IssueTrackerPropTest do
  @moduledoc """
  The laws of the issue tracker's report algebra
  (`HalC2Plugins.IssueTracker.Triage`): a report in the shape an agent is told
  to give is accepted in the agent's order, applying it leaves each issue with
  exactly the priority it was given and the labels that were not the old
  priority, and a per-issue action accepts a report on its own issue only. The
  module holds no state, so these are plain `forall`s; the plugin process and
  GitHub are covered by `features/source-control/issue-tracker.feature`.
  """

  use ExUnit.Case, async: true
  use PropCheck

  alias HalC2Plugins.IssueTracker.Triage

  @repository "acme/api"

  defp issue_number, do: elements(Enum.to_list(1..12))
  defp priority, do: elements([nil, "critical", "high", "medium", "low"])
  defp label, do: elements(["backend", "priority: low", "priority: high", "triage", "bug"])

  defp items do
    let picked <- list({issue_number(), priority(), resize(2, list(label()))}) do
      picked
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.map(fn {number, priority, labels} ->
        %{
          "repository" => @repository,
          "number" => number,
          "priority" => priority,
          "labels" => labels
        }
      end)
    end
  end

  defp current_labels do
    let all <- list({issue_number(), resize(3, list(label()))}) do
      Map.new(all, fn {number, labels} -> {Triage.key(@repository, number), labels} end)
    end
  end

  property "a prioritising report is accepted in the agent's order",
    numtests: HalC2.Prop.numtests(100),
    max_size: 20 do
    forall items <- items() do
      case Triage.report(
             %{"summary" => "Ranked.", "items" => items},
             "prioritise",
             %{"repository" => @repository}
           ) do
        {:ok, report} ->
          Enum.map(report["items"], & &1["number"]) == Enum.map(items, & &1["number"])

        {:error, "A prioritising report ranks at least one issue."} ->
          items == []
      end
    end
  end

  property "applying leaves one priority label, the new one, and keeps the rest",
    numtests: HalC2.Prop.numtests(100),
    max_size: 20 do
    forall {items, current} <- {items(), current_labels()} do
      report = %{"summary" => "Ranked.", "items" => checked(items)}
      operations = Triage.operations(report, current)

      by_number = Map.new(report["items"], &{&1["number"], &1})

      Enum.all?(operations, fn
        {:labels, @repository, number, labels} ->
          item = by_number[number]
          priorities = Enum.filter(labels, &String.starts_with?(&1, "priority:"))

          kept =
            Enum.reject(
              current[Triage.key(@repository, number)] || [],
              &String.starts_with?(&1, "priority:")
            )

          (item["priority"] == nil or priorities == ["priority: " <> item["priority"]]) and
            Enum.all?(kept, &(&1 in labels))

        _ ->
          true
      end)
    end
  end

  property "a per-issue report on any other issue is refused",
    numtests: HalC2.Prop.numtests(100),
    max_size: 20 do
    forall {target, other} <- {issue_number(), issue_number()} do
      report =
        Triage.report(
          %{
            "summary" => "Asked.",
            "items" => [%{"repository" => @repository, "number" => other, "comment" => "More?"}]
          },
          "followUp",
          %{"repository" => @repository, "number" => target}
        )

      if other == target, do: match?({:ok, _}, report), else: match?({:error, _}, report)
    end
  end

  property "a branch is named for its issue and fit for git",
    numtests: HalC2.Prop.numtests(100),
    max_size: 20 do
    forall {number, title} <- {issue_number(), utf8()} do
      branch = Triage.branch(number, title)

      String.starts_with?(branch, "issue-#{number}") and
        branch =~ ~r/^issue-\d+(-[a-z0-9]+(-[a-z0-9]+)*)?$/
    end
  end

  # Items as `Triage.report/3` returns them (labels trimmed and unique), so the
  # applying law runs on checked reports only.
  defp checked(items) do
    case Triage.report(%{"summary" => "Ranked.", "items" => items}, "prioritise", %{
           "repository" => @repository
         }) do
      {:ok, report} -> report["items"]
      {:error, _} -> []
    end
  end
end
