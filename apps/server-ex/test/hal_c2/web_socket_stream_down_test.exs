defmodule HalC2.Web.SocketStreamDownTest do
  # A stream's server that stops takes its subscriptions with it; the sockets
  # following it must tell their clients rather than go quiet. A subscription that
  # ends must not feed the next one.
  use ExUnit.Case, async: false

  alias HalC2.Streams
  alias HalC2.Test.WsClient

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    Application.put_env(:hal_c2, :port, 0)
    :persistent_term.erase({HalC2.Web, :token})
    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(start_supervised!(HalC2.Web))

    {:ok, _} = Streams.commit("th-down", :thread, [item("a")])
    shape = %{"type" => "stream", "mc" => Atom.to_string(node()), "stream" => "th-down"}

    {:ok, client} = WsClient.connect(port, "/ws?token=#{HalC2.Web.token()}")
    {%{"t" => "hello"}, client} = WsClient.recv(client, 1_000)
    client = WsClient.send_json(client, %{"t" => "sub", "id" => 7, "shape" => shape})
    {live, _snapshot, client} = WsClient.recv_until(client, &(&1["t"] == "live"))

    %{client: client, shape: shape, live: live}
  end

  defp item(text), do: {"turn-item", "i1", %{"s" => %{"text" => text}}}

  # Takes the stream down with its subscribers, as a crash does.
  defp stop_stream(reason) do
    server = Streams.ensure("th-down")
    ref = Process.monitor(server)
    Process.exit(server, reason)
    assert_receive {:DOWN, ^ref, :process, ^server, _}
  end

  defp resubscribe(client, shape, %{"offset" => offset, "handle" => handle}) do
    client
    |> WsClient.send_json(%{
      "t" => "sub",
      "id" => 7,
      "shape" => shape,
      "offset" => offset,
      "handle" => handle
    })
    |> WsClient.recv_until(&(&1["t"] == "live"))
  end

  test "a stream that crashes is resynced, and the client resumes from its own offset",
       %{client: client, shape: shape, live: live} do
    {:ok, seq} = Streams.commit("th-down", :thread, [item("b")])

    {%{"t" => "events", "offset" => ^seq} = events, _, client} =
      WsClient.recv_until(client, &(&1["t"] == "events"))

    stop_stream(:kill)

    assert {%{"t" => "resync", "id" => 7} = resync, client} = WsClient.recv(client, 1_000)
    refute Map.has_key?(resync, "offset")

    # Nothing it held is sent again, and what lands after reaches it.
    {%{"t" => "live", "offset" => ^seq}, [], client} =
      resubscribe(client, shape, %{live | "offset" => events["offset"]})

    {:ok, next} = Streams.commit("th-down", :thread, [item("c")])

    assert {%{"t" => "events", "id" => 7, "offset" => ^next}, _} =
             WsClient.recv(client, 1_000)
  end

  test "a stream whose MC left the cluster is an error, and the socket does not ask it again",
       %{client: client, shape: shape, live: live} do
    # The reason a monitor gives when the stream's MC drops off the cluster.
    stop_stream(:noconnection)

    assert {%{"t" => "error", "id" => 7, "reason" => "MC unavailable: noconnection"}, client} =
             WsClient.recv(client, 1_000)

    assert :sys.get_state(Streams.ensure("th-down")).subscribers == %{}

    # Once the MC is back the client follows the stream again.
    {%{"t" => "live"}, [], client} = resubscribe(client, shape, live)
    {:ok, next} = Streams.commit("th-down", :thread, [item("c")])

    assert {%{"t" => "events", "id" => 7, "offset" => ^next}, _} =
             WsClient.recv(client, 1_000)
  end

  # Found by proof/hal_c2/stream_relay_proof_test.exs.
  test "a message of the subscription a client left lands after it follows again, and is dropped",
       %{client: client, shape: shape, live: live} do
    stream = Streams.ensure("th-down")
    [{socket, %{name: left}}] = Map.to_list(:sys.get_state(stream).subscribers)

    client = WsClient.send_json(client, %{"t" => "unsub", "id" => 7})
    {%{"t" => "live"}, [], client} = resubscribe(client, shape, live)
    [{^socket, %{name: name}}] = Map.to_list(:sys.get_state(stream).subscribers)
    assert name != left

    # What a relay on a slow link still held for the old subscription.
    send(socket, {:hal_c2_stream, left, {:live, 0, live["handle"]}})
    {:ok, next} = Streams.commit("th-down", :thread, [item("b")])

    assert {%{"t" => "events", "id" => 7, "offset" => ^next}, _} =
             WsClient.recv(client, 1_000)
  end

  # Found by proof/hal_c2/stream_relay_proof_test.exs.
  test "the unsubscribe of a follow that gave up does not end the one after it",
       %{client: client} do
    stream = Streams.ensure("th-down")
    [socket] = Map.keys(:sys.get_state(stream).subscribers)
    # What the socket casts for a follow that failed, landing after it followed again.
    :ok = Streams.unsubscribe("th-down", socket, make_ref())
    {:ok, next} = Streams.commit("th-down", :thread, [item("b")])

    assert {%{"t" => "events", "id" => 7, "offset" => ^next}, _} =
             WsClient.recv(client, 1_000)
  end

  test "an unsubscribed stream that stops is no news to the client",
       %{client: client, shape: shape} do
    # The pong comes after the socket has taken the unsub.
    client = WsClient.send_json(client, %{"t" => "unsub", "id" => 7})
    client = WsClient.send_json(client, %{"t" => "ping"})
    {%{"t" => "pong"}, client} = WsClient.recv(client, 1_000)
    stop_stream(:kill)

    # The next frame is the answer to a new subscription, not a resync of the old one.
    client = WsClient.send_json(client, %{"t" => "sub", "id" => 8, "shape" => shape})
    assert {%{"t" => "snapshot", "id" => 8}, _} = WsClient.recv(client, 1_000)
  end
end
