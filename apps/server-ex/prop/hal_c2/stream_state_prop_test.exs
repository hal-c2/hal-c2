defmodule HalC2.StreamStatePropTest do
  @moduledoc """
  The laws `HalC2.StreamState` promises: folding a log is the same in one pass as in
  chunks, each entity is the composition of its patches, the bookkeeping (`created`,
  `changed`, `deleted`, `updated_at`) matches a reference model, a client that is behind
  can replay `changed_since/2` to the current state, and voids move only the seq. The
  histories come from raw events over the small pools, made valid by
  `HalC2.Prop.PatchGenerators.events/1`. These are plain `forall`s: a fold is pure.

  One law needs a store: a stream that holds only its latest runs in memory
  (`HalC2.StreamState`, "Hot and cold"), folded commit by commit as its process folds
  it, demoting, snapshotting and reloading along the way, reads the same as a whole
  fold of its log: its rows (whole and a page at a time), `changed_since/2` from every
  offset, each entity, each run's rows, its item counts and its transcript.
  """

  use ExUnit.Case, async: false
  use PropCheck

  import HalC2.Prop.PatchGenerators, only: [event_raw: 0, events: 1]

  alias HalC2.{Patch, Store}
  alias HalC2.Projection.Timeline
  alias HalC2.StreamState

  @runs ~w(r1 r2 r3 r4)
  # Each windowed entity's run and what it is, for good, as a thread's are.
  @windowed %{
    {"turn-item", "t1"} => %{"runId" => "r1", "type" => "assistant_message"},
    {"turn-item", "t2"} => %{"runId" => "r1", "type" => "run_interrupt_request"},
    {"turn-item", "t3"} => %{"runId" => "r2", "type" => "run_interrupt_result", "nodeId" => "n1"},
    {"turn-item", "t4"} => %{
      "runId" => "r3",
      "type" => "user_message",
      "inputIntent" => "queued_turn"
    },
    {"turn-item", "t5"} => %{"runId" => "r4", "type" => "assistant_message"},
    {"turn-item", "t6"} => %{"runId" => "r2", "type" => "run_interrupt_result", "nodeId" => "x"},
    {"turn-item", "t7"} => %{"type" => "assistant_message"},
    {"message", "m1"} => %{"runId" => "r1", "role" => "user"},
    {"message", "m2"} => %{"runId" => "r3", "role" => "assistant"},
    {"node", "n1"} => %{"runId" => "r2"}
  }

  property "one pass equals folding in any split into chunks",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall raw <- list(event_raw()) do
      evs = events(raw)
      whole = fold(evs)

      # Chunk sizes from one event at a time to the whole log: the splits that matter.
      Enum.all?([1, 2, 3, 7, length(evs) + 1], fn n ->
        evs
        |> Enum.chunk_every(n)
        |> Enum.reduce(StreamState.new(), &fold/2)
        |> Kernel.==(whole)
      end)
    end
  end

  property "each entity is the composition of its patches",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall raw <- list(event_raw()) do
      evs = events(raw)
      state = fold(evs)

      evs
      |> Enum.reject(&void?/1)
      |> Enum.group_by(&{&1.kind, &1.entity}, & &1.patch)
      |> Enum.all?(fn {{kind, id}, patches} ->
        composed = patches |> Enum.reduce(&Patch.compose(&2, &1))
        Patch.apply(nil, composed) == StreamState.get(state, kind)[id]
      end)
    end
  end

  property "the bookkeeping matches a reference model of the log",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall raw <- list(event_raw()) do
      evs = events(raw)
      state = fold(evs)
      model = model(evs)

      state.seq == model.seq and state.updated_at == model.updated_at and
        state.created == model.created and state.changed == model.changed and
        state.deleted == model.deleted and entities(state) == model.entities
    end
  end

  property "rows and lists come in creation order",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall raw <- list(event_raw()) do
      state = raw |> events() |> fold()
      keys = for {kind, by_id} <- state.entities, {id, _} <- by_id, do: {kind, id}
      by_created = Enum.sort_by(keys, &Map.fetch!(state.created, &1))

      rows = for {kind, id, _} <- StreamState.rows(state), do: {kind, id}

      rows == by_created and
        Enum.all?(Map.keys(state.entities), fn kind ->
          StreamState.list(state, kind) ==
            for({k, id} <- by_created, k == kind, do: StreamState.get(state, kind)[id])
        end)
    end
  end

  property "a client that is behind replays changed_since to the current state",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall raw <- list(event_raw()) do
      evs = events(raw)
      state = fold(evs)

      Enum.all?(0..length(evs), &(replay(state, evs, &1) == entities(state)))
    end
  end

  property "once deletions are forgotten, changed_since is exact from `since` on",
    numtests: HalC2.Prop.numtests(100) do
    # Deletions past the cap (1,000) are forgotten; a client older than `since` gets
    # `:unknown`, and any client at or after it still replays exactly.
    evs = churn(1_100)
    state = fold(evs)

    forall offset <- integer(0, length(evs)) do
      if offset < state.since do
        StreamState.changed_since(state, offset) == :unknown
      else
        replay(state, evs, offset) == entities(state)
      end
    end
  end

  property "voids change the seq and nothing else",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall raw <- list(event_raw()) do
      with_voids = fold(events(raw))
      without = fold(events(Enum.reject(raw, &match?({_, _, {:void, _, _, _, _}}, &1))))

      entities(with_voids) == entities(without)
    end
  end

  property "a snapshot round-trips and migrates to itself",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall raw <- list(event_raw()) do
      state = raw |> events() |> fold()

      :erlang.binary_to_term(:erlang.term_to_binary(state)) == state and
        StreamState.migrate(state) == state
    end
  end

  @tag timeout: :infinity
  property "a stream holding only its latest runs reads as a whole fold of its log",
    numtests: HalC2.Prop.numtests(100),
    max_size: 30 do
    forall {hot, steps} <- {range(1, 2), list(step())} do
      cold_case(hot, fn ->
        {_state, ok} =
          Enum.reduce(steps, {StreamState.load(Store.home_path(), "th", store: Store), true}, fn
            step, {state, ok} ->
              state = run_step(step, state)
              {state, ok and same?(state)}
          end)

        ok
      end)
    end
  end

  # --- hot and cold ----------------------------------------------------------

  defp step do
    frequency([
      {6, {:commit, non_empty(list(change()))}},
      {1, :snapshot},
      {1, :restart}
    ])
  end

  defp change do
    frequency([
      {3, {:run, oneof(@runs), oneof(~w(running completed failed cancelled rolled_back))}},
      {4, {:put, oneof(Map.keys(@windowed)), oneof(["", "a", "bc"])}},
      {2, {:append, oneof(Map.keys(@windowed))}},
      {1, {:delete, oneof(Map.keys(@windowed))}},
      {1, {:attempt, oneof(~w(running superseded))}},
      {1, {:thread, integer(0, 3)}}
    ])
  end

  defp cold_case(hot, fun) do
    HalC2.Prop.scratch_home("stream-state")
    previous = Application.get_env(:hal_c2, :stream_hot_items)
    Application.put_env(:hal_c2, :stream_hot_items, hot)
    HalC2.Prop.start_services([{Store, path: Store.home_path()}])

    try do
      fun.()
    after
      HalC2.Prop.stop_services()

      if previous,
        do: Application.put_env(:hal_c2, :stream_hot_items, previous),
        else: Application.delete_env(:hal_c2, :stream_hot_items)
    end
  end

  # As the stream's process does: a commit's events applied once the cold entities
  # they touch are back in memory, then whatever went cold demoted.
  defp run_step({:commit, intents}, state) do
    changes = resolve(intents, whole())

    case changes do
      [] ->
        state

      _ ->
        {:ok, _} = Store.append(Store, [{:thread, "th", changes}], 1)
        events = log(state.seq)

        state
        |> StreamState.promote(for {kind, id, _} <- changes, do: {kind, id})
        |> then(&Enum.reduce(events, &1, fn event, st -> StreamState.apply_event(st, event) end))
        |> StreamState.compact(Store)
    end
  end

  defp run_step(:snapshot, %{seq: 0} = state), do: state

  defp run_step(:snapshot, state) do
    {snapshot, cold} = StreamState.snapshot(state)
    :ok = Store.put_snapshot(Store, "th", state.seq, snapshot, cold)
    StreamState.written(state)
  end

  defp run_step(:restart, _state), do: StreamState.load(Store.home_path(), "th", store: Store)

  defp resolve(intents, whole) do
    {changes, _} =
      Enum.flat_map_reduce(intents, whole, fn intent, st ->
        case intent_change(intent, st) do
          nil ->
            {[], st}

          {kind, id, patch} = change ->
            {[change],
             StreamState.apply_event(st, %{
               seq: st.seq,
               kind: kind,
               entity: id,
               patch: patch,
               at: 1
             })}
        end
      end)

    changes
  end

  defp intent_change({:run, id, status}, st) do
    runs = StreamState.get(st, "run")

    case runs[id] do
      nil ->
        ordinal = runs |> Map.values() |> Enum.map(& &1["ordinal"]) |> Enum.max(fn -> 0 end)
        {"run", id, %{"s" => %{"id" => id, "ordinal" => ordinal + 1, "status" => status}}}

      _ ->
        {"run", id, %{"s" => %{"status" => status}}}
    end
  end

  defp intent_change({:put, {kind, id} = key, text}, _st) do
    entity = Map.merge(@windowed[key], %{"id" => id, "threadId" => "th", "text" => text})
    {kind, id, %{"s" => entity}}
  end

  defp intent_change({:append, {kind, id}}, st) do
    case StreamState.get(st, kind)[id] do
      %{"text" => text} when is_binary(text) -> {kind, id, %{"a" => %{"text" => "+"}}}
      _ -> nil
    end
  end

  defp intent_change({:delete, {kind, id}}, _st), do: {kind, id, Patch.delete()}

  defp intent_change({:attempt, status}, _st),
    do:
      {"run-attempt", "a1",
       %{"s" => %{"runId" => "r2", "rootNodeId" => "n1", "status" => status}}}

  defp intent_change({:thread, n}, _st), do: {"thread", "th", %{"s" => %{"id" => "th", "n" => n}}}

  defp log(after_seq),
    do:
      Store.home_path() |> Store.reduce_stream("th", after_seq, [], &[&1 | &2]) |> Enum.reverse()

  defp whole, do: fold(log(0))

  defp same?(state) do
    whole = whole()
    rows = &Enum.to_list(StreamState.rows(&1))

    replayed? =
      Enum.all?(0..whole.seq//1, fn offset ->
        changed(state, offset) == changed(whole, offset)
      end)

    fetched? =
      Enum.all?(Map.keys(@windowed), fn {kind, id} ->
        StreamState.fetch(state, kind, id) == StreamState.get(whole, kind)[id]
      end)

    run_rows? =
      Enum.all?([[], ["r1"], ["r2", "r4"], @runs], fn runs ->
        Enum.to_list(StreamState.run_rows(state, runs)) ==
          Enum.to_list(StreamState.run_rows(whole, runs))
      end)

    law(:rows, rows.(state) == rows.(whole)) and
      law(:changed_since, replayed?) and
      law(:fetch, fetched?) and
      law(
        :lookup,
        StreamState.lookup(state, Map.keys(@windowed)) ==
          StreamState.lookup(whole, Map.keys(@windowed))
      ) and
      law(:run_rows, run_rows?) and
      law(:rows_page, Enum.all?([1, 2], &(pages(state, &1) == rows.(whole)))) and
      law(:item_counts, StreamState.item_counts(state) == StreamState.item_counts(whole)) and
      law(:transcript, Timeline.local_items(state) == Timeline.local_items(whole)) and
      law(:count, Timeline.local_count(state) == length(Timeline.local_items(whole)))
  end

  # Every row, read `limit` at a time from the cursor each page returns.
  defp pages(state, limit, cursor \\ nil) do
    case StreamState.rows_page(state, cursor, limit) do
      {rows, nil} -> rows
      {rows, next} -> rows ++ pages(state, limit, next)
    end
  end

  defp changed(state, offset) do
    case StreamState.changed_since(state, offset) do
      :unknown -> :unknown
      {upserts, deletes} -> {Enum.to_list(upserts), deletes}
    end
  end

  defp law(_law, true), do: true

  defp law(law, false) do
    IO.puts("law broken: #{law}")
    false
  end

  # --- helpers ----------------------------------------------------------------

  defp fold(evs, state \\ StreamState.new()),
    do: Enum.reduce(evs, state, &StreamState.apply_event(&2, &1))

  defp void?(%{patch: %{"s" => nil}}), do: true
  defp void?(_), do: false

  # Every entity keyed by {kind, id}.
  defp entities(state) do
    for {kind, id, entity} <- StreamState.rows(state), into: %{}, do: {{kind, id}, entity}
  end

  # What a client holding the stream as of `offset` ends up with after the upserts
  # and deletes `changed_since/2` sends it.
  defp replay(state, evs, offset) do
    client = fold(Enum.take(evs, offset))
    {upserts, deletes} = StreamState.changed_since(state, offset)

    copy =
      Enum.reduce(upserts, entities(client), fn {_seq, kind, id, entity}, acc ->
        Map.put(acc, {kind, id}, entity)
      end)

    Enum.reduce(deletes, copy, fn {_seq, kind, id}, acc -> Map.delete(acc, {kind, id}) end)
  end

  # The reference model: the log's bookkeeping, computed the obvious way.
  defp model(evs) do
    Enum.reduce(
      evs,
      %{seq: 0, updated_at: nil, entities: %{}, created: %{}, changed: %{}, deleted: %{}},
      &model_step/2
    )
  end

  defp model_step(%{seq: seq} = event, model) do
    model = %{model | seq: seq}

    if void?(event) do
      model
    else
      %{kind: kind, entity: id, patch: patch, at: at} = event
      key = {kind, id}
      updated_at = if patch["q"] == true, do: model.updated_at, else: at
      model = %{model | updated_at: updated_at}

      case Patch.apply(model.entities[key], patch) do
        nil ->
          %{
            model
            | entities: Map.delete(model.entities, key),
              created: Map.delete(model.created, key),
              changed: Map.delete(model.changed, key),
              deleted: Map.put(model.deleted, key, seq)
          }

        entity ->
          %{
            model
            | entities: Map.put(model.entities, key, entity),
              created: Map.put_new(model.created, key, seq),
              changed: Map.put(model.changed, key, seq),
              deleted: Map.delete(model.deleted, key)
          }
      end
    end
  end

  # Creates and deletes entities with ids that never repeat, so the deletions pass the
  # cap that makes the stream forget the older ones.
  defp churn(count) do
    Enum.flat_map(1..count, fn i ->
      id = "t#{i}"

      [
        %{seq: 2 * i - 1, kind: "thread", entity: id, patch: %{"s" => %{"n" => i}}, at: i},
        %{seq: 2 * i, kind: "thread", entity: id, patch: Patch.delete(), at: i}
      ]
    end)
  end
end
