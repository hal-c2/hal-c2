defmodule HalC2.StorePropTest do
  @moduledoc """
  `HalC2.Store` against a model of the event log: a list of events per stream, the
  snapshots and meta values last put, and the next `seq`. Commands append batches,
  read streams back in every way the MC reads them, put snapshots and meta, and
  restart the store, which must lose nothing it acknowledged.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  import HalC2.Prop.Generators

  alias HalC2.Store

  @moduletag timeout: :infinity

  property "the store reads back exactly what it acknowledged",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        HalC2.Prop.scratch_home("store")
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

  # streams: id => %{kind: "thread" | "project", events: [event] oldest first}
  def initial_state, do: %{seq: 0, streams: %{}, snapshots: %{}, meta: %{}}

  def command(state) do
    known = Map.keys(state.streams)

    frequency(
      [
        {6, {:call, __MODULE__, :append, [batches(state), at()]}},
        {2, {:call, __MODULE__, :put_meta, [oneof(["k1", "k2"]), utf8()]}},
        {1, {:call, __MODULE__, :meta, [oneof(["k1", "k2"])]}},
        {1, {:call, __MODULE__, :list_streams, []}},
        {1, {:call, __MODULE__, :restart, []}}
      ] ++
        if known == [] do
          []
        else
          [
            {4,
             {:call, __MODULE__, :reduce_stream, [oneof(known), after_seq(state), read_opts()]}},
            {2,
             {:call, __MODULE__, :put_snapshot,
              [oneof(known), integer(0, max(state.seq, 1)), json_value()]}},
            {1, {:call, __MODULE__, :get_snapshot, [oneof(known)]}}
          ]
        end
    )
  end

  # A stream keeps the kind it was created with, so a batch names a new stream's kind
  # and repeats an existing one's.
  defp batches(state) do
    resize(
      4,
      list(
        let {id, kind, changes} <-
              {stream_id(), oneof([:thread, :project]), resize(6, list(change()))} do
          case state.streams do
            %{^id => %{kind: existing}} -> {String.to_existing_atom(existing), id, changes}
            _ -> {kind, id, changes}
          end
        end
      )
    )
  end

  defp change do
    oneof([
      {entity_kind(), entity_id(), patch()},
      {entity_kind(), entity_id(), patch(), at()}
    ])
  end

  defp at, do: integer(1_700_000_000_000, 1_800_000_000_000)
  defp after_seq(state), do: oneof([0, integer(0, state.seq + 1)])

  defp read_opts do
    oneof([
      [],
      [limit: integer(0, 5)],
      [kinds: list(entity_kind())],
      [limit: integer(1, 5), kinds: list(entity_kind())]
    ])
  end

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :append, [batches, at]}) do
    Enum.reduce(batches, state, fn {kind, id, changes}, state ->
      stream = Map.get(state.streams, id, %{kind: Atom.to_string(kind), events: []})

      {events, seq} =
        Enum.map_reduce(changes, state.seq, fn change, seq ->
          {kind, entity, patch, at} = with_time(change, at)
          {%{seq: seq + 1, kind: kind, entity: entity, patch: patch, at: at}, seq + 1}
        end)

      # The store creates a stream on first use, even for an empty batch.
      stream = %{stream | events: stream.events ++ events}
      %{state | seq: seq, streams: Map.put(state.streams, id, stream)}
    end)
  end

  def next_state(state, _result, {:call, _, :put_snapshot, [id, seq, value]}),
    do: put_in(state.snapshots[id], {seq, value})

  def next_state(state, _result, {:call, _, :put_meta, [key, value]}),
    do: put_in(state.meta[key], value)

  def next_state(state, _result, _call), do: state

  def postcondition(state, {:call, _, :append, [batches, _]}, result) do
    written = batches |> Enum.map(fn {_, _, changes} -> length(changes) end) |> Enum.sum()
    # The last seq written; a call that writes nothing reports 0, not the log's end.
    result == {:ok, if(written == 0, do: 0, else: state.seq + written)}
  end

  def postcondition(state, {:call, _, :reduce_stream, [id, after_seq, opts]}, result) do
    kinds = opts[:kinds]

    expected =
      state.streams[id].events
      |> Enum.filter(&(&1.seq > after_seq and (kinds == nil or &1.kind in kinds)))
      |> then(&if(opts[:limit], do: Enum.take(&1, opts[:limit]), else: &1))
      |> Enum.map(&%{&1 | patch: json_roundtrip(&1.patch)})

    result == expected
  end

  def postcondition(state, {:call, _, :get_snapshot, [id]}, result),
    do: result == state.snapshots[id]

  def postcondition(state, {:call, _, :meta, [key]}, result), do: result == state.meta[key]

  def postcondition(state, {:call, _, :list_streams, []}, result) do
    expected =
      for {id, stream} <- state.streams,
          do: %{
            id: id,
            kind: stream.kind,
            seq: stream.events |> Enum.map(& &1.seq) |> Enum.max(fn -> 0 end)
          }

    Enum.sort_by(result, & &1.id) == Enum.sort_by(expected, & &1.id)
  end

  def postcondition(_state, _call, result), do: result in [:ok, true]

  defp with_time({kind, entity, patch}, at), do: {kind, entity, patch, at}
  defp with_time(change, _at), do: change

  # The log stores JSON: a patch comes back as its JSON reading.
  defp json_roundtrip(patch), do: patch |> JSON.encode!() |> JSON.decode!()

  # --- system under test --------------------------------------------------------

  def append(batches, at), do: Store.append(Store, batches, at)

  def reduce_stream(id, after_seq, opts),
    do: Store.reduce_stream(Store.path(), id, after_seq, [], &[&1 | &2], opts) |> Enum.reverse()

  def put_snapshot(id, seq, value), do: Store.put_snapshot(id, seq, value)
  def get_snapshot(id), do: Store.get_snapshot(Store.path(), id)
  def put_meta(key, value), do: Store.put_meta(key, value)
  def meta(key), do: Store.meta(Store.path(), key)
  def list_streams, do: Store.list_streams(Store.path())

  # Stopping and starting again must keep everything acknowledged.
  def restart, do: HalC2.Prop.restart_service(Store)
end
