defmodule HalC2.SubprocessSandboxedTest do
  use ExUnit.Case, async: true

  alias HalC2.OpenShell
  alias HalC2.OpenShell.Client
  alias HalC2.Subprocess
  alias HalC2.Subprocess.Sandboxed
  alias HalC2.Test.FakeOpenShell

  # The reader as `start/3` leaves it, on an exec stream this test plays, its owner
  # still working on a batch it was handed.
  defp reader(opts \\ []) do
    owner = self()
    ref = make_ref()
    # A stream already gone: a cancel finds nothing to stop.
    exec = spawn(fn -> :ok end)

    reader =
      spawn_link(fn ->
        Sandboxed.reader_loop(%{
          owner: owner,
          monitor: Process.monitor(owner),
          ref: ref,
          status: :atomics.new(1, signed: true),
          exec: exec,
          limit: 1_000_000,
          held_limit: Keyword.get(opts, :held_limit, 1_000),
          on_limit: Keyword.get(opts, :on_limit, fn -> :ok end),
          seen: 0,
          partial: "",
          lines: [],
          held: 0,
          waiting: true,
          ended: false
        })
      end)

    {reader, ref, exec}
  end

  test "lines read while the owner has not acknowledged arrive as one batch, in order" do
    {reader, ref, exec} = reader()

    for chunk <- ["a\nb", "\nc\n", "d\ne\nf"],
        do: send(reader, {:openshell_exec, exec, {:stdout, chunk}})

    send(reader, :ack)
    assert_receive {:subprocess_lines, ^reader, ["a", "b", "c", "d", "e"]}

    send(reader, {:openshell_exec, exec, {:stdout, "g\n"}})
    send(reader, {:openshell_exec, exec, {:exit, 0}})
    assert_receive {^ref, {:ok, 0}}
    send(reader, :ack)
    assert_receive {:subprocess_lines, ^reader, ["fg"]}
    send(reader, :ack)
    assert_receive {:subprocess_eof, ^reader}
  end

  # Bytes alone do not bound what a busy owner leaves held: a short line costs far more
  # as a list cell than its two bytes.
  test "more lines held for a busy owner than its limit cancels the run and drops them" do
    test = self()
    {reader, ref, exec} = reader(held_limit: 3, on_limit: fn -> send(test, :limited) end)

    send(reader, {:openshell_exec, exec, {:stdout, "a\nb\n"}})
    send(reader, {:openshell_exec, exec, {:stdout, "c\nd\n"}})
    assert_receive :limited
    assert_receive {^ref, {:ok, 137}}

    send(reader, {:openshell_exec, exec, {:stdout, "e\n"}})
    send(reader, :ack)
    assert_receive {:subprocess_eof, ^reader}
    refute_received {:subprocess_lines, ^reader, _}
  end

  # A normal exit does not travel down the link, and a reader waiting on an
  # acknowledgement would otherwise wait, its stream open, for good.
  @tag :tmp_dir
  test "an owner that exits without stopping its program takes the reader and the stream with it",
       %{tmp_dir: dir} do
    gateway = FakeOpenShell.start(Path.join(dir, "pki"), exec: fn ["cat"], io -> cat(io) end)
    FakeOpenShell.put_sandbox(gateway, "box", %{OpenShell.owner_label() => OpenShell.owner()})
    {:ok, conn} = Client.connect(gateway.endpoint, gateway.credentials)
    on_exit(fn -> Client.disconnect(conn) end)
    test = self()

    {owner, owned} =
      spawn_monitor(fn ->
        {:ok, sub} = Subprocess.start(["cat"], sandbox: %{conn: conn, name: "box"})
        :ok = Subprocess.write_line(sub, "held")
        reader = sub.reader
        # Left unacknowledged.
        assert_receive {:subprocess_lines, ^reader, ["held"]}, 5_000
        send(test, {:running, reader, sub.proc.exec})
      end)

    assert_receive {:running, reader, exec}, 5_000
    assert_receive {:DOWN, ^owned, :process, ^owner, :normal}, 5_000
    reader = Process.monitor(reader)
    exec = Process.monitor(exec)
    assert_receive {:DOWN, ^reader, :process, _, _}, 5_000
    assert_receive {:DOWN, ^exec, :process, _, _}, 5_000
  end

  defp cat(io) do
    case io.read.() do
      {:stdin, data} ->
        io.stdout.(data)
        cat(io)

      :eof ->
        io.exit.(0)

      _ ->
        cat(io)
    end
  end

  # As `HalC2.JsonRpc.Connection` and `HalC2.Claude.Session` do: the program exits by
  # itself, its owner takes that from its mailbox, and only then stops it. No wait is
  # given, so a stop that waited for the taken message would cancel and make up 137.
  @tag :tmp_dir
  test "a program whose exit its owner took still answers with its own status", %{tmp_dir: dir} do
    exit = fn ["exit", code], io -> io.exit.(String.to_integer(code)) end
    gateway = FakeOpenShell.start(Path.join(dir, "pki"), exec: exit)
    FakeOpenShell.put_sandbox(gateway, "box", %{OpenShell.owner_label() => OpenShell.owner()})
    {:ok, conn} = Client.connect(gateway.endpoint, gateway.credentials)
    on_exit(fn -> Client.disconnect(conn) end)

    {:ok, sub} = Subprocess.start(["exit", "3"], sandbox: %{conn: conn, name: "box"})
    ref = sub.proc.exit_ref
    assert_receive {^ref, _} = message, 5_000
    assert Subprocess.exit_status(sub, message) == {:ok, 3}

    assert Subprocess.exited(sub, 0) == {:ok, 3}
    assert Subprocess.stop(sub, 0) == {:ok, 3}
  end
end
