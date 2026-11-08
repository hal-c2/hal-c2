defmodule HalC2.HandoffHistoryPropTest do
  @moduledoc """
  The laws `HalC2.Orchestration.Handoff.history/2` promises over any runs of what the
  user said, what other agents sent, the MC's notices, answers, commands and replies:
  the history fits its budget; every run is shown, under its heading, or counted as
  left out; it is the whole history whenever that fits; the first and newest runs are
  shown whenever any is; the newest run's last step is shown whenever what the user said
  leaves room for it; what the user said is cut only once every run with none of it is
  left out; a repeated message names a run that is shown; and a bigger budget never
  leaves out a run a smaller one kept, nor hides the newest run's last step. Pure, so
  plain `forall`s. proof/models/handoff_history.maude checks the same laws over every
  small thread at every budget.
  """

  use ExUnit.Case, async: true
  use PropCheck

  alias HalC2.Orchestration.Handoff

  @whole 100_000_000

  # Pure and fast, so it can afford the cases the newest run's rarer shapes need.
  property "a history fits, accounts for every run, and gives way in order",
    numtests: HalC2.Prop.numtests(500),
    max_size: 30 do
    forall {shapes, max_chars} <- {non_empty(list(run_shape())), budget()} do
      runs = build(shapes)
      # Less room than the note that every run is left out is no history.
      history = Handoff.history(runs, max_chars) || ""
      %{levels: levels, dropped: dropped} = Handoff.select(runs, max_chars)
      ordinals = Enum.map(runs, & &1.ordinal)
      shown = headings(history)

      checks = [
        fits: String.length(history) <= max_chars,
        accounted:
          Enum.sort(Map.keys(levels) ++ dropped) == ordinals and
            shown == Enum.sort(Map.keys(levels)),
        whole_when_it_fits: whole_when_it_fits?(runs, history, max_chars),
        ends_shown: levels == %{} or (hd(ordinals) in shown and List.last(ordinals) in shown),
        users_last: users_last?(runs, history, shown, dropped),
        newest_first: newest_first?(runs, history, max_chars),
        repeats_named: Enum.all?(repeat_targets(history), &(&1 in shown))
      ]

      failed = for {name, false} <- checks, do: name

      (failed == [])
      |> when_fail(IO.puts("failed #{inspect(failed)} at #{max_chars}:\n#{history}"))
      |> aggregate(path: path(levels, dropped))
    end
  end

  # A history within two characters of its budget once went condensed: what each run
  # took counted the blank line after the last.
  property "a whole history just under its budget is whole",
    numtests: HalC2.Prop.numtests(100),
    max_size: 30 do
    forall {shapes, slack} <- {non_empty(list(run_shape())), integer(0, 2)} do
      runs = build(shapes)
      whole = Handoff.history(runs, @whole)
      Handoff.history(runs, String.length(whole) + slack) == whole
    end
  end

  property "a bigger budget never leaves out a run a smaller one kept",
    numtests: HalC2.Prop.numtests(100),
    max_size: 30 do
    forall {shapes, small, more} <-
             {non_empty(list(run_shape())), budget(),
              frequency([{1, integer(0, 200)}, {1, integer(0, 30_000)}])} do
      runs = build(shapes)
      %{dropped: fewer} = Handoff.select(runs, small + more)
      %{dropped: dropped} = Handoff.select(runs, small)
      MapSet.subset?(MapSet.new(fewer), MapSet.new(dropped))
    end
  end

  # What the user said fitting whole with no room left for the newest run's answer once
  # went whole and hid it, where a smaller budget cut what was said to show it. That is
  # a window no wider than the step, around where what was said just fits, so budgets
  # across it are tried, each case from its own offset; a step too short to cut once hid
  # behind the line saying the steps before it are left out, two characters wide.
  property "a bigger budget never hides the newest run's last step",
    numtests: HalC2.Prop.numtests(100),
    max_size: 30 do
    forall {shapes, offset} <- {non_empty(list(run_shape())), integer(0, 19)} do
      runs = build(shapes)
      edge = said(runs) + 600

      max(0, edge - 1_500 + offset)..(edge + 1_500)//20
      |> Enum.map(&newest_step?(runs, Handoff.history(runs, &1)))
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.all?(fn [smaller, bigger] -> not smaller or bigger end)
    end
  end

  # Mostly room for a few runs, sometimes hardly any.
  defp budget, do: frequency([{1, integer(0, 1_000)}, {9, integer(1_000, 60_000)}])

  # --- what is checked ---------------------------------------------------------------

  defp newest_step?(runs, history) do
    case List.last(runs).entries |> Enum.filter(&step?/1) |> List.last() do
      nil -> false
      step -> is_binary(history) and String.contains?(history, step_id(step))
    end
  end

  defp headings(history) do
    Regex.scan(~r/^## Run (\d+)/m, history, capture: :all_but_first)
    |> Enum.map(fn [n] -> String.to_integer(n) end)
    |> Enum.sort()
  end

  defp repeat_targets(history) do
    Regex.scan(~r/\[the same message as in run (\d+)\]/, history, capture: :all_but_first)
    |> Enum.map(fn [n] -> String.to_integer(n) end)
  end

  defp whole_when_it_fits?(runs, history, max_chars) do
    whole = Handoff.history(runs, @whole)
    String.length(whole) > max_chars or history == whole
  end

  # Once a shown run's words from the user are not in the history whole (nor said once
  # before), every run between the first and the newest with none of them is left out.
  defp users_last?(runs, history, shown, dropped) do
    middle = runs |> Enum.drop(1) |> Enum.drop(-1)

    cut? =
      Enum.any?(runs, fn run ->
        run.ordinal in shown and
          Enum.any?(run.entries, fn
            {kind, text} when kind in [:user, :answer] ->
              not String.contains?(history, text) and not repeated?(runs, run, text)

            _ ->
              false
          end)
      end)

    not cut? or
      Enum.all?(middle, &(users_words?(&1) or &1.ordinal in dropped))
  end

  # Where what the user said leaves clear room, the newest run's last step is in the
  # history, whole or cut: the work the next agent picks up comes before older work.
  # The requests' share is overestimated by the runs without their steps, whole.
  defp newest_first?(runs, history, max_chars) do
    newest = List.last(runs)

    room = max_chars - 600 - said(runs) - 20 * length(runs)

    newest.entries |> Enum.filter(&step?/1) == [] or room < 1_500 or
      newest_step?(runs, history)
  end

  # About what the runs' requests take whole: the runs without their steps.
  defp said(runs) do
    runs
    |> Enum.map(fn run -> %{run | entries: Enum.reject(run.entries, &step?/1), files: []} end)
    |> Handoff.history(@whole)
    |> String.length()
  end

  defp step?({kind, _}), do: kind in [:command, :assistant]

  defp step_id({:command, %{input: input}}), do: "Command: #{input}\n"

  defp step_id({:assistant, text}),
    do: text |> String.split(" ", parts: 3) |> Enum.take(2) |> Enum.join(" ") |> Kernel.<>(" ")

  defp repeated?(runs, run, text) do
    Enum.any?(runs, fn earlier ->
      earlier.ordinal < run.ordinal and Enum.any?(earlier.entries, &(elem(&1, 1) == text))
    end)
  end

  defp users_words?(run), do: Enum.any?(run.entries, &(elem(&1, 0) in [:user, :answer]))

  defp path(levels, dropped) do
    cond do
      dropped != [] -> :left_out
      Enum.all?(Map.values(levels), &(&1 == :full)) -> :whole
      true -> :condensed
    end
  end

  # --- runs --------------------------------------------------------------------------

  defp size,
    do: frequency([{6, integer(1, 200)}, {3, integer(200, 3_000)}, {1, integer(3_000, 25_000)}])

  defp entry_shape do
    {frequency([
       {3, :user},
       {2, :agent},
       {1, :notice},
       {1, :answer},
       {3, :command},
       {3, :assistant},
       {1, :repeat}
     ]), size()}
  end

  defp run_shape,
    do: {non_empty(list(entry_shape())), integer(0, 12), oneof(["completed", "interrupted"])}

  # Every text starts with its own id, so finding it whole in the history is finding it.
  defp build(shapes) do
    {runs, _said} =
      shapes
      |> Enum.with_index(1)
      |> Enum.map_reduce([], fn {{entries, files, status}, ordinal}, said ->
        {entries, said} =
          entries
          |> Enum.with_index()
          |> Enum.map_reduce(said, fn {{kind, size}, i}, said ->
            body = "#{kind}-#{ordinal}-#{i} " <> String.duplicate("x", size)
            entry = entry(kind, body, ordinal, i, said)
            {entry, if(elem(entry, 0) == :user, do: [elem(entry, 1) | said], else: said)}
          end)

        run = %{
          ordinal: ordinal,
          provider: "codex",
          status: status,
          entries: entries,
          files:
            for(
              n <- 1..files//1,
              do: %{"path" => "f#{n}", "kind" => "modified", "additions" => n, "deletions" => 0}
            )
        }

        {run, said}
      end)

    runs
  end

  defp entry(:repeat, body, _ordinal, _i, []), do: {:user, "User: " <> body}
  defp entry(:repeat, _body, _ordinal, _i, [said | _]), do: {:user, said}
  defp entry(:user, body, _ordinal, _i, _said), do: {:user, "User: " <> body}
  defp entry(:agent, body, _ordinal, _i, _said), do: {:agent, "Sent by another agent: " <> body}

  defp entry(:answer, body, _ordinal, _i, _said),
    do: {:answer, "Asked: what?\nAnswered: " <> body}

  defp entry(:assistant, body, _ordinal, _i, _said), do: {:assistant, "Assistant: " <> body}

  defp entry(:notice, body, ordinal, i, _said),
    do: {:notice, %{text: "Notice: " <> body, line: "Notice: notice-#{ordinal}-#{i}"}}

  defp entry(:command, body, ordinal, i, _said) do
    input = "cmd-#{ordinal}-#{i}"
    output = String.slice(body, 0, 2_000)

    {:command,
     %{text: "Command: #{input}\nExit code: 0\n#{output}", input: input, ended: "Exit code: 0"}}
  end
end
