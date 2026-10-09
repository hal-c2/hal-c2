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
