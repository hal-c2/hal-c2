# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: The TokenEconomizer authors (microsoft/TokenEconomizer); HAL-C2 contributors
# Ported in part from tokeneconomizer/microskills/lifecycle.py
# (microsoft/TokenEconomizer@cb42207e3e09). Changed: a struct and pure functions
# instead of a mutable class; the edited-file readers live in MicroSkills.Observe.
# Evidence is aggregated -- counts and decayed score sums, with edited-file
# sets kept only for a drifting candidate's promotion -- where upstream keeps
# every confirmation forever: the same score, in bounded space.

defmodule HalC2Plugins.TokenEconomizer.MicroSkills.Lifecycle do
  @moduledoc """
  The lifecycle every learned fact goes through, whoever proposed it.

  A fact is a candidate until it is confirmed on `k_promote` tasks -- tasks that
  edited different files, for a fact about the code (`drift: true`); any
  `k_promote` tasks for a fact about the environment (`drift: false`). It is then
  active until a recency-weighted score, with contradictions weighted `lambda`
  times a confirmation, falls below the floor -- or at once, for a high-stakes
  fact, on one clean contradiction. An active fact is staged only while it clears
  the firing gate: the waste it prevents occurred (or, once staged, kept being
  prevented) on at least `fire_gate` of the tasks that exercised it, measured
  over at least `fire_min_n` of them.

  The numbers are upstream's validated replay constants, unchanged. Whoever
  proposes a fact -- today the environment-fact families in
  `MicroSkills.EnvFacts`, later the distiller -- puts it through this same
  lifecycle: promotion, retirement and the firing gate are not per-proposer.
  """

  @k_promote 3
  @gamma 0.8
  @lambda 5.0
  @score_floor 0.0
  @hard_kill true
  @fire_gate 0.40
  @fire_min_n 4

  defstruct key: nil,
            high: false,
            drift: true,
            state: "CANDIDATE",
            # A drifting candidate's kept confirmations ([{task, [file]}],
            # pairwise disjoint, at most k_promote of them); dropped at
            # promotion, and never kept at all without drift.
            confirms: [],
            confirm_count: 0,
            contra_count: 0,
            # The drifted count frozen at promotion, for a drifting fact.
            drifted: nil,
            # The score's two sums, decayed to `scored_at`.
            confirm_score: 0.0,
            contra_score: 0.0,
            scored_at: nil,
            fire_num: 0,
            fire_den: 0,
            promoted_at: nil,
            retired_at: nil

  @doc "Confirmations (drifted, where drift applies) to promote to active."
  def k_promote, do: @k_promote
  @doc "Recency decay per task-ago."
  def gamma, do: @gamma
  @doc "Contradiction weight (asymmetry: fail toward retirement)."
  def lambda, do: @lambda
  @doc "An active fact retires when its recency score falls below this."
  def score_floor, do: @score_floor
  @doc "Whether one clean contradiction retires a high-stakes active fact at once."
  def hard_kill, do: @hard_kill
  @doc "Staged only if its firing rate is at least this."
  def fire_gate, do: @fire_gate
  @doc "The firing rate is measured over at least this many exercised tasks."
  def fire_min_n, do: @fire_min_n

  def new(key, high, drift \\ true), do: %__MODULE__{key: key, high: high, drift: drift}

  @doc """
  How many of the confirmations count toward promotion: all of them without
  drift; with drift, the confirmations kept for editing files none of the
  earlier kept ones edited (a confirmation that edited nothing always
  counts), in the order they came -- frozen once the fact is promoted, when
  the file sets themselves are dropped.
  """
  def drifted_confirms(%__MODULE__{drift: false} = life), do: life.confirm_count
  def drifted_confirms(%__MODULE__{drifted: drifted}) when is_integer(drifted), do: drifted
  def drifted_confirms(%__MODULE__{} = life), do: length(life.confirms)

  @doc "How many tasks have contradicted the fact."
  def contradictions(%__MODULE__{} = life), do: life.contra_count

  @doc "The recency-weighted score at task `now`: confirmations less weighted contradictions."
  def score(%__MODULE__{scored_at: nil}, _now), do: 0.0

  def score(%__MODULE__{} = life, now) do
    decayed = @gamma ** (now - life.scored_at)
    (life.confirm_score - @lambda * life.contra_score) * decayed
  end

  # Brings the stored sums to `now`: the same score, folded forward.
  defp decay(%__MODULE__{scored_at: nil} = life, now), do: %{life | scored_at: now}

  defp decay(%__MODULE__{} = life, now) do
    factor = @gamma ** (now - life.scored_at)

    %{
      life
      | confirm_score: life.confirm_score * factor,
        contra_score: life.contra_score * factor,
        scored_at: now
    }
  end

  def firing_rate(%__MODULE__{fire_den: 0}), do: 0.0
  def firing_rate(%__MODULE__{} = life), do: life.fire_num / life.fire_den

  @doc "Active and clearing the firing gate: the fact may be staged."
  def injectable?(%__MODULE__{} = life) do
    life.state == "ACTIVE" and life.fire_den >= @fire_min_n and
      firing_rate(life) >= @fire_gate
  end

  @doc """
  Folds one task's verdict in: `"confirm"`, `"contradict"` or nil, whether the
  waste the fact prevents fired, whether the task exercised the fact at all, and
  the files the task edited. Promotion and retirement happen here, and only
  here; a retired fact never comes back through evidence.
  """
  def update(%__MODULE__{} = life, now, verdict, fired, exercised, files) do
    life = decay(life, now)

    life =
      if exercised do
        life
        |> Map.update!(:fire_den, &(&1 + 1))
        |> then(&if(fired, do: Map.update!(&1, :fire_num, fn n -> n + 1 end), else: &1))
      else
        life
      end

    life =
      case verdict do
        "confirm" ->
          life = %{
            life
            | confirm_count: life.confirm_count + 1,
              confirm_score: life.confirm_score + 1.0
          }

          if life.drift and life.state == "CANDIDATE",
            do: keep(life, now, files),
            else: life

        "contradict" ->
          %{life | contra_count: life.contra_count + 1, contra_score: life.contra_score + 1.0}

        _ ->
          life
      end

    case life.state do
      "CANDIDATE" ->
        if drifted_confirms(life) >= @k_promote do
          %{
            life
            | state: "ACTIVE",
              promoted_at: now,
              drifted: if(life.drift, do: drifted_confirms(life)),
              confirms: []
          }
        else
          life
        end

      "ACTIVE" ->
        hard = life.high and verdict == "contradict" and @hard_kill

        if hard or score(life, now) < @score_floor,
          do: %{life | state: "RETIRED", retired_at: now},
          else: life

      _ ->
        life
    end
  end

  # A drifting candidate keeps a confirmation only when it edited files none
  # of the kept ones did (or none at all): at most `k_promote` sets, ever.
  defp keep(%__MODULE__{} = life, now, files) do
    files = Enum.sort(files)
    set = MapSet.new(files)

    if MapSet.size(set) == 0 or
         Enum.all?(life.confirms, fn {_idx, other} -> MapSet.disjoint?(set, MapSet.new(other)) end) do
      %{life | confirms: life.confirms ++ [{now, files}]}
    else
      life
    end
  end

  # --- persistence (JSON-shaped maps, as upstream's `to_dict`) -------------------

  def dump(%__MODULE__{} = life) do
    %{
      "key" => life.key,
      "high" => life.high,
      "drift" => life.drift,
      "state" => life.state,
      "confirms" => Enum.map(life.confirms, fn {idx, files} -> [idx, files] end),
      "confirm_count" => life.confirm_count,
      "contra_count" => life.contra_count,
      "drifted" => life.drifted,
      "confirm_score" => life.confirm_score,
      "contra_score" => life.contra_score,
      "scored_at" => life.scored_at,
      "fire_num" => life.fire_num,
      "fire_den" => life.fire_den,
      "promoted_at" => life.promoted_at,
      "retired_at" => life.retired_at
    }
  end

  def load(%{} = saved) do
    life = %__MODULE__{
      key: saved["key"],
      high: saved["high"] == true,
      drift: saved["drift"] != false,
      state: saved["state"] || "CANDIDATE",
      fire_num: saved["fire_num"] || 0,
      fire_den: saved["fire_den"] || 0,
      promoted_at: saved["promoted_at"],
      retired_at: saved["retired_at"]
    }

    if Map.has_key?(saved, "scored_at") do
      %{
        life
        | confirms:
            Enum.map(saved["confirms"] || [], fn [idx, files] -> {idx, List.wrap(files)} end),
          confirm_count: saved["confirm_count"] || 0,
          contra_count: saved["contra_count"] || 0,
          drifted: saved["drifted"],
          confirm_score: saved["confirm_score"] || 0.0,
          contra_score: saved["contra_score"] || 0.0,
          scored_at: saved["scored_at"]
      }
    else
      aggregate_legacy(life, saved)
    end
  end

  # A state saved before aggregation kept every confirmation: fold it into
  # counts and decayed sums once, keeping only a drifting candidate's sets.
  defp aggregate_legacy(%__MODULE__{} = life, saved) do
    confirms =
      Enum.map(saved["confirms"] || [], fn [idx, files] -> {idx, List.wrap(files)} end)

    contradicts = saved["contradicts"] || []
    indices = Enum.map(confirms, &elem(&1, 0)) ++ contradicts
    base = if indices == [], do: nil, else: Enum.max(indices)

    sum = fn pairs ->
      Enum.sum_by(pairs, fn i -> @gamma ** (base - i) end)
    end

    kept =
      if life.drift do
        {kept, _sets} =
          Enum.reduce(confirms, {[], []}, fn {_idx, files} = entry, {kept, sets} ->
            set = MapSet.new(files)

            if MapSet.size(set) == 0 or Enum.all?(sets, &MapSet.disjoint?(set, &1)),
              do: {kept ++ [entry], sets ++ [set]},
              else: {kept, sets}
          end)

        kept
      else
        []
      end

    %{
      life
      | confirms: if(life.state == "CANDIDATE", do: kept, else: []),
        confirm_count: length(confirms),
        contra_count: length(contradicts),
        drifted: if(life.drift and life.state != "CANDIDATE", do: length(kept)),
        confirm_score: sum.(Enum.map(confirms, &elem(&1, 0))),
        contra_score: sum.(contradicts),
        scored_at: base
    }
  end
end
