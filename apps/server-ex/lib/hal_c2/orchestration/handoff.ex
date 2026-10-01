defmodule HalC2.Orchestration.Handoff do
  @moduledoc """
  Carries a conversation into a provider thread that has not seen it.

  A fork's first run continues the source provider's own thread when the fork
  runs on the same provider (`fork`). Otherwise, and whenever a run starts a
  provider thread while the thread already has history (a switch to another
  provider, or an agent session lost to a rewind), the provider gets a
  transcript of that history ahead of the message. A provider thread that the
  thread comes back to gets only the runs it missed. Work merged back from a fork
  arrives the same way, as a transcript prepared when it was merged.

  A transcript is what was said and each command the agent ran with how it ended,
  which is what tells the next agent what has been tried and verified. Reasoning,
  other tool calls and attachments stay behind. One too long to hand over whole
  keeps the newest request and answer, then the original request, then whatever
  else fits from the newest back; anything left out is left out whole and stays
  readable through `hal_c2_thread_read`.

  A thread migrated from the version 1 orchestrator (`HalC2.Import.V1Thread`) keeps
  its messages outside any run, so no transcript covers them. Until one of its runs
  completes, a run that starts a provider thread gets that conversation as imported
  history instead, the newest of it that fits in 32,000 characters.

  A thread that moved to another machine (`HalC2.ThreadMove`) continues the agent's
  carried session, keeping a transcript as its `fallback` should the copy not
  open; its first run there also tells the agent where the project now lives.
  """

  alias HalC2.Orchestration
  alias HalC2.StreamState

  @native_forks ~w(codex claudeAgent pi opencode)
  @finished ~w(completed interrupted failed)
  # Keeps a transcript well inside any provider's context.
  @max_chars 60_000
  @omitted "[earlier messages omitted]"
  # The end of a command's output is where it says how it went.
  @max_output_chars 2_000
  @legacy_max_chars 32_000
  @legacy_header "Imported conversation history from the previous HAL-C2 orchestrator. Use it as context; do not repeat it unless the user asks."

  @doc """
  How run `ordinal` starts in `provider_thread` (nil when the run creates it):
  `%{fork: %{thread: native_id, turn: native_turn_id} | nil, context: text | nil,
  changes: [...]}`, where `changes` settle the transfers the run consumes. A Pi or
  OpenCode fork also names the entry to cut the copy `before` (nil keeps all of it). A carried
  session's fork has `carried: true` and the `fallback` context for a new session.
  """
  def plan(state, provider_thread, driver, run_id, ordinal, at) do
    transfers =
      state
      |> StreamState.list("context-transfer")
      |> Enum.filter(&(&1["status"] == "pending"))

    {fork, fork_context, fork_changes} =
      case Enum.find(transfers, &(&1["type"] == "fork")) do
        nil -> {nil, nil, []}
        transfer -> resolve_fork(state, transfer, driver, run_id, ordinal, at)
      end

    fresh =
      provider_thread == nil or get_in(provider_thread, ["nativeThreadRef", "nativeId"]) == nil

    {moved, moved_changes} = moved(state)

    {fork, fork_changes} =
      case carried(provider_thread, driver, fresh) do
        nil when fork == nil ->
          {nil, fork_changes}

        nil ->
          {fork, fork_changes}

        carried ->
          fallback = wrap(transcript(state, ordinal), "", moved, nil)

          {Map.put(carried, :fallback, fallback),
           fork_changes ++ [consumed(state, provider_thread)]}
      end

    {history, delta_changes} =
      cond do
        fork != nil -> {nil, []}
        fork_context != nil -> {fork_context, []}
        fresh -> {transcript(state, ordinal), []}
        true -> delta(state, provider_thread, run_id, ordinal, at)
      end

    {merged, merge_changes} = merge_backs(state, transfers, driver, run_id, at)

    {legacy, legacy_changes} =
      if fork == nil and fresh, do: legacy_import(state, driver, run_id, at), else: {nil, []}

    %{
      fork: fork,
      context: wrap(history, merged, moved, legacy),
      changes:
        Enum.reject(
          fork_changes ++ delta_changes ++ merge_changes ++ moved_changes ++ legacy_changes,
          &is_nil/1
        )
    }
  end

  # The first run after a move to a checkout at another path is told where the
  # project now lives (the thread's `arrived`, which the run consumes).
  defp moved(state) do
    thread = state |> StreamState.get("thread") |> Map.values() |> List.first()

    case thread do
      %{"arrived" => %{"from" => from, "to" => to} = arrived} ->
        machine = if arrived["machine"], do: " on #{arrived["machine"]}", else: ""

        {"This thread moved to another machine: the project that was at #{from}#{machine} is now at #{to}. Paths from earlier in the conversation refer to the old location.",
         [Orchestration.upsert(state, "thread", thread["id"], &Map.delete(&1, "arrived"))]}

      _ ->
        {nil, []}
    end
  end

  # A session carried from another machine (`HalC2.PortableSessions`): the run
  # branches a new session from the copy. Claude and Pi find the copy by its path,
  # Codex and provider plugins by the id it was placed under.
  defp carried(%{"carriedSession" => %{"driver" => driver} = session}, driver, true) do
    thread = if driver in ~w(claudeAgent pi), do: session["path"], else: session["nativeId"]
    %{thread: thread, turn: nil, path: session["path"], carried: true, from: session["from"]}
  end

  defp carried(_provider_thread, _driver, _fresh), do: nil

  defp consumed(state, provider_thread),
    do:
      Orchestration.upsert(
        state,
        "provider-thread",
        provider_thread["id"],
        &Map.delete(&1, "carriedSession")
      )

  # A provider thread the thread comes back to (the user switched to another agent
  # and back) gets only the turns other provider threads ran since it last ran
  # (`delta_since_target_last_seen`).
  defp delta(state, provider_thread, run_id, ordinal, at) do
    own = provider_thread["id"]
    runs = StreamState.list(state, "run")
    seen = provider_thread["lastRunOrdinal"] || last_own_run(runs, own, ordinal)

    unseen =
      runs
      |> Enum.filter(
        &(&1["ordinal"] > seen and &1["ordinal"] < ordinal and &1["status"] in @finished and
            &1["providerThreadId"] not in [nil, own])
      )

    case Enum.min_max_by(unseen, & &1["ordinal"], fn -> nil end) do
      nil ->
        {nil, []}

      {first, last} ->
        text = transcript(state, last["ordinal"] + 1, first["ordinal"] - 1)
        id = "context-handoff:#{run_id}"

        handoff =
          Orchestration.create("context-handoff", id, %{
            "id" => id,
            "transferId" => nil,
            "threadId" => provider_thread["appThreadId"],
            "targetRunId" => run_id,
            "fromProviderThreadIds" =>
              unseen |> Enum.map(& &1["providerThreadId"]) |> Enum.uniq(),
            "toProviderThreadId" => own,
            "coveredRunOrdinals" => %{"from" => first["ordinal"], "to" => last["ordinal"]},
            "strategy" => "delta_since_target_last_seen",
            "status" => "ready",
            "summaryMessageId" => nil,
            "summaryText" => text || "",
            "createdByProviderInstanceId" => nil,
            "createdAt" => at,
            "updatedAt" => at
          })

        {text, [handoff]}
    end
  end

  # Before provider threads recorded `lastRunOrdinal`: the latest run it ran itself.
  defp last_own_run(runs, own, ordinal) do
    runs
    |> Enum.filter(&(&1["providerThreadId"] == own and &1["ordinal"] < ordinal))
    |> Enum.map(& &1["ordinal"])
    |> Enum.max(fn -> 0 end)
  end

  # Same provider: the run forks the source's native thread at the fork point.
  defp resolve_fork(state, transfer, driver, run_id, ordinal, at) do
    point = transfer["sourcePoint"]
    thread_ref = point["providerThreadRef"]
    turn_ref = point["providerTurnRef"]

    # An ACP agent's driver is its instance's id.
    kind = if driver in @native_forks, do: driver, else: HalC2.Acp.driver(driver)

    if kind in @native_forks and thread_ref["driver"] == driver and turn_ref != nil do
      settled =
        settle(state, transfer, run_id, at, %{
          "status" => "consumed",
          "resolution" => %{"strategy" => "native_fork", "providerThreadRef" => thread_ref}
        })

      fork = %{thread: thread_ref["nativeId"], turn: turn_ref["nativeId"]}

      fork =
        if kind in ~w(pi opencode),
          do: Map.put(fork, :before, next_turn(transfer, turn_ref)),
          else: fork

      {fork, nil, [settled]}
    else
      history = transcript(state, ordinal)
      handoff_id = "context-handoff:#{transfer["id"]}"

      settled =
        settle(state, transfer, run_id, at, %{
          "status" => "consumed",
          "resolution" => %{"strategy" => "portable_context", "contextHandoffId" => handoff_id}
        })

      handoff =
        handoff(
          handoff_id,
          transfer,
          run_id,
          driver,
          {1, ordinal - 1},
          "full_thread_summary",
          history,
          at
        )

      {nil, history, [settled, handoff]}
    end
  end

  # Pi and OpenCode fork a session before an entry: the user message of the source's
  # turn after the fork point, or nothing when the fork point is the source's latest turn.
  defp next_turn(transfer, turn_ref) do
    turns =
      HalC2.Streams.ensure(transfer["sourceThreadId"])
      |> HalC2.Streams.Server.state()
      |> StreamState.list("provider-turn")

    case Enum.find(turns, &(get_in(&1, ["nativeTurnRef", "nativeId"]) == turn_ref["nativeId"])) do
      nil ->
        nil

      point ->
        turns
        |> Enum.filter(
          &(&1["providerThreadId"] == point["providerThreadId"] and
              &1["ordinal"] > point["ordinal"] and &1["nativeTurnRef"] != nil)
        )
        |> Enum.min_by(& &1["ordinal"], fn -> nil end)
        |> then(&(&1 && get_in(&1, ["nativeTurnRef", "nativeId"])))
    end
  end

  # Each merge-back brings the fork's work since the fork point, read from the fork.
  defp merge_backs(state, transfers, driver, run_id, at) do
    transfers
    |> Enum.filter(&(&1["type"] == "merge_back"))
    |> Enum.reduce({[], []}, fn transfer, {texts, changes} ->
      fork_id = transfer["sourceThreadId"]
      fork = HalC2.Streams.Server.state(HalC2.Streams.ensure(fork_id))
      runs = StreamState.get(fork, "run")
      to = get_in(runs, [transfer["sourcePoint"]["runId"], "ordinal"]) || 0
      from = get_in(runs, [get_in(transfer, ["basePoint", "runId"]), "ordinal"]) || 0
      text = transcript(fork, to + 1, from)
      title = get_in(StreamState.get(fork, "thread"), [fork_id, "title"]) || fork_id
      handoff_id = "context-handoff:#{transfer["id"]}"

      settled =
        settle(state, transfer, run_id, at, %{
          "status" => "consumed",
          "resolution" => %{"strategy" => "portable_context", "contextHandoffId" => handoff_id}
        })

      handoff =
        handoff(
          handoff_id,
          transfer,
          run_id,
          driver,
          {from + 1, to},
          "fork_delta_summary",
          text,
          at
        )

      {texts ++ List.wrap(text && "From the fork \"#{title}\":\n\n#{text}"),
       changes ++ [settled, handoff]}
    end)
    |> then(fn {texts, changes} -> {Enum.join(texts, "\n\n"), changes} end)
  end

  defp handoff(id, transfer, run_id, driver, {from, to}, strategy, text, at) do
    Orchestration.create("context-handoff", id, %{
      "id" => id,
      "transferId" => transfer["id"],
      "threadId" => transfer["targetThreadId"],
      "targetRunId" => run_id,
      "fromProviderThreadIds" => [],
      "toProviderThreadId" => "provider-thread:#{driver}:#{transfer["targetThreadId"]}",
      "coveredRunOrdinals" => %{"from" => max(from, 1), "to" => max(to, max(from, 1))},
      "strategy" => strategy,
      "status" => "ready",
      "summaryMessageId" => nil,
      "summaryText" => text || "",
      "createdByProviderInstanceId" => nil,
      "createdAt" => at,
      "updatedAt" => at
    })
  end

  defp settle(state, transfer, run_id, at, fields) do
    Orchestration.upsert(state, "context-transfer", transfer["id"], fn entity ->
      Map.merge(
        entity,
        Map.merge(fields, %{"targetRunId" => run_id, "updatedAt" => at, "consumedAt" => at})
      )
    end)
  end

  @doc """
  The conversation of the runs before `ordinal` that finished, as `User:`,
  `Assistant:` and `Command:` entries in the order they happened, selected to fit
  (see the module doc); nil when there is none.
  """
  def transcript(state, ordinal, after_ordinal \\ 0) do
    runs =
      state
      |> StreamState.list("run")
      |> Enum.filter(
        &(&1["ordinal"] < ordinal and &1["ordinal"] > after_ordinal and &1["status"] in @finished)
      )
      |> Enum.sort_by(& &1["ordinal"])

    messages =
      for message <- StreamState.list(state, "message"),
          text = String.trim(message["text"] || ""),
          text != "" do
        role = if message["role"] == "user", do: :user, else: :assistant
        label = if role == :user, do: "User", else: "Assistant"
        {message["runId"], message["createdAt"] || "", role, "#{label}: #{text}"}
      end

    commands =
      for %{"type" => "command_execution", "input" => input} = item <-
            StreamState.list(state, "turn-item"),
          is_binary(input) and item["status"] in ~w(completed failed),
          do: {item["runId"], item["startedAt"] || "", :command, command(item)}

    # A run's user message comes before what the agent did, whatever the timestamps,
    # and a command before the answer that reports it.
    order = %{user: 0, command: 1, assistant: 2}

    entries =
      (messages ++ commands)
      |> Enum.sort_by(fn {_run, at, role, _text} -> {at, order[role]} end)
      |> Enum.group_by(&elem(&1, 0), fn {_run, _at, role, text} -> {role, text} end)

    case Enum.flat_map(runs, &Map.get(entries, &1["id"], [])) do
      [] -> nil
      entries -> fit(entries)
    end
  end

  defp command(item) do
    output = String.trim(item["output"] || "")

    output =
      if String.length(output) > @max_output_chars,
        do: "... " <> String.slice(output, -@max_output_chars, @max_output_chars),
        else: output

    [
      "Command: #{item["input"]}",
      is_integer(item["exitCode"]) && "Exit code: #{item["exitCode"]}",
      output != "" && output
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
  end

  # Every entry when they fit; otherwise the selection of the module doc, in the
  # order the entries happened, under a note that some were left out.
  defp fit(entries) do
    texts = Enum.map(entries, &elem(&1, 1))
    whole = Enum.join(texts, "\n\n")

    if String.length(whole) <= @max_chars do
      whole
    else
      indexed = Enum.with_index(entries)
      newest = Enum.reverse(indexed)
      role = fn role -> &match?({{^role, _}, _}, &1) end

      first =
        [Enum.find(newest, role.(:user)), Enum.find(newest, role.(:assistant))] ++
          [Enum.find(indexed, role.(:user))]

      {kept, _left} =
        (Enum.reject(first, &is_nil/1) ++ newest)
        |> Enum.reduce({MapSet.new(), @max_chars}, fn {{_role, text}, index}, {kept, left} ->
          cost = String.length(text) + 2

          if MapSet.member?(kept, index) or cost > left,
            do: {kept, left},
            else: {MapSet.put(kept, index), left - cost}
        end)

      selected = for {{_role, text}, index} <- indexed, MapSet.member?(kept, index), do: text
      Enum.join([@omitted | selected], "\n\n")
    end
  end

  defp wrap(nil, "", nil, nil), do: nil

  defp wrap(history, merged, moved, legacy) do
    [
      moved && "<moved>\n#{moved}\n</moved>",
      legacy && "<imported_history>\n#{legacy}\n</imported_history>",
      history &&
        "<conversation_history>\nThis conversation started in another agent session. Continue from it.\n\n#{history}\n</conversation_history>",
      merged != "" &&
        "<merged_work>\nWork done in a fork of this thread, merged back here:\n\n#{merged}\n</merged_work>"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n\n")
  end

  # The Node server's `shouldPrepareLegacyImportHandoff`: a version 1 thread with
  # migrated messages and no completed run. A provider thread that already exists has
  # been told, and an imported agent session resumes the agent's own history.
  defp legacy_import(state, driver, run_id, at) do
    thread = state |> StreamState.get("thread") |> Map.values() |> List.first()
    items = state |> StreamState.list("turn-item") |> Enum.filter(&(&1["runId"] == nil))
    completed? = state |> StreamState.list("run") |> Enum.any?(&(&1["status"] == "completed"))

    if thread["historyOrigin"] == "v1_import" and items != [] and not completed? do
      text = items |> Enum.sort_by(& &1["ordinal"]) |> legacy_summary()

      handoff =
        handoff(
          "context-handoff:legacy:#{run_id}",
          %{"targetThreadId" => thread["id"]},
          run_id,
          driver,
          {1, 1},
          "manual_context",
          text,
          at
        )

      {text, [handoff]}
    else
      {nil, []}
    end
  end

  @doc """
  The imported history of a version 1 thread's turn items (`makeLegacyImportSummary`):
  a header, then the newest messages that fit in 32,000 characters. The newest one
  that does not fit whole keeps its end, cut at a word and marked `... `.
  """
  def legacy_summary(items) do
    budget = @legacy_max_chars - String.length(@legacy_header) - 2

    {sections, _} =
      items
      |> Enum.reverse()
      |> Enum.reduce_while({[], budget}, fn
        _item, {sections, left} when left <= 0 ->
          {:halt, {sections, left}}

        item, {sections, left} ->
          case legacy_section(item, left) do
            nil -> {:cont, {sections, left}}
            section -> {:cont, {[section | sections], left - String.length(section) - 2}}
          end
      end)

    Enum.join([@legacy_header | sections], "\n\n")
  end

  # A message in at most `left` characters, or nil when none of it fits.
  defp legacy_section(%{"type" => type} = item, left)
       when type in ~w(user_message assistant_message) do
    label = if type == "user_message", do: "User:\n", else: "Assistant:\n"
    whole = label <> (item["text"] || "")
    marked = label <> "... "

    if String.length(whole) <= left do
      whole
    else
      case word_tail(item["text"], left - String.length(marked)) do
        "" -> nil
        tail -> marked <> tail
      end
    end
  end

  defp legacy_section(_item, _left), do: nil

  # The last `chars` characters of `text`, without a word the cut splits.
  defp word_tail(_text, chars) when chars <= 0, do: ""

  defp word_tail(text, chars) do
    {before, tail} = String.split_at(text, -chars)

    tail =
      if before == "" or before =~ ~r/\s\z/u,
        do: tail,
        else: String.replace(tail, ~r/\A\S+(?=\s)/u, "")

    String.trim_leading(tail)
  end

  @doc "The message a provider receives: the handed-off context, then the user's text."
  def prompt(nil, text), do: text
  def prompt(context, text), do: context <> "\n\n" <> text
end
