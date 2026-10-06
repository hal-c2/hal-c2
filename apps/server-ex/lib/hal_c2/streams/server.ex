defmodule HalC2.Streams.Server do
  @moduledoc """
  Owns the live state of one stream and its subscribers.

  A *client* subscription (`subscribe/4` with a view) is what a socket holds for a
  client. Its messages carry entities as clients see them (`HalC2.Web.Wire`), and
  only those of its `HalC2.Streams.View`. It receives, in order:

    * what it lacks, one of
      * `{:snapshot, seq, updated_at, rows, :more | :done, %{handle: h, floor: f}}`
        chunks when it starts fresh, where `rows` is a list of `{kind, id, entity}`
        and `floor` is its window's (absent without a window),
      * `{:events, events, seq}` chunks when it resumes from an offset: the log's
        events since, merged per entity, or one event replacing each entity changed
        since (`HalC2.StreamState.changed_since/2`) when the log holds more than
        `@max_replay` of them or they do not fit one chunk,
    * `{:live, seq, handle}` once it is caught up, then
    * `{:events, events, seq}` for every later commit that touches its view, and
    * `{:page, seq, rows, floor, :more | :done}` chunks answering `more/3`.

  Each arrives as `{:hal_c2_stream, stream_id, message}`. A client resumes only with
  the `handle/0` its offset came from; any other starts fresh.

  A plain subscription (`subscribe/3`) is for this MC's own processes: whole
  entities, as `{:snapshot, seq, updated_at, rows, :more | :done}` or
  `{:events, events}`, then `{:live, seq}` and `{:events, events}`. `watch/2` asks
  for none of the state: `{:live, seq}`, then `{:changed, seq}` after every commit.

  Messages are split into chunks of about `@chunk_bytes` because a subscriber may be
  on another MC, and one large message would stall every other message on that
  MC connection until it finished. Such a subscriber is sent everything through its
  own `HalC2.Streams.Relay`, so a slow connection holds up nobody else, and what it
  starts from is put together there too, not in the stream.

  Replay reads the log, not memory, so a reconnecting client costs one query rather
  than a buffered copy of the thread. The process hibernates between bursts and stops
  after `@idle_stop` with no subscribers; it writes a snapshot on the way out when
  enough events accumulated since the last one.
  """

  use GenServer, restart: :transient

  alias HalC2.{Store, StreamState}
  alias HalC2.Streams.{Relay, View}

  @state_version 3
  @idle_stop :timer.minutes(5)
  @snapshot_every 500
  # A subscriber further behind than this is not replayed the log.
  @max_replay 2_000
  @chunk_bytes 256 * 1024
  # While a thread streams, its sidebar row is recomputed at most this often.
  @shell_debounce 250

  @typedoc """
  What a client asks for: the `handle` its offset came from, the `kinds` it folds
  (`HalC2.Streams.View`), and its `window`, either `{:items, n}` to start with the
  newest runs holding `n` turn items or `{:floor, f}` to keep the window it has.
  """
  @type client :: %{
          optional(:handle) => String.t() | nil,
          optional(:kinds) => View.kinds(),
          optional(:window) => {:items, pos_integer} | {:floor, integer | nil} | nil
        }

  @doc "How long a stream without subscribers stays up."
  def idle_stop, do: @idle_stop

  @doc """
  Names what a client's copy is a copy of: this store's log, as this version trims
  it, of the `kinds` the client asked for. Offsets count this store's events, and
  what was left out of a copy by its kinds was never sent, so a client resumes from
  an offset only while all three still hold.
  """
  @spec handle(View.kinds()) :: String.t()
  def handle(kinds \\ nil) do
    log = "#{Store.id()}.#{HalC2.Web.Wire.version()}"
    if kinds, do: "#{log}.#{:erlang.phash2(kinds)}", else: log
  end

  def start_link(stream_id),
    do:
      GenServer.start_link(__MODULE__, stream_id,
        name: {:via, Registry, {HalC2.Streams.Registry, stream_id}},
        hibernate_after: 15_000
      )

  @spec subscribe(String.t(), pid, non_neg_integer | nil) :: :ok
  def subscribe(stream_id, pid, offset \\ nil),
    do: stream_id |> HalC2.Streams.ensure() |> GenServer.call({:subscribe, pid, offset, :plain})

  @spec subscribe(String.t(), pid, non_neg_integer | nil, client) :: :ok
  def subscribe(stream_id, pid, offset, %{} = client),
    do: stream_id |> HalC2.Streams.ensure() |> GenServer.call({:subscribe, pid, offset, client})

  @spec watch(String.t(), pid) :: :ok
  def watch(stream_id, pid),
    do: stream_id |> HalC2.Streams.ensure() |> GenServer.call({:subscribe, pid, nil, :watch})

  @doc """
  Sends a client the runs before its window's floor that together hold at least
  `items` turn items, and moves the floor down to hold them.
  """
  @spec more(String.t(), pid, pos_integer) :: :ok
  def more(stream_id, pid, items) do
    case Registry.lookup(HalC2.Streams.Registry, stream_id) do
      [{server, _}] -> GenServer.cast(server, {:more, pid, items})
      [] -> :ok
    end
  end

  @spec unsubscribe(String.t(), pid) :: :ok
  def unsubscribe(stream_id, pid) do
    case Registry.lookup(HalC2.Streams.Registry, stream_id) do
      [{server, _}] -> GenServer.cast(server, {:unsubscribe, pid})
      [] -> :ok
    end
  end

  # Writes wait as long as the store does (its own write timeout bounds them): a
  # caller that gave up sooner would be wrong about what landed, and a turn would
  # die over a slow disk.
  @spec commit(GenServer.server(), Store.stream_kind(), [Store.change()]) ::
          {:ok, non_neg_integer}
  def commit(server, stream_kind, changes),
    do: GenServer.call(server, {:commit, stream_kind, changes}, :infinity)

  @doc """
  Runs `fun` against the stream's current state inside the stream process and
  commits the changes it returns, so a decision and its effects are atomic with
  respect to other commits. `fun` returns `{changes, reply}`; an empty change list
  commits nothing.
  """
  @spec transact(GenServer.server(), Store.stream_kind(), (StreamState.t() ->
                                                             {[Store.change()], reply})) ::
          reply
        when reply: term
  def transact(server, stream_kind, fun),
    do: GenServer.call(server, {:transact, stream_kind, fun}, :infinity)

  @spec state(GenServer.server()) :: StreamState.t()
  def state(server), do: GenServer.call(server, :state)

  @doc "Puts the stream's sidebar row now instead of after the debounce."
  @spec flush_shell(GenServer.server()) :: :ok
  def flush_shell(server), do: GenServer.call(server, :flush_shell)

  @impl true
  def init(stream_id) do
    # An MC stopping still writes the pending sidebar row (`terminate/2`), which is
    # what boot recovery reads to find the turns it cut off.
    Process.flag(:trap_exit, true)
    path = Store.path()
    state = StreamState.load(path, stream_id)

    {:ok,
     %{
       v: @state_version,
       id: stream_id,
       path: path,
       stream: state,
       snapshot_seq: state.seq,
       shell_scheduled: false,
       # pid => %{ref: monitor, view: View.t() | :plain | :watch}
       subscribers: %{},
       # pid => the relay of a subscriber on another MC
       relays: %{}
     }, @idle_stop}
  end

  @impl true
  def handle_call({:subscribe, pid, offset, client}, _from, state) do
    state = drop(state, pid)
    {view, initial} = initial(state, pid, offset, client)

    relays =
      if node(pid) == node() do
        initial.()
        state.relays
      else
        Map.put(state.relays, pid, Relay.start(pid, initial))
      end

    sub = %{ref: Process.monitor(pid), view: view}
    {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, pid, sub), relays: relays}}
  end

  def handle_call({:commit, stream_kind, changes}, _from, state) do
    {:ok, last} = Store.append([{stream_kind, state.id, changes}])
    first = last - length(changes) + 1
    at = System.os_time(:millisecond)

    events =
      changes
      |> Enum.with_index(first)
      |> Enum.map(fn {change, seq} ->
        {kind, entity, patch, change_at} =
          case change do
            {kind, entity, patch} -> {kind, entity, patch, at}
            {_, _, _, _} = timed -> timed
          end

        %{seq: seq, kind: kind, entity: entity, patch: patch, at: change_at}
      end)

    stream = Enum.reduce(events, state.stream, &StreamState.apply_event(&2, &1))
    HalC2.Search.index(state.id, events, stream)
    broadcast(state, stream, events)
    state = schedule_shell(%{state | stream: stream})
    {:reply, {:ok, last}, state, timeout(state)}
  end

  def handle_call({:transact, stream_kind, fun}, from, state) do
    case fun.(state.stream) do
      {[], reply} ->
        {:reply, reply, state, timeout(state)}

      {changes, reply} ->
        {:reply, {:ok, _last}, state, _} =
          handle_call({:commit, stream_kind, changes}, from, state)

        {:reply, reply, state, timeout(state)}
    end
  end

  def handle_call(:state, _from, state), do: {:reply, state.stream, state, timeout(state)}

  def handle_call(:flush_shell, _from, %{shell_scheduled: true} = state) do
    {:noreply, state, _} = handle_info(:shell, state)
    {:reply, :ok, state, timeout(state)}
  end

  def handle_call(:flush_shell, _from, state), do: {:reply, :ok, state, timeout(state)}

  @impl true
  def handle_cast({:unsubscribe, pid}, state) do
    state = drop(state, pid)
    {:noreply, state, timeout(state)}
  end

  def handle_cast({:more, pid, items}, state) do
    state =
      case state.subscribers do
        %{^pid => %{view: %{window: %{floor: floor}} = view} = sub} when floor != nil ->
          {runs, floor} = View.take_runs(state.stream, floor, items)
          # By the way its events go, so it arrives after the ones it follows.
          to = Map.get(state.relays, pid, pid)

          send_chunks(View.page(view, state.stream, runs), fn rows, more ->
            send(to, {:hal_c2_stream, state.id, {:page, state.stream.seq, rows, floor, more}})
          end)

          sub = %{sub | view: %{view | window: %{floor: floor}}}
          %{state | subscribers: Map.put(state.subscribers, pid, sub)}

        # Nothing lies before a window that reaches the start, or before no window.
        %{^pid => %{view: %{}}} ->
          to = Map.get(state.relays, pid, pid)
          send(to, {:hal_c2_stream, state.id, {:page, state.stream.seq, [], nil, :done}})
          state

        _ ->
          state
      end

    {:noreply, state, timeout(state)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state) do
    state = drop(state, pid)
    {:noreply, state, timeout(state)}
  end

  def handle_info(:shell, state) do
    with {_kind, _row} = kind_row <- HalC2.Projection.row(state.path, state.id, state.stream) do
      :ok = Store.put_shell(state.id, state.stream.seq, kind_row)
      HalC2.Shell.put_row(state.id, kind_row)
    end

    state = %{state | shell_scheduled: false}
    {:noreply, state, timeout(state)}
  end

  def handle_info(:timeout, state), do: {:stop, :normal, state}

  # Linked processes still take the stream down with them, as before it trapped exits.
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state, timeout(state)}
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  @impl true
  def terminate(_reason, state) do
    # One still sending what a subscriber starts from would not see the stream go.
    for {_pid, relay} <- state.relays, do: Process.exit(relay, :kill)

    if state.shell_scheduled, do: handle_info(:shell, state)

    if state.stream.seq - state.snapshot_seq >= @snapshot_every,
      do: Store.put_snapshot(state.id, state.stream.seq, state.stream)
  end

  @impl true
  def code_change(_old_vsn, state, _extra) do
    # Before version 3 a subscriber was only its monitor, and sockets trimmed what
    # they were sent themselves. They take a client's messages now, and this MC's
    # own waiters only ever count them.
    subscribers =
      Map.new(state.subscribers, fn
        {pid, ref} when is_reference(ref) -> {pid, %{ref: ref, view: %{kinds: nil, window: nil}}}
        sub -> sub
      end)

    {:ok,
     state
     |> Map.put_new_lazy(:relays, fn -> relays(subscribers) end)
     |> Map.merge(%{
       v: @state_version,
       stream: StreamState.migrate(state.stream),
       subscribers: subscribers
     })}
  end

  # Relays for subscribers a version without them was sending to itself. They are
  # live already, so there is nothing to start them from.
  defp relays(subscribers) do
    for {pid, _sub} <- subscribers, node(pid) != node(), into: %{} do
      {pid, Relay.start(pid, fn -> :ok end)}
    end
  end

  # Forgets a subscriber. Its relay is killed, not left to finish: what it still
  # holds is no longer wanted, and would mix with what a new subscription is sent.
  defp drop(state, pid) do
    {sub, subscribers} = Map.pop(state.subscribers, pid)
    if sub, do: Process.demonitor(sub.ref, [:flush])
    {relay, relays} = Map.pop(state.relays, pid)
    if relay, do: Process.exit(relay, :kill)
    %{state | subscribers: subscribers, relays: relays}
  end

  # What a new subscriber is sent from now on, and what sends it the state it
  # starts from, for the stream or the subscriber's relay to run. Only the log is
  # read here, so that it ends where the stream stands; the rest is put together
  # by whoever runs it, from the stream as it is now.
  defp initial(%{id: id, stream: stream}, pid, _offset, :watch),
    do: {:watch, fn -> send(pid, {:hal_c2_stream, id, {:live, stream.seq}}) end}

  defp initial(%{id: id, stream: stream} = state, pid, offset, :plain) do
    replay = replay(state, offset)

    {:plain,
     fn ->
       case replay do
         events when is_list(events) ->
           events = Enum.reject(events, &StreamState.void?/1)
           send(pid, {:hal_c2_stream, id, {:events, events}})

         :too_many ->
           send_chunks(StreamState.rows(stream), fn rows, more ->
             send(
               pid,
               {:hal_c2_stream, id, {:snapshot, stream.seq, stream.updated_at, rows, more}}
             )
           end)
       end

       send(pid, {:hal_c2_stream, id, {:live, stream.seq}})
     end}
  end

  defp initial(%{id: id, stream: stream} = state, pid, offset, client) do
    handle = handle(client[:kinds])
    # An offset from another log, or a window that was never set, resumes nothing.
    resumes? = client[:handle] in [nil, handle] and not match?({:items, _}, client[:window])

    window =
      case client[:window] do
        {:items, items} -> %{floor: View.tail(stream, items)}
        {:floor, floor} -> %{floor: floor}
        nil -> nil
      end

    view = %{kinds: client[:kinds], window: window}
    replay = resumes? && replay(state, offset)

    {view,
     fn ->
       missed =
         case replay do
           events when is_list(events) ->
             merged =
               HalC2.Web.Protocol.coalesce(events) |> then(&View.replayed(view, stream, &1))

             # Sent in parts it could be cut off part-way, and a client that had
             # applied the first of them would be sent them again. A patch applied
             # twice appends its text twice; a whole entity is the same either way.
             if length(chunk(merged, [], 0, [])) > 1,
               do: View.changed_since(view, stream, offset),
               else: merged

           :too_many when is_integer(offset) and offset <= stream.seq ->
             View.changed_since(view, stream, offset)

           _ ->
             :unknown
         end

       case missed do
         [] ->
           :ok

         events when is_list(events) ->
           # A client cut off part-way resumes from where it was, so only the last
           # chunk moves its offset.
           send_chunks(events, fn chunk, more ->
             seq = if more == :done, do: List.last(chunk).seq, else: offset
             send(pid, {:hal_c2_stream, id, {:events, chunk, seq}})
           end)

         :unknown ->
           meta = if window, do: %{handle: handle, floor: window.floor}, else: %{handle: handle}

           send_chunks(View.rows(view, stream), fn rows, more ->
             send(
               pid,
               {:hal_c2_stream, id, {:snapshot, stream.seq, stream.updated_at, rows, more, meta}}
             )
           end)
       end

       send(pid, {:hal_c2_stream, id, {:live, stream.seq, handle}})
     end}
  end

  # The log's events after `offset`, oldest first, or `:too_many` when there are more
  # than a replay carries or `offset` is not one this stream reached.
  defp replay(state, offset) when is_integer(offset) and offset <= state.stream.seq do
    events =
      Store.reduce_stream(state.path, state.id, offset, [], &[&1 | &2], limit: @max_replay + 1)

    # Counted before the events that change nothing are left out, or a replay cut
    # short by the limit could pass for a whole one.
    if length(events) <= @max_replay, do: Enum.reverse(events), else: :too_many
  end

  defp replay(_state, _offset), do: :too_many

  # Calls `fun.(chunk, :more | :done)` for `list` in chunks of about `@chunk_bytes`:
  # once with nothing when `list` is empty, so whoever waits for `:done` gets it.
  defp send_chunks(list, fun) do
    chunks = chunk(list, [], 0, [])
    last = length(chunks) - 1

    for {chunk, i} <- Enum.with_index(chunks),
        do: fun.(chunk, if(i == last, do: :done, else: :more))
  end

  defp chunk([], current, _size, acc), do: Enum.reverse([Enum.reverse(current) | acc])

  defp chunk([item | rest], current, size, acc) do
    item_size = :erlang.external_size(item)

    if current != [] and size + item_size > @chunk_bytes,
      do: chunk(rest, [item], item_size, [Enum.reverse(current) | acc]),
      else: chunk(rest, [item | current], size + item_size, acc)
  end

  defp schedule_shell(%{shell_scheduled: true} = state), do: state

  defp schedule_shell(state) do
    Process.send_after(self(), :shell, @shell_debounce)
    %{state | shell_scheduled: true}
  end

  # Clients with the same view are sent the same events, trimmed and filtered once.
  # One on another MC is sent them through its relay.
  defp broadcast(state, stream, events) do
    seq = List.last(events).seq

    Enum.reduce(state.subscribers, %{}, fn {pid, %{view: view}}, by_view ->
      to = Map.get(state.relays, pid, pid)

      case view do
        :plain ->
          send(to, {:hal_c2_stream, state.id, {:events, events}})
          by_view

        :watch ->
          send(to, {:hal_c2_stream, state.id, {:changed, seq}})
          by_view

        view ->
          by_view =
            Map.put_new_lazy(by_view, view, fn ->
              View.events(view, stream, state.stream, events)
            end)

          # A commit that touches nothing the client holds is not news to it.
          if by_view[view] != [],
            do: send(to, {:hal_c2_stream, state.id, {:events, by_view[view], seq}})

          by_view
      end
    end)
  end

  defp timeout(%{subscribers: subs}) when map_size(subs) == 0, do: @idle_stop
  defp timeout(_state), do: :infinity
end
