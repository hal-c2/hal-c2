defmodule HalC2Plugins.Planner.Sync do
  @moduledoc """
  The plan and GitHub: what a look at the followed repositories, the board and the
  linked pull requests finds (`look/3`), how it changes the plan (`apply/5`), and
  what a change to a linked task asks of GitHub when the plan syncs both ways
  (`pushes/5`, run by `run/2`).

  GitHub wins over the plan for what it holds, except for a task whose last change
  GitHub refused (`syncError`): that one keeps the user's. A pushed task keeps what
  GitHub has of it (`synced`, see `synced/3`) until a push takes whole, and each push
  sends what the task has that GitHub has not, so a change refused goes again with the
  task's next one and the mark clears once GitHub has all of it. Pushes go one at a time
  per task, not per issue, so a milestone's move of an issue can reach GitHub after
  another milestone's; `reasserts/4` sets such an issue right. A task's state follows
  its issue only when the issue opens or closes, so a task the user marked doing stays
  doing while its issue stays open.
  """

  alias HalC2.Plugins.Host
  alias HalC2Plugins.Planner.Plan

  @id "planner"

  @doc """
  What GitHub holds for the plan: `issues` of the followed repositories (open, with
  the planner's label if one is set), `details` of linked issues not among them,
  the `board`'s items by issue, the `prs` linked tasks name by state, the
  repositories no project has (`unwatched`), the `problem` a part failed with and
  the MC's `projects`. `at` orders looks that overlap; `started` is when the look
  began by the clock.

  `before` is `{started, details}` of the look applied last, or nil. A repository's
  linked issues not among its open ones come from one listing of its issues updated
  since that look began, and one not updated since is the detail that look had, so
  only an issue neither has is read alone, or every one the listing lacks when it
  fails or is cut short.
  """
  def look(settings, items, before) do
    at = System.monotonic_time()
    started = DateTime.utc_now()

    case Host.projects(@id) do
      {:ok, projects} ->
        github = Enum.filter(projects, &(&1["kind"] == "github" and is_binary(&1["repository"])))

        found = %{
          at: at,
          started: started,
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
            do: found |> issues(settings, items, github, before) |> board(settings, github),
            else: found

        prs(found, items, github)

      {:error, error} ->
        %{
          at: at,
          started: started,
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

  defp issues(found, settings, items, github, before) do
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

    # The linked issues of the followed repositories that left the list (closed, or their
    # label taken off), by repository.
    shown = MapSet.new(listed, &key/1)

    missing =
      for {_, %{"issue" => %{"repository" => repo, "number" => _} = ref}} <- items,
          Enum.any?(repos, &same?(&1, repo)),
          not MapSet.member?(shown, key(ref)),
          project_of(github, repo),
          do: Map.take(ref, ~w(repository number))

    {details, problems} =
      for {_, [%{"repository" => repo} | _] = refs} <-
            Enum.group_by(missing, &String.downcase(&1["repository"])),
          reduce: {[], problems} do
        {details, problems} ->
          project = project_of(github, repo)
          {known, alone} = updated(project, repo, refs, before)

          for %{"number" => number} <- alone, reduce: {known ++ details, problems} do
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
      end

    problem(%{found | issues: listed, details: details, unwatched: unwatched}, problems)
  end

  # Of the linked issues `refs` of `repo` missing from its open ones, those GitHub lists
  # as updated since the look `before` began, those that look had and GitHub has not
  # updated since, and the rest, to be read alone. A listing that fails or is cut short
  # says nothing of the issues it lacks. GitHub stamps updates by its own clock, which
  # the MC's may run ahead of, so the listing reaches back `skew_seconds` further.
  defp updated(_project, _repo, refs, nil), do: {[], refs}

  defp updated(project, repo, refs, {started, had}) do
    since = started |> DateTime.add(-skew_seconds(), :second) |> DateTime.truncate(:millisecond)

    input = %{
      "projectId" => project["id"],
      "repository" => repo,
      "state" => "all",
      "since" => DateTime.to_iso8601(since),
      "limit" => 500
    }

    wanted = MapSet.new(refs, &key/1)

    case Host.issues(@id, "list", input) do
      {:ok, %{"issues" => issues} = list} ->
        fresh = Enum.filter(issues, &MapSet.member?(wanted, key(&1)))
        got = MapSet.new(fresh, &key/1)
        rest = Enum.reject(refs, &MapSet.member?(got, key(&1)))
        had = if list["truncated"], do: %{}, else: Map.new(had, &{key(&1), &1})
        {same, alone} = Enum.split_with(rest, &is_map_key(had, key(&1)))
        {fresh ++ Enum.map(same, &had[key(&1)]), alone}

      {:error, _} ->
        {[], refs}
    end
  end

  defp skew_seconds, do: Application.get_env(:hal_c2, :planner_skew_seconds, 300)

  defp board(found, settings, github) do
    with {:ok, owner, number} <- board_name(settings["board"]),
         [_ | _] <- github do
      case read_board(github, owner, number, 500) do
        {:ok, %{"items" => board_items} = read} ->
          # Only the dates the settings name, from fields the board has as dates: one
          # empty there is cleared, while a field it lacks (renamed, deleted, or not a
          # date) says nothing, and the task keeps its date.
          fields = for %{"type" => "date", "name" => name} <- read["fields"] || [], do: name

          named =
            for {date, field} <- [
                  {"start", settings["startField"]},
                  {"due", settings["targetField"]}
                ],
                is_binary(field),
                name = Enum.find(fields, &same?(&1, String.trim(field))),
                do: {date, name}

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

          # Only a complete read says an issue missing from it left the board.
          problem(%{found | board: {board, read["truncated"] != true}}, cut)

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

  # Linked pull requests of a repository a project checks out are read from its list,
  # any other alone through a checkout on its host; a merged one stays merged.
  defp prs(found, items, github) do
    linked =
      items
      |> Enum.flat_map(fn {_, item} -> item["pullRequests"] || [] end)
      |> Enum.reject(&(&1["state"] == "merged"))
      |> Enum.uniq_by(&key/1)

    {listed, alone} = Enum.split_with(linked, &project_of(github, &1["repository"]))

    found
    |> listed_prs(listed, github)
    |> lone_prs(alone, github)
  end

  defp listed_prs(found, [], _github), do: found

  defp listed_prs(found, listed, github) do
    ids = for pr <- listed, uniq: true, do: project_of(github, pr["repository"])["id"]
    input = %{"projectIds" => ids, "state" => "all", "limit" => 500}

    case pr_pages(input, MapSet.new(listed, &key/1), [], [], 20) do
      {:ok, entries, errors} ->
        prs = for entry <- entries, into: found.prs, do: {key(entry), entry["state"]}
        problem(%{found | prs: prs}, errors)

      {:error, error} ->
        problem(found, [message(error)])
    end
  end

  defp lone_prs(found, [], _github), do: found

  defp lone_prs(found, alone, github) do
    read =
      alone
      |> Task.async_stream(&lone_pr(&1, github), max_concurrency: 4, timeout: :infinity)
      |> Enum.map(fn {:ok, read} -> read end)

    prs = for {:ok, key, state} <- read, into: found.prs, do: {key, state}
    problem(%{found | prs: prs}, for({:error, error} <- read, do: error))
  end

  defp lone_pr(%{"repository" => repo, "number" => number} = pr, github) do
    host = URI.parse(pr["url"] || "").host || "github.com"

    if Enum.any?(github, &same?(&1["host"], host)) do
      input = %{"host" => host, "repository" => repo, "number" => number}

      case Host.pull_requests(@id, "summary", input) do
        {:ok, %{"state" => state}} -> {:ok, key(pr), state}
        {:error, error} -> {:error, "#{repo}##{number}: #{message(error)}"}
      end
    else
      {:error,
       "#{repo}##{number}: no project on this MC has a GitHub remote on #{host} to read it through."}
    end
  end

  # The repositories' pull requests, page by page until every one `wanted` is read,
  # carrying each repository on from where its last page stopped; a page that cannot be
  # carried on from is the last.
  defp pr_pages(input, wanted, entries, errors, pages) do
    with {:ok, list} <- Host.pull_requests(@id, "list", input) do
      page = list["entries"] || []
      entries = entries ++ page
      errors = errors ++ Enum.map(list["errors"] || [], & &1["message"])
      next = list["nextCursors"] || %{}
      wanted = MapSet.difference(wanted, MapSet.new(page, &key/1))

      cond do
        MapSet.size(wanted) == 0 ->
          {:ok, entries, errors}

        next != %{} and pages > 1 ->
          pr_pages(Map.put(input, "cursors", next), wanted, entries, errors, pages - 1)

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
  `items` with what `found` (`look/3`) holds: tasks for issues the plan does not
  have, linked tasks brought up to date, their subtasks and dependencies, a milestone
  for each issue milestone, board dates, and the pull requests' states. New items
  get ids from `new_id`. The tasks in `found.kept`, which the plan keeps as they are,
  keep their subtasks and dependencies, so the ones given to others are checked
  against them.
  """
  def apply(items, found, settings, now, new_id) do
    {items, open} =
      if settings["sync"] in ~w(import twoWay) do
        listed = found.issues
        issues = Enum.uniq_by(listed ++ found.details, &key/1)
        projects = found.projects || []

        items =
          items
          |> then(
            &Enum.reduce(issues, &1, fn issue, items ->
              issue(items, issue, issue in listed, projects, now, new_id)
            end)
          )
          |> relations(issues, Map.get(found, :kept, %{}), now)
          |> milestones(issues, found.items, settings, projects, now, new_id)
          |> dates(found.board, now)

        open = for issue <- issues, issue["state"] == "open", into: MapSet.new(), do: key(issue)
        {items, open}
      else
        {items, MapSet.new()}
      end

    pull_requests(items, found.prs, settings, open, now)
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

        # GitHub's own first assignee may be no login `Plan` takes; it must not
        # veto the task the issue otherwise makes, so it is made ownerless then.
        added =
          case Plan.add(items, new_id.(), fields, now) do
            {:error, _} -> Plan.add(items, new_id.(), Map.delete(fields, "owner"), now)
            added -> added
          end

        case added do
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
        # A closed issue's reason says done or dropped, so it counts as its state.
        # A closed issue's reason, done or dropped, counts as part of its state.
        was = item["issue"]

        unchanged =
          issue["state"] == was["state"] and
            (issue["state"] != "closed" or issue["stateReason"] == was["stateReason"])

        status =
          cond do
            unchanged ->
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
            "owner" => owner(item, issue),
            "labels" => issue["labels"] || []
          })

        # As where an issue is first linked: GitHub's own assignee may be no
        # login `Plan` takes, and must not veto the rest of what GitHub says.
        items =
          case Plan.update(items, item["id"], fields, now) do
            {:ok, items, _old, _new} ->
              items

            {:error, _} ->
              case Plan.update(items, item["id"], Map.delete(fields, "owner"), now) do
                {:ok, items, _old, _new} -> items
                {:error, _} -> items
              end
          end

        # The task now has GitHub's, so what a push left it of GitHub's goes.
        item = Map.replace(items[item["id"]], "synced", nil)
        issue_ref = Map.merge(item["issue"], link["issue"])

        item =
          if issue_ref == item["issue"],
            do: item,
            else: %{item | "issue" => issue_ref, "updatedAt" => now}

        Map.put(items, item["id"], prs_of(item, issue, now))
    end
  end

  # The task's owner is one of the issue's assignees: the one it has while the issue
  # still lists them, as a push adds the new owner after the others, else the first.
  defp owner(item, issue) do
    assignees = issue["assignees"] || []
    Enum.find(assignees, &login?(&1, item["owner"])) || List.first(assignees)
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
  # its task, a `kept` task's own left as they are. GitHub's are judged together first,
  # so issues GitHub swapped, a parent put under its sub-issue and the dependency between
  # them turned around say, swap in the plan though either taken alone meets the other's
  # old ones in a loop. When GitHub's together would make a task its own subtask or wait
  # for itself, they go one at a time instead: one that would is left out, and one left
  # out goes again once the others are in.
  defp relations(items, issues, kept, now) do
    wanted = for issue <- issues, one = issue_relations(items, issue, kept), do: one

    target =
      Enum.reduce(wanted, items, fn {id, fields}, acc ->
        Map.update!(acc, id, &Map.merge(&1, fields))
      end)

    # Each task is checked going from its old ones to its new ones with every other task
    # already holding its new ones, so the tasks pass together only if the plan GitHub's
    # make has no loop.
    together =
      Enum.reduce_while(wanted, target, fn {id, fields}, acc ->
        case Plan.update(Map.put(acc, id, items[id]), id, fields, now) do
          {:ok, acc, _old, _new} -> {:cont, acc}
          {:error, _} -> {:halt, nil}
        end
      end)

    together || one_at_a_time(items, wanted, now)
  end

  defp one_at_a_time(items, wanted, now) do
    {items, refused} =
      Enum.reduce(wanted, {items, []}, fn {id, fields} = one, {items, refused} ->
        case Plan.update(items, id, fields, now) do
          {:ok, items, _old, _new} -> {items, refused}
          {:error, _} -> {items, refused ++ [one]}
        end
      end)

    if refused != [] and length(refused) < length(wanted),
      do: one_at_a_time(items, refused, now),
      else: items
  end

  # `{task id, fields}` with the subtask and dependencies GitHub gives the issue's task,
  # or nil when the issue has no task the look may change.
  defp issue_relations(items, issue, kept) do
    with %{} = item <- linked(items, issue),
         false <- is_map_key(kept, item["id"]),
         nil <- item["syncError"] do
      parent = issue["parent"] && linked(items, issue["parent"])

      blockers =
        for ref <- issue["blockedBy"] || [], blocker = linked(items, ref), do: blocker["id"]

      # Dependencies on tasks with no issue are the plan's own and stay.
      own = Enum.reject(item["after"], &get_in(items, [&1, "issue"]))

      # GitHub names the parent of a task with an issue, so one it no longer names, or
      # names an issue the plan has no task for, goes; one with no issue is the plan's.
      parent =
        cond do
          parent -> parent["id"]
          get_in(items, [item["parent"], "issue"]) -> nil
          true -> item["parent"]
        end

      {item["id"], %{"after" => Enum.uniq(own ++ blockers), "parent" => parent}}
    else
      _ -> nil
    end
  end

  # A milestone of the plan for each issue milestone, waiting for the tasks it holds.
  # A task whose listed issue left the milestone stops holding it up. Each task's issue
  # keeps the number of the milestone GitHub has it in (`issue["milestone"]`): when the
  # plan syncs both ways, a task whose issue GitHub has where it had it when the plan
  # was read (`read`) stays where the user put it, its move on the way to GitHub or
  # refused, so only the tasks whose issues GitHub moved since change milestone.
  defp milestones(items, issues, read, settings, projects, now, new_id) do
    listed =
      Map.new(issues, fn issue ->
        {key(issue),
         issue["milestone"] && Map.put(issue["milestone"], "repository", issue["repository"])}
      end)

    moved? = fn id, number ->
      settings["sync"] != "twoWay" or
        Map.get(get_in(read, [id, "issue"]) || %{}, "milestone", :none) != number
    end

    left? = fn milestone, id ->
      issue = get_in(items, [id, "issue"])

      issue != nil and Map.has_key?(listed, key(issue)) and
        not Plan.same_ref?(listed[key(issue)], milestone) and
        moved?.(id, listed[key(issue)]["number"])
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
      tasks = for issue <- held, task = linked(items, issue), do: task

      case Enum.find_value(items, fn {_, item} ->
             if Plan.same_ref?(item["milestone"], ref), do: item
           end) do
        nil ->
          project = project_of(projects, first["repository"])

          fields = %{
            "kind" => "milestone",
            "title" => ref["title"],
            "due" => ref["dueOn"],
            "after" => Enum.map(tasks, & &1["id"]),
            "projectId" => project && project["id"]
          }

          case Plan.add(items, new_id.(), fields, now) do
            {:ok, items, item} -> Map.put(items, item["id"], Map.put(item, "milestone", ref))
            {:error, _} -> items
          end

        %{"syncError" => error} when is_binary(error) ->
          items

        milestone ->
          moved = for task <- tasks, moved?.(task["id"], ref["number"]), do: task["id"]

          fields = %{
            "title" => ref["title"],
            "due" => ref["dueOn"],
            "after" => Enum.uniq(milestone["after"] ++ moved)
          }

          case Plan.update(items, milestone["id"], fields, now) do
            {:ok, items, _old, new} -> Map.put(items, new["id"], Map.put(new, "milestone", ref))
            {:error, _} -> items
          end
      end
    end)
    |> then(
      &Enum.reduce(issues, &1, fn issue, items ->
        case linked(items, issue) do
          nil ->
            items

          task ->
            put_in(
              items[task["id"]]["issue"]["milestone"],
              get_in(issue, ["milestone", "number"])
            )
        end
      end)
    )
  end

  defp dates(items, nil, _now), do: items

  defp dates(items, {board, complete?}, now) do
    Enum.reduce(items, items, fn {id, item}, items ->
      case item["issue"] && board[key(item["issue"])] do
        # Taken off the board: the next date pushed adds it back.
        nil when complete? ->
          Map.update!(items, id, &Map.replace(&1, "boardItemId", nil))

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
  # planner is set to. One that closes the task's issue, while the look read the issue
  # as `open`, does not make it done: the merge did not close the issue, or it was
  # reopened since, and the issue has the say.
  defp pull_requests(items, prs, _settings, _open, _now) when prs == %{}, do: items

  defp pull_requests(items, prs, settings, open, now) do
    Map.new(items, fn {id, item} ->
      old = item["pullRequests"] || []
      new = Enum.map(old, &Map.put(&1, "state", prs[key(&1)] || &1["state"]))
      merged = new != [] and Enum.all?(new, &(&1["state"] == "merged"))
      open? = item["issue"] != nil and MapSet.member?(open, key(item["issue"]))

      newly =
        merged and
          Enum.any?(old, fn pr ->
            pr["state"] != "merged" and not (open? and pr["fromIssue"] == true)
          end)

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
  What GitHub has of a task that changed from `old` to `new`, as far as the plan
  knows: the `synced` a push left on it until a push took whole, or else what `old`
  had, GitHub having taken or given all of it. A task linked to another issue loses
  its `synced`, so what it had before stands for the new issue, which pushes only
  what the change itself made, but for its relations, which GitHub has on the issue
  they were made on, its `"issue"`. Its `"state"` is the issue's: open, done or dropped,
  and its `"refs"` the issues of the tasks it waits for and of its parent in `before`,
  the plan before the change, so a relation to a task removed or linked to another
  issue since is still dropped on GitHub. Its relations are only those to tasks with an
  issue, all GitHub can have, and none for a task with no issue: one to a task given an
  issue since goes with the next push.
  """
  def synced(old, new, before), do: new["synced"] || own(old, before)

  defp own(item, items) do
    ids = if item["issue"] || item["milestone"], do: [item["parent"] | item["after"]], else: []
    refs = for id <- ids, r = ref(items, id), into: %{}, do: {id, r}

    item
    |> fields()
    |> Map.merge(%{
      "after" => Enum.filter(item["after"], &is_map_key(refs, &1)),
      "parent" => if(is_map_key(refs, item["parent"]), do: item["parent"]),
      "refs" => refs,
      "issue" => item["issue"] && Map.take(item["issue"], ~w(repository number))
    })
  end

  @doc """
  What GitHub has of a task once it made an issue of `sent` (`create_issue/2`), of
  which it had `synced` (`synced/3`): the title, notes, owner and labels it was made
  with, open, with no dates on the board, and the relations of `synced`, so a push
  closes it, dates it and relates it as the task has it.
  """
  def created(synced, sent),
    do:
      synced
      |> Map.merge(Map.take(sent, ~w(title notes labels)))
      # Only the owner GitHub was actually asked to assign is one it has.
      |> Map.put("owner", if(login_shaped?(sent["owner"]), do: sent["owner"]))
      |> Map.merge(%{"state" => "open", "start" => nil, "due" => nil})

  defp fields(item),
    do:
      item
      |> Map.take(~w(title notes owner labels start due after parent))
      |> Map.put("state", state_of(item["status"]))

  # The issue of the task `id` of `items`, as a relation names it, or nil: only a task
  # with an issue can be related on GitHub; the others stay in the plan.
  defp ref(items, id) do
    case items[id] do
      %{"issue" => %{} = issue} -> Map.take(issue, ~w(repository number))
      _ -> nil
    end
  end

  # The issue GitHub relates a task to the task `id` by: the one the relation was made
  # with, which a task removed, unlinked or relinked since no longer names, or else the
  # task's.
  defp had(synced, items, id), do: (synced["refs"] || %{})[id] || ref(items, id)

  # What GitHub has of a task once it relates it, under `key`, to the task `id` of the
  # issue `ref`, or stops.
  # A relation made again, as one GitHub was never asked to drop from an issue no project
  # has, is had once.
  defp relate(synced, "after", id, ref),
    do: synced |> Map.update!("after", &Enum.uniq(&1 ++ [id])) |> remember(id, ref)

  defp relate(synced, "parent", id, ref), do: synced |> Map.put("parent", id) |> remember(id, ref)

  defp unrelate(synced, "after", id), do: Map.update!(synced, "after", &(&1 -- [id]))
  defp unrelate(synced, "parent", _id), do: Map.put(synced, "parent", nil)

  defp remember(synced, id, ref),
    do: Map.put(synced, "refs", Map.put(synced["refs"] || %{}, id, ref))

  defp state_of(status) when status in ~w(done dropped), do: status
  defp state_of(_status), do: "open"

  @doc """
  What GitHub is asked when the plan syncs both ways and `new` (in `items`) differs
  from what GitHub has of it (`synced`, see `synced/3`): the issue's title, body,
  state, assignees (the new owner added and the old one removed, one login at a time,
  so the issue's other assignees stay) and labels, its
  blocking issues and sub-issues, its dates on the
  board, and a milestone's title, date and the issues it holds. Each op is
  `{method, input, took}` for `HalC2.Plugins.Host.issues/3`, the method `:board`
  putting the issue on the board before its dates are set, and `took` what GitHub has
  once it took. Each asks through a project of `projects`
  (`HalC2.Plugins.Host.projects/1`), which the caller reads, as that runs git.

  `[]` when GitHub has all of `new`, nil when the plan does not push it.
  """
  def pushes(%{"sync" => "twoWay"} = settings, synced, new, items, projects) do
    with %{"repository" => repo, "number" => number} <- new["issue"] || new["milestone"],
         project when is_binary(project) <- project_id(new, projects) do
      base = %{"projectId" => project, "repository" => repo, "number" => number}

      if new["issue"],
        do: issue_pushes(settings, base, synced, new, items, projects),
        else: milestone_pushes(base, synced, new, items, projects)
    else
      _ -> nil
    end
  end

  def pushes(_settings, _synced, _new, _items, _projects), do: nil

  defp issue_pushes(settings, base, synced, new, items, projects) do
    differs = &(synced[&1] != new[&1])
    state = state_of(new["status"])

    patch =
      %{}
      |> put_if(differs.("title"), "title", new["title"])
      |> put_if(differs.("notes"), "body", new["notes"])
      |> put_if(differs.("labels"), "labels", new["labels"])
      |> Map.merge(if(synced["state"] == state, do: %{}, else: state(state)))

    update =
      if patch != %{},
        do: [
          {"update", Map.merge(base, patch),
           &Map.merge(&1, Map.take(fields(new), ~w(title notes labels state)))}
        ],
        else: []

    # GitHub has the relations of `synced` on the issue they were made on, `was`: a task
    # linked to another issue since drops them from that one and makes them anew on its
    # own, and one to a task linked to another issue since goes from the issue it had to
    # its new one. The drops go first: once a relation is made on the task's issue,
    # GitHub has all the task's relations there. An issue of a repository no project has
    # was never pushed, so it has nothing to drop.
    me = Map.take(base, ~w(repository number))
    was = Map.get(synced, "issue", me)
    moved? = not Plan.same_ref?(was, me)
    on_was = was && Map.put(was, "projectId", project_id(Map.put(new, "issue", was), projects))
    pushed = is_binary(on_was["projectId"]) && was

    # The old owner comes off the issue they were synced to (`was`), the new one goes
    # on the task's own: a relink and an owner change can land in one chained push.
    update = update ++ owner_pushes(base, if(pushed, do: on_was), synced, new)
    kept? = &(not moved? and Plan.same_ref?(had(synced, items, &1), ref(items, &1)))
    kept = Enum.filter(synced["after"], &(&1 in new["after"] and kept?.(&1)))
    onto = &Map.put(&1, "issue", me)

    unblock =
      for id <- synced["after"] -- kept,
          pushed,
          r = had(synced, items, id),
          do: {"removeBlockedBy", Map.put(on_was, "blockedBy", r), &unrelate(&1, "after", id)}

    block =
      for id <- new["after"] -- kept,
          r = ref(items, id),
          do:
            {"addBlockedBy", Map.put(base, "blockedBy", r),
             &(&1 |> relate("after", id, r) |> onto.())}

    {from, to} = {synced["parent"], new["parent"]}

    parent =
      if from == to and (from == nil or kept?.(from)) do
        []
      else
        for {method, id, r, sub, took} <- [
              {"removeSubIssue", from, had(synced, items, from), pushed,
               &unrelate(&1, "parent", from)},
              {"addSubIssue", to, ref(items, to), me,
               &(&1 |> relate("parent", to, ref(items, to)) |> onto.())}
            ],
            r && sub,
            project = project_id(Map.put(items[id] || %{}, "issue", r), projects),
            do:
              {method,
               %{
                 "projectId" => project,
                 "repository" => r["repository"],
                 "number" => r["number"],
                 "subIssue" => sub
               }, took}
      end

    {unsub, sub} = Enum.split_with(parent, &(elem(&1, 0) == "removeSubIssue"))

    update ++ unblock ++ unsub ++ block ++ sub ++ board_pushes(settings, base, differs, new)
  end

  # The task holds one of the issue's assignees, so a new owner replaces only the old
  # one: the old comes off first, then the new goes on, and GitHub has the owner it took
  # last, so a refusal in between sends only what is left.
  defp owner_pushes(base, on_was, synced, new) do
    old = synced["owner"]
    login = new["owner"]
    # GitHub reads a login whatever its case, so a change of case alone pushes nothing.
    changed? = old != login and not login?(old, login)

    # A stored owner from before owners had to be logins can be free text; it is
    # no GitHub assignee under that string, so there is nothing to take off, and
    # asking would be refused before GitHub and wedge every later push.
    off =
      if changed? and login_shaped?(old) and not is_nil(on_was),
        do: [
          {"removeAssignees", Map.put(on_was, "assignees", [old]), &Map.put(&1, "owner", nil)}
        ],
        else: []

    on =
      if changed? and login_shaped?(login),
        do: [{"addAssignees", Map.put(base, "assignees", [login]), &Map.put(&1, "owner", login)}],
        else: []

    off ++ on
  end

  defp board_pushes(settings, base, differs, new) do
    with [owner, number] <- String.split(String.trim(settings["board"] || ""), "/") do
      board = %{
        "projectId" => base["projectId"],
        "owner" => owner,
        "number" => String.to_integer(number)
      }

      dates =
        for {key, field} <- [{"start", settings["startField"]}, {"due", settings["targetField"]}],
            is_binary(field) and field != "",
            do: {key, field}

      set = fn {key, field} ->
        {"setBoardField", Map.merge(board, %{"field" => field, "value" => new[key]}),
         &Map.put(&1, key, new[key])}
      end

      sets = for {key, _} = date <- dates, differs.(key), do: set.(date)

      cond do
        sets == [] ->
          []

        new["boardItemId"] ->
          for {m, input, took} <- sets,
              do: {m, Map.put(input, "itemId", new["boardItemId"]), took}

        # A new board item holds none of the task's dates, so it is given each one the
        # task has. GitHub has none of them until each is set, so one refused goes again.
        true ->
          item = Map.put(board, "item", Map.take(base, ~w(repository number)))
          unset = &Map.merge(&1, Map.new(dates, fn {key, _} -> {key, nil} end))
          [{:board, item, unset} | for({key, _} = date <- dates, new[key], do: set.(date))]
      end
    else
      _ -> []
    end
  end

  defp milestone_pushes(base, synced, new, items, projects) do
    patch =
      %{}
      |> put_if(synced["title"] != new["title"], "title", new["title"])
      |> put_if(synced["due"] != new["due"], "dueOn", new["due"])

    update =
      if patch != %{},
        do: [
          {"updateMilestone", Map.merge(base, patch),
           &Map.merge(&1, Map.take(new, ~w(title due)))}
        ],
        else: []

    update ++ held_pushes(new, synced, items, projects)
  end

  # The tasks a milestone of GitHub's gained move their issues to it, and those it lost
  # leave it, unless another milestone of the repository holds them: a task moved from
  # one milestone to another is asked of GitHub once, by the one it moved to. GitHub
  # takes other milestones' moves while one waits on its push, and the one a task moved
  # to can lose it before it asks, so where GitHub has each issue (`issue["milestone"]`)
  # counts too: a task the milestone holds whose issue GitHub has elsewhere moves to it,
  # and one no milestone holds whose issue GitHub has in one of the plan's leaves it.
  # Only an issue of the milestone's repository can be in it.
  defp held_pushes(%{"milestone" => ref} = new, synced, items, projects) do
    holds? = &(holders(items, ref["repository"], &1, new["id"]) != [])

    elsewhere? =
      &(Map.get(items[&1]["issue"] || %{}, "milestone", ref["number"]) != ref["number"])

    planned =
      for {_, %{"milestone" => %{} = other}} <- items,
          same?(other["repository"], ref["repository"]),
          do: other["number"]

    left =
      for {id, %{"issue" => %{"milestone" => number} = issue}} <- items,
          number in planned,
          same?(issue["repository"], ref["repository"]),
          holders(items, ref["repository"], id) == [],
          do: id

    # A task linked to another issue since moves the issue it had out, whatever holds the
    # task, and its new one in.
    kept? = &Plan.same_ref?(had(synced, items, &1), ref(items, &1))
    kept = Enum.filter(synced["after"], &(&1 in new["after"] and kept?.(&1)))

    moves =
      for(
        id <- Enum.uniq((synced["after"] -- kept) ++ left),
        not holds?.(id) or not kept?.(id),
        issue = had(synced, items, id),
        do: {id, issue, nil, &unrelate(&1, "after", id)}
      ) ++
        for id <- Enum.uniq((new["after"] -- kept) ++ Enum.filter(new["after"], elsewhere?)),
            issue = ref(items, id),
            do: {id, issue, ref["number"], &relate(&1, "after", id, issue)}

    for {id, issue, milestone, took} <- moves,
        same?(issue["repository"], ref["repository"]),
        project = project_id(Map.put(items[id] || %{}, "issue", issue), projects),
        is_binary(project),
        do:
          {"update",
           %{
             "projectId" => project,
             "repository" => issue["repository"],
             "number" => issue["number"],
             "milestone" => milestone
           }, took}
  end

  # The numbers of the milestones of `repository` whose tasks hold the task `id`, but for
  # the milestone `except`.
  defp holders(items, repository, id, except \\ nil),
    do:
      for(
        {other, %{"milestone" => %{} = ref} = item} <- items,
        other != except,
        same?(ref["repository"], repository),
        id in item["after"],
        do: ref["number"]
      )

  @doc """
  What sets right the milestones of the issues a push moved (`moved`, see `run/2`) to
  where the plan no longer has them: GitHub keeps the move it takes last, and a push
  that took after another milestone's for the same issue, the task having moved on
  meanwhile, left it behind. Each op moves an issue to the milestone holding its task,
  or out of any, as `pushes/5` does; none goes for an issue the milestone's own `ops`
  move, or whose last move is where the plan has it, so a move that sets one right is
  only checked again, once it took.
  """
  def reasserts(moved, ops, items, projects) do
    sent = for {"update", %{"milestone" => _} = input, _} <- ops, do: key(input)

    for %{"milestone" => wrote} = issue <- moved |> Enum.reverse() |> Enum.uniq_by(&key/1),
        key(issue) not in sent,
        task = linked(items, issue),
        task != nil,
        held = holders(items, issue["repository"], task["id"]),
        if(held == [], do: wrote != nil, else: wrote not in held),
        project = project_id(Map.put(task, "issue", issue), projects),
        is_binary(project),
        do:
          {"update", Map.merge(issue, %{"projectId" => project, "milestone" => List.first(held)}),
           &unrelate(&1, "after", task["id"])}
  end

  @doc """
  `items` with the milestones GitHub took the issues `moved` (`run/2`) to, kept on
  their tasks' issues as a look reads them.
  """
  def landed(items, moved) do
    Enum.reduce(moved, items, fn move, items ->
      case linked(items, move) do
        nil -> items
        task -> put_in(items[task["id"]]["issue"]["milestone"], move["milestone"])
      end
    end)
  end

  defp state("done"), do: %{"state" => "closed", "stateReason" => "completed"}
  defp state("dropped"), do: %{"state" => "closed", "stateReason" => "not_planned"}
  defp state("open"), do: %{"state" => "open"}

  @doc """
  Asks GitHub for `ops` (`pushes/5`) in order until one is refused: `{nil, extra}`
  when all took, `{message, extra}` when one did not. `extra` holds what the task
  learnt: its board item, what GitHub has of it, `synced` with what took, the state
  and reason its issue took, `stated`, and the issues it moved to a milestone or out
  of one, `moved`, in the order GitHub took them.
  """
  def run(ops, synced) do
    {error, extra, synced} =
      Enum.reduce_while(ops, {nil, %{}, synced}, fn {method, input, took}, {nil, extra, synced} ->
        input =
          if method == "setBoardField",
            do: Map.put_new(input, "itemId", extra["boardItemId"]),
            else: input

        case ask(method, input) do
          {:ok, %{"itemId" => item}} when method == :board ->
            {:cont, {nil, Map.put(extra, "boardItemId", item), took.(synced)}}

          {:ok, _} when method != :board ->
            {:cont, {nil, extra |> moved(method, input) |> stated(method, input), took.(synced)}}

          {:error, error} ->
            {:halt, {message(error), extra, synced}}
        end
      end)

    {error, Map.put(extra, "synced", synced)}
  end

  defp moved(extra, "update", %{"milestone" => _} = input),
    do: Map.update(extra, "moved", [move(input)], &(&1 ++ [move(input)]))

  defp moved(extra, _method, _input), do: extra

  defp stated(extra, "update", %{"state" => state} = input),
    do: Map.put(extra, "stated", %{"state" => state, "stateReason" => input["stateReason"]})

  defp stated(extra, _method, _input), do: extra

  defp move(input), do: Map.take(input, ~w(repository number milestone))

  defp ask(:board, input), do: Host.issues(@id, "addBoardItem", input)

  # A relation GitHub says the issues already have, or do not have to remove, is what
  # the plan asked for: an earlier push took it without the plan hearing, say the
  # plugin stopped first. GitHub's wording for these is not documented, so the match
  # is narrow; a miss marks the task as not synced, as any refusal does.
  defp ask(method, input)
       when method in ~w(addBlockedBy addSubIssue removeBlockedBy removeSubIssue) do
    case Host.issues(@id, method, input) do
      {:error, error} = refused ->
        if had?(method, message(error)), do: {:ok, %{}}, else: refused

      answer ->
        answer
    end
  end

  defp ask(method, input), do: Host.issues(@id, method, input)

  defp had?(method, message) when method in ~w(addBlockedBy addSubIssue),
    do: message =~ ~r/already (exists|been taken|added)|duplicate/i

  defp had?(_method, message),
    do:
      message =~
        ~r/not (a sub-issue|blocked by)|(relationship|dependency|sub-issue) (was not found|does not exist)/i

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
         input =
           if(login_shaped?(item["owner"]),
             do: Map.put(input, "assignees", [item["owner"]]),
             else: input
           ),
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

  # Logins also compare without the blanks a stored owner may have around it.
  defp login?(a, b) when is_binary(a) and is_binary(b), do: same?(String.trim(a), String.trim(b))
  defp login?(_, _), do: false

  # The login shape `Plan.field("owner")` and the host enforce, duplicated here
  # because neither is callable from the plugin.
  defp login_shaped?(login) when is_binary(login),
    do:
      String.match?(
        String.trim(login),
        ~r/\A(?:[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}|[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,33}\[bot\]|(?=.{1,39}\z)[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*_[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*)\z/
      )

  defp login_shaped?(_), do: false

  defp key(%{"repository" => repo, "number" => number}), do: {String.downcase(repo || ""), number}

  defp day(value) when is_binary(value) and byte_size(value) >= 10, do: binary_part(value, 0, 10)
  defp day(_), do: nil

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, false, _key, _value), do: map

  defp message(%{"message" => message}) when is_binary(message), do: message
  defp message(message) when is_binary(message), do: message
  defp message(other), do: inspect(other)
end
