# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: The TokenEconomizer authors (microsoft/TokenEconomizer); HAL-C2 contributors
# Ported from tokeneconomizer/loopguard/envelope.py (microsoft/TokenEconomizer@cb42207e3e09),
# into Elixir for HAL-C2's MC. Changed: the tracker is a map, kept as JSON in the plugin's
# data directory, one file per project and provider; the plugin's one process reads and
# writes it, which replaces the store's lock; the frozen envelope is not ported.

defmodule HalC2Plugins.TokenEconomizer.LoopGuard.Envelope do
  @moduledoc """
  The project's envelope: how long a turn that ended well usually runs.

  A tracker learns, from turns that ended well only, a percentile of their lengths (the
  envelope past which a stuck turn may be acted on) and the detector thresholds on top
  of the preset level. A turn's own outcome only ever gates later turns.

  The percentile, not the max, keeps one very long turn from setting the envelope so far
  out that the guard never engages; it stays nil until `envelope_min_samples` turns ended
  well, so the guard never acts on a project it knows little about yet.
  """

  alias HalC2Plugins.TokenEconomizer.LoopGuard.Rules

  # Recent ended-green turns kept for the percentile.
  @history 500
  # Overrides that shape the envelope itself; the rest are pinned over the thresholds.
  @envelope_keys %{
    "envelope_margin" => :margin,
    "envelope_pct" => :pct,
    "envelope_min_samples" => :min_samples
  }

  def history, do: @history

  @doc "The linear-interpolated `p`th percentile of `xs` (0..100), nil for none."
  def percentile([], _), do: nil
  def percentile([x], _), do: x * 1.0

  def percentile(xs, p) do
    xs = Enum.sort(xs)
    n = length(xs)
    i = p / 100 * (n - 1)
    lo = trunc(i)

    if lo + 1 >= n do
      List.last(xs) * 1.0
    else
      a = Enum.at(xs, lo)
      a + (i - lo) * (Enum.at(xs, lo + 1) - a)
    end
  end

  @doc """
  A tracker at `level`, with the envelope-shaping `overrides` (`envelope_margin`,
  `envelope_pct`, `envelope_min_samples`) over the level's, and what `saved` (its JSON)
  had learned.
  """
  def new(level \\ "default", overrides \\ %{}, saved \\ %{}) do
    base = Rules.scaled_thresholds(level)

    ov =
      for {key, arg} <- @envelope_keys,
          Map.has_key?(overrides || %{}, key),
          into: %{},
          do: {arg, overrides[key]}

    %{
      level: level,
      base: base,
      margin: truthy(ov[:margin]) || base["envelope_margin"],
      pct: if(ov[:pct] != nil, do: ov[:pct], else: base["envelope_pct"]),
      min_samples:
        if(ov[:min_samples] != nil, do: ov[:min_samples], else: base["envelope_min_samples"]),
      resolved_turns:
        for(x <- List.wrap(saved["resolved_turns"]), is_number(x), x != 0, do: trunc(x)),
      resolved_snaps: for(s <- List.wrap(saved["resolved_snaps"]), is_map(s), do: s)
    }
  end

  defp truthy(x) when x in [nil, false, 0], do: nil
  defp truthy(x), do: x

  @doc "Records a finished turn; only one that ended green, with calls, feeds the baseline."
  def update(tracker, turns, resolved, snapshot \\ nil) do
    if resolved and turns not in [nil, 0] do
      snaps = if snapshot, do: tracker.resolved_snaps ++ [snapshot], else: tracker.resolved_snaps
      %{tracker | resolved_turns: tracker.resolved_turns ++ [turns], resolved_snaps: snaps}
    else
      tracker
    end
  end

  @doc "Margin times the percentile of the turns that ended well, or nil before enough."
  def envelope(tracker) do
    if length(tracker.resolved_turns) < tracker.min_samples,
      do: nil,
      else: percentile(tracker.resolved_turns, tracker.pct) * tracker.margin
  end

  @doc """
  The threshold map the rules read: the level's base and, once `min_samples` turns
  ended well, what they taught. Turn-scale gates scale down to the learned turn lengths;
  signal gates sit just above the green turns' p90 but never below the base, so learning
  never makes the guard more trigger-happy than its level asks. `max_turns`, a turn cap,
  keeps the backstop reachable under it.
  """
  def thresholds(tracker, max_turns \\ nil) do
    base = tracker.base
    env = envelope(tracker)

    thr =
      if env != nil do
        bt = env * base["backstop_mult"]
        Map.put(base, "backstop_turns", if(max_turns, do: min(bt, 0.9 * max_turns), else: bt))
      else
        base
      end

    if length(tracker.resolved_turns) < tracker.min_samples do
      thr
    else
      p90t = percentile(tracker.resolved_turns, 90) || 0

      thr =
        thr
        |> Map.put("gate_min_turns", clamp(0.6 * p90t, 6, base["gate_min_turns"]))
        |> Map.put("min_turns", clamp(0.6 * p90t, 8, base["min_turns"]))

      if tracker.resolved_snaps == [] do
        thr
      else
        sig = fn key -> for s <- tracker.resolved_snaps, do: number(s[key]) end
        above = fn key -> ceil_int((percentile(sig.(key), 90) || 0) + 1) end
        errors = max(base["error_outputs"], above.("error_outputs"))

        thr
        |> Map.put("edit_churn", max(base["edit_churn"], above.("edit_churn")))
        |> Map.put(
          "distinct_edit_files",
          max(base["distinct_edit_files"], above.("distinct_edit_files"))
        )
        |> Map.put("error_outputs", errors)
        |> Map.put("gate_error_outputs", max(base["gate_error_outputs"], errors))
        |> Map.put(
          "stagnation",
          max(base["stagnation"], Float.round((percentile(sig.("stagnation"), 90) || 0) * 1.0, 3))
        )
      end
    end
  end

  defp number(x) when is_number(x), do: x
  defp number(_), do: 0

  defp ceil_int(x) when is_integer(x), do: x
  defp ceil_int(x), do: x |> Float.ceil() |> trunc()

  # Python's int(max(lo, min(hi, round(v)))), round to even included.
  defp clamp(v, lo, hi), do: trunc(max(lo, min(hi, round_even(v))))

  @doc false
  def round_even(v) do
    floor = Float.floor(v * 1.0)
    diff = v - floor

    cond do
      diff > 0.5 -> trunc(floor) + 1
      diff < 0.5 -> trunc(floor)
      rem(trunc(floor), 2) == 0 -> trunc(floor)
      true -> trunc(floor) + 1
    end
  end

  @doc """
  The thresholds a turn is checked against: the level, what this project's history
  learned on top of it, then a person's pinned values, which win.
  """
  def turn_thresholds(tracker, overrides \\ %{}) do
    overrides = overrides || %{}
    thr = thresholds(tracker)
    thr = Map.merge(thr, Map.drop(overrides, Map.keys(@envelope_keys)))

    case {Map.has_key?(overrides, "backstop_mult"), envelope(tracker)} do
      {true, env} when env != nil -> Map.put(thr, "backstop_turns", env * thr["backstop_mult"])
      _ -> thr
    end
  end

  @doc "The thresholds before any learning: the level with a person's pinned values on top."
  def base_thresholds(level \\ "default", overrides \\ %{}),
    do: Map.merge(Rules.scaled_thresholds(level), overrides || %{})

  @doc "The tracker as its file keeps it."
  def dump(tracker) do
    %{
      "level" => tracker.level,
      "resolved_turns" => Enum.take(tracker.resolved_turns, -@history),
      "resolved_snaps" => Enum.take(tracker.resolved_snaps, -@history)
    }
  end

  @doc """
  Folds a finished turn into `tracker`. Only turns that ended green feed it; the
  snapshot is of the whole turn, not the segment after a nudge.
  """
  def record_turn(tracker, guard, stopped_normally) do
    alias HalC2Plugins.TokenEconomizer.LoopGuard.{State, Turn}

    tracker
    |> update(
      guard.cum_turns,
      Turn.resolved_proxy(guard, stopped_normally),
      State.snapshot(guard.whole)
    )
    |> then(
      &%{
        &1
        | resolved_turns: Enum.take(&1.resolved_turns, -@history),
          resolved_snaps: Enum.take(&1.resolved_snaps, -@history)
      }
    )
  end
end
