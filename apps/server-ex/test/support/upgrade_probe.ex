defmodule HalC2.Test.UpgradeProbe do
  @moduledoc """
  Loads `HalC2.Subprocess` again and again under readers waiting on a quiet program,
  on a VM of its own (`:peer`): a purge is VM-wide, and in the test VM any other
  test's process in one of the module's bounded waits refuses it.
  """

  alias HalC2.Subprocess

  # What each step saw, for the test on the other side to assert on.
  def run do
    {:ok, _} = Application.ensure_all_started(:exile)
    {:ok, sub} = Subprocess.start(["cat"], stderr_tail: true)
    Subprocess.write_line(sub, "before")
    before = lines(sub)

    loads =
      for _ <- 1..3 do
        purged = :code.soft_purge(Subprocess)
        if purged, do: {:module, Subprocess} = load(Subprocess)

        pinned =
          for pid <- [sub.reader, sub.errors],
              :erlang.check_process_code(pid, Subprocess),
              do: pid

        {purged, pinned}
      end

    Subprocess.write_line(sub, "after")
    later = lines(sub)

    %{before: before, loads: loads, after: later, stop: Subprocess.stop(sub)}
  end

  defp load(mod) do
    {^mod, beam, file} = :code.get_object_code(mod)
    :code.load_binary(mod, file, beam)
  end

  defp lines(sub) do
    receive do
      {:subprocess_lines, _reader, lines} ->
        Subprocess.ack(sub)
        lines
    after
      5_000 -> :timeout
    end
  end
end
