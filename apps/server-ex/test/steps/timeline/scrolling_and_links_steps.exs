defmodule HalC2.Steps.Timeline.ScrollingAndLinks do
  @moduledoc """
  Steps for the `@node` scenarios of `features/timeline/scrolling-and-links.feature`:
  a client following a thread stream over the WebSocket. The agent's writing is
  committed straight to the thread's stream, as the turn writer does, while the
  node's socket process for the client is held with `:sys.suspend/1` so that a burst
  lands in its mailbox before it can send anything, as it does behind a slow client.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Node, as: TestNode
  alias HalC2.Test.Node.World

  @history 300
  @reply "message:live-reply"

  step "the user is looking at a long thread in {string}", %{args: [project]} = context do
    context =
      if Map.has_key?(context.projects, project),
        do: context,
        else: World.create_project(context, project)

    context =
      context
      |> World.create_thread("Current thread", project)
      |> Map.put(:current, "Current thread")

    id = World.thread_id(context, "Current thread")
    at = HalC2.Orchestration.Entities.now()

    history =
      for n <- 1..@history do
        {"message", "message:history-#{n}",
         %{"s" => message(id, "message:history-#{n}", "Earlier reply #{n}.", at)}}
      end

    {:ok, _} = HalC2.Streams.commit(id, :thread, history)

    {:ok, _} =
      HalC2.Streams.commit(id, :thread, [
        {"message", @reply, %{"s" => message(id, @reply, "", at)}}
      ])

    context
  end

  step "a client is following the thread", context do
    follow(context)
  end

  step "a client is following a thread whose agent streams faster than the client reads",
       context do
    follow(context)
  end

  step "the agent writes more of its reply", context do
    deltas = for n <- 1..20, do: "word#{n} "
    seq = burst(context, deltas)
    Map.merge(context, %{written: Enum.join(deltas), last_seq: seq})
  end

  step "the client receives the new text without asking again", context do
    {frames, client} = frames_until(context.follower, context.sub_id, context.last_seq)
    reply = Enum.reduce(events(frames), context.reply, &apply_event(&2, &1))
    assert reply["text"] == context.written
    Map.merge(context, %{follower: client, received: frames})
  end

  step "a burst of streamed text arrives as one update", context do
    assert [%{"offset" => offset, "events" => [[_seq, "message", @reply, patch, _at]]}] =
             context.received

    assert offset == context.last_seq
    assert patch == %{"a" => %{"text" => context.written}}
    context
  end

  step "the client falls too far behind", context do
    # Nine 1 MB pieces: past the 8 MB a socket holds for one subscription.
    chunk = String.duplicate("x", 1024 * 1024)
    deltas = for n <- 1..9, do: "#{n}:" <> chunk
    seq = burst(context, deltas)
    Map.merge(context, %{written: Enum.join(deltas), last_seq: seq})
  end

  step "the client is told to resync", context do
    {frame, client} =
      TestNode.await(
        context.follower,
        &(&1["id"] == context.sub_id and &1["t"] in ~w(events resync)),
        5_000
      )

    # Nothing of the burst was sent: the client resumes from what it last had.
    assert %{"t" => "resync", "offset" => offset} = frame
    assert offset == context.offset
    Map.put(context, :follower, client)
  end

  step "it receives everything since its last position without gaps", context do
    client =
      sub(context.follower, context.sub_id, context.shape, context.offset)

    {frames, client} = frames_until(client, context.sub_id, context.last_seq, 10_000)

    {live, client} =
      TestNode.await(client, &(&1["id"] == context.sub_id and &1["t"] == "live"), 5_000)

    assert live["offset"] == context.last_seq

    # A replay from the offset, not a fresh snapshot, and it ends at the newest event.
    assert Enum.all?(frames, &(&1["t"] == "events"))
    assert List.last(frames)["offset"] == context.last_seq
    reply = Enum.reduce(events(frames), context.reply, &apply_event(&2, &1))
    assert reply["text"] == context.written
    Map.put(context, :follower, client)
  end

  # --- helpers -----------------------------------------------------------------------

  defp message(thread_id, id, text, at) do
    %{
      "id" => id,
      "threadId" => thread_id,
      "role" => "assistant",
      "text" => text,
      "attachments" => [],
      "createdAt" => at,
      "updatedAt" => at
    }
  end

  defp sub(client, id, shape, offset),
    do:
      HalC2.Test.WsClient.send_json(client, %{
        "t" => "sub",
        "id" => id,
        "shape" => shape,
        "offset" => offset
      })

  # Subscribes a fresh socket to the current thread and reads its snapshot to `live`.
  defp follow(context) do
    id = World.thread_id(context, World.current(context))
    shape = %{"type" => "stream", "node" => Atom.to_string(node()), "stream" => id}
    client = TestNode.connect(context.node) |> sub(1, shape, nil)
    {rows, client} = snapshot(client, 1, [])
    {live, client} = TestNode.await(client, &(&1["id"] == 1 and &1["t"] == "live"), 5_000)

    messages = for ["message", _id, entity] <- rows, do: entity
    assert length(messages) == @history + 1
    reply = Enum.find(messages, &(&1["id"] == @reply))

    Map.merge(context, %{
      follower: client,
      sub_id: 1,
      shape: shape,
      offset: live["offset"],
      reply: reply,
      socket: socket_pid(id)
    })
  end

  defp snapshot(client, id, rows) do
    {frame, client} = TestNode.await(client, &(&1["id"] == id and &1["t"] == "snapshot"), 5_000)
    rows = rows ++ frame["rows"]
    if frame["done"], do: {rows, client}, else: snapshot(client, id, rows)
  end

  # The node's socket process for the follower: the stream's one subscriber that is
  # not this test process.
  defp socket_pid(stream_id) do
    %{subscribers: subscribers} = :sys.get_state(HalC2.Streams.ensure(stream_id))
    assert [pid] = Map.keys(subscribers) -- [self()]
    pid
  end

  # Appends each delta to the reply as its own commit while the socket cannot run, so
  # every commit is waiting in its mailbox when it wakes. Returns the last seq.
  defp burst(context, deltas) do
    id = World.thread_id(context, World.current(context))
    :ok = :sys.suspend(context.socket)

    seq =
      try do
        Enum.reduce(deltas, nil, fn delta, _ ->
          {:ok, seq} =
            HalC2.Streams.commit(id, :thread, [{"message", @reply, %{"a" => %{"text" => delta}}}])

          seq
        end)
      after
        :sys.resume(context.socket)
      end

    seq
  end

  # The `events` frames for subscription `id` up to the one that reaches `seq`.
  defp frames_until(client, id, seq, timeout \\ 5_000, acc \\ []) do
    {frame, client} =
      TestNode.await(client, &(&1["id"] == id and &1["t"] in ~w(events snapshot resync)), timeout)

    acc = acc ++ [frame]

    if frame["t"] == "events" and frame["offset"] < seq,
      do: frames_until(client, id, seq, timeout, acc),
      else: {acc, client}
  end

  defp events(frames), do: Enum.flat_map(frames, &Map.get(&1, "events", []))

  defp apply_event(entity, [_seq, "message", @reply, patch, _at]),
    do: HalC2.Patch.apply(entity, patch)

  defp apply_event(entity, _event), do: entity
end
