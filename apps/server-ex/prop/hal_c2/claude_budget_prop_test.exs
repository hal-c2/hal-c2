defmodule HalC2.ClaudeBudgetPropTest do
  @moduledoc """
  `HalC2.Claude.Budget` against a simulated sandboxed Claude CLI (#1412): main
  conversation messages counted as they start and again as they end, subagent messages
  that carry only their starting counts with or without a progress after them, side
  requests no message reports, results carrying the process's own running count, and
  restarts, fresh or resuming a session from a partly restored count, as the CLI was
  seen to restore one.

  What the budget is told, each key's latest count added up, never exceeds what the
  CLI really spent and never goes down. After each result it is all of it but what an
  ended CLI spent after its last result, which no count reports, until a resumed
  session hides where its count began.
  """

  use ExUnit.Case, async: true
  use PropCheck

  alias HalC2.Claude.Budget

  defp tokens, do: range(0, 50)

  defp event do
    frequency([
      {4, {:main, tokens(), tokens()}},
      {4, {:sub, oneof(["toolu-a", "toolu-b"]), tokens(), tokens(), boolean()}},
      {1, {:side, tokens()}},
      {3, :result},
      {1, {:restart, boolean(), range(0, 100)}}
    ])
  end

  property "the budget is told no more than was spent, never less over time, and all of it at each result",
    numtests: HalC2.Prop.numtests(300),
    max_size: 40 do
    forall events <- list(event()) do
      start = %{
        budget: Budget.new(false),
        cli: 0,
        real: 0,
        told: %{},
        seen: 0,
        resumed: false,
        lost: 0,
        next: 0,
        ok: true
      }

      final = Enum.reduce(events, start, &step/2)

      when_fail(final.ok, IO.inspect(final, label: "end"))
    end
  end

  defp step(_event, %{ok: false} = sim), do: sim

  defp step({:main, input, output}, sim) do
    {id, sim} = id(sim)
    started = %{"input_tokens" => input, "output_tokens" => min(output, 1)}
    {budget, counts} = Budget.message(sim.budget, id, started)
    sim = tell(%{sim | budget: budget}, counts)
    {budget, counts} = Budget.message(sim.budget, id, %{started | "output_tokens" => output})
    %{sim | budget: budget} |> tell(counts) |> spend(input + output) |> holds(false)
  end

  defp step({:sub, parent, input, output, progress}, sim) do
    {id, sim} = id(sim)

    message = %{
      "type" => "assistant",
      "parent_tool_use_id" => parent,
      "message" => %{
        "id" => id,
        "usage" => %{"cache_read_input_tokens" => input, "output_tokens" => min(output, 2)}
      }
    }

    sim = sim |> observe(message) |> spend(input + output)

    sim =
      if progress,
        do:
          observe(sim, %{
            "type" => "system",
            "subtype" => "task_progress",
            "tool_use_id" => parent,
            "usage" => %{"total_tokens" => input + output}
          }),
        else: sim

    holds(sim, false)
  end

  defp step({:side, n}, sim), do: sim |> spend(n) |> holds(false)

  defp step(:result, sim) do
    half = div(sim.cli, 2)

    models = %{
      "claude-main" => %{"inputTokens" => half, "cacheReadInputTokens" => 0},
      "claude-side" => %{"outputTokens" => sim.cli - half}
    }

    sim |> observe(%{"type" => "result", "modelUsage" => models}) |> holds(true)
  end

  # A resumed CLI may restore part of what the session's earlier one counted.
  defp step({:restart, resume, percent}, sim) do
    cli = if resume, do: div(sim.cli * percent, 100), else: 0
    lost = sim.real - Enum.sum(Map.values(sim.told))

    %{sim | budget: Budget.new(resume), cli: cli, resumed: sim.resumed or resume, lost: lost}
    |> holds(false)
  end

  defp id(sim), do: {"msg-#{sim.next}", %{sim | next: sim.next + 1}}

  defp observe(sim, message) do
    {budget, counts} = Budget.observe(sim.budget, message)
    tell(%{sim | budget: budget}, counts)
  end

  defp tell(sim, counts),
    do: %{
      sim
      | told: Enum.reduce(counts, sim.told, fn {key, n}, told -> Map.put(told, key, n) end)
    }

  defp spend(sim, n), do: %{sim | real: sim.real + n, cli: sim.cli + n}

  defp holds(sim, result) do
    told = Enum.sum(Map.values(sim.told))
    exact = not result or sim.resumed or told == sim.real - sim.lost
    %{sim | seen: told, ok: told <= sim.real and told >= sim.seen and exact}
  end
end
