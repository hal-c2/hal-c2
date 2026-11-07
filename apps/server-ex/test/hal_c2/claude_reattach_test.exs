defmodule HalC2.ClaudeReattachTest do
  use ExUnit.Case, async: true

  alias HalC2.Claude.ThreadRuntime

  @moduletag :tmp_dir

  # A session that did not answer on reattaching was killed, but what it sent first,
  # such as the checkpoint its own question wrote, can still be in the mailbox.
  test "a checkpoint from a session that is not the runtime's saves nothing", %{tmp_dir: dir} do
    {:ok, state} = ThreadRuntime.init("t-stale")
    current = spawn(fn -> :ok end)
    stale = spawn(fn -> :ok end)
    state = %{state | session: current}
    checkpoint = %{dir: dir, offset: 10, channel: nil, wrote: true}

    assert {:noreply, ^state} =
             ThreadRuntime.handle_info({:claude, stale, {:checkpoint, checkpoint}}, state)

    refute File.exists?(Path.join(dir, "snapshot"))

    # The runtime's own session's checkpoint is saved.
    assert {:noreply, _} =
             ThreadRuntime.handle_info({:claude, current, {:checkpoint, checkpoint}}, state)

    assert %{offset: 10} = :erlang.binary_to_term(File.read!(Path.join(dir, "snapshot")))
  end
end
