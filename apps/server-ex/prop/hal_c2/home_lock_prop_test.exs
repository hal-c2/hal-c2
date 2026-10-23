defmodule HalC2.HomeLockPropTest do
  @moduledoc """
  `HalC2.HomeLock` against a model of who owns each HAL-C2 home. Two homes are
  contended by this MC and two other MCs, each another OS process (`sqlite3`)
  taking the lock as an MC does. This MC acquires, activates the lock as a service
  (boot, or a hot update), and waits out a holder that then dies; the others take a
  home and are killed. At most one of them owns a home at any time, this MC taking
  its own home again is a no-op, and a home is free once its holder is gone.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias Exqlite.Sqlite3
  alias HalC2.HomeLock

  @moduletag timeout: :infinity

  @homes [:a, :b]
  @others [:other1, :other2]

  property "one owner per home, whatever order the MCs start and stop in",
    numtests: HalC2.Prop.numtests(100),
    max_size: 30 do
    sqlite3 = System.find_executable("sqlite3") || flunk("this property needs sqlite3")

    forall cmds <- commands(__MODULE__) do
      trap_exit do
        start_case(sqlite3)
        {history, state, result} = run_commands(__MODULE__, cmds)
        end_case()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  defp start_case(sqlite3) do
    dir = HalC2.Prop.scratch_home("home-lock")
    paths = Map.new(@homes, &{&1, Path.join([dir, "#{&1}", "mc.lock"])})
    for {_, path} <- paths, do: File.mkdir_p!(Path.dirname(path))
    Process.put(:sqlite3, sqlite3)
    Process.put(:paths, paths)
    Process.put(:holders, %{})
  end

  # The others die with the case; this MC lets go of the case's homes, which a real MC
  # does only by ending.
  defp end_case do
    for {_, {port, _home}} <- Process.get(:holders), do: kill(port)

    for {_, path} <- Process.get(:paths),
        db = :persistent_term.get({HomeLock, path}, nil) do
      Sqlite3.close(db)
      :persistent_term.erase({HomeLock, path})
    end
  end

  # --- model ------------------------------------------------------------------

  # owners: home => :mc or another MC. held: another MC => the home it holds.
  def initial_state, do: %{owners: %{}, held: %{}}

  def command(state) do
    held_by_others = for {home, owner} <- state.owners, owner != :mc, do: home

    frequency(
      [
        {4, {:call, __MODULE__, :acquire, [oneof(@homes)]}},
        {3, {:call, __MODULE__, :activate, [oneof(@homes)]}},
        {4, {:call, __MODULE__, :other_takes, [oneof(@others), oneof(@homes)]}},
        {3, {:call, __MODULE__, :other_dies, [oneof(@others)]}}
      ] ++
        if(held_by_others == [],
          do: [],
          else: [{3, {:call, __MODULE__, :wait_out, [oneof(held_by_others)]}}]
        )
    )
  end

  def precondition(state, {:call, _, :other_takes, [other, _home]}),
    do: not Map.has_key?(state.held, other)

  def precondition(state, {:call, _, :other_dies, [other]}), do: Map.has_key?(state.held, other)

  def precondition(state, {:call, _, :wait_out, [home]}),
    do: state.owners[home] not in [nil, :mc]

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, cmd, [home]}) when cmd in [:acquire, :activate] do
    if state.owners[home] in [nil, :mc], do: put_in(state.owners[home], :mc), else: state
  end

  def next_state(state, _result, {:call, _, :other_takes, [other, home]}) do
    if state.owners[home] == nil,
      do: %{
        state
        | owners: Map.put(state.owners, home, other),
          held: Map.put(state.held, other, home)
      },
      else: state
  end

  def next_state(state, _result, {:call, _, :other_dies, [other]}) do
    {home, held} = Map.pop(state.held, other)
    %{state | owners: Map.delete(state.owners, home), held: held}
  end

  def next_state(state, _result, {:call, _, :wait_out, [home]}) do
    other = state.owners[home]
    %{state | owners: Map.put(state.owners, home, :mc), held: Map.delete(state.held, other)}
  end

  def postcondition(state, {:call, _, :acquire, [home]}, result),
    do: result == if(state.owners[home] in [nil, :mc], do: :ok, else: {:error, :held})

  def postcondition(state, {:call, _, :activate, [home]}, result),
    do: result == if(state.owners[home] in [nil, :mc], do: :ignore, else: {:error, :home_held})

  def postcondition(state, {:call, _, :other_takes, [_other, home]}, result),
    do: result == if(state.owners[home] == nil, do: :took, else: :refused)

  def postcondition(_state, {:call, _, cmd, _}, result) when cmd in [:other_dies, :wait_out],
    do: result == :ok

  # --- commands ---------------------------------------------------------------

  def acquire(home), do: HomeLock.acquire(path: path(home))

  # How an MC's supervisor starts the lock, at boot or after a hot update.
  def activate(home), do: HomeLock.start_link(path: path(home))

  # Another MC: an OS process holding the home's lock until it is killed, or refused it.
  def other_takes(other, home) do
    port =
      Port.open({:spawn_executable, Process.get(:sqlite3)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-bail", path(home)]
      ])

    Port.command(port, "BEGIN EXCLUSIVE;\nSELECT 'held';\n")
    taken(port, other, home)
  end

  # Refused, sqlite3 says why (on the port, stderr included) and exits.
  defp taken(port, other, home) do
    receive do
      {^port, {:data, "held" <> _}} ->
        Process.put(:holders, Map.put(Process.get(:holders), other, {port, home}))
        :took

      {^port, {:data, _why}} ->
        taken(port, other, home)

      {^port, {:exit_status, _}} ->
        :refused
    after
      10_000 -> raise "sqlite3 neither took #{path(home)} nor gave up"
    end
  end

  def other_dies(other) do
    {{port, _home}, holders} = Map.pop(Process.get(:holders), other)
    Process.put(:holders, holders)
    kill(port)
    :ok
  end

  # The background service: waits on a home another MC holds, which then dies.
  def wait_out(home) do
    path = path(home)
    waiter = Task.async(fn -> HomeLock.acquire(path: path, wait: true) end)
    {other, _} = Enum.find(Process.get(:holders), fn {_, {_port, held}} -> held == home end)
    other_dies(other)
    Task.await(waiter, 10_000)
  end

  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        System.cmd("kill", ["-9", Integer.to_string(os_pid)])

        receive do
          {^port, {:exit_status, _}} -> :ok
        after
          10_000 -> raise "sqlite3 #{os_pid} did not exit"
        end

      nil ->
        :ok
    end
  end

  defp path(home), do: Map.fetch!(Process.get(:paths), home)
end
