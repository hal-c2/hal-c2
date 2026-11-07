defmodule HalC2.Store.Compaction do
  @moduledoc """
  Removes the events of a thread's log that no replay needs any more: the
  intermediate updates of its thread and message entities. A message streamed in a
  thousand appends keeps its first event and its last; a thread renamed ten times
  keeps the rename that came last.

  Each entity's events are cut into *runs*: the events between two that are kept
  as they are, its *barriers* (the one that creates it, one that deletes or replaces
  it). In a run, the last event that is activity absorbs every event before it, and
  the run's last event absorbs the visits after that: each is rewritten to set every
  field those events touched to its value at that point, and the events it absorbed
  are deleted. Activity is never folded into a visit, so the stream's `updated_at`
  keeps its time, and every entity keeps the seq it was created and last changed at.

  So whatever offset a client resumes from, the events after it bring it to the
  same state, and a snapshot taken at any seq stays valid. The rewrite of an event
  is applied before the deletes of what it absorbed, in batches of `@batch` events
  through `HalC2.Store.compact/2`, so commands go between batches and a stop at any
  point leaves a log that still folds to the same state.

  Runs, turn items and everything else in the log stay as they are: rollbacks and
  the space history read those, and they are not superseded. A thread whose import
  is still running is left alone, as `HalC2.Import.PreviousInstall` resumes it from
  its event count.
  """

  require Logger

  alias HalC2.{Patch, Store, StreamState}

  @kinds ~w(thread message)
  @batch 50
  @through "compaction.through"

  @type op :: {:rewrite, pos_integer, String.t(), String.t(), Patch.t()} | {:delete, pos_integer}
  @type report :: %{
          streams: non_neg_integer,
          events: non_neg_integer,
          rewritten: non_neg_integer,
          reclaimable: non_neg_integer
        }

  @doc """
  Compacts the thread streams with events since the last run (every one with
  `all: true`) and reports what it removed and how many bytes the store could give
  back. `:on_batch` is called after each batch is written.
  """
  @spec run(GenServer.server(), keyword) :: report
  def run(store \\ Store, opts \\ []) do
    path = Store.path(store)
    on_batch = Keyword.get(opts, :on_batch, fn -> :ok end)
    through = if opts[:all], do: 0, else: String.to_integer(Store.meta(path, @through) || "0")
    importing = HalC2.Import.PreviousInstall.unfinished(path)
    ends = Store.stream_ends(path, "thread", through)
    log_end = ends |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> through end)

    report =
      ends
      |> Enum.reject(fn {id, _} -> MapSet.member?(importing, id) end)
      |> Enum.reduce(%{streams: 0, events: 0, rewritten: 0}, fn {id, last}, report ->
        case plan(path, id, last) do
          [] ->
            report

          ops ->
            removed = apply_ops(store, ops, on_batch)
            rewritten = Enum.count(ops, &(elem(&1, 0) == :rewrite))

            %{
              report
              | streams: report.streams + 1,
                events: report.events + removed,
                rewritten: report.rewritten + rewritten
            }
        end
      end)

    :ok = Store.put_meta(store, @through, Integer.to_string(log_end))
    Map.put(report, :reclaimable, Store.space(path).free)
  end

  @doc """
  How many events compacting every thread stream would remove now, read without
  writing anything, as the doctor surveys a store before it repairs it.
  """
  @spec removable(String.t()) :: non_neg_integer
  def removable(path) do
    importing = HalC2.Import.PreviousInstall.unfinished(path)

    for {id, _} <- Store.stream_ends(path, "thread"),
        not MapSet.member?(importing, id),
        {:delete, _} <- plan(path, id),
        reduce: 0,
        do: (n -> n + 1)
  end

  @doc """
  What compacting the stream `stream_id`, through `through`, would do: the ops
  `HalC2.Store.compact/2` applies, each rewrite ahead of the deletes it absorbs.
  """
  @spec plan(String.t() | reference, String.t(), pos_integer | :infinity) :: [op]
  def plan(path, stream_id, through \\ :infinity) do
    opts = [kinds: @kinds] ++ if(through == :infinity, do: [], else: [through: through])

    path
    |> Store.reduce_stream(stream_id, 0, %{}, &step/2, opts)
    |> Enum.flat_map(fn {_key, entity} -> close(entity).ops end)
    |> Enum.sort_by(&order/1)
  end

  # Rewrites first, by seq, so a batch never deletes what a rewrite in a later batch
  # absorbs before that rewrite is written.
  defp order({:rewrite, seq, _, _, _}), do: {0, seq}
  defp order({:delete, seq}), do: {1, seq}

  defp apply_ops(store, ops, on_batch) do
    ops
    |> Enum.chunk_every(@batch)
    |> Enum.reduce(0, fn batch, removed ->
      {:ok, n} = Store.compact(store, batch)
      on_batch.()
      removed + n
    end)
  end

  # Each entity: its value, the ops its closed runs left, and the run it is in:
  # `active` the last activity in it and what it absorbs, `quiet` the last event after
  # that and what it absorbs, each `{seq, value, touched fields, absorbed seqs, patch}`.
  defp step(event, entities) do
    if StreamState.void?(event) do
      entities
    else
      key = {event.kind, event.entity}
      entity = Map.get(entities, key, %{value: nil, ops: [], active: nil, quiet: nil})
      Map.put(entities, key, fold(entity, event))
    end
  end

  defp fold(entity, %{patch: patch} = event) do
    value = Patch.apply(entity.value, patch)

    if entity.value == nil or value == nil or Map.has_key?(patch, "d") do
      %{close(entity) | value: value}
    else
      touched = touched(patch)
      mark = {event.seq, event.kind, event.entity, patch}

      if patch["q"] == true,
        do: %{entity | value: value, quiet: absorb(entity.quiet, mark, value, touched)},
        else: %{
          entity
          | value: value,
            active: absorb(merge(entity.active, entity.quiet), mark, value, touched),
            quiet: nil
        }
    end
  end

  # The run so far, absorbed into its newest event.
  defp absorb(nil, mark, value, touched),
    do: %{mark: mark, value: value, touched: touched, gone: []}

  defp absorb(run, mark, value, touched) do
    {seq, _, _, _} = run.mark

    %{
      mark: mark,
      value: value,
      touched: MapSet.union(run.touched, touched),
      gone: [seq | run.gone]
    }
  end

  defp merge(nil, quiet), do: quiet
  defp merge(active, nil), do: active

  defp merge(active, quiet) do
    {seq, _, _, _} = active.mark

    %{
      quiet
      | touched: MapSet.union(active.touched, quiet.touched),
        gone: active.gone ++ [seq | quiet.gone]
    }
  end

  defp close(entity) do
    ops = entity.ops ++ ops(entity.active, false) ++ ops(entity.quiet, true)
    %{entity | ops: ops, active: nil, quiet: nil}
  end

  defp ops(nil, _quiet?), do: []
  defp ops(%{gone: []}, _quiet?), do: []

  defp ops(%{mark: {seq, kind, id, patch}, value: value, touched: touched, gone: gone}, quiet?) do
    {set, unset} = Enum.split_with(touched, &Map.has_key?(value, &1))

    rewrite =
      [{"s", Map.take(value, set)}, {"u", Enum.sort(unset)}, {"q", quiet?}]
      |> Enum.reject(fn {_, v} -> v in [%{}, [], false] end)
      |> Map.new()

    rewrite = if rewrite == patch, do: [], else: [{:rewrite, seq, kind, id, rewrite}]
    rewrite ++ Enum.map(gone, &{:delete, &1})
  end

  defp touched(patch) do
    [Map.keys(Map.get(patch, "s", %{})), Map.keys(Map.get(patch, "a", %{})), patch["u"] || []]
    |> Enum.concat()
    |> MapSet.new()
  end

  @doc "A line for the log that says what a run removed."
  @spec describe(report) :: String.t()
  def describe(report) do
    "compacted #{report.streams} threads: removed #{report.events} events, " <>
      "rewrote #{report.rewritten}, #{report.reclaimable} bytes reclaimable"
  end

  @doc false
  def log(report), do: Logger.info(describe(report))
end
