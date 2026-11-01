defmodule HalC2.Steps.Providers.InstanceProcess do
  @moduledoc """
  Steps for the scenarios that pin a driver's half of the contract in
  `HalC2.Plugins.Kinds`: a turn on another instance runs in a process of that instance.
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias HalC2.StreamState
  alias HalC2.Test.FakeAcp
  alias HalC2.Test.Mc.World

  # Sends `text` on `instance` and waits for its run to complete.
  defp turn_on(context, instance, text) do
    runs = length(StreamState.list(FakeAcp.await_runs(context, 1), "run"))
    selection = %{"modelSelection" => %{"instanceId" => instance, "model" => "fake/one"}}
    context = FakeAcp.send_message(context, text, nil, selection)
    state = FakeAcp.await_runs(context, runs + 1)
    assert Enum.all?(StreamState.list(state, "run"), &(&1["status"] == "completed"))
    context
  end

  # The processes of `instance` that served the thread: those in the project, not the
  # throwaway ones that read its version and models.
  defp serving(context, instance) do
    root = World.project(context).root

    Enum.filter(
      FakeAcp.starts(context, instance),
      &(&1["cwd"] == root and
          Enum.all?(~w(--no-session --disable-write), fn flag -> flag not in &1["argv"] end))
    )
  end

  defp heard?(context, instance, text) do
    Enum.any?(FakeAcp.log(context, instance), fn line ->
      is_map(line["recv"]) and JSON.encode!(line["recv"]) =~ text
    end)
  end

  step "a second instance {string} of it with a binary of its own", %{args: [id]} = context do
    FakeAcp.add_instance(context, id)
  end

  step "the next message goes to {string}", %{args: [id]} = context do
    turn_on(context, id, "over on the second instance")
  end

  step "a process of {string} runs that turn in place of the first instance's",
       %{args: [id]} = context do
    assert [%{"pid" => first}] = serving(context, context.provider)
    assert [%{"pid" => second}] = serving(context, id)
    assert heard?(context, id, "over on the second instance")
    refute heard?(context, context.provider, "over on the second instance")
    assert {_, status} = System.cmd("kill", ["-0", "#{first}"], stderr_to_stdout: true)
    refute status == 0
    Map.put(context, :second_process, second)
  end

  step "another message to {string} stays in that process", %{args: [id]} = context do
    context = turn_on(context, id, "still on the second instance")
    assert [%{"pid" => pid}] = serving(context, id)
    assert pid == context.second_process
    assert heard?(context, id, "still on the second instance")
    context
  end
end
