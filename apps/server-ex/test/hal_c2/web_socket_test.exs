defmodule HalC2.Web.SocketTest do
  use ExUnit.Case, async: false

  alias HalC2.Test.{LateUnsubscribe, WsClient}

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

  # A client changing a thread's window asks for a page, leaves, and follows again,
  # in one packet: the page answers the subscription that asked, so the new one
  # starts with its snapshot and no page, and pages from its own floor when asked.
  test "a more, unsub and sub in one packet do not page the new subscription", %{port: port} do
    run = fn n ->
      {"run", "run-#{n}",
       %{"s" => %{"id" => "run-#{n}", "ordinal" => n, "status" => "completed"}}}
    end

    item = fn n, r ->
      {"turn-item", "item-#{n}",
       %{
         "s" => %{
           "id" => "item-#{n}",
           "ordinal" => n,
           "runId" => "run-#{r}",
           "type" => "assistant_message"
         }
       }}
    end

    changes = for r <- 1..3, change <- [run.(r), item.(r * 2 - 1, r), item.(r * 2, r)], do: change
    {:ok, seq} = HalC2.Streams.commit("th-page", :thread, changes)
    shape = %{"type" => "stream", "mc" => Atom.to_string(node()), "stream" => "th-page"}
    window = %{"items" => 2}

    client =
      connect(port)
      |> WsClient.send_json(%{"t" => "sub", "id" => 1, "shape" => shape, "window" => window})

    {%{"t" => "live", "id" => 1, "offset" => ^seq}, [%{"t" => "snapshot", "floor" => 3}], client} =
      WsClient.recv_until(client, &(&1["t"] == "live"))

    # The stale ask differs from the fresh one below (1 item against 3), so a
    # stale page — item-3 and item-4 under a non-nil floor — cannot pass as
    # the fresh page this test awaits if the bad interleaving happens.
    client =
      WsClient.send_json_many(client, [
        %{"t" => "more", "id" => 1, "items" => 1},
        %{"t" => "unsub", "id" => 1},
        %{"t" => "sub", "id" => 2, "shape" => shape, "window" => window}
      ])

    {%{"t" => "live", "id" => 2, "offset" => ^seq}, before_live, client} =
      WsClient.recv_until(client, &(&1["t"] == "live" and &1["id"] == 2))

    assert [%{"t" => "snapshot", "id" => 2, "floor" => 3}] = before_live

    client = WsClient.send_json(client, %{"t" => "more", "id" => 2, "items" => 3})
    {page, _, _client} = WsClient.recv_until(client, &(&1["t"] == "page"))

    assert %{"id" => 2, "offset" => ^seq, "floor" => nil, "rows" => rows} = page
    assert for(["turn-item", id, _] <- rows, do: id) == ~w(item-1 item-2 item-3 item-4)
  end

  # A page can only answer a `more` sent once live: while a subscription is still
  # replaying what it starts from, a page is the one before it's and is dropped.
  test "a page arriving before live is dropped, and one after it is sent" do
    {:push, _hello, state} = HalC2.Web.Socket.init([])
    tag = {node(), make_ref()}

    state = %{
      state
      | subs: %{2 => {:stream, node(), "th-x"}},
        by_stream: %{"th-x" => {2, tag}},
        buffers: %{2 => %{events: [], bytes: 0, replay: true}}
    }

    page = {:hal_c2_stream, {"th-x", tag}, {:page, 1, [], nil, :done}}
    assert {:ok, ^state} = HalC2.Web.Socket.handle_info(page, state)

    assert {:push, [{:text, live}], state} =
             HalC2.Web.Socket.handle_info(
               {:hal_c2_stream, {"th-x", tag}, {:live, 1, "h"}},
               state
             )

    assert %{"t" => "live", "id" => 2} = live |> IO.iodata_to_binary() |> JSON.decode!()
    assert {:push, [{:text, frame}], _state} = HalC2.Web.Socket.handle_info(page, state)
    assert %{"t" => "page", "id" => 2} = frame |> IO.iodata_to_binary() |> JSON.decode!()
  end

  # The other half of the drop above: no `more` is forwarded while the
  # subscription is replaying, so its floor never moves for a page that
  # would be dropped — but the ask is held and forwarded at `live`, since
  # the client asks once and waits (it does not re-ask on `live`). The
  # stream server here is the test itself, so a forwarded ask lands in
  # this mailbox as its cast.
  test "a more while replaying is held and forwarded on live" do
    {:push, _hello, state} = HalC2.Web.Socket.init([])
    tag = {node(), make_ref()}

    state = %{
      state
      | subs: %{2 => {:stream, node(), "th-x"}},
        by_stream: %{"th-x" => {2, tag}},
        monitors: %{make_ref() => {2, self()}},
        buffers: %{2 => %{events: [], bytes: 0, replay: true}}
    }

    me = self()
    ask = {JSON.encode!(%{"t" => "more", "id" => 2, "items" => 3}), [opcode: :text]}
    assert {:ok, state} = HalC2.Web.Socket.handle_in(ask, state)
    refute_received {:"$gen_cast", {:more, _, _, _}}

    # A snapshot part in between resets the buffer but keeps the held ask.
    assert {:push, _snapshot, state} =
             HalC2.Web.Socket.handle_info(
               {:hal_c2_stream, {"th-x", tag}, {:snapshot, 1, "at", [], :done, %{handle: "h"}}},
               state
             )

    refute_received {:"$gen_cast", {:more, _, _, _}}

    assert {:push, [{:text, live}], state} =
             HalC2.Web.Socket.handle_info(
               {:hal_c2_stream, {"th-x", tag}, {:live, 1, "h"}},
               state
             )

    assert %{"t" => "live", "id" => 2} = live |> IO.iodata_to_binary() |> JSON.decode!()
    assert_received {:"$gen_cast", {:more, ^me, 3, ^tag}}

    # Once live, an ask goes straight out, as before.
    assert {:ok, _} = HalC2.Web.Socket.handle_in(ask, state)
    assert_received {:"$gen_cast", {:more, ^me, 3, ^tag}}
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

  defp start_terminals do
    start_supervised!({Registry, keys: :unique, name: HalC2.Terminal.Registry})

    start_supervised!(
      {DynamicSupervisor, name: HalC2.Terminal.Supervisor, strategy: :one_for_one}
    )

    start_supervised!(HalC2.Terminal.Hub)
  end

  defp terminal_shape(input),
    do: %{"type" => "terminal", "mc" => Atom.to_string(node()), "input" => input}

  defp terminal_snapshot(client, id) do
    {frame, _skipped, client} =
      WsClient.recv_until(
        client,
        &(&1["t"] == "terminal" and &1["id"] == id and &1["event"]["type"] == "snapshot")
      )

    {frame["event"]["snapshot"], client}
  end

  # The terminal output frames sent before the pong answering a ping sent now, as
  # `{id, text}`: the terminal has flushed by then (`await_terminal/1` first), and
  # the socket reads what it was sent before the ping's frame.
  defp terminal_output(client) do
    client = WsClient.send_json(client, %{"t" => "ping"})
    {_pong, frames, client} = WsClient.recv_until(client, &(&1["t"] == "pong"))

    output =
      for %{"t" => "terminal", "id" => id, "event" => %{"type" => "output", "data" => data}} <-
            frames,
          do: {id, data}

    {output, client}
  end

  defp await_terminal(input) do
    [{pid, _}] =
      Registry.lookup(HalC2.Terminal.Registry, {input["threadId"], input["terminalId"]})

    # Answered once the terminal has taken everything sent it so far, its pending
    # output included: ask it to flush, then read its state back.
    send(pid, :output)
    :sys.get_state(pid)
    pid
  end

  defp print_terminal(input, text) do
    pid = await_terminal(input)
    send(pid, {:stdout, :sys.get_state(pid).os_pid, text})
    await_terminal(input)
  end

  # Two pages of one client watching one terminal: both are told its output, and
  # either going leaves the other attached.
  test "two subscriptions to one terminal on a socket both follow it", %{
    port: port,
    tmp_dir: dir
  } do
    start_terminals()
    input = %{"threadId" => "th-twice", "terminalId" => "term-1", "cwd" => dir}

    client =
      connect(port)
      |> WsClient.send_json(%{"t" => "sub", "id" => 1, "shape" => terminal_shape(input)})
      |> WsClient.send_json(%{"t" => "sub", "id" => 2, "shape" => terminal_shape(input)})

    {%{"status" => "running"}, client} = terminal_snapshot(client, 1)
    {%{"status" => "running"}, client} = terminal_snapshot(client, 2)

    print_terminal(input, "for-both\r\n")
    assert {output, client} = terminal_output(client)
    assert Enum.sort(output) == [{1, "for-both\r\n"}, {2, "for-both\r\n"}]

    client = WsClient.send_json(client, %{"t" => "unsub", "id" => 1})
    print_terminal(input, "for-second\r\n")
    assert {output, _client} = terminal_output(client)
    assert output == [{2, "for-second\r\n"}]
  end

  # Output the terminal's timer flushed while the socket waited on the new
  # subscription's attach is in that subscription's snapshot: it is not then sent
  # again under the new id, and what follows still arrives.
  test "output flushed while resubscribing to a terminal is not repeated", %{
    port: port,
    tmp_dir: dir
  } do
    start_terminals()
    input = %{"threadId" => "th-repeat", "terminalId" => "term-1", "cwd" => dir}

    client =
      connect(port)
      |> WsClient.send_json(%{"t" => "sub", "id" => 1, "shape" => terminal_shape(input)})

    {_snapshot, client} = terminal_snapshot(client, 1)
    pid = await_terminal(input)
    os_pid = :sys.get_state(pid).os_pid

    # The output, its flush, the detach and the new attach queue at the terminal
    # in that order, as the timer firing just before the attach lands them.
    :ok = :sys.suspend(HalC2.Terminal.Hub)
    :ok = :sys.suspend(pid)
    send(pid, {:stdout, os_pid, "just-once\r\n"})
    send(pid, :output)

    client =
      WsClient.send_json_many(client, [
        %{"t" => "unsub", "id" => 1},
        %{"t" => "sub", "id" => 2, "shape" => terminal_shape(input)}
      ])

    :ok = WsClient.await_mailbox(pid, 4)
    :ok = :sys.resume(pid)
    :ok = :sys.resume(HalC2.Terminal.Hub)

    {snapshot, client} = terminal_snapshot(client, 2)
    assert snapshot["history"] =~ "just-once\r\n"

    print_terminal(input, "after\r\n")
    assert {output, _client} = terminal_output(client)
    assert output == [{2, "after\r\n"}]
  end

  # A subscription is told only the terminal events after the snapshot it was
  # sent: one at or below its sequence is already in that snapshot.
  test "a terminal event at or below the snapshot's sequence is not sent" do
    {:push, _hello, state} = HalC2.Web.Socket.init([])
    key = {"th-x", "term-1"}

    state = %{
      state
      | subs: %{2 => {:terminal, node(), key}},
        by_terminal: %{key => %{2 => 5}}
    }

    old = {:hal_c2_terminal, key, %{"type" => "output", "data" => "x", "sequence" => 5}}
    assert {:ok, ^state} = HalC2.Web.Socket.handle_info(old, state)

    # An error's message is in no snapshot, so one at the snapshot's sequence
    # (a shell that failed to start while attaching) is still told.
    error = {:hal_c2_terminal, key, %{"type" => "error", "message" => "m", "sequence" => 5}}
    assert {:push, [{:text, frame}], _} = HalC2.Web.Socket.handle_info(error, state)
    assert %{"t" => "terminal", "id" => 2} = frame |> IO.iodata_to_binary() |> JSON.decode!()

    new = {:hal_c2_terminal, key, %{"type" => "output", "data" => "y", "sequence" => 6}}
    assert {:push, [{:text, frame}], state} = HalC2.Web.Socket.handle_info(new, state)
    assert %{"t" => "terminal", "id" => 2} = frame |> IO.iodata_to_binary() |> JSON.decode!()
    assert {:ok, ^state} = HalC2.Web.Socket.handle_info(new, state)

    # A `started` event goes out as a snapshot event whose sequence sits only
    # inside its snapshot; at the floor it is held, above it is told (and the
    # same for a restart, which carries both).
    nested = fn seq ->
      {:hal_c2_terminal, key,
       %{"type" => "snapshot", "snapshot" => %{"sequence" => seq, "history" => "y"}}}
    end

    assert {:ok, ^state} = HalC2.Web.Socket.handle_info(nested.(6), state)

    restarted =
      {:hal_c2_terminal, key,
       %{"type" => "restarted", "sequence" => 6, "snapshot" => %{"sequence" => 6}}}

    assert {:ok, ^state} = HalC2.Web.Socket.handle_info(restarted, state)
    assert {:push, [{:text, frame}], state} = HalC2.Web.Socket.handle_info(nested.(7), state)
    assert %{"t" => "terminal", "id" => 2} = frame |> IO.iodata_to_binary() |> JSON.decode!()

    # A snapshot below the floor is a recreated terminal (its sequence
    # restarted): the subscription restarts from it instead of being
    # starved until the sequence climbs back past the old floor.
    assert {:push, [{:text, frame}], state} = HalC2.Web.Socket.handle_info(nested.(2), state)
    assert %{"t" => "terminal", "id" => 2} = frame |> IO.iodata_to_binary() |> JSON.decode!()

    after_reopen = {:hal_c2_terminal, key, %{"type" => "output", "data" => "z", "sequence" => 3}}

    assert {:push, [{:text, frame}], _state} =
             HalC2.Web.Socket.handle_info(after_reopen, state)

    assert %{"t" => "terminal", "id" => 2} = frame |> IO.iodata_to_binary() |> JSON.decode!()
  end

  # A shell that fails to start while attaching explains itself once per
  # subscription: the error is fanned out under the plain tag only.
  test "a shell that cannot start sends one error frame to its subscription", %{
    port: port,
    tmp_dir: dir
  } do
    start_terminals()
    previous_shell = System.get_env("SHELL")
    System.put_env("SHELL", "/nonexistent/sh")
    Application.put_env(:hal_c2, :terminal_shells, [])

    on_exit(fn ->
      if previous_shell, do: System.put_env("SHELL", previous_shell)
      Application.delete_env(:hal_c2, :terminal_shells)
    end)

    input = %{"threadId" => "th-noshell", "terminalId" => "term-1", "cwd" => dir}

    client =
      connect(port)
      |> WsClient.send_json(%{"t" => "sub", "id" => 1, "shape" => terminal_shape(input)})

    {snapshot, client} = terminal_snapshot(client, 1)
    assert snapshot["status"] == "error"

    client = WsClient.send_json(client, %{"t" => "ping"})
    {_pong, frames, _client} = WsClient.recv_until(client, &(&1["t"] == "pong"))

    errors =
      for %{"t" => "terminal", "id" => 1, "event" => %{"type" => "error"}} <- frames, do: 1

    assert errors == [1]
  end

  # Teardown threads each unsubscribe through the last one's state: of two
  # subscriptions sharing a terminal and two sharing an MC's config, the
  # terminal is detached and the settings watch ended (each exactly once is
  # the end state the other side is left in; the casts have no receipt, so
  # the wait for them is bounded and fails with what it found).
  test "terminate ends a shared terminal attach and a shared config watch", %{tmp_dir: dir} do
    start_terminals()
    start_supervised!(HalC2.Settings)
    input = %{"threadId" => "th-end", "terminalId" => "term-1", "cwd" => dir}
    {:ok, _} = HalC2.Terminal.attach(input, self())
    :ok = HalC2.Settings.watch(self())

    {:push, _hello, state} = HalC2.Web.Socket.init([])
    key = {"th-end", "term-1"}

    state = %{
      state
      | subs: %{
          1 => {:terminal, node(), key},
          2 => {:terminal, node(), key},
          3 => {:config, node()},
          4 => {:config, node()}
        },
        by_terminal: %{key => %{1 => nil, 2 => nil}, {:settings, node()} => [3, 4]}
    }

    assert :ok = HalC2.Web.Socket.terminate(:normal, state)

    [{session, _}] =
      Registry.lookup(HalC2.Terminal.Registry, {"th-end", "term-1"})

    await_true(
      fn ->
        :sys.get_state(session).subscribers == %{} and
          not Map.has_key?(:sys.get_state(HalC2.Settings).watchers, self())
      end,
      fn ->
        "subscribers=#{inspect(:sys.get_state(session).subscribers)} " <>
          "watchers=#{inspect(Map.keys(:sys.get_state(HalC2.Settings).watchers))}"
      end
    )
  end

  # Bounded condition wait for an end state no receipt announces.
  defp await_true(fun, describe, attempts \\ 200) do
    cond do
      fun.() ->
        :ok

      attempts <= 0 ->
        flunk("the awaited end state never arrived: #{describe.()}")

      true ->
        receive do
        after
          5 -> await_true(fun, describe, attempts - 1)
        end
    end
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

  @tag :capture_log
  test "two subscriptions to Slack on one socket each follow it until their own unsub", %{
    port: port
  } do
    :ok = HalC2.Test.FakeSlack.start()
    start_supervised!(HalC2.Slack)
    shape = %{"type" => "slack", "mc" => Atom.to_string(node())}

    client =
      connect(port)
      |> WsClient.send_json(%{"t" => "sub", "id" => 1, "shape" => shape})
      |> WsClient.send_json(%{"t" => "sub", "id" => 2, "shape" => shape})

    {[{1, "off"}, {2, "off"}], client} = slack_frames(client)

    {:ok, _} =
      HalC2.Slack.connect(%{
        "botToken" => HalC2.Test.FakeSlack.bot_token(),
        "appToken" => HalC2.Test.FakeSlack.app_token()
      })

    {frames, client} = slack_frames(client)

    assert Enum.sort(frames) == [
             {1, "connected"},
             {1, "connecting"},
             {2, "connected"},
             {2, "connecting"}
           ]

    # One page going leaves the other watching.
    {[], client} = client |> WsClient.send_json(%{"t" => "unsub", "id" => 1}) |> slack_frames()
    {:ok, _} = HalC2.Slack.disconnect()
    assert {[{2, "off"}], client} = slack_frames(client)

    {[], client} = client |> WsClient.send_json(%{"t" => "unsub", "id" => 2}) |> slack_frames()

    {:error, _} =
      HalC2.Slack.connect(%{"botToken" => "xoxb-revoked", "appToken" => "xapp-revoked"})

    assert {[], _} = slack_frames(client)
  end

  # A page closed and opened again: the unsub's :erpc.cast may reach HalC2.Slack only
  # after the new page's subscribe, and must not stop that one being told.
  @tag :capture_log
  test "a Slack unsubscribe landing after the next subscribe leaves that one watching", %{
    port: port
  } do
    :ok = HalC2.Test.FakeSlack.start()
    start_supervised!(HalC2.Slack)
    gate = LateUnsubscribe.install(HalC2.Slack)
    on_exit(fn -> LateUnsubscribe.uninstall(gate) end)
    shape = %{"type" => "slack", "mc" => Atom.to_string(node())}

    client = connect(port) |> WsClient.send_json(%{"t" => "sub", "id" => 1, "shape" => shape})
    {[{1, "off"}], client} = slack_frames(client)

    LateUnsubscribe.arm(gate)
    {[], client} = client |> WsClient.send_json(%{"t" => "unsub", "id" => 1}) |> slack_frames()
    assert_receive :unsubscribe_held, 5_000

    client = WsClient.send_json(client, %{"t" => "sub", "id" => 2, "shape" => shape})
    {[{2, "off"}], client} = slack_frames(client)

    {:ok, _} =
      HalC2.Slack.connect(%{
        "botToken" => HalC2.Test.FakeSlack.bot_token(),
        "appToken" => HalC2.Test.FakeSlack.app_token()
      })

    assert {[{2, "connecting"}, {2, "connected"}], _} = slack_frames(client)
  end

  # A page closed and opened again while Slack connects: the changes the socket was sent
  # for the closed page, still in its mailbox, are older than the new page's snapshot.
  @tag :capture_log
  test "a Slack status sent before a resubscribe does not follow its snapshot", %{port: port} do
    :ok = HalC2.Test.FakeSlack.start()
    start_supervised!(HalC2.Slack)
    gate = LateUnsubscribe.install(HalC2.Slack)
    on_exit(fn -> LateUnsubscribe.uninstall(gate) end)
    shape = %{"type" => "slack", "mc" => Atom.to_string(node())}

    client = connect(port) |> WsClient.send_json(%{"t" => "sub", "id" => 1, "shape" => shape})
    {[{1, "off"}], client} = slack_frames(client)

    LateUnsubscribe.arm(gate, hold: true)
    {[], client} = client |> WsClient.send_json(%{"t" => "unsub", "id" => 1}) |> slack_frames()
    assert_receive :unsubscribe_held, 5_000

    client = WsClient.send_json(client, %{"t" => "sub", "id" => 2, "shape" => shape})
    assert_receive :subscribe_held, 5_000

    {:ok, _} =
      HalC2.Slack.connect(%{
        "botToken" => HalC2.Test.FakeSlack.bot_token(),
        "appToken" => HalC2.Test.FakeSlack.app_token()
      })

    LateUnsubscribe.release(gate)
    assert {[{2, "connected"}], _} = slack_frames(client)
  end

  # The Slack frames that came before the pong answering a ping sent now, as
  # {id, state}. HalC2.Slack may answer a change before it tells the socket, so the
  # ping waits for it to finish the change first.
  defp slack_frames(client) do
    HalC2.Slack.status()
    client = WsClient.send_json(client, %{"t" => "ping"})
    {_pong, frames, client} = WsClient.recv_until(client, &(&1["t"] == "pong"), 5_000)

    {for(%{"t" => "slack", "id" => id, "status" => status} <- frames, do: {id, status["state"]}),
     client}
  end
end
