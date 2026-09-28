defmodule HalC2.Links.RowsTest do
  use ExUnit.Case, async: true

  alias HalC2.Links.Rows

  @env %{"environmentId" => "env-beast", "label" => "beast"}

  defp snapshot(rows, online \\ true) do
    %{
      "t" => "shell",
      "nodes" => [%{"node" => "beast@host", "online" => online, "environment" => @env}],
      "rows" => rows,
      "links" => []
    }
  end

  defp thread(title), do: ["beast@host", "th-1", "thread", %{"id" => "th-1", "title" => title}]

  test "the first snapshot introduces the nodes and then their rows" do
    {rows, changes} = Rows.apply(Rows.new(), snapshot([thread("One")]))

    assert changes == [
             {:environment, "beast@host", @env},
             {:node, "beast@host", true},
             {:rows, "beast@host", [{"th-1", {"thread", %{"id" => "th-1", "title" => "One"}}}]}
           ]

    assert Rows.listing(rows) == %{
             "nodes" => [%{"node" => "beast@host", "online" => true, "environment" => @env}],
             "rows" => [thread("One")]
           }
  end

  test "a snapshot after a reconnect yields only what differs" do
    {rows, _} = Rows.apply(Rows.new(), snapshot([thread("One")]))
    {rows, _} = Rows.offline(rows)

    other = ["beast@host", "th-2", "thread", %{"id" => "th-2"}]
    {_rows, changes} = Rows.apply(rows, snapshot([thread("One"), other]))

    assert changes == [
             {:node, "beast@host", true},
             {:rows, "beast@host", [{"th-2", {"thread", %{"id" => "th-2"}}}]}
           ]
  end

  test "a row change is passed on once, and an unchanged one not at all" do
    {rows, _} = Rows.apply(Rows.new(), snapshot([thread("One")]))
    [_node, id, kind, row] = thread("Two")
    frame = %{"t" => "shell.rows", "node" => "beast@host", "rows" => [[id, kind, row]]}

    {rows, changes} = Rows.apply(rows, frame)
    assert changes == [{:rows, "beast@host", [{id, {kind, row}}]}]
    assert {_, []} = Rows.apply(rows, frame)
  end

  test "a dropped link leaves the rows and marks each online node offline once" do
    {rows, _} = Rows.apply(Rows.new(), snapshot([thread("One")]))
    {rows, changes} = Rows.offline(rows)

    assert changes == [{:node, "beast@host", false}]
    assert {_, []} = Rows.offline(rows)
    assert Rows.listing(rows)["rows"] == [thread("One")]
  end

  test "a node is listed once its environment is known; the linked environment's links are not" do
    {rows, changes} =
      Rows.apply(Rows.new(), %{"t" => "shell.node", "node" => "other@host", "online" => true})

    assert changes == [{:node, "other@host", true}]
    assert Rows.listing(rows)["nodes"] == []
    assert {_, []} = Rows.apply(rows, %{"t" => "shell.links", "links" => [%{}]})
  end
end
