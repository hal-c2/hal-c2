defmodule HalC2.Web.SocketSlowFollowTest do
  # A stream that is slow to take a subscription must not hold up the socket: the
  # client's pings are answered meanwhile, or it gives up on a healthy MC and
  # reconnects, leaving the old socket behind.
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

    {:ok, _} = Streams.commit("th-slow", :thread, [item("a")])
    shape = %{"type" => "stream", "mc" => Atom.to_string(node()), "stream" => "th-slow"}

    {:ok, client} = WsClient.connect(port, "/ws?token=#{HalC2.Web.token()}")
    {%{"t" => "hello"}, client} = WsClient.recv(client, 1_000)

    # The stream's server busy elsewhere: it takes no subscription until resumed.
    server = Streams.ensure("th-slow")
    :ok = :sys.suspend(server)
    on_exit(fn -> if Process.alive?(server), do: :sys.resume(server) end)

    %{client: client, shape: shape, server: server}
  end

  defp item(text), do: {"turn-item", "i1", %{"s" => %{"text" => text}}}

  defp sub(client, shape),
    do: WsClient.send_json(client, %{"t" => "sub", "id" => 7, "shape" => shape})

  defp ping(client) do
    client = WsClient.send_json(client, %{"t" => "ping"})
    WsClient.recv_until(client, &(&1["t"] == "pong"), 1_000)
  end

  test "a ping is answered while a subscription waits on its stream",
       %{client: client, shape: shape, server: server} do
    {_pong, [], client} = client |> sub(shape) |> ping()

    :sys.resume(server)

    assert {%{"t" => "live", "id" => 7}, _, client} =
             WsClient.recv_until(client, &(&1["t"] == "live"), 5_000)

    {:ok, next} = Streams.commit("th-slow", :thread, [item("b")])

    assert {%{"t" => "events", "id" => 7, "offset" => ^next}, _} =
             WsClient.recv(client, 1_000)
  end

  test "a second sub of a stream still being followed is refused",
       %{client: client, shape: shape} do
    client = sub(client, shape)
    client = WsClient.send_json(client, %{"t" => "sub", "id" => 8, "shape" => shape})

    assert {%{"t" => "error", "id" => 8, "reason" => "already subscribed"}, _} =
             WsClient.recv(client, 1_000)
  end

  test "an unsub before the stream answers leaves it with no subscriber",
       %{client: client, shape: shape, server: server} do
    :erlang.trace(server, true, [:receive])
    client = client |> sub(shape) |> WsClient.send_json(%{"t" => "unsub", "id" => 7})
    {_pong, [], client} = ping(client)

    :sys.resume(server)
    # The stream takes the follow, then an unsubscribe for it: the socket's own may
    # reach the stream first, and does nothing there, so wait for one after the follow.
    await_trace(server, &match?({:"$gen_call", _, {:subscribe, _, _, _}}, &1))
    await_trace(server, &match?({:"$gen_cast", {:unsubscribe, _, _}}, &1))
    :erlang.trace(server, false, [:receive])
    assert :sys.get_state(server).subscribers == %{}

    {:ok, _} = Streams.commit("th-slow", :thread, [item("b")])
    {_pong, frames, _} = ping(client)
    assert frames == []
  end

  test "a stream that answers before the socket hears of its follow loses nothing",
       %{client: client, shape: shape, server: server} do
    :erlang.trace(server, true, [:receive])
    client = sub(client, shape)
    assert_receive {:trace, ^server, :receive, {:"$gen_call", _, {:subscribe, _, _, _}}}, 1_000
    :erlang.trace(server, false, [:receive])
    {_pong, [], client} = ping(client)
    # The commit lands while the follow waits; its events reach the client after
    # the subscription's live, in order.
    task = Task.async(fn -> Streams.commit("th-slow", :thread, [item("b")]) end)
    :sys.resume(server)
    {:ok, next} = Task.await(task)

    {_live, _, client} = WsClient.recv_until(client, &(&1["t"] == "live"), 5_000)

    {%{"t" => "events", "id" => 7, "offset" => offset}, _, _} =
      WsClient.recv_until(client, &(&1["t"] == "events"), 5_000)

    assert offset == next
  end

  # The next message `server` takes that `match?` holds for, in the order it took them.
  defp await_trace(server, match?) do
    receive do
      {:trace, ^server, :receive, message} ->
        if match?.(message), do: :ok, else: await_trace(server, match?)
    after
      1_000 -> flunk("#{inspect(server)} took no such message")
    end
  end
end
