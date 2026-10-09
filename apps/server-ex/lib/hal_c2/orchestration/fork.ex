defmodule HalC2.Orchestration.Fork do
  @moduledoc """
  `thread.fork` and `thread.merge_back`.

  A fork is a new thread that starts with a copy of its source's history through
  the fork point, so it reads and diffs like the source did, and keeps doing so
  if the source is deleted. Its first run picks the conversation up from there
  (`HalC2.Orchestration.Handoff`). Merging back queues the fork's newer work for the
  parent's next run.
  """

  alias HalC2.{Orchestration, Patch, StreamState}
  alias HalC2.Orchestration.Entities

  # What a thread's history is made of; each belongs to a run.
  @history ~w(run-attempt node message turn-item plan checkpoint)

  @spec fork(map) :: :ok | {:error, String.t()}
  def fork(%{"sourceThreadId" => source_id, "targetThreadId" => target_id} = command) do
    source = state(source_id)
    thread = live(source, source_id)

    with %{} <- thread || {:error, "Thread #{source_id} was not found."},
         {:ok, run} <- source_run(source, command["sourcePoint"]),
         # A run its provider finished ("waiting": not settled yet) is as good a point.
         :ok <- completed(run, ["completed", "waiting"]) do
      at = command["createdAt"] || Entities.now()

      target =
        Map.merge(thread, %{
          "id" => target_id,
          "title" => command["title"] || "#{thread["title"]} fork",
          "createdBy" => command["createdBy"] || "user",
          "creationSource" => command["creationSource"] || "web",
          "activeProviderThreadId" => nil,
          "lineage" => %{
            "parentThreadId" => source_id,
            "relationshipToParent" => "fork",
            "rootThreadId" => get_in(thread, ["lineage", "rootThreadId"]) || source_id
          },
          "forkedFrom" => %{"type" => "run", "threadId" => source_id, "runId" => run["id"]},
          "createdAt" => at,
          "updatedAt" => at,
          "archivedAt" => nil,
          "settledOverride" => nil,
          "settledAt" => nil,
          "snoozedUntil" => nil,
          "snoozedAt" => nil,
          "pinnedAt" => nil,
          "lastVisitedAt" => nil,
          "deletedAt" => nil
        })

      transfer =
        transfer(command, "fork", source_id, target_id, point(source, run), nil, run, at)

      changes =
        [create("thread", target_id, target)] ++
          history(source, run["ordinal"], target_id, at) ++
          [create("context-transfer", transfer["id"], transfer)]

      HalC2.Streams.transact(target_id, :thread, fn state ->
        if StreamState.get(state, "thread")[target_id],
          do: {[], {:error, "Thread #{target_id} already exists."}},
          else: {changes, :ok}
      end)
    end
  end

  @spec merge_back(map) :: :ok | {:error, String.t()}
  def merge_back(%{"sourceThreadId" => fork_id, "targetThreadId" => parent_id} = command) do
    fork = state(fork_id)
    thread = live(fork, fork_id)

    forked =
      fork
      |> StreamState.list("context-transfer")
      |> Enum.find(&(&1["type"] == "fork" and &1["sourceThreadId"] == parent_id))

    with %{} <- thread || {:error, "Thread #{fork_id} was not found."},
         true <-
           (get_in(thread, ["lineage", "parentThreadId"]) == parent_id and forked != nil) ||
             {:error, "Thread #{fork_id} is not a fork of #{parent_id}."},
         {:ok, run} <- source_run(fork, command["sourcePoint"]),
         :ok <- mergeable(fork, run) do
      at = command["createdAt"] || Entities.now()

      HalC2.Streams.transact(parent_id, :thread, fn state ->
        # The parent has seen the fork's work up to the last merge it consumed.
        base =
          state
          |> StreamState.list("context-transfer")
          |> Enum.filter(
            &(&1["type"] == "merge_back" and &1["status"] == "consumed" and
                &1["sourceThreadId"] == fork_id)
          )
          |> Enum.max_by(& &1["consumedAt"], fn -> nil end)
          |> case do
            nil -> forked["sourcePoint"]
            consumed -> consumed["sourcePoint"]
          end

        transfer =
          transfer(command, "merge_back", fork_id, parent_id, point(fork, run), base, run, at)

        # A newer merge from the same fork replaces one the parent has not used yet.
        superseded =
          for pending <- StreamState.list(state, "context-transfer"),
              pending["type"] == "merge_back" and pending["status"] == "pending" and
                pending["sourceThreadId"] == fork_id,
              do:
                Orchestration.upsert(state, "context-transfer", pending["id"], fn entity ->
                  Map.merge(entity, %{
                    "status" => "superseded",
                    "error" => "Superseded by merge-back transfer #{transfer["id"]}.",
                    "updatedAt" => at
                  })
                end)

        if live(state, parent_id),
          do: {superseded ++ [create("context-transfer", transfer["id"], transfer)], :ok},
          else: {[], {:error, "Thread #{parent_id} was not found."}}
      end)
    end
  end

  defp state(thread_id), do: HalC2.Streams.state(thread_id)

  # A deleted thread is gone as far as forking and merging go.
  defp live(state, thread_id) do
    case StreamState.get(state, "thread")[thread_id] do
      %{"deletedAt" => deleted} when deleted != nil -> nil
      thread -> thread
    end
  end

  # Work can be merged back once its provider has finished with it, or while the run
  # waits on the user (an approval or a question).
  defp mergeable(state, run) do
    waiting? =
      run["status"] == "running" and
        Enum.any?(StreamState.list(state, "runtime-request"), fn request ->
          request["status"] == "pending" and
            get_in(StreamState.get(state, "node"), [request["nodeId"], "runId"]) == run["id"]
        end)

    if waiting?, do: :ok, else: completed(run, ["completed", "waiting"])
  end

  defp source_run(state, %{"type" => "run", "runId" => run_id}),
    do: found(StreamState.get(state, "run")[run_id])

  defp source_run(state, %{"type" => "checkpoint", "checkpointId" => checkpoint_id}) do
    with %{"runId" => run_id} <- StreamState.get(state, "checkpoint")[checkpoint_id],
         do: found(StreamState.get(state, "run")[run_id]),
         else: (_ -> found(nil))
  end

  defp source_run(state, _latest_stable) do
    state
    |> StreamState.list("run")
    |> Enum.filter(&(&1["status"] == "completed"))
    |> Enum.max_by(& &1["ordinal"], fn -> nil end)
    |> found()
  end

  defp found(nil), do: {:error, "No stable source run was found."}
  defp found(run), do: {:ok, run}

  defp completed(run, statuses) do
    if run["status"] in statuses,
      do: :ok,
      else: {:error, "Run #{run["id"]} is #{run["status"]}; only finished runs can be used."}
  end

  # Where the source's conversation stood after `run`, natively when its provider says.
  defp point(state, run) do
    attempts =
      for attempt <- StreamState.list(state, "run-attempt"),
          attempt["runId"] == run["id"],
          into: MapSet.new(),
          do: attempt["id"]

    turn =
      state
      |> StreamState.list("provider-turn")
      |> Enum.find(&MapSet.member?(attempts, &1["runAttemptId"]))

    provider_thread = turn && StreamState.get(state, "provider-thread")[turn["providerThreadId"]]

    %{
      "threadId" => run["threadId"],
      "runId" => run["id"],
      "checkpointId" => run["checkpointId"],
      "providerThreadRef" => provider_thread && provider_thread["nativeThreadRef"],
      "providerTurnRef" => turn && turn["nativeTurnRef"]
    }
    |> Map.reject(fn {_key, value} -> value == nil end)
  end

  defp transfer(command, type, source_id, target_id, point, base, run, at) do
    %{
      "id" => "context-transfer:#{type}:#{command["commandId"] || Entities.new_id("command")}",
      "type" => type,
      "sourceThreadId" => source_id,
      "targetThreadId" => target_id,
      "sourcePoint" => point,
      "basePoint" => base,
      "sourceProviderInstanceId" => run["providerInstanceId"],
      "targetProviderInstanceId" => nil,
      "targetRunId" => nil,
      "status" => "pending",
      "resolution" => nil,
      "createdBy" => command["createdBy"] || "user",
      "error" => nil,
      "createdAt" => at,
      "updatedAt" => at,
      "consumedAt" => nil
    }
  end

  # The source's runs through `ordinal` and everything they produced, in creation
  # order, as the target's own. A run the provider finished but the source has not
  # settled is finished history in the copy: left "waiting" it would hold the fork's
  # first message in the queue behind a run nothing there will ever settle.
  defp history(state, ordinal, target_id, at) do
    runs =
      for run <- StreamState.list(state, "run"),
          run["ordinal"] <= ordinal,
          into: %{},
          do: {run["id"], run}

    waiting = for {id, %{"status" => "waiting"}} <- runs, into: MapSet.new(), do: id

    scopes =
      for checkpoint <- StreamState.list(state, "checkpoint"),
          Map.has_key?(runs, checkpoint["runId"]),
          into: MapSet.new(),
          do: checkpoint["scopeId"]

    for {kind, id, entity} <- StreamState.rows(state),
        (kind == "run" and Map.has_key?(runs, id)) or
          (kind in @history and Map.has_key?(runs, entity["runId"])) or
          (kind == "checkpoint-scope" and MapSet.member?(scopes, id)) do
      entity =
        cond do
          kind == "run" and entity["status"] == "queued" ->
            Map.merge(entity, %{"status" => "cancelled", "queuePosition" => nil})

          kind in ~w(run run-attempt node) and entity["status"] == "waiting" and
              (entity["runId"] || id) in waiting ->
            Map.merge(entity, %{
              "status" => "completed",
              "completedAt" => entity["completedAt"] || at
            })

          true ->
            entity
        end

      create(kind, id, Map.put(entity, "threadId", target_id))
    end
  end

  defp create(kind, id, entity), do: {kind, id, Patch.diff(nil, entity)}
end
