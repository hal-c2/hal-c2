defmodule HalC2.SubprocessSandboxedTest do
  use ExUnit.Case, async: true

  alias HalC2.OpenShell
  alias HalC2.OpenShell.Client
  alias HalC2.Subprocess
  alias HalC2.Subprocess.Sandboxed
  alias HalC2.Test.FakeOpenShell

  # The reader as `start/3` leaves it, on an exec stream this test plays, its owner
  # still working on a batch it was handed.
  defp reader do
    owner = self()
    ref = make_ref()
    exec = make_ref()

    reader =
      spawn_link(fn ->
        Sandboxed.reader_loop(%{
          owner: owner,
          ref: ref,
          status: :atomics.new(1, signed: true),
          exec: exec,
          limit: 1_000_000,
          on_limit: fn -> :ok end,
          seen: 0,
          partial: "",
          lines: [],
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
