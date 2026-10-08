defmodule HalC2.ShellPropTest do
  @moduledoc """
  `HalC2.Shell` against a model of the cluster sidebar: this MC's rows and its
  `{epoch, rev}` version, a few simulated members with versions of their own, and
  clients that subscribe from what they hold and resume after a disconnect.

  Members are played by this test through `:shell_transport` (`Wire`): the shell's
  casts to a member arrive here, and the member answers as a real one would. After
  every command the test settles the exchange: it syncs with the shell, answers
  what the shell sent, and repeats until nothing is left, so the model can say what
  every party holds at rest.

  The promises checked:

    * the shell holds this MC's rows, as the store has them after a restart, and
      every connected member's rows as that member has them;
    * a member holds this MC's rows as of the shell's version;
    * a client resuming from a version is sent exactly the rows changed after it,
      or everything with `reset` when the version is of another epoch, and from then
      on holds what the shell holds, never seeing a version go back within an epoch;
    * a forgotten member's rows are gone and stay gone;
    * subscribers stay subscribed across a restart of the shell;
    * a reader of the table, during a restart or a member's reset, never finds a
      row missing that is there before and after.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Shell, Store}

  @moduletag timeout: :infinity

  @streams ~w(s1 s2 s3)
  @peers [:"pa@prop.invalid", :"pb@prop.invalid"]
  @clients [:c1, :c2]

  defmodule Wire do
    @moduledoc false
    # Stands in for Erlang distribution: casts to a connected member come to the
    # test process as `{:wire, peer, message}`.

    def connected do
      [{_, peers}] = :ets.lookup(__MODULE__, :connected)
      peers
    end

    def cast(peer, message) do
      [{_, owner}] = :ets.lookup(__MODULE__, :owner)
      if peer in connected(), do: send(owner, {:wire, peer, message})
      :ok
    end
  end

  property "the shell's rows, versions and subscribers keep its promises",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        setup_case()
        {history, state, result} = run_commands(__MODULE__, cmds)
        teardown_case()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ------------------------------------------------------------------

  # rows: this MC's rows as the shell holds them, `id => {kind_row, rev}`; stored:
  # the store's. peers: each member's own rows and whether it is connected. held:
  # what the shell holds of a member, `%{v: {epoch, rev}, rows:}`. clients: `:off`,
  # `:on`, or `{:held, view}` with the shell's view when it went away.
  def initial_state do
    initial = Map.new(@streams, &{&1, {initial_row(&1), 0}})

    %{
      run: 0,
      rev: 0,
      rows: initial,
      stored: Map.new(initial, fn {id, {kind_row, _}} -> {id, kind_row} end),
      peers: Map.new(@peers, &{&1, %{run: 0, rev: 0, rows: %{}, connected: false}}),
      held: %{},
      clients: Map.new(@clients, &{&1, :off})
    }
  end

  def command(state) do
    connected = for {p, %{connected: true}} <- state.peers, do: p
    down = @peers -- connected
    off = for {c, status} <- state.clients, status != :on, do: c
    on = for {c, :on} <- state.clients, do: c

    frequency(
      [
        {6, {:call, __MODULE__, :put_local, [oneof(@streams), title()]}},
        {1, {:call, __MODULE__, :put_stored_only, [oneof(@streams), title()]}},
        {2, {:call, __MODULE__, :restart, []}},
        {5, {:call, __MODULE__, :peer_put, [oneof(@peers), stream_id(), title()]}},
        {1, {:call, __MODULE__, :peer_restart, [oneof(@peers)]}},
        {3, {:call, __MODULE__, :check, []}}
      ] ++
        if(down != [], do: [{3, {:call, __MODULE__, :peer_up, [oneof(down)]}}], else: []) ++
        if(connected != [],
          do: [
            {1, {:call, __MODULE__, :peer_down, [oneof(connected)]}},
            {1, {:call, __MODULE__, :peer_put_lost, [oneof(connected), stream_id(), title()]}}
          ],
          else: []
        ) ++
        if(state.held != %{},
          do: [{1, {:call, __MODULE__, :forget, [oneof(Map.keys(state.held))]}}],
          else: []
        ) ++
        if(off != [],
          do: [{3, {:call, __MODULE__, :subscribe, [oneof(off), boolean()]}}],
          else: []
        ) ++
        if(on != [], do: [{2, {:call, __MODULE__, :disconnect, [oneof(on)]}}], else: [])
    )
  end

  defp title, do: oneof(["a", "b", "c"])
  defp stream_id, do: oneof(["r1", "r2", "r3"])

  def precondition(state, {:call, _, :peer_up, [p]}), do: not state.peers[p].connected
  def precondition(state, {:call, _, :peer_down, [p]}), do: state.peers[p].connected
  def precondition(state, {:call, _, :peer_put_lost, [p, _, _]}), do: state.peers[p].connected
  def precondition(state, {:call, _, :forget, [p]}), do: Map.has_key?(state.held, p)
  def precondition(state, {:call, _, :subscribe, [c, _]}), do: state.clients[c] != :on
  def precondition(state, {:call, _, :disconnect, [c]}), do: state.clients[c] == :on
  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :put_local, [id, title]}) do
    kind_row = row(id, title)
    state = put_in(state.stored[id], kind_row)

    case state.rows[id] do
      {^kind_row, _} ->
        state

      _ ->
        rev = state.rev + 1
        %{state | rev: rev, rows: Map.put(state.rows, id, {kind_row, rev})}
    end
  end

  def next_state(state, _result, {:call, _, :put_stored_only, [id, title]}),
    do: put_in(state.stored[id], row(id, title))

  def next_state(state, _result, {:call, _, :restart, []}) do
    %{
      state
      | run: state.run + 1,
        rev: 0,
        rows: Map.new(state.stored, fn {id, kind_row} -> {id, {kind_row, 0}} end)
    }
    |> sync_connected()
  end

  def next_state(state, _result, {:call, _, :peer_up, [p]}),
    do: state |> put_in([:peers, p, :connected], true) |> sync(p)

  def next_state(state, _result, {:call, _, :peer_down, [p]}),
    do: put_in(state.peers[p].connected, false)

  def next_state(state, _result, {:call, _, :peer_put, [p, id, title]}) do
    # An unchanged row is not sent, so whatever was lost stays lost.
    case state.peers[p].rows[id] do
      {kind_row, _} when kind_row == {"thread", %{"id" => id, "title" => title}} -> state
      _ -> state |> peer_change(p, id, title) |> sync(p)
    end
  end

  def next_state(state, _result, {:call, _, :peer_put_lost, [p, id, title]}),
    do: peer_change(state, p, id, title)

  def next_state(state, _result, {:call, _, :peer_restart, [p]}) do
    peer = state.peers[p]
    rows = Map.new(peer.rows, fn {id, {kind_row, _}} -> {id, {kind_row, 0}} end)
    state |> put_in([:peers, p], %{peer | run: peer.run + 1, rev: 0, rows: rows}) |> sync(p)
  end

  def next_state(state, _result, {:call, _, :forget, [p]}) do
    %{state | held: Map.delete(state.held, p)}
    |> put_in([:peers, p, :connected], false)
  end

  def next_state(state, _result, {:call, _, :subscribe, [c, _keep?]}),
    do: put_in(state.clients[c], :on)

  def next_state(state, _result, {:call, _, :disconnect, [c]}),
    do: put_in(state.clients[c], {:held, shell_view(state)})

  def next_state(state, _result, _call), do: state

  defp peer_change(state, p, id, title) do
    peer = state.peers[p]
    kind_row = row(id, title)

    case peer.rows[id] do
      {^kind_row, _} ->
        state

      _ ->
        rev = peer.rev + 1
        put_in(state.peers[p], %{peer | rev: rev, rows: Map.put(peer.rows, id, {kind_row, rev})})
    end
  end

  # A connected member's rows reach the shell whole, whatever was lost on the way.
  defp sync(state, p) do
    peer = state.peers[p]

    if peer.connected,
      do: put_in(state.held[p], %{v: {peer_epoch(p, peer.run), peer.rev}, rows: peer.rows}),
      else: state
  end

  defp sync_connected(state), do: Enum.reduce(@peers, state, &sync(&2, &1))

  # Every MC the shell knows, as `%{v: {epoch, rev}, rows: id => {kind_row, rev}}`.
  defp shell_view(state),
    do: Map.put(state.held, :local, %{v: {{:local, state.run}, state.rev}, rows: state.rows})

  def postcondition(state, {:call, _, :subscribe, [c, keep?]}, reply) do
    have =
      case state.clients[c] do
        {:held, view} when keep? -> view
        _ -> %{}
      end

    expected =
      Map.new(shell_view(state), fn {mc, %{v: {epoch, rev} = v, rows: rows}} ->
        {reset?, after_rev} =
          case have[mc] do
            %{v: {^epoch, held}} when epoch != nil and held <= rev -> {false, held}
            _ -> {true, -1}
          end

        sent = for {id, {kind_row, r}} <- rows, r > after_rev, into: %{}, do: {id, kind_row}
        {mc, %{v: v, reset: reset?, rows: sent}}
      end)

    ok?(reply.sent == expected and reply.errors == [], {:subscribe, expected, reply})
  end

  def postcondition(state, {:call, _, :check, []}, actual) do
    view = shell_view(state)

    plain_rows = fn %{rows: rows} ->
      Map.new(rows, fn {id, {kind_row, _}} -> {id, kind_row} end)
    end

    rows = for {mc, entry} <- view, entry.rows != %{}, into: %{}, do: {mc, plain_rows.(entry)}
    local = view.local

    clients =
      for {c, :on} <- state.clients,
          into: %{},
          do:
            {c,
             %{
               view: Map.new(view, fn {mc, e} -> {mc, %{v: e.v, rows: plain_rows.(e)}} end),
               errors: []
             }}

    peers_hold =
      for {p, %{connected: true}} <- state.peers,
          into: %{},
          do: {p, %{v: local.v, rows: plain_rows.(local)}}

    expected = %{
      version: local.v,
      rows: rows,
      mcs: Enum.sort(Map.keys(view)),
      clients: clients,
      plain: %{rows: plain_rows.(local), errors: []},
      peers_hold: peers_hold
    }

    ok?(actual == expected, {:check, expected, actual})
  end

  # Readers never find a row missing that is there before and after.
  def postcondition(_state, {:call, _, cmd, _}, %{reader: reader})
      when cmd in [:restart, :peer_up, :peer_restart],
      do: ok?(reader == %{missing: [], crashes: 0}, {:reader, reader})

  def postcondition(_state, _call, result), do: result == :ok

  defp ok?(true, _detail), do: true

  defp ok?(false, detail) do
    IO.puts("postcondition failed: #{inspect(detail, pretty: true, limit: :infinity)}")
    false
  end

  # --- system under test --------------------------------------------------------

  defp initial_row(id), do: row(id, "init")
  defp row(id, title), do: {"thread", %{"id" => id, "title" => title}}
  defp peer_epoch(p, run), do: "#{p}:#{run}"
  defp descriptor(p), do: %{"environmentId" => "env-#{p}", "label" => "#{p}"}

  defp setup_case do
    HalC2.Prop.scratch_home("shell")
    Application.put_env(:hal_c2, :shell_transport, Wire)
    if :ets.whereis(Wire) != :undefined, do: :ets.delete(Wire)
    :ets.new(Wire, [:named_table, :public])
    :ets.insert(Wire, [{:owner, self()}, {:connected, []}])

    sup = HalC2.Prop.start_services([{Store, path: Store.home_path()}])

    for id <- @streams do
      {:ok, _} = Store.append([{:thread, id, [{"thread", id, %{"s" => %{"id" => id}}}]}])
      :ok = Store.put_shell(id, 1, initial_row(id))
    end

    {:ok, _} = Supervisor.start_child(sup, Shell)

    peers =
      Map.new(@peers, &{&1, %{run: 0, rev: 0, rows: %{}, local: nil}})

    plain = spawn_collector(:plain, Map.new(@streams, &{&1, initial_row(&1)}))
    send(plain, {:subscribe_plain, self()})
    assert_receive :subscribed, 5_000

    Process.put(:world, %{
      peers: peers,
      clients: %{},
      plain: plain,
      epochs: %{elem(Shell.version(), 0) => 0},
      run: 0,
      seq: 1
    })
  end

  defp teardown_case do
    world = Process.delete(:world)
    for {_, %{pid: pid}} when pid != nil <- world.clients, do: Process.exit(pid, :kill)
    Process.exit(world.plain, :kill)
    HalC2.Prop.stop_services()
    :ets.delete(Wire)
    Application.delete_env(:hal_c2, :shell_transport)
    flush_wire()
  end

  defp flush_wire do
    receive do
      {:wire, _, _} -> flush_wire()
    after
      0 -> :ok
    end
  end

  defp world, do: Process.get(:world)
  defp update_world(fun), do: Process.put(:world, fun.(world()))

  # A stream server's way: the row is stored, then the shell is told.
  def put_local(id, title) do
    store(id, title)
    Shell.put_row(id, row(id, title))
    settle()
  end

  # The row reached the store, and the shell went down before it was told.
  def put_stored_only(id, title) do
    store(id, title)
    :ok
  end

  defp store(id, title) do
    update_world(&%{&1 | seq: &1.seq + 1})
    :ok = Store.put_shell(id, world().seq, row(id, title))
  end

  # The server alone stops and starts again, as a crash would.
  def restart do
    reading(fn ->
      :ok = Supervisor.terminate_child(HalC2.Shell.Supervisor, Shell)
      {:ok, _} = Supervisor.restart_child(HalC2.Shell.Supervisor, Shell)
      {epoch, 0} = Shell.version()
      update_world(&%{&1 | run: &1.run + 1, epochs: Map.put(&1.epochs, epoch, &1.run + 1)})
      settle()
    end)
  end

  def peer_up(p) do
    reading(fn ->
      :ets.insert(Wire, {:connected, [p | Wire.connected()]})
      send(Shell, {:nodeup, p})
      # The member sees this MC come up too.
      peer_cast(p, {:peer_hello, p, peer(p).local && elem(peer(p).local, 0), false})
      settle()
    end)
  end

  def peer_down(p) do
    :ets.insert(Wire, {:connected, Wire.connected() -- [p]})
    send(Shell, {:nodedown, p})
    settle()
  end

  def peer_put(p, id, title), do: member_change(p, id, title, true)
  def peer_put_lost(p, id, title), do: member_change(p, id, title, false)

  defp member_change(p, id, title, deliver?) do
    peer = peer(p)
    kind_row = row(id, title)

    case peer.rows[id] do
      {^kind_row, _} ->
        :ok

      _ ->
        rev = peer.rev + 1
        put_peer(p, %{peer | rev: rev, rows: Map.put(peer.rows, id, {kind_row, rev})})

        if deliver?,
          do:
            peer_cast(
              p,
              {:peer_rows, p, {peer_epoch(p, peer.run), rev}, peer.rev, [{id, kind_row, rev}],
               false}
            )

        settle()
    end
  end

  # The member's shell starts again: a new epoch, its rows at rev 0, and nothing
  # held of this MC. A connected one says hello and asks to be told back.
  def peer_restart(p) do
    reading(fn ->
      peer = peer(p)
      rows = Map.new(peer.rows, fn {id, {kind_row, _}} -> {id, {kind_row, 0}} end)
      put_peer(p, %{peer | run: peer.run + 1, rev: 0, rows: rows, local: nil})
      peer_cast(p, {:peer_hello, p, nil, true})
      settle()
    end)
  end

  # The member is removed from the cluster; rows it had already sent arrive after
  # the shell forgot it, then the connection goes.
  def forget(p) do
    Shell.forget("env-#{p}")
    peer = peer(p)

    all = for {id, {kind_row, rev}} <- peer.rows, do: {id, kind_row, rev}
    peer_cast(p, {:peer_environment, p, descriptor(p)})
    peer_cast(p, {:peer_rows, p, {peer_epoch(p, peer.run), peer.rev}, 0, all, true})
    put_peer(p, %{peer | local: nil})
    :ets.insert(Wire, {:connected, Wire.connected() -- [p]})
    send(Shell, {:nodedown, p})
    settle()
  end

  # A client connects with what it kept (or nothing), and is sent what it lacks.
  def subscribe(c, keep?) do
    view =
      case world().clients[c] do
        %{view: view} when keep? -> view
        _ -> %{}
      end

    pid = spawn_collector(:client, view)
    send(pid, {:subscribe, self()})
    assert_receive {:subscribed, ^pid, sent, errors}, 5_000
    update_world(&put_in(&1.clients[c], %{pid: pid, view: nil}))
    settle()
    %{sent: translate_sent(sent), errors: errors}
  end

  def disconnect(c) do
    %{pid: pid} = world().clients[c]
    %{view: view} = collector_view(pid)
    Process.exit(pid, :kill)
    update_world(&put_in(&1.clients[c], %{pid: nil, view: view}))
    :ok
  end

  def check do
    settle()

    rows =
      Shell.rows()
      |> Enum.group_by(fn {{mc, _}, _} -> mc_key(mc) end, fn {{_, id}, kind_row} ->
        {id, kind_row}
      end)
      |> Map.new(fn {mc, rows} -> {mc, Map.new(rows)} end)

    clients =
      for {c, %{pid: pid}} when pid != nil <- world().clients, into: %{} do
        %{view: view, errors: errors} = collector_view(pid)
        {c, %{view: translate_view(view), errors: errors}}
      end

    %{view: plain, errors: plain_errors} = collector_view(world().plain)

    peers_hold =
      for p <- Wire.connected(), into: %{} do
        {version, rows} = peer(p).local || {nil, %{}}
        {p, %{v: translate_version(version), rows: rows}}
      end

    %{
      version: translate_version(Shell.version()),
      rows: rows,
      mcs: Shell.environments() |> Enum.map(&mc_key(elem(&1, 0))) |> Enum.sort(),
      clients: clients,
      plain: %{rows: plain, errors: plain_errors},
      peers_hold: peers_hold
    }
  end

  # --- simulated members ----------------------------------------------------------

  defp peer(p), do: world().peers[p]
  defp put_peer(p, peer), do: update_world(&put_in(&1.peers[p], peer))
  # A member that is not connected reaches nobody.
  defp peer_cast(p, message), do: if(p in Wire.connected(), do: GenServer.cast(Shell, message))

  # Syncs with the shell, which has then handled everything sent to it and sent
  # its own casts, answers those as the members would, and repeats until quiet.
  defp settle do
    Shell.version()

    receive do
      {:wire, p, message} ->
        on_wire(p, message)
        settle()
    after
      0 -> :ok
    end
  end

  defp on_wire(_p, {:peer_environment, _mc, _descriptor}), do: :ok

  defp on_wire(p, {:peer_hello, _mc, have, ask_back?}) do
    peer = peer(p)
    peer_cast(p, {:peer_environment, p, descriptor(p)})
    version = {peer_epoch(p, peer.run), peer.rev}

    {from, reset?} =
      case have do
        {epoch, held} when epoch == elem(version, 0) and held <= peer.rev -> {held, false}
        _ -> {0, true}
      end

    rows = for {id, {kind_row, rev}} <- peer.rows, reset? or rev > from, do: {id, kind_row, rev}
    peer_cast(p, {:peer_rows, p, version, from, rows, reset?})
    if ask_back?, do: peer_cast(p, {:peer_hello, p, peer.local && elem(peer.local, 0), false})
  end

  defp on_wire(p, {:peer_rows, _mc, {epoch, rev}, from, rows, reset?}) do
    peer = peer(p)
    {{held_epoch, held_rev}, held_rows} = peer.local || {{nil, 0}, %{}}
    plain = Map.new(rows, fn {id, kind_row, _} -> {id, kind_row} end)

    cond do
      reset? ->
        put_peer(p, %{peer | local: {{epoch, rev}, plain}})

      epoch == held_epoch and from <= held_rev ->
        put_peer(p, %{peer | local: {{epoch, max(rev, held_rev)}, Map.merge(held_rows, plain)}})

      true ->
        peer_cast(p, {:peer_hello, p, {held_epoch, held_rev}, false})
    end
  end

  # --- clients and readers ------------------------------------------------------

  # A subscriber that applies what it is sent to its view of every MC's rows, and
  # records anything that breaks the promises: a version going back within an
  # epoch, or rows of another epoch without a reset.
  defp spawn_collector(kind, view) do
    spawn(fn -> gather(kind, view, []) end)
  end

  defp gather(:plain = kind, view, errors) do
    receive do
      {:subscribe_plain, parent} ->
        :ok = Shell.subscribe(self())
        send(parent, :subscribed)
        gather(kind, view, errors)

      {:hal_c2_shell, {:rows, mc, rows}} ->
        view = if mc == node(), do: Map.merge(view, Map.new(rows)), else: view
        gather(kind, view, errors)

      {:hal_c2_shell, _other} ->
        gather(kind, view, errors)

      {:view, parent} ->
        {view, errors} = drain(kind, view, errors)
        send(parent, {:view, self(), %{view: view, errors: errors}})
        gather(kind, view, errors)
    end
  end

  defp gather(:client = kind, view, errors) do
    receive do
      {:subscribe, parent} ->
        have = Map.new(view, fn {mc, %{epoch: e, rev: r}} -> {Atom.to_string(mc), {e, r}} end)
        %{mcs: mcs, rows: rows} = Shell.subscribe(self(), have)
        by_mc = Enum.group_by(rows, &elem(&1, 0), fn {_, id, kind, row} -> {id, {kind, row}} end)

        {view, errors} =
          Enum.reduce(mcs, {%{}, errors}, fn mc, {acc, errors} ->
            sent = Map.new(Map.get(by_mc, mc.mc, []))
            held = view[mc.mc]

            {base, errors} =
              cond do
                mc.reset ->
                  {%{}, errors}

                held == nil ->
                  {%{}, [{:resumed_unknown, mc.mc} | errors]}

                held.epoch != mc.epoch or held.rev > mc.rev ->
                  {held.rows, [{:resumed_back, mc} | errors]}

                true ->
                  {held.rows, errors}
              end

            entry = %{epoch: mc.epoch, rev: mc.rev, rows: Map.merge(base, sent)}
            {Map.put(acc, mc.mc, entry), errors}
          end)

        sent =
          Map.new(mcs, fn mc ->
            {mc.mc,
             %{
               epoch: mc.epoch,
               rev: mc.rev,
               reset: mc.reset,
               rows: Map.new(Map.get(by_mc, mc.mc, []))
             }}
          end)

        send(parent, {:subscribed, self(), sent, errors})
        gather(kind, view, errors)

      {:hal_c2_shell, message} ->
        {view, errors} = apply_message(view, errors, message)
        gather(kind, view, errors)

      {:view, parent} ->
        {view, errors} = drain(kind, view, errors)
        send(parent, {:view, self(), %{view: view, errors: Enum.reverse(errors)}})
        gather(kind, view, errors)
    end
  end

  # Syncs with the shell, which has then sent this process everything before, and
  # applies it.
  defp drain(kind, view, errors) do
    Shell.version()
    drain_messages(kind, view, errors)
  end

  defp drain_messages(kind, view, errors) do
    receive do
      {:hal_c2_shell, {:rows, mc, rows}} when kind == :plain ->
        view = if mc == node(), do: Map.merge(view, Map.new(rows)), else: view
        drain_messages(kind, view, errors)

      {:hal_c2_shell, message} when kind == :client ->
        {view, errors} = apply_message(view, errors, message)
        drain_messages(kind, view, errors)

      {:hal_c2_shell, _} ->
        drain_messages(kind, view, errors)
    after
      0 -> {view, errors}
    end
  end

  defp apply_message(view, errors, {:rows, mc, rows, %{epoch: epoch, rev: rev, reset: reset?}}) do
    held = view[mc]

    {base, errors} =
      cond do
        reset? ->
          {%{}, errors}

        held == nil ->
          {%{}, [{:rows_of_unknown, mc} | errors]}

        held.epoch != epoch ->
          {held.rows, [{:epoch_without_reset, mc, held.epoch, epoch} | errors]}

        rev < held.rev ->
          {held.rows, [{:went_back, mc, held.rev, rev} | errors]}

        true ->
          {held.rows, errors}
      end

    {Map.put(view, mc, %{epoch: epoch, rev: rev, rows: Map.merge(base, Map.new(rows))}), errors}
  end

  defp apply_message(view, errors, {:mc, mc, :removed}), do: {Map.delete(view, mc), errors}
  defp apply_message(view, errors, _other), do: {view, errors}

  defp collector_view(pid) do
    send(pid, {:view, self()})
    assert_receive {:view, ^pid, view}, 5_000
    view
  end

  # Runs `fun` while another process reads the table as fast as it can, and returns
  # `fun`'s result, or `%{reader: ...}` with the rows found missing that were there
  # before and after, and how many reads raised.
  defp reading(fun) do
    before = keys()
    parent = self()

    reader =
      spawn_link(fn ->
        send(parent, {:reading, self()})
        read(parent, before, MapSet.new(), 0)
      end)

    assert_receive {:reading, ^reader}, 5_000
    :ok = fun.()
    send(reader, :stop)
    assert_receive {:read, ^reader, missing, crashes}, 5_000
    required = MapSet.intersection(before, keys())

    %{
      reader: %{
        missing: missing |> MapSet.intersection(required) |> Enum.sort(),
        crashes: crashes
      }
    }
  end

  defp keys, do: MapSet.new(Shell.rows(), &elem(&1, 0))

  defp read(parent, keys, missing, crashes) do
    {missing, crashes} =
      try do
        present = keys()
        local = for {mc, id} <- keys, mc == node(), Shell.row(mc, id) == nil, do: {mc, id}

        {missing
         |> MapSet.union(MapSet.difference(keys, present))
         |> MapSet.union(MapSet.new(local)), crashes}
      rescue
        _ -> {missing, crashes + 1}
      end

    receive do
      :stop -> send(parent, {:read, self(), missing, crashes})
    after
      0 -> read(parent, keys, missing, crashes)
    end
  end

  # --- translation to the model's terms -------------------------------------------

  defp mc_key(mc), do: if(mc == node(), do: :local, else: mc)

  defp translate_version(nil), do: nil

  defp translate_version({epoch, rev}) do
    case world().epochs do
      %{^epoch => run} -> {{:local, run}, rev}
      _ -> {epoch, rev}
    end
  end

  defp translate_view(view) do
    Map.new(view, fn {mc, %{epoch: e, rev: r, rows: rows}} ->
      {mc_key(mc), %{v: translate_version({e, r}), rows: rows}}
    end)
  end

  defp translate_sent(sent) do
    Map.new(sent, fn {mc, %{epoch: e, rev: r, reset: reset?, rows: rows}} ->
      {mc_key(mc), %{v: translate_version({e, r}), reset: reset?, rows: rows}}
    end)
  end
end
