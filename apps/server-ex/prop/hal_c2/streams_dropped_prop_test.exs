defmodule HalC2.StreamsDroppedPropTest do
  @moduledoc """
  A state machine over one process whose turn the store failed (`HalC2.Streams.unrecorded/2`
  for the thread "t"), writing to its thread and to a subagent's thread ("child"), which
  a full disk refuses, with recorded writes, reads and the end of the turn
  (`HalC2.Streams.forget_unrecorded/0`) between:

  - the store keeps every write made outside dry mode, and those to "child" while the
    disk had room and no write to it had been dropped, and nothing else;
  - what the process decides and reads in dry mode is the store's record with the
    changes it dropped, so a write that ends an entity it made finds it;
  - once forgotten, or outside dry mode, it reads the store's record alone.

  The messages belong to a settled run, which later runs push into cold storage
  (`HalC2.StreamState`, "Hot and cold"), so a dropped change can be to a cold one.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.StreamState

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @streams ~w(t child)
  @ids ~w(m1 m2)

  property "a turn the store failed decides on what it dropped, until it ends",
    numtests: HalC2.Prop.numtests(100),
    max_size: 30 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("streams-dropped")
        :persistent_term.put({__MODULE__, :full}, false)
        Application.put_env(:hal_c2, :store_hook, {__MODULE__, :refuse, []})
        Application.put_env(:hal_c2, :stream_hot_items, 1)

        HalC2.Prop.start_services([
          {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
          HalC2.Streams
        ])

        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()
        HalC2.Streams.forget_unrecorded()
        Application.delete_env(:hal_c2, :store_hook)
        Application.delete_env(:hal_c2, :stream_hot_items)

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # A full disk refuses the subagent's thread.
  def refuse(:append_change, "child") do
    if :persistent_term.get({__MODULE__, :full}) and self() == Process.whereis(HalC2.Store),
      do: raise("the disk is full")

    :ok
  end

  def refuse(_stage, _stream_id), do: :ok

  # --- model ----------------------------------------------------------------------

  # store: {stream, id} -> text, as recorded; dropped: {stream, id} -> text | nil, what
  # the process dropped (nil: deleted); dry: the streams it drops writes to while dry.
  def initial_state, do: %{store: %{}, dropped: %{}, dry: MapSet.new(["t"]), full: false}

  def command(_state) do
    frequency([
      {3, {:call, __MODULE__, :dry_write, [oneof(@streams), oneof(@ids), op(), text()]}},
      {2, {:call, __MODULE__, :dry_read, [oneof(@streams), oneof(@ids)]}},
      {2, {:call, __MODULE__, :write, [oneof(@streams), oneof(@ids), text()]}},
      {2, {:call, __MODULE__, :read, [oneof(@streams), oneof(@ids)]}},
      {1, {:call, __MODULE__, :cool, [oneof(@streams)]}},
      {1, {:call, __MODULE__, :disk, [boolean()]}},
      {1, {:call, __MODULE__, :forget, []}}
    ])
  end

  defp op, do: oneof([:put, :merge, :delete])
  defp text, do: oneof(~w(a b c))

  # A recorded write to "child" waits for the disk; a delete for what is there.
  def precondition(state, {:call, _, :write, ["child", _, _]}), do: not state.full
  def precondition(state, {:call, _, :cool, ["child"]}), do: not state.full

  def precondition(state, {:call, _, :dry_write, [stream, id, :delete, _]}),
    do: view(state, stream, id) != nil

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :dry_write, [stream, id, op, text]}) do
    value = if op == :delete, do: nil, else: text

    if stream in state.dry or state.full,
      do: %{
        state
        | dropped: Map.put(state.dropped, {stream, id}, value),
          dry: MapSet.put(state.dry, stream)
      },
      else: %{state | store: put(state.store, {stream, id}, value)}
  end

  def next_state(state, _result, {:call, _, :write, [stream, id, text]}),
    do: %{state | store: Map.put(state.store, {stream, id}, text)}

  def next_state(state, _result, {:call, _, :disk, [full]}), do: %{state | full: full}

  def next_state(state, _result, {:call, _, :forget, []}),
    do: %{state | dropped: %{}, dry: MapSet.new(["t"])}

  def next_state(state, _result, _call), do: state

  def postcondition(state, {:call, _, :dry_write, [stream, id, _, _]}, seen),
    do: seen == view(state, stream, id)

  def postcondition(state, {:call, _, :dry_read, [stream, id]}, seen),
    do: seen == {view(state, stream, id), view(state, stream, id)}

  def postcondition(state, {:call, _, :read, [stream, id]}, seen),
    do: seen == {state.store[{stream, id}], state.store[{stream, id}]}

  def postcondition(_state, _call, result), do: result == :ok

  # What the process sees of an entity while dry.
  defp view(state, stream, id) do
    case state.dropped do
      %{{^stream, ^id} => value} -> value
      _ -> state.store[{stream, id}]
    end
  end

  defp put(store, key, nil), do: Map.delete(store, key)
  defp put(store, key, text), do: Map.put(store, key, text)

  # --- commands -------------------------------------------------------------------

  # A write decided in dry mode; returns the text it found.
  def dry_write(stream, id, op, text) do
    HalC2.Streams.unrecorded("t", fn ->
      HalC2.Streams.transact(stream, :thread, fn state ->
        found = StreamState.fetch(state, "message", id)

        patch =
          case op do
            :put -> %{"s" => %{"id" => id, "runId" => "r0", "text" => text}}
            :merge -> %{"s" => %{"text" => text}}
            :delete -> %{"d" => true}
          end

        {[{"message", id, patch}], found && found["text"]}
      end)
    end)
  end

  # What the process reads in dry mode, by key and in the stream's state.
  def dry_read(stream, id), do: HalC2.Streams.unrecorded("t", fn -> read(stream, id) end)

  def write(stream, id, text) do
    {:ok, _} =
      HalC2.Streams.commit(stream, :thread, [
        {"message", id, %{"s" => %{"id" => id, "runId" => "r0", "text" => text}}}
      ])

    :ok
  end

  # A settled run with more turn items than memory keeps, recorded: the messages'
  # run, settled before it, goes cold.
  def cool(stream) do
    n = System.unique_integer([:positive, :monotonic])
    run = "r#{n}"

    {:ok, _} =
      HalC2.Streams.commit(
        stream,
        :thread,
        [
          {"run", "r0", %{"s" => %{"id" => "r0", "ordinal" => 0, "status" => "completed"}}},
          {"run", run, %{"s" => %{"id" => run, "ordinal" => n, "status" => "completed"}}}
        ] ++
          for(i <- 1..3, do: {"turn-item", "#{run}-#{i}", %{"s" => %{"runId" => run}}})
      )

    :ok
  end

  def read(stream, id) do
    by_key = HalC2.Streams.get(stream, "message", id)
    in_state = StreamState.fetch(HalC2.Streams.state(stream), "message", id)
    {by_key && by_key["text"], in_state && in_state["text"]}
  end

  def disk(full), do: :persistent_term.put({__MODULE__, :full}, full)
  def forget, do: HalC2.Streams.forget_unrecorded()
end
