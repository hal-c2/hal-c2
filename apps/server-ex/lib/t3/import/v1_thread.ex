defmodule T3.Import.V1Thread do
  @moduledoc """
  Folds a thread's version 1 event log (the Node server's history before
  orchestration v2) into v2 entities, the ones the Node server's
  `LegacyV1ThreadImporter` migrates it to: the thread itself, and each user and
  assistant message with its turn item.

  Each event does what the Node server's v1 projection does to the thread row and
  its messages. Plans, activities, sessions, checkpoints and request responses are
  not migrated, so they only move the thread's `updatedAt`. Turn start, interrupt,
  revert and session stop requests change nothing: their results are logged as
  later events.

  `apply/4` returns the entities an event changed, `nil` for one it removed.
  """

  alias T3.Projection.PullRequests

  @prefix "migration:v1"
  @default_model_selection %{"instanceId" => "codex", "model" => "gpt-6-astra"}
  @touching ~w(thread.proposed-plan-upserted thread.activity-appended
    thread.approval-response-requested thread.user-input-response-requested
    thread.session-set thread.turn-diff-completed thread.reverted)

  @type change :: {String.t(), String.t(), map | nil}

  @spec new(String.t()) :: map
  def new(thread_id),
    do: %{id: thread_id, thread: nil, messages: %{}, turns: %{}, ordinal: 0}

  @spec apply(map, String.t(), map, String.t()) :: {map, [change]}
  def apply(state, "thread.created", payload, _at) do
    removed = for id <- Map.keys(state.messages), change <- message_changes(id, nil), do: change
    thread = created(payload)
    {%{state | thread: thread, messages: %{}, turns: %{}}, removed ++ [thread_change(thread)]}
  end

  def apply(%{thread: nil} = state, _type, _payload, _at), do: {state, []}

  def apply(state, "thread.message-sent", %{"role" => role} = payload, _at)
      when role in ["user", "assistant"] do
    id = payload["messageId"]
    {message, state} = sent(state, Map.get(state.messages, id), payload)
    {put_in(state.messages[id], message), message_changes(id, message, state.id)}
  end

  def apply(state, "thread.turn-diff-completed", payload, at) do
    state = put_in(state.turns[payload["turnId"]], payload["checkpointTurnCount"])
    touch(state, at)
  end

  def apply(state, "thread.reverted", %{"turnCount" => count}, at) do
    turns = Map.filter(state.turns, fn {_, n} -> is_integer(n) and n <= count end)
    kept = retained(Map.values(state.messages), MapSet.new(Map.keys(turns)), count)
    dropped = Map.keys(state.messages) -- kept

    {state, changes} =
      touch(%{state | turns: turns, messages: Map.take(state.messages, kept)}, at)

    {state, Enum.flat_map(dropped, &message_changes(&1, nil)) ++ changes}
  end

  def apply(state, type, _payload, at) when type in @touching, do: touch(state, at)

  def apply(state, type, payload, _at) do
    case fields(type, payload, state.thread) do
      nil ->
        {state, []}

      fields ->
        thread = Map.merge(state.thread, fields)
        {%{state | thread: thread}, [thread_change(thread)]}
    end
  end

  defp touch(state, at) do
    thread = Map.put(state.thread, "updatedAt", at)
    {%{state | thread: thread}, [thread_change(thread)]}
  end

  defp thread_change(thread), do: {"thread", thread["id"], thread}

  defp created(p) do
    selection =
      case p["modelSelection"] do
        %{"instanceId" => i, "model" => m} = s when is_binary(i) and is_binary(m) -> s
        _ -> @default_model_selection
      end

    title = if String.trim(p["title"] || "") == "", do: "Untitled thread", else: p["title"]
    id = p["threadId"]

    %{
      "createdBy" => "system",
      "creationSource" => "server",
      "id" => id,
      "projectId" => p["projectId"],
      "title" => title,
      "providerInstanceId" => selection["instanceId"],
      "modelSelection" => selection,
      "runtimeMode" =>
        if(p["runtimeMode"] in ~w(approval-required auto-accept-edits auto full-access),
          do: p["runtimeMode"],
          else: "full-access"
        ),
      "interactionMode" => if(p["interactionMode"] == "plan", do: "plan", else: "default"),
      "branch" => blank_nil(p["branch"]),
      "worktreePath" => blank_nil(p["worktreePath"]),
      "linkedPullRequest" => nil,
      "pullRequests" => [],
      "branchPullRequest" => nil,
      "activeOrderKey" => nil,
      "activeProviderThreadId" => nil,
      "historyOrigin" => "v1_import",
      "lineage" => %{"parentThreadId" => nil, "relationshipToParent" => nil, "rootThreadId" => id},
      "forkedFrom" => nil,
      "createdAt" => p["createdAt"],
      "updatedAt" => p["updatedAt"],
      "archivedAt" => nil,
      "settledOverride" => nil,
      "settledAt" => nil,
      "unsettledAt" => nil,
      "snoozedUntil" => nil,
      "snoozedAt" => nil,
      "pinnedAt" => nil,
      "pinOrderKey" => nil,
      "lastVisitedAt" => nil,
      "deletedAt" => nil
    }
  end

  defp blank_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_nil(_), do: nil

  # The thread fields each v1 event sets, as the v1 projection sets them.
  defp fields("thread.deleted", p, _),
    do: %{"deletedAt" => p["deletedAt"], "updatedAt" => p["deletedAt"], "pullRequests" => []}

  defp fields("thread.archived", p, _),
    do: %{"archivedAt" => p["archivedAt"], "updatedAt" => p["updatedAt"]}

  defp fields("thread.unarchived", p, _),
    do: %{"archivedAt" => nil, "updatedAt" => p["updatedAt"]}

  defp fields("thread.settled", p, _),
    do: %{
      "settledOverride" => "settled",
      "settledAt" => p["settledAt"],
      "unsettledAt" => nil,
      "activeOrderKey" => nil,
      "updatedAt" => p["updatedAt"]
    }

  # A thread already pinned active keeps its re-entry stamp.
  defp fields("thread.unsettled", p, thread),
    do: %{
      "settledOverride" => if(p["reason"] == "user", do: "active"),
      "settledAt" => nil,
      "unsettledAt" =>
        if(thread["settledOverride"] == "active", do: thread["unsettledAt"], else: p["updatedAt"]),
      "updatedAt" => p["updatedAt"]
    }

  defp fields("thread.snoozed", p, _),
    do: %{
      "snoozedUntil" => p["snoozedUntil"],
      "snoozedAt" => p["snoozedAt"],
      "updatedAt" => p["updatedAt"]
    }

  defp fields("thread.unsnoozed", p, _),
    do: %{"snoozedUntil" => nil, "snoozedAt" => nil, "updatedAt" => p["updatedAt"]}

  defp fields("thread.pinned", p, _),
    do:
      Map.merge(
        %{"pinnedAt" => p["pinnedAt"], "updatedAt" => p["updatedAt"]},
        Map.take(p, ["pinOrderKey"])
      )

  defp fields("thread.unpinned", p, _),
    do: %{"pinnedAt" => nil, "pinOrderKey" => nil, "updatedAt" => p["updatedAt"]}

  defp fields("thread.pin-reordered", p, _),
    do: %{"pinOrderKey" => p["orderKey"], "updatedAt" => p["updatedAt"]}

  defp fields("thread.runtime-mode-set", p, _),
    do: %{"runtimeMode" => p["runtimeMode"], "updatedAt" => p["updatedAt"]}

  defp fields("thread.interaction-mode-set", p, _),
    do: %{"interactionMode" => p["interactionMode"], "updatedAt" => p["updatedAt"]}

  # The legacy single link owns only the manual links.
  defp fields("thread.meta-updated", p, thread) do
    selection = Map.take(p, ["modelSelection"])

    linked =
      case Map.fetch(p, "linkedPullRequest") do
        {:ok, linked} ->
          kept = Enum.reject(thread["pullRequests"], &(&1["source"] == "manual"))

          added =
            if linked,
              do: [manual_link(linked, p["updatedAt"])],
              else: []

          %{"linkedPullRequest" => linked, "pullRequests" => upsert_links(kept, added)}

        :error ->
          %{}
      end

    p
    |> Map.take(~w(title branch worktreePath activeOrderKey branchPullRequest))
    |> Map.merge(selection)
    |> Map.merge(
      if(selection["modelSelection"],
        do: %{"providerInstanceId" => selection["modelSelection"]["instanceId"]},
        else: %{}
      )
    )
    |> Map.merge(linked)
    |> Map.put("updatedAt", p["updatedAt"])
  end

  defp fields("thread.pull-request-linked", p, thread),
    do: %{
      "pullRequests" => upsert_links(thread["pullRequests"], [p["link"]]),
      "updatedAt" => p["updatedAt"]
    }

  defp fields("thread.pull-request-unlinked", p, thread),
    do: %{
      "pullRequests" => Enum.reject(thread["pullRequests"], &same_link?(&1, p)),
      "updatedAt" => p["updatedAt"]
    }

  # A sync for a link removed in the meantime is stale.
  defp fields("thread.pull-request-synced", p, thread) do
    if Enum.any?(thread["pullRequests"], &same_link?(&1, p)) do
      %{
        "pullRequests" =>
          Enum.map(
            thread["pullRequests"],
            &if(same_link?(&1, p),
              do: Map.merge(&1, %{"snapshot" => p["snapshot"], "stack" => p["stack"]}),
              else: &1
            )
          ),
        "updatedAt" => p["updatedAt"]
      }
    end
  end

  defp fields(_type, _payload, _thread), do: nil

  defp same_link?(a, b), do: PullRequests.key(a) == PullRequests.key(b)

  defp upsert_links(links, added) do
    Enum.reduce(added, links, fn link, links ->
      if Enum.any?(links, &same_link?(&1, link)),
        do: Enum.map(links, &if(same_link?(&1, link), do: link, else: &1)),
        else: links ++ [link]
    end)
  end

  defp manual_link(linked, at),
    do:
      linked
      |> PullRequests.legacy_key()
      |> Map.merge(%{
        "url" => linked["url"],
        "source" => "manual",
        "linkedAt" => at,
        "snapshot" => nil,
        "stack" => nil
      })

  # Streaming chunks append; a final message with empty text keeps what streamed.
  defp sent(state, nil, p) do
    ordinal = state.ordinal + 1

    message =
      p
      |> Map.take(
        ~w(messageId role text attachments context turnId streaming createdAt updatedAt)
      )
      |> Map.put("ordinal", ordinal)

    {message, %{state | ordinal: ordinal}}
  end

  defp sent(state, existing, p) do
    text =
      cond do
        p["streaming"] -> existing["text"] <> p["text"]
        p["text"] == "" -> existing["text"]
        true -> p["text"]
      end

    message =
      existing
      |> Map.merge(Map.take(p, ~w(attachments context turnId streaming updatedAt)))
      |> Map.put("text", text)

    {message, state}
  end

  defp message_changes(id, nil),
    do: [{"message", id, nil}, {"turn-item", "#{@prefix}:turn-item:#{id}", nil}]

  defp message_changes(id, m, thread_id) do
    context = if m["context"], do: %{"context" => m["context"]}, else: %{}
    attachments = m["attachments"] || []
    user? = m["role"] == "user"

    message =
      Map.merge(
        %{
          "createdBy" => if(user?, do: "user", else: "agent"),
          "creationSource" => "server",
          "id" => id,
          "threadId" => thread_id,
          "runId" => nil,
          "nodeId" => nil,
          "role" => m["role"],
          "text" => m["text"],
          "attachments" => attachments,
          "streaming" => false,
          "createdAt" => m["createdAt"],
          "updatedAt" => m["updatedAt"]
        },
        context
      )

    item_id = "#{@prefix}:turn-item:#{id}"

    base = %{
      "id" => item_id,
      "threadId" => thread_id,
      "runId" => nil,
      "nodeId" => nil,
      "providerThreadId" => nil,
      "providerTurnId" => nil,
      "nativeItemRef" => nil,
      "parentItemId" => nil,
      "ordinal" => m["ordinal"],
      "status" => if(m["streaming"], do: "interrupted", else: "completed"),
      "title" => nil,
      "startedAt" => m["createdAt"],
      "completedAt" => m["updatedAt"],
      "updatedAt" => m["updatedAt"],
      "messageId" => id,
      "text" => m["text"]
    }

    item =
      if user?,
        do:
          Map.merge(base, %{
            "createdBy" => "user",
            "creationSource" => "server",
            "type" => "user_message",
            "inputIntent" => "turn_start",
            "attachments" => attachments
          }),
        else: Map.merge(base, %{"type" => "assistant_message", "streaming" => false})

    [{"message", id, message}, {"turn-item", item_id, Map.merge(item, context)}]
  end

  # The messages a revert to `count` turns keeps (`retainThreadMessagesAfterRevert`):
  # those of kept turns, topped up with the earliest turnless user and assistant ones.
  defp retained(messages, turns, count) do
    kept = for m <- messages, m["turnId"] != nil and MapSet.member?(turns, m["turnId"]), do: m

    fill = fn kept, role ->
      missing = count - Enum.count(kept, &(&1["role"] == role))

      fallback =
        messages
        |> Enum.filter(
          &(&1["role"] == role and &1 not in kept and
              (&1["turnId"] == nil or MapSet.member?(turns, &1["turnId"])))
        )
        |> Enum.sort_by(&{&1["createdAt"], &1["messageId"]})
        |> Enum.take(max(missing, 0))

      kept ++ fallback
    end

    kept |> fill.("user") |> fill.("assistant") |> Enum.map(& &1["messageId"])
  end
end
