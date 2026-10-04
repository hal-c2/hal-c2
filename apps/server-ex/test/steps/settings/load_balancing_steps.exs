defmodule HalC2.Steps.Settings.LoadBalancing do
  @moduledoc """
  Steps for `features/settings/load-balancing.feature`: what an MC reports of its
  machine (`server.getHostResources`) and where it starts a new thread
  (`hal-c2.placeThread`).

  The machines and their checkouts are the ones
  `HalC2.Steps.Threads.MovingBetweenMachines` builds. A machine's load is stood in
  for (`:host_resources`), since the peers all run on this one.
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias HalC2.Test.Machines
  alias HalC2.Test.Mc.World

  # The agent the new thread runs on.
  @instance "claudeAgent"
  @fake_claude Path.expand("../../support/fake_claude.py", __DIR__)
  @memory 16_000_000_000

  step "a client asks the MC for its host resources", context do
    {reply, context} = World.call(context, "server.getHostResources")
    Map.put(context, :reply, reply)
  end

  step "the MC answers with its CPU count, CPU use and free memory", context do
    assert {:ok, host} = context.reply
    assert host["cpuCount"] >= 1
    assert is_float(host["cpuUtilization"]) and host["cpuUtilization"] >= 0.0
    assert host["cpuUtilization"] <= 1.0
    assert host["availableMemoryBytes"] > 0
    assert host["availableMemoryBytes"] <= host["totalMemoryBytes"]
    context
  end

  # --- placing a new thread ------------------------------------------------------------

  step "load balancing is on", context do
    World.update_settings(context, %{"loadBalancingEnabled" => true})
  end

  step "{string} is busy and {string} is idle", %{args: [busy, idle]} = context do
    load(context, busy, 0.9, 0.2)
    load(context, idle, 0.1, 0.9)
  end

  step "both machines are equally idle", context do
    for {machine, _} <- context.machines, do: load(context, machine, 0.1, 0.9)
    context
  end

  step "{string} is somewhat busier than {string}", %{args: [busier, other]} = context do
    load(context, busier, 0.5, 0.9)
    load(context, other, 0.2, 0.9)
  end

  step "{string} is at 95% CPU", %{args: [machine]} = context do
    load(context, machine, 0.95, 0.9)
  end

  step "{string} has 5% of memory free", %{args: [machine]} = context do
    load(context, machine, 0.1, 0.05)
  end

  step "{string} is set to manual only", %{args: [machine]} = context do
    weigh(context, %{machine => 0})
  end

  step "the user prefers {string} and sets {string} to less often",
       %{args: [preferred, less]} = context do
    weigh(context, %{preferred => 100, less => 25})
  end

  step "{string} does not answer in time", %{args: [machine]} = context do
    # The machine stays in the cluster and says nothing: its MC is paused.
    pid = to_string(Machines.on(context, machine, :os, :getpid, []))
    {_, 0} = System.cmd("kill", ["-STOP", pid])
    ExUnit.Callbacks.on_exit(fn -> System.cmd("kill", ["-CONT", pid]) end)
    context
  end

  step "{string} does not have the chosen provider signed in", %{args: [machine]} = context do
    Machines.on(context, machine, HalC2.ProviderUsageLimits, :remember_account, [
      @instance,
      %{"status" => "unauthenticated", "message" => "Run claude login."}
    ])

    Machines.on(context, machine, :sys, :get_state, [HalC2.ProviderUsageLimits])
    context
  end

  step "the user starts a new thread in {string} on {string}",
       %{args: [project, machine]} = context do
    # This machine has the agent as its peers do (`Machines` starts them with a stand-in),
    # whatever is installed where the scenarios run.
    World.put_app_env(:claude_command, ["python3", "-u", @fake_claude])

    picked = %{
      "environmentId" => environment(context, machine),
      "projectId" => context.checkouts[machine][project].id
    }

    {reply, context} =
      World.call(context, "hal-c2.placeThread", Map.put(picked, "instanceId", @instance))

    Map.merge(context, %{picked: picked, placed: reply})
  end

  step "the thread starts on {string}", %{args: [machine]} = context do
    assert context.picked["environmentId"] == environment(context, machine)
    assert context.placed == {:ok, context.picked}
    context
  end

  step "the thread starts on {string} in its checkout of {string}",
       %{args: [machine, project]} = context do
    assert context.placed ==
             {:ok,
              %{
                "environmentId" => environment(context, machine),
                "projectId" => context.checkouts[machine][project].id
              }}

    context
  end

  defp environment(context, machine) do
    case Machines.machine(context, machine) do
      :local -> context.mc.environment
      %{environment: environment} -> environment
    end
  end

  # What `machine` reports of itself: the share of its processors in use and of its
  # memory that is free.
  defp load(context, machine, cpu, free) do
    resources = %{
      "cpuCount" => 8,
      "cpuUtilization" => cpu,
      "totalMemoryBytes" => @memory,
      "availableMemoryBytes" => round(@memory * free)
    }

    case Machines.machine(context, machine) do
      :local ->
        World.put_app_env(:host_resources, resources)

      _peer ->
        Machines.on(context, machine, Application, :put_env, [:hal_c2, :host_resources, resources])
    end

    context
  end

  defp weigh(context, weights) do
    weights =
      Map.new(weights, fn {machine, weight} -> {environment(context, machine), weight} end)

    World.update_settings(context, %{"loadBalancingWeights" => weights})
  end
end
