defmodule HalC2.Orchestration.Rollback do
  @moduledoc """
  `checkpoint.rollback`: rewinds a thread to one of its checkpoints. The worktree goes
  back to the checkpoint unless `restoreFiles` is false, the provider drops the later
  turns from its conversation, and the later runs become `rolled_back`, which hides
  them from the timeline. A step that fails undoes the ones before it, so files,
  conversation and thread never disagree about where the thread stands.

  Restoring files resets the whole checkout, so it needs a worktree only this
  thread uses.
  """

  alias HalC2.Orchestration
  alias HalC2.Orchestration.Entities
  alias HalC2.StreamState

  @shared_workspace "File restore requires an isolated worktree. This workspace may contain changes from another thread. Rewind the conversation without restoring files instead."
  @active ~w(preparing starting running waiting)
  @finished ~w(completed failed interrupted)

  @spec run(map) :: :ok | {:error, String.t()}
  def run(%{"threadId" => thread_id} = command) do
    # The files go back first: a restore that fails then leaves the provider's
    # conversation as it was, still matching what the thread shows. The provider drops
    # its turns second, and if it cannot, the files return to where they were.
    with {:ok, plan} <- HalC2.Streams.transact(thread_id, :thread, &{[], plan(&1, command)}),
         :ok <- check_isolated(plan),
         {:ok, undo} <- restore(plan),
         {:ok, patch} <- rewind_checked(plan) |> reported(plan) |> or_undo(plan, undo),
         :ok <- HalC2.Streams.transact(thread_id, :thread, &{settle(&1, plan, patch), :ok}) do
      for checkpoint <- plan.stale, do: HalC2.Checkpoint.delete_ref(plan.cwd, checkpoint["ref"])
      if undo, do: HalC2.Checkpoint.delete_ref(plan.cwd, undo)
      HalC2.Vcs.Watch.refresh(plan.cwd)
      HalC2.Workspace.invalidate(plan.cwd)
      :ok
    end
  end

  # A provider that rewound must say where its conversation now stands: an
  # empty report leaves the thread disagreeing with the provider, so the
  # checkpoint is not restored. (The fresh context `rewind/1` marks for a
  # provider that cannot roll back is such a report.)
  defp reported({:ok, patch}, plan) do
    if plan.drop > 0 and patch == %{} do
      {:error,
       HalC2.Orchestration.UserFacingErrors.capability_message(
         plan.instance,
         :rollback_snapshot
       )}
    else
      {:ok, patch}
    end
  end

  defp reported(error, _plan), do: error

  defp or_undo({:ok, _} = ok, _plan, _undo), do: ok

  defp or_undo(error, plan, undo) do
    undo(plan, undo)
    error
  end

  # Puts the worktree back as `restore/1` found it (best effort) and drops the snapshot.
  defp undo(_plan, nil), do: :ok

  defp undo(plan, ref) do
    with {:error, reason} <- HalC2.Checkpoint.restore(plan.cwd, ref) do
      require Logger

      Logger.warning(
        "rewind of #{plan.thread_id} could not put its files back: #{inspect(reason)}"
      )
    end

    HalC2.Checkpoint.delete_ref(plan.cwd, ref)
    :ok
  end

  defp plan(state, command) do
    thread = StreamState.get(state, "thread")[command["threadId"]]
    runs = StreamState.list(state, "run")
    checkpoint = StreamState.get(state, "checkpoint")[command["checkpointId"]]
    scope = checkpoint && StreamState.get(state, "checkpoint-scope")[checkpoint["scopeId"]]

    provider_thread =
      thread && StreamState.get(state, "provider-thread")[thread["activeProviderThreadId"]]

    restore = command["restoreFiles"] != false

    cond do
      thread == nil ->
        {:error, "Thread #{command["threadId"]} was not found."}

      Enum.any?(runs, &(&1["status"] in @active)) ->
        {:error, "Interrupt the current turn before rewinding."}

      checkpoint == nil or checkpoint["status"] != "ready" ->
        {:error, "Checkpoint #{command["checkpointId"]} cannot be restored."}

      scope == nil or scope["id"] != command["scopeId"] ->
        {:error, "Checkpoint #{command["checkpointId"]} is not in scope #{command["scopeId"]}."}

      provider_thread == nil ->
        {:error, "No active provider thread exists for rollback."}

      # A provider with no way to rewind its conversation (Antigravity) is
      # refused in its name before any file moves. A provider plugin that
      # cannot roll back goes through `rewind/1`'s fresh context instead.
      refusal = rewind_refusal(provider_thread) ->
        {:error, refusal}

      true ->
        target = checkpoint["appRunOrdinal"] || 0
        later = Enum.filter(runs, &(&1["ordinal"] > target and &1["status"] in @finished))
        ordinals = MapSet.new(later, & &1["ordinal"])

        # A provider turn carries its run's ordinal.
        turns =
          state
          |> StreamState.list("provider-turn")
          |> Enum.filter(&(&1["providerThreadId"] == provider_thread["id"]))

        dropped = Enum.filter(turns, &MapSet.member?(ordinals, &1["ordinal"]))

        head =
          Enum.find_value(turns, fn turn ->
            if turn["ordinal"] == target and target > 0,
              do: get_in(turn, ["nativeTurnRef", "nativeId"])
          end)

        {:ok,
         %{
           thread_id: thread["id"],
           instance: provider_thread["providerInstanceId"],
           driver: provider_thread["driver"],
           provider_thread: provider_thread,
           native_thread_id: get_in(provider_thread, ["nativeThreadRef", "nativeId"]),
           fork: carried(provider_thread),
           model: get_in(thread, ["modelSelection", "model"]),
           selection_instance: get_in(thread, ["modelSelection", "instanceId"]),
           cwd: scope["cwd"],
           worktree: thread["worktreePath"],
           target: target,
           target_turn: Enum.any?(turns, &(&1["ordinal"] == target)),
           runs: later,
           drop: Enum.count(dropped),
           first_dropped:
             dropped
             |> Enum.min_by(& &1["ordinal"], fn -> %{} end)
             |> get_in(["nativeTurnRef", "nativeId"]),
           head: head,
           checkpoint: checkpoint,
           restore: restore,
           stale:
             state
             |> StreamState.list("checkpoint")
             |> Enum.filter(
               &(&1["scopeId"] == scope["id"] and &1["status"] == "ready" and
                   (&1["appRunOrdinal"] || 0) > target)
             )
         }}
    end
  end

  defp rewind_refusal(provider_thread) do
    instance = provider_thread["providerInstanceId"]
    driver = provider_thread["driver"] || Orchestration.driver_for(instance)

    if HalC2.Plugins.declared(driver) == nil do
      case HalC2.Orchestration.CommandPolicy.ensure(instance, :rollback) do
        :ok -> nil
        {:error, message} -> message
      end
    end
  end

  # A Codex session carried from another machine and not yet opened: the rewind
  # forks it from its copy first (`HalC2.PortableSessions`).
  defp carried(%{"carriedSession" => %{"driver" => "codex"} = session} = provider_thread) do
    if provider_thread["nativeThreadRef"] == nil,
      do: %{thread: session["nativeId"], turn: nil, path: session["path"]}
  end

  defp carried(_provider_thread), do: nil

  # The provider the plan was made against must still be the thread's active
  # one when the rewind runs: rewinding another provider's conversation would
  # drop turns from the wrong history.
  defp rewind_checked(plan) do
    thread =
      plan.thread_id
      |> HalC2.Streams.state()
      |> StreamState.get("thread")
      |> Map.get(plan.thread_id, %{})

    # Compared with what the plan recorded, not with the provider thread's
    # instance: picking another provider in the composer changes the
    # selection without moving the conversation, and a selection that names
    # no instance compares equal to itself.
    if thread["activeProviderThreadId"] == plan.provider_thread["id"] and
         get_in(thread, ["modelSelection", "instanceId"]) == plan.selection_instance do
      rewind(plan)
    else
      {:error,
       "Active provider changed before rollback target #{plan.checkpoint["id"]} could execute on thread #{plan.thread_id}."}
    end
  end

  # Codex is asked to drop the turns after the target turn; without that turn
  # in the history the MC recorded for it, the count cannot be worked out.
  defp rewind(%{driver: "codex", target: target, target_turn: false} = plan)
       when target > 0,
       do:
         {:error,
          "Cannot roll back Codex thread #{plan.provider_thread["id"]}: target turn was not found in the provider's turn history."}

  # Nothing to drop from the conversation when every later run is already gone.
  defp rewind(%{drop: 0}), do: {:ok, %{}}

  defp rewind(%{driver: "claudeAgent", target: target, head: nil}) when target > 0,
    do: {:error, "Cannot rewind this Claude thread: no message was recorded for that turn."}

  # A provider plugin that cannot roll its conversation back starts the next turn in
  # a fresh context, marked as no longer matching the provider's own history. A
  # provider that fails to drop the turns fails the whole rewind; nothing has changed yet.
  defp rewind(plan) do
    provider = HalC2.Plugins.declared(plan.driver)

    if provider == nil or :rollback in (provider[:capabilities] || []) do
      runtime = Orchestration.runtime(plan.instance)
      rollback = fn -> runtime.rollback(plan.thread_id, plan) end

      with {:error, reason} <-
             Orchestration.session_call(rollback, {:error, "its session stopped"}),
           do:
             {:error,
              "Failed to roll back #{plan.driver} provider thread #{plan.provider_thread["id"]}: #{reason}"}
    else
      {:ok, %{"nativeThreadRef" => nil, "contextDivergent" => true}}
    end
  end

  # Restores the files when asked: `{:ok, ref}` names a snapshot of the worktree as it
  # was (nil when nothing was restored), for `undo/2`.
  defp restore(%{restore: false}), do: {:ok, nil}

  defp restore(plan) do
    ref = "refs/hal-c2/orchestration-v2/rewind-undo/#{HalC2.Environment.uuid4()}"
    # A worktree that cannot be snapshotted is still restored, just without a way back.
    undo = if HalC2.Checkpoint.capture(plan.cwd, ref) == :ok, do: ref

    case HalC2.Checkpoint.restore(plan.cwd, plan.checkpoint["ref"]) do
      :ok ->
        {:ok, undo}

      error ->
        undo(plan, undo)

        case error do
          {:error, {_status, detail}} -> {:error, "Could not restore the checkpoint: #{detail}"}
          {:error, reason} -> {:error, "Could not restore the checkpoint: #{inspect(reason)}"}
        end
    end
  end

  defp settle(state, plan, patch) do
    at = Entities.now()
    # A provider that rewinds into a copy of its conversation renames the kept turns:
    # old native turn id -> new.
    {renamed, patch} = Map.pop(patch, "nativeTurnRefs", %{})

    provider_thread =
      Orchestration.upsert(state, "provider-thread", plan.provider_thread["id"], fn entity ->
        entity
        |> Map.merge(patch)
        |> then(&if(plan.fork && patch != %{}, do: Map.delete(&1, "carriedSession"), else: &1))
        |> Map.merge(%{
          "lastRunOrdinal" => if(plan.target > 0, do: plan.target),
          "status" => "idle",
          "updatedAt" => at
        })
      end)

    stale =
      for checkpoint <- plan.stale,
          do:
            Orchestration.upsert(
              state,
              "checkpoint",
              checkpoint["id"],
              &Map.put(&1, "status", "stale")
            )

    turns =
      for turn <- StreamState.list(state, "provider-turn"),
          turn["providerThreadId"] == plan.provider_thread["id"],
          copy = renamed[get_in(turn, ["nativeTurnRef", "nativeId"])],
          do:
            Orchestration.upsert(
              state,
              "provider-turn",
              turn["id"],
              &put_in(&1, ["nativeTurnRef", "nativeId"], copy)
            )

    rolled_back = &Map.merge(&1, %{"status" => "rolled_back", "completedAt" => at})

    runs =
      Enum.flat_map(plan.runs, fn run ->
        [
          Orchestration.upsert(state, "run", run["id"], rolled_back),
          run["rootNodeId"] && Orchestration.upsert(state, "node", run["rootNodeId"], rolled_back)
        ]
      end)

    # An upsert that changes nothing is nil.
    Enum.reject([provider_thread | stale ++ turns ++ runs], &is_nil/1)
  end

  defp check_isolated(%{restore: false}), do: :ok

  defp check_isolated(plan),
    do: if(isolated?(plan), do: :ok, else: {:error, @shared_workspace})

  # The thread's own worktree, which no other thread on this MC uses or has
  # used: a thread still pointing at it (archived ones included, through a
  # symbolic link or directly), or one whose checkpoints were taken in it
  # before it moved elsewhere, makes the workspace shared, since restoring
  # would reset the whole checkout under both.
  defp isolated?(plan) do
    cwd = real(plan.cwd)

    plan.worktree != nil and cwd == real(plan.worktree) and
      not Enum.any?(other_threads(plan.thread_id), fn {id, row} ->
        (row["worktreePath"] != nil and real(row["worktreePath"]) == cwd) or
          Enum.any?(scope_cwds(id), &(&1 != nil and real(&1) == cwd))
      end)
  end

  defp other_threads(thread_id) do
    for {{mc, id}, {"thread", row}} <- HalC2.Shell.rows(),
        mc == node(),
        id != thread_id,
        row["deletedAt"] == nil,
        do: {id, row}
  end

  # Folds only the thread's checkpoint-scope events from the log: a rollback
  # must not rebuild every other thread's whole stream state (messages
  # included) just to see where its checkpoints were taken. The log is
  # append-only, so nothing a snapshot holds is missing here.
  defp scope_cwds(thread_id) do
    HalC2.Store.path()
    |> HalC2.Store.reduce_stream(
      thread_id,
      0,
      %{},
      fn event, scopes ->
        cond do
          StreamState.void?(event) ->
            scopes

          scope = HalC2.Patch.apply(scopes[event.entity], event.patch) ->
            Map.put(scopes, event.entity, scope)

          true ->
            Map.delete(scopes, event.entity)
        end
      end,
      kinds: ["checkpoint-scope"]
    )
    |> Map.values()
    |> Enum.map(& &1["cwd"])
    |> Enum.uniq()
  end

  # The path with its symlinks resolved (macOS temp paths go through /var -> /private/var).
  defp real(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce("/", fn part, dir ->
      next = Path.join(dir, part)

      case :file.read_link_all(next) do
        {:ok, target} -> Path.expand(to_string(target), dir)
        _ -> next
      end
    end)
  end
end
