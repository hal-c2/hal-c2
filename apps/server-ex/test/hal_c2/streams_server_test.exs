defmodule HalC2.StreamsServerTest do
  # Regressions found by prop/hal_c2/streams_prop_test.exs. Uses the MC-wide named
  # Store and Streams processes.
  use ExUnit.Case, async: false

  alias HalC2.Streams

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    :ok
  end

  test "committing nothing leaves the stream and its subscribers as they were" do
    {:ok, 1} = Streams.commit("th-1", :thread, [{"note", "n1", %{"s" => %{"v" => 1}}}])
    pid = Streams.ensure("th-1")
    :ok = Streams.subscribe("th-1", self(), 1)
    assert_receive {:hal_c2_stream, "th-1", {:events, []}}
    assert_receive {:hal_c2_stream, "th-1", {:live, 1}}

    assert Streams.commit("th-1", :thread, []) == {:ok, 1}
    assert Streams.ensure("th-1") == pid
    refute_received {:hal_c2_stream, "th-1", {:events, _}}
  end

  test "a client resumes over a patch that sets nothing followed by another to the same entity" do
    {:ok, _} = Streams.commit("th-1", :thread, [{"note", "n0", %{"s" => %{"v" => 0}}}])

    {:ok, last} =
      Streams.commit("th-1", :thread, [
        {"turn-item", "i1", %{"s" => nil}},
        {"turn-item", "i1", %{"s" => %{"text" => "a"}}}
      ])

    :ok = Streams.subscribe("th-1", self(), 1, %{kinds: nil})

    assert_receive {:hal_c2_stream, "th-1",
                    {:events, [%{entity: "i1", patch: %{"s" => %{"text" => "a"}}}], ^last}}

    assert_receive {:hal_c2_stream, "th-1", {:live, ^last, _handle}}
  end

  # The second append is cut from what the first left, not from the text before them.
  test "appends to a subagent in one commit reach a client as the snapshot has them" do
    item = %{"type" => "subagent", "runId" => "r1", "progress" => ""}
    {:ok, _} = Streams.commit("th-1", :thread, [{"turn-item", "i1", %{"s" => item}}])
    :ok = Streams.subscribe("th-1", self(), nil, %{kinds: nil})
    assert_receive {:hal_c2_stream, "th-1", {:live, _, _handle}}
    chunk = String.duplicate("x", 20_000)

    {:ok, last} =
      Streams.commit("th-1", :thread, [
        {"turn-item", "i1", %{"a" => %{"progress" => chunk}}},
        {"turn-item", "i1", %{"a" => %{"progress" => chunk}}}
      ])

    assert_receive {:hal_c2_stream, "th-1", {:events, events, ^last}}
    client = Enum.reduce(events, item, &HalC2.Patch.apply(&2, &1.patch))
    server = HalC2.Patch.apply(item, %{"a" => %{"progress" => chunk <> chunk}})
    assert client == HalC2.Web.Wire.entity("turn-item", server)
  end

  # A client resuming from an offset is sent one merged patch per item, from text it
  # holds cut or whole: what it folds is the snapshot, whether the text went past the
  # limit since or went past it and was reset below.
  test "a client resuming over subagent appends past the limit holds what a snapshot shows" do
    item = %{"type" => "subagent", "runId" => "r1", "progress" => "Reading"}
    {:ok, start} = Streams.commit("th-1", :thread, [{"turn-item", "i1", %{"s" => item}}])
    append = {"turn-item", "i1", %{"a" => %{"progress" => String.duplicate("x", 20_000)}}}
    {:ok, _} = Streams.commit("th-1", :thread, [append])
    {:ok, past} = Streams.commit("th-1", :thread, [append])
    held = wire_item("i1")
    assert resumed(item, start) == held

    reset = {"turn-item", "i1", %{"s" => %{"progress" => "Again"}}}
    {:ok, _} = Streams.commit("th-1", :thread, [reset, append])
    assert resumed(held, past) == wire_item("i1")
    {:ok, _} = Streams.commit("th-1", :thread, [reset, append, append])
    assert resumed(held, past) == wire_item("i1")
  end

  defp resumed(held, offset) do
    :ok = Streams.subscribe("th-1", self(), offset, %{kinds: nil})
    assert_receive {:hal_c2_stream, "th-1", {:events, events, last}}
    assert_receive {:hal_c2_stream, "th-1", {:live, ^last, _handle}}
    :ok = Streams.unsubscribe("th-1", self())
    Enum.reduce(events, held, &HalC2.Patch.apply(&2, &1.patch))
  end

  defp wire_item(id) do
    state = HalC2.Streams.Server.state(Streams.ensure("th-1"))
    HalC2.Web.Wire.entity("turn-item", HalC2.StreamState.get(state, "turn-item")[id])
  end

  # Deciding a command can churn far more than the state it leaves behind. The
  # garbage goes once the work is done, not after 15 quiet seconds no sweep
  # allows. The burst's caller is answered before the release runs (a reply
  # precedes a continue, and a release with work queued collects nothing), so
  # the release's own receipt is the thing to wait on, not a later call.
  test "a stream releases the garbage a burst of work left behind" do
    on_release()
    pid = Streams.ensure("th-1")
    # Answered only after the load's release ran: no receipt of it is in flight.
    _ = HalC2.Streams.Server.sequence(pid)
    flush_releases(pid)

    :ok =
      Streams.transact("th-1", :thread, fn _ ->
        garbage = for i <- 1..200_000, do: {i, "item-#{i}", [i, i, i]}
        _ = length(garbage)
        {[], :ok}
      end)

    assert_receive {:hal_c2_stream_released, ^pid, _heap_words}, 5_000
    assert {:memory, memory} = Process.info(pid, :memory)
    assert memory < 4_000_000, "stream still holds #{memory} bytes after its burst"
  end

  # Demotion drops most of the state's entities to the cold table. The release
  # floor recorded before it must not stand: it is the heap of a state that
  # held them, and the release would wait for another half of it to accrue.
  test "a demoted stream releases what demotion let go" do
    previous = Application.get_env(:hal_c2, :stream_hot_items)
    Application.put_env(:hal_c2, :stream_hot_items, 2)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:hal_c2, :stream_hot_items, previous),
        else: Application.delete_env(:hal_c2, :stream_hot_items)
    end)

    on_release()
    for i <- 1..7, do: run(i)
    # Heap-heavy, so the heap is past the release's slack whatever collection
    # the demoting commit itself happens to do on the way.
    run(8, 15_000)
    pid = Streams.ensure("th-1")
    _ = HalC2.Streams.Server.sequence(pid)
    flush_releases(pid)

    # A floor from before some demotion, and a heap grown well past what the
    # remaining state needs but nowhere near half that floor again.
    :sys.replace_state(pid, fn state ->
      garbage = for i <- 1..200_000, do: {i, "item-#{i}", [i, i, i]}
      _ = length(garbage)
      Map.put(state, :gc_floor, 10_000_000)
    end)

    # This run demotes the one before it out of memory.
    run(9, 15_000)

    assert_receive {:hal_c2_stream_released, ^pid, _heap_words}, 5_000
    assert {:memory, memory} = Process.info(pid, :memory)
    assert memory < 4_000_000, "demoted stream still holds #{memory} bytes"
    state = HalC2.Streams.Server.state(pid)
    assert HalC2.StreamState.get(state, "turn-item")["r8-i1"] == nil
    assert HalC2.StreamState.get(state, "turn-item")["r9-i1"] != nil
  end

  # Sends this test `{:hal_c2_stream_released, server, heap_words}` for every
  # release that collects, until the test ends.
  defp on_release do
    test = self()
    id = {__MODULE__, test, make_ref()}

    :ok =
      :telemetry.attach(
        id,
        [:hal_c2, :streams, :release_memory],
        fn _event, %{heap_words: words}, %{server: server}, _config ->
          send(test, {:hal_c2_stream_released, server, words})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp flush_releases(pid) do
    receive do
      {:hal_c2_stream_released, ^pid, _heap_words} -> flush_releases(pid)
    after
      0 -> :ok
    end
  end

  # One settled run of three turn items, `ordinal` `i` (as in StreamsColdTest).
  # With `heavy`, each item also carries a list of that many integers of its own.
  defp run(i, heavy \\ 0) do
    run = "r#{i}"

    item = fn j ->
      fields = %{"runId" => run, "threadId" => "th-1", "text" => "#{i}.#{j}"}
      fields = if heavy > 0, do: Map.put(fields, "blob", Enum.to_list(1..heavy)), else: fields
      {"turn-item", "#{run}-i#{j}", %{"s" => fields}}
    end

    {:ok, _} =
      Streams.commit("th-1", :thread, [
        {"run", run, %{"s" => %{"id" => run, "ordinal" => i, "status" => "running"}}},
        {"message", "#{run}-m", %{"s" => %{"runId" => run, "text" => "q#{i}"}}}
        | Enum.map(1..3, item)
      ])

    {:ok, _} =
      Streams.commit("th-1", :thread, [{"run", run, %{"s" => %{"status" => "completed"}}}])
  end

  test "a transaction that raises fails its caller and leaves the stream serving" do
    :ok = Streams.subscribe("th-1", self(), nil)
    pid = Streams.ensure("th-1")

    assert_raise RuntimeError, "nope", fn ->
      Streams.transact("th-1", :thread, fn _ -> raise "nope" end)
    end

    assert Streams.ensure("th-1") == pid
    assert Streams.transact("th-1", :thread, fn _ -> {[], :fine} end) == :fine
  end

  test "streams that crash in a burst take no other stream down with them" do
    :ok = Streams.subscribe("th-keep", self(), nil)
    keep = Streams.ensure("th-keep")

    for i <- 1..5 do
      pid = Streams.ensure("th-#{i}")
      ref = Process.monitor(pid)
      Process.exit(pid, :boom)
      assert_receive {:DOWN, ^ref, :process, ^pid, :boom}
    end

    assert Process.alive?(keep)
    assert Streams.ensure("th-keep") == keep
  end

  # A socket's subscription from before an upgrade in place has no tag. Its relay failing
  # dropped it without a word, and the socket followed a stream that sent it nothing.
  test "an untagged client subscription whose relay fails is told to resync" do
    {:ok, _} = Streams.commit("th-1", :thread, [{"note", "n1", %{"s" => %{"v" => 1}}}])
    stream = Streams.ensure("th-1")
    :ok = Streams.subscribe("th-1", self(), nil, %{kinds: nil})
    assert_receive {:hal_c2_stream, "th-1", {:live, _, _}}

    # What a subscriber on another MC has: a relay, linked to the stream.
    test = self()

    :sys.replace_state(stream, fn state ->
      relay = spawn_link(fn -> receive do: (:never -> :ok) end)
      put_in(state.relays[test], relay)
    end)

    relay = :sys.get_state(stream).relays[test]
    Process.exit(relay, :failed)

    assert_receive {:hal_c2_stream, "th-1", :resync}
    assert Streams.ensure("th-1") == stream
  end
end
