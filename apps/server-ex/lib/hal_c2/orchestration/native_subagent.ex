defmodule HalC2.Orchestration.NativeSubagent do
  @moduledoc """
  A subagent the provider started itself (Grok's `task` tool, say), projected by the
  provider adapters.

  The parent thread gets a `provider_native` subagent entity with its node (under the
  run's root node) and turn item. Its work goes to a child thread, a subagent of the
  parent forked from that node: the task prompt as a user message, then the
  subagent's answer as an assistant message, with the work it reports in between
  (`item/5`). The provider runs the child, so the child thread has no run of its own.
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
    parent_state = stream(ids.thread)
    parent = parent_state |> StreamState.get("thread") |> Map.get(ids.thread, %{})
    ordinal = length(StreamState.list(parent_state, "subagent")) + 1

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
          "title" => title(parent["title"] || "", task["title"], prompt, ordinal),
          "modelSelection" => subagent_selection(parent["modelSelection"], task["model"]),
          "runtimeMode" => parent["runtimeMode"],
          "interactionMode" => parent["interactionMode"],
          "createdBy" => "agent",
          "creationSource" => "provider"
        },
        at
      )
      |> Map.merge(%{
        # A subagent starts awake, whatever state its parent is in.
        "archivedAt" => nil,
        "settledOverride" => nil,
        "settledAt" => nil,
        "snoozedUntil" => nil,
        "snoozedAt" => nil,
        "lastVisitedAt" => nil,
        "deletedAt" => nil,
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

    HalC2.Streams.transact(child_id, :thread, fn state ->
      changes =
        Enum.map(conversation(state, sub, :user, prompt, at), fn {kind, id, entity} ->
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
    said = HalC2.Streams.read(child, &(&1 |> StreamState.all("message") |> Enum.count()))

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

    # Running again, so no longer what a restart cut off (`Recovery.cut_off?/1`).
    open =
      &Map.merge(&1, %{
        "status" => "running",
        "completedAt" => nil,
        "result" => nil,
        "statusDetail" => nil,
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

    HalC2.Streams.transact(child, :thread, fn state ->
      {Enum.map(conversation(state, sub, :user, message || "", at), fn {kind, id, entity} ->
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
        Enum.map(conversation(state, sub, :assistant, sub.text, at), fn {kind, id, entity} ->
          if StreamState.fetch(state, kind, id),
            do:
              Orchestration.upsert(
                state,
                kind,
                id,
                &Map.merge(&1, Map.drop(entity, ["createdAt", "startedAt", "ordinal"]))
              ),
            else: Orchestration.create(kind, id, entity)
        end)

      {Enum.filter(changes, &is_tuple/1), :ok}
    end)

    sub
  end

  @doc """
  Sets the subagent's task after it started: its entity and turn item, and the
  user message its child thread opened with, and with `title` the title of all
  three. For a provider that names the task only after the subagent is already
  running.
  """
  def prompt(sub, text, title \\ nil) do
    at = Entities.now()
    named = if title, do: %{"title" => title}, else: %{}
    put = &Map.merge(&1, Map.merge(named, %{"prompt" => text, "updatedAt" => at}))

    HalC2.Streams.transact(sub.thread, :thread, fn state ->
      {[
         Orchestration.upsert(state, "subagent", sub.id, put),
         Orchestration.upsert(state, "turn-item", sub.item, put)
       ]
       |> Enum.filter(&is_tuple/1), :ok}
    end)

    HalC2.Streams.transact(sub.child, :thread, fn state ->
      thread =
        if title,
          do: [Orchestration.upsert(state, "thread", sub.child, &Map.merge(&1, named))],
          else: []

      changes =
        Enum.map(conversation(state, sub, :user, text, at), fn {kind, id, entity} ->
          if StreamState.fetch(state, kind, id),
            do:
              Orchestration.upsert(
                state,
                kind,
                id,
                &Map.merge(&1, Map.drop(entity, ["createdAt", "startedAt", "ordinal"]))
              ),
            else: Orchestration.create(kind, id, entity)
        end)

      {Enum.filter(thread ++ changes, &is_tuple/1), :ok}
    end)

    sub
  end

  @doc "Shows the subagent as `status` while it runs: its entity, node and turn item."
  def show(sub, status) do
    at = Entities.now()
    put = &Map.merge(&1, %{"status" => status, "updatedAt" => at})

    HalC2.Streams.transact(sub.thread, :thread, fn state ->
      {[
         Orchestration.upsert(state, "subagent", sub.id, put),
         Orchestration.upsert(state, "node", sub.id, put),
         Orchestration.upsert(state, "turn-item", sub.item, put)
       ]
       |> Enum.filter(&is_tuple/1), :ok}
    end)

    sub
  end

  @doc "Shows what the running subagent is doing now, on its entity and its turn item."
  def progress(sub, text, opts \\ []) do
    at = Entities.now()
    put = &Map.merge(&1, %{"progress" => text, "updatedAt" => at})

    HalC2.Streams.transact(sub.thread, :thread, fn state ->
      {[
         Orchestration.upsert(state, "subagent", sub.id, put),
         Orchestration.upsert(state, "turn-item", sub.item, put)
       ]
       |> Enum.filter(&is_tuple/1), :ok}
    end)

    # `thinking: true` also shows it in the child thread, as one thinking item that
    # holds the latest progress and ends with the subagent.
    if opts[:thinking],
      do:
        item(sub, "#{sub.native}:progress", "reasoning", "running", %{
          "title" => "Subagent progress",
          "text" => text,
          "streaming" => true
        }),
      else: sub
  end

  @doc """
  Writes the subagent's own work into its child thread, for a provider that reports
  it (Claude's messages under the subagent's tool call): a turn item of `type` for its
  `native` id, created the first time and updated with `status` and `fields` after
  that. An `"assistant_message"` (its `text` in `fields`) is something the subagent
  said; the latest is its answer unless the provider reports another.
  """
  def item(sub, native, type, status, fields) do
    at = Entities.now()
    ids = child_ids(sub)
    item_id = "turn-item:#{sub.driver}:#{native}"
    message_id = if type == "assistant_message", do: "message:#{sub.driver}:#{native}"

    fields =
      if message_id,
        do: Map.merge(%{"messageId" => message_id, "streaming" => false}, fields),
        else: fields

    put =
      Map.merge(fields, %{"status" => status, "updatedAt" => at})
      |> then(&if(status in @terminal, do: Map.put(&1, "completedAt", at), else: &1))

    HalC2.Streams.transact(sub.child, :thread, fn state ->
      # An item can become a message after it was created as something else (a block
      # Claude reported under another's id), so the message is created when missing.
      message =
        cond do
          message_id == nil ->
            nil

          StreamState.fetch(state, "message", message_id) ->
            Orchestration.upsert(
              state,
              "message",
              message_id,
              &Map.merge(&1, %{"text" => fields["text"], "updatedAt" => at})
            )

          true ->
            Orchestration.create(
              "message",
              message_id,
              Entities.message(ids, message_id, "assistant", fields["text"] || "", false, at, %{
                "createdBy" => "agent",
                "creationSource" => "provider"
              })
            )
        end

      changes =
        if StreamState.fetch(state, "turn-item", item_id) do
          [Orchestration.upsert(state, "turn-item", item_id, &Map.merge(&1, put)), message]
        else
          [
            message,
            Orchestration.create(
              "turn-item",
              item_id,
              Entities.turn_item(
                ids,
                item_id,
                type,
                Orchestration.next_ordinal(state),
                status,
                at,
                fields
              )
              |> Map.put("nativeItemRef", Entities.provider_ref(native, sub.driver))
            )
          ]
        end

      {Enum.filter(changes, &is_tuple/1), :ok}
    end)

    if message_id, do: Map.put(sub, :said, fields["text"]), else: sub
  end

  @doc "What the subagent said so far, or nil."
  def said(sub), do: nilify(Map.get(sub, :said) || sub.text)

  @doc """
  Settles the subagent as `status` with its `result` (the answer it streamed when the
  provider reports none). With `summary: true` the result only sums up its work (a
  background task's end), so it is the answer only when the subagent said nothing.
  """
  def finish(sub, status, result, opts \\ []) do
    status = if status in @terminal, do: status, else: "completed"
    said = Map.get(sub, :said)
    result = if result in [nil, ""], do: nilify(said || sub.text), else: result

    sub =
      cond do
        # What the subagent said (`item/5`) is in its thread, the latest its answer,
        # which the provider's result repeats with more around it (Claude adds the
        # agent's id and usage); a result that does not repeat it follows as its answer.
        # A summary that only repeats the end of what was said (a message per message
        # id keeps all of it in one) is already in the thread.
        said != nil and result != nil and not Keyword.get(opts, :summary, false) and
          not String.contains?(result, String.trim(said)) and
            not String.contains?(said, String.trim(result)) ->
          item(sub, "#{sub.native}:message:result", "assistant_message", "completed", %{
            "text" => result
          })

        said == nil and sub.text == "" and result != nil ->
          append(sub, result)

        true ->
          sub
      end

    at = Entities.now()
    done = &Map.merge(&1, %{"status" => status, "completedAt" => at})
    settle_child(sub, status, at)

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

  @doc """
  Ends the still-running work in the child threads of `thread_id`'s provider
  subagents as `status`, from the thread's record alone: for an end no runtime
  reports (the thread was deleted), where no handle survives to `finish/3`.
  """
  def settle_children(thread_id, status) do
    at = Entities.now()

    for subagent <- StreamState.list(stream(thread_id), "subagent"),
        subagent["origin"] == "provider_native",
        is_binary(subagent["childThreadId"]) do
      settle_child(%{child: subagent["childThreadId"]}, status, at)
    end

    :ok
  end

  @doc """
  Ends the still-running work in the child threads of the provider subagents of
  `thread_id`'s run `run_id`, each as its subagent ended or as `status`: for a run
  ended from the thread's record (`TurnWriter.abandon/5`), whose runtime's own end of
  them the store refused or that crashed before it. With `ended`, the `{kind, id}`s
  that runtime ended, the subagents it ended are settled whichever run they are of
  (one it resumed), and the run's it keeps running are left to it, unless `keep?` is
  false (the runtime went, and its app-server with them). A child thread the store
  refuses raises.
  """
  def settle_run_children(thread_id, run_id, status, at, ended \\ nil, keep? \\ true) do
    for subagent <- StreamState.list(stream(thread_id), "subagent"),
        subagent["origin"] == "provider_native" and is_binary(subagent["childThreadId"]),
        settles?(subagent, run_id, ended, keep?) do
      ended = if subagent["status"] in @terminal, do: subagent["status"], else: status
      settle_child(%{child: subagent["childThreadId"]}, ended, at)
    end

    :ok
  end

  defp settles?(subagent, run_id, nil, _keep?), do: subagent["runId"] == run_id

  defp settles?(%{"id" => id} = subagent, run_id, ended, keep?),
    do:
      {"subagent", id} in ended or
        (subagent["runId"] == run_id and (not keep? or subagent["status"] in @terminal))

  # Work still open in the child thread (a tool call, the progress) ends with it.
  defp settle_child(sub, status, at) do
    HalC2.Streams.transact(sub.child, :thread, fn state ->
      {for item <- StreamState.list(state, "turn-item"),
           item["status"] == "running" do
         Orchestration.upsert(state, "turn-item", item["id"], fn item ->
           item
           |> Map.merge(%{"status" => status, "completedAt" => at, "updatedAt" => at})
           |> then(
             &if(Map.has_key?(&1, "streaming"), do: Map.put(&1, "streaming", false), else: &1)
           )
         end)
       end
       |> Enum.filter(&is_tuple/1), :ok}
    end)
  end

  defp child_ids(sub),
    do: %{thread: sub.child, run: nil, root_node: sub.root, provider_thread: nil}

  # The child's message and its turn item (`makeSubagentConversationArtifacts`), after
  # whatever the child thread already shows.
  defp conversation(state, sub, role, text, at) do
    native = "#{sub.native}:#{if role == :user, do: "prompt", else: "message:result"}"
    message_id = "message:#{sub.driver}:#{native}"
    item_id = "turn-item:#{sub.driver}:#{native}"
    ids = child_ids(sub)
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
        max(
          Orchestration.next_ordinal(state),
          Map.get(sub, :ordinal, 100) + if(role == :user, do: 0, else: 1)
        ),
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

  # A subagent on its own model keeps the parent's instance but not its options:
  # the parent's reasoning effort belongs to the parent's model.
  defp subagent_selection(parent, nil), do: parent

  defp subagent_selection(parent, model) do
    parent = parent || %{}

    if parent["model"] in [nil, model],
      do: Map.put(parent, "model", model),
      else: parent |> Map.put("model", model) |> Map.delete("options")
  end

  # The child's title (upstream `subagentThreadTitle`): its given title, else its
  # prompt, cut to 72 characters; with neither, it is named after its parent. The
  # cut counts UTF-16 units as upstream's did, and never falls through a character
  # (an emoji's surrogate pair), which clients would show as a replacement glyph.
  defp title(parent_title, given, prompt, ordinal) do
    case trimmed(given) || trimmed(prompt) do
      nil -> "#{parent_title} subagent #{ordinal}"
      detail -> cut(detail, 72, 69)
    end
  end

  defp cut(text, limit, keep) do
    if utf16_length(text) > limit, do: grapheme_prefix(text, keep) <> "...", else: text
  end

  # The longest prefix of `text` within `budget` UTF-16 units that ends on a
  # grapheme boundary, so the cut never falls through a surrogate pair, a
  # joined sequence, a flag, or a variation selector.
  defp grapheme_prefix(text, budget) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({0, []}, fn grapheme, {used, kept} ->
      length = utf16_length(grapheme)

      if used + length <= budget,
        do: {:cont, {used + length, [grapheme | kept]}},
        else: {:halt, {used, kept}}
    end)
    |> elem(1)
    |> Enum.reverse()
    |> Enum.join()
  end

  defp utf16_length(text),
    do: text |> :unicode.characters_to_binary(:utf8, :utf16) |> byte_size() |> div(2)

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp trimmed(_value), do: nil

  defp nilify(""), do: nil
  defp nilify(text), do: text

  defp stream(thread_id), do: HalC2.Streams.state(thread_id)
end
