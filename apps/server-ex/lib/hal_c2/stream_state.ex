defmodule HalC2.StreamState do
  @moduledoc """
  The folded state of one stream: its entities by kind and id, plus the last `seq`
  applied. It is plain data, so it can be snapshotted with `term_to_binary` and
  migrated by a pure function when its shape changes.

  `created` records the seq at which each entity first appeared, which is the order
  lists such as runs and turn items are presented in. `updated_at` is the time of the
  latest event that was activity (unix ms); quiet patches such as visits do not move it.

  `changed` records the seq of each entity's latest change and `deleted` the seq at
  which an entity went away, so a client that is behind can be sent only the entities
  that differ from its copy (`changed_since/2`) however long the log between is.
  `since` is the seq that record starts at: nothing is known about changes before it.

  ## Hot and cold

  A thread's turn items, messages and nodes grow with every run, and nothing a
  stream decides reads the old ones. So memory holds only the *hot* part of a
  stream: every entity of the small kinds, and the windowed kinds (`windowed/0`) of
  runs at or above `floor` or still unsettled. The windowed entities of settled runs
  below `floor` are *cold*: they live in the store's `cold` table, one row each, as of
  the stream's latest hot snapshot (`HalC2.Store.put_snapshot/5` writes both in one
  transaction). `floor` is `nil` while nothing is cold, and only ever rises.

  `get/2` and `list/2` read memory only, which is all a decision about the running
  turn needs. `fetch/3`, `rows/2`, `all/2`, `run_rows/2` and `changed_since/2` read
  through to the cold rows, lazily and a page at a time, so even a whole thread
  goes out in bounded memory. An event to a cold entity is applied after
  `promote/2` brings it back to memory; `dirty` names the cold rows that became
  stale that way (or by a delete), which reads skip and the next snapshot deletes.
  `tally` counts the cold turn items of each run by what a transcript needs to know
  of them (`tally/1`), so counts never read the cold rows. `src` says where the cold
  rows are, and is not part of a snapshot.
  """

  alias HalC2.{Patch, Store}

  @version 4
  # Past this many, the older half of the deletions is forgotten and `since` moves up.
  @max_deleted 1_000
  @windowed ~w(turn-item message node)
  @settled ~w(completed failed cancelled interrupted rolled_back)
  # Cold rows are read this many at a time.
  @page 500

  defstruct v: @version,
            seq: 0,
            updated_at: nil,
            entities: %{},
            created: %{},
            changed: %{},
            deleted: %{},
            since: 0,
            floor: nil,
            dirty: %{},
            tally: %{},
            src: nil

  @type key :: {kind :: String.t(), id :: String.t()}
  @type row :: {String.t(), String.t(), Patch.entity()}
  @type tag :: :item | :queued_user | :interrupt_request | {:interrupt_result, String.t()}
  @type t :: %__MODULE__{
          v: pos_integer,
          seq: non_neg_integer,
          updated_at: integer | nil,
          entities: %{String.t() => %{String.t() => Patch.entity()}},
          created: %{key => non_neg_integer},
          changed: %{key => non_neg_integer},
          deleted: %{key => non_neg_integer},
          since: non_neg_integer,
          floor: integer | nil,
          dirty: %{key => String.t() | nil},
          tally: %{String.t() => %{tag => pos_integer}},
          src: src
        }

  # Where cold rows are read from: the store's path; a store whose migration is still
  # writing them (`load/3`); a read transaction pinned for a reader in another
  # process (`pin/1`), or one the stream sends that reader once its migration is done.
  @typep src ::
           {path :: String.t(), stream_id :: String.t()}
           | {:migrating, String.t(), String.t(), pid, term}
           | {:pinned, reference, String.t()}
           | {:pin_pending, pid, String.t()}
           | nil

  @spec new() :: t
  def new, do: %__MODULE__{}

  @doc "The kinds that belong to a run, whose entities of older runs go cold."
  @spec windowed() :: [String.t()]
  def windowed, do: @windowed

  @doc """
  How many turn items a stream keeps in memory at least. It demotes once it holds
  twice as many (`demote/2`).
  """
  @spec hot_items() :: pos_integer
  def hot_items, do: Application.get_env(:hal_c2, :stream_hot_items, 1_000)

  @doc """
  Whether an event changes nothing. Logs hold a few patches that set nothing
  (`"s": null`), written when a question whose item was missing got answered. A
  stream holding one must still load, and no client is sent it.
  """
  @spec void?(HalC2.Store.event()) :: boolean
  def void?(%{patch: %{"s" => nil} = patch}) when map_size(patch) == 1, do: true
  def void?(_event), do: false

  @doc """
  Applies one event to memory. An event to a cold entity must have had it
  promoted first (`promote/2`): here it would start from nothing.
  """
  @spec apply_event(t, HalC2.Store.event()) :: t
  def apply_event(
        %__MODULE__{} = state,
        %{seq: seq, kind: kind, entity: id, patch: patch} = event
      ) do
    if void?(event),
      do: %{state | seq: seq},
      else: apply_change(state, seq, kind, id, patch, event)
  end

  defp apply_change(state, seq, kind, id, patch, event) do
    by_id = Map.get(state.entities, kind, %{})
    updated_at = if patch["q"] == true, do: state.updated_at, else: event[:at] || state.updated_at
    state = %{state | seq: seq, updated_at: updated_at}

    case Patch.apply(Map.get(by_id, id), patch) do
      nil ->
        # A deleted entity that comes back is appended again.
        forget_old_deletions(%{
          state
          | entities: put_kind(state.entities, kind, Map.delete(by_id, id)),
            created: Map.delete(state.created, {kind, id}),
            changed: Map.delete(state.changed, {kind, id}),
            deleted: Map.put(state.deleted, {kind, id}, seq)
        })

      entity ->
        %{
          state
          | entities: Map.put(state.entities, kind, Map.put(by_id, id, entity)),
            created: Map.put_new(state.created, {kind, id}, seq),
            changed: Map.put(state.changed, {kind, id}, seq),
            deleted: Map.delete(state.deleted, {kind, id})
        }
    end
  end

  defp forget_old_deletions(%{deleted: deleted} = state) when map_size(deleted) <= @max_deleted,
    do: state

  defp forget_old_deletions(state) do
    {old, kept} =
      state.deleted |> Enum.sort_by(&elem(&1, 1)) |> Enum.split(div(@max_deleted, 2))

    {_, forgotten} = List.last(old)
    %{state | deleted: Map.new(kept), since: max(state.since, forgotten)}
  end

  @doc """
  What a copy of the stream as of `offset` lacks: `{upserts, deletes}`, where
  `upserts` is `{seq, kind, id, entity}` for every entity changed after `offset` and
  `deletes` is `{seq, kind, id}` for every one deleted after it, each oldest first.
  `upserts` is lazy: cold entities are read as it is walked, only those of
  `:cold_runs` when given. `:unknown` when `offset` is from before `since`.
  """
  @spec changed_since(t, non_neg_integer, keyword) ::
          {Enumerable.t({non_neg_integer, String.t(), String.t(), Patch.entity()}),
           [{non_neg_integer, String.t(), String.t()}]}
          | :unknown
  def changed_since(state, offset, opts \\ [])

  def changed_since(%__MODULE__{since: since}, offset, _opts) when offset < since, do: :unknown

  def changed_since(state, offset, opts) do
    hot =
      for {{kind, id}, seq} <- state.changed, seq > offset do
        {seq, kind, id, state.entities[kind][id]}
      end

    cold =
      case Keyword.get(opts, :cold_runs, :all) do
        [] -> []
        :all -> cold_pages(state, :changed, offset, [])
        runs -> cold_pages(state, :changed, offset, runs: runs)
      end
      |> Stream.map(fn page ->
        for {kind, id, _run, _created, changed, entity} <- page, do: {changed, kind, id, entity}
      end)

    deletes = for {{kind, id}, seq} <- state.deleted, seq > offset, do: {seq, kind, id}
    {merge(Enum.sort(hot), cold, &elem(&1, 0)), Enum.sort(deletes)}
  end

  @doc "The ids of `kind` (a small kind, always in memory) changed after `offset`."
  @spec changed_ids(t, String.t(), non_neg_integer) :: [String.t()]
  def changed_ids(state, kind, offset),
    do: for({{^kind, id}, seq} <- state.changed, seq > offset, do: id)

  defp put_kind(entities, kind, by_id) when map_size(by_id) == 0, do: Map.delete(entities, kind)
  defp put_kind(entities, kind, by_id), do: Map.put(entities, kind, by_id)

  @doc """
  Every entity as `{kind, id, entity}` in the order they were created, cold ones
  included, read lazily. `:kinds` keeps only those kinds, and `:cold_runs` (run
  ids) only the cold entities of those runs.
  """
  @spec rows(t, keyword) :: Enumerable.t(row)
  def rows(state, opts \\ []) do
    kinds = Keyword.get(opts, :kinds)
    cold_kinds = if kinds, do: Enum.filter(kinds, &(&1 in @windowed)), else: nil
    cold_runs = Keyword.get(opts, :cold_runs, :all)

    hot =
      for {kind, by_id} <- state.entities,
          kinds == nil or kind in kinds,
          {id, entity} <- by_id,
          do: {Map.get(state.created, {kind, id}, 0), kind, id, entity}

    cold =
      cond do
        cold_kinds == [] or cold_runs == [] ->
          []

        true ->
          runs = if cold_runs == :all, do: nil, else: cold_runs

          state
          |> cold_pages(:created, 0, kinds: cold_kinds, runs: runs)
          |> Stream.map(&created_rows/1)
      end

    sorted_rows(hot, cold)
  end

  @doc """
  The turn items, messages and nodes of `runs` (run ids) in the order they were
  created, cold ones included.
  """
  @spec run_rows(t, Enumerable.t(String.t())) :: Enumerable.t(row)
  def run_rows(state, runs) do
    runs = MapSet.new(runs)

    hot =
      for kind <- @windowed,
          {id, %{"runId" => run} = entity} <- get(state, kind),
          MapSet.member?(runs, run),
          do: {Map.get(state.created, {kind, id}, 0), kind, id, entity}

    # Only a run below the floor can have cold entities.
    by_run = get(state, "run")

    cold_runs =
      for run <- runs, (by_run[run] || %{}) |> below?(state.floor), do: run

    cold =
      if cold_runs == [],
        do: [],
        else: cold_pages(state, :created, 0, runs: cold_runs) |> Stream.map(&created_rows/1)

    sorted_rows(hot, cold)
  end

  defp below?(_run, nil), do: false
  defp below?(run, floor), do: ordinal(run) < floor

  @doc "A kind's entities in the order they were created, cold ones included, lazily."
  @spec all(t, String.t()) :: Enumerable.t(Patch.entity())
  def all(state, kind), do: state |> rows(kinds: [kind]) |> Stream.map(&elem(&1, 2))

  defp created_rows(page),
    do: for({kind, id, _run, created, _changed, entity} <- page, do: {created, kind, id, entity})

  defp sorted_rows(hot, cold) do
    hot
    |> Enum.sort_by(&elem(&1, 0))
    |> merge(cold, &elem(&1, 0))
    |> Stream.map(fn {_created, kind, id, entity} -> {kind, id, entity} end)
  end

  @doc "A kind's entities in memory, in the order they were created."
  @spec list(t, String.t()) :: [Patch.entity()]
  def list(state, kind) do
    state
    |> get(kind)
    |> Enum.sort_by(fn {id, _} -> Map.get(state.created, {kind, id}, 0) end)
    |> Enum.map(&elem(&1, 1))
  end

  @doc """
  A kind's entities in memory by id: all of a small kind's, and the windowed kinds'
  of hot runs only. `fetch/3` finds a cold one by its id.
  """
  @spec get(t, String.t()) :: %{String.t() => Patch.entity()}
  def get(state, kind), do: Map.get(state.entities, kind, %{})

  @doc "One entity by kind and id, read from the cold rows when it is not in memory."
  @spec fetch(t, String.t(), String.t()) :: Patch.entity() | nil
  def fetch(state, kind, id) do
    case state.entities[kind][id] do
      nil when kind in @windowed ->
        case cold(state, [{kind, id}]) do
          [{_, _, _, _, _, entity}] -> entity
          [] -> nil
        end

      entity ->
        entity
    end
  end

  @doc "The entities of `keys` (`{kind, id}`) that exist, by key, cold ones in one read."
  @spec lookup(t, Enumerable.t(key)) :: %{key => Patch.entity()}
  def lookup(state, keys) do
    {hot, missing} =
      keys
      |> Enum.uniq()
      |> Enum.split_with(fn {kind, id} -> Map.has_key?(get(state, kind), id) end)

    hot = Map.new(hot, fn {kind, id} = key -> {key, state.entities[kind][id]} end)
    missing = Enum.filter(missing, fn {kind, _} -> kind in @windowed end)

    for {kind, id, _, _, _, entity} <- cold(state, missing),
        into: hot,
        do: {{kind, id}, entity}
  end

  @doc "How many turn items each run holds, cold ones included, by run id."
  @spec item_counts(t) :: %{(String.t() | nil) => non_neg_integer}
  def item_counts(state) do
    hot = state |> get("turn-item") |> Enum.frequencies_by(fn {_id, item} -> item["runId"] end)

    for {run, tags} <- state.tally, reduce: hot do
      acc -> Map.update(acc, run, Enum.sum(Map.values(tags)), &(&1 + Enum.sum(Map.values(tags))))
    end
  end

  @doc """
  The cold turn items of each run, counted by `tag`: `:queued_user` for a queued
  turn's user message, `:interrupt_request`, `{:interrupt_result, node_id}`, and
  `:item` for any other. That is what `HalC2.Projection.Timeline` needs to know which
  are visible.
  """
  @spec tally(t) :: %{String.t() => %{tag => pos_integer}}
  def tally(state), do: state.tally

  defp tag(%{"type" => "run_interrupt_result", "nodeId" => node}) when node != nil,
    do: {:interrupt_result, node}

  defp tag(%{"type" => "run_interrupt_request"}), do: :interrupt_request
  defp tag(%{"type" => "user_message", "inputIntent" => "queued_turn"}), do: :queued_user
  defp tag(_item), do: :item

  defp count(tally, "turn-item", run, item, by) do
    tags = tally |> Map.get(run, %{}) |> Map.update(tag(item), by, &(&1 + by))
    tags = for {tag, n} <- tags, n > 0, into: %{}, do: {tag, n}
    if tags == %{}, do: Map.delete(tally, run), else: Map.put(tally, run, tags)
  end

  defp count(tally, _kind, _run, _entity, _by), do: tally

  @doc false
  # One more cold turn item of `run` in a tally (`tally/1`).
  def count_tag(tally, run, item), do: count(tally, "turn-item", run, item, 1)

  # The cold rows of `keys` still current: neither in memory nor stale.
  defp cold(%{floor: floor, src: src} = state, keys) when floor != nil and src != nil do
    keys =
      Enum.reject(keys, fn {kind, eid} = key ->
        Map.has_key?(state.dirty, key) or Map.has_key?(get(state, kind), eid)
      end)

    if keys == [] do
      []
    else
      {path, id} = source(src)
      Store.cold_rows(path, id, keys)
    end
  end

  defp cold(_state, _keys), do: []

  # The current cold rows a page at a time, in `order` from after `after_seq`.
  defp cold_pages(%{floor: floor, src: src} = state, order, after_seq, opts)
       when floor != nil and src != nil do
    at = if order == :created, do: 3, else: 4

    after_seq
    |> Stream.unfold(fn
      :done ->
        nil

      after_seq ->
        {path, id} = source(src)

        case Store.cold_page(path, id, order, after_seq, @page, opts) do
          [] ->
            nil

          page ->
            next = if length(page) < @page, do: :done, else: page |> List.last() |> elem(at)
            {Enum.reject(page, &stale?(state, &1)), next}
        end
    end)
    |> Stream.reject(&(&1 == []))
  end

  defp cold_pages(_state, _order, _after, _opts), do: []

  # Where the cold rows are read from. Those of a migrating stream are there once
  # its migration wrote them.
  defp source({:migrating, path, id, pid, _plan}) do
    :ok = HalC2.Streams.Server.await_cold(pid)
    {path, id}
  end

  defp source({:pinned, db, id}), do: {db, id}

  defp source({:pin_pending, _pid, _id}),
    do: raise(ArgumentError, "a pinned state's cold rows are read inside read/2")

  defp source(src), do: src

  @doc """
  The state for a reader in another process, called by the stream's own process as
  it hands the state over: its cold rows are read in a read transaction pinned to
  what the store holds now (`HalC2.Store.pin/1`), which the stream's later snapshots
  do not change. Otherwise a reader walking them after an entity was brought back to
  memory and a snapshot written would find it in neither. The reader reads it in
  `read/2`.

  A migrating stream's cold rows are not all written yet: its reader is sent the pin
  when they are (`{:hal_c2_pin, stream, pin}`), before the stream writes anything
  else, and must be added to who the stream sends it to.
  """
  @spec pin(t) :: t
  def pin(%{floor: floor, src: {path, id}} = state) when floor != nil and is_binary(path),
    do: %{state | src: {:pinned, HalC2.Store.pin(path), id}}

  def pin(%{src: {:migrating, _path, id, pid, _plan}} = state),
    do: %{state | src: {:pin_pending, pid, id}}

  def pin(state), do: state

  @doc """
  Runs `fun` with a state `pin/1` handed over, its cold rows read in its pinned
  transaction, which ends with it: what `fun` returns must not read them lazily any
  more. Waits for a migrating stream's pin first, and exits if the stream stops
  before sending it. Any other state is passed as it is.
  """
  @spec read(t, (t -> result)) :: result when result: term
  def read(%{src: {:pin_pending, pid, id}} = state, fun) do
    ref = Process.monitor(pid)

    receive do
      {:hal_c2_pin, ^pid, db} ->
        Process.demonitor(ref, [:flush])
        read(%{state | src: {:pinned, db, id}}, fun)

      {:DOWN, ^ref, :process, ^pid, reason} ->
        exit({:stream_down, reason})
    end
  end

  def read(%{src: {:pinned, db, _id}} = state, fun) do
    fun.(state)
  after
    HalC2.Store.unpin(db)
  end

  def read(state, fun), do: fun.(state)

  defp stale?(state, {kind, id, _, _, _, _}),
    do: Map.has_key?(state.dirty, {kind, id}) or Map.has_key?(get(state, kind), id)

  # Merges a sorted list with a stream of sorted pages, by `key`, lazily.
  defp merge(list, [], _key), do: list

  defp merge(list, pages, key) do
    Stream.transform(
      pages,
      fn -> list end,
      fn page, list ->
        last = key.(List.last(page))
        {before, rest} = Enum.split_while(list, &(key.(&1) <= last))
        {merge_lists(before, page, key, []), rest}
      end,
      fn list -> {list, []} end,
      fn _ -> :ok end
    )
  end

  defp merge_lists([], b, _key, acc), do: Enum.reverse(acc, b)
  defp merge_lists(a, [], _key, acc), do: Enum.reverse(acc, a)

  defp merge_lists([x | a] = xs, [y | b] = ys, key, acc) do
    if key.(x) <= key.(y),
      do: merge_lists(a, ys, key, [x | acc]),
      else: merge_lists(xs, b, key, [y | acc])
  end

  @doc """
  `state` as if `changes` (`{kind, id, patch}`) were committed, to decide what
  follows them in one step. Every change applies at `state.seq`, to the entity as it
  is, a cold one brought back first (`promote/2`).
  """
  @spec with_changes(t, [{String.t(), String.t(), Patch.t()}]) :: t
  def with_changes(state, changes) do
    state
    |> promote(for {kind, id, _} <- changes, do: {kind, id})
    |> then(fn state ->
      Enum.reduce(changes, state, fn {kind, id, patch}, state ->
        apply_event(state, %{seq: state.seq, kind: kind, entity: id, patch: patch})
      end)
    end)
  end

  @doc """
  Brings the cold entities among `keys` (`{kind, id}`) back to memory, as they
  were, so events to them apply to what they are. Their cold rows are stale from
  here on.
  """
  @spec promote(t, Enumerable.t(key)) :: t
  def promote(%{floor: nil} = state, _keys), do: state
  def promote(%{src: nil} = state, _keys), do: state

  def promote(state, keys) do
    keys = keys |> Enum.filter(fn {kind, _} -> kind in @windowed end) |> Enum.uniq()

    state
    |> cold(keys)
    |> Enum.reduce(state, fn {kind, id, run, created, changed, entity}, state ->
      %{
        state
        | entities: Map.update(state.entities, kind, %{id => entity}, &Map.put(&1, id, entity)),
          created: Map.put(state.created, {kind, id}, created),
          changed: Map.put(state.changed, {kind, id}, changed),
          dirty: Map.put(state.dirty, {kind, id}, run),
          tally: count(state.tally, kind, run, entity, -1)
      }
    end)
  end

  @doc """
  Moves the windowed entities of settled runs below a new floor out of memory: the
  newest runs that hold `hot_items` turn items stay. Returns the state without them
  and their rows for the cold table (`HalC2.Store.put_snapshot/5`), or `:none` when
  nothing would move. The floor only rises.
  """
  @spec demote(t, pos_integer) :: {t, [Store.cold_row()]} | :none
  def demote(state, hot_items) do
    runs = get(state, "run")
    floor = max_floor(state.floor, tail(state, runs, hot_items))

    moving =
      for kind <- @windowed,
          {id, %{"runId" => run_id} = entity} <- get(state, kind),
          cold?(runs[run_id], floor),
          do: {kind, id, entity}

    if moving == [] do
      :none
    else
      rows =
        for {kind, id, entity} <- moving,
            do:
              {kind, id, entity["runId"], Map.get(state.created, {kind, id}, 0),
               Map.get(state.changed, {kind, id}, 0), entity}

      entities =
        Enum.reduce(moving, state.entities, fn {kind, id, _}, entities ->
          put_kind(entities, kind, Map.delete(entities[kind], id))
        end)

      keys = for {kind, id, _} <- moving, do: {kind, id}

      tally =
        Enum.reduce(moving, state.tally, fn {kind, _, entity}, tally ->
          count(tally, kind, entity["runId"], entity, 1)
        end)

      {%{
         state
         | entities: entities,
           floor: floor,
           tally: tally,
           created: Map.drop(state.created, keys),
           changed: Map.drop(state.changed, keys)
       }, rows}
    end
  end

  @doc "Whether memory holds enough turn items for `demote/2` to be worth a pass."
  @spec demote?(t, pos_integer) :: boolean
  def demote?(state, hot_items), do: map_size(get(state, "turn-item")) > 2 * hot_items

  defp max_floor(nil, floor), do: floor
  defp max_floor(floor, nil), do: floor
  defp max_floor(a, b), do: max(a, b)

  defp cold?(%{"status" => status} = run, floor) when floor != nil and status in @settled,
    do: ordinal(run) < floor

  defp cold?(_run, _floor), do: false

  # The floor for what memory holds now.
  defp tail(state, runs, items) do
    counts = state |> get("turn-item") |> Enum.frequencies_by(fn {_, item} -> item["runId"] end)
    floor_for(runs, counts, items)
  end

  @doc """
  The ordinal of the oldest of the newest `runs` (by id) that hold `items` turn
  items together, given how many each holds (`counts`, by run id); `nil` when all of
  them hold fewer. That is the floor `demote/2` moves below.
  """
  @spec floor_for(%{String.t() => map}, %{String.t() => non_neg_integer}, pos_integer) ::
          integer | nil
  def floor_for(runs, counts, items) do
    runs
    |> Enum.map(fn {id, run} -> {ordinal(run), Map.get(counts, id, 0)} end)
    |> Enum.sort(:desc)
    |> Enum.reduce_while(0, fn {ordinal, count}, held ->
      if held + count >= items, do: {:halt, {:floor, ordinal}}, else: {:cont, held + count}
    end)
    |> case do
      {:floor, ordinal} -> ordinal
      _ -> nil
    end
  end

  @doc "Whether a run's entities go cold below `floor`: it settled, and is below it."
  @spec cold_run?(map | nil, integer | nil) :: boolean
  def cold_run?(run, floor), do: cold?(run, floor)

  defp ordinal(run), do: run["ordinal"] || 0

  @doc """
  What a snapshot of the state holds, with the cold rows it is written with
  brought up to date (`HalC2.Store.put_snapshot/5`): `{snapshot, cold}`.
  """
  @spec snapshot(t, [Store.cold_row()], boolean) :: {t, keyword}
  def snapshot(state, rows \\ [], reset? \\ nil) do
    reset? = if reset? == nil, do: state.floor == nil, else: reset?
    cold = [reset: reset?, delete: Map.keys(state.dirty), put: rows]
    {%{state | dirty: %{}, src: nil}, cold}
  end

  @doc "The state once its snapshot is written: no cold row is stale any more."
  @spec written(t) :: t
  def written(state), do: %{state | dirty: %{}}

  @doc """
  Folds a stream from its snapshot (if any) plus the events after it.

  With `store:` (a `HalC2.Store`), the stream's own process loads it: a stream
  without a hot snapshot migrates, and memory is kept to the hot part as it
  folds, the cold rows and a hot snapshot written to that store along the way. An
  older MC's snapshot is read whole only below `:max_legacy` bytes. A longer one is
  read one entity at a time for its hot part (`HalC2.StreamState.Legacy.hot/3`),
  and the state comes back *migrating* (`migration/1`): its cold rows are not
  written yet, and every read of them waits until they are.
  """
  @spec load(String.t() | reference, String.t(), keyword) :: t
  def load(path, stream_id, opts \\ []) do
    store = Keyword.get(opts, :store)
    src = {path, stream_id}

    loaded =
      case Store.get_snapshot(path, stream_id) do
        {seq, %{} = snapshot} ->
          {seq, %{migrate(snapshot) | src: src}, true}

        nil ->
          max = if store, do: Keyword.get(opts, :max_legacy, max_legacy()), else: :infinity

          case Store.legacy_snapshot(path, stream_id, max_bytes(max)) do
            {seq, %{} = snapshot} -> {seq, %{migrate(snapshot) | src: src}, false}
            {:too_big, _seq} -> load_legacy(path, stream_id)
            _ -> {0, %{new() | src: src}, false}
          end
      end

    case loaded do
      {:migrating, state} ->
        state

      {after_seq, state, hot?} ->
        folded =
          path
          |> Store.reduce_stream(stream_id, after_seq, {state, []}, fn event, {state, batch} ->
            if length(batch) >= @page,
              do: {fold(state, Enum.reverse([event | batch]), store), []},
              else: {state, [event | batch]}
          end)
          |> then(fn {state, batch} -> fold(state, Enum.reverse(batch), store) end)

        folded = if store, do: compact(folded, store), else: folded

        if store && not hot? && folded.seq > 0,
          do: write(folded, store, [], folded.floor == nil),
          else: folded
    end
  end

  # The hot part of a long legacy snapshot, and the events after it. What they touch
  # is kept in memory, so none of them needs a cold row that is not written yet.
  defp load_legacy(path, stream_id) do
    {seq, blob} = Store.legacy_blob(path, stream_id)

    keep =
      Store.reduce_stream(path, stream_id, seq, MapSet.new(), fn %{kind: kind, entity: id},
                                                                 keys ->
        MapSet.put(keys, {kind, id})
      end)

    {state, plan} = HalC2.StreamState.Legacy.hot(blob, hot_items(), keep)
    state = Store.reduce_stream(path, stream_id, seq, state, &apply_event(&2, &1))

    case plan do
      # Nothing went cold: the hot snapshot is the whole one, written as for a short thread.
      nil -> {state.seq, %{state | src: {path, stream_id}}, false}
      plan -> {:migrating, %{state | src: {:migrating, path, stream_id, self(), plan}}}
    end
  end

  @doc """
  What a state `load/3` left migrating still needs written: the plan for
  `HalC2.StreamState.Legacy.cold/4`, or `nil`.
  """
  @spec migration(t) :: map | nil
  def migration(%{src: {:migrating, _path, _id, _pid, plan}}), do: plan
  def migration(_state), do: nil

  @doc "The state once its migration's cold rows are written: it reads them as any other's."
  @spec migrated(t) :: t
  def migrated(%{src: {:migrating, path, id, _pid, _plan}} = state),
    do: %{state | src: {path, id}}

  def migrated(state), do: state

  @doc """
  `fun` of the stream `stream_id` as the store at `path` holds it, loaded and read in one
  read transaction (`HalC2.Store.pin/1`), for a reader with no stream process to ask
  while one may be running and writing snapshots. Whatever `fun` returns must not read
  the state's cold rows later.
  """
  @spec load_read(String.t(), String.t(), (t -> result)) :: result when result: var
  def load_read(path, stream_id, fun) do
    db = Store.pin(path)

    try do
      fun.(load(db, stream_id))
    after
      Store.unpin(db)
    end
  end

  @doc "Bytes of an older MC's snapshot `load/3` reads whole; a longer one migrates in the background."
  @spec max_legacy() :: non_neg_integer
  def max_legacy, do: Application.get_env(:hal_c2, :stream_max_legacy_bytes, 16 * 1024 * 1024)

  defp max_bytes(:infinity), do: 9_223_372_036_854_775_807
  defp max_bytes(n), do: n

  # Events applied as one batch: the cold entities they touch read in one query.
  defp fold(state, [], _store), do: state

  defp fold(state, events, store) do
    state = promote(state, for(%{kind: kind, entity: id} <- events, do: {kind, id}))
    state = Enum.reduce(events, state, &apply_event(&2, &1))
    if store, do: compact(state, store), else: state
  end

  @doc """
  Demotes what has gone cold, when there is enough of it, and writes the cold rows
  and a hot snapshot to `store`: they must be on disk before memory lets them go.
  """
  @spec compact(t, GenServer.server()) :: t
  # A migrating stream's cold rows are being written: nothing moves until they are.
  def compact(%{src: {:migrating, _path, _id, _pid, _plan}} = state, _store), do: state

  def compact(state, store) do
    with true <- demote?(state, hot_items()),
         {demoted, rows} <- demote(state, hot_items()) do
      # Whatever the table held while nothing was cold is stale.
      write(demoted, store, rows, state.floor == nil)
    else
      _ -> state
    end
  end

  defp write(%{src: {_path, id}} = state, store, rows, reset?) do
    {snapshot, cold} = snapshot(state, rows, reset?)
    :ok = Store.put_snapshot(store, id, state.seq, snapshot, cold)
    written(state)
  end

  @doc "Brings a snapshot written by an older version up to the current shape."
  @spec migrate(t) :: t
  def migrate(%__MODULE__{v: @version} = state), do: state

  # v3 held every entity in memory: nothing is cold.
  def migrate(%{v: 3} = state),
    do: %{
      struct(__MODULE__, Map.from_struct(state))
      | v: 4,
        floor: nil,
        dirty: %{},
        tally: %{},
        src: nil
    }

  # v2 did not record when entities changed: nothing is known before its seq.
  def migrate(%{v: 2} = state) do
    changed =
      for {kind, by_id} <- state.entities,
          {id, _} <- by_id,
          into: %{},
          do: {{kind, id}, state.seq}

    migrate(%{
      struct(__MODULE__, Map.from_struct(state))
      | v: 3,
        changed: changed,
        deleted: %{},
        since: state.seq
    })
  end

  # v1 had no creation order; fall back to entity id order.
  def migrate(%{v: 1} = state),
    do: migrate(%{struct(__MODULE__, Map.from_struct(state)) | v: 2, created: %{}})
end
