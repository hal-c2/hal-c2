defmodule HalC2.Test.StopSignal do
  @moduledoc """
  A test run stopped by SIGTERM ends 143, not 0. The BEAM takes SIGTERM as a clean
  shutdown, so a run stopped part way (a `timeout`, or a memory-capped scope systemd
  stops once the kernel killed a process in it, as it did a Maude) left no summary
  and read as passed.
  """

  @doc "Called first in each test_helper.exs."
  def fail_run do
    {:ok, _} =
      System.trap_signal(:sigterm, fn ->
        IO.puts(:stderr, "\nStopped by SIGTERM before the run finished.")
        System.halt(143)
      end)

    :ok
  end
end
