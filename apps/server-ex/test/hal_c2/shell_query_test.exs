defmodule HalC2.ShellQueryTest do
  # Uses the MC-wide named Store and Shell processes.
  use ExUnit.Case, async: false

  alias HalC2.{Shell, Store}

  @moduletag :tmp_dir

  defmodule QuietWire do
    @moduledoc false
    def connected, do: []
    def cast(_peer, _message), do: :ok
  end

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :shell_transport, QuietWire)
    on_exit(fn -> Application.delete_env(:hal_c2, :shell_transport) end)
    start_supervised!({Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(Shell)

    Shell.put_row(
      "q-run",
      {"thread", %{"id" => "q-run", "activeRunId" => "run-1", "lastErrorClass" => "usage_limit"}}
    )

    Shell.put_row(
      "q-idle",
      {"thread", %{"id" => "q-idle", "activeRunId" => nil, "lastErrorClass" => "other"}}
    )

    Shell.put_row("q-bare", {"thread", %{"id" => "q-bare", "lineage" => %{}}})

    Shell.put_row("q-sub", {
      "thread",
      %{
        "id" => "q-sub",
        "lineage" => %{"parentThreadId" => "q-run", "relationshipToParent" => "subagent"}
      }
    })

    Shell.put_row("q-proj", {"project", %{"id" => "q-proj", "title" => "Q"}})
    :ok = Shell.sync()
    :ok
  end

  defp sorted(rows), do: Enum.sort(rows)

  test "query/1 agrees with filtering rows/0" do
    rows = Shell.rows()
    assert length(rows) >= 4

    filtered = fn fun -> rows |> Enum.filter(fun) |> sorted() end

    assert sorted(Shell.query([])) == sorted(rows)

    assert sorted(Shell.query(mc: :local, kind: "thread")) ==
             filtered.(fn {{mc, _}, {kind, _}} -> mc == node() and kind == "thread" end)

    assert sorted(Shell.query(kind: "project")) ==
             filtered.(fn {_, {kind, _}} -> kind == "project" end)

    assert sorted(Shell.query(mc: node(), kind: "thread", present: "activeRunId")) ==
             filtered.(fn
               {{mc, _}, {"thread", row}} -> mc == node() and row["activeRunId"] != nil
               _ -> false
             end)

    assert sorted(Shell.query(where: %{"lastErrorClass" => "usage_limit"})) ==
             filtered.(fn
               {_, {_, row}} -> row["lastErrorClass"] == "usage_limit"
             end)

    assert sorted(
             Shell.query(
               mc: :local,
               kind: "thread",
               where: %{"lastErrorClass" => "usage_limit"},
               present: ["activeRunId"]
             )
           ) ==
             filtered.(fn
               {{mc, _}, {"thread", row}} ->
                 mc == node() and row["lastErrorClass"] == "usage_limit" and
                   row["activeRunId"] != nil

               _ ->
                 false
             end)

    assert sorted(Shell.query(id: "q-run")) ==
             filtered.(fn {{_mc, id}, _} -> id == "q-run" end)

    assert length(Shell.query(kind: "thread", limit: 1)) == 1
    assert Shell.query(mc: :"nobody@nowhere.invalid") == []
    assert Shell.query(mc: :"nobody@nowhere.invalid", limit: 1) == []
  end

  defp ids(rows), do: rows |> Enum.map(fn {{_mc, id}, _} -> id end) |> Enum.sort()

  test "where matches a map value exactly, not a map that extends it" do
    assert ids(Shell.query(where: %{"lineage" => %{}})) == ["q-bare"]

    lineage = %{"parentThreadId" => "q-run", "relationshipToParent" => "subagent"}
    assert ids(Shell.query(where: %{"lineage" => lineage})) == ["q-sub"]
    assert Shell.query(where: %{"lineage" => %{"parentThreadId" => "q-run"}}) == []
  end

  test "a field in both where and present must satisfy both" do
    assert ids(
             Shell.query(where: %{"lastErrorClass" => "usage_limit"}, present: "lastErrorClass")
           ) == ["q-run"]

    assert ids(Shell.query(where: %{"activeRunId" => nil})) == ["q-idle"]
    assert Shell.query(where: %{"activeRunId" => nil}, present: "activeRunId") == []
  end

  test "duplicate present fields query as one" do
    assert sorted(Shell.query(present: ["activeRunId", "activeRunId"])) ==
             sorted(Shell.query(present: "activeRunId"))

    assert ids(Shell.query(present: ["activeRunId", "activeRunId"])) == ["q-run"]
  end

  test "a query naming more fields than it has match variables is refused" do
    assert_raise ArgumentError, ~r/at most 32/, fn ->
      Shell.query(present: Enum.map(1..33, &"field#{&1}"))
    end
  end
end
