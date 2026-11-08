# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: The TokenEconomizer authors (microsoft/TokenEconomizer); HAL-C2 contributors
# Ported in part from tokeneconomizer/microskills/lifecycle.py
# (microsoft/TokenEconomizer@cb42207e3e09). Changed: a struct and pure functions
# instead of a mutable class; the edited-file readers live in MicroSkills.Observe.

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
            # [{task index, [edited file]}]
            confirms: [],
            # [task index]
            contradicts: [],
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
  drift; with drift, a greedy set whose edited files are pairwise disjoint (a
  confirmation that edited nothing always counts), in the order they came.
  """
  def drifted_confirms(%__MODULE__{drift: false, confirms: confirms}), do: length(confirms)

  def drifted_confirms(%__MODULE__{confirms: confirms}) do
    kept =
      Enum.reduce(confirms, [], fn {idx, files}, kept ->
        files = MapSet.new(files)

        if MapSet.size(files) == 0 or
             Enum.all?(kept, fn {_idx, other} -> MapSet.disjoint?(files, other) end) do
          [{idx, files} | kept]
        else
          kept
        end
      end)

    length(kept)
  end

  @doc "The recency-weighted score at task `now`: confirmations less weighted contradictions."
  def score(%__MODULE__{} = life, now) do
    confirmed = Enum.sum_by(life.confirms, fn {i, _files} -> @gamma ** (now - i) end)
    contradicted = Enum.sum_by(life.contradicts, fn i -> @gamma ** (now - i) end)
    confirmed - @lambda * contradicted
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
        "confirm" -> %{life | confirms: life.confirms ++ [{now, Enum.sort(files)}]}
        "contradict" -> %{life | contradicts: life.contradicts ++ [now]}
        _ -> life
      end

    case life.state do
      "CANDIDATE" ->
        if drifted_confirms(life) >= @k_promote,
          do: %{life | state: "ACTIVE", promoted_at: now},
          else: life

      "ACTIVE" ->
        hard = life.high and verdict == "contradict" and @hard_kill

        if hard or score(life, now) < @score_floor,
          do: %{life | state: "RETIRED", retired_at: now},
          else: life

      _ ->
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
      "contradicts" => life.contradicts,
      "fire_num" => life.fire_num,
      "fire_den" => life.fire_den,
      "promoted_at" => life.promoted_at,
      "retired_at" => life.retired_at
    }
  end

  def load(%{} = saved) do
    %__MODULE__{
      key: saved["key"],
      high: saved["high"] == true,
      drift: saved["drift"] != false,
      state: saved["state"] || "CANDIDATE",
      confirms: Enum.map(saved["confirms"] || [], fn [idx, files] -> {idx, List.wrap(files)} end),
      contradicts: saved["contradicts"] || [],
      fire_num: saved["fire_num"] || 0,
      fire_den: saved["fire_den"] || 0,
      promoted_at: saved["promoted_at"],
      retired_at: saved["retired_at"]
    }
  end
end
