defmodule HalC2.SubprocessDurableTest do
  use ExUnit.Case, async: false

  alias HalC2.Subprocess
  alias HalC2.Subprocess.Durable

  @moduletag :tmp_dir
  @echo ["sh", "-c", ~s(while read l; do echo "got $l"; done)]

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:hal_c2, :home)
    Application.put_env(:hal_c2, :home, dir)
    Application.put_env(:hal_c2, :durable_programs, true)

    on_exit(fn ->
      Application.put_env(:hal_c2, :home, previous)
      Application.put_env(:hal_c2, :durable_programs, false)
    end)

    {:ok, home: dir}
  end

  defp lines(sub, count, acc \\ [], offset \\ 0)
  defp lines(_sub, 0, acc, offset), do: {Enum.reverse(acc), offset}

  defp lines(sub, count, acc, offset) do
    receive do
      {:subprocess_lines, _, new} ->
        Subprocess.ack(sub)
        lines(sub, count - length(new), Enum.reverse(new) ++ acc, offset)

      {:subprocess_offset, _, offset} ->
        lines(sub, count, acc, offset)
    after
      5_000 -> flunk("got #{inspect(acc)}, #{count} more expected")
    end
  end

  # The offset message follows its lines.
  defp offset(fallback) do
    receive do
      {:subprocess_offset, _, offset} -> offset
    after
      200 -> fallback
    end
  end

  test "a program goes on after its VM is killed, and a later VM connects to it", %{home: home} do
    # A VM of its own, killed the way a crash kills one, with no chance to tidy up.
    script = """
    {:ok, _} = Application.ensure_all_started(:exile)
    Application.put_env(:hal_c2, :home, #{inspect(home)})
    Application.put_env(:hal_c2, :durable_programs, true)
    {:ok, sub} = HalC2.Subprocess.start(#{inspect(@echo)}, durable: "t1")
    HalC2.Subprocess.write_line(sub, "before")
    receive do {:subprocess_lines, _, _} -> :ok end
    offset = receive do {:subprocess_offset, _, offset} -> offset end
    IO.puts("ATTACHED \#{sub.durable.dir} \#{offset} \#{HalC2.Subprocess.os_pid(sub)}")
    HalC2.Subprocess.write_line(sub, "while dying")
    Process.sleep(200)
    System.cmd("kill", ["-KILL", System.pid()])
    """

    paths = Enum.flat_map(:code.get_path(), &["-pa", to_string(&1)])
    {out, status} = System.cmd("elixir", paths ++ ["-e", script], stderr_to_stdout: true)
    assert status != 0

    [_, dir, offset, pid] = Regex.run(~r/ATTACHED (\S+) (\d+) (\d+)/, out)
    assert Durable.attachable?(dir)

    {:ok, sub} = Subprocess.adopt(dir, String.to_integer(offset))
    assert Subprocess.os_pid(sub) == String.to_integer(pid)
    Subprocess.write_line(sub, "after")

    # Written with no MC reading, and what was sent to the new one.
    assert {["got while dying", "got after"], _} = lines(sub, 2)
    assert {:ok, _} = Subprocess.stop(sub)
    refute File.exists?(dir)
  end

  test "an unfinished line is read whole from where the last whole line ended" do
    {:ok, sub} =
      Subprocess.start(["sh", "-c", ~s(printf 'one\\ntw'; read l; printf 'o\\n'; read l)],
        durable: "t1"
      )

    assert {["one"], _} = lines(sub, 1)
    offset = offset(4)
    assert offset == 4
    dir = sub.durable.dir
    HalC2.Orchestration.Recovery.leaving(true)
    assert Subprocess.stop(sub) == :detached
    HalC2.Orchestration.Recovery.leaving(false)

    {:ok, sub} = Subprocess.adopt(dir, offset)
    Subprocess.write_line(sub, "go")
    assert {["two"], _} = lines(sub, 1)
    Subprocess.stop(sub)
  end

  test "the end of a program ends its output, with its status" do
    {:ok, sub} = Subprocess.start(["sh", "-c", "echo bye; exit 3"], durable: "t1")
    assert {["bye"], _} = lines(sub, 1)
    assert_receive {:subprocess_eof, _}, 5_000
    assert {:ok, 3} = Subprocess.stop(sub)
  end

  test "a stop ends a program, whose stdin never closes" do
    {:ok, sub} = Subprocess.start(@echo, durable: "t1")
    pid = Subprocess.os_pid(sub)
    Subprocess.stop(sub)
    refute Durable.attachable?(sub.durable.dir)
    assert HalC2.Subprocess.Orphans.gone?(pid)
  end
end
