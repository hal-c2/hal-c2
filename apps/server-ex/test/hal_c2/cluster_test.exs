defmodule HalC2.ClusterTest do
  # Starts a second BEAM MC with its own store and joins it to this one.
  use ExUnit.Case, async: false

  alias HalC2.Test.WsClient

  @moduletag :tmp_dir
  @moduletag :cluster

  setup %{tmp_dir: dir} do
    unless Node.alive?() do
      {_, 0} = System.cmd("epmd", ["-daemon"])
      # Unique names, so the test never collides with MCs running on this machine.
      {:ok, _} =
        Node.start(:"hal_c2_test#{System.unique_integer([:positive])}@127.0.0.1", :longnames)
    end

    Application.put_env(:hal_c2, :home, Path.join(dir, "a"))
    Application.put_env(:hal_c2, :port, 0)
    :persistent_term.erase({HalC2.Web, :token})
    start_supervised!({HalC2.Store, path: Path.join([dir, "a", "hal-c2.sqlite"])})
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(start_supervised!(HalC2.Web))

    {:ok, peer, b} =
      :peer.start_link(%{
        name: :"hal_c2_peer#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true,
        args: code_path_args()
      })

    # A peer MC does not read Mix config, so it gets the MC settings directly.
    for {key, value} <- [start_mc: true, home: Path.join(dir, "b"), port: 0],
        do: :ok = :erpc.call(b, Application, :put_env, [:hal_c2, key, value])

    {:ok, _} = :erpc.call(b, Application, :ensure_all_started, [:hal_c2])
    %{port: port, peer: peer, b: b}
  end

  defp code_path_args, do: Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

  test "a subscriber on another MC is fed through a relay, which the stream never waits for",
       %{b: b} do
    alias HalC2.Streams

    thread = [{"thread", "local-th", %{"s" => %{"id" => "local-th", "title" => "On a"}}}]
    {:ok, _} = Streams.commit("local-th", :thread, thread)

    # A process on MC b that passes what it is sent on to this test.
    subscriber = Node.spawn(b, Streams.Relay, :loop, [self()])
    :ok = Streams.subscribe("local-th", subscriber, nil)
    assert_receive {:hal_c2_stream, "local-th", {:snapshot, seq, _at, [_thread], :done}}, 1_000
    assert_receive {:hal_c2_stream, "local-th", {:live, ^seq}}, 1_000

    %{relays: %{^subscriber => relay}} = :sys.get_state(Streams.ensure("local-th"))

    # A connection that takes nothing more stops the relay, as a busy one does a sender.
    true = :erlang.suspend_process(relay)
    item = fn text -> [{"turn-item", "i1", %{"a" => %{"text" => text}}}] end
    {:ok, first} = Streams.commit("local-th", :thread, item.("one"))
    {:ok, second} = Streams.commit("local-th", :thread, item.("two"))
    assert Streams.Server.state(Streams.ensure("local-th")).seq == second

    true = :erlang.resume_process(relay)
    assert_receive {:hal_c2_stream, "local-th", {:events, [%{seq: ^first}]}}, 1_000
    assert_receive {:hal_c2_stream, "local-th", {:events, [%{seq: ^second}]}}, 1_000

    ref = Process.monitor(relay)
    :ok = Streams.unsubscribe("local-th", subscriber)
    assert_receive {:DOWN, ^ref, :process, ^relay, _}, 1_000
    assert :sys.get_state(Streams.ensure("local-th")).relays == %{}

    # A stream that stops takes its relays with it, whatever they are in the middle of.
    :ok = Streams.subscribe("local-th", subscriber, nil)
    stream = Streams.ensure("local-th")
    %{relays: %{^subscriber => relay}} = state = :sys.get_state(stream)
    ref = Process.monitor(relay)
    :ok = GenServer.stop(stream)
    assert_receive {:DOWN, ^ref, :process, ^relay, :killed}, 1_000

    # A stream from before relays gives the subscribers it already has one.
    {:ok, %{relays: %{^subscriber => relay}}} =
      Streams.Server.code_change(1, Map.delete(state, :relays), nil)

    send(relay, {:hal_c2_stream, "local-th", :passed_on})
    assert_receive {:hal_c2_stream, "local-th", :passed_on}, 1_000
    Process.exit(relay, :kill)
  end

  test "one socket sees and follows threads on every MC", %{port: port, peer: peer, b: b} do
    b_name = Atom.to_string(b)
    {:ok, client} = WsClient.connect(port, "/ws?token=#{HalC2.Web.token()}")
    {%{"t" => "hello"}, client} = WsClient.recv(client, 1_000)

    # A thread created on MC b shows up in MC a's shell.
    {:ok, _} =
      :erpc.call(b, HalC2.Streams, :commit, [
        "remote-th",
        :thread,
        [{"thread", "remote-th", %{"s" => %{"id" => "remote-th", "title" => "On b"}}}]
      ])

    client =
      WsClient.send_json(client, %{"t" => "sub", "id" => 1, "shape" => %{"type" => "shell"}})

    # Node b's row arrives in the first shell frame or, if b is still computing it, just after.
    has_remote_row? = fn
      %{"t" => "shell", "rows" => rows} ->
        Enum.any?(rows, &match?([^b_name, "remote-th", "thread", %{"title" => "On b"}], &1))

      %{"t" => "shell.rows", "mc" => ^b_name, "rows" => rows} ->
        Enum.any?(rows, &match?(["remote-th", "thread", %{"title" => "On b"}], &1))

      _ ->
        false
    end

    {_, _, client} = WsClient.recv_until(client, has_remote_row?)

    # Following it from MC a streams events committed on MC b.
    shape = %{"type" => "stream", "mc" => b_name, "stream" => "remote-th"}
    client = WsClient.send_json(client, %{"t" => "sub", "id" => 2, "shape" => shape})

    {%{"t" => "live"}, _, client} =
      WsClient.recv_until(client, &(&1["t"] == "live" and &1["id"] == 2))

    {:ok, seq} =
      :erpc.call(b, HalC2.Streams, :commit, [
        "remote-th",
        :thread,
        [{"turn-item", "i1", %{"s" => %{"text" => "from b"}}}]
      ])

    {events, _, client} = WsClient.recv_until(client, &(&1["t"] == "events" and &1["id"] == 2))
    assert [[^seq, "turn-item", "i1", %{"s" => %{"text" => "from b"}}, _at]] = events["events"]

    # Node a describes the whole cluster and serves MC b's config by environment id.
    {:ok, _} = Application.ensure_all_started(:inets)

    {:ok, {{_, 200, _}, _, body}} =
      :httpc.request(~c"http://127.0.0.1:#{port}/.well-known/hal-c2/environment")

    b_env = :erpc.call(b, HalC2.Environment, :id, [])
    assert %{"cluster" => cluster} = JSON.decode!(to_string(body))
    assert Enum.any?(cluster, &(&1["environmentId"] == b_env))

    client =
      WsClient.send_json(client, %{
        "t" => "sub",
        "id" => 3,
        "shape" => %{"type" => "config", "environment" => b_env}
      })

    {config, _, client} = WsClient.recv_until(client, &(&1["t"] == "config"))

    assert %{"mc" => ^b_name, "config" => %{"environment" => %{"environmentId" => ^b_env}}} =
             config

    :peer.stop(peer)
    {down, _, client} = WsClient.recv_until(client, &(&1["t"] == "shell.mc"), 5_000)
    assert down == %{"t" => "shell.mc", "id" => 1, "mc" => b_name, "online" => false}
    assert Enum.any?(HalC2.Shell.rows(), &match?({{^b, "remote-th"}, _}, &1))

    # Removed from the cluster, it is gone with its rows, for clients too.
    HalC2.Shell.forget(b_env)
    {removed, _, _client} = WsClient.recv_until(client, &(&1["t"] == "shell.mc"), 5_000)
    assert %{"mc" => ^b_name, "online" => false, "removed" => true} = removed
    refute Enum.any?(HalC2.Shell.rows(), &match?({{^b, _}, _}, &1))
    refute List.keymember?(HalC2.Shell.environments(), b, 0)
  end
end
