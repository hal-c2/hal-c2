defmodule HalC2.SearchBackfillTest do
  # Uses the MC-wide named Store and Streams.
  use ExUnit.Case, async: false

  alias HalC2.{Search, Store}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    start_supervised!({Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    :ok
  end

  defp thread(id) do
    {:ok, _} = Store.append([{:thread, id, [{"thread", id, %{"s" => %{"id" => id}}}]}])
  end

  defp open?(id), do: Registry.lookup(HalC2.Streams.Registry, id) != []

  # A stream opened on a thread its import has not finished would keep the part
  # stored so far: the import writes the rest to the store, past the open stream.
  test "the boot backfill leaves a thread an import has not finished unopened" do
    thread("th-done")
    thread("th-importing")
    :ok = Store.put_meta("import.thread.th-importing", "events:project-1")
    :ok = Search.read_again()

    :ok = Search.backfill()

    assert open?("th-done")
    refute open?("th-importing")
  end
end
