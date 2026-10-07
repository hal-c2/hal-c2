defmodule HalC2.StoreTest do
  use ExUnit.Case, async: false

  alias HalC2.Store

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "hal-c2.sqlite")
    start_supervised!({Store, path: path})
    %{path: path}
  end

  defp change(id), do: {"thread", id, %{"s" => %{"id" => id}}}

  test "an append that writes nothing reports the end of the log" do
    assert {:ok, 0} = Store.append([])
    {:ok, last} = Store.append([{:thread, "t1", [change("t1"), change("t1")]}])

    assert {:ok, ^last} = Store.append([])
    assert {:ok, ^last} = Store.append([{:thread, "t2", []}])
  end

  test "the time of an append is only given with its store" do
    assert {:ok, 1} = Store.append(Store, [{:thread, "t1", [change("t1")]}], 1_700_000_000_000)

    # Taking the batches for the store would exit in GenServer.whereis.
    assert_raise FunctionClauseError, fn ->
      apply(Store, :append, [[{:thread, "t1", [change("t1")]}], 1_700_000_000_000])
    end
  end

  test "derived rows do not create a stream, whose kind only an append knows", %{path: path} do
    assert {:error, :unknown_stream} = Store.put_snapshot("p1", 0, %{})
    assert {:error, :unknown_stream} = Store.put_shell("p1", 0, {"project", %{}})
    Store.index_messages("p1", [{"m1", "user", "hello", "2026-01-01T00:00:00Z"}])
    _ = :sys.get_state(Store)

    assert Store.list_streams(path) == []
    assert Store.search_messages(path, "%hello%", 10) == []

    {:ok, _} = Store.append([{:project, "p1", [{"project", "p1", %{"s" => %{"id" => "p1"}}}]}])
    assert [%{id: "p1", kind: "project"}] = Store.list_streams(path)
  end

  test "an append that fails leaves no events and no stream", %{path: path} do
    {:ok, 1} = Store.append([{:thread, "t1", [change("t1")]}])

    assert {:error, _} =
             Store.append([
               {:thread, "t2", [change("t2")]},
               {:thread, "t3", [{"thread", "t3", {:not_json}}]}
             ])

    assert [%{id: "t1"}] = Store.list_streams(path)
    assert {:ok, 2} = Store.append([{:thread, "t2", [change("t2")]}])
  end

  test "a batch of messages is indexed whole or not at all", %{path: path} do
    {:ok, _} = Store.append([{:thread, "t1", [change("t1")]}])
    messages = [{"m1", "user", "one", "a"}, {"m2", "user", "two", "b"}]

    Store.index_messages("t1", messages)
    assert [{"t1", "user", "one", "a"}] = Store.search_messages(path, "%one%", 10)

    # The second row cannot be stored, so the first must not stay either.
    Store.index_messages("t1", [{"m3", "user", "three", "c"}, {"m4", "user", nil, "d"}])
    _ = :sys.get_state(Store)

    assert Store.search_messages(path, "%three%", 10) == []
    assert Store.search_messages(path, "%two%", 10) == [{"t1", "user", "two", "b"}]
  end
end
