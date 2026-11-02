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
        case changes(heard, snapshot, runs) do
          [] -> {Map.put(link, "heard", advance(heard, snapshot, [])), []}
          _ when not idle? -> {link, []}
          changes -> {Map.put(link, "heard", advance(heard, snapshot, changes)), changes}
        end
    end
  end

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
  comment marker is kept only once snapshots carry it, so links synced before they did
  are not woken for their whole history.
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

    next = %{
      "state" => snapshot["state"] || heard["state"],
      "checksState" => checks,
      "mergeability" => mergeability,
      "checksFailed" => failed
    }

    cond do
      Map.has_key?(snapshot, "activity") ->
        Map.put(
          next,
          "activityAt",
          heard["activityAt"]
          |> latest(get_in(snapshot, ["activity", "at"]))
          |> latest(get_in(snapshot, ["ownActivity", "at"]))
        )

      Map.has_key?(heard, "activityAt") ->
        Map.put(next, "activityAt", heard["activityAt"])

      true ->
        next
    end
  end

  @doc """
  The news in `snapshot` for a thread that heard `heard`, oldest kind first: a merge
  or a close; while open, checks that went to failing, checks that pass again after
  the thread heard they failed, and a conflict with the base branch; and a review or
  comment newer than any it heard (`{:activity, activity}`). One by the signed-in
  account counts only when none of the thread's `runs` was going as it was posted:
  that one is the agent's own.
  """
  def changes(heard, snapshot, runs \\ []) do
    state = snapshot["state"]
    open? = state == "open"
    new? = &(is_map(&1) and later?(&1["at"], heard["activityAt"]))
    own = snapshot["ownActivity"]

    [
      state == "merged" and heard["state"] != "merged" and :merged,
      state == "closed" and heard["state"] != "closed" and :closed,
      open? and snapshot["checksState"] == "failing" and heard["checksState"] != "failing" and
        :checks_failing,
      open? and snapshot["checksState"] == "passing" and heard["checksFailed"] == true and
        :checks_passing,
      open? and snapshot["mergeability"] == "conflicting" and
        heard["mergeability"] != "conflicting" and :conflicting,
      Map.has_key?(heard, "activityAt") and new?.(snapshot["activity"]) and
        {:activity, snapshot["activity"]},
      Map.has_key?(heard, "activityAt") and new?.(own) and not during_run?(own["at"], runs) and
        {:activity, own}
    ]
    |> Enum.filter(& &1)
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
        "Unlinking one (unlink_pull_request) or settling the thread stops these messages."

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
    api = if host == "github.com", do: "gh api", else: "gh api --hostname #{host}"
    url = link["url"]

    lines =
      Enum.map(changes, fn
        :checks_failing -> "- Checks are failing. See which with `gh pr checks #{url}`."
        :checks_passing -> "- Checks pass again."
        :conflicting -> "- It conflicts with its base branch."
        :merged -> "- It was merged."
        :closed -> "- It was closed without merging."
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
  defp label({:activity, %{"kind" => "review"}}), do: "new review"
  defp label({:activity, _}), do: "new comment"

  defp outcome(changes) do
    cond do
      Enum.any?(changes, &(&1 in [:checks_failing, :conflicting])) -> "failed"
      :closed in changes -> "cancelled"
      Enum.any?(changes, &(&1 in [:merged, :checks_passing])) -> "completed"
      true -> "updated"
    end
  end
end
