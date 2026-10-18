defmodule HalC2Plugins.Planner.Plan do
  @moduledoc """
  The rules of a plan, as plain functions over its items (id → item): what a task
  may hold, that nothing waits for itself or is its own subtask, what is derived
  for clients (late, early, progress, slip), how an agent's proposed changes apply,
  and the outline of the plan an agent's prompt gets.

  Every change goes through `add/4` or `update/4`, so an item that is stored has
  been checked against the others.
  """

  @fields ~w(title notes kind status start due progress parent after labels owner projectId)
  # What an agent's change may set; the project is the user's to pick.
  @change_fields @fields -- ["projectId"]
  @kinds ~w(task milestone)
  @statuses ~w(todo doing blocked done dropped)
  @closed ~w(done dropped)

  @layouts ~w(gantt board list)
  @group_by ~w(none status project label owner parent milestone)
  @sort_by ~w(manual start due title status progress)
  @zooms ~w(day week month quarter)
  @view_fields ~w(status owner start due progress labels project links)

  def fields, do: @fields
  def statuses, do: @statuses

  # --- items -----------------------------------------------------------------------------

  @doc """
  `{:ok, items, item}` with a new item `id` made of `fields`, last among its
  siblings, or `{:error, message}`.
  """
  def add(items, id, fields, now) do
    item = %{
      "id" => id,
      "title" => "",
      "notes" => "",
      "kind" => "task",
      "status" => "todo",
      "start" => nil,
      "due" => nil,
      "progress" => nil,
      "parent" => nil,
      "after" => [],
      "labels" => [],
      "owner" => nil,
      "projectId" => nil,
      "order" => 0,
      "issue" => nil,
      "milestone" => nil,
      "pullRequests" => [],
      "threads" => [],
      "feedback" => [],
      "note" => nil,
      "baseline" => nil,
      "syncError" => nil,
      "updatedAt" => now
    }

    with {:ok, fields} <- cast(fields, @fields),
         item = Map.merge(item, fields),
         item = Map.put(item, "order", next_order(items, item["parent"])),
         {:ok, item} <- check(items, item),
         do: {:ok, Map.put(items, id, item), item}
  end

  @doc """
  `{:ok, items, old, new}` with `fields` set on item `id`, or `{:error, message}`.
  Keys that are not fields of a task are left out, so a client may send an item back.
  """
  def update(_items, _id, fields, _now) when not is_map(fields),
    do: {:error, "Give the fields as an object."}

  def update(items, id, fields, now) do
    with %{} = old <- items[id] || {:error, "There is no task #{id}."},
         {:ok, fields} <- cast(Map.take(fields, @fields), @fields),
         new = Map.merge(old, fields),
         new =
           if(new["parent"] != old["parent"],
             do: Map.put(new, "order", next_order(items, new["parent"])),
             else: new
           ),
         {:ok, new} <- check(items, new) do
      new = if new == old, do: old, else: Map.put(new, "updatedAt", now)
      {:ok, Map.put(items, id, new), old, new}
    end
  end

  @doc """
  Item `id` gone: its subtasks move up to its parent and nothing waits for it any
  more.
  """
  def remove(items, id) do
    case Map.pop(items, id) do
      {nil, items} ->
        items

      {removed, items} ->
        Map.new(items, fn {key, item} ->
          item = if item["parent"] == id, do: %{item | "parent" => removed["parent"]}, else: item
          {key, Map.update!(item, "after", &List.delete(&1, id))}
        end)
    end
  end

  @doc """
  `{:ok, items}` with item `id` under `parent` (nil for the top), placed before its
  sibling `before` (nil for last); siblings are numbered again from 0.
  """
  def move(items, id, parent, before, now) do
    with {:ok, items, _old, item} <- update(items, id, %{"parent" => parent}, now) do
      siblings =
        items
        |> Map.values()
        |> Enum.filter(&(&1["parent"] == item["parent"] and &1["id"] != id))
        |> Enum.sort_by(&{&1["order"], &1["id"]})

      at = Enum.find_index(siblings, &(&1["id"] == before)) || length(siblings)

      items =
        siblings
        |> List.insert_at(at, item)
        |> Enum.with_index()
        |> Enum.reduce(items, fn {sibling, order}, items ->
          put_in(items[sibling["id"]]["order"], order)
        end)

      {:ok, items}
    end
  end

  # The fields of `fields` that a task may hold, checked one by one.
  defp cast(fields, allowed) when is_map(fields) do
    Enum.reduce_while(fields, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      if key in allowed do
        case field(key, value) do
          {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
          {:error, _} = error -> {:halt, error}
        end
      else
        {:halt, {:error, "#{key} is not a field a change can set."}}
      end
    end)
  end

  defp cast(_fields, _allowed), do: {:error, "Give the fields as an object."}

  defp field("title", value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, "A task needs a title."}
      title -> {:ok, title}
    end
  end

  defp field("title", _), do: {:error, "A task needs a title."}
  defp field("notes", nil), do: {:ok, ""}
  defp field("notes", value) when is_binary(value), do: {:ok, value}
  defp field("kind", value) when value in @kinds, do: {:ok, value}
  defp field("kind", value), do: {:error, "#{inspect(value)} is not a task or a milestone."}
  defp field("status", value) when value in @statuses, do: {:ok, value}

  defp field("status", value),
    do:
      {:error,
       "#{inspect(value)} is not a state a task can be in (#{Enum.join(@statuses, ", ")})."}

  defp field(date, value) when date in ~w(start due), do: date(date, value)
  defp field("progress", nil), do: {:ok, nil}

  defp field("progress", value) when is_number(value) and value >= 0 and value <= 100,
    do: {:ok, round(value)}

  defp field("progress", _), do: {:error, "progress is a number from 0 to 100."}

  defp field(id, value) when id in ~w(parent owner projectId) and value in [nil, ""],
    do: {:ok, nil}

  defp field(id, value) when id in ~w(parent owner projectId) and is_binary(value),
    do: {:ok, value}

  defp field(list, value) when list in ~w(after labels) and is_list(value) do
    if Enum.all?(value, &is_binary/1),
      do: {:ok, Enum.uniq(value)},
      else: {:error, "#{list} is a list of #{if list == "after", do: "task ids", else: "names"}."}
  end

  defp field(key, _value), do: {:error, "#{key} cannot hold that."}

  defp date(_key, nil), do: {:ok, nil}

  defp date(key, value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, _} -> {:ok, value}
      _ -> {:error, "#{key}: #{inspect(value)} is not a date (YYYY-MM-DD)."}
    end
  end

  defp date(key, value), do: {:error, "#{key}: #{inspect(value)} is not a date (YYYY-MM-DD)."}

  # `{:ok, item}` once it fits the plan: it has a title, what it names exists, it is
  # nobody's subtask or dependency through itself, and it ends no earlier than it starts.
  defp check(items, item) do
    id = item["id"]
    item = if item["kind"] == "milestone", do: %{item | "start" => nil}, else: item
    others = Map.put(items, id, item)

    cond do
      item["title"] == "" ->
        {:error, "A task needs a title."}

      item["parent"] == id ->
        {:error, "#{item["title"]} cannot be a subtask of itself."}

      item["parent"] != nil and others[item["parent"]] == nil ->
        {:error, "There is no task #{item["parent"]}."}

      missing = Enum.find(item["after"], &(others[&1] == nil)) ->
        {:error, "There is no task #{missing}."}

      id in ancestors(others, item["parent"]) ->
        {:error, "That would make #{item["title"]} a subtask of itself."}

      id in item["after"] or reaches?(others, item["after"], id) ->
        {:error, "That would make #{item["title"]} wait for itself."}

      item["start"] && item["due"] && item["start"] > item["due"] ->
        {:error, "#{item["title"]} cannot end before it starts."}

      true ->
        {:ok, item}
    end
  end

  defp ancestors(items, id, seen \\ [])
  defp ancestors(_items, nil, seen), do: seen

  defp ancestors(items, id, seen) do
    if id in seen, do: seen, else: ancestors(items, items[id]["parent"], [id | seen])
  end

  # Whether waiting on `ids` waits, through what they wait for, on `target`.
  defp reaches?(items, ids, target, seen \\ MapSet.new())
  defp reaches?(_items, [], _target, _seen), do: false

  defp reaches?(items, [id | rest], target, seen) do
    cond do
      id == target -> true
      MapSet.member?(seen, id) -> reaches?(items, rest, target, seen)
      true -> reaches?(items, (items[id]["after"] || []) ++ rest, target, MapSet.put(seen, id))
    end
  end

  defp next_order(items, parent) do
    items
    |> Map.values()
    |> Enum.filter(&(&1["parent"] == parent))
    |> Enum.map(& &1["order"])
    |> Enum.max(fn -> -1 end)
    |> Kernel.+(1)
  end

  # --- what clients see --------------------------------------------------------------------

  @doc """
  The items in order, each with what is derived from the plan on `today`:
  `late`, `early` (the ids it waits for that end on or after its start),
  `derivedProgress`, `slip` (days its due date moved past its baseline's) and
  `children`.
  """
  def derive(items, today) do
    children = Enum.group_by(Map.values(items), & &1["parent"])

    items
    |> Map.values()
    |> Enum.sort_by(&{&1["order"], &1["id"]})
    |> Enum.map(fn item ->
      # What GitHub has of the task is the sync's own; clients show `syncError`.
      item
      |> Map.delete("synced")
      |> Map.merge(%{
        "late" => late?(item, today),
        "early" => early(items, item),
        "derivedProgress" => progress(item, children),
        "slip" => slip(item),
        "children" => length(children[item["id"]] || [])
      })
    end)
  end

  def late?(item, today),
    do: item["due"] != nil and item["due"] < today and item["status"] not in @closed

  defp early(_items, %{"start" => nil}), do: []

  defp early(items, item) do
    for id <- item["after"],
        dep = items[id],
        dep["due"] != nil,
        if(dep["kind"] == "milestone",
          do: item["start"] < dep["due"],
          else: item["start"] <= dep["due"]
        ),
        do: id
  end

  # Done is done; then what the user set; then the share of its subtasks' progress,
  # dropped ones left out; then the share of its pull requests that merged.
  defp progress(item, children) do
    kids = Enum.reject(children[item["id"]] || [], &(&1["status"] == "dropped"))
    prs = item["pullRequests"] || []

    cond do
      item["status"] == "done" -> 100
      is_number(item["progress"]) -> item["progress"]
      kids != [] -> round(Enum.sum(Enum.map(kids, &progress(&1, children))) / length(kids))
      prs != [] -> round(100 * Enum.count(prs, &(&1["state"] == "merged")) / length(prs))
      true -> 0
    end
  end

  defp slip(%{"baseline" => %{"due" => base}, "due" => due})
       when is_binary(base) and is_binary(due),
       do: Date.diff(Date.from_iso8601!(due), Date.from_iso8601!(base))

  defp slip(_item), do: nil

  # --- an agent's changes --------------------------------------------------------------------

  @doc """
  `{:ok, changes}`, an agent's reported `changes` numbered `c1`… and checked against
  `items` as if applied in order, or `{:error, message}` saying what to fix. An
  added task's `ref` may be named by later changes in `parent` and `after`.
  """
  def check_changes(items, changes) when is_list(changes) do
    numbered =
      changes
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, []}, fn {change, i}, {:ok, acc} ->
        case change(change, i) do
          {:ok, change} -> {:cont, {:ok, [change | acc]}}
          {:error, message} -> {:halt, {:error, "Change #{i}: #{message}"}}
        end
      end)

    with {:ok, numbered} <- numbered do
      numbered = Enum.reverse(numbered)

      # Applied to a copy, every change must take; one that would not is the agent's to fix.
      {_items, applied} = apply_changes(items, numbered, "check", "", &check_id/1)

      case Enum.find(applied, &(&1["outcome"] == "stale")) do
        nil ->
          {:ok, numbered}

        stale ->
          {:error, "Change #{String.trim_leading(stale["id"], "c")}: #{stale["staleReason"]}"}
      end
    end
  end

  def check_changes(_items, _changes), do: {:error, "changes is a list."}

  defp check_id(i), do: "check-#{i}"

  defp change(%{"op" => op} = change, i) when op in ~w(update add remove link) do
    fields = change["fields"] || %{}
    reason = change["reason"]
    link = is_map(fields) and op == "link" and link_target(fields, ~w(pullRequest issue))

    cond do
      op != "add" and not is_binary(change["itemId"]) ->
        {:error, "#{op} names the task in itemId."}

      not is_map(fields) ->
        {:error, "fields is an object."}

      not (is_nil(reason) or is_binary(reason)) ->
        {:error, "reason is text."}

      op == "add" and not is_binary(fields["title"]) ->
        {:error, "a task it adds needs a title."}

      link == :error ->
        {:error,
         "link gives in fields just one of: a pullRequest or an issue as {repository, number}."}

      bad = op in ~w(update add) && Enum.find(Map.keys(fields), &(&1 not in @change_fields)) ->
        {:error, "#{bad} is not a field a change can set."}

      true ->
        {:ok,
         %{
           "id" => "c#{i}",
           "op" => op,
           "itemId" => if(op != "add", do: change["itemId"]),
           "ref" => if(op == "add", do: change["ref"] || "new-#{i}"),
           "fields" =>
             case op do
               "remove" -> %{}
               "link" -> elem(link, 1)
               _ -> fields
             end,
           "reason" => reason,
           "dismissed" => false,
           "outcome" => nil
         }}
    end
  end

  defp change(_change, _i), do: {:error, "op is update, add, remove or link."}

  @doc """
  `{:ok, %{kind => target}}` when `given` names just one thing to link to, of `kinds`,
  and names it well: a pullRequest or an issue as {repository, number} (`ref/1`), a
  threadId as text. Anything else in it, a second one included, is `:error`, so no part
  of a link is dropped.
  """
  def link_target(given, kinds) do
    case Map.reject(given, fn {_, value} -> is_nil(value) end) |> Map.to_list() do
      [{kind, value}] -> if kind in kinds, do: target(kind, value), else: :error
      _ -> :error
    end
  end

  defp target("threadId", value) when is_binary(value), do: {:ok, %{"threadId" => value}}
  defp target("threadId", _value), do: :error
  defp target(kind, value), do: with({:ok, ref} <- ref(value), do: {:ok, %{kind => ref}})

  @doc """
  `{:ok, ref}` with what the plan takes of a pull request or an issue a client or an
  agent names as {repository, number}, or `:error`. The rest it gives is dropped: the
  state is GitHub's, so a link starts open and the next look reads it, and a pull
  request linked once it merged moves its task as one seen to merge. A `url` stays when
  it is a web address of that very pull request or issue, as it names the host a
  repository the MC has no checkout of is read through (`Sync.look/3`, by host alone,
  the port left out as the remotes of a project leave it out); whether that host is one
  of the MC's is that read's to say.
  """
  def ref(%{"repository" => repository, "number" => number} = value)
      when is_binary(repository) and is_integer(number) do
    ref = %{"repository" => repository, "number" => number}

    case web_url(value["url"], repository, number) do
      nil -> {:ok, ref}
      url -> {:ok, Map.put(ref, "url", url)}
    end
  end

  def ref(_value), do: :error

  defp web_url(url, repository, number) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, path: path}
      when scheme in ["http", "https"] and host not in [nil, ""] and is_binary(path) ->
        name = Regex.escape(String.downcase(repository))
        if String.downcase(path) =~ ~r{\A/#{name}/(pull|issues)/#{number}(/|\z)}, do: url

      _ ->
        nil
    end
  end

  defp web_url(_url, _repository, _number), do: nil

  @doc """
  `{items, changes}` with the changes the user kept applied in order, each marked
  `applied`, or `stale` with a `staleReason` when the task it names is gone or it no
  longer fits the plan. A task added gets an id from `new_id.(i)`.
  """
  def apply_changes(items, changes, now, project_id, new_id) do
    {items, applied, _refs} =
      changes
      |> Enum.with_index(1)
      |> Enum.reduce({items, [], %{}}, fn
        {%{"dismissed" => true} = change, _i}, {items, acc, refs} ->
          refs = if change["op"] == "add", do: Map.put(refs, change["ref"], nil), else: refs
          {items, [change | acc], refs}

        {change, i}, {items, acc, refs} ->
          case apply_change(items, change, refs, now, project_id, new_id.(i)) do
            {:ok, items, refs} ->
              {items, [Map.merge(change, %{"outcome" => "applied", "staleReason" => nil}) | acc],
               refs}

            {:error, reason} ->
              {items, [Map.merge(change, %{"outcome" => "stale", "staleReason" => reason}) | acc],
               refs}
          end
      end)

    {items, Enum.reverse(applied)}
  end

  defp apply_change(items, %{"op" => "add"} = change, refs, now, project_id, id) do
    fields = resolve(change["fields"], refs)
    # A subtask is in its parent's project unless the agent says otherwise.
    project = get_in(items, [fields["parent"], "projectId"]) || project_id
    fields = Map.put(fields, "projectId", project)

    with {:ok, items, _item} <- add(items, id, fields, now),
         do: {:ok, items, Map.put(refs, change["ref"], id)}
  end

  defp apply_change(
         items,
         %{"op" => op, "itemId" => id} = change,
         refs,
         now,
         _project_id,
         _new_id
       ) do
    case items[id] do
      nil ->
        {:error, "The task #{id} is no longer in the plan."}

      item ->
        result =
          case op do
            "remove" ->
              {:ok, remove(items, id)}

            "link" ->
              with :ok <- check_link(items, id, change["fields"]),
                   do: {:ok, Map.put(items, id, link(item, change["fields"], now))}

            "update" ->
              with {:ok, items, _, _} <-
                     update(items, id, resolve(change["fields"], refs), now),
                   do: {:ok, items}
          end

        with {:ok, items} <- result, do: {:ok, items, refs}
    end
  end

  # The fields with an added task's ref replaced by the id it got. `after` leaves out
  # the ref of an add the user dismissed (nil in `refs`); any other name that is no
  # task is kept, for `check/2` to refuse.
  defp resolve(fields, refs) do
    fields
    |> then(
      &if(is_binary(&1["parent"]),
        do: Map.put(&1, "parent", refs[&1["parent"]] || &1["parent"]),
        else: &1
      )
    )
    |> then(
      &if(is_list(&1["after"]),
        do:
          Map.put(
            &1,
            "after",
            for(id <- &1["after"], Map.fetch(refs, id) != {:ok, nil}, do: refs[id] || id)
          ),
        else: &1
      )
    )
  end

  @doc "Item `item` linked to a pull request or an issue (`%{\"pullRequest\" | \"issue\" => ref}`)."
  def link(item, %{"pullRequest" => %{"repository" => repository, "number" => number} = ref}, now) do
    prs = item["pullRequests"] || []

    # A link made again with the address of the host serving it corrects the address
    # stored before links kept it, which is github.com's whatever the host.
    case Enum.find_index(prs, &same_ref?(&1, ref)) do
      nil ->
        pr = %{
          "repository" => repository,
          "number" => number,
          "url" => ref["url"] || "https://github.com/#{repository}/pull/#{number}",
          "title" => ref["title"],
          "state" => ref["state"] || "open"
        }

        %{item | "pullRequests" => prs ++ [pr], "updatedAt" => now}

      at ->
        url = ref["url"]

        if url && Enum.at(prs, at)["url"] != url,
          do: %{
            item
            | "pullRequests" => List.update_at(prs, at, &Map.put(&1, "url", url)),
              "updatedAt" => now
          },
          else: item
    end
  end

  # The issue a task has already keeps what its looks last saw of it, so a closed one
  # linked again does not read as newly closed.
  def link(item, %{"issue" => %{"repository" => repository, "number" => number} = ref}, now) do
    if same_ref?(item["issue"], ref) do
      item
    else
      issue = %{
        "repository" => repository,
        "number" => number,
        "url" => ref["url"] || "https://github.com/#{repository}/issues/#{number}",
        "state" => ref["state"] || "open"
      }

      # The board row, the failure and what GitHub has of the task belong to the issue
      # the task was linked to before.
      stale = %{"boardItemId" => nil, "syncError" => nil, "synced" => nil}
      item |> Map.merge(stale) |> Map.merge(%{"issue" => issue, "updatedAt" => now})
    end
  end

  def link(item, _fields, _now), do: item

  @doc """
  `:ok` when the task `id` of `items` may be linked as `fields` say, or `{:error, message}`
  naming the task that has the issue already: an issue is one task's, the one its look
  and pushes follow.
  """
  def check_link(items, id, %{"issue" => ref}) do
    holder =
      Enum.find_value(items, fn {other, item} ->
        if other != id and same_ref?(item["issue"], ref), do: item
      end)

    if holder,
      do:
        {:error,
         "#{holder["title"]} already has the issue #{ref["repository"]}##{ref["number"]}."},
      else: :ok
  end

  def check_link(_items, _id, _fields), do: :ok

  def same_ref?(a, b) when is_map(a) and is_map(b),
    do:
      String.downcase(a["repository"] || "") == String.downcase(b["repository"] || "") and
        a["number"] == b["number"]

  def same_ref?(_, _), do: false

  # --- views --------------------------------------------------------------------------------

  @doc "The views a new plan has."
  def default_views do
    [
      view(%{"id" => "timeline", "name" => "Timeline", "layout" => "gantt", "zoom" => "week"}),
      view(%{"id" => "board", "name" => "Board", "layout" => "board", "groupBy" => "status"}),
      view(%{"id" => "list", "name" => "All tasks", "layout" => "list"})
    ]
  end

  defp view(fields) do
    Map.merge(
      %{
        "layout" => "list",
        "filter" => filter(%{}),
        "groupBy" => "none",
        "sortBy" => "manual",
        "zoom" => "week",
        "fields" => ~w(status owner start due progress),
        "showDependencies" => true,
        "showBaseline" => false
      },
      fields
    )
  end

  defp filter(filter) do
    Map.merge(
      %{
        "text" => "",
        "statuses" => [],
        "labels" => [],
        "projects" => [],
        "owners" => [],
        "hideDone" => false
      },
      Map.take(filter, ~w(text statuses labels projects owners hideDone))
    )
  end

  @doc "`{:ok, view}` with what it leaves out filled in, or `{:error, message}`."
  def check_view(input) when is_map(input) do
    view =
      view(
        Map.take(
          input,
          ~w(id name layout filter groupBy sortBy zoom fields showDependencies showBaseline)
        )
      )

    view =
      Map.put(view, "filter", filter(if is_map(view["filter"]), do: view["filter"], else: %{}))

    f = view["filter"]

    cond do
      not is_binary(view["name"]) or String.trim(view["name"]) == "" ->
        {:error, "A view needs a name."}

      view["layout"] not in @layouts ->
        {:error, "#{shown(view["layout"])} is not a layout a view can have."}

      view["groupBy"] not in @group_by ->
        {:error, "#{shown(view["groupBy"])} is not something a view can group by."}

      view["sortBy"] not in @sort_by ->
        {:error, "#{shown(view["sortBy"])} is not something a view can sort by."}

      view["zoom"] not in @zooms ->
        {:error, "#{shown(view["zoom"])} is not a zoom a view can have."}

      not is_list(view["fields"]) ->
        {:error, "fields is a list of #{Enum.join(@view_fields, ", ")}."}

      bad = Enum.find(view["fields"], &(&1 not in @view_fields)) ->
        {:error, "#{shown(bad)} is not a field a view can show."}

      not is_binary(f["text"]) or not is_boolean(f["hideDone"]) or
          not Enum.all?(~w(statuses labels projects owners), &is_list(f[&1])) ->
        {:error, "filter gives text, statuses, labels, projects, owners and hideDone."}

      not is_boolean(view["showDependencies"]) or not is_boolean(view["showBaseline"]) ->
        {:error, "showDependencies and showBaseline are true or false."}

      true ->
        {:ok, Map.put(view, "name", String.trim(view["name"]))}
    end
  end

  def check_view(_input), do: {:error, "Give the view as an object."}

  # A value a client sent, for the message that refuses it.
  defp shown(value) when is_binary(value), do: value
  defp shown(value), do: inspect(value)

  # --- prompts ------------------------------------------------------------------------------

  @doc "`template` with each `{{ name }}` of `values` filled in; other names are left as they are."
  def fill(template, values) do
    Regex.replace(~r/\{\{\s*([\w.]+)\s*\}\}/, template, fn whole, name ->
      values[name] || whole
    end)
  end

  @doc """
  The prompt values of a run on `run_items` (derived items) of the plan `derived` on
  `today` in the project titled `project`.
  """
  def values(derived, run_items, today, project) do
    by_id = Map.new(derived, &{&1["id"], &1})
    item = List.first(run_items) || %{}

    %{
      "today" => today,
      "plan" => outline(derived),
      "items" =>
        if(run_items == [],
          do: "Every task of the plan.",
          else: Enum.map_join(run_items, "\n", &line(&1, by_id))
        ),
      "project" => project || "",
      "item.id" => item["id"] || "",
      "item.title" => item["title"] || "",
      "item.notes" => item["notes"] || "",
      "item.status" => item["status"] || "",
      "item.start" => item["start"] || "",
      "item.due" => item["due"] || "",
      "item.progress" => if(item["derivedProgress"], do: "#{item["derivedProgress"]}", else: ""),
      "item.owner" => item["owner"] || "",
      "item.labels" => Enum.join(item["labels"] || [], ", "),
      "item.issue" => issue(item["issue"]),
      "item.pullRequests" =>
        Enum.map_join(
          item["pullRequests"] || [],
          "\n",
          &"#{&1["repository"]}##{&1["number"]} #{&1["state"]}"
        ),
      "item.subtasks" =>
        derived
        |> Enum.filter(&(&1["parent"] == item["id"] and item["id"] != nil))
        |> Enum.map_join("\n", &line(&1, by_id)),
      "item.after" => Enum.map_join(item["after"] || [], ", ", &"#{by_id[&1]["title"]} (#{&1})")
    }
  end

  @doc "The plan as a markdown outline, subtasks under their parents."
  def outline([]), do: "The plan has no tasks yet."

  def outline(derived) do
    by_id = Map.new(derived, &{&1["id"], &1})
    children = Enum.group_by(derived, & &1["parent"])
    roots = Enum.filter(derived, &(&1["parent"] == nil or by_id[&1["parent"]] == nil))
    roots |> Enum.flat_map(&lines(&1, children, by_id, 0)) |> Enum.join("\n")
  end

  defp lines(item, children, by_id, depth) do
    [String.duplicate("  ", depth) <> line(item, by_id)] ++
      Enum.flat_map(children[item["id"]] || [], &lines(&1, children, by_id, depth + 1))
  end

  defp line(item, by_id) do
    dates =
      cond do
        item["kind"] == "milestone" -> "on #{item["due"] || "no date"}"
        item["start"] || item["due"] -> "#{item["start"] || "?"} to #{item["due"] || "?"}"
        true -> "no dates"
      end

    [
      "- [#{item["id"]}] #{item["title"]} (#{item["kind"]}, #{item["status"]}, #{item["derivedProgress"]}% done): #{dates}",
      item["owner"] && "owner #{item["owner"]}",
      item["projectId"] && "project #{item["projectId"]}",
      item["after"] != [] &&
        "waits for #{Enum.map_join(item["after"], ", ", &"#{by_id[&1]["title"]} [#{&1}]")}",
      item["labels"] != [] && "labels #{Enum.join(item["labels"], ", ")}",
      item["issue"] && "issue #{issue(item["issue"])} #{item["issue"]["state"]}",
      item["pullRequests"] != [] &&
        "pull requests #{Enum.map_join(item["pullRequests"], ", ", &"#{&1["repository"]}##{&1["number"]} #{&1["state"]}")}",
      item["late"] && "LATE",
      item["early"] not in [nil, []] &&
        "starts before #{Enum.map_join(item["early"], ", ", &by_id[&1]["title"])} ends",
      item["note"] && "note: #{item["note"]}"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(", ")
  end

  defp issue(%{"repository" => repository, "number" => number}), do: "#{repository}##{number}"
  defp issue(_), do: ""
end
