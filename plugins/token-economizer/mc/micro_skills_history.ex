# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: The TokenEconomizer authors (microsoft/TokenEconomizer); HAL-C2 contributors
# Ported from tokeneconomizer/plugin/history.py (microsoft/TokenEconomizer@cb42207e3e09), into
# Elixir for HAL-C2's MC. Changed: a project's earlier threads are read from the MC
# (`Host.project_threads/2`, `Host.history/3`) instead of an agent's session logs, a thread
# standing for upstream's session and a turn for its prompt-turn; the fold's state is kept
# with the project's micro-skills instead of in a file of its own under a lock, as the
# plugin's one process folds; the envelope is seeded only where it has learned nothing yet,
# and what it seeded can be taken back out (`unseed/2`), which upstream had no way to do.

defmodule HalC2Plugins.TokenEconomizer.MicroSkills.History do
  @moduledoc """
  The first fold from history: a project's earlier threads, folded into its
  micro-skills when they are first turned on in it with nothing folded yet.

  A fold is a map kept with the project's micro-skills, so a page of turns and
  the place reached after it are saved together and a fold cut off by a crash
  or a restart resumes where it was, never folding a turn twice:

    * `"state"`: `"running"`, then `"done"`, or `"stopped"` (with
      `"reason"`) when the history import was turned off under it, which
      `resume/1` picks up where it stopped once it is on again, or `"skipped"`
      (with `"reason"`) for a project that had already learned from its turns,
      which is never imported into;
    * `"startedAt"`: only turns that ended before it are imported; one that
      ended since was heard live, held back or folded then;
    * `"plan"`: the thread ids to read, oldest first, nil until planned;
      `"next"`, the index of the one being read, and `"after"`, the last of its
      turns read;
    * `"step"`: how many reads the fold applied, which names the next, so the
      answer to a read the fold has moved past is told from the one it awaits;
    * `"pending"`: the turns that ended live in the project while it ran,
      `[thread id, run id, staged fact ids]`, oldest first, folded after the
      import, in order;
    * `"turns"`, the turns folded, and `"skipped"`, what was left out and why;
    * `"envelopes"`: per provider driver, whether the loop guard's envelope was
      seeded from the imported turns (`%{"seeded" => n}`) or left out (`%{"left"
      => reason}`), and how many pages it missed for the guard being off
      (`"guardOff"`), so one seeded around them does not read as whole.

  Nothing here reads a thread or a file: the plugin's process reads in a task
  of its own (`HalC2Plugins.TokenEconomizer`), a page at a time, and folds what
  this says.
  """

  alias HalC2Plugins.TokenEconomizer.LoopGuard.{Envelope, State, Turn}

  # The live turns a running fold holds back at most; one more is left out, counted.
  @pending_kept 500

  def pending_kept, do: @pending_kept

  @doc "A fold that starts now, `id` naming it."
  def new(id, now) do
    %{
      "state" => "running",
      "id" => id,
      "startedAt" => now,
      "plan" => nil,
      "next" => 0,
      "after" => nil,
      "step" => 0,
      "turns" => 0,
      "skipped" => %{},
      "pending" => [],
      "envelopes" => %{}
    }
  end

  @doc "A project that is never imported into, and why."
  def skipped(reason, now), do: %{"state" => "skipped", "reason" => reason, "endedAt" => now}

  @doc """
  The threads to read, oldest first, and what was left out, by reason: those
  never sent a message (`"noPrompt"`), those last active more than `days` days
  before `now` (`"tooOld"`), and past the newest `max` of the rest
  (`"overLimit"`). `threads` are `Host.project_threads/2`'s.
  """
  def plan(threads, %DateTime{} = now, days, max) do
    since = DateTime.add(now, -days * 86_400, :second)

    {eligible, skipped} =
      Enum.reduce(threads, {[], %{}}, fn thread, {eligible, skipped} ->
        cond do
          thread["latestUserMessageAt"] == nil ->
            {eligible, count(skipped, "noPrompt")}

          older?(last_active(thread), since) ->
            {eligible, count(skipped, "tooOld")}

          true ->
            {[thread | eligible], skipped}
        end
      end)

    eligible = Enum.sort_by(eligible, &{&1["createdAt"] || "", &1["id"]})
    over = max(length(eligible) - max, 0)
    skipped = if over > 0, do: Map.put(skipped, "overLimit", over), else: skipped
    {eligible |> Enum.drop(over) |> Enum.map(& &1["id"]), skipped}
  end

  defp last_active(thread),
    do: thread["latestRunCompletedAt"] || thread["updatedAt"] || thread["createdAt"]

  defp older?(at, since) do
    case is_binary(at) && DateTime.from_iso8601(at) do
      {:ok, at, _} -> DateTime.compare(at, since) == :lt
      _ -> false
    end
  end

  defp count(skipped, reason, n \\ 1), do: Map.update(skipped, reason, n, &(&1 + n))

  @doc "The fold with its plan."
  def planned(fold, ids, skipped),
    do: %{
      fold
      | "plan" => ids,
        "skipped" => merge(fold["skipped"], skipped),
        "step" => step(fold)
    }

  defp merge(a, b), do: Map.merge(a, b, fn _k, x, y -> x + y end)
  defp step(fold), do: fold["step"] + 1

  @doc """
  What a running fold reads next: `:plan`, `{:page, thread id, after run id}`,
  `{:pending, entries}` (the live turns it held back, once the import is over
  or stopped), or `:finish` once nothing is left.
  """
  def next(%{"state" => "running"} = fold) do
    cond do
      fold["plan"] == nil and fold["stop"] == nil -> :plan
      importing?(fold) -> {:page, Enum.at(fold["plan"], fold["next"]), fold["after"]}
      fold["pending"] != [] -> {:pending, Enum.take(fold["pending"], 10)}
      true -> :finish
    end
  end

  def next(_fold), do: nil

  @doc """
  The turns of one thread among `runs`, the run ids it held back, by run id:
  `read` takes the run to read before (nil for the newest) and answers a page
  of `page` turns, oldest first, as `HalC2.Plugins.Host.history/3` does.
  Pages are read newest first until every run is found, the thread has no
  more, or the page reaches the turns that ended before `fold` started,
  which no held turn is among. A page that cannot be read ends it.
  """
  def held_turns(runs, fold, page, read, before \\ nil, found \\ %{}) do
    case read.(before) do
      {:ok, [oldest | _] = turns} ->
        found = for turn <- turns, turn["runId"] in runs, into: found, do: {turn["runId"], turn}

        if map_size(found) == MapSet.size(runs) or length(turns) < page or
             imported?(fold, oldest["completedAt"] || oldest["startedAt"]),
           do: found,
           else: held_turns(runs, fold, page, read, oldest["runId"], found)

      _ ->
        found
    end
  end

  @doc "Whether a fold still reads the threads of its plan."
  def importing?(fold) do
    running?(fold) and fold["stop"] == nil and is_list(fold["plan"]) and
      fold["next"] < length(fold["plan"])
  end

  @doc "Whether a fold holds the project's live turns back."
  def running?(fold), do: match?(%{"state" => "running"}, fold)

  @doc """
  The fold after a page of a thread was read and `folded` of its turns
  folded: on at the thread's next page when there is `more`, else at the next
  thread.
  """
  def paged(fold, folded, last_run, more) do
    fold = %{fold | "turns" => fold["turns"] + folded, "step" => step(fold)}

    if more and last_run != nil,
      do: %{fold | "after" => last_run},
      else: %{fold | "next" => fold["next"] + 1, "after" => nil}
  end

  @doc """
  The fold after its thread could not be read: the thread is left out and
  counted, and what was folded of it stands.
  """
  def unreadable(fold) do
    %{
      fold
      | "next" => fold["next"] + 1,
        "after" => nil,
        "step" => step(fold),
        "skipped" => count(fold["skipped"], "unreadable")
    }
  end

  @doc """
  The fold after the first `length(entries)` held-back live turns were read,
  `folded` of them folded and the rest, which could not be read, counted.
  """
  def drained(fold, entries, folded) do
    lost = length(entries) - folded

    %{
      fold
      | "pending" => Enum.drop(fold["pending"], length(entries)),
        "turns" => fold["turns"] + folded,
        "step" => step(fold),
        "skipped" =>
          if(lost > 0, do: count(fold["skipped"], "unreadable", lost), else: fold["skipped"])
    }
  end

  @doc """
  Holds a live turn back until the import is over, `[thread id, run id,
  staged ids]`; past `pending_kept/0` it is left out, counted.
  """
  def hold(fold, entry) do
    if length(fold["pending"]) < @pending_kept,
      do: %{fold | "pending" => fold["pending"] ++ [entry]},
      else: %{fold | "skipped" => count(fold["skipped"], "tooManyLive")}
  end

  @doc "The run ids of the live turns held back, which the import leaves to them."
  def held(fold), do: MapSet.new(fold["pending"], fn [_thread, run, _ids] -> run end)

  @doc "Stops reading the plan; the live turns held back are still folded, then it is `stopped`."
  def stop(%{"state" => "running"} = fold, reason), do: Map.put(fold, "stop", reason)
  def stop(fold, _reason), do: fold

  @doc """
  The fold once nothing is left to read: `done`, or `stopped` keeping where
  it got to, for `resume/1`.
  """
  def finish(fold, now) do
    case fold["stop"] do
      nil ->
        Map.merge(fold, %{"state" => "done", "endedAt" => now, "plan" => nil, "pending" => []})

      reason ->
        fold
        |> Map.delete("stop")
        |> Map.merge(%{"state" => "stopped", "reason" => reason, "endedAt" => now})
    end
  end

  @doc """
  A stopped fold running again from where it stopped, or a running one told
  to stop that goes on reading; any other as it is.
  """
  def resume(%{"state" => "stopped", "step" => step} = fold) when is_integer(step),
    do: fold |> Map.drop(~w(reason endedAt)) |> Map.put("state", "running")

  def resume(%{"state" => "running"} = fold), do: Map.delete(fold, "stop")

  def resume(fold), do: fold

  @doc """
  Whether an imported turn that ended at `ended_at` is the fold's: it ended
  before the fold started. Without a time it is not, as it cannot be told
  from one heard live.
  """
  def imported?(fold, ended_at) do
    with true <- is_binary(ended_at) and is_binary(fold["startedAt"]),
         {:ok, ended, _} <- DateTime.from_iso8601(ended_at),
         {:ok, started, _} <- DateTime.from_iso8601(fold["startedAt"]) do
      DateTime.compare(ended, started) == :lt
    else
      _ -> false
    end
  end

  @doc "What a person is shown of a fold: nil is one that never started."
  def view(nil), do: %{"state" => "none"}

  def view(fold) do
    %{
      "state" => fold["state"],
      "reason" => fold["reason"] || fold["stop"],
      "startedAt" => fold["startedAt"],
      "endedAt" => fold["endedAt"],
      "threads" => if(is_list(fold["plan"]), do: length(fold["plan"])),
      "threadsRead" => if(is_list(fold["plan"]), do: min(fold["next"], length(fold["plan"]))),
      "turns" => fold["turns"],
      "pending" => length(fold["pending"] || []),
      "skipped" => fold["skipped"],
      "envelopes" => fold["envelopes"]
    }
    |> Map.reject(fn {_k, v} -> v == nil end)
  end

  @doc "A fold as saved, or nil for one that is not: never half a fold."
  def load(%{"state" => state, "id" => id, "step" => step, "startedAt" => at} = saved)
      when state in ~w(running stopped) and is_binary(id) and is_integer(step) and
             is_binary(at) do
    pending =
      for [thread, run, ids] <- List.wrap(saved["pending"]),
          is_binary(thread) and is_binary(run) and is_list(ids),
          do: [thread, run, Enum.filter(ids, &is_binary/1)]

    fold =
      new(id, at)
      |> Map.merge(
        Map.take(saved, ~w(plan next after turns skipped envelopes stop reason endedAt))
      )
      |> Map.merge(%{"state" => state, "step" => step, "pending" => pending})

    if (fold["plan"] == nil or is_list(fold["plan"])) and is_integer(fold["next"]) and
         is_integer(fold["turns"]) and is_map(fold["skipped"]) and is_map(fold["envelopes"]),
       do: fold,
       else: nil
  end

  def load(%{"state" => state} = saved) when state in ~w(done skipped),
    do: Map.take(saved, ~w(state reason id startedAt endedAt turns skipped envelopes))

  def load(_saved), do: nil

  # --- the loop guard's envelope ----------------------------------------------------------

  @doc """
  An imported turn replayed through a fresh guard with no envelope and no
  judge, so nothing can redirect or stop it, as upstream's `replay_envelope`:
  `%{"turns", "snap"}` when it feeds the envelope (it ended green, with calls,
  `Turn.resolved_proxy/2`), else nil. `calls` are `{name, args, result, code}`.
  """
  def replay(calls, status, level, thresholds) do
    thr = Envelope.base_thresholds(level, thresholds)

    guard =
      Enum.reduce(calls, Turn.new(), fn {name, args, result, code}, guard ->
        {guard, _decision, _job} =
          Turn.fold(guard, name, args, result, code, envelope: nil, thr: thr, judge: false)

        guard
      end)

    if Turn.resolved_proxy(guard, status == "completed"),
      do: %{"turns" => guard.cum_turns, "snap" => State.snapshot(guard.whole)}
  end

  @doc """
  `tracker` claimed for a running fold as a live turn is about to be recorded
  in it with nothing learned yet, so what the fold imports after still seeds
  it, ahead of that turn.
  """
  def claim(tracker, fold) do
    if running?(fold) and tracker.resolved_turns == [] and tracker[:seed] == nil,
      do: Map.put(tracker, :seed, %{"fold" => fold["id"], "n" => 0, "step" => -1}),
      else: tracker
  end

  @doc "A tracker's seed as saved with it, or nil."
  def load_seed(%{"fold" => fold, "n" => n, "step" => step} = seed)
      when is_binary(fold) and is_integer(n) and n >= 0 and is_integer(step),
      do: Map.take(seed, ~w(fold n step))

  def load_seed(_saved), do: nil

  @doc """
  Whether fold `fold_id` may seed `tracker`: one it seeds already, or one that
  has learned nothing yet. An envelope that learned from live turns cannot say
  which, so the imported turns could count twice: `{:left, reason}`.
  """
  def seedable(tracker, fold_id) do
    cond do
      match?(%{"fold" => ^fold_id}, tracker[:seed]) ->
        :seeding

      tracker.resolved_turns == [] ->
        :seeding

      true ->
        {:left, "the envelope had already learned from #{length(tracker.resolved_turns)} turns"}
    end
  end

  @doc """
  What an imported page does to a provider driver's envelope, whose fold
  entry is `entry`: `:seed` it, `:keep` what an earlier page did, or leave
  the page out, `{:left, reason}`. The guard off leaves out only that page:
  on again, a later page seeds where `seedable/2` lets it.
  """
  def envelope(entry, guard_on, tracker, fold_id) do
    cond do
      not guard_on and match?(%{"seeded" => _}, entry) -> :keep
      not guard_on -> {:left, "the loop guard was off"}
      true -> with :seeding <- seedable(tracker, fold_id), do: :seed
    end
  end

  @doc """
  A provider driver's fold entry after a page whose `envelope/4` decision
  came to `outcome`: `{:seeded, n}`, `:keep` or `{:left, reason}`.
  """
  def noted(entry, guard_on, outcome) do
    entry = entry || %{}
    entry = if guard_on, do: entry, else: Map.update(entry, "guardOff", 1, &(&1 + 1))

    case outcome do
      {:seeded, n} -> entry |> Map.delete("left") |> Map.put("seeded", n)
      :keep -> entry
      {:left, reason} -> Map.put(entry, "left", reason)
    end
  end

  @doc """
  Seeds `tracker` with an imported page's `samples` (`replay/4`'s), for fold
  `fold_id`'s read `step`, ahead of the turns it learned live since: the
  imported turns are the older. A step it has already seeded changes nothing,
  so a page read again after a crash is not seeded twice.
  """
  def seed(tracker, fold_id, step, samples) do
    seed =
      case tracker[:seed] do
        %{"fold" => ^fold_id} = seed -> seed
        _ -> %{"fold" => fold_id, "n" => 0, "step" => -1}
      end

    if step <= seed["step"] or samples == [] do
      Map.put(tracker, :seed, %{seed | "step" => max(seed["step"], step)})
    else
      n = seed["n"]

      turns =
        Enum.take(tracker.resolved_turns, n) ++
          Enum.map(samples, & &1["turns"]) ++ Enum.drop(tracker.resolved_turns, n)

      snaps =
        Enum.take(tracker.resolved_snaps, n) ++
          Enum.map(samples, & &1["snap"]) ++ Enum.drop(tracker.resolved_snaps, n)

      cut = max(length(turns) - Envelope.history(), 0)

      %{
        tracker
        | resolved_turns: Enum.drop(turns, cut),
          resolved_snaps: Enum.drop(snaps, max(length(snaps) - Envelope.history(), 0))
      }
      |> Map.put(:seed, %{seed | "n" => max(n + length(samples) - cut, 0), "step" => step})
    end
  end

  @doc """
  Records a live turn as `Envelope.record_turn/3` does, keeping count of the
  seeded turns the cap pushed out.
  """
  def record_turn(tracker, guard, stopped_normally) do
    recorded = Envelope.record_turn(tracker, guard, stopped_normally)

    case tracker[:seed] do
      %{"n" => n} = seed when n > 0 ->
        grew = recorded.resolved_turns != tracker.resolved_turns

        cut =
          if grew and length(recorded.resolved_turns) == length(tracker.resolved_turns),
            do: 1,
            else: 0

        Map.put(recorded, :seed, %{seed | "n" => n - cut})

      _ ->
        recorded
    end
  end

  @doc "Takes what fold `fold_id` seeded back out of `tracker`."
  def unseed(tracker, fold_id) do
    case tracker[:seed] do
      %{"fold" => ^fold_id, "n" => n} ->
        %{
          tracker
          | resolved_turns: Enum.drop(tracker.resolved_turns, n),
            resolved_snaps: Enum.drop(tracker.resolved_snaps, n)
        }
        |> Map.put(:seed, nil)

      _ ->
        tracker
    end
  end
end
