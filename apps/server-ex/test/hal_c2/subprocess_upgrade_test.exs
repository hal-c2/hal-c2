defmodule HalC2.SubprocessUpgradeTest do
  use ExUnit.Case, async: true

  # The readers of a quiet program wait for its output for as long as it is quiet. They
  # used to wait in `HalC2.Subprocess`'s code, so the second load after they began
  # refused to purge it (`{:old_processes, HalC2.Subprocess}`). A purge is VM-wide, so
  # this runs on a VM of its own (`HalC2.Test.UpgradeProbe`).
  test "readers waiting on a quiet program let the module load again and again" do
    # Linked: it stops with the test.
    {:ok, peer, _node} =
      :peer.start_link(%{
        connection: :standard_io,
        args: Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
      })

    assert %{before: ["before"], after: ["after"], stop: {:ok, 0}, loads: loads} =
             :peer.call(peer, HalC2.Test.UpgradeProbe, :run, [], 30_000)

    # Each load purges the one before; no reader is left on the old code.
    assert loads == List.duplicate({true, []}, 3)
  end
end
