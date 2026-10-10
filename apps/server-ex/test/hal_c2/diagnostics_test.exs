defmodule HalC2.DiagnosticsTest do
  use ExUnit.Case, async: true

  test "the MC's own processes are listed and can be signalled, but no others" do
    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["30"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    {:ok, %{"processes" => processes, "error" => %{"_tag" => "None"}}} =
      HalC2.Diagnostics.processes()

    assert [root | _] = processes
    assert root["depth"] == 0

    assert %{"startTimeMs" => started, "command" => "/bin/sleep 30"} =
             Enum.find(processes, &(&1["pid"] == pid))

    # Not the process that was seen: it restarted, or never was ours.
    assert {:ok, %{"signaled" => false}} =
             HalC2.Diagnostics.signal(%{
               "pid" => pid,
               "startTimeMs" => started - 60_000,
               "signal" => "SIGKILL"
             })

    assert {:ok, %{"signaled" => false}} =
             HalC2.Diagnostics.signal(%{"pid" => 1, "startTimeMs" => 0, "signal" => "SIGKILL"})

    assert {:ok, %{"signaled" => true}} =
             HalC2.Diagnostics.signal(%{
               "pid" => pid,
               "startTimeMs" => started,
               "signal" => "SIGKILL"
             })
  end

  test "the sampler's own ps is not listed as one of the MC's processes" do
    {:ok, %{"processes" => processes}} = HalC2.Diagnostics.processes()
    refute Enum.any?(processes, &String.contains?(&1["command"], " -axo pid="))
  end

  test "host memory is read" do
    assert {:ok, %{"totalMemoryBytes" => total, "availableMemoryBytes" => available}} =
             HalC2.Diagnostics.host()

    assert total > 0 and available > 0 and available <= total
  end
end
