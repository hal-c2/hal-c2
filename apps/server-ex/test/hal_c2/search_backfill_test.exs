defmodule HalC2.SearchBackfillTest do
  # The search backfill reads a thread with no hot snapshot through its stream, and
  # leaves that stream as it found it (#1003). Uses the MC-wide named Store and
  # Streams processes.
  use ExUnit.Case, async: false

  alias HalC2.{Search, Store, Streams}
  alias HalC2.Test.Mc

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "hal-c2.sqlite")
    start_supervised!({Store, path: path})
    start_supervised!(Streams)
    %{path: path}
  end

  # A thread an older MC wrote: its log and no snapshot of its hot part.
  defp older_thread(id, text) do
    {:ok, _} =
      Store.append([
        {:thread, id,
         [
           {"thread", id, %{"s" => %{"id" => id, "title" => "t"}}},
           {"message", "#{id}-m",
            %{"s" => %{"id" => "#{id}-m", "role" => "user", "text" => text}}}
         ]}
      ])

    :ok
  end

  defp running?(id) do
    Mc.settle_registry(HalC2.Streams.Registry)
    Registry.lookup(HalC2.Streams.Registry, id) != []
  end

  defp indexed(path),
    do: for({id, _, text, _} <- Store.search_messages(path, "%", 10), do: {id, text})

  test "an idle thread is indexed and its stream is not left running", %{path: path} do
    :ok = older_thread("th-1", "hello there")
    refute Store.hot_snapshot?(path, "th-1")

    :ok = Search.backfill()

    assert indexed(path) == [{"th-1", "hello there"}]
    refute running?("th-1")
    # Its stream wrote the hot snapshot as it loaded, so the next read needs no stream.
    assert Store.hot_snapshot?(path, "th-1")
  end

  test "a stream that was running before the backfill is still running after it", %{path: path} do
    :ok = older_thread("th-1", "hello there")
    pid = Streams.ensure("th-1")

    :ok = Search.backfill()

    assert indexed(path) == [{"th-1", "hello there"}]
    assert Streams.ensure("th-1") == pid
  end

  test "a stream a client subscribed to during the read stays running" do
    :ok = older_thread("th-1", "hello there")

    Streams.read_once("th-1", fn _state ->
      :ok = Streams.subscribe("th-1", self(), nil)
    end)

    assert running?("th-1")
    assert_receive {:hal_c2_stream, "th-1", {:snapshot, _, _, _, :done}}
  end
end
