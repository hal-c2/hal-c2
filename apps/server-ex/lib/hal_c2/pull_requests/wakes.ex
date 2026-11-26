defmodule HalC2.PullRequests.Wakes do
  @moduledoc """
  Wakes a thread's agent when a pull request it owns needs attention, the way a
  delegated task's result does (`HalC2.Orchestration.Delegation`): a `message.dispatch`
  from the server with a `notification`, which the timeline shows in place of its text
  and which starts a turn.

  A thread owns the links it shows while it is neither settled nor archived. A
  delegated task's child owns them only while it works on its task: once it is quiet
  its task ends and its links pass to its caller with what it heard of them
  (`HalC2.Orchestration.Delegation.hand_over_pull_requests/1`, which a check also
  calls, so a handover cut short completes), so it is not woken beside whoever took
  the work over. Each link
  remembers what the thread was last told of it (`heard`); a snapshot from
  `HalC2.PullRequests.Sync` that differs from it in a way worth acting on is news
  (`changes/2`). A link's first snapshot is its baseline. A settled or archived thread
  hears nothing, and what it heard stays as it was, so bringing it back tells it what
  changed meanwhile in one message. Unlinking drops the link and what it heard.
  A link's `notify` (`subscribed/1`) names the kinds of news that wake its thread;
  news of another kind is heard without telling, so subscribing again later does
  not bring it back.

  News is delivered only when the thread is idle: while it has a run working or
  queued, nothing new is marked heard, so everything that lands meanwhile shares the
  one wake its run's end brings. The message and the new `heard` commit in one
  transaction, so a restart neither loses nor repeats news. A thread that settles on
  its own once its pull requests are done (`HalC2.Orchestration.Settlement`) takes
  the news as heard and is left to settle instead of being woken.

  Each sidebar row whose links may hold something to hear is checked, and every
  thread once at start. `sweep/0` checks every thread now and returns when it is done.
  """

  use GenServer

  require Logger

  alias HalC2.{Orchestration, StreamState}
  alias HalC2.Orchestration.{Delegation, Settlement}
  alias HalC2.Projection.JS
  alias HalC2.Projection.PullRequests, as: Links

  @busy ~w(preparing starting running waiting queued)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Checks every thread now."
  def sweep, do: GenServer.call(__MODULE__, :sweep, :infinity)

  @impl true
  def init(_opts) do
    :ok = HalC2.Shell.subscribe(self())
    {:ok, nil, {:continue, :sweep}}
  end

  @impl true
  def handle_continue(:sweep, state) do
    check_all()
    {:noreply, state}
  end

  @impl true
  def handle_call(:sweep, _from, state) do
    check_all()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:hal_c2_shell, {:rows, mc, rows}}, state) when mc == node() do
    for {id, {"thread", row}} <- rows, due?(row), do: safe_check(id)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp check_all do
    for {{mc, id}, {"thread", row}} <- HalC2.Shell.rows(),
        mc == node(),
        due?(row),
        do: safe_check(id)
  end

  defp safe_check(id) do
    check(id)
  rescue
    error ->
      Logger.warning("pull request wake check for #{id} failed: #{Exception.message(error)}")
  end

  # A quick look at a sidebar row before its stream decides: whether a link has a
  # snapshot it has not heard. A busy thread waits for its run's end, which changes the
  # row again. A delegated child put away with links left has a handover to finish,
  # whatever it heard: an archived one hears no news. Its row seldom changes; an
  # active child's news completes the handover too.
  defp due?(row) do
    away? = row["archivedAt"] != nil or row["settledAt"] != nil
    waiting? = away? or row["activityRunStatus"] != nil
    handing_over? = away? and row["activityRunStatus"] == nil and delegated?(row)

    row["deletedAt"] == nil and
      Enum.any?(Links.visible(row["pullRequests"] || []), fn link ->
        case {link["heard"], link["snapshot"]} do
          {_, nil} ->
            false

          {nil, _} ->
            true

          _ when handing_over? ->
            true

          _ when waiting? ->
            false

          {heard, snapshot} ->
            advance(heard, snapshot, []) != heard or changes(heard, snapshot) != []
        end
      end)
  end

  @doc """
  Marks what thread `thread_id` hears of its links' snapshots, and wakes it when that
  is news. Returns `:woken`, `:quiet` (nothing to tell) or `{:error, reason}` when the
  wake was refused; what needed no telling is marked heard either way.
  """
  def check(thread_id) do
    HalC2.Streams.transact(thread_id, :thread, fn state ->
      case StreamState.get(state, "thread")[thread_id] do
        nil -> {[], :quiet}
        thread -> decide(state, thread_id, thread)
      end
    end)
    |> case do
      {:woken, command, sent} ->
        Orchestration.dispatched(thread_id, command, sent)
        :woken

      other ->
        # A delegated child done with its task kept what it heard for its caller.
        Delegation.hand_over_pull_requests(thread_id)
        other
    end
  end

  defp decide(state, thread_id, thread) do
    links = Links.of(thread)
    runs = StreamState.list(state, "run")
    idle? = not Enum.any?(runs, &(&1["status"] in @busy))
    away? = away?(thread) or (delegated?(thread) and Delegation.quiet?(state))
    {quiet, told, news} = hear(links, away?, idle?, runs)

    cond do
      news == [] ->
        {heard(state, thread_id, quiet), :quiet}

      Settlement.settles_now?(HalC2.Projection.Shell.thread_shell(state)) ->
        {heard(state, thread_id, told), :quiet}

      true ->
        command = wake(thread_id, news)

        case Orchestration.decide_dispatch(state, thread_id, command) do
          {changes, {:ok, _} = sent} ->
            {heard(state, thread_id, told) ++ changes, {:woken, command, sent}}

          {_, error} ->
            {heard(state, thread_id, quiet), error}
        end
    end
  end

  defp delegated?(thread),
    do: get_in(thread, ["lineage", "relationshipToParent"]) == "subagent"

  defp away?(thread),
    do:
      thread["archivedAt"] != nil or thread["deletedAt"] != nil or
        thread["settledOverride"] == "settled" or thread["settledAt"] != nil

  @doc """
  What a thread hears of `links`: `{quiet, told, news}`, the links as they are with
  everything heard that needs no telling, as they are once the news is told too, and
  the news as `[{link, changes}]`. Away (settled or archived), a thread hears nothing
  but a new link's baseline; busy, news waits. `runs` are the thread's, for
  `changes/3`.
  """
  def hear(links, away?, idle?, runs \\ []) do
    {quiet, told, news} =
      Enum.reduce(links, {[], [], []}, fn link, {quiet, told, news} ->
        case hear_link(link, away?, idle?, runs) do
          {link, []} -> {[link | quiet], [link | told], news}
          {next, changes} -> {[link | quiet], [next | told], [{link, changes} | news]}
        end
      end)

    {Enum.reverse(quiet), Enum.reverse(told), Enum.reverse(news)}
  end

  defp hear_link(link, away?, idle?, runs) do
    heard = link["heard"]
    snapshot = link["snapshot"]

    cond do
      snapshot == nil or link["source"] == "stack-dismissed" ->
        {link, []}

      heard == nil ->
        {Map.put(link, "heard", baseline(snapshot)), []}

      away? ->
        {link, []}

      true ->
        # Comment activity is stamped when it last changed, so an edit counts.
        # A link heard under the creation-time stamp has no `commentEditAt`:
        # its first read of an edit-stamped snapshot only re-baselines comment
        # news, so edits from before it are not woken for.
        changes =
          heard
          |> changes(snapshot, runs)
          |> then(fn changes ->
            if Map.has_key?(heard, "commentEditAt") or snapshot["commentStamp"] != "edited",
              do: changes,
              else: Enum.reject(changes, &(event(&1) == "comments"))
          end)

        # News of a kind the thread is not subscribed to is heard without telling.
        case Enum.filter(changes, &(event(&1) in subscribed(link))) do
          [] -> {Map.put(link, "heard", advance(heard, snapshot, changes)), []}
          _ when not idle? -> {link, []}
          told -> {Map.put(link, "heard", advance(heard, snapshot, changes)), told}
        end
    end
  end

  @events ~w(reviews comments checks conflicts merge_queue merged closed)

  @doc """
  The kinds of news a link can wake its thread with, the `notify` a subscription
  keeps (`subscribed/1`): a review or a comment from someone the repository trusts,
  checks that start failing (or pass again after failing), a conflict with the base
  branch, leaving the merge queue, a merge and a close.
  """
  def events, do: @events

  @doc "The kinds of news `link` wakes its thread with: its `notify`, or every kind."
  def subscribed(%{"notify" => notify}) when is_list(notify), do: notify
  def subscribed(_link), do: @events

  # What `advance/3` moves past for each kind of news.
  @heard_fields %{
    "merged" => ~w(state),
    "closed" => ~w(state),
    "checks" => ~w(checksState checksFailed),
    "conflicts" => ~w(mergeability),
    "merge_queue" => ~w(mergeQueueRemovalAt),
    "reviews" => ~w(reviewActivityAt),
    "comments" => ~w(commentActivityAt)
  }

  # A link heard before the kinds were kept apart holds only `activityAt`.
  defp held(heard, key) when key in ~w(reviewActivityAt commentActivityAt),
    do: Map.get(heard, key, heard["activityAt"])

  defp held(heard, key), do: heard[key]

  @doc """
  `link` subscribed to `notify` (nil is every kind) in place of what it was. News of a
  kind it now hears for the first time, already in its snapshot, is heard without
  telling: it arrived while that kind was muted. News of a kind it was already
  subscribed to stays to be told.
  """
  def resubscribe(link, notify) do
    before = subscribed(link)
    link = if notify == nil, do: Map.delete(link, "notify"), else: Map.put(link, "notify", notify)
    heard = link["heard"]
    snapshot = link["snapshot"]
    enabled = subscribed(link) -- before

    if is_map(heard) and is_map(snapshot) and enabled != [] do
      {consumed, pending} = Enum.split_with(changes(heard, snapshot), &(event(&1) in enabled))

      kept =
        pending
        |> Enum.flat_map(&Map.fetch!(@heard_fields, event(&1)))
        |> Map.new(&{&1, held(heard, &1)})

      next = heard |> advance(snapshot, consumed) |> Map.merge(kept)

      # Restoring a pending comment's marker on a link heard before comment
      # edits were stamped must not stamp it from that edit: the marker goes
      # with the baselined comment time, or the historical edit wakes later.
      next =
        if not Map.has_key?(heard, "commentEditAt") and
             Map.has_key?(kept, "commentActivityAt") do
          Map.delete(next, "commentEditAt")
        else
          next
        end

      Map.put(link, "heard", next)
    else
      link
    end
  end

  @doc "`{:ok, notify}` for a list of `events/0` (nil is every kind), or `{:error, message}`."
  def notify(nil), do: {:ok, nil}

  def notify(events) when is_list(events) do
    case Enum.reject(events, &(&1 in @events)) do
      [] ->
        {:ok, Enum.filter(@events, &(&1 in events))}

      unknown ->
        {:error, "Unknown events #{Enum.join(unknown, ", ")}; use #{Enum.join(@events, ", ")}."}
    end
  end

  def notify(_events), do: {:error, "events must be a list of #{Enum.join(@events, ", ")}."}

  @doc "The kind of news (`events/0`) a change from `changes/3` is."
  def event(:merged), do: "merged"
  def event(:closed), do: "closed"
  def event(:checks_failing), do: "checks"
  def event(:checks_passing), do: "checks"
  def event(:conflicting), do: "conflicts"
  def event({:left_merge_queue, _reason}), do: "merge_queue"
  def event({:activity, %{"kind" => "review"}}), do: "reviews"
  def event({:activity, _comment}), do: "comments"

  # The link list as the thread keeps it; host state is not activity.
  defp heard(state, thread_id, links) do
    case Orchestration.upsert(state, "thread", thread_id, &Map.put(&1, "pullRequests", links)) do
      nil -> []
      {kind, id, patch} -> [{kind, id, Map.put(patch, "q", true)}]
    end
  end

  @doc "What a thread hears of a pull request it has just linked: the snapshot, as no news."
  def baseline(snapshot), do: advance(%{"checksFailed" => false}, snapshot, [])

  @doc """
  What a thread has heard once it heard `snapshot`, told of `changes`. A snapshot that
  does not say (no checks, mergeability unknown) keeps what was heard; the review and
  comment marker and the merge-queue removal marker are kept only once snapshots carry
  them, so links synced before they did are not woken for their whole history.
  """
  def advance(heard, snapshot, changes) do
    checks = snapshot["checksState"] || heard["checksState"]

    mergeability =
      if snapshot["mergeability"] in [nil, "unknown"],
        do: heard["mergeability"],
        else: snapshot["mergeability"]

    failed =
      cond do
        :checks_failing in changes -> true
        checks == "passing" -> false
        true -> heard["checksFailed"] == true
      end

    %{
      "state" => snapshot["state"] || heard["state"],
      "checksState" => checks,
      "mergeability" => mergeability,
      "checksFailed" => failed
    }
    |> advance_activity(heard, snapshot)
    |> advance_removal(heard, snapshot)
  end

  # `activityAt` is the newest review or comment heard; `reviewActivityAt` and
  # `commentActivityAt` the newest of each kind, so news of one kind heard without
  # telling (a subscription to the other) never hides the other's. A link heard
  # before the kinds were kept apart starts both at `activityAt`. `commentEditAt`
  # only marks that the comment marker was written under the edit-time stamp:
  # present (a time or nil) once a snapshot carrying that stamp (its
  # `commentStamp`) advanced it. A snapshot synced before the stamp existed
  # still holds creation times, so advancing over it writes no mark: a boot
  # check over stored rows must not re-baseline before the first new sync.
  defp advance_activity(next, heard, snapshot) do
    cond do
      Map.has_key?(snapshot, "activity") or Map.has_key?(snapshot, "activities") ->
        all = activities(snapshot)
        newest = fn activities, from -> Enum.reduce(activities, from, &latest(&2, &1["at"])) end

        advanced =
          Enum.reduce(
            ~w(review comment),
            Map.put(next, "activityAt", newest.(all, heard["activityAt"])),
            fn kind, next ->
              key = kind_key(kind)
              of_kind = Enum.filter(all, &(kind_key(&1) == key))
              Map.put(next, key, newest.(of_kind, Map.get(heard, key, heard["activityAt"])))
            end
          )

        cond do
          snapshot["commentStamp"] == "edited" ->
            Map.put(advanced, "commentEditAt", advanced["commentActivityAt"])

          Map.has_key?(heard, "commentEditAt") ->
            Map.put(advanced, "commentEditAt", heard["commentEditAt"])

          true ->
            advanced
        end

      Map.has_key?(heard, "activityAt") ->
        Map.merge(
          next,
          Map.take(heard, ~w(activityAt reviewActivityAt commentActivityAt commentEditAt))
        )

      true ->
        next
    end
  end

  # The newest trusted review and comment, then the signed-in account's own; a snapshot
  # synced before the kinds were kept apart carries only the newest of either.
  defp activities(snapshot), do: trusted_activities(snapshot) ++ own_activities(snapshot)
  defp trusted_activities(snapshot), do: activities(snapshot, "activities", "activity")
  defp own_activities(snapshot), do: activities(snapshot, "ownActivities", "ownActivity")

  defp activities(snapshot, key, fallback) do
    case snapshot[key] do
      list when is_list(list) -> list
      _ -> List.wrap(snapshot[fallback])
    end
    |> Enum.filter(&is_map/1)
    |> Enum.sort_by(&(JS.epoch_ms(&1["at"]) || 0))
  end

  defp kind_key(%{"kind" => kind}), do: kind_key(kind)
  defp kind_key("review"), do: "reviewActivityAt"
  defp kind_key(_comment), do: "commentActivityAt"

  defp heard_at(heard, activity), do: Map.get(heard, kind_key(activity), heard["activityAt"])

  defp advance_removal(next, heard, snapshot) do
    cond do
      Map.has_key?(snapshot, "mergeQueueRemoval") ->
        Map.put(
          next,
          "mergeQueueRemovalAt",
          latest(heard["mergeQueueRemovalAt"], get_in(snapshot, ["mergeQueueRemoval", "at"]))
        )

      Map.has_key?(heard, "mergeQueueRemovalAt") ->
        Map.put(next, "mergeQueueRemovalAt", heard["mergeQueueRemovalAt"])

      true ->
        next
    end
  end

  @doc """
  The news in `snapshot` for a thread that heard `heard`, oldest kind first: a merge
  or a close; while open, checks that went to failing, checks that pass again after
  the thread heard they failed, a conflict with the base branch, and leaving the
  merge queue (`{:left_merge_queue, reason}`) later than any removal it heard; and the
  newest review and the newest comment each newer than any of its kind it heard
  (`{:activity, activity}`). One by the signed-in account counts only when none of the
  thread's `runs` was going as it was posted: that one is the agent's own. A removal is open-only news, so one whose pull
  request then merged or closed is told as that, not as a queue failure.
  """
  def changes(heard, snapshot, runs \\ []) do
    state = snapshot["state"]
    open? = state == "open"
    removal = snapshot["mergeQueueRemoval"]

    [
      state == "merged" and heard["state"] != "merged" and :merged,
      state == "closed" and heard["state"] != "closed" and :closed,
      open? and snapshot["checksState"] == "failing" and heard["checksState"] != "failing" and
        :checks_failing,
      open? and snapshot["checksState"] == "passing" and heard["checksFailed"] == true and
        :checks_passing,
      open? and snapshot["mergeability"] == "conflicting" and
        heard["mergeability"] != "conflicting" and :conflicting,
      open? and Map.has_key?(heard, "mergeQueueRemovalAt") and is_map(removal) and
        later?(removal["at"], heard["mergeQueueRemovalAt"]) and
        {:left_merge_queue, removal["reason"]}
    ]
    |> Enum.filter(& &1)
    |> Kernel.++(activity_changes(heard, snapshot, runs))
  end

  defp activity_changes(heard, snapshot, runs) do
    if Map.has_key?(heard, "activityAt") do
      new? = &later?(&1["at"], heard_at(heard, &1))
      others = Enum.filter(trusted_activities(snapshot), new?)

      own =
        Enum.filter(own_activities(snapshot), &(new?.(&1) and not during_run?(&1["at"], runs)))

      Enum.map(others ++ own, &{:activity, &1})
    else
      []
    end
  end

  defp during_run?(at, runs) do
    at = JS.epoch_ms(at)

    Enum.any?(runs, fn run ->
      start = JS.epoch_ms(run["requestedAt"] || run["startedAt"])
      done = JS.epoch_ms(run["completedAt"])
      start != nil and start <= at and (done == nil or at <= done)
    end)
  end

  defp later?(at, nil), do: JS.epoch_ms(at) != nil
  defp later?(at, heard), do: (JS.epoch_ms(at) || 0) > (JS.epoch_ms(heard) || 0)

  defp latest(a, b), do: if(later?(b, a), do: b, else: a)

  # --- the message --------------------------------------------------------------------

  @doc "The `message.dispatch` that tells thread `thread_id` the news, `[{link, changes}]`."
  def wake(thread_id, news) do
    summary =
      Enum.map_join(news, "; ", fn {link, changes} ->
        "#{name(link)}: #{Enum.map_join(changes, ", ", &label/1)}"
      end)

    text =
      Enum.map_join(news, "\n\n", fn {link, changes} -> describe(link, changes) end) <>
        "\n\nlist_thread_pull_requests lists every pull request this thread owns. " <>
        "unsubscribe_pull_request stops some or all of these messages for one; " <>
        "unlinking it (unlink_pull_request) or settling the thread stops them all."

    id = HalC2.Environment.uuid4()

    %{
      "type" => "message.dispatch",
      "commandId" => "command:pr-wake:#{thread_id}:#{id}",
      "threadId" => thread_id,
      "messageId" => "message:pr-wake:" <> id,
      "text" => text,
      "attachments" => [],
      "createdBy" => "system",
      "creationSource" => "server",
      "dispatchMode" => %{"type" => "queue_after_active"},
      "notification" => %{
        "source" => %{
          "kind" => "pull_request",
          "pullRequests" => Enum.map(news, fn {link, _} -> Links.key(link) end)
        },
        "outcome" => outcome(Enum.flat_map(news, &elem(&1, 1))),
        "summary" => summary
      }
    }
  end

  defp describe(link, changes) do
    %{"host" => host, "repository" => repository, "number" => number} = Links.normalize(link)
    url = link["url"]

    if forgejo?(host, url),
      do: describe_forgejo(link, changes),
      else: describe_github(link, changes, host, repository, number, url)
  end

  defp forgejo?(host, url),
    do:
      HalC2.PullRequests.host_kind(host) == "forgejo" or
        String.match?(url || "", ~r{/pulls/\d+(?:[/?#]|$)})

  defp describe_github(link, changes, host, repository, number, url) do
    api = if host == "github.com", do: "gh api", else: "gh api --hostname #{host}"

    lines =
      Enum.map(changes, fn
        :checks_failing -> "- Checks are failing. See which with `gh pr checks #{url}`."
        :checks_passing -> "- Checks pass again."
        :conflicting -> "- It conflicts with its base branch."
        :merged -> "- It was merged."
        :closed -> "- It was closed without merging."
        {:left_merge_queue, reason} -> "- " <> left_merge_queue(link, repository, number, reason)
        {:activity, activity} -> "- " <> said(activity)
      end)

    """
    Pull request #{name(link)} #{url} needs your attention:
    #{Enum.join(lines, "\n")}
    Read its reviews and comments with `#{api} repos/#{repository}/pulls/#{number}/reviews`, \
    `#{api} repos/#{repository}/pulls/#{number}/comments` and \
    `#{api} repos/#{repository}/issues/#{number}/comments`, and its checks with \
    `gh pr checks #{url}`.\
    """
  end

  # Forgejo has no `gh`. The pull request's page shows it all to anyone; its API answers
  # a request carrying fj's token. Every path names the link's server: `tea api` would
  # ask whichever server tea's active login is for, which may hold another pull request
  # of the same repository and number (fj has no `api` command).
  defp describe_forgejo(link, changes) do
    %{"host" => host, "repository" => repository, "number" => number} = Links.normalize(link)
    pull = "repos/#{repository}/pulls/#{number}"
    api = "https://#{host}/api/v1"

    lines =
      Enum.map(changes, fn
        :checks_failing ->
          "- Checks are failing. Each failing status's `target_url` links its job's log."

        :checks_passing ->
          "- Checks pass again."

        :conflicting ->
          "- It conflicts with its base branch."

        :merged ->
          "- It was merged."

        :closed ->
          "- It was closed without merging."

        {:left_merge_queue, _reason} ->
          "- It left the merge queue."

        {:activity, activity} ->
          "- " <> said(activity)
      end)

    """
    Pull request #{name(link)} #{link["url"]} needs your attention:
    #{Enum.join(lines, "\n")}
    Its page #{link["url"]} shows them. Over its API, with the token `fj` signs in \
    to #{host} with as `Authorization: token <token>`, read its reviews at \
    `#{api}/#{pull}/reviews` (a review's inline comments at \
    `#{api}/#{pull}/reviews/<id>/comments`), its comments at \
    `#{api}/repos/#{repository}/issues/#{number}/comments`, and its checks at \
    `#{api}/repos/#{repository}/commits/<head sha>/status`, the head sha being `head.sha` \
    in `#{api}/#{pull}`.\
    """
  end

  # The queue's checks run on its own commit, so the head stays green: name the queue
  # run the agent should read, found by the queue branch's prefix.
  defp left_merge_queue(link, repository, number, "failed_checks") do
    base = get_in(link, ["snapshot", "baseBranch"]) || "main"

    "It left the merge queue: its checks failed there. See the queue's run with " <>
      "`gh run list --repo #{repository} --event merge_group --limit 100 " <>
      "--json databaseId,headBranch,status,conclusion,url " <>
      "--jq '.[] | select(.headBranch | startswith(\"gh-readonly-queue/#{base}/pr-#{number}-\"))'`, " <>
      "then `gh run view <databaseId> --repo #{repository} --log-failed`."
  end

  defp left_merge_queue(_link, _repository, _number, reason) when is_binary(reason) do
    "It left the merge queue (#{String.replace(reason, "_", " ")})."
  end

  defp left_merge_queue(_link, _repository, _number, _reason), do: "It left the merge queue."

  defp said(%{"kind" => "review"} = activity) do
    state = activity["state"] && String.replace(activity["state"], "_", " ")
    "New review from #{activity["author"]}#{if state, do: " (#{state})"}."
  end

  defp said(activity), do: "New comment from #{activity["author"]}."

  defp name(link), do: "#{link["repository"]}##{link["number"]}"

  defp label(:checks_failing), do: "checks failing"
  defp label(:checks_passing), do: "checks pass"
  defp label(:conflicting), do: "merge conflict"
  defp label(:merged), do: "merged"
  defp label(:closed), do: "closed"
  defp label({:left_merge_queue, _}), do: "left merge queue"
  defp label({:activity, %{"kind" => "review"}}), do: "new review"
  defp label({:activity, _}), do: "new comment"

  defp outcome(changes) do
    failed_queue? = {:left_merge_queue, "failed_checks"} in changes

    cond do
      failed_queue? or Enum.any?(changes, &(&1 in [:checks_failing, :conflicting])) -> "failed"
      :closed in changes -> "cancelled"
      Enum.any?(changes, &(&1 in [:merged, :checks_passing])) -> "completed"
      true -> "updated"
    end
  end
end
