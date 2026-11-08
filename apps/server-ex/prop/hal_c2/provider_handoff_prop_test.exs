defmodule HalC2.ProviderHandoffPropTest do
  @moduledoc """
  The law `HalC2.Orchestration.Handoff.room/3` promises, which the room check of
  `Handoff.plan/6` stands on (#1232, proof/models/provider_handoff.maude): it never
  takes a conversation to be emptier than it is.

  A thread's runs alternate between a provider thread and another one. The provider
  thread's conversation was replaced once (`nativeSinceRunOrdinal`): the runs before
  that are in an old conversation whose usage reports say nothing of the new one. Each
  run in the new conversation sends some tokens and gets an answer no bigger than the
  reserve, and its usage report reaches the MC or is lost; a report that arrives late
  is in the stream the same as one on time. The conversation then holds what each of
  its runs sent and was answered, and `held` is never less than that. A run that ended
  before its turn began sent nothing, and takes nothing from the room. When the newest
  run's report is in, `held` is exactly that report, so the check refuses no handoff
  that fits; and what the message takes is its text, a fixed share per image, and for a
  file a token per 4 bytes up to a cap (the cap when its size is not known). Only the
  text is the message's own (`text`): what the attachments take is an estimate.
  Not every report names the window (Claude's count after compacting does not): the
  window is the one the provider thread's reports named, whichever conversation they
  came from, and the assumed one only when none did (`reported` says which).

  A plain `forall`: the room is pure over the thread's state.
  """

  use ExUnit.Case, async: true
  use PropCheck

  alias HalC2.Orchestration.Handoff
  alias HalC2.Orchestration.TurnWriter
  alias HalC2.StreamState

  @own "pthread-1"
  @other "pthread-2"
  @next %{text: "next", attachments: []}

  property "the room never takes a conversation to be emptier than it is",
    numtests: HalC2.Prop.numtests(300) do
    forall {window, old, current, since_set?, message} <-
             {integer(8_000, 300_000), list(old_run()), list(current_run()), boolean(), message()} do
      # Answers stay within the smallest reserve the room can use: the window's, or the
      # assumed window's when no report names one.
      answer_cap = reserve(min(window, 128_000))

      {state, provider_thread, occupancy, newest, named?} =
        thread(window, old, current, since_set?, answer_cap)

      room = Handoff.room(state, provider_thread, message)

      exact? =
        case newest do
          {:reported, used} -> room.held == used
          :unreported -> true
        end

      expected_text = div(String.length(message.text) + 3, 4)

      expected_message =
        expected_text + Enum.sum_by(message.attachments, &attachment_tokens/1)

      expected_window = if named?, do: window, else: 128_000

      (room.held >= occupancy and exact? and room.message == expected_message and
         room.text == expected_text and room.window == expected_window and
         room.reported == named?)
      |> when_fail(
        IO.puts(
          "held #{room.held} < occupancy #{occupancy}, or newest #{inspect(newest)}, " <>
            "or window not #{expected_window}; " <>
            "room #{inspect(room)}"
        )
      )
    end
  end

  # The law of the unconfirmed mark (#1233): a provider thread whose last handoff may
  # not have reached it is never resumed from where the MC took it to be. Runs go to
  # its conversation and another provider's, each completing, failing (its runtime
  # crashed or the prompt was lost) or being stopped; the provider thread's last run
  # is one whose confirmation never came, through which it was known to hold the
  # thread up to its run before. Whatever the next run's plan, it hands over every
  # run after that one; it starts a new conversation unless background work runs in
  # the old one, and then with the whole thread; it keeps no later point as the one
  # the conversation holds; and a late confirmation of any other run leaves the mark.
  # A marked run that ended before its turn began sent nothing: the conversation it
  # would have gone into goes on, handed what other providers did since the point the
  # mark kept (the run's own words never reached it, and are not sent again).
  property "a provider thread that may have lost its handoff is never resumed past it",
    numtests: HalC2.Prop.numtests(300) do
    forall {before, mark_status, others, background?, native?, started?} <-
             {list(marked_run()), oneof(["failed", "interrupted"]), list(other_run()), boolean(),
              boolean(), boolean()} do
      runs =
        Enum.map(before, fn {owner, status} -> {owner, status} end) ++
          [{"pt", mark_status}] ++ Enum.map(others, &{"po", &1})

      runs = Enum.with_index(runs, 1)
      {_, marked} = Enum.find(Enum.reverse(runs), fn {{owner, _}, _} -> owner == "pt" end)

      since =
        Enum.find_value(Enum.reverse(runs), 0, fn {{owner, _}, ordinal} ->
          owner == "pt" and ordinal < marked and ordinal
        end)

      next = length(runs) + 1
      state = marked_thread(runs, marked, since, background?, native?, started?)
      provider_thread = StreamState.get(state, "provider-thread")["pt"]
      ids = %{driver: "claudeAgent", run: "run-#{next}", thread: "t", provider_thread: "pt"}
      plan = Handoff.plan(state, provider_thread, ids, next, "2026-10-01T11:00:00Z", @next)

      context = plan.context || ""
      missed = requests(Handoff.transcript(state, next, since))
      whole = requests(Handoff.transcript(state, next))

      late_acks =
        for {_, ordinal} <- runs,
            ordinal != marked,
            change = TurnWriter.confirmed(state, %{ids | run: "run-#{ordinal}"}),
            do: {ordinal, change}

      handed = if started?, do: missed, else: missed -- ["req-#{marked}."]

      (plan.refusal == nil and Enum.all?(handed, &String.contains?(context, &1)) and
         if(started?,
           do: background? or plan.new_conversation,
           else: not (native? and plan.new_conversation)
         ) and
         (not plan.new_conversation or Enum.all?(whole, &String.contains?(context, &1))) and
         plan.unconfirmed_since <= since and late_acks == [])
      |> when_fail(
        IO.puts(
          "runs #{inspect(runs)}, marked run-#{marked} (started #{started?}) since #{since}: " <>
            "missed #{inspect(missed)}, " <>
            "plan #{inspect(Map.take(plan, [:new_conversation, :unconfirmed_since, :refusal]))}, " <>
            "context #{inspect(context)}, late acks #{inspect(late_acks)}"
        )
      )
    end
  end

  defp marked_run,
    do: {oneof(["pt", "po"]), oneof(["completed", "failed", "interrupted", "rolled_back"])}

  defp other_run, do: oneof(["completed", "failed", "interrupted", "rolled_back"])

  # Each run's request, and the answer of one that completed.
  defp marked_thread(runs, marked, since, background?, native?, started?) do
    entities =
      for {{owner, status}, ordinal} <- runs,
          entity <- [
            {"run",
             %{
               "id" => "run-#{ordinal}",
               "ordinal" => ordinal,
               "providerThreadId" => owner,
               "status" => status,
               "startedAt" => if(ordinal != marked or started?, do: "2026-10-01T10:00:00Z")
             }},
            message(ordinal, "user", "req-#{ordinal}.", 0),
            status == "completed" && message(ordinal, "assistant", "answer-#{ordinal}.", 1)
          ],
          entity,
          do: entity

    provider_thread =
      %{
        "id" => "pt",
        "lastRunOrdinal" => marked,
        "unconfirmedRunId" => "run-#{marked}",
        "unconfirmedSince" => since
      }
      |> then(
        &if(native?,
          do: Map.put(&1, "nativeThreadRef", %{"driver" => "claudeAgent", "nativeId" => "n"}),
          else: &1
        )
      )
      |> then(
        &if(background?,
          do:
            Map.put(&1, "pendingBackgroundTasks", [
              %{"taskId" => "task-1", "taskType" => "local_bash"}
            ]),
          else: &1
        )
      )

    apply_all([{"provider-thread", provider_thread} | entities])
  end

  defp message(ordinal, role, text, step),
    do:
      {"message",
       %{
         "id" => "#{role}-#{ordinal}",
         "runId" => "run-#{ordinal}",
         "role" => role,
         "text" => text,
         "createdAt" => "2026-10-01T10:#{String.pad_leading("#{ordinal}", 2, "0")}:0#{step}Z"
       }}

  defp requests(nil), do: []
  defp requests(transcript), do: Regex.scan(~r/req-\d+\./, transcript) |> List.flatten()

  defp apply_all(entities) do
    entities
    |> Enum.with_index(1)
    |> Enum.reduce(StreamState.new(), fn {{kind, entity}, seq}, state ->
      StreamState.apply_event(state, %{
        seq: seq,
        kind: kind,
        entity: entity["id"],
        patch: %{"s" => entity}
      })
    end)
  end

  # A run of the old conversation: what it sent, the usage it reported there, if any,
  # and whether the report named the window.
  defp old_run, do: {integer(0, 50_000), oneof([nil, integer(0, 300_000)]), boolean()}

  # A run of the new conversation's own provider thread, one of it that ended before its
  # turn began (it sent nothing), or one of the other provider thread.
  defp current_run do
    oneof([
      {:own, integer(0, 40_000), integer(0, 100), boolean(), boolean()},
      {:unsent, integer(0, 40_000), oneof(["failed", "interrupted"])},
      {:other, integer(0, 40_000)}
    ])
  end

  defp message do
    let {length, images, files} <-
          {integer(0, 400), integer(0, 3), list(oneof([nil, integer(0, 40_000)]))} do
      %{
        text: String.duplicate("x", length),
        attachments:
          List.duplicate(%{type: "image"}, images) ++
            Enum.map(files, &%{type: "file", size_bytes: &1})
      }
    end
  end

  defp attachment_tokens(%{type: "image"}), do: 8_192
  defp attachment_tokens(%{size_bytes: nil}), do: 4_096
  defp attachment_tokens(%{size_bytes: size}), do: min(4_096, div(size + 3, 4))

  defp reserve(window), do: max(div(window, 4), min(16_000, div(window, 2)))

  # The thread's stream, its provider thread, how full the new conversation truly is,
  # whether the newest of its runs reported, and whether any report named the window.
  defp thread(window, old, current, since_set?, answer_cap) do
    max_tokens = fn names? -> if names?, do: window end
    old_count = length(old)
    since = old_count + 1

    old_entities =
      old
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {{sent, used, names?}, ordinal} ->
        [run(ordinal, @own, sent)] ++
          if(used, do: [turn(ordinal, @own, used, max_tokens.(names?))], else: [])
      end)

    old_named? = Enum.any?(old, fn {_sent, used, names?} -> used != nil and names? end)

    {current_entities, occupancy, newest, _ordinal, named?} =
      Enum.reduce(current, {[], 0, :unreported, since, old_named?}, fn
        {:unsent, sent, status}, {entities, occupancy, newest, ordinal, named?} ->
          {entities ++ [run(ordinal, @own, sent, status, nil)], occupancy, newest, ordinal + 1,
           named?}

        {:other, sent}, {entities, occupancy, newest, ordinal, named?} ->
          # The other provider thread's report is of its own conversation and model.
          {entities ++ [run(ordinal, @other, sent), turn(ordinal, @other, 999_999, 1_000_000)],
           occupancy, newest, ordinal + 1, named?}

        {:own, sent, percent, reported?, names?},
        {entities, occupancy, _newest, ordinal, named?} ->
          occupancy = occupancy + sent + div(answer_cap * percent, 100)

          report =
            if reported?, do: [turn(ordinal, @own, occupancy, max_tokens.(names?))], else: []

          newest = if reported?, do: {:reported, occupancy}, else: :unreported

          {entities ++ [run(ordinal, @own, sent) | report], occupancy, newest, ordinal + 1,
           named? or (reported? and names?)}
      end)

    # A provider thread whose first conversation is its only one may not say where it
    # began.
    provider_thread =
      %{"id" => @own, "providerInstanceId" => "codex"}
      |> then(
        &if(old_count > 0 or since_set?,
          do: Map.put(&1, "nativeSinceRunOrdinal", since),
          else: &1
        )
      )

    entities = [{"provider-thread", provider_thread} | old_entities ++ current_entities]

    state =
      entities
      |> Enum.with_index(1)
      |> Enum.reduce(StreamState.new(), fn {{kind, entity}, seq}, state ->
        StreamState.apply_event(state, %{
          seq: seq,
          kind: kind,
          entity: entity["id"],
          patch: %{"s" => entity}
        })
      end)

    {state, provider_thread, occupancy, newest, named?}
  end

  defp run(
         ordinal,
         provider_thread,
         sent,
         status \\ "completed",
         started \\ "2026-10-01T10:00:00Z"
       ) do
    {"run",
     %{
       "id" => "run-#{ordinal}",
       "ordinal" => ordinal,
       "providerThreadId" => provider_thread,
       "sentTokens" => sent,
       "status" => status,
       "startedAt" => started
     }}
  end

  defp turn(ordinal, provider_thread, used, max_tokens) do
    {"provider-turn",
     %{
       "id" => "pturn-#{ordinal}",
       "ordinal" => ordinal,
       "providerThreadId" => provider_thread,
       "tokenUsage" => %{"usedTokens" => used, "maxTokens" => max_tokens}
     }}
  end
end
