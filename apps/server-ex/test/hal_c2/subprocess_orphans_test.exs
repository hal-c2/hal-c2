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
end
