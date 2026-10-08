defmodule HalC2.ShellProjectionPropTest do
  @moduledoc """
  A thread's sidebar row (`HalC2.Projection.row/3`) does not depend on how its log was
  folded: all at once in memory, from a snapshot taken partway and the events after it,
  or from the store, which keeps the patches as JSON and the row as JSON. The last is
  what this MC reads after a restart, so a difference is a row that changes when the
  shell starts again.

  The events are patches to the entities the row is built from, with values drawn from
  the shapes the Node server writes: ISO dates, run and item statuses, nulls.
  """

  use ExUnit.Case, async: false
  use PropCheck

  alias HalC2.{Projection, Store, StreamState}

  @moduletag timeout: :infinity

  @thread "t1"
  @t0 1_790_000_000_000

  property "a thread's row is the same however its events are folded",
    numtests: HalC2.Prop.numtests(100) do
    forall {events, split, batches} <- log() do
      HalC2.Prop.scratch_home("shell-projection")
      HalC2.Prop.start_services([{Store, path: Store.home_path()}])
      path = Store.path()

      try do
        in_memory = fold(StreamState.new(), events, 1)
        whole = Projection.row(path, @thread, in_memory)

        {first, rest} = Enum.split(events, split)

        resumed =
          StreamState.new()
          |> fold(first, 1)
          |> :erlang.term_to_binary()
          |> :erlang.binary_to_term()
          |> fold(rest, split + 1)

        {stored_first, stored_rest} = Enum.split(events, split)
        append(stored_first, batches)

        if stored_first != [] do
          state = StreamState.load(path, @thread)
          :ok = Store.put_snapshot(@thread, state.seq, state)
        end

        append(stored_rest, batches)
        loaded = StreamState.load(path, @thread)
        rebuilt = Projection.rebuild(@thread)

        persisted =
          for {@thread, kind, row} <- Store.list_shell(path), do: {kind, row}

        results = %{
          whole: whole,
          resumed: Projection.row(path, @thread, resumed),
          loaded: Projection.row(path, @thread, loaded),
          rebuilt: rebuilt,
          persisted: List.first(persisted)
        }

        (Enum.all?(Map.values(results), &(&1 == whole)) and
           (whole == nil or persisted == [whole]))
        |> when_fail(
          IO.puts("""
          events: #{inspect(events, pretty: true, limit: :infinity)}
          split: #{split}
          results: #{inspect(results, pretty: true, limit: :infinity)}
          """)
        )
        |> collect(if whole, do: :row, else: :no_row)
      after
        HalC2.Prop.stop_services()
      end
    end
  end

  defp fold(state, events, seq) do
    events
    |> Enum.with_index(seq)
    |> Enum.reduce(state, fn {{kind, id, patch, at}, seq}, state ->
      StreamState.apply_event(state, %{seq: seq, kind: kind, entity: id, patch: patch, at: at})
    end)
  end

  # Appends `changes` a few at a time, as stream servers commit them.
  defp append([], _size), do: :ok

  defp append(changes, size) do
    {batch, rest} = Enum.split(changes, size)
    {:ok, _} = Store.append([{:thread, @thread, batch}])
    append(rest, size)
  end

  # --- generators -------------------------------------------------------------

  # The thread is created first, as every thread's log starts; the events after it
  # touch every entity the row reads.
  defp log do
    let {created, events, split, batches} <-
          {thread_fields(), resize(20, list(event())), integer(0, 21), integer(1, 4)} do
      events =
        [{"thread", @thread, %{"s" => Map.put(created, "id", @thread)}} | events]
        |> Enum.with_index()
        |> Enum.map(fn {{kind, id, patch}, i} -> {kind, id, patch, @t0 + i * 1_000} end)

      {events, min(split, length(events)), batches}
    end
  end

  defp event do
    frequency([
      {3, entity_event("thread", [@thread], thread_fields())},
      {3, entity_event("run", ~w(r1 r2), run_fields())},
      {1, entity_event("run-attempt", ~w(a1 a2), attempt_fields())},
      {4, entity_event("turn-item", ~w(i1 i2 i3), item_fields())},
      {2, entity_event("message", ~w(m1 m2), message_fields())},
      {1, entity_event("runtime-request", ~w(q1 q2), request_fields())},
      {1, entity_event("provider-session", ~w(ps1), session_fields())},
      {1, entity_event("provider-thread", ~w(pt1 pt2), provider_thread_fields())},
      {1, entity_event("plan", ~w(pl1), plan_fields())}
    ])
  end

  defp entity_event(kind, ids, fields) do
    let {id, patch} <- {oneof(ids), patch(fields)} do
      # Entities carry their own id, which the row reads.
      {kind, id, if(patch["s"], do: put_in(patch["s"]["id"], id), else: patch)}
    end
  end

  # A set of some fields, an unset, a delete, or a delete with a replacement; any of
  # them possibly quiet (no activity).
  defp patch(fields) do
    let {shape, set, unset, quiet} <-
          {frequency([{6, :set}, {2, :unset}, {1, :delete}, {1, :replace}]), fields,
           resize(3, list(oneof(["status", "title", "updatedAt", "runId", "lastError"]))),
           frequency([{4, false}, {1, true}])} do
      patch =
        case shape do
          :set -> %{"s" => set}
          :unset -> %{"u" => Enum.uniq(unset)}
          :delete -> %{"d" => true}
          :replace -> %{"d" => true, "s" => set}
        end

      if quiet, do: Map.put(patch, "q", true), else: patch
    end
  end

  # Some of `fields`, each with one of its values.
  defp some(fields) do
    {names, values} = Enum.unzip(fields)

    let {present, values} <- {vector(length(fields), boolean()), List.to_tuple(values)} do
      for {name, value, true} <- Enum.zip([names, Tuple.to_list(values), present]),
          into: %{},
          do: {name, value}
    end
  end

  defp iso, do: oneof([nil, "2026-09-10T09:13:16.387Z", "2026-09-10T10:00:00.000Z", "not a date"])
  defp maybe(gen), do: oneof([nil, gen])

  defp thread_fields do
    some([
      {"title", oneof(["Fix it", "  ", "Ünïcode"])},
      {"projectId", oneof(["p1", "p2"])},
      {"providerInstanceId", oneof(["codex", "claude"])},
      {"modelSelection",
       oneof([
         nil,
         %{"instanceId" => "codex", "model" => "gpt"},
         %{"provider" => "claude", "model" => "opus", "options" => %{"effort" => "high"}}
       ])},
      {"branch", maybe("main")},
      {"createdAt", iso()},
      {"updatedAt", iso()},
      {"archivedAt", iso()},
      {"activeProviderThreadId", maybe(oneof(["pt1", "pt2"]))},
      {"forkedFrom", oneof([nil, %{"type" => "run", "threadId" => "t0", "runId" => "r1"}])},
      {"pullRequests", oneof([[], [%{"url" => "https://example.com/a/b/pull/1"}]])},
      {"historyOrigin", maybe("v1_import")},
      {"moving", maybe(%{"to" => "env-b"})},
      {"settledOverride", maybe(oneof(["settled", "unsettled"]))},
      {"pinnedAt", iso()}
    ])
  end

  @run_statuses ~w(preparing starting running waiting completed failed cancelled interrupted rolled_back)

  defp run_fields do
    some([
      {"status", oneof(@run_statuses)},
      {"ordinal", integer(1, 3)},
      {"rootNodeId", oneof(["n1", "n2"])},
      {"requestedAt", iso()},
      {"startedAt", iso()},
      {"completedAt", iso()}
    ])
  end

  defp attempt_fields do
    some([
      {"runId", oneof(["r1", "r2"])},
      {"rootNodeId", oneof(["n1", "n2"])},
      {"status", oneof(["superseded", "active"])}
    ])
  end

  defp item_fields do
    some([
      {"threadId", @thread},
      {"runId", maybe(oneof(["r1", "r2"]))},
      {"nodeId", maybe(oneof(["n1", "n2"]))},
      {"type",
       oneof(
         ~w(user_message assistant_message error command_execution subagent dynamic_tool run_interrupt_result run_interrupt_request)
       )},
      {"status", oneof(~w(completed failed running pending waiting))},
      {"inputIntent", maybe("queued_turn")},
      {"ordinal", integer(0, 3)},
      {"updatedAt", iso()},
      {"title", maybe(oneof(["  ", "Build"]))},
      {"input", oneof([nil, "make", %{"persistent" => true}])},
      {"nativeItemRef", maybe(%{"nativeId" => "task-1"})},
      {"failure",
       maybe(
         oneof([
           %{"message" => "boom", "class" => "usage_limit", "resetAt" => "2026-09-11T00:00:00Z"},
           %{"message" => "other", "class" => "provider"}
         ])
       )}
    ])
  end

  defp message_fields,
    do: some([{"role", oneof(["user", "assistant"])}, {"updatedAt", iso()}])

  defp request_fields do
    some([
      {"kind", "approval"},
      {"status", oneof(["pending", "resolved"])},
      {"createdAt", iso()}
    ])
  end

  defp session_fields do
    some([
      {"providerInstanceId", oneof(["codex", "claude"])},
      {"updatedAt", iso()},
      {"lastError", maybe(oneof(["boom", "other"]))}
    ])
  end

  defp provider_thread_fields do
    some([
      {"appThreadId", oneof([@thread, "t9"])},
      {"ownerNodeId", maybe("n1")},
      {"providerInstanceId", oneof(["codex", "claude"])},
      {"createdAt", iso()},
      {"pendingBackgroundTasks",
       oneof([[], [%{"taskId" => "k1", "taskType" => "bash", "description" => " d "}]])}
    ])
  end

  defp plan_fields,
    do: some([{"kind", oneof(["proposed_plan", "other"])}, {"status", oneof(["active", "done"])}])
end
