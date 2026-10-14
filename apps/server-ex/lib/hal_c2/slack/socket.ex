defmodule HalC2.Slack.Socket do
  @moduledoc """
  One Socket Mode connection, started by `HalC2.Slack` with the URL `apps.connections.open`
  handed out and the bot's identity. It tells its owner the app Slack's `hello` names
  (`{:slack_hello, socket, app_id}`), so the MC can refuse an app token of another app
  than the bot token's, and acks every envelope but hands `HalC2.Slack.Bot` only those for
  the bot's app and workspace, each in a task. An ack can be lost with the connection, and
  Slack then delivers the event again, on the next connection too; `HalC2.Slack.Bot` hands
  it on once. It never reconnects: when it ends, `HalC2.Slack` makes a new one.
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

    state = %{identity: identity, owner: owner, alive: true}
    WebSockex.start_link(url, __MODULE__, state, insecure: false, ssl_options: ssl)
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

      {:ok, %{"envelope_id" => id} = envelope} ->
        deliver(envelope, state.identity)
        {:reply, {:text, JSON.encode!(%{"envelope_id" => id})}, state}

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

  def handle_info(_message, state), do: {:ok, state}

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
  workspace an event happened in and, in `authorizations`, the installations it reached;
  in a channel shared with another workspace those differ.
  """
  def ours?(payload, identity) do
    teams = [payload["team_id"] | for(a <- payload["authorizations"] || [], do: a["team_id"])]
    payload["api_app_id"] == identity.app_id and identity.team_id in teams
  end
end
