defmodule HalC2.AntigravitySessionFilesTest do
  use ExUnit.Case, async: false

  alias HalC2.Acp.Antigravity.SessionFiles

  @tag :tmp_dir
  test "a runtime directory outlives the process that launched it", %{tmp_dir: profile} do
    # Left behind by an MC that was killed: swept by the next launch.
    stale = Path.join(SessionFiles.temp_dir(profile), "run-stale")
    File.mkdir_p!(stale)

    task = Task.async(fn -> SessionFiles.runtime_dir(profile) end)
    assert {:ok, first} = Task.await(task)

    # The table belongs to the SessionFiles owner, never to the launcher:
    # in this environment nothing has started it yet, so the launch did.
    owner = Process.whereis(SessionFiles)
    assert is_pid(owner) and owner != task.pid
    assert :ets.info(:hal_c2_antigravity_live_temp, :owner) == owner
    assert File.dir?(first)
    refute File.exists?(stale)

    # The launching task has exited; a second launch's sweep must not take
    # the first runtime directory (its process may still be running).
    assert {:ok, second} = SessionFiles.runtime_dir(profile)
    assert File.dir?(first)
    assert File.dir?(second)

    :ok = SessionFiles.release(first)
    refute File.exists?(first)
    :ok = SessionFiles.release(second)
  end
end
