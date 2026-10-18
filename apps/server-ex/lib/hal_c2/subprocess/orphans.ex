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
  `track/2` writes the record in the calling process, not in this service, so a
  program started while the service restarts is still on disk for the next boot; only
  removing the record when the program ends needs the service. `{:error, reason}` when
  the record could not be written: the caller must stop the program rather than run it
  untracked. A program already gone has no start time and nothing to record. A no-op
  when this service has not been started in this VM (tests, Mix tasks).
  """
  @spec track(pid, pos_integer) :: :ok | {:error, term}
  def track(proc, os_pid) do
    with %{dir: dir, owner: owner} <- :persistent_term.get(__MODULE__, nil),
         started when started != nil <- started(os_pid) do
      # The start time in the name keeps a reused pid's record apart from the one before.
      path = Path.join(dir, "#{os_pid}-#{:erlang.phash2(started)}.json")
      record = %{"pid" => os_pid, "started" => started, "mc" => owner}

      with :ok <- File.write(path, JSON.encode!(record)) do
        GenServer.cast(__MODULE__, {:watch, proc, path})
      end
    else
      _ -> :ok
    end
  end

  @doc """
  When the process `pid` started, as a string that differs between two processes that
  had the same pid, or nil when there is no such process.
  """
  def started(pid) do
    case process(pid) do
      {_state, started} -> started
      nil -> nil
    end
  end

  # Whether `owner` is that MC and still running. One that exited but that its parent
  # has not reaped yet keeps its pid and start time, as a zombie.
  defp running?(%{"pid" => pid, "started" => started}) do
    case process(pid) do
      {state, ^started} -> state not in ["Z", "X"]
      _ -> false
    end
  end

  # `{state, started}` of the process `pid`, or nil.
  defp process(pid) do
    case File.read("/proc/#{pid}/stat") do
      # Fields 3 and 22, the state and the start time in ticks since boot, counted
      # after the command name, which may hold spaces and parentheses.
      {:ok, stat} ->
        [state | rest] = stat |> String.split(")") |> List.last() |> String.split()
        {state, "#{boot_id()}:#{Enum.at(rest, 18)}"}

      {:error, _} ->
        if File.dir?("/proc/self"), do: nil, else: ps_process(pid)
    end
  end

  # A boot of the machine, so ticks since boot from an earlier one never match.
  defp boot_id do
    case File.read("/proc/sys/kernel/random/boot_id") do
      {:ok, id} -> String.trim(id)
      {:error, _} -> ""
    end
  end

  # macOS: the state's first letter, and the wall-clock start time to the second.
  defp ps_process(pid) do
    case System.cmd("ps", ["-o", "state=,lstart=", "-p", "#{pid}"], stderr_to_stdout: true) do
      {out, 0} ->
        case String.split(String.trim(out), " ", parts: 2) do
          [state, started] -> {String.first(state), String.trim(started)}
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  @impl true
  def init(opts) do
    # So a supervisor's shutdown runs `terminate/2`.
    Process.flag(:trap_exit, true)

    owner =
      Keyword.get_lazy(opts, :owner, fn ->
        pid = String.to_integer(System.pid())
        %{"pid" => pid, "started" => started(pid)}
      end)

    dir = dir()
    HalC2.Paths.mkdir_private!(dir)
    reap(dir)

    # Without its own start time no later boot could tell this MC from one that reused
    # its pid, so its records could get a live MC's programs killed: track nothing.
    if owner["started"],
      do: :persistent_term.put(__MODULE__, %{dir: dir, owner: owner}),
      else: Logger.warning("not tracking programs: this MC's start time cannot be read")

    {:ok, %{programs: %{}}}
  end

  @impl true
  def handle_cast({:watch, proc, path}, state) do
    ref = Process.monitor(proc)
    {:noreply, put_in(state.programs[ref], path)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _proc, _reason}, state) do
    {path, programs} = Map.pop(state.programs, ref)
    if path, do: File.rm(path)
    {:noreply, %{state | programs: programs}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Stopped on purpose, programs are untracked again. A crash keeps tracking on, so
  # the programs started before the supervisor brings this back are still recorded.
  @impl true
  def terminate(reason, _state) do
    if reason in [:normal, :shutdown] or match?({:shutdown, _}, reason),
      do: :persistent_term.erase(__MODULE__)
  end

  defp reap(dir) do
    killed =
      for name <- File.ls!(dir), path = Path.join(dir, name), reap_one(path) == :killed do
        path
      end

    if killed != [],
      do: Logger.warning("killed #{length(killed)} programs an earlier MC left running")
  end

  # The group first: the leader's pid names it. A program that survives keeps its
  # record, so the next boot tries again.
  defp kill(path, pid, started) do
    case System.cmd("kill", ["-s", "KILL", "--", "-#{pid}", "#{pid}"], stderr_to_stdout: true) do
      {_, 0} ->
        File.rm(path)
        :killed

      {out, status} ->
        if running?(%{"pid" => pid, "started" => started}) do
          Logger.error(
            "could not kill #{pid}, which an earlier MC left running: #{status} #{out}"
          )

          :kept
        else
          File.rm(path)
          :killed
        end
    end
  end

  defp reap_one(path) do
    with {:ok, text} <- File.read(path),
         {:ok, %{"pid" => pid, "started" => started, "mc" => %{"pid" => mc} = owner}}
         when is_integer(pid) and pid > 1 and is_integer(mc) <- JSON.decode(text) do
      cond do
        running?(owner) ->
          :kept

        started(pid) == started ->
          kill(path, pid, started)

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
