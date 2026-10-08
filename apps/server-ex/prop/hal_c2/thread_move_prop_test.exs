defmodule HalC2.ThreadMovePropTest do
  @moduledoc """
  `HalC2.ThreadMove` across three MCs against a model of where each thread lives.

  Threads are created on any machine, renamed, and moved between the machines, back
  included. A move can also be held at a stage (the source about to send it, the
  destination having copied it or taking it, the source told it arrived) while other
  things happen: the process that started the move dies, `HalC2.ThreadMove` or the store
  restarts on either side, the thread is renamed, its queue resumed or it is moved
  again, other threads move.
  The held move then goes on, or ends where it was held, as a lost connection or a
  crashed machine ends it.

  Some threads are started by a plugin (`HalC2.Plugins.Host.launch_thread/4`), which
  each machine has installed and a case turns on and off (or whose manager restarts).

  The promises checked after every step: once a move settles, a thread lives on exactly
  one machine (the model's) with all its history and its attachment intact, the machines
  it left keep only a forwarding record, and no machine keeps a partial copy. A move
  refused or cut off before the destination took the thread leaves it where it was, and
  one cut off after that completes. A plugin's thread is refused while its plugin runs
  on the machine it lives on, and once moved it is an ordinary thread, its plugin's
  mark left behind.

  The machines are peers started once for the property (`HalC2.Prop.ThreadMoveCluster`);
  each case uses threads of its own.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Prop.ThreadMoveCluster, as: Cluster

  @moduletag timeout: :infinity

  @mcs [:a, :b, :c]
  @threads ["t1", "t2", "t3"]
  # How long a move cut off may take to settle; it settles on its own, so a case that
  # waits this long has found a move that never does.
  @settle 15_000
  # How `HalC2.Plugins.Host` marks the threads the plugin starts.
  @mark %{"id" => "prop-mover", "kind" => "review", "listed" => false}

  setup_all do
    machines = Cluster.start(Enum.map(@mcs, &Atom.to_string/1))

    :persistent_term.put(
      {__MODULE__, :mcs},
      Map.new(machines, fn {l, m} -> {String.to_atom(l), m.mc} end)
    )

    on_exit(fn -> Cluster.stop(machines) end)
    :ok
  end

  property "a thread lives on exactly one machine, whole, however its moves end or break off",
    numtests: HalC2.Prop.numtests(100),
    max_size: 30 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        Process.put(:case, "p#{System.unique_integer([:positive])}")
        {history, state, result} = run_commands(__MODULE__, cmds)
        cleanup(state)

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ------------------------------------------------------------------------

  # threads: name => %{at: mc, title: title, made: title it was created with,
  #   plugin: whether it still has the mark of the plugin that started it}
  # held: nil or %{t, from, to, stage, pid, mover, ref, killed, source_restarted}
  # running: the machines the plugin runs on
  def initial_state, do: %{threads: %{}, held: nil, running: []}

  def command(state) do
    made = Map.keys(state.threads)
    fresh = @threads -- made
    free = Enum.reject(made, &moving?(state, &1))
    # A move refused at once is never held: `move/3` covers it.
    holdable = Enum.reject(free, &pinned?(state, &1, state.threads[&1].at))

    frequency(
      [
        {1,
         {:call, __MODULE__, :restart, [oneof(@mcs), oneof([:thread_move, :store, :plugins])]}},
        {2, {:call, __MODULE__, :plugin, [oneof(@mcs), boolean()]}}
      ] ++
        if(fresh != [],
          do: [{3, {:call, __MODULE__, :create, [oneof(fresh), oneof(@mcs)]}}],
          else: []
        ) ++
        if(fresh != [] and state.running != [],
          do: [{3, {:call, __MODULE__, :create_plugin, [oneof(fresh), oneof(state.running)]}}],
          else: []
        ) ++
        if(free != [],
          do: [
            {4,
             let t <- oneof(free) do
               {:call, __MODULE__, :move, [t, state.threads[t].at, oneof(@mcs)]}
             end},
            {1,
             let t <- oneof(free) do
               {:call, __MODULE__, :move, [t, oneof(@mcs -- [state.threads[t].at]), oneof(@mcs)]}
             end},
            {2,
             let t <- oneof(free) do
               {:call, __MODULE__, :rename, [t, state.threads[t].at, title()]}
             end},
            {1,
             let t <- oneof(free) do
               {:call, __MODULE__, :resume_queue, [t, state.threads[t].at]}
             end}
          ],
          else: []
        ) ++
        if(holdable != [] and state.held == nil,
          do: [
            {4,
             let t <- oneof(holdable) do
               {:call, __MODULE__, :hold,
                [
                  t,
                  state.threads[t].at,
                  oneof(@mcs -- [state.threads[t].at]),
                  oneof([:sending, :staged, :taking, :accepted])
                ]}
             end}
          ],
          else: []
        ) ++
        if(state.held,
          do:
            [
              {3, {:call, __MODULE__, :release, [state.held, :go]}},
              {2, {:call, __MODULE__, :release, [state.held, :crash]}},
              {1, {:call, __MODULE__, :rename, [state.held.t, state.held.from, title()]}},
              {1, {:call, __MODULE__, :resume_queue, [state.held.t, state.held.from]}},
              {1, {:call, __MODULE__, :move, [state.held.t, state.held.from, oneof(@mcs)]}}
            ] ++
              if(state.held.stage in [:staged, :taking] and not state.held.killed,
                do: [{4, {:call, __MODULE__, :kill_mover, [state.held]}}],
                else: []
              ),
          else: []
        )
    )
  end

  defp title, do: let(n <- integer(1, 99), do: "title #{n}")

  def precondition(state, {:call, _, :create, [t, _]}), do: not is_map_key(state.threads, t)

  # A plugin starts threads only where it runs.
  def precondition(state, {:call, _, :create_plugin, [t, mc]}),
    do: not is_map_key(state.threads, t) and mc in state.running

  def precondition(state, {:call, _, :hold, [t, from, to, _]}),
    do:
      state.held == nil and is_map_key(state.threads, t) and state.threads[t].at == from and
        from != to and not pinned?(state, t, from)

  # The held move as the model has it (but for its ids, symbolic until run), so shrinking
  # drops a release of a hold it dropped.
  def precondition(state, {:call, _, fun, [held | _]}) when fun in [:release, :kill_mover],
    do: state.held != nil and Map.delete(held, :ids) == Map.delete(state.held, :ids)

  def precondition(state, {:call, _, :rename, [t, at, _]}),
    do: is_map_key(state.threads, t) and state.threads[t].at == at

  def precondition(state, {:call, _, :resume_queue, [t, at]}),
    do: is_map_key(state.threads, t) and state.threads[t].at == at

  def precondition(state, {:call, _, :move, [t, _from, _to]}), do: is_map_key(state.threads, t)
  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :create, [t, mc]}),
    do: put_in(state.threads[t], %{at: mc, title: t, made: t, plugin: false})

  def next_state(state, _result, {:call, _, :create_plugin, [t, mc]}),
    do: put_in(state.threads[t], %{at: mc, title: t, made: t, plugin: true})

  def next_state(state, _result, {:call, _, :plugin, [mc, running]}),
    do: %{state | running: if(running, do: [mc], else: []) ++ (state.running -- [mc])}

  def next_state(state, _result, {:call, _, :move, [t, from, to]}) do
    if moves?(state, t, from, to), do: arrive(state, t, to), else: state
  end

  def next_state(state, _result, {:call, _, :rename, [t, _at, title]}) do
    if moving?(state, t), do: state, else: put_in(state.threads[t].title, title)
  end

  def next_state(state, result, {:call, _, :hold, [t, from, to, stage]}) do
    held = %{
      t: t,
      from: from,
      to: to,
      stage: stage,
      ids: {:call, Kernel, :elem, [result, 0]},
      killed: false,
      source_restarted: false
    }

    %{state | held: held}
  end

  def next_state(state, _result, {:call, _, :release, [held, how]}) do
    cond do
      released?(state.held) -> %{state | held: nil}
      arrives?(state.held, how) -> %{arrive(state, held.t, held.to) | held: nil}
      true -> %{state | held: nil}
    end
  end

  def next_state(state, _result, {:call, _, :kill_mover, [_]}),
    do: put_in(state.held.killed, true)

  def next_state(%{held: %{from: mc}} = state, _result, {:call, _, :restart, [mc, :thread_move]}),
    do: put_in(state.held.source_restarted, true)

  def next_state(state, _result, _call), do: state

  # Whether a move of `t` from `from` to `to` moves it: only the machine it lives on
  # moves it, never while it is moving, never while the plugin that started it runs
  # there, and never to where it is.
  defp moves?(state, t, from, to),
    do:
      not moving?(state, t) and state.threads[t].at == from and from != to and
        not pinned?(state, t, from)

  # Whether `t` is a plugin's thread whose plugin runs on `mc`.
  defp pinned?(state, t, mc), do: state.threads[t].plugin and mc in state.running

  # A thread that arrives is an ordinary one: the plugin's mark stays behind.
  defp arrive(state, t, to),
    do: update_in(state.threads[t], &%{&1 | at: to, plugin: false})

  defp moving?(state, t),
    do: state.held != nil and state.held.t == t and not released?(state.held)

  # Whether a held move was called off before the destination asked to take the thread:
  # the process that started it died, or the source's `HalC2.ThreadMove` restarted and
  # settled it (it cannot tell a move still going from one a restart cut off). The
  # thread is then where it was, and free; the destination is refused when it asks.
  defp released?(held),
    do: held.stage in [:sending, :staged] and (held.killed or held.source_restarted)

  # Whether a held move ends with the thread on its destination. A move ends where it
  # was until the destination asks to take it (`:taking`); from then on it completes.
  defp arrives?(held, how),
    do: not released?(held) and (held.stage == :accepted or how == :go)

  def postcondition(state, {:call, _, fun, _} = call, {result, world})
      when fun in [:create, :create_plugin],
      do: result == :ok and settled?(next_state(state, nil, call), world, held(state))

  def postcondition(state, {:call, _, :plugin, [_, running]} = call, {result, world}),
    do: result == running and settled?(next_state(state, nil, call), world, held(state))

  def postcondition(state, {:call, _, :move, [t, from, to]} = call, {result, world}) do
    # Refused for its plugin, unless already moving or not here, which is said first.
    plugin? = pinned?(state, t, from) and state.threads[t].at == from and not moving?(state, t)

    told? =
      case result do
        {:ok, %{"status" => "moved"}} ->
          moves?(state, t, from, to)

        {:error, %{"code" => "thread_not_movable", "message" => message}} when plugin? ->
          message =~ "stays on this machine while"

        {:error, %{"code" => _}} ->
          not plugin? and not moves?(state, t, from, to)

        _ ->
          false
      end

    told? and settled?(next_state(state, nil, call), world, held(state))
  end

  def postcondition(state, {:call, _, :rename, [t | _]} = call, {result, world}) do
    # A moving thread is read-only: renaming it is refused, not lost when it leaves.
    match?({:ok, _}, result) != moving?(state, t) and
      settled?(next_state(state, nil, call), world, held(state))
  end

  # Its queue too: a resume while it moves is refused, as a rename is.
  def postcondition(state, {:call, _, :resume_queue, [t | _]}, {result, world}) do
    match?({:ok, _}, result) != moving?(state, t) and settled?(state, world, held(state))
  end

  def postcondition(_state, {:call, _, :hold, _}, {result, _world}),
    do: match?({:held, _}, result)

  def postcondition(state, {:call, _, :release, [_held, how]} = call, {result, world}) do
    arrives? = arrives?(state.held, how)

    told? =
      case result do
        {:ok, %{"status" => "moved"}} -> arrives?
        # The process that started the move died: no one is told.
        :gone -> true
        {:error, %{"code" => _}} -> not arrives?
        _ -> false
      end

    told? and settled?(next_state(state, result, call), world, [])
  end

  def postcondition(state, {:call, _, :kill_mover, _}, {:ok, world}),
    do: settled?(state, world, held(state))

  def postcondition(state, {:call, _, :restart, _}, {:ok, world}),
    do: settled?(state, world, held(state))

  def postcondition(_state, _call, _result), do: false

  defp held(%{held: nil}), do: []
  defp held(%{held: held} = state), do: if(moving?(state, held.t), do: [held.t], else: [])

  # Every thread but `skip` (a moving one) lives where the model says, whole, and only
  # there; with no move held, no machine keeps a partial copy.
  defp settled?(state, world, skip) do
    Enum.all?(state.threads, fn {t, thread} ->
      t in skip or
        Enum.all?(@mcs, fn mc ->
          copy = world.copies[t][mc]
          if mc == thread.at, do: copy == live(t, thread), else: copy in [:none, :forward]
        end)
    end) and (state.held != nil or Enum.all?(world.leftovers, fn {_, l} -> l == [] end))
  end

  defp live(t, thread) do
    id = id(t)
    attachment = :crypto.hash(:sha256, :binary.copy(:crypto.hash(:sha256, id), 37_500))
    messages = for n <- 1..3, do: "message #{n} of #{thread.made}"
    {:live, thread.title, messages, attachment, if(thread.plugin, do: @mark)}
  end

  # --- system under test -------------------------------------------------------------

  def create(t, mc) do
    result = Cluster.on(mcs()[mc], :create_thread, [id(t), "proj-#{mc}", t])
    {result, world()}
  end

  # The plugin running on `mc` starts `t` there.
  def create_plugin(t, mc) do
    result = Cluster.on(mcs()[mc], :create_plugin_thread, [id(t), "proj-#{mc}", t])
    {result, world()}
  end

  # Turns the plugin on or off on `mc`; returns whether it runs there.
  def plugin(mc, running) do
    result = Cluster.on(mcs()[mc], :plugin, [running])
    {result, world()}
  end

  # Moves `t` to `to`, asking the machine `from`, as a client connected there does.
  def move(t, from, to) do
    result =
      :erpc.call(
        mcs()[from],
        HalC2.ThreadMove,
        :move,
        [id(t), label(to), [project: "proj-#{to}", confirmed: true]],
        60_000
      )

    {result, world()}
  end

  def rename(t, at, title) do
    result = Cluster.on(mcs()[at], :rename, [id(t), title])
    {result, world()}
  end

  def resume_queue(t, at) do
    result = Cluster.on(mcs()[at], :resume_queue, [id(t)])
    {result, world()}
  end

  # Starts moving `t` from `from` to `to` and returns once it is held at `stage`:
  # `{:held, ids}`, or `{:ended, result}` if the move ended before getting there.
  def hold(t, from, to, stage) do
    id = id(t)
    where = if stage in [:sending, :accepted], do: from, else: to
    Cluster.on(mcs()[where], :hold, [id, stage, self()])
    ref = make_ref()
    mover = Cluster.on(mcs()[from], :start_move, [id, label(to), "proj-#{to}", self(), ref])
    monitor = Process.monitor(mover)

    receive do
      {:move_held, pid, ^stage, ^id} ->
        {{:held, %{pid: pid, mover: mover, ref: ref, monitor: monitor}}, world()}

      {:move_result, ^ref, result} ->
        Cluster.on(mcs()[where], :unhold, [id])
        {{:ended, result}, world()}
    after
      30_000 -> {{:ended, :timeout}, world()}
    end
  end

  # Lets a held move go on (`:go`) or ends it where it is held (`:crash`), and returns
  # what the move returned (`:gone` if the process that started it died) once the
  # thread has settled.
  def release(%{ids: {:held, ids}} = held, how) do
    stage_process = Process.monitor(ids.pid)
    send(ids.pid, how)

    result =
      if held.killed do
        :gone
      else
        receive do
          {:move_result, ref, result} when ref == ids.ref -> result
          {:DOWN, ref, :process, _, _} when ref == ids.monitor -> :gone
        after
          60_000 -> :timeout
        end
      end

    receive do
      {:DOWN, ^stage_process, :process, _, _} -> :ok
    after
      60_000 -> :ok
    end

    Process.demonitor(ids.monitor, [:flush])
    {result, await_settled(held.t)}
  end

  # The process that started the move dies (its client went away) while the
  # destination works on. The source settles it in a task, waited for here so that the
  # model's next step finds the thread released, or still moving, as the model says.
  def kill_mover(%{ids: {:held, ids}} = held) do
    Process.exit(ids.mover, :kill)

    receive do
      {:DOWN, ref, :process, _, _} when ref == ids.monitor -> :ok
    end

    :ok = Cluster.on(mcs()[held.from], :settled, [])
    {:ok, world()}
  end

  def restart(mc, service) do
    child = %{thread_move: HalC2.ThreadMove, store: HalC2.Store, plugins: HalC2.Plugins}[service]
    :ok = Cluster.on(mcs()[mc], :restart, [child])
    {:ok, world()}
  end

  # What every machine has of every thread of this case, and the partial copies each
  # keeps.
  defp world do
    copies =
      Map.new(@threads, fn t ->
        {t, Map.new(@mcs, fn mc -> {mc, Cluster.on(mcs()[mc], :copy, [id(t)])} end)}
      end)

    leftovers = Map.new(@mcs, fn mc -> {mc, Cluster.on(mcs()[mc], :leftovers, [])} end)
    %{copies: copies, leftovers: leftovers}
  end

  # The world once no machine has `t` moving and no partial copy is left, or as it is
  # after `@settle`: a move cut off settles on its own (`HalC2.ThreadMove`), as the
  # thread's streams tell.
  defp await_settled(t) do
    for mc <- @mcs, do: :ok = Cluster.on(mcs()[mc], :watch, [id(t), self()])
    await_settled(t, System.monotonic_time(:millisecond) + @settle)
  end

  defp await_settled(t, deadline) do
    world = world()

    settled? =
      Enum.all?(world.copies[t], fn {_, copy} -> not match?({:moving, _}, copy) end) and
        Enum.all?(world.leftovers, fn {_, l} -> l == [] end)

    left = deadline - System.monotonic_time(:millisecond)

    if settled? or left <= 0 do
      world
    else
      id = id(t)

      receive do
        {:hal_c2_stream, ^id, _} -> await_settled(t, deadline)
      after
        left -> world()
      end
    end
  end

  # A case leaves no move held and the plugin off, so the next starts from settled
  # machines.
  defp cleanup(state) do
    with %{held: %{ids: {:held, ids}} = held} <- state do
      send(ids.pid, :go)
      await_settled(held.t)
    end

    for mc <- @mcs, do: false = Cluster.on(mcs()[mc], :plugin, [false])
    :ok
  end

  defp id(t), do: "#{Process.get(:case)}-#{t}"
  defp label(mc), do: Atom.to_string(mc)
  defp mcs, do: :persistent_term.get({__MODULE__, :mcs})
end
