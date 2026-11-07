defmodule HalC2.NativeSubagentSettlePropTest do
  @moduledoc """
  A state machine over a thread whose provider starts subagents of its own
  (`HalC2.Orchestration.NativeSubagent`), each working in a thread of its own that has
  no run, where a subagent may start subagents in turn, with tool calls opening and
  ending in those threads, subagents ending, and the MC settling the thread at a
  restart (`Recovery.settle/2`):

  - the settle ends every subagent still running under the thread, however deep, and
    every tool call still running in their threads, which no sidebar row shows active;
  - it leaves alone what had ended, and the threads of subagents that had ended, which
    are not its to settle.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Orchestration.Recovery
  alias HalC2.StreamState

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @thread "t1"

  property "a restart settles the threads of the subagents it ends, however deep",
    numtests: HalC2.Prop.numtests(100),
    max_size: 30 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("native-subagent-settle")

        HalC2.Prop.start_services([
          {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
          HalC2.Streams,
          HalC2.Shell
        ])

        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ----------------------------------------------------------------------

  # subagents: n -> {the thread it runs under, its status}; items: item id -> {thread,
  # status}. A subagent's own thread is "child-n".
  def initial_state, do: %{subagents: %{}, items: %{}}

  def command(state) do
    threads = [@thread | Enum.map(Map.keys(state.subagents), &child/1)]
    n = map_size(state.subagents) + 1

    frequency(
      [
        {3, {:call, __MODULE__, :spawn, [n, oneof(threads)]}},
        {1, {:call, __MODULE__, :restart, []}}
      ] ++
        if(state.subagents == %{},
          do: [],
          else: [
            {3,
             {:call, __MODULE__, :tool, [oneof(Map.keys(state.subagents)), map_size(state.items)]}},
            {1, {:call, __MODULE__, :finish, [oneof(Map.keys(state.subagents))]}}
          ]
        ) ++
        if(state.items == %{},
          do: [],
          else: [{1, {:call, __MODULE__, :end_tool, [oneof(Map.keys(state.items))]}}]
        )
    )
  end

  def precondition(state, {:call, _, :spawn, [n, under]}),
    do:
      n == map_size(state.subagents) + 1 and
        (under == @thread or Enum.any?(Map.keys(state.subagents), &(child(&1) == under)))

  def precondition(state, {:call, _, :tool, [n, i]}),
    do: Map.has_key?(state.subagents, n) and i == map_size(state.items)

  def precondition(state, {:call, _, :finish, [n]}), do: Map.has_key?(state.subagents, n)
  def precondition(state, {:call, _, :end_tool, [id]}), do: Map.has_key?(state.items, id)
  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :spawn, [n, under]}),
    do: put_in(state.subagents[n], {under, "running"})

  def next_state(state, _result, {:call, _, :tool, [n, i]}),
    do: put_in(state.items[item(i)], {child(n), "running"})

  def next_state(state, _result, {:call, _, :finish, [n]}),
    do: update_in(state.subagents[n], fn {under, _} -> {under, "completed"} end)

  def next_state(state, _result, {:call, _, :end_tool, [id]}),
    do: update_in(state.items[id], fn {thread, _} -> {thread, "completed"} end)

  def next_state(state, _result, {:call, _, :restart, _}) do
    ended = ended(state)

    %{
      subagents:
        Map.new(state.subagents, fn
          {n, {under, "running"}} ->
            {n, {under, if(n in ended, do: "interrupted", else: "running")}}

          other ->
            other
        end),
      items:
        Map.new(state.items, fn
          {id, {thread, "running"}} ->
            {id, {thread, if(thread in threads(ended), do: "interrupted", else: "running")}}

          other ->
            other
        end)
    }
  end

  def next_state(state, _result, _call), do: state

  def postcondition(state, {:call, _, :restart, _}, seen) do
    after_restart = next_state(state, nil, {:call, __MODULE__, :restart, []})

    seen ==
      %{
        subagents: Map.new(after_restart.subagents, fn {n, {_, status}} -> {n, status} end),
        items: Map.new(after_restart.items, fn {id, {_, status}} -> {id, status} end)
      }
  end

  def postcondition(_state, _call, _result), do: true

  # The subagents the settle reaches: running, under the thread or under a subagent it
  # reaches (a thread is settled for the subagents it ends).
  defp ended(state) do
    Stream.iterate(MapSet.new(), fn reached ->
      for {n, {under, "running"}} <- state.subagents,
          under == @thread or under in threads(reached),
          into: reached,
          do: n
    end)
    |> Stream.chunk_every(2, 1)
    |> Enum.find_value(fn [a, b] -> if a == b, do: a end)
  end

  defp threads(subagents), do: Enum.map(subagents, &child/1)

  # --- commands -------------------------------------------------------------------

  # The provider of `under` starts subagent `n`, which works in its own thread.
  def spawn(n, under) do
    id = "subagent-#{n}"

    commit(under, [
      {"subagent", id,
       %{
         "id" => id,
         "origin" => "provider_native",
         "status" => "running",
         "childThreadId" => child(n)
       }}
    ])
  end

  # Subagent `n` calls a tool, which shows in its thread.
  def tool(n, i),
    do:
      commit(child(n), [
        {"turn-item", item(i),
         %{"id" => item(i), "type" => "command_execution", "status" => "running"}}
      ])

  def finish(n) do
    {under, _} = owner(n)
    commit(under, [{"subagent", "subagent-#{n}", %{"status" => "completed"}}])
  end

  def end_tool(id) do
    thread = Enum.find(streams(), &StreamState.get(stream(&1), "turn-item")[id])
    commit(thread, [{"turn-item", id, %{"status" => "completed"}}])
  end

  # The MC restarts and settles the thread; returns every subagent's and tool call's
  # status.
  def restart do
    Recovery.settle(@thread)
    states = Enum.map(streams(), &stream/1)

    %{
      subagents:
        for(
          state <- states,
          %{"id" => "subagent-" <> n, "status" => status} <- StreamState.list(state, "subagent"),
          into: %{},
          do: {String.to_integer(n), status}
        ),
      items:
        for(
          state <- states,
          %{"id" => id, "status" => status} <- StreamState.list(state, "turn-item"),
          into: %{},
          do: {id, status}
        )
    }
  end

  # --- helpers --------------------------------------------------------------------

  defp child(n), do: "child-#{n}"
  defp item(i), do: "item-#{i}"

  # The streams written so far: the thread and its subagents' threads.
  defp streams do
    Stream.iterate(1, &(&1 + 1))
    |> Enum.take_while(&(owner(&1) != nil))
    |> Enum.map(&child/1)
    |> then(&[@thread | &1])
  end

  defp owner(n) do
    Enum.find_value([@thread | Enum.map(1..(n - 1)//1, &child/1)], fn thread ->
      if StreamState.get(stream(thread), "subagent")["subagent-#{n}"], do: {thread, n}
    end)
  end

  defp stream(thread), do: HalC2.Streams.state(thread)

  defp commit(thread, entities) do
    {:ok, _} =
      HalC2.Streams.commit(
        thread,
        :thread,
        for({kind, id, s} <- entities, do: {kind, id, %{"s" => s}})
      )

    :ok
  end
end
