defmodule HalC2Plugins.IssueTracker.Triage do
  @moduledoc """
  The rules of a triage report, as plain functions: what shape an agent's report
  must have for each action, and what applying its proposal asks GitHub for.
  Nothing here needs the MC, so the tests run it on its own.

  A report is `%{"summary", "items"}`. Each item names one issue and what the
  agent proposes for it: a `priority` and extra `labels` (prioritising), a
  `comment` to post (a follow-up question, or a summary worth keeping on the
  issue), and the `duplicates` it named. Every item may carry a one-line
  `reason`. Applying turns an item into operations — set its labels, post its
  comment — in the order the agent ranked them.
  """

  @priorities ~w(critical high medium low)
  @actions ~w(prioritise followUp summarise)
  @repository ~r{^[\w.-]+/[\w.-]+$}
  @max_items 200

  def priorities, do: @priorities
  def actions, do: @actions

  @doc "Fills `{{name}}` in a prompt template; a name with no value stays as written."
  def fill(template, values) when is_binary(template) do
    Regex.replace(~r/\{\{(\w+)\}\}/, template, fn whole, name -> values[name] || whole end)
  end

  def fill(_template, _values), do: ""

  @doc "The key an issue is kept under everywhere: `owner/name#7`."
  def key(repository, number), do: "#{repository}##{number}"

  @doc """
  An agent's report for `action`, checked. `target` is the run's own issue as
  `%{"repository", "number"}` for the per-issue actions, and nil for
  prioritising, which ranks a whole queue.
  """
  def report(arguments, action, target) when is_map(arguments) do
    summary = arguments["summary"]
    items = arguments["items"] || []

    cond do
      action not in @actions ->
        {:error, "There is no triage action #{inspect(action)}."}

      not is_binary(summary) or String.trim(summary) == "" ->
        {:error, "summary must say what you found."}

      not is_list(items) or length(items) > @max_items ->
        {:error, "items must be a list of at most #{@max_items} issues."}

      true ->
        with {:ok, items} <- items(items),
             :ok <- targeted(action, items, target),
             do: {:ok, %{"summary" => String.trim(summary), "items" => items}}
    end
  end

  def report(_arguments, _action, _target), do: {:error, "A report is an object."}

  # A per-issue action reports on its own issue or not at all; prioritising stays
  # inside the repository it ranked, which its items name.
  defp targeted("prioritise", [], _target),
    do: {:error, "A prioritising report ranks at least one issue."}

  defp targeted("prioritise", items, %{"repository" => repository}) do
    if Enum.all?(items, &(&1["repository"] == repository)),
      do: :ok,
      else: {:error, "Rank only the issues of #{repository}."}
  end

  defp targeted(_action, items, %{"repository" => repository, "number" => number}) do
    case items do
      [%{"repository" => ^repository, "number" => ^number}] -> :ok
      _ -> {:error, "Report on #{key(repository, number)} and nothing else."}
    end
  end

  defp targeted(_action, _items, _target), do: :ok

  defp items(items) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, checked} ->
      case item(item) do
        {:ok, checked_item} -> {:cont, {:ok, checked ++ [checked_item]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, checked} ->
        keys = Enum.map(checked, &key(&1["repository"], &1["number"]))

        if length(keys) == length(Enum.uniq(keys)),
          do: {:ok, checked},
          else: {:error, "Each issue is reported once."}

      error ->
        error
    end
  end

  defp item(item) when is_map(item) do
    repository = item["repository"]
    number = item["number"]
    priority = item["priority"]
    labels = item["labels"] || []
    comment = item["comment"]
    reason = item["reason"]
    duplicates = item["duplicates"] || []

    cond do
      not (is_binary(repository) and Regex.match?(@repository, repository)) ->
        {:error, "Each item names its repository as owner/name."}

      not (is_integer(number) and number > 0) ->
        {:error, "Each item names its issue number."}

      priority not in [nil | @priorities] ->
        {:error, "priority is one of #{Enum.join(@priorities, ", ")}."}

      not labels?(labels) ->
        {:error, "labels must be a list of label names."}

      not (comment == nil or is_binary(comment)) ->
        {:error, "comment must be the text to post."}

      not (reason == nil or is_binary(reason)) ->
        {:error, "reason must say why, in one line."}

      not numbers?(duplicates) ->
        {:error, "duplicates must be issue numbers."}

      true ->
        {:ok,
         %{
           "repository" => repository,
           "number" => number,
           "priority" => priority,
           "labels" =>
             labels |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq(),
           "comment" => comment && String.trim(comment),
           "reason" => reason && String.trim(reason),
           "duplicates" => Enum.uniq(duplicates) -- [number]
         }}
    end
  end

  defp item(_item), do: {:error, "Each item is an object naming one issue."}

  defp labels?(labels),
    do:
      is_list(labels) and length(labels) <= 20 and
        Enum.all?(labels, &(is_binary(&1) and String.trim(&1) != ""))

  defp numbers?(numbers),
    do: is_list(numbers) and Enum.all?(numbers, &(is_integer(&1) and &1 > 0))

  @doc """
  What applying a proposal asks GitHub for, in the agent's order:
  `{:labels, repository, number, labels}` sets the issue's whole label list and
  `{:comment, repository, number, text}` posts a comment. `current` maps an
  issue's key to the labels it has now, so a priority replaces the old
  `priority:` label instead of piling up beside it.
  """
  def operations(%{"items" => items}, current) do
    Enum.flat_map(items, fn item ->
      labels =
        case {item["priority"], item["labels"]} do
          {nil, []} ->
            []

          {priority, extra} ->
            have = current[key(item["repository"], item["number"])] || []
            kept = if priority, do: without_priority(have), else: have
            extra = if priority, do: without_priority(extra), else: extra
            wanted = kept ++ extra ++ List.wrap(priority && priority_label(priority))
            [{:labels, item["repository"], item["number"], Enum.uniq(wanted)}]
        end

      comment =
        if is_binary(item["comment"]) and item["comment"] != "",
          do: [{:comment, item["repository"], item["number"], item["comment"]}],
          else: []

      labels ++ comment
    end)
  end

  def operations(_report, _current), do: []

  @doc "Whether applying this report would ask GitHub for anything."
  def applicable?(report), do: operations(report, %{}) != []

  defp priority_label(priority), do: "priority: #{priority}"

  defp without_priority(labels),
    do: Enum.reject(labels, &String.starts_with?(String.downcase(&1), "priority:"))

  @doc "An issue as the page and the prompts need it: everything but its body."
  def slim(issue) do
    %{
      "key" => key(issue["repository"], issue["number"]),
      "repository" => issue["repository"],
      "number" => issue["number"],
      "title" => issue["title"],
      "state" => issue["state"],
      "url" => issue["url"],
      "author" => issue["author"],
      "assignees" => issue["assignees"] || [],
      "labels" => issue["labels"] || [],
      "milestone" => get_in(issue, ["milestone", "title"]),
      "createdAt" => issue["createdAt"],
      "updatedAt" => issue["updatedAt"],
      "blockedBy" => refs(issue["blockedBy"]),
      "pullRequests" =>
        for pr <- issue["pullRequests"] || [] do
          %{
            "repository" => pr["repository"],
            "number" => pr["number"],
            "title" => pr["title"],
            "url" => pr["url"],
            "state" => pr["state"]
          }
        end,
      "subIssues" => %{
        "total" => get_in(issue, ["subIssuesSummary", "total"]) || 0,
        "completed" => get_in(issue, ["subIssuesSummary", "completed"]) || 0
      }
    }
  end

  defp refs(refs),
    do:
      for(ref <- refs || [], do: %{"repository" => ref["repository"], "number" => ref["number"]})

  @doc "One issue in one line, for a prompt."
  def issue_line(issue) do
    extras =
      [
        issue["author"] && "by #{issue["author"]}",
        issue["labels"] != [] && issue["labels"] != nil &&
          "labels: #{Enum.join(issue["labels"], ", ")}",
        issue["milestone"] && "milestone: #{issue["milestone"]}",
        issue["assignees"] not in [nil, []] && "assigned: #{Enum.join(issue["assignees"], ", ")}",
        blocked(issue),
        issue["updatedAt"] && "updated #{String.slice(issue["updatedAt"], 0, 10)}"
      ]
      |> Enum.filter(& &1)
      |> Enum.join("; ")

    "- #{key(issue["repository"], issue["number"])} #{issue["title"]}" <>
      if(extras == "", do: "", else: " (#{extras})")
  end

  defp blocked(issue) do
    case issue["blockedBy"] do
      [_ | _] = blockers ->
        "blocked by " <> Enum.map_join(blockers, ", ", &key(&1["repository"], &1["number"]))

      _ ->
        nil
    end
  end

  @doc "A whole queue for a prompt, one issue per line."
  def queue_text([]), do: "No open issues."
  def queue_text(issues), do: Enum.map_join(issues, "\n", &issue_line/1)

  @doc "The branch an implementing thread works on: `issue-7-add-limits`."
  def branch(number, title) do
    slug =
      (title || "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 40)
      |> String.trim("-")

    if slug == "", do: "issue-#{number}", else: "issue-#{number}-#{slug}"
  end
end
