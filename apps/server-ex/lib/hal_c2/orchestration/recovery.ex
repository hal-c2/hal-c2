defmodule HalC2.Orchestration.Recovery do
  @moduledoc """
  Settles turns an MC was running when it stopped. A provider program that outlived
  the MC and checkpointed the run its thread is on (`HalC2.Subprocess.Durable`) goes
  on: `continue/0` connects its runtime to it and the thread is not touched. Any
  other is killed, here or by `HalC2.Subprocess.Orphans`, so every run still active on
  the rest of this MC's threads is ended as interrupted, with its items, prompts, and
  provider thread; otherwise the thread would stay "running" and refuse its next message.

  A run the MC accepted but never handed to its provider goes back to the
  front of the queue instead, and `continue/0` starts it once, the way an effect
  outbox replays pending provider work.

  Work a provider left running in the background after its turn (a subagent, a
  background command) died with the process too, and is ended the same way; a thread
  that had finished its turn is then told which background commands the restart
  ended (`continue/0`), where its project continues threads after a restart. A
  task the thread delegated runs in its own thread and is left to settle when
  that ends (`Delegation.finished/3`); one whose child had already stopped without
  telling it settles now (`Delegation.reconcile/2`), and one whose child this boot
  interrupted settles once `continue/0` has seen whether the child goes on.

  Only threads whose sidebar row shows an active run or background work are opened.

  A clean stop settles the same way as it goes (`shut_down/0`, from
  `HalC2.Orchestration.Recovery.Shutdown`), once the runtimes have stopped, so no thread
  is left running while the MC is down; what it would have continued is kept for the
  next boot. Work a restart or a shutdown cut off says which ended it (`statusDetail`).
  """

  require Logger

  alias HalC2.Orchestration.Entities
  alias HalC2.{Patch, StreamState}
  alias HalC2.Subprocess.Durable

  @active_runs ~w(preparing queued starting running waiting)
  @active ~w(pending preparing queued starting running waiting active)
  # What a clean stop settled and would continue, for the next boot.
  @shut_down_key "recovery:shutdown"

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
    leaving(false)
    survivors = reattachable()
    :persistent_term.put({__MODULE__, :survivors}, survivors)
    threads = active_threads(Map.keys(survivors))

    # Before any run is interrupted: a child still running when the MC stopped is not
    # one that ended, and `continue/0` may resume it to report as it should.
    reconciled = Map.new(threads, &{&1, HalC2.Orchestration.Delegation.reconcile(&1)})
    {shut_down, shut_down_threads} = take_shut_down()
    :persistent_term.put({__MODULE__, :delegating}, Enum.uniq(threads ++ shut_down_threads))

    settled =
      for thread_id <- threads,
          {count, continuable} = settle(thread_id),
          count = count + reconciled[thread_id],
          count > 0,
          do: {thread_id, continuable}

    # A thread settled again here (its program survived the stop but not the boot)
    # goes by what this boot found.
    settled = settled ++ Enum.reject(shut_down, &List.keymember?(settled, elem(&1, 0), 0))

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

  # This MC's threads whose sidebar row shows an active run or background work, but those
  # in `except`.
  defp active_threads(except) do
    for {{mc, thread_id}, {"thread", row}} <- HalC2.Shell.rows(),
        mc == node(),
        thread_id not in except,
        # `status` is the latest run's, so a cancelled queued run can hide a running
        # one behind it; `activityRunStatus` is the latest active run's.
        row["status"] in @active_runs or row["activityRunStatus"] != nil or
          (row["pendingBackgroundTasks"] || []) != [],
        do: thread_id
  end

  @doc """
  Settles, at a clean stop and once the provider runtimes have stopped, the turns of
  threads whose program does not outlive the MC, saying the shutdown ended them. What
  `continue/0` would do for them is kept for the next boot's `run/0`.
  """
  def shut_down do
    going_on = for {thread_id, %{snapshot: %{}}} <- Durable.survivors_peek(), do: thread_id
    # The sidebar rows trail their streams by a flush; bring them up to date first.
    for stream_id <- Registry.select(HalC2.Streams.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}]),
        do: HalC2.Streams.flush_shell(stream_id)

    settled =
      for thread_id <- active_threads(going_on),
          # One still up (a service an update added stops before them) ends its own.
          not HalC2.Orchestration.IdleSessions.live?(thread_id),
          {count, what} = settle(thread_id, :shutdown),
          count > 0,
          do: {thread_id, what}

    for {thread_id, _} <- settled, do: HalC2.Streams.flush_shell(thread_id)

    if settled != [] do
      :ok = HalC2.Store.put_meta(@shut_down_key, JSON.encode!(Enum.map(settled, &encode/1)))
      Logger.info("settled turns in #{length(settled)} threads before stopping")
    end

    :ok
  end

  defp encode({thread_id, what}) do
    case what do
      %{} = run ->
        %{"thread" => thread_id, "continue" => run}

      :requeued ->
        %{"thread" => thread_id, "requeued" => true}

      {:background, run, commands} ->
        %{"thread" => thread_id, "background" => run, "commands" => commands}

      nil ->
        %{"thread" => thread_id}
    end
  end

  defp decode(%{"thread" => thread_id} = entry) do
    case entry do
      %{"continue" => %{} = run} ->
        {thread_id, run}

      %{"requeued" => true} ->
        {thread_id, :requeued}

      %{"background" => %{} = run, "commands" => commands} ->
        {thread_id, {:background, run, commands}}

      _ ->
        {thread_id, nil}
    end
  end

  # What the last clean stop settled: `{[{thread, what}], threads}`, read once.
  defp take_shut_down do
    case HalC2.Store.meta(HalC2.Store.home_path(), @shut_down_key) do
      nil ->
        {[], []}

      text ->
        :ok = HalC2.Store.delete_meta(@shut_down_key)
        entries = text |> JSON.decode!() |> Enum.map(&decode/1)
        {Enum.reject(entries, &is_nil(elem(&1, 1))), Enum.map(entries, &elem(&1, 0))}
    end
  rescue
    e ->
      Logger.warning("could not read what the last stop settled: #{Exception.message(e)}")
      {[], []}
  end

  # The programs that can go on: alive, and last saved on the very run the thread is on.
  # A checkpoint from before its run started, or one that ran on after it ended,
  # would drive the wrong turn, so that program is killed and the turn settled.
  defp reattachable do
    Durable.survivors()
    |> Enum.filter(fn {thread_id, survivor} ->
      keep = Durable.attachable?(survivor.dir) and current?(thread_id, survivor.snapshot)
      unless keep, do: Durable.kill_dir(survivor.dir)
      keep
    end)
    |> Map.new()
  end

  defp current?(thread_id, snapshot) do
    runs = HalC2.Streams.state(thread_id) |> StreamState.list("run")

    running =
      runs
      |> Enum.filter(&(&1["status"] in ~w(preparing starting running waiting)))
      |> Enum.map(& &1["id"])

    saved =
      case snapshot.state[:turn] do
        %{ids: %{run: run}} -> [run]
        _ -> []
      end

    # A queued run with nothing ahead of it: the MC went before moving it on. Settling holds
    # it where the user can see, which a program left to go on would not do.
    waiting? =
      running == [] and Enum.any?(runs, &(&1["status"] == "queued" and &1["queueHeld"] != true))

    running == saved and not waiting?
  end

  @doc false
  # Connects before the MC takes requests; `continue/0` acts on what failed.
  def start_reattach do
    # Before the listener, so a page's agent asked after it is not the reconciliation's.
    HalC2.Space.PageAgent.boot()

    :persistent_term.put({__MODULE__, :failed}, reattach())
    :ignore
  end

  # Connects each survivor's runtime. One that cannot be connected to is killed and
  # settled as if it had not survived; returns what those settled to.
  defp reattach do
    survivors = :persistent_term.get({__MODULE__, :survivors}, %{})
    :persistent_term.erase({__MODULE__, :survivors})

    for {thread_id, survivor} <- survivors,
        result = adopt(thread_id, survivor),
        result != :ok do
      Logger.warning("could not reattach to the program of #{thread_id}: #{inspect(result)}")
      Durable.kill_dir(survivor.dir)
      {_count, what} = settle(thread_id)
      HalC2.Streams.flush_shell(thread_id)
      {thread_id, what}
    end
  end

  defp adopt(thread_id, survivor) do
    survivor.snapshot.runtime.adopt(thread_id, survivor)
  catch
    kind, reason -> {kind, reason}
  end

  @doc """
  Settles one thread's interrupted turn: `{entities changed, what}`, where `what` is
  the run that was mid-turn on a provider thread that can resume, `:requeued` for a
  run that goes back to the queue, `{:background, run, commands}` when the thread's
  turn had finished and only the commands it left running in the background were
  ended (`run` is that turn's), or nil.
  """
  def settle(thread_id, trigger \\ :restart) do
    capturing = capturing(thread_id)

    HalC2.Streams.transact(thread_id, :thread, fn state ->
      changes = changes(state, Entities.now(), trigger, capturing)
      requeued? = Enum.any?(StreamState.list(state, "run"), &unstarted?(state, &1))

      what =
        cond do
          requeued? -> :requeued
          (latest_run(state) || %{})["id"] in capturing -> nil
          true -> continuable(state) || ended_background(state)
        end

      {changes, {length(changes), what}}
    end)
  end

  # The background commands of the thread's finished latest run that are still marked
  # active: they ran in the provider process, which is gone.
  defp ended_background(state) do
    with %{"status" => "completed"} = run <- latest_run(state),
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
  def stopping?,
    do:
      match?({:stopping, _}, :init.get_status()) or
        :persistent_term.get({__MODULE__, :leaving}, false)

  @doc false
  # For tests of a stop in one VM, where `:init` is not stopping.
  def leaving(leaving?), do: :persistent_term.put({__MODULE__, :leaving}, leaving?)

  # Accepted, but the provider never got the turn: no attempt reached it.
  defp unstarted?(state, run) do
    attempt = StreamState.get(state, "run-attempt")[run["activeAttemptId"]]

    run["status"] == "starting" and run["startedAt"] == nil and
      (attempt == nil or (attempt["status"] == "pending" and attempt["providerTurnId"] == nil))
  end

  @doc """
  Asks each thread whose turn the restart cut off to continue, when its project's
  `continueThreadsAfterServerUpdate` is on and nothing newer was sent. Runs once the MC
  can start turns; an MC without automatic actions (`HAL_C2_MC_NO_AUTO_ACTIONS`) only
  ends the tasks of interrupted children.
  """
  def continue do
    failed = :persistent_term.get({__MODULE__, :failed}, []) ++ reattach()
    :persistent_term.erase({__MODULE__, :failed})

    runs =
      :persistent_term.get({__MODULE__, :continuable}, []) ++
        for {thread_id, %{} = run} <- failed, do: {thread_id, run}

    :persistent_term.erase({__MODULE__, :continuable})

    requeued =
      :persistent_term.get({__MODULE__, :requeued}, []) ++
        for {thread_id, :requeued} <- failed, do: thread_id

    :persistent_term.erase({__MODULE__, :requeued})

    background =
      :persistent_term.get({__MODULE__, :background}, []) ++
        for {thread_id, {:background, run, commands}} <- failed, do: {thread_id, run, commands}

    :persistent_term.erase({__MODULE__, :background})

    continued =
      if Application.get_env(:hal_c2, :auto_actions, true) do
        for thread_id <- requeued, not HalC2.Space.PageAgent.stopping?(thread_id) do
          HalC2.Orchestration.start_next(thread_id)
        end

        interrupted =
          for {thread_id, run} <- runs, continue?(thread_id, run) do
            continuation(thread_id, run, "Continue where you left off.")
            thread_id
          end

        # A thread whose turn had finished hears which of its background commands the
        # restart ended, so its agent can start them again rather than wait on them.
        waiting =
          for {thread_id, run, commands} <- background, continue?(thread_id, run) do
            continuation(thread_id, run, background_text(commands))
            thread_id
          end

        interrupted ++ waiting
      else
        []
      end

    # A child this boot interrupted and nothing continued will not report: its task ends.
    delegating = :persistent_term.get({__MODULE__, :delegating}, [])
    :persistent_term.erase({__MODULE__, :delegating})
    for thread_id <- delegating, do: HalC2.Orchestration.Delegation.reconcile(thread_id, false)
    # A page's agent that is not going on says so on its page, whatever the crash lost.
    HalC2.Space.PageAgent.reconcile(continued)

    :ok
  end

  defp continue?(thread_id, run) do
    case HalC2.Shell.row(node(), thread_id) do
      {"thread", thread} ->
        thread["archivedAt"] == nil and thread["deletedAt"] == nil and
          HalC2.Settings.for_project(thread["projectId"])["continueThreadsAfterServerUpdate"] ==
            true and same_provider?(thread, run) and latest?(thread_id, run) and
          not continued?(thread_id, run) and not HalC2.Space.PageAgent.stopping?(thread_id)

      _ ->
        false
    end
  end

  # A thread set to another provider since would be continued on a conversation it left.
  defp same_provider?(thread, run) do
    instance = fn entity ->
      (entity["modelSelection"] || %{})["instanceId"] || entity["providerInstanceId"]
    end

    instance.(thread) in [nil, instance.(run)]
  end

  # A recovery that ran again (a boot cut short after it asked) asks once.
  defp continued?(thread_id, run),
    do:
      StreamState.fetch(
        HalC2.Streams.state(thread_id),
        "message",
        "message:restart-continuation:#{run["id"]}"
      ) != nil

  defp continuation(thread_id, run, text) do
    command = %{
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
    }

    HalC2.Orchestration.Effects.enqueue(
      thread_id,
      "provider-runtime.continue",
      %{"command" => command}
    )
  end

  defp background_text([command]),
    do:
      "The server stopped, which ended the background command `#{command}`. " <>
        "Start it again if you still need it, then continue where you left off."

  defp background_text(commands),
    do:
      "The server stopped, which ended these background commands: " <>
        Enum.map_join(commands, ", ", &"`#{&1}`") <>
        ". Start them again if you still need them, then continue where you left off."

  # A message the user sent since takes precedence; a held one does not when it
  # was made before `run` (a run that passed a held queue was sent after it, and
  # is numbered below it since the renumbering). A held run made after `run` —
  # a message queued behind it, held by this very settle — still counts as
  # newer-sent, so no continuation jumps it: creation order (the order of
  # `StreamState.list/2`) tells the two apart where the ordinal no longer can.
  defp latest?(thread_id, run) do
    state = HalC2.Streams.state(thread_id)
    runs = StreamState.list(state, "run")
    made = Map.new(Enum.with_index(runs, &{&1["id"], &2}))

    Enum.all?(runs, fn other ->
      (HalC2.Projection.Shell.held_never_started?(other) and
         made[other["id"]] <= made[run["id"]]) or
        (other["ordinal"] || 0) <= (run["ordinal"] || 0)
    end)
  end

  # The thread's latest run, passing over held queued runs: a run that passed a held
  # queue is numbered below the held run it passed (`Orchestration.start_ordinal/3`). A
  # queue that is not held was sent after the latest run that began, and is latest.
  defp latest_run(state),
    do: state |> StreamState.list("run") |> HalC2.Projection.Shell.latest_run()

  defp continuable(state) do
    with %{"status" => "running"} = run <- latest_run(state),
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

  # Runs whose provider turn ended but whose checkpoint the MC stopped capturing. The
  # capture runs again at boot (`HalC2.Orchestration.Effects`) and completes the run,
  # so the restart leaves them be (apps/server ProviderRuntimeRecovery.ts).
  defp capturing(thread_id) do
    for %{"type" => "checkpoint.capture", "status" => status, "args" => %{"runId" => run_id}} <-
          HalC2.Orchestration.Effects.effects(thread_id),
        status in ~w(pending running),
        into: MapSet.new(),
        do: run_id
  end

  defp changes(state, at, trigger, capturing) do
    done = %{"status" => "interrupted", "completedAt" => at}

    # What a capturing run still owns: itself, its attempts, provider turn, nodes and items.
    left =
      for {id, run} <- StreamState.get(state, "run"),
          id in capturing,
          attempt = StreamState.get(state, "run-attempt")[run["activeAttemptId"]] || %{},
          own <- [id, attempt["providerTurnId"]],
          own != nil,
          into: MapSet.new(),
          do: own

    ended = if trigger == :shutdown, do: "shut down", else: "restarted"
    detail = "Cancelled because the server #{ended} before the provider work completed."

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
                 "streaming" => false,
                 "statusDetail" => detail
               })
           )},
          {"message",
           &if(&1["streaming"] == true or Map.has_key?(&1, "steer"),
             do:
               &1 |> Map.delete("steer") |> Map.merge(%{"streaming" => false, "updatedAt" => at})
           )},
          # The provider that asked is gone, so nobody can answer the request now.
          {"runtime-request",
           &if(&1["status"] == "pending" and &1["id"] not in asked,
             do:
               Map.merge(&1, %{
                 "status" => "expired",
                 "responseCapability" => %{
                   "type" => "not_resumable",
                   "reason" => "The server #{ended} before this runtime request was resolved."
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
        id not in left and entity["runId"] not in capturing,
        next = fun.(entity),
        next != nil,
        patch = Patch.diff(entity, next),
        patch != :unchanged,
        do: {kind, id, patch}
  end
end
