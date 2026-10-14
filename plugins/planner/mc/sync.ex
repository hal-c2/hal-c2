defmodule HalC2Plugins.Planner.Sync do
  @moduledoc """
  The plan and GitHub: what a look at the followed repositories, the board and the
  linked pull requests finds (`look/2`), how it changes the plan (`apply/5`), and
  what a change to a linked task asks of GitHub when the plan syncs both ways
  (`pushes/5`, run by `run/1`).

  GitHub wins over the plan for what it holds, except for a task whose last change
  GitHub refused (`syncError`): that one keeps the user's, and its next push sends all
  of it again, until a push takes. A task's state follows its issue only when the
  issue opens or closes, so a task the user marked doing stays doing while its issue
  stays open.
  """

  alias HalC2.Plugins.Host
  alias HalC2Plugins.Planner.Plan

  @id "planner"

  @doc """
  What GitHub holds for the plan: `issues` of the followed repositories (open, with
  the planner's label if one is set), `details` of linked issues not among them,
  the `board`'s items by issue, the `prs` linked tasks name by state, the
  repositories no project has (`unwatched`), the `problem` a part failed with and
  the MC's `projects`. `at` orders looks that overlap.
  """
  def look(settings, items) do
    at = System.monotonic_time()

    case Host.projects(@id) do
      {:ok, projects} ->
        github = Enum.filter(projects, &(&1["kind"] == "github" and is_binary(&1["repository"])))

        found = %{
          at: at,
          problem: nil,
          unwatched: [],
          projects: projects,
          issues: [],
          details: [],
          board: nil,
          prs: %{}
        }

        found =
          if settings["sync"] in ~w(import twoWay),
            do: found |> issues(settings, items, github) |> board(settings, github),
            else: found

        prs(found, items, github)

      {:error, error} ->
        %{
          at: at,
          problem: message(error),
          unwatched: [],
          projects: nil,
          issues: [],
          details: [],
          board: nil,
          prs: %{}
        }
    end
  end

  defp issues(found, settings, items, github) do
    label = String.trim(settings["issueLabel"] || "")
    repos = settings["repositories"] || []
    unwatched = Enum.reject(repos, &project_of(github, &1))

    {listed, problems} =
      for repo <- repos, project = project_of(github, repo), reduce: {[], []} do
        {listed, problems} ->
          input = %{
            "projectId" => project["id"],
            "repository" => repo,
            "state" => "open",
            "limit" => 500
          }

          input = if label != "", do: Map.put(input, "labels", [label]), else: input

          case Host.issues(@id, "list", input) do
            {:ok, %{"issues" => issues} = list} ->
              cut =
                if list["truncated"],
                  do: [
                    "#{repo}: only its 500 most recently updated open issues were read. A planner label follows fewer."
                  ],
                  else: []

              # GitHub matches labels whatever their case.
              labelled =
                &(label == "" or Enum.any?(&1["labels"] || [], fn l -> same?(l, label) end))

              {listed ++ Enum.filter(issues, labelled), problems ++ cut}

            {:error, error} ->
              {listed, problems ++ ["#{repo}: #{message(error)}"]}
          end
      end

    # A linked issue of a followed repository that left the list (closed, or its label
    # taken off) is read alone.
    {details, problems} =
      for {_, %{"issue" => %{"repository" => repo, "number" => number}}} <- items,
          Enum.any?(repos, &same?(&1, repo)),
          not Enum.any?(listed, &Plan.same_ref?(&1, %{"repository" => repo, "number" => number})),
          project = project_of(github, repo),
          reduce: {[], problems} do
        {details, problems} ->
          case Host.issues(@id, "detail", %{
                 "projectId" => project["id"],
                 "repository" => repo,
                 "number" => number
               }) do
            {:ok, issue} -> {[issue | details], problems}
            {:error, error} -> {details, problems ++ ["#{repo}##{number}: #{message(error)}"]}
          end
      end

    problem(%{found | issues: listed, details: details, unwatched: unwatched}, problems)
  end

  defp board(found, settings, github) do
    with {:ok, owner, number} <- board_name(settings["board"]),
         [_ | _] <- github do
      case read_board(github, owner, number, 500) do
        {:ok, %{"items" => board_items} = read} ->
          # Only the dates the settings name; one empty on the board is cleared.
          named =
            for {date, field} <- [
                  {"start", settings["startField"]},
                  {"due", settings["targetField"]}
                ],
                is_binary(field) and field != "",
                do: {date, field}

          board =
            for %{"content" => %{"kind" => "issue"} = content} = item <- board_items, into: %{} do
              dates =
                for {date, field} <- named, into: %{}, do: {date, day(item["fields"][field])}

              {key(content), Map.put(dates, "itemId", item["id"])}
            end

          cut =
            if read["truncated"],
              do: ["#{settings["board"]}: only its first 500 items were read."],
              else: []

          problem(%{found | board: board}, cut)

        {:error, error} ->
          problem(found, ["#{settings["board"]}: #{message(error)}"])
      end
    else
      _ -> found
    end
  end

  @doc """
  The open GitHub Projects boards the settings offer: those of the owners of the MC's
  GitHub projects (and so of every repository the plan can follow), each named
  `owner/number`, and the `problems` owners failed with, such as gh lacking the
  project scope.
  """
  def boards do
    with {:ok, github} <- github_projects() do
      read =
        for project <- Enum.uniq_by(github, &owner_key/1) do
          owner = hd(String.split(project["repository"], "/"))
          Host.issues(@id, "boards", %{"projectId" => project["id"], "owner" => owner})
        end

      boards =
        for {:ok, %{"boards" => boards}} <- read, board <- boards, !board["closed"] do
          %{
            "id" => "#{board["owner"]}/#{board["number"]}",
            "owner" => board["owner"],
            "number" => board["number"],
            "title" => board["title"]
          }
        end

      problems = for {:error, error} <- read, uniq: true, do: message(error)
      {:ok, %{"boards" => boards, "problems" => problems}}
    end
  end

  @doc """
  The names of the date fields of `board` (`owner/number`), for the settings' start
  and target date fields.
  """
  def board_fields(board) do
    with {:ok, owner, number} <- board_name(board),
         {:ok, github} <- github_projects(),
         {:ok, %{"fields" => fields}} <- read_board(github, owner, number, 1) do
      {:ok, %{"dateFields" => for(%{"type" => "date", "name" => name} <- fields, do: name)}}
    else
      :error -> {:error, "Name a board as owner/number."}
      {:error, error} -> {:error, message(error)}
    end
  end

  defp owner_key(project), do: String.downcase(hd(String.split(project["repository"], "/")))

  defp github_projects do
    with {:ok, projects} <- Host.projects(@id),
         do:
           {:ok, Enum.filter(projects, &(&1["kind"] == "github" and is_binary(&1["repository"])))}
  end

  defp read_board([], _owner, _number, _limit),
    do: {:error, "No project on this MC has a GitHub remote to read boards through."}

  defp read_board(github, owner, number, limit) do
    project = Enum.find(github, &owner?(&1["repository"], owner)) || hd(github)

    Host.issues(@id, "board", %{
      "projectId" => project["id"],
      "owner" => owner,
      "number" => number,
      "limit" => limit
    })
  end

  defp board_name(board) when is_binary(board) do
    with [owner, number] <- String.split(String.trim(board), "/"),
         true <- owner != "",
         {number, ""} <- Integer.parse(number),
         do: {:ok, owner, number},
         else: (_ -> :error)
  end

  defp board_name(_), do: :error

  defp prs(found, items, github) do
    linked =
      for {_, item} <- items,
          pr <- item["pullRequests"] || [],
          uniq: true,
          do: String.downcase(pr["repository"] || "")

    ids =
      for project <- github,
          String.downcase(project["repository"]) in linked,
          uniq: true,
          do: project["id"]

    if ids == [] do
      found
    else
      case pr_pages(%{"projectIds" => ids, "state" => "all", "limit" => 500}, [], [], 20) do
        {:ok, entries, errors} ->
          prs = for entry <- entries, into: %{}, do: {key(entry), entry["state"]}
          problem(%{found | prs: prs}, errors)

        {:error, error} ->
          problem(found, [message(error)])
      end
    end
  end

  # Every page of the repositories' pull requests, carrying each repository on from
  # where its last page stopped; a page that cannot be carried on from is the last.
  defp pr_pages(input, entries, errors, pages) do
    with {:ok, list} <- Host.pull_requests(@id, "list", input) do
      entries = entries ++ (list["entries"] || [])
      errors = errors ++ Enum.map(list["errors"] || [], & &1["message"])
      next = list["nextCursors"] || %{}

      cond do
        next != %{} and pages > 1 ->
          pr_pages(Map.put(input, "cursors", next), entries, errors, pages - 1)

        list["truncated"] ->
          {:ok, entries, errors ++ ["Not every pull request could be read."]}

        true ->
          {:ok, entries, errors}
      end
    end
  end

  defp problem(found, []), do: found

  defp problem(found, more),
    do: %{found | problem: Enum.join(Enum.reject([found.problem | more], &is_nil/1), " ")}

  @doc """
  `items` with what `found` (`look/2`) holds: tasks for issues the plan does not
  have, linked tasks brought up to date, their subtasks and dependencies, a milestone
  for each issue milestone, board dates, and the pull requests' states. New items
  get ids from `new_id`.
  """
  def apply(items, found, settings, now, new_id) do
    items =
      if settings["sync"] in ~w(import twoWay) do
        listed = found.issues
        issues = Enum.uniq_by(listed ++ found.details, &key/1)
        projects = found.projects || []

        items
        |> then(
          &Enum.reduce(issues, &1, fn issue, items ->
            issue(items, issue, issue in listed, projects, now, new_id)
          end)
        )
        |> relations(issues, now)
        |> milestones(issues, projects, now, new_id)
        |> dates(found.board, now)
      else
        items
      end

    pull_requests(items, found.prs, settings, now)
  end

  # A task for an open issue the plan does not have, or the linked task brought up to date.
  defp issue(items, issue, listed, projects, now, new_id) do
    link = %{"issue" => Map.take(issue, ~w(repository number url state stateReason title))}
    new? = listed and issue["state"] == "open"

    case linked(items, issue) do
      nil when new? ->
        project = project_of(projects, issue["repository"])

        fields = %{
          "title" => issue["title"],
          "notes" => issue["body"] || "",
          "owner" => List.first(issue["assignees"] || []),
          "labels" => issue["labels"] || [],
          "projectId" => project && project["id"]
        }

        case Plan.add(items, new_id.(), fields, now) do
          {:ok, items, item} ->
            item = item |> Map.put("issue", link["issue"]) |> prs_of(issue, now)
            Map.put(items, item["id"], item)

          {:error, _} ->
            items
        end

      nil ->
        items

      %{"syncError" => error} = item when is_binary(error) ->
        Map.put(items, item["id"], prs_of(item, issue, now))

      item ->
        was = item["issue"]["state"]

        status =
          cond do
            issue["state"] == was ->
              %{}

            issue["state"] == "closed" and issue["stateReason"] == "not_planned" ->
              %{"status" => "dropped"}

            issue["state"] == "closed" ->
              %{"status" => "done"}

            item["status"] in ~w(done dropped) ->
              %{"status" => "todo"}

            true ->
              %{}
          end

        fields =
          Map.merge(status, %{
            "title" => issue["title"],
            "notes" => issue["body"] || "",
            "owner" => List.first(issue["assignees"] || []),
            "labels" => issue["labels"] || []
          })

        items =
          case Plan.update(items, item["id"], fields, now) do
            {:ok, items, _old, _new} -> items
            {:error, _} -> items
          end

        item = items[item["id"]]
        issue_ref = Map.merge(item["issue"], link["issue"])

        item =
          if issue_ref == item["issue"],
            do: item,
            else: %{item | "issue" => issue_ref, "updatedAt" => now}

        Map.put(items, item["id"], prs_of(item, issue, now))
    end
  end

  # The pull requests GitHub says close the issue, linked and marked as the issue's.
  # One the issue named before and no longer does goes; one linked by hand stays.
  defp prs_of(item, issue, now) do
    named = issue["pullRequests"] || []
    prs = item["pullRequests"] || []

    kept =
      Enum.reject(prs, fn pr ->
        pr["fromIssue"] == true and not Enum.any?(named, &Plan.same_ref?(&1, pr))
      end)

    item = if kept == prs, do: item, else: %{item | "pullRequests" => kept, "updatedAt" => now}

    Enum.reduce(named, item, fn pr, item ->
      if Enum.any?(item["pullRequests"], &Plan.same_ref?(&1, pr)) do
        item
      else
        linked = Plan.link(item, %{"pullRequest" => pr}, now)
        marked = List.update_at(linked["pullRequests"], -1, &Map.put(&1, "fromIssue", true))
        %{linked | "pullRequests" => marked}
      end
    end)
  end

  # Sub-issues and blocking issues as subtasks and dependencies, once every issue has
  # its task. One that would make a task its own subtask or wait for itself is left out.
  defp relations(items, issues, now) do
    Enum.reduce(issues, items, fn issue, items ->
      with %{} = item <- linked(items, issue),
           nil <- item["syncError"] do
        parent = issue["parent"] && linked(items, issue["parent"])

        blockers =
          for ref <- issue["blockedBy"] || [], blocker = linked(items, ref), do: blocker["id"]

        # Dependencies on tasks with no issue are the plan's own and stay.
        own = Enum.reject(item["after"], &get_in(items, [&1, "issue"]))

        # GitHub names the parent of a task with an issue; one with no issue is the plan's.
        parent =
          cond do
            parent -> parent["id"]
            issue["parent"] -> item["parent"]
            get_in(items, [item["parent"], "issue"]) -> nil
            true -> item["parent"]
          end

        fields = %{"after" => Enum.uniq(own ++ blockers), "parent" => parent}

        case Plan.update(items, item["id"], fields, now) do
          {:ok, items, _old, _new} -> items
          {:error, _} -> items
        end
      else
        _ -> items
      end
    end)
  end

  # A milestone of the plan for each issue milestone, waiting for the tasks it holds.
  # A task whose listed issue left the milestone stops holding it up.
  defp milestones(items, issues, projects, now, new_id) do
    listed =
      Map.new(issues, fn issue ->
        {key(issue),
         issue["milestone"] && Map.put(issue["milestone"], "repository", issue["repository"])}
      end)

    left? = fn milestone, id ->
      issue = get_in(items, [id, "issue"])

      issue != nil and Map.has_key?(listed, key(issue)) and
        not Plan.same_ref?(listed[key(issue)], milestone)
    end

    # Every imported milestone, holding a listed issue or no longer, lets go first.
    items =
      Enum.reduce(items, items, fn {id, item}, items ->
        with ref when is_map(ref) <- item["milestone"],
             nil <- item["syncError"],
             kept = Enum.reject(item["after"], &left?.(ref, &1)),
             true <- kept != item["after"],
             {:ok, items, _old, _new} <- Plan.update(items, id, %{"after" => kept}, now) do
          items
        else
          _ -> items
        end
      end)

    issues
    |> Enum.filter(&is_map(&1["milestone"]))
    |> Enum.group_by(&{String.downcase(&1["repository"]), &1["milestone"]["number"]})
    |> Enum.reduce(items, fn {_, [first | _] = held}, items ->
      ref = Map.put(first["milestone"], "repository", first["repository"])
      tasks = for issue <- held, task = linked(items, issue), do: task["id"]

      case Enum.find_value(items, fn {_, item} ->
             if Plan.same_ref?(item["milestone"], ref), do: item
           end) do
        nil ->
          project = project_of(projects, first["repository"])

          fields = %{
            "kind" => "milestone",
            "title" => ref["title"],
            "due" => ref["dueOn"],
            "after" => tasks,
            "projectId" => project && project["id"]
          }

          case Plan.add(items, new_id.(), fields, now) do
            {:ok, items, item} -> Map.put(items, item["id"], Map.put(item, "milestone", ref))
            {:error, _} -> items
          end

        %{"syncError" => error} when is_binary(error) ->
          items

        milestone ->
          fields = %{
            "title" => ref["title"],
            "due" => ref["dueOn"],
            "after" => Enum.uniq(milestone["after"] ++ tasks)
          }

          case Plan.update(items, milestone["id"], fields, now) do
            {:ok, items, _old, new} -> Map.put(items, new["id"], Map.put(new, "milestone", ref))
            {:error, _} -> items
          end
      end
    end)
  end

  defp dates(items, nil, _now), do: items

  defp dates(items, board, now) do
    Enum.reduce(items, items, fn {id, item}, items ->
      case item["issue"] && board[key(item["issue"])] do
        nil ->
          items

        on_board ->
          dates =
            if item["syncError"],
              do: %{},
              else: Map.take(on_board, ~w(start due))

          items =
            case Plan.update(items, id, dates, now) do
              {:ok, items, _old, _new} -> items
              {:error, _} -> items
            end

          put_in(items[id]["boardItemId"], on_board["itemId"])
      end
    end)
  end

  # The pull requests' states; a task whose last open one merged is done, when the
  # planner is set to.
  defp pull_requests(items, prs, _settings, _now) when prs == %{}, do: items

  defp pull_requests(items, prs, settings, now) do
    Map.new(items, fn {id, item} ->
      old = item["pullRequests"] || []
      new = Enum.map(old, &Map.put(&1, "state", prs[key(&1)] || &1["state"]))
      merged = new != [] and Enum.all?(new, &(&1["state"] == "merged"))
      newly = merged and not Enum.all?(old, &(&1["state"] == "merged"))

      item = if new == old, do: item, else: %{item | "pullRequests" => new, "updatedAt" => now}

      item =
        if newly and settings["doneWhenMerged"] != false and
             item["status"] not in ~w(done dropped),
           do: %{item | "status" => "done", "updatedAt" => now},
           else: item

      {id, item}
    end)
  end

  # --- pushing ------------------------------------------------------------------------------

  @doc """
  What GitHub is asked when `old` becomes `new` (in `items`) and the plan syncs both
  ways: the issue's title, body, state, assignee and labels, its blocking issues and
  sub-issues, its dates on the board, and a milestone's title, date and the issues it
  holds. Each op is `{method, input}` for `HalC2.Plugins.Host.issues/3`, or
  `{:board, input}` to put the issue on the board before its dates are set. Each asks
  through a project of `projects` (`HalC2.Plugins.Host.projects/1`), which the caller
  reads, as that runs git.

  A task GitHub refused a change to is pushed whole: its issue's fields but the
  assignees, the dates it has on the board and, for a milestone, its title, date and
  the issues it holds, so a change refused before goes again with the next, and the
  mark clears once all of it took.
  """
  def pushes(%{"sync" => "twoWay"} = settings, old, new, items, projects) do
    with %{"repository" => repo, "number" => number} <- new["issue"] || new["milestone"],
         project when is_binary(project) <- project_id(new, projects) do
      base = %{"projectId" => project, "repository" => repo, "number" => number}

      if new["issue"],
        do: issue_pushes(settings, base, old, new, items, projects),
        else: milestone_pushes(base, old, new, items, projects)
    else
      _ -> []
    end
  end

  def pushes(_settings, _old, _new, _items, _projects), do: []

  # A task GitHub refused a change to sends its fields whole and the dates it has; its
  # owner, blocking issues and parent go only as they changed. A date it never had
  # stays off a board that may lack the field for it.
  defp issue_pushes(settings, base, old, new, items, projects) do
    again? = is_binary(new["syncError"])
    changed = fn key -> again? or old[key] != new[key] end
    dated = fn key -> old[key] != new[key] or (again? and new[key] != nil) end

    patch =
      %{}
      |> put_if(changed.("title"), "title", new["title"])
      |> put_if(changed.("notes"), "body", new["notes"])
      # The task holds one of the issue's assignees: sent again, it would drop the rest.
      |> put_if(old["owner"] != new["owner"], "assignees", List.wrap(new["owner"]))
      |> put_if(changed.("labels"), "labels", new["labels"])
      |> Map.merge(state(if(again?, do: :again, else: old["status"]), new["status"]))

    # Only a task with an issue can be named on GitHub; the others stay in the plan.
    ref = fn id ->
      case items[id] do
        %{"issue" => %{} = issue} -> Map.take(issue, ~w(repository number))
        _ -> nil
      end
    end

    blocked =
      for(
        id <- new["after"] -- old["after"],
        r = ref.(id),
        do: {"addBlockedBy", Map.put(base, "blockedBy", r)}
      ) ++
        for id <- old["after"] -- new["after"],
            r = ref.(id),
            do: {"removeBlockedBy", Map.put(base, "blockedBy", r)}

    me = Map.take(base, ~w(repository number))

    parent =
      if old["parent"] != new["parent"] do
        for {method, id} <- [{"removeSubIssue", old["parent"]}, {"addSubIssue", new["parent"]}],
            r = id && ref.(id),
            project = project_id(items[id], projects),
            do:
              {method,
               %{
                 "projectId" => project,
                 "repository" => r["repository"],
                 "number" => r["number"],
                 "subIssue" => me
               }}
      else
        []
      end

    [if(patch != %{}, do: {"update", Map.merge(base, patch)})] ++
      blocked ++ parent ++ board_pushes(settings, base, dated, new)
  end

  defp board_pushes(settings, base, changed, new) do
    with [owner, number] <- String.split(String.trim(settings["board"] || ""), "/") do
      board = %{
        "projectId" => base["projectId"],
        "owner" => owner,
        "number" => String.to_integer(number)
      }

      sets =
        for {key, field} <- [{"start", settings["startField"]}, {"due", settings["targetField"]}],
            changed.(key),
            is_binary(field) and field != "",
            do: {"setBoardField", Map.merge(board, %{"field" => field, "value" => new[key]})}

      cond do
        sets == [] ->
          []

        new["boardItemId"] ->
          Enum.map(sets, fn {m, input} -> {m, Map.put(input, "itemId", new["boardItemId"])} end)

        true ->
          [{:board, Map.put(board, "item", Map.take(base, ~w(repository number)))} | sets]
      end
    else
      _ -> []
    end
  end

  defp milestone_pushes(base, old, new, items, projects) do
    again? = is_binary(new["syncError"])
    changed = fn key -> again? or old[key] != new[key] end

    patch =
      %{}
      |> put_if(changed.("title"), "title", new["title"])
      |> put_if(changed.("due"), "dueOn", new["due"])

    [if(patch != %{}, do: {"updateMilestone", Map.merge(base, patch)})] ++
      held_pushes(new, if(again?, do: [], else: old["after"]), items, projects)
  end

  # The tasks a milestone of GitHub's gained move their issues to it, and those it lost
  # leave it, unless another milestone of the repository holds them: a task moved from
  # one milestone to another is asked of GitHub once, by the one it moved to. Only an
  # issue of the milestone's repository can be in it.
  defp held_pushes(%{"milestone" => ref} = new, before, items, projects) do
    holds? = fn id ->
      Enum.any?(items, fn {other, item} ->
        other != new["id"] and is_map(item["milestone"]) and
          same?(item["milestone"]["repository"], ref["repository"]) and id in item["after"]
      end)
    end

    moves =
      Enum.map(new["after"] -- before, &{&1, ref["number"]}) ++
        for id <- before -- new["after"], not holds?.(id), do: {id, nil}

    for {id, milestone} <- moves,
        %{"issue" => %{} = issue} = task <- [items[id]],
        same?(issue["repository"], ref["repository"]),
        project = project_id(task, projects),
        is_binary(project),
        do:
          {"update",
           %{
             "projectId" => project,
             "repository" => issue["repository"],
             "number" => issue["number"],
             "milestone" => milestone
           }}
  end

  defp state(:again, "done"), do: state(nil, "done")
  defp state(:again, "dropped"), do: state(nil, "dropped")
  defp state(:again, _new), do: %{"state" => "open"}
  defp state(old, new) when old == new, do: %{}
  defp state(_old, "done"), do: %{"state" => "closed", "stateReason" => "completed"}
  defp state(_old, "dropped"), do: %{"state" => "closed", "stateReason" => "not_planned"}
  defp state(old, _new) when old in ~w(done dropped), do: %{"state" => "open"}
  defp state(_old, _new), do: %{}

  @doc """
  Asks GitHub for `ops` in order until one is refused: `{nil, extra}` when all took,
  `{message, extra}` when one did not. `extra` holds what the task learnt, such as its
  board item.
  """
  def run(ops) do
    Enum.reduce_while(Enum.reject(ops, &is_nil/1), {nil, %{}}, fn
      {:board, input}, {nil, extra} ->
        case Host.issues(@id, "addBoardItem", input) do
          {:ok, %{"itemId" => item}} -> {:cont, {nil, Map.put(extra, "boardItemId", item)}}
          {:error, error} -> {:halt, {message(error), extra}}
        end

      {"setBoardField", input}, {nil, extra} ->
        input = Map.put_new(input, "itemId", extra["boardItemId"])
        result(Host.issues(@id, "setBoardField", input), extra)

      {method, input}, {nil, extra} ->
        result(Host.issues(@id, method, input), extra)
    end)
  end

  defp result({:ok, _}, extra), do: {:cont, {nil, extra}}
  defp result({:error, error}, extra), do: {:halt, {message(error), extra}}

  @doc "`{:ok, issue}`, a new issue in `repository` made of `item`, as a link to it."
  def create_issue(item, repository) do
    with {:ok, projects} <- Host.projects(@id),
         %{} = project <-
           project_of(projects, repository) ||
             {:error, "No project on this MC has the repository #{repository}."},
         input = %{
           "projectId" => project["id"],
           "repository" => repository,
           "title" => item["title"],
           "body" => item["notes"] || ""
         },
         input = if(item["owner"], do: Map.put(input, "assignees", [item["owner"]]), else: input),
         input = if(labels?(item), do: Map.put(input, "labels", item["labels"]), else: input),
         {:ok, issue} <- Host.issues(@id, "create", input) do
      {:ok, Map.take(issue, ~w(repository number url state title))}
    else
      {:error, error} -> {:error, message(error)}
    end
  end

  # --- helpers -----------------------------------------------------------------------------

  defp linked(items, ref),
    do:
      Enum.find_value(items, fn {_, item} -> if Plan.same_ref?(item["issue"], ref), do: item end)

  # The project of `projects` to ask GitHub through: the task's own when it has the
  # repository, or any project that has it.
  defp project_id(item, projects) do
    repo = (item["issue"] || item["milestone"] || %{})["repository"]
    own = Enum.find(projects, &(&1["id"] == item["projectId"] and same?(&1["repository"], repo)))
    (own || project_of(projects, repo) || %{})["id"]
  end

  defp labels?(item), do: item["labels"] not in [nil, []]

  defp project_of(projects, repo),
    do: Enum.find(projects, &(&1["kind"] == "github" and same?(&1["repository"], repo)))

  defp owner?(repository, owner),
    do:
      is_binary(repository) and
        String.downcase(hd(String.split(repository, "/"))) == String.downcase(owner)

  defp same?(a, b) when is_binary(a) and is_binary(b),
    do: String.downcase(a) == String.downcase(b)

  defp same?(_, _), do: false

  defp key(%{"repository" => repo, "number" => number}), do: {String.downcase(repo || ""), number}

  defp day(value) when is_binary(value) and byte_size(value) >= 10, do: binary_part(value, 0, 10)
  defp day(_), do: nil

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, false, _key, _value), do: map

  defp message(%{"message" => message}) when is_binary(message), do: message
  defp message(message) when is_binary(message), do: message
  defp message(other), do: inspect(other)
end
