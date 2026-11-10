# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: The TokenEconomizer authors (microsoft/TokenEconomizer); HAL-C2 contributors
# Ported from tokeneconomizer/loopguard/rules.py (microsoft/TokenEconomizer@cb42207e3e09),
# into Elixir for HAL-C2's MC. Changed: thresholds are a map with string keys (the names
# a person pins in the plugin's settings), and `read_verdict/2` reads a verdict on its own,
# for the plugin's judge, which answers in the background a call later. `assess_abort/4`
# keeps upstream's judge as a function of the digest.

defmodule HalC2Plugins.TokenEconomizer.LoopGuard.Rules do
  @moduledoc """
  When a turn counts as stuck, and what to do about it. Three tiers, cheapest first:

    * `gate_for_judge/2`, free, on every call: is the recent trace worth a paid look?
    * a paid judge, only when the gate is open;
    * `stuck?/2`, the strict heuristic used when no judge is wired: churn or scatter,
      and sustained errors, and repeated identical failures.

  `assess_abort/4` runs the cascade against the project's envelope (how long a turn that
  ended well usually runs) with a hard backstop the judge cannot veto. `nudge_text/1` is
  the redirect sent first: it mirrors only the agent's own actions back at it, carries no
  outside knowledge, and never tells it to stop.
  """

  alias HalC2Plugins.TokenEconomizer.LoopGuard.State

  # The stuck signature asks for a conjunction (churn and errors and some repetition), so
  # productive but hard turns, whose failures change, are spared.
  @defaults %{
    # Do not judge a turn stuck before its solve loop has run a while.
    "min_turns" => 20,
    # Four or more edits to one file,
    "edit_churn" => 4,
    # or edits scattered across three or more files.
    "distinct_edit_files" => 3,
    # Sustained error density.
    "error_outputs" => 6,
    # A fifth or more of the failures repeat an earlier one.
    "stagnation" => 0.20,
    # Act only beyond margin times the percentile of turns that ended well,
    "envelope_margin" => 1.25,
    # the p90, not the max: one very long turn would set the envelope far out.
    "envelope_pct" => 90,
    # Five turns that ended well before the percentile is trusted.
    "envelope_min_samples" => 5,
    # How sure the judge must be to drive an abort.
    "judge_confidence" => 0.7,
    # Beyond this multiple of the envelope, a stuck turn aborts whatever the judge says:
    # a judge can read thrashing far past the envelope as exploration.
    "backstop_mult" => 2.5,
    # The gate to the judge is sensitive on purpose; the judge supplies precision.
    "gate_min_turns" => 18,
    "gate_error_outputs" => 8
  }

  # A level scales the thresholds the guard starts from; the envelope then learns on top.
  # "aggressive" mainly wakes the nudge (a less sure judge, an earlier gate, and a nudge
  # for a turn the judge could not call) and pulls the backstop in; "conservative" spares
  # harder, for churny but productive projects.
  @levels %{
    "conservative" => %{
      "judge_confidence" => 0.85,
      "envelope_margin" => 1.5,
      "backstop_mult" => 3.5,
      "stagnation" => 0.30,
      "gate_min_turns" => 24,
      "min_turns" => 28,
      "edit_churn" => 5,
      "error_outputs" => 8,
      "envelope_min_samples" => 7
    },
    "default" => %{},
    "aggressive" => %{
      "judge_confidence" => 0.55,
      "envelope_margin" => 1.0,
      "backstop_mult" => 1.8,
      "stagnation" => 0.12,
      "gate_min_turns" => 12,
      "min_turns" => 14,
      "edit_churn" => 3,
      "error_outputs" => 4,
      "envelope_min_samples" => 3,
      "nudge_on_ambiguous" => true
    }
  }

  def defaults, do: @defaults
  def levels, do: Map.keys(@levels)

  @doc "The defaults with `level`'s overrides on top; an unknown level is the default."
  def scaled_thresholds(level \\ "default"),
    do: Map.merge(@defaults, Map.get(@levels, level, %{}))

  @doc """
  Whether the recent trace is worth a paid look: a repeated identical failure, or a high
  error density, once the loop has had time to form.
  """
  def gate_for_judge(state, thr \\ @defaults) do
    state.turns >= thr["gate_min_turns"] and
      (state.repeated_fail_sigs >= 1 or state.error_outputs >= thr["gate_error_outputs"])
  end

  @doc """
  The strict heuristic: run a while, and churn or scatter, and sustained errors, and
  repeated identical failures. The last term separates a doomed loop from a hard grind.
  """
  def stuck?(state, thr \\ @defaults) do
    state.turns >= thr["min_turns"] and
      (State.edit_churn(state) >= thr["edit_churn"] or
         State.distinct_edit_files(state) >= thr["distinct_edit_files"]) and
      state.error_outputs >= thr["error_outputs"] and
      State.stagnation(state) >= thr["stagnation"]
  end

  @doc """
  Whether to abort, as `{abort?, reason}`. `judge` is nil when none is wired, else a
  function of the state's digest that answers nil (throttled, or still thinking) or
  `%{"stuck" => true | false | nil, "confidence" => c, "reason" => text}`.

    * The backstop first: far past the envelope and stuck by `stuck?/2` aborts whatever
      the judge says.
    * With a judge, the gate opens on `gate_for_judge/2` or, unless
      `gate_over_envelope` is false, on a turn past the envelope. A stuck verdict at
      `judge_confidence` or more aborts, a productive one spares, and an unsure one spares
      too: only the backstop acts on the envelope alone.
    * With no judge, `stuck?/2` and a turn past the envelope abort.
  """
  def assess_abort(state, envelope \\ nil, judge \\ nil, thr \\ @defaults) do
    cond do
      abort = backstop(state, envelope, thr) ->
        abort

      judge == nil ->
        fallback(state, envelope, thr)

      not judge_gate_open?(state, envelope, thr) ->
        {false, "gate-closed"}

      true ->
        verdict =
          try do
            judge.(State.recent_digest(state, 24, envelope))
          rescue
            _ -> nil
          end

        read_verdict(verdict, thr)
    end
  end

  @doc """
  The hard backstop, checked before any judge: far past the envelope (or past the
  learned `backstop_turns`) and stuck by `stuck?/2`. `{true, reason}` or nil.
  """
  def backstop(state, envelope, thr) do
    turns =
      case {thr["backstop_turns"], envelope} do
        {nil, nil} -> nil
        {nil, env} -> env * thr["backstop_mult"]
        {turns, _} -> turns
      end

    if turns != nil and state.turns >= turns and stuck?(state, thr),
      do:
        {true,
         "backstop:#{state.turns}>=#{fixed(turns, 0)}turns stagnation=#{fixed(State.stagnation(state), 2)}"}
  end

  @doc """
  Whether a wired judge is asked: on the free gate, or on a turn past the envelope
  unless `gate_over_envelope` is false (the plugin's, which leaves the gate to the
  trouble signs alone).
  """
  def judge_gate_open?(state, envelope, thr) do
    gate_for_judge(state, thr) or
      (envelope != nil and state.turns >= envelope and
         Map.get(thr, "gate_over_envelope", true) != false)
  end

  @doc """
  What a verdict decides: stuck at `judge_confidence` or more aborts, productive spares,
  and unsure spares too (only the backstop acts on the envelope alone). No verdict is
  a throttled judge.
  """
  def read_verdict(verdict, thr) when is_map(verdict) do
    conf = confidence(verdict["confidence"])

    cond do
      verdict["stuck"] == true and conf >= thr["judge_confidence"] ->
        {true,
         "judge-stuck@#{fixed(conf, 2)}:#{String.slice(to_string(verdict["reason"] || ""), 0, 60)}"}

      verdict["stuck"] == false ->
        {false, "judge-productive"}

      true ->
        {false, "judge-ambiguous-spared"}
    end
  end

  def read_verdict(_, _), do: {false, "judge-throttled"}

  defp fallback(state, envelope, thr) do
    cond do
      not stuck?(state, thr) ->
        {false, "not-stuck"}

      envelope != nil and state.turns >= envelope ->
        {true, "envelope:#{state.turns}>=#{fixed(envelope, 0)}"}

      true ->
        {false, "stuck-but-within-envelope"}
    end
  end

  @doc """
  The redirect: the agent's own repeated actions mirrored back at it. Nothing but a
  summary of what it already did, framed to redirect its effort, never to stop it.
  """
  def nudge_text(state) do
    busiest =
      case Enum.max_by(state.edit_counts, &elem(&1, 1), fn -> nil end) do
        nil -> "one file"
        {name, _} -> name
      end

    "Process check (automated): so far you've made " <>
      "#{state.edit_counts |> Map.values() |> Enum.sum()} edits across " <>
      "#{State.distinct_edit_files(state)} file(s) (most to `#{busiest}`) and run " <>
      "#{state.test_runs} verification(s), and the same failure has recurred " <>
      "#{state.repeated_fail_sigs} time(s) without the tests going green. This " <>
      "looks like a repetitive loop. Do NOT stop — instead step back and try a " <>
      "MATERIALLY DIFFERENT hypothesis: re-read the failing test's expectation, " <>
      "consider a different file or root cause than the ones you've been editing, " <>
      "and verify the new hypothesis directly before editing again."
  end

  @doc "A judge's confidence as a number, 0 for anything that is not one."
  def confidence(c) when is_number(c), do: c * 1.0

  def confidence(c) when is_binary(c) do
    case Float.parse(String.trim(c)) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  def confidence(_), do: 0.0

  @doc false
  def fixed(x, digits), do: :erlang.float_to_binary(x * 1.0, decimals: digits)
end
