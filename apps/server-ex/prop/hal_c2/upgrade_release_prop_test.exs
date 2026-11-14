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

  An update whose `code_change/3` raises fails past the point of no return, and the
  release handler restarts the node on the release it ran (`init:restart/0`), which
  would restart this VM. So for it the case stands in for the release handler's
  install: it checks the generated relup marks the point of no return before the
  raising migration, runs the mark, and replies as the release handler does. Then
  nothing may restart the MC into the new version, the next boot must be the old one,
  and that boot says the update rolled back. It ends the case too.
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
  @continue "continueRunningThreads"

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
      {6, {:call, __MODULE__, :update, [boolean(), children(), boolean()]}},
      {1, {:call, __MODULE__, :update_native, [boolean()]}},
      {1, {:call, __MODULE__, :update_crash, [boolean()]}},
      {2, hold}
    ])
  end

  defp children,
    do: let(pairs <- list({oneof(@ids), range(1, 2)}), do: Map.new(pairs))

  def precondition(%{done: done}, {:call, _, :version, []}), do: done
  def precondition(%{done: true}, _call), do: false
  def precondition(%{holder: holder}, {:call, _, :hold, []}), do: holder == :none
  def precondition(%{holder: holder}, {:call, _, :let_go, []}), do: holder != :none
  # Old code still running is refused before the point of no return, so never crashes.
  def precondition(%{holder: holder}, {:call, _, :update_crash, _}), do: holder != :old
  def precondition(_state, _call), do: true

  def next_state(%{holder: :old} = state, _result, {:call, _, :update, _}),
    do: %{state | done: true}

  def next_state(state, _result, {:call, _, :update, [reshape, children, _continue]}) do
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

  def next_state(state, _result, {:call, _, :update_native, _}), do: %{state | done: true}
  def next_state(state, _result, {:call, _, :update_crash, _}), do: %{state | done: true}
  def next_state(state, _result, {:call, _, :version, []}), do: state
  def next_state(state, _result, {:call, _, :hold, []}), do: %{state | holder: :current}
  def next_state(state, _result, {:call, _, :let_go, []}), do: %{state | holder: :none}

  def postcondition(%{holder: :old} = state, {:call, _, :update, [_, _, continue]}, result) do
    # The install stops before anything changes and rolls back, and the MC restarts
    # into the new version instead.
    match?(%{reply: {:ok, _}, restarted: true, version_moved: false}, result) and
      continued?(result, continue) and
      result.outcome["status"] == "rolled-back" and
      result.counter_vsn == state.vsn and
      result.counter_same_pid and
      result.counter_state == {state.shape, state.history} and
      Map.new(result.children, fn {id, {value, _pid}} -> {id, value} end) == state.children and
      Map.new(result.children, fn {id, {_value, pid}} -> {id, pid} end) == result.before and
      result.old_code == [result.holder]
  end

  def postcondition(state, {:call, _, :update, [reshape, children, _continue]}, result) do
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
      not continued?(result) and
      result.counter_vsn == state.vsn + 1 and
      result.counter_same_pid and
      result.counter_state == {shape, history} and
      Map.new(result.children, fn {id, {value, _pid}} -> {id, value} end) == children and
      Enum.all?(kept) and Enum.all?(changed) and
      Enum.sort(result.old_code) == Enum.sort(holders_of_old)
  end

  def postcondition(_state, {:call, _, :update_native, [continue]}, result),
    do:
      match?(%{reply: {:ok, _}, restarted: true, version_moved: false, nif_loaded: false}, result) and
        continued?(result, continue)

  def postcondition(_state, {:call, _, :update_crash, _}, result) do
    match?(%{reply: {:error, _}, marked: true, version_moved: false, restarted: false}, result) and
      not continued?(result) and not result.rebooted_continue and
      result.start == result.from and not result.previous? and
      result.outcome["status"] == "rolled-back" and
      result.rebooted["status"] == "rolled-back" and result.start_after_boot == result.from
  end

  def postcondition(state, {:call, _, :version, []}, result),
    do: result == release(state.vsn)

  def postcondition(_state, {:call, _, :hold, []}, result), do: result == :lingering
  def postcondition(_state, {:call, _, :let_go, []}, result), do: result == :ok

  # A restart carries `continueRunningThreads` as asked to the boot it is for, which
  # takes it off the outcome; nothing else ever records it.
  defp continued?(result, continue),
    do:
      result.restarting[@continue] == continue and result.booted.continue == continue and
        not Map.has_key?(result.booted.outcome, @continue)

  defp continued?(result),
    do: Map.has_key?(result.outcome || %{}, @continue) or Upgrade.continue_threads?()

  # --- commands ---------------------------------------------------------------------

  def update(reshape, children, continue) do
    %{vsn: vsn, shape: shape} = Process.get(:versions)
    shape = if reshape, do: shape + 1, else: shape
    vsn = vsn + 1
    before = Map.new(children_now(), fn {id, {_value, pid}} -> {id, pid} end)
    counter = Process.whereis(Services.counter())
    counter_vsn_before = apply(Services.counter(), :vsn, [])

    result =
      install(
        vsn,
        [
          {Services.counter(), Services.counter(vsn, shape)},
          {Services.sup(), Services.sup(vsn, children)}
        ],
        continue
      )

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

  def update_native(continue) do
    %{vsn: vsn, shape: shape} = Process.get(:versions)
    {nif, _} = native = Mc.nif_module(%{home: Process.get(:home)})

    result =
      install(
        vsn + 1,
        [
          {Services.counter(), Services.counter(vsn + 1, shape)},
          native
        ],
        continue
      )

    Map.put(result, :nif_loaded, :code.is_loaded(nif) != false)
  end

  def update_crash(continue) do
    %{vsn: vsn, shape: shape} = Process.get(:versions)
    test = self()
    counter = Process.whereis(Services.counter())
    Application.put_env(:hal_c2, :install_release, &crash(&1, &2, test, counter))

    result =
      try do
        install(
          vsn + 1,
          [{Services.counter(), Services.counter(vsn + 1, shape, true)}],
          continue
        )
      after
        Application.delete_env(:hal_c2, :install_release)
      end

    start = start_version()
    previous? = File.exists?(previous_start())
    # The node comes back on the release it ran, and reads how the update went.
    :persistent_term.erase({Upgrade, :outcome})
    HalC2.Prop.restart_service(HalC2.Upgrade)
    :ok = Upgrade.await_pruned()

    Map.merge(result, %{
      marked:
        receive do
          {:marked, ok} -> ok
        after
          0 -> false
        end,
      start: start,
      previous?: previous?,
      rebooted: Upgrade.outcome(),
      rebooted_continue: Upgrade.continue_threads?(),
      start_after_boot: start_version()
    })
  end

  # The release handler's install of a relup whose migration raises, up to its reply:
  # the mark this MC's relup carries right after the point of no return runs, and the
  # migration fails after it.
  defp crash(vsn, _opts, test, counter) do
    path = Path.join([Upgrade.release_root(), "releases", to_string(vsn), "relup"])
    {:ok, [{_, [{_, _, script}], _}]} = :file.consult(String.to_charlist(path))
    {_, [:point_of_no_return | rest]} = Enum.split_while(script, &(&1 != :point_of_no_return))

    with [{:apply, {:persistent_term, :put, [_, ^vsn]} = {m, f, a}} | after_mark] <- rest,
         true <- Enum.any?(after_mark, &match?({:code_change, :up, [{_, _}]}, &1)) do
      apply(m, f, a)
      send(test, {:marked, true})
    end

    {:error,
     {:code_change_failed, counter, Services.counter(), :undefined,
      {:EXIT, {:migration_broke, []}}}}
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
  defp install(vsn, modules, continue) do
    from = Upgrade.version()
    target = release(vsn)
    running = Process.get(:running)

    # The MC's code carries the tree sync, as `:hal_c2` does in a real release.
    {Tree, tree, _} = :code.get_object_code(Tree)

    entries =
      for {mod, beam} <- [{Tree, tree} | modules],
          do: if(cur = running[mod], do: {mod, beam, cur}, else: {mod, beam})

    archive = Mc.bundle(%{home: Process.get(:home)}, target, %{}, entries)
    :ok = Source.put(target, Upgrade.platform(), archive)
    reply = Upgrade.update(%{"targetVersion" => target, @continue => continue})

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
    |> Map.merge(if restarted, do: boot_into(target), else: %{})
  end

  # The restart's boot into `target`, as far as the update's outcome goes: what it was
  # left with and what the boot made of it. This VM stays on the version it ran.
  defp boot_into(target) do
    restarting =
      JSON.decode!(File.read!(Path.join([HalC2.Paths.data_dir(), "upgrades", "outcome.json"])))

    ran = :persistent_term.get({Upgrade, :version}, nil)
    :persistent_term.put({Upgrade, :version}, target)

    try do
      HalC2.Prop.restart_service(HalC2.Upgrade)
      # Once the boot has read the outcome and removed old versions.
      :ok = Upgrade.await_pruned()
      booted = %{continue: Upgrade.continue_threads?(), outcome: Upgrade.outcome()}
      %{restarting: restarting, booted: booted}
    after
      if ran,
        do: :persistent_term.put({Upgrade, :version}, ran),
        else: :persistent_term.erase({Upgrade, :version})
    end
  end

  defp start_version do
    [_erts, vsn] =
      Path.join([Upgrade.release_root(), "releases", "start_erl.data"])
      |> File.read!()
      |> String.split()

    vsn
  end

  defp previous_start,
    do: Path.join([Upgrade.release_root(), "releases", "start_erl.data.previous"])

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

  # The case's `vsn`th release, each newer than the last: the MC refuses to move back
  # without being asked to.
  defp release(vsn), do: "0.#{Process.get(:minor)}.#{vsn}"

  defp setup do
    home = HalC2.Prop.scratch_home("upgrade-release")
    Process.put(:minor, System.unique_integer([:positive]))
    base = release(0)
    :persistent_term.erase({Upgrade, :outcome})
    :persistent_term.put({Upgrade, :version}, base)
    Process.put(:home, home)
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
    Application.delete_env(:hal_c2, :install_release)
    :persistent_term.erase({Upgrade, :version})
    :persistent_term.erase({Upgrade, :outcome})
    # A case's simulated reboot can leave this set; the next property in the VM
    # would read it as this boot's answer (`Recovery.deliverable?/2` does).
    :persistent_term.erase({Upgrade, :continue_threads})
    :code.set_path(Process.get(:paths))
    Mc.restore_modules()
    File.rm_rf(Process.get(:home))
  end
end
