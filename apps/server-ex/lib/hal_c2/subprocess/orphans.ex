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
  or the ancestry recorded at spawn (hal-c2/hal-c2#387).

  A program that had already exited by the boot (a CLI that stopped on its closed
  stdin) may have left background commands in its group. With no leader, the group's
  id alone cannot be told from a later group's: a daemon that reused the pid and
  called `setsid` has the same one. So each program runs with a random mark in its
  environment (`HAL_C2_PROGRAM_ID`), which its record names and its descendants
  inherit, and the boot kills, one pid at a time, the processes in that group whose
  `/proc/<pid>/environ` holds the mark. A command started with the mark stripped from
  its environment is not told from a stranger and keeps running. macOS offers no
  `/proc`, so there such a record is dropped with its commands left running
  (hal-c2/hal-c2#702). Nor does anything reach what a program left behind when it
  exited under a live MC, which removes the record at that exit.

  Nor is the last identity read atomic with the signal: a pid reused in the moment
  between that read and the external `kill` running would be signalled instead;
  closing that needs a pidfd (`pidfd_open` + `pidfd_send_signal`), which no helper
  here provides. Nor is a program recorded before it runs: its pid is only known
  once it is spawned, so it executes — argv and all — between the spawn and its
  record landing, and a VM that dies in that moment leaves an orphan no boot can
  find. Closing that would take spawning it held until tracked; the fail-closed
  checks below refuse the failures known before the spawn, and a failed record
  write kills the program, but neither un-runs those first moments.

  The kernel's parent-death signal (`PR_SET_PDEATHSIG`) is not used. It would kill
  the program but leave its background commands with no leader to check the group
  against, and macOS has none. A release under systemd loses the unit's processes
  when the MC stops anyway (`KillMode=mixed`).

  macOS reads processes with `ps` and kills with BSD `kill`; no test runs there but
  the one of how `ps` output is read. Windows has neither `/proc` nor `ps`, so an MC
  there cannot read its own start time and tracks no programs: that platform runs
  its programs untracked by design.

  Off Windows, tracking that cannot be set up fails closed rather than quietly
  off. If the records dir cannot be made, or this MC's own start time cannot be
  read, the MC still boots, but `track/3` returns an error, so
  `HalC2.Subprocess.start` refuses to run a program no later boot could find —
  the same answer a failed record write gets, given before the program is
  started at all when the failure is already known. That refusal covers every
  program `HalC2.Subprocess` runs, not only provider CLIs: the Claude session
  and every JSON-RPC provider connection, and the device hub alike, so a
  broken state dir refuses all of them. A single program whose start
  time cannot be read (as against one already gone) is refused the same way, and
  so is a start in a running MC before this service has started.

  A refused start first has this service try the setup again, so a moment's read
  failure does not outlast the moment (`handle_call/3`). The attempt runs in the
  service, one at a time, with the owner `init/1` was given, and reaps before it marks
  tracking on: a dir that can be made again may hold records of a dead MC that
  `init/1` never reaped, and a caller waiting on the attempt is answered after that
  reap, so nothing resumes ahead of it. A failed attempt logs a warning, once per
  refused start, and changes nothing.

  The boot-time reap is synchronous, in `init/1`, before Recovery resumes
  anything. Its cost is bounded per orphan, not in total: a program that does
  not leave at once (in uninterruptible sleep, or a zombie whose parent never
  reaps it — that one pays in full at every boot until it does) is awaited up
  to about half a second, so N such records hold the boot for about N times
  that. Genuinely stuck orphans are rare; a total budget would leave the rest
  for the next boot at the price of resuming a session ahead of its reap.
  """

  use GenServer

  require Logger

  @doc """
  `opts[:owner]` replaces this MC's identity in the records it writes, for tests: the
  identity, or a function read at each attempt to set tracking up.
  """
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # The name is free of KEY, SECRET and TOKEN: providers that filter what their
  # commands inherit (Codex's default shell policy) drop names with those in them.
  @mark_var "HAL_C2_PROGRAM_ID"

  @doc "Where the records live."
  def dir, do: Path.join(HalC2.Paths.state_dir(), "subprocesses")

  @doc """
  Whether a program started now would be tracked, known before it exists: `:ok`,
  `{:error, reason}` with the reason `track/3` would refuse it (tracking could
  not be set up, tried again just now, or, in a running MC, this service has not
  started yet), or `:off` where nothing is tracked by design (no MC services in
  this VM, or Windows). `HalC2.Subprocess.start` refuses on the error before
  spawning, so a known-unavailable boot starts no CLI just to kill it;
  `track/3` stays the authoritative check for what races past this one.
  """
  @spec available?() :: :ok | :off | {:error, term}
  def available? do
    case :persistent_term.get(__MODULE__, nil) do
      %{} -> :ok
      {:unavailable, reason} -> retry_setup(reason)
      nil -> if tracking_expected?(), do: {:error, :not_started}, else: :off
    end
  end

  # Waits for the attempt, and for the reap that comes with it, as a boot waits for
  # its own: bounded per orphan (see the moduledoc). A service that is not there
  # (restarting) leaves the start refused, for the next one to try again.
  defp retry_setup(reason) do
    GenServer.call(__MODULE__, :retry_setup, :infinity)
  catch
    :exit, _ -> {:error, reason}
  end

  # An MC running its services off Windows is expected to track: no mark from
  # this service yet is the exception there, the ordinary state elsewhere.
  defp tracking_expected?,
    do:
      Application.get_env(:hal_c2, :start_mc, false) and
        HalC2.Paths.platform() != :windows

  @doc "A new mark for a program, and the environment entry that carries it."
  def new_mark do
    mark = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    {mark, {@mark_var, mark}}
  end

  @doc """
  Records the program `os_pid`, started with the environment entry of `mark`, run by the Exile process `proc`, until `proc` ends.
  `track/3` writes the record in the calling process, not in this service, so a
  program started while the service restarts is still on disk for the next boot; only
  removing the record when the program ends needs the service. `{:error, reason}` when
  the record could not be written, when tracking could not be set up, tried again
  just now (`:no_records_dir`, `:no_start_time`; see the moduledoc), or when the program's
  start time could not be read (`:no_start_time`): the caller must stop the program
  rather than run it untracked. A program already gone has nothing to record. A
  no-op when this service has not been started in this VM and none is expected
  (tests, Mix tasks, Windows); in a running MC that window — before this
  service's `init/1`, or after a hot upgrade before it is started — refuses
  with `:not_started` instead, and logs it once.
  """
  @spec track(pid, pos_integer, String.t()) :: :ok | {:error, term}
  def track(proc, os_pid, mark) do
    case :persistent_term.get(__MODULE__, nil) do
      %{dir: dir, owner: owner} -> record(dir, owner, proc, os_pid, mark)
      {:unavailable, reason} -> with :ok <- retry_setup(reason), do: track(proc, os_pid, mark)
      nil -> untracked()
    end
  end

  defp record(dir, owner, proc, os_pid, mark) do
    case process_result(os_pid) do
      # Already gone: nothing to record. Unreadable is not gone: refuse, as a
      # failed write is refused, rather than run the program unrecorded.
      :gone ->
        :ok

      :unknown ->
        {:error, :no_start_time}

      {:ok, {_state, started, _group}} ->
        # The start time in the name keeps a reused pid's record apart from the one
        # before.
        path = Path.join(dir, "#{os_pid}-#{:erlang.phash2(started)}.json")
        record = %{"pid" => os_pid, "started" => started, "mark" => mark, "mc" => owner}

        # Written whole under another name, then renamed, so a VM that dies mid-write
        # leaves no partial record. `reap/2` reads a `.tmp` like any record, and drops
        # one that does not parse.
        tmp = path <> ".tmp"

        case write_record(tmp, path, record) do
          :ok ->
            GenServer.cast(__MODULE__, {:watch, proc, path})

          # The dir was removed under a running MC (cleanup tooling, a user
          # tidying state): tracking is still marked on, so make it again and
          # write once more rather than refuse every start for the boot.
          {:error, :enoent} ->
            with :ok <- mkdir(dir),
                 :ok <- write_record(tmp, path, record) do
              GenServer.cast(__MODULE__, {:watch, proc, path})
            else
              error ->
                File.rm(tmp)
                if error == :error, do: {:error, :no_records_dir}, else: error
            end

          error ->
            File.rm(tmp)
            error
        end
    end
  end

  defp write_record(tmp, path, record) do
    with :ok <- File.write(tmp, JSON.encode!(record)),
         :ok <- File.rename(tmp, path),
         do: :ok
  end

  defp untracked do
    if Application.get_env(:hal_c2, :start_mc, false) and
         not :persistent_term.get({__MODULE__, :untracked}, false) do
      :persistent_term.put({__MODULE__, :untracked}, true)
      Logger.warning("programs are not tracked: #{inspect(__MODULE__)} is not running")
    end

    if tracking_expected?(), do: {:error, :not_started}, else: :ok
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

  @doc """
  Whether the process `pid` runs no more code: no such process, or one that
  exited and waits to be reaped. An identity that cannot be read counts as
  not gone: the callers are deciding whether a program whose kill may have
  failed can be left, where unreadable must not read as dead.
  """
  def gone?(pid) do
    case process_result(pid) do
      {:ok, {state, _started, _group}} -> state in ["Z", "X"]
      :gone -> true
      :unknown -> false
    end
  end

  # Whether the process a record names (a program, or the MC that ran it) is still that
  # process and alive. One that exited but that its parent has not reaped yet keeps its
  # pid and start time, as a zombie. An identity that cannot be read counts as
  # still running: an owner only momentarily unreadable must not read as a dead
  # MC whose programs may be killed.
  defp running?(%{"pid" => pid, "started" => started}) do
    case process_result(pid) do
      {:ok, {state, ^started, _group}} -> state not in ["Z", "X"]
      {:ok, _other} -> false
      :gone -> false
      :unknown -> true
    end
  end

  # `{state, started, process group}` of the process `pid`, or nil. Only
  # `started/1` collapses the tri-state this way, where nil fails closed (a
  # start time that cannot be read tracks nothing); every path that decides a
  # kill or a record's fate reads `process_result/1` itself, so unreadable is
  # never taken for gone there.
  defp process(pid) do
    case process_result(pid) do
      {:ok, process} -> process
      _ -> nil
    end
  end

  # `{:ok, {state, started, process group}}`, `:gone` when there is no such
  # process, or `:unknown` when its identity cannot be read (a stat that does
  # not parse, a read error other than a missing pid, `ps` that cannot run).
  defp process_result(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        parse_stat(stat)

      {:error, reason} ->
        cond do
          not File.dir?("/proc/self") -> ps_process_result(pid)
          reason == :enoent -> :gone
          true -> :unknown
        end
    end
  end

  @doc false
  # Fields 3, 5 and 22, the state, the group and the start time in ticks since
  # boot, counted after the command name, which may hold spaces and
  # parentheses. A process exiting as it is read can leave less: `:unknown`, as
  # is a stat whose boot could not be read: ticks without their boot are no
  # identity, and a record stamped without one never matches a later boot
  # that reads it, so its orphans would be silently spared.
  def parse_stat(stat), do: parse_stat(stat, boot_id())

  @doc false
  def parse_stat(_stat, ""), do: :unknown

  def parse_stat(stat, boot) do
    case stat |> String.split(")") |> List.last() |> String.split() do
      [state, _parent, group | rest] when length(rest) >= 17 ->
        # The ticks are validated like the group: a non-numeric field stamped
        # into a record could never be reproduced by a later boot, silently
        # sparing that program's orphans instead of refusing the start.
        with {group, ""} <- Integer.parse(group),
             {_ticks, ""} <- Integer.parse(Enum.at(rest, 16)) do
          {:ok, {state, "#{boot}:#{Enum.at(rest, 16)}", group}}
        else
          _ -> :unknown
        end

      _ ->
        :unknown
    end
  end

  # A boot of the machine, so ticks since boot from an earlier one never match.
  # Immutable for the life of the VM, so a successful read is cached. A failed
  # or empty one is not: caching "" would stamp every record this VM writes
  # with no boot id (and read every process `:unknown` for its life), and no
  # later boot (reading the file fine) would ever match one of them.
  defp boot_id do
    case :persistent_term.get({__MODULE__, :boot_id}, nil) do
      nil ->
        case File.read("/proc/sys/kernel/random/boot_id") do
          {:ok, id} ->
            case String.trim(id) do
              "" ->
                ""

              id ->
                :persistent_term.put({__MODULE__, :boot_id}, id)
                id
            end

          {:error, _} ->
            ""
        end

      id ->
        id
    end
  end

  # macOS. `lstart` is written in the locale's words in local time, so both are
  # pinned: an MC read under another locale, or after the machine's timezone
  # changed (a laptop that travels), would look like a different process, and
  # be taken for gone.
  # For a pid with no process `ps` exits non-zero saying nothing (the headers are
  # suppressed), and only that silence is read as `:gone`; a non-zero exit that
  # says something, output that does not parse, and a `ps` that cannot run at
  # all are failures, not proof of absence: `:unknown`.
  # `ps` runs in a process of its own: `System.cmd` links its port to the
  # caller, and a caller trapping exits (a provider session, which stops on
  # any `:EXIT`) would be handed the port's `{:EXIT, port, :normal}`.
  @doc false
  def ps_process_result(pid) do
    {runner, ref} = spawn_monitor(fn -> exit({:ps, run_ps(pid)}) end)

    receive do
      {:DOWN, ^ref, :process, ^runner, {:ps, outcome}} -> outcome
      {:DOWN, ^ref, :process, ^runner, _crash} -> :unknown
    end
  end

  defp run_ps(pid) do
    ps_outcome(
      System.cmd("ps", ps_args(pid),
        stderr_to_stdout: true,
        env: [{"LC_ALL", "C"}, {"TZ", "UTC"}]
      )
    )
  rescue
    _ -> :unknown
  end

  @doc false
  # The argv BSD `ps` takes for one process with no headers, pinned in a test:
  # the macOS commands themselves run in no test, so an edit here is otherwise
  # invisible until a macOS-only bug report.
  def ps_args(pid), do: ["-o", "state=,pgid=,lstart=", "-p", "#{pid}"]

  @doc false
  # What a finished `ps` run proves: as `ps_process_result/1` reads it.
  def ps_outcome({out, 0}) do
    case parse_ps(out) do
      nil -> :unknown
      process -> {:ok, process}
    end
  end

  def ps_outcome({out, _status}), do: if(String.trim(out) == "", do: :gone, else: :unknown)

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

    owner = Keyword.get(opts, :owner, &own_identity/0)

    # Tracking still on is a restart inside this MC, after a crash: a program may be
    # being recorded right now, so its record's `.tmp` is not this reap's to drop.
    # Only the tracking mark means that: after an unavailable boot no record
    # write can be in flight, so its restart reaps `.tmp` records like a boot.
    set_up(owner, match?(%{}, :persistent_term.get(__MODULE__, nil)))

    {:ok, %{programs: %{}, owner: owner}}
  end

  defp own_identity do
    pid = String.to_integer(System.pid())
    %{"pid" => pid, "started" => started(pid)}
  end

  defp set_up(owner, restart?) do
    owner = if is_function(owner), do: owner.(), else: owner
    dir = dir()

    # Nothing here may stop the MC from booting (cf. `reap_one/1`): a records dir
    # that cannot be made (a parent that is a file, a read-only or full filesystem)
    # must not raise out of `init/1`, where a restart would burn through the
    # supervisor's restart intensity and take the application down. The boot goes
    # on, but tracking is marked unavailable, so program starts fail closed (see
    # the moduledoc) instead of running untracked for the whole boot.
    case mkdir(dir) do
      :ok ->
        reap(dir, restart?)

        # Without its own start time no later boot could tell this MC from one that reused
        # its pid, so its records could get a live MC's programs killed: track nothing.
        # On Windows no start time can ever be read, so programs there run
        # untracked by design; anywhere else the same unavailable mark applies.
        cond do
          owner["started"] ->
            :persistent_term.put(__MODULE__, %{dir: dir, owner: owner})

          HalC2.Paths.platform() == :windows ->
            Logger.warning("not tracking programs: this MC's start time cannot be read")
            :persistent_term.erase(__MODULE__)

          true ->
            Logger.warning("not tracking programs: this MC's start time cannot be read")
            :persistent_term.put(__MODULE__, {:unavailable, :no_start_time})
        end

      :error ->
        # As the no-start-time branch: on Windows programs run untracked by
        # design, so an unmakeable dir is not a reason to refuse every start.
        if HalC2.Paths.platform() == :windows,
          do: :persistent_term.erase(__MODULE__),
          else: :persistent_term.put(__MODULE__, {:unavailable, :no_records_dir})
    end
  end

  defp mkdir(dir) do
    HalC2.Paths.mkdir_private!(dir)
    :ok
  rescue
    e ->
      Logger.warning("not tracking programs: cannot create #{dir}: #{Exception.message(e)}")

      :error
  end

  # Here rather than in the caller, so concurrent starts cannot reap twice, and the
  # ones behind the attempt that succeeded find tracking on and do nothing. Reaps like
  # a boot: the mark said no record write was in flight. One that began just before a
  # crash and a failed `init/1` is at worst a live MC's record, which is kept, or a
  # half-written `.tmp`, dropped, whose rename then fails and is written again.
  @impl true
  def handle_call(:retry_setup, _from, state) do
    if match?({:unavailable, _}, :persistent_term.get(__MODULE__, nil)),
      do: set_up(state.owner, false)

    reply =
      case :persistent_term.get(__MODULE__, nil) do
        {:unavailable, reason} -> {:error, reason}
        _tracking -> :ok
      end

    {:reply, reply, state}
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

    # Only names this module writes are records; anything else in the dir (a file a
    # user or another tool put there) is not this boot's to remove.
    killed =
      for name <- names,
          name =~ ~r/^\d+-\d+\.json(\.tmp)?$/,
          not (restart? and String.ends_with?(name, ".tmp")),
          path = Path.join(dir, name),
          reap_one(path) == :killed,
          do: path

    if killed != [],
      do: Logger.warning("killed #{length(killed)} programs an earlier MC left running")
  end

  @doc false
  # `-KILL`, not `-s KILL`: the one-dash form is the one both GNU and BSD `kill`
  # take as separate argv entries, with `--` before a negative (group) pid.
  # The group first, when the program still leads it: the leader's pid names
  # it. Pinned in a test, like `ps_args/1`.
  def kill_args(pid, leader?) do
    targets = if leader?, do: ["-#{pid}", "#{pid}"], else: ["#{pid}"]
    ["-KILL", "--" | targets]
  end

  # A program that survives keeps its record, so the next boot tries again.
  defp kill(path, pid, started, leader?) do
    case System.cmd("kill", kill_args(pid, leader?), stderr_to_stdout: true) do
      {_, 0} ->
        # Exit 0 proves the signal was delivered, not that the program died:
        # one in uninterruptible sleep takes SIGKILL only when it wakes. The
        # record goes only once the pid no longer holds that process (a
        # zombie keeping its start time keeps the record, as below, since its
        # group may have survived); nothing signals an outside process's
        # death, so that is awaited bounded rather than read once.
        if await_left(pid, started) do
          File.rm(path)
          :killed
        else
          Logger.warning(
            "kill of #{pid}, which an earlier MC left running, was delivered but it is still there"
          )

          :kept
        end

      # One target failed (the group, when the program led none; a member it may not
      # signal), and the program may yet show as running for a moment after SIGKILL.
      # Only a pid no longer holding that process proves it gone: a zombie leader is
      # "not running" before any signal, while its group may have survived this one,
      # so its record is kept for the next boot rather than counted killed.
      {out, status} ->
        case process_result(pid) do
          # Still that process, or unreadable either way: not provably gone,
          # so the record stays for the next boot.
          {:ok, {_state, ^started, _group}} ->
            Logger.warning(
              "could not kill #{pid}, which an earlier MC left running: #{status} #{out}"
            )

            :kept

          :unknown ->
            Logger.warning(
              "could not kill #{pid}, which an earlier MC left running: #{status} #{out}" <>
                " (and its identity cannot be read, kept for the next boot)"
            )

            :kept

          _gone_or_reused ->
            File.rm(path)
            :killed
        end
    end
  end

  defp await_left(pid, started, tries \\ 50) do
    case process_result(pid) do
      {:ok, {_state, ^started, _group}} -> await_left_again(pid, started, tries)
      :unknown -> await_left_again(pid, started, tries)
      _gone_or_reused -> true
    end
  end

  defp await_left_again(_pid, _started, 0), do: false

  defp await_left_again(pid, started, tries) do
    Process.sleep(10)
    await_left(pid, started, tries - 1)
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
          } = record}
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
        # Not atomic with the external `kill` (see the moduledoc's pidfd limit).
        # Unreadable is not gone: the record stays for the next boot, as an
        # unreadable record does; dropping it would spare the orphan forever.
        case process_result(pid) do
          {:ok, {_state, ^started, group}} ->
            kill(path, pid, started, group == pid)

          :unknown ->
            :kept

          _gone_or_reused ->
            sweep(path, pid, record["mark"])
        end
    end
  end

  defp reap_record(path, _malformed) do
    File.rm(path)
    :gone
  end

  # The program is gone: kills what it left in its group, until none is left. With no
  # `/proc` to read marks from, or no mark (a record from before marks), nothing can
  # be told from a stranger, so nothing is signalled.
  defp sweep(path, group, mark) when is_binary(mark) and mark != "" do
    if File.dir?("/proc/self") do
      sweep(path, group, "#{@mark_var}=#{mark}", 50, :gone)
    else
      File.rm(path)
      :gone
    end
  end

  defp sweep(path, _group, _mark) do
    File.rm(path)
    :gone
  end

  # Marks are read afresh each round, so a command that forked meanwhile is caught and
  # each pid is signalled right after its mark is read. Nothing signals an outside
  # process's death, so the result is awaited, bounded, as in `await_left/3`; what stays
  # keeps the record for the next boot.
  defp sweep(path, group, entry, tries, outcome) do
    case members(group, entry) do
      {[], false} ->
        File.rm(path)
        outcome

      _left when tries == 0 ->
        Logger.warning(
          "commands of group #{group}, which an earlier MC left, are still there or unreadable"
        )

        :kept

      {[], true} ->
        Process.sleep(10)
        sweep(path, group, entry, tries - 1, outcome)

      {pids, _unreadable?} ->
        System.cmd("kill", ["-KILL", "--" | Enum.map(pids, &to_string/1)], stderr_to_stdout: true)

        Process.sleep(10)
        sweep(path, group, entry, tries - 1, :killed)
    end
  end

  # `{running processes in group that carry entry, never this MC itself; whether a marked
  # process could not be placed}`. No listing of `/proc` proves nothing, so it counts
  # as unreadable.
  defp members(group, entry) do
    case File.ls("/proc") do
      {:ok, names} ->
        me = System.pid()

        for name <- names, name != me, name =~ ~r/^\d+$/, reduce: {[], false} do
          {pids, unreadable?} ->
            case member(process_result(name), group, fn -> marked?(name, entry) end) do
              :member -> {[String.to_integer(name) | pids], unreadable?}
              :unreadable -> {pids, true}
              :stranger -> {pids, unreadable?}
            end
        end

      {:error, _} ->
        {[], true}
    end
  end

  @doc false
  # What a process read from `/proc` is to a sweep of `group`. An unreadable stat holds
  # the sweep up only when the process has the mark: a stranger's (another user's under
  # `hidepid`, which stays that way) must not keep the record at every boot. `marked?`
  # is a function so most processes, in other groups, have no environ read.
  def member({:ok, {state, _started, group}}, group, marked?) when state not in ["Z", "X"],
    do: if(marked?.(), do: :member, else: :stranger)

  def member(:unknown, _group, marked?), do: if(marked?.(), do: :unreadable, else: :stranger)
  def member(_other, _group, _marked?), do: :stranger

  # An environ that cannot be read (another user's, one exiting) carries no mark we
  # can prove. Compared whole, so no other variable's value can pass for it.
  defp marked?(pid, entry) do
    case File.read("/proc/#{pid}/environ") do
      {:ok, environ} -> entry in :binary.split(environ, <<0>>, [:global])
      {:error, _} -> false
    end
  end
end
