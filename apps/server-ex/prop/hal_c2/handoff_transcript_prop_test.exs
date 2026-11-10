defmodule HalC2.HandoffTranscriptPropTest do
  @moduledoc """
  What `HalC2.Orchestration.Handoff.transcript/5` promises over any thread and budget:
  the transcript never outgrows its budget, even one smaller than its note, and a run
  still running reaches it only when asked (`running: true`, the PR description
  writer's). How a history too long for its budget gives way is
  `HalC2.HandoffHistoryPropTest`'s. A plain `forall`: the transcript is pure over the
  thread's state.
  """

  use ExUnit.Case, async: true
  use PropCheck

  alias HalC2.Orchestration.Handoff
  alias HalC2.StreamState

  @chars Enum.map(Enum.concat(?a..?z, ?A..?Z), &<<&1>>)

  # A budget smaller than the note itself: the transcript still stays inside it.
  property "a budget smaller than the note is still never exceeded",
    numtests: HalC2.Prop.numtests(200) do
    forall [turns, max_chars] <- [turns(), integer(1, 149)] do
      transcript = Handoff.transcript(state(turns), length(turns) + 1, 0, max_chars)
      transcript == nil or String.length(transcript) <= max_chars
    end
  end

  # A thread whose last run is still running: the running-turn reader sees every command
  # it finished and the plain transcript sees none of that run.
  property "a running turn reaches the transcript only when asked",
    numtests: HalC2.Prop.numtests(100) do
    forall [turns, max_chars] <- [turns(), budget()] do
      ordinal = length(turns) + 1
      base = state(turns)

      entities = [
        {"run", %{"id" => "run-#{ordinal}", "ordinal" => ordinal, "status" => "running"}},
        {"turn-item",
         %{
           "id" => "item-running",
           "runId" => "run-#{ordinal}",
           "type" => "command_execution",
           "input" => "check-running",
           "status" => "completed",
           "exitCode" => 0,
           "startedAt" => "2026-10-02T10:00:00Z"
         }}
      ]

      state =
        entities
        |> Enum.with_index(1000)
        |> Enum.reduce(base, fn {{kind, entity}, seq}, state ->
          StreamState.apply_event(state, %{
            seq: seq,
            kind: kind,
            entity: entity["id"],
            patch: %{"s" => entity}
          })
        end)

      plain = Handoff.transcript(state, 1_000_000, 0, max_chars)
      with_running = Handoff.transcript(state, 1_000_000, 0, max_chars, running: true)

      # The running command is the newest step, so a fitted transcript keeps it or says
      # it gave way (nil: less room than the note); a plain one never mentions it.
      (plain == nil or not String.contains?(plain, "check-running")) and
        (with_running == nil or
           (String.length(with_running) <= max_chars and
              (String.contains?(with_running, "check-running") or
                 with_running =~ ~r/left out|condensed|cut/i)))
    end
  end

  # One to eight runs, each a request, sometimes a command, and usually an answer.
  defp turns do
    resize(8, non_empty(list({message_length(), oneof([nil, message_length()]), boolean()})))
  end

  defp message_length do
    frequency([{3, integer(1, 60)}, {3, integer(60, 3_000)}, {2, integer(3_000, 12_000)}])
  end

  defp budget, do: frequency([{1, integer(150, 400)}, {3, integer(400, 16_000)}])

  # The entries in order, as `{index, role, text}`. Each message
  # repeats a character of its own, so a cut end still says whose it is.
  defp entries(turns) do
    turns
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {{request, answer, command}, ordinal} ->
      [
        {:user, request},
        command && {:command, ordinal},
        answer && {:assistant, answer}
      ]
      |> Enum.filter(& &1)
    end)
    |> Enum.with_index()
    |> Enum.map(fn
      {{:user, n}, i} ->
        {i, :user, "User: " <> String.duplicate(Enum.at(@chars, i), n)}

      {{:assistant, n}, i} ->
        {i, :assistant, "Assistant: " <> String.duplicate(Enum.at(@chars, i), n)}

      {{:command, ordinal}, i} ->
        {i, :command, "Command: c#{ordinal}\nExit code: 0"}
    end)
  end

  defp state(turns) do
    entries = entries(turns)

    turns
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {_turn, ordinal} ->
      [{"run", %{"id" => "run-#{ordinal}", "ordinal" => ordinal, "status" => "completed"}}]
    end)
    |> Kernel.++(Enum.map(entries, &row(&1, entries)))
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

  # An entry's row, in its run (counted by the requests before it) at a time that
  # keeps the order.
  defp row({i, role, text}, entries) do
    ordinal = Enum.count(entries, fn {j, r, _} -> j <= i and r == :user end)
    at = "2026-10-01T10:00:#{String.pad_leading("#{i}", 2, "0")}Z"

    case role do
      :command ->
        {"turn-item",
         %{
           "id" => "item-#{i}",
           "runId" => "run-#{ordinal}",
           "type" => "command_execution",
           "input" => "c#{ordinal}",
           "status" => "completed",
           "exitCode" => 0,
           "startedAt" => at
         }}

      _ ->
        [_label, body] = String.split(text, ": ", parts: 2)

        {"message",
         %{
           "id" => "message-#{i}",
           "runId" => "run-#{ordinal}",
           "role" => Atom.to_string(role),
           "text" => body,
           "createdAt" => at
         }}
    end
  end
end
