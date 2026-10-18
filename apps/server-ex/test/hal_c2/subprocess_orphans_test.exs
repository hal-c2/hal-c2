defmodule HalC2.Subprocess.OrphansTest do
  # hal-c2/hal-c2#254: an MC that died left its provider CLIs running, and the next
  # turn resumed their sessions in second ones.
  use ExUnit.Case, async: false

  alias HalC2.Subprocess
  alias HalC2.Subprocess.Orphans

  @moduletag :tmp_dir

  # A stand-in provider: echoes its input. An MC that dies here only stops tracking
  # it, so its stdin stays open, as a provider CLI with work in flight carries on.
  @echo ~s(while read l; do echo "$l"; done)

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    :ok
  end

  # An MC that is gone: this VM's pid, but not its start time.
  defp dead_mc, do: %{"pid" => String.to_integer(System.pid()), "started" => "an earlier boot"}

  defp boot(id, opts \\ []),
    do: start_supervised!(Supervisor.child_spec({Orphans, opts}, id: id))

  defp alive!(sub) do
    :ok = Subprocess.write_line(sub, "ping")
    assert_receive {:subprocess_lines, reader, ["ping"]} when reader == sub.reader
    Subprocess.ack(sub)
  end

  test "the next boot kills a program an MC that died left running, and its background commands" do
    boot(:died, owner: dead_mc())
    # The background `sleep` keeps stdout open, so its end is seen as end of file too.
    {:ok, sub} = Subprocess.start(["sh", "-c", "sleep 60 & " <> @echo])
    alive!(sub)
    :ok = stop_supervised(:died)

    boot(:next)

    assert_receive {:subprocess_eof, reader} when reader == sub.reader, 5_000
    exit_ref = sub.proc.exit_ref
    assert_receive {^exit_ref, {:ok, 137}}
    assert File.ls!(Orphans.dir()) == []
  end

  test "a record a VM that died while writing it left is reaped when whole, dropped when not" do
    boot(:died, owner: dead_mc())
    {:ok, sub} = Subprocess.start(["sh", "-c", @echo])
    :ok = stop_supervised(:died)
    # Died after the write but before the rename, and mid-write of another record.
    [record] = File.ls!(Orphans.dir())
    path = Path.join(Orphans.dir(), record)
    File.rename!(path, path <> ".tmp")
    File.write!(Path.join(Orphans.dir(), "1-1.json.tmp"), ~s({"pid": 1))

    boot(:next)

    assert_receive {:subprocess_eof, reader} when reader == sub.reader, 5_000
    assert File.ls!(Orphans.dir()) == []
  end

  test "a record that is not one this MC writes is dropped, and the boot goes on" do
    {:ok, sub} = Subprocess.start(["sh", "-c", @echo])
    pid = Subprocess.os_pid(sub)
    File.mkdir_p!(Orphans.dir())
    mc = dead_mc()

    records = [
      %{"pid" => pid, "started" => Orphans.started(pid), "mc" => %{"pid" => mc["pid"]}},
      %{"pid" => pid, "started" => nil, "mc" => mc},
      %{"pid" => "#{pid}", "started" => Orphans.started(pid), "mc" => mc},
      %{"pid" => pid, "started" => Orphans.started(pid), "mc" => %{mc | "started" => 1}},
      %{"pid" => pid, "started" => Orphans.started(pid), "mc" => mc["pid"]},
      [pid],
      pid
    ]

    for {record, n} <- Enum.with_index(records),
        do: File.write!(Path.join(Orphans.dir(), "#{n}.json"), JSON.encode!(record))

    boot(:next)

    alive!(sub)
    assert File.ls!(Orphans.dir()) == []
    assert {:ok, 0} = Subprocess.stop(sub)
  end

  test "a boot with no kill to run keeps the record, and a later one kills the program" do
    boot(:died, owner: dead_mc())
    {:ok, sub} = Subprocess.start(["sh", "-c", @echo])
    :ok = stop_supervised(:died)
    path = System.get_env("PATH")
    System.put_env("PATH", Path.join(Orphans.dir(), "no-bin"))

    try do
      boot(:blind)
    after
      System.put_env("PATH", path)
    end

    alive!(sub)
    assert [_record] = File.ls!(Orphans.dir())
    :ok = stop_supervised(:blind)

    boot(:next)

    assert_receive {:subprocess_eof, reader} when reader == sub.reader, 5_000
    assert File.ls!(Orphans.dir()) == []
  end

  test "a record that cannot be read is kept, and a later boot kills its program" do
    boot(:died, owner: dead_mc())
    {:ok, sub} = Subprocess.start(["sh", "-c", @echo])
    :ok = stop_supervised(:died)
    [record] = File.ls!(Orphans.dir())
    path = Path.join(Orphans.dir(), record)
    File.chmod!(path, 0o000)

    boot(:blind)

    alive!(sub)
    assert File.ls!(Orphans.dir()) == [record]
    :ok = stop_supervised(:blind)
    File.chmod!(path, 0o600)

    boot(:next)

    assert_receive {:subprocess_eof, reader} when reader == sub.reader, 5_000
    assert File.ls!(Orphans.dir()) == []
  end

  test "records that cannot be listed are left for a later boot" do
    boot(:died, owner: dead_mc())
    {:ok, sub} = Subprocess.start(["sh", "-c", @echo])
    :ok = stop_supervised(:died)
    File.chmod!(Orphans.dir(), 0o300)
    on_exit(fn -> File.chmod(Orphans.dir(), 0o700) end)

    boot(:blind)

    alive!(sub)
    :ok = stop_supervised(:blind)
    File.chmod!(Orphans.dir(), 0o700)

    boot(:next)

    assert_receive {:subprocess_eof, reader} when reader == sub.reader, 5_000
    assert File.ls!(Orphans.dir()) == []
  end

  test "a file where the records go does not stop the boot" do
    File.mkdir_p!(Path.dirname(Orphans.dir()))
    File.write!(Orphans.dir(), "")

    boot(:next)

    assert {:error, {:untracked, :enotdir}} = Subprocess.start(["sh", "-c", @echo])
  end

  test "a program that leads no group is killed alone" do
    # The background `sleep` is in the shell's group, which a group kill would end; the
    # shell says how it ended, then carries on.
    script = ~s(sleep 60 & echo $!; wait $!; echo "ended $?"; ) <> @echo
    {:ok, sub} = Subprocess.start(["sh", "-c", script])
    assert_receive {:subprocess_lines, reader, [line]} when reader == sub.reader
    Subprocess.ack(sub)
    sleep = String.to_integer(line)
    File.mkdir_p!(Orphans.dir())

    File.write!(
      Path.join(Orphans.dir(), "#{sleep}-1.json"),
      JSON.encode!(%{"pid" => sleep, "started" => Orphans.started(sleep), "mc" => dead_mc()})
    )

    boot(:next)

    assert_receive {:subprocess_lines, reader, ["ended 137"]} when reader == sub.reader, 5_000
    Subprocess.ack(sub)
    alive!(sub)
    assert File.ls!(Orphans.dir()) == []
    assert {:ok, 0} = Subprocess.stop(sub)
  end

  test "a restart leaves the record a program is being given" do
    {:ok, tracker} = GenServer.start(Orphans, [owner: dead_mc()], name: Orphans)
    ref = Process.monitor(tracker)
    Process.exit(tracker, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}
    # Half written by a `Subprocess.start` racing the restart.
    in_flight = Path.join(Orphans.dir(), "1-1.json.tmp")
    File.write!(in_flight, ~s({"pid": 1))

    boot(:again)

    assert File.exists?(in_flight)
  end

  test "ps output is read with its group and start time" do
    assert {"S", "Sat Oct 18 12:00:00 2026", 123} =
             Orphans.parse_ps("Ss     123 Sat Oct 18 12:00:00 2026\n")

    assert Orphans.parse_ps("") == nil
    assert Orphans.parse_ps("Ss x Sat Oct 18 12:00:00 2026") == nil
  end

  test "a program of an MC still running is left alone when the service restarts" do
    boot(:first)
    {:ok, sub} = Subprocess.start(["sh", "-c", @echo])
    :ok = stop_supervised(:first)

    boot(:again)

    alive!(sub)
    assert [_record] = File.ls!(Orphans.dir())
    assert {:ok, 0} = Subprocess.stop(sub)
  end

  test "a record whose pid another program has now is dropped without killing it" do
    {:ok, sub} = Subprocess.start(["sh", "-c", @echo])
    pid = Subprocess.os_pid(sub)
    File.mkdir_p!(Orphans.dir())

    File.write!(
      Path.join(Orphans.dir(), "#{pid}-1.json"),
      JSON.encode!(%{"pid" => pid, "started" => "an earlier program", "mc" => dead_mc()})
    )

    boot(:next)

    alive!(sub)
    assert File.ls!(Orphans.dir()) == []
    assert {:ok, 0} = Subprocess.stop(sub)
  end

  test "a program that ends takes its record with it" do
    tracker = boot(:mc)
    {:ok, sub} = Subprocess.start(["sh", "-c", @echo])
    ref = Process.monitor(sub.proc.pid)
    assert [_record] = File.ls!(Orphans.dir())

    assert {:ok, 0} = Subprocess.stop(sub)
    assert_receive {:DOWN, ^ref, :process, _, _}
    # Its own DOWN is in the tracker's mailbox by now; a call is answered after it.
    :sys.get_state(tracker)
    assert File.ls!(Orphans.dir()) == []
  end

  test "a program whose record cannot be written is not run" do
    boot(:mc)
    File.chmod!(Orphans.dir(), 0o500)
    on_exit(fn -> File.chmod(Orphans.dir(), 0o700) end)

    assert {:error, {:untracked, :eacces}} = Subprocess.start(["sh", "-c", @echo])
    assert File.ls!(Orphans.dir()) == []
  end

  test "a program started while the service restarts is still recorded" do
    {:ok, tracker} = GenServer.start(Orphans, [owner: dead_mc()], name: Orphans)
    ref = Process.monitor(tracker)
    # A crash, which the supervisor answers by starting it again.
    Process.exit(tracker, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}

    {:ok, sub} = Subprocess.start(["sh", "-c", @echo])
    assert [_record] = File.ls!(Orphans.dir())

    boot(:next)

    assert_receive {:subprocess_eof, reader} when reader == sub.reader, 5_000
    assert File.ls!(Orphans.dir()) == []
  end

  test "an MC that cannot read its own start time records nothing" do
    # Its records would name an owner no later boot could tell from a live MC.
    boot(:blind, owner: %{"pid" => String.to_integer(System.pid()), "started" => nil})
    {:ok, sub} = Subprocess.start(["sh", "-c", @echo])
    alive!(sub)
    assert File.ls!(Orphans.dir()) == []
    {:ok, _} = Subprocess.stop(sub)
  end

  test "an MC that exited but was not reaped yet is gone" do
    # A zombie: the shell forks a child, then becomes `sleep`, which never waits for it.
    # The child exits only once its parent is `sleep`, so the shell cannot reap it first.
    child = ~S{sh -c 'while [ "$(cat /proc/$PPID/comm)" != sleep ]; do sleep 0.01; done'}
    {:ok, holder} = Exile.Process.start_link(["sh", "-c", child <> " & echo $!; exec sleep 60"])
    {:ok, line} = Exile.Process.read(holder)
    zombie = line |> String.trim() |> String.to_integer()
    await_zombie(zombie, 500)
    boot(:died, owner: %{"pid" => zombie, "started" => Orphans.started(zombie)})
    {:ok, sub} = Subprocess.start(["sh", "-c", @echo])
    :ok = stop_supervised(:died)

    boot(:next)

    assert_receive {:subprocess_eof, reader} when reader == sub.reader, 5_000
    assert File.ls!(Orphans.dir()) == []
    :ok = Exile.Process.kill(holder, :sigkill)
  end

  # Nothing tells a process other than the parent that a child exited without reaping
  # it, so this reads the child's state; the bound is only how long a failure waits.
  defp await_zombie(pid, tries) when tries > 0 do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        if stat |> String.split(")") |> List.last() |> String.split() |> hd() == "Z" do
          :ok
        else
          Process.sleep(10)
          await_zombie(pid, tries - 1)
        end

      {:error, reason} ->
        flunk("#{pid} was reaped before it was seen as a zombie: #{reason}")
    end
  end

  defp await_zombie(pid, 0), do: flunk("#{pid} never became a zombie")
end
