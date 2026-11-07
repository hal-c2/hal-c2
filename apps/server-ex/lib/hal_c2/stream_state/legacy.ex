defmodule HalC2.StreamState.Legacy do
  @moduledoc """
  Reads a whole-stream snapshot an older MC wrote (`HalC2.Store.legacy_snapshot/3`)
  one entity at a time, so a long thread's is never all in memory at once.

  The snapshot is a compressed `term_to_binary` of a `HalC2.StreamState` that held
  every entity. It is inflated a piece at a time, and the struct and its
  `entities` map are walked by their headers: every other field, and each entity,
  is decoded on its own with `binary_to_term(_, [:used])`.
  """

  alias HalC2.StreamState

  @map 116
  # Compressed bytes inflated at a time.
  @piece 256 * 1024
  # Bytes tried for a term at least; doubled until it decodes. Each class of term
  # (`:key`, `:value`) starts from twice the size of the last one.
  @window 64

  @typedoc "What `walk/3` hands its function, in the snapshot's order."
  @type item ::
          {:field, atom, term, raw :: binary}
          | {:entity, kind :: String.t(), id :: String.t(), entity :: map, raw :: binary}

  @doc """
  Calls `fun.(item, acc)` for every field of the snapshot's struct but its
  entities, and for every entity. Each comes with `raw`, its own encoding: a valid
  `binary_to_term/1` input that shares memory with the snapshot's, so copy it to
  keep it. Holding that rather than a large term spares the walk's collections
  copying the term again and again.
  Fields, kinds and entities come in no order the caller can count on: `:created`
  may come after the entities.
  """
  @spec walk(binary, acc, (item, acc -> acc)) :: acc when acc: term
  def walk(blob, acc, fun) do
    reader = open(blob)

    try do
      {pairs, reader} = map_header(reader)

      {acc, reader} =
        Enum.reduce(1..pairs//1, {acc, reader}, fn _, {acc, reader} ->
          {field, reader} = term(reader, :key)

          case field do
            :entities ->
              entities(reader, acc, fun)

            field ->
              raw_term(reader, :value)
              |> then(fn {value, raw, r} -> {fun.({:field, field, value, raw}, acc), r} end)
          end
        end)

      _ = reader
      acc
    after
      close(reader)
    end
  end

  defp entities(reader, acc, fun) do
    {kinds, reader} = map_header(reader)

    Enum.reduce(1..kinds//1, {acc, reader}, fn _, {acc, reader} ->
      {kind, reader} = term(reader, :key)
      {count, reader} = map_header(reader)

      Enum.reduce(1..count//1, {acc, reader}, fn _, {acc, reader} ->
        {id, reader} = term(reader, :key)
        {entity, raw, reader} = raw_term(reader, :value)
        {fun.({:entity, kind, id, entity, raw}, acc), reader}
      end)
    end)
  end

  @doc """
  The hot part of a legacy snapshot, as `HalC2.StreamState.demote/2` would leave
  it, and what `cold/4` needs to write the rest: `{state, plan}`, where `plan` is
  `nil` when nothing is cold. The entities of `keep` (`{kind, id}`) stay in memory
  whatever their run, for the events after the snapshot to apply to.

  Those of a settled run that the newest runs' items already push below the floor
  are dropped as they come, so only about `hot_items` turn items are held. The rest
  are held encoded until the floor is known. That bound holds because a map with few
  string keys is encoded in their order, so the turn items come after the runs; were
  they first, the walk would still be right, only hold more.
  """
  @spec hot(binary, pos_integer, MapSet.t()) :: {StreamState.t(), map | nil}
  def hot(blob, hot_items, keep) do
    # In a process of its own, its heap sized for what it holds, so collecting the
    # walk's garbage does not copy that again and again, and what it held goes with it.
    {pid, ref} =
      :erlang.spawn_opt(
        fn -> exit({:hot, do_hot(blob, hot_items, keep)}) end,
        [:monitor, min_heap_size: heap_words(blob)]
      )

    receive do
      {:DOWN, ^ref, :process, ^pid, {:hot, result}} -> result
      {:DOWN, ^ref, :process, ^pid, reason} -> exit(reason)
    end
  end

  # About an eighth of the inflated snapshot, in words, up to 64 MB.
  defp heap_words(<<131, 80, size::32, _::binary>>), do: min(div(size, 64), 8_000_000)
  defp heap_words(blob), do: min(div(byte_size(blob), 64), 8_000_000)

  defp do_hot(blob, hot_items, keep) do
    acc =
      walk(
        blob,
        %{
          fields: %{},
          entities: %{},
          held: %{},
          counts: %{},
          seen: 0,
          tally: %{},
          floor: nil,
          dropped?: false
        },
        fn
          {:field, :__struct__, _value, _raw}, acc ->
            acc

          # The record of when each entity changed is large: held encoded until the end.
          {:field, field, _value, raw}, acc when field in [:created, :changed] ->
            %{acc | fields: Map.put(acc.fields, field, {:raw, :binary.copy(raw)})}

          {:field, field, value, _raw}, acc ->
            %{acc | fields: Map.put(acc.fields, field, value)}

          {:entity, kind, id, entity, raw}, acc ->
            hold(acc, kind, id, entity, raw, hot_items, keep)
        end
      )

    runs = Map.get(acc.entities, "run", %{})

    floor =
      if acc.seen > 2 * hot_items, do: StreamState.floor_for(runs, acc.counts, hot_items)

    {cold, hot} =
      Enum.split_with(acc.held, fn {run, _} -> StreamState.cold_run?(runs[run], floor) end)

    entities =
      for {_run, held} <- hot, {kind, id, raw} <- held, reduce: acc.entities do
        entities -> put_entity(entities, kind, id, :erlang.binary_to_term(raw))
      end

    cold_runs =
      for {run, entry} <- runs, StreamState.cold_run?(entry, floor), into: MapSet.new(), do: run

    # Whether anything went: the floor is only set by moving something below it.
    moved? = cold != [] or acc.dropped?
    held? = fn {kind, id} -> not windowed?(kind) or Map.has_key?(entities[kind] || %{}, id) end

    fields =
      Map.new(acc.fields, fn
        {field, {:raw, raw}} -> {field, :erlang.binary_to_term(raw)}
        field -> field
      end)

    v = Map.get(fields, :v, 1)

    state =
      struct(StreamState, fields)
      |> Map.merge(%{
        v: v,
        entities: entities,
        created: fields |> Map.get(:created, %{}) |> Map.filter(fn {key, _} -> held?.(key) end),
        changed: fields |> Map.get(:changed, %{}) |> Map.filter(fn {key, _} -> held?.(key) end)
      })
      |> StreamState.migrate()

    if moved? do
      tally = Map.take(acc.tally, MapSet.to_list(cold_runs))
      plan = %{cold_runs: cold_runs, keep: keep, v: v, seq: state.seq}
      {%{state | floor: floor, tally: tally}, plan}
    else
      {state, nil}
    end
  end

  # Turn items between evictions of the runs gone below the floor.
  @evict_every 1_000

  defp hold(acc, kind, id, entity, raw, hot_items, keep) do
    cond do
      not windowed?(kind) ->
        %{acc | entities: put_entity(acc.entities, kind, id, entity)}

      true ->
        run = Map.get(entity, "runId")
        key = {kind, id}
        turn_item? = kind == "turn-item"

        acc =
          if turn_item?,
            do: %{acc | seen: acc.seen + 1, counts: Map.update(acc.counts, run, 1, &(&1 + 1))},
            else: acc

        acc =
          if turn_item? and not MapSet.member?(keep, key),
            do: %{acc | tally: StreamState.count_tag(acc.tally, run, entity)},
            else: acc

        cond do
          run == nil or MapSet.member?(keep, key) ->
            %{acc | entities: put_entity(acc.entities, kind, id, entity)}

          # Below the floor so far, so below the last one too: never held at all.
          acc.floor != nil and
              StreamState.cold_run?(
                acc.entities |> Map.get("run", %{}) |> Map.get(run),
                acc.floor
              ) ->
            %{acc | dropped?: true}

          true ->
            held = {kind, id, :binary.copy(raw)}
            %{acc | held: Map.update(acc.held, run, [held], &[held | &1])}
        end
        |> then(fn acc ->
          if turn_item? and
               (acc.seen == 2 * hot_items + 1 or
                  (acc.seen > 2 * hot_items and rem(acc.seen, @evict_every) == 0)),
             do: evict(acc, hot_items),
             else: acc
        end)
    end
  end

  # Drops what the items so far already put below the floor: the floor only rises
  # as more come.
  defp evict(acc, hot_items) do
    runs = Map.get(acc.entities, "run", %{})
    floor = StreamState.floor_for(runs, acc.counts, hot_items)
    gone = for {run, _} <- acc.held, StreamState.cold_run?(runs[run], floor), do: run
    %{acc | held: Map.drop(acc.held, gone), floor: floor, dropped?: acc.dropped? or gone != []}
  end

  for kind <- StreamState.windowed(), do: defp(windowed?(unquote(kind)), do: true)
  defp windowed?(_kind), do: false

  defp put_entity(entities, kind, id, entity),
    do: Map.update(entities, kind, %{id => entity}, &Map.put(&1, id, entity))

  @doc """
  Calls `fun` with the cold rows of a legacy snapshot that `hot/3` planned, about
  `batch` at a time: `HalC2.Store.cold_row/0` tuples, as of the snapshot.
  """
  @spec cold(binary, map, pos_integer, ([HalC2.Store.cold_row()] -> any)) :: :ok
  def cold(blob, plan, batch, fun) do
    # A version that did not record changes knew nothing before its seq.
    default_changed = if plan.v < 3, do: plan.seq, else: 0

    # The struct's fields come in no fixed order, so they are read first.
    fields =
      walk(blob, %{}, fn
        {:field, field, _value, raw}, acc when field in [:created, :changed] ->
          Map.put(acc, field, :binary.copy(raw))

        _item, acc ->
          acc
      end)

    decoded = fn field -> if raw = fields[field], do: :erlang.binary_to_term(raw), else: %{} end

    acc =
      walk(blob, %{created: decoded.(:created), changed: decoded.(:changed), rows: [], n: 0}, fn
        {:field, _field, _value, _raw}, acc ->
          acc

        {:entity, kind, id, %{"runId" => run} = entity, _raw}, acc ->
          key = {kind, id}

          if windowed?(kind) and MapSet.member?(plan.cold_runs, run) and
               not MapSet.member?(plan.keep, key) do
            row =
              {kind, id, run, Map.get(acc.created, key, 0),
               Map.get(acc.changed, key, default_changed), entity}

            acc = %{acc | rows: [row | acc.rows], n: acc.n + 1}

            if acc.n >= batch do
              fun.(Enum.reverse(acc.rows))
              %{acc | rows: [], n: 0}
            else
              acc
            end
          else
            acc
          end

        {:entity, _kind, _id, _entity, _raw}, acc ->
          acc
      end)

    if acc.rows != [], do: fun.(Enum.reverse(acc.rows))
    :ok
  end

  # A reader: the inflated bytes not read yet, and the zlib stream that has more.
  defp open(<<131, 80, _size::32, data::binary>>) do
    z = :zlib.open()
    :ok = :zlib.inflateInit(z)
    %{buf: <<>>, z: z, input: data, window: %{key: @window, value: @window}}
  end

  defp open(<<131, data::binary>>),
    do: %{buf: data, z: nil, input: nil, window: %{key: @window, value: @window}}

  defp close(%{z: nil}), do: :ok
  defp close(%{z: z}), do: :zlib.close(z)

  # More inflated bytes, or `:eof`.
  defp refill(%{z: nil}), do: :eof
  defp refill(%{input: <<>>}), do: :eof

  defp refill(%{z: z, input: input, buf: buf} = reader) do
    size = min(byte_size(input), @piece)
    out = :zlib.inflate(z, binary_part(input, 0, size))
    rest = binary_part(input, size, byte_size(input) - size)
    {:ok, %{reader | buf: IO.iodata_to_binary([buf | out]), input: rest}}
  end

  # The reader with at least `n` bytes, or all there are.
  defp grow(%{buf: buf} = reader, n) when byte_size(buf) >= n, do: reader

  defp grow(reader, n) do
    case refill(reader) do
      {:ok, reader} -> grow(reader, n)
      :eof -> reader
    end
  end

  defp ensure(%{buf: buf} = reader, n) when byte_size(buf) >= n, do: reader

  defp ensure(reader, n) do
    case refill(reader) do
      {:ok, reader} -> ensure(reader, n)
      :eof -> raise ArgumentError, "a legacy snapshot ended early"
    end
  end

  defp map_header(reader) do
    reader = ensure(reader, 5)
    <<@map, arity::32, rest::binary>> = reader.buf
    {arity, %{reader | buf: rest}}
  end

  defp term(reader, class) do
    {term, _raw, reader} = raw_term(reader, class)
    {term, reader}
  end

  # The next term and its own encoding. A window of the bytes is tried first: a
  # truncated encoding never decodes, so one that does is the whole term.
  defp raw_term(%{buf: buf, window: windows} = reader, class) do
    window = Map.fetch!(windows, class)
    size = byte_size(buf)
    try_bytes = min(size, window)
    candidate = <<131, binary_part(buf, 0, try_bytes)::binary>>

    case decode(candidate) do
      {term, used} ->
        raw = binary_part(candidate, 0, used)
        rest = binary_part(buf, used - 1, size - used + 1)
        {term, raw, %{reader | buf: rest, window: %{windows | class => max(@window, 2 * used)}}}

      :short when try_bytes < size ->
        raw_term(%{reader | window: %{windows | class => 2 * window}}, class)

      # Twice the bytes before trying again, so a large term is decoded a few times,
      # not once per piece inflated.
      :short ->
        reader = grow(reader, max(2 * size, @window))

        if byte_size(reader.buf) == size,
          do: raise(ArgumentError, "a legacy snapshot ended early")

        raw_term(%{reader | window: %{windows | class => byte_size(reader.buf)}}, class)
    end
  end

  defp decode(candidate) do
    :erlang.binary_to_term(candidate, [:used])
  catch
    :error, :badarg -> :short
  end
end
