defmodule HalC2.StoreCompactionPropTest do
  @moduledoc """
  `HalC2.Store.Compaction` against a model of the log as it was written: every event
  of each thread stream, none ever removed. Commands append batches of thread,
  message and turn-item patches (sets, appends, unsets, deletes, replacements, voids,
  any of them quiet), compact the log, restart the store, and resume a client from an
  offset. Whatever compaction removed, a client that had the log up to any offset
  and reads the store after it folds to the state the whole log folds to: the same
  entities, the seqs they were created, changed and deleted at, the stream's last
  seq and its `updated_at`. A second compaction straight after one removes nothing.
  `HalC2.StoreCompactionParallelPropTest` runs compaction alongside appends and
  resumes.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Store, StreamState}
  alias HalC2.Prop.PatchGenerators
  alias HalC2.Store.Compaction

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @streams ["s-a", "s-b"]

  property "compaction leaves every resume with the state of the whole log",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        HalC2.Prop.scratch_home("store-compaction")
        HalC2.Prop.start_services([{Store, path: Store.home_path()}])
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ------------------------------------------------------------------

  # events: stream => [event] oldest first, as written. seq: the log's last seq.
  def initial_state, do: %{seq: 0, events: %{}}

  def command(state), do: commands_for(state, :sequential)

  @doc "The commands a state allows; concurrent callers (`:parallel`) do not restart the store."
  def commands_for(state, mode) do
    frequency(
      [
        # An append lands at the time the seq before it names, so times move.
        {6, {:call, __MODULE__, :append, [oneof(@streams), changes(mode), state.seq]}},
        {3, {:call, __MODULE__, :resume, [oneof(@streams), offset(state)]}},
        {2, {:call, __MODULE__, :compact, [mode]}}
      ] ++ if(mode == :sequential, do: [{1, {:call, __MODULE__, :restart, []}}], else: [])
    )
  end

  # A batch of changes, each valid against the entity the stream holds when it lands.
  # Concurrent appends to one entity may land in either order, so they never append
  # to a string, which only the order they were generated in makes valid.
  defp changes(:parallel), do: resize(5, list(no_appends()))
  defp changes(:sequential), do: resize(5, list(PatchGenerators.event_raw()))

  defp no_appends do
    let {kind, id, {op, sets, _appends, unsets, quiet}} <- PatchGenerators.event_raw() do
      {kind, id, {op, sets, %{}, unsets, quiet}}
    end
  end

  defp offset(%{seq: 0}), do: 0
  defp offset(state), do: integer(0, state.seq)

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :append, [stream, raws, at]}) do
    {seq, events} =
      Enum.reduce(raws, {state.seq, Map.get(state.events, stream, [])}, fn raw, {seq, acc} ->
        event = event(acc, raw, seq + 1, 1_000 + at)
        {seq + 1, acc ++ [event]}
      end)

    %{state | seq: seq, events: Map.put(state.events, stream, events)}
  end

  def next_state(state, _result, _call), do: state

  def postcondition(state, {:call, _, :append, [_, raws, _]}, result),
    do: result == {:ok, if(raws == [], do: state.seq, else: state.seq + length(raws))}

  def postcondition(state, {:call, _, :resume, [stream, offset]}, read),
    do: resumes?(Map.get(state.events, stream, []), offset, read)

  def postcondition(state, {:call, _, :compact, [:sequential]}, {report, again, logs}) do
    again.events == 0 and report.events >= 0 and
      Enum.all?(@streams, fn stream ->
        written = Map.get(state.events, stream, [])
        read = Map.get(logs, stream, [])

        last(read) == last(written) and
          Enum.all?([0 | Enum.map(written, & &1.seq)], fn offset ->
            resumes?(written, offset, Enum.drop_while(read, &(&1.seq <= offset)))
          end)
      end)
  end

  def postcondition(_state, {:call, _, :compact, [:parallel]}, result), do: match?(%{}, result)
  def postcondition(_state, {:call, _, :restart, []}, result), do: result == :ok

  # The event a raw change makes against the stream's events so far: valid against the
  # entity its key holds then, numbered and timed as the store writes it.
  defp event(events, {kind, id, raw}, seq, at) do
    entity = (fold(events).entities[kind] || %{})[id]
    %{seq: seq, kind: kind, entity: id, patch: PatchGenerators.valid_patch(entity, raw), at: at}
  end

  defp resumes?(written, offset, read) do
    known = written |> Enum.take_while(&(&1.seq <= offset)) |> fold()
    view(Enum.reduce(read, known, &StreamState.apply_event(&2, &1))) == view(fold(written))
  end

  defp last([]), do: nil
  defp last(events), do: List.last(events).seq

  defp fold(events), do: Enum.reduce(events, StreamState.new(), &StreamState.apply_event(&2, &1))

  defp view(state),
    do: Map.take(state, [:seq, :updated_at, :entities, :created, :changed, :deleted])

  # --- commands -----------------------------------------------------------------

  def append(stream, raws, seq) do
    events = Store.reduce_stream(Store.path(), stream, 0, [], &[&1 | &2]) |> Enum.reverse()

    # The store holds the compacted log, which folds to the state the written one does.
    {_, changes} =
      Enum.reduce(raws, {events, []}, fn raw, {events, acc} ->
        event = event(events, raw, 0, 0)
        {events ++ [event], [{event.kind, event.entity, event.patch} | acc]}
      end)

    Store.append(Store, [{:thread, stream, Enum.reverse(changes)}], 1_000 + seq)
  end

  def resume(stream, offset),
    do: Store.reduce_stream(Store.path(), stream, offset, [], &[&1 | &2]) |> Enum.reverse()

  def compact(:parallel), do: Compaction.run(Store, all: true)

  def compact(:sequential) do
    report = Compaction.run(Store, all: true)
    again = Compaction.run(Store, all: true)
    logs = Map.new(@streams, &{&1, resume(&1, 0)})
    {report, again, logs}
  end

  def restart, do: HalC2.Prop.restart_service(Store)
end

defmodule HalC2.StoreCompactionParallelPropTest do
  @moduledoc """
  The compaction model with compaction running alongside appends and resumes:
  compaction applies its batches between other writes, and some order of the calls
  explains every resume.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Store
  alias HalC2.StoreCompactionPropTest, as: Model

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  property "compaction among appends leaves every resume with the state of the log",
    numtests: HalC2.Prop.numtests(100),
    max_size: 20 do
    forall cmds <- parallel_commands(__MODULE__) do
      trap_exit do
        HalC2.Prop.scratch_home("store-compaction-parallel")
        HalC2.Prop.start_services([{Store, path: Store.home_path()}])
        {sequential, parallel, result} = run_parallel_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, sequential, parallel, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  defdelegate initial_state, to: Model
  defdelegate precondition(state, call), to: Model
  defdelegate next_state(state, result, call), to: Model
  defdelegate postcondition(state, call, result), to: Model

  def command(state), do: Model.commands_for(state, :parallel)
end
