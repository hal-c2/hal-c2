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
    message = %{"s" => %{"id" => "m-#{id}", "role" => "user", "text" => "said in #{id}"}}

    {:ok, _} =
      Store.append([
        {:thread, id, [{"thread", id, %{"s" => %{"id" => id}}}, {"message", "m-#{id}", message}]}
      ])
  end

  defp indexed?(id), do: Store.search_messages(Store.path(), "%said in #{id}%", 10) != []

  defp open?(id), do: Registry.lookup(HalC2.Streams.Registry, id) != []

  # Entities come back from JSON, so a typed message can carry explicit nulls
  # (`:null`) for the fields that would make it not typed. It still indexes as
  # typed, and a store read under the old mark (`messages_typed`) is read again.
  test "a typed message with stored nulls indexes as typed, and the old mark re-reads" do
    # As `:json.decode` gives a stored entity: explicit nulls are `:null`.
    message =
      :json.decode("""
      {"id": "m-th-null", "role": "user", "text": "said with nulls",
       "createdAt": "2026-11-01", "senderThreadId": null,
       "scheduledTaskId": null, "notification": null}
      """)

    state =
      Enum.reduce(
        [{"thread", %{"id" => "th-null"}}, {"message", message}],
        HalC2.StreamState.new(),
        fn {kind, entity}, state ->
          HalC2.StreamState.apply_event(state, %{
            seq: 1,
            kind: kind,
            entity: entity["id"],
            patch: %{"s" => entity},
            at: 1_788_256_800_000
          })
        end
      )

    {:ok, _} =
      Store.append([
        {:thread, "th-null", [{"thread", "th-null", %{"s" => %{"id" => "th-null"}}}]}
      ])

    :ok = Search.index_thread("th-null", state)
    _ = :sys.get_state(Store)

    assert [{"th-null", "2026-11-01", 1}] = Store.typed_messages_since(Store.path(), "2000-01-01")

    :ok = Store.put_meta("messages_typed", "1")
    refute Search.read?()
  end

  # A stream opened on a thread its import has not finished would keep the part
  # stored so far: the import writes the rest to the store, past the open stream.
  # Neither is opened: a boot reads idle threads from disk.
  test "the boot backfill leaves a thread an import has not finished to the import" do
    thread("th-done")
    thread("th-importing")
    :ok = Store.put_meta("import.thread.th-importing", "events:project-1")
    :ok = Search.read_again()

    :ok = Search.backfill()

    assert indexed?("th-done")
    refute indexed?("th-importing")
    refute open?("th-done")
    refute open?("th-importing")
  end
end
