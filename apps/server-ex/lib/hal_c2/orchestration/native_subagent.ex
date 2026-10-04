defmodule HalC2.Orchestration.NativeSubagent do
  @moduledoc """
  A subagent the provider started itself (Grok's `task` tool, say), written the way
  the TS adapters project one (`SubagentProjection.ts`).

  The parent thread gets a `provider_native` subagent entity with its node (under the
  run's root node) and turn item. Its work goes to a child thread, a subagent of the
  parent forked from that node: the task prompt as a user message, then the
  subagent's answer as an assistant message. The provider runs the child, so the
  child thread has no run of its own.
  """

  alias HalC2.{Orchestration, StreamState}
  alias HalC2.Orchestration.Entities

  @terminal ~w(completed failed interrupted cancelled)

  @doc """
  Records a subagent the provider started as `native` (its tool call id) in the turn
  `ids`; `task` has `prompt`, `title`, `model`. Returns the handle `append/2` and
  `finish/3` take.
  """
  def start(ids, native, task) do
    driver = Entities.driver(ids)
    instance = Entities.instance(ids)
    at = Entities.now()
    id = "node:subagent:#{driver}:#{native}"
    child_id = HalC2.Environment.uuid4()
    child_root = "node:subagent-root:#{driver}:#{native}"
    item_id = "turn-item:subagent:#{id}"
    ref = Entities.provider_ref(native, driver)
    prompt = task["prompt"] || ""
    parent = stream(ids.thread) |> StreamState.get("thread") |> Map.get(ids.thread, %{})

    HalC2.Streams.transact(ids.thread, :thread, fn state ->
      item =
        Entities.turn_item(
          Map.put(ids, :node, id),
          item_id,
          "subagent",
          Orchestration.next_ordinal(state),
          "running",
          at,
          %{
            "title" => task["title"],
            "nodeId" => id,
            "subagentId" => id,
            "origin" => "provider_native",
            "driver" => driver,
            "providerInstanceId" => instance,
            "childThreadId" => child_id,
            "prompt" => prompt,
            "result" => nil,
            "nativeItemRef" => ref
          }
        )

      {[
         Orchestration.create("subagent", id, %{
           "id" => id,
           "threadId" => ids.thread,
           "runId" => ids.run,
           "parentNodeId" => ids.root_node,
           "origin" => "provider_native",
           "createdBy" => "agent",
           "driver" => driver,
           "providerInstanceId" => instance,
           "providerThreadId" => nil,
           "childThreadId" => child_id,
           "nativeTaskRef" => ref,
           "prompt" => prompt,
           "title" => task["title"],
           "model" => task["model"],
           "status" => "running",
           "result" => nil,
           "startedAt" => at,
           "completedAt" => nil,
           "updatedAt" => at
         }),
         Orchestration.create(
           "node",
           id,
           Entities.node(ids, id, "subagent", "running", at, %{
             "countsForRun" => false,
             "nativeItemRef" => ref
           })
         ),
         Orchestration.create("turn-item", item_id, item)
       ], :ok}
    end)

    child =
      Entities.thread(
        %{
          "threadId" => child_id,
          "projectId" => parent["projectId"],
          "title" => task["title"] || title(prompt),
          "modelSelection" =>
            if(task["model"],
              do: Map.put(parent["modelSelection"] || %{}, "model", task["model"]),
              else: parent["modelSelection"]
            ),
          "runtimeMode" => parent["runtimeMode"],
          "interactionMode" => parent["interactionMode"],
          "createdBy" => "agent",
          "creationSource" => "provider"
        },
        at
      )
      |> Map.merge(%{
        "worktreePath" => parent["worktreePath"],
        "branch" => parent["branch"],
        "lineage" => %{
          "parentThreadId" => ids.thread,
          "relationshipToParent" => "subagent",
          "rootThreadId" => get_in(parent, ["lineage", "rootThreadId"]) || ids.thread
        },
        "forkedFrom" => %{"type" => "node", "nodeId" => id}
      })

    sub = %{
      id: id,
      item: item_id,
      thread: ids.thread,
      child: child_id,
      root: child_root,
      native: native,
      driver: driver,
      sender: ids.thread,
      text: ""
    }

    HalC2.Streams.transact(child_id, :thread, fn _state ->
      changes =
        Enum.map(conversation(sub, :user, prompt, at), fn {kind, id, entity} ->
          Orchestration.create(kind, id, entity)
        end)

      {[Orchestration.create("thread", child_id, child) | changes], :ok}
    end)

    sub
  end

  @doc """
  Reopens a subagent the provider resumed with `message` (Claude's SendMessage to a
  subagent it started earlier): the subagent `entity` runs again, and the message is
  the next thing its child thread says, where the answer to it will follow. Works from
  the thread's record alone, so a runtime that has forgotten the subagent can resume
  it. Returns the handle `append/2` and `finish/3` take.
  """
  def resume(ids, %{"id" => id, "childThreadId" => child} = entity, message) do
    driver = Entities.driver(ids)
    native = get_in(entity, ["nativeTaskRef", "nativeId"])
    at = Entities.now()
    said = stream(child) |> StreamState.list("message") |> length()

    sub = %{
      id: id,
      item: "turn-item:subagent:#{id}",
      thread: entity["threadId"],
      child: child,
      root: "node:subagent-root:#{driver}:#{native}",
      # Its own messages, after those the child thread already has.
      native: "#{native}:resume:#{said}",
      ordinal: 100 + 2 * said,
      driver: driver,
      sender: entity["threadId"],
      text: ""
    }

    open =
      &Map.merge(&1, %{
        "status" => "running",
        "completedAt" => nil,
        "result" => nil,
        "updatedAt" => at
      })

    HalC2.Streams.transact(sub.thread, :thread, fn state ->
      {[
         Orchestration.upsert(state, "subagent", id, open),
         Orchestration.upsert(
           state,
           "node",
           id,
           &Map.merge(&1, %{"status" => "running", "completedAt" => nil})
         ),
         Orchestration.upsert(state, "turn-item", sub.item, open)
       ]
       |> Enum.filter(&is_tuple/1), :ok}
    end)

    HalC2.Streams.transact(child, :thread, fn _state ->
      {Enum.map(conversation(sub, :user, message || "", at), fn {kind, id, entity} ->
         Orchestration.create(kind, id, entity)
       end), :ok}
    end)

    sub
  end

  @doc "Appends streamed answer text to the subagent's child thread."
  def append(sub, ""), do: sub

  def append(sub, text) do
    sub = %{sub | text: sub.text <> text}
    at = Entities.now()

    HalC2.Streams.transact(sub.child, :thread, fn state ->
      changes =
        Enum.map(conversation(sub, :assistant, sub.text, at), fn {kind, id, entity} ->
          if StreamState.get(state, kind)[id],
            do:
              Orchestration.upsert(
                state,
                kind,
                id,
                &Map.merge(&1, Map.drop(entity, ["createdAt", "startedAt"]))
              ),
            else: Orchestration.create(kind, id, entity)
        end)

      {Enum.filter(changes, &is_tuple/1), :ok}
    end)

    sub
  end

  @doc "Shows what the running subagent is doing now, on its entity and its turn item."
  def progress(sub, text) do
    at = Entities.now()
    put = &Map.merge(&1, %{"progress" => text, "updatedAt" => at})

    HalC2.Streams.transact(sub.thread, :thread, fn state ->
      {[
         Orchestration.upsert(state, "subagent", sub.id, put),
         Orchestration.upsert(state, "turn-item", sub.item, put)
       ]
       |> Enum.filter(&is_tuple/1), :ok}
    end)

    sub
  end

  @doc """
  Settles the subagent as `status` with its `result` (the answer it streamed when the
  provider reports none).
  """
  def finish(sub, status, result) do
    status = if status in @terminal, do: status, else: "completed"
    result = if result in [nil, ""], do: nilify(sub.text), else: result
    sub = if sub.text == "" and result, do: append(sub, result), else: sub
    at = Entities.now()
    done = &Map.merge(&1, %{"status" => status, "completedAt" => at})

    HalC2.Streams.transact(sub.thread, :thread, fn state ->
      {[
         Orchestration.upsert(state, "subagent", sub.id, fn task ->
           Map.merge(task, %{
             "status" => status,
             "result" => result,
             "completedAt" => at,
             "updatedAt" => at
           })
         end),
         Orchestration.upsert(state, "node", sub.id, done),
         Orchestration.upsert(state, "turn-item", sub.item, fn item ->
           Map.merge(item, %{
             "status" => status,
             "result" => result,
             "completedAt" => at,
             "updatedAt" => at
           })
         end)
       ]
       |> Enum.filter(&is_tuple/1), :ok}
    end)

    sub
  end

  # The child's message and its turn item (`makeSubagentConversationArtifacts`).
  defp conversation(sub, role, text, at) do
    native = "#{sub.native}:#{if role == :user, do: "prompt", else: "message:result"}"
    message_id = "message:#{sub.driver}:#{native}"
    item_id = "turn-item:#{sub.driver}:#{native}"
    ids = %{thread: sub.child, run: nil, root_node: sub.root, provider_thread: nil}
    sender = if role == :user, do: %{"senderThreadId" => sub.sender}, else: %{}

    message =
      Entities.message(ids, message_id, Atom.to_string(role), text, false, at, %{
        "createdBy" => "agent",
        "creationSource" => "provider"
      })
      |> Map.merge(sender)

    fields =
      if role == :user,
        do:
          Map.merge(sender, %{
            "createdBy" => "agent",
            "creationSource" => "provider",
            "inputIntent" => "turn_start",
            "attachments" => []
          }),
        else: %{"streaming" => false}

    item =
      Entities.turn_item(
        ids,
        item_id,
        "#{role}_message",
        Map.get(sub, :ordinal, 100) + if(role == :user, do: 0, else: 1),
        "completed",
        at,
        Map.merge(fields, %{"messageId" => message_id, "text" => text})
      )
      |> Map.put("nativeItemRef", %{
        "driver" => sub.driver,
        "nativeId" => native,
        "strength" => "weak"
      })

    [{"message", message_id, message}, {"turn-item", item_id, item}]
  end

  defp title(prompt), do: prompt |> String.split("\n") |> hd() |> String.slice(0, 80)

  defp nilify(""), do: nil
  defp nilify(text), do: text

  defp stream(thread_id), do: HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))
end
