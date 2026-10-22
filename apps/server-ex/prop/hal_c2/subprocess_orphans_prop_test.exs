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
  what it left. A boot that cannot make the records dir still comes up, but runs
  no program until the service restarts (or the MC dies) with the dir restored.
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
  # says both are gone. A closed stdin ends both.
  @program ["sh", "-c", ~s(sleep 60 & while read l; do echo "$l"; done; kill $!)]

  @tag skip: @chmod_skip
  property "a boot kills what a dead MC left running and nothing else",
    numtests: HalC2.Prop.numtests(40),
    max_size: 20 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        HalC2.Prop.scratch_home("orphans")
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
  # running. `unavailable`: tracking could not be set up this boot, so starts are
  # refused. `dir_made`: the records dir has been made once; a dirless boot is
  # only possible before that (an existing dir needs no making).
  def initial_state,
    do: %{
      up: false,
      next: 0,
      running: %{},
      records: [],
      left: [],
      orphans: [],
      unavailable: false,
      dir_made: false
    }

  def command(%{up: false} = state) do
    dirless =
      if state.dir_made, do: [], else: [{1, {:call, __MODULE__, :dirless_boot, []}}]

    frequency(
      [
        {3, {:call, __MODULE__, :boot, []}},
        {1, {:call, __MODULE__, :blind_boot, [oneof([:unlistable, :unreadable])]}}
      ] ++ dirless
    )
  end

  def command(state) do
    stops =
      if state.running == %{},
        do: [],
        else: [{3, {:call, __MODULE__, :stop, [oneof(Map.keys(state.running))]}}]

    # While unavailable no start succeeds, so there is nothing to start during a
    # restart either; the restart itself (dir restored) is the way out.
    during =
      if state.unavailable,
        do: [],
        else: [{1, {:call, __MODULE__, :start_during_restart, [state.next]}}]

    frequency(
      [
        {4, {:call, __MODULE__, :start, [state.next]}},
        {1, {:call, __MODULE__, :restart_service, []}},
        {1, {:call, __MODULE__, :die, []}}
      ] ++ during ++ stops
    )
  end

  def precondition(state, {:call, _, :boot, []}), do: not state.up
  def precondition(state, {:call, _, :blind_boot, _}), do: not state.up
  def precondition(state, {:call, _, :dirless_boot, []}), do: not state.up and not state.dir_made

  def precondition(state, {:call, _, :start_during_restart, _}),
    do: state.up and not state.unavailable

  def precondition(state, {:call, _, :stop, [id]}), do: state.up and is_map_key(state.running, id)
  def precondition(state, {:call, _, _, _}), do: state.up

  def next_state(state, _, {:call, _, :boot, []}),
    do: reaped(%{state | up: true, unavailable: false, dir_made: true})

  def next_state(state, _, {:call, _, :blind_boot, _}),
    do: %{state | up: true, unavailable: false, dir_made: true}

  def next_state(state, _, {:call, _, :dirless_boot, []}),
    do: %{state | up: true, unavailable: true}

  # A start while unavailable is refused and records nothing.
  def next_state(%{unavailable: true} = state, _, {:call, _, :start, _}), do: state

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

  # The dir is back by the restart, so tracking is available again.
  def next_state(state, _, {:call, _, :restart_service, []}),
    do:
      reaped(%{
        state
        | unavailable: false,
          dir_made: true,
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
        running: %{},
        records: [],
        left: state.left ++ state.records,
        orphans: state.orphans ++ Map.keys(state.running)
    }

  # A reap kills what dead MCs left running and drops every record naming one.
  defp reaped(state), do: %{state | left: [], orphans: []}

  def postcondition(state, {:call, _, :boot, []}, {killed, records, foreign_left}),
    do: Enum.sort(killed) == Enum.sort(state.orphans) and records == [] and foreign_left

  def postcondition(state, {:call, _, :blind_boot, _}, {alive, records}),
    do: alive == Enum.sort(state.orphans) and records == pids(state.left)

  def postcondition(_state, {:call, _, :dirless_boot, []}, result), do: result == :ok

  def postcondition(state, {:call, _, :start, _} = call, {outcome, records}),
    do:
      outcome == if(state.unavailable, do: :error, else: :started) and
        records == records_of(next_state(state, nil, call))

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
    alive = for id <- Process.get(:orphans, []), alive?(Process.get({:sub, id})), do: id
    {Enum.sort(alive), records()}
  end

  # A new MC whose records dir cannot be made (a file where its parent goes).
  # The filesystem is restored once it is up; tracking stays unavailable until
  # the service restarts or the MC dies.
  def dirless_boot do
    new_mc()
    parent = Path.dirname(Orphans.dir())
    File.rm_rf!(parent)
    File.write!(parent, "")
    start_service()
    File.rm!(parent)
    File.mkdir_p!(parent)
    :ok
  end

  def start(id) do
    case Subprocess.start(@program) do
      {:ok, sub} ->
        Process.put({:sub, id}, sub)
        Process.put({:pid, id}, Subprocess.os_pid(sub))
        {:started, records()}

      {:error, _reason} ->
        {:error, records()}
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
    # After a dirless boot the records dir was never made; the restart is what
    # tracking coming back looks like, with the dir restored. No record write
    # can be in flight then (every start was refused), so the half-written
    # record is only planted when tracking was on.
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
    killed = for id <- Process.get(:orphans, []), ended?(Process.delete({:sub, id})), do: id
    Process.put(:orphans, [])
    killed
  end

  defp start_service,
    do: {:ok, _} = GenServer.start(Orphans, [owner: Process.get(:owner)], name: Orphans)

  defp kill_service do
    pid = Process.whereis(Orphans)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    receive do: ({:DOWN, ^ref, :process, _, _} -> :ok)
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
    dir = Orphans.dir()

    # No records dir yet (a dirless boot) is no records.
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
        match?({:sub, _}, key) or match?({:pid, _}, key) or key in [:mc, :owner, :orphans],
        do: Process.delete(key)
  end
end
