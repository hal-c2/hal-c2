defmodule HalC2.StorePropTest do
  @moduledoc """
  `HalC2.Store` against a model of the event log: a list of events per stream, the
  snapshots, sidebar rows, indexed messages and meta values last put, the store's id,
  and the next `seq`. Commands append batches (some of which fail and must leave no
  trace), read streams back in every way the MC reads them, put the derived rows,
  search the indexed messages, and restart the store, which must lose nothing it
  acknowledged. `HalC2.StoreParallelPropTest` runs the same model with concurrent
  appenders and readers.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  import HalC2.Prop.Generators

  alias HalC2.Store

  @moduletag timeout: :infinity
  @moduletag capture_log: true

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
  # shell: id => {kind, row}; messages: stream id => %{message id => {role, text, created_at}}
  # clock numbers message creation times, which search orders by.
  def initial_state,
    do: %{
      seq: 0,
      streams: %{},
      snapshots: %{},
      meta: %{},
      shell: %{},
      messages: %{},
      clock: 0,
      store_id: nil
    }

  def command(state), do: commands_for(state, true)

  @doc "The commands a state allows; concurrent runs leave out the one that stops the store."
  def commands_for(state, restarts?) do
    frequency(
      [
        {6, {:call, __MODULE__, :append, [batches(state), at()]}},
        {1,
         {:call, __MODULE__, :append_failing,
          [batches(state), oneof([:first, :last]), stream_id()]}},
        {2, {:call, __MODULE__, :put_meta, [oneof(["k1", "k2"]), utf8()]}},
        {1, {:call, __MODULE__, :meta, [oneof(["k1", "k2"])]}},
        {1, {:call, __MODULE__, :list_streams, []}},
        {1, {:call, __MODULE__, :store_id, []}},
        {1, {:call, __MODULE__, :checkpoint, []}},
        {4, {:call, __MODULE__, :reduce_stream, [stream_id(), after_seq(state), read_opts()]}},
        {2,
         {:call, __MODULE__, :put_snapshot,
          [stream_id(), integer(0, max(state.seq, 1)), json_value()]}},
        {1, {:call, __MODULE__, :get_snapshot, [stream_id()]}},
        {2,
         {:call, __MODULE__, :put_shell,
          [stream_id(), integer(0, max(state.seq, 1)), oneof(["thread", "project"]), entity()]}},
        {1, {:call, __MODULE__, :list_shell, []}},
        {3, {:call, __MODULE__, :index_messages, [stream_id(), messages(), state.clock]}},
        {3, {:call, __MODULE__, :search_messages, [needle(), integer(1, 6)]}}
      ] ++ if(restarts?, do: [{1, {:call, __MODULE__, :restart, []}}], else: [])
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

  # Texts are built from words that exercise LIKE's wildcards and escape, and mixed case.
  @words ["alpha", "Beta", "a%b", "c_d", "bang!", " "]
  defp messages do
    resize(
      3,
      list({oneof(["m1", "m2", "m3"]), oneof(["user", "assistant"]), text()})
    )
  end

  defp text, do: let(words <- resize(3, list(oneof(@words))), do: Enum.join(words))
  defp needle, do: oneof(["alpha", "beta", "BETA", "a%b", "c_d", "d!", "a", " ", "x"])

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

  # Derived rows are only kept for streams that have events or were appended to.
  def next_state(state, _result, {:call, _, :put_snapshot, [id, seq, value]}),
    do: if(known?(state, id), do: put_in(state.snapshots[id], {seq, value}), else: state)

  def next_state(state, _result, {:call, _, :put_shell, [id, _seq, kind, row]}),
    do: if(known?(state, id), do: put_in(state.shell[id], {kind, row}), else: state)

  def next_state(state, _result, {:call, _, :index_messages, [id, messages, clock]}) do
    if known?(state, id) do
      indexed =
        messages
        |> Enum.with_index(clock)
        |> Enum.reduce(Map.get(state.messages, id, %{}), fn {{mid, role, text}, n}, acc ->
          Map.put(acc, mid, {role, text, created_at(n, id, mid)})
        end)

      %{state | messages: Map.put(state.messages, id, indexed), clock: clock + length(messages)}
    else
      %{state | clock: clock + length(messages)}
    end
  end

  def next_state(state, _result, {:call, _, :put_meta, [key, value]}),
    do: put_in(state.meta[key], value)

  def next_state(%{store_id: nil} = state, result, {:call, _, :store_id, []}),
    do: %{state | store_id: result}

  def next_state(state, _result, _call), do: state

  def postcondition(state, {:call, _, :append, [batches, _]}, result) do
    written = batches |> Enum.map(fn {_, _, changes} -> length(changes) end) |> Enum.sum()
    # The last seq written, or the end of the log when nothing was.
    result == {:ok, state.seq + written}
  end

  def postcondition(_state, {:call, _, :append_failing, _}, result),
    do: match?({:error, _}, result)

  def postcondition(state, {:call, _, :reduce_stream, [id, after_seq, opts]}, result) do
    kinds = opts[:kinds]

    expected =
      state.streams
      |> Map.get(id, %{events: []})
      |> Map.fetch!(:events)
      |> Enum.filter(&(&1.seq > after_seq and (kinds == nil or &1.kind in kinds)))
      |> then(&if(opts[:limit], do: Enum.take(&1, opts[:limit]), else: &1))
      |> Enum.map(&%{&1 | patch: json_roundtrip(&1.patch)})

    result == expected
  end

  def postcondition(state, {:call, _, :get_snapshot, [id]}, result),
    do: result == state.snapshots[id]

  def postcondition(state, {:call, _, :put_snapshot, [id | _]}, result),
    do: result == if(known?(state, id), do: :ok, else: {:error, :unknown_stream})

  def postcondition(state, {:call, _, :put_shell, [id | _]}, result),
    do: result == if(known?(state, id), do: :ok, else: {:error, :unknown_stream})

  def postcondition(state, {:call, _, :list_shell, []}, result) do
    expected =
      for {id, {kind, row}} <- state.shell, do: {id, kind, json_roundtrip(row)}

    Enum.sort(result) == Enum.sort(expected)
  end

  # Search finds exactly the indexed texts that contain the needle, newest first.
  def postcondition(state, {:call, _, :search_messages, [needle, limit]}, result) do
    needle = String.downcase(needle)

    expected =
      for {id, messages} <- state.messages,
          {_, {role, text, created_at}} <- messages,
          String.contains?(String.downcase(text), needle),
          do: {id, role, text, created_at}

    result == expected |> Enum.sort_by(&elem(&1, 3), :desc) |> Enum.take(limit)
  end

  def postcondition(state, {:call, _, :meta, [key]}, result), do: result == state.meta[key]

  def postcondition(state, {:call, _, :store_id, []}, result) do
    if state.store_id,
      do: result == state.store_id,
      else: is_binary(result) and byte_size(result) == 16
  end

  def postcondition(_state, {:call, _, :checkpoint, []}, result) do
    # A checkpoint that finds another one running does nothing and says so.
    result == {:error, :busy} or
      match?({:ok, %{log: log, checkpointed: done}} when done in 0..log//1, result)
  end

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

  defp known?(state, id), do: Map.has_key?(state.streams, id)

  defp with_time({kind, entity, patch}, at), do: {kind, entity, patch, at}
  defp with_time(change, _at), do: change

  # The log stores JSON: a patch comes back as its JSON reading.
  defp json_roundtrip(patch), do: patch |> JSON.encode!() |> JSON.decode!()

  # Distinct messages never share a time, even when concurrent calls start from the same
  # clock, so search has one order to be held to.
  defp created_at(n, stream_id, message_id),
    do: "2026-01-01T00:00:" <> String.pad_leading("#{n}", 8, "0") <> stream_id <> message_id

  # --- system under test --------------------------------------------------------

  def append(batches, at), do: Store.append(Store, batches, at)

  # A batch the store cannot encode, before or after the others: the whole call rolls
  # back, including a stream it would have created.
  def append_failing(batches, where, stream_id) do
    bad = {:thread, stream_id, [{"thread", "e1", {:not_json}}]}
    Store.append(if(where == :first, do: [bad | batches], else: batches ++ [bad]))
  end

  def reduce_stream(id, after_seq, opts),
    do: Store.reduce_stream(Store.path(), id, after_seq, [], &[&1 | &2], opts) |> Enum.reverse()

  def put_snapshot(id, seq, value), do: Store.put_snapshot(id, seq, value)
  def get_snapshot(id), do: Store.get_snapshot(Store.path(), id)
  def put_shell(id, seq, kind, row), do: Store.put_shell(id, seq, {kind, row})
  def list_shell, do: Store.list_shell(Store.path())

  # Indexing is a cast; a call to the store from the same process returns after it.
  def index_messages(id, messages, clock) do
    indexed =
      messages
      |> Enum.with_index(clock)
      |> Enum.map(fn {{mid, role, text}, n} -> {mid, role, text, created_at(n, id, mid)} end)

    Store.index_messages(id, indexed)
    _ = :sys.get_state(Store)
    :ok
  end

  def search_messages(needle, limit) do
    escaped = String.replace(needle, ["!", "%", "_"], &("!" <> &1))
    Store.search_messages(Store.path(), "%" <> escaped <> "%", limit)
  end

  def put_meta(key, value), do: Store.put_meta(key, value)
  def meta(key), do: Store.meta(Store.path(), key)
  def list_streams, do: Store.list_streams(Store.path())
  def store_id, do: Store.id()
  def checkpoint, do: Store.checkpoint()

  # Stopping and starting again must keep everything acknowledged.
  def restart, do: HalC2.Prop.restart_service(Store)
end

defmodule HalC2.StoreParallelPropTest do
  @moduledoc """
  The store's model with concurrent callers: appenders, readers and the derived-row
  writers run at once, and some order of them must explain every result. The store is
  never restarted here, since a call to a stopped store is rightly an exit.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Store
  alias HalC2.StorePropTest, as: Model

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  property "concurrent callers see an order of the acknowledged writes",
    numtests: HalC2.Prop.numtests(100),
    max_size: 20 do
    forall cmds <- parallel_commands(__MODULE__) do
      trap_exit do
        HalC2.Prop.scratch_home("store-parallel")
        HalC2.Prop.start_services([{Store, path: Store.home_path()}])
        {sequential, parallel, result} = run_parallel_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()

        (result == :ok)
        |> when_fail(
          IO.puts("""
          Sequential: #{inspect(sequential, pretty: true, limit: :infinity)}
          Parallel: #{inspect(parallel, pretty: true, limit: :infinity)}
          Result: #{inspect(result, pretty: true)}
          """)
        )
        |> aggregate(command_names(cmds))
      end
    end
  end

  defdelegate initial_state, to: Model
  defdelegate precondition(state, call), to: Model
  defdelegate next_state(state, result, call), to: Model
  defdelegate postcondition(state, call, result), to: Model

  def command(state), do: Model.commands_for(state, false)
end
