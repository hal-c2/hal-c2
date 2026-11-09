defmodule HalC2.SubprocessUpgradeTest do
  # Loads other versions of a module the whole VM shares, so it runs alone.
  use ExUnit.Case, async: false

  alias HalC2.Subprocess

  # A module keeps one old version, so a load must purge the one before it, and a
  # soft purge refuses while a process still runs it: what a release install checks.
  defp load(mod) do
    {^mod, beam, file} = :code.get_object_code(mod)
    assert :code.soft_purge(mod), "a process still runs #{inspect(mod)}'s old code"
    {:module, ^mod} = :code.load_binary(mod, file, beam)
  end

  # The readers of a quiet program wait for its output for as long as it is quiet. They
  # used to wait in this module's code, so the second update after they began refused
  # to load it (`{:old_processes, HalC2.Subprocess}`).
  test "readers waiting on a quiet program let the module load again and again" do
    {:ok, sub} = Subprocess.start(["cat"], stderr_tail: true)
    Subprocess.write_line(sub, "before")
    assert_receive {:subprocess_lines, reader, ["before"]}
    Subprocess.ack(sub)

    for _ <- 1..3, do: load(Subprocess)

    refute :erlang.check_process_code(reader, Subprocess)
    refute :erlang.check_process_code(sub.errors, Subprocess)

    Subprocess.write_line(sub, "after")
    assert_receive {:subprocess_lines, ^reader, ["after"]}
    Subprocess.ack(sub)
    assert {:ok, 0} = Subprocess.stop(sub)
  after
    :code.soft_purge(Subprocess)
  end
end
