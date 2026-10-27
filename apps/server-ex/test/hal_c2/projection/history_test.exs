defmodule HalC2.Projection.HistoryTest do
  use ExUnit.Case, async: true

  alias HalC2.Projection.History
  alias HalC2.StreamState

  @thread %{"id" => "thread-1", "title" => "Thread"}

  defp state(entities) do
    entities
    |> Enum.with_index(1)
    |> Enum.reduce(StreamState.new(), fn {{kind, entity}, seq}, state ->
      StreamState.apply_event(state, %{
        seq: seq,
        kind: kind,
        entity: entity["id"],
        patch: %{"s" => entity},
        at: 1_788_256_800_000 + seq * 1000
      })
    end)
  end

  defp run(n, status \\ "completed"),
    do: %{"id" => "run-#{n}", "threadId" => "thread-1", "ordinal" => n, "status" => status}

  defp item(id, run_id, extra \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "threadId" => "thread-1",
        "runId" => run_id,
        "type" => "assistant_message",
        "status" => "completed"
      },
      extra
    )
  end

  # Runs 1..n, each opened by a user turn and holding `per` assistant items.
  defp turns(n, per), do: turns_in(1..n//1, per)

  defp turns_in(range, per) do
    Enum.flat_map(range, fn run_n ->
      [{"run", run(run_n)}] ++
        [
          {"turn-item",
           item("u-#{run_n}", "run-#{run_n}", %{
             "type" => "user_message",
             "inputIntent" => "turn_start",
             "createdBy" => "user"
           })}
        ] ++
        for i <- 1..per//1, do: {"turn-item", item("a-#{run_n}-#{i}", "run-#{run_n}")}
    end)
  end

  defp item_ids(%{rows: rows}),
    do: for(["turn-item", id, _] <- rows, do: id)

  test "a bounded snapshot holds the newest 10 user turns, whole" do
    page = History.bounded(state([{"thread", @thread}] ++ turns(60, 2)))

    ids = item_ids(page)
    assert length(ids) == 30
    assert hd(ids) == "u-51"
    assert List.last(ids) == "a-60-2"
    assert page.has_more == true
    assert is_binary(page.cursor)
  end

  test "the page before a cursor holds the 20 user turns before it, then the rest" do
    state = state([{"thread", @thread}] ++ turns(60, 1))
    assert {:ok, page} = History.page_before(state, History.bounded(state).cursor)
    assert item_ids(page) |> hd() == "u-31"
    assert length(item_ids(page)) == 40

    assert {:ok, page} = History.page_before(state, page.cursor)
    assert item_ids(page) |> hd() == "u-11"

    assert {:ok, page} = History.page_before(state, page.cursor)
    assert item_ids(page) |> hd() == "u-1"
    assert page.has_more == false
    assert page.cursor == nil
  end

  test "a page never splits a turn, and steering does not count as a turn" do
    big =
      [
        {"run", run(1)},
        {"turn-item",
         item("u-1", "run-1", %{
           "type" => "user_message",
           "inputIntent" => "turn_start",
           "createdBy" => "user"
         })}
      ] ++
        for(i <- 1..300, do: {"turn-item", item("tool-#{i}", "run-1", %{"type" => "tool_call"})}) ++
        [
          {"turn-item",
           item("steer-1", "run-1", %{
             "type" => "user_message",
             "inputIntent" => "steer",
             "createdBy" => "user"
           })},
          {"turn-item", item("last", "run-1")}
        ]

    state = state([{"thread", @thread}] ++ big ++ turns(11, 1))
    # The snapshot holds turns 2..11 of the small tail plus... newest 10 user
    # turns overall; paging back from its cursor reaches the huge first turn.
    assert {:ok, page} = page_to_start(state, History.bounded(state).cursor)
    ids = item_ids(page)
    assert "u-1" in ids
    assert "steer-1" in ids
    assert "last" in ids
    assert length(Enum.filter(ids, &String.starts_with?(&1, "tool-"))) == 300
  end

  defp page_to_start(state, cursor) do
    case History.page_before(state, cursor) do
      {:ok, %{has_more: false} = page} -> {:ok, page}
      {:ok, page} -> page_to_start(state, page.cursor)
    end
  end

  test "automatic turns cannot make a page unbounded" do
    automatic =
      Enum.flat_map(1..400, fn n ->
        [
          {"run", run(n)},
          {"turn-item",
           item("auto-#{n}", "run-#{n}", %{
             "type" => "user_message",
             "inputIntent" => "turn_start",
             "createdBy" => "agent"
           })}
        ]
      end)

    state = state([{"thread", @thread}] ++ automatic ++ turns_in(401..401//1, 0))
    page = History.bounded(state)
    # One user turn, then automatic turns back to the raw cap of 150 turns.
    assert length(item_ids(page)) <= 151
    assert page.has_more == true
  end

  test "history with no turn starts is paged by items, with at least one item a page" do
    entities =
      [{"thread", @thread}, {"run", run(1)}] ++
        for(i <- 1..200, do: {"turn-item", item("i-#{i}", "run-1")})

    page = History.bounded(state(entities))
    assert length(item_ids(page)) == 75
    assert hd(item_ids(page)) == "i-126"
    assert page.has_more == true

    huge = String.duplicate("x", 2_000_000)

    entities =
      [{"thread", @thread}, {"run", run(1)}] ++
        for(i <- 1..3, do: {"turn-item", item("big-#{i}", "run-1", %{"text" => huge})})

    page = History.bounded(state(entities))
    assert item_ids(page) == ["big-3"]
    assert page.has_more == true
  end

  test "a cursor the MC cannot use is refused" do
    state = state([{"thread", @thread}])
    assert History.page_before(state, "") == :invalid_cursor
    assert History.page_before(state, "not a cursor") == :invalid_cursor
    assert History.page_before(state, String.duplicate("a", 4_097)) == :invalid_cursor

    foreign =
      %{"v" => 2, "seq" => 0, "st" => "thread-1", "si" => "i-1", "p" => 0}
      |> JSON.encode!()
      |> Base.url_encode64(padding: false)

    assert History.page_before(state, foreign) == :invalid_cursor
  end

  test "a cursor stays valid while the thread grows, and resumes where its item was" do
    base = [{"thread", @thread}] ++ turns(40, 1)
    cursor = History.bounded(state(base)).cursor

    grown = state(base ++ turns_in(41..45//1, 1))
    assert {:ok, page} = History.page_before(grown, cursor)
    assert item_ids(page) |> hd() == "u-11"

    # The item the cursor names is gone (its run rolled back): the page resumes
    # from the position the cursor recorded.
    rolled =
      Enum.map(base, fn
        {"run", %{"id" => "run-31"} = run} -> {"run", %{run | "status" => "rolled_back"}}
        other -> other
      end)

    assert {:ok, page} = History.page_before(state(rolled), cursor)
    ids = item_ids(page)
    refute "u-31" in ids
    assert "u-30" in ids
    assert hd(ids) == "u-11"
  end

  test "a bounded snapshot keeps what the user can still act on, however old" do
    old = [
      {"run", run(900, "queued")},
      {"message",
       %{
         "id" => "queued-msg",
         "threadId" => "thread-1",
         "runId" => "run-900",
         "role" => "user",
         "text" => "later"
       }},
      {"plan",
       %{
         "id" => "plan-1",
         "threadId" => "thread-1",
         "kind" => "proposed_plan",
         "status" => "active",
         "markdown" => "# Plan"
       }},
      {"context-handoff",
       %{
         "id" => "handoff-1",
         "threadId" => "thread-1",
         "status" => "pending",
         "summaryText" => "the summary"
       }},
      {"runtime-request",
       %{
         "id" => "request-1",
         "threadId" => "thread-1",
         "kind" => "approval",
         "status" => "pending"
       }}
    ]

    page = History.bounded(state([{"thread", @thread}] ++ old ++ turns(30, 1)))
    kinds = Map.new(page.rows, fn [kind, id, entity] -> {{kind, id}, entity} end)

    assert kinds[{"message", "queued-msg"}]["text"] == "later"
    assert kinds[{"plan", "plan-1"}]["markdown"] == "# Plan"
    assert kinds[{"context-handoff", "handoff-1"}]["status"] == "pending"
    assert kinds[{"runtime-request", "request-1"}] != nil
  end

  test "finished plans and handoffs in the window carry only their status" do
    entities =
      [{"thread", @thread}] ++
        turns(3, 1) ++
        [
          {"turn-item", item("pp", "run-3", %{"type" => "proposed_plan", "planId" => "plan-1"})},
          {"turn-item",
           item("ho", "run-3", %{"type" => "handoff", "contextHandoffId" => "handoff-1"})},
          {"plan",
           %{
             "id" => "plan-1",
             "threadId" => "thread-1",
             "kind" => "proposed_plan",
             "status" => "completed",
             "markdown" => "# Done"
           }},
          {"context-handoff",
           %{
             "id" => "handoff-1",
             "threadId" => "thread-1",
             "status" => "superseded",
             "summaryText" => "the summary"
           }}
        ]

    page = History.bounded(state(entities))
    kinds = Map.new(page.rows, fn [kind, id, entity] -> {{kind, id}, entity} end)

    assert kinds[{"plan", "plan-1"}]["status"] == "completed"
    assert kinds[{"plan", "plan-1"}]["markdown"] == ""
    assert kinds[{"plan", "plan-1"}]["detailInTurnItem"] == true
    assert kinds[{"context-handoff", "handoff-1"}]["status"] == "superseded"
    assert kinds[{"context-handoff", "handoff-1"}]["summaryText"] == ""
    assert kinds[{"context-handoff", "handoff-1"}]["detailInTurnItem"] == true
  end

  test "a snapshot over its size budget says so and drops nothing actionable" do
    huge = String.duplicate("x", 1_100_000)

    entities =
      [{"thread", @thread}] ++
        turns(3, 1) ++
        [
          {"plan",
           %{
             "id" => "plan-1",
             "threadId" => "thread-1",
             "kind" => "proposed_plan",
             "status" => "active",
             "markdown" => huge
           }}
        ]

    page = History.bounded(state(entities))
    assert page.over_budget == true
    assert Enum.any?(page.rows, &match?(["plan", "plan-1", _], &1))
  end

  test "cursors round-trip, including an upstream-shaped one" do
    cursor = History.encode_cursor(42, "thread-1", "i-9", 7)

    assert {:ok, %{"seq" => 42, "st" => "thread-1", "si" => "i-9", "p" => 7}} =
             History.decode_cursor(cursor)

    upstream =
      ~s({"v":1,"seq":42,"st":"thread-1","si":"i-9","p":7}) |> Base.url_encode64(padding: false)

    assert {:ok, %{"si" => "i-9"}} = History.decode_cursor(upstream)
  end
end
