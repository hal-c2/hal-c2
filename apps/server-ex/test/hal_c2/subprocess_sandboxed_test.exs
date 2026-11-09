defmodule HalC2.SubprocessSandboxedTest do
  use ExUnit.Case, async: true

  alias HalC2.Subprocess.Sandboxed

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
end
