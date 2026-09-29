defmodule HalC2.Links.Connection do
  @moduledoc """
  One link's websocket to its environment (`HalC2.Links`). It mints a socket ticket
  with the link's token, connects over protocol 3, and forwards this node's client
  RPCs and subscriptions. After a drop it reconnects with backoff and subscribes
  again, so subscribers get a fresh snapshot, as after their own reconnect; a stream
  resumes from the last offset it passed on instead. RPCs fail while it is down
  rather than wait for it, and so do new subscriptions once it has failed to connect.
  A socket that answers nothing between two pings counts as dropped. When the
  environment no longer accepts the link's token it stops trying: only pairing again
  can fix that. It tells `HalC2.Links` why it is down (`"unreachable"` or `"refused"`).

  It also reaches the other members of the environment's cluster: it registers their
  environment ids beside its own (`HalC2.Links.route/1`), from the environment's
  descriptor as it connects and from the shells it passes on, and names them in what
  it forwards so that the environment routes them to its members.
  """

  use GenServer

  require Logger

  @ping :timer.seconds(20)
  @min_backoff 500
  @max_backoff :timer.seconds(30)

  def start_link(link) do
    id = link["environment"]["environmentId"]
    GenServer.start_link(__MODULE__, link, name: {:via, Registry, {HalC2.Links.Registry, id}})
  end

  def child_spec(link),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [link]}, restart: :transient}

  def rpc(pid, environment, method, payload, timeout) do
    GenServer.call(pid, {:rpc, environment, method, payload}, timeout)
  catch
    :exit, {:timeout, _} -> {:error, "#{method} timed out"}
    :exit, _ -> {:error, "unknown environment"}
  end

  def watch(pid, shape, subscriber, offset \\ nil) do
    GenServer.call(pid, {:watch, shape, subscriber, offset})
  catch
    :exit, _ -> {:error, "unknown environment"}
  end

  @doc "`watch/4` under `ref`, without waiting for a link that may be connecting."
  def watch_async(pid, ref, shape, subscriber),
    do: GenServer.cast(pid, {:watch, ref, shape, subscriber, nil})

  def unwatch(pid, ref), do: GenServer.cast(pid, {:unwatch, ref})

  # --- server --------------------------------------------------------------------

  @impl true
  def init(link) do
    send(self(), :connect)

    {:ok,
     %{
       link: link,
       environment: link["environment"]["environmentId"],
       conn: nil,
       request: nil,
       upgrade: nil,
       ws: nil,
       # The remote node's name, from its hello: set while the link is up.
       node: nil,
       next_id: 1,
       # Remote id => {:call, from} | {:sub, ref}
       pending: %{},
       # ref => %{pid, monitor, shape, id, offset}
       subs: %{},
       backoff: @min_backoff,
       # Why it is down since it last failed: nil while up or first connecting, else
       # "unreachable" or "refused".
       problem: nil,
       # The ping loop of the socket that is up, and whether it said anything since
       # the last ping.
       ping: nil,
       heard: true,
       # The other environments of its cluster, registered beside its own.
       members: MapSet.new()
     }}
  end

  # From before members and liveness: a refused link had `refused: true`.
  @impl true
  def code_change(_old_vsn, state, _extra) do
    {refused, state} = Map.pop(state, :refused, false)

    {:ok,
     state
     |> Map.put_new(:problem, if(refused, do: "refused"))
     |> Map.put_new(:ping, nil)
     |> Map.put_new(:heard, true)
     |> Map.put_new(:members, MapSet.new())}
  end

  @impl true
  def handle_call({:rpc, environment, _method, _payload}, _from, %{node: nil} = state),
    do: {:reply, {:error, down_error(state, environment)}, state}

  def handle_call({:rpc, environment, method, payload}, from, state) do
    {id, state} = next_id(state)

    frame = %{
      "t" => "rpc",
      "id" => id,
      "environment" => environment,
      "method" => method,
      "payload" => payload
    }

    {:noreply, state |> put_in([:pending, id], {:call, from}) |> push(frame)}
  end

  def handle_call({:watch, shape, _pid, _offset}, _from, %{node: nil, problem: p} = state)
      when p != nil,
      do: {:reply, {:error, down_error(state, shape["environment"] || state.environment)}, state}

  def handle_call({:watch, shape, pid, offset}, _from, state) do
    ref = make_ref()
    {:reply, {:ok, ref}, add_sub(state, ref, shape, pid, offset)}
  end

  @impl true
  def handle_cast({:watch, ref, shape, pid, offset}, state),
    do: {:noreply, add_sub(state, ref, shape, pid, offset)}

  def handle_cast({:unwatch, ref}, state), do: {:noreply, drop_sub(state, ref, true)}

  defp add_sub(state, ref, shape, pid, offset) do
    sub = %{pid: pid, monitor: Process.monitor(pid), shape: shape, id: nil, offset: offset}
    state = put_in(state.subs[ref], sub)
    if state.node, do: send_sub(state, ref), else: state
  end

  @impl true
  def handle_info(:connect, %{conn: conn} = state) when conn != nil, do: {:noreply, state}

  def handle_info(:connect, state) do
    case open(state.link) do
      {:ok, conn, request} ->
        state = members(state, cluster(state.link))
        {:noreply, %{state | conn: conn, request: request, upgrade: %{responses: []}}}

      {:error, :refused} ->
        Logger.warning("link to #{label(state)}: its token is no longer accepted")
        problem(state, "refused")
        {:noreply, %{state | problem: "refused"}}

      {:error, reason} ->
        Logger.warning("link to #{label(state)}: #{reason}")
        problem(state, "unreachable")
        {:noreply, retry(%{state | problem: "unreachable"})}
    end
  end

  def handle_info({:ping, tag}, %{ping: tag, heard: false} = state) do
    Logger.info("link to #{label(state)} stopped answering")
    {:noreply, down(state)}
  end

  def handle_info({:ping, tag}, %{ping: tag} = state) do
    Process.send_after(self(), {:ping, tag}, @ping)
    {:noreply, push(%{state | heard: false}, %{"t" => "ping"})}
  end

  # A ping loop of a socket that is gone.
  def handle_info({:ping, _tag}, state), do: {:noreply, state}

  # The untagged loop from before the liveness check: the socket's loop starts afresh.
  def handle_info(:ping, %{ws: nil} = state), do: {:noreply, state}
  def handle_info(:ping, state), do: {:noreply, ping(state)}

  def handle_info({:DOWN, monitor, :process, _pid, _}, state) do
    case Enum.find(state.subs, fn {_, sub} -> sub.monitor == monitor end) do
      {ref, _} -> {:noreply, drop_sub(state, ref, true)}
      nil -> {:noreply, state}
    end
  end

  def handle_info(message, %{conn: conn} = state) when conn != nil do
    case Mint.WebSocket.stream(conn, message) do
      :unknown ->
        {:noreply, state}

      {:ok, conn, responses} ->
        {:noreply, received(%{state | conn: conn}, responses)}

      {:error, conn, reason, _responses} ->
        Logger.info("link to #{label(state)} dropped: #{inspect(reason)}")
        {:noreply, down(%{state | conn: conn})}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- the socket ----------------------------------------------------------------

  # A fresh ticket for each connection; the link's token only mints them.
  defp open(link) do
    uri = URI.parse(link["origin"])
    auth = [{"authorization", "Bearer " <> link["token"]}]

    with {:ticket, {:ok, 200, %{"ticket" => ticket}}} <-
           {:ticket,
            HalC2.Links.http(
              :post,
              link["origin"] <> "/api/auth/websocket-ticket",
              auth,
              {"application/json", "{}"}
            )},
         path = "/ws?" <> URI.encode_query(%{"wsTicket" => ticket, "protocol" => 3}),
         # HTTP/1.1 only: over HTTP/2 a websocket needs extended CONNECT, which
         # proxies such as `tailscale serve` do not offer.
         {:ok, conn} <-
           Mint.HTTP.connect(String.to_existing_atom(uri.scheme), uri.host, uri.port,
             protocols: [:http1]
           ),
         {:ok, conn, request} <-
           Mint.WebSocket.upgrade(if(uri.scheme == "https", do: :wss, else: :ws), conn, path, []) do
      {:ok, conn, request}
    else
      {:ticket, {:ok, 401, _}} -> {:error, :refused}
      {:ticket, {:ok, status, _}} -> {:error, "ticket refused (#{status})"}
      {:ticket, {:error, reason}} -> {:error, "unreachable (#{inspect(reason)})"}
      {:error, reason} -> {:error, "unreachable (#{inspect(reason)})"}
      {:error, _conn, reason} -> {:error, "unreachable (#{inspect(reason)})"}
    end
  end

  # The upgrade's response, until the socket is open.
  defp received(%{ws: nil, upgrade: upgrade, request: request} = state, responses) do
    responses = upgrade.responses ++ responses

    if Enum.any?(responses, &match?({:done, ^request}, &1)) do
      status = Enum.find_value(responses, fn r -> match?({:status, _, _}, r) && elem(r, 2) end)

      headers =
        Enum.find_value(responses, [], fn r -> match?({:headers, _, _}, r) && elem(r, 2) end)

      case Mint.WebSocket.new(state.conn, request, status, headers) do
        {:ok, conn, ws} ->
          early = for {:data, ^request, data} <- responses, into: "", do: data
          frames(%{state | conn: conn, ws: ws, upgrade: nil}, early)

        {:error, conn, reason} ->
          Logger.warning("link to #{label(state)}: upgrade refused (#{inspect(reason)})")
          down(%{state | conn: conn})
      end
    else
      %{state | upgrade: %{upgrade | responses: responses}}
    end
  end

  defp received(%{request: request} = state, responses) do
    if Enum.any?(responses, &match?({:done, ^request}, &1)),
      do: down(state),
      else: frames(state, for({:data, ^request, data} <- responses, into: "", do: data))
  end

  defp frames(state, ""), do: state

  defp frames(state, data) do
    case Mint.WebSocket.decode(state.ws, data) do
      {:ok, ws, frames} ->
        Enum.reduce_while(frames, %{state | ws: ws, heard: true}, fn
          _frame, %{ws: nil} = state -> {:halt, state}
          {:text, text}, state -> {:cont, message(state, JSON.decode!(text))}
          {:ping, data}, state -> {:cont, send_frame(state, {:pong, data})}
          {:close, _, _}, state -> {:halt, down(state)}
          _, state -> {:cont, state}
        end)

      {:error, _ws, reason} ->
        Logger.warning("link to #{label(state)}: bad frame (#{inspect(reason)})")
        down(state)
    end
  end

  defp message(state, %{"t" => "hello", "node" => node}) do
    GenServer.cast(HalC2.Links, {:online, state.environment, true})
    state = ping(%{state | node: node, backoff: @min_backoff, problem: nil})
    Enum.reduce(Map.keys(state.subs), state, &send_sub(&2, &1))
  end

  defp message(state, %{"t" => t, "id" => id} = frame) when t in ["rpc.result", "rpc.error"] do
    case Map.pop(state.pending, id) do
      {{:call, from}, pending} ->
        GenServer.reply(from, reply(frame))
        %{state | pending: pending}

      _ ->
        state
    end
  end

  defp message(state, %{"t" => t, "id" => id} = frame) do
    case state.pending do
      %{^id => {:sub, ref}} ->
        # A member the frame names is reachable before anyone hears of it.
        state = learn(state, frame)
        send(state.subs[ref].pid, {:hal_c2_link, ref, frame})

        # The remote ended the subscription; a stream that fell behind resubscribes.
        if t in ["end", "error", "resync"],
          do: drop_sub(state, ref, false),
          else: update_in(state.subs[ref], &passed_on(&1, frame))

      _ ->
        state
    end
  end

  defp message(state, _frame), do: state

  # How far a stream's subscriber has been brought, to resume from after a drop.
  defp passed_on(sub, %{"t" => t, "offset" => offset}) when t in ["events", "live"],
    do: %{sub | offset: offset}

  defp passed_on(sub, %{"t" => "snapshot", "done" => true, "offset" => offset}),
    do: %{sub | offset: offset}

  defp passed_on(sub, _frame), do: sub

  defp reply(%{"t" => "rpc.result"} = frame), do: {:ok, frame["result"]}

  defp reply(%{"detail" => %{} = detail} = frame),
    do: {:error, Map.put(detail, "message", frame["error"])}

  defp reply(frame), do: {:error, frame["error"]}

  # A shape for the environment itself goes to its node by name; one for a member of
  # its cluster keeps the member's environment, for the environment to route.
  defp send_sub(state, ref) do
    {id, state} = next_id(state)
    sub = state.subs[ref]

    shape =
      if sub.shape["environment"] in [nil, state.environment],
        do: sub.shape |> Map.delete("environment") |> Map.put("node", state.node),
        else: sub.shape

    state
    |> put_in([:subs, ref], %{sub | id: id})
    |> put_in([:pending, id], {:sub, ref})
    |> push(%{"t" => "sub", "id" => id, "shape" => shape, "offset" => sub.offset})
  end

  defp drop_sub(state, ref, unsubscribe?) do
    case Map.pop(state.subs, ref) do
      {nil, _} ->
        state

      {sub, subs} ->
        Process.demonitor(sub.monitor, [:flush])
        state = %{state | subs: subs, pending: Map.delete(state.pending, sub.id)}

        if unsubscribe? and sub.id != nil and state.node != nil,
          do: push(state, %{"t" => "unsub", "id" => sub.id}),
          else: state
    end
  end

  defp push(state, frame), do: send_frame(state, {:text, JSON.encode!(frame)})

  defp send_frame(%{ws: nil} = state, _frame), do: state

  defp send_frame(state, frame) do
    with {:ok, ws, data} <- Mint.WebSocket.encode(state.ws, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.request, data) do
      %{state | ws: ws, conn: conn}
    else
      _ -> down(state)
    end
  end

  # The socket is gone: pending calls fail, subscriptions wait for the next one.
  defp down(state) do
    if state.conn, do: Mint.HTTP.close(state.conn)
    if state.node, do: GenServer.cast(HalC2.Links, {:online, state.environment, false})

    for {_id, {:call, from}} <- state.pending,
        do: GenServer.reply(from, {:error, down_error(state, state.environment)})

    subs = Map.new(state.subs, fn {ref, sub} -> {ref, %{sub | id: nil}} end)

    retry(%{
      state
      | problem: "unreachable",
        ping: nil,
        conn: nil,
        request: nil,
        upgrade: nil,
        ws: nil,
        node: nil,
        pending: %{},
        subs: subs
    })
  end

  defp ping(state) do
    tag = make_ref()
    Process.send_after(self(), {:ping, tag}, @ping)
    %{state | ping: tag, heard: true}
  end

  defp retry(state) do
    Process.send_after(self(), :connect, state.backoff)
    %{state | backoff: min(state.backoff * 2, @max_backoff)}
  end

  defp next_id(state), do: {state.next_id, %{state | next_id: state.next_id + 1}}

  defp problem(state, kind), do: GenServer.cast(HalC2.Links, {:problem, state.environment, kind})

  defp label(state), do: state.link["environment"]["label"] || state.link["origin"]

  # What a request for `environment` gets while the link is down.
  defp down_error(%{problem: "refused"} = state, environment),
    do:
      HalC2.Links.unreachable(
        environment,
        "refused",
        "#{label(state)} no longer accepts this node's access; pair it again"
      )

  defp down_error(state, environment),
    do: HalC2.Links.unreachable(environment, "unreachable", "#{label(state)} is unreachable")

  # --- the environment's cluster ---------------------------------------------------

  # Its members' environment ids, from its descriptor; nil when that cannot be read.
  defp cluster(link) do
    case HalC2.Links.http(:get, link["origin"] <> "/.well-known/hal-c2/environment", [], nil) do
      {:ok, 200, %{"cluster" => cluster}} when is_list(cluster) ->
        for %{"environmentId" => id} when is_binary(id) <- cluster, do: id

      _ ->
        nil
    end
  end

  # Environments of its cluster that its shells name as they pass through.
  defp learn(state, %{"t" => "shell", "nodes" => nodes}) do
    ids = for %{"environment" => %{"environmentId" => id}} <- nodes, do: id
    members(state, MapSet.union(state.members, MapSet.new(ids)))
  end

  defp learn(state, %{"t" => "shell.environment", "environment" => %{"environmentId" => id}}),
    do: members(state, MapSet.put(state.members, id))

  defp learn(state, _frame), do: state

  # Registers `ids` (but its own environment, and ones this node reaches otherwise) as
  # the members this link reaches, and lets go of the rest.
  defp members(state, nil), do: state

  defp members(state, ids) do
    ids =
      ids
      |> MapSet.new()
      |> MapSet.delete(state.environment)
      |> MapSet.reject(&(HalC2.Links.route(&1) != :unknown and &1 not in state.members))

    for id <- MapSet.difference(state.members, ids),
        do: Registry.unregister(HalC2.Links.Registry, id)

    # Another link may reach the same member; the first to register it keeps it.
    for id <- MapSet.difference(ids, state.members),
        do: Registry.register(HalC2.Links.Registry, id, :member)

    %{state | members: ids}
  end
end
