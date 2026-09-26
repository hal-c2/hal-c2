defmodule T3.Orchestration.Handoff do
  @moduledoc """
  Carries a conversation into a provider thread that has not seen it.

  A fork's first run continues the source provider's own thread when the fork
  runs on the same provider (`fork`). Otherwise, and whenever a run starts a
  provider thread while the thread already has history (a switch to another
  provider, or an agent session lost to a rewind), the provider gets a
  transcript of that history ahead of the message. A provider thread that the
  thread comes back to gets only the runs it missed. Work merged back from a fork
  arrives the same way, as a transcript prepared when it was merged.
  """

  alias T3.Orchestration
  alias T3.StreamState

  @native_forks ~w(codex claudeAgent pi)
  @finished ~w(completed interrupted failed)
  # Keeps a transcript well inside any provider's context; the newest part wins.
  @max_chars 60_000

  @doc """
  How run `ordinal` starts in `provider_thread` (nil when the run creates it):
  `%{fork: %{thread: native_id, turn: native_turn_id} | nil, context: text | nil,
  changes: [...]}`, where `changes` settle the transfers the run consumes. A Pi
  fork also names the entry to cut the copy `before` (nil keeps all of it).
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

    {history, delta_changes} =
      cond do
        fork != nil -> {nil, []}
        fork_context != nil -> {fork_context, []}
        fresh -> {transcript(state, ordinal), []}
        true -> delta(state, provider_thread, run_id, ordinal, at)
      end

    {merged, merge_changes} = merge_backs(state, transfers, driver, run_id, at)

    %{
      fork: fork,
      context: wrap(history, merged),
      changes: Enum.reject(fork_changes ++ delta_changes ++ merge_changes, &is_nil/1)
    }
  end

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

    if driver in @native_forks and thread_ref["driver"] == driver and turn_ref != nil do
      settled =
        settle(state, transfer, run_id, at, %{
          "status" => "consumed",
          "resolution" => %{"strategy" => "native_fork", "providerThreadRef" => thread_ref}
        })

      fork = %{thread: thread_ref["nativeId"], turn: turn_ref["nativeId"]}

      fork =
        if driver == "pi", do: Map.put(fork, :before, next_turn(transfer, turn_ref)), else: fork

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

  # Pi forks a session before an entry: the user message of the source's turn after
  # the fork point, or nothing when the fork point is the source's latest turn.
  defp next_turn(transfer, turn_ref) do
    turns =
      T3.Streams.ensure(transfer["sourceThreadId"])
      |> T3.Streams.Server.state()
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
      fork = T3.Streams.Server.state(T3.Streams.ensure(fork_id))
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
  The conversation of the runs before `ordinal` that finished, as `User:` and
  `Assistant:` turns, trimmed from the start to fit; nil when there is none.
  """
  def transcript(state, ordinal, after_ordinal \\ 0) do
    runs =
      state
      |> StreamState.list("run")
      |> Enum.filter(
        &(&1["ordinal"] < ordinal and &1["ordinal"] > after_ordinal and &1["status"] in @finished)
      )
      |> Enum.sort_by(& &1["ordinal"])

    # A run's user message comes before its replies, whatever their ids.
    messages =
      state
      |> StreamState.list("message")
      |> Enum.sort_by(&{&1["createdAt"] || "", if(&1["role"] == "user", do: 0, else: 1)})
      |> Enum.group_by(& &1["runId"])

    lines =
      for run <- runs,
          message <- Map.get(messages, run["id"], []),
          text = String.trim(message["text"] || ""),
          text != "" do
        "#{if message["role"] == "user", do: "User", else: "Assistant"}: #{text}"
      end

    case lines do
      [] -> nil
      lines -> lines |> Enum.join("\n\n") |> tail()
    end
  end

  defp tail(text) do
    if String.length(text) > @max_chars,
      do: "[earlier messages omitted]\n\n" <> String.slice(text, -@max_chars, @max_chars),
      else: text
  end

  defp wrap(nil, ""), do: nil

  defp wrap(history, merged) do
    [
      history &&
        "<conversation_history>\nThis conversation started in another agent session. Continue from it.\n\n#{history}\n</conversation_history>",
      merged != "" &&
        "<merged_work>\nWork done in a fork of this thread, merged back here:\n\n#{merged}\n</merged_work>"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n\n")
  end

  @doc "The message a provider receives: the handed-off context, then the user's text."
  def prompt(nil, text), do: text
  def prompt(context, text), do: context <> "\n\n" <> text
end
