defmodule HalC2.Acp.StoppedReadingTest do
  # Regression from the review of hal-c2/hal-c2#1351: a registry agent's write
  # failure (`HalC2.JsonRpc.Connection`'s `write_failed`) failed its calls with an
  # error the ACP runtime did not take as the agent's end, so the runtime kept the
  # connection instead of starting the agent afresh for the next message.
  use ExUnit.Case, async: false

  alias HalC2.Test.AcpFixtures, as: Acp
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @moduletag :tmp_dir

  test "an agent that stops reading its input is started afresh for the next message",
       %{tmp_dir: dir} do
    ctx =
      %{mc: Mc.start(dir), clients: %{}, projects: %{}, threads: %{}}
      |> World.create_project("shop")
      |> Acp.ready()
      |> Acp.publish()
      |> Acp.run_as("acme", "acme")

    Acp.add_registry_instance("acme", "acme")
    ctx = Acp.launch(ctx, "Acme", "acme", "stop reading")
    thread = ctx.threads["Acme"]
    assert [%{"status" => "completed"}] = Acp.await_runs(thread, 1)

    # The agent no longer reads, so this prompt's write fails and its turn with it.
    Acp.follow_up(ctx, "Acme", "hello")
    assert [_, %{"status" => "failed"}] = Acp.await_runs(thread, 2)

    errors =
      thread
      |> Acp.stream()
      |> HalC2.StreamState.list("provider-session")
      |> Enum.map(& &1["lastError"])

    assert Enum.any?(errors, &(&1 =~ "ACP stopped taking input"))

    [{runtime, _}] = Registry.lookup(HalC2.Acp.Registry, thread)
    assert :sys.get_state(runtime).conn == nil

    Acp.follow_up(ctx, "Acme", "hello")
    assert [_, _, %{"status" => "completed"}] = Acp.await_runs(thread, 3)
    assert length(Acp.launches(ctx, "acme")) == 2
  end
end
