defmodule T3.Steps.Settings.LoadBalancing do
  @moduledoc """
  What a node tells clients that balance new threads across machines:
  `server.getHostResources` (CPU count, CPU use and free memory).
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias T3.Test.Node.World

  step "a client asks the node for its host resources", context do
    {reply, context} = World.call(context, "server.getHostResources")
    Map.put(context, :reply, reply)
  end

  step "the node answers with its CPU count, CPU use and free memory", context do
    assert {:ok, host} = context.reply
    assert host["cpuCount"] >= 1
    assert is_float(host["cpuUtilization"]) and host["cpuUtilization"] >= 0.0
    assert host["cpuUtilization"] <= 1.0
    assert host["availableMemoryBytes"] > 0
    assert host["availableMemoryBytes"] <= host["totalMemoryBytes"]
    context
  end
end
