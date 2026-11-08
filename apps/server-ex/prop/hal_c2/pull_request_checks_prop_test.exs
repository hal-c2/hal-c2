defmodule HalC2.PullRequestChecksPropTest do
  @moduledoc """
  The laws of `HalC2.PullRequests.GitHub.checks/1`
  (`features/source-control/pull-request-review.feature`): one entry per check
  rather than per run of it, in the order each check first appeared; a run
  still going makes its check pending however an earlier run ended; and with
  every run finished, the newest wins, however its time is spelled. The
  function is pure, so these are plain `forall`s.
  """

  use ExUnit.Case, async: true
  use PropCheck

  alias HalC2.PullRequests.GitHub

  # A small pool, so runs of one check collide: instants in the spellings a
  # host uses, `{spelling, rank}` with rank being their order in time.
  @instants [
    {"2026-10-16T12:00:00Z", 0},
    {"2026-10-16T12:00:00.500Z", 1},
    {"2026-10-16T13:00:00+00:00", 2},
    {"2026-10-16T13:00:01Z", 3}
  ]

  defp run do
    let {name, workflow, status, {at, rank}} <-
          {oneof(["build", "lint"]), oneof([nil, "CI", "Release"]),
           oneof(["COMPLETED", "IN_PROGRESS", "QUEUED"]), oneof(@instants)} do
      {name, workflow, status, at, rank}
    end
  end

  # A run as `checks/1` is given it, with the conclusion that makes its state
  # unambiguous: success at even ranks, failure at odd ones, so the model can
  # name the survivor by rank.
  defp raw({name, workflow, status, at, rank}) do
    base = %{"name" => name, "status" => status, "completedAt" => at}

    base =
      if status == "COMPLETED",
        do: Map.put(base, "conclusion", if(rem(rank, 2) == 0, do: "SUCCESS", else: "FAILURE")),
        else: base

    if workflow, do: Map.put(base, "workflowName", workflow), else: base
  end

  defp key({name, workflow, _status, _at, _rank}), do: {workflow, name}

  # The state the law gives one check's runs: pending while any run is going,
  # else the newest finished run's, by rank.
  defp expected(runs) do
    if Enum.any?(runs, fn {_n, _w, status, _at, _r} -> status != "COMPLETED" end) do
      "pending"
    else
      {_n, _w, _s, _at, rank} = Enum.max_by(runs, &elem(&1, 4))
      if rem(rank, 2) == 0, do: "success", else: "failure"
    end
  end

  # The name a check is listed under: `workflow / name` only where the bare
  # name is shared with a check of another workflow.
  defp listed(runs) do
    keys = Enum.uniq_by(runs, &key/1)

    Map.new(keys, fn {name, workflow, _s, _at, _r} = run ->
      shared = Enum.count(keys, fn {n, _w, _s2, _a, _r2} -> n == name end) > 1
      shown = if workflow && shared, do: "#{workflow} / #{name}", else: name
      {key(run), shown}
    end)
  end

  property "checks are one per check, first seen first, pending or newest winning",
    numtests: HalC2.Prop.numtests(200),
    max_size: 20 do
    forall runs <- resize(12, list(run())) do
      out = GitHub.checks(Enum.map(runs, &raw/1))
      names = listed(runs)
      by_key = Enum.group_by(runs, &key/1)
      first_seen = runs |> Enum.uniq_by(&key/1) |> Enum.map(&key/1)

      # One entry per check, in first-appearance order, with the lawful state.
      Enum.map(out, & &1["name"]) == Enum.map(first_seen, &names[&1]) and
        Enum.all?(out, fn check ->
          key = Enum.find(first_seen, &(names[&1] == check["name"]))
          check["status"] == expected(by_key[key])
        end)
    end
  end
end
