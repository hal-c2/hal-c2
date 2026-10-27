defmodule HalC2.AntigravitySessionFilesTest do
  use ExUnit.Case, async: false

  alias HalC2.Acp.Antigravity.SessionFiles

  @tag :tmp_dir
  test "a runtime directory outlives the process that launched it", %{tmp_dir: profile} do
    # Take the owner down so the launch below is the one that starts it
    # (unlinked, in table/0). A supervised owner goes through the supervisor:
    # GenServer.stop/1 alone would race its restart as a permanent child.
    supervised? =
      case Process.whereis(HalC2.Supervisor) do
        nil ->
          false

        _pid ->
          HalC2.Supervisor
          |> Supervisor.which_children()
          |> Enum.any?(fn {id, pid, _type, _modules} -> id == SessionFiles and is_pid(pid) end)
      end

    if supervised? do
      :ok = Supervisor.terminate_child(HalC2.Supervisor, SessionFiles)

      on_exit(fn ->
        if pid = Process.whereis(SessionFiles), do: GenServer.stop(pid)
        Supervisor.restart_child(HalC2.Supervisor, SessionFiles)
      end)
    else
      if pid = Process.whereis(SessionFiles), do: GenServer.stop(pid)
    end

    assert Process.whereis(SessionFiles) == nil
    assert :ets.whereis(:hal_c2_antigravity_live_temp) == :undefined
    # Left behind by an MC that was killed: swept by the next launch.
    stale = Path.join(SessionFiles.temp_dir(profile), "run-stale")
    File.mkdir_p!(stale)

    task = Task.async(fn -> SessionFiles.runtime_dir(profile) end)
    assert {:ok, first} = Task.await(task)

    # The table belongs to the SessionFiles owner the launch started,
    # never to the launcher itself. That owner is the unsupervised instance
    # from table/0, not a child the supervisor restarted.
    owner = Process.whereis(SessionFiles)
    assert is_pid(owner) and owner != task.pid
    assert :ets.info(:hal_c2_antigravity_live_temp, :owner) == owner

    if Process.whereis(HalC2.Supervisor) do
      supervised_pids =
        HalC2.Supervisor
        |> Supervisor.which_children()
        |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)

      refute owner in supervised_pids
    end

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
