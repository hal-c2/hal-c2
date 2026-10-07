defmodule HalC2.StreamsParallelPropTest do
  @moduledoc """
  `HalC2.Streams` under concurrent commits and subscribes. Commit results must be
  linearizable against a model of the global seq and each stream's fold, and once
  everything settles every subscriber that ever subscribed holds what the log says:
  a plain one was sent exactly the log after its `live` seq, and every one folds to
  the stream's final state.

  Each subscribe starts its own `HalC2.Prop.StreamsCollector`, so concurrent
  subscriptions never share one.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Prop.StreamsCollector, as: Collector
  alias HalC2.{Store, Streams, StreamState}
  alias HalC2.Streams.{Server, View}

  @moduletag timeout: :infinity

  @streams ["s-a", "s-b"]
  @notes ["n1", "n2", "n3"]
  @subscribed :streams_parallel_subscribed

  property "concurrent commits and subscribes stay linearizable and converge",
    numtests: HalC2.Prop.numtests(100),
    max_size: 20 do
    forall cmds <- parallel_commands(__MODULE__) do
      trap_exit do
        HalC2.Prop.scratch_home("streams-parallel")
        HalC2.Prop.start_services([{Store, path: Store.home_path()}, Streams])
        table = :ets.new(@subscribed, [:named_table, :public, :bag])

        try do
          {sequential, branches, result} = run_parallel_commands(__MODULE__, cmds)
          settled = settled()

          # `HalC2.Prop.report/4` reads a sequential history only.
          (result == :ok and settled == :ok)
          |> when_fail(
            IO.puts(
              inspect(
                %{sequential: sequential, branches: branches, result: result, settled: settled},
                pretty: true,
                limit: :infinity
              )
            )
          )
          |> aggregate(command_names(cmds))
        after
          for {_id, pid, _mode} <- :ets.tab2list(table), do: Process.exit(pid, :kill)
          :ets.delete(table)
          HalC2.Prop.stop_services()
        end
      end
    end
  end

  # --- model ------------------------------------------------------------------

  def initial_state, do: %{seq: 0, folds: %{}}

  def command(_state) do
    frequency([
      {5, {:call, __MODULE__, :commit, [stream(), changes()]}},
      {3, {:call, __MODULE__, :subscribe, [stream(), oneof([:plain, :client]), oneof([nil, 0])]}},
      {1, {:call, __MODULE__, :state, [stream()]}}
    ])
  end

  defp stream, do: oneof(@streams)

  defp changes do
    resize(
      4,
      list(
        oneof([
          {"note", oneof(@notes), let(v <- integer(0, 9), do: %{"s" => %{"v" => v}})},
          {"note", oneof(@notes), exactly(%{"d" => true})},
          {"note", oneof(@notes), exactly(%{"s" => nil})}
        ])
      )
    )
  end

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :commit, [_id, []]}), do: state

  def next_state(state, _result, {:call, _, :commit, [id, changes]}) do
    {events, seq} =
      Enum.map_reduce(changes, state.seq, fn {kind, entity, patch}, seq ->
        {%{seq: seq + 1, kind: kind, entity: entity, patch: patch, at: 0}, seq + 1}
      end)

    fold = Enum.reduce(events, fold(state, id), &StreamState.apply_event(&2, &1))
    %{state | seq: seq, folds: Map.put(state.folds, id, fold)}
  end

  def next_state(state, _result, _call), do: state

  def postcondition(state, {:call, _, :commit, [id, []]}, result),
    do: result == {:ok, fold(state, id).seq}

  def postcondition(state, {:call, _, :commit, [_id, changes]}, result),
    do: result == {:ok, state.seq + length(changes)}

  def postcondition(state, {:call, _, :state, [id]}, result),
    do: result == comparable(fold(state, id))

  def postcondition(_state, _call, result), do: result == :ok

  defp fold(state, id), do: Map.get(state.folds, id, StreamState.new())

  defp comparable(st), do: %{st | updated_at: nil}

  # --- what everyone holds once it settles ---------------------------------------

  # A call to the stream returns after every message it sent before, and those are
  # already in the collectors' mailboxes ahead of our request.
  defp settled do
    failures =
      Enum.flat_map(:ets.tab2list(@subscribed), fn {id, pid, mode} ->
        final = Server.state(Streams.ensure(id))
        log = Store.reduce_stream(Store.path(), id, 0, [], &[&1 | &2]) |> Enum.reverse()
        got = Collector.get(pid, id)
        if holds?(mode, got, final, log), do: [], else: [{id, mode, got}]
      end)

    if failures == [], do: :ok, else: failures
  end

  defp holds?(:plain, got, final, log) do
    case Enum.split_while(got.msgs, &(not match?({:live, _}, &1))) do
      {_initial, [{:live, live} | tail]} ->
        sent = for {:events, evs} <- tail, ev <- evs, do: strip(ev)
        sent == for(ev <- log, ev.seq > live, do: strip(ev)) and got.entities == rows(final)

      _ ->
        false
    end
  end

  defp holds?(:client, got, final, _log) do
    offsets = for {:events, _, seq} <- got.msgs, do: seq
    expected = View.rows(%{kinds: nil, window: nil}, final)

    offsets == Enum.uniq(Enum.sort(offsets)) and
      got.entities == Map.new(expected, fn {kind, id, e} -> {{kind, id}, e} end)
  end

  defp rows(st), do: Map.new(StreamState.rows(st), fn {kind, id, e} -> {{kind, id}, e} end)

  defp strip(event), do: Map.take(event, [:seq, :kind, :entity, :patch])

  # --- system under test --------------------------------------------------------

  def commit(id, changes), do: Streams.commit(id, :thread, changes)

  def subscribe(id, mode, from) do
    pid = Collector.start()
    :ok = Collector.reset(pid, id, from, false)
    :ets.insert(@subscribed, {id, pid, mode})

    case mode do
      :plain -> Streams.subscribe(id, pid, from)
      :client -> Streams.subscribe(id, pid, from, %{kinds: nil})
    end
  end

  def state(id), do: comparable(Server.state(Streams.ensure(id)))
end
