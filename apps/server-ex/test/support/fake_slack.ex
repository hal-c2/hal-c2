defmodule HalC2.Test.FakeSlack do
  @moduledoc """
  A Slack workspace for tests, so nothing reaches slack.com. `start/1` makes every Req
  request the MC sends answer from this plug (`Req.default_options/1`, restored when
  the test ends): the Web API under `/api/<method>` and slash commands' `response_url`s.
  `apps.connections.open` hands out a loopback Socket Mode URL served by Bandit, whose
  socket says hello, takes acks and pushes what `event/1` and `command/1` send.

  The workspace is "acme" (`T0ACME`) with the bot "HAL" (`UHAL`, `BHAL`), the person
  "dana" (`UDANA`), the channel "#planning" (`CPLAN`) the bot is in and "#random"
  (`CRANDOM`) it is not. It takes the tokens `bot_token/0` and `app_token/0`; any other
  is `invalid_auth`. `available(false)` answers every request with a 503 until it is
  `true` again; `drop/0` closes the socket. `calls/1` lists the requests made to a
  method, `responses/0` the slash command answers. Tests that use it are not async:
  it is one named process and Req's defaults are global.
  """
  @behaviour Plug

  import Plug.Conn

  @bot_token "xoxb-acme-test"
  @app_token "xapp-acme-test"

  def bot_token, do: @bot_token
  def app_token, do: @app_token

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
        calls: [],
        responses: [],
        socket: nil,
        # Frames and drops sent before the socket's server side is up, in order.
        pending: [],
        seq: 0
      },
      overrides
    )
  end

  @doc "Whether Slack answers at all."
  def available(on?), do: Agent.update(__MODULE__, &%{&1 | available: on?})

  @doc "Closes the Socket Mode connection, as Slack or the network does."
  def drop, do: to_socket(:drop)

  @doc "Pushes a Socket Mode `events_api` envelope carrying `event`."
  def event(event),
    do: to_socket({:frame, envelope("events_api", %{"event" => event})})

  @doc "Pushes a `slash_commands` envelope; `payload` as Slack sends one."
  def command(payload), do: to_socket({:frame, envelope("slash_commands", payload)})

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
    conn
    |> WebSockAdapter.upgrade(__MODULE__.Socket, nil, timeout: :infinity)
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

  defp bearer("Bearer " <> token), do: token
  defp bearer(_), do: nil

  defp answer("apps.connections.open", @app_token, _params, state),
    do: {ok(%{"url" => "ws://127.0.0.1:#{state.port}/link"}), state}

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

  defp answer("users.conversations", _token, _params, state) do
    channels =
      for {id, %{"member" => true} = channel} <- Enum.sort(state.channels) do
        %{"id" => id, "name" => channel["name"], "is_private" => channel["private"]}
      end

    {ok(%{"channels" => channels, "response_metadata" => %{"next_cursor" => ""}}), state}
  end

  defp answer("users.info", _token, %{"user" => id}, state) do
    case state.users[id] do
      nil -> {refuse("user_not_found"), state}
      user -> {ok(%{"user" => Map.put(user, "id", id)}), state}
    end
  end

  defp answer("conversations.replies", _token, %{"channel" => channel, "ts" => ts}, state) do
    with :ok <- member(state, channel) do
      messages =
        for m <- Enum.reverse(state.messages),
            m["channel"] == channel and (m["ts"] == ts or m["thread_ts"] == ts),
            do: m

      if messages == [],
        do: {refuse("thread_not_found"), state},
        else: {ok(%{"messages" => messages}), state}
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
    def init(_) do
      me = self()

      pending =
        Agent.get_and_update(HalC2.Test.FakeSlack, fn state ->
          {state.pending, %{state | socket: me, pending: []}}
        end)

      for message <- pending, do: send(self(), message)
      {:push, {:text, JSON.encode!(%{"type" => "hello"})}, %{}}
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

      Agent.update(HalC2.Test.FakeSlack, fn
        %{socket: ^me} = state -> %{state | socket: nil}
        state -> state
      end)
    catch
      :exit, _ -> :ok
    end
  end
end
