# SPDX-License-Identifier: Apache-2.0

for file <-
      ~w(loop_guard_state loop_guard_rules loop_guard_shell_edits loop_guard_turn loop_guard_envelope micro_skills_history),
    do: Code.require_file("../../../../plugins/token-economizer/mc/#{file}.ex", __DIR__)

defmodule HalC2.TokenEconomizerHistoryTest do
  @moduledoc """
  TokenEconomizer's first fold from history (`plugins/token-economizer/mc/micro_skills_history.ex`):
  what it reads, in what order, what it leaves out, where a crash resumes it, and what it
  seeds the loop guard's envelope with and takes back out.
  """
  use ExUnit.Case, async: true

  alias HalC2Plugins.TokenEconomizer.LoopGuard.{Envelope, Turn}
  alias HalC2Plugins.TokenEconomizer.MicroSkills.History

  @now ~U[2026-11-09 12:00:00Z]

  defp thread(id, created, opts \\ []) do
    %{
      "id" => id,
      "createdAt" => created,
      "updatedAt" => opts[:active] || created,
      "latestUserMessageAt" => Keyword.get(opts, :prompt, created),
      "latestRunCompletedAt" => opts[:active]
    }
  end

  describe "the plan" do
    test "reads the threads oldest first, leaving out those never prompted, too old and past the most" do
      threads = [
        thread("c", "2026-11-03T00:00:00Z"),
        thread("a", "2026-11-01T00:00:00Z"),
        thread("silent", "2026-11-02T00:00:00Z", prompt: nil),
        thread("old", "2024-01-01T00:00:00Z"),
        thread("revived", "2024-01-01T00:00:00Z", active: "2026-11-08T00:00:00Z"),
        thread("b", "2026-11-02T00:00:00Z")
      ]

      assert {["a", "b", "c"], %{"noPrompt" => 1, "tooOld" => 1, "overLimit" => 1}} =
               History.plan(threads, @now, 365, 3)

      assert {["revived", "a", "b", "c"], %{"noPrompt" => 1, "tooOld" => 1}} =
               History.plan(threads, @now, 365, 200)
    end
  end

  describe "a fold's reads" do
    test "plans, pages each thread to its end, then folds the live turns it held back, in order" do
      fold = History.new("f", "2026-11-09T12:00:00Z")
      assert History.next(fold) == :plan

      fold = History.planned(fold, ["a", "b"], %{"tooOld" => 2})
      assert History.next(fold) == {:page, "a", nil}

      fold = History.hold(fold, ["live", "r9", ["fact"]])
      assert History.held(fold) == MapSet.new(["r9"])

      fold = History.paged(fold, 20, "r20", true)
      assert History.next(fold) == {:page, "a", "r20"}
      fold = History.paged(fold, 3, "r23", false)
      assert History.next(fold) == {:page, "b", nil}

      fold = History.unreadable(fold)
      assert History.next(fold) == {:pending, [["live", "r9", ["fact"]]]}

      fold = History.drained(fold, [["live", "r9", ["fact"]]], 1)
      assert History.next(fold) == :finish
      fold = History.finish(fold, "2026-11-09T12:01:00Z")

      assert %{
               "state" => "done",
               "turns" => 24,
               "skipped" => %{"tooOld" => 2, "unreadable" => 1},
               "pending" => 0
             } = History.view(fold)

      assert History.next(fold) == nil
    end

    test "each read moves the step, so an answer the fold moved past is told apart" do
      fold = History.new("f", "2026-11-09T12:00:00Z")
      steps = [fold, History.planned(fold, ["a"], %{})]
      steps = steps ++ [History.paged(List.last(steps), 1, "r1", false)]
      assert Enum.map(steps, & &1["step"]) == [0, 1, 2]
    end

    test "past the live turns it keeps, one more is left out and counted" do
      fold =
        Enum.reduce(1..(History.pending_kept() + 1), History.new("f", "t"), fn n, fold ->
          History.hold(fold, ["t", "r#{n}", []])
        end)

      assert length(fold["pending"]) == History.pending_kept()
      assert fold["skipped"] == %{"tooManyLive" => 1}
    end

    test "stopped, it folds what it held back, keeps where it got to, and resumes from there" do
      fold =
        History.new("f", "2026-11-09T12:00:00Z")
        |> History.planned(["a", "b"], %{})
        |> History.paged(2, "r2", false)
        |> History.hold(["live", "r9", []])
        |> History.stop("the history import was turned off")

      assert History.running?(fold)
      assert History.next(fold) == {:pending, [["live", "r9", []]]}
      fold = fold |> History.drained([["live", "r9", []]], 1) |> History.finish("later")

      assert %{"state" => "stopped", "reason" => "the history import was turned off"} =
               History.view(fold)

      refute History.running?(fold)
      fold = History.resume(fold)
      assert History.next(fold) == {:page, "b", nil}
      assert History.view(fold)["turns"] == 3
    end

    test "told to stop and resumed before it stopped, it goes on reading" do
      fold =
        History.new("f", "t")
        |> History.planned(["a"], %{})
        |> History.stop("off")
        |> History.resume()

      assert History.next(fold) == {:page, "a", nil}
    end
  end

  describe "the live turns it held back" do
    # A thread of `n` ended turns, r1 to rn, the fold started as r`started` ended,
    # read as `Host.history/3` reads it with `before:`; the reads are counted.
    defp thread_of(n, started) do
      turns =
        for i <- 1..n,
            do: %{"runId" => "r#{i}", "completedAt" => "2026-11-09T12:00:#{pad(i)}Z"}

      fold = History.new("f", "2026-11-09T12:00:#{pad(started)}.5Z")

      read = fn before ->
        send(self(), :read)
        cut = if before, do: Enum.find_index(turns, &(&1["runId"] == before)), else: n
        {:ok, turns |> Enum.take(cut) |> Enum.take(-5)}
      end

      {fold, read}
    end

    defp pad(i), do: i |> Integer.to_string() |> String.pad_leading(2, "0")

    defp reads(n \\ 0) do
      receive do
        :read -> reads(n + 1)
      after
        0 -> n
      end
    end

    test "pages back past the newest turns until it has them all" do
      {fold, read} = thread_of(30, 2)
      found = History.held_turns(MapSet.new(["r28", "r12", "r4"]), fold, 5, read)
      assert Map.keys(found) |> Enum.sort() == ["r12", "r28", "r4"]
      assert reads() == 6
    end

    test "stops at the turns that ended before the fold started, or the thread's first" do
      {fold, read} = thread_of(30, 18)

      assert History.held_turns(MapSet.new(["r25", "gone"]), fold, 5, read) |> Map.keys() == [
               "r25"
             ]

      assert reads() == 3

      {fold, read} = thread_of(7, 0)
      assert History.held_turns(MapSet.new(["gone"]), fold, 5, read) == %{}
      assert reads() == 2
    end

    test "a page that cannot be read ends it with what it found" do
      assert History.held_turns(MapSet.new(["r1"]), History.new("f", "t"), 5, fn _ ->
               {:error, :gone}
             end) ==
               %{}
    end
  end

  describe "what it imports" do
    test "only turns that ended before it started; one without a time is not" do
      fold = History.new("f", "2026-11-09T12:00:00Z")
      assert History.imported?(fold, "2026-11-09T11:59:59.999Z")
      refute History.imported?(fold, "2026-11-09T12:00:00Z")
      refute History.imported?(fold, "2026-11-09T12:00:01Z")
      refute History.imported?(fold, nil)
    end
  end

  describe "a saved fold" do
    test "loads back as it was, running or stopped, and done or skipped as shown" do
      running =
        History.new("f", "2026-11-09T12:00:00Z")
        |> History.planned(["a", "b"], %{"noPrompt" => 1})
        |> History.paged(5, "r5", true)
        |> History.hold(["live", "r9", ["fact"]])

      stopped = running |> History.stop("off") |> History.drained([["live", "r9", ["fact"]]], 1)
      stopped = History.finish(stopped, "later")
      done = running |> History.drained(running["pending"], 1) |> History.finish("later")
      skipped = History.skipped("the project had already learned from its turns", "now")

      for fold <- [running, stopped] do
        assert History.load(fold |> JSON.encode!() |> JSON.decode!()) == fold
      end

      for fold <- [done, skipped] do
        loaded = History.load(fold |> JSON.encode!() |> JSON.decode!())
        assert History.view(loaded) == History.view(fold)
      end
    end

    test "never half a fold" do
      fold = History.new("f", "2026-11-09T12:00:00Z")
      assert History.load(Map.put(fold, "plan", "a")) == nil
      assert History.load(Map.delete(fold, "step")) == nil
      assert History.load(Map.put(fold, "state", "elsewhere")) == nil
      assert History.load(nil) == nil
    end
  end

  describe "the loop guard's envelope" do
    defp green, do: [{"Bash", %{"command" => "pytest -q"}, "3 passed in 0.10s", 0}]

    defp sample, do: History.replay(green(), "completed", "default", %{})

    defp live(tracker) do
      {g, _, _} = Turn.fold(Turn.new(), "Bash", %{"command" => "pytest -q"}, "3 passed", 0)
      History.record_turn(tracker, g, true)
    end

    test "replays a turn with no envelope and no judge, giving a sample only for a green one" do
      assert %{"turns" => 1, "snap" => %{}} = sample()
      assert History.replay(green(), "failed", "default", %{}) == nil
      assert History.replay([], "completed", "default", %{}) == nil
    end

    test "seeds one that learned nothing, ahead of the live turns it claimed for, each step once" do
      tracker = Envelope.new()
      fold = History.new("f", "t")
      assert History.seedable(tracker, "f") == :seeding

      tracker = tracker |> History.claim(fold) |> live()
      assert tracker.resolved_turns == [1]
      assert History.seedable(tracker, "f") == :seeding

      seeded =
        History.seed(tracker, "f", 3, [%{sample() | "turns" => 7}, %{sample() | "turns" => 8}])

      assert seeded.resolved_turns == [7, 8, 1]
      assert History.seed(seeded, "f", 3, [sample()]) == seeded

      seeded = History.seed(seeded, "f", 4, [%{sample() | "turns" => 9}])
      assert seeded.resolved_turns == [7, 8, 9, 1]
      assert length(seeded.resolved_snaps) == 4

      unseeded = History.unseed(seeded, "f")
      assert unseeded.resolved_turns == [1]
      assert unseeded.resolved_snaps == tracker.resolved_snaps
      assert History.unseed(seeded, "another") == seeded
    end

    test "leaves one that learned from live turns before it, saying why" do
      tracker = live(Envelope.new())
      assert {:left, reason} = History.seedable(tracker, "f")
      assert reason =~ "already learned from 1 turns"
      assert History.claim(tracker, History.new("f", "t")) == tracker
    end

    test "unseeds only what it seeded once the cap has pushed some out" do
      cap = Envelope.history()
      samples = for n <- 1..3, do: %{sample() | "turns" => 100 + n}
      tracker = History.seed(Envelope.new(), "f", 0, samples)
      tracker = Enum.reduce(1..(cap - 2), tracker, fn _, t -> live(t) end)

      assert length(tracker.resolved_turns) == cap
      assert tracker.seed["n"] == 2
      assert hd(tracker.resolved_turns) == 102

      unseeded = History.unseed(tracker, "f")
      assert unseeded.resolved_turns == List.duplicate(1, cap - 2)
    end

    test "a page with the guard off is left out; a later page with it on seeds" do
      tracker = Envelope.new()
      assert {:left, "the loop guard was off"} = left = History.envelope(nil, false, tracker, "f")
      assert History.envelope(%{"left" => elem(left, 1)}, true, tracker, "f") == :seed
      assert History.envelope(%{"seeded" => 2}, false, tracker, "f") == :keep
      assert History.envelope(%{"seeded" => 2}, true, tracker, "f") == :seed

      assert {:left, reason} = History.envelope(nil, true, live(tracker), "f")
      assert reason =~ "already learned"
    end

    test "a seed saved with the tracker loads back; a bad one does not" do
      seed = %{"fold" => "f", "n" => 2, "step" => 3}
      assert History.load_seed(seed) == seed
      assert History.load_seed(%{seed | "n" => -1}) == nil
      assert History.load_seed(nil) == nil
    end
  end
end
