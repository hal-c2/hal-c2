defmodule HalC2Plugins.Office.Floor do
  @moduledoc """
  Who is in the office and what each does: the office plugin's state, pure.

  It is fed this MC's thread sidebar rows (`load/3` for the rows read at start, `rows/3`
  for those that changed since) and the turn events the plugin hears (`observe/3`), and
  `view/2` is the `office` topic:

      %{"people" => [%{"id", "title", "projectId", "project", "parentId", "kind",
                       "provider", "model", "state", "activity", "question", "since"}],
        "talks" => [%{"id", "from", "to", "kind", "text", "at"}]}

  A thread is in the office while it works, waits or asks, or was idle less than
  `idleHours` and is not settled; never once archived, deleted or moved to another
  machine. A worker is in it only while the thread it was delegated from is, unless it
  works or waits itself: a parent's row that changes changes its workers too.
  A person's `state` comes from its row alone (`state_of/1`); its `activity` from the
  last tool call heard in the turn under way, shown only while it is working. Its `kind`
  is `"reviewer"` for a thread the code-review plugin started to review a pull request,
  and for the workers it delegated to however deep, so they sit together; nil for
  everyone else. Talks are
  kept newest last, the newest #{40}, each only while current, thirty seconds: `view/2`
  shows those, and `expire/2` and every talk added drop the rest. One whose text was
  not heard shows as `…`.
  Times are milliseconds since the epoch; the topic carries them as ISO 8601.
  """

  @live ~w(queued preparing starting running)
  @live_activity ~w(preparing starting running)
  @kept_talks 40
  # How long a talk is what is happening now. A hand-off is one only while its worker is
  # this new too, whether the call or the worker's row says it: a row first seen later is
  # of a worker from another machine, say, and a call heard later waited for its worker.
  @talk_ms 30_000
  # `idleHours` above this is refused: a year, whose milliseconds stay a small integer.
  @max_idle_hours 8_760
  @text_chars 120
  # What a talk says when its text was not heard: never an empty speech bubble.
  @unheard "…"
  @ranks %{"asking" => 0, "working" => 1, "waiting" => 2, "idle" => 3, "failed" => 3}
  # The plugin marks (`HalC2.Plugins.Host.launch_thread/4`) of review threads.
  @reviews [{"code-review", "review"}]

  defstruct rows: %{},
            states: %{},
            activity: %{},
            drivers: %{},
            said: %{},
            talks: [],
            max_people: 24,
            idle_hours: 24

  @type t :: %__MODULE__{}

  @doc "An empty office with `settings` (`maxPeople`, `idleHours`)."
  def new(settings), do: settings(%__MODULE__{}, settings)

  @doc "The office with new settings; a value it cannot use keeps the default."
  def settings(floor, settings) do
    %{
      floor
      | max_people: whole(settings["maxPeople"], 24),
        idle_hours: positive(settings["idleHours"], 24)
    }
  end

  defp whole(n, _default) when is_number(n) and n >= 0, do: trunc(n)
  defp whole(_n, default), do: default

  defp positive(n, _default) when is_number(n) and n >= 0 and n <= @max_idle_hours, do: n
  defp positive(_n, default), do: default

  @doc "The most hours `idleHours` may be."
  def max_idle_hours, do: @max_idle_hours

  @doc """
  The rows read as the plugin starts: each state is taken as having begun when the row
  says it did.
  """
  def load(floor, rows, now), do: Enum.reduce(rows, floor, &put_row(&2, &1, now, false))

  @doc """
  Rows that changed: a state that changed began `now`, a row first seen began when it
  says it did (as `load/3` takes it), a deleted row leaves, and a worker just created is
  a `delegate` talk from its parent.
  """
  def rows(floor, rows, now), do: Enum.reduce(rows, floor, &put_row(&2, &1, now, true))

  defp put_row(floor, %{"id" => id} = row, now, changed?) when is_binary(id) do
    if row["deletedAt"] != nil do
      forget(floor, id)
    else
      state = state_of(row)
      new? = not Map.has_key?(floor.rows, id)

      since =
        case floor.states[id] do
          {^state, since} -> still(since, floor.rows[id], row, state, changed? && now)
          {_other, _since} when changed? -> iso(now)
          _ -> began(row, state, now)
        end

      floor = %{
        floor
        | rows: Map.put(floor.rows, id, row),
          states: Map.put(floor.states, id, {state, since})
      }

      parent = parent_of(row)

      if changed? and new? and parent != nil and not seen?(floor, id) and born?(row, now) do
        add_talk(floor, now, %{
          "id" => "delegate:" <> id,
          "from" => parent,
          "to" => id,
          "kind" => "delegate",
          "text" => line(row["title"]),
          "at" => iso(now)
        })
      else
        floor
      end
    end
  end

  defp put_row(floor, _row, _now, _changed?), do: floor

  # Whether a delegate talk to `id` is already kept. A worker is made before its
  # hand-off is said, and is new (`born?/2`) no longer than a talk is kept: so a talk
  # dropped as too old is never said again.
  defp seen?(floor, id), do: Enum.any?(floor.talks, &(&1["id"] == "delegate:" <> id))

  defp born?(row, now) do
    case ms(row["createdAt"]) do
      nil -> false
      at -> now - at < @talk_ms
    end
  end

  # Whether a talk heard is of something long done: a hand-off to a worker no longer new.
  defp over?(floor, %{"kind" => "delegate", "to" => child}, now) do
    case floor.rows[child] do
      %{"createdAt" => created} = row when is_binary(created) -> not born?(row, now)
      _ -> false
    end
  end

  defp over?(_floor, _talk, _now), do: false

  defp forget(floor, id) do
    %{
      floor
      | rows: Map.delete(floor.rows, id),
        states: Map.delete(floor.states, id),
        activity: Map.delete(floor.activity, id),
        drivers: Map.delete(floor.drivers, id),
        said: Map.delete(floor.said, id)
    }
  end

  # When a thread idle or failed before and after a change (`old` to `row`) is quiet
  # from. One the user unarchived or made active again is back `now`, for `idleHours`
  # more. One whose latest run ended after `since` ran in between, and the shell's
  # batching folded that run into the one change: it is quiet from that run's end.
  defp still(since, old, row, state, now) when state in ~w(idle failed) do
    ended = row["latestRunCompletedAt"]

    cond do
      (now && put_away?(old)) and not put_away?(row) -> iso(now)
      (ms(ended) || 0) > (ms(since) || 0) -> ended
      true -> since
    end
  end

  defp still(since, _old, _row, _state, _now), do: since

  defp put_away?(nil), do: false
  defp put_away?(row), do: row["archivedAt"] != nil or settled?(row)

  # When a row read at start, or first seen, says its state began. An idle thread that
  # waited on background work after its run ended counts from the run's end: the row
  # keeps no time for when that work finished.
  defp began(row, "asking", now),
    do: get_in(row, ["pendingRuntimeRequest", "createdAt"]) || row["updatedAt"] || iso(now)

  defp began(row, "working", now),
    do: row["activityRunStartedAt"] || row["latestRunStartedAt"] || row["updatedAt"] || iso(now)

  defp began(row, _state, now), do: row["latestRunCompletedAt"] || row["updatedAt"] || iso(now)

  @doc """
  A row's state: `asking` with a pending request, `working` with a live run, `waiting`
  on background work, `failed` when its latest run failed, otherwise `idle`.
  """
  def state_of(row) do
    cond do
      is_map(row["pendingRuntimeRequest"]) ->
        "asking"

      row["status"] in @live or row["activityRunStatus"] in @live_activity ->
        "working"

      row["activityRunStatus"] == "waiting" or (row["pendingBackgroundTasks"] || []) != [] ->
        "waiting"

      row["status"] == "failed" ->
        "failed"

      true ->
        "idle"
    end
  end

  defp parent_of(%{"lineage" => %{"relationshipToParent" => "subagent", "parentThreadId" => p}})
       when is_binary(p),
       do: p

  defp parent_of(_row), do: nil

  defp kind(floor, row), do: if(reviewer?(floor, row, []), do: "reviewer")

  # A review thread, or a worker of one: its parents are walked through every row of
  # this MC's, so a worker whose reviewer is not in the office still sits as one. A
  # lineage that loops ends where it began.
  defp reviewer?(floor, %{"id" => id} = row, seen) do
    review?(row["plugin"]) or
      (id not in seen and reviewer?(floor, floor.rows[parent_of(row)], [id | seen]))
  end

  defp reviewer?(_floor, _row, _seen), do: false

  defp review?(%{"id" => plugin, "kind" => kind}), do: {plugin, kind} in @reviews
  defp review?(_mark), do: false

  @doc "A turn event the plugin heard (`HalC2.Plugins.Extension`'s `observe/2`)."
  def observe(floor, %{"type" => "turn.started", "threadId" => id} = event, _now)
      when is_binary(id) do
    floor
    |> driver(id, event["provider"])
    |> Map.update!(:activity, &Map.put(&1, id, "thinking"))
    |> Map.update!(:said, &Map.delete(&1, id))
  end

  def observe(floor, %{"type" => "turn.item", "threadId" => id} = event, now)
      when is_binary(id) do
    floor = driver(floor, id, event["provider"])

    floor =
      case activity(event) do
        nil -> floor
        activity -> %{floor | activity: Map.put(floor.activity, id, activity)}
      end

    floor =
      if event["itemType"] == "assistant_message" and line(event["text"]) not in [nil, ""],
        do: %{floor | said: Map.put(floor.said, id, line(event["text"]))},
        else: floor

    case talk(event, now) do
      nil -> floor
      talk -> if over?(floor, talk, now), do: floor, else: add_talk(floor, now, talk)
    end
  end

  def observe(floor, %{"type" => "turn.finished", "threadId" => id} = event, now)
      when is_binary(id) do
    said = floor.said[id]
    parent = parent_of(floor.rows[id])

    floor = %{
      floor
      | activity: Map.delete(floor.activity, id),
        said: Map.delete(floor.said, id)
    }

    if parent && said do
      add_talk(floor, now, %{
        "id" => "result:#{id}:#{event["runId"]}",
        "from" => id,
        "to" => parent,
        "kind" => "result",
        "text" => said,
        "at" => iso(now)
      })
    else
      floor
    end
  end

  def observe(floor, _event, _now), do: floor

  defp driver(floor, id, provider) when is_binary(provider) and provider != "",
    do: %{floor | drivers: Map.put(floor.drivers, id, provider)}

  defp driver(floor, _id, _provider), do: floor

  # A talk an item is: a task delegated with `delegate_task`, a message sent with
  # `hal_c2_thread_send`, once the call completed. Only the last 4,000 characters of an
  # input are heard (`HalC2.Plugins.Extension`), so a longer one is no JSON: whom and
  # what it was about are then read from the call's result.
  defp talk(%{"status" => "completed", "threadId" => from} = event, now) do
    input = decoded(event["input"])
    result = decoded(event["output"])

    case tool(event["tool"]) do
      "delegate_task" ->
        with child when is_binary(child) <- child_thread(event["output"]) do
          %{
            "id" => "delegate:" <> child,
            "from" => from,
            "to" => child,
            "kind" => "delegate",
            "text" => line(input["title"]) || line(result["title"]) || line(input["task"]),
            "at" => iso(now)
          }
        end

      "hal_c2_thread_send" ->
        with to when is_binary(to) and to != "" <- input["threadId"] || result["threadId"] do
          %{
            "id" => "message:#{from}:#{event["itemId"] || event["ordinal"]}",
            "from" => from,
            "to" => to,
            "kind" => "message",
            "text" => line(input["message"]),
            "at" => iso(now)
          }
        end

      _ ->
        nil
    end
    |> case do
      %{} = talk -> talk
      _ -> nil
    end
  end

  defp talk(_event, _now), do: nil

  defp child_thread(output) when is_binary(output) do
    case Regex.run(~r/childThreadId\\*"\s*:\s*\\*"([^"\\]+)/, output) do
      [_, child] -> child
      _ -> nil
    end
  end

  defp child_thread(_output), do: nil

  defp decoded(input) when is_binary(input) do
    case JSON.decode(input) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  defp decoded(%{} = input), do: input
  defp decoded(_input), do: %{}

  # A tool's own name, whatever its provider calls the server it came from:
  # `mcp__hal-c2__delegate_task` and `hal-c2.delegate_task` are `delegate_task`.
  defp tool(name) when is_binary(name),
    do: name |> String.split(["__", ".", "/", ":"]) |> List.last() |> String.downcase()

  defp tool(_name), do: ""

  @reading ~w(read grep glob ls search find view read_file list_dir list_files codebase_search
              file_search grep_search notebookread)
  @browsing ~w(websearch webfetch web_search web_fetch fetch browse)
  @planning ~w(todowrite todoread update_plan exitplanmode enterplanmode plan)
  @delegating ~w(delegate_task hal_c2_thread_send hal_c2_thread_launch agent task spawn_agent
                 send_input create_threads)
  @typing ~w(edit write multiedit notebookedit apply_patch str_replace_editor create_file
             write_file edit_file replace)
  @commands ~w(bash shell exec_command local_shell run_terminal_cmd terminal command)
  @testing ~r/\b(test|tests|spec|specs|check|lint|build|compile|typecheck|tsc|mix|cargo|vp|pytest|jest|vitest|rspec|go\s+test|make|gradle|mvn|ctest|ninja)\b/i

  @doc """
  What an item heard shows its person doing, or nil when it shows nothing new:
  `typing`, `running`, `testing`, `reading`, `browsing`, `planning`, `delegating` or
  `thinking`.
  """
  def activity(%{"itemType" => type} = event) do
    name = tool(event["tool"])

    cond do
      type == "subagent" or name in @delegating ->
        "delegating"

      type == "web_search" or name in @browsing or String.starts_with?(name, "preview_") ->
        "browsing"

      type == "file_search" or name in @reading ->
        "reading"

      type in ~w(todo_list proposed_plan) or name in @planning ->
        "planning"

      type == "file_change" or name in @typing ->
        "typing"

      type == "command_execution" or name in @commands ->
        command(event["input"])

      type in ~w(assistant_message reasoning) ->
        "thinking"

      is_binary(event["path"]) and event["path"] != "" ->
        "typing"

      true ->
        nil
    end
  end

  def activity(_event), do: nil

  defp command(input) do
    text =
      case decoded(input) do
        %{"command" => command} when is_list(command) -> Enum.join(command, " ")
        %{"command" => command} when is_binary(command) -> command
        %{"cmd" => command} when is_binary(command) -> command
        _ when is_binary(input) -> input
        _ -> ""
      end

    if Regex.match?(@testing, text), do: "testing", else: "running"
  end

  # A talk heard again keeps its place and time and takes the new text.
  defp add_talk(floor, now, %{"id" => id} = talk) do
    floor = expire(floor, now)

    talks =
      if Enum.any?(floor.talks, &(&1["id"] == id)),
        do:
          Enum.map(floor.talks, fn kept ->
            if kept["id"] == id, do: %{kept | "text" => talk["text"] || kept["text"]}, else: kept
          end),
        else: Enum.take(floor.talks ++ [talk], -@kept_talks)

    %{floor | talks: talks}
  end

  @doc "The office without the talks no longer current at `now`: their text is not kept."
  def expire(floor, now), do: %{floor | talks: Enum.filter(floor.talks, &recent?(&1, now))}

  defp recent?(talk, now), do: (ms(talk["at"]) || 0) > now - @talk_ms

  @doc "The `office` topic at `now`."
  def view(floor, now) do
    people =
      floor.rows
      |> Map.values()
      |> Enum.map(&{&1, elem(floor.states[&1["id"]], 0)})
      |> Enum.filter(fn {row, state} -> in?(floor, row, state, now) end)
      |> Enum.sort_by(fn {row, state} ->
        {@ranks[state], -(ms(row["updatedAt"]) || 0), row["id"]}
      end)
      |> Enum.take(floor.max_people)
      |> Enum.map(fn {row, state} -> person(floor, row, state) end)

    talks =
      for talk <- floor.talks,
          recent?(talk, now),
          do: %{talk | "text" => talk["text"] || @unheard}

    %{"people" => people, "talks" => talks}
  end

  # Whether a thread is in the office: not archived or moved away, and working, waiting,
  # or else asking or recently idle while not settled. A worker that is not working or
  # waiting leaves with the thread it was delegated from (`parent_here?/4`), asking or
  # not: putting the parent away puts its work away. An idle or failed thread stays
  # `idleHours` from when it became so: its row changes for other reasons too (a
  # provider session stopped for sitting idle, say), and those do not make it any less
  # quiet.
  defp in?(floor, row, state, now, seen \\ []) do
    cond do
      row["archivedAt"] != nil or is_map(row["movedTo"]) -> false
      state in ~w(working waiting) -> true
      not parent_here?(floor, row, now, [row["id"] | seen]) -> false
      state == "asking" -> true
      true -> not settled?(row) and quiet_for(floor, row, now) < floor.idle_hours * 3_600_000
    end
  end

  # Whether the thread `row` was delegated from is in the office, walking up its lineage:
  # a parent this MC has no row for (deleted, or never here) is not. A lineage that loops
  # back stops where it does, as if it ended there.
  defp parent_here?(floor, row, now, seen) do
    with parent when is_binary(parent) <- parent_of(row),
         false <- parent in seen do
      case {floor.rows[parent], floor.states[parent]} do
        {%{} = parent_row, {state, _since}} -> in?(floor, parent_row, state, now, seen)
        _ -> false
      end
    else
      _ -> true
    end
  end

  defp settled?(row),
    do:
      row["settledOverride"] == "settled" or
        (row["settledAt"] != nil and row["settledOverride"] != "active")

  defp quiet_for(floor, row, now), do: now - (ms(since(floor, row)) || now)

  defp since(floor, row), do: elem(floor.states[row["id"]], 1)

  defp person(floor, row, state) do
    id = row["id"]
    request = row["pendingRuntimeRequest"]

    %{
      "id" => id,
      "title" => row["title"],
      "projectId" => row["projectId"],
      "project" => row["projectTitle"],
      "parentId" => parent_of(row),
      "kind" => kind(floor, row),
      "provider" => floor.drivers[id] || row["providerInstanceId"],
      "model" => get_in(row, ["modelSelection", "model"]),
      "state" => state,
      "activity" => if(state == "working", do: floor.activity[id]),
      "question" =>
        if(state == "asking", do: %{"kind" => request["kind"], "since" => request["createdAt"]}),
      "since" => since(floor, row)
    }
  end

  @doc """
  When `view/2` next changes with nothing heard: the first idle thread to have been
  quiet too long or talk to grow too old after `now`, in milliseconds since the epoch,
  or nil.
  """
  def next_change(floor, now) do
    idle =
      for {id, row} <- floor.rows,
          {state, _} = floor.states[id],
          state in ~w(idle failed),
          in?(floor, row, state, now),
          at = ms(since(floor, row)),
          do: at + ceil(floor.idle_hours * 3_600_000)

    talks = for talk <- floor.talks, at = ms(talk["at"]), at + @talk_ms > now, do: at + @talk_ms

    case Enum.filter(idle ++ talks, &(&1 > now)) do
      [] -> nil
      times -> Enum.min(times)
    end
  end

  @doc "The first non-blank line of `text`, its runs of space made one, cut to 120 characters."
  def line(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.map(&(&1 |> String.replace(~r/\s+/u, " ") |> String.trim()))
    |> Enum.find(&(&1 != ""))
    |> case do
      nil -> nil
      line -> String.slice(line, 0, @text_chars)
    end
  end

  def line(_text), do: nil

  @doc "An ISO 8601 time as milliseconds since the epoch, or nil."
  def ms(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _} -> DateTime.to_unix(at, :millisecond)
      _ -> nil
    end
  end

  def ms(_iso), do: nil

  @doc "Milliseconds since the epoch as ISO 8601."
  def iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
end
