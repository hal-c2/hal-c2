defmodule HalC2.Push.Alerts do
  @moduledoc """
  What `HalC2.Push` tells a phone, worked out from sidebar rows (`HalC2.Shell`): which
  alerts are due, the alert one push carries, the activity card, and quiet hours. Pure.

  Alerts fire on transitions as the desktop's `AlertController` does: each thread is
  remembered by its id as `%{attention, completion}`, and an alert is due when its
  attention (a pending approval or question, a failed run) changes to something new, or
  its latest run completes later than before. A thread keeps its id when it moves to
  another MC, so what was seen of it moves too. A thread seen for the first time is a
  baseline, except for work that happened after `started_at` (upstream
  pingdotgg/t3code#13340): threads finished before the MC started produce nothing.
  """

  @title_limit 120
  @finished_kept :timer.minutes(15)
  @active_expiry :timer.hours(2)
  # A card for work still running is sent again this long before it would expire.
  @refresh_ahead :timer.hours(1)
  @max_rows 5
  @budget 3500

  @doc """
  A thread's view for alerts and activity from its sidebar `row`, or nil for a row that
  is gone, a subagent's, or the record a thread that moved away leaves behind.
  `environment_id` is its MC's, `project` its project's title.
  """
  def thread(environment_id, row, project) do
    if row["deletedAt"] == nil and row["movedTo"] == nil and not subagent?(row) do
      request = row["pendingRuntimeRequest"]
      status = status(row, request)

      %{
        key: "#{environment_id}:#{row["id"]}",
        environment_id: environment_id,
        thread_id: row["id"],
        title: clip(row["title"] || ""),
        project: clip(project || ""),
        archived: row["archivedAt"] != nil,
        status: status,
        phase: phase(row, request),
        waiting: row["pendingBackgroundTasks"] not in [nil, []] or run_status(row) == "waiting",
        attention: attention(row, request, status),
        attention_at: attention_at(row, request, status),
        completion:
          if(status == "ready" and row["status"] == "completed",
            do: ms(row["latestRunCompletedAt"])
          ),
        finished_at: ms(row["latestRunCompletedAt"]) || ms(row["updatedAt"]),
        updated_at: ms(row["updatedAt"]) || 0
      }
    end
  end

  defp subagent?(row), do: get_in(row, ["lineage", "relationshipToParent"]) == "subagent"

  # The desktop's sidebar status (`sidebar::status`), with a failed run's.
  defp status(row, request) do
    kind = request && request["kind"]

    cond do
      kind == "user_input" ->
        "input"

      kind not in [nil, "auth_refresh"] ->
        "approval"

      row["latestRunId"] == nil and row["activeProviderThreadId"] == nil ->
        "ready"

      true ->
        runtime =
          if row["pendingBackgroundTasks"] not in [nil, []], do: "idle", else: run_status(row)

        cond do
          runtime in ~w(preparing queued starting running waiting) -> "working"
          runtime == "idle" -> "waiting"
          runtime == "failed" and row["lastErrorClass"] == "usage_limit" -> "limited"
          runtime == "failed" -> "failed"
          true -> "ready"
        end
    end
  end

  defp run_status(row), do: row["activityRunStatus"] || row["status"]

  # The activity phase, as upstream's `projectThreadAwarenessV2`.
  defp phase(row, request) do
    kind = request && request["kind"]

    cond do
      kind == "user_input" -> "waiting_for_input"
      kind not in [nil, "auth_refresh"] -> "waiting_for_approval"
      run_status(row) in ~w(preparing queued starting) -> "starting"
      run_status(row) in ~w(running waiting) -> "running"
      run_status(row) == "completed" -> "completed"
      run_status(row) == "failed" -> "failed"
      true -> nil
    end
  end

  defp attention(_row, request, status) when status in ~w(approval input),
    do: "request:#{request["id"]}:#{status}"

  defp attention(row, _request, status) when status in ~w(failed limited),
    do: "run:#{row["latestRunId"]}:#{status}"

  defp attention(_row, _request, _status), do: nil

  defp attention_at(_row, request, status) when status in ~w(approval input),
    do: ms(request["createdAt"])

  defp attention_at(row, _request, status) when status in ~w(failed limited),
    do: ms(row["latestRunCompletedAt"])

  defp attention_at(_row, _request, _status), do: nil

  @doc """
  Remembers `threads` in `seen` and returns `{seen, due}`: the alerts now due, as
  `%{id, kind, key, title, environment_id, thread_id}`, in `threads`' order.
  """
  def observe(seen, threads, started_at) do
    Enum.reduce(threads, {seen, []}, fn thread, {seen, due} ->
      prior = seen[thread.thread_id]
      seen = remember(seen, thread, prior)

      case event(thread, prior, started_at) do
        nil -> {seen, due}
        _ when thread.archived -> {seen, due}
        {kind, event} -> {seen, [due(thread, kind, event) | due]}
      end
    end)
    |> then(fn {seen, due} -> {seen, Enum.reverse(due)} end)
  end

  @doc "Remembers `threads` in `seen` as they are, with no alert for any of them."
  def baseline(seen, threads),
    do: Enum.reduce(threads, seen, &remember(&2, &1, &2[&1.thread_id]))

  defp remember(seen, thread, prior) do
    completion = thread.completion || (prior && prior.completion)
    Map.put(seen, thread.thread_id, %{attention: thread.attention, completion: completion})
  end

  # First seen: only what happened after the MC started is news.
  defp event(thread, nil, started_at) do
    cond do
      thread.attention && after?(thread.attention_at, started_at) -> attention_event(thread)
      after?(thread.completion, started_at) -> completion_event(thread)
      true -> nil
    end
  end

  defp event(thread, prior, _started_at) do
    cond do
      thread.attention && thread.attention != prior.attention ->
        attention_event(thread)

      thread.completion && (prior.completion == nil or thread.completion > prior.completion) ->
        completion_event(thread)

      true ->
        nil
    end
  end

  defp after?(nil, _), do: false
  defp after?(at, started_at), do: at > started_at

  defp attention_event(%{status: "limited"} = thread), do: {"failed", thread.attention}
  defp attention_event(thread), do: {thread.status, thread.attention}
  defp completion_event(thread), do: {"completed", "done:#{thread.completion}"}

  defp due(thread, kind, event),
    do: %{
      id: "#{thread.key}:#{event}",
      kind: kind,
      key: thread.key,
      title: thread.title,
      environment_id: thread.environment_id,
      thread_id: thread.thread_id
    }

  @bodies %{
    "completed" => "Agent finished",
    "failed" => "Agent failed",
    "approval" => "Approval needed",
    "input" => "Question for you"
  }

  @doc "The one alert a push carries for `due` (at least one): its own, or a grouped one."
  def alert([one]) do
    one |> base() |> Map.merge(%{"id" => one.id, "kind" => one.kind, "body" => @bodies[one.kind]})
  end

  def alert([first | _] = due) do
    count = length(due)
    kinds = MapSet.new(due, & &1.kind)

    title =
      cond do
        MapSet.equal?(kinds, MapSet.new(["completed"])) -> "#{count} agents finished"
        MapSet.subset?(kinds, MapSet.new(["approval", "input"])) -> "#{count} agents need you"
        true -> "#{count} agent updates"
      end

    id =
      "grouped:" <>
        Base.url_encode64(:crypto.hash(:sha256, Enum.map_join(due, "\n", & &1.id)),
          padding: false
        )

    first
    |> base()
    |> Map.merge(%{
      "id" => id,
      "kind" => "grouped",
      "title" => title,
      "body" => Enum.map_join(due, "\n", & &1.title)
    })
  end

  defp base(due),
    do: %{
      "title" => due.title,
      "link" => link(due.environment_id, due.thread_id),
      "environmentId" => due.environment_id,
      "threadId" => due.thread_id
    }

  defp link(environment_id, thread_id), do: "hal-c2://threads/#{environment_id}/#{thread_id}"

  @labels %{
    "waiting_for_approval" => "Approval",
    "waiting_for_input" => "Input",
    "starting" => "Connecting",
    "running" => "Working",
    "completed" => "Done",
    "failed" => "Failed"
  }

  @doc """
  The activity card at `now` for `threads`, or nil when it has no rows: every listed
  thread with a phase, finished ones for 15 minutes after they finished.
  """
  def activity(threads, now) do
    rows =
      for thread <- threads,
          not thread.archived,
          thread.phase != nil,
          not finished?(thread) or (thread.finished_at || 0) + @finished_kept > now,
          do: thread

    case Enum.sort_by(rows, &{group(&1), -&1.updated_at}) do
      [] ->
        nil

      [first | _] = sorted ->
        active? = Enum.any?(sorted, &(not finished?(&1)))

        expires_at =
          if active?,
            do: now + @active_expiry,
            else: Enum.max(Enum.map(sorted, &(&1.finished_at || now))) + @finished_kept

        %{
          "active" => active?,
          "phase" => first.phase,
          "expiresAt" => expires_at,
          "activeCount" => Enum.count(sorted, &(not finished?(&1))),
          "attentionCount" => Enum.count(sorted, &(group(&1) == 0)),
          "link" => link(first.environment_id, first.thread_id),
          "environmentId" => first.environment_id,
          "threadId" => first.thread_id,
          "rows" => Enum.map(Enum.take(sorted, @max_rows), &row/1)
        }
    end
  end

  @doc "The card that clears the phone's: no rows, expiring `now`."
  def cleared(now),
    do: %{
      "active" => false,
      "rows" => [],
      "expiresAt" => now,
      "activeCount" => 0,
      "attentionCount" => 0
    }

  @doc "When a finished row next leaves the card after `now`, or nil."
  def next_expiry(threads, now) do
    threads
    |> Enum.filter(&(finished?(&1) and not &1.archived and &1.finished_at != nil))
    |> Enum.map(&(&1.finished_at + @finished_kept))
    |> Enum.filter(&(&1 > now))
    |> Enum.min(fn -> nil end)
  end

  @doc "A card without its timestamps, for telling whether it changed."
  def unstamped(nil), do: nil
  def unstamped(activity), do: Map.delete(activity, "expiresAt")

  @doc """
  When `activity` must be sent again though nothing in it changed, or nil: a card for
  work still running would otherwise expire on the phone while the work goes on.
  """
  def refresh_at(%{"active" => true, "expiresAt" => expires_at}),
    do: expires_at - @refresh_ahead

  def refresh_at(_activity), do: nil

  defp finished?(thread), do: thread.phase in ~w(completed failed)

  defp group(%{phase: phase}) when phase in ~w(waiting_for_approval waiting_for_input), do: 0
  defp group(%{phase: "failed"}), do: 1
  defp group(%{phase: "completed"}), do: 3
  defp group(_), do: 2

  defp row(thread),
    do: %{
      "status" =>
        if(thread.phase == "running" and thread.waiting,
          do: "Waiting",
          else: @labels[thread.phase]
        ),
      "title" => thread.title,
      "project" => thread.project,
      "environmentId" => thread.environment_id,
      "threadId" => thread.thread_id
    }

  @doc """
  The message JSON for `alert` and `activity` (either may be nil), sent at `now`, made
  to fit in #{@budget} bytes: a grouped alert's body loses titles from its end, said in
  a last line, then the card loses rows from its end (its counts still say how many
  threads there are). A message that is still over, which titles clipped to
  #{@title_limit} characters should rule out, goes as it is.
  """
  def message(alert, activity, now) do
    titles = if alert && alert["kind"] == "grouped", do: String.split(alert["body"], "\n")
    fit(alert, titles, 0, activity, now)
  end

  defp fit(alert, titles, dropped, activity, now) do
    json = encode(with_titles(alert, titles, dropped), activity, now)
    rows = activity && activity["rows"]

    cond do
      byte_size(json) < @budget ->
        json

      titles not in [nil, []] ->
        fit(alert, Enum.drop(titles, -1), dropped + 1, activity, now)

      is_list(rows) and length(rows) > 1 ->
        fit(alert, titles, dropped, %{activity | "rows" => Enum.drop(rows, -1)}, now)

      true ->
        json
    end
  end

  defp with_titles(alert, nil, _dropped), do: alert
  defp with_titles(alert, titles, 0), do: %{alert | "body" => Enum.join(titles, "\n")}

  defp with_titles(alert, titles, dropped),
    do: %{alert | "body" => Enum.join(titles ++ ["and #{dropped} more"], "\n")}

  defp encode(alert, activity, now) do
    %{"v" => 1, "sentAt" => now}
    |> put_present("alert", alert)
    |> put_present("activity", activity)
    |> JSON.encode!()
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  @doc "Whether `now` (ms) falls in `quiet` hours (nil: never)."
  def quiet?(nil, _now), do: false
  def quiet?(%{"start" => same, "end" => same}, _now), do: false

  def quiet?(%{"start" => start, "end" => stop} = quiet, now) do
    minute = local_minute(quiet, now)
    if start < stop, do: minute >= start and minute < stop, else: minute >= start or minute < stop
  end

  @doc "When the quiet hours `now` falls in end, in ms."
  def quiet_end(%{"end" => stop} = quiet, now) do
    minutes = Integer.mod(stop - local_minute(quiet, now), 1440)
    (div(now, 60_000) + minutes) * 60_000
  end

  defp local_minute(quiet, now),
    do: Integer.mod(div(now, 60_000) + (quiet["utcOffsetMinutes"] || 0), 1440)

  defp clip(text) do
    if String.length(text) > @title_limit,
      do: String.slice(text, 0, @title_limit - 1) <> "…",
      else: text
  end

  defp ms(nil), do: nil
  defp ms(iso), do: HalC2.Projection.JS.epoch_ms(iso)
end
