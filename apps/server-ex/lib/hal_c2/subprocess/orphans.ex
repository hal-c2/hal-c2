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

  The group is as far as the kill reaches. A descendant that started a session or
  group of its own (`setsid`, `setpgid`: a shell on a pty, a `node` child spawned
  `detached`) is not in it and keeps running, a dev server holding its port with it.
  The agent that would resume is dead either way. Reaching those would take a cgroup,
  or the ancestry recorded at spawn (hal-c2/hal-c2#387). Nor does it reach the
  background commands of a program that had already exited by the boot (a CLI that
  stopped on its closed stdin): with no leader left to check, its group's id cannot
  be told from a later group's, so the record is dropped and they are not signalled.

  The kernel's parent-death signal (`PR_SET_PDEATHSIG`) is not used. It would kill
  the program but leave its background commands with no leader to check the group
  against, and macOS has none. A release under systemd loses the unit's processes
  when the MC stops anyway (`KillMode=mixed`).

  macOS reads processes with `ps` and kills with BSD `kill`; no test runs there but
  the one of how `ps` output is read. Windows has neither `/proc` nor `ps`, so an MC
  there cannot read its own start time and tracks no programs.
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
  when this service has not been started in this VM (tests, Mix tasks); an MC that
  runs its services logs that once, as a program it starts then is not recorded.
  """
  @spec track(pid, pos_integer) :: :ok | {:error, term}
  def track(proc, os_pid) do
    case :persistent_term.get(__MODULE__, nil) do
      %{dir: dir, owner: owner} -> record(dir, owner, proc, os_pid)
      nil -> untracked()
    end
  end

  defp record(dir, owner, proc, os_pid) do
    case started(os_pid) do
      nil ->
        :ok

      started ->
        # The start time in the name keeps a reused pid's record apart from the one
        # before.
        path = Path.join(dir, "#{os_pid}-#{:erlang.phash2(started)}.json")
        record = %{"pid" => os_pid, "started" => started, "mc" => owner}

        # Written whole under another name, then renamed, so a VM that dies mid-write
        # leaves no partial record. `reap/1` reads a `.tmp` like any record, and drops
        # one that does not parse.
        tmp = path <> ".tmp"

        with :ok <- File.write(tmp, JSON.encode!(record)),
             :ok <- File.rename(tmp, path) do
          GenServer.cast(__MODULE__, {:watch, proc, path})
        else
          error ->
            File.rm(tmp)
            error
        end
    end
  end

  defp untracked do
    if Application.get_env(:hal_c2, :start_mc, false) and
         not :persistent_term.get({__MODULE__, :untracked}, false) do
      :persistent_term.put({__MODULE__, :untracked}, true)
      Logger.warning("programs are not tracked: #{inspect(__MODULE__)} is not running")
    end

    :ok
  end

  @doc """
  When the process `pid` started, as a string that differs between two processes that
  had the same pid, or nil when there is no such process. On macOS it is to the
  second, so two that had the same pid differ only when they started in different
  seconds.
  """
  def started(pid) do
    case process(pid) do
      {_state, started, _group} -> started
      nil -> nil
    end
  end

  # Whether the process a record names (a program, or the MC that ran it) is still that
  # process and alive. One that exited but that its parent has not reaped yet keeps its
  # pid and start time, as a zombie.
  defp running?(%{"pid" => pid, "started" => started}) do
    case process(pid) do
      {state, ^started, _group} -> state not in ["Z", "X"]
      _ -> false
    end
  end

  # `{state, started, process group}` of the process `pid`, or nil.
  defp process(pid) do
    case File.read("/proc/#{pid}/stat") do
      # Fields 3, 5 and 22, the state, the group and the start time in ticks since boot,
      # counted after the command name, which may hold spaces and parentheses. A process
      # exiting as it is read can leave less.
      {:ok, stat} ->
        case stat |> String.split(")") |> List.last() |> String.split() do
          [state, _parent, group | rest] when length(rest) >= 17 ->
            {state, "#{boot_id()}:#{Enum.at(rest, 16)}", String.to_integer(group)}

          _ ->
            nil
        end

      {:error, _} ->
        if File.dir?("/proc/self"), do: nil, else: ps_process(pid)
    end
  end

  # A boot of the machine, so ticks since boot from an earlier one never match.
  # Immutable for the life of the VM, so it is read once.
  defp boot_id do
    case :persistent_term.get({__MODULE__, :boot_id}, nil) do
      nil ->
        id =
          case File.read("/proc/sys/kernel/random/boot_id") do
            {:ok, id} -> String.trim(id)
            {:error, _} -> ""
          end

        :persistent_term.put({__MODULE__, :boot_id}, id)
        id

      id ->
        id
    end
  end

  # macOS. `lstart` is written in the locale's words, so the locale is pinned: an MC
  # read under another one would look like a different process, and be taken for gone.
  defp ps_process(pid) do
    case System.cmd("ps", ["-o", "state=,pgid=,lstart=", "-p", "#{pid}"],
           stderr_to_stdout: true,
           env: [{"LC_ALL", "C"}]
         ) do
      {out, 0} -> parse_ps(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc false
  # The state's first letter, the group, and the wall-clock start time to the second.
  def parse_ps(out) do
    with [state, group, started] <- String.split(String.trim(out), ~r/\s+/, parts: 3),
         {group, ""} <- Integer.parse(group) do
      {String.first(state), String.trim(started), group}
    else
      _ -> nil
    end
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

    # Tracking still on is a restart inside this MC, after a crash: a program may be
    # being recorded right now, so its record's `.tmp` is not this reap's to drop.
    restart? = :persistent_term.get(__MODULE__, nil) != nil
    dir = dir()

    # Nothing here may stop the MC from booting (cf. `reap_one/1`): a records dir
    # that cannot be made (a parent that is a file, a read-only or full filesystem)
    # leaves tracking off instead of raising out of `init/1`, where a restart would
    # burn through the supervisor's restart intensity and take the application down.
    case mkdir(dir) do
      :ok ->
        reap(dir, restart?)

        # Without its own start time no later boot could tell this MC from one that reused
        # its pid, so its records could get a live MC's programs killed: track nothing.
        if owner["started"],
          do: :persistent_term.put(__MODULE__, %{dir: dir, owner: owner}),
          else: Logger.warning("not tracking programs: this MC's start time cannot be read")

      :error ->
        # A stale entry from before a restart would point at the same unusable dir.
        :persistent_term.erase(__MODULE__)
    end

    {:ok, %{programs: %{}}}
  end

  defp mkdir(dir) do
    HalC2.Paths.mkdir_private!(dir)
    :ok
  rescue
    e ->
      Logger.warning("not tracking programs: cannot create #{dir}: #{Exception.message(e)}")

      :error
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
  # The ones still running then lose their monitors, so their records stay on disk until
  # the next boot reaps them. They name this MC, which that boot finds gone: leave them.
  @impl true
  def terminate(reason, _state) do
    if reason in [:normal, :shutdown] or match?({:shutdown, _}, reason),
      do: :persistent_term.erase(__MODULE__)
  end

  defp reap(dir, restart?) do
    names =
      case File.ls(dir) do
        {:ok, names} ->
          names

        {:error, reason} ->
          Logger.warning("could not list #{dir}, left for the next boot: #{reason}")
          []
      end

    killed =
      for name <- names,
          not (restart? and String.ends_with?(name, ".tmp")),
          path = Path.join(dir, name),
          reap_one(path) == :killed,
          do: path

    if killed != [],
      do: Logger.warning("killed #{length(killed)} programs an earlier MC left running")
  end

  # The group first, when the program still leads it: the leader's pid names it. A
  # program that survives keeps its record, so the next boot tries again.
  defp kill(path, pid, started, leader?) do
    targets = if leader?, do: ["-#{pid}", "#{pid}"], else: ["#{pid}"]

    # `-KILL`, not `-s KILL`: the one-dash form is the one both GNU and BSD `kill`
    # take as separate argv entries, with `--` before a negative (group) pid.
    case System.cmd("kill", ["-KILL", "--" | targets], stderr_to_stdout: true) do
      {_, 0} ->
        File.rm(path)
        :killed

      # One target failed (the group, when the program led none; a member it may not
      # signal), and the program may yet show as running for a moment after SIGKILL.
      {out, status} ->
        if running?(%{"pid" => pid, "started" => started}) do
          Logger.warning(
            "could not kill #{pid}, which an earlier MC left running: #{status} #{out}"
          )

          :kept
        else
          File.rm(path)
          :killed
        end
    end
  end

  # Nothing here may stop the MC from booting: a record that cannot be dealt with now
  # (unreadable, no `kill` to run) is kept for a later boot.
  defp reap_one(path) do
    case File.read(path) do
      {:ok, text} ->
        reap_record(path, JSON.decode(text))

      {:error, :enoent} ->
        :gone

      {:error, reason} ->
        Logger.warning("could not read #{path}, kept for the next boot: #{reason}")
        :kept
    end
  rescue
    e ->
      Logger.warning("could not reap #{path}, kept for the next boot: #{Exception.message(e)}")
      :kept
  end

  # A record that is not one this module writes is dropped.
  defp reap_record(
         path,
         {:ok,
          %{
            "pid" => pid,
            "started" => started,
            "mc" => %{"pid" => mc, "started" => mc_started} = owner
          }}
       )
       when is_integer(pid) and pid > 1 and is_binary(started) and is_integer(mc) and mc > 0 and
              is_binary(mc_started) do
    cond do
      # Never signal ourselves, and never a "program" that is its own MC: a corrupt
      # or crafted record (anything running as this user can write here) naming this
      # boot's pid with a matching start would otherwise have it kill its own group.
      pid == String.to_integer(System.pid()) or pid == mc ->
        File.rm(path)
        :gone

      running?(owner) ->
        :kept

      true ->
        # Read again right before the signal, with the group the program leads now.
        case process(pid) do
          {_state, ^started, group} ->
            kill(path, pid, started, group == pid)

          _ ->
            File.rm(path)
            :gone
        end
    end
  end

  defp reap_record(path, _malformed) do
    File.rm(path)
    :gone
  end
end
