defmodule HalC2.StreamsPropTest do
  @moduledoc """
  `HalC2.Streams` against a model of what its subscribers are promised: every
  subscriber sees, in order and without gaps or duplicates, the acknowledged changes
  after its offset (or a snapshot, then the tail), and what it folds from them is the
  stream as a fresh subscription would hand it over.

  The model is each stream's acknowledged events and their fold with
  `HalC2.StreamState`, plus what each subscription asked for. Subscribers are
  `HalC2.Prop.StreamsCollector` processes named `p1`..`p3` that fold what they are
  sent as a client does, and resume from what they hold. Commands commit and
  transact, subscribe plainly, as clients (kinds and windows) and as watchers, resume,
  unsubscribe, page a window back, crash subscribers, stop streams idle, crash them,
  restart the stream supervisor and the store, and append enough at once to push a
  subscriber past what a replay carries.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Prop.StreamsCollector, as: Collector
  alias HalC2.{Store, Streams, StreamState}
  alias HalC2.Streams.{Server, View}

  @moduletag timeout: :infinity

  @streams ["s-a", "s-b"]
  @names ["p1", "p2", "p3"]
  @runs ["r1", "r2", "r3"]
  @items ["i1", "i2", "i3", "i4"]
  @messages ["m1", "m2", "m3"]
  # Which run each item and message belongs to, and each message's role, for good:
  # a view's one way out is its run being rolled back (`HalC2.Streams.View`).
  @run_of %{"i1" => "r1", "i2" => "r1", "i3" => "r2", "i4" => "r3", "m1" => "r1", "m2" => "r2"}
  @role_of %{"m1" => "user", "m2" => "assistant", "m3" => "user"}
  @notes ["n1", "n2"]
  @kinds [
    nil,
    %{"turn-item" => %{}, "run" => %{}},
    %{"message" => %{"role" => "user"}, "note" => %{}}
  ]
  # Past this many events behind, a subscriber is not replayed the log (`Server`).
  @max_replay 2_000

  property "subscribers see exactly the acknowledged changes and converge",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        {history, state, result} = run_case(cmds, &run_commands(__MODULE__, &1))

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  defp run_case(cmds, run) do
    HalC2.Prop.scratch_home("streams")

    HalC2.Prop.start_services([
      {Store, path: Store.home_path()},
      Streams
    ])

    for name <- @names, do: Process.put({:collector, name}, Collector.start())

    try do
      run.(cmds)
    after
      for name <- @names, do: Process.exit(collector(name), :kill)
      HalC2.Prop.stop_services()
    end
  end

  # --- model ------------------------------------------------------------------

  # streams: id => %{events: [event] oldest first, fold: StreamState, commits: [last seq]}
  # subs: {name, stream} => %{mode: :plain | :watch | :client, kinds, window: nil | %{floor: f},
  #   active: boolean, live: the stream's seq when it subscribed, until: seq it stopped at}
  def initial_state, do: %{seq: 0, streams: %{}, subs: %{}}

  def command(state) do
    base = [
      {8, changes_call(state, :commit)},
      {3, changes_call(state, :transact)},
      {3, {:call, __MODULE__, :subscribe_plain, [name(), stream(), oneof([:fresh, :bogus])]}},
      {2, {:call, __MODULE__, :watch, [name(), stream()]}},
      {4,
       {:call, __MODULE__, :subscribe_client,
        [name(), stream(), integer(0, length(@kinds) - 1), oneof([nil, {:items, 1}, {:items, 3}])]}},
      {3, {:call, __MODULE__, :unsubscribe, [name(), stream()]}},
      {1, {:call, __MODULE__, :crash_subscriber, [name()]}},
      {1, {:call, __MODULE__, :transact_raise, [stream()]}},
      {2, {:call, __MODULE__, :state, [stream()]}},
      {2, {:call, __MODULE__, :subscribers, [stream()]}},
      {1, {:call, __MODULE__, :idle_stop, [stream()]}},
      {1, {:call, __MODULE__, :crash_stream, [stream(), oneof([:kill, :boom])]}},
      {1, {:call, __MODULE__, :restart_streams, []}},
      {1, {:call, __MODULE__, :restart_store, []}},
      {2, {:call, __MODULE__, :bulk, [stream(), oneof([600, @max_replay + 1])]}}
    ]

    subs = Map.keys(state.subs)

    with_subs =
      if subs == [],
        do: [],
        else: [
          {6, {:call, __MODULE__, :check, [oneof(subs)]}},
          {2,
           let key <- oneof(subs) do
             {:call, __MODULE__, :rekind,
              [key, integer(0, length(@kinds) - 1), state.subs[key].window != nil]}
           end},
          {6,
           let key <- oneof(subs) do
             {:call, __MODULE__, :resume, [key, asked(state.subs[key])]}
           end},
          {2, {:call, __MODULE__, :more, [oneof(subs), oneof([1, 2])]}}
        ]

    frequency(base ++ with_subs)
  end

  defp stream, do: oneof(@streams)
  defp name, do: oneof(@names)

  # Changes that keep to what streams promise their clients: runs are created in
  # order with the next ordinal and never deleted, and a rolled-back run stays so
  # (`HalC2.Streams.View`); text is appended only to text.
  defp changes_call(state, call) do
    let [id <- stream(), intents <- resize(5, list(intent()))] do
      {:call, __MODULE__, call, [id, resolve(intents, fold(state, id))]}
    end
  end

  # What a resumed subscription asks for again: the one before it's.
  defp asked(sub), do: {sub.mode, sub.kinds, sub.window != nil}

  defp intent do
    text = oneof(["", "a", "bc", "héllo"])

    oneof([
      {:run, oneof(@runs), oneof(["running", "done", "rolled_back"])},
      {:item, oneof(@items), text},
      {:append, oneof(@items), oneof(["a", "bc", "é"])},
      {:message, oneof(@messages)},
      {:delete, oneof(Enum.map(@items, &{"turn-item", &1}) ++ Enum.map(@notes, &{"note", &1}))},
      {:delete, oneof(Enum.map(@messages, &{"message", &1}))},
      {:note, oneof(@notes), oneof([nil, true, 1, "x"]), boolean()},
      {:void, oneof(@items)}
    ])
  end

  @doc false
  def resolve(intents, st) do
    {changes, _} =
      Enum.flat_map_reduce(intents, st, fn intent, st ->
        case change(intent, st) do
          nil ->
            {[], st}

          {kind, id, patch} = change ->
            event = %{seq: st.seq, kind: kind, entity: id, patch: patch, at: 0}
            {[change], StreamState.apply_event(st, event)}
        end
      end)

    changes
  end

  defp change({:run, id, status}, st) do
    runs = StreamState.get(st, "run")

    case runs[id] do
      nil ->
        ordinal = runs |> Map.values() |> Enum.map(& &1["ordinal"]) |> Enum.max(fn -> 0 end)
        {"run", id, %{"s" => %{"id" => id, "ordinal" => ordinal + 1, "status" => status}}}

      %{"status" => "rolled_back"} ->
        nil

      _ ->
        {"run", id, %{"s" => %{"status" => status}}}
    end
  end

  defp change({:item, id, text}, st) do
    with %{} = item <- with_run(%{"id" => id, "text" => text}, st),
         do: {"turn-item", id, %{"d" => true, "s" => item}}
  end

  defp change({:append, id, suffix}, st) do
    case StreamState.get(st, "turn-item")[id] do
      %{"text" => text} when is_binary(text) -> {"turn-item", id, %{"a" => %{"text" => suffix}}}
      _ -> nil
    end
  end

  defp change({:message, id}, st) do
    message = %{"id" => id, "role" => @role_of[id], "text" => "t"}
    with %{} = message <- with_run(message, st), do: {"message", id, %{"s" => message}}
  end

  defp change({:delete, {kind, id}}, _st), do: {kind, id, %{"d" => true}}

  defp change({:note, id, value, quiet}, _st) do
    patch = %{"s" => %{"v" => value}}
    {"note", id, if(quiet, do: Map.put(patch, "q", true), else: patch)}
  end

  defp change({:void, id}, _st), do: {"turn-item", id, %{"s" => nil}}

  # Items are made after their run, so one whose run does not exist yet waits.
  defp with_run(entity, st) do
    case @run_of[entity["id"]] do
      nil -> entity
      run -> if StreamState.get(st, "run")[run], do: Map.put(entity, "runId", run)
    end
  end

  def precondition(state, {:call, _, :idle_stop, [id]}),
    do: not Enum.any?(state.subs, fn {{_, s}, sub} -> s == id and sub.active end)

  def precondition(state, {:call, _, :more, [key, _]}),
    do: match?(%{mode: :client, active: true, window: %{}}, state.subs[key])

  def precondition(state, {:call, _, :resume, [key, asked]}),
    do: Map.has_key?(state.subs, key) and asked(state.subs[key]) == asked

  def precondition(state, {:call, _, :rekind, [key, _, windowed?]}),
    do: match?(%{mode: :client}, state.subs[key]) and state.subs[key].window != nil == windowed?

  def precondition(state, {:call, _, :check, [key]}), do: Map.has_key?(state.subs, key)

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, call, [id, changes]})
      when call in [:commit, :transact],
      do: append(state, id, changes)

  def next_state(state, _result, {:call, _, :bulk, [id, n]}),
    do: append(state, id, bulk_changes(n))

  def next_state(state, _result, {:call, _, :subscribe_plain, [name, id, _]}),
    do: subscribe(state, name, id, %{mode: :plain, kinds: nil, window: nil})

  def next_state(state, _result, {:call, _, :watch, [name, id]}),
    do: subscribe(state, name, id, %{mode: :watch, kinds: nil, window: nil})

  def next_state(state, _result, {:call, _, :subscribe_client, [name, id, kinds, window]}) do
    window =
      case window do
        {:items, n} -> %{floor: View.tail(fold(state, id), n)}
        nil -> nil
      end

    subscribe(state, name, id, %{mode: :client, kinds: Enum.at(@kinds, kinds), window: window})
  end

  # A resumed subscription asks for what the one before it had.
  def next_state(state, _result, {:call, _, :resume, [{name, id}, _asked]}),
    do: subscribe(state, name, id, Map.take(state.subs[{name, id}], [:mode, :kinds, :window]))

  def next_state(state, _result, {:call, _, :rekind, [{name, id} = key, kinds, _]}) do
    sub = %{mode: :client, kinds: Enum.at(@kinds, kinds), window: state.subs[key].window}
    subscribe(state, name, id, sub)
  end

  def next_state(state, _result, {:call, _, :unsubscribe, [name, id]}),
    do: stop_subs(state, &(&1 == {name, id}))

  # Its process is gone, and with it everything it held.
  def next_state(state, _result, {:call, _, :crash_subscriber, [name]}),
    do: %{state | subs: Map.reject(state.subs, fn {{n, _}, _} -> n == name end)}

  def next_state(state, _result, {:call, _, :crash_stream, [id, _]}),
    do: stop_subs(state, fn {_, s} -> s == id end)

  def next_state(state, _result, {:call, _, :restart_streams, []}),
    do: stop_subs(state, fn _ -> true end)

  def next_state(state, _result, {:call, _, :more, [key, items]}) do
    update_in(state.subs[key], fn
      %{window: %{floor: floor}} = sub when floor != nil ->
        {_runs, floor} = View.take_runs(fold(state, elem(key, 1)), floor, items)
        %{sub | window: %{floor: floor}}

      sub ->
        sub
    end)
  end

  def next_state(state, _result, _call), do: state

  defp append(state, _id, []), do: state

  defp append(state, id, changes) do
    stream = Map.get(state.streams, id, %{events: [], fold: StreamState.new(), commits: []})

    {events, seq} =
      Enum.map_reduce(changes, state.seq, fn {kind, entity, patch}, seq ->
        {%{seq: seq + 1, kind: kind, entity: entity, patch: patch, at: 0}, seq + 1}
      end)

    stream = %{
      events: stream.events ++ events,
      fold: Enum.reduce(events, stream.fold, &StreamState.apply_event(&2, &1)),
      commits: stream.commits ++ [seq]
    }

    %{state | seq: seq, streams: Map.put(state.streams, id, stream)}
  end

  defp subscribe(state, name, id, sub) do
    sub = Map.merge(sub, %{active: true, live: fold(state, id).seq, until: nil})
    put_in(state.subs[{name, id}], sub)
  end

  defp stop_subs(state, which) do
    subs =
      Map.new(state.subs, fn {{_, id} = key, sub} ->
        if sub.active and which.(key),
          do: {key, %{sub | active: false, until: fold(state, id).seq}},
          else: {key, sub}
      end)

    %{state | subs: subs}
  end

  defp fold(state, id) do
    case state.streams do
      %{^id => %{fold: fold}} -> fold
      _ -> StreamState.new()
    end
  end

  defp events(state, id), do: get_in(state.streams, [id, :events]) || []

  defp fold_until(state, id, seq) do
    state |> events(id) |> Enum.filter(&(&1.seq <= seq)) |> fold_events()
  end

  defp fold_events(events),
    do: Enum.reduce(events, StreamState.new(), &StreamState.apply_event(&2, &1))

  # --- postconditions -------------------------------------------------------------

  def postcondition(state, {:call, _, :commit, [id, changes]}, result) do
    case changes do
      [] -> result == {:ok, fold(state, id).seq}
      _ -> result == {:ok, state.seq + length(changes)}
    end
  end

  # The function sees the stream as the model has it.
  def postcondition(state, {:call, _, :transact, [id, _]}, result),
    do: result == comparable(fold(state, id))

  def postcondition(state, {:call, _, :state, [id]}, result),
    do: result == comparable(fold(state, id))

  def postcondition(state, {:call, _, :subscribers, [id]}, result) do
    expected =
      for {{name, ^id}, %{active: true}} <- state.subs, into: MapSet.new(), do: collector(name)

    result == expected
  end

  def postcondition(state, {:call, _, :check, [{_name, id} = key]}, got) do
    sub = state.subs[key]
    upto = sub.until || fold(state, id).seq
    check(sub.mode, sub, got, state, id, upto)
  end

  def postcondition(state, {:call, _, call, [_ | _] = args} = c, got)
      when call in [:subscribe_plain, :watch, :subscribe_client, :resume, :rekind] do
    key =
      case args do
        [{_name, _id} = key | _] -> key
        [name, id | _] -> {name, id}
      end

    postcondition(next_state(state, got, c), {:call, __MODULE__, :check, [key]}, got)
  end

  def postcondition(_state, {:call, _, :bulk, _}, {:ok, _}), do: true
  def postcondition(_state, _call, result), do: result == :ok

  # A subscription's messages: what it lacked, `live`, then every later change. What
  # it holds at the end is the stream as of the last change it was sent.
  defp check(:plain, sub, got, state, id, upto) do
    {initial, live} = split_live(got.msgs, &match?({:live, _}, &1))
    live = if live == :no_live, do: [:no_live], else: live
    events = events(state, id)
    missed = Enum.filter(events, &(&1.seq > (got.from || 0) and &1.seq <= sub.live))

    replays? =
      is_integer(got.from) and got.from <= sub.live and length(missed) <= @max_replay

    initial_ok =
      if replays?,
        do:
          match?([{:events, _}], initial) and
            strip(elem(hd(initial), 1)) == strip(Enum.reject(missed, &StreamState.void?/1)),
        else: snapshot_ok?(initial, sub.live, StreamState.rows(fold_until(state, id, sub.live)))

    tail = Enum.filter(events, &(&1.seq > sub.live and &1.seq <= upto))

    tagged(:initial, initial_ok) and
      tagged(
        :live,
        Enum.flat_map(live, fn
          {:events, evs} -> strip(evs)
          other -> [other]
        end) == strip(tail)
      ) and
      tagged(:holds, got.entities == entities(fold_until(state, id, upto)))
  end

  defp check(:watch, sub, got, state, id, upto) do
    commits = state.streams |> get_in([id, :commits]) |> List.wrap()
    changed = for seq <- commits, seq > sub.live and seq <= upto, do: {:changed, seq}
    tagged(:watch, got.msgs == [{:live, sub.live} | changed])
  end

  defp check(:client, sub, got, state, id, upto) do
    {initial, live} = split_live(got.msgs, &match?({:live, _, _}, &1))
    view = %{kinds: sub.kinds, window: sub.window}

    expected =
      for {kind, eid, e} <- View.rows(view, fold_until(state, id, upto)),
          into: %{},
          do: {{kind, eid}, e}

    live = if live == :no_live, do: [:no_live], else: live
    fresh? = got.from == nil

    # Inside one commit a rolled-back run's items follow its other events, so it is
    # the offsets each message moves the client to that only go forward.
    sent = for {:events, evs, seq} <- live, do: {Enum.map(evs, & &1.seq), seq}
    offsets = Enum.map(sent, &elem(&1, 1))

    tagged(:live_marker, Enum.any?(got.msgs, &match?({:live, s, _} when s == sub.live, &1))) and
      tagged(:fresh_snapshot, not fresh? or match?([{:snapshot, _, _, _, _, _} | _], initial)) and
      tagged(
        :messages,
        Enum.all?(live, &(match?({:page, _, _, _, _}, &1) or match?({:events, _, _}, &1)))
      ) and
      tagged(
        :ordered,
        offsets == Enum.uniq(Enum.sort(offsets)) and
          Enum.all?(sent, fn {seqs, seq} -> Enum.all?(seqs, &(&1 > sub.live and &1 <= seq)) end) and
          Enum.all?(offsets, &(&1 <= upto))
      ) and
      tagged(:holds, got.entities == expected)
  end

  defp split_live(msgs, live?) do
    case Enum.split_while(msgs, &(not live?.(&1))) do
      {initial, [_live | rest]} -> {initial, rest}
      {initial, []} -> {initial, :no_live}
    end
  end

  defp snapshot_ok?(initial, seq, rows) do
    parts = for {:snapshot, ^seq, _at, part, more} <- initial, do: {part, more}
    mores = Enum.map(parts, &elem(&1, 1))

    length(parts) == length(initial) and parts != [] and List.last(mores) == :done and
      Enum.all?(Enum.drop(mores, -1), &(&1 == :more)) and
      strip_rows(Enum.flat_map(parts, &elem(&1, 0))) == strip_rows(rows)
  end

  defp tagged(_tag, true), do: true

  defp tagged(tag, false) do
    IO.puts("check failed: #{tag}")
    false
  end

  defp strip(:no_live), do: :no_live
  defp strip(events), do: Enum.map(events, &Map.take(&1, [:seq, :kind, :entity, :patch]))
  defp strip_rows(rows), do: rows

  defp entities(st),
    do: for({kind, id, e} <- StreamState.rows(st), into: %{}, do: {{kind, id}, e})

  defp comparable(st), do: %{st | updated_at: nil}

  # --- system under test --------------------------------------------------------

  defp collector(name), do: Process.get({:collector, name})

  def commit(id, changes), do: Streams.commit(id, :thread, changes)

  def transact(id, changes),
    do: Streams.transact(id, :thread, fn st -> {changes, comparable(st)} end)

  # A failing decision fails its caller only: the stream, its state and its
  # subscribers stay as they were (`subscribers`/`check` see to the last two).
  def transact_raise(id) do
    pid = Streams.ensure(id)

    try do
      Streams.transact(id, :thread, fn _ -> raise ArgumentError, "decided badly" end)
    rescue
      ArgumentError -> if Streams.ensure(id) == pid, do: :ok, else: :restarted
    end
  end

  def bulk(id, n), do: Streams.commit(id, :thread, bulk_changes(n))

  # Deletions of entities that never were: each one is recorded, so enough of them
  # also move the point before which the stream forgets what changed.
  defp bulk_changes(n), do: for(i <- 1..n, do: {"note", "b#{i}", %{"d" => true}})

  def subscribe_plain(name, id, from) do
    offset = if from == :bogus, do: 1_000_000_000
    :ok = Collector.reset(collector(name), id, offset, false)
    :ok = Streams.subscribe(id, collector(name), offset)
    Collector.get(collector(name), id)
  end

  def watch(name, id) do
    :ok = Collector.reset(collector(name), id, nil, false)
    :ok = Streams.watch(id, collector(name))
    Collector.get(collector(name), id)
  end

  def subscribe_client(name, id, kinds, window) do
    :ok = Collector.reset(collector(name), id, nil, false)
    client = %{kinds: Enum.at(@kinds, kinds), window: window}
    :ok = Streams.subscribe(id, collector(name), nil, client)
    Collector.get(collector(name), id)
  end

  # Subscribes again from what the collector holds, asking for what it had.
  def resume({name, id}, {mode, kinds, windowed?}) do
    pid = collector(name)
    held = Collector.get(pid, id)

    :ok =
      case mode do
        :plain ->
          :ok = Collector.reset(pid, id, held.offset, true)
          Streams.subscribe(id, pid, held.offset)

        :watch ->
          :ok = Collector.reset(pid, id, nil, false)
          Streams.watch(id, pid)

        :client ->
          window = if windowed?, do: {:floor, held.floor}
          :ok = Collector.reset(pid, id, held.offset, true)
          client = %{handle: held.handle, kinds: kinds, window: window}
          Streams.subscribe(id, pid, held.offset, client)
      end

    Collector.get(pid, id)
  end

  # Resumes a client from what it holds, but asking for other kinds: what it holds
  # is not a copy of those, so it must start over.
  def rekind({name, id}, kinds, windowed?) do
    pid = collector(name)
    held = Collector.get(pid, id)
    :ok = Collector.reset(pid, id, held.offset, true)
    window = if windowed?, do: {:floor, held.floor}
    client = %{handle: held.handle, kinds: Enum.at(@kinds, kinds), window: window}
    :ok = Streams.subscribe(id, pid, held.offset, client)
    Collector.get(pid, id)
  end

  def unsubscribe(name, id) do
    Streams.unsubscribe(id, collector(name))
  end

  def crash_subscriber(name) do
    pid = collector(name)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    receive do: ({:DOWN, ^ref, _, _, _} -> :ok)
    Process.put({:collector, name}, Collector.start())
    :ok
  end

  def more({name, id}, items), do: Streams.more(id, collector(name), items)

  def check({name, id}), do: Collector.get(collector(name), id)

  def state(id), do: comparable(Server.state(Streams.ensure(id)))

  def subscribers(id) do
    case Registry.lookup(HalC2.Streams.Registry, id) do
      # The registry forgets a stream a moment after it stops.
      [{pid, _}] ->
        try do
          pid |> :sys.get_state() |> Map.fetch!(:subscribers) |> Map.keys() |> MapSet.new()
        catch
          :exit, {:noproc, _} -> MapSet.new()
        end

      [] ->
        MapSet.new()
    end
  end

  # What its idle timeout does: the stream stops, and starts again on next use.
  def idle_stop(id) do
    case Registry.lookup(HalC2.Streams.Registry, id) do
      [{pid, _}] ->
        ref = Process.monitor(pid)
        send(pid, :timeout)
        receive do: ({:DOWN, ^ref, _, _, reason} -> if(reason == :normal, do: :ok, else: reason))

      [] ->
        :ok
    end
  end

  def crash_stream(id, reason) do
    case Registry.lookup(HalC2.Streams.Registry, id) do
      [{pid, _}] ->
        ref = Process.monitor(pid)
        Process.exit(pid, reason)
        receive do: ({:DOWN, ^ref, _, _, _} -> :ok)

      [] ->
        :ok
    end
  end

  def restart_streams, do: HalC2.Prop.restart_service(Streams)
  def restart_store, do: HalC2.Prop.restart_service(Store)
end
