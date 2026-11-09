defmodule HalC2.HandoffTranscriptPropTest do
  @moduledoc """
  The law `HalC2.Orchestration.Handoff.transcript/4` promises when it fits a
  conversation to a budget, for any message lengths and budget:

  - (a) the transcript is never longer than the budget;
  - (b) the first request is kept whole whenever it fits beside the note, unless
    the newest pair would fit whole without it but not beside it (then the newest
    history wins and it is an older entry);
  - (c) the newest request and the newest answer share what the first request
    leaves: each keeps at least its end when there is room for one, a cut one
    leaves none of that room unused, and when both are cut each has half;
  - (d) older entries fill what is left newest first, each whole or not at all;
  - the note's counts of entries kept, cut and left out are true.

  A plain `forall`: the transcript is pure over the thread's state.
  """

  use ExUnit.Case, async: true
  use PropCheck

  alias HalC2.Orchestration.Handoff
  alias HalC2.StreamState

  # Room `fit` keeps for its note, and the least a cut message costs: its label,
  # ": ... ", one character, and the "\n\n" before it.
  @note 120
  @min_cut %{user: String.length("User") + 9, assistant: String.length("Assistant") + 9}
  @chars Enum.map(Enum.concat(?a..?z, ?A..?Z), &<<&1>>)

  property "a fitted transcript keeps the budget, the first request and the newest pair",
    numtests: HalC2.Prop.numtests(300) do
    forall [turns, max_chars] <- [turns(), budget()] do
      entries = entries(turns)
      transcript = Handoff.transcript(state(turns), length(turns) + 1, 0, max_chars)
      laws = laws(entries, transcript, max_chars)

      laws
      |> Enum.all?(&elem(&1, 1))
      |> when_fail(
        IO.puts("""
        Lengths: #{inspect(turns)}  budget: #{max_chars}
        Broken: #{inspect(for {name, false} <- laws, do: name)}
        """)
      )
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

      # The running command is the newest entry, so a fitted transcript keeps it or
      # says it left it out; a plain one never mentions it.
      (plain == nil or not String.contains?(plain, "check-running")) and
        String.length(with_running) <= max_chars and
        (String.contains?(with_running, "check-running") or
           with_running =~ ~r/left out|omitted|kept/i)
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

  # The entries as `fit` sees them: `{index, role, text}`, in order. Each message
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

  defp laws(entries, transcript, max_chars) do
    whole = Enum.map_join(entries, "\n\n", &elem(&1, 2))

    if String.length(whole) <= max_chars do
      [{:whole_when_it_fits, transcript == whole}]
    else
      fitted(entries, transcript, max_chars)
    end
  end

  defp fitted(entries, transcript, max_chars) do
    [note | segments] = String.split(transcript, "\n\n")

    case match(segments, entries) do
      :mismatch -> [{:every_segment_is_an_entry, false}]
      kept -> fitted(entries, transcript, max_chars, note, kept)
    end
  end

  defp fitted(entries, transcript, max_chars, note, kept) do
    room = max_chars - @note
    cost = fn text -> String.length(text) + 2 end
    used = kept |> Map.values() |> Enum.map(&cost.(elem(&1, 1))) |> Enum.sum()

    newest = fn role -> entries |> Enum.reverse() |> Enum.find(&(elem(&1, 1) == role)) end
    pair = Enum.reject([newest.(:user), newest.(:assistant)], &is_nil/1)
    pair_ids = Enum.map(pair, &elem(&1, 0))
    first = Enum.find(entries, &(elem(&1, 1) == :user))
    pair_whole = pair |> Enum.map(fn {_i, _role, text} -> cost.(text) end) |> Enum.sum()

    first =
      if first && elem(first, 0) not in pair_ids &&
           (pair_whole > room or cost.(elem(first, 2)) + pair_whole <= room),
         do: first

    first_whole? = first != nil and match?({:whole, _}, kept[elem(first, 0)])
    share = room - if(first_whole?, do: cost.(elem(first, 2)), else: 0)

    pair_costs = for {i, _role, _text} <- pair, kept[i], do: cost.(elem(kept[i], 1))
    cut_pair = for {i, _role, _text} <- pair, match?({:cut, _}, kept[i]), do: i
    cuts = kept |> Map.values() |> Enum.count(&match?({:cut, _}, &1))

    note_counts =
      case Regex.run(
             ~r/^\[earlier messages omitted: (\d+) items kept(?: whole|, (\d+) of them cut to their end), (\d+) left out\]$/,
             note
           ) do
        [_, k, "", l] -> {String.to_integer(k), 0, String.to_integer(l)}
        [_, k, c, l] -> {String.to_integer(k), String.to_integer(c), String.to_integer(l)}
        _ -> nil
      end

    [
      {:a_within_budget, String.length(transcript) <= max_chars},
      {:b_first_request_whole, first == nil or cost.(elem(first, 2)) > room or first_whole?},
      {:c_newest_pair_present,
       share < length(pair) * Enum.max(Enum.map(pair, &@min_cut[elem(&1, 1)]), fn -> 0 end) or
         Enum.all?(pair_ids, &Map.has_key?(kept, &1))},
      {:c_cut_uses_the_share,
       cut_pair == [] or length(pair_costs) < length(pair) or Enum.sum(pair_costs) == share},
      {:c_both_cut_split_in_half,
       length(cut_pair) < 2 or Enum.all?(pair_costs, &(&1 >= div(share, 2)))},
      {:d_older_newest_first, older_newest_first?(entries, kept, room, pair_ids, first, cost)},
      {:only_the_newest_cut,
       Enum.all?(kept, fn {i, {how, _}} -> how == :whole or i in pair_ids end)},
      {:note_counts_true,
       note_counts == {map_size(kept), cuts, length(entries) - map_size(kept)}},
      {:within_budget_by_room, used <= room}
    ]
  end

  # Each left-out older entry did not fit in what was left once the first request,
  # the newest pair and the older entries newer than it were kept.
  defp older_newest_first?(entries, kept, room, pair_ids, first, cost) do
    ahead = Enum.reject([first && elem(first, 0) | pair_ids], &is_nil/1)
    taken = fn i -> if kept[i], do: cost.(elem(kept[i], 1)), else: 0 end
    fixed = ahead |> Enum.map(taken) |> Enum.sum()

    older = entries |> Enum.reject(&(elem(&1, 0) in ahead)) |> Enum.reverse()

    {ok, _left} =
      Enum.reduce(older, {true, room - fixed}, fn {i, _role, text}, {ok, left} ->
        if kept[i], do: {ok, left - cost.(text)}, else: {ok and cost.(text) > left, left}
      end)

    ok
  end

  # The kept entries by index, `{:whole | :cut, segment}`, matching the segments in
  # order; :mismatch when a segment is no entry or its cut end.
  defp match(segments, entries) do
    Enum.reduce_while(segments, {%{}, entries}, fn segment, {kept, rest} ->
      case Enum.drop_while(rest, &(how(segment, &1) == nil)) do
        [{i, _role, _text} = entry | rest] ->
          {:cont, {Map.put(kept, i, {how(segment, entry), segment}), rest}}

        [] ->
          {:halt, :mismatch}
      end
    end)
    |> case do
      :mismatch -> :mismatch
      {kept, _rest} -> kept
    end
  end

  defp how(segment, {_i, role, text}) when role in [:user, :assistant] do
    [label, body] = String.split(text, ": ", parts: 2)

    cond do
      segment == text ->
        :whole

      String.starts_with?(segment, label <> ": ... ") ->
        tail = String.replace_prefix(segment, label <> ": ... ", "")

        if tail != "" and String.ends_with?(body, tail) and
             String.length(tail) < String.length(body),
           do: :cut

      true ->
        nil
    end
  end

  defp how(segment, {_i, :command, text}), do: if(segment == text, do: :whole)

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
