defmodule HalC2.Diagnostics.AttributionTest do
  # The table is named, so these run one at a time.
  use ExUnit.Case, async: false

  alias HalC2.Diagnostics.Attribution

  setup do
    # Owned by the test process when no `HalC2.Diagnostics` runs, so it goes with it.
    if :ets.whereis(Attribution) == :undefined do
      Attribution.create()
    else
      :ets.delete_all_objects(Attribution)
    end

    :ok
  end

  test "totals each operation and lists the most written first" do
    Attribution.record("server-trace", "append", write: 10, duration_ms: 2)
    Attribution.record("server-trace", "append", write: 5, duration_ms: 1)
    Attribution.record("provider-event-log", "native.append", write: 40)
    Attribution.record("checkpoint", "read", read: 7, count: 3)

    assert [
             %{"component" => "provider-event-log", "logicalWriteBytes" => 40, "count" => 1},
             %{
               "component" => "server-trace",
               "operation" => "append",
               "logicalReadBytes" => 0,
               "logicalWriteBytes" => 15,
               "count" => 2,
               "durationMs" => 3
             },
             %{"component" => "checkpoint", "logicalReadBytes" => 7, "count" => 3}
           ] = Attribution.entries()
  end

  test "negative and missing measures do not subtract" do
    Attribution.record("server-trace", "append", write: -4, duration_ms: 1.6)

    assert [%{"logicalWriteBytes" => 0, "durationMs" => 2, "count" => 1}] =
             Attribution.entries()
  end

  test "write returns the writer's result" do
    assert Attribution.write("server-trace", "append", 3, fn -> :written end) == :written
    assert [%{"logicalWriteBytes" => 3}] = Attribution.entries()
  end
end
