defmodule HalC2.StreamState do
  @moduledoc """
  The folded state of one stream: every entity by kind and id, plus the last `seq`
  applied. It is plain data, so it can be snapshotted with `term_to_binary` and
  migrated by a pure function when its shape changes.

  `created` records the seq at which each entity first appeared, which is the order
  lists such as runs and turn items are presented in. `updated_at` is the time of the
  latest event that was activity (unix ms); quiet patches such as visits do not move it.

  `changed` records the seq of each entity's latest change and `deleted` the seq at
  which an entity went away, so a client that is behind can be sent only the entities
  that differ from its copy (`changed_since/2`) however long the log between is.
  `since` is the seq that record starts at: nothing is known about changes before it.
  """

  alias HalC2.Patch

  @version 3
  # Past this many, the older half of the deletions is forgotten and `since` moves up.
  @max_deleted 1_000

  defstruct v: @version,
            seq: 0,
            updated_at: nil,
            entities: %{},
            created: %{},
            changed: %{},
            deleted: %{},
            since: 0

  @type key :: {kind :: String.t(), id :: String.t()}
  @type t :: %__MODULE__{
          v: pos_integer,
          seq: non_neg_integer,
          updated_at: integer | nil,
          entities: %{String.t() => %{String.t() => Patch.entity()}},
          created: %{key => non_neg_integer},
          changed: %{key => non_neg_integer},
          deleted: %{key => non_neg_integer},
          since: non_neg_integer
        }

  @spec new() :: t
  def new, do: %__MODULE__{}

  @doc """
  Whether an event changes nothing. Logs hold a few patches that set nothing
  (`"s": null`), written when a question whose item was missing got answered. A
  stream holding one must still load, and no client is sent it.
  """
  @spec void?(HalC2.Store.event()) :: boolean
  def void?(%{patch: %{"s" => nil} = patch}) when map_size(patch) == 1, do: true
  def void?(_event), do: false

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
        # A deleted entity that comes back is appended again, as in the Node projection.
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
  `:unknown` when `offset` is from before `since`.
  """
  @spec changed_since(t, non_neg_integer) ::
          {[{non_neg_integer, String.t(), String.t(), Patch.entity()}],
           [{non_neg_integer, String.t(), String.t()}]}
          | :unknown
  def changed_since(%__MODULE__{since: since}, offset) when offset < since, do: :unknown

  def changed_since(state, offset) do
    upserts =
      for {{kind, id}, seq} <- state.changed, seq > offset do
        {seq, kind, id, state.entities[kind][id]}
      end

    deletes = for {{kind, id}, seq} <- state.deleted, seq > offset, do: {seq, kind, id}
    {Enum.sort(upserts), Enum.sort(deletes)}
  end

  defp put_kind(entities, kind, by_id) when map_size(by_id) == 0, do: Map.delete(entities, kind)
  defp put_kind(entities, kind, by_id), do: Map.put(entities, kind, by_id)

  @doc "Every entity as `{kind, id, entity}`, in the order they were created."
  @spec rows(t) :: [{String.t(), String.t(), Patch.entity()}]
  def rows(state) do
    for({kind, by_id} <- state.entities, {id, entity} <- by_id, do: {kind, id, entity})
    |> Enum.sort_by(fn {kind, id, _} -> Map.get(state.created, {kind, id}, 0) end)
  end

  @doc "A kind's entities in the order they were created."
  @spec list(t, String.t()) :: [Patch.entity()]
  def list(state, kind) do
    state
    |> get(kind)
    |> Enum.sort_by(fn {id, _} -> Map.get(state.created, {kind, id}, 0) end)
    |> Enum.map(&elem(&1, 1))
  end

  @spec get(t, String.t()) :: %{String.t() => Patch.entity()}
  def get(state, kind), do: Map.get(state.entities, kind, %{})

  @doc "Folds a stream from its snapshot (if any) plus the events after it."
  @spec load(String.t(), String.t()) :: t
  def load(path, stream_id) do
    {after_seq, state} =
      case HalC2.Store.get_snapshot(path, stream_id) do
        {seq, %__MODULE__{} = snapshot} -> {seq, migrate(snapshot)}
        nil -> {0, new()}
      end

    HalC2.Store.reduce_stream(path, stream_id, after_seq, state, &apply_event(&2, &1))
  end

  @doc "Brings a snapshot written by an older version up to the current shape."
  @spec migrate(t) :: t
  def migrate(%__MODULE__{v: @version} = state), do: state

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
