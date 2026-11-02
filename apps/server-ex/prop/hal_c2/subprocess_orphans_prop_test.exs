defmodule HalC2.SubprocessOrphansPropTest do
  @moduledoc """
  `HalC2.Subprocess.Orphans` against a model of the programs an MC runs: started,
  stopped, started while the service is down for a restart, carried over a restart of
  the service inside a running MC, or left running by an MC that died. The MC is a stand-in OS process, so dying is that process
  ending while its programs keep running. Each boot after a death must kill exactly
  the programs the dead MC left, each with its background command, leave a file in
  the records dir that is not a record alone, and spare the
  rest; there is a record for each program running, and one that a service which
  restarted no longer tracks stays until the next boot. A restart leaves a record
  being written alone. A boot that cannot list or read the records kills nothing and
  still comes up, and the next reap (a restart of the service, or a later boot) kills
  what it left. A boot that cannot make the records dir or read its own start time
  still comes up, but runs no program until the failure ends: the next start then
  reaps what the boot could not, as the MC the boot was given, before it runs
  (hal-c2/hal-c2#451). An orphan may exit on its own before the boot, leaving its background command in its
  group: the boot kills that command all the same (hal-c2/hal-c2#380).
  A run kills through the pid-kill helper or with the `kill` it falls back to, and
  which must not change any of this (hal-c2/hal-c2#411).
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Subprocess
  alias HalC2.Subprocess.Orphans

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  # `blind_boot` leans on chmod, which does not restrict root.
  @chmod_skip (case System.cmd("id", ["-u"]) do
                 {"0\n", 0} -> "chmod does not restrict root"
                 _ -> false
               end)

  # An echo with a command in the background that holds stdout too, so end of file
  # says both are gone. A closed stdin ends both; the line `leave` ends only the
  # program, which answers with its background command's pid.
  @program [
    "sh",
    "-c",
    ~s(sleep 60 & while read l; do [ "$l" = leave ] && { echo $!; exit 0; }; echo "$l"; done; kill $!)
  ]

  @tag skip: @chmod_skip
  property "a boot kills what a dead MC left running and nothing else",
    numtests: HalC2.Prop.numtests(40),
    max_size: 20 do
    forall {cmds, helper?} <- {commands(__MODULE__), boolean()} do
      trap_exit do
        HalC2.Prop.scratch_home("orphans")
        Application.put_env(:hal_c2, :pid_kill_helper, helper? && nil)
        {history, state, result} = run_commands(__MODULE__, cmds)
        cleanup()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # `running`: id => whether this incarnation of the service tracks it; one that
  # restarted forgets what it tracked. `records`: the ids that have a record naming
  # this MC, `left` the ones naming a dead MC. `orphans`: the ids a dead MC left
  # running, `exited` the ones among them whose program has since exited, leaving its
  # background command. `unavailable`: tracking could not be set up this boot, so starts
  # try again. `broken`: what it failed on still fails, so they are refused.
  def initial_state,
    do: %{
      up: false,
      next: 0,
      running: %{},
      records: [],
      left: [],
      orphans: [],
      exited: [],
      unavailable: false,
      broken: false
    }

  def command(%{up: false} = state) do
    frequency(
      [
        {3, {:call, __MODULE__, :boot, []}},
        {1, {:call, __MODULE__, :blind_boot, [oneof([:unlistable, :unreadable])]}},
        # Orphans waiting out of reach are what a healing start must reap first.
        {if(state.orphans == [], do: 1, else: 5), {:call, __MODULE__, :dirless_boot, []}},
        {1, {:call, __MODULE__, :timeless_boot, []}}
      ] ++ exits(state)
    )
  end

  def command(state) do
    stops =
      if state.running == %{},
        do: [],
        else: [{3, {:call, __MODULE__, :stop, [oneof(Map.keys(state.running))]}}]

    # While unavailable there is no service to retry through during a restart, so
    # nothing to start then either; the restart itself (failure ended) is one way out.
    during =
      if state.unavailable,
        do: [],
        else: [{1, {:call, __MODULE__, :start_during_restart, [state.next]}}]

    # The other way out: the failure ends, and the next start heals.
    heals = if state.broken, do: [{8, {:call, __MODULE__, :failure_ends, []}}], else: []

    frequency(
      [
        {4, {:call, __MODULE__, :start, [state.next]}},
        {1, {:call, __MODULE__, :restart_service, []}},
        {1, {:call, __MODULE__, :die, []}}
      ] ++ during ++ heals ++ stops
    )
  end

  defp exits(state) do
    case state.orphans -- state.exited do
      [] -> []
      orphans -> [{3, {:call, __MODULE__, :orphan_exits, [oneof(orphans)]}}]
    end
  end

  def precondition(state, {:call, _, :orphan_exits, [id]}),
    do: not state.up and id in state.orphans and id not in state.exited

  def precondition(state, {:call, _, :boot, []}), do: not state.up
  def precondition(state, {:call, _, :blind_boot, _}), do: not state.up
  def precondition(state, {:call, _, :dirless_boot, []}), do: not state.up
  def precondition(state, {:call, _, :timeless_boot, []}), do: not state.up
  def precondition(state, {:call, _, :failure_ends, []}), do: state.up and state.broken

  def precondition(state, {:call, _, :start_during_restart, _}),
    do: state.up and not state.unavailable

  def precondition(state, {:call, _, :stop, [id]}), do: state.up and is_map_key(state.running, id)
  def precondition(state, {:call, _, _, _}), do: state.up

  def next_state(state, _, {:call, _, :orphan_exits, [id]}),
    do: %{state | exited: [id | state.exited]}

  def next_state(state, _, {:call, _, :boot, []}),
    do: reaped(%{state | up: true, unavailable: false})

  def next_state(state, _, {:call, _, :blind_boot, _}),
    do: %{state | up: true, unavailable: false}

  # The records wait out of reach: nothing is reaped.
  def next_state(state, _, {:call, _, :dirless_boot, []}),
    do: %{state | up: true, unavailable: true, broken: true}

  # The dir is fine, so the reap ran.
  def next_state(state, _, {:call, _, :timeless_boot, []}),
    do: reaped(%{state | up: true, unavailable: true, broken: true})

  def next_state(state, _, {:call, _, :failure_ends, []}), do: %{state | broken: false}

  # A start while the failure lasts is refused and records nothing.
  def next_state(%{broken: true} = state, _, {:call, _, :start, _}), do: state

  # The first start after it ended reaps, then runs.
  def next_state(%{unavailable: true} = state, result, {:call, _, :start, _} = call),
    do: next_state(reaped(%{state | unavailable: false}), result, call)

  def next_state(state, _, {:call, _, :start, [id]}),
    do: %{
      state
      | next: id + 1,
        running: Map.put(state.running, id, true),
        records: state.records ++ [id]
    }

  def next_state(state, _, {:call, _, :stop, [id]}) do
    {tracked?, running} = Map.pop(state.running, id)

    %{
      state
      | running: running,
        records: if(tracked?, do: state.records -- [id], else: state.records)
    }
  end

  # The failure is over by the restart, so tracking is available again.
  def next_state(state, _, {:call, _, :restart_service, []}),
    do:
      reaped(%{
        state
        | unavailable: false,
          broken: false,
          running: Map.new(state.running, fn {id, _} -> {id, false} end)
      })

  # Recorded, but by no incarnation of the service that watches it end.
  def next_state(state, _, {:call, _, :start_during_restart, [id]}) do
    state = next_state(state, nil, {:call, __MODULE__, :restart_service, []})

    %{
      state
      | next: id + 1,
        running: Map.put(state.running, id, false),
        records: state.records ++ [id]
    }
  end

  def next_state(state, _, {:call, _, :die, []}),
    do: %{
      state
      | up: false,
        unavailable: false,
        broken: false,
        running: %{},
        records: [],
        left: state.left ++ state.records,
        orphans: state.orphans ++ Map.keys(state.running)
    }

  # A reap kills what dead MCs left running and drops every record naming one.
  defp reaped(state), do: %{state | left: [], orphans: [], exited: []}

  def postcondition(_state, {:call, _, :orphan_exits, _}, result), do: result == :ok

  def postcondition(state, {:call, _, :boot, []}, {killed, records, foreign_left}),
    do: Enum.sort(killed) == Enum.sort(state.orphans) and records == [] and foreign_left

  def postcondition(state, {:call, _, :blind_boot, _}, {alive, records}),
    do: alive == Enum.sort(state.orphans) and records == pids(state.left)

  # The orphans still answer, their records out of reach or the reap not yet due.
  def postcondition(state, {:call, _, :dirless_boot, []}, alive),
    do: alive == Enum.sort(state.orphans)

  def postcondition(state, {:call, _, :timeless_boot, []}, {killed, records}),
    do: Enum.sort(killed) == Enum.sort(state.orphans) and records == []

  def postcondition(_state, {:call, _, :failure_ends, []}, result), do: result == :ok

  # A start that heals answers only after its reap: what it returns to has been killed.
  def postcondition(state, {:call, _, :start, _} = call, {outcome, killed, records}) do
    healing? = state.unavailable and not state.broken

    outcome == if(state.broken, do: :error, else: :started) and
      Enum.sort(killed) == if(healing?, do: Enum.sort(state.orphans), else: []) and
      records == records_of(next_state(state, nil, call))
  end

  def postcondition(state, {:call, _, :stop, _} = call, {status, records}),
    do: status == {:ok, 0} and records == records_of(next_state(state, nil, call))

  def postcondition(state, {:call, _, :restart_service, []}, {killed, alive, records}),
    do:
      Enum.sort(killed) == Enum.sort(state.orphans) and
        alive == Enum.sort(Map.keys(state.running)) and records == pids(state.records)

  def postcondition(state, {:call, _, :start_during_restart, _} = call, {killed, records}),
    do:
      Enum.sort(killed) == Enum.sort(state.orphans) and
        records == records_of(next_state(state, nil, call))

  def postcondition(_state, {:call, _, :die, []}, result), do: result == :ok

  # --- commands ----------------------------------------------------------------------

  # An orphan stops on its own, as a provider does on its closed stdin, leaving its
  # background command, which stays in its group with nothing left to answer for it.
  def orphan_exits(id) do
    sub = Process.get({:sub, id})
    reader = sub.reader
    :ok = Subprocess.write_line(sub, "leave")

    command =
      receive do
        {:subprocess_lines, ^reader, [line]} ->
          Subprocess.ack(sub)
          String.to_integer(line)
      end

    await_gone(Process.get({:pid, id}), 500)
    Process.put({:command, id}, command)
    :ok
  end

  # A new MC: a stand-in OS process for it, then the service, which reaps as it starts.
  # Returns the orphans whose program and background command ended, the records,
  # and whether a file in the records dir that is not a record was left alone.
  def boot do
    new_mc()
    File.mkdir_p!(Orphans.dir())
    foreign = Path.join(Orphans.dir(), "notes.txt")
    File.write!(foreign, "not a record")
    start_service()
    {killed(), records(), File.exists?(foreign)}
  end

  # A new MC whose reap cannot list the records, or read any of them, until it is up.
  # Returns the orphans that still answer, and the records.
  def blind_boot(how) do
    new_mc()
    dir = Orphans.dir()
    File.mkdir_p!(dir)
    names = File.ls!(dir)

    case how do
      :unlistable -> File.chmod!(dir, 0o300)
      :unreadable -> for name <- names, do: File.chmod!(Path.join(dir, name), 0o000)
    end

    start_service()
    File.chmod!(dir, 0o700)
    for name <- names, do: File.chmod!(Path.join(dir, name), 0o600)
    alive = for id <- Process.get(:orphans, []), orphan_alive?(id), do: id
    {Enum.sort(alive), records()}
  end

  # A new MC whose records dir cannot be made: a file where its parent goes, the dir,
  # with what a dead MC left in it, set aside until `failure_ends/0`. Returns the
  # orphans that still answer.
  def dirless_boot do
    new_mc()
    parent = Path.dirname(Orphans.dir())
    File.mkdir_p!(parent)
    File.rename!(parent, parent <> ".aside")
    File.write!(parent, "")
    Process.put(:failure, :dir)
    start_service()
    Enum.sort(for id <- Process.get(:orphans, []), orphan_alive?(id), do: id)
  end

  # A new MC that cannot read its own start time until `failure_ends/0`. Its records
  # dir is fine, so the reap runs. The function is what the service reads again.
  # Returns the orphans the reap ended, and the records.
  def timeless_boot do
    new_mc()
    owner = Process.get(:owner)
    :persistent_term.put({__MODULE__, :timeless}, true)
    Process.put(:failure, :start_time)

    start_service(fn ->
      if :persistent_term.get({__MODULE__, :timeless}, false),
        do: %{owner | "started" => nil},
        else: owner
    end)

    {killed(), records()}
  end

  def failure_ends do
    case Process.delete(:failure) do
      :dir ->
        parent = Path.dirname(Orphans.dir())
        File.rm!(parent)
        File.rename!(parent <> ".aside", parent)

      :start_time ->
        :persistent_term.erase({__MODULE__, :timeless})

      nil ->
        :ok
    end

    :ok
  end

  def start(id) do
    healing? = match?({:unavailable, _}, :persistent_term.get(Orphans, nil))

    case Subprocess.start(@program) do
      {:ok, sub} ->
        Process.put({:sub, id}, sub)
        Process.put({:pid, id}, Subprocess.os_pid(sub))
        {:started, if(healing?, do: killed(), else: []), records()}

      {:error, _reason} ->
        {:error, [], records()}
    end
  end

  def stop(id) do
    sub = Process.delete({:sub, id})
    ref = Process.monitor(sub.proc.pid)
    status = Subprocess.stop(sub)
    # The service's DOWN is in its mailbox once ours is here; a call is answered after it.
    receive do: ({:DOWN, ^ref, :process, _, _} -> :ok)
    :sys.get_state(Orphans)
    {status, records()}
  end

  # The service crashes and its supervisor starts it again, inside the same MC, while
  # a program's record is half written. Returns the programs that still answer, and
  # the records, once that write is done; it fails when the restart dropped the write.
  def restart_service do
    kill_service()
    # A failure ends by the restart, with the dir restored. No record write can be in
    # flight then (every start was refused), so the half-written record is only
    # planted when tracking was on.
    failure_ends()
    File.mkdir_p!(Orphans.dir())
    in_flight = Path.join(Orphans.dir(), "#{System.pid()}-0.json.tmp")

    planted? = match?(%{}, :persistent_term.get(Orphans, nil))
    if planted?, do: File.write!(in_flight, ~s({"pid": ))
    start_service()
    if planted?, do: :ok = File.rm(in_flight)
    killed = killed()
    {killed, for({id, sub} <- subs(), alive?(sub), do: id) |> Enum.sort(), records()}
  end

  # A program starts after the service crashed and before its supervisor starts it
  # again. Returns the records.
  def start_during_restart(id) do
    kill_service()
    {:ok, sub} = Subprocess.start(@program)
    Process.put({:sub, id}, sub)
    Process.put({:pid, id}, Subprocess.os_pid(sub))
    start_service()
    {killed(), records()}
  end

  # The MC's VM dies: nothing runs its shutdown, and its programs keep running.
  def die do
    kill_service()
    mc = Process.delete(:mc)
    :ok = Exile.Process.kill(mc, :sigkill)
    {:ok, _} = Exile.Process.await_exit(mc)
    failure_ends()
    # The VM's terms go with it: the next boot is not a restart.
    :persistent_term.erase(Orphans)
    Process.put(:orphans, for({id, _} <- subs(), do: id))
    :ok
  end

  # --- helpers -----------------------------------------------------------------------

  defp records_of(state), do: pids(state.records ++ state.left)

  defp new_mc do
    {:ok, mc} = Exile.Process.start_link(["sh", "-c", "read l"])
    {:ok, os_pid} = Exile.Process.os_pid(mc)
    Process.put(:mc, mc)
    Process.put(:owner, %{"pid" => os_pid, "started" => Orphans.started(os_pid)})
  end

  # The orphans the reap that just ran ended, each with its background command.
  defp killed do
    killed = for id <- Process.get(:orphans, []), orphan_ended?(id), do: id
    Process.put(:orphans, [])
    killed
  end

  defp start_service(owner \\ Process.get(:owner)),
    do: {:ok, _} = GenServer.start(Orphans, [owner: owner], name: Orphans)

  defp kill_service do
    pid = Process.whereis(Orphans)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    receive do: ({:DOWN, ^ref, :process, _, _} -> :ok)
  end

  defp orphan_alive?(id) do
    case Process.get({:command, id}) do
      nil -> alive?(Process.get({:sub, id}))
      command -> not Orphans.gone?(command)
    end
  end

  # An orphan that exited has only its command left to have ended: the reap is over,
  # so that is read once.
  defp orphan_ended?(id) do
    sub = Process.delete({:sub, id})

    case Process.delete({:command, id}) do
      nil -> ended?(sub)
      command -> Orphans.gone?(command)
    end
  end

  defp await_gone(pid, tries) when tries > 0 do
    if Orphans.gone?(pid) do
      :ok
    else
      Process.sleep(10)
      await_gone(pid, tries - 1)
    end
  end

  defp subs, do: for({{:sub, id}, sub} <- Process.get(), do: {id, sub})

  defp alive?(sub) do
    :ok = Subprocess.write_line(sub, "ping")
    reader = sub.reader

    receive do
      {:subprocess_lines, ^reader, ["ping"]} ->
        Subprocess.ack(sub)
        true

      {:subprocess_eof, ^reader} ->
        false
    end
  end

  # End of file comes once the program and its background command are both gone;
  # the bound is only how long a failing case waits for it.
  defp ended?(sub) do
    reader = sub.reader
    exit_ref = sub.proc.exit_ref

    receive do
      {:subprocess_eof, ^reader} ->
        receive do
          {^exit_ref, {:ok, status}} -> status == 137
        after
          5_000 -> false
        end
    after
      5_000 -> false
    end
  end

  defp pids(ids), do: ids |> Enum.map(&Process.get({:pid, &1})) |> Enum.sort()

  defp records do
    dir =
      if Process.get(:failure) == :dir do
        parent = Path.dirname(Orphans.dir())
        Path.join(parent <> ".aside", Path.basename(Orphans.dir()))
      else
        Orphans.dir()
      end

    # No records dir yet is no records.
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&Regex.match?(~r/^\d+-\d+\.json(\.tmp)?$/, &1))
        |> Enum.map(&(Path.join(dir, &1) |> File.read!() |> JSON.decode!() |> Map.fetch!("pid")))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  defp cleanup do
    if Process.whereis(Orphans), do: kill_service()
    failure_ends()

    # A command an orphan left has nothing else to stop it.
    for {{:command, _id}, command} <- Process.get(),
        do: System.cmd("kill", ["-KILL", "#{command}"], stderr_to_stdout: true)

    for {_id, sub} <- subs() do
      try do
        Subprocess.stop(sub, 500)
      catch
        :exit, _ -> :ok
      end
    end

    if mc = Process.get(:mc), do: Exile.Process.kill(mc, :sigkill)
    # A killed service leaves tracking on, for the scratch home this run is done with.
    :persistent_term.erase(Orphans)

    for {key, _} <- Process.get(),
        match?({:sub, _}, key) or match?({:pid, _}, key) or match?({:command, _}, key) or
          key in [:mc, :owner, :orphans],
        do: Process.delete(key)
  end
end
