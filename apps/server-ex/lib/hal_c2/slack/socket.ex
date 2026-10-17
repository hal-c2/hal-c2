defmodule HalC2.Slack.Socket do
  @moduledoc """
  One Socket Mode connection, started by `HalC2.Slack` with the URL `apps.connections.open`
  handed out and the bot's identity. It tells its owner the app Slack's `hello` names
  (`{:slack_hello, socket, app_id}`), so the MC can refuse an app token of another app
  than the bot token's. Until the owner has made the bot's identity the MC's
  (`activate/1`) it holds envelopes unacked, as Slack may send them straight after hello:
  `HalC2.Slack.Bot` would drop them, and Slack, acked, would not send them again. A socket
  never activated (the attempt was replaced) ends with them unacked, and Slack delivers
  them on the next connection. Active, it acks every envelope, in the order they came, but
  hands `HalC2.Slack.Bot` only those for the bot's app and workspace, each in a task. An
  ack can be lost with the connection, and Slack then delivers the event again, on the
  next connection too; `HalC2.Slack.Bot` hands it on once. When the owner is about to
  forget the identity (a connect or disconnect replaces the connection) it
  `deactivate/1`s the socket first, which answers once the socket holds envelopes unacked
  again, so none is acked into a bot that no longer knows who it is; the socket ends soon
  after, and Slack delivers them on the next connection. It never reconnects: when it
  ends, `HalC2.Slack` makes a new one.
  """

  use WebSockex
  require Logger

  @ping_ms 30_000

  def child_spec({url, identity, owner}) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [url, identity, owner]},
      restart: :temporary
    }
  end

  # WebSockex skips checking the server's certificate unless told otherwise.
  def start_link(url, identity, owner) do
    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    state = %{identity: identity, owner: owner, alive: true, active: false, held: []}
    WebSockex.start_link(url, __MODULE__, state, insecure: false, ssl_options: ssl)
  end

  @doc "Acks and hands on the envelopes held so far, and every one after; the owner's call."
  def activate(socket), do: send(socket, :activate)

  @doc """
  Makes the socket hold envelopes unacked again, and answers once it does: none it had
  begun to handle is left to ack afterwards. The owner's call, before it forgets the
  identity; `:ok` too when the socket has ended. One that does not answer in time is
  killed, as it could still ack: its connection ends and Slack delivers its events again.
  """
  def deactivate(socket, timeout \\ 5_000) do
    ref = Process.monitor(socket)
    send(socket, {:deactivate, self(), ref})

    receive do
      {^ref, :deactivated} ->
        Process.demonitor(ref, [:flush])
        :ok

      {:DOWN, ^ref, :process, _, _} ->
        :ok
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        Process.exit(socket, :kill)
        :ok
    end
  end

  @impl true
  def handle_connect(_conn, state) do
    Process.send_after(self(), :ping, @ping_ms)
    {:ok, state}
  end

  @impl true
  def handle_frame({:text, text}, state) do
    state = %{state | alive: true}

    case JSON.decode(text) do
      {:ok, %{"type" => "hello"} = hello} ->
        send(state.owner, {:slack_hello, self(), get_in(hello, ["connection_info", "app_id"])})
        {:ok, state}

      # Behind held ones too, so they are handed on in the order they came.
      {:ok, %{"envelope_id" => _} = envelope} when state.active and state.held == [] ->
        {:reply, take(envelope, state.identity), state}

      {:ok, %{"envelope_id" => _} = envelope} ->
        {:ok, %{state | held: state.held ++ [envelope]}}

      _ ->
        {:ok, state}
    end
  end

  def handle_frame(_frame, state), do: {:ok, %{state | alive: true}}

  # A pong echoes the ping's payload, as RFC 6455 asks.
  @impl true
  def handle_ping(:ping, state), do: {:reply, :pong, %{state | alive: true}}
  def handle_ping({:ping, data}, state), do: {:reply, {:pong, data}, %{state | alive: true}}

  @impl true
  def handle_pong(_pong, state), do: {:ok, %{state | alive: true}}

  # A connection that dies without a close frame would wait forever, so it pings, and
  # closes when nothing at all arrived since the last ping.
  @impl true
  def handle_info(:ping, %{alive: false} = state) do
    Logger.info("Slack sent nothing for #{@ping_ms}ms; closing the connection")
    {:close, state}
  end

  def handle_info(:ping, state) do
    Process.send_after(self(), :ping, @ping_ms)
    {:reply, :ping, %{state | alive: false}}
  end

  # One held envelope per message, as a callback acks only one.
  def handle_info(:activate, state) do
    send(self(), :drain)
    {:ok, %{state | active: true}}
  end

  def handle_info({:deactivate, from, ref}, state) do
    send(from, {ref, :deactivated})
    {:ok, %{state | active: false}}
  end

  def handle_info(:drain, %{held: [envelope | rest], active: true} = state) do
    if rest != [], do: send(self(), :drain)
    {:reply, take(envelope, state.identity), %{state | held: rest}}
  end

  def handle_info(_message, state), do: {:ok, state}

  # Hands the envelope on if it is the bot's; answers its ack.
  defp take(%{"envelope_id" => id} = envelope, identity) do
    deliver(envelope, identity)
    {:text, JSON.encode!(%{"envelope_id" => id})}
  end

  defp deliver(%{"type" => type, "payload" => payload}, identity) do
    with true <- ours?(payload, identity),
         {type, event, id} when is_map(event) <- event(type, payload) do
      Task.Supervisor.start_child(HalC2.Slack.Tasks, fn ->
        HalC2.Slack.Bot.handle_event(type, event, identity, id)
      end)
    end
  end

  defp deliver(_envelope, _identity), do: nil

  # With the Events API's `event_id`, the same on every delivery of an event.
  defp event("events_api", %{"event" => %{"type" => type} = event} = payload),
    do: {type, event, payload["event_id"]}

  defp event("slash_commands", payload), do: {"slash_commands", payload, nil}
  defp event(_type, _payload), do: nil

  @doc """
  Whether an envelope's payload is for the bot: its app, and its workspace. Slack names the
  workspace an event happened in and, in `authorizations`, the installation it reached; in a
  channel shared with another workspace those differ, and only the installation counts. A
  payload without `authorizations`, such as a slash command, names the workspace alone.
  """
  def ours?(payload, identity) do
    teams =
      case payload["authorizations"] do
        [_ | _] = authorizations -> for a <- authorizations, do: a["team_id"]
        _ -> [payload["team_id"]]
      end

    payload["api_app_id"] == identity.app_id and identity.team_id in teams
  end
end
