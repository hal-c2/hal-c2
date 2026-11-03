defmodule HalC2.UpgradeReleasePropTest do
  @moduledoc """
  `HalC2.Upgrade` installing release upgrades in place through the release handler,
  in this VM, from a release root in a scratch home. Each update brings a new
  version of a GenServer, whose state it may keep in another shape, and of a
  supervisor, whose children it may add, drop or change, and may bring a module
  loading a NIF. A process may hold a version's code meanwhile.

  The model: an update installs in place unless it brings native code or a process
  still runs the code of the update before the module it replaces, and then the MC
  restarts into the new version through its service instead. In place, the GenServer
  keeps its pid and its state migrated through every shape between, the supervisor
  runs exactly the new children, a child whose spec did not change keeps its pid, and
  no process but the one holding it runs replaced code. A restart ends the case: this
  VM cannot boot into the new release.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Prop.Upgrade, as: Services
  alias HalC2.Test.Mc
  alias HalC2.Upgrade
  alias HalC2.Upgrade.Source
  alias HalC2.Upgrade.Tree

  @ids [:a, :b, :c]

  property "an update installs in place, or restarts only when it must",
    numtests: HalC2.Prop.numtests(15) do
    forall cmds <- resize(6, commands(__MODULE__)) do
      trap_exit do
        setup()

        {history, state, result} =
          try do
            run_commands(__MODULE__, cmds)
          after
            teardown()
          end

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ------------------------------------------------------------------------

  # The version installed (0 the first), the counter's shape and the shapes its state
  # migrated from, the supervisor's children, and whether a process holds the
  # counter's code (`:current`, or `:old` once an update replaced it). `done` once the
  # MC restarted.
  def initial_state,
    do: %{vsn: 0, shape: 0, history: [], children: %{}, holder: :none, done: false}

  # Once the MC restarted, all that is left is to see that it stayed where it was.
  def command(%{done: true}), do: {:call, __MODULE__, :version, []}

  def command(state) do
    hold =
      if state.holder == :none,
        do: {:call, __MODULE__, :hold, []},
        else: {:call, __MODULE__, :let_go, []}

    frequency([
      {6, {:call, __MODULE__, :update, [boolean(), children()]}},
      {1, {:call, __MODULE__, :update_native, []}},
      {2, hold}
    ])
  end

  defp children,
    do: let(pairs <- list({oneof(@ids), range(1, 2)}), do: Map.new(pairs))

  def precondition(%{done: done}, {:call, _, :version, []}), do: done
  def precondition(%{done: true}, _call), do: false
  def precondition(%{holder: holder}, {:call, _, :hold, []}), do: holder == :none
  def precondition(%{holder: holder}, {:call, _, :let_go, []}), do: holder != :none
  def precondition(_state, _call), do: true

  def next_state(%{holder: :old} = state, _result, {:call, _, :update, _}),
    do: %{state | done: true}

  def next_state(state, _result, {:call, _, :update, [reshape, children]}) do
    shape = if reshape, do: state.shape + 1, else: state.shape
    history = if reshape, do: state.history ++ [state.shape], else: state.history
    holder = if state.holder == :current, do: :old, else: state.holder

    %{
      state
      | vsn: state.vsn + 1,
        shape: shape,
        history: history,
        children: children,
        holder: holder
    }
  end

  def next_state(state, _result, {:call, _, :update_native, []}), do: %{state | done: true}
  def next_state(state, _result, {:call, _, :version, []}), do: state
  def next_state(state, _result, {:call, _, :hold, []}), do: %{state | holder: :current}
  def next_state(state, _result, {:call, _, :let_go, []}), do: %{state | holder: :none}

  def postcondition(%{holder: :old} = state, {:call, _, :update, _}, result) do
    # The install stops before anything changes and rolls back, and the MC restarts
    # into the new version instead.
    match?(%{reply: {:ok, _}, restarted: true, version_moved: false}, result) and
      result.outcome["status"] == "rolled-back" and
      result.counter_vsn == state.vsn and
      result.counter_same_pid and
      result.counter_state == {state.shape, state.history} and
      Map.new(result.children, fn {id, {value, _pid}} -> {id, value} end) == state.children and
      Map.new(result.children, fn {id, {_value, pid}} -> {id, pid} end) == result.before and
      result.old_code == [result.holder]
  end

  def postcondition(state, {:call, _, :update, [reshape, children]}, result) do
    shape = if reshape, do: state.shape + 1, else: state.shape
    history = if reshape, do: state.history ++ [state.shape], else: state.history

    kept =
      for {id, value} <- children,
          state.children[id] == value,
          do: result.children[id] |> elem(1) == result.before[id]

    changed =
      for {id, value} <- children,
          Map.has_key?(state.children, id) and state.children[id] != value,
          do: result.children[id] |> elem(1) != result.before[id]

    holders_of_old = if state.holder == :current, do: [result.holder], else: []

    match?(%{reply: {:ok, _}, restarted: false, version_moved: true}, result) and
      result.counter_vsn == state.vsn + 1 and
      result.counter_same_pid and
      result.counter_state == {shape, history} and
      Map.new(result.children, fn {id, {value, _pid}} -> {id, value} end) == children and
      Enum.all?(kept) and Enum.all?(changed) and
      Enum.sort(result.old_code) == Enum.sort(holders_of_old)
  end

  def postcondition(_state, {:call, _, :update_native, []}, result),
    do:
      match?(%{reply: {:ok, _}, restarted: true, version_moved: false, nif_loaded: false}, result)

  def postcondition(state, {:call, _, :version, []}, result),
    do: result == "#{Process.get(:base)}#{if state.vsn > 0, do: "-#{state.vsn}"}"

  def postcondition(_state, {:call, _, :hold, []}, result), do: result == :lingering
  def postcondition(_state, {:call, _, :let_go, []}, result), do: result == :ok

  # --- commands ---------------------------------------------------------------------

  def update(reshape, children) do
    %{vsn: vsn, shape: shape} = Process.get(:versions)
    shape = if reshape, do: shape + 1, else: shape
    vsn = vsn + 1
    before = Map.new(children_now(), fn {id, {_value, pid}} -> {id, pid} end)
    counter = Process.whereis(Services.counter())
    counter_vsn_before = apply(Services.counter(), :vsn, [])

    result =
      install(vsn, [
        {Services.counter(), Services.counter(vsn, shape)},
        {Services.sup(), Services.sup(vsn, children)}
      ])

    if result.version_moved, do: Process.put(:versions, %{vsn: vsn, shape: shape})

    Map.merge(result, %{
      before: before,
      counter_vsn_before: counter_vsn_before,
      counter_vsn: apply(Services.counter(), :vsn, []),
      counter_same_pid: Process.whereis(Services.counter()) == counter,
      counter_state: apply(Services.counter(), :state, []),
      children: children_now(),
      holder: Process.get(:holder),
      old_code: old_code()
    })
  end

  def update_native do
    %{vsn: vsn, shape: shape} = Process.get(:versions)
    {nif, _} = native = Mc.nif_module(%{home: Process.get(:home)})

    result =
      install(vsn + 1, [
        {Services.counter(), Services.counter(vsn + 1, shape)},
        native
      ])

    Map.put(result, :nif_loaded, :code.is_loaded(nif) != false)
  end

  def version, do: Upgrade.version()

  def hold do
    parent = self()
    counter = Services.counter()
    pid = spawn(counter, :linger, [parent])

    receive do
      {:lingering, ^pid} ->
        Process.put(:holder, pid)
        :lingering
    end
  end

  def let_go do
    pid = Process.delete(:holder)
    ref = Process.monitor(pid)
    send(pid, :go)
    receive do: ({:DOWN, ^ref, :process, _, _} -> :ok)
  end

  # Builds a bundle of the next version holding `modules` (`{module, beam}`) over the
  # running ones, puts it in the cache and asks the MC to update to it.
  defp install(vsn, modules) do
    from = Upgrade.version()
    target = "#{Process.get(:base)}-#{vsn}"
    running = Process.get(:running)

    # The MC's code carries the tree sync, as `:hal_c2` does in a real release.
    {Tree, tree, _} = :code.get_object_code(Tree)

    entries =
      for {mod, beam} <- [{Tree, tree} | modules],
          do: if(cur = running[mod], do: {mod, beam, cur}, else: {mod, beam})

    archive = Mc.bundle(%{home: Process.get(:home)}, target, %{}, entries)
    :ok = Source.put(target, Upgrade.platform(), archive)
    reply = Upgrade.update(%{"targetVersion" => target})

    moved = Upgrade.version() == target
    # A restart leaves this VM where it was, with the service set to start `target`,
    # and exits for it once the reply has gone out.
    restarted = not moved and start_version() == target and await_restart()

    if moved do
      Process.put(:running, Map.merge(running, Map.new(modules)))
    end

    %{
      reply: reply,
      restarted: restarted,
      version_moved: moved,
      from: from,
      outcome: Upgrade.outcome()
    }
  end

  defp start_version do
    [_erts, vsn] =
      Path.join([Upgrade.release_root(), "releases", "start_erl.data"])
      |> File.read!()
      |> String.split()

    vsn
  end

  defp await_restart do
    receive do
      {:restart, 75} -> true
    after
      5_000 -> false
    end
  end

  defp children_now do
    for {id, pid, _, _} <- Supervisor.which_children(Services.sup()),
        is_pid(pid),
        into: %{},
        do: {id, {Agent.get(pid, & &1), pid}}
  end

  # Processes running code of the counter or the supervisor an update replaced.
  defp old_code do
    for pid <- Process.list(),
        mod <- [Services.counter(), Services.sup()],
        :erlang.check_process_code(pid, mod),
        uniq: true,
        do: pid
  end

  # --- a case's MC ------------------------------------------------------------------

  defp setup do
    home = HalC2.Prop.scratch_home("upgrade-release")
    base = "0.0.#{System.unique_integer([:positive])}"
    :persistent_term.erase({Upgrade, :outcome})
    :persistent_term.put({Upgrade, :version}, base)
    Process.put(:home, home)
    Process.put(:base, base)
    Process.put(:paths, :code.get_path())
    Process.put(:versions, %{vsn: 0, shape: 0})

    # Version 0 of each service runs, and is in the running release.
    running = %{
      Services.counter() => Services.counter(0, 0),
      Services.sup() => Services.sup(0, %{})
    }

    for {mod, beam} <- running do
      Mc.remember_module(mod)
      :code.purge(mod)
      {:module, ^mod} = :code.load_binary(mod, ~c"#{mod}.beam", beam)
    end

    Process.put(:running, running)
    root = Path.join(home, "release")
    HalC2.Test.Release.root(root, base, Mc.manifest(base))
    HalC2.Test.Release.write(root, base, Map.to_list(running), Mc.manifest(base))
    System.put_env("RELEASE_ROOT", root)
    System.put_env("HAL_C2_SERVICE", "1")
    test = self()
    Application.put_env(:hal_c2, :restart_exit, &send(test, {:restart, &1}))

    for spec <- [
          %{id: Services.counter(), start: {Services.counter(), :start_link, [nil]}},
          %{
            id: Services.sup(),
            start: {Services.sup(), :start_link, [nil]},
            type: :supervisor
          }
        ],
        do: {:ok, _} = Supervisor.start_child(HalC2.Supervisor, spec)

    HalC2.Prop.start_services([HalC2.Settings, HalC2.Upgrade])
  end

  defp teardown do
    HalC2.Prop.stop_services()

    if pid = Process.delete(:holder), do: Process.exit(pid, :kill)

    for id <- [Services.counter(), Services.sup()] do
      Supervisor.terminate_child(HalC2.Supervisor, id)
      Supervisor.delete_child(HalC2.Supervisor, id)
    end

    System.delete_env("RELEASE_ROOT")
    System.delete_env("HAL_C2_SERVICE")
    Application.delete_env(:hal_c2, :restart_exit)
    :persistent_term.erase({Upgrade, :version})
    :persistent_term.erase({Upgrade, :outcome})
    :code.set_path(Process.get(:paths))
    Mc.restore_modules()
    File.rm_rf(Process.get(:home))
  end
end
