defmodule HalC2.WebSocketFollowPropTest do
  @moduledoc """
  Stream subscriptions on one client socket while the streams' servers are busy,
  against what the socket promises: it answers every ping whatever a stream is doing
  (a client that hears no pong gives up on a healthy MC), and each subscription it
  holds ends at its stream's head, every change once and in order, from its sub until
  its own unsub, however its follow and the stream's commits interleave.

  Two streams, a small pool of ids. Commands subscribe an id to a stream, unsubscribe
  it (also while its follow still waits), commit to a stream (left waiting while it is
  busy), make a stream busy (`:sys.suspend/1` of its server) and free again, and hold
  the socket itself busy while batches of 400 changes are committed (`lag`): past
  1,000 unsent changes the socket drops the subscription with a `resync`, whose offset
  must leave none of the stream's changes after what the client saw, and the client
  subscribes again from it. Each stream also has a running tool call whose progress
  the socket holds a moment to send its latest (`progress`). After
  every step the socket must answer a ping, and every subscription to a free stream
  must have reached its head with nothing sent twice, holding the tool call's latest
  progress; a subscription to a busy stream, or an id with none, is sent nothing.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Streams
  alias HalC2.Test.WsClient

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @streams ["fp-a", "fp-b"]
  @ids [1, 2, 3]

  setup do
    saved = for key <- [:port, :home], do: {key, Application.fetch_env(:hal_c2, key)}

    on_exit(fn ->
      :persistent_term.erase({HalC2.Web, :token})

      for {key, value} <- saved do
        case value do
          {:ok, value} -> Application.put_env(:hal_c2, key, value)
          :error -> Application.delete_env(:hal_c2, key)
        end
      end
    end)
  end

  property "a socket answers pings while its streams are busy, and each subscription ends at its head",
    numtests: HalC2.Prop.numtests(60),
    max_size: 30 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        start()

        {history, state, result} =
          try do
            run_commands(__MODULE__, cmds)
          after
            stop()
          end

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  defp start do
    Application.put_env(:hal_c2, :port, 0)
    home = HalC2.Prop.scratch_home("web-socket-follow")
    :persistent_term.erase({HalC2.Web, :token})

    sup =
      HalC2.Prop.start_services([
        {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
        HalC2.Streams,
        HalC2.Shell,
        Supervisor.child_spec(HalC2.Web, id: HalC2.Web)
      ])

    [port] =
      for {HalC2.Web, pid, _, _} <- Supervisor.which_children(sup) do
        {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
        port
      end

    heads =
      Map.new(@streams, fn stream ->
        {:ok, seq} = Streams.commit(stream, :thread, [item(0), tool("p0", "running")])
        {stream, seq}
      end)

    {:ok, client} = WsClient.connect(port, "/ws?token=#{HalC2.Web.token()}")
    {%{"t" => "hello"}, client} = WsClient.recv(client, 5_000)

    put(:client, client)
    put(:heads, heads)
    put(:log, Map.new(heads, fn {stream, seq} -> {stream, [seq, seq - 1]} end))
    put(:progress, Map.new(heads, fn {stream, seq} -> {stream, {seq, "p0"}} end))
    put(:shown, %{})
    put(:subs, %{})
    put(:seen, %{})
    put(:busy, MapSet.new())
    put(:waiting, %{})
  end

  defp stop do
    # A suspended server takes no exit signal; free them before the services stop.
    for stream <- get(:busy) || [], do: :sys.resume(Streams.ensure(stream))
    for {_, tasks} <- get(:waiting) || %{}, task <- tasks, do: Task.await(task, 10_000)

    for key <- [:client, :heads, :log, :progress, :shown, :subs, :seen, :busy, :waiting],
        do: Process.delete({__MODULE__, key})

    HalC2.Prop.stop_services()
  end

  # --- model ------------------------------------------------------------------------

  # subs: id => stream. busy: the streams whose servers are suspended.
  def initial_state, do: %{subs: %{}, busy: []}

  def command(state) do
    free_ids = @ids -- Map.keys(state.subs)
    taken = Map.values(state.subs)
    open = @streams -- taken

    frequency(
      [
        {3, {:call, __MODULE__, :commit, [oneof(@streams)]}},
        {3, {:call, __MODULE__, :progress, [oneof(@streams)]}},
        {2, {:call, __MODULE__, :busy, [oneof(@streams)]}}
      ] ++
        if(lagging(state) != [],
          do: [{1, {:call, __MODULE__, :lag, [oneof(lagging(state)), range(1, 3)]}}],
          else: []
        ) ++
        if(state.busy != [],
          do: [{3, {:call, __MODULE__, :free, [oneof(state.busy)]}}],
          else: []
        ) ++
        if(free_ids != [] and open != [],
          do: [{4, {:call, __MODULE__, :sub, [oneof(free_ids), oneof(open)]}}],
          else: []
        ) ++
        if(state.subs != %{},
          do: [{3, {:call, __MODULE__, :unsub, [oneof(Map.keys(state.subs))]}}],
          else: []
        )
    )
  end

  # One subscription per stream on a socket, as the clients keep it.
  def precondition(state, {:call, _, :sub, [id, stream]}),
    do: not Map.has_key?(state.subs, id) and stream not in Map.values(state.subs)

  def precondition(state, {:call, _, :unsub, [id]}), do: Map.has_key?(state.subs, id)
  def precondition(state, {:call, _, :busy, [stream]}), do: stream not in state.busy
  def precondition(state, {:call, _, :free, [stream]}), do: stream in state.busy
  def precondition(_state, {:call, _, :commit, _}), do: true
  def precondition(_state, {:call, _, :progress, _}), do: true
  def precondition(state, {:call, _, :lag, [stream, _]}), do: stream in lagging(state)

  # A followed stream that is free: the socket is found by its subscription.
  defp lagging(state), do: Map.values(state.subs) -- state.busy

  def next_state(state, _result, {:call, _, :sub, [id, stream]}),
    do: put_in(state.subs[id], stream)

  def next_state(state, _result, {:call, _, :unsub, [id]}),
    do: %{state | subs: Map.delete(state.subs, id)}

  def next_state(state, _result, {:call, _, :busy, [stream]}),
    do: %{state | busy: [stream | state.busy]}

  def next_state(state, _result, {:call, _, :free, [stream]}),
    do: %{state | busy: List.delete(state.busy, stream)}

  def next_state(state, _result, {:call, _, :commit, _}), do: state
  def next_state(state, _result, {:call, _, :progress, _}), do: state
  def next_state(state, _result, {:call, _, :lag, _}), do: state

  def postcondition(_state, _call, result), do: result == :ok

  # --- commands ---------------------------------------------------------------------

  def sub(id, stream) do
    shape = %{"type" => "stream", "mc" => Atom.to_string(node()), "stream" => stream}
    send_frame(%{"t" => "sub", "id" => id, "shape" => shape})
    put(:subs, Map.put(get(:subs), id, stream))
    put(:seen, Map.put(get(:seen), id, nil))
    settle()
  end

  def unsub(id) do
    send_frame(%{"t" => "unsub", "id" => id})
    put(:subs, Map.delete(get(:subs), id))
    put(:seen, Map.delete(get(:seen), id))
    put(:shown, Map.delete(get(:shown), id))
    settle()
  end

  # A commit to a busy stream waits for it, as a caller's would.
  def commit(stream), do: commit(stream, item(:rand.uniform(1000)), nil)

  # The running tool call reports progress.
  def progress(stream) do
    detail = "p#{System.unique_integer([:positive])}"
    commit(stream, tool(detail, "running"), detail)
  end

  defp commit(stream, change, detail) do
    if busy?(stream) do
      task = Task.async(fn -> {Streams.commit(stream, :thread, [change]), detail} end)
      put(:waiting, Map.update(get(:waiting), stream, [task], &[task | &1]))
    else
      {:ok, seq} = Streams.commit(stream, :thread, [change])
      committed(stream, [seq], detail)
    end

    settle()
  end

  # The socket takes nothing while `batches` commits of 400 changes reach it.
  def lag(stream, batches) do
    [socket] = Map.keys(:sys.get_state(Streams.ensure(stream)).subscribers)
    :ok = :sys.suspend(socket)

    for _ <- 1..batches do
      {:ok, seq} = Streams.commit(stream, :thread, for(n <- 1..400, do: item(n, n)))
      committed(stream, Enum.to_list((seq - 399)..seq))
    end

    :ok = :sys.resume(socket)
    settle()
  end

  def busy(stream) do
    :ok = :sys.suspend(Streams.ensure(stream))
    put(:busy, MapSet.put(get(:busy), stream))
    settle()
  end

  def free(stream) do
    :ok = :sys.resume(Streams.ensure(stream))
    put(:busy, MapSet.delete(get(:busy), stream))
    {tasks, waiting} = Map.pop(get(:waiting), stream, [])
    put(:waiting, waiting)

    for task <- Enum.reverse(tasks) do
      {{:ok, seq}, detail} = Task.await(task, 10_000)
      committed(stream, [seq], detail)
    end

    settle()
  end

  # --- checking ---------------------------------------------------------------------

  # Takes frames until every subscription to a free stream is at its head, then
  # pings: the pong must come, with nothing more for anyone. :ok or what went wrong.
  defp settle do
    with :ok <- take_until_heads(System.monotonic_time(:millisecond) + 5_000),
         :ok <- latest_progress() do
      client = WsClient.send_json(get(:client), %{"t" => "ping"})

      case recv_until_pong(client, 2_000) do
        {:ok, frames, client} ->
          put(:client, client)
          Enum.reduce_while(frames, :ok, fn frame, :ok -> check(frame) end)

        :timeout ->
          {:no_pong, get(:subs), get(:busy)}
      end
    end
  end

  defp take_until_heads(deadline) do
    behind =
      for {id, stream} <- get(:subs),
          not busy?(stream),
          get(:seen)[id] != get(:heads)[stream],
          do: {id, stream, get(:seen)[id], get(:heads)[stream]}

    left = deadline - System.monotonic_time(:millisecond)

    cond do
      behind == [] ->
        :ok

      left <= 0 ->
        {:behind, behind}

      true ->
        case recv(get(:client), left) do
          {:ok, frame, client} ->
            put(:client, client)

            case check(frame) do
              {:cont, :ok} -> take_until_heads(deadline)
              {:halt, wrong} -> wrong
            end

          :timeout ->
            {:behind, behind}
        end
    end
  end

  # Every subscription at its head holds the tool call as it is now.
  defp latest_progress do
    wrong =
      for {id, stream} <- get(:subs),
          not busy?(stream),
          {_seq, detail} <- [get(:progress)[stream]],
          get(:shown)[id] != detail,
          do: {id, stream, get(:shown)[id], detail}

    if wrong == [], do: :ok, else: {:not_latest, wrong}
  end

  # A frame for a subscription to a free stream that moves it forward, or what is wrong
  # with it.
  defp check(%{"id" => id} = frame) do
    show(id, frame)
    stream = get(:subs)[id]
    seen = get(:seen)[id]

    cond do
      stream == nil ->
        {:halt, {:stray, frame}}

      busy?(stream) ->
        {:halt, {:while_busy, frame}}

      frame["t"] == "snapshot" ->
        {:cont, :ok}

      frame["t"] == "live" and (seen == nil or frame["offset"] >= seen) ->
        advance(id, frame["offset"])

      frame["t"] == "events" and seen != nil and frame["offset"] > seen ->
        advance(id, frame["offset"])

      # The client holds everything up to the offset, and subscribes again from it.
      frame["t"] == "resync" and seen != nil and frame["offset"] >= seen and
          not Enum.any?(get(:log)[stream], &(&1 > seen and &1 <= frame["offset"])) ->
        shape = %{"type" => "stream", "mc" => Atom.to_string(node()), "stream" => stream}
        send_frame(%{"t" => "sub", "id" => id, "shape" => shape, "offset" => seen})
        {:cont, :ok}

      true ->
        {:halt, {:out_of_order, seen, frame}}
    end
  end

  defp check(frame), do: {:halt, {:unexpected, frame}}

  # The tool call's progress as the client folds it from snapshots and events.
  defp show(id, %{"t" => "snapshot", "rows" => rows}) do
    for ["turn-item", "tool", %{"detail" => detail}] <- rows, do: shown(id, detail)
  end

  defp show(id, %{"t" => "events", "events" => events}) do
    for [_seq, "turn-item", "tool", %{"s" => %{"detail" => detail}}, _at] <- events,
        do: shown(id, detail)
  end

  defp show(_id, _frame), do: :ok

  defp shown(id, detail), do: put(:shown, Map.put(get(:shown), id, detail))

  defp advance(id, offset) do
    put(:seen, Map.put(get(:seen), id, offset))
    {:cont, :ok}
  end

  defp recv(client, timeout) do
    {frame, client} = WsClient.recv(client, timeout)
    {:ok, frame, client}
  rescue
    RuntimeError -> :timeout
  end

  defp recv_until_pong(client, timeout) do
    {_pong, frames, client} = WsClient.recv_until(client, &(&1["t"] == "pong"), timeout)
    {:ok, frames, client}
  rescue
    RuntimeError -> :timeout
  end

  defp send_frame(frame), do: put(:client, WsClient.send_json(get(:client), frame))

  defp committed(stream, seqs, detail \\ nil) do
    put(:heads, Map.update!(get(:heads), stream, &Enum.max([&1 | seqs])))
    put(:log, Map.update!(get(:log), stream, &(seqs ++ &1)))

    with [seq] when detail != nil <- seqs,
         {at, _} when at < seq <- get(:progress)[stream],
         do: put(:progress, Map.put(get(:progress), stream, {seq, detail}))
  end

  defp busy?(stream), do: MapSet.member?(get(:busy), stream)
  defp item(n, id \\ 1), do: {"turn-item", "i#{id}", %{"s" => %{"text" => "t#{n}"}}}

  defp tool(detail, status),
    do:
      {"turn-item", "tool",
       %{"s" => %{"type" => "command_execution", "status" => status, "detail" => detail}}}

  defp get(key), do: Process.get({__MODULE__, key})
  defp put(key, value), do: Process.put({__MODULE__, key}, value)
end
