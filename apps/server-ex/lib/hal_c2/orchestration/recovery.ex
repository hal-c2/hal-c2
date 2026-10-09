defmodule HalC2.Orchestration.Recovery do
  @moduledoc """
  Settles turns an MC was running when it stopped. Provider processes die with
  the MC, so at boot every run still active on this MC's threads is ended as
  interrupted, with its items, prompts, and provider thread; otherwise the thread
  would stay "running" and refuse its next message.

  A run the MC accepted but never handed to its provider goes back to the
  front of the queue instead, and `continue/0` starts it once, as the Node
  server's effect outbox replays pending provider work.

  Work a provider left running in the background after its turn (a subagent, a
  background command) died with the process too, and is ended the same way; a thread
  that had finished its turn is then told which background commands the restart
  ended (`continue/0`), where its project continues threads after a restart. A
  task the thread delegated runs in its own thread and is left to settle when
  that ends (`Delegation.finished/3`); one whose child had already stopped without
  telling it settles now (`Delegation.reconcile/1`).

  Only threads whose sidebar row shows an active run or background work are opened.
  """

  require Logger

  alias HalC2.Orchestration.Entities
  alias HalC2.{Patch, StreamState}

  @active_runs ~w(preparing queued starting running waiting)
  @active ~w(pending preparing queued starting running waiting active)

  @doc false
  # Settles before the MC takes requests, so no client sees a stale "running".
  def start_link do
    run()
    :ignore
  end

  @doc """
  Settles every interrupted turn on this MC; returns the threads touched. Runs
  that could go on are kept for `continue/0`.
  """
  def run do
    threads =
      for {{mc, thread_id}, {"thread", row}} <- HalC2.Shell.rows(),
          mc == node(),
          # `status` is the latest run's, so a cancelled queued run can hide a running
          # one behind it; `activityRunStatus` is the latest active run's.
          row["status"] in @active_runs or row["activityRunStatus"] != nil or
            (row["pendingBackgroundTasks"] || []) != [],
          do: thread_id

    # Before any run is interrupted: a child still running when the MC stopped is not
    # one that ended, and `continue/0` may resume it to report as it should.
    reconciled = Map.new(threads, &{&1, HalC2.Orchestration.Delegation.reconcile(&1)})

    settled =
      for thread_id <- threads,
          {count, continuable} = settle(thread_id),
          count = count + reconciled[thread_id],
          count > 0,
          do: {thread_id, continuable}

    # Their sidebar rows too, or a client connecting right away would see "running".
    for {thread_id, _} <- settled, do: HalC2.Streams.flush_shell(thread_id)

    :persistent_term.put(
      {__MODULE__, :continuable},
      for({thread_id, %{} = run} <- settled, do: {thread_id, run})
    )

    :persistent_term.put(
      {__MODULE__, :requeued},
      for({thread_id, :requeued} <- settled, do: thread_id)
    )

    :persistent_term.put(
      {__MODULE__, :background},
      for({thread_id, {:background, run, commands}} <- settled, do: {thread_id, run, commands})
    )

    if settled != [], do: Logger.info("settled interrupted turns in #{length(settled)} threads")
    Enum.map(settled, &elem(&1, 0))
  end

  @doc """
  Settles one thread's interrupted turn: `{entities changed, what}`, where `what` is
  the run that was mid-turn on a provider thread that can resume, `:requeued` for a
  run that goes back to the queue, `{:background, run, commands}` when the thread's
  turn had finished and only the commands it left running in the background were
  ended (`run` is that turn's), or nil.
  """
  def settle(thread_id) do
    HalC2.Streams.transact(thread_id, :thread, fn state ->
      changes = changes(state, Entities.now())
      requeued? = Enum.any?(StreamState.list(state, "run"), &unstarted?(state, &1))

      what =
        if requeued?, do: :requeued, else: continuable(state) || ended_background(state)

      {changes, {length(changes), what}}
    end)
  end

  # The background commands of the thread's finished latest run that are still marked
  # active: they ran in the provider process, which is gone.
  defp ended_background(state) do
    with %{"status" => "completed"} = run <-
           state |> StreamState.list("run") |> Enum.max_by(& &1["ordinal"], fn -> nil end),
         %{"nativeThreadRef" => %{}} <-
           StreamState.get(state, "provider-thread")[run["providerThreadId"]],
         [_ | _] = commands <-
           for(
             %{"type" => "command_execution", "input" => input} = item <-
               StreamState.list(state, "turn-item"),
             item["status"] in @active and item["runId"] == run["id"] and is_binary(input),
             do: input
           ) do
      {:background, run, commands}
    else
      _ -> nil
    end
  end

  @doc """
  Whether the MC itself is stopping. A provider runtime that ends then leaves the
  background work it ran marked as it is, so the next boot ends it here and can ask
  the thread to continue; ended by the runtime it would look like work the user stopped.
  """
  def stopping?, do: match?({:stopping, _}, :init.get_status())

  # Accepted, but the provider never got the turn: no attempt reached it.
  defp unstarted?(state, run) do
    attempt = StreamState.get(state, "run-attempt")[run["activeAttemptId"]]

    run["status"] == "starting" and run["startedAt"] == nil and
      (attempt == nil or (attempt["status"] == "pending" and attempt["providerTurnId"] == nil))
  end

  @doc """
  Asks each thread whose turn the restart cut off to continue, when its project's
  `continueThreadsAfterServerUpdate` is on and nothing newer was sent, as the Node
  server does. Runs once the MC can start turns.
  """
  def continue do
    runs = :persistent_term.get({__MODULE__, :continuable}, [])
    :persistent_term.erase({__MODULE__, :continuable})
    requeued = :persistent_term.get({__MODULE__, :requeued}, [])
    :persistent_term.erase({__MODULE__, :requeued})

    background = :persistent_term.get({__MODULE__, :background}, [])
    :persistent_term.erase({__MODULE__, :background})

    for thread_id <- requeued, do: HalC2.Orchestration.start_next(thread_id)

    for {thread_id, run} <- runs,
        continue?(thread_id, run),
        do: continuation(thread_id, run, "Continue where you left off.")

    # A thread whose turn had finished hears which of its background commands the
    # restart ended, so its agent can start them again rather than wait on them.
    for {thread_id, run, commands} <- background,
        continue?(thread_id, run),
        do: continuation(thread_id, run, background_text(commands))

    :ok
  end

  defp continue?(thread_id, run) do
    case HalC2.Shell.row(node(), thread_id) do
      {"thread", thread} ->
        thread["archivedAt"] == nil and thread["deletedAt"] == nil and
          HalC2.Settings.for_project(thread["projectId"])["continueThreadsAfterServerUpdate"] ==
            true and latest?(thread_id, run)

      _ ->
        false
    end
  end

  defp continuation(thread_id, run, text) do
    HalC2.Orchestration.dispatch(%{
      "type" => "message.dispatch",
      "commandId" => "command:restart-continuation:#{run["id"]}",
      "threadId" => thread_id,
      "messageId" => "message:restart-continuation:#{run["id"]}",
      "text" => text,
      "attachments" => [],
      "modelSelection" => run["modelSelection"],
      "dispatchMode" => %{"type" => "start_immediately"},
      "createdBy" => "agent",
      "creationSource" => "server"
    })
  end

  defp background_text([command]),
    do:
      "The server restarted, which stopped the background command `#{command}`. " <>
        "Start it again if you still need it, then continue where you left off."

  defp background_text(commands),
    do:
      "The server restarted, which stopped these background commands: " <>
        Enum.map_join(commands, ", ", &"`#{&1}`") <>
        ". Start them again if you still need them, then continue where you left off."

  # A message the user sent since takes precedence.
  defp latest?(thread_id, run) do
    state = HalC2.Streams.state(thread_id)
    Enum.all?(StreamState.list(state, "run"), &(&1["ordinal"] <= run["ordinal"]))
  end

  defp continuable(state) do
    with %{"status" => "running"} = run <-
           state |> StreamState.list("run") |> Enum.max_by(& &1["ordinal"], fn -> nil end),
         %{"nativeThreadRef" => %{}} <-
           StreamState.get(state, "provider-thread")[run["providerThreadId"]] do
      run
    else
      _ -> nil
    end
  end

  defp requeue(run),
    do:
      Map.merge(run, %{
        "status" => "queued",
        "queuePosition" => 0,
        "queueHeld" => false,
        "activeAttemptId" => nil
      })

  defp changes(state, at) do
    done = %{"status" => "interrupted", "completedAt" => at}

    delegated =
      for {id, %{"origin" => "app_owned"}} <- StreamState.get(state, "subagent"),
          into: MapSet.new(),
          do: id

    # Questions answered with a message need no provider: they stay open.
    asked =
      for {id, request} <- StreamState.get(state, "runtime-request"),
          HalC2.Orchestration.TurnWriter.message_request?(request),
          into: MapSet.new(),
          do: id

    for {kind, fun} <- [
          {"run",
           fn run ->
             cond do
               # Queued messages wait for the user to resume the queue.
               run["status"] == "queued" -> Map.put(run, "queueHeld", true)
               # Never reached its provider: it goes first and starts again.
               unstarted?(state, run) -> requeue(run)
               run["status"] in @active_runs -> Map.merge(run, done)
               true -> nil
             end
           end},
          {"run-attempt", &if(&1["status"] in @active, do: Map.merge(&1, done))},
          {"provider-turn", &if(&1["status"] in @active, do: Map.merge(&1, done))},
          {"node",
           &if(&1["status"] in @active and &1["id"] not in delegated, do: Map.merge(&1, done))},
          {"subagent",
           &if(&1["origin"] == "provider_native" and &1["status"] in @active,
             do: Map.merge(&1, Map.put(done, "updatedAt", at))
           )},
          {"turn-item",
           &if(
             &1["status"] in @active and &1["nodeId"] not in delegated and
               &1["requestId"] not in asked,
             do:
               Map.merge(&1, %{
                 "status" => "interrupted",
                 "completedAt" => at,
                 "updatedAt" => at,
                 "streaming" => false
               })
           )},
          {"message",
           &if(&1["streaming"] == true,
             do: Map.merge(&1, %{"streaming" => false, "updatedAt" => at})
           )},
          # The provider that asked is gone, so nobody can answer the request now.
          {"runtime-request",
           &if(&1["status"] == "pending" and &1["id"] not in asked,
             do:
               Map.merge(&1, %{
                 "status" => "expired",
                 "responseCapability" => %{
                   "type" => "not_resumable",
                   "reason" => "The server restarted before this runtime request was resolved."
                 },
                 "resolvedAt" => at
               })
           )},
          {"provider-thread",
           &if(&1["status"] == "active",
             do: Map.merge(&1, %{"status" => "idle", "updatedAt" => at})
           )}
        ],
        {id, entity} <- StreamState.get(state, kind),
        next = fun.(entity),
        next != nil,
        patch = Patch.diff(entity, next),
        patch != :unchanged,
        do: {kind, id, patch}
  end
end
