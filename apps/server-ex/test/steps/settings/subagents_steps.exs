defmodule HalC2.Steps.Settings.Subagents do
  @moduledoc """
  Steps for `features/settings/subagents.feature`: the `nativeSubagents` setting as the
  MC reads it, and what the agents' instructions say about it. The adapters' use of it
  is in the Claude and Codex steps.
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @stored %{
    "the provider's own" => %{"nativeSubagents" => "provider"},
    "HAL-C2 workers" => %{"nativeSubagents" => "hal-c2"},
    "not set" => %{}
  }

  step ~r/^the subagents setting is (?<stored>not set|the provider's own|HAL-C2 workers)$/,
       %{args: [stored]} = context do
    Mc.ensure(HalC2.Settings)
    World.update_settings(context, @stored[stored])
  end

  step ~r/^agents (?<must>must|need not) use HAL-C2 workers instead of their provider's subagents$/,
       %{args: [must]} = context do
    assert HalC2.Settings.hal_c2_subagents?() == (must == "must")
    context
  end

  # An agent that can delegate is one given HAL-C2's MCP server (any non-nil `for_agent/2`).
  step "the instructions given to agents end by telling them to delegate with {string}",
       %{args: [tool]} = context do
    assert HalC2.Mcp.instructions(HalC2.Mcp.workers_only?(%{})) =~
             ~r/built-in subagents\. Delegate child work with `#{tool}`/

    context
  end

  step "the instructions given to agents do not tell them to delegate with {string} instead",
       %{args: [_tool]} = context do
    refute HalC2.Mcp.instructions(HalC2.Mcp.workers_only?(%{})) =~
             "The user keeps agents to HAL-C2's workers"

    context
  end
end
