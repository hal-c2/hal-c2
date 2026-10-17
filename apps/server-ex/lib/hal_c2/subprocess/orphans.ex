defmodule HalC2.Subprocess.Orphans do
  @moduledoc """
  `<state dir>/subprocesses/`: a record of each program `HalC2.Subprocess` runs, so
  the next boot kills the ones an MC that died left behind.

  Exile stops a program when the process that owns it exits, not when the VM dies.
  After a crash, a hard kill or `halt`, a provider CLI that does not exit on a closed
  stdin keeps working, and the thread's next turn would `--resume` its session in a
  second one (hal-c2/hal-c2#254). So each program gets a file naming it and the MC
  that started it, removed when the program's Exile process ends. At boot, before
  `HalC2.Orchestration.Recovery`, a record whose MC is gone and whose program is still
  the one it names (same pid and start time, so a reused pid is spared) has the
  program's process group killed: erl_child_setup starts every port program as the
  leader of a session of its own, and the commands it ran in the background share
  its group. A record of an MC still running is kept, as when this service restarts
  inside one.

  SIGKILL rather than a polite signal: once `kill` returns the program runs no more
  code, so nothing the boot resumes races it.

  The kernel's parent-death signal (`PR_SET_PDEATHSIG`) is not used. It would kill
  the program but leave its background commands with no leader to check the group
  against, and macOS has none. A release under systemd loses the unit's processes
  when the MC stops anyway (`KillMode=mixed`).
  """

  use GenServer

  require Logger

  @doc "`opts[:owner]` replaces this MC's identity in the records it writes, for tests."
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Where the records live."
  def dir, do: Path.join(HalC2.Paths.state_dir(), "subprocesses")

  @doc """
  Records the program `os_pid`, run by the Exile process `proc`, until `proc` ends.
  A no-op when this service is not running (tests, Mix tasks).
  """
  @spec track(pid, pos_integer) :: :ok
  def track(proc, os_pid) do
    case started(os_pid) do
      nil -> :ok
      started -> GenServer.call(__MODULE__, {:track, proc, os_pid, started})
    end
  catch
    :exit, _ -> :ok
  end

  @doc """
  When the process `pid` started, as a string that differs between two processes that
  had the same pid, or nil when there is no such process.
  """
  def started(pid) do
    case File.read("/proc/#{pid}/stat") do
      # Field 22, the start time in ticks since boot, counted after the command name,
      # which may hold spaces and parentheses.
      {:ok, stat} ->
        ticks = stat |> String.split(")") |> List.last() |> String.split() |> Enum.at(19)
        "#{boot_id()}:#{ticks}"

      {:error, _} ->
        if File.dir?("/proc/self"), do: nil, else: ps_started(pid)
    end
  end

  # A boot of the machine, so ticks since boot from an earlier one never match.
  defp boot_id do
    case File.read("/proc/sys/kernel/random/boot_id") do
      {:ok, id} -> String.trim(id)
      {:error, _} -> ""
    end
  end

  # macOS: wall-clock start time, to the second.
  defp ps_started(pid) do
    case System.cmd("ps", ["-o", "lstart=", "-p", "#{pid}"], stderr_to_stdout: true) do
      {out, 0} -> if (out = String.trim(out)) != "", do: out
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @impl true
  def init(opts) do
    owner =
      Keyword.get_lazy(opts, :owner, fn ->
        pid = String.to_integer(System.pid())
        %{"pid" => pid, "started" => started(pid)}
      end)

    dir = dir()
    HalC2.Paths.mkdir_private!(dir)
    reap(dir)
    {:ok, %{owner: owner, dir: dir, programs: %{}}}
  end

  @impl true
  def handle_call({:track, proc, os_pid, started}, _from, state) do
    # The start time in the name keeps a reused pid's record apart from the one before.
    path = Path.join(state.dir, "#{os_pid}-#{:erlang.phash2(started)}.json")
    record = %{"pid" => os_pid, "started" => started, "mc" => state.owner}
    _ = File.write(path, JSON.encode!(record))
    ref = Process.monitor(proc)
    {:reply, :ok, put_in(state.programs[ref], path)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _proc, _reason}, state) do
    {path, programs} = Map.pop(state.programs, ref)
    if path, do: File.rm(path)
    {:noreply, %{state | programs: programs}}
  end

  defp reap(dir) do
    killed =
      for name <- File.ls!(dir), path = Path.join(dir, name), reap_one(path) == :killed do
        path
      end

    if killed != [],
      do: Logger.warning("killed #{length(killed)} programs an earlier MC left running")
  end

  defp reap_one(path) do
    with {:ok, text} <- File.read(path),
         {:ok, %{"pid" => pid, "started" => started, "mc" => %{"pid" => mc} = owner}}
         when is_integer(pid) and is_integer(mc) <- JSON.decode(text) do
      cond do
        started(mc) == owner["started"] ->
          :kept

        started(pid) == started ->
          # The group first: the leader's pid names it.
          System.cmd("kill", ["-s", "KILL", "--", "-#{pid}", "#{pid}"], stderr_to_stdout: true)
          File.rm(path)
          :killed

        true ->
          File.rm(path)
          :gone
      end
    else
      _ ->
        File.rm(path)
        :gone
    end
  end
end
