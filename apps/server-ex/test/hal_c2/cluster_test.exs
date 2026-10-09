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

    # A stream from before relays gives the subscribers it already has one, and sends
    # them their messages under its id as it did.
    subscribers = Map.new(state.subscribers, fn {pid, sub} -> {pid, Map.delete(sub, :name)} end)

    {:ok, %{relays: %{^subscriber => relay}, subscribers: %{^subscriber => %{name: "local-th"}}}} =
      Streams.Server.code_change(1, %{Map.delete(state, :relays) | subscribers: subscribers}, nil)

    send(relay, {:hal_c2_stream, "local-th", :passed_on})
    assert_receive {:hal_c2_stream, "local-th", :passed_on}, 1_000
    Process.exit(relay, :kill)
  end

  test "a client on another MC is sent its view and its pages through its relay, in order",
       %{b: b} do
    alias HalC2.Streams

    run = fn n -> {"run", "run-#{n}", %{"s" => %{"id" => "run-#{n}", "ordinal" => n}}} end

    item = fn n ->
      fields = %{"id" => "item-#{n}", "runId" => "run-#{n}", "ordinal" => n, "text" => ""}
      {"turn-item", "item-#{n}", %{"s" => fields}}
    end

    changes = for n <- 1..2, change <- [run.(n), item.(n)], do: change
    {:ok, seq} = Streams.commit("windowed-th", :thread, changes)

    subscriber = Node.spawn(b, Streams.Relay, :loop, [self()])
    :ok = Streams.subscribe("windowed-th", subscriber, nil, %{window: {:items, 1}})

    assert_receive {:hal_c2_stream, "windowed-th",
                    {:snapshot, ^seq, _at, rows, :done, %{floor: 2, handle: handle}}},
                   1_000

    assert for({"turn-item", id, _} <- rows, do: id) == ["item-2"]
    assert_receive {:hal_c2_stream, "windowed-th", {:live, ^seq, ^handle}}, 1_000

    # A change and then a page, while the connection takes nothing: the page is the
    # stream as of the change, so it must not overtake it.
    %{relays: %{^subscriber => relay}} = :sys.get_state(Streams.ensure("windowed-th"))
    true = :erlang.suspend_process(relay)
    append = [{"turn-item", "item-2", %{"a" => %{"text" => "x"}}}]
    {:ok, next} = Streams.commit("windowed-th", :thread, append)
    :ok = Streams.more("windowed-th", subscriber, 1)
    # The stream has taken both before the relay passes anything on.
    %{subscribers: %{^subscriber => %{view: %{window: %{floor: nil}}}}} =
      :sys.get_state(Streams.ensure("windowed-th"))

    true = :erlang.resume_process(relay)
    assert_receive {:hal_c2_stream, "windowed-th", first}, 1_000
    assert {:events, [%{entity: "item-2"}], ^next} = first
    assert_receive {:hal_c2_stream, "windowed-th", {:page, ^next, page, nil, :done}}, 1_000
    assert for({"turn-item", id, _} <- page, do: id) == ["item-1"]
  end

  # Found by proof/hal_c2/stream_relay_proof_test.exs.
  test "a relay that failed before its subscriber left does not take the stream down",
       %{b: b} do
    alias HalC2.Streams

    {:ok, _} = Streams.commit("left-th", :thread, [{"note", "n1", %{"s" => %{"v" => 1}}}])
    subscriber = Node.spawn(b, Streams.Relay, :loop, [self()])
    :ok = Streams.subscribe("left-th", subscriber, nil)
    assert_receive {:hal_c2_stream, "left-th", {:live, _}}, 1_000
    stream = Streams.ensure("left-th")
    %{relays: %{^subscriber => relay}} = :sys.get_state(stream)

    # The subscriber leaves, and its relay fails before the stream gets to it.
    :ok = :sys.suspend(stream)
    :ok = Streams.unsubscribe("left-th", subscriber)
    ref = Process.monitor(relay)
    Process.exit(relay, :failed)
    assert_receive {:DOWN, ^ref, :process, ^relay, :failed}
    # Taken while suspended: the relay's exit is in the stream's mailbox now.
    %{relays: %{^subscriber => ^relay}} = :sys.get_state(stream)
    :ok = :sys.resume(stream)

    assert %{relays: relays, subscribers: subscribers} = :sys.get_state(stream)
    assert relays == %{} and subscribers == %{}
    assert Streams.ensure("left-th") == stream
  end

  # Found by proof/hal_c2/stream_relay_proof_test.exs.
  test "a client whose relay fails is told to resync, and follows the thread again",
       %{port: port, b: b} do
    {:ok, _} = :erpc.call(b, HalC2.Streams, :commit, ["relayed-th", :thread, [note("n1")]])
    {:ok, client} = WsClient.connect(port, "/ws?token=#{HalC2.Web.token()}")
    {%{"t" => "hello"}, client} = WsClient.recv(client, 1_000)
    shape = %{"type" => "stream", "mc" => Atom.to_string(b), "stream" => "relayed-th"}
    client = WsClient.send_json(client, %{"t" => "sub", "id" => 1, "shape" => shape})
    {%{"t" => "live"}, _, client} = WsClient.recv_until(client, &(&1["t"] == "live"))

    stream = :erpc.call(b, HalC2.Streams, :ensure, ["relayed-th"])
    [relay] = Map.values(:erpc.call(b, :sys, :get_state, [stream]).relays)
    true = :erpc.call(b, Process, :exit, [relay, :failed])
    {resync, _, client} = WsClient.recv_until(client, &(&1["t"] == "resync"))
    assert resync == %{"t" => "resync", "id" => 1}
    assert :erpc.call(b, HalC2.Streams, :ensure, ["relayed-th"]) == stream

    client = WsClient.send_json(client, %{"t" => "sub", "id" => 1, "shape" => shape})
    {%{"t" => "live"}, _, client} = WsClient.recv_until(client, &(&1["t"] == "live"))
    {:ok, seq} = :erpc.call(b, HalC2.Streams, :commit, ["relayed-th", :thread, [note("n2")]])
    {events, _, _client} = WsClient.recv_until(client, &(&1["t"] == "events"))
    assert [[^seq, "note", "n2", _, _at]] = events["events"]
  end

  defp note(id), do: {"note", id, %{"s" => %{"v" => 1}}}

  # Found by proof/hal_c2/stream_relay_proof_test.exs. A suspended socket still takes
  # the messages sent to it.
  test "a client whose follow is answered as the MCs part and meet again is told it failed",
       %{tmp_dir: dir, port: port} do
    {peer, c} = member(dir)
    true = Node.connect(c)
    {:ok, _} = :peer.call(peer, HalC2.Streams, :commit, ["split-th", :thread, [note("n1")]])
    {:ok, client} = WsClient.connect(port, "/ws?token=#{HalC2.Web.token()}")
    {%{"t" => "hello"}, client} = WsClient.recv(client, 1_000)

    # The socket, found by a stream here it follows.
    {:ok, _} = HalC2.Streams.commit("here-th", :thread, [note("n1")])
    here = %{"type" => "stream", "mc" => Atom.to_string(node()), "stream" => "here-th"}
    client = WsClient.send_json(client, %{"t" => "sub", "id" => 1, "shape" => here})
    {%{"t" => "live"}, _, client} = WsClient.recv_until(client, &(&1["t"] == "live"))
    [socket] = Map.keys(:sys.get_state(HalC2.Streams.ensure("here-th")).subscribers)

    # The stream on c holds the follow until the socket waits for its answer.
    stream = :erpc.call(c, HalC2.Streams, :ensure, ["split-th"])
    tracer = Node.spawn(c, HalC2.Test.Forward, :loop, [self()])
    1 = :erpc.call(c, :erlang, :trace, [stream, true, [:receive, {:tracer, tracer}]])
    :ok = :erpc.call(c, :sys, :suspend, [stream])
    shape = %{"type" => "stream", "mc" => Atom.to_string(c), "stream" => "split-th"}
    client = WsClient.send_json(client, %{"t" => "sub", "id" => 2, "shape" => shape})

    assert_receive {:trace, ^stream, :receive,
                    {:"$gen_call", {worker, _}, {:subscribe, ^socket, _, _}}},
                   5_000

    # The answer lands, and the MCs part and meet again, before the socket reads it.
    :erlang.trace(socket, true, [:receive])
    true = :erlang.suspend_process(socket)
    :ok = :erpc.call(c, :sys, :resume, [stream])
    assert_receive {:trace, ^socket, :receive, {:DOWN, _, :process, ^worker, _}}, 5_000
    true = Node.disconnect(c)
    true = Node.connect(c)
    assert :erpc.call(c, :sys, :get_state, [stream]).subscribers == %{}
    true = :erlang.resume_process(socket)
    :erlang.trace(socket, false, [:receive])

    {error, _, client} = WsClient.recv_until(client, &(&1["id"] == 2))
    assert %{"t" => "error", "id" => 2} = error

    client = WsClient.send_json(client, %{"t" => "sub", "id" => 2, "shape" => shape})
    {%{"t" => "live"}, _, client} = WsClient.recv_until(client, &(&1["t"] == "live"))
    {:ok, seq} = :erpc.call(c, HalC2.Streams, :commit, ["split-th", :thread, [note("n2")]])
    {events, _, _client} = WsClient.recv_until(client, &(&1["t"] == "events"))
    assert [[^seq, "note", "n2", _, _at]] = events["events"]
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

  # A member this test can still reach while the two MCs are apart: its control
  # connection is its standard io, not the cluster's.
  defp member(dir) do
    {:ok, peer, c} =
      :peer.start_link(%{
        name: :"hal_c2_peer#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        args: code_path_args() ++ [~c"-setcookie", ~c"#{Node.get_cookie()}"]
      })

    for {key, value} <- [start_mc: true, home: Path.join(dir, "c"), port: 0],
        do: :ok = :peer.call(peer, Application, :put_env, [:hal_c2, key, value])

    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:hal_c2])
    {peer, c}
  end

  defp put_thread(peer, id, title) do
    change = {"thread", id, %{"s" => %{"id" => id, "title" => title}}}
    {:ok, _} = :peer.call(peer, HalC2.Streams, :commit, [id, :thread, [change]])
    # Its row is put now, and the member's shell has taken it once it answers.
    :ok = :peer.call(peer, HalC2.Streams, :flush_shell, [id])
    {_epoch, _rev} = :peer.call(peer, HalC2.Shell, :version, [])
  end

  # The rows of `mc` this MC's clients are told of until `id` is among them, as
  # `{rows, version}` per message.
  defp rows_until(mc, id, acc \\ []) do
    assert_receive {:hal_c2_shell, {:rows, ^mc, rows, version}}, 5_000
    acc = [{rows, version} | acc]
    if List.keymember?(rows, id, 0), do: Enum.reverse(acc), else: rows_until(mc, id, acc)
  end

  test "a member that comes back sends only the rows that changed while it was away",
       %{tmp_dir: dir} do
    {peer, c} = member(dir)
    HalC2.Shell.subscribe(self(), %{})
    true = Node.connect(c)
    put_thread(peer, "th-1", "One")
    put_thread(peer, "th-2", "Two")
    rows_until(c, "th-2")

    true = Node.disconnect(c)
    assert_receive {:hal_c2_shell, {:mc, ^c, :down}}, 5_000
    put_thread(peer, "th-2", "Renamed")
    true = Node.connect(c)

    sent = rows_until(c, "th-2")
    assert Enum.all?(sent, fn {_rows, version} -> version.reset == false end)
    assert [{"th-2", {"thread", %{"title" => "Renamed"}}}] = Enum.flat_map(sent, &elem(&1, 0))
  end

  test "a member whose shell started again sends its rows whole", %{tmp_dir: dir} do
    {peer, c} = member(dir)
    HalC2.Shell.subscribe(self(), %{})
    true = Node.connect(c)
    put_thread(peer, "th-1", "One")
    put_thread(peer, "th-2", "Two")
    [{_, %{epoch: epoch}} | _] = rows_until(c, "th-2")

    shell = :peer.call(peer, Process, :whereis, [HalC2.Shell])
    true = :peer.call(peer, Process, :exit, [shell, :kill])

    # What this MC held of it counted another run's changes: all of it is replaced.
    {rows, version} = List.last(rows_until(c, "th-2"))
    assert version.reset
    assert version.epoch != epoch
    assert for({id, {"thread", _}} <- rows, do: id) |> Enum.sort() == ~w(th-1 th-2)
  end
end
