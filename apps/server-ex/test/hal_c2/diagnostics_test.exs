defmodule HalC2.DiagnosticsTest do
  use ExUnit.Case, async: true

  test "the MC's own processes are listed and can be signalled, but no others" do
    port = Port.open({:spawn_executable, "/bin/cat"}, [:binary])
    {:os_pid, pid} = Port.info(port, :os_pid)
    # Until the child execs, ps shows the kernel's placeholder name; an echo comes from
    # cat itself, so it has exec'd by then.
    Port.command(port, "ready\n")
    assert_receive {^port, {:data, "ready\n"}}, 10_000

    {:ok, %{"processes" => processes, "error" => %{"_tag" => "None"}}} =
      HalC2.Diagnostics.processes()

    assert [root | _] = processes
    assert root["depth"] == 0

    assert %{"startTimeMs" => started, "command" => "/bin/cat"} =
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

  test "process commands redact authorization and credential values" do
    secrets = ["live-bearer", "token-value", "password-value", "api-key-value"]

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        args: [
          "-c",
          ~s(while read line; do echo "$line"; done),
          ~s("Authorization":"Bearer live-bearer"),
          "--token=token-value",
          "--password=password-value",
          "--api-key=api-key-value"
        ]
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)
    Port.command(port, "ready\n")
    assert_receive {^port, {:data, "ready\n"}}, 10_000

    {:ok, %{"processes" => processes}} = HalC2.Diagnostics.processes()
    process = Enum.find(processes, &(&1["pid"] == pid))
    assert process["command"] =~ "Bearer [REDACTED]"
    assert process["command"] =~ "token=[REDACTED]"
    assert process["command"] =~ "password=[REDACTED]"
    assert process["command"] =~ "api-key=[REDACTED]"
    refute Enum.any?(secrets, &String.contains?(process["command"], &1))

    assert {:ok, %{"signaled" => true}} =
             HalC2.Diagnostics.signal(%{
               "pid" => pid,
               "startTimeMs" => process["startTimeMs"],
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

  test "a history request is held to a window of up to an hour and buckets of a second or more" do
    assert HalC2.Diagnostics.history_bounds(3 * 3_600_000, 60_000) == {3_600_000, 60_000}
    assert HalC2.Diagnostics.history_bounds(100, 100) == {1_000, 1_000}
    assert HalC2.Diagnostics.history_bounds(600_000, 3_600_000) == {600_000, 600_000}
    assert HalC2.Diagnostics.history_bounds(600_000, 10) == {600_000, 1_000}
  end

  test "a counter adds what it moved, but not backwards or across a long gap" do
    assert HalC2.Diagnostics.counter_delta(100, 160, 5_000) == 60
    assert HalC2.Diagnostics.counter_delta(160, 100, 5_000) == 0
    assert HalC2.Diagnostics.counter_delta(100, 160, 90_000) == 0
  end
end
