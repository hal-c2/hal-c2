defmodule HalC2.StreamStatePropTest do
  @moduledoc """
  The laws `HalC2.StreamState` promises: folding a log is the same in one pass as in
  chunks, each entity is the composition of its patches, the bookkeeping (`created`,
  `changed`, `deleted`, `updated_at`) matches a reference model, a client that is behind
  can replay `changed_since/2` to the current state, and voids move only the seq. The
  histories come from raw events over the small pools, made valid by
  `HalC2.Prop.PatchGenerators.events/1`. These are plain `forall`s: a fold is pure.
  """

  use ExUnit.Case, async: true
  use PropCheck

  import HalC2.Prop.PatchGenerators, only: [event_raw: 0, events: 1]

  alias HalC2.Patch
  alias HalC2.StreamState

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
