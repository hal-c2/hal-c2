defmodule HalC2.Steps.Settings.ResourceTelemetry do
  @moduledoc """
  The resource monitor on a node: the `resourceTelemetry` socket shape streams a
  snapshot after every sample (every 2s while watched, 15s otherwise), and the
  sampler keeps an hour of samples (`HalC2.Diagnostics`).
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias HalC2.Test.Node
  alias HalC2.Test.Node.World

  @hour 60 * 60_000

  step "the user watches the resource monitor", context do
    Node.ensure(HalC2.Diagnostics)

    client =
      context
      |> World.client("monitor")
      |> Node.sub(1, %{"type" => "resourceTelemetry", "node" => Atom.to_string(node())})

    {%{"snapshot" => snapshot}, client} = Node.await(client, &(&1["t"] == "resourceTelemetry"))
    context |> World.put_client("monitor", client) |> Map.put(:snapshot, snapshot)
  end

  step "a fresh snapshot of the process tree arrives every few seconds", context do
    assert context.snapshot["sampleIntervalMs"] == 2_000

    {%{"snapshot" => next}, client} =
      Node.await(World.client(context, "monitor"), &(&1["t"] == "resourceTelemetry"), 3_000)

    assert next["readAt"] > context.snapshot["readAt"]
    assert [%{"category" => "server", "depth" => 0} | _] = next["processes"]
    World.put_client(context, "monitor", client)
  end

  step "no client watches the resource monitor", context do
    Node.ensure(HalC2.Diagnostics)
    assert :sys.get_state(HalC2.Diagnostics).watchers == %{}
    context
  end

  step "the node samples every 15 seconds", context do
    {{:ok, history}, context} = history(context, @hour)
    assert history["sampleIntervalMs"] == 15_000
    context
  end

  # Samples an hour and more old are dropped when the next sample is taken.
  step "it keeps at most one hour of samples", context do
    {{:ok, %{"retainedSampleCount" => before}}, context} = history(context, 3 * @hour)
    World.add_resource_samples([@hour - 60_000, @hour + 60_000, 2 * @hour])
    {{:ok, _}, context} = World.call(context, "server.retryResourceTelemetry")

    {{:ok, %{"retainedSampleCount" => after_retry, "buckets" => buckets}}, context} =
      history(context, 3 * @hour)

    assert after_retry == before + 2
    oldest = System.system_time(:millisecond) - @hour - 60_000

    for bucket <- buckets do
      {:ok, ended, _} = DateTime.from_iso8601(bucket["endedAt"])
      assert DateTime.to_unix(ended, :millisecond) >= oldest
    end

    context
  end

  step "the user retries the resource monitor", context do
    Node.ensure(HalC2.Diagnostics)
    asked = DateTime.utc_now() |> DateTime.truncate(:millisecond)
    {reply, context} = World.call(context, "server.retryResourceTelemetry")
    Map.merge(context, %{reply: reply, asked: asked})
  end

  step "a new snapshot is taken immediately", context do
    assert {:ok, %{"accepted" => true, "snapshot" => snapshot}} = context.reply
    {:ok, read, _} = DateTime.from_iso8601(snapshot["readAt"])
    assert DateTime.compare(read, context.asked) != :lt
    assert snapshot["processes"] != []
    context
  end

  step ~r/^host power state and application I\/O are shown as unavailable$/, context do
    snapshot = context.snapshot
    assert %{"source" => "unknown", "onBattery" => "unknown", "stale" => true} = snapshot["power"]
    assert snapshot["health"]["desktop"]["status"] == "unavailable"
    assert snapshot["processes"] != []
    # Application I/O is the instrumented, per-operation attribution. The storage
    # counters each process reports from /proc/<pid>/io are separate
    # (node/platform/diagnostics.feature, "The node reports per-process I/O").
    assert snapshot["attribution"]["entries"] == []
    context
  end

  defp history(context, window) do
    World.call(context, "server.getResourceTelemetryHistory", %{
      "windowMs" => window,
      "bucketMs" => 60_000
    })
  end
end
