defmodule HalC2.Web.SocketTest do
  use ExUnit.Case, async: false

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
    %{port: port}
  end

  defp connect(port) do
    {:ok, client} = WsClient.connect(port, "/ws?token=#{HalC2.Web.token()}")
    {%{"t" => "hello", "protocol" => 3}, client} = WsClient.recv(client, 1_000)
    client
  end

  test "rejects connections without the access token", %{port: port} do
    assert {:error, 401} = WsClient.connect(port, "/ws?token=wrong")
  end

  test "shell lists threads and pushes changes", %{port: port} do
    :ok = HalC2.Shell.subscribe(self())

    {:ok, _} =
      HalC2.Streams.commit("th-1", :thread, [
        {"thread", "th-1", %{"s" => %{"id" => "th-1", "title" => "First"}}}
      ])

    assert_receive {:hal_c2_shell, {:rows, _, [{"th-1", _}]}}, 1_000

    client =
      connect(port)
      |> WsClient.send_json(%{"t" => "sub", "id" => 1, "shape" => %{"type" => "shell"}})

    {shell, client} = WsClient.recv(client, 1_000)
    me = Atom.to_string(node())

    assert %{
             "t" => "shell",
             "rows" => [[^me, "th-1", "thread", %{"title" => "First"}]],
             "mcs" => [
               %{"mc" => ^me, "online" => true, "environment" => %{"environmentId" => _}}
             ]
           } = shell

    {:ok, _} =
      HalC2.Streams.commit("th-1", :thread, [
        {"thread", "th-1", %{"s" => %{"title" => "Renamed"}}}
      ])

    assert {%{"t" => "shell.rows", "rows" => [["th-1", "thread", %{"title" => "Renamed"}]]}, _} =
             WsClient.recv(client, 1_000)
  end

  # A socket following the shell, held with `:sys.suspend/1` while `messages` queue up
  # behind each other as they do when it falls behind. Returns every frame it then
  # sends for them.
  defp shell_frames(port, messages) do
    subscribers = fn -> for {pid, _} <- :ets.tab2list(HalC2.Shell.Subscribers), do: pid end
    before = subscribers.()

    client =
      connect(port)
      |> WsClient.send_json(%{"t" => "sub", "id" => 1, "shape" => %{"type" => "shell"}})

    {%{"t" => "shell"}, client} = WsClient.recv(client, 1_000)
    [socket] = subscribers.() -- before

    :ok = :sys.suspend(socket)
    for message <- messages, do: send(socket, {:hal_c2_shell, message})
    :ok = :sys.resume(socket)

    # The ping goes after the first frame, so it lands behind the socket's own flush.
    {first, client} = WsClient.recv(client, 1_000)
    client = WsClient.send_json(client, %{"t" => "ping"})
    {%{"t" => "pong"}, frames, _client} = WsClient.recv_until(client, &(&1["t"] == "pong"))
    [first | frames]
  end

  defp rows(rev, rows, epoch \\ "e1", reset? \\ false),
    do: {:rows, node(), rows, %{epoch: epoch, rev: rev, reset: reset?}}

  defp row(id, title), do: {id, {"thread", %{"title" => title}}}

  test "a burst of row changes is one frame per MC, the latest row winning", %{port: port} do
    frames =
      shell_frames(port, [
        rows(1, [row("th-2", "Second")]),
        rows(2, [row("th-1", "First"), row("th-3", "Third")]),
        rows(3, [row("th-2", "Renamed")])
      ])

    me = Atom.to_string(node())

    assert [
             %{
               "t" => "shell.rows",
               "id" => 1,
               "mc" => ^me,
               "epoch" => "e1",
               "rev" => 3,
               "reset" => false,
               "rows" => [
                 ["th-1", "thread", %{"title" => "First"}],
                 ["th-2", "thread", %{"title" => "Renamed"}],
                 ["th-3", "thread", %{"title" => "Third"}]
               ]
             }
           ] = frames
  end

  test "a reset drops the rows before it, and rows after it keep the frame a reset", %{
    port: port
  } do
    frames =
      shell_frames(port, [
        rows(4, [row("th-1", "Before")]),
        rows(0, [row("th-2", "Whole")], "e2", true),
        rows(1, [row("th-3", "After"), row("th-2", "Changed")], "e2")
      ])

    assert [
             %{
               "t" => "shell.rows",
               "epoch" => "e2",
               "rev" => 1,
               "reset" => true,
               "rows" => [
                 ["th-2", "thread", %{"title" => "Changed"}],
                 ["th-3", "thread", %{"title" => "After"}]
               ]
             }
           ] = frames
  end

  test "a reset with no rows still goes out", %{port: port} do
    assert [%{"t" => "shell.rows", "reset" => true, "rows" => []}] =
             shell_frames(port, [rows(0, [], "e2", true)])
  end

  test "other shell messages do not overtake the rows sent before them", %{port: port} do
    environment = %{"environmentId" => "env-1"}

    frames =
      shell_frames(port, [
        rows(1, [row("th-1", "One")]),
        {:environment, node(), environment},
        rows(2, [row("th-1", "Two")]),
        {:mc, node(), :down},
        rows(3, [row("th-1", "Three")])
      ])

    assert [
             %{"t" => "shell.rows", "rev" => 1, "rows" => [[_, _, %{"title" => "One"}]]},
             %{"t" => "shell.environment", "environment" => ^environment},
             %{"t" => "shell.rows", "rev" => 2, "rows" => [[_, _, %{"title" => "Two"}]]},
             %{"t" => "shell.mc", "online" => false},
             %{"t" => "shell.rows", "rev" => 3, "rows" => [[_, _, %{"title" => "Three"}]]}
           ] = frames
  end

  test "a stream snapshot, then live tokens, then a resume that merges what was missed", %{
    port: port
  } do
    {:ok, _} =
      HalC2.Streams.commit("th-2", :thread, [{"turn-item", "i1", %{"s" => %{"text" => ""}}}])

    me = Atom.to_string(node())
    shape = %{"type" => "stream", "mc" => me, "stream" => "th-2"}
    client = connect(port) |> WsClient.send_json(%{"t" => "sub", "id" => 7, "shape" => shape})

    {%{"t" => "live", "offset" => offset}, [snapshot], client} =
      WsClient.recv_until(client, &(&1["t"] == "live"))

    assert %{
             "t" => "snapshot",
             "part" => 0,
             "done" => true,
             "rows" => [["turn-item", "i1", %{"text" => ""}]]
           } = snapshot

    last =
      Enum.reduce(~w(Hel lo , world), 0, fn tok, _ ->
        {:ok, seq} =
          HalC2.Streams.commit("th-2", :thread, [{"turn-item", "i1", %{"a" => %{"text" => tok}}}])

        seq
      end)

    {frames, _client} = collect_events(client, last, [])

    patches =
      for %{"events" => events} <- frames,
          [_seq, "turn-item", "i1", patch, _at] <- events,
          do: patch

    assert Enum.reduce(patches, %{"text" => ""}, &HalC2.Patch.apply(&2, &1))["text"] ==
             "Hello,world"

    # A new connection resuming from the first offset gets only what it missed, merged.
    resumed =
      connect(port)
      |> WsClient.send_json(%{"t" => "sub", "id" => 1, "shape" => shape, "offset" => offset})

    {%{"t" => "live", "offset" => ^last}, skipped, _} =
      WsClient.recv_until(resumed, &(&1["t"] == "live"))

    assert [
             %{
               "t" => "events",
               "events" => [[^last, "turn-item", "i1", %{"a" => %{"text" => "Hello,world"}}, _at]]
             }
           ] = skipped
  end

  test "a stream named by environment resumes on the MC serving it; an unknown one fails",
       %{port: port} do
    {:ok, first} =
      HalC2.Streams.commit("th-3", :thread, [{"turn-item", "i1", %{"s" => %{"text" => "a"}}}])

    {:ok, next} =
      HalC2.Streams.commit("th-3", :thread, [{"turn-item", "i2", %{"s" => %{"text" => "b"}}}])

    shape = %{"type" => "stream", "environment" => HalC2.Environment.id(), "stream" => "th-3"}

    client =
      connect(port)
      |> WsClient.send_json(%{"t" => "sub", "id" => 1, "shape" => shape, "offset" => first})

    {%{"t" => "live", "offset" => ^next}, [%{"t" => "events", "events" => events}], client} =
      WsClient.recv_until(client, &(&1["t"] == "live"))

    assert [[^next, "turn-item", "i2", _patch, _at]] = events

    missing = %{shape | "environment" => "env-missing"}
    client = WsClient.send_json(client, %{"t" => "sub", "id" => 2, "shape" => missing})

    assert {%{"t" => "error", "id" => 2, "reason" => "unknown environment"}, _} =
             WsClient.recv(client, 1_000)
  end

  test "command output and file diffs stay on the MC", %{port: port} do
    command = %{"id" => "c1", "type" => "command_execution", "output" => "x", "exitCode" => nil}
    change = %{"id" => "f1", "type" => "file_change", "path" => "a.ex", "diffStr" => "@@"}

    {:ok, _} =
      HalC2.Streams.commit("th-3", :thread, [
        {"turn-item", "c1", %{"s" => command}},
        {"turn-item", "f1", %{"s" => change}}
      ])

    shape = %{"type" => "stream", "mc" => Atom.to_string(node()), "stream" => "th-3"}
    client = connect(port) |> WsClient.send_json(%{"t" => "sub", "id" => 1, "shape" => shape})
    {_live, [%{"rows" => rows}], client} = WsClient.recv_until(client, &(&1["t"] == "live"))

    assert [["turn-item", "c1", sent_command], ["turn-item", "f1", sent_change]] = Enum.sort(rows)
    refute Map.has_key?(sent_command, "output")
    assert sent_change == Map.delete(change, "diffStr")

    # Output streamed after the snapshot is trimmed too; only the failure survives.
    {:ok, _} =
      HalC2.Streams.commit("th-3", :thread, [{"turn-item", "c1", %{"a" => %{"output" => "more"}}}])

    {:ok, last} =
      HalC2.Streams.commit("th-3", :thread, [
        {"turn-item", "c1", %{"a" => %{"output" => "boom"}, "s" => %{"exitCode" => 1}}}
      ])

    {frames, _} = collect_events(client, last, [])

    assert [[^last, "turn-item", "c1", patch, _]] =
             Enum.flat_map(frames, & &1["events"])

    assert patch == %{"s" => %{"exitCode" => 1, "outputIndicatesFailure" => true}}
  end

  defp collect_events(client, last, acc) do
    {frame, client} = WsClient.recv(client, 1_000)
    acc = [frame | acc]

    if frame["offset"] == last,
      do: {Enum.reverse(acc), client},
      else: collect_events(client, last, acc)
  end

  test "a terminal shape attaches a shell that RPCs drive; metadata follows it", %{
    port: port,
    tmp_dir: dir
  } do
    start_supervised!({Registry, keys: :unique, name: HalC2.Terminal.Registry})

    start_supervised!(
      {DynamicSupervisor, name: HalC2.Terminal.Supervisor, strategy: :one_for_one}
    )

    start_supervised!(HalC2.Terminal.Hub)
    [{_mc, %{"environmentId" => environment}}] = HalC2.Shell.environments()
    me = Atom.to_string(node())
    input = %{"threadId" => "th-t", "terminalId" => "term-1", "cwd" => dir}

    client =
      connect(port)
      |> WsClient.send_json(%{
        "t" => "sub",
        "id" => 1,
        "shape" => %{"type" => "terminals", "mc" => me}
      })
      |> WsClient.send_json(%{
        "t" => "sub",
        "id" => 2,
        "shape" => %{"type" => "terminal", "mc" => me, "input" => input}
      })

    {%{"t" => "terminals", "id" => 1, "event" => %{"type" => "snapshot", "terminals" => []}},
     client} =
      WsClient.recv(client, 1_000)

    {%{"t" => "terminal", "id" => 2, "event" => %{"type" => "snapshot", "snapshot" => snapshot}},
     _, client} =
      WsClient.recv_until(client, &(&1["t"] == "terminal"))

    assert %{"status" => "running", "threadId" => "th-t"} = snapshot

    client =
      WsClient.send_json(client, %{
        "t" => "rpc",
        "id" => 3,
        "environment" => environment,
        "method" => "terminal.write",
        "payload" => Map.put(input, "data", "echo over-the-wire\n")
      })

    {_, _, client} =
      WsClient.recv_until(client, fn frame ->
        frame["t"] == "terminal" and frame["event"]["type"] == "output" and
          frame["event"]["data"] =~ "over-the-wire"
      end)

    # A contract error comes back with its tag and fields.
    client =
      WsClient.send_json(client, %{
        "t" => "rpc",
        "id" => 4,
        "environment" => environment,
        "method" => "terminal.write",
        "payload" => %{"threadId" => "th-t", "terminalId" => "term-9", "data" => "x"}
      })

    {error, _, _client} = WsClient.recv_until(client, &(&1["t"] == "rpc.error"))

    assert %{
             "id" => 4,
             "detail" => %{"_tag" => "TerminalSessionLookupError", "terminalId" => "term-9"}
           } = error
  end

  test "a request that raises is logged and still answered", %{port: port} do
    [{_mc, %{"environmentId" => environment}}] = HalC2.Shell.environments()
    client = connect(port)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        client =
          WsClient.send_json(client, %{
            "t" => "rpc",
            "id" => 1,
            "environment" => environment,
            "method" => "hal-c2.threadRows",
            # Not a thread id, so reading the thread raises.
            "payload" => %{"threadId" => %{}}
          })

        {error, _, _client} = WsClient.recv_until(client, &(&1["t"] == "rpc.error"))
        assert %{"id" => 1} = error
      end)

    assert log =~ "[error] hal-c2.threadRows failed: "
  end

  test "an MC without a feature fails that subscription, not the socket", %{port: port} do
    # No terminal hub runs here, as on an MC from before terminals.
    client =
      connect(port)
      |> WsClient.send_json(%{
        "t" => "sub",
        "id" => 1,
        "shape" => %{"type" => "terminals", "mc" => Atom.to_string(node())}
      })

    {%{"t" => "error", "id" => 1}, client} = WsClient.recv(client, 1_000)
    client = WsClient.send_json(client, %{"t" => "ping"})
    assert {%{"t" => "pong"}, _} = WsClient.recv(client, 1_000)
  end

  test "config sends usage-limit sources after the snapshot, then on every change", %{
    port: port
  } do
    start_supervised!(HalC2.Settings)

    client =
      connect(port)
      |> WsClient.send_json(%{
        "t" => "sub",
        "id" => 3,
        "shape" => %{"type" => "config", "mc" => Atom.to_string(node())}
      })

    {%{"id" => 3, "sources" => []}, [%{"t" => "config"}, %{"t" => "config.themes"}], client} =
      WsClient.recv_until(client, &(&1["t"] == "config.usageLimitSources"))

    source = %{"id" => "hub", "kind" => "cliproxy", "label" => "Hub", "accounts" => []}
    HalC2.Settings.notify_usage_limit_sources([source])

    assert {%{"t" => "config.usageLimitSources", "id" => 3, "sources" => [^source]}, _} =
             WsClient.recv(client, 1_000)
  end
end
