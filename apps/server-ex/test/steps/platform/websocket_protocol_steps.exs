defmodule HalC2.Steps.Platform.WebsocketProtocol do
  @moduledoc "Steps for `features/mc/platform/websocket-protocol.feature`."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World
  alias HalC2.Test.WsClient

  # --- greeting and credentials ---------------------------------------------------------

  step "the client opens a socket with a valid credential", context do
    {:ok, client} = WsClient.connect(context.mc.port, "/ws?token=#{HalC2.Web.token()}")
    {hello, client} = WsClient.recv(client, 1_000)
    context |> Map.put(:hello, hello) |> World.put_client(client)
  end

  step "the first frame names protocol 3, the MC it reached and the environment it serves",
       context do
    assert context.hello == %{
             "t" => "hello",
             "protocol" => 3,
             "mc" => Atom.to_string(node()),
             "environment" => context.mc.environment
           }

    context
  end

  step "a client opens a socket without a ticket or token", context do
    Map.put(context, :upgrade, WsClient.connect(context.mc.port, "/ws"))
  end

  step "the upgrade is refused as unauthorized", context do
    assert context.upgrade == {:error, 401}
    context
  end

  step "the client minted a socket ticket", context do
    {:ok, ticket, _expires} = HalC2.Auth.issue_ticket(context.access_token)
    Map.put(context, :ticket, ticket)
  end

  step "it opens a socket with that ticket twice", context do
    path = "/ws?wsTicket=#{context.ticket}"
    first = WsClient.connect(context.mc.port, path)
    Map.put(context, :upgrades, [first, WsClient.connect(context.mc.port, path)])
  end

  step "the first socket opens", context do
    assert [{:ok, client}, _] = context.upgrades
    assert {%{"t" => "hello"}, _} = WsClient.recv(client, 1_000)
    context
  end

  step "the second is refused", context do
    assert [_, {:error, 401}] = context.upgrades
    context
  end

  # --- snapshots, replay and resync -----------------------------------------------------

  step "the client subscribes to a thread from the beginning", context do
    stream = stream_id()
    # Four rows of 100 KB: more than one 256 KB snapshot part.
    big = String.duplicate("x", 100_000)
    changes = for i <- 1..4, do: {"note", "n#{i}", %{"s" => %{"text" => big}}}
    {:ok, seq} = HalC2.Streams.commit(stream, :thread, changes)
    client = World.client(context) |> sub(1, stream)
    context |> Map.merge(%{stream: stream, seq: seq}) |> World.put_client(client)
  end

  step "it receives the thread's snapshot in parts until done", context do
    {parts, client} = snapshot_parts(World.client(context), 1, [])
    assert Enum.map(parts, & &1["part"]) == Enum.to_list(0..(length(parts) - 1))
    assert length(parts) > 1
    assert Enum.all?(parts, &(&1["offset"] == context.seq))
    assert parts |> Enum.flat_map(& &1["rows"]) |> Enum.map(&Enum.at(&1, 1)) == ~w(n1 n2 n3 n4)
    World.put_client(context, client)
  end

  step "then a frame saying the subscription is live", context do
    {frame, client} = WsClient.recv(World.client(context), 1_000)
    assert %{"t" => "live", "id" => 1, "offset" => offset} = frame
    assert offset == context.seq
    World.put_client(context, client)
  end

  step "later changes arrive live as events", context do
    {:ok, seq} = HalC2.Streams.commit(context.stream, :thread, [note("later")])
    {frame, client} = Mc.await(World.client(context), &(&1["t"] == "events"))
    assert [[^seq, "note", _, %{"s" => %{"text" => "later"}}, _]] = frame["events"]
    World.put_client(context, client)
  end

  step "the client saw a thread up to some offset and disconnected", context do
    stream = stream_id()
    {:ok, _} = HalC2.Streams.commit(stream, :thread, [note("first")])
    client = Mc.connect(context.mc) |> sub(1, stream)
    {%{"offset" => offset, "handle" => handle}, client} = Mc.await(client, &(&1["t"] == "live"))
    Mint.HTTP.close(client.conn)
    Map.merge(context, %{stream: stream, offset: offset, handle: handle})
  end

  step "fewer than 2000 events were written since", context do
    {:ok, last} =
      HalC2.Streams.commit(context.stream, :thread, for(i <- 1..5, do: note("missed #{i}")))

    Map.put(context, :missed, Enum.to_list((context.offset + 1)..last))
  end

  step "one note grew by more than 2000 events since", context do
    grown = [
      {"note", "grown", %{"s" => %{"text" => ""}}}
      | for(_ <- 1..2_001, do: {"note", "grown", %{"a" => %{"text" => "x"}}})
    ]

    {:ok, last} = HalC2.Streams.commit(context.stream, :thread, grown)
    Map.put(context, :seq, last)
  end

  step "it receives that note once, whole", context do
    {live, skipped, client} =
      WsClient.recv_until(World.client(context), &(&1["t"] == "live" and &1["id"] == 2), 5_000)

    seq = context.seq
    assert live["offset"] == seq
    events = for %{"t" => "events", "events" => events} <- skipped, event <- events, do: event
    assert [[^seq, "note", "grown", %{"d" => true, "s" => %{"text" => text}}, _at]] = events
    assert byte_size(text) == 2_001
    context |> Map.put(:skipped, skipped) |> World.put_client(client)
  end

  step "no snapshot", context do
    refute Enum.any?(context.skipped, &(&1["t"] == "snapshot"))
    context
  end

  step "more was written since than one frame carries", context do
    # Four notes of 100 KB: more than one 256 KB part.
    big = String.duplicate("x", 100_000)
    changes = for i <- 1..4, do: {"note", "big#{i}", %{"s" => %{"text" => big}}}
    {:ok, last} = HalC2.Streams.commit(context.stream, :thread, changes)
    Map.put(context, :seq, last)
  end

  step "it receives what it missed in several frames of whole entities", context do
    {live, skipped, client} =
      WsClient.recv_until(World.client(context), &(&1["t"] == "live" and &1["id"] == 2), 5_000)

    parts = for %{"t" => "events", "id" => 2} = frame <- skipped, do: frame
    assert length(parts) > 1
    events = Enum.flat_map(parts, & &1["events"])
    assert Enum.map(events, &Enum.at(&1, 2)) == ~w(big1 big2 big3 big4)

    # Whole entities, so a part applied twice (the socket dropped before the last
    # and the client asked again from where it was) leaves the same thread.
    assert Enum.all?(events, &match?([_, _, _, %{"d" => true, "s" => %{}}, _], &1))
    assert live["offset"] == context.seq
    refute Enum.any?(skipped, &(&1["t"] == "snapshot"))
    context |> Map.put(:parts, parts) |> World.put_client(client)
  end

  step "only the last of them moves its offset", context do
    {last, earlier} = List.pop_at(context.parts, -1)
    assert Enum.all?(earlier, &(&1["offset"] == context.offset))
    assert last["offset"] == context.seq
    context
  end

  step "it subscribes again with that offset and the handle it was given", context do
    resume = %{"offset" => context.offset, "handle" => context.handle}
    client = Mc.connect(context.mc) |> sub(2, context.stream, resume)
    World.put_client(context, client)
  end

  step "it subscribes again with that offset and a handle this MC did not give", context do
    resume = %{"offset" => context.offset, "handle" => "another-store.1"}
    client = Mc.connect(context.mc) |> sub(2, context.stream, resume)
    context |> Map.put(:seq, context.offset) |> World.put_client(client)
  end

  step "a thread where the agent is writing a reply", context do
    stream = stream_id()

    reply = fn kind, id, fields ->
      {kind, id, %{"s" => Map.merge(%{"id" => id, "runId" => "r1", "text" => ""}, fields)}}
    end

    {:ok, _} =
      HalC2.Streams.commit(stream, :thread, [
        {"run", "r1", %{"s" => %{"id" => "r1", "ordinal" => 1, "status" => "running"}}},
        reply.("message", "m-user", %{"role" => "user", "text" => "Hi"}),
        reply.("node", "n1", %{}),
        reply.("turn-item", "i1", %{"type" => "assistant_message", "messageId" => "m-agent"}),
        reply.("message", "m-agent", %{"role" => "assistant"})
      ])

    Map.put(context, :stream, stream)
  end

  step "the client subscribes to its turn items and the user's messages", context do
    kinds = %{"run" => %{}, "turn-item" => %{}, "message" => %{"role" => "user"}}
    client = World.client(context) |> sub(1, context.stream, %{}, kinds)
    {parts, client} = snapshot_parts(client, 1, [])
    {_live, client} = Mc.await(client, &(&1["t"] == "live" and &1["id"] == 1))
    context |> Map.put(:rows, Enum.flat_map(parts, & &1["rows"])) |> World.put_client(client)
  end

  step "the snapshot holds the reply's turn item but neither its message nor its node", context do
    assert Enum.map(context.rows, &Enum.take(&1, 2)) == [
             ["run", "r1"],
             ["message", "m-user"],
             ["turn-item", "i1"]
           ]

    context
  end

  step "text added to the reply arrives once, for the turn item", context do
    {:ok, seq} =
      HalC2.Streams.commit(context.stream, :thread, [
        {"turn-item", "i1", %{"a" => %{"text" => "Hello"}}},
        {"message", "m-agent", %{"a" => %{"text" => "Hello"}}}
      ])

    {frame, client} = Mc.await(World.client(context), &(&1["t"] == "events"))
    assert frame["offset"] == seq
    assert [[_seq, "turn-item", "i1", %{"a" => %{"text" => "Hello"}}, _at]] = frame["events"]
    World.put_client(context, client)
  end

  step "it subscribes again from that offset", context do
    client = Mc.connect(context.mc) |> sub(2, context.stream, context.offset)
    World.put_client(context, client)
  end

  step "it receives only the events it missed", context do
    {_live, skipped, client} =
      WsClient.recv_until(World.client(context), &(&1["t"] == "live" and &1["id"] == 2))

    refute Enum.any?(skipped, &(&1["t"] == "snapshot"))
    assert event_seqs(skipped, 2) == context.missed
    World.put_client(context, client)
  end

  step "it receives a fresh snapshot of the thread", context do
    {first, client} = Mc.await(World.client(context), &(&1["id"] == 2))
    assert %{"t" => "snapshot", "part" => 0, "offset" => offset} = first
    assert offset == context.seq

    {%{"offset" => ^offset}, _, client} =
      WsClient.recv_until(client, &(&1["t"] == "live" and &1["id"] == 2), 5_000)

    World.put_client(context, client)
  end

  step "the client subscribed to a busy thread", context do
    follow_thread(context)
  end

  step "more than 8 MB of changes wait unsent for that subscription", context do
    three_mb = String.duplicate("y", 3_000_000)
    :ok = :sys.suspend(context.socket)

    seqs =
      for i <- 1..3 do
        {:ok, seq} =
          HalC2.Streams.commit(context.stream, :thread, [
            {"note", "big#{i}", %{"s" => %{"text" => three_mb}}}
          ])

        seq
      end

    :ok = :sys.resume(context.socket)
    Map.put(context, :missed, seqs)
  end

  step "the MC sends a resync for that subscription", context do
    {frame, client} =
      Mc.await(World.client(context), &(&1["t"] == "resync" and &1["id"] == 1), 10_000)

    assert frame["offset"] == hd(context.missed) - 1
    context |> Map.put(:offset, frame["offset"]) |> World.put_client(client)
  end

  step "the client subscribes again from its last offset", context do
    client = World.client(context) |> sub(2, context.stream, context.offset)

    {_live, skipped, client} =
      WsClient.recv_until(client, &(&1["t"] == "live" and &1["id"] == 2), 10_000)

    assert event_seqs(skipped, 2) == context.missed
    World.put_client(context, client)
  end

  step "the client subscribed to a thread", context do
    follow_thread(context)
  end

  step "one message changes many times before the socket drains", context do
    :ok = :sys.suspend(context.socket)

    seqs =
      for i <- 1..10 do
        {:ok, seq} =
          HalC2.Streams.commit(context.stream, :thread, [
            {"message", "m1", %{"a" => %{"text" => "part#{i} "}}}
          ])

        seq
      end

    :ok = :sys.resume(context.socket)
    Map.put(context, :seq, List.last(seqs))
  end

  step "the client receives the merged change once", context do
    {frame, client} = Mc.await(World.client(context), &(&1["t"] == "events"))
    text = Enum.map_join(1..10, &"part#{&1} ")
    seq = context.seq
    assert [[^seq, "message", "m1", %{"a" => %{"text" => ^text}}, _]] = frame["events"]
    World.put_client(context, client)
  end

  step "it subscribes to the same thread again on that socket", context do
    World.put_client(context, sub(World.client(context), 2, context.stream))
  end

  step "only the second subscription fails as already subscribed", context do
    {frame, client} = Mc.await(World.client(context), &(&1["t"] == "error"))
    assert frame == %{"t" => "error", "id" => 2, "reason" => "already subscribed"}

    {:ok, seq} = HalC2.Streams.commit(context.stream, :thread, [note("still here")])
    {events, client} = Mc.await(client, &(&1["t"] == "events"))
    assert %{"id" => 1, "events" => [[^seq | _]]} = events
    World.put_client(context, client)
  end

  step "the client follows two threads", context do
    [first, second] = for _ <- 1..2, do: stream_id()
    for s <- [first, second], do: {:ok, _} = HalC2.Streams.commit(s, :thread, [note("hi")])
    client = World.client(context) |> sub(1, first) |> sub(2, second)

    {_, client} =
      Mc.await_all(client, [
        &(&1["t"] == "live" and &1["id"] == 1),
        &(&1["t"] == "live" and &1["id"] == 2)
      ])

    context |> Map.put(:streams, [first, second]) |> World.put_client(client)
  end

  step "it drops the first subscription", context do
    client = World.client(context) |> Mc.unsub(1) |> WsClient.send_json(%{"t" => "ping"})
    # A round trip, so the socket has handled the unsub before anything commits.
    {%{"t" => "pong"}, client} = WsClient.recv(client, 1_000)
    World.put_client(context, client)
  end

  step "both threads change", context do
    [first, second] = context.streams
    {:ok, _} = HalC2.Streams.commit(first, :thread, [note("dropped")])
    {:ok, seq} = HalC2.Streams.commit(second, :thread, [note("kept")])
    Map.put(context, :seq, seq)
  end

  step "nothing more arrives for the first thread", context do
    {_, skipped, client} =
      WsClient.recv_until(World.client(context), &(&1["t"] == "events" and &1["id"] == 2))

    assert Enum.filter(skipped, &(&1["id"] == 1)) == []
    context |> Map.put(:second_events, true) |> World.put_client(client)
  end

  step "the second thread keeps streaming", context do
    {:ok, seq} = HalC2.Streams.commit(List.last(context.streams), :thread, [note("more")])

    {frame, _, client} =
      WsClient.recv_until(World.client(context), &(&1["t"] == "events" and &1["id"] == 2))

    assert [[^seq | _]] = frame["events"]
    World.put_client(context, client)
  end

  # --- config, keybindings, shell and scheduled tasks -----------------------------------

  step "two clients follow the MC's config", context do
    Mc.ensure(HalC2.Settings)

    context
    |> World.put_client("first", Mc.connect(context.mc) |> Mc.config())
    |> World.put_client("second", Mc.connect(context.mc) |> Mc.config())
  end

  step "the first client writes settings at the version it read", context do
    {%{"version" => version}, context} = World.call!(context, "hal-c2.readSettings", %{}, "first")
    doc = %{"enableAssistantStreaming" => false}

    {%{"version" => next}, context} =
      World.call!(
        context,
        "hal-c2.writeSettings",
        %{"settings" => doc, "version" => version},
        "first"
      )

    assert next == version + 1
    Map.merge(context, %{settings: doc, version: version})
  end

  step "the second client sees the new settings", context do
    {frame, client} =
      Mc.await(World.client(context, "second"), &(&1["t"] == "config.settings"))

    assert frame["settings"] == context.settings
    World.put_client(context, "second", client)
  end

  step "a write from the second client at the old version is refused as stale", context do
    payload = %{"settings" => %{}, "version" => context.version}
    {reply, context} = World.call(context, "hal-c2.writeSettings", payload, "second")
    assert {:error, "settings changed", %{"_tag" => "StaleSettings"}} = reply
    context
  end

  step "the client follows the MC's config", context do
    Mc.ensure(HalC2.Settings)
    World.put_client(context, Mc.config(World.client(context)))
  end

  step "it adds a keybinding and then removes it", context do
    rule = %{"key" => "mod+j", "command" => "terminal.toggle"}
    {added, context} = keybinding(context, "hal-c2.upsertKeybinding", rule)
    {removed, context} = keybinding(context, "hal-c2.removeKeybinding", rule)
    Map.merge(context, %{rule: rule, changes: [added, removed]})
  end

  step "each change arrives as the complete list of rules", context do
    rule = context.rule

    assert [
             {%{"rules" => [^rule]}, %{"rules" => [^rule]}},
             {%{"rules" => []}, %{"rules" => []}}
           ] = context.changes

    context
  end

  step ~r/^it calls (?<method>server\.(?:upsert|remove)Keybinding)$/,
       %{args: [method]} = context do
    rule = %{"key" => "mod+k", "command" => "terminal.toggle"}

    context =
      if method == "server.removeKeybinding",
        do: context |> keybinding("hal-c2.upsertKeybinding", rule) |> elem(1),
        else: context

    {change, context} = keybinding(context, method, rule)
    expected = if method == "server.removeKeybinding", do: [], else: [rule]
    Map.merge(context, %{change: change, expected: expected})
  end

  step "the MC answers with the complete list of rules", context do
    {result, pushed} = context.change
    assert result["rules"] == context.expected
    assert pushed["rules"] == context.expected
    context
  end

  step "the client follows the shell", context do
    client = World.client(context) |> Mc.sub(1, %{"type" => "shell"})
    {%{"t" => "shell"}, client} = Mc.await(client, &(&1["t"] == "shell"))
    World.put_client(context, client)
  end

  step "it creates a thread, archives it and unarchives it", context do
    thread = "th-#{System.unique_integer([:positive])}"
    row? = fn pred -> &(&1["t"] == "shell.rows" and Enum.any?(&1["rows"], pred)) end

    context =
      command(
        context,
        %{"type" => "thread.create", "threadId" => thread, "title" => "Scenario"},
        row?.(&match?([^thread, "thread", %{"title" => "Scenario"}], &1))
      )

    context =
      command(
        context,
        %{"type" => "thread.archive", "threadId" => thread},
        row?.(&match?([^thread, "thread", %{"archivedAt" => at}] when is_binary(at), &1))
      )

    {%{"threads" => archived}, context} =
      World.call!(context, "orchestration.getArchivedShellSnapshot")

    context =
      command(
        context,
        %{"type" => "thread.unarchive", "threadId" => thread},
        row?.(&match?([^thread, "thread", %{"archivedAt" => nil}], &1))
      )

    {%{"threads" => after_unarchive}, context} =
      World.call!(context, "orchestration.getArchivedShellSnapshot")

    Map.merge(context, %{thread: thread, archived: [archived, after_unarchive]})
  end

  step "the sidebar and the archived list follow each step", context do
    thread = context.thread
    # Each command waited for its sidebar row; the archived list had it only while archived.
    assert [[%{"id" => ^thread}], []] = context.archived
    context
  end

  step "the client follows the MC's scheduled tasks", context do
    Mc.ensure(HalC2.ScheduledTasks)
    shape = %{"type" => "scheduledTasks", "mc" => Atom.to_string(node())}
    client = World.client(context) |> Mc.sub(1, shape)
    {%{"tasks" => []}, client} = Mc.await(client, &(&1["t"] == "scheduledTasks"))
    World.put_client(context, client)
  end

  step "it adds a task, enables it and deletes it", context do
    pushed? = &(&1["t"] == "scheduledTasks" and &1["id"] == 1)

    task = %{
      "title" => "Nightly",
      "prompt" => "summarize the day",
      "enabled" => false,
      "schedule" => %{"type" => "interval", "everyMs" => 3_600_000}
    }

    {[%{"result" => %{"task" => %{"id" => id}}}, added], context} =
      push(context, "scheduledTasks.upsert", task, pushed?)

    {[_, enabled], context} =
      push(context, "scheduledTasks.setEnabled", %{"id" => id, "enabled" => true}, pushed?)

    {[_, deleted], context} = push(context, "scheduledTasks.delete", %{"id" => id}, pushed?)
    Map.merge(context, %{task_id: id, pushes: [added, enabled, deleted]})
  end

  step "every change pushes the complete task list", context do
    id = context.task_id

    assert [
             %{"tasks" => [%{"id" => ^id, "enabled" => false, "nextRunAt" => nil}]},
             %{"tasks" => [%{"id" => ^id, "enabled" => true, "nextRunAt" => next}]},
             %{"tasks" => []}
           ] = context.pushes

    assert is_binary(next)
    context
  end

  # --- errors -----------------------------------------------------------------------------

  step "the client calls several methods the MC does not serve", context do
    methods = ~w(server.commitDesktopUpdate server.getTraceDiagnostics.unknown)
    client = World.client(context)
    env = context.mc.environment

    client =
      Enum.reduce(Enum.with_index(methods, 1), client, fn {method, id}, client ->
        Mc.rpc(client, env, id, method, %{})
      end)

    {replies, client} = Mc.await_all(client, [Mc.reply?(1), Mc.reply?(2)])
    context |> Map.merge(%{methods: methods, replies: replies}) |> World.put_client(client)
  end

  step "each call fails saying the method is not served by this MC yet", context do
    for {method, reply} <- Enum.zip(context.methods, context.replies),
        do:
          assert(
            %{"t" => "rpc.error", "error" => "#{method} is not served by this MC yet"} ==
              Map.take(reply, ["t", "error"])
          )

    context
  end

  step "the socket stays open for other calls", context do
    {result, context} = World.call!(context, "hal-c2.readSettings")
    assert %{"settings" => _, "version" => _} = result
    context
  end

  # "the client sends <frame>" is the common refusal step; it keeps the frame as `context.refusal`.
  step "the MC answers with the error {string}", %{args: [reason]} = context do
    frame = context.refusal
    assert (frame["reason"] || frame["error"]) == reason
    context
  end

  step "a client sends any MC name it likes", context do
    name = "hal_c2_made#{System.unique_integer([:positive])}@nowhere"
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end

    client =
      World.client(context)
      |> Mc.sub(1, %{"type" => "stream", "mc" => name, "stream" => "x"})
      |> Mc.sub(2, %{"type" => "config", "mc" => name})

    # A frame that fails to decode is answered without its id.
    error? = &(&1["t"] == "error")
    {replies, client} = Mc.await_all(client, [error?, error?])

    context |> Map.merge(%{name: name, replies: replies}) |> World.put_client(client)
  end

  step "the MC only accepts names of MCs already in its cluster", context do
    assert Enum.all?(context.replies, &(&1["t"] == "error" and &1["reason"] == "unknown MC"))
    assert_raise ArgumentError, fn -> String.to_existing_atom(context.name) end

    # Its own name is one it knows.
    stream = stream_id()
    {:ok, _} = HalC2.Streams.commit(stream, :thread, [note("hi")])
    client = World.client(context) |> sub(3, stream)
    {_, client} = Mc.await(client, &(&1["t"] == "live" and &1["id"] == 3))
    World.put_client(context, client)
  end

  step "the client sends a ping", context do
    World.put_client(context, WsClient.send_json(World.client(context), %{"t" => "ping"}))
  end

  # --- RPCs --------------------------------------------------------------------------------

  step "the client follows a thread", context do
    follow_thread(context)
  end

  # Scheduled tasks answer from their server, which a suspended process holds up
  # (settings are read from a table and never wait).
  step "it calls an RPC that takes a long time", context do
    tasks = Mc.ensure(HalC2.ScheduledTasks)
    :ok = :sys.suspend(tasks)
    ExUnit.Callbacks.on_exit(fn -> resume(tasks) end)

    client =
      Mc.rpc(World.client(context), context.mc.environment, 99, "scheduledTasks.list", %{})

    context |> Map.put(:tasks_pid, tasks) |> World.put_client(client)
  end

  step "events for the thread keep arriving while the call runs", context do
    {:ok, seq} = HalC2.Streams.commit(context.stream, :thread, [note("while waiting")])

    {frame, skipped, client} =
      WsClient.recv_until(World.client(context), &(&1["t"] == "events" and &1["id"] == 1))

    assert [[^seq | _]] = frame["events"]
    refute Enum.any?(skipped, &(&1["id"] == 99))

    :ok = :sys.resume(context.tasks_pid)
    {reply, client} = Mc.await(client, Mc.reply?(99))
    assert %{"t" => "rpc.result", "result" => %{"tasks" => _}} = reply
    World.put_client(context, client)
  end

  step "a client connected to the first MC calls an RPC for an environment of the second",
       context do
    thread = "th-remote-#{System.unique_integer([:positive])}"
    client = Mc.connect(context.mc)

    {reply, client} =
      Mc.call(client, Mc.peer_environment(context.peer), "orchestration.dispatchCommand", %{
        "type" => "thread.create",
        "commandId" => "cmd-#{thread}",
        "threadId" => thread,
        "title" => "On the second MC"
      })

    context |> Map.merge(%{thread: thread, reply: reply}) |> World.put_client(client)
  end

  step "the second MC runs it", context do
    b = context.peer
    server = :erpc.call(b, HalC2.Streams, :ensure, [context.thread])
    assert node(server) == b

    thread =
      HalC2.StreamState.get(:erpc.call(b, HalC2.Streams.Server, :state, [server]), "thread")

    assert %{"title" => "On the second MC"} = thread[context.thread]
    # Nothing of it ran here.
    assert Registry.lookup(HalC2.Streams.Registry, context.thread) == []
    context
  end

  step "the answer comes back over the client's one socket", context do
    assert {:ok, %{} = _result} = context.reply
    # The same socket still serves this MC.
    {_, context} = World.call!(context, "hal-c2.readSettings")
    context
  end

  step "the client calls an RPC that never finishes", context do
    assert HalC2.Web.Socket.rpc_timeout() == :timer.minutes(10)
    # Ten minutes is the default; the scenario shortens it rather than waiting.
    Application.put_env(:hal_c2, :rpc_timeout, 100)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :rpc_timeout) end)
    tasks = Mc.ensure(HalC2.ScheduledTasks)
    :ok = :sys.suspend(tasks)
    ExUnit.Callbacks.on_exit(fn -> resume(tasks) end)

    client =
      Mc.rpc(World.client(context), context.mc.environment, 7, "scheduledTasks.list", %{})

    context |> Map.put(:tasks_pid, tasks) |> World.put_client(client)
  end

  step "it fails after ten minutes", context do
    {reply, client} = Mc.await(World.client(context), Mc.reply?(7))
    assert %{"t" => "rpc.error", "error" => "scheduledTasks.list timed out"} = reply
    :ok = :sys.resume(context.tasks_pid)
    World.put_client(context, client)
  end

  # --- stream lifetime and upgrades --------------------------------------------------------

  step "nobody follows a thread for five minutes", context do
    stream = stream_id()

    {:ok, seq} =
      HalC2.Streams.commit(stream, :thread, [{"note", "kept", %{"s" => %{"text" => "stored"}}}])

    server = HalC2.Streams.ensure(stream)
    assert :sys.get_state(server).subscribers == %{}
    assert HalC2.Streams.Server.idle_stop() == :timer.minutes(5)
    ref = Process.monitor(server)
    # What the stream's idle timeout delivers once five minutes pass without subscribers.
    send(server, :timeout)
    Map.merge(context, %{stream: stream, seq: seq, server: server, server_ref: ref})
  end

  step "the MC stops its stream process", context do
    %{server: server, server_ref: ref} = context
    assert_receive {:DOWN, ^ref, :process, ^server, :normal}, 2_000
    context
  end

  step "the next subscription starts it again from the store", context do
    client = World.client(context) |> sub(1, context.stream)
    {snapshot, client} = Mc.await(client, &(&1["t"] == "snapshot"))
    assert snapshot["offset"] == context.seq
    assert [["note", "kept", %{"text" => "stored"}]] = snapshot["rows"]
    [{server, _}] = Registry.lookup(HalC2.Streams.Registry, context.stream)
    assert server != context.server
    World.put_client(context, client)
  end

  step "the client follows the shell and a thread", context do
    context = World.create_thread(context, "Hot")
    stream = World.thread_id(context, "Hot")
    client = World.client(context) |> Mc.sub(1, %{"type" => "shell"}) |> sub(2, stream)

    {_, client} =
      Mc.await_all(client, [
        &(&1["t"] == "shell"),
        &(&1["t"] == "live" and &1["id"] == 2)
      ])

    context |> Map.put(:stream, stream) |> World.put_client(client)
  end

  # Shared with upgrades.feature: a real in-place update to a bundle whose only changes
  # are new versions of the socket and stream modules.
  step "the MC loads a new version in place", context do
    if System.get_env("RELEASE_ROOT") == nil, do: Mc.release(context.mc)
    Mc.ensure(HalC2.Upgrade)
    target = "#{HalC2.Upgrade.version()}-hot#{System.unique_integer([:positive])}"
    # Only loaded modules are replaced in place.
    Code.ensure_loaded!(HalC2.Streams.Server)
    modules = [Mc.variant(HalC2.Web.Socket), Mc.variant(HalC2.Streams.Server)]
    archive = Mc.bundle(context.mc, target, %{}, modules)
    :ok = HalC2.Upgrade.Source.put(target, HalC2.Upgrade.platform(), archive)

    assert {:ok, %{"method" => "hot-upgrade", "targetVersion" => ^target}} =
             HalC2.Upgrade.update(%{"targetVersion" => target})

    refute_received {:hal_c2_restart, _}
    assert function_exported?(HalC2.Web.Socket, :__hal_c2_variant__, 0)
    assert function_exported?(HalC2.Streams.Server, :__hal_c2_variant__, 0)
    assert HalC2.Upgrade.version() == target
    Map.put(context, :target, target)
  end

  step "the socket stays connected", context do
    client = WsClient.send_json(World.client(context), %{"t" => "ping"})
    {_, client} = Mc.await(client, &(&1["t"] == "pong"))
    World.put_client(context, client)
  end

  step "its subscriptions keep streaming", context do
    thread = context.stream
    context = World.add_message(context, "Hot", "user", "after the upgrade")

    {[events, _rows], client} =
      Mc.await_all(World.client(context), [
        &(&1["t"] == "events" and &1["id"] == 2),
        &(&1["t"] == "shell.rows" and Enum.any?(&1["rows"], fn row -> hd(row) == thread end))
      ])

    assert Enum.any?(events["events"], &match?([_, "message", _, _, _], &1))
    World.put_client(context, client)
  end

  step "the client followed the shell and two threads", context do
    context = context |> World.create_thread("One") |> World.create_thread("Two")
    streams = for t <- ["One", "Two"], do: World.thread_id(context, t)
    client = Mc.connect(context.mc) |> Mc.sub(1, %{"type" => "shell"})

    client =
      streams |> Enum.with_index(2) |> Enum.reduce(client, fn {s, id}, c -> sub(c, id, s) end)

    {[_shell | lives], client} =
      Mc.await_all(client, [
        &(&1["t"] == "shell"),
        &(&1["t"] == "live" and &1["id"] == 2),
        &(&1["t"] == "live" and &1["id"] == 3)
      ])

    Map.merge(context, %{
      streams: streams,
      offsets: Enum.map(lives, & &1["offset"]),
      dropped: client
    })
  end

  step "its socket drops and it connects again", context do
    Mint.HTTP.close(context.dropped.conn)

    missed =
      for s <- context.streams do
        {:ok, seq} = HalC2.Streams.commit(s, :thread, [note("while away")])
        seq
      end

    Map.put(context, :missed, missed)
    |> World.put_client(Mc.connect(context.mc))
  end

  step "it resubscribes each thread from its last offset", context do
    client =
      context.streams
      |> Enum.zip(context.offsets)
      |> Enum.with_index(2)
      |> Enum.reduce(World.client(context), fn {{s, offset}, id}, c -> sub(c, id, s, offset) end)

    {_, skipped, client} =
      WsClient.recv_until(client, &(&1["t"] == "live" and &1["id"] == 3))

    {client, skipped} =
      if Enum.any?(skipped, &(&1["t"] == "live" and &1["id"] == 2)),
        do: {client, skipped},
        else:
          (fn ->
             {_, more, c} = WsClient.recv_until(client, &(&1["t"] == "live" and &1["id"] == 2))
             {c, skipped ++ more}
           end).()

    refute Enum.any?(skipped, &(&1["t"] == "snapshot"))
    assert [event_seqs(skipped, 2), event_seqs(skipped, 3)] == Enum.map(context.missed, &[&1])
    World.put_client(context, client)
  end

  step "it takes the shell whole", context do
    client = World.client(context) |> Mc.sub(1, %{"type" => "shell"})
    {shell, client} = Mc.await(client, &(&1["t"] == "shell"))
    ids = for [_mc, stream | _] <- shell["rows"], do: stream
    assert Enum.all?(context.streams, &(&1 in ids))
    World.put_client(context, client)
  end

  step "the client followed the shell and kept its rows with their version", context do
    context = context |> World.create_thread("One") |> World.create_thread("Two")
    client = Mc.connect(context.mc) |> Mc.sub(1, %{"type" => "shell"})
    {shell, client} = Mc.await(client, &(&1["t"] == "shell"))
    Mint.HTTP.close(client.conn)

    name = Atom.to_string(node())
    %{"epoch" => epoch, "rev" => rev} = Enum.find(shell["mcs"], &(&1["mc"] == name))
    assert is_binary(epoch) and is_integer(rev)
    Map.merge(context, %{have: %{name => [epoch, rev]}, kept: length(shell["rows"])})
  end

  step "one thread was renamed since", context do
    id = World.thread_id(context, "Two")

    {:ok, _} =
      HalC2.Streams.commit(id, :thread, [{"thread", id, %{"s" => %{"title" => "Renamed"}}}])

    World.await_row(id, &(&1["title"] == "Renamed"))
    Map.put(context, :renamed, id)
  end

  step "it follows the shell again with that version", context do
    client = Mc.connect(context.mc) |> shell_sub(context.have)
    {shell, client} = Mc.await(client, &(&1["t"] == "shell"))
    context |> Map.put(:shell, shell) |> World.put_client(client)
  end

  step "it receives that thread's row and no other", context do
    name = Atom.to_string(node())
    renamed = context.renamed
    assert [[^name, ^renamed, "thread", %{"title" => "Renamed"}]] = context.shell["rows"]

    assert %{"reset" => false, "rev" => rev} =
             Enum.find(context.shell["mcs"], &(&1["mc"] == name))

    assert rev > context.have |> Map.fetch!(name) |> List.last()
    context
  end

  step "it follows the shell again with a version the MC never gave", context do
    have = Map.new(context.have, fn {mc, [_epoch, rev]} -> {mc, ["another-run", rev]} end)
    client = Mc.connect(context.mc) |> shell_sub(have)
    {shell, client} = Mc.await(client, &(&1["t"] == "shell"))
    context |> Map.put(:shell, shell) |> World.put_client(client)
  end

  step "the MC sends every row and says they replace the client's", context do
    name = Atom.to_string(node())
    assert %{"reset" => true} = Enum.find(context.shell["mcs"], &(&1["mc"] == name))
    assert length(context.shell["rows"]) == context.kept
    context
  end

  # --- protocol negotiation and revocation -------------------------------------------------

  step "a client speaking a protocol newer than the MC's", context do
    Map.put(context, :protocol, HalC2.Web.Protocol.version() + 1)
  end

  step "it opens a socket", context do
    path = "/ws?protocol=#{context.protocol}&token=#{HalC2.Web.token()}"

    Map.merge(context, %{
      upgrade: WsClient.connect(context.mc.port, path),
      response: Mc.request(context.mc, :get, path)
    })
  end

  step "the MC refuses with a message naming the MC to update", context do
    assert context.upgrade == {:error, 426}

    assert {426, _headers, %{"code" => "protocol_incompatible", "message" => message}} =
             context.response

    assert message =~ "Update this MC"
    context
  end

  step "a client session has an open socket", context do
    {:ok, %{id: session}} = HalC2.Auth.session(context.access_token)
    Map.put(context, :session, session)
  end

  step "an administrator revokes that session", context do
    assert HalC2.Auth.revoke_client(context.session)
    context
  end

  step "the MC closes the socket", context do
    assert Mc.await_close(World.client(context, "paired")) == {:close, 4401, "session revoked"}
    context
  end

  step "the client cannot reconnect with that session", context do
    assert HalC2.Auth.issue_ticket(context.access_token) == :error

    assert {401, _, _} = Mc.request(context.mc, :get, "/ws?token=#{context.access_token}")

    context
  end

  # --- helpers -----------------------------------------------------------------------------

  defp stream_id, do: "th-ws-#{System.unique_integer([:positive])}"

  defp note(text),
    do: {"note", "n-#{System.unique_integer([:positive])}", %{"s" => %{"text" => text}}}

  # `resume` is the offset to continue from, or the frame's fields saying where
  # (offset, handle, window); `kinds` the entity kinds the client folds.
  defp sub(client, id, stream, resume \\ nil, kinds \\ nil) do
    shape = %{"type" => "stream", "mc" => Atom.to_string(node()), "stream" => stream}
    shape = if kinds, do: Map.put(shape, "kinds", kinds), else: shape
    frame = %{"t" => "sub", "id" => id, "shape" => shape}

    resume =
      case resume do
        nil -> %{}
        offset when is_integer(offset) -> %{"offset" => offset}
        %{} = fields -> fields
      end

    WsClient.send_json(client, Map.merge(frame, resume))
  end

  defp shell_sub(client, have),
    do:
      WsClient.send_json(client, %{
        "t" => "sub",
        "id" => 1,
        "shape" => %{"type" => "shell"},
        "have" => have
      })

  defp snapshot_parts(client, id, parts) do
    {frame, client} = Mc.await(client, &(&1["t"] == "snapshot" and &1["id"] == id))
    parts = [frame | parts]
    if frame["done"], do: {Enum.reverse(parts), client}, else: snapshot_parts(client, id, parts)
  end

  defp event_seqs(frames, id),
    do:
      for(
        %{"t" => "events", "id" => ^id, "events" => events} <- frames,
        [seq | _] <- events,
        do: seq
      )

  # A thread stream with one message, followed on the default socket as id 1; the
  # socket's pid is kept to hold it busy.
  defp follow_thread(context) do
    stream = stream_id()

    {:ok, _} =
      HalC2.Streams.commit(stream, :thread, [
        {"message", "m1",
         %{"s" => %{"id" => "m1", "role" => "assistant", "text" => "", "streaming" => true}}}
      ])

    client = World.client(context) |> sub(1, stream)
    {_, client} = Mc.await(client, &(&1["t"] == "live" and &1["id"] == 1))
    [socket] = Map.keys(:sys.get_state(HalC2.Streams.ensure(stream)).subscribers)
    context |> Map.merge(%{stream: stream, socket: socket}) |> World.put_client(client)
  end

  defp keybinding(context, method, rule) do
    client = Mc.rpc(World.client(context), context.mc.environment, 50, method, rule)

    {[reply, pushed], client} =
      Mc.await_all(client, [Mc.reply?(50), &(&1["t"] == "config.keybindings")])

    assert %{"t" => "rpc.result", "result" => result} = reply
    {{result, pushed}, World.put_client(context, client)}
  end

  defp command(context, command, row?) do
    command = Map.put(command, "commandId", "cmd-#{System.unique_integer([:positive])}")

    client =
      Mc.rpc(
        World.client(context),
        context.mc.environment,
        60,
        "orchestration.dispatchCommand",
        command
      )

    {[reply, _row], client} = Mc.await_all(client, [Mc.reply?(60), row?])
    assert reply["t"] == "rpc.result"
    World.put_client(context, client)
  end

  defp push(context, method, payload, pushed?) do
    client = Mc.rpc(World.client(context), context.mc.environment, 70, method, payload)
    {[reply, pushed], client} = Mc.await_all(client, [Mc.reply?(70), pushed?])
    assert reply["t"] == "rpc.result"
    {[reply, pushed], World.put_client(context, client)}
  end

  defp resume(pid) do
    :sys.resume(pid)
  catch
    _, _ -> :ok
  end
end
