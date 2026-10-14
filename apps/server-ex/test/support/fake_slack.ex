defmodule HalC2.Test.FakeSlack do
  @moduledoc """
  A Slack workspace for tests, so nothing reaches slack.com. `start/1` makes every Req
  request the MC sends answer from this plug (`Req.default_options/1`, restored when
  the test ends): the Web API under `/api/<method>` and slash commands' `response_url`s.
  `apps.connections.open` hands out a loopback Socket Mode URL served by Bandit, whose
  socket says hello (naming the app token's app), takes acks and pushes what `event/2`
  and `command/1` send, as envelopes from the bot's app and workspace unless told
  otherwise, and what `retry/3` sends again.

  The workspace is "acme" (`T0ACME`) with the app `A0ACME`, its bot "HAL" (`UHAL`,
  `BHAL`), the person "dana" (`UDANA`), the channel "#planning" (`CPLAN`) the bot is in
  and "#random" (`CRANDOM`) it is not. It takes the tokens `bot_token/0` and
  `app_token/0`, and `other_app_token/0`, the app token of another app (`A0OTHER`); any
  other is `invalid_auth`. `available(false)` answers every request with a 503 until it is
  `true` again; `drop/0` closes the socket. `hello(false)` makes new sockets keep quiet,
  `hold/1` makes a Web API method wait until `release/0`. Paginated methods follow Slack's `cursor`, in
  pages of `page_size/1` at most; `join/2` adds a channel the bot is in. `calls/1` lists
  the requests made to a method, `responses/0` the slash command answers. Tests that use
  it are not async: it is one named process and Req's defaults are global.
  """
  @behaviour Plug

  import Plug.Conn

  @bot_token "xoxb-acme-test"
  @app_token "xapp-acme-test"
  @other_app_token "xapp-other-test"
  @apps %{@app_token => "A0ACME", @other_app_token => "A0OTHER"}

  def bot_token, do: @bot_token
  def app_token, do: @app_token
  def other_app_token, do: @other_app_token

  @doc "Starts the workspace under the test supervisor, for as long as the test runs."
  def start(overrides \\ %{}) do
    server =
      ExUnit.Callbacks.start_supervised!(
        {Bandit, plug: __MODULE__, port: 0, ip: :loopback},
        id: {__MODULE__, :socket}
      )

    ExUnit.Callbacks.start_supervised!(%{
      id: __MODULE__,
      start:
        {Agent, :start_link, [fn -> initial(port(server), overrides) end, [name: __MODULE__]]}
    })

    ExUnit.Callbacks.on_exit(route_req())
    :ok
  end

  @doc """
  Starts the workspace outside a test's own process (a property case, where
  `start_supervised` is not available); answers the function that stops it again.
  """
  def start_unsupervised(overrides \\ %{}) do
    {:ok, server} = Bandit.start_link(plug: __MODULE__, port: 0, ip: :loopback)
    {:ok, agent} = Agent.start_link(fn -> initial(port(server), overrides) end, name: __MODULE__)
    Enum.each([server, agent], &Process.unlink/1)
    restore = route_req()

    fn ->
      Agent.stop(agent)
      Supervisor.stop(server)
      restore.()
    end
  end

  defp port(server) do
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    port
  end

  # Sends every Req request here; answers the function that puts Req's defaults back.
  defp route_req do
    previous = Application.get_env(:req, :default_options)
    Req.default_options(plug: __MODULE__, retry: false)

    fn ->
      if previous,
        do: Application.put_env(:req, :default_options, previous),
        else: Application.delete_env(:req, :default_options)
    end
  end

  defp initial(port, overrides) do
    Map.merge(
      %{
        port: port,
        team: "acme",
        team_id: "T0ACME",
        bot: "HAL",
        bot_user_id: "UHAL",
        bot_id: "BHAL",
        app_id: "A0ACME",
        available: true,
        channels: %{
          "CPLAN" => %{"name" => "planning", "member" => true, "private" => false},
          "CRANDOM" => %{"name" => "random", "member" => false, "private" => false}
        },
        users: %{
          "UDANA" => %{"name" => "dana", "real_name" => "Dana Ito"},
          "UHAL" => %{"name" => "HAL", "real_name" => "HAL"}
        },
        messages: [],
        # The most a page of a paginated method holds, whatever `limit` asks.
        page_size: 1000,
        calls: [],
        responses: [],
        socket: nil,
        # Frames and drops sent before the socket's server side is up, in order.
        pending: [],
        # Whether a new socket says hello, and who hears it open and close.
        hello: true,
        watcher: nil,
        # Web API methods that wait for `release/0`, and the requests waiting.
        held: MapSet.new(),
        waiting: [],
        seq: 0
      },
      overrides
    )
  end

  @doc """
  Whether a new socket says hello; `pid` hears `{:fake_slack_socket, :open | :closed}`
  as the socket's server side opens and closes.
  """
  def hello(on?, pid \\ self()),
    do: Agent.update(__MODULE__, &%{&1 | hello: on?, watcher: pid})

  @doc """
  Makes requests to `method` wait until `release/0`; `pid` hears
  `{:fake_slack_held, method, requester}` as each one starts waiting.
  """
  def hold(method, pid \\ self()),
    do: Agent.update(__MODULE__, &%{&1 | held: MapSet.put(&1.held, method), watcher: pid})

  @doc "Lets the held requests answer, and the next ones answer at once."
  def release do
    waiting =
      Agent.get_and_update(__MODULE__, &{&1.waiting, %{&1 | held: MapSet.new(), waiting: []}})

    for pid <- waiting, do: send(pid, :fake_slack_release)
    :ok
  end

  @doc "Whether Slack answers at all."
  def available(on?), do: Agent.update(__MODULE__, &%{&1 | available: on?})

  @doc "Pages of paginated methods hold at most `size` items from now on."
  def page_size(size), do: Agent.update(__MODULE__, &%{&1 | page_size: size})

  @doc "Puts the bot in the channel `id`, named `name`."
  def join(id, name) do
    Agent.update(__MODULE__, fn state ->
      channel = %{"name" => name, "member" => true, "private" => false}
      %{state | channels: Map.put(state.channels, id, channel)}
    end)
  end

  @doc "Takes the bot out of the channel `id`, as leaving it or its deletion does."
  def leave(id),
    do: Agent.update(__MODULE__, &%{&1 | channels: Map.delete(&1.channels, id)})

  @doc "Closes the Socket Mode connection, as Slack or the network does."
  def drop, do: to_socket(:drop)

  @doc """
  Pushes a Socket Mode `events_api` envelope carrying `event`, from the bot's app and
  workspace, with an `event_id` of its own; `payload` overrides the rest (`event_id`,
  `team_id`, `api_app_id`, `authorizations`).
  """
  def event(event, payload \\ %{}) do
    id = %{"event_id" => "Ev#{System.unique_integer([:positive])}"}
    payload = origin() |> Map.merge(id) |> Map.merge(Map.put(payload, "event", event))
    to_socket({:frame, envelope("events_api", payload)})
  end

  @doc """
  Pushes `event` again as Slack does when it missed the ack of the event `id`: a new
  envelope with the same `event_id`, and Socket Mode's `retry_attempt` and `retry_reason`.
  """
  def retry(event, id, attempt \\ 1) do
    payload = Map.merge(origin(), %{"event" => event, "event_id" => id})

    envelope =
      Map.merge(envelope("events_api", payload), %{
        "retry_attempt" => attempt,
        "retry_reason" => "timeout"
      })

    to_socket({:frame, envelope})
  end

  @doc "Pushes a `slash_commands` envelope; `payload` as Slack sends one."
  def command(payload),
    do: to_socket({:frame, envelope("slash_commands", Map.merge(origin(), payload))})

  # Where an envelope comes from: the bot's app, installed in the bot's workspace.
  defp origin do
    Agent.get(__MODULE__, fn state ->
      %{
        "team_id" => state.team_id,
        "api_app_id" => state.app_id,
        "authorizations" => [
          %{"team_id" => state.team_id, "user_id" => state.bot_user_id, "is_bot" => true}
        ]
      }
    end)
  end

  @doc "The params of every request to Web API `method`, oldest first."
  def calls(method) do
    for {^method, params} <- Agent.get(__MODULE__, &Enum.reverse(&1.calls)), do: params
  end

  @doc "What was posted to slash commands' response URLs: `%{\"url\", \"body\"}`."
  def responses, do: Agent.get(__MODULE__, &Enum.reverse(&1.responses))

  @doc "The workspace's messages, oldest first."
  def messages, do: Agent.get(__MODULE__, &Enum.reverse(&1.messages))

  @doc "Adds a message (string keys as Slack's: channel, user, text, thread_ts, bot_id); answers its ts."
  def add_message(message) do
    Agent.get_and_update(__MODULE__, fn state ->
      {ts, state} = next_ts(state)
      {ts, %{state | messages: [Map.put(message, "ts", ts) | state.messages]}}
    end)
  end

  @doc "A response URL for a slash command."
  def response_url,
    do: "https://hooks.slack.com/commands/T0ACME/#{System.unique_integer([:positive])}/x"

  defp envelope(type, payload),
    do: %{
      "envelope_id" => "env-#{System.unique_integer([:positive])}",
      "type" => type,
      "payload" => payload
    }

  defp to_socket(message) do
    pid =
      Agent.get_and_update(__MODULE__, fn
        %{socket: nil} = state -> {nil, %{state | pending: state.pending ++ [message]}}
        state -> {state.socket, state}
      end)

    if pid, do: send(pid, message)
    :ok
  end

  # --- the Web API ----------------------------------------------------------------------

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{request_path: "/link"} = conn, _opts) do
    app = URI.decode_query(conn.query_string)["app_id"]

    conn
    |> WebSockAdapter.upgrade(__MODULE__.Socket, app, timeout: :infinity)
    |> halt()
  end

  def call(%{host: "hooks.slack.com"} = conn, _opts) do
    {:ok, body, conn} = read_body(conn)
    url = "https://hooks.slack.com" <> conn.request_path

    Agent.update(__MODULE__, fn state ->
      %{state | responses: [%{"url" => url, "body" => JSON.decode!(body)} | state.responses]}
    end)

    send_resp(conn, 200, "ok")
  end

  def call(%{request_path: "/api/" <> method} = conn, _opts) do
    {:ok, body, conn} = read_body(conn)
    params = Map.merge(URI.decode_query(conn.query_string), URI.decode_query(body))
    params = Map.update(params, "channel", nil, &channel_id(&1))
    token = conn |> get_req_header("authorization") |> List.first() |> bearer()
    wait(method)

    reply =
      Agent.get_and_update(__MODULE__, fn state ->
        state = %{state | calls: [{method, params} | state.calls]}
        if state.available, do: answer(method, token, params, state), else: {:down, state}
      end)

    case reply do
      :down ->
        send_resp(conn, 503, "unavailable")

      reply ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, JSON.encode!(reply))
    end
  end

  # Req runs this plug in the process that asked, so a held method holds it.
  defp wait(method) do
    me = self()

    watcher =
      Agent.get_and_update(__MODULE__, fn state ->
        if method in state.held,
          do: {state.watcher, %{state | waiting: [me | state.waiting]}},
          else: {nil, state}
      end)

    if watcher do
      send(watcher, {:fake_slack_held, method, me})

      receive do
        :fake_slack_release -> :ok
      end
    end
  end

  defp bearer("Bearer " <> token), do: token
  defp bearer(_), do: nil

  defp answer("apps.connections.open", token, _params, state) when is_map_key(@apps, token),
    do: {ok(%{"url" => "ws://127.0.0.1:#{state.port}/link?app_id=#{@apps[token]}"}), state}

  defp answer("apps.connections.open", _token, _params, state),
    do: {refuse("invalid_auth"), state}

  defp answer(_method, token, _params, state) when token != @bot_token,
    do: {refuse("invalid_auth"), state}

  defp answer("auth.test", _token, _params, state) do
    {ok(%{
       "team" => state.team,
       "team_id" => state.team_id,
       "user" => state.bot,
       "user_id" => state.bot_user_id,
       "bot_id" => state.bot_id,
       "url" => "https://acme.slack.com/"
     }), state}
  end

  defp answer("bots.info", _token, %{"bot" => id}, %{bot_id: id} = state) do
    {ok(%{
       "bot" => %{
         "id" => id,
         "name" => state.bot,
         "app_id" => state.app_id,
         "user_id" => state.bot_user_id
       }
     }), state}
  end

  defp answer("bots.info", _token, _params, state), do: {refuse("bot_not_found"), state}

  defp answer("users.conversations", _token, params, state) do
    channels =
      for {id, %{"member" => true} = channel} <- Enum.sort(state.channels) do
        %{"id" => id, "name" => channel["name"], "is_private" => channel["private"]}
      end

    {channels, cursor} = page(channels, params, page_size(params, state))
    {ok(%{"channels" => channels, "response_metadata" => %{"next_cursor" => cursor}}), state}
  end

  defp answer("users.info", _token, %{"user" => id}, state) do
    case state.users[id] do
      nil -> {refuse("user_not_found"), state}
      user -> {ok(%{"user" => Map.put(user, "id", id)}), state}
    end
  end

  defp answer(
         "conversations.replies",
         _token,
         %{"channel" => channel, "ts" => ts} = params,
         state
       ) do
    with :ok <- member(state, channel) do
      messages =
        for m <- Enum.reverse(state.messages),
            m["channel"] == channel and (m["ts"] == ts or m["thread_ts"] == ts),
            do: m

      case messages do
        [] ->
          {refuse("thread_not_found"), state}

        # Every page starts with the parent, the replies paged after it.
        [parent | replies] ->
          {replies, cursor} = page(replies, params, max(page_size(params, state) - 1, 1))

          {ok(%{
             "messages" => [parent | replies],
             "response_metadata" => %{"next_cursor" => cursor}
           }), state}
      end
    else
      error -> {refuse(error), state}
    end
  end

  defp answer("chat.postMessage", _token, %{"channel" => channel} = params, state) do
    with :ok <- member(state, channel) do
      {ts, state} = next_ts(state)

      message =
        params
        |> Map.take(["channel", "text", "thread_ts", "blocks"])
        |> Map.merge(%{"ts" => ts, "user" => state.bot_user_id, "bot_id" => state.bot_id})

      {ok(%{"channel" => channel, "ts" => ts, "message" => message}),
       %{state | messages: [message | state.messages]}}
    else
      error -> {refuse(error), state}
    end
  end

  defp answer("chat.update", _token, %{"channel" => channel, "ts" => ts} = params, state) do
    case Enum.find_index(state.messages, &(&1["channel"] == channel and &1["ts"] == ts)) do
      nil ->
        {refuse("message_not_found"), state}

      index ->
        messages = List.update_at(state.messages, index, &Map.put(&1, "text", params["text"]))
        {ok(%{"channel" => channel, "ts" => ts}), %{state | messages: messages}}
    end
  end

  defp answer("reactions.add", _token, %{"channel" => channel}, state) do
    case member(state, channel) do
      :ok -> {ok(%{}), state}
      error -> {refuse(error), state}
    end
  end

  defp answer(_method, _token, _params, state), do: {refuse("unknown_method"), state}

  # One page of `items` from `cursor` (an offset here) and the next cursor, "" after the
  # last. Slack's `cursor` is the parameter; a `next_cursor` one is ignored, as Slack does.
  defp page(items, params, size) do
    offset = String.to_integer(params["cursor"] || "0")
    next = if offset + size < length(items), do: Integer.to_string(offset + size), else: ""
    {Enum.slice(items, offset, size), next}
  end

  defp page_size(params, state),
    do: min(String.to_integer(params["limit"] || "1000"), state.page_size)

  # Slack takes a channel's name where it takes its id.
  defp channel_id("#" <> name) do
    Agent.get(__MODULE__, fn state ->
      Enum.find_value(state.channels, "#" <> name, fn {id, c} -> c["name"] == name && id end)
    end)
  end

  defp channel_id(channel), do: channel

  defp member(state, channel) do
    case state.channels[channel] do
      nil -> "channel_not_found"
      %{"member" => true} -> :ok
      _ -> "not_in_channel"
    end
  end

  defp next_ts(state) do
    seq = state.seq + 1
    {"1700000000.#{String.pad_leading(Integer.to_string(seq), 6, "0")}", %{state | seq: seq}}
  end

  defp ok(body), do: Map.put(body, "ok", true)
  defp refuse(error), do: %{"ok" => false, "error" => error}

  defmodule Socket do
    @moduledoc false
    # The server side of one Socket Mode connection.
    @behaviour WebSock

    @impl true
    def init(app) do
      me = self()

      {pending, hello?, watcher} =
        Agent.get_and_update(HalC2.Test.FakeSlack, fn state ->
          {{state.pending, state.hello, state.watcher}, %{state | socket: me, pending: []}}
        end)

      for message <- pending, do: send(self(), message)
      if watcher, do: send(watcher, {:fake_slack_socket, :open})
      hello = %{"type" => "hello", "connection_info" => %{"app_id" => app}}
      if hello?, do: {:push, {:text, JSON.encode!(hello)}, %{}}, else: {:ok, %{}}
    end

    @impl true
    def handle_in(_ack, state), do: {:ok, state}

    @impl true
    def handle_info({:frame, frame}, state), do: {:push, {:text, JSON.encode!(frame)}, state}
    def handle_info(:drop, state), do: {:stop, :normal, state}
    def handle_info(_, state), do: {:ok, state}

    @impl true
    def terminate(_reason, _state) do
      me = self()

      watcher =
        Agent.get_and_update(HalC2.Test.FakeSlack, fn
          %{socket: ^me} = state -> {state.watcher, %{state | socket: nil}}
          state -> {state.watcher, state}
        end)

      if watcher, do: send(watcher, {:fake_slack_socket, :closed})
    catch
      :exit, _ -> :ok
    end
  end
end
